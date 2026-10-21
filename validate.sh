#!/bin/bash
# ai-fabric validation (adapted from <reference-platform>/validate.sh, extended for an AI fabric). Read-only except for short-lived test pods
# in namespace gpu and one test PVC that the run deletes again. PASS / FAIL / SKIP per check, non-zero exit on any FAIL.
#   A inventory          B frontend control plane (Cumulus EVPN-MH / vEX ESI-LAG / Nexus vPC fabric peering)     C frontend data plane (bonds, mesh, jumbo, DNS, NTP)
#   D firewall, north-south, OOB, office-LAN path     E backend control plane (OcNOS eBGP, BFD, ECMP, LLDP cabling, rail VLANs)
#   F backend data plane at the GPU NICs (rail alignment, same-rail, cross-rail, jumbo)
#   G GPU pods over the rails (Multus: 8 rails per pod; same-rail, jumbo 8972 DF, cross-rail both ways, ECMP spread, iperf3 incl. ring)
#   H platform (URLs + TLS, inference path, storage-API PVC through the firewall, Longhorn)
#   I registry + storage services (Harbor behind the Gateway, proxy-cache pull, S3 blobs, Longhorn backup to S3, Longhorn RWX = NFS)
# Usage: ./validate.sh [sections, default ABCDEFGHI]      e.g. ./validate.sh EFG
cd "$(dirname "$0")"; . ./lib.sh
SECTIONS=${1:-ABCDEFGHI}; want() { case "$SECTIONS" in *"$1"*) return 0;; esac; return 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
is_full || { echo "this is the light lab: use ./validate-fabric.sh (validate.sh needs the VM guests and Kubernetes)"; exit 2; }
# The result is saved next to the audits and traces: audits/ai-fabric_validation_<ts>/validate.txt (+ RESULT.txt = the verdict lines).
# One result set per category: a complete run (all sections) replaces the previous one; a partial run is saved as validate-<sections>.txt
# into the newest existing result directory so it never displaces a full result. The script re-runs itself under `tee` for that (a
# process substitution would make every bare `wait` below hang on the tee process).
if [ -z "${VALIDATE_INNER:-}" ]; then TS=$(date -u +%Y%m%d_%H%M%S)
  if [ "$SECTIONS" = ABCDEFGHI ]; then VOUT=audits/ai-fabric_validation_$TS; VFILE=validate.txt
  else VOUT=$(ls -1d audits/ai-fabric_validation_[0-9]* 2>/dev/null | sort | tail -1); VOUT=${VOUT:-audits/ai-fabric_validation_$TS}; VFILE=validate-$SECTIONS.txt; fi
  mkdir -p "$VOUT"; export EVID="$PWD/$VOUT/commands${VFILE#validate}"; : > "$EVID"      # commands.txt: every command behind every check, with device prompt and raw output
  VALIDATE_INNER=1 "$0" "$SECTIONS" 2>&1 | tee "$VOUT/$VFILE"; RC=${PIPESTATUS[0]}
  { echo "ai-fabric validation $TS  sections: $SECTIONS"; grep -E "^== RESULT|^   (known|failed)|^     - " "$VOUT/$VFILE"; } > "$VOUT/RESULT${VFILE#validate}"
  [ "$SECTIONS" = ABCDEFGHI ] && keep_latest ai-fabric_validation "$VOUT"; echo "validation result -> $VOUT/$VFILE   (commands + raw outputs: $VOUT/commands${VFILE#validate})"; exit $RC
fi
echo "== ai-fabric validation $(date -u +%FT%TZ)  sections: $SECTIONS"
HOSTS="$CTRLS storage $GPUS"; declare -A FIP OIP
while read -r n ip; do FIP[$n]=$ip; done < <(python3 -c "import gen; [print(n, h['ip']) for n, h in gen.HOSTS.items()]; print('bastion', gen.BASTION_IP)")   # follows the active profile
NG=$(echo $GPUS | wc -w); NH=$(echo $HOSTS | wc -w); SEQ=$(seq -s ' ' 1 $NG); GL=gpu$NG; GLI=$((10 + NG))     # GPU nodes, guests, 1..NG, last GPU node and its rail index
for h in "${!FIP[@]}"; do OIP[$h]=10.1.2.${FIP[$h]##*.}; done
# site-a-nx (MULTI=1): VLAN 100/200/300 in separate VRFs, inter-VLAN only through the firewall; storage management API on the VLAN 200 VIP; DNS/NTP = dns-b
read -r MULTI FBA DNSN DV FZ <<< "$(python3 -c 'import gen; print(int(gen.MULTI), gen.FB_API, gen.DNS_NTP or gen.BASTION_IP, gen.FE_VLAN, gen.FZ)')"
FBCA=$(python3 -c 'import gen; print(f"FB_CACERT=/shared/{gen.CLUSTER}/cluster-ca.crt" if gen.LAB_CA else "")')   # lab CA: pvc-tool verifies the storage API   # FZ: firewall zone of VRF k8s (data on site-a-nx)
VIP=$(gw_vip); API=10.1.1.20; DNSIP=10.1.1.17; FWOUT=$(fw_out); DOMAIN=lab.ai   # VIP = what the running cluster announces

# ------------------------------------------------------------------------------------------------ A
if want A; then sec "A. Inventory and health"
  n=0; for s in $FE_SPINES $FE_LEAVES $FE_BORDERS oob-sw $BE_SPINES $BE_LEAVES fw; do [ "$(health $s)" = healthy ] && n=$((n + 1)) || bad "$s health" "$(health $s)"; done; NSW=$(echo $FE_SPINES $FE_LEAVES $FE_BORDERS oob-sw $BE_SPINES $BE_LEAVES fw | wc -w); chk "$NSW switch/firewall VMs healthy" $NSW $n
  n=0; for h in $HOSTS; do [ "$(H $h "echo up")" = up ] && n=$((n + 1)) || bad "guest $h reachable over ssh"; done; chk "$NH guests reachable (operator key)" $NH $n
  chk "$NH Kubernetes nodes Ready" $NH "$(K "kubectl get nodes --no-headers | grep -cw Ready")"
  chk "3 control-plane nodes" 3 "$(K "kubectl get nodes --no-headers | grep -c control-plane")"
  # Open WebUI starts without an API key (Secret webui/inference-key is optional), so it is held to the same standard as every other pod
  wx='^$'
  np=$(K "kubectl get pods -A --no-headers | grep -vE 'Running|Completed' | grep -v '^gpu ' | grep -vE '$wx' | wc -l"); chk "no pod outside Running/Completed" 0 "$np"
  o=$(K "kubectl get events -A --field-selector type=Warning --no-headers 2>/dev/null | wc -l"); chk "0 Warning events in the cluster before the tests start (Headlamp overview)" 0 "$o"
  # persistence: what a guest or host reboot would run again must be what this repository holds
  o=$(_run "root@$(hostname):~# CHECK=1 ./node-sync.sh" env CHECK=1 ./node-sync.sh | tail -1 | grep -o "in sync"); chk "persistence: what every guest runs at boot (netsetup, units, networkd drop-in; init node: bootstrap + manifests) = repository" "in sync" "$o"
  o=$(K "kubectl get nodes -l node-role.ai-fabric.lab/control=true --no-headers | grep -vc '^ctrl'"); chk "persistence: control class (announces the Gateway VIP) holds only ctrl nodes" 0 "$o"
  o=$(_run "root@$(hostname):~# CHECK=1 ./cilium-devices.sh" env CHECK=1 ./cilium-devices.sh | tail -1 | grep -o "in sync"); chk "persistence: running Cilium devices = repository (CILIUM_DEVICES)" "in sync" "$o"
  if [ -n "$FBCA" ]; then   # lab CA (site-a-nx): dns-b root -> Platform CA (cert-manager) + Kubernetes CA (kubeadm)
    RS="ai-fabric Lab Root CA"; CAF=/shared/ai-fabric/cluster-ca.crt
    o=$(H ctrl1 "openssl x509 -in $CAF -noout -subject -issuer" | grep -c "$RS"); chk "lab CA: the published cluster-ca.crt is the dns-b lab root (self-signed)" 2 "$o"
    o=$(H ctrl1 "openssl x509 -in /etc/kubernetes/pki/ca.crt -noout -subject -issuer | tr \"\\n\" \" \""); echo "$o" | grep -q "ai-fabric Kubernetes CA.*issuer=.*$RS" \
      && ok "lab CA: kubeadm's CA on ctrl1 is the lab Kubernetes CA, issued by the lab root" || bad "lab CA: kubeadm CA" "$o"
    for cp in ctrl1 ctrl2 ctrl3; do o=$(H $cp "grep -c \"BEGIN CERTIFICATE\" /etc/kubernetes/pki/apiserver.crt"); chk "lab CA: $cp serves the API certificate with its chain (leaf + Kubernetes CA)" 2 "$o"; done
    o=$(H ctrl3 "curl -s --cacert $CAF -m 8 -o /dev/null -w %{http_code} https://api.$DOMAIN:6443/version"); chk "lab CA: https://api.$DOMAIN:6443 verifies against the lab root alone" 200 "$o"
    o=$(H ctrl3 "curl -s --cacert $CAF -m 12 -o /dev/null -w %{http_code} https://demo.platform.$DOMAIN/"); chk "lab CA: the platform wildcard (Gateway) verifies against the lab root" 200 "$o"
    o=$(_run "root@$(hostname):~# CHECK=1 ./ca-certs.sh" env CHECK=1 ./ca-certs.sh); rc=$?
    [ $rc = 0 ] && ok "lab CA: storage API + firewall UI certificates issued, not expiring, storage API serves its lab certificate (ca-certs.sh)" \
      || bad "lab CA: ca-certs.sh CHECK" "$(echo "$o" | grep -E "NOT" | head -2 | paste -sd';')"
    echo "$o" | grep -q "firewall UI: presents the lab certificate" && ok "lab CA: firewall UI presents its lab certificate" \
      || skip "lab CA: firewall UI certificate" "operator step: ssh -t <host> <repo>/fw-ui-cert.sh, then fw-backup.sh"
  fi
  if [ -f /etc/systemd/system/ai-fabric-lab.service ]; then
    o=$(_run "root@$(hostname):~# systemctl is-enabled ai-fabric-lab.service; systemctl is-active ai-fabric-lab.service" sh -c "systemctl is-enabled ai-fabric-lab.service; systemctl is-active ai-fabric-lab.service" | xargs)
    chk "persistence: ai-fabric-lab.service enabled + active (boot.sh after a host boot, clean guest power-off at shutdown)" "enabled active" "$o"
    n=0; for c in $(docker ps -a --format '{{.Names}}' | grep '^ai-fabric-cache-'); do [ "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' $c)" = unless-stopped ] || n=$((n + 1)); done; chk "persistence: registry caches restart with docker" 0 "$n"
  else skip "persistence: boot-time start not installed on this host (host/install.sh)"; fi
fi

# ------------------------------------------------------------------------------------------------ B
if want B && [ "$FE_NOS" = cumulus ]; then sec "B. Frontend control plane (Cumulus: eBGP unnumbered underlay, EVPN-VXLAN, EVPN multihoming)"
  # Everything the frontend asserts scales with the profile, so it is read from the topology rather than written out: a spine peers with
  # every leaf and border, a leaf sees every OTHER leaf as a remote VTEP, and a leaf's Ethernet Segments are the servers on its pair
  # (the bastion counts as one on the control pair). Hard-coded counts here silently became wrong when the office grew to 4 GPU pairs.
  NLB=$(echo $FE_LEAVES $FE_BORDERS | wc -w); NVT=$(( $(echo $FE_LEAVES | wc -w) - 1 ))
  declare -A ES SVI
  while read -r l e s; do ES[$l]=$e; SVI[$l]=$s; done < <(python3 -c '
import gen
for name, sw in gen.FE.items():
    if sw.get("role") != "leaf": continue
    n = len([h for h in gen.HOSTS.values() if h["pair"] == sw["pair"]]) + (gen.BASTION["pair"] == sw["pair"])
    print(name, n, sw["svi"])')
  for s in $FE_SPINES; do
    chk "$s: $NLB/$NLB EVPN sessions Established" $NLB "$(CVX $s "sudo vtysh -c 'show bgp l2vpn evpn summary json'" | grep -c '"state":"Established"')"
    chk "$s: $NLB/$NLB IPv4 underlay sessions Established" $NLB "$(CVX $s "sudo vtysh -c 'show bgp ipv4 unicast summary json'" | grep -c '"state":"Established"')"
    chk "$s: $NLB/$NLB BFD sessions Up on the underlay (3 x 300 ms, as production fall-over bfd)" $NLB "$(CVX $s "sudo ptmctl -b | grep -c ' Up '")"
  done
  n=0; for l in $FE_LEAVES $FE_BORDERS; do [ "$(CVX $l "sudo ptmctl -b | grep -c ' Up '")" = 2 ] && n=$((n + 1)) || bad "$l BFD" "not 2 sessions Up"; done; chk "$NLB leaves/borders: 2/2 BFD sessions Up towards the spines" $NLB $n
  for l in $FE_LEAVES; do
    o=$(CVX $l "sudo vtysh -c 'show bgp l2vpn evpn summary json' | grep -c '\"state\":\"Established\"'; sudo vtysh -c 'show evpn vni' | awk '\$1==10 {print \$2, \$6} \$1==1000 {print \$2}' | tr '\n' ' '; echo; sudo vtysh -c 'show evpn es' | grep -cE '^03:.* [A-Z]*L[A-Z]* +bond'; sudo vtysh -c 'show evpn es' | grep -E '^03:.* [A-Z]*L[A-Z]* +bond' | awk 'NF<4' | wc -l; for b in /proc/net/bonding/bond*; do grep -m1 'MII Status' \$b; done | grep -c up; ip -br addr show vlan10 | grep -c ${SVI[$l]}/24; ip -br addr show vlan10-v0 | grep -c 10.1.1.1/24; ip -br link show vlan10-v0 | awk '{print \$3}'; sudo vtysh -c 'show ip route 10.0.0.17/32' | grep -c 'via swp'; sudo lldpcli show neighbors summary | grep -E 'Interface:|SysName:' | paste - - | grep -E 'Interface: +swp[12],' | awk '{print \$2 \$NF}' | tr -d ',' | sort | tr '\n' ' '; echo; ip -d link show type vxlan | grep -c 'neigh_suppress on\|nolearning'; ip route show vrf k8s | grep -cE '^10\.1\.1\.[0-9]+ '")
    mapfile -t L <<< "$o"
    e=0; [ "${L[0]}" = 2 ] || e=1; [ "${L[1]// /}" = "L2${NVT}L3" ] || e=1
    [ $e = 0 ] && ok "$l: 2/2 EVPN uplinks, VNI 10 (L2, $NVT remote VTEPs) + VNI 1000 (L3)" || bad "$l EVPN" "sessions=${L[0]} vni='${L[1]}' expected='L2 $NVT L3 '"
    [ "${L[2]}" = "${ES[$l]}" ] && [ "${L[3]}" = 0 ] && [ "${L[4]}" = "${ES[$l]}" ] && ok "$l: ${ES[$l]} local Ethernet Segments, each with its partner VTEP, ${ES[$l]} bonds up" || bad "$l EVPN-MH" "localES=${L[2]} withoutPeer=${L[3]} bondsUp=${L[4]} expected=${ES[$l]}"
    [ "${L[5]}" = 1 ] && [ "${L[6]}" = 1 ] && [ "${L[7]}" = "00:0a:00:c1:00:01" ] && ok "$l: SVI ${SVI[$l]} + anycast gateway 10.1.1.1 / 00:0a:00:c1:00:01" || bad "$l gateway" "svi=${L[5]} vrr=${L[6]} mac=${L[7]}"
    [ "${L[8]}" = 2 ] && ok "$l: underlay ECMP over both spines" || bad "$l underlay ECMP" "nexthops=${L[8]}"
    [ "${L[9]}" = "swp1fe-spine1 swp2fe-spine2 " ] && ok "$l: LLDP cabling swp1->fe-spine1, swp2->fe-spine2" || bad "$l LLDP cabling" "${L[9]}"
    ge "$l: EVPN host routes (/32) for remote servers in vrf k8s" 5 "${L[11]}"
  done
  for b in $FE_BORDERS; do o=$(CVX $b "sudo vtysh -c 'show bgp vrf k8s ipv4 unicast summary json'"); echo "$o" | grep -q '"state":"Established"' && ok "$b: eBGP to the firewall Established (vrf k8s)" || bad "$b firewall BGP"
    CVX $b "ip route show vrf k8s" | grep -q "^default" && ok "$b: default route received from the firewall" || bad "$b default route"; done
  CVX fe-gpu-leaf1 "ip route show vrf k8s" | grep -q "^default" && ok "server leaves: type-5 default present in vrf k8s" || bad "type-5 default on server leaves"
  o=$(CVX fe-stor-leaf1 "sudo /sbin/bridge vlan show dev bond1 | grep -w 10"); echo "$o" | grep -q PVID && bad "storage trunk" "VLAN 10 is untagged/PVID on bond1" || ok "fe-stor-leaf1: storage LAG carries VLAN 10 TAGGED only (trunk, no native VLAN)"
fi

if want B && [ "$FE_NOS" = junos ]; then sec "B. Frontend control plane (Juniper vEX: eBGP unnumbered underlay + BFD, EVPN-VXLAN in a MAC-VRF, ESI-LAG, type-5 in vrf k8s)"
  NL=$(echo $FE_LEAVES $FE_BORDERS | wc -w); NSL=$(echo $FE_LEAVES | wc -w)
  for s in $FE_SPINES; do o=$(JNX $s "show bgp summary")
    chk "$s: $NL/$NL EVPN overlay sessions Established (loopback peers)" $NL "$(echo "$o" | grep -cE '^10\.0\.0\.[0-9]+ .* Establ')"
    chk "$s: $NL/$NL unnumbered underlay sessions Established (IPv6 link-local peers, IPv4 over RFC 5549 next hops)" $NL "$(echo "$o" | grep -cE '^fe80:.* Establ')"
    chk "$s: $NL/$NL BFD sessions Up on the underlay (3 x 300 ms)" $NL "$(JNX $s "show bfd session" | grep -cE ' Up +ge-')"
  done
  declare -A AE; for l in $FE_LEAVES; do AE[$l]=$(grep -c "^set interfaces ae[0-9]* esi all-active" configs/$l.set); done
  for l in $FE_LEAVES; do
    o=$(JNX $l "show bgp summary"); b=$(JNX $l "show bfd session" | grep -cE ' Up +ge-')
    [ "$(echo "$o" | grep -cE '^10\.0\.0\.[12] .* Establ')" = 2 ] && [ "$(echo "$o" | grep -cE '^fe80:.* Establ')" = 2 ] && [ "$b" = 2 ] \
      && ok "$l: 2/2 EVPN overlay, 2/2 unnumbered underlay, 2/2 BFD Up" || bad "$l BGP/BFD" "bfd=$b $(echo "$o" | grep -cE 'Establ') sessions Established"
    v=$(JNX $l "show ethernet-switching vxlan-tunnel-end-point remote summary instance FABRIC" | grep -cE '^ *10\.0\.0\.[0-9]+ ')
    chk "$l: VNI 10 in MAC-VRF FABRIC, VXLAN tunnels to the $((NSL - 1)) other server leaves" $((NSL - 1)) "$v"
    up=$(JNX $l "show lacp interfaces" | grep -c "Collecting distributing"); m=$(grep -c "ether-options 802.3ad" configs/$l.set)
    chk "$l: $m LACP member links Collecting/Distributing in ${AE[$l]} ESI-LAGs" $m "$up"
    e=$(JNX $l "show evpn instance FABRIC extensive" | awk '/^ +ESI: / {loc = 0} /Local interface: ae/ {loc = 1} /Number of remote PEs connected: 1$/ && loc {n++} END {print n + 0}')   # LOCAL segments whose only other PE is the partner leaf
    chk "$l: ${AE[$l]} Ethernet Segments all-active, each with its partner leaf" ${AE[$l]} "$e"
    g=$(JNX $l "show interfaces irb.10" | grep -cE "Destination: 10\.1\.1/24|Flags: Up")
    c=$(grep -cE "virtual-gateway-address 10.1.1.1|virtual-gateway-v4-mac 00:0a:00:c1:00:01" configs/$l.set); [ "$g" -ge 2 ] && [ "$c" = 2 ] && ok "$l: irb.10 up with anycast gateway 10.1.1.1 / 00:0a:00:c1:00:01" || bad "$l gateway" "irb=$g cfg=$c"
    n=$(JNX $l "show route 10.0.0.17/32 table inet.0 active-path" | grep -cE "via ge-0/0/[01]\.0"); chk "$l: underlay ECMP to a border loopback over both spines" 2 "$n"
    lp=$(JNX $l "show lldp neighbors" | awk '$1 ~ /^ge-0\/0\/[01]$/ {print $1 ">" $NF}' | sort | tr '\n' ' '); [ "$lp" = "ge-0/0/0>fe-spine1 ge-0/0/1>fe-spine2 " ] && ok "$l: LLDP cabling ge-0/0/0 -> fe-spine1, ge-0/0/1 -> fe-spine2" || bad "$l LLDP cabling" "$lp"
    ge "$l: type-5 host routes (/32) of remote servers in vrf k8s" 5 "$(JNX $l "show route table k8s.inet.0 protocol evpn" | grep -cE '^10\.1\.1\.[0-9]+/32')"
  done
  for b in $FE_BORDERS; do JNX $b "show bgp summary instance k8s" | grep -qE '^10\.1\.254\.[0-9]+ .* Establ' && ok "$b: eBGP to the firewall Established (vrf k8s)" || bad "$b firewall BGP"
    JNX $b "show route table k8s.inet.0 0.0.0.0/0 exact" | grep -q "0.0.0.0/0" && ok "$b: default route received from the firewall" || bad "$b default route"; done
  JNX fe-gpu-leaf1 "show route table k8s.inet.0 0.0.0.0/0 exact" | grep -q "0.0.0.0/0" && ok "server leaves: type-5 default present in vrf k8s" || bad "type-5 default on server leaves"
  o=$(JNX fe-stor-leaf1 "show configuration interfaces ae1 unit 0"); echo "$o" | grep -q "interface-mode trunk" && ! echo "$o" | grep -q native-vlan && ok "fe-stor-leaf1: storage LAG carries VLAN 10 TAGGED only (trunk, no native VLAN)" || bad "storage trunk" "$(echo $o | cut -c1-90)"
fi

if want B && [ "$FE_NOS" = nxos ]; then sec "B. Frontend control plane (Cisco Nexus 9300v: OSPF unnumbered underlay, iBGP EVPN, vPC fabric peering, type-5 in vrf k8s)"
  . ./nx-checks.sh; nx_frontend      # shared with validate-fabric.sh; every expectation derived from gen.py
fi

# ------------------------------------------------------------------------------------------------ C
if want C; then sec "C. Frontend data plane (ESI-LAG bonds, full mesh, jumbo, DNS, NTP)"
  for h in $HOSTS; do a=$(H $h "grep -o \"Aggregator ID: [0-9]*\" /proc/net/bonding/bond0 | sort -u | wc -l"); m=$(H $h "grep -c \"Slave Interface\" /proc/net/bonding/bond0"); exp=2; [ $h = storage ] && exp=8
    [ "$a" = 1 ] && [ "$m" = "$exp" ] && ok "$h: $m bond0 members in ONE LACP aggregator across both leaves" || bad "$h LACP" "members=$m aggregators=$a"; done
  H storage "ip -br addr show bond0.$DV" | grep -q "${FIP[storage]}/24" && ok "storage: address on tagged bond0.$DV" || bad "storage bond0.$DV"
  MESH="$HOSTS"; [ "$MULTI" = 1 ] || MESH="$MESH bastion"      # site-a-nx: the bastion is in VLAN 300, behind the firewall (section D tests it)
  for h in $HOSTS; do { for d in $MESH; do [ $d = $h ] || echo "p '$h -> $d' ${FIP[$d]}"; done; echo "p '$h -> anycast gateway' 10.1.1.1"; } | batch_file > "$T/c.$h" & done; wait
  for h in $HOSTS; do f=$(cat "$T/c.$h"); HS $h "$f" > "$T/cr.$h" & done; wait
  for h in $HOSTS; do tally_quiet "$h: frontend full mesh ($NH peers + gateway)" < "$T/cr.$h"; done
  tally < <({ echo "p 'jumbo 8972 DF gpu1 -> ctrl1 (GPU pair -> control pair over VXLAN)' -M do -s 8972 10.1.1.11"; echo "p 'jumbo 8972 DF gpu1 -> storage (tagged trunk)' -M do -s 8972 ${FIP[storage]}"; echo "p 'jumbo 8972 DF gpu1 -> $GL' -M do -s 8972 ${FIP[$GL]}"; } | HS gpu1 "$(batch_file)")
  for h in ctrl1 gpu4 storage; do o=$(H $h "getent hosts api.$DOMAIN | cut -d\" \" -f1; getent ahostsv4 demo.platform.$DOMAIN | head -1 | cut -d\" \" -f1; timedatectl show -p NTPSynchronized --value")
    [ "$(echo $o)" = "$API $VIP yes" ] && ok "$h: lab DNS on $DNSN (api -> $API, *.platform -> $VIP), NTP synchronised" || bad "$h DNS/NTP" "$(echo $o)"; done
fi

# ------------------------------------------------------------------------------------------------ D
if want D; then sec "D. Firewall: north-south, OOB/BMC network, policy (positive + negative), office-LAN path"
  o=$(H gpu2 "ip route get 8.8.8.8 | head -1; curl -s -m 12 -o /dev/null -w %{http_code} https://www.google.com/"); echo "$o" | grep -q "via 10.1.1.1 dev bond0" && echo "$o" | grep -qE "(200|301|302)$" && ok "gpu2 -> internet via the fabric (anycast gateway -> border -> firewall source NAT)" || bad "node internet egress" "$(echo $o | cut -c1-120)"
  { for h in $HOSTS; do echo "p 'pc-1 -> $h (enterprise -> firewall -> border leaves -> L3 VNI -> node)' ${FIP[$h]}"; done      # EVERY node: one target hid per-flow drops on a vEX border (2026-09-18)
    for h in $HOSTS bastion; do [ "$MULTI" = 1 ] && [ $h = storage ] && continue; echo "p 'pc-1 -> $h OOB/BMC ${OIP[$h]}' ${OIP[$h]}"; done   # site-a-nx: storage left the OOB network
    echo "t 'pc-1 -> https://demo.platform.$DOMAIN (TLS verified with the cluster CA)' curl -sS -f -m 12 -o /dev/null https://demo.platform.$DOMAIN/"; echo "t 'pc-1 -> internet' curl -sS -m 12 -o /dev/null https://www.google.com/"; } | XS pc-1 "$(batch_file)" > "$T/d1"; tally_quiet "pc-1: fabric, all $((NH + 1)) OOB/BMC addresses, demo over TLS, internet" < "$T/d1"
  tally < <({ echo "p 'pc-2 -> ctrl1' 10.1.1.11"; echo "t 'pc-2 -> https://demo.platform.$DOMAIN' curl -sS -f -m 12 -o /dev/null https://demo.platform.$DOMAIN/"; } | XS pc-2 "$(batch_file)")
  o=$(H ctrl3 "ip route get $FBA | head -1"); echo "$o" | grep -q "via 10.1.1.1 dev bond0" && ok "ctrl3: the storage management API $FBA is reached through the fabric + firewall, not through its own BMC NIC" || bad "OOB isolation" "$o"
  RN=$(python3 -c 'import gen; print(gen.fw_rule("fabric-to-stor-mgmt" if gen.MULTI else "fabric-to-storage-api"))')
  o=$(H ctrl3 "curl -sk -m 8 -o /dev/null -w %{http_code} https://$FBA/api/api_version"); chk "policy +: $FZ -> storage API $FBA:443 (rule $RN)" 200 "$o"
  o=$(H ctrl3 "curl -sk -m 6 -o /dev/null https://$FBA:8443/; echo rc=\$?"); chk "policy -: $FZ -> storage management tcp/8443 dropped by the firewall (timeout, not RST)" "rc=28" "$o"
  o=$(H ctrl3 "ping -c 2 -W 2 -q $FBA | grep -o \"[0-9]* received\""); chk "policy -: $FZ -> storage management ICMP dropped" "0 received" "$o"
  if [ "$MULTI" = 1 ]; then   # the operator's inter-VLAN policy (2026-09-23): 100->200 443; 300->100 and 300->200 22/80/443/6443; every VLAN -> internet; rest denied
    tcp() { echo "timeout 6 bash -c \"echo > /dev/tcp/$1/$2\" 2>/dev/null && echo open || echo blocked"; }
    chk "policy +: bastion (VLAN 300) -> API VIP $API:6443 (rule bastion-to-$FZ)" 200 "$(X bastion "curl -sk -m 8 -o /dev/null -w %{http_code} https://$API:6443/version")"
    chk "policy +: bastion -> ctrl1 ssh (rule bastion-to-$FZ)" open "$(X bastion "$(tcp ${FIP[ctrl1]} 22)")"
    chk "policy +: bastion -> https://demo.platform.$DOMAIN via $DNSN + Gateway VIP (rule bastion-to-$FZ)" 200 "$(X bastion "curl -sk -m 12 -o /dev/null -w %{http_code} https://demo.platform.$DOMAIN/")"
    chk "policy -: bastion -> ctrl1 ICMP dropped (only tcp 22/80/443/6443 allowed)" "0 received" "$(X bastion "ping -c 2 -W 2 -q ${FIP[ctrl1]} | grep -o \"[0-9]* received\"")"
    chk "policy +: bastion -> storage management API $FBA:443 (rule bastion-to-stor-mgmt)" 200 "$(X bastion "curl -sk -m 8 -o /dev/null -w %{http_code} https://$FBA/api/api_version")"
    chk "policy +: bastion -> storage management ssh (rule bastion-to-stor-mgmt)" open "$(X bastion "$(tcp $FBA 22)")"
    chk "policy -: ctrl3 (VLAN 100) -> bastion ssh dropped" blocked "$(H ctrl3 "$(tcp ${FIP[bastion]} 22)")"
    chk "policy -: ctrl3 -> storage management ssh dropped (VLAN 100 -> 200 is tcp/443 only)" blocked "$(H ctrl3 "$(tcp $FBA 22)")"
    chk "policy -: storage management (VIP) -> ctrl1 API 6443 dropped (VLAN 200 -> 100 not allowed)" "rc=28" "$(H storage "curl -sk -m 6 --interface $FBA -o /dev/null https://${FIP[ctrl1]}:6443/version; echo rc=\$?")"
    chk "policy +: storage management (VIP) -> internet (rule stor-mgmt-to-internet, source NAT)" 1 "$(H storage "curl -s -m 12 --interface $FBA -o /dev/null -w %{http_code} https://www.google.com/" | grep -cE '^(200|301|302)$')"
    chk "policy +: bastion -> internet (rule bastion-to-internet)" 1 "$(X bastion "curl -s -m 12 -o /dev/null -w %{http_code} https://www.google.com/" | grep -cE '^(200|301|302)$')"
    chk "bastion resolves the lab through $DNSN (api.$DOMAIN -> $API)" "$API" "$(X bastion "getent hosts api.$DOMAIN | cut -d' ' -f1")"
  fi
  o=$(H ctrl3 "timeout 6 bash -c \"echo > /dev/tcp/${OIP[bastion]}/22\" 2>/dev/null && echo open || echo blocked"); chk "policy -: $FZ -> bastion BMC ${OIP[bastion]}:22 blocked" blocked "$o"
  o=$(curl -sS -m 12 --resolve demo.platform.$DOMAIN:443:$FWOUT --cacert shared/ai-fabric/cluster-ca.crt -o /dev/null -w "%{http_code} %{ssl_verify_result}" https://demo.platform.$DOMAIN/ 2>&1 | tail -1)
  chk "office LAN -> firewall outside $FWOUT:443 -> DNAT -> Gateway VIP (rules internet-to-inside-vips + dnat-gateway-vip), TLS verified" "200 0" "$o"
  o=$(timeout 6 bash -c "echo > /dev/tcp/$FWOUT/22" 2>/dev/null && echo open || echo blocked); chk "policy -: office LAN -> firewall outside tcp/22 blocked" blocked "$o"
  UIP=$(python3 -c 'import gen; print(gen.PF["fw_ui"]["port"] if gen.PF["fw_ui"] else "")')
  if [ -n "$UIP" ]; then   # profiles that publish the firewall web UI on the outside address (no tunnel): DNAT :port -> loopback with an HTTPS management profile
    o=$(_run "root@$(hostname):~# curl -sk -m 15 -o /dev/null -w '%{http_code}' https://$FWOUT:$UIP/php/login.php" curl -sk -m 15 -o /dev/null -w '%{http_code}' "https://$FWOUT:$UIP/php/login.php")
    chk "LAN -> firewall web UI https://$FWOUT:$UIP/ (rule internet-to-fw-ui, NAT dnat-fw-ui -> loopback.1:443)" 200 "$o"
  fi
fi

# ------------------------------------------------------------------------------------------------ E
if want E; then sec "E. Backend control plane (OcNOS: eBGP leaf-spine, BFD, 4-way ECMP, LLDP cabling, rail VLAN/SVI, RoCE config)"
  # one SSH session per switch, all 12 in parallel. The CLI is fed on a timer (OcNOS has no exec form), so on a loaded host an answer can be cut
  # short: a collection without its BGP summary, BFD table and route summary is repeated (up to 3 times) before anything is judged.
  ecollect() { local n=$1 i; for i in 1 2 3; do OCS $n "show ip bgp summary" "show bfd session" "show ip route summary" "show lldp neighbors brief" "show interface brief" "show running-config | include qos|data-center|priority-flow|bfd|max-paths" > "$T/e.$n" 2>&1
      grep -q "Established sessions" "$T/e.$n" && grep -q "Single-Hop" "$T/e.$n" && grep -q "Total number of IPv4 routes\|ECMP paths\|Route Source" "$T/e.$n" && return 0; sleep 5; done; }
  for n in $BE_SPINES $BE_LEAVES; do ecollect $n & done; wait
  for s in $BE_SPINES; do f="$T/e.$s"; i=${s#be-spine}
    chk "$s: 8/8 eBGP sessions Established (AS 65200)" 8 "$(awk '/Established sessions/ {print $NF}' $f)"
    chk "$s: 8 BFD sessions Up" 8 "$(grep -cE 'Single-Hop +Up' $f)"
    lp=$(awk '$1 ~ /^eth[0-9]+$/ && $2 ~ /^be-leaf/ {printf "%s>%s ", $1, $2}' $f); exp=$(for l in 1 2 3 4 5 6 7 8; do printf "eth%s>be-leaf%s " $l $l; done); [ "$lp" = "$exp" ] && ok "$s: LLDP cabling eth1..8 -> be-leaf1..8" || bad "$s LLDP cabling" "$lp"
  done
  for l in $BE_LEAVES; do f="$T/e.$l"; i=${l#be-leaf}; v=$((i * 10))
    s=$(awk '/Established sessions/ {print $NF}' $f); b=$(grep -cE 'Single-Hop +Up' $f); e=$(awk '/routes with +4 +ECMP paths/ {print $NF}' $f)
    [ "$s" = 4 ] && [ "$b" = 4 ] && [ "${e:-0}" = 14 ] && ok "$l (AS $((65200 + i))): 4/4 eBGP, 4 BFD Up, 14 four-way ECMP routes (7 rails + 7 loopbacks)" || bad "$l control plane" "bgp=$s bfd=$b ecmp4=${e:-0}"
    lp=$(awk '$1 ~ /^eth[1-4]$/ && $2 ~ /^be-spine/ {printf "%s>%s ", $1, $2}' $f); [ "$lp" = "eth1>be-spine1 eth2>be-spine2 eth3>be-spine3 eth4>be-spine4 " ] && ok "$l: LLDP cabling eth1..4 -> be-spine1..4" || bad "$l LLDP cabling" "$lp"
    a=$(awk -v v=$v '$1 ~ /^eth[0-9]+$/ && substr($1, 4) + 0 > 4 && $3 == v && $4 == "access" && $5 == "up"' $f | wc -l); sv=$(awk -v n="vlan1.$v" '$1 == n {print $2}' $f)
    [ "$a" = "$NG" ] && [ "$sv" = up ] && ok "$l: rail $i = $NG GPU access ports in VLAN $v up, SVI vlan1.$v up" || bad "$l rail VLAN" "accessUp=$a svi=$sv"
    c=$(grep -cE "^qos enable|data-center-bridging enable bridge 1|priority-flow-control enable bridge 1|fall-over bfd|max-paths ebgp 64" $f); ge "$l: RoCE/ECMP config lines present (qos, DCB, PFC, BFD, max-paths ebgp 64)" 5 "$c"
  done
fi

# ------------------------------------------------------------------------------------------------ F
if want F; then sec "F. Backend data plane at the GPU NICs (NIC r = gpu(r-1) = rail r = 172.16.r.(10+node))"
  for n in $SEQ; do nx=$((n % NG + 1)); { for r in 1 2 3 4 5 6 7 8; do d=$((r - 1)); xr=$((r % 8 + 1))
      echo "p 'gpu$n rail$r -> rail gateway 172.16.$r.1 (rail alignment)' -I gpu$d 172.16.$r.1"
      echo "p 'gpu$n rail$r -> gpu$nx rail$r (same rail)' -I gpu$d 172.16.$r.$((10 + nx))"
      echo "p 'gpu$n rail$r -> gpu$nx rail$r jumbo 8972 DF' -I gpu$d -M do -s 8972 172.16.$r.$((10 + nx))"
      echo "p 'gpu$n rail$r -> gpu$nx rail$xr (cross-rail via spine)' -I 172.16.$r.$((10 + n)) 172.16.$xr.$((10 + nx))"; done
      echo "t 'gpu$n: 8 per-rail source-routing rules' sh -c 'test \$(ip rule | grep -c \"lookup 30[0-7]\") = 8'"; } | batch_file > "$T/f.$n"; done
  for n in $SEQ; do f=$(cat "$T/f.$n"); HS gpu$n "$f" > "$T/fr.$n" & done; wait
  for n in $SEQ; do tally_quiet "gpu$n: 8 rails x (gateway, same-rail, jumbo 8972 DF, cross-rail) + source routing" < "$T/fr.$n"; done
  xjumbo() { # node, source rail address, destination: largest routed DF packet across rails
    H $1 "ip route flush cache; ping -c 2 -W 1 -q -I $2 $3 >/dev/null 2>&1; true"; local o; o=$(H $1 "ping -c 4 -W 2 -q -I $2 -M do -s 1472 $3 | grep -o \"[0-9]* received\"")     # first resolve ARP on both rail leaves (1-2 s on the OcNOS VM); ge "$4: 1472-byte DF crosses rails (leaf > spine > leaf)" 3 "${o%% *}"
    o=$(H $1 "ping -c 2 -W 2 -I $2 -M do -s 8972 $3 2>&1"); if echo "$o" | grep -q "2 received"; then ok "$4: jumbo 8972 DF crosses rails"
    elif echo "$o" | grep -qE "mtu ?= ?1500|Frag needed"; then known "$4: jumbo 8972 DF does NOT cross rails on the OcNOS VM (path MTU 1500)" "the destination rail leaf answers ICMP frag-needed mtu 1500: a rail SVI cannot be raised above 1500 on the VM (every 'mtu' > 1500 is refused); hardware uses 'interface vlan1.N / mtu 9216' as AI_FABRIC production. Same-rail (L2) jumbo passes; path-MTU discovery works."
    else bad "$4: jumbo 8972 DF across rails" "$(echo "$o" | tail -1 | cut -c1-90)"; fi; }
  xjumbo gpu1 172.16.1.11 172.16.5.$GLI "gpu1 rail1 -> $GL rail5"; xjumbo $GL 172.16.5.$GLI 172.16.1.11 "$GL rail5 -> gpu1 rail1 (reverse)"
fi

# ------------------------------------------------------------------------------------------------ G
if want G; then OPR=$(python3 -c 'import gen; print(1 if gen.NETOP else 0)')   # 1: the NVIDIA network-operator owns the rails (site-a-nx)
  if [ "$OPR" = 1 ]; then sec "G. GPU pods over the OcNOS rails (NVIDIA network-operator: NicClusterPolicy + MacvlanNetwork net-rail-0..7; one pod per GPU node, all 8 rails)"
    # the operator stack itself: every line of netop.sh's report is a check (the rdma_shared capacity line is informational until rdma-probe.sh settles it)
    while IFS= read -r l; do case "$l" in
        *"advertising rdma/rdma_shared"*) n=${l##*: }; n=${n%%/*}; [ "${n:-0}" -gt 0 ] 2>/dev/null && ok "network-operator: ${l#   }" \
            || known "network-operator: rdma-shared-dev-plugin advertises no rdma/rdma_shared on the GPU nodes" "SoftRoCE devices are not bound to a PCI device, which is how the plugin finds RDMA devices; see the SoftRoCE probe (rdma-probe.sh)" ;;
        *"<-- NOT OK"*) bad "network-operator: ${l%%   <-- NOT OK}" ;;
        "   "*": "*) ok "network-operator: ${l#   }" ;; esac
    done < <(env CHECK=1 ./netop.sh 2>&1)
    # SoftRoCE on the hosts (rdma-prep.sh CHECK: "rdma-prep: <ok>/<all> GPU nodes with ..."); a device whose QP1 is in ERR counts as broken
    NG=$(echo $GPUS | wc -w); chk "SoftRoCE on every GPU node: packages, $(python3 -c 'import gen; print(gen.RAILS)') rxe devices with QP1 healthy, rdma_cm, mlx5_core (rdma-prep.sh CHECK)" \
      "$NG/$NG" "$(env CHECK=1 ./rdma-prep.sh 2>&1 | tail -1 | awk '{print $2}')"
    NADS=$(for r in 0 1 2 3 4 5 6 7; do printf 'default/net-rail-%s,' $r; done | sed 's/,$//'); RRE=' net[1-8] 172\.16\.[1-8]\.(6[4-9]|[7-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-4])$'; RTXT="172.16.R.64-254, the node block .0/26 excluded"
  else sec "G. GPU pods over the OcNOS rails (Multus + whereabouts: one pod per GPU node, all 8 rails attached)"
    chk "8 rail NetworkAttachmentDefinitions in namespace gpu" 8 "$(K "kubectl -n gpu get net-attach-def --no-headers | wc -l")"
    NADS='gpu/rail-1,gpu/rail-2,gpu/rail-3,gpu/rail-4,gpu/rail-5,gpu/rail-6,gpu/rail-7,gpu/rail-8'; RRE=' net[1-8] 172\.16\.[1-8]\.1[0-9][0-9]$'; RTXT="172.16.R.100-199"
  fi
  for n in $SEQ; do cat <<EOF
apiVersion: v1
kind: Pod
metadata: {name: rail-g$n, namespace: gpu, labels: {app: railtest}, annotations: {k8s.v1.cni.cncf.io/networks: '$NADS'}}
spec:
  nodeSelector: {kubernetes.io/hostname: gpu$n}
  tolerations: [{key: nvidia.com/gpu, operator: Exists, effect: NoSchedule}]
  terminationGracePeriodSeconds: 1
  containers: [{name: t, image: ghcr.io/srl-labs/network-multitool, command: [sleep, '3600']}]
---
EOF
  done > "$T/pods.yaml"
  # KT: K stops a command after 180 s by default, which cut this 900 s wait short on a cold image cache (32 first pulls after a wipe, 2026-09-23)
  docker cp "$T/pods.yaml" $LAB-bastion:/tmp/railtest.yaml >/dev/null; KT=960 K "kubectl -n gpu delete pod -l app=railtest --wait=true >/dev/null 2>&1; kubectl apply -f /tmp/railtest.yaml >/dev/null; kubectl -n gpu wait --for=condition=Ready pod -l app=railtest --timeout=900s >/dev/null 2>&1"
  chk "$NG test pods Ready (one per GPU node, 8 rails each = $((NG * 8)) Multus attachments)" $NG "$(K "kubectl -n gpu get pods -l app=railtest --no-headers | grep -c Running")"
  K "for n in $SEQ; do kubectl -n gpu get pod rail-g\$n -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}' | jq -r --arg n \$n '.[] | select(.interface | test(\"^net\")) | \"\(\$n) \(.interface) \(.ips[0])\"'; done" > "$T/podips"
  chk "$((NG * 8)) rail addresses handed out by whereabouts ($RTXT)" $((NG * 8)) "$(grep -cE "$RRE" "$T/podips")"
  pip() { awk -v n=$1 -v i=net$2 '$1 == n && $2 == i {print $3}' "$T/podips"; }
  for n in $SEQ; do nx=$((n % NG + 1)); { for r in 1 2 3 4 5 6 7 8; do xr=$((r % 8 + 1))
      echo "p 'pod gpu$n rail$r -> pod gpu$nx rail$r (same rail)' -I net$r $(pip $nx $r)"
      echo "p 'pod gpu$n rail$r -> pod gpu$nx rail$r jumbo 8972 DF' -I net$r -M do -s 8972 $(pip $nx $r)"
      [ "$OPR" = 1 ] || echo "p 'pod gpu$n rail$r -> pod gpu$nx rail$xr (cross-rail: rail leaf > spine > rail leaf)' -I net$r $(pip $nx $xr)"; done; } | batch_file > "$T/g.$n"; done
  for n in $SEQ; do f=$(cat "$T/g.$n"); PS rail-g$n "$f" > "$T/gr.$n" & done; wait
  for n in $SEQ; do tally_quiet "pod on gpu$n: 8 rails x (same-rail, jumbo 8972 DF$([ "$OPR" = 1 ] || echo ', cross-rail'))" < "$T/gr.$n"; done
  if [ "$OPR" = 1 ]; then   # production shape: the MacvlanNetworks carry no routes -- a rail interface reaches its own rail only
    chk "production shape: no 172.16.0.0/16 route in the test pods (rails stay separate)" 0 "$(K "for n in 1 $NG; do kubectl -n gpu exec rail-g\$n -- ip route show 172.16.0.0/16 root 172.16.0.0/16; done" | grep -c '^172\.16\.0\.0/16')"
  else
  pxj() { local o; K "kubectl -n gpu exec rail-g$1 -- ping -c 2 -W 1 -q -I net$2 $3" >/dev/null 2>&1      # resolve ARP on both rail leaves first: the OcNOS VM takes 1-2 s, which is not what this check measures
    o=$(K "kubectl -n gpu exec rail-g$1 -- ping -c 4 -W 2 -q -I net$2 -M do -s 1472 $3 | grep -o '[0-9]* received'"); ge "$4: 1472-byte DF crosses rails" 3 "${o%% *}"
    o=$(K "kubectl -n gpu exec rail-g$1 -- ping -c 2 -W 2 -I net$2 -M do -s 8972 $3 2>&1"); if echo "$o" | grep -q "2 received"; then ok "$4: jumbo 8972 DF crosses rails"
    elif echo "$o" | grep -qE "mtu ?= ?1500|Frag needed|too long"; then known "$4: jumbo 8972 DF does NOT cross rails on the OcNOS VM (path MTU 1500)" "same cause as in section F (rail SVI capped at 1500 on the VM); same-rail jumbo between pods passes."
    else bad "$4: jumbo 8972 DF across rails" "$(echo "$o" | tail -1 | cut -c1-90)"; fi; }
  pxj 1 1 "$(pip $NG 5)" "pod gpu1 rail1 -> pod $GL rail5"; pxj $NG 5 "$(pip 1 1)" "pod $GL rail5 -> pod gpu1 rail1 (reverse)"
  fi
  # path shape + ECMP spread: hop1 = rail gateway, hop2 = a spine link 10.255.<spine>.x, hop3 = destination rail leaf, hop4 = pod
  if [ "$OPR" = 0 ]; then for n in $SEQ; do nx=$((n % NG + 1)); for r in 1 3 6; do xr=$((r % 8 + 1)); echo "traceroute -n -w 1 -q 1 -i net$r $(pip $nx $xr) 2>/dev/null | awk 'NR>1 {printf \"%s \", \$2} END {print \"\"}'"; done > "$T/tr.$n"; done
  for n in $SEQ; do PS rail-g$n "$T/tr.$n" > "$T/trr.$n" & done; wait
  cat "$T"/trr.* | grep -E "^172\.16\." > "$T/paths"; tot=$(wc -l < "$T/paths"); good=$(grep -cE "^172\.16\.[1-8]\.1 10\.255\.[1-4]\.[0-9]+ 10\.255\.[1-4]\.[0-9]+ 172\.16\.[1-8]\.1[0-9][0-9] $" "$T/paths")
  chk "cross-rail path shape: rail gateway > spine > destination rail leaf > pod ($tot traceroutes)" "$tot" "$good"
  sp=$(awk '{split($2, a, "."); print a[3]}' "$T/paths" | sort | uniq -c | awk '{printf "spine%s:%s ", $2, $1}'); ns=$(awk '{split($2, a, "."); print a[3]}' "$T/paths" | sort -u | wc -l)
  [ "$ns" = 4 ] && ok "ECMP: cross-rail flows use all 4 spines ($sp)" || bad "ECMP spread" "$sp"; fi
  # iperf3 (VM switches: numbers show the fabric carries load without loss, not line rate)
  K "for n in $SEQ; do kubectl -n gpu exec rail-g\$n -- sh -c 'pkill iperf3; iperf3 -s -D >/dev/null 2>&1'; done" >/dev/null 2>&1; sleep 2
  # a multi-homed iperf3 UDP server answers from the address its route back selects (rail 1 is directly attached), not from the rail-5
  # address the client sent to, and the client drops that reply. Bind a second server to the rail-5 address for the cross-rail UDP test.
  K "kubectl -n gpu exec rail-g$NG -- sh -c 'iperf3 -s -B $(pip $NG 5) -p 5205 -D >/dev/null 2>&1'" >/dev/null 2>&1; sleep 1
  ipf() { K "kubectl -n gpu exec rail-g$1 -- iperf3 -J -t 5 $2" | python3 -c '
import json, sys
try: e = json.load(sys.stdin)["end"]
except Exception: print(""); sys.exit()
if sys.argv[1] == "udp": print(round(e["sum"]["lost_percent"], 3), e["sum"]["packets"])
else: print(round(e["sum_received"]["bits_per_second"] / 1e9, 2), e["sum_sent"].get("retransmits", "?"))' "${3:-tcp}"; }
  pos() { awk -v g="${1:-0}" 'BEGIN {exit !(g + 0 > 0)}'; }
  read -r g rt <<< "$(ipf 1 "-B $(pip 1 1) -c $(pip $NG 1) -M 8948")"; pos "$g" && ok "iperf3 TCP same rail (pod gpu1 rail1 -> pod $GL rail1, MSS 8948): ${g} Gbit/s, $rt retransmits" || bad "iperf3 same rail" "no result"
  [ "$OPR" = 0 ] && read -r g rt <<< "$(ipf 1 "-B $(pip 1 1) -c $(pip $NG 5) -M 8948")" && { pos "$g" && ok "iperf3 TCP cross-rail (pod gpu1 rail1 -> pod $GL rail5 via the spines): ${g} Gbit/s, $rt retransmits" || bad "iperf3 cross-rail" "no result"; }
  read -r lp pk <<< "$(ipf 1 "-u -b 200M -l 8000 -B $(pip 1 1) -c $(pip $NG 1)" udp)"; [ -n "$lp" ] && awk -v l="$lp" 'BEGIN {exit !(l + 0 < 1)}' && ok "iperf3 UDP same rail 200 Mbit/s, JUMBO 8000-byte datagrams: ${lp}% loss of $pk packets" || bad "iperf3 UDP same-rail jumbo loss" "${lp:-no result}% of ${pk:-?}"
  [ "$OPR" = 0 ] && { read -r lp pk <<< "$(ipf 1 "-u -b 200M -l 1400 -p 5205 -B $(pip 1 1) -c $(pip $NG 5)" udp)"; [ -n "$lp" ] && awk -v l="$lp" 'BEGIN {exit !(l + 0 < 1)}' && ok "iperf3 UDP cross-rail 200 Mbit/s, 1400-byte datagrams (routed path MTU on the VM is 1500): ${lp}% loss of $pk packets" || bad "iperf3 UDP cross-rail loss" "${lp:-no result}% of ${pk:-?}"; }
  # ring (all-reduce style): every GPU node sends to its ring neighbour at the same time, node n on rail ((n-1) mod 8)+1
  for n in $SEQ; do nx=$((n % NG + 1)); r=$(( (n - 1) % 8 + 1 )); ( ipf $n "-t 8 -B $(pip $n $r) -c $(pip $nx $r) -M 8948" > "$T/ring.$n" ) & done; wait
  okr=0; tot=0; line=""; for n in $SEQ; do read -r gb rt < "$T/ring.$n"; pos "$gb" && okr=$((okr + 1)); line="$line g$n:${gb:-0}G/${rt:-?}rtx"; done
  chk "ring traffic: $NG simultaneous flows gpu(n) -> gpu(n+1), node n on rail ((n-1) mod 8)+1 ($line )" $NG "$okr"
  o=$(K "kubectl -n gpu exec rail-g3 -- sh -c 'nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1 && echo dns-ok; curl -s -I -m 15 -o /dev/null -w %{http_code} https://openrouter.ai/api/v1/models; true' 2>/dev/null"); chk "pod on gpu3: cluster DNS + internet egress through the firewall" "dns-ok 200" "$(echo $o)"
  K "kubectl -n gpu delete pod -l app=railtest --wait=false >/dev/null 2>&1"
fi

# ------------------------------------------------------------------------------------------------ H
if want H; then sec "H. Platform (published URLs, inference path, storage-API PVC through the firewall, Longhorn)"
  WSEC=$(K "kubectl -n webui get deploy open-webui -o jsonpath='{.status.availableReplicas}' 2>/dev/null" | grep -c '^[1-9]')     # Open WebUI serves with or without a model behind it
  for u in $(K "kubectl get httproute -A -o jsonpath='{range .items[*]}{.spec.hostnames[0]} {end}'"); do
    case "$u" in webui*) [ "$WSEC" = 1 ] || { skip "pc-1 -> https://$u/" "Open WebUI is not available yet (its model is an OPERATOR step: <host>:<repo>/post-deploy.sh)"; continue; };; esac
    c=$(X pc-1 "curl -sS -m 15 -o /dev/null -w '%{http_code} %{ssl_verify_result}' https://$u/" | tail -1); case "$u" in inference*) exp="404 0";; s3.*) exp="403 0";; *) exp="200 0";; esac      # the S3 API answers an anonymous GET / with 403 AccessDenied
    chk "pc-1 -> https://$u/ through the firewall (TLS verified against the cluster CA)" "$exp" "$c"; done
  if K "kubectl get ns inference >/dev/null 2>&1 && echo yes" | grep -q yes; then
    c=$(X pc-1 "curl -sS -m 20 -o /dev/null -w %{http_code} https://inference.platform.$DOMAIN/models/565df347-26cb-598a-b838-b7e9531f00fa/proxy/v1/models")
    case "$c" in 401|403) ok "inference path without a key: HTTP $c from LiteLLM (Gateway -> HTTPRoute -> APISIX -> LiteLLM reachable; no credential used)";; *) bad "inference path" "HTTP $c";; esac
  else skip "inference path" "the inference gateway is an OPERATOR step (post-deploy.sh asks for the OpenRouter key); not deployed on this lab yet"; fi
  chk "Gateway programmed on $VIP" "$VIP True" "$(K "kubectl -n gateway get gateway --no-headers | awk '{print \$3, \$4}'")"
  chk "Longhorn: $NH nodes ready + schedulable" $NH "$(K "kubectl -n longhorn-system get nodes.longhorn.io --no-headers | grep -c 'True.*true.*True'")"
  o=$(H ctrl2 "$FBCA FB_MGMT=$FBA KUBECONFIG=/shared/ai-fabric/kubeconfig pvc-tool.sh test validate-fs 1Gi default 2>&1 | grep -E \"route:|http=|pod phase|written-by|Bound|deleted\""); echo "$o" | sed 's/^/        /' | cut -c1-150
  echo "$o" | grep -q "via 10.1.1.1 dev bond0" && echo "$o" | grep -q "http=201" && echo "$o" | grep -q "pod phase: Succeeded" && echo "$o" | grep -q "written-by-ctrl2" && echo "$o" | grep -q deleted \
    && ok "PVC from ctrl2 through the storage management API on the OOB address (fabric -> firewall -> oob-sw): 201, Bound, pod wrote to it, deleted" || bad "storage-API PVC"
  c=$(H storage "journalctl -u flashblade-api --no-pager --since -3min | grep -c \"client=${FIP[ctrl2]} \""); ge "storage API logged the client as ctrl2's FABRIC address ${FIP[ctrl2]} (not its BMC address)" 2 "$c"
fi
# ------------------------------------------------------------------------------------------------ I
if want I; then sec "I. Registry and storage services (Harbor, S3 stand-in for the FlashBlade, Longhorn backup target, Longhorn RWX)"
  if ! K "kubectl get ns harbor >/dev/null 2>&1 && echo yes" | grep -q yes; then skip "Harbor / S3 / backup checks" "not deployed on this lab: ./harbor-deploy.sh"
  else GLN=$(echo $GPUS | awk '{print $NF}')
    chk "S3 stand-in (MinIO) runs ON the storage node, on that node's own disk" storage "$(K "kubectl -n s3 get pod -l app=minio -o jsonpath='{.items[0].spec.nodeName}'")"
    chk "S3 buckets for the registry blobs and the Longhorn backups exist" "harbor longhorn-backups" "$(K "kubectl -n s3 exec deploy/minio -- ls /data" | grep -E '^(harbor|longhorn-backups)$' | sort | tr '\n' ' ' | sed 's/ $//')"
    c=$(X pc-1 "curl -sS -m 15 -o /dev/null -w '%{http_code} %{ssl_verify_result} ' https://s3-console.platform.lab.ai/; curl -sS -m 15 -o /dev/null -w '%{http_code} %{ssl_verify_result} ' https://s3.platform.lab.ai/minio/health/live; curl -sS -m 15 -o /dev/null -w '%{http_code}' https://s3.platform.lab.ai/")
    chk "pc-1 -> S3 console and S3 API through the Gateway (TLS verified; an anonymous bucket listing is refused with 403)" "200 0 200 0 403" "$c"
    chk "Longhorn backup target = the S3 bucket, and Longhorn can reach it" "s3://longhorn-backups@us-east-1/ true" "$(K "kubectl -n longhorn-system get backuptargets.longhorn.io default -o jsonpath='{.spec.backupTargetURL} {.status.available}'")"
    n=$(K "kubectl -n harbor get deploy,sts --no-headers" | awk '{split($2, a, "/"); if (a[1] == a[2] && a[1] > 0) n++} END {print n + 0}'); chk "Harbor: core, jobservice, portal, registry, database, redis and trivy all available" 7 "$n"
    chk "Harbor route on the lab Gateway" "harbor.platform.lab.ai" "$(K "kubectl -n harbor get httproute -o jsonpath='{.items[0].spec.hostnames[0]}'")"
    c=$(X pc-1 "curl -sS -m 15 -w ' %{http_code} %{ssl_verify_result}' https://harbor.platform.lab.ai/api/v2.0/ping" | tail -1); chk "pc-1 -> Harbor API through the firewall (TLS verified against the cluster CA)" "Pong 200 0" "$c"
    c=$(X pc-1 "curl -sS -m 15 -o /dev/null -D - https://harbor.platform.lab.ai/v2/" | tr -d '\r' | grep -i -c 'realm="https://harbor.platform.lab.ai/service/token"'); chk "registry API answers 401 with the token realm on the PUBLIC name (externalURL is right)" 1 "$c"
    chk "five public proxy-cache projects (nvcr.io since the network-operator phase)" "proxy-dockerhub proxy-ghcr proxy-k8s proxy-nvcr proxy-quay" "$(X pc-1 "curl -sS -m 15 'https://harbor.platform.lab.ai/api/v2.0/projects?public=true&page_size=50'" | tr ',' '\n' | grep -o '"name":"proxy-[a-z0-9]*"' | cut -d'"' -f4 | sort | tr '\n' ' ' | sed 's/ $//')"
    h=0; for n in $CTRLS storage $GPUS; do ( H $n "grep -c harbor.platform.lab.ai/v2/proxy- /etc/containerd/certs.d/docker.io/hosts.toml /etc/containerd/certs.d/quay.io/hosts.toml /etc/containerd/certs.d/ghcr.io/hosts.toml /etc/containerd/certs.d/registry.k8s.io/hosts.toml /etc/containerd/certs.d/nvcr.io/hosts.toml | grep -c \":1\"; test -s /etc/containerd/certs.d/harbor.platform.lab.ai/ca.crt && echo ca" | tr '\n' ' ' > "$T/i.$n" ) & done; wait
    for n in $CTRLS storage $GPUS; do [ "$(cat "$T/i.$n")" = "5 ca " ] && h=$((h + 1)); done; chk "containerd on all $NH nodes: Harbor proxy caches first for the 5 upstream registries + cluster CA trusted" $NH $h
    # a real pull through the proxy cache, by the kubelet (CRI), on the LAST GPU node (second GPU leaf pair on site-b)
    cat > "$T/hp.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata: {name: harbor-pull, namespace: gpu}
spec:
  nodeSelector: {kubernetes.io/hostname: $GLN}
  tolerations: [{key: nvidia.com/gpu, operator: Exists, effect: NoSchedule}]
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  containers: [{name: t, image: "docker.io/library/busybox:1.36.1", imagePullPolicy: Always, command: [sleep, "120"]}]
EOF
    # The node must not already hold the image, or containerd answers the manifest resolve from its own content store, never contacts
    # Harbor, and this check silently measures the cache instead of the proxy path (site-a 2026-09-20). `ctr images rm` alone is not
    # enough: it drops the tag but leaves the manifest blob, which is what the resolve is served from -- the content has to go too.
    H "$GLN" "D=\$(ctr -n k8s.io images ls 2>/dev/null | awk '/busybox/ {print \$3}' | sort -u); \
              ctr -n k8s.io images ls -q 2>/dev/null | grep busybox | xargs -r ctr -n k8s.io images rm >/dev/null 2>&1; \
              for d in \$D; do ctr -n k8s.io content rm \$d >/dev/null 2>&1; done; true" >/dev/null 2>&1
    docker cp "$T/hp.yaml" $LAB-bastion:/tmp/hp.yaml >/dev/null; K "kubectl -n gpu delete pod harbor-pull --ignore-not-found >/dev/null 2>&1; kubectl apply -f /tmp/hp.yaml >/dev/null; kubectl -n gpu wait --for=condition=Ready pod/harbor-pull --timeout=300s >/dev/null 2>&1"
    chk "kubelet on $GLN pulled docker.io/library/busybox:1.36.1 (imagePullPolicy Always)" Running "$(K "kubectl -n gpu get pod harbor-pull --no-headers" | awk '{print $3}')"
    for i in 1 2 3 4 5 6 7 8; do r=$(X pc-1 "curl -sS -m 15 'https://harbor.platform.lab.ai/api/v2.0/projects/proxy-dockerhub/repositories?page_size=100'" | grep -o '"name":"proxy-dockerhub/library/busybox"' | wc -l); [ "$r" -ge 1 ] && break; sleep 10; done   # Harbor records the cached artifact a few seconds AFTER it served the pull
    ge "Harbor's proxy-dockerhub project now holds library/busybox (the pull went THROUGH Harbor)" 1 "$r"
    ge "its blobs are in the S3 bucket on the storage node" 1 "$(K "kubectl -n s3 exec deploy/minio -- ls /data/harbor/docker/registry/v2/repositories/proxy-dockerhub/library" | grep -c '^busybox$')"
    K "kubectl -n gpu delete pod harbor-pull --wait=false >/dev/null 2>&1" >/dev/null
    # Longhorn RWX (NFS export by a share-manager) shared by two nodes, then a backup of that volume to S3
    cat > "$T/rwx.yaml" <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: val-rwx, namespace: default}
spec: {accessModes: [ReadWriteMany], storageClassName: longhorn, resources: {requests: {storage: 1Gi}}}
---
apiVersion: v1
kind: Pod
metadata: {name: val-rwx-a, namespace: default, labels: {app: valrwx}}
spec:
  nodeSelector: {kubernetes.io/hostname: ctrl4}
  terminationGracePeriodSeconds: 1
  containers: [{name: t, image: ghcr.io/srl-labs/network-multitool, command: [sh, -c, "echo written-on-ctrl4 > /data/a.txt; sleep 3600"], volumeMounts: [{name: d, mountPath: /data}]}]
  volumes: [{name: d, persistentVolumeClaim: {claimName: val-rwx}}]
---
apiVersion: v1
kind: Pod
metadata: {name: val-rwx-b, namespace: default, labels: {app: valrwx}}
spec:
  nodeSelector: {kubernetes.io/hostname: $GLN}
  tolerations: [{key: nvidia.com/gpu, operator: Exists, effect: NoSchedule}]
  terminationGracePeriodSeconds: 1
  containers: [{name: t, image: ghcr.io/srl-labs/network-multitool, command: [sleep, "3600"], volumeMounts: [{name: d, mountPath: /data}]}]
  volumes: [{name: d, persistentVolumeClaim: {claimName: val-rwx}}]
EOF
    docker cp "$T/rwx.yaml" $LAB-bastion:/tmp/val-rwx.yaml >/dev/null
    if K "kubectl get nodes ctrl4 >/dev/null 2>&1 && echo yes" | grep -q yes; then :; else sed -i "s/hostname: ctrl4/hostname: ctrl3/; s/written-on-ctrl4/written-on-ctrl3/" "$T/rwx.yaml"; docker cp "$T/rwx.yaml" $LAB-bastion:/tmp/val-rwx.yaml >/dev/null; fi
    K "kubectl -n default delete pod -l app=valrwx --wait=true >/dev/null 2>&1; kubectl -n default delete pvc val-rwx >/dev/null 2>&1
       awk '/^---/ {exit} {print}' /tmp/val-rwx.yaml | kubectl apply -f - >/dev/null      # the claim first, bound before its pods exist: no FailedScheduling warning
       kubectl -n default wait --for=jsonpath='{.status.phase}'=Bound pvc/val-rwx --timeout=240s >/dev/null 2>&1
       kubectl apply -f /tmp/val-rwx.yaml >/dev/null; kubectl -n default wait --for=condition=Ready pod -l app=valrwx --timeout=480s >/dev/null 2>&1"
    o=$(K "kubectl -n default exec val-rwx-b -- cat /data/a.txt"); case "$o" in written-on-ctrl*) ok "Longhorn RWX volume: a pod on $GLN reads what a pod on a control-leaf node wrote (NFS share-manager)";; *) bad "Longhorn RWX volume" "$o";; esac
    V=$(K "kubectl -n default get pvc val-rwx -o jsonpath={.spec.volumeName}"); BK=val-backup-$(date +%H%M%S)
    printf 'apiVersion: longhorn.io/v1beta2\nkind: Snapshot\nmetadata: {name: %s, namespace: longhorn-system}\nspec: {volume: %s, createSnapshot: true}\n---\napiVersion: longhorn.io/v1beta2\nkind: Backup\nmetadata: {name: %s, namespace: longhorn-system, labels: {backup-volume: %s}}\nspec: {snapshotName: %s}\n' "$BK" "$V" "$BK" "$V" "$BK" > "$T/bk.yaml"
    docker cp "$T/bk.yaml" $LAB-bastion:/tmp/val-bk.yaml >/dev/null; K "kubectl apply -f /tmp/val-bk.yaml >/dev/null 2>&1; for i in \$(seq 1 36); do [ \"\$(kubectl -n longhorn-system get backups.longhorn.io $BK -o jsonpath={.status.state})\" = Completed ] && break; sleep 5; done" >/dev/null
    chk "Longhorn backup of that volume to S3" Completed "$(K "kubectl -n longhorn-system get backups.longhorn.io $BK -o jsonpath={.status.state}")"
    ge "the backup is in the longhorn-backups bucket" 1 "$(K "kubectl -n s3 exec deploy/minio -- ls /data/longhorn-backups/backupstore/volumes" | wc -l)"
    K "kubectl -n longhorn-system delete backups.longhorn.io $BK --wait=false >/dev/null 2>&1; kubectl -n default delete pod -l app=valrwx --wait=true >/dev/null 2>&1
       for i in \$(seq 1 30); do [ \"\$(kubectl -n longhorn-system get volumes.longhorn.io $V -o jsonpath={.status.state} 2>/dev/null)\" = attached ] || break; sleep 5; done      # detach first: no VolumeFailedDelete warning
       kubectl -n default delete pvc val-rwx >/dev/null 2>&1" >/dev/null
  fi
fi
# Leave the cluster with 0 Warning events: the test pods of this run (rail pods, RWX share-manager start, PVC teardown) raise a few by design.
# clear-warnings.sh refuses when the cluster is not healthy and reports warnings that come back while it watches.
if is_full; then o=$(./clear-warnings.sh ${VALIDATE_ALL:+0} 2>&1 | tail -1)
  case "$o" in *"0 Warning events after"*|*"and deleted"|*"no Warning events") ok "Warning events (Headlamp) back to 0 after the run: ${o#clear-warnings: }";; *) bad "Warning events not at 0 after the run" "$o";; esac; fi
summary
