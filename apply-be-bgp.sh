#!/bin/bash
# one-off: swap the running backend to the regenerated BGP stanza without redeploying the lab. Reports BUSY/ERR/ok truthfully.
cd /root/ai-fabric && . ./lib.sh
for n in $BE_SPINES $BE_LEAVES; do
  start=$(grep -n -m1 -E "^ip prefix-list|^router bgp" configs/$n.cfg | cut -d: -f1)
  mapfile -t lines < <(tail -n +"$start" configs/$n.cfg)
  old=$(OCN $n "show running-config bgp" | awk '/^router bgp/{print $3; exit}')
  raw=$(OCN $n "configure terminal" "abort transaction" ${old:+"no router bgp $old"} "commit" "${lines[@]}" "end")
  if echo "$raw" | grep -q "CONSOLE BUSY"; then printf "%-10s BUSY\n" "$n"; continue; fi
  err=$(echo "$raw" | grep -E "^%" | grep -v -E "No Valid operations|No transaction|Executing the CLI from higher" | sort -u | head -3 | tr '\n' ';')
  printf "%-10s %s\n" "$n" "${err:+ERR: $err}${err:-ok (was AS ${old:-none})}"
done
