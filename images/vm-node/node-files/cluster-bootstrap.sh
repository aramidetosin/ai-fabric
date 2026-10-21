#!/bin/bash
# ai-fabric cluster self-bootstrap. Runs as a systemd service on every k8s node; idempotent and
# retried by systemd on failure. Mirrors the reference build: kubeadm HA control plane behind a
# kube-vip ARP VIP, Cilium (KPR, geneve, L2 announcements, Gateway API, Hubble), cert-manager
# with a cluster CA (self-signed, or the dns-b lab CA on site-a-nx) issuing the platform wildcard, a Gateway + HTTPRoutes. Then the worker
# tier: Multus + whereabouts with one attachment per GPU rail, Longhorn on the storage node, and Open
# WebUI (backed by the lab's own model, an optional key Secret) on a Longhorn volume.
set -u
set -a; . /etc/ai-fabric/node.env; set +a
export KUBECONFIG=/etc/kubernetes/admin.conf
export NODE_NAME=$(hostname)
K=/opt/ai-fabric/k8s
log() { echo "[bootstrap $(date +%H:%M:%S)] $*"; }
# Point containerd at the host's pull-through caches BEFORE anything is pulled. Without this every one of the 39 nodes
# fetches each image straight from the upstreams: ~2.5 GB each, slow enough that the Cilium install times out, and
# Docker Hub's anonymous limit is reached long before Longhorn is done. registry-mirrors.sh is a no-op when the profile
# sets no mirrors, and it is idempotent (harbor-trust.sh rewrites the same files later to add Harbor's proxy caches).
[ -x /usr/local/bin/registry-mirrors.sh ] && /usr/local/bin/registry-mirrors.sh || true
render() { envsubst < "$1"; }
# A large rollout (39 guests on one host) makes the API time out now and then: every manifest apply retries instead of being skipped silently.
apply() { local i; for i in $(seq 1 30); do render "$1" | kubectl apply -f - >/dev/null && return 0; log "apply $(basename "$1") failed (try $i), retrying"; sleep 10; done; log "apply $(basename "$1") GAVE UP"; return 1; }
IGN=SystemVerification,ImagePull,Swap,FileAvailable--etc-kubernetes-manifests-kubevip.yaml

kubevip_manifest() { KUBEVIP_KUBECONFIG="$1" envsubst '${API_VIP} ${KUBEVIP_KUBECONFIG}' < "$K/kubevip.yaml"; }
# kube-vip's leader election must not depend on the address it manages: give it a kubeconfig that talks to the local API
# server. Without it, once the address is lost no instance can reach the API to win it back.
kubevip_local_kubeconfig() { sed "s#server: https://api\.${DOMAIN}:6443#server: https://127.0.0.1:6443#" "$1" > /etc/kubernetes/kube-vip.conf; chmod 600 /etc/kubernetes/kube-vip.conf; }
wait_api() { until curl -sk --max-time 3 "https://${API_VIP}:6443/healthz" 2>/dev/null | grep -q ok; do sleep 5; done; }
# lab CA (site-a-nx): cloud-init writes the dns-b-issued intermediates here on the INIT node only (from the lab host's host-only ca/ directory)
CA=/etc/ai-fabric/ca
subj() { openssl x509 -in "$1" -noout -"$2" | sed "s/^$2=//"; }
# kubeadm keeps a CA it finds in place: the lab's Kubernetes CA (an intermediate under the dns-b root) instead of a self-signed one
place_k8s_ca() { [ -s "$CA/kubernetes.crt" ] && [ -s "$CA/kubernetes.key" ] || return 0
  mkdir -p /etc/kubernetes/pki; install -m 0644 "$CA/kubernetes.crt" /etc/kubernetes/pki/ca.crt; install -m 0600 "$CA/kubernetes.key" /etc/kubernetes/pki/ca.key
  log "kubeadm CA: $(subj "$CA/kubernetes.crt" subject), issued by $(subj "$CA/kubernetes.crt" issuer)"; }
# with an intermediate kubeadm CA the API server must SEND it after its own certificate, or a client that trusts only the lab root cannot build the
# chain. Idempotent and re-checked at every run ('kubeadm certs renew' rewrites apiserver.crt without it); kube-apiserver reloads the file by itself.
chain_apiserver() { local c=/etc/kubernetes/pki/apiserver.crt ca=/etc/kubernetes/pki/ca.crt
  [ -s "$c" ] && [ -s "$ca" ] || return 0
  [ "$(subj "$ca" subject)" = "$(subj "$ca" issuer)" ] && return 0            # self-signed kubeadm CA (other profiles): nothing to add
  [ "$(grep -c 'BEGIN CERTIFICATE' "$c")" -ge 2 ] && return 0
  cat "$ca" >> "$c"; log "API server certificate now served with its chain (+ $(subj "$ca" subject))"; }

case "${NODE_ROLE:-}" in
  init)
    if [ ! -f /etc/kubernetes/admin.conf ]; then
      log "kubeadm init (first control plane, endpoint api.${DOMAIN} = ${API_VIP})"
      mkdir -p /etc/kubernetes/manifests
      place_k8s_ca                     # every attempt: a failed init's 'kubeadm reset' also removes /etc/kubernetes/pki
      # kube-vip must exist before init so the VIP answers; during init it can only use super-admin.conf
      kubevip_manifest /etc/kubernetes/super-admin.conf > /etc/kubernetes/manifests/kubevip.yaml
      render "$K/kubeadm-init.yaml" > /etc/ai-fabric/kubeadm-init.yaml
      if ! kubeadm init --config /etc/ai-fabric/kubeadm-init.yaml --upload-certs --ignore-preflight-errors="$IGN"; then
        log "kubeadm init failed; resetting so systemd can retry"
        kubeadm reset -f >/dev/null 2>&1; rm -f /etc/kubernetes/manifests/*.yaml
        exit 1
      fi
      kubevip_local_kubeconfig /etc/kubernetes/admin.conf
      kubevip_manifest /etc/kubernetes/kube-vip.conf > /etc/kubernetes/manifests/kubevip.yaml
      log "control plane initialised"
    fi
    chain_apiserver
    ;;
  join-cp)
    if [ ! -f /etc/kubernetes/kubelet.conf ]; then
      log "waiting for the API VIP ${API_VIP}:6443"; wait_api
      render "$K/kubeadm-join.yaml" > /etc/ai-fabric/kubeadm-join.yaml
      until kubeadm join --config /etc/ai-fabric/kubeadm-join.yaml --ignore-preflight-errors="$IGN"; do
        log "join failed, retrying in 30s"; kubeadm reset -f >/dev/null 2>&1; sleep 30
      done
      kubevip_local_kubeconfig /etc/kubernetes/admin.conf
      kubevip_manifest /etc/kubernetes/kube-vip.conf > /etc/kubernetes/manifests/kubevip.yaml
      log "joined as control plane"
    fi
    chain_apiserver                    # the joining control plane got the (intermediate) CA from kubeadm's certificate upload
    exit 0 ;;
  join-worker)
    if [ ! -f /etc/kubernetes/kubelet.conf ]; then
      log "waiting for the API VIP ${API_VIP}:6443"; wait_api
      # the node registers its own class labels and taint (see kubeadm-join-worker.yaml)
      case "${NODE_KIND:-worker}" in
        gpu)     export NODE_LABELS="node-role.ai-fabric.lab/worker=true,node-role.ai-fabric.lab/compute=true,node-role.ai-fabric.lab/gpu=true,nvidia.com/gpu.present=true"
                 export NODE_TAINTS="nvidia.com/gpu=present:NoSchedule" ;;
        storage) export NODE_LABELS="node-role.ai-fabric.lab/worker=true,node-role.ai-fabric.lab/storage=true,node.longhorn.io/create-default-disk=true"
                 export NODE_TAINTS="" ;;
        *)       export NODE_LABELS="node-role.ai-fabric.lab/worker=true"; export NODE_TAINTS="" ;;
      esac
      render "$K/kubeadm-join-worker.yaml" > /etc/ai-fabric/kubeadm-join.yaml
      until kubeadm join --config /etc/ai-fabric/kubeadm-join.yaml --ignore-preflight-errors="$IGN"; do
        log "join failed, retrying in 30s"; kubeadm reset -f >/dev/null 2>&1; sleep 30
      done
      log "joined as worker (${NODE_KIND:-worker})"
    fi
    exit 0 ;;
  *) log "NODE_ROLE not set; nothing to do"; exit 0 ;;
esac

# ---------------- init node only: cluster-wide configuration (idempotent) ----------------
wait_api
# keep the join certificate key valid for late joiners (kubeadm's upload expires after 2h)
kubeadm init phase upload-certs --upload-certs --certificate-key "$CERT_KEY" >/dev/null 2>&1 || true

log "waiting for ${EXPECT_NODES} nodes"
for i in $(seq 1 120); do
  n=$(kubectl get nodes --no-headers 2>/dev/null | wc -l); [ "$n" -ge "$EXPECT_NODES" ] && break; sleep 10
done

# Node classes (reference-style labels) and the ROLES column, by node name. Runs at EVERY boot of the init node, so it must produce the final
# state by itself (same table as roles.sh on the lab host):
#   gpu*      worker + compute + gpu, tainted, role gpu         (never control/ingress: the Gateway VIP is L2-announced from the control class only)
#   storage*  worker + storage (Longhorn default disk), role storage
#   others    control + worker + ingress + compute; role worker unless kubeadm made it a control plane (ctrl4+)
P=node-role.ai-fabric.lab
for n in $(kubectl get nodes -o name); do
  case "${n#node/}" in
    gpu-node-*|*-gpu-*|gpu[0-9]*)
      kubectl label --overwrite "$n" $P/worker=true $P/compute=true $P/gpu=true nvidia.com/gpu.present=true node-role.kubernetes.io/gpu= \
        $P/control- $P/ingress- >/dev/null
      kubectl taint nodes --overwrite "${n#node/}" nvidia.com/gpu=present:NoSchedule >/dev/null ;;
    storage-node-*|*pure*|storage*)
      kubectl label --overwrite "$n" $P/worker=true $P/storage=true node.longhorn.io/create-default-disk=true node-role.kubernetes.io/storage= \
        $P/control- $P/ingress- $P/compute- >/dev/null ;;
    *)
      kubectl label --overwrite "$n" $P/control=true $P/worker=true $P/ingress=true $P/compute=true >/dev/null
      kubectl get "$n" -o jsonpath='{.metadata.labels}' | grep -q node-role.kubernetes.io/control-plane \
        || kubectl label --overwrite "$n" node-role.kubernetes.io/worker= >/dev/null ;;
  esac
done
kubectl taint nodes --all node-role.kubernetes.io/control-plane- >/dev/null 2>&1 || true

# Gateway API CRDs (standard channel), before Cilium so its Gateway controller starts
if ! kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1; then
  log "installing Gateway API ${GATEWAY_API_VERSION}"
  until kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"; do sleep 10; done
fi

# Cilium (as reference: KPR, geneve, cluster-pool IPAM, bond0, L2 announcements, Gateway API, Envoy DS, Hubble)
if ! kubectl -n kube-system get ds cilium >/dev/null 2>&1; then
  log "installing Cilium ${CILIUM_VERSION}"
  until command -v helm >/dev/null && helm repo add cilium https://helm.cilium.io/ --force-update >/dev/null 2>&1 && helm repo update >/dev/null 2>&1; do sleep 10; done
  render "$K/cilium-values.yaml" > /etc/ai-fabric/cilium-values.yaml
  helm upgrade --install cilium cilium/cilium --version "${CILIUM_VERSION}" -n kube-system \
    -f /etc/ai-fabric/cilium-values.yaml --wait --timeout 20m || { log "cilium install failed"; exit 1; }
fi
kubectl wait --for=condition=Ready nodes --all --timeout=900s || { log "nodes not Ready"; exit 1; }

# cert-manager + cluster CA + platform wildcard (as reference). The cluster CA is self-signed, unless the lab CA is provided (site-a-nx): then
# secret cluster-ca IS the dns-b-issued Platform CA, with ca.crt = the lab root -- so the cluster-ca.crt published below is the root, which the
# workstations trust once for good (a self-signed CA changed with every rebuild).
if ! kubectl -n cert-manager get deploy cert-manager >/dev/null 2>&1; then
  log "installing cert-manager"
  until command -v helm >/dev/null && helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null 2>&1 && helm repo update >/dev/null 2>&1; do sleep 10; done
  helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager --create-namespace \
    ${CERTMGR_VERSION:+--version $CERTMGR_VERSION} --set crds.enabled=true --wait --timeout 15m || { log "cert-manager install failed"; exit 1; }
fi
if [ -s "$CA/platform.crt" ] && [ -s "$CA/platform.key" ] && [ -s "$CA/root.crt" ]; then
  kubectl -n cert-manager delete certificate cluster-ca --ignore-not-found >/dev/null 2>&1   # a self-signed Certificate would take the secret back
  until cat "$CA/platform.crt" "$CA/root.crt" > /tmp/cluster-ca-chain.crt && kubectl -n cert-manager create secret generic cluster-ca --type=kubernetes.io/tls \
      --from-file=tls.crt=/tmp/cluster-ca-chain.crt --from-file=tls.key="$CA/platform.key" --from-file=ca.crt="$CA/root.crt" --dry-run=client -o yaml \
      | kubectl apply -f - >/dev/null; do log "cluster-ca secret: retrying"; sleep 10; done
  rm -f /tmp/cluster-ca-chain.crt; log "cluster CA: $(subj "$CA/platform.crt" subject), issued by $(subj "$CA/platform.crt" issuer)"
else
  apply "$K/pki-selfsigned-ca.yaml"
  kubectl -n cert-manager wait --for=condition=Ready certificate/cluster-ca --timeout=300s || { log "cluster CA not ready"; exit 1; }
fi
apply "$K/pki.yaml"
kubectl wait --for=condition=Ready clusterissuer/cluster-ca --timeout=300s || { log "cluster CA issuer not ready"; exit 1; }
kubectl -n gateway wait --for=condition=Ready certificate/listener-tls --timeout=300s || { log "wildcard cert not ready"; exit 1; }

# LB-IPAM pool + L2 announcement policies (reference style), Gateway, demo app, Hubble route
if [ "${LB_MODE:-l2}" = "bgp" ]; then
  # the BGP CRDs appear once the BGP control plane is on; use whichever version the cluster stores them as
  for i in $(seq 1 60); do kubectl get crd ciliumbgpclusterconfigs.cilium.io >/dev/null 2>&1 && break; sleep 5; done
  export BGP_API=$(kubectl get crd ciliumbgpclusterconfigs.cilium.io -o jsonpath='{.spec.versions[?(@.storage==true)].name}' 2>/dev/null)
  export BGP_API=${BGP_API:-v2}
  log "BGP announcement: pool ${LB_POOL_CIDR}, peers ${BGP_PEER_A} ${BGP_PEER_B} AS ${BGP_PEER_ASN}, CRD version ${BGP_API}"
  apply "$K/lb-bgp.yaml"      # routed pool + Cilium BGP peering with the gateway pair
else
  apply "$K/lb-l2.yaml"      # pool inside the node subnet, L2/ARP announcement
fi
apply "$K/gateway.yaml"
apply "$K/demo.yaml"
apply "$K/hubble-route.yaml"

# Multus (thick) + whereabouts beside Cilium (cni.exclusive=false), then one macvlan attachment per GPU rail
if ! kubectl -n kube-system get ds kube-multus-ds >/dev/null 2>&1; then
  log "installing Multus ${MULTUS_VERSION} and whereabouts ${WHEREABOUTS_VERSION}"
  until kubectl apply -f "https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/${MULTUS_VERSION}/deployments/multus-daemonset-thick.yml"; do sleep 10; done
  # the upstream thick manifest caps the daemon at 50Mi; every delegate CNI call (cilium-cni) runs inside that cgroup, and a
  # burst of pod creations on a large host gets the daemon and its delegates OOM-killed (seen on a 96-core host)
  kubectl -n kube-system set resources ds kube-multus-ds -c kube-multus --requests=memory=128Mi --limits=memory=512Mi >/dev/null
  W="https://raw.githubusercontent.com/k8snetworkplumbingwg/whereabouts/${WHEREABOUTS_VERSION}/doc/crds"
  for f in whereabouts.cni.cncf.io_ippools.yaml whereabouts.cni.cncf.io_overlappingrangeipreservations.yaml whereabouts.cni.cncf.io_nodeslicepools.yaml daemonset-install.yaml; do
    until kubectl apply -f "$W/$f"; do sleep 10; done
  done
fi
kubectl get ns gpu >/dev/null 2>&1 || kubectl create ns gpu >/dev/null
# RAIL_NADS=operator (site-a-nx): the NVIDIA network-operator owns the rail networks (MacvlanNetwork net-rail-N -> NAD default/net-rail-N, netop.sh).
# Also skipped once the operator's MacvlanNetwork CRD exists: a node.env written before the flag existed must not bring the old NADs back.
if [ "${RAIL_NADS:-bootstrap}" != operator ] && ! kubectl get crd macvlannetworks.mellanox.com >/dev/null 2>&1; then
  for R in $(seq 1 "${GPU_RAILS:-8}"); do
    until R="$R" R0="$((R - 1))" envsubst '${R} ${R0} ${RAIL_PREFIX} ${NODE_MTU}' < "$K/rail-nad.yaml" | kubectl apply -f - >/dev/null; do sleep 10; done
  done
fi

# Longhorn: replicas only on the storage node (create-default-disk label), one replica per volume, default class
if ! kubectl -n longhorn-system get deploy longhorn-driver-deployer >/dev/null 2>&1; then
  log "installing Longhorn ${LONGHORN_VERSION}"
  helm repo add longhorn https://charts.longhorn.io >/dev/null 2>&1 || true
  until helm repo update >/dev/null 2>&1; do sleep 10; done
  helm upgrade --install longhorn longhorn/longhorn -n longhorn-system --create-namespace --version "${LONGHORN_VERSION}" \
    -f "$K/longhorn-values.yaml" --wait --timeout 25m || { log "longhorn install failed"; exit 1; }
fi
apply "$K/longhorn-route.yaml"

# metrics-server (node and pod usage for kubectl top and Headlamp); kubeadm's kubelet serving certificates are self-signed,
# hence --kubelet-insecure-tls
if ! kubectl -n kube-system get deploy metrics-server >/dev/null 2>&1; then
  log "installing metrics-server ${METRICS_SERVER_VERSION}"
  until kubectl apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml" >/dev/null; do sleep 10; done
  kubectl -n kube-system patch deploy metrics-server --type=json -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' >/dev/null
fi

# Headlamp (Kubernetes UI) behind the Gateway, admin service account for the operator (token via scripts/headlamp-token.sh)
if ! kubectl -n headlamp get deploy headlamp >/dev/null 2>&1; then
  log "installing Headlamp ${HEADLAMP_CHART_VERSION}"
  helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/ >/dev/null 2>&1 || true
  until helm repo update >/dev/null 2>&1; do sleep 10; done
  for i in 1 2 3; do
    helm upgrade --install headlamp headlamp/headlamp -n headlamp --create-namespace --version "${HEADLAMP_CHART_VERSION}" \
      --set service.port=80 --wait --timeout 15m && break; log "headlamp install failed (try $i)"
  done
fi
apply "$K/headlamp.yaml"

# Open WebUI on a Longhorn volume. Its OpenAI-compatible backend is WEBUI_API_BASE, the lab's own model by
# default (Service llm in ai-sim). The bearer token is Secret webui/inference-key and is OPTIONAL, so this
# applies cleanly on a fresh cluster: post-deploy.sh starts the model and creates the Secret afterwards.
apply "$K/webui.yaml"

# publish to the lab's shared dir for the bastion and the PC
S="/shared/${CLUSTER_NAME}"; mkdir -p "$S"
kubectl -n cert-manager get secret cluster-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > "$S/cluster-ca.crt"
cp /etc/kubernetes/admin.conf "$S/kubeconfig"; chmod 644 "$S/kubeconfig"
date -u +%FT%TZ > "$S/ready"
log "cluster bootstrap complete"
kubectl get nodes -o wide
kubectl -n gateway get gateway
kubectl -n longhorn-system get nodes.longhorn.io 2>/dev/null
kubectl -n webui get pod,pvc 2>/dev/null
