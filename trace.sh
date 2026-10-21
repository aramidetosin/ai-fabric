#!/bin/bash
# trace.sh [outdir]: end-to-end trace of ai-fabric from three clients to the inference endpoint (adapted from <reference-platform>/trace.sh):
#   pc-1 / pc-2      enterprise side of the firewall (zone enterprise, rule enterprise-to-fabric; enterprise-to-data on site-a-nx)
#   office LAN       site-a's own 10.80.15.10 -> firewall OUTSIDE address 10.80.15.121 (zone internet, rules internet-to-inside-vips +
#                    dnat-gateway-vip) -- the path the office workstations use
# Every control-plane lookup on the way (raw/trace.txt), captures at each hop (captures/*.pcap + decoded .txt), the recorded curls, TRACE.md.
# Since 2026-10-04 the gateway has a model served from the lab's own GPU nodes (inference-local-model.sh). When it is there, the trace sends the
# WORKING request by default: a chat completion for that model, answered HTTP 200 by Gateway VIP -> Envoy -> APISIX -> LiteLLM -> EAST-WEST to a
# replica on a GPU node -> its RPC workers over a rail, and back; the east-west leg and the rails are captured too. The bearer key is read from
# the cluster on the fly, handed to curl in a header file (never on a command line) and replaced by <redacted> in everything this script writes.
# RUN_INFERENCE=0: the old probe without a credential (GET .../proxy/v1/models -> HTTP 401 from LiteLLM, which proves the chain up to LiteLLM).
# Without the local model: RUN_INFERENCE=1 (operator) sends the completion to an external-provider model. PAN-OS session lookups need FW_PASS.
set -u
cd "$(dirname "$0")"; . ./lib.sh
read -r FZ RUE DTAG DV DNSN <<< "$(python3 -c 'import gen; print(gen.FZ, gen.fw_rule("enterprise-to-fabric"), gen.ZONE[gen.VRF]["tag"] or "-", gen.FE_VLAN, gen.DNS_NTP or gen.BASTION_IP)')"
L3VNI=$(l3vni); MH_KIND=$([ "$FE_NOS" = nxos ] && echo vPC || echo ESI-LAG)     # per profile: Nexus = L3 VNI 11000 + vPC, else 1000 + ESI-LAG
TS=$(date -u +%Y%m%d_%H%M%S); OUT=${1:-audits/ai-fabric_e2e_trace_$TS}; mkdir -p "$OUT/raw" "$OUT/captures" "$OUT/curl"
VIP=$(gw_vip); FWOUT=$(fw_out); LANSRC=$(lan_src); DOMAIN=lab.ai; HOST="inference.platform.$DOMAIN"; UUID=565df347-26cb-598a-b838-b7e9531f00fa; MODEL=${WEBUI_MODEL:-qwen2.5-0.5b-instruct}
R="$OUT/raw/trace.txt"; : > "$R"
export EVID="$PWD/$OUT/raw/commands.txt"; : > "$EVID"     # full transcript: prompt + command + raw output of everything this script runs on a device
sec() { { echo; echo "################ $*"; } | tee -a "$R"; }
run() { # title, command...: shows the device prompt + the exact command + the raw output (the transcript the helpers in lib.sh record);
  local title=$1; shift; local m t; m=$(wc -c < "$EVID"); t=$(mktemp)   # a command that does not go through a helper is shown as "$ command"
  { echo; echo "---- $title"; "$@" > "$t" 2>&1; if [ "$(wc -c < "$EVID")" -gt "$m" ]; then tail -c +$((m + 1)) "$EVID" | cat -s; else echo "\$ $*"; cat "$t"; fi; rm -f "$t"; } | tee -a "$R"; }
redact() { sed -E 's/(Bearer )[A-Za-z0-9_.-]+/\1<redacted>/g; s/sk-[A-Za-z0-9_-]{8,}/<redacted>/g'; }

sec "0. Who answers the Gateway VIP $VIP (Cilium L2 announcement) and where the inference pods run"
run "l2announce lease (holder = the node that answers ARP for the VIP)" K "kubectl -n kube-system get lease | grep -i l2announce"
VNODE=$(K "kubectl -n kube-system get lease -o jsonpath='{range .items[*]}{.metadata.name} {.spec.holderIdentity}{\"\\n\"}{end}' | awk '/l2announce.*gateway/ {print \$2; exit}'")
[ -n "$VNODE" ] || { echo "no L2 announcement lease found"; exit 1; }
read -r L1 L2 PORT <<< "$(leafport "$VNODE")"; [ -n "$PORT" ] || { echo "cannot map $VNODE to a leaf pair"; exit 1; }
VMAC=$(H $VNODE "cat /sys/class/net/bond0/address")
# Cilium L2 announcement, the way an operator checks it by hand (each command is recorded with its prompt and raw output)
LEASE=cilium-l2announce-gateway-cilium-gateway-gateway
run "Cilium: L2 announcements enabled (and no BGP control plane: the VIP is announced by ARP on bond0)" K "kubectl -n kube-system get cm cilium-config -o yaml | grep -E 'enable-l2-announcements|enable-bgp-control-plane'"
run "Cilium: L2 announcement policies" K "kubectl get ciliuml2announcementpolicies"
run "Cilium: the lease of the Gateway VIP (HOLDER = the node answering ARP for $VIP)" K "kubectl -n kube-system get lease $LEASE"
run "Kubernetes: control-plane nodes (the VIP holder comes from the control class, see roles.sh)" K "kubectl get nodes -l node-role.kubernetes.io/control-plane; kubectl get nodes -l node-role.ai-fabric.lab/control=true --no-headers | awk '{print \$1, \$3}' | tr '\n' ';'"
CPOD="\$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=$VNODE -o name)"
run "Cilium agent on $VNODE: L2 announce table (VIP -> interface)" K "kubectl -n kube-system exec $CPOD -- cilium-dbg shell -- db/show l2-announce"
run "Cilium agent on $VNODE: devices (bond0 must be Selected)" K "kubectl -n kube-system exec $CPOD -- cilium-dbg shell -- db/show devices"
run "Cilium agent on $VNODE: eBPF L2 responder map (key = the VIP in hex + ifindex)" K "kubectl -n kube-system exec $CPOD -- bpftool map dump pinned /sys/fs/bpf/tc/globals/cilium_l2_responder_v4"
run "gateway + inference route + backends" K "kubectl -n gateway get gateway -o wide; kubectl -n inference get httproute,svc,pods -o wide | cut -c1-150"
INF=$(K "kubectl get ns inference >/dev/null 2>&1 && echo yes" | grep -c yes)     # the inference gateway is an operator step; without it the trace targets the demo app
if [ "$INF" = 1 ]; then
  read -r APISIX_IP APISIX_NODE <<< "$(K "kubectl -n inference get pod -l app=apisix -o jsonpath='{.items[0].status.podIP} {.items[0].spec.nodeName}'")"
  read -r LITELLM_IP LITELLM_NODE <<< "$(K "kubectl -n inference get pod -l app=litellm -o jsonpath='{.items[0].status.podIP} {.items[0].spec.nodeName}'")"
else HOST="demo.platform.$DOMAIN"; read -r APISIX_IP APISIX_NODE <<< "$(K "kubectl -n demo get pod -o jsonpath='{.items[0].status.podIP} {.items[0].spec.nodeName}' 2>/dev/null")"; LITELLM_IP=$APISIX_IP; LITELLM_NODE=$APISIX_NODE
  DEMO_RE=$(K "kubectl -n demo get pod -o jsonpath='{range .items[*]}{.status.podIP}{\"\\n\"}{end}'" | grep -E '^[0-9.]+$' | sed 's/\./\\./g' | paste -sd'|')     # Envoy balances over every replica
  echo "inference gateway not deployed (operator step): tracing https://$HOST/ instead; demo replicas: $(echo "$DEMO_RE" | tr -d '\\' | tr '|' ' ')" | tee -a "$R"; fi
LOCAL=0; LNAME="Qwen/Qwen2.5-0.5B-Instruct"      # the gateway's model that is served from the GPU nodes (inference-local-model.sh)
if [ "$INF" = 1 ] && K "kubectl -n inference get cm litellm-config -o jsonpath='{.data.config\.yaml}'" | grep -q "llm.ai-sim.svc" && [ "$(K "kubectl -n ai-sim get endpoints llm -o jsonpath='{.subsets[*].addresses[*].ip}'" | wc -w)" -ge 1 ]; then
  LOCAL=1; [ "${RUN_INFERENCE:-}" = 0 ] || RUN_INFERENCE=1; MODEL=$LNAME; UUID=$(python3 -c 'import uuid, sys; print(uuid.uuid5(uuid.NAMESPACE_URL, "https://ai-fabric.lab/models/" + sys.argv[1]))' "$LNAME")
  nip() { python3 -c "import gen, sys; print(gen.HOSTS[sys.argv[1]]['ip'])" "$1"; }; hx() { printf '0x%02x%02x%02x%02x' $(echo "$1" | tr . ' '); }
  SRV=$(K "kubectl -n ai-sim get pods -l app=llm -o jsonpath='{range .items[*]}{.metadata.name} {.spec.nodeName} {.status.podIP} {.metadata.annotations.k8s\.v1\.cni\.cncf\.io/networks}{\"\n\"}{end}'" | grep -E '^llm-')      # name node podIP rail-network
  MNIP=$(nip "$LITELLM_NODE"); read -r ML1 ML2 MPORT <<< "$(leafport "$LITELLM_NODE")"; SNIPS=$(while read -r _ n _ _; do nip "$n"; done <<< "$SRV" | xargs); SPODS=$(awk '{print $3}' <<< "$SRV" | paste -sd'|' | sed 's/\./\\./g')
  echo "local model $LNAME: LiteLLM on $LITELLM_NODE ($MNIP) -> Service llm (ai-sim) -> $(awk '{printf "%s on %s (pod %s, %s)  ", $1, $2, $3, $4}' <<< "$SRV")" | tee -a "$R"; fi
echo "VIP $VIP is announced by $VNODE (bond0 $VMAC, $MH_KIND on $L1/$L2 port $PORT). Path inside the cluster: Envoy on $VNODE -> APISIX $APISIX_IP on $APISIX_NODE -> LiteLLM $LITELLM_IP on $LITELLM_NODE" | tee -a "$R"

declare -A CAP
CAP[1-pc1-access]="pc-1 eth1"; CAP[1-pc2-access]="pc-2 eth1"; CAP[2-fw-in-enterprise-pc1]="fw eth4"; CAP[2-fw-in-enterprise-pc2]="fw eth6"; CAP[2-fw-in-officeLAN]="fw eth5"
CAP[3-fw-out-border1]="fw eth1"; CAP[3-fw-out-border2]="fw eth2"
for b in 1 2; do for s in 1 2; do CAP[4-border$b-spine$s]="fe-border$b eth$s"; done; done
CAP[5-$L1-to-$VNODE]="$L1 eth$PORT"; CAP[5-$L2-to-$VNODE]="$L2 eth$PORT"
FILT="(tcp port 443 and (host $VIP or host $FWOUT)) or udp port 4789"; FILT="$FILT or (vlan and ($FILT))"   # + 802.1Q frames (fw ethernet1/1.100, tagged host ports); `vlan` last: it shifts the offsets of what follows
sec "1. Capture points (container:interface, tcpdump in the container's network namespace; ethN = switch port swpN / firewall ethernet1/N)"
PIDS=""; for k in $(printf '%s\n' "${!CAP[@]}" | sort); do set -- ${CAP[$k]}; pid=$(docker inspect -f '{{.State.Pid}}' "$LAB-$1" 2>/dev/null); [ -n "$pid" ] || continue; echo "  $k: $1 $2" | tee -a "$R"
  timeout 120 nsenter -t "$pid" -n tcpdump -i "$2" -nn -s 256 -w "$OUT/captures/$k.pcap" "$FILT" >/dev/null 2>&1 & PIDS="$PIDS $!"; done
for n in $(printf '%s\n' $VNODE $APISIX_NODE $LITELLM_NODE | sort -u); do NF="host $VIP or host $APISIX_IP or host $LITELLM_IP or udp port 6081"; [ "$INF" = 1 ] || NF="host $VIP or net 10.42.0.0/16 or udp port 6081"
  echo "  6-node-$n: guest, all interfaces (bond0 + pod veths + geneve)" | tee -a "$R"
  ssh -n $SSHO "admin@$(mgmt "$n")" "sudo rm -f /tmp/trace-$n.pcap; sudo timeout 120 tcpdump -i any -nn -s 256 -w /tmp/trace-$n.pcap '$NF' >/dev/null 2>&1; sudo chmod 644 /tmp/trace-$n.pcap" & PIDS="$PIDS $!"; done
if [ "$LOCAL" = 1 ] && [ "${RUN_INFERENCE:-0}" = 1 ]; then      # the east-west leg LiteLLM -> a replica on a GPU node, and the replicas' rails
  # pod traffic between nodes = Geneve (udp 6081) between the NODE addresses; between two leaf pairs that tunnel rides VXLAN in the L2 VNI (inner IP header
  # 64 bytes into the frame: its addresses at +12 / +16, the Geneve port at +22)
  ecap() { local pid; pid=$(docker inspect -f '{{.State.Pid}}' "$LAB-$2" 2>/dev/null); [ -n "$pid" ] || return 0; echo "  $1: $2 $3" | tee -a "$R"
    timeout 120 nsenter -t "$pid" -n tcpdump -i "$3" -nn -s 200 -c 3000 -w "$OUT/captures/$1.pcap" "$4" >/dev/null 2>&1 & PIDS="$PIDS $!"; }
  EWH=$(for a in $SNIPS; do printf 'host %s or ' $a; done | sed 's/ or $//'); EW="udp port 6081 and host $MNIP and ($EWH)"; EW="($EW) or (vlan and ($EW))"
  EWS=$(for a in $SNIPS; do printf 'ether[80:4] = %s or ' $(hx $a); done | sed 's/ or $//'); EWB=$(for a in $SNIPS; do printf 'ether[76:4] = %s or ' $(hx $a); done | sed 's/ or $//')
  EWX="udp port 4789 and ether[86:2] = 6081 and ((ether[76:4] = $(hx $MNIP) and ($EWS)) or (ether[80:4] = $(hx $MNIP) and ($EWB)))"
  for l in $ML1 $ML2; do ecap "7-$l-eth$MPORT-$LITELLM_NODE-east-west" "$l" "eth$MPORT" "$EW"; for u in 1 2; do ecap "8-$l-uplink$u-to-fe-spine$u-east-west" "$l" "eth$u" "$EWX"; done; done
  while read -r pn n _ net; do read -r g1 g2 gp <<< "$(leafport "$n")"; for l in $g1 $g2; do ecap "9-$l-eth$gp-$n-east-west" "$l" "eth$gp" "$EW"; done
    r=$(( ${net##*-} + 1 )); ecap "10-be-leaf$r-eth$((4 + ${n#gpu}))-$n-$pn-rpc-rail$r" "be-leaf$r" "eth$((4 + ${n#gpu}))" "tcp port 50052"; done <<< "$SRV"; fi
sleep 3

URLP="/models/$UUID/proxy/v1/models"; [ "$INF" = 1 ] || URLP="/"; KEYCMD="kubectl -n inference get secret litellm-secret -o jsonpath={.data.master-key} | base64 -d"
record() { # client label, how to run, resolve-to address
  local c=$1 runner=$2 to=$3 f="$OUT/curl/$1.txt" cmd
  if [ "${RUN_INFERENCE:-0}" = 1 ]; then      # the key goes into a header file on the client (mode 600, removed after the request), never onto a command line
    if [ "$c" = office-lan ]; then HF=$(mktemp); chmod 600 "$HF"; else HF=/tmp/.gw-h; fi
    printf 'Authorization: Bearer %s' "$(EVID= K "$KEYCMD")" | { if [ "$c" = office-lan ]; then cat > "$HF"; else docker exec -i "$LAB-$c" sh -c "umask 077; cat > $HF"; fi; }
    cmd="curl -sS -v --max-time 120 --resolve $HOST:443:$to -H @$HF -H 'Content-Type: application/json' -d '{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Name the capital of France in one word.\"}],\"max_tokens\":20,\"temperature\":0}' https://$HOST/models/$UUID/proxy/v1/chat/completions"
  else cmd="curl -sS -v --max-time 30 --resolve $HOST:443:$to https://$HOST$URLP"; fi
  [ "$c" = office-lan ] && cmd="${cmd/curl /curl --cacert $PWD/shared/ai-fabric/cluster-ca.crt }"   # site-a does not trust the lab CA system-wide; the PCs do
  { echo "# $c, executed $(date -u +%FT%TZ) -- name pinned to $to:"; echo "$cmd" | redact; echo; EVID= $runner "$cmd -w '\n--- http=%{http_code} dns=%{time_namelookup}s connect=%{time_connect}s tls=%{time_appconnect}s ttfb=%{time_starttransfer}s total=%{time_total}s tls_verify=%{ssl_verify_result}\n'" 2>&1 | redact | grep -v -E "^[{}] \[|bytes data\]"; } > "$f"
  if [ "${RUN_INFERENCE:-0}" = 1 ]; then if [ "$c" = office-lan ]; then rm -f "$HF"; else docker exec "$LAB-$c" rm -f "$HF"; fi; fi
  { echo; echo "---- request from $c (the redacted record; the transcript is off while a request with a key runs)"; cat "$f"; } >> "$EVID"
  tee -a "$R" < "$f" | grep -E "^# |< HTTP|--- http=|subject:|issuer:|SSL certificate verify" | cut -c1-200; }
sec "2. The requests (recorded verbatim in curl/, credentials redacted)"
for pc in pc-1 pc-2; do run "$pc: name resolution by the bastion BIND + forwarding decision" X $pc "dig +noall +answer $HOST @10.1.1.17 2>/dev/null || getent hosts $HOST; ip route get $VIP | head -1"; record $pc "X $pc" $VIP; sleep 1; done
run "office LAN client ($(hostname) $LANSRC): forwarding decision to the firewall outside address" bash -c "ip route get $FWOUT | head -1"
record office-lan "bash -c" $FWOUT
sleep 4; for p in $PIDS; do kill -INT $p 2>/dev/null; done; sleep 2
for n in $(printf '%s\n' $VNODE $APISIX_NODE $LITELLM_NODE | sort -u); do H $n "pkill -INT -x tcpdump; sleep 1; chmod 644 /tmp/trace-$n.pcap" >/dev/null 2>&1; scp -q $SSHO "admin@$(mgmt "$n")":/tmp/trace-$n.pcap "$OUT/captures/6-node-$n.pcap" 2>/dev/null; done
CL="pc-1=10.66.10.10 pc-2=10.66.20.10 office-lan=$LANSRC"
syn() { tcpdump -r "$OUT/captures/$1.pcap" -nn 2>/dev/null | grep -cE "IP $2\.[0-9]+ > $3\.443: Flags \[S\]"; }   # capture, client, destination: SYNs of that client (text match, so it also sees the INNER header of VXLAN frames)
syns() { local c=$1 d=$2 t=0 k; shift 2; for k in "$@"; do t=$((t + $(syn "$k" "$c" "$d"))); done; echo $t; }
for f in "$OUT"/captures/*.pcap; do n=$(basename "$f" .pcap); tot=$(tcpdump -r "$f" -nn 2>/dev/null | wc -l); line="# $n: $tot frames; SYNs per client:"
  for c in $CL; do line="$line ${c%%=*}=$(( $(syn "$n" "${c#*=}" "$VIP") + $(syn "$n" "${c#*=}" "$FWOUT") ))"; done
  { echo "$line$(case $n in 4-*) echo '  (inner header, inside VXLAN)';; esac)"; for c in $CL; do tcpdump -r "$f" -nn -e -v 2>/dev/null | grep -B3 -m1 -E "IP ${c#*=}\.[0-9]+ > ($VIP|$FWOUT)\.443: Flags \[S\]|^ +${c#*=}\.[0-9]+ > ($VIP|$FWOUT)\.443: Flags \[S\]" | cut -c1-210; done; } > "$OUT/captures/$n.txt"; done

sec "3. Frames per capture point (which firewall port, border leaf, spine link and server leaf carried the flows)"
for f in "$OUT"/captures/*.txt; do head -1 "$f"; done | tee -a "$R"
sec "4. Control plane along the path"
cp_borders() { for b in $FE_BORDERS; do echo "== $b"; fe_vrf_bgp $b | cut -c1-160; fe_vrf_route $b $VIP | cut -c1-160; done; }
cp_spines() { for s in $FE_SPINES; do echo "== $s"; fe_underlay $s; done; }
cp_leaves() { for l in $L1 $L2; do echo "== $l"; fe_mac $l $VMAC $VIP; done; }
run "firewall -> border leaves: eBGP in vrf k8s, what the fabric advertises to the firewall" cp_borders
run "border leaf: the VIP is a host route learned over EVPN (MAC $VMAC) via the server leaf pair, VXLAN L3 VNI $L3VNI" fe_host_route fe-border1 $VIP
run "spines: ECMP towards the server leaf pair's VTEPs" cp_spines
run "$L1/$L2: MAC of the VIP -> ES bond -> $VNODE" cp_leaves
run "$VNODE: VIP on bond0 via Cilium (service entry + L2 responder)" K "P=\$(kubectl -n kube-system get pods -l k8s-app=cilium --field-selector spec.nodeName=$VNODE -o name | head -1); kubectl -n kube-system exec \$P -c cilium-agent -- cilium service list 2>/dev/null | grep -E '$VIP:443' | head -3"
run "Hubble flows on $VNODE during the requests (identity-level view)" K "P=\$(kubectl -n kube-system get pods -l k8s-app=cilium --field-selector spec.nodeName=$VNODE -o name | head -1); kubectl -n kube-system exec \$P -c cilium-agent -- hubble observe --since 3m -o compact 2>/dev/null | grep -E 'inference|apisix|litellm' | tail -14 | cut -c1-200"
if [ -n "${FW_PASS:-}" ]; then FWM=$(mgmt fw); key=$(curl -sk --max-time 20 "https://$FWM/api/?type=keygen&user=${FW_USER:-admin}" --data-urlencode "password=$FW_PASS" | sed -n 's|.*<key>\(.*\)</key>.*|\1|p')
  run "PAN-OS sessions to the VIP / DNAT address" bash -c "for d in $VIP $FWOUT; do curl -sk --max-time 30 'https://$FWM/api/' --data-urlencode type=op --data-urlencode 'key=$key' --data-urlencode \"cmd=<show><session><all><filter><destination>\$d</destination></filter></all></session></show>\" | grep -oE '<(source|dst|xsource|xdst|from|to|state|security-rule|nat)>[^<]*' | paste -sd' ' | cut -c1-400; done"
else run "PAN-OS session table" echo "(skipped: export FW_PASS before running to include it; the firewall is proven below by its own interfaces' captures)"; fi
sec "5. Captures (first SYN of each flow at every hop)"; for f in "$OUT"/captures/*.txt; do echo; cat "$f"; done >> "$R"

# ---- verdict: the trace is also a test. Every hop of the three paths is asserted from the captures.
EXP=$([ "${RUN_INFERENCE:-0}" = 1 ] && echo 200 || echo 401); [ "$INF" = 1 ] || EXP=200; BS="4-border1-spine1 4-border1-spine2 4-border2-spine1 4-border2-spine2"; LG="5-$L1-to-$VNODE 5-$L2-to-$VNODE"
{ printf "\n== Verdict (e2e trace, Gateway VIP on %s)\n" "$VNODE"
  VHEX=$(printf '%02x %02x %02x %02x' $(echo $VIP | tr . ' '))
  ge "Cilium on $VNODE announces $VIP on bond0 (db/show l2-announce)" 1 "$(grep -cE "^$VIP +bond0" "$R")"
  ge "the eBPF L2 responder on $VNODE holds the VIP ($VHEX)" 1 "$(grep -c "key: $VHEX" "$R")"
  for c in $CL; do n=${c%%=*}; a=${c#*=}; r=$(grep -h -- "--- http=" "$OUT/curl/$n.txt" | head -1)
    chk "$n ($a): HTTP $EXP from $HOST (the Gateway, its HTTPRoute and the backend answered)" "$EXP" "$(echo "$r" | sed -n 's/.*http=\([0-9]*\).*/\1/p')"
    chk "$n: TLS verified against the cluster CA (ssl_verify_result)" 0 "$(echo "$r" | sed -n 's/.*tls_verify=\([0-9]*\).*/\1/p')"; done
  ge "pc-1 enters the firewall on ethernet1/4 (zone enterprise)" 1 "$(syn 2-fw-in-enterprise-pc1 10.66.10.10 $VIP)"
  ge "pc-2 enters the firewall on ethernet1/6 (zone enterprise)" 1 "$(syn 2-fw-in-enterprise-pc2 10.66.20.10 $VIP)"
  ge "office LAN enters on ethernet1/5 (zone internet), addressed to the firewall OUTSIDE address $FWOUT" 1 "$(syn 2-fw-in-officeLAN $LANSRC $FWOUT)"
  ge "DNAT dnat-gateway-vip: that flow leaves towards the fabric addressed to $VIP, client address preserved" 1 "$(syns $LANSRC $VIP 3-fw-out-border1 3-fw-out-border2)"
  chk "DNAT: nothing addressed to $FWOUT leaks into the fabric" 0 "$(syns $LANSRC $FWOUT 3-fw-out-border1 3-fw-out-border2 $BS)"
  for c in $CL; do n=${c%%=*}; a=${c#*=}
    ge "$n: firewall > border leaf handoff (ethernet1/1 or 1/2)" 1 "$(syns $a $VIP 3-fw-out-border1 3-fw-out-border2)"
    ge "$n: border leaf > spine inside VXLAN" 1 "$(syns $a $VIP $BS)"
    ge "$n: $L1/$L2 > $VNODE over the $MH_KIND (port $PORT)" 1 "$(syns $a $VIP $LG)"
    ge "$n: arrives on $VNODE with the client address intact (no source NAT on the way in)" 1 "$(syn 6-node-$VNODE $a $VIP)"; done
  ge "fabric transport is VXLAN L3 VNI $L3VNI (symmetric IRB, vrf k8s)" 1 "$(cat "$OUT"/captures/4-*.txt | grep -cw "vni $L3VNI")"
  if [ "$INF" = 1 ]; then
    ge "Envoy > APISIX leg seen on $APISIX_NODE (pod $APISIX_IP:9080)" 1 "$(tcpdump -r "$OUT/captures/6-node-$APISIX_NODE.pcap" -nn 2>/dev/null | grep -c "$APISIX_IP\.9080")"
    ge "APISIX > LiteLLM leg seen on $LITELLM_NODE (pod $LITELLM_IP:4000)" 1 "$(tcpdump -r "$OUT/captures/6-node-$LITELLM_NODE.pcap" -nn 2>/dev/null | grep -c "$LITELLM_IP\.4000")"
    if [ "$LOCAL" = 1 ] && [ "${RUN_INFERENCE:-0}" = 1 ]; then
      fr() { local f="$OUT/captures/$1.pcap"; [ -s "$f" ] || { echo 0; return; }; tcpdump -r "$f" -nn "${2:-}" 2>/dev/null | wc -l; }; sm() { local t=0 n flt=$1; shift; for n in "$@"; do t=$((t + $(fr "$n" "$flt"))); done; echo $t; }
      P7=$(cd "$OUT/captures" && ls 7-*.pcap 2>/dev/null | sed 's/\.pcap$//' | xargs); P8=$(cd "$OUT/captures" && ls 8-*.pcap 2>/dev/null | sed 's/\.pcap$//' | xargs); P9=$(cd "$OUT/captures" && ls 9-*.pcap 2>/dev/null | sed 's/\.pcap$//' | xargs); P10=$(cd "$OUT/captures" && ls 10-*.pcap 2>/dev/null | sed 's/\.pcap$//' | xargs)
      for c in $CL; do n=${c%%=*}; ge "$n: the answer carries text generated by the model" 1 "$(grep -c '"content":"[^"]' "$OUT/curl/$n.txt")"; done
      ge "LiteLLM > the model, east-west: its requests left $LITELLM_NODE for the serving GPU nodes in Geneve ($MNIP > $SNIPS, udp 6081) on $ML1/$ML2 eth$MPORT" 6 "$(sm "src $MNIP or (vlan and src $MNIP)" $P7)"
      ge "east-west: the answers came back to $LITELLM_NODE the same way" 6 "$(sm "dst $MNIP or (vlan and dst $MNIP)" $P7)"
      ge "east-west: inside that tunnel are LiteLLM's connections to the replicas' pods (tcp 8080)" 6 "$(for n in $P7; do tcpdump -r "$OUT/captures/$n.pcap" -nn 2>/dev/null; done | grep -cE "($SPODS)\.8080[ :]")"
      ge "east-west: it crossed the spines inside VXLAN (the 4 uplinks of $ML1/$ML2, both directions)" 12 "$(sm "" $P8)"
      chk "east-west: one VXLAN segment carries it, the L2 VNI of the nodes' VLAN" "vni $(python3 -c 'import gen; print(gen.NX_L2VNI if gen.NXOS else gen.FE_VLAN)')" "$(for n in $P8; do tcpdump -r "$OUT/captures/$n.pcap" -nn 2>/dev/null | grep -oE "VXLAN, flags \[I\] \(0x08\), vni [0-9]+" | grep -oE "vni [0-9]+"; done | sort -u | xargs)"
      ge "east-west: it reached the serving GPU nodes on their leaf pairs' ports, and the answers left there" 6 "$(sm "" $P9)"
      ge "the replicas computed the answers on their RPC workers over their rails (tcp 50052 on the rail leaf ports during the requests)" 50 "$(sm "" $P10)"; fi
  elif [ -n "${DEMO_RE:-}" ]; then ge "Envoy on $VNODE opens connections to the demo replicas (inner header of the geneve tunnel when the pod is on another node)" 1 "$(tcpdump -r "$OUT/captures/6-node-$VNODE.pcap" -nn 2>/dev/null | grep -cE "> ($DEMO_RE)\.[0-9]+: Flags \[S\]")"; fi
  summary; } > "$OUT/verdict.txt"; RC=$?; cat "$OUT/verdict.txt" | tee -a "$R"
c1=$(grep -h -- "--- http=" "$OUT/curl/pc-1.txt" | head -1); c2=$(grep -h -- "--- http=" "$OUT/curl/pc-2.txt" | head -1); c3=$(grep -h -- "--- http=" "$OUT/curl/office-lan.txt" | head -1)
{ echo "# ai-fabric end-to-end trace, $TS"; echo
echo "Target: https://$HOST$URLP  (Gateway VIP $VIP, L2-announced by **$VNODE**, bond0 $VMAC). $([ "${RUN_INFERENCE:-0}" = 1 ] && echo "Real chat completion for model $MODEL$([ "$LOCAL" = 1 ] && echo ', which is served from the GPU nodes of this lab'), key redacted." || echo 'No credential sent: HTTP 401 is LiteLLM refusing the request, i.e. the chain answered up to LiteLLM.')"; echo
echo "| client | result |"; echo "|---|---|"; echo "| pc-1 (10.66.10.10, zone enterprise) | \`${c1#--- }\` |"; echo "| pc-2 (10.66.20.10, zone enterprise) | \`${c2#--- }\` |"; echo "| outside LAN ($LANSRC -> DNAT $FWOUT) | \`${c3#--- }\` |"; echo
echo "## Verdict"; echo '```'; cat "$OUT/verdict.txt"; echo '```'; echo
echo "## Path"; echo
if [ "$DNSN" = 10.1.1.17 ]; then echo "1. **DNS**: the bastion BIND (10.1.1.17) answers \`*.platform.$DOMAIN\` with the Gateway VIP $VIP. Office-LAN workstations use the same resolver through the firewall (rule internet-to-bastion-dns)."
else echo "1. **DNS**: the office DNS server $DNSN answers \`*.platform.$DOMAIN\` with the Gateway VIP $VIP (lab zones published by dns-b-zones.sh)."; fi
echo "2. **Firewall in**: pc-1/pc-2 enter on ethernet1/4 and 1/6 (zone enterprise, rule $RUE). Office-LAN clients enter on ethernet1/5 (zone internet): routed to $VIP (rule internet-to-inside-vips) or to the outside address $FWOUT:443, which **dnat-gateway-vip** translates to $VIP."
echo "3. **Firewall out -> border leaf** (ethernet1/1 or 1/2$([ "$DTAG" != - ] && echo ", sub-interface .$DTAG = tag $DTAG, zone $FZ"), /30 handoffs): the firewall learned 10.1.1.0/24 and the /32 host routes by eBGP (AS 65500 <-> 65104) in vrf k8s."
echo "4. **Border leaf -> server leaf pair**: $VIP/32 is an EVPN type-2 route; VXLAN with **L3 VNI $L3VNI** over the $([ "$FE_NOS" = nxos ] && echo 'OSPF-unnumbered' || echo 'eBGP-unnumbered') underlay, ECMP across fe-spine1/2 (captures 4-*: the flow is the INNER header)."
echo "5. **$L1/$L2 -> $VNODE**: decapsulate, look up $VMAC in VLAN $DV, forward on the $MH_KIND bond (port $PORT on both leaves; capture 5-* shows which leg)."
echo "6. **On $VNODE**: Cilium answers ARP for the VIP (L2 announcement); the Gateway's Envoy (host network) terminates TLS with the \`*.platform.$DOMAIN\` certificate of the cluster CA."
echo "7. **HTTPRoute inference -> APISIX** ($APISIX_IP on $APISIX_NODE, geneve between nodes when not local) **-> LiteLLM** ($LITELLM_IP on $LITELLM_NODE). LiteLLM validates the bearer key$(if [ "${RUN_INFERENCE:-0}" != 1 ]; then echo '; none was sent, hence 401'; elif [ "$LOCAL" = 1 ]; then echo " and hands the request to the model's Service llm (namespace ai-sim)"; else echo ' and calls OpenRouter: pod -> node SNAT -> anycast gateway -> border -> firewall source NAT -> internet'; fi)."
[ "$LOCAL" = 1 ] && [ "${RUN_INFERENCE:-0}" = 1 ] && { echo "8. **East-west to the model**: LiteLLM's connection to a replica pod ($(awk '{printf "%s on %s, ", $1, $2}' <<< "$SRV" | sed 's/, $//')) rides Cilium's Geneve tunnel between the node addresses ($MNIP > $SNIPS); the nodes share VLAN $DV, so between the control leaf pair and a GPU leaf pair the tunnel rides VXLAN in the L2 VNI, over a spine (captures 7-*, 8-*, 9-*)."
  echo "9. **The model**: each replica is a llama-server with two RPC workers on other GPU nodes, reached over its rail and bridged on that rail's leaf (captures 10-*). The answer returns the same way: replica -> LiteLLM -> APISIX -> Envoy -> the client, through either border leaf and the firewall."; }
echo; echo "## Frames per capture point"; echo '```'; for f in "$OUT"/captures/*.txt; do head -1 "$f"; done; echo '```'
echo; echo "## Recorded requests"; for c in pc-1 pc-2 office-lan; do echo; echo "### $c"; echo '```'; grep -v -E "^\* (Connected|ALPN|TLSv|Connection|using|Using|old SSL|Mark|Trying|\[)" "$OUT/curl/$c.txt" | head -45; echo '```'; done
echo; echo "## Control plane"; echo '```'; sed -n '/^################ 4\. Control plane/,/^################ 5\. Captures/p' "$R" | grep -vE '^################' | grep -v '^$' | head -110; echo '```'
echo; echo "## Captures (first SYN per hop)"; for f in "$OUT"/captures/*.txt; do echo; echo "### $(basename "$f" .txt)"; echo '```'; head -6 "$f"; echo '```'; done
echo; echo "Every command with its raw output, as typed on the devices: raw/commands.txt. Full outputs: raw/trace.txt. Packet files: captures/*.pcap."; } > "$OUT/TRACE.md"
# belt and braces: no bearer token or key in anything this run wrote
sed -i -E 's/(Bearer )[A-Za-z0-9_.-]+/\1<redacted>/g; s/sk-[A-Za-z0-9_-]{8,}/<redacted>/g' "$OUT"/raw/*.txt "$OUT"/curl/*.txt "$OUT"/TRACE.md "$OUT"/verdict.txt 2>/dev/null
keep_latest ai-fabric_e2e_trace "$OUT"
echo; echo "e2e trace -> $OUT"; exit $RC
