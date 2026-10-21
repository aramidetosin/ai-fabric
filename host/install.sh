#!/bin/bash
# host/install.sh: make ai-fabric survive a reboot of this host. Idempotent. Undo with host/uninstall.sh.
#   - checks what ./up.sh needs on a bare host (nothing is downloaded or changed by the checks)
#   - installs + enables ai-fabric-lab.service: boot.sh after a boot, stop.sh (clean guest power-off) before a shutdown
# A running lab is adopted, not redeployed. One-off opt-out for the next boot: touch /root/ai-fabric/no-autostart
set -euo pipefail
cd "$(dirname "$0")/.."; D=$(pwd); bad=0
chk() { if eval "$2" >/dev/null 2>&1; then printf '  ok       %s\n' "$1"; else printf '  MISSING  %s\n' "$1"; bad=1; fi; }
echo "prerequisites:"
chk "docker"                                   "docker info"
chk "containerlab"                             "command -v containerlab"
chk "KVM (/dev/kvm)"                           "[ -e /dev/kvm ]"
chk "python3 + PyYAML-free generator runs"     "python3 -c 'import gen'"
chk "bridge $(python3 -c 'import gen; print(gen.EXT_BRIDGE)') (firewall outside)" "ip link show $(python3 -c 'import gen; print(gen.EXT_BRIDGE)')"
chk "Ubuntu cloud image in $(python3 -c 'import gen; print(gen.BASE_IMG_DIR)')"   "ls $(python3 -c 'import gen; print(gen.BASE_IMG_DIR)')/*.img"
chk "NAT for the management subnet (clab-mgmt-nat.service)" "systemctl is-enabled clab-mgmt-nat.service"
for i in $(python3 -c 'import gen; print(" ".join(sorted({gen.OCNOS_IMAGE, gen.PAN_IMAGE, gen.VEX_IMAGE if (gen.VEX or gen.NXOS) else gen.CVX_IMAGE} | ({gen.NX_IMAGE} if gen.NXOS else set()))))'); do chk "image $i" "docker image inspect $i"; done
chk "operator keys (common/authorized_keys)"   "[ -s common/authorized_keys ]"
[ $bad = 0 ] || { echo "fix the MISSING items first (the node/bastion images are built by ./up.sh itself)"; exit 1; }
sed "s#/root/ai-fabric#$D#g" host/ai-fabric-lab.service > /etc/systemd/system/ai-fabric-lab.service
systemctl daemon-reload; systemctl enable ai-fabric-lab.service >/dev/null 2>&1
systemctl start --no-block ai-fabric-lab.service       # adopts the running lab, or deploys it when it is down
echo "ai-fabric-lab.service enabled and started (log: /var/log/ai-fabric-lab.log, verdict: $D/boot-status)"
