#!/bin/bash
# OPERATOR STEP -- secrets-to-s3.sh: copy the platform's tokens and passwords out of their Kubernetes Secrets into the PRIVATE S3 bucket
# `lab-secrets` (MinIO on the storage node; https://s3-console.platform.lab.ai). Run it yourself:   ssh site-b /root/ai-fabric/secrets-to-s3.sh
# Re-run after any password change (objects are overwritten). Runs inside the bastion; every value goes Secret -> pipe -> S3 over TLS.
# NOTHING is printed, logged or written to disk: the output is object names, HTTP codes and sizes only.
#   harbor/admin-password            Harbor  https://harbor.platform.lab.ai        user admin
#   s3/root-user, s3/root-password   S3      https://s3-console.platform.lab.ai    (the key that opens this very bucket)
#   headlamp/admin-token             Headlamp https://headlamp.platform.lab.ai     token login
#   inference/litellm-master-key     bearer key of https://inference.platform.lab.ai (only with post-deploy.sh --gateway)
#   ai-sim/llm-api-key               bearer key of the lab's own model, Service llm in ai-sim (post-deploy.sh)
#   webui/openrouter-api-key         YOUR OpenRouter API key, if you set one. Remove that line below to keep it out of S3.
# NOT copied on purpose: the cluster CA's private key, the admin kubeconfig, and the switch/firewall image-default logins (the lab reaches
# devices with SSH keys). WARNING: anyone holding the S3 root key can read all of this. The bucket is private (no anonymous policy);
# a secrets manager (Vault + External Secrets) is the production answer, a bucket is a lab convenience.
set -uo pipefail
B=$(docker ps --format '{{.Names}}' | grep -E '^clab-ai-fabric-.*bastion' | head -1); [ -n "$B" ] || { echo "no ai-fabric bastion running" >&2; exit 1; }
docker exec -i "$B" bash -l -s <<'INNER'
set -u
# login shell: /etc/profile.d/operator-shell.sh sets KUBECONFIG; make sure of it, and stop early if the cluster does not answer
export KUBECONFIG=${KUBECONFIG:-/var/opt/ai-fabric/clusters/current/kubeconfig.yaml}
kubectl get ns s3 >/dev/null 2>&1 || { echo "kubectl on the bastion cannot reach the cluster (KUBECONFIG=$KUBECONFIG)"; exit 1; }
CA=/shared/ai-fabric/cluster-ca.crt; EP=https://s3.platform.lab.ai; BK=lab-secrets
CFG=$(mktemp -p /dev/shm); chmod 600 "$CFG"; trap 'rm -f "$CFG"' EXIT          # curl reads the S3 key from a 0600 tmpfs file, not from its command line
AK=$(kubectl -n s3 get secret minio-root -o jsonpath='{.data.rootUser}' | base64 -d); SK=$(kubectl -n s3 get secret minio-root -o jsonpath='{.data.rootPassword}' | base64 -d)
[ -n "$AK" ] && [ -n "$SK" ] || { echo "Secret s3/minio-root not found: run ./harbor-deploy.sh first"; exit 1; }
printf 'user = "%s:%s"\naws-sigv4 = "aws:amz:us-east-1:s3"\ncacert = "%s"\nsilent\nshow-error\n' "$AK" "$SK" "$CA" > "$CFG"; unset SK
s3() { curl -K "$CFG" "$@"; }
c=$(s3 -o /dev/null -w '%{http_code}' -X PUT "$EP/$BK"); echo "bucket $BK: HTTP $c  (200 = created, 409 = already there)"
put() { local v c; v=$(kubectl -n "$1" get secret "$2" -o jsonpath="{.data.$3}" 2>/dev/null | base64 -d); [ -n "$v" ] || { echo "  skip  $4   (no Secret $1/$2 key $3)"; return; }
  c=$(printf '%s' "$v" | s3 -o /dev/null -w '%{http_code}' -X PUT -H 'Content-Type: text/plain' --data-binary @- "$EP/$BK/$4"); unset v; echo "  HTTP $c  $4"; }
put harbor    harbor-admin          HARBOR_ADMIN_PASSWORD  harbor/admin-password
put s3        minio-root            rootUser               s3/root-user
put s3        minio-root            rootPassword           s3/root-password
put headlamp  headlamp-admin-token  token                  headlamp/admin-token
put inference litellm-secret        master-key             inference/litellm-master-key
put ai-sim    llm-api-key           key                    ai-sim/llm-api-key
put webui     openrouter            api-key                webui/openrouter-api-key
printf '%s\n' "ai-fabric lab credentials, copied from Kubernetes Secrets by secrets-to-s3.sh on $(date -u +%FT%TZ)" "" \
  "harbor/admin-password          Harbor     https://harbor.platform.lab.ai       user: admin" \
  "s3/root-user, s3/root-password S3 / MinIO https://s3-console.platform.lab.ai   API: https://s3.platform.lab.ai" \
  "headlamp/admin-token           Headlamp   https://headlamp.platform.lab.ai     token login" \
  "inference/litellm-master-key   inference  https://inference.platform.lab.ai    Authorization: Bearer <key>" \
  "ai-sim/llm-api-key             the model  Service llm.ai-sim:8080 (OpenAI API)  Authorization: Bearer <key>" \
  "webui/openrouter-api-key       OpenRouter API key, only if you set one" "" \
  "Source of truth = the Kubernetes Secrets; re-run the script after changing a password." \
  | s3 -o /dev/null -w '  HTTP %{http_code}  INDEX.txt\n' -X PUT -H 'Content-Type: text/plain' --data-binary @- "$EP/$BK/INDEX.txt"
echo "objects now in $BK (name, bytes):"; s3 "$EP/$BK?list-type=2" | tr '<' '\n' | awk -F'>' '$1 == "Key" {k = $2} $1 == "Size" {printf "  %-34s %s\n", k, $2}'
INNER
