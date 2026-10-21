#!/bin/bash
# Create the OpenRouter API key Secret that Open WebUI waits for, in every running lab (or the labs given).
# Run on the lab host by the operator; the key is read from the terminal, never stored in the repo.
# Usage: scripts/openrouter-secret.sh [lab]        (default: ai-fabric)
# Needs a terminal: without one the hidden prompt cannot switch echo off and the key would be printed as you type.
set -uo pipefail
bastion_of() { docker ps --format "{{.Names}}" | grep -E "^clab-(.+-)?$1-.*bastion" | head -1; }
SD=$(cd "$(dirname "$0")" && pwd); cd "$SD/.."
LABS=${*:-ai-fabric}
[ -t 0 ] && [ -t 1 ] || { echo "openrouter-secret.sh needs a terminal so the key prompt stays hidden: use  ssh -t <host> ..." >&2; exit 2; }
read -r -s -p "OpenRouter API key (sk-or-...): " KEY; echo
[ -n "$KEY" ] || { echo "no key given"; exit 1; }
for D in $LABS; do
  docker exec -i "$(bastion_of "$D")" bash -lc "kubectl create ns webui --dry-run=client -o yaml | kubectl apply -f - >/dev/null; \
    kubectl -n webui create secret generic openrouter --from-literal=api-key='$KEY' --dry-run=client -o yaml | kubectl apply -f - && \
    kubectl -n webui rollout restart deploy/open-webui >/dev/null 2>&1; echo \"$D: secret webui/openrouter applied\""
  # once the pod is back with the key, hide OpenRouter's batch-only model variants (they refuse chat requests)
  docker exec -i "$(bastion_of "$D")" bash -lc "kubectl -n webui rollout status deploy/open-webui --timeout=300s >/dev/null 2>&1; sleep 20" \
    && docker exec -i "$(bastion_of "$D")" bash -s -- "$D" < "$SD/webui-hide-batch.sh"
done
unset KEY
