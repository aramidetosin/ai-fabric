#!/bin/bash
# clear-warnings.sh [watch-seconds]: bring the Warning events (Headlamp's "Warnings") to 0 -- but only when they are HISTORY.
#   1. health gate: every node Ready, every pod Running/Completed (Open WebUI may wait for the operator's secret). Not healthy = nothing is
#      deleted: the warnings are then the symptom to look at, and the unhealthy objects are printed.
#   2. archive: all Warning events go to audits/ai-fabric_warnings_<ts>/ first (one result set, like every other category), command included.
#   3. delete the Warning events, then WATCH (default 90 s): a warning that comes back is a live problem -> printed, exit 2.
# Warnings are expected after a restart (NodeNotReady, Rebooted, FailedMount, probe failures while 39 nodes boot), during the failure drills
# and from the validation's own test pods; finish.sh, drills.sh, validate.sh and validate-all.sh therefore end with this script.
cd "$(dirname "$0")"; . ./lib.sh
WATCH=${1:-90}; TS=$(date +%Y%m%d_%H%M%S); OUT=audits/ai-fabric_warnings_$TS; Q="kubectl get events -A --field-selector type=Warning"
# Open WebUI no longer waits for an API key (Secret webui/inference-key is optional), so it does not restart-loop and its
# namespace is counted like every other one -- nothing is excluded here.
SKIPNS=""
cnt() { EVID= K "$Q --no-headers 2>/dev/null | awk -v s='$SKIPNS' '\$1 != s' | wc -l" | tail -1; }
for i in $(seq 1 30); do
  nr=$(EVID= K "kubectl get nodes --no-headers | awk '\$2 != \"Ready\" {print \$1}' | xargs" | tail -1)
  np=$(EVID= K "kubectl get pods -A --no-headers | awk '\$4 != \"Running\" && \$4 != \"Completed\" && \$1 != \"webui\" {print \$1\"/\"\$2\"(\"\$4\")\"}' | xargs" | tail -1)
  [ -z "$nr$np" ] && break; sleep 10
done
[ -z "$nr$np" ] || { echo "clear-warnings: NOT clearing, the cluster is not healthy -> nodes not Ready: ${nr:-none}; pods: ${np:-none}"; exit 1; }
n=$(cnt)
if [ "${n:-0}" -gt 0 ]; then mkdir -p "$OUT"
  EVID="$OUT/commands.txt" K "$Q --sort-by=.lastTimestamp -o custom-columns=LAST:.lastTimestamp,NS:.metadata.namespace,KIND:.involvedObject.kind,OBJECT:.involvedObject.name,REASON:.reason,COUNT:.count,MESSAGE:.message" > "$OUT/warnings.txt"
  { echo "ai-fabric Warning events cleared $TS: $n (cluster healthy: all nodes Ready, all pods Running)"; echo; echo "by namespace / kind / reason:"
    awk 'NR > 1 {print $2, $3, $5}' "$OUT/warnings.txt" | sort | uniq -c | sort -rn; } > "$OUT/SUMMARY.txt"
  EVID="$OUT/commands.txt" K "kubectl delete events -A --field-selector type=Warning >/dev/null 2>&1; $Q --no-headers 2>/dev/null | wc -l" >/dev/null
  keep_latest ai-fabric_warnings "$OUT"; echo "clear-warnings: $n Warning events archived in $OUT and deleted"
else echo "clear-warnings: no Warning events"; fi
[ "$WATCH" -gt 0 ] || exit 0
sleep "$WATCH"; new=$(cnt)
[ "${new:-0}" = 0 ] && { echo "clear-warnings: 0 Warning events after a $WATCH s watch${SKIPNS:+ (namespace $SKIPNS excluded: waiting for the operator secret)}"; exit 0; }
echo "clear-warnings: $new NEW Warning event(s) within $WATCH s -- live problem(s):"
EVID= K "$Q -o custom-columns=NS:.metadata.namespace,KIND:.involvedObject.kind,OBJECT:.involvedObject.name,REASON:.reason,MESSAGE:.message --no-headers" | cut -c1-220; exit 2
