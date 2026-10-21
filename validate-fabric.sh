#!/bin/bash
# ai-fabric fabric validation: frontend (Cumulus EVPN-MH, or Nexus vPC fabric peering), firewall/OOB/internet, backend (OcNOS rails + eBGP ECMP).
# Works against the full lab (VM nodes, via ssh) and the light lab (containers, via docker exec). Run on eve: ./validate-fabric.sh
cd "$(dirname "$0")"; . ./lib.sh
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf "  PASS  %s\n" "$1"; }
bad() { FAIL=$((FAIL + 1)); printf "  FAIL  %s%s\n" "$1" "${2:+   -> $2}"; }
# servers are VM guests in the full lab and plain containers in the light lab
if docker inspect -f '{{.Config.Image}}' $LAB-gpu1 2>/dev/null | grep -q vm-node; then MODE=full; HX() { H "$1" "$2"; }; else MODE=light; HX() { X "$1" "$2"; }; fi
ping_t() { # label, node, ping args  (one retry: the first flow through the firewall can lose its first packets to ARP)
  local out; for try in 1 2; do out=$(HX "$2" "ping -c 3 -W 2 -q $3" | grep -oE "[0-9]+ received" | cut -d" " -f1); [ "${out:-0}" -ge 2 ] && { ok "$1"; return; }; sleep 2; done; bad "$1" "${out:-0}/3 replies"; }
echo "== ai-fabric fabric validation ($MODE lab) $(date -u +%FT%TZ)"
read -r STIP STOOB <<< "$(python3 -c 'import gen; print(gen.HOSTS["storage"]["ip"], gen.oob(gen.HOSTS["storage"]["ip"]))')"   # per profile (.16 or .18)
read -r MULTI FBA DV <<< "$(python3 -c 'import gen; print(int(gen.MULTI), gen.FB_API, gen.FE_VLAN)')"      # site-a-nx: VLAN 100/200/300, storage management VIP

echo "-- frontend control plane"
# light hosts are idle containers: one gateway ping each, so the leaves have learned them (ARP -> EVPN /32 host routes) before they are checked
[ "$MODE" = light ] && { for h in $CTRLS storage $GPUS bastion; do X $h "ping -c 2 -W 1 -q 10.1.1.1" >/dev/null 2>&1 & done; wait; }
if [ "$FE_NOS" = nxos ]; then . ./nx-checks.sh; nx_frontend      # Nexus 9300v: the same checks as validate.sh section B
else
for s in $FE_SPINES; do n=$(CVX $s "sudo vtysh -c 'show bgp l2vpn evpn summary json'" | grep -c '"state":"Established"'); [ "$n" = 8 ] && ok "$s: 8/8 EVPN sessions Established" || bad "$s EVPN sessions" "$n/8"; done
for l in $FE_LEAVES; do
  n=$(CVX $l "sudo vtysh -c 'show evpn es'" | grep -c " L"); b=$(CVX $l "grep -l 'MII Status: up' /proc/net/bonding/bond* 2>/dev/null | wc -l")
  [ "$n" -ge 1 ] && [ "$b" -ge 1 ] && ok "$l: $n local ES, $b bonds up" || bad "$l ES/bonds" "ES=$n bonds=$b"
done
g=$(CVX fe-gpu-leaf1 "ip -br link show vlan10-v0" | awk '{print $3}'); [ "$g" = "00:0a:00:c1:00:01" ] && ok "anycast gateway MAC 00:0a:00:c1:00:01 on vlan10" || bad "anycast gateway MAC" "$g"
for b in $FE_BORDERS; do CVX $b "sudo vtysh -c 'show bgp vrf k8s ipv4 unicast summary'" | grep -E "^10\.1\.254\." | grep -qE "[0-9]+:[0-9]+:[0-9]+ +[0-9]+ " && ok "$b: eBGP to the firewall Established (vrf k8s)" || bad "$b firewall BGP"; done
CVX fe-gpu-leaf1 "ip route show vrf k8s" | grep -q "^default" && ok "default route from the firewall present in vrf k8s on a server leaf" || bad "default route in vrf k8s"

fi

echo "-- frontend host attachment"
for h in gpu1 gpu8 ctrl1; do a=$(HX $h "grep -o \"Aggregator ID: [0-9]*\" /proc/net/bonding/bond0 | sort -u | wc -l"); [ "$a" = 1 ] && ok "$h: both bond0 legs in one LACP aggregator (ESI-LAG)" || bad "$h LACP" "aggregators=$a"; done
a=$(HX storage "grep -o \"Aggregator ID: [0-9]*\" /proc/net/bonding/bond0 | sort -u | wc -l"); m=$(HX storage "grep -c \"Slave Interface\" /proc/net/bonding/bond0")
[ "$a" = 1 ] && [ "$m" = 8 ] && ok "storage: 8 links in one aggregator across both leaves of its pair" || bad "storage LACP" "members=$m aggregators=$a"
HX storage "ip -br addr show bond0.$DV" | grep -q "$STIP/24" && ok "storage: address on tagged bond0.$DV (trunk)" || bad "storage bond0.$DV"

echo "-- frontend data plane"
ping_t "gpu1 -> anycast gateway 10.1.1.1" gpu1 10.1.1.1
ping_t "gpu1 -> gpu8 (same leaf pair)" gpu1 10.1.1.28
ping_t "gpu1 -> ctrl1 (GPU pair -> control pair over VXLAN)" gpu1 10.1.1.11
ping_t "gpu1 -> storage (tagged trunk)" gpu1 $STIP
if [ "$MULTI" = 1 ]; then   # VLAN 300 / VLAN 200 are behind the firewall: tcp only, per the operator's policy
  # tcp probe that works in every image (the bastion has no nc) + one retry: the first packets of a new flow through the PA-VM, and the first
  # contact with an address the leaf has never ARPed, are often lost (same retry as ping_t)
  nz() { local r; for try in 1 2; do r=$(X "$1" "timeout 6 bash -c 'echo > /dev/tcp/$2/$3' 2>/dev/null && echo open || echo blocked" | tail -1); [ "$r" = open ] && break; sleep 2; done; echo "$r"; }
  [ "$(nz gpu1 $FBA 443)" = open ] && ok "gpu1 (VLAN 100) -> storage management VIP $FBA:443 through the firewall" || bad "gpu1 -> storage management 443"
  [ "$(nz gpu1 $FBA 8443)" = blocked ] && ok "gpu1 -> storage management tcp/8443 blocked (VLAN 100 -> 200 is 443 only)" || bad "gpu1 -> storage management 8443 not blocked"
  [ "$(nz bastion $FBA 443)" = open ] && ok "bastion (VLAN 300) -> storage management VIP $FBA:443" || bad "bastion -> storage management 443"
  X bastion "ping -c 2 -W 2 -q $STIP" | grep -q " 0 received" && ok "bastion -> storage ICMP blocked (VLAN 300 -> 100 is tcp 22/80/443/6443 only)" || bad "bastion -> storage ICMP not blocked"
else
  ping_t "storage -> bastion" storage 10.1.1.17
fi
X bastion "ping -c 3 -W 2 -q 8.8.8.8" | grep -qE "[23] received" && ok "bastion -> internet 8.8.8.8 (fabric > border > firewall NAT)" || bad "bastion -> internet"
X pc-1 "ping -c 3 -W 2 -q 10.1.1.23" | grep -qE "[23] received" || sleep 3; X pc-1 "ping -c 3 -W 2 -q 10.1.1.23" | grep -qE "[23] received" && ok "pc-1 -> gpu3 (enterprise > firewall > fabric)" || bad "pc-1 -> gpu3"
[ "$MULTI" = 1 ] && STOOB=$(python3 -c 'import gen; print(gen.oob(gen.HOSTS["ctrl1"]["ip"]))')      # site-a-nx: the storage left the OOB network; test ctrl1's BMC
X pc-2 "ping -c 3 -W 2 -q $STOOB" | grep -qE "[23] received" || sleep 3; X pc-2 "ping -c 3 -W 2 -q $STOOB" | grep -qE "[23] received" && ok "pc-2 -> OOB/BMC $STOOB (enterprise > firewall > oob-sw)" || bad "pc-2 -> OOB $STOOB"

echo "-- backend control plane"
for s in $BE_SPINES; do n=$(OCS $s "show ip bgp summary" | awk '/Established sessions/ {print $NF}'); [ "$n" = 8 ] && ok "$s: 8/8 eBGP sessions" || bad "$s sessions" "${n:-?}/8"; done
for l in $BE_LEAVES; do
  o=$(OCS $l "show ip bgp summary" "show ip route summary" "show bfd session"); n=$(echo "$o" | awk '/Established sessions/ {print $NF}'); e=$(echo "$o" | awk '/routes with +4 +ECMP paths/ {print $NF}'); f=$(echo "$o" | grep -c " Up ")
  [ "$n" = 4 ] && [ "${e:-0}" -ge 7 ] && [ "$f" = 4 ] && ok "$l: 4/4 sessions, $e four-way ECMP routes, 4 BFD up" || bad "$l" "sessions=${n:-?} ecmp4=${e:-0} bfd=$f"
done

echo "-- backend data plane (GPU NIC r = gpu(r-1), rail r = 172.16.r.0/24)"
ping_t "gpu1 rail1 -> rail gateway 172.16.1.1" gpu1 "-I gpu0 172.16.1.1"
ping_t "gpu1 rail1 -> gpu8 rail1 (same rail, one leaf)" gpu1 "-I gpu0 172.16.1.18"
ping_t "gpu2 rail8 -> gpu7 rail8 (same rail, one leaf)" gpu2 "-I gpu7 172.16.8.17"
ping_t "gpu1 rail1 -> gpu8 rail5 (cross-rail: leaf > spine > leaf)" gpu1 "-I 172.16.1.11 172.16.5.18"
ping_t "gpu3 rail7 -> gpu6 rail2 (cross-rail)" gpu3 "-I 172.16.7.13 172.16.2.16"
ping_t "gpu1 rail1 -> gpu8 rail1 jumbo 8972 DF" gpu1 "-I gpu0 -M do -s 8972 172.16.1.18"
if HX gpu1 "command -v traceroute" | grep -q traceroute; then
  sp=$(for p in "gpu1 172.16.1.11 172.16.5.18" "gpu2 172.16.1.12 172.16.6.17" "gpu3 172.16.1.13 172.16.7.16" "gpu4 172.16.1.14 172.16.8.15" "gpu5 172.16.1.15 172.16.2.14" "gpu6 172.16.1.16 172.16.3.13" "gpu7 172.16.1.17 172.16.4.12" "gpu8 172.16.1.18 172.16.5.11"; do set -- $p; HX $1 "traceroute -n -w 1 -q 1 -s $2 $3 2>/dev/null | sed -n 3p" | awk '{print $2}'; done | sed -nE 's/^10\.255\.([1-4])\..*/\1/p' | sort -u | tr '\n' ' ')
  [ "$(echo $sp | wc -w)" -ge 3 ] && ok "cross-rail flows spread over spines: $sp" || bad "ECMP spread" "spines seen: $sp"
else
  printf "  SKIP  ECMP spread per flow (guests ship no traceroute; proven in the light lab, and every leaf shows four-way ECMP above)\n"
fi

echo "== $PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]
