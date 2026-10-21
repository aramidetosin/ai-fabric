#!/bin/bash
# apply-junos.sh [switch ...]: push configs/<switch>.set to the Juniper vEX switches over key-based SSH (the boot config carries only the
# operator keys, see gen.py junos_keys). `load set` + `commit check` + `commit`; any line Junos rejects is printed. Idempotent. No password.
cd "$(dirname "$0")"; . ./lib.sh
NODES=${*:-$(awk '$3 == "junos" {print $1}' "$MH")}; rc=0
one() { local n=$1 ip; ip=$(mgmt "$n"); local out
  for i in $(seq 1 40); do ssh -n $SSHO "admin@$ip" "show version" >/dev/null 2>&1 && break; sleep 15; done
  scp -O -q $SSHO "configs/$n.set" "admin@$ip:/var/tmp/$n.set" || { echo "$n: FAILED (scp)"; return 1; }
  out=$(printf 'configure exclusive\nload set /var/tmp/%s.set\ncommit check\ncommit and-quit\n' "$n" | ssh -T $SSHO "admin@$ip" 2>&1)
  if echo "$out" | grep -q "commit complete"; then echo "$n: committed$(echo "$out" | grep -E "^/var/tmp|syntax error|error:" | head -3 | sed 's/^/  | /')"; else echo "$n: FAILED"; echo "$out" | grep -v -E "license|^$" | tail -8 | sed 's/^/  | /'; return 1; fi; }
for n in $NODES; do one "$n" & done; for j in $(jobs -p); do wait "$j" || rc=1; done; exit $rc
