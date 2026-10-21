#!/usr/bin/env bash
# Add the inference gateway (APISIX + LiteLLM) to Open WebUI as a second
# OpenAI-compatible backend, keeping a direct OpenRouter connection when one is
# configured. Runs on
# the lab host; configures Open WebUI through its runtime config API (persisted
# in the Open WebUI volume), so no deployment change and no bootstrap coupling.
#   scripts/webui-add-inference.sh [lab]          (default: ai-fabric)
set -u
bastion_of() { docker ps --format "{{.Names}}" | grep -E "^clab-(.+-)?$1-.*bastion" | head -1; }
# base route UUID: any model route forwards all paths to LiteLLM, so one is enough as the base.
# uuid5 of the first curated model, same rule as gen-inference.py.
UUID="${INFER_BASE_UUID:-565df347-26cb-598a-b838-b7e9531f00fa}"
LABS=${*:-"ai-fabric"}
for D in $LABS; do
  B="$(bastion_of "$D")"
  docker ps --format '{{.Names}}' | grep -qx "$B" || { echo "$D: no bastion, skipping"; continue; }
  docker exec -i "$B" bash -lc '
    set -u
    H=webui.platform.'"${LAB_DOMAIN:-lab.ai}"'
    GW="http://apisix-gateway.inference.svc.cluster.local/models/'"$UUID"'/proxy/v1"
    ORK=$(kubectl -n webui get secret openrouter -o jsonpath="{.data.api-key}" 2>/dev/null | base64 -d)
    MK=$(kubectl -n inference get secret litellm-secret -o jsonpath="{.data.master-key}" 2>/dev/null | base64 -d)
    [ -n "$MK" ] || { echo "'"$D"': no inference master key (run scripts/deploy-inference.sh first)"; exit 1; }
    T=$(curl -sk --max-time 20 -H "Content-Type: application/json" https://$H/api/v1/auths/signin -d "{\"email\":\"\",\"password\":\"\"}" | jq -r ".token // empty")
    [ -n "$T" ] || { echo "'"$D"': no Open WebUI token"; exit 1; }
    if [ -n "$ORK" ]; then
      BODY=$(jq -cn --arg gw "$GW" --arg ork "$ORK" --arg mk "$MK" \
        "{ENABLE_OPENAI_API:true, OPENAI_API_BASE_URLS:[\"https://openrouter.ai/api/v1\",\$gw], OPENAI_API_KEYS:[\$ork,\$mk], OPENAI_API_CONFIGS:{\"1\":{enable:true,prefix_id:\"gw\",tags:[],model_ids:[],connection_type:\"external\"}}}")
    else
      BODY=$(jq -cn --arg gw "$GW" --arg mk "$MK" \
        "{ENABLE_OPENAI_API:true, OPENAI_API_BASE_URLS:[\$gw], OPENAI_API_KEYS:[\$mk], OPENAI_API_CONFIGS:{\"0\":{enable:true,prefix_id:\"gw\",tags:[],model_ids:[],connection_type:\"external\"}}}")
    fi
    curl -sk --max-time 30 -H "Authorization: Bearer $T" -H "Content-Type: application/json" \
      https://$H/openai/config/update -d "$BODY" >/dev/null
    # per-user default model = the local model through the gateway (the global default strips the gw. prefix; the per-user setting keeps it)
    DEF=$(curl -sk --max-time 20 -H "Authorization: Bearer $T" https://$H/api/v1/users/user/settings | jq -c ".ui = (.ui // {}) | .ui.models = [\"gw.Qwen/Qwen2.5-0.5B-Instruct\"]")
    curl -sk --max-time 20 -H "Authorization: Bearer $T" -H "Content-Type: application/json" https://$H/api/v1/users/user/settings/update -d "$DEF" >/dev/null
    n=$(curl -sk --max-time 20 -H "Authorization: Bearer $T" https://$H/openai/config | jq ".OPENAI_API_BASE_URLS | length")
    echo "'"$D"': backends $n; gw. prefix; default gw.Qwen/Qwen2.5-0.5B-Instruct"
  '
done
