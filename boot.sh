#!/bin/bash
# boot.sh: bring ai-fabric back after a host boot (run by the ai-fabric-lab systemd unit, see host/install.sh; also fine by hand).
# A reboot leaves the lab's containers behind WITHOUT their links (veth pairs do not survive, and docker restarts the restart=always ones on
# its own), so the lab is removed and deployed again ON THE EXISTING GUEST DISKS: Kubernetes, Longhorn volumes, Harbor, the S3 disk and the
# operator's secrets are all still there. Switches and the firewall always boot from the generated configs. Then finish.sh, then validation.
# Always exits 0 so the unit stays active and its ExecStop (clean guest shutdown) runs at the next host shutdown; the verdict is in
# boot-status and the log.
cd "$(dirname "$0")"; . ./lib.sh 2>/dev/null
say() { echo "== $(date '+%F %T') $*"; }
verdict() { echo "$(date '+%F %T') $*" > boot-status; say "RESULT: $*"; exit 0; }
[ -e no-autostart ] && verdict "skipped (no-autostart present)"
say "boot: waiting for docker and the ${EXT:=pnet0} bridge"
for i in $(seq 1 120); do docker info >/dev/null 2>&1 && ip link show "$EXT" >/dev/null 2>&1 && break; sleep 5; done
docker info >/dev/null 2>&1 || verdict "FAILED: docker not available"
# already up with its wiring intact (unit started by hand / installed on a running lab)? then only finish, never redeploy
if [ "$(health bastion)" = running ] && [ "$(health fw)" = healthy ] && docker exec "$LAB-ctrl1" ip link show eth1 >/dev/null 2>&1; then
  say "lab is running with its links: adopting it (no redeploy)"; NO_DEPLOY=1
fi
if [ -z "${NO_DEPLOY:-}" ]; then
  say "removing what the reboot left behind (guest disks are kept)"; ./down.sh fast
  say "deploying"; NO_FINISH=1 ./up.sh || verdict "FAILED: up.sh (see above)"
fi
./finish.sh; rc=$?
[ $rc = 0 ] || verdict "FAILED: finish.sh, $rc stage(s) -- see finish.log"
if [ "${BOOT_VALIDATE:-1}" = 1 ] && [ -z "${NO_DEPLOY:-}" ]; then say "validation (result set in audits/, as always)"; ./validate.sh > /dev/null 2>&1
  r=$(grep -h "^== RESULT" $(ls -t audits/ai-fabric_validation_*/RESULT.txt 2>/dev/null | head -1) 2>/dev/null | tail -1)
  verdict "lab fully working; validation ${r:-: no result found, see audits/}"; fi
verdict "lab fully working"
