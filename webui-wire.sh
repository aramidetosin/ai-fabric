#!/bin/bash
# webui-wire.sh [local|gateway|status]: point Open WebUI at a model and give it the token it needs.
#
#   local    (default) the lab's OWN model: Service llm in namespace ai-sim, served from the GPU nodes by
#            ./llm-serve.sh. Copies that service's bearer token into Secret webui/inference-key INSIDE the
#            cluster (the value is never printed and never written to the repo), points Open WebUI's
#            OPENAI_API_BASE_URL at the service, restarts it and checks that it offers the model.
#   gateway  ADD the inference gateway (APISIX > LiteLLM) as a second OpenAI-compatible backend, keeping the
#            first one: scripts/webui-add-inference.sh. Needs scripts/deploy-inference.sh to have run.
#   status   what Open WebUI is pointed at, whether the token is there, how many models it offers.
#
# Prompts for nothing and prints no secret, so plain ssh is fine. Run it on the lab host.
set -uo pipefail
cd "$(dirname "$0")"; . ./lib.sh; unset EVID
MODE=${1:-local}
BASE=${WEBUI_API_BASE:-http://llm.ai-sim.svc.cluster.local:8080/v1}
DOMAIN=$(python3 -c 'import gen; print(gen.DOMAIN)')
H="webui.platform.$DOMAIN"

# Open WebUI runs single-user (WEBUI_AUTH=false), so an empty sign-in returns the admin token. It is minted and
# used inside the bastion and never leaves it: only the model count comes back here.
models() { KT=240 K "T=\$(curl -sk -m 20 -H 'Content-Type: application/json' https://$H/api/v1/auths/signin -d '{\"email\":\"\",\"password\":\"\"}' | jq -r '.token // empty'); [ -n \"\$T\" ] || { echo 0; exit 0; }; curl -sk -m 120 -H \"Authorization: Bearer \$T\" https://$H/api/models | jq '[.data[].id] | length'" | tail -1; }
cur()      { K "kubectl -n webui set env deploy/open-webui --list 2>/dev/null | sed -n 's/^OPENAI_API_BASE_URL=//p'" | tail -1; }
have_key() { K "kubectl -n webui get secret inference-key >/dev/null 2>&1 && echo yes || echo no" | tail -1; }

case "$MODE" in
  status)
    echo "Open WebUI  https://$H"
    echo "  backend   $(cur)"
    echo "  token     Secret webui/inference-key: $(have_key)"
    echo "  models    $(models) offered"
    exit 0 ;;
  gateway)
    [ -x scripts/webui-add-inference.sh ] || { echo "scripts/webui-add-inference.sh is missing"; exit 1; }
    LAB_DOMAIN=$DOMAIN scripts/webui-add-inference.sh ai-fabric
    echo "models offered now: $(models)"
    exit 0 ;;
  local) ;;
  *) echo "usage: webui-wire.sh [local|gateway|status]"; exit 2 ;;
esac

K "kubectl -n ai-sim get secret llm-api-key >/dev/null 2>&1" >/dev/null \
  || { echo "the lab's model is not serving yet: run  ./llm-serve.sh up  first"; exit 1; }
n=$(K "kubectl -n ai-sim get endpoints llm -o jsonpath='{.subsets[*].addresses[*].ip}'" | tail -1 | wc -w)
[ "$n" -ge 1 ] || { echo "Service llm (ai-sim) has no endpoints yet: ./llm-serve.sh status"; exit 1; }

echo "== 1/3 bearer token -> Secret webui/inference-key (copied inside the cluster, never printed)"
K "kubectl -n ai-sim get secret llm-api-key -o jsonpath='{.data.key}' | base64 -d | kubectl -n webui create secret generic inference-key --from-file=api-key=/dev/stdin --dry-run=client -o yaml | kubectl apply -f -" >/dev/null
[ "$(have_key)" = yes ] || { echo "the Secret was not created"; exit 1; }

echo "== 2/3 backend $BASE"
[ "$(cur)" = "$BASE" ] || K "kubectl -n webui set env deploy/open-webui OPENAI_API_BASE_URL=$BASE" >/dev/null
KT=600 K "kubectl -n webui rollout restart deploy/open-webui >/dev/null; kubectl -n webui rollout status deploy/open-webui --timeout=540s" | tail -1

echo "== 3/3 what Open WebUI offers"
m=0; for i in $(seq 1 12); do m=$(models); [ "${m:-0}" -ge 1 ] && break; sleep 20; done
echo "   $m model(s) at https://$H  (default ${WEBUI_MODEL:-qwen2.5-0.5b-instruct})"
[ "${m:-0}" -ge 1 ] || { echo "   WARNING: no model offered yet -- check ./llm-serve.sh status, then ./webui-wire.sh status"; exit 1; }
