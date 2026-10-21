#!/bin/bash
# trace-pvc.sh [node] [outdir]: end-to-end trace of a PVC provisioned through the storage management API, the way the platform's
# CSI driver would do it (adapted from <reference-platform>/trace-pvc.sh). pvc-tool.sh on a node calls https://10.1.2.16 (the storage
# node's OOB/management address). The call crosses VLAN 10 -> anycast gateway 10.1.1.1 -> VXLAN (L3 VNI $L3VNI) -> border leaf ->
# firewall (zone fabric -> oob, rule fabric-to-storage-api, tcp/443 only) -> oob-sw -> storage node eth9.
# Evidence: captures at every hop, a negative test against the firewall policy, the storage API log with the client address, and the
# Kubernetes provisioning events. The PAN-OS session/traffic-log section runs only if the OPERATOR exports FW_PASS (nothing here stores it).
set -u
cd "$(dirname "$0")"; . ./lib.sh
L3VNI=$(l3vni); MH_KIND=$([ "$FE_NOS" = nxos ] && echo vPC || echo ESI-LAG)     # per profile: Nexus = L3 VNI 11000 + vPC, else 1000 + ESI-LAG
# site-a-nx (MULTI=1): the storage management API lives on VLAN 200 (VRF stor-mgmt, L3 VNI 12000) behind the firewall's .200 sub-interfaces, reached
# through the SAME firewall ports it enters on (tag 100 in = VRF k8s / zone data, tag 200 out = VRF stor-mgmt); FM1/FM2 hang off Eth1/<port> of the control pair.
read -r MULTI SMVNI SMTAG SMPORT <<< "$(python3 -c 'import gen; z = gen.ZONE.get("stor-mgmt"); print(int(gen.MULTI), z["l3vni"] if z else "", z["tag"] if z else "", gen.STOR_MGMT["port"] if gen.MULTI else "")')"
read -r DTAG FZ RSM <<< "$(python3 -c 'import gen; print(gen.ZONE[gen.VRF]["tag"] or "-", gen.FZ, gen.fw_rule("fabric-to-stor-mgmt" if gen.MULTI else "fabric-to-storage-api"))')"
NODE=${1:-ctrl2}; TS=$(date -u +%Y%m%d_%H%M%S); case "$NODE" in ctrl*) CLS=ctrl;; *) CLS=gpu;; esac   # one result set per node class
OUT=${2:-audits/ai-fabric_pvc_trace_${CLS}_$TS}; mkdir -p "$OUT/raw" "$OUT/captures"
FB=$(python3 -c 'import gen; print(gen.FB_API)'); KC=/shared/ai-fabric/kubeconfig; PVC=pvc-trace-$(date +%H%M%S); R="$OUT/raw/trace.txt"; : > "$R"
export EVID="$PWD/$OUT/raw/commands.txt"; : > "$EVID"     # full transcript: prompt + command + raw output of everything this script runs on a device
FW_MGMT=$(mgmt fw)
sec() { { echo; echo "################ $*"; } | tee -a "$R"; }
run() { # title, command...: shows the device prompt + the exact command + the raw output (the transcript the helpers in lib.sh record);
  local title=$1; shift; local m t; m=$(wc -c < "$EVID"); t=$(mktemp)   # a command that does not go through a helper is shown as "$ command"
  { echo; echo "---- $title"; "$@" > "$t" 2>&1; if [ "$(wc -c < "$EVID")" -gt "$m" ]; then tail -c +$((m + 1)) "$EVID" | cat -s; else echo "\$ $*"; cat "$t"; fi; rm -f "$t"; } | tee -a "$R"; }
read -r L1 L2 PORT <<< "$(leafport "$NODE")"; [ -n "$PORT" ] || { echo "node must be a control or GPU node of this lab"; exit 2; }
NODE_IP=$(H $NODE "ip route get $FB" | grep -oE "src [0-9.]+" | cut -d" " -f2)   # the address the node really uses (bond0 may also hold the kube API VIP)

sec "0. Path expectation: $NODE ($NODE_IP) -> storage management API $FB"
run "$NODE route to the storage management address (must be the fabric gateway on bond0, not the node's own BMC NIC)" H $NODE "ip route get $FB; ip rule show | grep 100; ip route show table 100"
run "server leaf $L1: $FB resolves via the type-5 default from the firewall (vrf k8s)" fe_vrf_route $L1 $FB
run "border leaf: next hop is the firewall" fe_vrf_route fe-border1 $FB
show_rule() { RSM=$RSM python3 -c 'import os,xml.etree.ElementTree as ET
r=ET.parse("bootstrap/fw.xml").getroot()
for e in r.iter("entry"):
    if e.get("name")==os.environ["RSM"]:
        g=lambda t: ",".join(m.text for m in e.find(t))
        print("rule", e.get("name") + ": from", g("from"), "to", g("to"), "| source", g("source"), "| destination", g("destination"), "| service", g("service"), "| action", e.findtext("action"))'; }
run "firewall rule that must match (from the generated bootstrap/fw.xml)" show_rule
run "storage node: API listener on the management address" H storage "ss -ltnp | grep :443; systemctl is-active flashblade-api; ip -br -4 addr | grep -F $FB"

# ---- captures: every hop (container interface ethN = switch port swpN / firewall ethernet1/N)
declare -A CAP
CAP[1-$L1-$NODE]="$L1 eth$PORT"; CAP[1-$L2-$NODE]="$L2 eth$PORT"
CAP[2-border1-spine1]="fe-border1 eth1"; CAP[2-border1-spine2]="fe-border1 eth2"; CAP[2-border2-spine1]="fe-border2 eth1"; CAP[2-border2-spine2]="fe-border2 eth2"
CAP[3-fw-in-border1]="fw eth1"; CAP[3-fw-in-border2]="fw eth2"
if [ "$MULTI" = 1 ]; then   # egress = the same firewall ports, tag $SMTAG; then border (VRF stor-mgmt) > VXLAN L3 VNI $SMVNI > control leaf Eth1/$SMPORT > FM1 / FM2
  read -r CL1 CL2 <<< "$(python3 -c 'import gen; print(*gen.PAIR[gen.HOSTS["storage"]["pair"]])')"
  CAP[5-$CL1-fm1]="$CL1 eth$SMPORT"; CAP[5-$CL2-fm2]="$CL2 eth$SMPORT"
  FILT="host $FB or udp port 4789 or (vlan and (host $FB or udp port 4789))"
else
  CAP[4-fw-out-oob]="fw eth3"
  read -r OOBFW OOBST <<< "$(python3 -c 'import gen; print(gen.OOB_FW_PORT, gen.OOB_PORTS["storage"])')"      # OOB switch ports of the firewall and of the storage node (per profile)
  CAP[5-oobsw-from-fw]="oob-sw eth$OOBFW"; CAP[5-oobsw-to-storage]="oob-sw eth$OOBST"
  FILT="host $FB or udp port 4789"
fi
sec "1. Capture points (tcpdump in each container's network namespace + inside the two guests)"
PIDS=""
for k in $(printf '%s\n' "${!CAP[@]}" | sort); do set -- ${CAP[$k]}; pid=$(docker inspect -f '{{.State.Pid}}' "$LAB-$1" 2>/dev/null); [ -n "$pid" ] || continue
  echo "\$ nsenter -t $pid -n tcpdump -i $2 -nn -s 256 -w captures/$k.pcap '$FILT'   # $1" | tee -a "$R"
  timeout 150 nsenter -t "$pid" -n tcpdump -i "$2" -nn -s 256 -w "$OUT/captures/$k.pcap" "$FILT" >/dev/null 2>&1 & PIDS="$PIDS $!"; done
for n in $NODE storage; do
  echo "\$ ssh admin@$(mgmt $n) sudo tcpdump -i any -nn -s 256 -w /tmp/pvc-trace-$n.pcap 'host $FB'   # $n (guest, all interfaces)" | tee -a "$R"
  ssh -n $SSHO "admin@$(mgmt "$n")" "sudo rm -f /tmp/pvc-trace-$n.pcap; sudo timeout 150 tcpdump -i any -nn -s 256 -w /tmp/pvc-trace-$n.pcap 'host $FB' >/dev/null 2>&1; sudo chmod 644 /tmp/pvc-trace-$n.pcap" & PIDS="$PIDS $!"; done
if [ -n "${FW_PASS:-}" ]; then   # operator-supplied only
  fwkey() { curl -sk --max-time 20 "https://$FW_MGMT/api/?type=keygen&user=${FW_USER:-admin}" --data-urlencode "password=$FW_PASS" | sed -n 's|.*<key>\(.*\)</key>.*|\1|p'; }
  ( k=$(fwkey); for i in $(seq 1 20); do sleep 1; curl -sk --max-time 10 "https://$FW_MGMT/api/" --data-urlencode type=op --data-urlencode "key=$k" --data-urlencode "cmd=<show><session><all><filter><destination>$FB</destination></filter></all></session></show>" | grep -oE "<(source|dst|sport|dport|from|to|state|application|security-rule)>[^<]*" | tr '\n' ' '; echo; done | grep -v '^ *$' | sort -u > "$OUT/raw/fw-sessions-during.txt" ) &
fi
sleep 3

sec "2. pvc-tool.sh on $NODE (the exact command and its full output)"
FBCA=$(python3 -c 'import gen; print(f"FB_CACERT=/shared/{gen.CLUSTER}/cluster-ca.crt " if gen.LAB_CA else "")')   # lab CA: verify the API's certificate
CMD="${FBCA}FB_MGMT=$FB KUBECONFIG=$KC pvc-tool.sh test $PVC 1Gi default"
echo "\$ ssh admin@$(mgmt $NODE) sudo $CMD" | tee -a "$R"
H $NODE "$CMD" | tee -a "$R" | tee "$OUT/pvc-tool-output.txt" >/dev/null

sec "3. Firewall policy check from $NODE: only tcp/443 to $FB is allowed fabric -> oob (everything else must be DROPPED, i.e. time out, not be refused)"
run "allowed: tcp/443 (API version call)" H $NODE "curl -sk -m 8 -o /dev/null -w \"https://$FB:443 -> http=%{http_code} time=%{time_total}s rc=ok\n\" https://$FB/api/api_version || echo \"rc=\$? (unexpected)\""
run "not allowed: tcp/8443 (a closed port would answer RST at once if it reached the storage node; a firewall drop times out: curl rc=28)" H $NODE "curl -sk -m 6 -o /dev/null https://$FB:8443/; echo \"curl rc=\$?\""
run "not allowed: ICMP" H $NODE "ping -c 3 -W 2 -q $FB | tail -2 | head -1"
if [ "$MULTI" = 1 ]; then run "control: bastion (VLAN 300) -> storage management tcp/22 is allowed (rule bastion-to-stor-mgmt)" X bastion "timeout 6 bash -c 'echo > /dev/tcp/$FB/22' 2>/dev/null && echo 'tcp/22 open' || echo 'tcp/22 blocked'"
else run "control: enterprise -> oob is allowed for any service (pc-1 ping $FB)" X pc-1 "ping -c 3 -W 2 -q $FB | tail -2 | head -1"; fi
sleep 4; for p in $PIDS; do kill -INT $p 2>/dev/null; done; sleep 3
for n in $NODE storage; do H $n "pkill -INT -x tcpdump; sleep 1; chmod 644 /tmp/pvc-trace-$n.pcap" >/dev/null 2>&1; scp -q $SSHO "admin@$(mgmt "$n")":/tmp/pvc-trace-$n.pcap "$OUT/captures/0-guest-$n.pcap" 2>/dev/null; done
for f in "$OUT"/captures/*.pcap; do n=$(basename "$f" .pcap)
  # tcpdump decodes VXLAN, so matching the decoded text finds the flow by its INNER header on the fabric links too
  { echo "# $n: $(tcpdump -r "$f" -nn 2>/dev/null | wc -l) frames captured, $(tcpdump -r "$f" -nn 2>/dev/null | grep -c "$FB\.443") carrying $NODE_IP <-> $FB:443$(case $n in 2-*) echo " (inside VXLAN)";; esac)"
    echo "\$ tcpdump -r captures/$n.pcap -nn -e -v   # first SYN of the flow"
    tcpdump -r "$f" -nn -e -v 2>/dev/null | grep -B3 -m1 "$FB\.443: Flags \[S\]" | cut -c1-200; } > "$OUT/captures/$n.txt"; done
run "frames per capture point (which leaf, which border leaf and which firewall port carried the flow)" bash -c "for f in $OUT/captures/*.txt; do head -1 \$f; done"
run "VXLAN leg: the flow inside L3 VNI $L3VNI between the server leaf and a border leaf" bash -c "for f in $OUT/captures/2-*.txt; do grep -q 'Flags' \$f && { tail -n +3 \$f; break; }; done"
run "firewall ingress (from the border leaf): first SYN" bash -c "for f in $OUT/captures/3-fw-in-border*.txt; do grep -q 'Flags' \$f && { tail -n 2 \$f; break; }; done"
if [ "$MULTI" = 1 ]; then run "firewall egress (sub-interface .$SMTAG, zone stor-mgmt): first SYN -- same source address (no NAT), TTL one lower" bash -c "for f in $OUT/captures/3-fw-in-border*.pcap; do tcpdump -r \$f -nn -e -v 'vlan $SMTAG and host $FB and tcp port 443' 2>/dev/null | grep -B1 -m1 'Flags \[S\]'; done | head -4"
else run "firewall egress (towards oob-sw): first SYN -- same source address (no NAT), TTL one lower" bash -c "tail -n 2 $OUT/captures/4-fw-out-oob.txt"; fi
if [ -n "${FW_PASS:-}" ]; then run "PAN-OS sessions sampled during the call" cat "$OUT/raw/fw-sessions-during.txt"; else run "PAN-OS session table / traffic log" echo "(skipped: export FW_PASS=<firewall admin password> before running to include it)"; fi

sec "4. Storage node: management API log (client address = the node's FABRIC address $NODE_IP, not its BMC address)"
run "flashblade-api journal" H storage "journalctl -u flashblade-api --no-pager --since -4min | grep -E client= | tail -8"

sec "5. Kubernetes: what the API created (events of the PVC and the Longhorn volume)"
run "PVC events (provisioning)" K "kubectl -n default get events --field-selector involvedObject.name=$PVC -o custom-columns=TIME:.lastTimestamp,REASON:.reason,MSG:.message 2>/dev/null | head -12"
run "Longhorn volume events" K "kubectl -n longhorn-system get events --sort-by=.lastTimestamp -o custom-columns=TIME:.lastTimestamp,OBJ:.involvedObject.name,REASON:.reason,MSG:.message 2>/dev/null | grep -iE 'pvc-|volume' | tail -8"
run "state after the tool's cleanup (PVC deleted through the API)" K "kubectl -n default get pvc $PVC 2>&1 | tail -1; kubectl get pv 2>/dev/null | grep -c $PVC"

# ---- verdict: the trace is also a test. Every expectation of the path is asserted from the recorded evidence.
cnt()  { tcpdump -r "$OUT/captures/$1.pcap" -nn 2>/dev/null | grep -cE "$2"; }                                   # capture, regex on the decoded text (sees the inner header of VXLAN frames)
cnts() { local re=$1 t=0 k; shift; for k in "$@"; do t=$((t + $(cnt "$k" "$re"))); done; echo $t; }
SYN="IP $NODE_IP\.[0-9]+ > $FB\.443: Flags \[S\]"; SYN8="IP $NODE_IP\.[0-9]+ > $FB\.8443: Flags \[S\]"; PING="IP $NODE_IP > $FB: ICMP echo request"
# the SAME connection on both sides of the firewall: first SYN leaving towards the OOB network, then the SYN with that source port on the fabric side
SYNF="tcp[tcpflags] & (tcp-syn|tcp-ack) == tcp-syn and src host $NODE_IP and dst host $FB and dst port 443"
if [ "$MULTI" = 1 ]; then   # ingress = tag $DTAG on the firewall ports, egress = the same ports with tag $SMTAG (libpcap: `vlan` shifts the offsets of what FOLLOWS it)
  FOUT=$(for b in 1 2; do tcpdump -r "$OUT/captures/3-fw-in-border$b.pcap" -nn -v "vlan $SMTAG and $SYNF" 2>/dev/null | head -2 | paste -sd' '; echo; done | grep -m1 Flags)
  SPORT=$(echo "$FOUT" | grep -oE "$NODE_IP\.[0-9]+ >" | head -1 | grep -oE "\.[0-9]+ >" | tr -d '. >')
  FIN=$(for b in 1 2; do tcpdump -r "$OUT/captures/3-fw-in-border$b.pcap" -nn -v "vlan $DTAG and $SYNF and src port ${SPORT:-1}" 2>/dev/null | head -2 | paste -sd' '; echo; done | grep -m1 Flags)
  cntv() { tcpdump -r "$OUT/captures/$1.pcap" -nn $3 2>/dev/null | grep -cE "$2"; }   # $3 = pcap filter (which tag). No -e: with it tcpdump prints "ethertype IPv4 (0x0800), a > b" instead of "IP a > b"
  cntsv() { local re=$1 f=$2 t=0 k; shift 2; for k in "$@"; do t=$((t + $(cntv "$k" "$re" "$f"))); done; echo $t; }
else
FOUT=$(tcpdump -r "$OUT/captures/4-fw-out-oob.pcap" -nn -v "$SYNF" 2>/dev/null | head -2 | paste -sd' '); SPORT=$(echo "$FOUT" | grep -oE "$NODE_IP\.[0-9]+ >" | head -1 | grep -oE "\.[0-9]+ >" | tr -d '. >')
FIN=$(for b in 1 2; do tcpdump -r "$OUT/captures/3-fw-in-border$b.pcap" -nn -v "$SYNF and src port ${SPORT:-1}" 2>/dev/null | head -2 | paste -sd' '; echo; done | grep -m1 Flags)
fi
fld() { echo "$1" | grep -oE "$2 [0-9]+" | head -1 | cut -d' ' -f2; }; flow() { echo "$1" | grep -oE "$NODE_IP\.[0-9]+ > $FB\.443" | head -1; }
PT="$OUT/pvc-tool-output.txt"; sect() { sed -n "/^---- $1/,/^----/p" "$R" | sed '1d;$d'; }
{ printf "\n== Verdict (PVC through the storage management API, from %s %s)\n" "$NODE" "$NODE_IP"
  chk "$NODE routes $FB through the fabric gateway on bond0 (not through its own BMC NIC)" "via 10.1.1.1 dev bond0" "$(grep -m1 -oE "via 10\.1\.1\.1 dev bond0" "$PT")"
  chk "storage API answered the create call: HTTP 201" "http=201" "$(grep -m1 -oE "http=201" "$PT")"
  chk "PVC $PVC reached state Bound (Longhorn provisioned the volume)" '"state": "Bound"' "$(grep -m1 -oE '"state": "Bound"' "$PT")"
  chk "the API saw the request come from the node's FABRIC address" "\"requested_from\": \"$NODE_IP\"" "$(grep -m1 -oE "\"requested_from\": \"[0-9.]+\"" "$PT")"
  chk "a pod mounted the volume and wrote to it (data path)" "pod phase: Succeeded" "$(grep -m1 -oE "pod phase: Succeeded" "$PT")"
  ge  "the file written through the volume was read back" 1 "$(grep -c "written-by-$NODE" "$PT")"
  ge  "cleanup: PVC deleted through the API" 1 "$(grep -c "deleted from default namespace" "$PT")"
  chk "cleanup: no PVC / PV left behind" 0 "$(K "kubectl -n default get pvc $PVC --no-headers 2>/dev/null | wc -l; kubectl get pv --no-headers 2>/dev/null | grep -c $PVC" | paste -sd+ | bc)"
  ge  "hop 1: $NODE > $L1/$L2 port $PORT ($MH_KIND)" 1 "$(cnts "$SYN" 1-$L1-$NODE 1-$L2-$NODE)"
  ge  "hop 2: server leaf > border leaf inside VXLAN" 1 "$(cnts "$SYN" 2-border1-spine1 2-border1-spine2 2-border2-spine1 2-border2-spine2)"
  ge  "hop 2: that VXLAN leg uses L3 VNI $L3VNI (vrf k8s, type-5 default from the firewall)" 1 "$(cat "$OUT"/captures/2-*.txt | grep -cw "vni $L3VNI")"
  if [ "$MULTI" = 1 ]; then
  ge  "hop 3: border leaf (VRF k8s) > firewall ethernet1/1.$DTAG or 1/2.$DTAG (zone $FZ)" 1 "$(cntsv "$SYN" "vlan $DTAG" 3-fw-in-border1 3-fw-in-border2)"
  ge  "hop 4: firewall > sub-interface .$SMTAG (zone stor-mgmt) > border leaf (VRF stor-mgmt)" 1 "$(cntsv "$SYN" "vlan $SMTAG" 3-fw-in-border1 3-fw-in-border2)"
  ge  "hop 5: border leaf > control leaf inside VXLAN L3 VNI $SMVNI (VRF stor-mgmt)" 1 "$(for f in "$OUT"/captures/2-*.pcap; do tcpdump -r "$f" -nn 2>/dev/null; done | grep -A1 "vni $SMVNI" | grep -cE "$SYN")"
  ge  "hop 6: $CL1/$CL2 Eth1/$SMPORT (VLAN $SMTAG, FM1 / FM2 link) > storage node" 1 "$(cnts "$SYN" 5-$CL1-fm1 5-$CL2-fm2)"
  ge  "hop 7: arrives on the storage node's management VIP $FB" 1 "$(cnt 0-guest-storage "$SYN")"
  else
  ge  "hop 3: border leaf > firewall ethernet1/1 or 1/2 (zone $FZ)" 1 "$(cnts "$SYN" 3-fw-in-border1 3-fw-in-border2)"
  ge  "hop 4: firewall ethernet1/3 (zone oob) > oob-sw" 1 "$(cnt 4-fw-out-oob "$SYN")"
  ge  "hop 5: oob-sw port $OOBFW > port $OOBST > storage node" 1 "$(( $(cnt 5-oobsw-from-fw "$SYN") * $(cnt 5-oobsw-to-storage "$SYN") ))"
  ge  "hop 6: arrives on the storage node's OOB NIC" 1 "$(cnt 0-guest-storage "$SYN")"
  fi
  chk "firewall does NOT NAT the flow: same client address:port on both sides" "$(flow "$FIN")" "$(flow "$FOUT")"
  chk "it is the same packet on both sides of the firewall (IP id)" "$(fld "$FIN" id)" "$(fld "$FOUT" id)"
  chk "the firewall is a routed hop: TTL one lower on the way out" "$(( $(fld "$FIN" ttl) - 1 ))" "$(fld "$FOUT" ttl)"
  chk "policy +: tcp/443 to the storage API is allowed (rule $RSM)" "http=200" "$(grep -m1 -oE "https://$FB:443 -> http=200" "$R" | grep -oE "http=200")"
  chk "policy -: tcp/8443 times out (curl rc=28 = dropped, a closed port would have been refused)" "curl rc=28" "$(grep -m1 -oE "curl rc=[0-9]+" "$R")"
  if [ "$MULTI" = 1 ]; then
  ge  "policy -: the tcp/8443 SYNs DID reach the firewall" 1 "$(cntsv "$SYN8" "vlan $DTAG" 3-fw-in-border1 3-fw-in-border2)"
  chk "policy -: and none left it towards VLAN $SMTAG" 0 "$(cntsv "$SYN8" "vlan $SMTAG" 3-fw-in-border1 3-fw-in-border2)"
  ge  "policy -: ICMP from the node reached the firewall" 1 "$(cntsv "$PING" "vlan $DTAG" 3-fw-in-border1 3-fw-in-border2)"
  chk "policy -: and none left it towards VLAN $SMTAG" 0 "$(cntsv "$PING" "vlan $SMTAG" 3-fw-in-border1 3-fw-in-border2)"
  chk "control: bastion > storage management tcp/22 is allowed, so the drops above are policy, not a broken path" "tcp/22 open" "$(grep -A3 "^---- control: bastion" "$R" | grep -m1 -xE "tcp/22 (open|blocked)")"   # the RESULT line (the echoed command contains both words)
  else
  ge  "policy -: the tcp/8443 SYNs DID reach the firewall" 1 "$(cnts "$SYN8" 3-fw-in-border1 3-fw-in-border2)"
  chk "policy -: and none left it towards the OOB network" 0 "$(cnt 4-fw-out-oob "$SYN8")"
  ge  "policy -: ICMP from the node reached the firewall" 1 "$(cnts "$PING" 3-fw-in-border1 3-fw-in-border2)"
  chk "policy -: and none left it towards the OOB network" 0 "$(cnt 4-fw-out-oob "$PING")"
  ge  "control: enterprise > oob is allowed (pc-1 pings $FB), so the drops above are policy, not a broken path" 2 "$(grep -A3 "^---- control: enterprise" "$R" | grep -oE "[0-9]+ received" | cut -d' ' -f1)"
  fi
  ge  "storage API log records client=$NODE_IP for the create call" 1 "$(grep -cE "client=$NODE_IP \"POST /api/2.4/file-systems\?names=$PVC" "$R")"
  summary; } > "$OUT/verdict.txt"; RC=$?; cat "$OUT/verdict.txt" | tee -a "$R"

{ echo "# ai-fabric storage-API PVC trace, $TS"; echo
echo "Flow: \`pvc-tool.sh\` on **$NODE** ($NODE_IP) -> POST https://$FB/api/2.4/file-systems (FlashBlade-style management API on the storage node's management address) -> Longhorn PVC \`$PVC\` -> a pod writes to it -> DELETE through the API."; echo
echo "1. Routing on the node: \`ip route get $FB\` resolves via the anycast gateway 10.1.1.1 on bond0. The node's own BMC NIC is not a path to the OOB subnet (its connected route lives only in table 100, for BMC-sourced traffic)."
echo "2. $L1/$L2 (vrf k8s) route $FB via the type-5 default learned by eBGP from the firewall through fe-border1/2; VXLAN L3 VNI $L3VNI to a border leaf (captures 1-*, 2-*)."
if [ "$MULTI" = 1 ]; then
echo "3. Border leaf (VRF k8s) -> firewall ethernet1/1.$DTAG or 1/2.$DTAG (captures 3-*, tag $DTAG): zone $FZ -> zone stor-mgmt, rule **$RSM** (src 10.1.1.0/24, dst $FB, tcp/443), no NAT. Section 3: tcp/443 answers, tcp/8443 and ICMP time out."
echo "4. Firewall ethernet1/1.$SMTAG or 1/2.$SMTAG (the same ports, tag $SMTAG) -> border leaf (VRF stor-mgmt) -> VXLAN L3 VNI $SMVNI -> $CL1/$CL2 Eth1/$SMPORT (VLAN $SMTAG, FM1 / FM2) -> storage node VIP $FB (captures 3-*, 2-*, 5-*, 0-guest-storage)."
else
echo "3. Border leaf -> firewall ethernet1/1 or 1/2 (captures 3-*): zone $FZ -> zone oob, rule **$RSM** (src 10.1.1.0/24, dst $FB, tcp/443), no NAT. Section 3: tcp/443 answers, tcp/8443 and ICMP time out."
echo "4. Firewall ethernet1/3 -> oob-sw port $OOBFW -> port $OOBST -> storage node eth9 $FB (captures 4-*, 5-*, 0-guest-storage)."
fi
echo "5. The storage API logs the client as $NODE_IP (section 4), creates the PVC and waits for Bound; Longhorn provisions the volume (section 5). The pod's write proves the data path; DELETE through the API removes it."
echo; echo "## Verdict"; echo '```'; cat "$OUT/verdict.txt"; echo '```'
echo; echo "## pvc-tool.sh output"; echo '```'; echo "\$ sudo $CMD   # on $NODE"; cat "$OUT/pvc-tool-output.txt"; echo '```'
echo; echo "## Firewall evidence"; echo '```'; sed -n '/^################ 3\. Firewall/,/^################ 4\. Storage/p' "$R" | grep -vE '^################' | head -60; echo '```'
echo; echo "## Storage API log"; echo '```'; sed -n '/^################ 4\. Storage/,/^################ 5\. Kubernetes/p' "$R" | grep -vE '^################' | head -20; echo '```'
echo; echo "## Kubernetes events"; echo '```'; sed -n '/^################ 5\. Kubernetes/,$p' "$R" | grep -vE '^################' | head -40; echo '```'
echo; echo "## Captures"; echo; for f in "$OUT"/captures/*.txt; do echo "### $(basename "$f" .txt)"; echo '```'; head -10 "$f"; echo '```'; done
echo; echo "Every command with its raw output, as typed on the devices: raw/commands.txt. Full command outputs: raw/trace.txt. Packet files: captures/*.pcap."; } > "$OUT/TRACE.md"
keep_latest ai-fabric_pvc_trace_$CLS "$OUT"
echo; echo "pvc trace -> $OUT"; exit $RC
