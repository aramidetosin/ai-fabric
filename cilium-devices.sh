#!/bin/bash
# cilium-devices.sh: keep the RUNNING Cilium's device list equal to gen.py's CILIUM_DEVICES. The bootstrap installs Cilium only when its DaemonSet is
# missing, so a changed list never reaches an existing cluster by itself -- site-a-nx moved the storage node's tagged data VLAN 10 -> 100
# (bond0.10 -> bond0.100), and BPF masquerade + the host datapath only cover LISTED devices. Compared as sets; no difference = no helm call.
# CHECK=1 only reports (validation section A). finish.sh stage 3 runs it after node-sync.
# The agents read cilium-config only at start, and a --reuse-values upgrade that changes nothing but the ConfigMap does NOT roll the DaemonSet
# (2026-09-23: config said bond0.100, every agent still ran bond0.10; the storage node -- the only guest whose data address is on the tagged
# sub-interface -- lost its service translation, and its host traffic to 10.43.0.1 leaked to the firewall). So: restart the agents after the
# upgrade, and treat any agent older than the ConfigMap's last write as drift too.
cd "$(dirname "$0")"; . ./lib.sh
read -r WANT VER <<< "$(python3 -c 'import gen; print(gen.CILIUM_DEVICES, gen.K8S["cilium_version"])')"
norm() { tr ', ' '\n\n' | grep -v '^$' | sort -u | xargs; }
have=$(K "kubectl -n kube-system get cm cilium-config -o jsonpath={.data.devices}" | tail -1)
# agents started before the ConfigMap's last write still run the previous device list (RFC3339 UTC timestamps sort as strings)
stale() { K "c=\$(kubectl -n kube-system get cm cilium-config -o jsonpath='{.metadata.managedFields[*].time}' | tr ' ' '\n' | sort | tail -1)
  kubectl -n kube-system get pods -l k8s-app=cilium -o jsonpath='{range .items[*]}{.metadata.creationTimestamp}{\"\n\"}{end}' | awk -v c=\"\$c\" 'NF && \$1 < c' | wc -l" | tail -1; }
restart() { KT=1200 K "kubectl -n kube-system rollout restart ds/cilium >/dev/null && kubectl -n kube-system rollout status ds/cilium --timeout=1100s | tail -1"; }
if [ "$(norm <<< "$have")" = "$(norm <<< "$WANT")" ]; then
  n=$(stale); [ "${n:-0}" = 0 ] && { echo "cilium devices: in sync ($(norm <<< "$have")), every agent started after the config"; exit 0; }
  [ -n "${CHECK:-}" ] && { echo "cilium devices: config in sync but $n agent(s) started before it (still running the old list)"; exit 1; }
  echo "cilium devices: config in sync, $n agent(s) older than it: rolling restart"; restart || { echo "cilium devices: restart FAILED"; exit 1; }
  echo "cilium devices: agents restarted ($(stale) stale)"; exit 0
fi
[ -n "${CHECK:-}" ] && { echo "cilium devices: DRIFT running '$have', repository '$WANT'"; exit 1; }
echo "cilium devices: '$have' -> '$WANT' (helm upgrade --reuse-values, rolling restart of the agents)"
KT=1200 K "helm repo add cilium https://helm.cilium.io/ --force-update >/dev/null 2>&1; helm repo update cilium >/dev/null 2>&1
  helm -n kube-system upgrade cilium cilium/cilium --version $VER --reuse-values --set devices='{$WANT}' --wait --timeout 15m >/dev/null" \
  || { echo "cilium devices: helm upgrade FAILED"; exit 1; }
restart || { echo "cilium devices: agent restart FAILED"; exit 1; }
now=$(K "kubectl -n kube-system get cm cilium-config -o jsonpath={.data.devices}" | tail -1)
[ "$(norm <<< "$now")" = "$(norm <<< "$WANT")" ] && echo "cilium devices: now $(norm <<< "$now")" || { echo "cilium devices: still '$now'"; exit 1; }
