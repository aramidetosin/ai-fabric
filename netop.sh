#!/bin/bash
# netop.sh: the production GPU cluster's NVIDIA network-operator stack on the simulated GPU nodes (site-a-nx, operator decisions 2026-09-24).
#   1. NFD, a SEPARATE Helm release like production (upstream chart, namespace node-feature-discovery); its worker tolerates the GPU taint
#   2. network-operator chart v26.1.1 (NGC) in namespace nvidia-network-operator, its bundled NFD off
#   3. netop/manifests.yaml (gen.py): the NodeFeatureRule faking pci-15b3 (SoftRoCE stands in for ConnectX), the NicClusterPolicy (production's
#      nodeAffinity verbatim, rdma-shared-dev-plugin over the rail NICs, no ofedDriver) and MacvlanNetwork net-rail-0..7 (NAD in namespace default)
#   4. the bootstrap's hand-made gpu/rail-N NADs removed (replaced by the operator's, operator decision)
#   5. waits and reports: pci-15b3 on every GPU node, NicClusterPolicy ready, 8 MacvlanNetworks ready + their NADs, the RDMA plugin on every GPU node,
#      and the rdma/rdma_shared capacity it advertises (reported, not failed: whether it sees SoftRoCE devices is what rdma-probe.sh answers)
# Idempotent (helm upgrade --install, kubectl apply). finish.sh runs it after rdma-prep.sh. Images come through Harbor's proxy-nvcr / proxy-k8s.
#   CHECK=1   only the report (validation)
cd "$(dirname "$0")"; . ./lib.sh
python3 -c 'import gen,sys; sys.exit(0 if gen.NETOP else 1)' || { echo "netop: no network-operator in this profile"; exit 0; }
eval "$(python3 -c 'import gen; n = gen.NETOP; print(" ".join(f"{k.upper()}={v}" for k, v in n.items()), f"RAILS={gen.RAILS}", "NGPU=%d" % sum(1 for h in gen.HOSTS.values() if h.get("kind") == "gpu"))')"
RC=0; say() { echo "$1: $2"; }; nok() { echo "$1: $2   <-- NOT OK"; RC=1; }
cnt() { K "$1" | tail -1 | tr -d ' '; }

if [ -z "${CHECK:-}" ]; then
  docker cp netop/manifests.yaml "$LAB-bastion:/tmp/netop-manifests.yaml" >/dev/null
  echo "NFD $NFD_CHART (separate release, namespace $NFD_NS)"
  KT=900 K "helm repo add nfd $NFD_REPO --force-update >/dev/null 2>&1; helm repo update nfd >/dev/null 2>&1
    helm upgrade --install nfd nfd/node-feature-discovery --version $NFD_CHART -n $NFD_NS --create-namespace \
      --set-json 'worker.tolerations=[{\"operator\":\"Exists\"}]' --wait --timeout 14m 2>&1 | tail -1" | sed 's/^/   /' || { echo "netop: NFD install failed"; exit 1; }
  echo "network-operator $CHART (namespace $NS, bundled NFD off)"
  KT=900 K "helm repo add nvidia $REPO --force-update >/dev/null 2>&1; helm repo update nvidia >/dev/null 2>&1
    helm upgrade --install network-operator nvidia/network-operator --version $CHART -n $NS --create-namespace \
      --set nfd.enabled=false --wait --timeout 14m 2>&1 | tail -1" | sed 's/^/   /' || { echo "netop: network-operator install failed"; exit 1; }
  echo "manifests: NodeFeatureRule, NicClusterPolicy, $RAILS MacvlanNetworks"
  KT=300 K "kubectl apply -f /tmp/netop-manifests.yaml" | sed 's/^/   /' || { echo "netop: manifests not applied"; exit 1; }
  o=$(K "kubectl -n gpu get net-attach-def -o name 2>/dev/null | grep -E '/rail-[0-9]+\$' | xargs -r kubectl -n gpu delete" | tail -3)
  [ -n "$o" ] && echo "$o" | sed 's/^/   old NAD /'
  echo "waiting for the stack to settle"
  KT=1500 K "for i in \$(seq 1 90); do
      l=\$(kubectl get nodes -l feature.node.kubernetes.io/pci-15b3.present=true --no-headers 2>/dev/null | wc -l)
      s=\$(kubectl get nicclusterpolicy nic-cluster-policy -o jsonpath={.status.state} 2>/dev/null)
      m=\$(kubectl get macvlannetworks -o jsonpath='{range .items[*]}{.status.state}{\"\\n\"}{end}' 2>/dev/null | grep -c ready)
      [ \$l -ge $NGPU ] && [ \"\$s\" = ready ] && [ \$m -ge $RAILS ] && break; sleep 15; done; echo \"label=\$l policy=\$s macvlan-ready=\$m\"" | sed 's/^/   /'
fi

echo "report"
l=$(cnt "kubectl get nodes -l feature.node.kubernetes.io/pci-15b3.present=true,node-role.ai-fabric.lab/gpu=true --no-headers 2>/dev/null | wc -l")
[ "$l" = "$NGPU" ] && say "   GPU nodes labelled pci-15b3.present (NodeFeatureRule)" "$l/$NGPU" || nok "   GPU nodes labelled pci-15b3.present (NodeFeatureRule)" "$l/$NGPU"
s=$(cnt "kubectl get nicclusterpolicy nic-cluster-policy -o jsonpath={.status.state}")
[ "$s" = ready ] && say "   NicClusterPolicy nic-cluster-policy" "$s" || nok "   NicClusterPolicy nic-cluster-policy" "${s:-absent}"
m=$(cnt "kubectl get macvlannetworks -o jsonpath='{range .items[*]}{.metadata.name}={.status.state}{\"\\n\"}{end}' 2>/dev/null | grep -c '^net-rail-[0-9]*=ready'")
[ "$m" = "$RAILS" ] && say "   MacvlanNetworks net-rail-N ready" "$m/$RAILS" || nok "   MacvlanNetworks net-rail-N ready" "$m/$RAILS"
d=$(cnt "kubectl -n default get net-attach-def -o name 2>/dev/null | grep -c '/net-rail-[0-9]*\$'")
[ "$d" = "$RAILS" ] && say "   NADs default/net-rail-N (created by the operator)" "$d/$RAILS" || nok "   NADs default/net-rail-N (created by the operator)" "$d/$RAILS"
o=$(cnt "kubectl -n gpu get net-attach-def -o name 2>/dev/null | grep -c '/rail-[0-9]*\$'")
[ "$o" = 0 ] && say "   old gpu/rail-N NADs" "none (replaced)" || nok "   old gpu/rail-N NADs" "$o still present"
p=$(cnt "kubectl -n $NS get pods -l app=rdma-shared-dp --no-headers 2>/dev/null | grep -c Running")
[ "$p" = "$NGPU" ] && say "   rdma-shared-dev-plugin pods Running" "$p/$NGPU" || nok "   rdma-shared-dev-plugin pods Running" "$p/$NGPU"
a=$(K "kubectl get nodes -l node-role.ai-fabric.lab/gpu=true -o jsonpath='{range .items[*]}{.status.allocatable.rdma/rdma_shared}{\"\\n\"}{end}'" | grep -cE '^[1-9][0-9]*$')
say "   GPU nodes advertising rdma/rdma_shared > 0 (SoftRoCE devices found by the plugin)" "$a/$NGPU$([ "$a" = 0 ] && echo '  -- see rdma-probe.sh')"
[ $RC = 0 ] && echo "netop: network-operator stack in place" || echo "netop: NOT complete"
exit $RC
