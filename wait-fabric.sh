#!/bin/bash
# wait-fabric.sh: block until the FRONTEND fabric is configured and converged: every leaf/border holds its EVPN sessions to both spines and
# every spine holds one per leaf/border, in two consecutive polls. up.sh releases the held guests only after this (see up.sh: hold-guests).
cd "$(dirname "$0")"; . ./lib.sh
LV="$FE_LEAVES $FE_BORDERS"; NS=$(echo $FE_SPINES | wc -w); NL=$(echo $LV | wc -w); good=0
for i in $(seq 1 "${1:-120}"); do left=""
  for n in $LV; do [ "$(EVID= fe_sessions $n 2>/dev/null | tail -1)" = "$NS" ] || left="$left $n"; done
  for n in $FE_SPINES; do [ "$(EVID= fe_sessions $n 2>/dev/null | tail -1)" = "$NL" ] || left="$left $n"; done
  if [ -z "$left" ]; then good=$((good + 1)); [ $good -ge 2 ] && { echo "$(date +%T) frontend converged: $NL leaves/borders x $NS spines, EVPN sessions established"; exit 0; }
  else good=0; [ $((i % 4)) = 1 ] && echo "$(date +%T) frontend not converged yet:$left"; fi; sleep 15
done; echo "frontend did NOT converge"; exit 1
