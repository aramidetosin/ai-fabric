#!/bin/bash
# Wait until every switch VM and the firewall report healthy (vrnetlab health = bootstrap + startup-config applied).
cd "$(dirname "$0")"; . ./lib.sh
NODES="$FE_SPINES $FE_LEAVES $FE_BORDERS oob-sw $BE_SPINES $BE_LEAVES fw"
for i in $(seq 1 ${1:-80}); do
  left=""; for n in $NODES; do [ "$(health $n)" = healthy ] || left="$left $n"; done
  [ -z "$left" ] && { echo "$(date +%T) all switches + firewall healthy"; exit 0; }
  echo "$(date +%T) waiting for:$left"; sleep 30
done; exit 1
