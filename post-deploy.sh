#!/bin/bash
# post-deploy.sh [--gateway]: OPERATOR STEP -- run it once ./status.sh shows every node Ready.
#
# DEFAULT (no flag, no API key, nothing typed): brings up the lab's OWN model on the GPU nodes and wires Open
# WebUI to it, so https://webui.platform.<domain> answers chat requests with nothing outside the lab involved.
#   1. ./llm-serve.sh up   two llama-server replicas, each with two RPC workers over the rails (namespace
#                          ai-sim). It calls ./ai-sim-build.sh itself when a GPU node is missing the image
#                          (llama.cpp + an Apache-2.0 GGUF, downloaded once into images/ai-sim/dl/).
#   2. ./webui-wire.sh     copies the bearer token into Secret webui/inference-key and points Open WebUI at it.
# Plain ssh is fine for this: nothing is prompted and no secret is printed.
#
# --gateway ALSO deploys the APISIX + LiteLLM inference gateway (scripts/) and publishes
# inference.platform.<domain>. Its three curated models are served through OpenRouter, so this branch PROMPTS
# for an OpenRouter API key and needs a terminal:
#
#   ssh -t <host> <repo>/post-deploy.sh --gateway        <-- the -t matters
#
# Without a terminal the hidden prompt cannot switch echo off and the key would be PRINTED as you type, so the
# gateway branch refuses to run without one. The key is stored only as a Kubernetes Secret, never on disk or in
# the repo. The lab's own model is then added to the gateway as a fourth model (./inference-local-model.sh),
# which needs no key at all.
set -uo pipefail
cd "$(dirname "$0")"
HERE="$PWD"
GATEWAY=0
case "${1:-}" in
  "") ;;
  --gateway) GATEWAY=1 ;;
  *) echo "usage: post-deploy.sh [--gateway]" >&2; exit 2 ;;
esac

B=$(docker ps --format '{{.Names}}' | grep -E '^clab-ai-fabric-.*bastion' | head -1)
[ -n "$B" ] || { echo "no running ai-fabric bastion container: is the lab up (./status.sh)?" >&2; exit 1; }
docker exec "$B" bash -lc 'kubectl get nodes >/dev/null 2>&1' \
  || { echo "the bastion ($B) cannot reach the cluster yet: wait for the bootstrap (./status.sh)" >&2; exit 1; }
DOMAIN=$(python3 -c 'import gen; print(gen.DOMAIN)')

if [ "$GATEWAY" = 1 ] && { [ ! -t 0 ] || [ ! -t 1 ]; }; then
  echo "post-deploy.sh --gateway needs a terminal so the API key prompt stays hidden." >&2
  echo "Run:  ssh -t $(hostname) $HERE/post-deploy.sh --gateway" >&2
  exit 2
fi

echo "== 1/2 the lab's own model on the GPU nodes (llm-serve.sh)"
echo "   First run downloads and builds the model image, so this takes a while and goes quiet. That is normal."
./llm-serve.sh up

echo "== 2/2 Open WebUI -> that model (webui-wire.sh)"
./webui-wire.sh local

if [ "$GATEWAY" = 1 ]; then
  export LAB_DOMAIN=$DOMAIN
  echo "== + OpenRouter key (Secret webui/openrouter), for the gateway's three curated models"
  scripts/openrouter-secret.sh ai-fabric
  docker exec "$B" bash -lc 'kubectl -n webui get secret openrouter >/dev/null 2>&1' \
    || { echo "the key Secret was not created: stopping here, the local model above is untouched" >&2; exit 1; }
  echo "== + inference gateway (APISIX + LiteLLM) -- a few minutes; it ends by printing the endpoints"
  scripts/deploy-inference.sh ai-fabric
  echo "== + the lab's own model as a fourth model of the gateway"
  ./inference-local-model.sh || echo "   WARNING: not added (run ./inference-local-model.sh once the rails forward)"
  echo "== + the gateway as a second Open WebUI backend"
  ./webui-wire.sh gateway
fi

echo "== done"
echo "   Open WebUI    https://webui.platform.$DOMAIN      (./webui-wire.sh status)"
[ "$GATEWAY" = 1 ] && echo "   inference     https://inference.platform.$DOMAIN   (bearer key: ./show-creds.sh)"
DNSH=$(python3 -c 'import gen; print(f"the lab DNS server {gen.DNS_NTP}" if gen.DNS_NTP else f"the bastion DNS {gen.BASTION_IP}")')
echo "   (names resolve via $DNSH; try them from pc-1 / pc-2, the bastion, or a workstation with publish/hosts)"
