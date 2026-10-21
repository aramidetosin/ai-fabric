#!/bin/bash
# nx-tcam-reload.sh [leaf ...]: activate the TCAM carve vPC fabric peering needs (ing-flow-redirect, 9300v name `redirect`, >= 512). Cisco: "TCAM
# carving requires saving the configuration and reloading the switch". configs/<leaf>.cfg carries the carve, but vrnetlab types it into a RUNNING
# switch and saves; nothing reloads it -- and every ./up.sh is a first boot (vrnetlab keeps the N9Kv disk inside the container). So every deploy
# reloads the vPC leaves once, before the guests are released. Idempotent. Found on the nxprobe lab (2026-09-23), both are useless as markers:
#   - `show hardware access-list tcam region` prints the CONFIGURED size (512 straight after the first boot);
#   - "Last reset ... Reason" stays "Unknown" on the 9300v even after a CLI reload.
# Marker used: the switch's kernel uptime against its container's age. On a first boot the VM starts seconds after the container; after a reload
# the switch is at least one provisioning cycle (~3.5 min) younger than its container.
cd "$(dirname "$0")"; . ./lib.sh
GAP=${GAP:-150}
q() { local o; o=$(timeout 30 ssh -n $SSHO "ops@$(mgmt "$1")" "$2" 2>/dev/null); printf '%s\n' "$o"; }      # buffered: see NX() in lib.sh
up_s() { q $1 "show version" | awk '/Kernel uptime/ {gsub(/[^0-9 ]/, " "); n = split($0, a, " +"); k = 0; for (i = 1; i <= n; i++) if (a[i] != "") v[++k] = a[i]; print v[1]*86400 + v[2]*3600 + v[3]*60 + v[4]}'; }
age_s() { echo $(( $(date +%s) - $(date -d "$(docker inspect -f '{{.State.StartedAt}}' $LAB-$1)" +%s) )); }
LV=${*:-$(awk '$3 == "nxos" && $1 ~ /^fe-(gpu|ctrl)-leaf/ {print $1}' "$MH")}; todo=""
for s in $LV; do
  u=$(up_s $s); a=$(age_s $s); cfg=$(q $s "show startup-config | include 'tcam region redirect'")
  echo "$s: container ${a}s, switch up ${u:-?}s, startup-config: ${cfg:-NO CARVE}"
  [ -n "$cfg" ] || { echo "$s: the carve is missing from its startup-config -- not reloading (check configs/$s.cfg)"; continue; }
  [ -n "$u" ] && [ $((a - u)) -gt $GAP ] || todo="$todo $s"
done
if [ -z "$todo" ]; then echo "TCAM carve active on every vPC leaf"
else
  for s in $todo; do ( timeout 20 ssh -n $SSHO "ops@$(mgmt $s)" "terminal dont-ask ; reload" >/dev/null 2>&1; true ) & echo "$(date +%T) $s: reload issued"; done; wait
  sleep 90
  ./nx-wait.sh $todo || exit 1
  for s in $todo; do echo "$s: container $(age_s $s)s, switch up $(up_s $s)s"; done
fi
# 2026-09-28 proof boot: after the TCAM reload ONE leaf (fe-ctrl-leaf2) came back with every loopback stuck in "down (initializing)" / admin
# state unknown, OSPF on no interface, while its twin with the identical config was fine -> no underlay, no virtual peer-link, the ctrl
# pair's vPCs suspended (the whole control plane cut off). vrnetlab still reports the container healthy. A second reload repairs it,
# so a leaf whose loopback0 is not up 3 min after the reload is reloaded again (at most twice).
lo_up() { q $1 "show interface loopback0" | grep -q "loopback0 is up"; }
chk=$LV      # every vPC leaf: also covers a first boot and a re-run of this script
for attempt in 1 2 3; do
  stuck=""; for s in $chk; do for i in $(seq 1 18); do lo_up $s && break; sleep 10; done; lo_up $s || stuck="$stuck $s"; done
  [ -z "$stuck" ] && { echo "$(date +%T) loopback0 up on every vPC leaf"; break; }
  [ $attempt = 3 ] && break
  echo "$(date +%T) loopbacks stuck in 'initializing' after the reload on:$stuck -- reloading it again (attempt $attempt of 2)"
  for s in $stuck; do ( timeout 20 ssh -n $SSHO "ops@$(mgmt $s)" "terminal dont-ask ; reload" >/dev/null 2>&1; true ) & done; wait
  sleep 90; ./nx-wait.sh $stuck || exit 1; chk=$stuck
done
[ -n "$stuck" ] && { echo "$(date +%T) loopbacks still down on:$stuck after 2 extra reloads"; exit 1; }
# A leaf that answers SSH is not forwarding yet: vPC holds its vPCs down for `delay restore` (150 s after the peers form) and NVE holds the source
# loopback -- and with it the pair VIP -- down for its hold-down time (180 s). A validation right after the reload saw every pair VIP missing from
# every NVE peer table and a leaf's 16 vPCs down (2026-09-23); up.sh releases the guests only after this returns.
settled() { local s o; for s in $LV; do o=$(q $s "show vpc brief"); grep -q "peer adjacency formed ok" <<< "$o" && grep -q "Delay-restore status *: Timer is off" <<< "$o" || return 1
  o=$(q $s "show nve interface nve1 detail"); grep -q "Source Interface State: Up" <<< "$o" && grep -q "Remaining hold-down time: 0 seconds" <<< "$o" || return 1; done; }
for i in $(seq 1 40); do settled && { echo "$(date +%T) vPC delay-restore and NVE hold-down finished on every vPC leaf"; exit 0; }; [ $((i % 4)) = 1 ] && echo "$(date +%T) waiting for vPC delay-restore / NVE hold-down"; sleep 15; done
echo "$(date +%T) WARNING: vPC delay-restore / NVE hold-down still running after 10 min"; exit 1
