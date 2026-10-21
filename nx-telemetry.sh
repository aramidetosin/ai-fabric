#!/bin/bash
# nx-telemetry.sh [switch ...]: put Nexus Dashboard's telemetry block (ndfc/telemetry.cfg, profiles with ndfc=True) on the N9Kv frontend
# AFTER boot, then save. It cannot ride in configs/<switch>.cfg: vrnetlab types the startup config through scrapli, which only recognises
# `(config...)#` prompts, and the telemetry sub-modes prompt `(conf-tm-...)#` -- on the 2026-09-28 proof boot every switch hung on the
# second telemetry line for an hour, then the launcher crashed and took the switch down. Here NX-OS parses the file itself:
# scp to bootflash, `copy bootflash:... running-config`, `copy running-config startup-config`. Idempotent; verified by reading back.
cd "$(dirname "$0")"; . ./lib.sh
F=ndfc/telemetry.cfg; DST=ndfc-telemetry.cfg
python3 -c 'import gen, sys; sys.exit(0 if gen.NDFC else 1)' || { echo "profile has no ndfc=True: nothing to do"; exit 0; }
[ -s "$F" ] || { echo "missing $F"; exit 1; }
T=$(mktemp); trap 'rm -f "$T"' EXIT; grep -v '^#' "$F" | sed 's/[[:space:]]*$//' | grep -v '^$' > "$T"
q() { local o; o=$(timeout 120 ssh -n $SSHO "ops@$(mgmt "$1")" "$2" 2>&1); printf '%s\n' "$o"; }      # buffered: never close an NX-OS pipe early
has() { q $1 "show running-config telemetry" | grep -c "ip address 172.29.129.135 port 57500"; }        # both destination-groups = 2
SW=${*:-$(awk '$3 == "nxos" {print $1}' "$MH")}; bad=0
for s in $SW; do
  [ "$(has $s)" -ge 2 ] && { echo "$s: telemetry block present"; continue; }
  timeout 120 scp -O -q $SSHO "$T" "ops@$(mgmt $s):$DST" || { echo "$s: scp to bootflash FAILED"; bad=$((bad + 1)); continue; }
  q $s "terminal dont-ask ; copy bootflash:$DST running-config" > /dev/null
  q $s "terminal dont-ask ; copy running-config startup-config" > /dev/null
  n=$(has $s); s2=$(q $s "show startup-config | include 'port 57500'" | grep -c "port 57500")
  [ "$n" -ge 2 ] && [ "$s2" -ge 2 ] && echo "$s: telemetry block applied and saved" || { echo "$s: telemetry block NOT applied (running $n/2, startup $s2/2)"; bad=$((bad + 1)); }
done
exit $bad
