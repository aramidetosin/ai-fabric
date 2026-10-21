#!/bin/bash
# PID 1 of the REFPLAT VM node container: bridge the containerlab interfaces into taps, build the cloud-init seed
# from the container environment, create the guest disks, boot the guest under KVM and stay attached.
#   eth0 (clab mgmt)   -> br0/tap0 : the guest takes the container's management address and default route
#   eth1, eth2 (fabric) -> br1/tap1, br2/tap2 : the guest bonds them (LACP) to the REFPLAT leaf pair
#   eth3 (OOB / BMC)    -> br3/tap3 : only when OOB_IP is set; the guest addresses it from the BMC range
#   eth(N+1), eth(N+2)  -> storage management FM1 / FM2 when NODE_SM_NICS=2 (site-a-nx: VLAN 200 on the control leaf pair, replaces the OOB NIC)
#   /base/<image>.img   : read-only Ubuntu cloud image; /vm : per-node overlay disk, data disk, seed, console log
set -u
log() { echo "[vm-init] $*"; }
: "${NODE_IP:?}" "${DOMAIN:?}"
HOSTNAME=${NODE_HOSTNAME:-$(hostname)}
VM_MEM=${VM_MEM:-4096}; VM_CPUS=${VM_CPUS:-4}; VM_DISK=${VM_DISK:-40G}; VM_DATA=${VM_DATA:-60G}
BASE=$(ls /base/*.img 2>/dev/null | head -1); [ -n "$BASE" ] || { log "no base image in /base"; sleep infinity; }
mkdir -p /vm
N=${FABRIC_NICS:-2}; NICS="0 $(seq -s " " 1 "$N")"; OOBN=$((N + 1)); [ -n "${OOB_IP:-}" ] && NICS="$NICS $OOBN"
SM=${NODE_SM_NICS:-0}; SMS=""; [ "$SM" -gt 0 ] && [ -z "${OOB_IP:-}" ] && { SMS=$(seq -s " " "$OOBN" $((OOBN + SM - 1))); NICS="$NICS $SMS"; }   # storage management NICs
# ai-fabric: REAL GPU rail NICs (refplat used unwired dummies). Container eth(N+2)..eth(N+1+RAIL_NICS) -> guest gpu0..gpu(RAIL_NICS-1);
# slot N+1 stays reserved for the OOB NIC exactly as in refplat, so none of the OOB handling moves.
R=${RAIL_NICS:-0}; RB=$((N + 2)); [ "$R" -gt 0 ] && NICS="$NICS $(seq -s " " "$RB" $((RB + R - 1)))"

log "waiting for links ..."
for i in $(seq 1 240); do ok=1; for n in $NICS; do ip link show "eth$n" >/dev/null 2>&1 || ok=0; done; [ $ok = 1 ] && break; sleep 1; done
MGMT_IP=$(ip -4 -o addr show eth0 | awk '{print $4}' | head -1)
MGMT_GW=$(ip -4 route show default | awk '{print $3}' | head -1)
MAC_BASE=${NODE_MAC:-52:54:00:00:00:00}; MAC_PFX=${MAC_BASE%:*}
mac() { printf '%s:%02x' "$MAC_PFX" "$1"; }                           # tap<k> -> NODE_MAC prefix + (0x10 + k)
log "guest $HOSTNAME: mgmt $MGMT_IP via $MGMT_GW, fabric $NODE_IP, oob ${OOB_IP:-none}, ${VM_CPUS} vcpu ${VM_MEM} MiB, base $(basename "$BASE")"

ip addr flush dev eth0
for i in $NICS; do
  ip link add "br$i" type bridge 2>/dev/null; ip link set "br$i" up
  ip tuntap add "tap$i" mode tap 2>/dev/null; ip link set "tap$i" master "br$i"
  ip link set "eth$i" master "br$i"
  if [ "$i" -ge 1 ] && [ "$i" != "$OOBN" ] && ! [[ " $SMS " == *" $i "* ]]; then   # jumbo on the fabric bond members and on the rails (not OOB / storage management)
    for d in "eth$i" "tap$i" "br$i"; do ip link set "$d" mtu "${NODE_MTU:-9000}"; done
  fi
  if [ "$i" -ge 1 ]; then
    # 0x4 = bit 2 = 01:80:c2:00:00:02, the slow-protocols address LACP needs to reach the switch. 0x4000 = bit 14 =
    # 01:80:c2:00:00:0e, LLDP. A Linux bridge drops both by default, and only LACP was ever allowed through: the servers
    # were therefore invisible to LLDP on every fabric, rail and OOB link, while switch-to-switch LLDP worked because
    # vrnetlab wires those VMs without a bridge (found 2026-09-20). br0 is the management network and stays closed.
    echo 0x4004 > "/sys/class/net/br$i/bridge/group_fwd_mask"
  fi
  ip link set "tap$i" up; ip link set "eth$i" up
done

# cloud-init seed (NoCloud)
export MGMT_IP MGMT_GW HOSTNAME MAC0=$(mac 16)
# systemd .link files naming every fabric NIC (with the jumbo MTU) and the OOB NIC by MAC, plus the unmanaged list for networkd
LINK_FILES=""; UNMANAGED="bond0 bond0.*"; NL=$'\n'
lnk() { printf -- '- {path: /etc/systemd/network/10-%s.link, content: "[Match]\\nMACAddress=%s\\n[Link]\\nName=%s\\n%s"}' "$1" "$2" "$1" "$3"; }
for k in $(seq 1 "$N"); do LINK_FILES="$LINK_FILES$(lnk "eth$k" "$(mac $((16 + k)))" "MTUBytes=${NODE_MTU:-9000}\\n")$NL"; UNMANAGED="$UNMANAGED eth$k"; done
[ -n "${OOB_IP:-}" ] && { LINK_FILES="$LINK_FILES$(lnk "eth$OOBN" "$(mac $((16 + OOBN)))" "")$NL"; UNMANAGED="$UNMANAGED eth$OOBN"; }
for k in $SMS; do LINK_FILES="$LINK_FILES$(lnk "eth$k" "$(mac $((16 + k)))" "")$NL"; UNMANAGED="$UNMANAGED eth$k"; done
if [ "$R" -gt 0 ]; then for r in $(seq 0 $((R - 1))); do LINK_FILES="$LINK_FILES$(lnk "gpu$r" "$(mac $((16 + RB + r)))" "MTUBytes=${NODE_MTU:-9000}\\n")$NL"; UNMANAGED="$UNMANAGED gpu$r"; done; fi
export LINK_FILES UNMANAGED
export OPERATOR_KEYS=$(grep -v "^\s*$" /authorized_keys 2>/dev/null | sed "s/^/\"/; s/$/\"/" | paste -sd, | sed "s/^/[/; s/$/]/")
export NODE_ENV_B64=$( { env | grep -E '^(NODE_|OOB_|NTP_|CLUSTER_|API_|DOMAIN=|POD_CIDR=|SVC_CIDR=|K8S_|JOIN_|CERT_|GW_|LB_|DNS_|FABRIC_|HUBBLE_|CILIUM_|CERTMGR_|GATEWAY_|EXPECT_|BASTION_|PC_|DEMO_|BGP_|LB_MODE=|GPU_|RAIL_|MULTUS_|WHEREABOUTS_|LONGHORN_|WEBUI_|HEADLAMP_|METRICS_)' \
  | while IFS='=' read -r k v; do printf '%s=%q\n' "$k" "$v"; done; } | base64 -w0 )
b64() { base64 -w0 < "$1"; }
export NETSETUP_B64=$(b64 /opt/node-files/netsetup.sh) BOOTSTRAP_B64=$(b64 /opt/node-files/cluster-bootstrap.sh)
export NETSETUP_UNIT_B64=$(b64 /opt/node-files/ai-fabric-netsetup.service) CLUSTER_UNIT_B64=$(b64 /opt/node-files/ai-fabric-cluster.service)
# every kubeadm / helm / manifest file the bootstrap renders, as cloud-init write_files entries
export K8S_FILES=$(for f in /opt/node-files/k8s/*; do [ -f "$f" ] || continue; printf -- '- {path: /opt/ai-fabric/k8s/%s, permissions: "0644", encoding: b64, content: "%s"}\n' "$(basename "$f")" "$(b64 "$f")"; done)
# lab tools on every node: the storage management API stand-in (served on the storage node) and the PVC client
export TOOL_FILES=$(for f in /opt/node-files/tools/*; do [ -f "$f" ] || continue; printf -- '- {path: /usr/local/bin/%s, permissions: "0755", encoding: b64, content: "%s"}\n' "$(basename "$f")" "$(b64 "$f")"; done)
# lab CA (site-a-nx): only the init node's container gets the host-only ca/ directory (read-only). Its files reach the guest as write_files, which
# cloud-init runs before runcmd starts the bootstrap, so kubeadm init finds the Kubernetes CA in place. Keys 0600; every other node renders nothing.
export CA_FILES=$(for f in /ca/root.crt /ca/platform.crt /ca/platform.key /ca/kubernetes.crt /ca/kubernetes.key; do [ -s "$f" ] || continue
  case $f in *.key) m=0600 ;; *) m=0644 ;; esac; printf -- '- {path: /etc/ai-fabric/ca/%s, permissions: "%s", encoding: b64, content: "%s"}\n' "$(basename "$f")" "$m" "$(b64 "$f")"; done)
K8S_MINOR=$(echo "${K8S_VERSION:-v1.35.8}" | cut -d. -f1-2); export K8S_MINOR
export NODE_MTU=${NODE_MTU:-9000} NTP_SERVER=${NTP_SERVER:-8.8.8.8}
envsubst < /opt/cloud-init/user-data.tmpl > /vm/user-data
# storage node: a TLS listener stands in for the FlashBlade management REST API (the firewall rule under test). It binds the management VIP
# (site-a-nx, VLAN 200, floated by fb-vip) or the OOB address (other profiles); both units are repository files that node-sync keeps current.
if [ "${NODE_KIND:-}" = storage ] && { [ -n "${OOB_IP:-}" ] || [ -n "${NODE_SM_VIP:-}" ]; }; then
  FBU=$(b64 /opt/node-files/flashblade-api.service); VIPU=$(b64 /opt/node-files/fb-vip.service)
  cat >> /vm/user-data <<EOT
- [sh, -c, "mkdir -p /etc/ai-fabric/fb && openssl req -x509 -newkey rsa:2048 -nodes -keyout /etc/ai-fabric/fb/key.pem -out /etc/ai-fabric/fb/cert.pem -days 3650 -subj '/CN=${HOSTNAME}' >/dev/null 2>&1"]
- [sh, -c, "echo ${FBU} | base64 -d > /etc/systemd/system/flashblade-api.service && echo ${VIPU} | base64 -d > /etc/systemd/system/fb-vip.service && systemctl daemon-reload && systemctl enable --now fb-vip.service flashblade-api.service"]
EOT
fi
envsubst < /opt/cloud-init/network-config.tmpl > /vm/network-config
printf 'instance-id: %s\nlocal-hostname: %s\n' "$HOSTNAME" "$HOSTNAME" > /vm/meta-data
cloud-localds -N /vm/network-config /vm/seed.iso /vm/user-data /vm/meta-data

[ -f /vm/root.qcow2 ] || qemu-img create -q -f qcow2 -b "$BASE" -F qcow2 /vm/root.qcow2 "$VM_DISK"
[ -f /vm/data.img ]   || qemu-img create -q -f raw /vm/data.img "$VM_DATA"

NETS=""
for k in $(seq 1 "$N"); do NETS="$NETS -netdev tap,id=n$k,ifname=tap$k,script=no,downscript=no -device virtio-net-pci,netdev=n$k,mac=$(mac $((16 + k))),speed=10000,duplex=full"; done
[ -n "${OOB_IP:-}" ] && NETS="$NETS -netdev tap,id=n$OOBN,ifname=tap$OOBN,script=no,downscript=no -device virtio-net-pci,netdev=n$OOBN,mac=$(mac $((16 + OOBN)))"
for k in $SMS; do NETS="$NETS -netdev tap,id=n$k,ifname=tap$k,script=no,downscript=no -device virtio-net-pci,netdev=n$k,mac=$(mac $((16 + k)))"; done
if [ "$R" -gt 0 ]; then for r in $(seq 0 $((R - 1))); do k=$((RB + r)); NETS="$NETS -netdev tap,id=n$k,ifname=tap$k,script=no,downscript=no -device virtio-net-pci,netdev=n$k,mac=$(mac $((16 + k))),speed=10000,duplex=full"; done; fi
log "booting guest (console in /vm/console.log)"
exec qemu-system-x86_64 -enable-kvm -cpu host -machine q35,accel=kvm -smp "$VM_CPUS" -m "$VM_MEM" -nographic -nodefaults \
  -serial file:/vm/console.log -monitor none \
  -drive file=/vm/root.qcow2,if=virtio,format=qcow2,cache=none,aio=threads \
  -drive file=/vm/data.img,if=virtio,format=raw,cache=none,aio=threads \
  -drive file=/vm/seed.iso,if=virtio,format=raw,readonly=on \
  -fsdev local,id=fs0,path=/shared,security_model=none -device virtio-9p-pci,fsdev=fs0,mount_tag=shared \
  -netdev tap,id=n0,ifname=tap0,script=no,downscript=no -device virtio-net-pci,netdev=n0,mac="$MAC0" \
  $NETS
