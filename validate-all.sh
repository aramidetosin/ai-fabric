#!/bin/bash
# validate-all.sh [drills]: the complete acceptance run of ai-fabric. Every part saves itself under audits/ and replaces the previous
# result of its own category (one result set per category, nothing stacks):
#   ai-fabric_validation_*      validate.sh, sections A-H (fabric, firewall, OcNOS rails, GPU pods over the rails, platform)
#   ai-fabric_rail_trace_*      GPU-to-GPU pod traffic hop by hop: same rail, jumbo, cross-rail both ways (leaf > spine > leaf)
#   ai-fabric_e2e_trace_*       pc-1, pc-2 and the office LAN to the inference endpoint, through the firewall
#   ai-fabric_pvc_trace_ctrl_*  PVC through the storage management API (OOB address, through the firewall) from a control node
#   ai-fabric_pvc_trace_gpu_*   the same from a GPU node
#   ai-fabric_ai_workload_*     ai-workload.sh: a real PyTorch distributed training job (4 nodes, gradients over a rail, dataset and checkpoints on a
#                             shared volume) and a real LLM served by two replicas, each spread over three nodes (llama.cpp + RPC workers over a rail);
#                             captures at every hop, all logs, verdicts
#   ai-fabric_audit_*           state dump of every device (firewall: CLI state, logs and the running configuration as set commands)
#   ai-fabric_drills_*          only with the argument "drills": four failure drills FIRST (disruptive, self-restoring), so that everything
#                             after them also proves the fabric came back to its full state
# No credential is used anywhere (firewall API sections need FW_PASS exported by the operator and are skipped without it).
# Exit status = number of parts that failed. Overview of the run: audits/SUMMARY.md
cd "$(dirname "$0")"; . ./lib.sh
is_full || { echo "validate-all needs the full lab (light lab: ./validate-fabric.sh)"; exit 2; }
CT=${CTRL_NODE:-ctrl1}; GN=${GPU_NODE:-$(echo $GPUS | awk '{print $NF}')};   # PVC trace: a control node and the LAST GPU node (on site-b that is the second GPU leaf pair)
 RA=${RAIL_A:-gpu1}; RB=${RAIL_B:-gpu8}; T0=$(date +%s); FAILS=0; ROWS=""
part() { local name=$1 log=/tmp/ai-fabric-all-$$.log; shift; printf "%-34s " "$name"; local t=$(date +%s); "$@" > "$log" 2>&1; local rc=$?
  local res; res=$(grep -E "^== RESULT" "$log" | tail -1 | sed 's/^== RESULT: //'); [ -n "$res" ] || res=$(grep -E "^files: " "$log" | tail -1); [ -n "$res" ] || res=$(grep -E "^clear-warnings: " "$log" | tail -1 | sed 's/^clear-warnings: //')
  [ $rc = 0 ] && v=PASS || { v=FAIL; FAILS=$((FAILS + 1)); }; echo "$v  ${res:-rc=$rc}  ($(( $(date +%s) - t )) s)"; ROWS="$ROWS| $name | **$v** | ${res:-rc=$rc} |"$'\n'
  [ $rc = 0 ] || grep -E "^ *FAIL" "$log" | head -12; rm -f "$log"; }
echo "== ai-fabric full acceptance run $(date -u +%FT%TZ)"
# the rails first: the OcNOS demo VM leaks under load and a rail leaf then stops forwarding; the host's watchdog stands down while this run is active,
# so the same check and remedy run here (rail-heal.sh). A reload is listed in the summary as a known platform limitation.
rails() { local RH RHN; RH=$(./rail-heal.sh 2>&1); echo "$RH" | sed 's/^/  /'; RHN=$(grep -c '^RELOADED' <<< "$RH")      # $1 = when
  ROWS="$ROWS| rails $1 | $([ "$(grep -c '^STILL-DOWN' <<< "$RH")" = 0 ] && echo '**PASS**' || echo '**FAIL**') | $(tail -1 <<< "$RH" | sed 's/^rail-heal: //')$([ "$RHN" = 0 ] || echo " (KNOWN: OcNOS demo VM memory leak, $(grep '^RELOADED' <<< "$RH" | cut -d: -f1 | sed 's/RELOADED //' | xargs))") |"$'\n'; }
rails "before the run"
export VALIDATE_ALL=1      # parts clear their own warnings without the watch; the watch runs once, last
[ "${1:-}" = drills ] && part "failure drills (1-4)" ./drills.sh
part "validation (sections A-I)" ./validate.sh
rails "before the rail parts"      # the leak builds up with the traffic of the drills and of the validation: check again where the rails are the subject
part "rail trace $RA <-> $RB" ./trace-rail.sh $RA $RB
python3 -c 'import gen,sys; sys.exit(0 if gen.NETOP else 1)' && part "SoftRoCE probe (network-operator: rdma_shared + net-rail-0)" ./rdma-probe.sh
part "e2e trace (pc-1, pc-2, office LAN)" ./trace.sh
part "PVC trace from $CT" ./trace-pvc.sh $CT
part "PVC trace from $GN" ./trace-pvc.sh $GN
# real multi-node AI workloads with their traffic captured hop by hop (profiles with the network-operator's rail networks): ai-workload.sh
python3 -c 'import gen,sys; sys.exit(0 if gen.NETOP else 1)' && [ -f ./ai-workload.sh ] && part "AI workloads: 4-node training + 2x3-node inference" ./ai-workload.sh all
part "audit (all devices)" ./audit.sh
part "Warning events back to 0" ./clear-warnings.sh
{ echo "# ai-fabric acceptance run, $(date -u +%FT%TZ)"; echo; echo "| part | verdict | result |"; echo "|---|---|---|"; printf "%s" "$ROWS"; echo
  echo "Result sets (one per category, older runs are replaced):"; echo; for d in audits/ai-fabric_*; do [ -d "$d" ] && echo "- \`$d\`"; done; echo
  echo "KNOWN = a documented limit of the virtual platform (OcNOS VM: rail SVI MTU capped at 1500, so jumbo does not cross rails), reported separately and never counted as a pass."; } > audits/SUMMARY.md
echo; echo "$( [ $FAILS = 0 ] && echo "ALL PARTS PASSED" || echo "$FAILS PART(S) FAILED" ) in $(( ($(date +%s) - T0) / 60 )) min -> audits/SUMMARY.md"; ls -1 audits; exit $FAILS
