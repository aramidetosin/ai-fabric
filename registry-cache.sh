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
        -e REGISTRY_PROXY_REMOTEURL="$1" -e REGISTRY_HTTP_ADDR="0.0.0.0:$2" -e REGISTRY_STORAGE_DELETE_ENABLED=true registry:2 >/dev/null && echo "ai-fabric-cache-$n -> $1 on :$2"; done
      # A cache that cannot BIND its port exits immediately and docker keeps restarting it. `docker run`/`docker start` still
      # succeeded, so this used to report success and move on -- and the real symptom turned up 20 minutes later as
      # ImagePullBackOff on every node, with nothing pointing at a registry. Check that each one answers, and say what holds the port.
      # Check OUR container, not just the port: when another lab's cache holds the port it answers /v2/ perfectly well while
      # ours sits in a restart loop, so a port probe alone reports success for a cache that is not running at all.
      # A crash-looping container is briefly "running" between crashes, so one sample passes it. Require it to still be running
      # a few seconds later: over its restart backoff a wedged cache is in "restarting" nearly all the time.
      ok1() { [ "$(docker inspect -f '{{.State.Status}}' "ai-fabric-cache-$1" 2>/dev/null)" = running ] \
              && [ "$(curl -s -o /dev/null -w '%{http_code}' -m 3 "http://127.0.0.1:$2/v2/" 2>/dev/null)" != 000 ]; }
      healthy() { ok1 "$1" "$2" && sleep 4 && ok1 "$1" "$2"; }
      bad=""
      for n in "${!UP[@]}"; do set -- ${UP[$n]}
        for _ in $(seq 1 6); do healthy "$n" "$2" && break; sleep 3; done
        healthy "$n" "$2" && continue
        bad="$bad $n"
        echo "registry-cache: ai-fabric-cache-$n state=$(docker inspect -f '{{.State.Status}} restarts={{.RestartCount}}' "ai-fabric-cache-$n" 2>/dev/null || echo absent)"
        echo "registry-cache: ai-fabric-cache-$n is NOT serving on :$2 -- $(docker logs --tail 5 "ai-fabric-cache-$n" 2>&1 | grep -oE 'bind: address already in use|level=fatal.*' | head -1)"
        ss -lntp 2>/dev/null | grep ":$2 " | sed 's/^/   /'
      done
      if [ -n "$bad" ]; then
        echo "registry-cache: not serving:$bad"
        echo "registry-cache: the nodes would fall back to the upstreams, and 39 of them trip Docker Hub's anonymous pull limit."
        echo "registry-cache: usually ANOTHER lab on this host still holds those ports -- check 'docker ps | grep cache', stop them,"
        echo "registry-cache: then re-run. One big lab per host (RUNBOOK section 0)."
        exit 1
      fi ;;
  stop)  for n in "${!UP[@]}"; do docker rm -f "ai-fabric-cache-$n" >/dev/null 2>&1; done; echo "caches removed (data kept in /var/lib/ai-fabric-registry-cache)" ;;
  status) for n in "${!UP[@]}"; do set -- ${UP[$n]}; printf "%-18s %-8s :%s  %s cached\n" "ai-fabric-cache-$n" "$(docker inspect -f '{{.State.Status}}' "ai-fabric-cache-$n" 2>/dev/null || echo absent)" "$2" "$(du -sh "/var/lib/ai-fabric-registry-cache/$n" 2>/dev/null | cut -f1)"; done ;;
esac
