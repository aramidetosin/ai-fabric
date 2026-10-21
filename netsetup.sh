#!/bin/bash
# Fabric networking for an ai-fabric k8s node (systemd oneshot, before kubelet / cluster bootstrap).
# eth0  = clab mgmt / OOB (keeps the default route -> internet via eve NAT)
# eth1+eth2 = 802.3ad bond0 to the vPC pair, MTU 9000 (as reflab), fabric routes only.
set -u
. /etc/ai-fabric/node.env
log() { echo "[netsetup] $*"; }
MTU=${NODE_MTU:-9000}

N=${FABRIC_NICS:-2}; OOBDEV="eth$((N + 1))"
# VM nodes: NIC k carries NODE_MAC's prefix + (0x10 + k) (vm-init.sh); if udev has not named them yet, do it here
if [ -n "${NODE_MAC:-}" ]; then
  for n in $(seq 1 $((N + 1))); do
    ip link show "eth$n" >/dev/null 2>&1 && continue
    want=$(printf '%s:%02x' "${NODE_MAC%:*}" $((16 + n)))
    dev=$(ip -o link | awk -v m="$want" 'tolower($0) ~ m {sub(":", "", $2); print $2; exit}')
    [ -n "$dev" ] && { ip link set "$dev" down; ip link set "$dev" name "eth$n"; log "renamed $dev ($want) to eth$n"; }
  done
fi
log "waiting for fabric links eth1..eth$N ..."
for i in $(seq 1 240); do ok=1; for k in $(seq 1 "$N"); do ip link show "eth$k" >/dev/null 2>&1 || ok=0; done; [ $ok = 1 ] && break; sleep 1; done
ip link show eth1 >/dev/null 2>&1 || { log "eth1 never appeared"; exit 1; }

# 802.3ad needs a speed and duplex from each member; virtio NICs (the VM nodes) report none unless told
for k in $(seq 1 "$N"); do ethtool -s "eth$k" speed 10000 duplex full autoneg off >/dev/null 2>&1 || true; done
if ! ip link show bond0 >/dev/null 2>&1; then
  ip link add bond0 type bond mode 802.3ad lacp_rate fast miimon 100 xmit_hash_policy layer3+4
  [ -n "${NODE_MAC:-}" ] && ip link set bond0 address "$NODE_MAC"
  for k in $(seq 1 "$N"); do ip link set "eth$k" down; ip link set "eth$k" master bond0; ip link set "eth$k" mtu "$MTU"; done
  ip link set bond0 mtu "$MTU"
  for k in $(seq 1 "$N"); do ip link set "eth$k" up; done; ip link set bond0 up
fi
# NODE_VLAN set (storage node): the switch port is a tagged-only trunk, so the node address lives on bond0.<vlan>
DATA_DEV=bond0
if [ -n "${NODE_VLAN:-}" ]; then
  DATA_DEV="bond0.${NODE_VLAN}"
  ip link show "$DATA_DEV" >/dev/null 2>&1 || ip link add link bond0 name "$DATA_DEV" type vlan id "$NODE_VLAN"
  ip link set "$DATA_DEV" mtu "$MTU"; ip link set "$DATA_DEV" up
fi
ip addr replace "${NODE_IP}/${NODE_PREFIX:-24}" dev "$DATA_DEV"
ip route replace "${FABRIC_CIDR:-10.167.0.0/16}" via "$NODE_GW" dev "$DATA_DEV"
# Internet egress goes through the fabric: anycast gateway -> border leaves -> firewall (NAT on its external interface), as the
# e& design. The management NIC (eth0, clab management network) keeps a default of its own in table 200 for traffic sourced
# from the management address only (operator SSH, the bastion pass-through), so replies never leave via the fabric.
MGMT_IP=$(ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1 | head -1); MGMT_GW=$(ip -4 route show default dev eth0 | awk '{print $3}' | head -1)
if [ -n "$MGMT_IP" ] && [ -n "$MGMT_GW" ]; then
  ip route replace default via "$MGMT_GW" dev eth0 table 200; ip route replace "$(ip -4 -o route show dev eth0 proto kernel | awk '{print $1; exit}')" dev eth0 src "$MGMT_IP" table 200 2>/dev/null
  ip rule show | grep -q "from $MGMT_IP lookup 200" || ip rule add from "$MGMT_IP" lookup 200
  ip route del default via "$MGMT_GW" dev eth0 2>/dev/null
fi
ip route replace default via "$NODE_GW" dev "$DATA_DEV"
log "default route via $NODE_GW on $DATA_DEV (fabric -> firewall); management ${MGMT_IP:-?} keeps eth0 via ${MGMT_GW:-?} in table 200"
# BGP announcement option: tagged peering sub-interface on the bond (VLAN 111, not VXLAN-extended). Requests for a
# published address arrive here, replies leave untagged via the anycast gateway, so reverse-path filtering must be off.
if [ -n "${NODE_BGP_IP:-}" ]; then
  V=${BGP_VLAN:-111}
  ip link show "bond0.$V" >/dev/null 2>&1 || ip link add link bond0 name "bond0.$V" type vlan id "$V"
  ip link set "bond0.$V" mtu "$MTU"; ip link set "bond0.$V" up
  ip addr replace "${NODE_BGP_IP}/24" dev "bond0.$V"
  echo 0 > "/proc/sys/net/ipv4/conf/bond0.$V/rp_filter" 2>/dev/null || true
  log "bond0.$V ${NODE_BGP_IP}/24 (Cilium BGP peering to ${BGP_PEER_A:-?} and ${BGP_PEER_B:-?}, AS ${BGP_PEER_ASN:-?})"
fi
# GPU nodes: 8 rail NICs addressed <RAIL_PREFIX>.R.<idx>/24, Multus attaches pods to them.
#   RAIL_NICS>0 (ai-fabric): gpu<r> are REAL NICs cabled to the backend rail leaves (rail R = leaf R, gateway <RAIL_PREFIX>.R.1).
#   RAIL_NICS unset (refplat): unwired dummy NICs.
if [ -n "${NODE_RAIL_INDEX:-}" ]; then
  RN=${RAIL_NICS:-0}; RB=$((N + 2))
  for r in $(seq 0 $(( ${GPU_RAILS:-8} - 1 ))); do
    if [ "$RN" -gt 0 ]; then
      if ! ip link show "gpu$r" >/dev/null 2>&1 && [ -n "${NODE_MAC:-}" ]; then   # udev has not named it yet: find it by MAC
        want=$(printf "%s:%02x" "${NODE_MAC%:*}" $((16 + RB + r)))
        dev=$(ip -o link | awk -v m="$want" "tolower(\$0) ~ m {sub(\":\", \"\", \$2); print \$2; exit}")
        [ -n "$dev" ] && { ip link set "$dev" down; ip link set "$dev" name "gpu$r"; log "renamed $dev ($want) to gpu$r"; }
      fi
    else
      ip link show "gpu$r" >/dev/null 2>&1 || ip link add "gpu$r" type dummy
    fi
    ip link show "gpu$r" >/dev/null 2>&1 || { log "gpu$r missing"; continue; }
    ip link set "gpu$r" mtu "$MTU" up
    RIP="${RAIL_PREFIX:-10.200}.$((r + 1)).${NODE_RAIL_INDEX}"
    ip addr replace "$RIP/24" dev "gpu$r"
    if [ "$RN" -gt 0 ]; then
      # single-homed rail NICs, no bonding (AI_FABRIC backend onboarding notes). Traffic SOURCED from a rail address must leave on that
      # rail, so cross-rail destinations go leaf -> spine -> leaf instead of hopping rails inside the host.
      T=$((300 + r)); GW="${RAIL_PREFIX:-10.200}.$((r + 1)).1"
      ip route replace "${RAIL_PREFIX:-10.200}.$((r + 1)).0/24" dev "gpu$r" src "$RIP" table "$T"
      ip route replace default via "$GW" dev "gpu$r" table "$T"
      ip rule show | grep -q "from $RIP lookup $T" || ip rule add from "$RIP" lookup "$T"
      for k in rp_filter; do echo 0 > "/proc/sys/net/ipv4/conf/gpu$r/$k" 2>/dev/null || true; done
      echo 1 > "/proc/sys/net/ipv4/conf/gpu$r/arp_ignore" 2>/dev/null || true     # eight NICs in one host: answer ARP only for the address on that NIC
      echo 2 > "/proc/sys/net/ipv4/conf/gpu$r/arp_announce" 2>/dev/null || true
    fi
  done
  log "rails gpu0-gpu$(( ${GPU_RAILS:-8} - 1 )) up, ${RAIL_PREFIX:-10.200}.R.${NODE_RAIL_INDEX}/24 ($([ "$RN" -gt 0 ] && echo "real NICs, source-routed via .1" || echo dummies))"
fi
# Longhorn: every node is an iSCSI initiator (the kernel transport module is host-wide and must be loaded from
# somewhere; the nodes do it at boot); the image ships one IQN, so give each node its own
modprobe iscsi_tcp 2>/dev/null || true
mkdir -p /run/lock/iscsi   # iscsiadm refuses to run without its lock directory, which nothing creates for it here
if command -v iscsi-iname >/dev/null 2>&1 && ! grep -q "$(hostname)" /etc/iscsi/initiatorname.iscsi 2>/dev/null; then
  echo "InitiatorName=$(iscsi-iname -p iqn.2026-09.local.ai-fabric):$(hostname)" > /etc/iscsi/initiatorname.iscsi
  systemctl restart iscsid 2>/dev/null || true
fi
# OOB / BMC NIC (eth3 -> the OOB switch): addressed from the BMC range, answers only from its own table so replies to
# the firewall's OOB side leave via eth3, never via the fabric bond
if [ -n "${OOB_IP:-}" ] && ip link show "$OOBDEV" >/dev/null 2>&1; then
  ip link set "$OOBDEV" up
  ip addr replace "${OOB_IP}/${OOB_PREFIX:-27}" dev "$OOBDEV"
  ip rule show | grep -q "from ${OOB_IP} lookup 100" || ip rule add from "${OOB_IP}" lookup 100
  ip route replace default via "${OOB_GW:-10.125.31.254}" dev "$OOBDEV" table 100
  # a real BMC is a separate device: the OS must not shortcut to the OOB subnet through its own BMC NIC (that would make
  # node -> FlashBlade-mgmt traffic bypass the firewall one way and be dropped as asymmetric). Keep the connected route
  # only in the BMC's own table, so main-table traffic to 10.125.31.x goes through the fabric and the firewall.
  OOB_NET=$(ip -o -4 route show dev "$OOBDEV" table main | awk '/proto kernel/ {print $1; exit}')
  if [ -n "$OOB_NET" ]; then ip route del "$OOB_NET" dev "$OOBDEV" table main 2>/dev/null; ip route replace "$OOB_NET" dev "$OOBDEV" src "$OOB_IP" table 100; fi
  echo 0 > "/proc/sys/net/ipv4/conf/$OOBDEV/rp_filter" 2>/dev/null || true
  log "$OOBDEV (OOB/BMC) ${OOB_IP}/${OOB_PREFIX:-27}, replies via ${OOB_GW:-10.125.31.254} (table 100)"
fi
# kube-vip's ARP VIP and the L2-announced LB VIPs live in this subnet: allow local delivery
sysctl -qw net.ipv4.ip_forward=1 net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.bond0.rp_filter=0 net.ipv4.conf.eth0.rp_filter=0
[ "$DATA_DEV" = bond0 ] || echo 0 > "/proc/sys/net/ipv4/conf/$DATA_DEV/rp_filter" 2>/dev/null
# eve's VPN client sets net.ipv4.conf.all.src_valid_mark=1 and the host passes it into
# new network namespaces. With it, the kernel validates a proxied packet's source using Cilium's
# 0x200 fwmark, hits table 2004 ("local default dev lo") and drops wire clients of the Gateway as a
# martian (kfree_skb reason IP_LOCAL_SOURCE). reference nodes (Ubuntu VMs) have 0; match them.
sysctl -qw net.ipv4.conf.all.src_valid_mark=0 net.ipv4.conf.default.src_valid_mark=0 net.ipv4.conf.bond0.src_valid_mark=0

# Pod egress to the internet leaves through the management NIC, which is not a Cilium device, so Cilium never
# masquerades it: SNAT the pod range to the node's management address here (the host NATs it onwards)
if command -v iptables >/dev/null 2>&1; then
  for o in eth0 "$DATA_DEV"; do   # pod egress leaves via the fabric bond now (default route); keep the management NIC rule for completeness
    iptables -t nat -C POSTROUTING -s "${POD_CIDR:-10.42.0.0/16}" -o "$o" -j MASQUERADE 2>/dev/null \
      || iptables -t nat -A POSTROUTING -s "${POD_CIDR:-10.42.0.0/16}" -o "$o" -j MASQUERADE
  done
fi
# DNS: the bastion's BIND first (serves the lab zone and forwards the internet), public fallback
[ -L /etc/resolv.conf ] && rm -f /etc/resolv.conf
printf 'search %s\nnameserver %s\nnameserver 8.8.8.8\noptions timeout:2 attempts:2\n' "$DOMAIN" "$DNS_SERVER" > /etc/resolv.conf
# /etc/hosts: API VIP (kubeadm's control-plane endpoint must resolve before BIND is up) + lab hosts
grep -q "api.${DOMAIN}" /etc/hosts || echo "${API_VIP} api.${DOMAIN}" >> /etc/hosts
for kv in ${NODE_HOSTS:-}; do
  h=${kv%%=*}; a=${kv#*=}
  grep -q "^${a} ${h}" /etc/hosts || echo "${a} ${h} ${h}.${DOMAIN}" >> /etc/hosts
done
log "$DATA_DEV ${NODE_IP}/${NODE_PREFIX:-24} mtu $MTU via $NODE_GW; dns $DNS_SERVER; api.${DOMAIN}=${API_VIP}"
