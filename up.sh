#!/bin/bash
# Deploy ai-fabric. ./up.sh = full lab (refplat-style VM nodes + Kubernetes) and everything after it (finish.sh) up to a fully working lab;
# ./up.sh light = same cabling, servers as containers. Existing guest disks are re-used (./down.sh wipe starts from nothing). NO_FINISH=1 stops after the deploy.
set -euo pipefail
cd "$(dirname "$0")"
python3 gen.py
T=ai-fabric.clab.yml; [ "${1:-}" = light ] && T=ai-fabric-light.clab.yml
[ -f "$(dirname "$0")/images/vm-node/base/noble-server-cloudimg-amd64.img" ] || { echo "missing Ubuntu base image: see RUNBOOK.md section 2 (images/vm-node/base/noble-server-cloudimg-amd64.img)"; exit 1; }
lsmod | grep -q '^bonding' || modprobe bonding
# Directories the topology bind-mounts. They are deliberately NOT in the repository (ca/ holds the
# lab CA, shared/ and publish/ are runtime state), but containerlab verifies every bind path before
# it deploys, so they have to exist first. ca-certs.sh then populates ca/.
mkdir -p shared ca publish
MIRRORS=$(python3 -c 'import gen; print(gen.PF["mirrors"])'); [ -z "$MIRRORS" ] || ./registry-cache.sh start      # profiles with pull-through caches (site-b)
# Rebuild an image whenever its BUILD CONTEXT is newer than the image, not merely when the image is missing. The old guard shipped
# whatever was built last: on 2026-09-20 an edit to images/bastion (bastion-dns.sh) and to images/vm-node/node-files (the sshd fix)
# would have been silently left out of a "fresh" deploy, because both images already existed. Docker's layer cache makes the
# no-change case cheap, so this only costs time when something really did change.
stale() {   # $1 = image tag, $2 = build context
  local created
  docker image inspect "$1" >/dev/null 2>&1 || return 0
  created=$(date -d "$(docker image inspect -f '{{.Created}}' "$1")" +%s 2>/dev/null) || return 0
  [ -n "$(find "$2" -type f -newermt "@$created" -print -quit 2>/dev/null)" ]
}
if stale ai-fabric-vm-node:latest images/vm-node || stale ai-fabric-bastion:latest images/bastion; then
  echo "image build context changed -> rebuilding the lab images"; ./build-images.sh
fi
# PA-VM launcher console fix (profiles with pa_console_fix, site-b-nx): a login prompt split across two console reads deadlocked the launcher
if python3 -c 'import gen, sys; sys.exit(0 if gen.PF.get("pa_console_fix") else 1)'; then ./host/pa-vm-console-fix.sh; fi
# HOLD THE GUESTS until the frontend is configured and converged (vm-init.sh waits while shared/hold-guests exists). On existing disks a guest is
# up in a minute and brings LACP, MAC learning and ARP onto switches whose EVPN/ESI configuration is still being committed: both restart tests of
# 2026-09-18 left vEX data planes with stale entries (control plane correct, single flows dropped for good). A first deployment never showed it:
# its guests spend 40 min in cloud-init first.
[ "${1:-}" = light ] || { : > shared/hold-guests; trap 'rm -f shared/hold-guests' EXIT; }
containerlab deploy -t "$T" --reconfigure --max-workers "${CLAB_WORKERS:-8}"
./eve-cloud.sh || true      # EVE-NG cloud <-> management network (profiles with eve_cloud): the bridge is new after every deploy
# Juniper vEX frontend: the boot config only carries the operator SSH keys; the fabric configuration goes in over key-based SSH once Junos is up
if grep -q " junos$" mgmt-hosts.txt; then echo "waiting for the vEX switches, then applying configs/*.set ..."; ./apply-junos.sh; fi
# Cisco Nexus frontend (site-a-nx): vrnetlab applies configs/*.cfg at first boot; the vPC fabric-peering TCAM carve then needs ONE reload of the
# vPC leaves (every deploy is a first boot). A failure here only warns, like wait-fabric: aborting would fire the EXIT trap and release the guests.
if grep -q " nxos$" mgmt-hosts.txt; then echo "waiting for the Nexus switches, then activating the fabric-peering TCAM carve ..."
  { ./nx-wait.sh && ./nx-tcam-reload.sh; } || echo "WARNING: Nexus switches not ready or TCAM carve not active (see above)"
  # Nexus Dashboard's telemetry block (profiles with ndfc=True): applied after boot, see nx-telemetry.sh for why it is not in configs/*.cfg
  ./nx-telemetry.sh || echo "WARNING: ND telemetry block not applied on every Nexus switch (see above)"; fi
if [ "${1:-}" != light ]; then ./wait-fabric.sh || echo "WARNING: releasing the guests although the frontend has not converged"; rm -f shared/hold-guests; echo "$(date +%T) guests released"; fi
# everything after the deploy, up to "fully working": bootstrap wait, node roles, Harbor/S3/Longhorn services, pods settled (finish.sh)
if [ "${1:-}" != light ] && [ -z "${NO_FINISH:-}" ]; then ./finish.sh; fi
