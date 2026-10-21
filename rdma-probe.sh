#!/bin/bash
# rdma-probe.sh [gpuA] [gpuB] [outdir]: the SoftRoCE probe of the NVIDIA network-operator lab (site-a-nx, operator decision 2026-09-24).
# Question: does pod-to-pod RDMA over a rail work the way production does it -- rdma-shared-dev-plugin (resource rdma/rdma_shared) + a MacvlanNetwork
# attachment -- with SoftRoCE (rxe_gpuN, netsetup.sh) standing in for ConnectX? Answered in layers, rail 1 (gpu0 -> be-leaf1, 172.16.1.0/24):
#   0. plugin     does rdma-shared-dev-plugin advertise rdma/rdma_shared? It finds RDMA devices under the NIC's PCI device; rxe_gpuN is virtual (no PCI
#                 parent), so on this platform it does not, and the pods fall back to privileged + a /dev/infiniband hostPath (evidence recorded)
#   1. host       gpuA <-> gpuB in the root namespace: ib_write_bw with verbs (GID of the host rail address) and with RDMA CM (-R)
#   2. pods       rdma-a on gpuA, rdma-b on gpuB, both on default/net-rail-0: rail address, RDMA devices, the RoCE GID of the pod's macvlan address
#   3. pod GID    pod-to-pod ib_write_bw over the pod's OWN macvlan GID -- production's path. rdma_rxe before kernel 7.1 is init_net-only (route lookup and
#                 the UDP 4791 socket), so a pod namespace's RoCE packets are neither routed nor received: KNOWN there, PASS on a kernel with rxe netns support
#   4. host GID   pod-to-pod ib_write_bw through the shared rxe device with the host rail GID: pods do drive RDMA on the rail through the shared device
#   RDMA CM from a pod is deliberately NOT run: on rxe before 7.1 it puts the device's GSI QP (QP1) into ERR, and RDMA CM on that device stays dead --
#   for the host too -- until the device is re-created (seen 2026-09-24; netsetup.sh now re-creates such devices). NCCL uses verbs + its own socket
#   exchange, like tests 3 and 4, not RDMA CM.
#   5. health     QP1 of rxe_gpu0 in RTS on both nodes before (repaired through netsetup if not) and after
# Evidence: raw/*.txt, verdict.txt, PROBE.md. The pods install perftest themselves (ubuntu:24.04, ~1-2 min; no readinessProbe, see below).
set -u
cd "$(dirname "$0")"; . ./lib.sh
python3 -c 'import gen,sys; sys.exit(0 if gen.NETOP else 1)' || { echo "rdma-probe: no network-operator in this profile"; exit 0; }
A=${1:-gpu1}; B=${2:-gpu2}; TS=$(date -u +%Y%m%d_%H%M%S); OUT=${3:-audits/ai-fabric_rdma_probe_$TS}; mkdir -p "$OUT/raw"
export EVID="$PWD/$OUT/raw/commands.txt"; : > "$EVID"; R="$OUT/raw/probe.txt"; : > "$R"
sec() { { echo; echo "################ $*"; } | tee -a "$R"; }
alloc() { K "kubectl get node $1 -o jsonpath='{.status.allocatable.rdma/rdma_shared}'" | tail -1; }
qp1() { H $1 'rdma res show qp link rxe_gpu0/1' | awk '/type GSI/ {print $8}' | tail -1; }
bw() { awk '/^ *65536 +[0-9]+ +[0-9.]+ +[0-9.]+/ {print $4; exit}' "$1"; }
gidx() { grep -F "::ffff:$2" "$1" | sed -E 's/.*GID\[ *([0-9]+)\].*/\1/' | head -1; }
EX() { K "kubectl -n gpu exec $1 -- sh -c '$2'"; }

aa=$(alloc $A); ab=$(alloc $B)
if [ "${aa:-0}" -gt 0 ] 2>/dev/null && [ "${ab:-0}" -gt 0 ] 2>/dev/null; then MODE=plugin; else MODE=fallback; fi
sec "0. Plugin: mode $MODE (rdma/rdma_shared allocatable: $A=${aa:-0} $B=${ab:-0})"
{ echo "---- $A: rail NIC gpu0 vs its SoftRoCE device"
  H $A 'p=$(basename $(readlink -f /sys/class/net/gpu0/device/..)); echo "gpu0 -> PCI $p, driver $(basename $(readlink /sys/class/net/gpu0/device/driver)), RDMA devices under /sys/bus/pci/devices/$p/infiniband: $(ls /sys/bus/pci/devices/$p/infiniband 2>/dev/null || echo none)"
    echo "rxe_gpu0 -> $(readlink -f /sys/class/infiniband/rxe_gpu0) (parent netdev $(cat /sys/class/infiniband/rxe_gpu0/parent))"'
  echo "---- $A: rdma-shared-dev-plugin discovery log"
  K "p=\$(kubectl -n nvidia-network-operator get pods -l app=rdma-shared-dp --field-selector spec.nodeName=$A -o name); kubectl -n nvidia-network-operator logs \$p | grep -cE 'missing RDMA device spec' | sed 's/\$/ PCI network devices rejected: missing RDMA device spec/'; kubectl -n nvidia-network-operator logs \$p | grep -E 'no devices in device pool|exposing' | tail -2"
} 2>&1 | tee -a "$R" > "$OUT/raw/plugin-discovery.txt"

sec "5a. Health before: QP1 of rxe_gpu0"
for n in $A $B; do s=$(qp1 $n)
  if [ "$s" != RTS ]; then H $n 'systemctl restart ai-fabric-netsetup' >/dev/null; echo "$n: QP1 was ${s:-absent}, netsetup re-created the device -> $(qp1 $n)"
  else echo "$n: QP1 RTS"; fi; done 2>&1 | tee -a "$R"

sec "1. Host: $A <-> $B over rail 1, root namespace"
HA=$(H $A 'ip -4 -o addr show gpu0' | awk '{print $4}' | cut -d/ -f1 | tail -1); HB=$(H $B 'ip -4 -o addr show gpu0' | awk '{print $4}' | cut -d/ -f1 | tail -1)
H $A 'ibv_devinfo -d rxe_gpu0 -v' > "$OUT/raw/host-gids-$A.txt" 2>&1; H $B 'ibv_devinfo -d rxe_gpu0 -v' > "$OUT/raw/host-gids-$B.txt" 2>&1
GA=$(gidx "$OUT/raw/host-gids-$A.txt" $HA); GB=$(gidx "$OUT/raw/host-gids-$B.txt" $HB)
echo "$A gpu0 $HA (GID index ${GA:-?})   $B gpu0 $HB (GID index ${GB:-?})" | tee -a "$R"
for t in "verbs:-d rxe_gpu0 -x $GB:-d rxe_gpu0 -x $GA:18611" "rdmacm:-R:-R:18612"; do IFS=: read -r name so co port <<< "$t"
  H $B "nohup timeout 40 stdbuf -oL ib_write_bw $so -p $port -F -D 3 --report_gbits >/tmp/rdmaprobe-srv.txt 2>&1 </dev/null & sleep 1" >/dev/null
  { echo "---- host $name: $A -> $B"; H $A "timeout 30 stdbuf -oL ib_write_bw $co -p $port -F -D 3 --report_gbits $HB"; } > "$OUT/raw/host-$name.txt" 2>&1
  grep -E "rdma_cm QPs|GID index|^ *65536|rror|ail" "$OUT/raw/host-$name.txt" | tee -a "$R"; done

sec "2. Pods rdma-a on $A, rdma-b on $B (default/net-rail-0)"
pod() { cat <<EOF
apiVersion: v1
kind: Pod
metadata: {name: $1, namespace: gpu, labels: {app: rdmaprobe}, annotations: {k8s.v1.cni.cncf.io/networks: default/net-rail-0}}
spec:
  nodeSelector: {kubernetes.io/hostname: $2}
  tolerations: [{key: nvidia.com/gpu, operator: Exists, effect: NoSchedule}]
  terminationGracePeriodSeconds: 1
  containers:
  - name: t
    image: docker.io/library/ubuntu:24.04
    command: [sh, -c, "apt-get update -qq >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq perftest ibverbs-utils ibverbs-providers rdma-core iproute2 >/dev/null && touch /ready && sleep 1800"]
EOF
  if [ "$MODE" = plugin ]; then cat <<EOF
    securityContext: {capabilities: {add: [IPC_LOCK]}}
    resources: {limits: {rdma/rdma_shared: 1}}
---
EOF
  else cat <<EOF
    securityContext: {privileged: true}
    volumeMounts: [{name: ib, mountPath: /dev/infiniband}]
  volumes: [{name: ib, hostPath: {path: /dev/infiniband}}]
---
EOF
  fi; }
{ pod rdma-a $A; pod rdma-b $B; } > "$OUT/raw/pods.yaml"
docker cp "$OUT/raw/pods.yaml" $LAB-bastion:/tmp/rdmaprobe.yaml >/dev/null
# no readinessProbe: a probe failing every 5 s while apt installs perftest is a Warning event each time (Headlamp); wait for /ready by exec instead
KT=600 K "kubectl -n gpu delete pod -l app=rdmaprobe --wait=true >/dev/null 2>&1; kubectl apply -f /tmp/rdmaprobe.yaml >/dev/null
  kubectl -n gpu wait --for=condition=Ready pod -l app=rdmaprobe --timeout=240s >/dev/null || exit 1
  for i in \$(seq 1 100); do kubectl -n gpu exec rdma-a -- test -f /ready 2>/dev/null && kubectl -n gpu exec rdma-b -- test -f /ready 2>/dev/null && break; sleep 5; done
  kubectl -n gpu exec rdma-a -- test -f /ready && kubectl -n gpu exec rdma-b -- test -f /ready && echo 'rdma-a, rdma-b running with perftest installed'" | tee -a "$R"
IA=$(EX rdma-a 'ip -4 -o addr show net1' | awk '{print $4}' | cut -d/ -f1 | tail -1); IB=$(EX rdma-b 'ip -4 -o addr show net1' | awk '{print $4}' | cut -d/ -f1 | tail -1)
for p in rdma-a rdma-b; do { echo "---- $p"; EX $p 'ip -br addr show net1; ls /dev/infiniband 2>&1 | tr "\n" " "; echo; ibv_devices'; } 2>&1 | tee -a "$R" > "$OUT/raw/$p-devices.txt"; done
EX rdma-a 'ibv_devinfo -d rxe_gpu0 -v' > "$OUT/raw/pod-gids-rdma-a.txt" 2>&1; EX rdma-b 'ibv_devinfo -d rxe_gpu0 -v' > "$OUT/raw/pod-gids-rdma-b.txt" 2>&1
{ echo "---- rxe_gpu0 as rdma-a sees it: the RoCE GID of the pod's own rail address $IA is what production's macvlan + shared RDMA device relies on"
  grep -E "state:|active_mtu|GID\[" "$OUT/raw/pod-gids-rdma-a.txt"; } 2>&1 | tee -a "$R" > "$OUT/raw/gids.txt"
PA=$(gidx "$OUT/raw/pod-gids-rdma-a.txt" $IA); PB=$(gidx "$OUT/raw/pod-gids-rdma-b.txt" $IB)
QA=$(gidx "$OUT/raw/pod-gids-rdma-a.txt" $HA); QB=$(gidx "$OUT/raw/pod-gids-rdma-b.txt" $HB)
[ "$MODE" = plugin ] && { echo "---- rdma-a resource request"; K "kubectl -n gpu get pod rdma-a -o jsonpath='{.spec.containers[0].resources}'"; echo; } 2>&1 | tee -a "$R"

# the out-of-band exchange of both tests runs over net1 (rdma-b's rail address); separate ports, so a server left waiting cannot collide
podbw() { local name=$1 xs=$2 xc=$3 port=$4
  EX rdma-b "(timeout 40 stdbuf -oL ib_write_bw -d rxe_gpu0 -x $xs -p $port -F -D 3 --report_gbits >/tmp/srv-$name.txt 2>&1 &)" >/dev/null; sleep 2
  { echo "---- pod $name: rdma-a -> rdma-b $IB, GID index client $xc / server $xs"
    KT=60 K "kubectl -n gpu exec rdma-a -- timeout 30 stdbuf -oL ib_write_bw -d rxe_gpu0 -x $xc -p $port -F -D 3 --report_gbits $IB"; } > "$OUT/raw/pod-$name.txt" 2>&1
  grep -E "GID:|^ *65536|rror|ail|terminated" "$OUT/raw/pod-$name.txt" | tee -a "$R"; }
sec "3. Pod-to-pod over the pods' own macvlan GIDs ($IA -> $IB): production's path"
podbw podgid "${PB:-2}" "${PA:-2}" 18613
sec "4. Pod-to-pod through the shared rxe device with the host rail GIDs ($HA -> $HB)"
podbw hostgid "${QB:-1}" "${QA:-1}" 18614
K "kubectl -n gpu delete pod -l app=rdmaprobe --wait=false >/dev/null 2>&1"

sec "5b. Health after: QP1 of rxe_gpu0"
SA=$(qp1 $A); SB=$(qp1 $B); echo "$A: QP1 $SA   $B: QP1 $SB" | tee -a "$R"
KV=$(H $A 'echo "$(uname -r) rxe_ns-symbols=$(grep -c rxe_ns /proc/kallsyms)"' | tail -1); echo "$A kernel: $KV" | tee -a "$R"

B1=$(bw "$OUT/raw/host-verbs.txt"); B2=$(bw "$OUT/raw/host-rdmacm.txt"); B3=$(bw "$OUT/raw/pod-podgid.txt"); B4=$(bw "$OUT/raw/pod-hostgid.txt")
pos() { awk -v b="${1:-0}" 'BEGIN {exit !(b + 0 > 0)}'; }
{ printf "\n== Verdict (SoftRoCE probe %s <-> %s over rail 1, mode %s; SoftRoCE in software on a VM: rates prove the path, not a speed)\n" "$A" "$B" "$MODE"
  if [ "$MODE" = plugin ]; then ok "rdma-shared-dev-plugin advertises rdma/rdma_shared on both nodes ($A=$aa, $B=$ab) and the pods were scheduled with it"
  else known "rdma-shared-dev-plugin advertises no rdma/rdma_shared (it finds RDMA devices under the NIC's PCI device; rxe_gpuN is virtual, see raw/plugin-discovery.txt)" \
         "production gets the resource from ConnectX; this lab ran the pods privileged with /dev/infiniband mounted instead"; fi
  pos "$B1" && ok "host $A -> $B, verbs over rail 1 (GID $HA -> $HB): $B1 Gbit/s" || bad "host $A -> $B, verbs over rail 1" "$(grep -E 'rror|ail' "$OUT/raw/host-verbs.txt" | head -1)"
  pos "$B2" && ok "host $A -> $B, RDMA CM (-R) over rail 1: $B2 Gbit/s" || bad "host $A -> $B, RDMA CM (-R) over rail 1" "$(grep -E 'rror|ail' "$OUT/raw/host-rdmacm.txt" | head -1)"
  chk "both pods got a rail-1 address from default/net-rail-0" 2 "$(printf '%s\n' $IA $IB | grep -c '^172\.16\.1\.')"
  ge "rdma-a sees RDMA devices (ibv_devices lists rxe_gpuN)" 1 "$(grep -c 'rxe_gpu' "$OUT/raw/rdma-a-devices.txt")"
  ge "rxe_gpu0's GID table holds rdma-a's own rail address $IA (macvlan + shared RDMA device, as in production)" 1 "$(grep -c "::ffff:$IA" "$OUT/raw/gids.txt")"
  if pos "$B3"; then ok "pod-to-pod over the pods' own macvlan GIDs ($IA -> $IB, production's path): $B3 Gbit/s"
  elif [ "${KV##*rxe_ns-symbols=}" = 0 ]; then known "pod-to-pod RoCE over the pods' own macvlan GIDs (production's path) fails: $(grep -E 'rror|ail' "$OUT/raw/pod-podgid.txt" | head -1 | sed 's/^ *//')" \
    "rdma_rxe on kernel ${KV%% *} is init_net-only (route lookup + UDP 4791 socket); rxe netns support is upstream from v7.1 (commit 13f2a53); ConnectX does this in hardware"
  else bad "pod-to-pod over the pods' own macvlan GIDs" "$(grep -E 'rror|ail' "$OUT/raw/pod-podgid.txt" | head -1)"; fi
  pos "$B4" && ok "pod-to-pod through the shared rxe device with the host rail GIDs ($HA -> $HB): $B4 Gbit/s" || bad "pod-to-pod through the shared rxe device (host GIDs)" "$(grep -E 'rror|ail|terminated' "$OUT/raw/pod-hostgid.txt" | head -1)"
  known "RDMA CM (-R) from a pod network namespace: not run" "on rdma_rxe before v7.1 it puts the device's GSI QP (QP1) into ERR, killing RDMA CM on it for the host as well until the device is re-created"
  chk "QP1 of rxe_gpu0 still RTS on $A and $B after the probe" "RTS RTS" "$SA $SB"
  summary; } > "$OUT/verdict.txt"; RC=$?; cat "$OUT/verdict.txt" | tee -a "$R"
{ echo "# ai-fabric SoftRoCE probe, $TS"; echo
  echo "Rail 1 (gpu0 -> be-leaf1, bridged on the leaf) between **$A** ($HA) and **$B** ($HB); pods **rdma-a** ($IA) and **rdma-b** ($IB) on \`default/net-rail-0\`. Mode: **$MODE**. Kernel: $KV."; echo
  echo "Production: rdma-shared-dev-plugin hands the pod the ConnectX RDMA device; the MacvlanNetwork gives it a rail address, whose RoCE GID the pod's QPs use."
  echo "Here SoftRoCE (rxe_gpuN) stands in for ConnectX. The layers: plugin discovery, host-to-host RoCE, pod-to-pod over the pod's own GID, pod-to-pod over the host GID."
  echo; echo "## Verdict"; echo '```'; cat "$OUT/verdict.txt"; echo '```'
  for f in host-verbs host-rdmacm pod-podgid pod-hostgid; do echo; echo "## $f"; echo '```'; grep -vE '^ *$|^-+$' "$OUT/raw/$f.txt" | tail -14; echo '```'; done
  echo; echo "## Devices and GIDs (rdma-a)"; echo '```'; cat "$OUT/raw/rdma-a-devices.txt" "$OUT/raw/gids.txt"; echo '```'
  echo; echo "## Why the plugin finds no SoftRoCE device"; echo '```'; cat "$OUT/raw/plugin-discovery.txt"; echo '```'; } > "$OUT/PROBE.md"
keep_latest ai-fabric_rdma_probe "$OUT"
echo; echo "SoftRoCE probe -> $OUT"; exit $RC
