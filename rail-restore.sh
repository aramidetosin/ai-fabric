#!/bin/bash
# rail-restore.sh [be-leafN ...]: bring rail leaves back to their generated configuration without redeploying the lab (default: all eight).
# Written 2026-10-04 after every rail leaf had stopped forwarding (OcNOS demo VM: memory leak under load, the L2 configuration disappears from
# the running config) and a reload had made it worse: OcNOS then asks "The system has unsaved changes. Would you like to save them now?" and
# the answer "y" writes the broken running config over the good saved one. Per leaf:
#   saved config intact (as long as the generated one)   reload WITHOUT saving: the guest reboots with its saved config and fresh memory
#   saved config overwritten                              reload without saving, then type configs/<leaf>.cfg in again, check it, and only then save
# A leaf that comes back from the reload without forwarding gets the generated config typed in as well (its saved config stays as it is).
# A leaf is done when its running config is complete AND its rail gateway answers EVERY GPU node. Never saves a config it has not checked.
cd "$(dirname "$0")"; . ./lib.sh; unset EVID
LEAVES=${*:-$BE_LEAVES}; PROBE=${RAIL_PROBE:-gpu1}
cli() { timeout "${T:-60}" ssh -tt $SSHO "admin@$(mgmt "$1")" 2>&1 | tr -d '\r'; }                       # commands on stdin
show() { { sleep 3; printf 'enable\nterminal length 0\n'; sleep 1; printf '%s\n' "$2"; sleep 5; printf 'exit\n'; sleep 1; printf 'exit\n'; } | T=40 cli "$1" | awk 'f && NF {print} /terminal length 0/ {f=1}' | grep -v -E '[>#]exit$'; }
nlines() { local c; c=$(show "$1" "show $2-config" | grep -vc '^$'); [ "${c:-0}" -gt 5 ] || { sleep 4; c=$(show "$1" "show $2-config" | grep -vc '^$'); }; echo "${c:-0}"; }
rail_up() { timeout 20 ssh -n $SSHO "admin@$(mgmt "$PROBE")" "ping -c2 -W2 172.16.${1#be-leaf}.1 >/dev/null 2>&1" >/dev/null 2>&1; }
reload_nosave() { local n=$1 out ans      # look at what reload asks first (the session is closed without an answer: nothing happens), then answer exactly that
  out=$({ sleep 3; printf 'enable\n'; sleep 2; printf 'reload\n'; sleep 5; } | T=30 cli "$n")
  if grep -q "save them now" <<< "$out"; then ans="n y"; else ans="y"; fi
  { sleep 3; printf 'enable\n'; sleep 2; printf 'reload\n'; sleep 4; for a in $ans; do printf '%s\n' "$a"; sleep 4; done; sleep 4; } | T=60 cli "$n" >/dev/null; }
wait_cli() { local i; sleep 60; for i in $(seq 1 40); do [ "$(nlines "$1" running)" -gt 50 ] && return 0; sleep 10; done; return 1; }
push() { local n=$1      # the generated config, typed in configuration mode the way the launcher does it at the first boot (it carries its own commits)
  { sleep 3; printf 'enable\nconfigure terminal\n'; sleep 2; while IFS= read -r l; do printf '%s\n' "$l"; sleep 0.25; done < "configs/$n.cfg"; sleep 2; printf 'commit\nend\n'; sleep 4; printf 'exit\n'; } | T=500 cli "$n" | grep -E '^%' | sort | uniq -c | sort -rn | head -4 | sed "s/^/   $n push: /"; }
# every(leaf): how many GPU nodes get an answer from the leaf's rail gateway on that rail's NIC. It is also what makes a reloaded leaf usable: its
# ARP table is empty after the reload and the OcNOS VM resolves a neighbour in seconds, not milliseconds, so the first test that pings the gateway
# from all nodes at once loses its first packets (acceptance run 2026-10-04: 8 "rail alignment" failures on a leaf reloaded 12 minutes earlier,
# all 8 nodes answered when asked again). Asking from every node here fills the table before a test does.
every() { local r=${1#be-leaf} g t; t=$(mktemp -d)
  for g in $GPUS; do timeout 30 ssh -n $SSHO "admin@$(mgmt "$g")" "ping -c 3 -W 2 -q -I gpu$((r - 1)) 172.16.$r.1 >/dev/null 2>&1 || { sleep 3; ping -c 3 -W 2 -q -I gpu$((r - 1)) 172.16.$r.1 >/dev/null 2>&1; }" >/dev/null 2>&1 && : > "$t/$g" & done; wait
  ls "$t" | wc -l; rm -rf "$t"; }
one() { local n=$1 want st run i all=$(echo $GPUS | wc -w) ans
  want=$(grep -vc '^$' "configs/$n.cfg"); st=$(nlines "$n" startup)
  if [ "$st" -ge $((want * 9 / 10)) ]; then echo "$n: saved config intact ($st lines): reload without saving"
  else echo "$n: saved config OVERWRITTEN ($st lines, generated $want): reload without saving, then type the generated config in again"; fi
  reload_nosave "$n"; wait_cli "$n"
  [ "$st" -ge $((want * 9 / 10)) ] || { push "$n"; sleep 10; }
  for i in $(seq 1 12); do rail_up "$n" && break; sleep 10; done; run=$(nlines "$n" running)
  if ! rail_up "$n" || [ "$run" -lt $((want * 9 / 10)) ]; then      # back from the reload but not forwarding although its saved config is complete (be-leaf6, 2026-10-04: running 199 lines)
    echo "$n: after the reload: running $run lines, rail gateway $(rail_up "$n" && echo answers || echo 'does not answer'): typing the generated config in"
    push "$n"; sleep 10; for i in $(seq 1 12); do rail_up "$n" && break; sleep 10; done; run=$(nlines "$n" running); fi
  if [ "$run" -ge $((want * 9 / 10)) ] && rail_up "$n"; then
    if [ "$st" -lt $((want * 9 / 10)) ]; then { sleep 3; printf 'enable\ncopy running-config startup-config\n'; sleep 8; printf 'exit\n'; } | T=40 cli "$n" >/dev/null; st=$(nlines "$n" startup); fi
    ans=$(every "$n"); [ "$ans" = "$all" ] || { sleep 10; ans=$(every "$n"); }
    if [ "$ans" = "$all" ]; then echo "$n: RESTORED: running $run lines, saved $st lines, rail ${n#be-leaf} gateway answers all $all GPU nodes"
    else echo "$n: NOT RESTORED: running $run lines, but the rail ${n#be-leaf} gateway answers only $ans of $all GPU nodes"; fi
  else echo "$n: NOT RESTORED: running $run lines (generated $want), rail gateway $(rail_up "$n" && echo answers || echo 'does not answer')"; fi; }
for n in $LEAVES; do one "$n" & sleep 2; done; wait
