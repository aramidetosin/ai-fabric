#!/bin/bash
# roles.sh: node classes and the ROLES column, by node name (idempotent). The bootstrap inherited refplat's name patterns (gpu-node-*, storage-node-*),
# which never matched this lab's gpuN / storage names, so EVERY node ended up labelled control + ingress + compute and showed ROLES <none>.
#   ctrl1-3   control-plane (kubeadm)                 class: control, worker, ingress, compute
#   ctrl4+    worker                                  class: control, worker, ingress, compute   (the Gateway VIP is L2-announced from this class only)
#   gpuN      gpu      + taint nvidia.com/gpu         class: worker, compute, gpu
#   storage   storage                                 class: worker, storage (Longhorn default disk)
cd "$(dirname "$0")"; . ./lib.sh
P=node-role.ai-fabric.lab
K "for n in \$(kubectl get nodes -o name); do h=\${n#node/}
  case \$h in
    gpu*)     kubectl label --overwrite \$n $P/worker=true $P/compute=true $P/gpu=true nvidia.com/gpu.present=true node-role.kubernetes.io/gpu= $P/control- $P/ingress- >/dev/null
              kubectl taint nodes --overwrite \$h nvidia.com/gpu=present:NoSchedule >/dev/null ;;
    storage*) kubectl label --overwrite \$n $P/worker=true $P/storage=true node.longhorn.io/create-default-disk=true node-role.kubernetes.io/storage= $P/control- $P/ingress- $P/compute- >/dev/null ;;
    ctrl*)    kubectl label --overwrite \$n $P/control=true $P/worker=true $P/ingress=true $P/compute=true >/dev/null
              kubectl get \$n -o jsonpath='{.metadata.labels}' | grep -q node-role.kubernetes.io/control-plane || kubectl label --overwrite \$n node-role.kubernetes.io/worker= >/dev/null ;;
  esac; done; kubectl get nodes --no-headers | awk '{print \$3}' | sort | uniq -c"
