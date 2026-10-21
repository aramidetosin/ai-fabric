#!/bin/bash
# trace-rail.sh [gpuA] [gpuB] [outdir]: hop-by-hop trace of GPU-to-GPU POD traffic over the OcNOS rail fabric (the backend's equivalent of
# trace.sh). Two pods with Multus rail attachments -- A on gpuA with rails 1+2, B on gpuB with rails 1+5 -- then the flows below.
# Rail networks per profile: the NVIDIA network-operator's MacvlanNetwork NADs default/net-rail-N (site-a-nx, operator decision 2026-09-24,
# production shape: NO routes, a rail interface reaches only its own rail) or the bootstrap's gpu/rail-N (other profiles: + a 172.16/16 route).
#   1. same rail            A.rail1 -> B.rail1   must stay on be-leaf1 (bridged in VLAN 10), no spine involved
#   2. same rail, jumbo     8972-byte DF on the same path
#   operator networks: 3. rails stay separate -- no 172.16/16 route in the pod, rail 5 is not reached through a rail interface of rail 2
#                      4/5. INTER-RAIL at the GPU NICs (the nodes' own rail addresses, which do route between rails): rail 2 of gpuA -> rail 5
#                      of gpuB and back: rail gateway > ONE spine (per-flow ECMP) > the other rail leaf; TTL per hop; 6. 1472 DF / jumbo.
#                      This is the only traffic the rail spines carry: a job whose GPUs keep to their own rail never reaches them.
#   bootstrap networks: 3/4. cross-rail both ways via a spine (ECMP), 5. cross-rail jumbo (OcNOS-VM rail SVI capped at MTU 1500)
# Evidence: routing/ECMP lookups on the rail leaves and spines, captures on every leaf and spine port of both paths, TTL per hop, TRACE.md.
set -u
cd "$(dirname "$0")"; . ./lib.sh
A=${1:-gpu1}; B=${2:-gpu8}; TS=$(date -u +%Y%m%d_%H%M%S); OUT=${3:-audits/ai-fabric_rail_trace_$TS}; mkdir -p "$OUT/raw" "$OUT/captures"
a=${A#gpu}; b=${B#gpu}; PA=$((4 + a)); PB=$((4 + b)); R="$OUT/raw/trace.txt"; : > "$R"
export EVID="$PWD/$OUT/raw/commands.txt"; : > "$EVID"     # full transcript: prompt + command + raw output of everything this script runs on a device
sec() { { echo; echo "################ $*"; } | tee -a "$R"; }
run() { # title, command...: shows the device prompt + the exact command + the raw output (the transcript the helpers in lib.sh record);
  local title=$1; shift; local m t; m=$(wc -c < "$EVID"); t=$(mktemp)   # a command that does not go through a helper is shown as "$ command"
  { echo; echo "---- $title"; "$@" > "$t" 2>&1; if [ "$(wc -c < "$EVID")" -gt "$m" ]; then tail -c +$((m + 1)) "$EVID" | cat -s; else echo "\$ $*"; cat "$t"; fi; rm -f "$t"; } | tee -a "$R"; }
pod() { cat <<EOF
apiVersion: v1
kind: Pod
metadata: {name: $1, namespace: gpu, labels: {app: railtrace}, annotations: {k8s.v1.cni.cncf.io/networks: '$3'}}
spec:
  nodeSelector: {kubernetes.io/hostname: $2}
  tolerations: [{key: nvidia.com/gpu, operator: Exists, effect: NoSchedule}]
  terminationGracePeriodSeconds: 1
  containers: [{name: t, image: ghcr.io/srl-labs/network-multitool, command: [sleep, '1800']}]
---
EOF
}
OPR=$(python3 -c 'import gen; print(1 if gen.NETOP else 0)')      # 1: rails = the network-operator's default/net-rail-N (rail r = net-rail-(r-1))
nad() { [ "$OPR" = 1 ] && echo "default/net-rail-$(($1 - 1))" || echo "gpu/rail-$1"; }
{ pod rt-a $A "$(nad 1),$(nad 2)"; pod rt-b $B "$(nad 1),$(nad 5)"; } > "$OUT/raw/pods.yaml"
docker cp "$OUT/raw/pods.yaml" $LAB-bastion:/tmp/railtrace.yaml >/dev/null
KT=360 K "kubectl -n gpu delete pod -l app=railtrace --wait=true >/dev/null 2>&1; kubectl apply -f /tmp/railtrace.yaml >/dev/null; kubectl -n gpu wait --for=condition=Ready pod -l app=railtrace --timeout=300s" | tail -2
ipof() { K "kubectl -n gpu exec $1 -- ip -4 -o addr show $2" | awk '{print $4}' | cut -d/ -f1; }
A1=$(ipof rt-a net1); A2=$(ipof rt-a net2); B1=$(ipof rt-b net1); B5=$(ipof rt-b net2)
[ -n "$A1" ] && [ -n "$A2" ] && [ -n "$B1" ] && [ -n "$B5" ] || { echo "pods did not get their rail addresses"; exit 1; }
# Between rails: on the operator networks the PODS cannot (no route), the NODES can: NIC r of node n is 172.16.r.(10+n) with its own routing
# table (default via the rail gateway). XA / XB = the two ends of the inter-rail flows: the nodes' NICs there, the pods on the other profiles.
XA=$A2; XB=$B5; [ "$OPR" = 1 ] && { XA="172.16.2.$((10 + a))"; XB="172.16.5.$((10 + b))"; }

sec "0. Endpoints"
echo "pod rt-a on $A : rail1 $A1 (net1 = macvlan on gpu0 -> be-leaf1 eth$PA)   rail2 $A2 (net2 = macvlan on gpu1 -> be-leaf2 eth$PA)" | tee -a "$R"
echo "pod rt-b on $B : rail1 $B1 (net1 = macvlan on gpu0 -> be-leaf1 eth$PB)   rail5 $B5 (net2 = macvlan on gpu4 -> be-leaf5 eth$PB)" | tee -a "$R"
run "rt-a addresses + routes$([ "$OPR" = 1 ] && echo ' (operator networks, production shape: only the connected rail /24s)' || echo ' (the /16 via each rail gateway comes from the rail NetworkAttachmentDefinition)')" K "kubectl -n gpu exec rt-a -- sh -c 'ip -br addr | grep net; ip route | grep 172.16'"
run "rt-b addresses + routes" K "kubectl -n gpu exec rt-b -- sh -c 'ip -br addr | grep net; ip route | grep 172.16'"
if [ "$OPR" = 1 ]; then
  run "the rail networks: the network-operator's MacvlanNetworks and the NADs it rendered" K "kubectl get macvlannetworks -o custom-columns=NAME:.metadata.name,MASTER:.spec.master,MTU:.spec.mtu,STATE:.status.state --no-headers; kubectl -n default get net-attach-def $(nad 1 | cut -d/ -f2) -o jsonpath='{.spec.config}'; echo"
  run "rt-a network-status (Multus): which NAD handed out which rail address" K "kubectl -n gpu get pod rt-a -o jsonpath='{.metadata.annotations.k8s\\.v1\\.cni\\.cncf\\.io/network-status}' | jq -c '.[] | {name, interface, ips}'"
fi

sec "1. Control plane: how the rail leaves and spines route between rail 2 and rail 5"
run "be-leaf2 (rail 2, AS 65202): route to rail 5 -- expect 4 next hops, one per spine" OCS be-leaf2 "show ip route 172.16.5.0/24" "show ip bgp 172.16.5.0/24"
run "be-leaf5 (rail 5, AS 65205): route back to rail 2" OCS be-leaf5 "show ip route 172.16.2.0/24"
for s in 1 2 3 4; do run "be-spine$s: rail 2 and rail 5 are each one hop away" OCS be-spine$s "show ip route 172.16.2.0/24" "show ip route 172.16.5.0/24"; done
run "be-leaf2 BFD to the spines (failure detection for the ECMP members)" OCS be-leaf2 "show bfd session"

declare -A CAP
CAP[1a-leaf1-eth$PA-from-$A]="be-leaf1 eth$PA"; CAP[1b-leaf1-eth$PB-to-$B]="be-leaf1 eth$PB"
for u in 1 2 3 4; do CAP[1c-leaf1-uplink$u]="be-leaf1 eth$u"; CAP[3b-leaf2-uplink$u]="be-leaf2 eth$u"; CAP[3c-spine$u-eth2-leaf2side]="be-spine$u eth2"; CAP[3d-spine$u-eth5-leaf5side]="be-spine$u eth5"; CAP[3e-leaf5-uplink$u]="be-leaf5 eth$u"; done
CAP[3a-leaf2-eth$PA-from-$A]="be-leaf2 eth$PA"; CAP[3f-leaf5-eth$PB-to-$B]="be-leaf5 eth$PB"
FILT="icmp and (host $A1 or host $A2 or host $B1 or host $B5 or host $XA or host $XB)"
sec "2. Capture points (tcpdump in each switch container's namespace; container ethN carries the frames of the switch port ethN)"
PIDS=""; for k in $(printf '%s\n' "${!CAP[@]}" | sort); do set -- ${CAP[$k]}; pid=$(docker inspect -f '{{.State.Pid}}' "$LAB-$1"); echo "  $k: $1 $2" | tee -a "$R"
  timeout 120 nsenter -t "$pid" -n tcpdump -i "$2" -nn -s 128 -w "$OUT/captures/$k.pcap" "$FILT" >/dev/null 2>&1 & PIDS="$PIDS $!"; done
sleep 3

sec "3. The flows (exact commands, run inside the pods)"
flow() { local id=$1 t=$2 p=$3; shift 3; { echo; echo "---- $t"; echo "\$ kubectl -n gpu exec $p -- $*"; K "kubectl -n gpu exec $p -- $*" 2>&1 | tail -6; } | tee "$OUT/raw/flow-$id.txt"; }
hflow() { local id=$1 t=$2 n=$3; shift 3; { echo; echo "---- $t"; echo "$n\$ $*"; H $n "$*" 2>&1 | tail -6; } | tee "$OUT/raw/flow-$id.txt"; }      # on the node itself
{ flow 1 "flow 1: same rail, rt-a rail1 -> rt-b rail1" rt-a ping -c 3 -W 2 -I net1 $B1
  flow 2 "flow 2: same rail, jumbo 8972-byte DF" rt-a ping -c 3 -W 2 -I net1 -M do -s 8972 $B1
  if [ "$OPR" = 1 ]; then
  flow 3r "flow 3: production shape -- rt-a's routes to the rails (only its own /24s, no 172.16.0.0/16)" rt-a ip route show 172.16.0.0/16 root 172.16.0.0/16
  flow 3g "flow 3: how rt-a would reach rt-b's rail-5 address $B5 (must NOT be via a rail interface net1/net2)" rt-a ip route get $B5
  flow 3p "flow 3: rail 2 -> rail 5 bound to the rail interface net2 (must fail: rails are separate networks)" rt-a ping -c 2 -W 2 -I net2 $B5
  H $A "ping -c 2 -W 1 -q -I $XA $XB >/dev/null 2>&1; true" >/dev/null 2>&1      # ARP on both rail leaves first (1-2 s on the OcNOS VM): not part of the record
  hflow 4r "flow 4: inter-rail at the GPU NICs -- how $A routes rail 2 -> rail 5 (the rail NIC's own table: default via the rail gateway)" $A ip route get $XB from $XA
  hflow 4 "flow 4: inter-rail, $A rail 2 ($XA) -> $B rail 5 ($XB): routed by be-leaf2, one spine, be-leaf5" $A ping -c 3 -W 2 -I $XA $XB
  hflow 5 "flow 5: inter-rail reverse, $B rail 5 ($XB) -> $A rail 2 ($XA)" $B ping -c 3 -W 2 -I $XB $XA
  hflow 6a "flow 6a: inter-rail, largest unfragmented standard packet (1472-byte DF)" $A ping -c 4 -W 2 -I $XA -M do -s 1472 $XB
  hflow 6b "flow 6b: inter-rail, jumbo 8972-byte DF (OcNOS VM: rail SVI MTU 1500 -> expect frag-needed, not a reply)" $A ping -c 2 -W 2 -I $XA -M do -s 8972 $XB
  else
  flow 3 "flow 3: cross-rail, rt-a rail2 -> rt-b rail5" rt-a ping -c 3 -W 2 -I net2 $B5
  flow 3t "flow 3: path (traceroute)" rt-a traceroute -n -w 2 -q 1 -i net2 $B5
  flow 4 "flow 4: cross-rail reverse, rt-b rail5 -> rt-a rail2" rt-b ping -c 3 -W 2 -I net2 $A2
  flow 4t "flow 4: path (traceroute)" rt-b traceroute -n -w 2 -q 1 -i net2 $A2
  flow 5a "flow 5a: cross-rail, largest unfragmented standard packet (1472-byte DF)" rt-a ping -c 4 -W 2 -I net2 -M do -s 1472 $B5
  flow 5b "flow 5b: cross-rail, jumbo 8972-byte DF (OcNOS VM: rail SVI MTU 1500 -> expect frag-needed from be-leaf5, not a reply)" rt-a ping -c 2 -W 2 -I net2 -M do -s 8972 $B5
  fi; } | tee -a "$R" | tee "$OUT/flows.txt"
sleep 3; for p in $PIDS; do kill -INT $p 2>/dev/null; done; sleep 2

sec "4. Where each flow was seen (ICMP frames per capture point)"
for f in "$OUT"/captures/*.pcap; do n=$(basename "$f" .pcap)
  same=$(tcpdump -r "$f" -nn "host $A1 and host $B1" 2>/dev/null | wc -l); fwd=$(tcpdump -r "$f" -nn "src $XA and dst $XB" 2>/dev/null | wc -l); rev=$(tcpdump -r "$f" -nn "src $XB and dst $XA" 2>/dev/null | wc -l)
  podx=0; [ "$OPR" = 1 ] && podx=$(tcpdump -r "$f" -nn "host $A2 and host $B5" 2>/dev/null | wc -l)      # operator networks: the pod's attempt of flow 3 (must be nowhere)
  printf "  %-30s same-rail %-3s cross A>B %-3s cross B>A %-3s pod-rail2>rail5 %-3s\n" "$n" "$same" "$fwd" "$rev" "$podx"
  { echo "# $n"; tcpdump -r "$f" -nn -v 2>/dev/null | grep -B1 -E "ICMP echo (request|reply)" | grep -E "ttl|ICMP echo" | head -12; tcpdump -r "$f" -nn 2>/dev/null | grep -m2 "need to frag"; } > "$OUT/captures/$n.txt"; done | tee -a "$R" | tee "$OUT/where.txt"
FS=$(awk '$1 ~ /^3c-spine/ && $6 + 0 > 0 {sub("3c-spine", "", $1); sub("-.*", "", $1); print "be-spine" $1}' "$OUT/where.txt" | head -1)
RS=$(awk '$1 ~ /^3d-spine/ && $9 + 0 > 0 {sub("3d-spine", "", $1); sub("-.*", "", $1); print "be-spine" $1}' "$OUT/where.txt" | head -1)
UP=$(awk '$1 ~ /^1c-leaf1-uplink/ {s += $3} END {print s + 0}' "$OUT/where.txt")
X3=$(awk '{s += $11} END {print s + 0}' "$OUT/where.txt")   # production shape: frames of the pod's flow 3p (rail 2 -> rail 5 bound to net2) at any capture point
EQ=$(tcpdump -r "$OUT/captures/1a-leaf1-eth$PA-from-$A.pcap" -nn "icmp[icmptype] = 8 and src $A1 and dst $B1" 2>/dev/null | wc -l); ER=$(tcpdump -r "$OUT/captures/1a-leaf1-eth$PA-from-$A.pcap" -nn "icmp[icmptype] = 0 and src $B1 and dst $A1" 2>/dev/null | wc -l)
EQ2=$(tcpdump -r "$OUT/captures/1b-leaf1-eth$PB-to-$B.pcap" -nn "icmp[icmptype] = 8 and src $A1 and dst $B1" 2>/dev/null | wc -l); ER2=$(tcpdump -r "$OUT/captures/1b-leaf1-eth$PB-to-$B.pcap" -nn "icmp[icmptype] = 0 and src $B1 and dst $A1" 2>/dev/null | wc -l)
{ echo; echo "same-rail frames seen on be-leaf1 UPLINKS: $UP (0 = the flow never left the rail leaf)"
  echo "same rail, both directions on be-leaf1: eth$PA $EQ echo requests in / $ER echo replies out; eth$PB $EQ2 echo requests out / $ER2 echo replies in"
  [ "$OPR" = 1 ] && echo "flow 3p frames (the POD's rail 2 -> rail 5 attempt bound to net2) at any capture point: $X3 (0 = nothing of it reached a rail leaf)"
  echo "inter-rail A>B ($XA -> $XB) chose ${FS:-?}; the return B>A chose ${RS:-?}"; } | tee -a "$R"
: > "$OUT/ttl.txt"; sec "5. TTL per hop of the inter-rail flow $XA -> $XB (the request leaves its sender with TTL 64)"
for k in 3a-leaf2-eth$PA-from-$A 3c-${FS#be-}-eth2-leaf2side 3e-leaf5-uplink${FS#be-spine} 3f-leaf5-eth$PB-to-$B; do f="$OUT/captures/$k.pcap"; [ -f "$f" ] || continue
  printf "  %-32s %s\n" "$k" "$(tcpdump -r "$f" -nn -v "src $XA and dst $XB and icmp[icmptype] = 8 and ip[2:2] < 200" 2>/dev/null | grep -m1 -oE "ttl [0-9]+")"; done | tee -a "$R" | tee "$OUT/ttl.txt"
K "kubectl -n gpu delete pod -l app=railtrace --wait=false >/dev/null 2>&1"

# ---- verdict: the trace is also a test. Every expectation of the path is asserted from the recorded evidence.
loss() { grep -oE "[0-9]+% packet loss" "$OUT/raw/flow-$1.txt" | head -1; }
hops() { awk '$1 ~ /^[0-9]+$/ {print $2}' "$OUT/raw/flow-$1.txt" | paste -sd' '; }
rcv()  { local r; r=$(grep -oE "[0-9]+ received" "$OUT/raw/flow-$1.txt" | head -1 | cut -d' ' -f1); echo "${r:-0}"; }   # no reply line at all (unreachable) = 0
NF=$(awk '$1 ~ /^3c-spine/ && $6 + 0 > 0' "$OUT/where.txt" | wc -l); NR=$(awk '$1 ~ /^3d-spine/ && $9 + 0 > 0' "$OUT/where.txt" | wc -l)
FRAG=$(tcpdump -r "$OUT/captures/3a-leaf2-eth$PA-from-$A.pcap" -nn 2>/dev/null | grep -m1 -oE "IP [0-9.]+ > $XA: ICMP $XB unreachable - need to frag \(mtu [0-9]+\)")
{ printf "\n== Verdict (rail trace %s <-> %s)\n" "$A" "$B"
  chk "flow 1: same rail $A1 -> $B1, no loss" "0% packet loss" "$(loss 1)"
  chk "flow 2: same rail JUMBO 8972-byte DF, no loss" "0% packet loss" "$(loss 2)"
  chk "same-rail frames never reached a spine (frames on the 4 be-leaf1 uplinks)" 0 "$UP"
  [ "$EQ" -ge 3 ] && [ "$ER" -ge 3 ] && [ "$EQ2" -ge 3 ] && [ "$ER2" -ge 3 ] && ok "same rail, both directions captured on be-leaf1: requests in on eth$PA and out on eth$PB, replies in on eth$PB and out on eth$PA" || bad "same-rail request + reply on both leaf ports" "eth$PA $EQ/$ER, eth$PB $EQ2/$ER2"
  if [ "$OPR" = 1 ]; then
  ns=$(K "kubectl -n gpu get pod rt-a -o jsonpath='{.metadata.annotations.k8s\\.v1\\.cni\\.cncf\\.io/network-status}'" | jq -r '[.[] | select(.interface | test("^net")) | .name] | join(",")')
  chk "rt-a's rail interfaces come from the network-operator's NADs" "default/net-rail-0,default/net-rail-1" "$ns"
  chk "rail addresses outside the excluded node block (.0/26): whereabouts range .64-.254" 4 "$(printf '%s\n' $A1 $A2 $B1 $B5 | awk -F. '$4 >= 64 && $4 <= 254' | wc -l)"
  chk "production shape: no 172.16.0.0/16 route in the pod" 0 "$(grep -c '^172\.16\.0\.0/16' "$OUT/raw/flow-3r.txt")"
  o=$(grep -oE "dev [a-z0-9]+" "$OUT/raw/flow-3g.txt" | head -1); case "$o" in "dev net"*) bad "rail 5 reached through a rail interface" "$o";; "") bad "route lookup for $B5" "no answer";; *) ok "rail 5 ($B5) is not reached through a rail interface of rt-a: $o";; esac
  chk "rail 2 -> rail 5 bound to net2 fails (rails are separate networks, as in production)" 0 "$(rcv 3p)"
  chk "no frame of that attempt on any rail capture point (the leaves never saw it)" 0 "$X3"
  grep -q "via 172.16.2.1 dev" "$OUT/raw/flow-4r.txt" && ok "inter-rail at the GPU NICs: $A sends rail 2 -> rail 5 to its rail gateway 172.16.2.1 (be-leaf2)" || bad "$A route for $XB from $XA" "$(grep -m1 172.16 "$OUT/raw/flow-4r.txt")"
  chk "flow 4: inter-rail $XA -> $XB (rail 2 -> rail 5), no loss" "0% packet loss" "$(loss 4)"
  chk "flow 4 rode exactly ONE spine (per-flow ECMP, no spraying): ${FS:-none}" 1 "$NF"
  chk "flow 5: inter-rail reverse $XB -> $XA, no loss" "0% packet loss" "$(loss 5)"
  chk "the return direction rode exactly ONE spine: ${RS:-none}" 1 "$NR"
  chk "TTL of flow 4 drops by one per routed hop (node, after be-leaf2, after the spine, after be-leaf5)" "64 63 62 61" "$(grep -oE "ttl [0-9]+" "$OUT/ttl.txt" | cut -d' ' -f2 | paste -sd' ')"
  ge "flow 6a: 1472-byte DF crosses rails (4 sent; the first may be lost to ARP)" 3 "$(rcv 6a)"
  if [ "$(rcv 6b)" = 2 ]; then ok "flow 6b: jumbo 8972-byte DF crosses rails (this platform routes jumbo between rails)"
  elif [ -n "$FRAG" ]; then known "flow 6b: jumbo 8972 DF does NOT cross rails on the OcNOS VM (path MTU 1500)" "evidence: $FRAG -- path-MTU discovery works; the VM refuses any rail SVI MTU above 1500, hardware carries mtu 9216"
  else bad "flow 6b: inter-rail jumbo dropped silently (no frag-needed seen)" "$(loss 6b)"; fi
  else
  chk "flow 3: cross-rail $A2 -> $B5, no loss" "0% packet loss" "$(loss 3)"
  case "$(hops 3t)" in "172.16.2.1 10.255."*" 10.255."*" $B5") ok "flow 3 path = rail-2 gateway (be-leaf2) > spine > be-leaf5 > pod: $(hops 3t)";; *) bad "flow 3 path shape" "$(hops 3t)";; esac
  chk "flow 3 rode exactly ONE spine (per-flow ECMP, no spraying): ${FS:-none}" 1 "$NF"
  chk "flow 4: cross-rail reverse $B5 -> $A2, no loss" "0% packet loss" "$(loss 4)"
  case "$(hops 4t)" in "172.16.5.1 10.255."*" 10.255."*" $A2") ok "flow 4 path = rail-5 gateway (be-leaf5) > spine > be-leaf2 > pod: $(hops 4t)";; *) bad "flow 4 path shape" "$(hops 4t)";; esac
  chk "flow 4 rode exactly ONE spine: ${RS:-none}" 1 "$NR"
  chk "TTL of flow 3 drops by one per routed hop (pod, after be-leaf2, after the spine, after be-leaf5)" "64 63 62 61" "$(grep -oE "ttl [0-9]+" "$OUT/ttl.txt" | cut -d' ' -f2 | paste -sd' ')"
  ge "flow 5a: 1472-byte DF crosses rails (4 sent; the first may be lost to ARP)" 3 "$(rcv 5a)"
  if [ "$(rcv 5b)" = 2 ]; then ok "flow 5b: jumbo 8972-byte DF crosses rails (this platform routes jumbo between rails)"
  elif [ -n "$FRAG" ]; then known "flow 5b: jumbo 8972 DF does NOT cross rails on the OcNOS VM (path MTU 1500)" "evidence: $FRAG -- path-MTU discovery works; the VM refuses any rail SVI MTU above 1500, hardware carries mtu 9216"
  else bad "flow 5b: jumbo dropped silently (no frag-needed seen)" "$(loss 5b)"; fi
  fi
  summary; } > "$OUT/verdict.txt"; RC=$?; cat "$OUT/verdict.txt" | tee -a "$R"

{ echo "# ai-fabric rail trace (GPU-to-GPU pod traffic over the OcNOS backend), $TS"; echo
echo "Pods: **rt-a** on $A (rail1 $A1, rail2 $A2) and **rt-b** on $B (rail1 $B1, rail5 $B5). Rail N = be-leafN, VLAN N*10, 172.16.N.0/24, gateway .1."; echo
echo "1. **Same rail** ($A1 -> $B1): both NICs sit in VLAN 10 on be-leaf1 (ports eth$PA and eth$PB). The frames are bridged on the leaf; its uplinks saw $UP of them. No spine, no routing, so jumbo 8972-byte DF passes."
if [ "$OPR" = 1 ]; then
echo "2. **Rails stay separate** (production shape): the network-operator's MacvlanNetworks carry no routes, so rt-a holds only the connected /24 of each attached rail. rt-b's rail-5 address $B5 is not reachable through a rail interface of rt-a (flow 3), exactly as in the production GPU cluster: collective traffic uses the same rail end to end."
echo "3. **Where the addresses come from**: whereabouts per MacvlanNetwork, range 172.16.R.0/24 minus .1 and the node block .0/26, so pods get .64-.254 (raw/trace.txt: the rendered NAD and rt-a's network-status)."
echo "4. **Inter-rail, and what the rail spines are for** ($XA -> $XB, the GPU NICs' own addresses): a node, unlike its pods, has a routing table per rail NIC with a default via the rail gateway. $A sends rail 2 -> rail 5 to 172.16.2.1 on be-leaf2, which holds 172.16.5.0/24 as an eBGP route with FOUR next hops (one per spine) and hashed this flow onto **${FS:-?}**; the spine reaches rail 5 one hop away on be-leaf5, which delivers it on eth$PB. Three routed hops: TTL 64 > 63 > 62 > 61 (below)."
echo "5. **The way back** ($XB -> $XA): be-leaf5 makes its own ECMP choice, here **${RS:-?}**: request and reply are hashed independently and may or may not share a spine."
echo "6. **Why a training job never does this**: its pods keep GPU r on rail r end to end (same rail = one leaf, bridged, jumbo), and the rail networks give them no route to another rail. The spines carry only traffic BETWEEN rails; on the OcNOS VM that routed path is also capped at MTU 1500 (flow 6b: frag-needed), same-rail traffic is not."
else
echo "2. **Cross-rail** ($A2 -> $B5): the pod routes 172.16.0.0/16 to its rail gateway 172.16.2.1 (be-leaf2). be-leaf2 holds 172.16.5.0/24 as an eBGP route with FOUR next hops (one per spine, \`max-paths ebgp 64\`) and hashed this flow onto **${FS:-?}**; the spine has the rail as a one-hop eBGP route to be-leaf5, which bridges it to the pod on eth$PB."
echo "3. **Reverse** ($B5 -> $A2): be-leaf5 makes its own ECMP choice, here **${RS:-?}** -- forward and return paths are chosen independently (they may or may not share a spine)."
echo "4. **TTL**: 64 at the pod, minus one per routed hop (be-leaf2, the spine, be-leaf5): see below."
echo "5. **Cross-rail jumbo**: on the OcNOS VM a rail SVI cannot exceed MTU 1500 (every \`mtu\` above it is refused), so routed packets are capped at 1500 while same-rail L2 jumbo works. be-leaf5 answers a DF 8972 packet with ICMP frag-needed (path-MTU discovery works). Hardware carries \`interface vlan1.N / mtu 9216\` as in the AI_FABRIC production configs."
fi
echo; echo "## Verdict"; echo '```'; cat "$OUT/verdict.txt"; echo '```'
echo; echo "## Flows"; echo '```'; cat "$OUT/flows.txt"; echo '```'
echo; echo "## Where each flow was seen"; echo '```'; cat "$OUT/where.txt"; echo '```'
echo; echo "## TTL per hop (inter-rail flow $XA -> $XB)"; echo '```'; cat "$OUT/ttl.txt"; echo '```'
echo; echo "## Control plane"; echo '```'; sed -n '/^################ 1\. Control plane/,/^################ 2\. Capture/p' "$R" | grep -vE '^################' | grep -v '^$' | head -90; echo '```'
echo; echo "Every command with its raw output, as typed on the devices: raw/commands.txt. Full outputs: raw/trace.txt. Packet files: captures/*.pcap (decoded heads in captures/*.txt)."; } > "$OUT/TRACE.md"
keep_latest ai-fabric_rail_trace "$OUT"
echo; echo "rail trace -> $OUT"; exit $RC
