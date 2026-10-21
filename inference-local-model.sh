#!/bin/bash
# inference-local-model.sh [status]: give the inference gateway (https://inference.platform.<domain>, APISIX > LiteLLM) a model that is served
# from the lab's own GPU nodes. Operator decision 2026-10-04: "point the original inference.platform.lab.ai chain at the model on the GPU nodes".
# The gateway itself is the shared tooling's (post-deploy.sh > /root/ai-fabric/scripts/deploy-inference.sh): three models, all handed to an
# external provider. This script ADDS a fourth and removes nothing:
#   model      Qwen/Qwen2.5-0.5B-Instruct   (the model llm-serve.sh runs on gpu2 / gpu25 with RPC workers over rails 3 and 6)
#   LiteLLM    openai-compatible backend http://llm.ai-sim.svc.cluster.local:8080/v1, its bearer key from Secret inference/local-llm
#   APISIX     route /models/<uuid>/proxy/*   (uuid5 of the model name, the same rule as the shared tooling: an id that is stable platform-wide)
# so a request to the gateway for that model goes Envoy > APISIX > LiteLLM > EAST-WEST to a GPU node, and never leaves the lab.
# Idempotent. Run it again after post-deploy.sh / deploy-inference.sh (they write the gateway's ConfigMaps and Deployment from scratch);
# post-deploy.sh calls it as its last step. No key is printed: the model's key is copied Secret to Secret inside the cluster, and the test at the
# end reads the gateway's key on the fly and shows only the HTTP status and the model's answer.
set -u
cd "$(dirname "$0")"; . ./lib.sh; unset EVID
NAME="Qwen/Qwen2.5-0.5B-Instruct"; BACKEND=qwen2.5-0.5b-instruct; BASE="http://llm.ai-sim.svc.cluster.local:8080/v1"; DOMAIN=lab.ai
UUID=$(python3 -c 'import uuid, sys; print(uuid.uuid5(uuid.NAMESPACE_URL, "https://ai-fabric.lab/models/" + sys.argv[1]))' "$NAME")
URL="https://inference.platform.$DOMAIN/models/$UUID/proxy/v1/chat/completions"
K "kubectl -n inference get deploy litellm apisix >/dev/null 2>&1" || { echo "the inference gateway is not deployed (operator step: post-deploy.sh): nothing to add the model to"; exit 1; }
has() { K "kubectl -n inference get cm $1 -o jsonpath='{.data.$2}'" | grep -c -F "$3"; }
if [ "${1:-}" = status ]; then
  echo "model $NAME  ->  $URL"; echo "LiteLLM entry: $(has litellm-config 'config\.yaml' "$BASE")   APISIX route: $(has apisix-config 'apisix\.yaml' "$UUID")   key Secret: $(K "kubectl -n inference get secret local-llm -o name 2>/dev/null" | grep -c .)"
  ./llm-serve.sh status; exit 0; fi

echo "== 1/4 the model on the GPU nodes"; ./llm-serve.sh up || exit 1
echo "== 2/4 its bearer key, Secret ai-sim/llm-api-key -> Secret inference/local-llm (copied inside the cluster, not shown)"
K "kubectl -n ai-sim get secret llm-api-key -o jsonpath='{.data.key}' | base64 -d | kubectl -n inference create secret generic local-llm --from-file=api-key=/dev/stdin --dry-run=client -o yaml | kubectl apply -f - 2>&1 | tail -1"
echo "== 3/4 LiteLLM model entry + APISIX route"
ch=0; BK="audits/inference-gateway-before-local-model-$(date -u +%Y%m%d_%H%M%S).yaml"      # what the gateway looked like before (ConfigMaps + Deployment; they hold no key values)
[ "$(has litellm-config 'config\.yaml' "$BASE")" != 0 ] || { K "kubectl -n inference get cm litellm-config apisix-config -o yaml; echo ---; kubectl -n inference get deploy litellm -o yaml" > "$BK"; echo "gateway configuration saved to $BK"; }
if [ "$(has litellm-config 'config\.yaml' "$BASE")" = 0 ]; then
  K "kubectl -n inference get cm litellm-config -o json" | python3 -c '
import json, sys
name, backend, base = sys.argv[1:4]; cm = json.load(sys.stdin); c = cm["data"]["config.yaml"]
entry = f"  - model_name: {name}\n    litellm_params:\n      model: openai/{backend}\n      api_base: {base}\n      api_key: os.environ/LOCAL_LLM_API_KEY\n"
i = c.index("general_settings:"); cm["data"]["config.yaml"] = c[:i] + entry + c[i:]
for k in ("resourceVersion", "uid", "creationTimestamp", "managedFields"): cm["metadata"].pop(k, None)
cm["metadata"].get("annotations", {}).pop("kubectl.kubernetes.io/last-applied-configuration", None); print(json.dumps(cm))' "$NAME" "$BACKEND" "$BASE" | docker exec -i "$LAB-bastion" bash -lc "kubectl apply -f - 2>&1 | tail -1"; ch=1
else echo "LiteLLM already has the model"; fi
if [ "$(has apisix-config 'apisix\.yaml' "$UUID")" = 0 ]; then
  K "kubectl -n inference get cm apisix-config -o json" | python3 -c '
import json, re, sys
name, u = sys.argv[1:3]; cm = json.load(sys.stdin); c = cm["data"]["apisix.yaml"]; nid = max([int(x) for x in re.findall(r"- id: \"(\d+)\"", c)] or [0]) + 1
route = f"  - id: \"{nid}\"\n    name: {name}\n    uri: /models/{u}/proxy/*\n    methods: [GET, POST]\n    plugins:\n      proxy-rewrite:\n        regex_uri: [\"^/models/{u}/proxy/(.*)\", \"/$1\"]\n    upstream_id: litellm\n"
i = c.index("#END"); cm["data"]["apisix.yaml"] = c[:i] + route + c[i:]
for k in ("resourceVersion", "uid", "creationTimestamp", "managedFields"): cm["metadata"].pop(k, None)
cm["metadata"].get("annotations", {}).pop("kubectl.kubernetes.io/last-applied-configuration", None); print(json.dumps(cm))' "$NAME" "$UUID" | docker exec -i "$LAB-bastion" bash -lc "kubectl apply -f - 2>&1 | tail -1"; ch=1
else echo "APISIX already has the route"; fi
if ! K "kubectl -n inference get deploy litellm -o jsonpath='{.spec.template.spec.containers[0].env[*].name}'" | grep -q LOCAL_LLM_API_KEY; then
  K "kubectl -n inference set env deploy/litellm --from=secret/local-llm --prefix=LOCAL_LLM_ 2>&1 | tail -1"; ch=1; fi      # Secret key api-key -> env LOCAL_LLM_API_KEY
if [ $ch = 1 ]; then KT=600 K "kubectl -n inference rollout restart deploy/litellm deploy/apisix >/dev/null; kubectl -n inference rollout status deploy/apisix --timeout=180s | tail -1; kubectl -n inference rollout status deploy/litellm --timeout=420s | tail -1"; fi
echo "== 4/4 test through the whole chain from pc-1: $URL"
KEYCMD="kubectl -n inference get secret litellm-secret -o jsonpath={.data.master-key} | base64 -d"
BODY="{\"model\":\"$NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"Name the capital of France in one word.\"}],\"max_tokens\":20,\"temperature\":0}"
out=$(docker exec -i "$LAB-pc-1" sh -c "umask 077; cat > /tmp/.gw-h; curl -sS -m 120 -o /tmp/gw.json -w '%{http_code}' -H @/tmp/.gw-h -H 'Content-Type: application/json' -d '$BODY' '$URL'; rm -f /tmp/.gw-h" < <(printf 'Authorization: Bearer %s' "$(docker exec "$LAB-bastion" bash -lc "$KEYCMD")") 2>&1 | tail -1)
ans=$(docker exec "$LAB-pc-1" sh -c 'cat /tmp/gw.json; rm -f /tmp/gw.json' 2>/dev/null | python3 -c 'import json, sys
try: d = json.load(sys.stdin); print(repr(d["choices"][0]["message"]["content"].strip()[:60]), "model", d.get("model"))
except Exception as e: print("no completion in the answer")')
echo "pc-1 -> gateway -> $NAME: HTTP $out, answer $ans"; [ "$out" = 200 ]
