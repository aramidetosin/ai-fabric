#!/bin/bash
# ai-sim-build.sh [node ...]: build the image of ai-workload.sh on this host (ai-fabric/ai-sim:1, see images/ai-sim/Dockerfile) and import it into containerd on
# the nodes that run the workloads (default: the nodes ai-workload.sh uses). Nothing is pulled by the cluster: imagePullPolicy Never.
# Downloads (once, to images/ai-sim/dl/): the llama.cpp release build for ubuntu-x64 (llama-server + ggml-rpc-server) and the model
# Qwen2.5-0.5B-Instruct Q4_K_M (GGUF, 491 MB, Apache-2.0) from Hugging Face.
cd "$(dirname "$0")"; . ./lib.sh; unset EVID
IMG=ai-fabric/ai-sim:1; D=images/ai-sim; mkdir -p $D/dl
LLAMA=${LLAMA_URL:-https://github.com/ggml-org/llama.cpp/releases/download/b11382/llama-b11382-bin-ubuntu-x64.tar.gz}
MODEL=${MODEL_URL:-https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf}
[ -s $D/dl/llama.tar.gz ] || curl -fsSL -o $D/dl/llama.tar.gz "$LLAMA" || { echo "llama.cpp download failed"; exit 1; }
[ -s $D/dl/model.gguf ] || { curl -fsSL -C - -o $D/dl/model.gguf.part "$MODEL" && mv $D/dl/model.gguf.part $D/dl/model.gguf; } || { echo "model download failed"; exit 1; }
docker image inspect $IMG >/dev/null 2>&1 && [ -z "${REBUILD:-}" ] || docker build -q -t $IMG $D || { echo "image build failed"; exit 1; }
ID=$(docker image inspect -f '{{.Id}}' $IMG); echo "image $IMG ${ID:7:12} ($(docker image inspect -f '{{.Size}}' $IMG | awk '{printf "%.2f GB", $1 / 1e9}'))"
NODES=${*:-${AI_NODES:-gpu1 gpu8 gpu17 gpu32 gpu2 gpu9 gpu18 gpu25 gpu16 gpu31}}
one() { local n=$1 have; have=$(timeout 60 ssh -n $SSHO "admin@$(mgmt "$n")" "sudo ctr -n k8s.io images ls -q 2>/dev/null | grep -c '^docker.io/$IMG\$'; sudo cat /var/lib/ai-sim.id 2>/dev/null" | xargs)
  [ "$have" = "1 $ID" ] && { echo "$n: image present"; return; }
  docker save $IMG | timeout 900 ssh $SSHO "admin@$(mgmt "$n")" "sudo ctr -n k8s.io images import - >/dev/null && echo $ID | sudo tee /var/lib/ai-sim.id >/dev/null" && echo "$n: image imported" || echo "$n: IMPORT FAILED"; }
i=0; for n in $NODES; do one "$n" & i=$((i + 1)); [ $((i % 4)) = 0 ] && wait; done; wait
