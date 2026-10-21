#!/bin/bash
# rail-heal.sh [report]: make sure every backend rail forwards; reload a rail leaf that does not. Called at the start of validate-all.sh and of
# ai-workload.sh, because the host's rail-leaf watchdog (host/rail-leaf-watchdog.sh, which has the history of this fault) stands down while an
# acceptance run is active. THE FAULT: the OcNOS demo VM leaks under load; at its memory ceiling a rail leaf keeps BGP and its CLI but stops
# forwarding. THE CHECK is the symptom: the rail gateway 172.16.R.1 no longer answers a GPU node (two tries, 8 s apart). THE REMEDY is a reload
# over the leaf's own CLI WITHOUT saving (rail-restore.sh): the guest reboots, the container and its links stay, the leaf is back in ~3 min.
# One leaf at a time.
#   rail-heal.sh          check the 8 rails, reload a leaf whose rail does not forward
#   rail-heal.sh report   only report
#   rail-heal.sh all      reload EVERY rail leaf, one after the other (~15 min): a fresh start before a long acceptance run, because the leak builds
#                         up with the traffic of every run and a leaf can then die in the middle of a part (seen 2026-10-04, third run of the day)
# Output: one line per rail that needed it ("RELOADED be-leafN ..." or "STILL-DOWN be-leafN ..."), then a summary. Exit 1 = a rail is still down.
cd "$(dirname "$0")"; . ./lib.sh; unset EVID
PROBE=${RAIL_PROBE:-gpu1}; MODE=${1:-act}; bad=0; n=0
rail_up() { timeout 20 ssh -n $SSHO "admin@$(mgmt "$PROBE")" "ping -c2 -W2 172.16.$1.1 >/dev/null 2>&1" >/dev/null 2>&1; }
timeout 15 ssh -n $SSHO "admin@$(mgmt "$PROBE")" true >/dev/null 2>&1 || { echo "rail-heal: probe node $PROBE unreachable, nothing checked"; exit 1; }
for r in 1 2 3 4 5 6 7 8; do
  if [ "$MODE" != all ]; then rail_up $r && continue; sleep 8; rail_up $r && continue; fi
  q=$(docker top "$LAB-be-leaf$r" 2>/dev/null | awk '/qemu-system/ {print $2; exit}'); rss=$([ -n "$q" ] && awk '/VmRSS/ {printf "%d", $2 / 1024}' "/proc/$q/status" 2>/dev/null)
  [ "$MODE" = report ] && { echo "DOWN be-leaf$r: rail $r gateway 172.16.$r.1 does not answer (qemu RSS ${rss:-?} MB high-water)"; bad=$((bad + 1)); continue; }
  # the remedy is rail-restore.sh: it reloads WITHOUT saving (on a leaf that lost its L2 config OcNOS asks "save the unsaved changes?"; a yes writes the
  # broken config over the good saved one: seen 2026-10-04) and types the generated config in again where the saved one is already overwritten
  o=$(./rail-restore.sh "be-leaf$r" 2>&1 | tail -1)
  if grep -q ": RESTORED" <<< "$o" && rail_up $r; then echo "RELOADED be-leaf$r: $([ "$MODE" = all ] && echo "preventive reload" || echo "rail $r did not forward") (qemu RSS ${rss:-?} MB high-water); ${o#*: RESTORED: }"; n=$((n + 1))
  else echo "STILL-DOWN be-leaf$r: ${o#*: }"; bad=$((bad + 1)); fi; done
echo "rail-heal: 8 rails checked, $n rail leaf(s) reloaded, $bad still down"; [ $bad = 0 ]
