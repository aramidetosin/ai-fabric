#!/bin/bash
# registry-cache.sh [start|stop|status]: pull-through registry caches on this host, one per upstream, for profiles that set `mirrors` in
# gen.py (site-b). 39 nodes behind one home IP would each pull ~2.5 GB and trip Docker Hub's anonymous limit; with the caches every image
# is fetched once. The nodes' containerd reaches them on the management gateway (http://<mgmt gateway>:5001-5004) and still falls back to
# the upstream if a cache is down. Data: /var/lib/ai-fabric-registry-cache/<name>. Host network, because this host runs Docker with iptables=false.
set -u
declare -A UP=([dockerio]="https://registry-1.docker.io 5005" [quay]="https://quay.io 5002" [ghcr]="https://ghcr.io 5003" [k8s]="https://registry.k8s.io 5004")
case "${1:-start}" in
  start) for n in "${!UP[@]}"; do set -- ${UP[$n]}
      docker inspect "ai-fabric-cache-$n" >/dev/null 2>&1 && { docker start "ai-fabric-cache-$n" >/dev/null; continue; }
      mkdir -p "/var/lib/ai-fabric-registry-cache/$n"
      docker run -d --name "ai-fabric-cache-$n" --restart unless-stopped --network host -v "/var/lib/ai-fabric-registry-cache/$n:/var/lib/registry" \
        -e REGISTRY_PROXY_REMOTEURL="$1" -e REGISTRY_HTTP_ADDR="0.0.0.0:$2" -e REGISTRY_STORAGE_DELETE_ENABLED=true registry:2 >/dev/null && echo "ai-fabric-cache-$n -> $1 on :$2"; done ;;
  stop)  for n in "${!UP[@]}"; do docker rm -f "ai-fabric-cache-$n" >/dev/null 2>&1; done; echo "caches removed (data kept in /var/lib/ai-fabric-registry-cache)" ;;
  status) for n in "${!UP[@]}"; do set -- ${UP[$n]}; printf "%-18s %-8s :%s  %s cached\n" "ai-fabric-cache-$n" "$(docker inspect -f '{{.State.Status}}' "ai-fabric-cache-$n" 2>/dev/null || echo absent)" "$2" "$(du -sh "/var/lib/ai-fabric-registry-cache/$n" 2>/dev/null | cut -f1)"; done ;;
esac
