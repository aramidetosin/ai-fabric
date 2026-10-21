#!/bin/bash
# stop.sh: power the Kubernetes guests off CLEANLY before the lab is destroyed or the host goes down. The guests are plain QEMU processes:
# `docker stop` / a host shutdown would cut them mid-write (etcd, the Longhorn replicas and the S3 disk on the storage node, Harbor's database).
# Order: workloads first (GPU nodes, worker-role control nodes), then the storage node, then the control plane.
# Called by ./down.sh (not for `wipe`/`fast`) and by the ai-fabric-lab systemd unit at host shutdown. Guests that do not answer SSH are skipped.
cd "$(dirname "$0")"; [ -f mgmt-hosts.txt ] || exit 0; . ./lib.sh
running() { [ "$(docker inspect -f '{{.State.Running}}' "$LAB-$1" 2>/dev/null)" = true ]; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
off() {   # off <label> <seconds to wait> <node ...>
  local label=$1 w=$2 n i left t0=$(date +%s); shift 2; : > "$T/asked"
  for n in "$@"; do running "$n" || continue
    # containerlab gives linux nodes restart=always: without this docker boots the guest again the moment it powers off
    ( docker update --restart=no "$LAB-$n" >/dev/null 2>&1
      timeout 20 ssh -n $SSHO -o ConnectTimeout=5 "admin@$(mgmt "$n")" "sudo systemctl poweroff" >/dev/null 2>&1 && echo "$n" >> "$T/asked" ) &
  done; wait
  for i in $(seq 1 $((w / 5))); do left=""; for n in $(cat "$T/asked"); do running "$n" && left="$left $n"; done; [ -z "$left" ] && break; sleep 5; done
  printf '  %-22s %2d powered off cleanly in %3d s%s\n' "$label" "$(( $(wc -l < "$T/asked") - $(echo $left | wc -w) ))" $(( $(date +%s) - t0 )) "${left:+, STILL RUNNING:$left}"
}
CP=$(echo $CTRLS | tr ' ' '\n' | head -3 | xargs); WK=$(echo $CTRLS | tr ' ' '\n' | tail -n +4 | xargs)
echo "$(date +%T) stopping the guests cleanly"
# the storage node unmounts the Longhorn replicas and the S3 disk and has taken > 2 min: it gets the longest wait (unit: TimeoutStopSec=900)
off "GPU + worker nodes" 180 $GPUS $WK
off "storage node" 420 storage
off "control plane" 180 $CP
