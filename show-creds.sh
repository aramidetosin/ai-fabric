#!/bin/bash
# show-creds.sh: print this lab's service credentials ON YOUR TERMINAL. They are read straight from the Kubernetes Secrets that
# harbor-deploy.sh / post-deploy.sh generated in-cluster; the same values secrets-to-s3.sh copies into the lab-secrets bucket.
# TTY-guarded on purpose: refuses to run over a pipe or a non-interactive ssh, so the values never land in a log or a transcript.
#   ssh -t <host> <repo>/show-creds.sh
set -uo pipefail
[ -t 1 ] || { echo "refusing: stdout is not a terminal -- run it as:  ssh -t <host> <repo>/show-creds.sh" >&2; exit 1; }
B=$(docker ps --format '{{.Names}}' | grep -E '^clab-ai-fabric-.*bastion' | head -1)
[ -n "$B" ] || { echo "no ai-fabric bastion running" >&2; exit 1; }
docker exec -i "$B" bash -l -s <<'INNER'
set -u
export KUBECONFIG=${KUBECONFIG:-/var/opt/ai-fabric/clusters/current/kubeconfig.yaml}
kubectl get ns s3 >/dev/null 2>&1 || { echo "kubectl on the bastion cannot reach the cluster"; exit 1; }
get() { kubectl -n "$1" get secret "$2" -o jsonpath="{.data.$3}" 2>/dev/null | base64 -d; }
line() { local v; v=$(get "$2" "$3" "$4"); printf '%-34s %-18s %s\n' "$1" "${5:-}" "${v:-<not set: run the step that creates it>}"; }
printf '%-34s %-18s %s\n' 'URL' 'USER' 'SECRET'
line 'https://harbor.platform.lab.ai'     harbor    harbor-admin         HARBOR_ADMIN_PASSWORD admin
printf '%-34s %-18s %s\n' 'https://s3-console.platform.lab.ai' "$(get s3 minio-root rootUser)" "$(get s3 minio-root rootPassword)"
line 'https://headlamp.platform.lab.ai'   headlamp  headlamp-admin-token token                 '<token login>'
line 'https://inference.platform.lab.ai'  inference litellm-secret       master-key            '<Bearer>'
echo
echo 'Harbor: change the bootstrap password with  ssh -t <host> <repo>/harbor-password.sh'
INNER
