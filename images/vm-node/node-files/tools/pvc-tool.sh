#!/bin/bash
# pvc-tool.sh (platform nodes only, not the bastion): provision a Longhorn PVC through the storage node's management API (the FlashBlade-style API on the OOB
# address 10.1.2.16 in ai-fabric), the way the platform's CSI driver would, then prove the volume by writing to it from a pod.
# The API call leaves this node via the fabric, crosses the firewall (rule fabric -> oob tcp/443) and the OOB network.
#   pvc-tool.sh create <name> <size, e.g. 2Gi> [namespace]   # API call + wait for Bound
#   pvc-tool.sh test   <name> <size> [namespace]              # create + pod that writes/reads the volume, then cleanup
#   pvc-tool.sh list | delete <name> [namespace] | version | arrays
set -uo pipefail
FB=${FB_MGMT:-10.1.2.16}; TOKEN=${FB_TOKEN:-lab-storage-api-token}; KC=${KUBECONFIG:-/shared/ai-fabric/kubeconfig}
# FB_CACERT (site-a-nx lab CA): verify the storage API's certificate against the lab root instead of skipping verification (-k)
TLS=(-k); [ -n "${FB_CACERT:-}" ] && [ -s "$FB_CACERT" ] && TLS=(--cacert "$FB_CACERT")
api() { curl -s "${TLS[@]}" --max-time 150 -H "api-token: $TOKEN" -H "Content-Type: application/json" "$@"; }
to_bytes() { python3 -c 'import sys,re; s=sys.argv[1]; m=re.match(r"(\d+)([KMGT]i?)?",s); n=int(m.group(1)); u=(m.group(2) or "").rstrip("i"); print(n*{"":1,"K":1<<10,"M":1<<20,"G":1<<30,"T":1<<40}[u])' "$1"; }
cmd=${1:-help}; name=${2:-}; size=${3:-1Gi}; ns=${4:-default}
case "$cmd" in
  version) api "https://$FB/api/api_version";;
  arrays)  api "https://$FB/api/2.4/arrays";;
  list)    api "https://$FB/api/2.4/file-systems";;
  delete)  api -X DELETE "https://$FB/api/2.4/file-systems?names=$name&namespace=${3:-default}";;
  create|test)
    [ -n "$name" ] || { echo "usage: $0 $cmd <name> <size> [namespace]"; exit 2; }
    echo "== $(hostname) -> storage mgmt API https://$FB (path: fabric -> firewall rule fabric->oob 443 -> OOB): create file-system '$name' $size in $ns"
    ip route get "$FB" | head -1 | sed 's/^/   route: /'
    api -X POST -w '   http=%{http_code} time=%{time_total}s\n' -d "{\"provisioned\": $(to_bytes "$size"), \"namespace\": \"$ns\"}" "https://$FB/api/2.4/file-systems?names=$name"
    [ "$cmd" = test ] || exit 0
    command -v kubectl >/dev/null || { echo "no kubectl here; PVC state via the API:"; api "https://$FB/api/2.4/file-systems?names=$name"; exit 0; }
    echo "== pod writing to the volume (data path: Longhorn on the storage node over the fabric)"
    kubectl --kubeconfig "$KC" -n "$ns" delete pod "pvc-test-$name" --ignore-not-found >/dev/null 2>&1
    kubectl --kubeconfig "$KC" -n "$ns" apply -f - >/dev/null <<Y
apiVersion: v1
kind: Pod
metadata: {name: pvc-test-$name}
spec:
  restartPolicy: Never
  containers:
  - name: t
    image: busybox:1.36
    command: ["sh","-c","echo written-by-$(hostname)-$(date -u +%FT%TZ) > /data/proof.txt && cat /data/proof.txt && df -h /data"]
    volumeMounts: [{name: v, mountPath: /data}]
  volumes: [{name: v, persistentVolumeClaim: {claimName: $name}}]
Y
    for i in $(seq 1 60); do p=$(kubectl --kubeconfig "$KC" -n "$ns" get pod "pvc-test-$name" -o jsonpath='{.status.phase}' 2>/dev/null); [ "$p" = Succeeded ] || [ "$p" = Failed ] && break; sleep 3; done
    echo "   pod phase: $p"; kubectl --kubeconfig "$KC" -n "$ns" logs "pvc-test-$name" 2>/dev/null | sed 's/^/   /'
    kubectl --kubeconfig "$KC" -n "$ns" get pvc "$name" -o wide | sed 's/^/   /'
    kubectl --kubeconfig "$KC" -n "$ns" delete pod "pvc-test-$name" --ignore-not-found --wait=true >/dev/null 2>&1
    # let Longhorn detach the volume before the file system is deleted through the API (otherwise the PV deleter retries
    # with VolumeFailedDelete until the VolumeAttachment is gone)
    pv=$(kubectl --kubeconfig "$KC" -n "$ns" get pvc "$name" -o jsonpath='{.spec.volumeName}' 2>/dev/null)
    for i in $(seq 1 40); do kubectl --kubeconfig "$KC" get volumeattachment -o jsonpath='{.items[*].spec.source.persistentVolumeName}' 2>/dev/null | grep -qw "$pv" || break; sleep 3; done
    echo "== cleanup: DELETE via the API (volume detached: $([ -n "$pv" ] && echo "$pv"))"; api -X DELETE "https://$FB/api/2.4/file-systems?names=$name&namespace=$ns"; echo;;
  *) sed -n 2,8p "$0";;
esac
