#!/bin/bash
LABDIR="${LABDIR:-/root/ai-fabric}"   # override if the repo lives elsewhere
# rail-leaf-watchdog.sh: detect a rail leaf that has stopped forwarding and reload it in place.
#
# THE FAULT. The OcNOS demo VM leaks under sustained load. The guest climbs to whatever memory ceiling it was given
# and then stops forwarding: BGP stays Established and the CLI still answers, but the rail SVI stops replying to ARP
# and every cross-rail flow through that leaf dies. Seen twice:
#   2026-09-20  be-leaf7 + be-leaf8 at 4004 MB of a 4096 MB ceiling
#   2026-09-21  be-leaf3 + be-leaf4 + be-leaf5 at ~6046 MB of a 6144 MB ceiling
# Raising the ceiling only buys time, so this watches for the fault itself.
#
# WHY NOT TRIGGER ON MEMORY. qemu never returns freed guest pages to the host, so its RSS is a HIGH-WATER MARK, not
# current usage: be-leaf5 still read 6162 MB immediately after a clean reboot that fully restored the rail. Triggering
# on RSS would therefore reload a healthy leaf forever. RSS is reported here as context only, never as the trigger.
#
# THE TRIGGER is the symptom itself: from a GPU node, the rail gateway 172.16.<R>.1 stops answering. That is exactly
# what breaks cross-rail traffic, it has no false positives from high-water RSS, and it clears the moment the leaf is
# healthy again.
#
# THE ACTION is `reload` over the switch's own CLI, WITHOUT saving (rail-restore.sh, see below). That reboots the guest while the CONTAINER and its veth links stay
# in place, so the leaf comes back cabled and configured (~3 min). NEVER `docker restart` a containerlab node: that does
# not recreate the veths and the node returns link-less, with qemu stuck "waiting for provisioned interfaces".
#
#   ./rail-leaf-watchdog.sh           one pass: report every rail, reload at most ONE broken leaf
#   ./rail-leaf-watchdog.sh report    report only, change nothing
set -uo pipefail
LAB=${LAB:-clab-ai-fabric}
MGMT_BASE=${MGMT_BASE:-172.21.21}
LEAF_BASE=${LEAF_BASE:-50}          # be-leaf L -> $MGMT_BASE.$((LEAF_BASE + L))
PROBE=${PROBE:-172.21.21.121}       # a GPU node to probe the rail gateways from (gpu1)
RAIL_NET=${RAIL_NET:-172.16}
LOG=${LOG:-/var/log/rail-leaf-watchdog.log}
MODE=${1:-act}
SSHO="-o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10"

say() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }

rss_mb() { local p; p=$(docker top "$1" 2>/dev/null | awk '/qemu-system/ {print $2; exit}')
           [ -n "$p" ] || { echo 0; return; }
           echo $(( $(awk '/VmRSS/{print $2}' "/proc/$p/status" 2>/dev/null || echo 0) / 1024 )); }

rail_up() {  # $1 = rail number. Two tries: one lost packet after a reload is not a fault.
  timeout 20 ssh -n $SSHO "admin@$PROBE" "ping -c2 -W2 $RAIL_NET.$1.1 >/dev/null 2>&1" >/dev/null 2>&1
}

# GUARD 1: never act while the lab is being rebuilt or deliberately broken. The acceptance drills fail links and
# whole spines on purpose, and a redeploy takes every rail down for minutes; reacting to either would be wrong.
for u in ai-fabric-redeploy ai-fabric-accept ai-fabric-lab; do
  if systemctl is-active --quiet "$u" 2>/dev/null; then say "$u is running, standing down"; exit 0; fi
done
if [ -f "$LABDIR/shared/hold-guests" ]; then say "guests still held by up.sh, standing down"; exit 0; fi

timeout 15 ssh -n $SSHO "admin@$PROBE" true >/dev/null 2>&1 || { say "probe node $PROBE unreachable, nothing done"; exit 0; }

broken=""
for L in 1 2 3 4 5 6 7 8; do
  c="$LAB-be-leaf$L"; m=$(rss_mb "$c")
  [ "$m" = 0 ] && { say "be-leaf$L: no qemu running, skipped"; continue; }
  if rail_up "$L"; then say "be-leaf$L: rail $L up (rss ${m}MB high-water)"
  else say "be-leaf$L: rail $L DOWN (rss ${m}MB high-water)"; broken="$broken $L"; fi
done

# GUARD 2: only act on a fault that PERSISTS across two passes. A rail can be legitimately down for a moment while
# a leaf boots, while the fabric converges after a deploy, or during a drill that this script did not catch above.
# The leak, by contrast, does not heal on its own, so a real one is still there on the next pass.
STATE=${STATE:-/var/lib/rail-leaf-watchdog/down-last-pass}
mkdir -p "$(dirname "$STATE")"
prev=$(cat "$STATE" 2>/dev/null || echo "")
echo "$broken" > "$STATE"

[ -z "$broken" ] && { say "pass complete, all 8 rails up"; exit 0; }
[ "$MODE" = report ] && { say "pass complete, rails down:$broken (report only)"; exit 0; }

confirmed=""
for L in $broken; do case " $prev " in *" $L "*) confirmed="$confirmed $L";; esac; done
[ -z "$confirmed" ] && { say "rails down:$broken - first pass, waiting for confirmation before acting"; exit 0; }
broken="$confirmed"

# One per pass on purpose: reloading two rail leaves at once would drop two rails simultaneously.
L=$(echo $broken | awk '{print $1}'); ip="$MGMT_BASE.$((LEAF_BASE + L))"
say "be-leaf$L: restoring (rail $L is already down; reload without saving, ~3 min to come back)"
# 2026-10-04: the old sequence here answered "y" to everything. On a leaf that has LOST its L2 configuration, OcNOS first asks "The system has unsaved
# changes. Would you like to save them now?", and that yes wrote the broken running config over the good saved one. rail-restore.sh looks at the
# prompt, never saves an unchecked config, and types the generated config in again when the saved one is already overwritten.
o=$("$(dirname "$(readlink -f "$0")")/../rail-restore.sh" "be-leaf$L" 2>&1 | tail -1); say "$o"
rail_up "$L" && say "be-leaf$L: rail $L back up" || say "be-leaf$L: rail $L STILL DOWN, needs a redeploy"
say "pass complete, rails still to check:$(echo $broken | cut -d' ' -f2-)"
