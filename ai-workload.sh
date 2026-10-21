#!/bin/bash
# ai-workload.sh [all|train|infer] [outdir]: REAL multi-node AI workloads on the lab, with the traffic captured hop by hop and every log kept
# (result set audits/ai-fabric_ai_workload_<ts>/: TRACE.md, verdict.txt, captures/, logs/, raw/). KEEP=1 also leaves the training pods and their volume.
# The inference pods always stay: they are the lab's model, also the local backend of the inference gateway (llm-serve.sh, inference-local-model.sh).
#
# TRAINING (4 GPU nodes, two per frontend leaf pair): a PyTorch DistributedDataParallel job, one rank per node (images/ai-sim/train.py)
#   T1 dataset    rank 0 stages one shard per rank on a shared ReadWriteMany volume (Longhorn share-manager, NFS); every rank reads its shard
#   T2 gradients  every optimiser step ends with an all-reduce of the gradients between the 4 ranks over RAIL 1 (gloo, TCP on the rail interface):
#                 the ranks' rail NICs sit in the same rail VLAN on be-leaf1, so the frames are bridged on that leaf and never reach a spine
#   T3 checkpoint rank 0 writes a checkpoint per epoch to the shared volume
#   T4 collective the pattern of an 8-GPU node: GPU r of a node talks to GPU r of the next node over rail r. A ring of flows between the same
#                 4 pods on rails 2-8 at the same time (iperf3, rate-limited: the rail leaves are VMs)
# INFERENCE (6 GPU nodes): one small open model (Qwen2.5-0.5B-Instruct, GGUF) served by llama.cpp, TWO replicas behind one Service; each replica
#   is spread over three nodes: llama-server on one node, its transformer layers on ggml-rpc-server workers on two other nodes, over a rail
#   I1 model load  each server ships the model's layers to its two RPC workers over its rail (rail 3 for replica A, rail 6 for replica B)
#   I2 requests    pc-1, pc-2 (enterprise zone) and the office LAN send chat completions to https://llm-sim.platform.<domain>: firewall ->
#                  border leaves -> Gateway VIP (Envoy on the announcing node) -> Service -> a replica -> its RPC workers over the rail -> back
# This run uses the model's own endpoint (namespace ai-sim, bearer key in a Secret created here, never printed). The same pods are a model of
# the inference gateway (namespace inference: APISIX -> LiteLLM -> Service llm here): trace.sh traces that path.
# Needs the image ai-fabric/ai-sim:1 on the nodes: ./ai-sim-build.sh (run automatically when it is missing).
set -u
cd "$(dirname "$0")"; . ./lib.sh
MODE=${1:-all}; TS=$(date -u +%Y%m%d_%H%M%S); OUT=${2:-audits/ai-fabric_ai_workload_$TS}; mkdir -p "$OUT/raw" "$OUT/captures" "$OUT/logs"
NS=ai-sim; IMG=docker.io/ai-fabric/ai-sim:1; DOMAIN=lab.ai; HOST="llm-sim.platform.$DOMAIN"; MODEL=qwen2.5-0.5b-instruct
TRAIN=(${TRAIN_NODES:-gpu1 gpu8 gpu17 gpu32}); NR=${#TRAIN[@]}; EPOCHS=${EPOCHS:-3}; STEPS=${STEPS:-10}; HIDDEN=${HIDDEN:-768}
INFA=(${INF_A:-gpu2 gpu9 gpu18}); RA=${RAIL_A:-3}; INFB=(${INF_B:-gpu25 gpu16 gpu31}); RB=${RAIL_B:-6}      # server, rpc worker, rpc worker; the rail of the replica
R="$OUT/raw/trace.txt"; : > "$R"; export EVID="$PWD/$OUT/raw/commands.txt"; : > "$EVID"
sec() { { echo; echo "################ $*"; } | tee -a "$R"; }
run() { local title=$1; shift; local m t; m=$(wc -c < "$EVID"); t=$(mktemp)
  { echo; echo "---- $title"; "$@" > "$t" 2>&1; if [ "$(wc -c < "$EVID")" -gt "$m" ]; then tail -c +$((m + 1)) "$EVID" | cat -s; else echo "\$ $*"; cat "$t"; fi; rm -f "$t"; } | tee -a "$R"; }
redact() { sed -E 's/(Bearer )[A-Za-z0-9_.-]+/\1<redacted>/g; s/sk-sim-[A-Za-z0-9]+/<redacted>/g'; }
port() { echo $((4 + ${1#gpu})); }                                   # rail-leaf port of a GPU node (gpuN -> be-leafR eth(4+N))
railip() { K "kubectl -n $NS exec $1 -- ip -4 -o addr show $2" | awk '{print $4}' | cut -d/ -f1 | tail -1; }
PIDS=""
cap() { local pid; pid=$(docker inspect -f '{{.State.Pid}}' "$LAB-$2" 2>/dev/null); [ -n "$pid" ] || return 0; echo "  $1: $2 $3   [$4]" | tee -a "$R"
  timeout "${CAPT:-900}" nsenter -t "$pid" -n tcpdump -i "$3" -nn -s 160 -c "${5:-4000}" -w "$OUT/captures/$1.pcap" "$4" >/dev/null 2>&1 & PIDS="$PIDS $!"; }
gcap() { echo "  $1: guest $2, all interfaces   [$3]" | tee -a "$R"      # inside a node (pod veths, bond0, geneve)
  timeout "${CAPT:-900}" ssh -n $SSHO "admin@$(mgmt "$2")" "sudo timeout ${CAPT:-900} tcpdump -i any -nn -s 160 -c ${4:-3000} -U -w - '$3' 2>/dev/null" > "$OUT/captures/$1.pcap" 2>/dev/null & PIDS="$PIDS $!"; }
stopcaps() { local p; for p in $PIDS; do kill -INT "$p" 2>/dev/null; done; for n in "$@"; do ssh -n $SSHO "admin@$(mgmt "$n")" "sudo pkill -INT tcpdump" >/dev/null 2>&1; done; sleep 3; PIDS=""; }
frames() { local f="$OUT/captures/$1.pcap"; [ -s "$f" ] || { echo 0; return; }; if [ -n "${2:-}" ]; then tcpdump -r "$f" -nn "$2" 2>/dev/null | wc -l; else tcpdump -r "$f" -nn 2>/dev/null | wc -l; fi; }
ctr() { local pid; pid=$(docker inspect -f '{{.State.Pid}}' "$LAB-$1"); nsenter -t "$pid" -n cat /proc/net/dev | sed 's/:/ /' | awk -v d="$2" '$1 == d {print $2, $10}'; }   # bytes the switch port received / sent (the container's ethN = the port)
mb() { awk -v a="$1" -v b="$2" 'BEGIN {printf "%.1f", (b - a) / 1e6}'; }
decode() { local f; for f in "$OUT"/captures/*.pcap; do [ -s "$f" ] || continue; { echo "# $(basename "$f" .pcap): $(tcpdump -r "$f" -nn 2>/dev/null | wc -l) frames captured (capture stops at its frame limit; the port counters give the volume)"; echo "# conversations (frames, source > destination)"
      tcpdump -r "$f" -nn -q 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == ">") {print $(i - 1), ">", $(i + 1); break}}' | sed 's/:$//' | sort | uniq -c | sort -rn | head -14; echo "# first frames"; tcpdump -r "$f" -nn 2>/dev/null | head -6 | cut -c1-200; } > "${f%.pcap}.txt"; done; }

# ---------------------------------------------------------------- prerequisites: image on the nodes, namespace, key, shared volume
sec "0. Prerequisites"
NODES=$(printf '%s\n' "${TRAIN[@]}" "${INFA[@]}" "${INFB[@]}" | sort -u | xargs)
miss=$(for n in $NODES; do (timeout 40 ssh -n $SSHO "admin@$(mgmt "$n")" "sudo ctr -n k8s.io images ls -q 2>/dev/null | grep -q '^$IMG\$'" || echo "$n") & done; wait)
[ -z "$miss" ] || { echo "image missing on: $(echo $miss | xargs) -> ai-sim-build.sh" | tee -a "$R"; EVID= ./ai-sim-build.sh $miss 2>&1 | tail -12 | tee -a "$R"; }
echo "image $IMG on: $NODES" | tee -a "$R"
EVID= KT=400 K "kubectl get ns $NS >/dev/null 2>&1 || kubectl create ns $NS >/dev/null; kubectl -n $NS delete pod -l app=ai-train --wait=true >/dev/null 2>&1; [ $MODE = train ] || kubectl -n $NS delete pod -l 'app in (llm, ai-rpc)' --wait=true >/dev/null 2>&1
  [ -z \"\$(kubectl -n $NS get pvc ai-data -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null)\" ] || kubectl -n $NS wait --for=delete pvc/ai-data --timeout=240s >/dev/null 2>&1
  kubectl -n $NS get secret llm-api-key >/dev/null 2>&1 || { umask 077; f=\$(mktemp); printf 'sk-sim-%s' \"\$(head -c 18 /dev/urandom | od -An -tx1 | tr -d ' \\n')\" > \$f; kubectl -n $NS create secret generic llm-api-key --from-file=key=\$f >/dev/null; rm -f \$f; }" >/dev/null
cat > "$OUT/raw/pvc.yaml" <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: ai-data, namespace: $NS}
spec: {accessModes: [ReadWriteMany], storageClassName: longhorn, resources: {requests: {storage: 2Gi}}}
EOF
docker cp "$OUT/raw/pvc.yaml" $LAB-bastion:/tmp/ai-pvc.yaml >/dev/null
run "namespace $NS, the bearer key (Secret llm-api-key, value never shown) and the shared volume (ReadWriteMany, Longhorn)" K "kubectl apply -f /tmp/ai-pvc.yaml; kubectl -n $NS get secret llm-api-key -o jsonpath='{.metadata.name}: {.type}, 1 key'; echo; kubectl -n $NS get pvc"
VIP=$(gw_vip); FWOUT=$(fw_out); LANSRC=$(lan_src)
# ---- the rails must forward before anything runs on them: rail-heal.sh (the OcNOS demo VM leaks under load and a rail leaf then stops forwarding; the
# host's watchdog stands down during an acceptance run). A reload done here is reported as a KNOWN platform limitation, not hidden.
RAILFIX=$(EVID= ./rail-heal.sh 2>&1 | tee -a "$R" | sed -n 's/^RELOADED \(be-leaf[0-9]*\).*/\1/p' | xargs); [ -z "$RAILFIX" ] || RAILFIX=" $RAILFIX"
railknown() { [ -z "$RAILFIX" ] || { known "rail leaf reloaded before the run:$RAILFIX" "OcNOS demo VM: it leaks memory under load and stops forwarding at its ceiling; a reload restores it (the lab's rail-leaf watchdog does the same outside acceptance runs)"; RAILFIX=""; }; }
tpod() { cat <<EOF
apiVersion: v1
kind: Pod
metadata: {name: $1, namespace: $NS, labels: {app: $3, part: $4}, annotations: {k8s.v1.cni.cncf.io/networks: '$5'}}
spec:
  nodeSelector: {kubernetes.io/hostname: $2}
  tolerations: [{key: nvidia.com/gpu, operator: Exists, effect: NoSchedule}]
  terminationGracePeriodSeconds: 2
  restartPolicy: ${RP:-Never}
  containers:
  - name: main
    image: $IMG
    imagePullPolicy: Never
    command: $6
$7
---
EOF
}
TRC=0; IRC=0

# ================================================================= TRAINING
if [ "$MODE" = all ] || [ "$MODE" = train ]; then
sec "T. MULTI-NODE TRAINING: PyTorch DistributedDataParallel, $NR ranks on ${TRAIN[*]}"
ALLRAILS=$(for r in 0 1 2 3 4 5 6 7; do printf 'default/net-rail-%s,' $r; done | sed 's/,$//')
VOL="    volumeMounts: [{name: data, mountPath: /data}]
  volumes: [{name: data, persistentVolumeClaim: {claimName: ai-data}}]"
for i in $(seq 0 $((NR - 1))); do tpod train-$i "${TRAIN[$i]}" ai-train rank-$i "$ALLRAILS" "[sleep, '7200']" "$VOL"; done > "$OUT/raw/train-pods.yaml"
docker cp "$OUT/raw/train-pods.yaml" $LAB-bastion:/tmp/ai-train.yaml >/dev/null
KT=420 K "kubectl apply -f /tmp/ai-train.yaml >/dev/null; kubectl -n $NS wait --for=condition=Ready pod -l app=ai-train --timeout=360s" | tail -$NR | tee -a "$R"
declare -A T1IP; for i in $(seq 0 $((NR - 1))); do T1IP[$i]=$(railip train-$i net1); done
[ -n "${T1IP[0]}" ] || { echo "the training pods did not get their rail addresses"; exit 1; }
run "the ranks: node, pod address on the frontend (Cilium), the eight rail interfaces (network-operator MacvlanNetworks net-rail-0..7 = rails 1..8)" K "kubectl -n $NS get pods -l app=ai-train -o wide | cut -c1-120; for p in \$(kubectl -n $NS get pods -l app=ai-train -o name); do echo \"== \$p\"; kubectl -n $NS exec \$p -- ip -4 -br addr | grep -E 'eth0|net'; done"
PV=$(K "kubectl -n $NS get pvc ai-data -o jsonpath='{.spec.volumeName}'" | tail -1)
SMPOD=$(K "kubectl -n longhorn-system get pods -o wide --no-headers | awk '\$1 == \"share-manager-$PV\" {print \$1, \$6, \$7}'" | tail -1); read -r SMP SMIP SMNODE <<< "$SMPOD"
run "the shared volume: Longhorn share-manager (the NFS server the ranks mount) and where it runs" K "kubectl -n $NS get pvc ai-data; kubectl -n longhorn-system get pods -o wide | grep -E 'NAME|share-manager'; kubectl -n $NS exec train-0 -- sh -c 'mount | grep /data'"
N0=${TRAIN[0]}; read -r FL1 FL2 FPORT <<< "$(leafport "$N0")"
echo "rank 0 = train-0 on $N0 (rail 1 ${T1IP[0]}); rendezvous tcp://${T1IP[0]}:29500; shared volume served by $SMP ($SMIP on $SMNODE)" | tee -a "$R"

sec "T. Capture points"
for i in $(seq 0 $((NR - 1))); do n=${TRAIN[$i]}; cap "T2-be-leaf1-eth$(port $n)-rank$i-$n" be-leaf1 "eth$(port $n)" "tcp and net 172.16.1.0/24" 4000; done
for u in 1 2 3 4; do cap "T2-be-leaf1-uplink$u-to-be-spine$u" be-leaf1 "eth$u" "tcp and net 172.16.1.0/24" 200; done
for r in 2 3 4 5 6 7 8; do cap "T4-be-leaf$r-eth$(port $N0)-rank0-$N0" be-leaf$r "eth$(port $N0)" "tcp and net 172.16.$r.0/24" 1500; done
gcap "T1-node-$N0-nfs-to-share-manager" "$N0" "port 2049" 3000
cap "T1-$FL1-eth$FPORT-$N0-frontend" "$FL1" "eth$FPORT" "udp port 6081 and host $(python3 -c "import gen; print(gen.HOSTS['$N0']['ip'])")" 1500
cap "T1-$FL2-eth$FPORT-$N0-frontend" "$FL2" "eth$FPORT" "udp port 6081 and host $(python3 -c "import gen; print(gen.HOSTS['$N0']['ip'])")" 1500
sleep 3
declare -A C0 C1; for i in $(seq 0 $((NR - 1))); do C0[$i]=$(ctr be-leaf1 "eth$(port ${TRAIN[$i]})"); done; for u in 1 2 3 4; do C0[u$u]=$(ctr be-leaf1 eth$u); done

sec "T. The job (one process per rank, started at the same time; logs/train-rank-N.log)"
T0=$(date +%s)
for i in $(seq 0 $((NR - 1))); do c="kubectl -n $NS exec train-$i -- env RANK=$i WORLD_SIZE=$NR MASTER_ADDR=${T1IP[0]} MASTER_PORT=29500 GLOO_SOCKET_IFNAME=net1 DATA_DIR=/data EPOCHS=$EPOCHS STEPS=$STEPS HIDDEN=$HIDDEN python3 /opt/ai/train.py"
  echo "\$ $c" | tee -a "$R"; ( timeout 900 docker exec "$LAB-bastion" bash -lc "$c" > "$OUT/logs/train-rank-$i.log" 2>&1 ) & TP[$i]=$!; [ $i = 0 ] && sleep 4; done
for i in $(seq 0 $((NR - 1))); do wait "${TP[$i]}"; done; TSEC=$(( $(date +%s) - T0 ))
for i in $(seq 0 $((NR - 1))); do C1[$i]=$(ctr be-leaf1 "eth$(port ${TRAIN[$i]})"); done; for u in 1 2 3 4; do C1[u$u]=$(ctr be-leaf1 eth$u); done
for i in $(seq 0 $((NR - 1))); do echo "---- rank $i (${TRAIN[$i]})"; grep -vE "UserWarning|_conversion_method" "$OUT/logs/train-rank-$i.log" | tail -9; done | cut -c1-230 | tee -a "$R"
run "checkpoints and dataset on the shared volume" K "kubectl -n $NS exec train-0 -- sh -c 'ls -la /data/dataset /data/checkpoints'"

sec "T4. Collective traffic on rails 2-8: ring rank i -> rank i+1 on every rail at once (iperf3, 5 Mbit/s per flow, 6 s)"
K "for i in $(seq -s' ' 0 $((NR - 1))); do kubectl -n $NS exec train-\$i -- sh -c 'for r in 2 3 4 5 6 7 8; do a=\$(ip -4 -o addr show net\$r | awk \"{print \\\$4}\" | cut -d/ -f1); iperf3 -s -D -B \$a -p 520\$r >/dev/null 2>&1; done'; done" >/dev/null
for i in $(seq 0 $((NR - 1))); do j=$(( (i + 1) % NR ))
  peers=$(K "kubectl -n $NS exec train-$j -- sh -c 'for r in 2 3 4 5 6 7 8; do ip -4 -o addr show net\$r | awk \"{print \\\$4}\" | cut -d/ -f1; done'" | xargs)
  ( EVID= K "kubectl -n $NS exec train-$i -- sh -c 'r=2; for p in $peers; do ( a=\$(ip -4 -o addr show net\$r | awk \"{print \\\$4}\" | cut -d/ -f1); o=\$(iperf3 -c \$p -B \$a -p 520\$r -t 6 -b 5M 2>&1 | grep receiver | tail -1); echo \"rail \$r: train-$i \$a -> train-$j \$p: \${o:-FAILED}\" ) & r=\$((r + 1)); done; wait'" > "$OUT/logs/collective-rank-$i.log" 2>&1 ) & CP[$i]=$!; done; for i in $(seq 0 $((NR - 1))); do wait "${CP[$i]}"; done      # not a bare wait: the captures run in the background too
cat "$OUT"/logs/collective-rank-*.log | sort -V | sed -E 's/\[ *[0-9]+\] +//' | cut -c1-150 | tee -a "$R" | tee "$OUT/raw/collective.txt" >/dev/null; sed -n 1,8p "$OUT/raw/collective.txt"; echo "   ... ($(grep -c receiver "$OUT/raw/collective.txt") of $((NR * 7)) flows completed; all of them in raw/collective.txt)"
sleep 2; stopcaps "$N0"
MACRE=$(for i in $(seq 0 $((NR - 1))); do K "kubectl -n $NS exec train-$i -- cat /sys/class/net/net1/address" | tail -1 | tr -d ':' | sed -E 's/^(....)(....)(....)$/\1.\2.\3/'; done | paste -sd'|')
{ echo; echo "---- be-leaf1: where the ranks' rail-1 MAC addresses were learnt (show mac address-table bridge 1, the ranks' entries)"; EVID= OCE be-leaf1 "show mac address-table bridge 1" | grep -iE "VLAN|$MACRE" | head -12; } | tee -a "$R"

# ---- training verdict
{ printf "\n== Verdict: multi-node training (%s ranks on %s, %s epochs x %s steps, %s s)\n" "$NR" "${TRAIN[*]}" "$EPOCHS" "$STEPS" "$TSEC"
  res() { grep -h "RESULT " "$OUT/logs/train-rank-$1.log" | sed 's/.*RESULT //' | tail -1; }; jf() { python3 -c 'import json, sys; d = json.loads(sys.argv[1] or "{}"); print(d.get(sys.argv[2], ""))' "$(res "$1")" "$2"; }
  railknown
  chk "every rank finished the job (a RESULT line per rank)" "$NR" "$(cat "$OUT"/logs/train-rank-*.log | grep -c 'RESULT ')"
  chk "every rank ran all $((EPOCHS * STEPS)) steps in a world of $NR" "$NR" "$(for i in $(seq 0 $((NR - 1))); do echo "$(jf $i steps)/$(jf $i world)"; done | grep -c "^$((EPOCHS * STEPS))/$NR$")"
  chk "gradient all-reduce kept the ranks identical: one weight checksum across all ranks ($(jf 0 weights_sha))" 1 "$(for i in $(seq 0 $((NR - 1))); do jf $i weights_sha; done | sort -u | grep -c .)"
  chk "the loss fell on every rank (first -> last: $(for i in $(seq 0 $((NR - 1))); do printf '%s->%s ' "$(jf $i first_loss)" "$(jf $i last_loss)"; done))" "$NR" "$(for i in $(seq 0 $((NR - 1))); do awk -v a="$(jf $i first_loss)" -v b="$(jf $i last_loss)" 'BEGIN {print (b + 0 < a + 0) ? "down" : "no"}'; done | grep -c down)"
  for i in $(seq 0 $((NR - 1))); do read -r a b <<< "${C0[$i]}"; read -r c d <<< "${C1[$i]}"; ge "rank $i (${TRAIN[$i]}): gradients crossed be-leaf1 eth$(port ${TRAIN[$i]}): $(mb $a $c) MB from the node, $(mb $b $d) MB to it (pod counters: tx $(jf $i rail_tx_mb) / rx $(jf $i rail_rx_mb) MB)" 20 "$(mb $a $c | cut -d. -f1)"; done
  for i in $(seq 0 $((NR - 1))); do n=${TRAIN[$i]}; ge "rank $i: its all-reduce frames captured on be-leaf1 eth$(port $n) (TCP between the ranks' rail-1 addresses)" 100 "$(frames "T2-be-leaf1-eth$(port $n)-rank$i-$n")"; done
  UPF=0; for u in 1 2 3 4; do UPF=$((UPF + $(frames "T2-be-leaf1-uplink$u-to-be-spine$u"))); done
  chk "same-rail training traffic never reached a spine (frames on the 4 be-leaf1 uplinks)" 0 "$UPF"
  chk "every rank read its dataset shard from the shared volume" "$NR" "$(cat "$OUT"/logs/train-rank-*.log | grep -c 'shard loaded from the shared volume')"
  chk "rank 0 wrote a checkpoint per epoch to the shared volume" "$EPOCHS" "$(grep -c 'checkpoint written to the shared volume' "$OUT/logs/train-rank-0.log")"
  ge "storage traffic of the job seen inside $N0: NFS (tcp 2049) between the pod and the share-manager" 50 "$(frames "T1-node-$N0-nfs-to-share-manager")"
  if [ "$SMNODE" = "$N0" ]; then ok "the share-manager runs on $N0 itself: the NFS traffic of rank 0 stays on the node (other ranks reach it over the frontend)"
  else ge "that storage traffic left $N0 over the frontend (geneve to $SMNODE) on $FL1/$FL2 eth$FPORT" 20 "$(( $(frames "T1-$FL1-eth$FPORT-$N0-frontend") + $(frames "T1-$FL2-eth$FPORT-$N0-frontend") ))"; fi
  chk "collective ring on rails 2-8: every flow completed ($((NR * 7)) flows)" "$((NR * 7))" "$(grep -c receiver "$OUT/raw/collective.txt")"
  chk "each of the rails 2-8 carried its own flows on its own leaf (frames on be-leafR eth$(port $N0), R = 2..8)" 7 "$(for r in 2 3 4 5 6 7 8; do [ "$(frames "T4-be-leaf$r-eth$(port $N0)-rank0-$N0")" -gt 20 ] && echo y; done | grep -c y)"
  summary; } > "$OUT/verdict-training.txt"; TRC=$?; cat "$OUT/verdict-training.txt" | tee -a "$R"
TPASS=$PASS; TFAIL=$FAIL; TKNOWN=$KNOWN
EVID= K "kubectl -n $NS logs -l app=ai-train --tail=5 --prefix 2>/dev/null; kubectl -n $NS get events --sort-by=.lastTimestamp 2>/dev/null | tail -40" > "$OUT/logs/train-k8s-events.txt" 2>&1
[ -n "${KEEP:-}" ] || EVID= K "kubectl -n $NS delete pod -l app=ai-train --wait=false >/dev/null 2>&1" >/dev/null
fi

# ================================================================= INFERENCE
if [ "$MODE" = all ] || [ "$MODE" = infer ]; then
PASS=0; FAIL=0; KNOWN=0; SKIP=0; FAILED=(); KNOWNS=()
sec "I. MULTI-NODE INFERENCE: $MODEL, replica A on ${INFA[*]} (rail $RA), replica B on ${INFB[*]} (rail $RB)"
RP=Always      # the inference pods are the lab's model (llm-serve.sh, the inference gateway's local backend): they stay, and restart when they die
{ tpod rpc-a1 "${INFA[1]}" ai-rpc a "default/net-rail-$((RA - 1))" "[ggml-rpc-server, -H, 0.0.0.0, -p, '50052', -t, '2']" ""
  tpod rpc-a2 "${INFA[2]}" ai-rpc a "default/net-rail-$((RA - 1))" "[ggml-rpc-server, -H, 0.0.0.0, -p, '50052', -t, '2']" ""
  tpod rpc-b1 "${INFB[1]}" ai-rpc b "default/net-rail-$((RB - 1))" "[ggml-rpc-server, -H, 0.0.0.0, -p, '50052', -t, '2']" ""
  tpod rpc-b2 "${INFB[2]}" ai-rpc b "default/net-rail-$((RB - 1))" "[ggml-rpc-server, -H, 0.0.0.0, -p, '50052', -t, '2']" ""; } > "$OUT/raw/infer-rpc.yaml"
docker cp "$OUT/raw/infer-rpc.yaml" $LAB-bastion:/tmp/ai-rpc.yaml >/dev/null
KT=300 K "kubectl apply -f /tmp/ai-rpc.yaml >/dev/null; kubectl -n $NS wait --for=condition=Ready pod -l app=ai-rpc --timeout=240s" | tail -4 | tee -a "$R"
A1=$(railip rpc-a1 net1); A2=$(railip rpc-a2 net1); B1=$(railip rpc-b1 net1); B2=$(railip rpc-b2 net1)
[ -n "$A1" ] && [ -n "$A2" ] && [ -n "$B1" ] && [ -n "$B2" ] || { echo "the RPC workers did not get their rail addresses"; exit 1; }
run "what a server will compute on: the RPC devices reachable over the rail (llama-server --list-devices, asked before the servers start: a worker serves one client at a time)" K "echo '-- replica A, rail $RA:'; kubectl -n $NS exec rpc-a1 -- llama-server --rpc $A1:50052,$A2:50052 --list-devices 2>&1 | grep -vE '^load_backend|^\$' | cut -c1-160; echo '-- replica B, rail $RB:'; kubectl -n $NS exec rpc-b1 -- llama-server --rpc $B1:50052,$B2:50052 --list-devices 2>&1 | grep -vE '^load_backend|^\$' | cut -c1-160"
SEC="    volumeMounts: [{name: key, mountPath: /secret, readOnly: true}]
    readinessProbe: {httpGet: {path: /health, port: 8080}, periodSeconds: 3, failureThreshold: 200}
    ports: [{containerPort: 8080}]
  volumes: [{name: key, secret: {secretName: llm-api-key}}]"
srv() { echo "[llama-server, -m, /models/model.gguf, --alias, $MODEL, --host, 0.0.0.0, --port, '8080', --rpc, '$1:50052,$2:50052', -ngl, '99', -c, '2048', -t, '2', -np, '2', --no-webui, --api-key-file, /secret/key]"; }
{ tpod llm-a "${INFA[0]}" llm a "default/net-rail-$((RA - 1))" "$(srv $A1 $A2)" "$SEC"; tpod llm-b "${INFB[0]}" llm b "default/net-rail-$((RB - 1))" "$(srv $B1 $B2)" "$SEC"
  cat <<EOF
apiVersion: v1
kind: Service
metadata: {name: llm, namespace: $NS}
spec: {selector: {app: llm}, ports: [{port: 8080, targetPort: 8080}]}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: llm-sim, namespace: $NS}
spec:
  parentRefs: [{group: gateway.networking.k8s.io, kind: Gateway, name: gateway, namespace: gateway}]
  hostnames: [$HOST]
  rules: [{matches: [{path: {type: PathPrefix, value: /}}], timeouts: {request: 300s, backendRequest: 300s}, backendRefs: [{name: llm, port: 8080}]}]
EOF
} > "$OUT/raw/infer-servers.yaml"
docker cp "$OUT/raw/infer-servers.yaml" $LAB-bastion:/tmp/ai-llm.yaml >/dev/null

sec "I. Capture points: the rails (model load + per-token RPC)"
for x in "a $RA ${INFA[*]}" "b $RB ${INFB[*]}"; do set -- $x; rep=$1; rl=$2; shift 2; k=0; for n in "$@"; do role=$([ $k = 0 ] && echo server || echo rpc$k); cap "I1-be-leaf$rl-eth$(port $n)-replica-$rep-$role-$n" be-leaf$rl "eth$(port $n)" "tcp port 50052" 3000; k=$((k + 1)); done
  for u in 1 2 3 4; do cap "I1-be-leaf$rl-uplink$u-replica-$rep" be-leaf$rl "eth$u" "tcp port 50052" 200; done; done
sleep 3
declare -A I0 I1 I2; for x in "a $RA ${INFA[*]}" "b $RB ${INFB[*]}"; do set -- $x; rep=$1; rl=$2; shift 2; for n in "$@"; do I0[$rep$n]=$(ctr be-leaf$rl "eth$(port $n)"); done; done
L0=$(date +%s)
# wait until both servers are Ready, but stop at once when one ends in Error (a server that cannot reach its RPC workers exits)
KT=900 K "kubectl apply -f /tmp/ai-llm.yaml >/dev/null; for i in \$(seq 1 200); do s=\$(kubectl -n $NS get pods -l app=llm --no-headers | awk '{print \$2\":\"\$3}' | xargs); case \"\$s\" in *Error*|*Failed*|*CrashLoop*) break;; '1/1:Running 1/1:Running') break;; esac; sleep 4; done; kubectl -n $NS get pods -l app=llm --no-headers" | tail -2 | tee -a "$R"; LSEC=$(( $(date +%s) - L0 ))
for x in "a $RA ${INFA[*]}" "b $RB ${INFB[*]}"; do set -- $x; rep=$1; rl=$2; shift 2; for n in "$@"; do I1[$rep$n]=$(ctr be-leaf$rl "eth$(port $n)"); done; done
run "the replicas: llama-server pods, their RPC workers, the Service and the route" K "kubectl -n $NS get pods -o wide | cut -c1-125; kubectl -n $NS get svc,httproute,endpoints | cut -c1-140"
run "replica A: its load log and a worker's log (the worker accepts the server's connection over rail $RA)" K "kubectl -n $NS logs llm-a | grep -E 'load_model|model loaded|listening' | cut -c1-160; echo '-- rpc-a1:'; kubectl -n $NS logs rpc-a1 | grep -E 'endpoint|Accepted|RPC server' | head -4"
run "replica B: the same over rail $RB" K "kubectl -n $NS logs llm-b | grep -E 'load_model|model loaded|listening' | cut -c1-160; echo '-- rpc-b1:'; kubectl -n $NS logs rpc-b1 | grep -E 'endpoint|Accepted|RPC server' | head -4"

sec "I. Who answers the Gateway VIP $VIP, and the capture points of the request path"
VNODE=$(K "kubectl -n kube-system get lease -o jsonpath='{range .items[*]}{.metadata.name} {.spec.holderIdentity}{\"\\n\"}{end}' | awk '/l2announce.*gateway/ {print \$2; exit}'"); read -r VL1 VL2 VPORT <<< "$(leafport "$VNODE")"
read -r LAIP LANODE <<< "$(K "kubectl -n $NS get pod llm-a -o jsonpath='{.status.podIP} {.spec.nodeName}'")"; read -r LBIP LBNODE <<< "$(K "kubectl -n $NS get pod llm-b -o jsonpath='{.status.podIP} {.spec.nodeName}'")"
echo "VIP $VIP announced by $VNODE ($VL1/$VL2 port $VPORT). Envoy on $VNODE -> Service llm -> llm-a $LAIP on $LANODE | llm-b $LBIP on $LBNODE -> RPC workers $A1, $A2 (rail $RA) | $B1, $B2 (rail $RB)" | tee -a "$R"
FILT="(tcp port 443 and (host $VIP or host $FWOUT))"; FILT="$FILT or (vlan and $FILT)"
cap I2-1-pc1-access pc-1 eth1 "$FILT" 600; cap I2-1-pc2-access pc-2 eth1 "$FILT" 600
cap I2-2-fw-in-enterprise-pc1 fw eth4 "$FILT" 600; cap I2-2-fw-in-enterprise-pc2 fw eth6 "$FILT" 600; cap I2-2-fw-in-officeLAN fw eth5 "$FILT" 600
cap I2-3-fw-out-border1 fw eth1 "$FILT" 600; cap I2-3-fw-out-border2 fw eth2 "$FILT" 600
cap "I2-4-$VL1-eth$VPORT-to-$VNODE" "$VL1" "eth$VPORT" "$FILT" 600; cap "I2-4-$VL2-eth$VPORT-to-$VNODE" "$VL2" "eth$VPORT" "$FILT" 600
gcap "I2-5-node-$LANODE-llm-a-8080" "$LANODE" "tcp port 8080" 1500; gcap "I2-5-node-$LBNODE-llm-b-8080" "$LBNODE" "tcp port 8080" 1500
for x in "a $RA ${INFA[0]}" "b $RB ${INFB[0]}"; do set -- $x; cap "I2-6-be-leaf$2-eth$(port $3)-replica-$1-requests" be-leaf$2 "eth$(port $3)" "tcp port 50052" 2500; done
# I2-7 .. I2-9: the EAST-WEST leg of a request, Envoy on $VNODE -> the replica's pod on a GPU node (the model is served from the GPU nodes, so every user
# request ends there). Pod traffic between nodes rides Cilium's Geneve tunnel (udp 6081) between the NODE addresses; the nodes share one VLAN, so between two
# leaf pairs the tunnel itself rides VXLAN in the L2 VNI. Captured where it leaves $VNODE, on the spine side of its leaf pair (the inner addresses are matched
# at their offset in the VXLAN payload: 14 + 20 + 8 + 8 + 14 = 64 bytes to the inner IP header, its addresses at +12 and +16, the Geneve port at +22) and
# where it reaches each serving node.
nip() { python3 -c "import gen, sys; print(gen.HOSTS[sys.argv[1]]['ip'])" "$1"; }; hx() { printf '0x%02x%02x%02x%02x' $(echo "$1" | tr . ' '); }
VNIP=$(nip "$VNODE"); LANIP=$(nip "$LANODE"); LBNIP=$(nip "$LBNODE"); read -r GA1 GA2 GAP <<< "$(leafport "$LANODE")"; read -r GB1 GB2 GBP <<< "$(leafport "$LBNODE")"
EW="udp port 6081 and host $VNIP and (host $LANIP or host $LBNIP)"; EW="($EW) or (vlan and ($EW))"
EWX="udp port 4789 and ether[86:2] = 6081 and ((ether[76:4] = $(hx $VNIP) and (ether[80:4] = $(hx $LANIP) or ether[80:4] = $(hx $LBNIP))) or (ether[80:4] = $(hx $VNIP) and (ether[76:4] = $(hx $LANIP) or ether[76:4] = $(hx $LBNIP))))"
for l in $VL1 $VL2; do cap "I2-7-$l-eth$VPORT-$VNODE-east-west" "$l" "eth$VPORT" "$EW" 1500; for u in 1 2; do cap "I2-8-$l-uplink$u-to-fe-spine$u-east-west" "$l" "eth$u" "$EWX" 1500; done; done
for l in $GA1 $GA2; do cap "I2-9-$l-eth$GAP-$LANODE-east-west" "$l" "eth$GAP" "$EW" 1500; done; for l in $GB1 $GB2; do cap "I2-9-$l-eth$GBP-$LBNODE-east-west" "$l" "eth$GBP" "$EW" 1500; done
sleep 3

sec "I2. The requests: 3 chat completions each from pc-1, pc-2 and the office LAN (bearer key from the Secret, shown as <redacted>)"
BODY() { printf '{"model":"%s","messages":[{"role":"user","content":"%s"}],"max_tokens":20,"temperature":0}' "$MODEL" "$1"; }
PROMPTS=("Name the capital of France in one word." "What is 12 plus 30? Answer with the number only." "Reply with the single word READY.")
CA=publish/ai-fabric-cluster-ca.crt; HDR=$(mktemp); chmod 600 "$HDR"
docker exec "$LAB-bastion" bash -lc "kubectl -n $NS get secret llm-api-key -o jsonpath='{.data.key}' | base64 -d" 2>/dev/null | { printf 'Authorization: Bearer '; cat; } > "$HDR"
for pc in pc-1 pc-2; do docker exec -i "$LAB-$pc" sh -c 'umask 077; cat > /tmp/.llm-h' < "$HDR"; done
: > "$OUT/raw/requests.txt"
req() { local who=$1 addr=$2 i=$3 body code; body=$(BODY "${PROMPTS[$i]}"); local f="$OUT/raw/infer-$who-$((i + 1)).json"
  echo "\$ ($who) curl --cacert <lab CA> --resolve $HOST:443:$addr -H 'Authorization: Bearer <redacted>' -d '$body' https://$HOST/v1/chat/completions" >> "$OUT/raw/requests.txt"
  if [ "$who" = lan ]; then code=$(curl -sS --cacert "$CA" --resolve "$HOST:443:$addr" -m 240 -o "$f" -w '%{http_code} %{time_total}' -H @"$HDR" -H 'Content-Type: application/json' -d "$body" "https://$HOST/v1/chat/completions" 2>&1 | tail -1)
  else code=$(docker exec "$LAB-$who" sh -c "curl -sS --cacert /usr/local/share/ca-certificates/ai-fabric-cluster-ca.crt --resolve $HOST:443:$addr -m 240 -o /tmp/r.json -w '%{http_code} %{time_total}' -H @/tmp/.llm-h -H 'Content-Type: application/json' -d '$body' https://$HOST/v1/chat/completions" 2>&1 | tail -1); docker exec "$LAB-$who" cat /tmp/r.json > "$f" 2>/dev/null; fi
  python3 - "$who" "$addr" "$i" "$code" "$f" "${PROMPTS[$i]}" <<'PY' | tee -a "$OUT/raw/requests.txt"
import json, sys
who, addr, i, code, f, prompt = sys.argv[1:7]
try: d = json.load(open(f))
except Exception: d = {}
c = (d.get("choices") or [{}])[0].get("message", {}).get("content", "").strip().replace("\n", " ")
u, t = d.get("usage", {}), d.get("timings", {})
print(f"  {who:5} -> {addr:13} #{int(i) + 1}: HTTP {code.split()[0]} in {code.split()[-1]} s | {prompt!r} -> {c[:60]!r} | tokens in/out {u.get('prompt_tokens', '?')}/{u.get('completion_tokens', '?')}, {t.get('predicted_per_second', 0):.1f} tok/s")
PY
}
for i in 0 1 2; do req pc-1 "$VIP" $i; req pc-2 "$VIP" $i; req lan "$FWOUT" $i; done
NOKEY=$(docker exec "$LAB-pc-1" sh -c "curl -sS --cacert /usr/local/share/ca-certificates/ai-fabric-cluster-ca.crt --resolve $HOST:443:$VIP -m 30 -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d '$(BODY hi)' https://$HOST/v1/chat/completions" 2>&1 | tail -1)
echo "  pc-1 without a bearer key: HTTP $NOKEY" | tee -a "$OUT/raw/requests.txt"
cat "$OUT/raw/requests.txt" >> "$R"
for pc in pc-1 pc-2; do docker exec "$LAB-$pc" rm -f /tmp/.llm-h /tmp/r.json; done; rm -f "$HDR"
sleep 2; stopcaps "$LANODE" "$LBNODE"
for x in "a $RA ${INFA[*]}" "b $RB ${INFB[*]}"; do set -- $x; rep=$1; rl=$2; shift 2; for n in "$@"; do I2[$rep$n]=$(ctr be-leaf$rl "eth$(port $n)"); done; done
EVID= K "kubectl -n $NS logs llm-a" > "$OUT/logs/llm-a.log" 2>&1; EVID= K "kubectl -n $NS logs llm-b" > "$OUT/logs/llm-b.log" 2>&1
for p in rpc-a1 rpc-a2 rpc-b1 rpc-b2; do EVID= K "kubectl -n $NS logs $p" > "$OUT/logs/$p.log" 2>&1; done
RQA=$(grep -c "processing task" "$OUT/logs/llm-a.log"); RQB=$(grep -c "processing task" "$OUT/logs/llm-b.log")      # llama-server logs one "processing task" per completion
echo "requests served: replica A (llm-a on $LANODE) $RQA, replica B (llm-b on $LBNODE) $RQB" | tee -a "$R"
# the firewall's own record of the request flows: its traffic log, read over the CLI with a time and port filter (never unfiltered: the whole log is large),
# one entry per line (the CLI prints four lines per entry)
if fw_cli_ok; then
  EVID= FWT=90 _pancli_raw "show log traffic direction equal backward receive_time in last-15-minutes dport equal 443" | awk '/^[0-9][0-9][0-9][0-9]\/[0-9][0-9]\/[0-9][0-9] / {if (l != "") print l; l = $0; next} /^Time|^Rule|^Src User|^Rule_UUid|^====/ {next} {gsub(/^ +/, " "); l = l " | " $0} END {if (l != "") print l}' \
    | grep -E " ($VIP|$FWOUT)( |$)" | sed -E 's/ +/ /g' | head -30 > "$OUT/raw/fw-traffic-log.txt"
  { echo; echo "---- firewall traffic log, the request flows (admin@ai-fabric-fw> show log traffic direction equal backward receive_time in last-15-minutes dport equal 443; one entry per line:"; echo "     time app from-zone src-port source | rule action to-zone dst-port destination | end reason)"; cat "$OUT/raw/fw-traffic-log.txt"; } | cut -c1-230 | tee -a "$R" | tail -14
  FWLOG=$(grep -cE "^[0-9]{4}/" "$OUT/raw/fw-traffic-log.txt"); else FWLOG=-1; fi
EVID= K "kubectl -n $NS get pods -o wide; kubectl -n $NS describe pods -l app=llm | grep -A12 '^Events'; kubectl -n $NS get events --sort-by=.lastTimestamp | tail -40" > "$OUT/logs/infer-k8s-events.txt" 2>&1

{ printf "\n== Verdict: multi-node inference (%s; replica A %s rail %s, replica B %s rail %s; model load %s s)\n" "$MODEL" "${INFA[*]}" "$RA" "${INFB[*]}" "$RB" "$LSEC"
  railknown
  chk "both replicas Ready (llama-server answers /health)" 2 "$(K "kubectl -n $NS get pods -l app=llm --no-headers" | grep -c '1/1 *Running')"
  for x in "a $RA ${INFA[*]}" "b $RB ${INFB[*]}"; do set -- $x; rep=$1; rl=$2; srvn=$3; shift 3; read -r a b <<< "${I0[$rep$srvn]}"; read -r c d <<< "${I1[$rep$srvn]}"
    ge "replica $rep: the server on $srvn shipped the model's layers to its RPC workers over rail $rl ($(mb $a $c) MB from the server on be-leaf$rl eth$(port $srvn))" 100 "$(mb $a $c | cut -d. -f1)"
    for n in "$@"; do read -r a b <<< "${I0[$rep$n]}"; read -r c d <<< "${I1[$rep$n]}"; ge "replica $rep: RPC worker on $n received its share of the model ($(mb $b $d) MB to the node on be-leaf$rl eth$(port $n))" 20 "$(mb $b $d | cut -d. -f1)"; done
    UPF=0; for u in 1 2 3 4; do UPF=$((UPF + $(frames "I1-be-leaf$rl-uplink$u-replica-$rep"))); done; chk "replica $rep: its RPC traffic stayed on be-leaf$rl (frames on the 4 uplinks)" 0 "$UPF"; done
  chk "9 of 9 chat completions answered HTTP 200 (pc-1, pc-2, office LAN x 3)" 9 "$(grep -c ': HTTP 200 ' "$OUT/raw/requests.txt")"
  chk "every answer carries generated text" 9 "$(grep ': HTTP 200 ' "$OUT/raw/requests.txt" | grep -vc -- "-> '' |")"
  chk "a request without the bearer key is refused (HTTP 401)" 401 "$NOKEY"
  ge "both replicas served requests (A $RQA, B $RQB): the Service balances over the two nodes" 1 "$([ "$RQA" -ge 1 ] && [ "$RQB" -ge 1 ] && echo 1 || echo 0)"
  chk "all requests arrived at a replica ($RQA + $RQB of 9 authorised)" 9 "$((RQA + RQB))"
  ge "hop 1: pc-1 and pc-2 sent their requests to the VIP (frames on their access links)" 20 "$(( $(frames I2-1-pc1-access) + $(frames I2-1-pc2-access) ))"
  ge "hop 2: the firewall received them in the enterprise zone (ethernet1/4 + 1/6) and the office LAN flow on the outside (1/5)" 30 "$(( $(frames I2-2-fw-in-enterprise-pc1) + $(frames I2-2-fw-in-enterprise-pc2) + $(frames I2-2-fw-in-officeLAN) ))"
  ge "hop 3: requests and replies crossed the firewall's fabric side (requests out on its one active route, ethernet1/1 > fe-border1; replies back on 1/1 or 1/2)" 30 "$(( $(frames I2-3-fw-out-border1) + $(frames I2-3-fw-out-border2) ))"
  ge "hop 4: they reached $VNODE, the node announcing the VIP, on $VL1/$VL2 eth$VPORT" 30 "$(( $(frames "I2-4-$VL1-eth$VPORT-to-$VNODE") + $(frames "I2-4-$VL2-eth$VPORT-to-$VNODE") ))"
  ge "hop 5: Envoy handed them to the replicas' pods (tcp 8080 inside $LANODE and $LBNODE)" 20 "$(( $(frames "I2-5-node-$LANODE-llm-a-8080") + $(frames "I2-5-node-$LBNODE-llm-b-8080") ))"
  ewf() { local n t=0 f all="$*"; f=${all##*-- }; for n in "$@"; do [ "$n" = -- ] && break; t=$((t + $(frames "$n" "($f) or (vlan and ($f))"))); done; echo $t; }      # frames matching a filter, summed over capture points
  P7="I2-7-$VL1-eth$VPORT-$VNODE-east-west I2-7-$VL2-eth$VPORT-$VNODE-east-west"; P8=$(for l in $VL1 $VL2; do for u in 1 2; do printf 'I2-8-%s-uplink%s-to-fe-spine%s-east-west ' $l $u $u; done; done)
  ge "hop 5a, east-west: Envoy's requests left $VNODE for the serving GPU nodes in Geneve ($VNIP > $LANIP / $LBNIP, udp 6081) on $VL1/$VL2 eth$VPORT" 10 "$(ewf $P7 -- src $VNIP)"
  ge "hop 5a: the answers came back to $VNODE the same way ($LANIP / $LBNIP > $VNIP)" 10 "$(ewf $P7 -- dst $VNIP)"
  ge "hop 5a: inside that tunnel are Envoy's connections to the replicas' pods ($LAIP and $LBIP, tcp 8080)" 10 "$(for n in $P7; do tcpdump -r "$OUT/captures/$n.pcap" -nn 2>/dev/null; done | grep -cE "($LAIP|$LBIP)\.8080[ :]")"
  EWS=0; for n in $P8; do EWS=$((EWS + $(frames "$n"))); done; EWV=$(for n in $P8; do tcpdump -r "$OUT/captures/$n.pcap" -nn 2>/dev/null | grep -oE "VXLAN, flags \[I\] \(0x08\), vni [0-9]+" | grep -oE "vni [0-9]+"; done | sort -u | xargs)
  ge "hop 5b, east-west: that traffic crossed the spines inside VXLAN (frames on the 4 uplinks of $VL1/$VL2, both directions)" 20 "$EWS"
  chk "hop 5b: one VXLAN segment carries it, the L2 VNI of the nodes' VLAN" "vni $(python3 -c 'import gen; print(gen.NX_L2VNI if gen.NXOS else gen.FE_VLAN)')" "$EWV"
  ge "hop 5c, east-west: it reached $LANODE (replica A) on $GA1/$GA2 eth$GAP, and the answers left there" 10 "$(ewf "I2-9-$GA1-eth$GAP-$LANODE-east-west" "I2-9-$GA2-eth$GAP-$LANODE-east-west" -- host $LANIP)"
  ge "hop 5c: and $LBNODE (replica B) on $GB1/$GB2 eth$GBP" 10 "$(ewf "I2-9-$GB1-eth$GBP-$LBNODE-east-west" "I2-9-$GB2-eth$GBP-$LBNODE-east-west" -- host $LBNIP)"
  for x in "a $RA ${INFA[0]}" "b $RB ${INFB[0]}"; do set -- $x; ge "hop 6: replica $1 computed the answers on its RPC workers over rail $2 (tcp 50052 frames on be-leaf$2 eth$(port $3) during the requests)" 50 "$(frames "I2-6-be-leaf$2-eth$(port $3)-replica-$1-requests")"; done
  if [ "$FWLOG" -ge 0 ]; then ge "the firewall logged the request flows to $VIP / $FWOUT port 443 (traffic log)" 1 "$FWLOG"; else skip "firewall traffic log" "the firewall CLI is not reachable (export FW_PASS)"; fi
  summary; } > "$OUT/verdict-inference.txt"; IRC=$?; cat "$OUT/verdict-inference.txt" | tee -a "$R"
IPASS=$PASS; IFAIL=$FAIL; IKNOWN=$KNOWN
fi
# the training pods and their volume go; the inference pods, their Service and route STAY: they are the lab's model (see llm-serve.sh)
[ -n "${KEEP:-}" ] || EVID= K "kubectl -n $NS delete pod -l app=ai-train --wait=false >/dev/null 2>&1; kubectl -n $NS delete pvc ai-data --wait=false >/dev/null 2>&1" >/dev/null
decode

# ================================================================= one verdict + the report
{ [ -f "$OUT/verdict-training.txt" ] && cat "$OUT/verdict-training.txt"; [ -f "$OUT/verdict-inference.txt" ] && cat "$OUT/verdict-inference.txt"
  printf "\n== RESULT: %s passed, %s failed, %s known platform limitation(s), 0 skipped\n" "$(( ${TPASS:-0} + ${IPASS:-0} ))" "$(( ${TFAIL:-0} + ${IFAIL:-0} ))" "$(( ${TKNOWN:-0} + ${IKNOWN:-0} ))"; } > "$OUT/verdict.txt"
{ echo "# ai-fabric: real multi-node AI workloads, traced ($TS)"; echo
  echo "Two workloads ran on the lab's own nodes and networks; every hop was captured (captures/*.pcap, decoded heads in captures/*.txt), every log kept (logs/), every command with its raw output in raw/commands.txt."; echo
  if [ -f "$OUT/verdict-training.txt" ]; then
  echo "## 1. Multi-node training"; echo
  echo "PyTorch DistributedDataParallel (CPU build, gloo backend), **$NR ranks**: $(for i in $(seq 0 $((NR - 1))); do printf 'rank %s on %s (rail 1 %s)%s' $i "${TRAIN[$i]}" "${T1IP[$i]}" "$([ $i -lt $((NR - 1)) ] && echo ', ')"; done). ${TRAIN[0]} and ${TRAIN[1]} hang off the first frontend leaf pair, the other two off the second; all four share **rail 1** (be-leaf1)."; echo
  echo "| flow | what | path | evidence |"; echo "|---|---|---|---|"
  echo "| T1 dataset | rank 0 stages a shard per rank on the shared volume, every rank reads its own | pod -> Longhorn share-manager $SMP on $SMNODE (NFS, tcp 2049), frontend network (Cilium, geneve between nodes) | $(frames "T1-node-$N0-nfs-to-share-manager") NFS frames captured in $N0; logs/train-rank-N.log |"
  echo "| T2 gradients | all-reduce of the gradients after every step, $((EPOCHS * STEPS)) steps | rank NIC -> be-leaf1 host port -> be-leaf1 host port -> rank NIC (bridged in the rail VLAN; **no spine**) | $(for i in $(seq 0 $((NR - 1))); do read -r a b <<< "${C0[$i]}"; read -r c d <<< "${C1[$i]}"; printf 'eth%s %s MB in / %s MB out; ' "$(port ${TRAIN[$i]})" "$(mb $a $c)" "$(mb $b $d)"; done) uplink frames: 0 |"
  echo "| T3 checkpoints | rank 0 writes the model after every epoch | as T1 | $(grep -c 'checkpoint written' "$OUT/logs/train-rank-0.log") checkpoints on the volume |"
  echo "| T4 collective | ring rank i -> i+1 on each of the rails 2-8 at once | same as T2, one rail leaf per rail (be-leaf2 .. be-leaf8) | $(grep -c receiver "$OUT/raw/collective.txt") of $((NR * 7)) flows; frames on every rail leaf |"
  echo; echo '```'; cat "$OUT/verdict-training.txt"; echo '```'; echo; echo "Rank 0's log:"; echo '```'; grep -vE "UserWarning|_conversion_method" "$OUT/logs/train-rank-0.log" | cut -c1-220; echo '```'; fi
  if [ -f "$OUT/verdict-inference.txt" ]; then
  echo; echo "## 2. Multi-node inference"; echo
  echo "Model **$MODEL** (GGUF, llama.cpp). Two replicas behind Service \`llm\`; each replica = one \`llama-server\` plus two \`ggml-rpc-server\` workers on other nodes, reached over a rail:"; echo
  echo "| replica | llama-server | RPC workers | rail |"; echo "|---|---|---|---|"
  echo "| A | llm-a on ${INFA[0]} (pod $LAIP) | ${INFA[1]} ($A1), ${INFA[2]} ($A2) | rail $RA, be-leaf$RA |"; echo "| B | llm-b on ${INFB[0]} (pod $LBIP) | ${INFB[1]} ($B1), ${INFB[2]} ($B2) | rail $RB, be-leaf$RB |"; echo
  echo "| flow | what | path |"; echo "|---|---|---|"
  echo "| I1 model load | at start each server sends the model's layers to its two workers ($LSEC s for both replicas) | server NIC -> be-leaf$RA / be-leaf$RB -> worker NICs, bridged on the rail leaf |"
  echo "| I2 request | chat completion from pc-1, pc-2 (enterprise) and the office LAN ($LANSRC) | client -> firewall (enterprise: ethernet1/4, 1/6; office LAN: ethernet1/5, DNAT $FWOUT -> $VIP) -> border leaves -> VXLAN -> $VL1/$VL2 -> $VNODE (Envoy, Gateway VIP $VIP) -> Service llm -> EAST-WEST over the frontend to the GPU nodes (Geneve $VNIP > $LANIP / $LBNIP, inside VXLAN $EWV between the leaf pairs, over a spine) -> llm-a on $LANODE or llm-b on $LBNODE -> RPC workers over the rail -> back the same way |"
  echo; echo "East-west leg, frames per capture point (towards the serving node / back to $VNODE):"; echo '```'
  for n in $P7 $P8 "I2-9-$GA1-eth$GAP-$LANODE-east-west" "I2-9-$GA2-eth$GAP-$LANODE-east-west" "I2-9-$GB1-eth$GBP-$LBNODE-east-west" "I2-9-$GB2-eth$GBP-$LBNODE-east-west"; do
    case $n in I2-8-*) a=$(frames "$n" "ether[76:4] = $(hx $VNIP)"); b=$(frames "$n" "ether[80:4] = $(hx $VNIP)");; *) a=$(ewf "$n" -- src $VNIP); b=$(ewf "$n" -- dst $VNIP);; esac; printf "  %-52s %4s / %-4s\n" "$n" "$a" "$b"; done; echo '```'
  echo; echo "Requests:"; echo '```'; grep -E "^  (pc-1|pc-2|lan  |pc-1 without)" "$OUT/raw/requests.txt" | cut -c1-230; echo "requests served: replica A $RQA, replica B $RQB"; echo '```'
  echo; echo '```'; cat "$OUT/verdict-inference.txt"; echo '```'; fi
  echo; echo "## Captures (frames per point)"; echo '```'; for f in "$OUT"/captures/*.pcap; do printf "  %-58s %s\n" "$(basename "$f" .pcap)" "$(frames "$(basename "$f" .pcap)")"; done; echo '```'
  echo; echo "Files: logs/ (rank logs, llama-server and RPC worker logs, Kubernetes events), raw/trace.txt (everything in order), raw/commands.txt (every device command with its output), raw/*.yaml (the manifests), raw/requests.txt + raw/infer-*.json (requests and full answers), captures/."; } | redact > "$OUT/TRACE.md"
sed -i -E 's/(Bearer )[A-Za-z0-9_.-]+/\1<redacted>/g; s/sk-sim-[A-Za-z0-9]+/<redacted>/g' "$OUT"/raw/*.txt "$OUT"/logs/*.log 2>/dev/null
keep_latest ai-fabric_ai_workload "$OUT"
echo; tail -1 "$OUT/verdict.txt"; echo "AI workload trace -> $OUT"; [ "$TRC" = 0 ] && [ "$IRC" = 0 ]
