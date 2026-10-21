#!/bin/bash
# drills.sh [drills, default 1234]: failure drills with continuous traffic (after /root/ai-fabric/scripts/drills.sh, extended for the AI backend).
# DISRUPTIVE for ~30-45 s per drill, self-restoring; every drill ends by checking the fabric is back to its full state.
#   1 frontend  one ESI-LAG leg of the node announcing the Gateway VIP goes down      (probe: pc-1 -> https://demo through the firewall)
#   2 frontend  the spine CARRYING a live jumbo flow loses all fabric ports (silent: BFD detects; Nexus: the 3 s OSPF dead timer)  (probe: same + jumbo 8972 DF gpu1 -> ctrl1)
#   3 backend   SILENT failure of the be-leaf1 uplink that carries a live cross-rail flow: the port is shut on the SPINE side, the leaf keeps
#               carrier (virtual wire), so only BFD / BGP fall-over can detect it            (probe: gpu1 rail1 -> gpu8 rail5, 5 pkt/s)
#   4 backend   a whole spine loses all 8 ports; the spine carrying the most of the 4 live flows is chosen   (probe: 4 cross-rail flows)
# Backend changes are made over SSH in privileged exec (OCE) and are reverted by an EXIT trap if the script is interrupted.
cd "$(dirname "$0")"; . ./lib.sh
DR=${1:-1234}; want() { case "$DR" in *"$1"*) return 0;; esac; return 1; }
is_full || { echo "drills need the full lab"; exit 2; }
if [ -z "${DRILLS_INNER:-}" ]; then TS=$(date -u +%Y%m%d_%H%M%S); DOUT=audits/ai-fabric_drills_$TS; mkdir -p "$DOUT"   # result saved next to the audits
  export EVID="$PWD/$DOUT/commands.txt"; : > "$EVID"; DRILLS_INNER=1 "$0" "$DR" 2>&1 | tee "$DOUT/drills.txt"; RC=${PIPESTATUS[0]}; [ "$DR" = 1234 ] && keep_latest ai-fabric_drills "$DOUT"; echo "drills result -> $DOUT/drills.txt"; exit $RC; fi
T=$(mktemp -d)
echo "== ai-fabric failure drills $(date -u +%FT%TZ)  drills: $DR"
demo() { X pc-1 "curl -sk --max-time 3 -o /dev/null -w %{http_code} https://demo.platform.lab.ai/" 2>/dev/null; }
probe_demo() { local n=$1 i okc=0; for i in $(seq 1 "$n"); do c=$(demo); [ "$c" = 200 ] && okc=$((okc + 1)); printf "%s " "${c:-000}"; sleep 3; done; echo; echo "$okc" > "$T/demo.ok"; }
flood() { H $1 "ping -i 0.2 -c $4 -W 1 -q -I $2 $3 | tail -2 | head -1" > "$T/flood.$1" 2>&1; }   # node, source, destination, count
lost() { awk '{split($0, a, ","); gsub(/[^0-9]/, "", a[1]); gsub(/[^0-9]/, "", a[2]); print a[1] - a[2]}' "$1"; }
ecmp() { OCS $1 "show ip route $2" | grep -cE "^ +\* +10\.255\."; }
be_shut() { local n=$1 act=$2; shift 2; local args=("configure terminal"); for p in "$@"; do args+=("interface $p" "$act" "exit"); done; OCE $n "${args[@]}" "commit" "end" | grep -E "^%" | grep -v -E "No Valid|higher config" | head -2; }
# which be-leaf uplink / which spine carries a running ICMP flow: count its frames for 2 s on every candidate (container ethN = switch port ethN)
seen() { local pid; pid=$(docker inspect -f '{{.State.Pid}}' "$LAB-$1"); timeout 2 nsenter -t "$pid" -n tcpdump -i "$2" -nn -q "$3" 2>/dev/null | wc -l; }
seent() { local pid; pid=$(docker inspect -f '{{.State.Pid}}' "$LAB-$1"); timeout 2 nsenter -t "$pid" -n tcpdump -i any -nn "$2" 2>/dev/null | grep -cE "$3"; }   # same, matching the decoded text (inner header of VXLAN frames)
RESTORE=""; trap 'rm -rf "$T"; [ -z "$RESTORE" ] || { echo "restoring after an aborted drill"; eval "$RESTORE"; }' EXIT

if want 1; then sec "Drill 1 (frontend): one ESI-LAG leg of the Gateway-VIP node goes down for ~30 s"
  V=$(K "kubectl -n kube-system get lease -o jsonpath='{range .items[*]}{.metadata.name} {.spec.holderIdentity}{\"\\n\"}{end}' | awk '/l2announce.*gateway/ {print \$2; exit}'"); echo "  VIP $(gw_vip) is announced by $V; taking its eth1 (leg to leaf 1 of the pair) down"
  RESTORE="H $V \"ip link set eth1 up\""; H $V "ip link set eth1 down"; printf "  pc-1 -> demo during the failure: "; probe_demo 9; H $V "ip link set eth1 up"; RESTORE=""; sleep 12
  ge "drill 1: service stayed reachable on the surviving leg (>= 8 of 9 probes HTTP 200)" 8 "$(cat $T/demo.ok)"
  chk "drill 1: after recovery both legs are back in ONE aggregator" "2 1" "$(H $V "grep -c \"Slave Interface\" /proc/net/bonding/bond0; grep -o \"Aggregator ID: [0-9]*\" /proc/net/bonding/bond0 | sort -u | wc -l" | tr '\n' ' ' | sed 's/ $//')"
fi
if want 2; then sec "Drill 2 (frontend): the spine carrying a live east-west jumbo flow loses all its fabric ports for ~35 s (silent: leaves keep carrier, BFD must detect it)"
  ( H gpu1 "ping -i 0.2 -c 200 -W 1 -q -M do -s 8972 10.1.1.11 | tail -2 | head -1" > "$T/flood.fe" ) & sleep 3
  FSP=fe-spine1; for x in fe-spine1 fe-spine2; do c=$(seent $x "udp port 4789" "10\.1\.1\.21 > 10\.1\.1\.11: ICMP echo request"); echo "  $x: $c VXLAN frames of the flow gpu1 -> ctrl1 in 2 s"; [ "$c" -gt 0 ] && FSP=$x; done; echo "  failing all fabric ports of $FSP"
  NLP=$(echo $FE_LEAVES $FE_BORDERS | wc -w); FP=$(seq -s ' ' 1 $NLP)
  RESTORE="fe_ports $FSP up $FP"; fe_ports $FSP down $FP
  printf "  pc-1 -> demo during the failure: "; probe_demo 10; wait; fe_ports $FSP up $FP; RESTORE=""
  l=$(lost "$T/flood.fe"); echo "  jumbo 8972 DF gpu1 -> ctrl1 over VXLAN: $(cat $T/flood.fe)"
  ge "drill 2: service stayed reachable over the other spine (>= 9 of 10 probes HTTP 200)" 9 "$(cat $T/demo.ok)"
  if [ "$FE_NOS" = nxos ]; then   # Nexus design: no BFD; OSPF 1 s hello / 3 s dead is the detector (nxprobe spine failure: 3.2 s = 17 packets at 5 pkt/s)
    [ "${l:-999}" -le 20 ] && ok "drill 2: the east-west jumbo flow lost $l of 200 packets (5 pkt/s): the OSPF dead timer (3 s) moved it to the other spine" || bad "drill 2: east-west loss (OSPF dead interval is 3 s = 15 packets: are the 1 s / 3 s timers on the uplinks?)" "$l of 200"
  else
    [ "${l:-999}" -le 15 ] && ok "drill 2: the east-west jumbo flow lost $l of 200 packets (5 pkt/s): BFD (3 x 300 ms) moved it to the other spine" || bad "drill 2: east-west loss (BGP hold time is 9 s = 45 packets: is BFD up on the underlay?)" "$l of 200"
  fi
  for i in $(seq 1 12); do n=$(fe_sessions $FSP); [ "$n" = "$NLP" ] && break; sleep 10; done; chk "drill 2: $FSP back to $NLP/$NLP EVPN sessions" $NLP "$n"
  for i in $(seq 1 12); do b=$(fe_bfd_up $FSP); [ "$b" = "$NLP" ] && break; sleep 10; done; chk "drill 2: $FSP back to $NLP/$NLP $([ "$FE_NOS" = nxos ] && echo 'OSPF adjacencies FULL' || echo 'BFD sessions Up')" $NLP "$b"     # BFD follows BGP by a few seconds on Junos
fi
if want 3; then sec "Drill 3 (backend): SILENT failure of the be-leaf1 uplink that carries a live cross-rail flow (spine side shut: only BFD can detect it)"
  chk "drill 3: before -- be-leaf1 reaches rail 5 over 4 spines" 4 "$(ecmp be-leaf1 172.16.5.0/24)"
  ( flood gpu1 172.16.1.11 172.16.5.18 200 ) & sleep 3; U=0; for u in 1 2 3 4; do [ "$(seen be-leaf1 eth$u "icmp[icmptype] = 8 and src 172.16.1.11 and dst 172.16.5.18")" -gt 0 ] && U=$u; done
  [ "$U" != 0 ] || { U=2; echo "  could not see the flow on an uplink; using be-spine2"; }; echo "  the flow gpu1 rail1 -> gpu8 rail5 rides be-leaf1 eth$U -> be-spine$U; shutting be-spine$U eth1 (be-leaf1 keeps carrier: a silent failure)"
  RESTORE="be_shut be-spine$U \"no shutdown\" eth1"; be_shut be-spine$U shutdown eth1; sleep 8; e=$(ecmp be-leaf1 172.16.5.0/24); b=$(OCS be-leaf1 "show bfd session" | grep -cE "Single-Hop +Up"); wait
  l=$(lost "$T/flood.gpu1"); echo "  cross-rail gpu1 rail1 -> gpu8 rail5 during the failure: $(cat $T/flood.gpu1)"
  chk "drill 3: BFD took the dead link out -- be-leaf1 now has 3 BFD sessions Up" 3 "$b"; chk "drill 3: rail 5 route shrank to 3 ECMP next hops" 3 "$e"
  [ "${l:-999}" -le 25 ] && ok "drill 3: the flow lost $l of 200 packets (5 pkt/s) and continued on another spine" || bad "drill 3: cross-rail loss" "$l of 200"
  be_shut be-spine$U "no shutdown" eth1; RESTORE=""; for i in $(seq 1 12); do e=$(ecmp be-leaf1 172.16.5.0/24); [ "$e" = 4 ] && break; sleep 8; done; chk "drill 3: after repair -- back to 4 ECMP next hops" 4 "$e"
fi
if want 4; then sec "Drill 4 (backend): a whole spine goes down (all 8 ports), chosen as the spine carrying the most of 4 live cross-rail flows"
  for n in 1 3 5 7; do ( flood gpu$n 172.16.$n.$((10 + n)) 172.16.$((n + 1)).$((11 + n)) 200 ) & done; sleep 3
  S=1; best=-1; for x in 1 2 3 4; do c=$(seen be-spine$x any "icmp and net 172.16.0.0/16"); echo "  be-spine$x: $c ICMP frames in 2 s"; [ "$c" -gt "$best" ] && { best=$c; S=$x; }; done; echo "  shutting all 8 ports of be-spine$S"
  PORTS="eth1 eth2 eth3 eth4 eth5 eth6 eth7 eth8"; RESTORE="be_shut be-spine$S \"no shutdown\" $PORTS"; be_shut be-spine$S shutdown $PORTS; sleep 8; e=$(ecmp be-leaf4 172.16.8.0/24); wait
  tot=0; for n in 1 3 5 7; do l=$(lost "$T/flood.gpu$n"); tot=$((tot + l)); echo "  gpu$n rail$n -> gpu$((n + 1)) rail$((n + 1)): $(cat $T/flood.gpu$n)"; done
  chk "drill 4: leaves fell back to 3 ECMP next hops (checked on be-leaf4 -> rail 8)" 3 "$e"
  [ "$tot" -le 100 ] && ok "drill 4: four concurrent cross-rail flows lost $tot of 800 packets in total and kept running on 3 spines" || bad "drill 4: cross-rail loss" "$tot of 800"
  be_shut be-spine$S "no shutdown" $PORTS; RESTORE=""
  for i in $(seq 1 15); do s=$(OCS be-spine$S "show ip bgp summary" | awk '/Established sessions/ {print $NF}'); [ "$s" = 8 ] && break; sleep 8; done; chk "drill 4: be-spine$S back to 8/8 eBGP sessions" 8 "$s"
  for i in $(seq 1 8); do e=$(ecmp be-leaf4 172.16.8.0/24); [ "$e" = 4 ] && break; sleep 6; done; chk "drill 4: leaves back to 4 ECMP next hops" 4 "$e"
fi
# a drill breaks things on purpose (probe failures, BFD/BGP flaps): once everything is restored, the warnings it raised are history
o=$(./clear-warnings.sh 0 2>&1 | tail -1); case "$o" in *"and deleted"|*"no Warning events") ok "after the drills: cluster healthy, Warning events back to 0";; *) bad "after the drills: warnings not cleared" "$o";; esac
summary
