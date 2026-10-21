#!/bin/bash
# nx-wait.sh [switch ...]: wait (max 40 min) until every Nexus 9300v is docker-healthy (vrnetlab "Startup complete" = configs/<switch>.cfg typed in
# and saved) AND answers `show hostname` over SSH as ops with this host's key (the key comes from that config, so this also proves it was applied).
cd "$(dirname "$0")"; . ./lib.sh
want=${*:-$(awk '$3 == "nxos" {print $1}' "$MH")}; [ -n "$want" ] || { echo "no Nexus switches in this profile"; exit 0; }
nxname() { local o; o=$(timeout 30 ssh -n $SSHO "ops@$(mgmt "$1")" "show hostname" 2>/dev/null); printf '%s' "$o" | tr -d '\r '; }   # buffered: see NX() in lib.sh
for i in $(seq 1 120); do
  left=""; for s in $want; do [ "$(health $s)" = healthy ] && [ "$(nxname $s)" = "$s" ] || left="$left $s"; done
  [ -z "$left" ] && { echo "$(date +%T) Nexus ready:$(printf ' %s' $want)"; exit 0; }
  [ $((i % 3)) = 1 ] && echo "$(date +%T) waiting for Nexus:$(for s in $left; do printf ' %s(%s)' $s "$(health $s)"; done)"
  sleep 20
done
echo "$(date +%T) TIMEOUT waiting for:$left"; exit 1
