#!/bin/bash
# llm-serve.sh [up|restart|status]: the lab's language model, served from the GPU nodes and kept running (namespace ai-sim).
# Since 2026-10-04 (operator decision) the inference gateway (inference.platform.<domain>: APISIX > LiteLLM) has a model whose backend is this
# deployment (inference-local-model.sh), so it is part of the lab and no longer only a test fixture of ai-workload.sh.
#   two replicas behind Service llm (tcp 8080, OpenAI-compatible, bearer key in Secret llm-api-key, never printed):
#     replica A  llama-server on gpu2,  ggml-rpc-server workers on gpu9 + gpu18,  over rail 3
#     replica B  llama-server on gpu25, ggml-rpc-server workers on gpu16 + gpu31, over rail 6
#   also published directly as https://llm-sim.platform.<domain> (HTTPRoute llm-sim)
#   up       nothing to do when both replicas serve and each server points at the rail addresses its workers hold NOW; otherwise redeploy
#            (a server is started with its workers' rail addresses; a worker pod that is re-created, e.g. after a reboot, may get another one)
#   restart  redeploy from scratch
#   status   pods, endpoints, route
# finish.sh calls `up` at the end of a boot; ai-workload.sh deploys the same pods itself (it captures the model load) and leaves them running.
# Same manifests as ai-workload.sh (keep the two in step). Needs the image ai-fabric/ai-sim:1 on the six nodes (./ai-sim-build.sh).
set -u
cd "$(dirname "$0")"; . ./lib.sh; unset EVID
MODE=${1:-up}; NS=ai-sim; IMG=docker.io/ai-fabric/ai-sim:1; DOMAIN=lab.ai; HOST="llm-sim.platform.$DOMAIN"; MODEL=qwen2.5-0.5b-instruct
INFA=(${INF_A:-gpu2 gpu9 gpu18}); RA=${RAIL_A:-3}; INFB=(${INF_B:-gpu25 gpu16 gpu31}); RB=${RAIL_B:-6}
railip() { K "kubectl -n $NS get pod $1 -o jsonpath='{.metadata.annotations.k8s\\.v1\\.cni\\.cncf\\.io/network-status}'" | python3 -c 'import json, sys
try: print(next(n["ips"][0] for n in json.load(sys.stdin) if n.get("interface") == "net1"))
except Exception: pass'; }
ready() { K "kubectl -n $NS get endpoints llm -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{\"\\n\"}{end}' 2>/dev/null" | grep -c .; }
args() { K "kubectl -n $NS get pod $1 -o jsonpath='{.spec.containers[0].command}' 2>/dev/null"; }
if [ "$MODE" = status ]; then K "kubectl -n $NS get pods -o wide 2>&1 | cut -c1-130; kubectl -n $NS get svc,endpoints,httproute 2>&1 | cut -c1-140"; exit 0; fi
if [ "$MODE" = up ] && [ "$(ready)" = 2 ]; then
  A1=$(railip rpc-a1); A2=$(railip rpc-a2); B1=$(railip rpc-b1); B2=$(railip rpc-b2)
  if [ -n "$A1$A2$B1$B2" ] && args llm-a | grep -q "$A1:50052,$A2:50052" && args llm-b | grep -q "$B1:50052,$B2:50052"; then
    echo "llm-serve: both replicas serve (A on ${INFA[*]} over rail $RA, B on ${INFB[*]} over rail $RB), nothing to do"; exit 0; fi; fi
NODES=$(printf '%s\n' "${INFA[@]}" "${INFB[@]}" | sort -u | xargs)
miss=$(for n in $NODES; do (timeout 40 ssh -n $SSHO "admin@$(mgmt "$n")" "sudo ctr -n k8s.io images ls -q 2>/dev/null | grep -q '^$IMG\$'" || echo "$n") & done; wait)
[ -z "$miss" ] || { echo "llm-serve: image missing on $(echo $miss | xargs): ai-sim-build.sh"; ./ai-sim-build.sh $miss 2>&1 | tail -4; }
./rail-heal.sh 2>&1 | tail -1      # the replicas load and compute over rails 3 and 6
KT=300 K "kubectl get ns $NS >/dev/null 2>&1 || kubectl create ns $NS >/dev/null; kubectl -n $NS delete pod -l 'app in (llm, ai-rpc)' --wait=true >/dev/null 2>&1
  kubectl -n $NS get secret llm-api-key >/dev/null 2>&1 || { umask 077; f=\$(mktemp); printf 'sk-sim-%s' \"\$(head -c 18 /dev/urandom | od -An -tx1 | tr -d ' \\n')\" > \$f; kubectl -n $NS create secret generic llm-api-key --from-file=key=\$f >/dev/null; rm -f \$f; }" >/dev/null
tpod() { cat <<EOF
apiVersion: v1
kind: Pod
metadata: {name: $1, namespace: $NS, labels: {app: $3, part: $4}, annotations: {k8s.v1.cni.cncf.io/networks: '$5'}}
spec:
  nodeSelector: {kubernetes.io/hostname: $2}
  tolerations: [{key: nvidia.com/gpu, operator: Exists, effect: NoSchedule}]
  terminationGracePeriodSeconds: 2
  restartPolicy: Always
  containers:
  - name: main
    image: $IMG
    imagePullPolicy: Never
    command: $6
$7
---
EOF
}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
RPC="[ggml-rpc-server, -H, 0.0.0.0, -p, '50052', -t, '2']"
{ tpod rpc-a1 "${INFA[1]}" ai-rpc a "default/net-rail-$((RA - 1))" "$RPC" ""; tpod rpc-a2 "${INFA[2]}" ai-rpc a "default/net-rail-$((RA - 1))" "$RPC" ""
  tpod rpc-b1 "${INFB[1]}" ai-rpc b "default/net-rail-$((RB - 1))" "$RPC" ""; tpod rpc-b2 "${INFB[2]}" ai-rpc b "default/net-rail-$((RB - 1))" "$RPC" ""; } > "$T/rpc.yaml"
docker cp "$T/rpc.yaml" $LAB-bastion:/tmp/llm-rpc.yaml >/dev/null
KT=300 K "kubectl apply -f /tmp/llm-rpc.yaml >/dev/null; kubectl -n $NS wait --for=condition=Ready pod -l app=ai-rpc --timeout=240s" | tail -4
A1=$(railip rpc-a1); A2=$(railip rpc-a2); B1=$(railip rpc-b1); B2=$(railip rpc-b2)
[ -n "$A1" ] && [ -n "$A2" ] && [ -n "$B1" ] && [ -n "$B2" ] || { echo "llm-serve: the RPC workers did not get their rail addresses"; exit 1; }
SEC="    volumeMounts: [{name: key, mountPath: /secret, readOnly: true}]
    readinessProbe: {httpGet: {path: /health, port: 8080}, periodSeconds: 3, failureThreshold: 200}
    ports: [{containerPort: 8080}]
  volumes: [{name: key, secret: {secretName: llm-api-key}}]"
srv() { echo "[llama-server, -m, /models/model.gguf, --alias, $MODEL, --host, 0.0.0.0, --port, '8080', --rpc, '$1:50052,$2:50052', -ngl, '99', -c, '2048', -t, '2', -np, '2', --no-webui, --api-key-file, /secret/key]"; }
{ tpod llm-a "${INFA[0]}" llm a "default/net-rail-$((RA - 1))" "$(srv $A1 $A2)" "$SEC"; tpod llm-b "${INFB[0]}" llm b "default/net-rail-$((RB - 1))" "$(srv $B1 $B2)" "$SEC"
  cat <<EOF
apiVersion: v1
kind: Service
metadata: {name: llm, namespace: $NS}
spec: {selector: {app: llm}, ports: [{port: 8080, targetPort: 8080}]}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: llm-sim, namespace: $NS}
spec:
  parentRefs: [{group: gateway.networking.k8s.io, kind: Gateway, name: gateway, namespace: gateway}]
  hostnames: [$HOST]
  rules: [{matches: [{path: {type: PathPrefix, value: /}}], timeouts: {request: 300s, backendRequest: 300s}, backendRefs: [{name: llm, port: 8080}]}]
EOF
} > "$T/llm.yaml"
docker cp "$T/llm.yaml" $LAB-bastion:/tmp/llm-servers.yaml >/dev/null
KT=900 K "kubectl apply -f /tmp/llm-servers.yaml >/dev/null; for i in \$(seq 1 200); do s=\$(kubectl -n $NS get pods -l app=llm --no-headers | awk '{print \$2\":\"\$3}' | xargs); case \"\$s\" in *Error*|*Failed*|*CrashLoop*) break;; '1/1:Running 1/1:Running') break;; esac; sleep 4; done; kubectl -n $NS get pods -l 'app in (llm, ai-rpc)' -o wide --no-headers | cut -c1-110"
n=$(ready); [ "$n" = 2 ] && echo "llm-serve: both replicas serve: A on ${INFA[*]} (rail $RA: $A1, $A2), B on ${INFB[*]} (rail $RB: $B1, $B2)" || { echo "llm-serve: only $n of 2 replicas ready"; exit 1; }
