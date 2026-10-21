#!/usr/bin/env bash
# Deploy the APISIX + LiteLLM inference gateway. Runs on the
# lab host (uses docker exec into each bastion and python3 on the host).
#
#   scripts/deploy-inference.sh [lab]              # default: ai-fabric
#
# Endpoint per lab:
#   https://inference.platform.<domain>/models/<uuid>/proxy/v1/chat/completions
#   Authorization: Bearer <master key>
#
# The master key is generated once and stored in secret inference/litellm-secret
# (reused on re-runs). Pass INFER_API_KEY=sk-... to seed the same key across labs
# on first deploy. The OpenRouter key is copied from secret webui/openrouter, so
# scripts/openrouter-secret.sh must have run. Nothing secret is written to the repo.
set -u
bastion_of() { docker ps --format "{{.Names}}" | grep -E "^clab-(.+-)?$1-.*bastion" | head -1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
LABS=${*:-"ai-fabric"}
DOM="${LAB_DOMAIN:-lab.ai}"
for D in $LABS; do
  B="$(bastion_of "$D")"
  docker ps --format '{{.Names}}' | grep -qx "$B" || { echo "$D: no bastion ($B), skipping"; continue; }
  ex() { docker exec -i "$B" bash -lc "$1"; }
  echo "=== $D"
  ex "kubectl create ns inference --dry-run=client -o yaml | kubectl apply -f - >/dev/null"
  KEY=$(ex "kubectl -n inference get secret litellm-secret -o jsonpath='{.data.master-key}' 2>/dev/null" | base64 -d 2>/dev/null || true)
  if [ -z "$KEY" ]; then KEY="${INFER_API_KEY:-sk-aif-$(openssl rand -hex 16)}"; fi
  ORK=$(ex "kubectl -n webui get secret openrouter -o jsonpath='{.data.api-key}' 2>/dev/null" | base64 -d 2>/dev/null || true)
  if [ -z "$ORK" ]; then echo "$D: secret webui/openrouter missing; run scripts/openrouter-secret.sh first"; continue; fi
  ex "kubectl -n inference create secret generic litellm-secret \
        --from-literal=master-key='$KEY' --from-literal=openrouter-key='$ORK' \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null"
  python3 "$HERE/gen-inference.py" "$D" | ex "kubectl apply -f -" >/dev/null
  ex "kubectl -n inference rollout status deploy/apisix  --timeout=180s" || true
  ex "kubectl -n inference rollout status deploy/litellm --timeout=420s" || true
  echo "$D endpoints (Authorization: Bearer $KEY):"
  python3 "$HERE/gen-inference.py" "$D" map | while IFS=$'\t' read -r model uuid; do
    printf '  %-34s https://inference.platform.%s/models/%s/proxy/v1/chat/completions\n' "$model" "$DOM" "$uuid"
  done
done

# wire the gateway into each lab's Open WebUI as a second OpenAI backend
bash "$HERE/webui-add-inference.sh" $LABS
