#!/bin/bash
# host/reboot-test.sh: prove the lab survives a host reboot WITHOUT rebooting the host (other labs run here). It reproduces what a reboot does
# to the lab and then lets the systemd unit bring it back exactly as after a boot:
#   1. systemctl stop ai-fabric-lab     = the shutdown hook: every guest powered off cleanly (stop.sh)
#   2. docker stop on the rest        = docker at shutdown; all veth links are gone afterwards
#   3. docker start on restart=always = docker after a boot: those containers come back WITHOUT their links
#   4. systemctl start ai-fabric-lab    = boot.sh: remove the leftovers, deploy on the existing disks, finish.sh, validate.sh
# ~45 min at 39 nodes. Verdict: boot-status; log: /var/log/ai-fabric-lab.log; validation result set in audits/.
cd "$(dirname "$0")/.."; . ./lib.sh
systemctl is-enabled ai-fabric-lab.service >/dev/null 2>&1 || { echo "ai-fabric-lab.service is not installed (host/install.sh)"; exit 1; }
t0=$(date +%s); echo "== $(date +%T) 1/4 shutdown hook"; systemctl stop ai-fabric-lab.service
echo "== $(date +%T) 2/4 stopping the remaining containers"; docker ps -q --filter name=$LAB- | xargs -r docker stop -t 5 >/dev/null 2>&1
echo "== $(date +%T) 3/4 containers docker restarts by policy after a boot:"
for c in $(docker ps -aq --filter name=$LAB-); do [ "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' $c)" = always ] && docker start $c >/dev/null 2>&1; done
echo "   $(docker ps --format '{{.Names}}' --filter name=$LAB- | xargs)"
: > boot-status; echo "== $(date +%T) 4/4 boot"; systemctl start --no-block ai-fabric-lab.service
until [ -s boot-status ]; do sleep 30; done
echo "== $(date +%T) done in $(( ($(date +%s) - t0) / 60 )) min: $(cat boot-status)"
