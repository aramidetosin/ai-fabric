#!/bin/bash
# Destroy ai-fabric (either flavour). The guests are powered off cleanly first (stop.sh) because their disks are kept and re-used by the next
# ./up.sh. ./down.sh fast skips that; ./down.sh wipe also removes the guests' disks and the shared cluster state (fresh Kubernetes next time).
cd "$(dirname "$0")"
case "${1:-}" in wipe|fast) ;; *) ./stop.sh ;; esac
for T in ai-fabric.clab.yml ai-fabric-light.clab.yml; do containerlab destroy -t "$T" --cleanup 2>/dev/null | tail -1; done
docker ps -a --format '{{.Names}}' | grep '^clab-ai-fabric-' | xargs -r docker rm -f
[ "${1:-}" = wipe ] && { rm -rf nodes/*/vm/* shared/ai-fabric; echo "guest disks and shared cluster state removed"; }
exit 0   # the test above returns 1 on every non-wipe run, which read as a failure (2026-09-23)
