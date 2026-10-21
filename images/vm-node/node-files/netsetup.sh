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
  EXTRA=${NODE_SM_NICS:-1}; [ "$EXTRA" -ge 1 ] || EXTRA=1      # OOB NIC, or the storage management NICs FM1/FM2 (site-a-nx)
  for n in $(seq 1 $((N + EXTRA))); do
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
# a changed tag (site-a-nx moved the data VLAN 10 -> 100) leaves the old sub-interface holding the same address: drop every other bond0.<vlan>
for d in $(ip -o link show type vlan | awk -F': ' '{print $2}' | cut -d@ -f1); do
  case "$d" in bond0.*) [ "$d" = "$DATA_DEV" ] || { ip link del "$d"; log "removed stale $d (data VLAN is now ${NODE_VLAN:-untagged})"; };; esac
done
ip addr replace "${NODE_IP}/${NODE_PREFIX:-24}" dev "$DATA_DEV"
ip route replace "${FABRIC_CIDR:-10.167.0.0/16}" via "$NODE_GW" dev "$DATA_DEV"
# Internet egress goes through the fabric: anycast gateway -> border leaves -> firewall (NAT on its external interface), as the
# Operator design. The management NIC (eth0, clab management network) keeps a default of its own in table $MGMT_TABLE for traffic sourced
# from the management address only (operator SSH, the bastion pass-through), so replies never leave via the fabric.
# This block has to be idempotent. Its own last line deletes eth0's default from the main table, so a RE-RUN (node-sync applying
# network files live, finish.sh stage 3) reads nothing back there: it used to wait the full 90 s for a route it had itself removed
# and then skip the block with an empty gateway. If anything had flushed table 200 in the meantime -- a systemd-networkd
# reconfiguration of eth0 takes its routes down with it -- the table was never rebuilt. That is exactly what happened on
# 2026-09-20: every guest kept the `from <mgmt ip> lookup 200` rule with an EMPTY table behind it, so replies to the management
# network (Weft's SSH and SNMP polls) went out of the fabric default instead and every node but the bastion showed DOWN.
# 2026-09-21, the case the above did NOT cover: a COLD BOOT. eth0 is configured statically from the clab mgmt-ipv4 and
# never gets a default route of its own, so "wait for eth0's default" waits 90 s for something that never appears, and on a
# fresh boot table 200 is empty too. MGMT_GW from node.env only exists on guests whose disk was created after it was added
# to gen.py, so an existing disk has none of the three. Result: table 200 stayed empty after every reboot and Weft could not
# reach any server. The last source below always works: the containerlab management bridge takes the FIRST address of the
# management subnet (verified: `docker network inspect ai-fabric-mgmt` -> Gateway 172.21.21.1), which is also what gen.py
# emits as MGMT_GW, so the computed value and the topology value are the same number by construction.
# 2026-09-21, the ACTUAL root cause, found with `ip monitor route` across two reboots and confirmed causally by restarting the
# agent: Cilium reserves route table 200 for IPsec (linux_defaults.RouteTableIPSec) and FLUSHES it every time the agent starts --
# at boot, on pod restart, on upgrade. A probe route placed in tables 150/200/201/202 before a Cilium restart survived in 150,
# 201 and 202 and was deleted ONLY from 200, so this is a table-NUMBER COLLISION, not a general route flush and not a boot race.
# netsetup runs Before=kubelet, so a one-shot at boot can never win: Cilium starts afterwards and wipes the table every time.
# The management table therefore moves to 150, which no component of this lab reserves (our own OOB table is 100, the rails are
# 300-307, Cilium uses 200/201/202 and 2004/2005). The stale `lookup 200` rule from older disks is removed below, otherwise it
# would sit in front of the new rule pointing at a table Cilium keeps empty.
MGMT_TABLE=150
# Four sources for the gateway, in order: node.env / eth0's default in main / the one already in the table / computed from eth0's subnet.
MGMT_IP=$(ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1 | head -1)
for i in $(seq 1 20); do [ -n "$MGMT_IP" ] && break; sleep 1; MGMT_IP=$(ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1 | head -1); done
_G=${MGMT_GW:-}
[ -n "$_G" ] || _G=$(ip -4 route show default dev eth0 | awk '{print $3}' | head -1)
[ -n "$_G" ] || _G=$(ip -4 route show default dev eth0 table "$MGMT_TABLE" | awk '{print $3}' | head -1)
[ -n "$_G" ] || _G=$(printf '%s' "$MGMT_IP" | awk -F. 'NF==4 {print $1"."$2"."$3".1"}')
MGMT_GW=$_G
if [ -n "$MGMT_IP" ] && [ -n "$MGMT_GW" ]; then
  ip route replace default via "$MGMT_GW" dev eth0 table "$MGMT_TABLE"; ip route replace "$(ip -4 -o route show dev eth0 proto kernel | awk '{print $1; exit}')" dev eth0 src "$MGMT_IP" table "$MGMT_TABLE" 2>/dev/null
  ip rule show | grep -q "from $MGMT_IP lookup $MGMT_TABLE" || ip rule add from "$MGMT_IP" lookup "$MGMT_TABLE"
  while ip rule show | grep -q "from $MGMT_IP lookup 200"; do ip rule del from "$MGMT_IP" lookup 200 2>/dev/null || break; done
  ip route del default via "$MGMT_GW" dev eth0 2>/dev/null
fi
ip route replace default via "$NODE_GW" dev "$DATA_DEV"
log "default route via $NODE_GW on $DATA_DEV (fabric -> firewall); management ${MGMT_IP:-?} keeps eth0 via ${MGMT_GW:-?} in table $MGMT_TABLE"
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
# Storage management (site-a-nx, VLAN 200): FlashBlade-style FM1 = eth(N+1) on the first control leaf, FM2 = eth(N+2) on the second, no bond.
# Each FM answers from its own table (101 / 102) through its own link; the management VIP (the API address) is floated between them by fb-vip.sh,
# table 100 follows it. No connected route in main: node traffic to 10.1.20.x must cross the firewall like everyone else's. The storage node used
# to have an OOB NIC in this slot: its address, rule and table 100 routes are removed here (existing disks).
if [ -n "${NODE_SM_FM1:-}" ]; then
  SMPFX=${NODE_SM_PREFIX:-24}; SMNET=$(python3 -c 'import ipaddress, sys; print(ipaddress.ip_interface(sys.argv[1]).network)' "$NODE_SM_GW/$SMPFX")
  for r in $(ip rule show | awk '/lookup 100$/ {print $3}'); do [ "$r" = "$NODE_SM_VIP" ] || { ip rule del from "$r" lookup 100 2>/dev/null; log "removed stale rule from $r lookup 100"; }; done
  ip route show table 100 | grep -v "$SMNET\|via $NODE_SM_GW" | while read -r rt; do ip route del $rt table 100 2>/dev/null; done
  k=1; for fm in "$NODE_SM_FM1" "$NODE_SM_FM2"; do
    dev="eth$((N + k))"; tb=$((100 + k))
    ip link show "$dev" >/dev/null 2>&1 || { log "$dev (storage management FM$k) missing"; k=$((k + 1)); continue; }
    ip link set "$dev" mtu 1500 up
    sysctl -qw "net.ipv4.conf.$dev.arp_ignore=1" "net.ipv4.conf.$dev.arp_announce=2" "net.ipv4.conf.$dev.rp_filter=0"
    for a in $(ip -4 -o addr show dev "$dev" | awk '{print $4}'); do case "$a" in "$fm/$SMPFX"|"$NODE_SM_VIP/$SMPFX") ;; *) ip addr del "$a" dev "$dev"; log "removed stale $a from $dev";; esac; done
    ip addr replace "$fm/$SMPFX" dev "$dev" noprefixroute
    ip route replace "$SMNET" dev "$dev" src "$fm" table "$tb"; ip route replace default via "$NODE_SM_GW" dev "$dev" table "$tb"
    ip rule show | grep -q "from $fm lookup $tb" || ip rule add from "$fm" lookup "$tb"
    k=$((k + 1))
  done
  ip rule show | grep -q "from $NODE_SM_VIP lookup 100" || ip rule add from "$NODE_SM_VIP" lookup 100
  if ! ip -4 -o addr show | grep -q " $NODE_SM_VIP/"; then        # first placement on FM1; fb-vip.sh moves it when FM1 loses the gateway
    ip addr replace "$NODE_SM_VIP/$SMPFX" dev "eth$((N + 1))" noprefixroute
    ip route replace "$SMNET" dev "eth$((N + 1))" src "$NODE_SM_VIP" table 100; ip route replace default via "$NODE_SM_GW" dev "eth$((N + 1))" table 100
  fi
  log "storage management: FM1 $NODE_SM_FM1 eth$((N + 1)), FM2 $NODE_SM_FM2 eth$((N + 2)), VIP $NODE_SM_VIP via $NODE_SM_GW (tables 101/102/100)"
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
# NTP: timesyncd follows node.env (cloud-init wrote this file once; site-a-nx moved NTP from the bastion to the office server dns-b)
TS=/etc/systemd/timesyncd.conf.d/ai-fabric.conf; TSW=$(printf '[Time]\nNTP=%s\nFallbackNTP=8.8.8.8' "${NTP_SERVER:-8.8.8.8}")
if [ "$(cat "$TS" 2>/dev/null)" != "$TSW" ]; then mkdir -p "${TS%/*}"; printf '%s\n' "$TSW" > "$TS"; systemctl restart systemd-timesyncd 2>/dev/null; log "timesyncd: NTP ${NTP_SERVER:-8.8.8.8}"; fi
# DNS: the lab's DNS server first (the bastion's BIND, or dns-b on site-a-nx: both serve the lab zone and resolve the internet), public fallback
[ -L /etc/resolv.conf ] && rm -f /etc/resolv.conf
printf 'search %s\nnameserver %s\nnameserver 8.8.8.8\noptions timeout:2 attempts:2\n' "$DOMAIN" "$DNS_SERVER" > /etc/resolv.conf
# /etc/hosts: API VIP (kubeadm's control-plane endpoint must resolve before BIND is up) + lab hosts
grep -q "api.${DOMAIN}" /etc/hosts || echo "${API_VIP} api.${DOMAIN}" >> /etc/hosts
for kv in ${NODE_HOSTS:-}; do
  h=${kv%%=*}; a=${kv#*=}
  # a host that moved (site-a-nx: bastion 10.1.1.17 -> 10.1.30.17) must not keep its old line first
  awk -v h="$h" -v d="$h.$DOMAIN" -v a="$a" '!($2 == h && $3 == d && $1 != a)' /etc/hosts > /etc/hosts.new && cat /etc/hosts.new > /etc/hosts && rm -f /etc/hosts.new
  grep -q "^${a} ${h}" /etc/hosts || echo "${a} ${h} ${h}.${DOMAIN}" >> /etc/hosts
done
# sshd as a plain always-listening service, never socket-activated. Ubuntu 24.04 ships ssh.socket enabled: sshd is then started
# on the first connection, and during that socket -> service handover nothing holds port 22, so a connection is REFUSED. Every
# helper in this repository reaches the guests over ssh, so that window turns into random "UNREACHABLE" failures -- it broke the
# persistence check of an otherwise clean acceptance run on 2026-09-20 (gpu27, "connect to host ... port 22: Connection refused").
if [ "$(systemctl is-enabled ssh.socket 2>/dev/null)" = enabled ]; then
  systemctl disable --now ssh.socket >/dev/null 2>&1
  systemctl enable ssh.service >/dev/null 2>&1
  systemctl is-active ssh.service >/dev/null 2>&1 || systemctl start ssh.service >/dev/null 2>&1
  log "sshd: socket activation off, ssh.service always listening"
fi
# self-heal (2026-09-23: 17 of 39 fresh guests). The switch above can leave the socket-started sshd running OUTSIDE the unit (systemd: "Unit process
# ... remains running after unit stopped"). That orphan keeps port 22, ssh.service then fails to bind, and systemd deletes /run/sshd with the failed
# unit -- so every connection reaches the orphan, whose children die on "Missing privilege separation directory: /run/sshd" (clients: "Connection
# reset by peer"; node-sync: UNREACHABLE). Whenever ssh.service is not active or port 22 is held by anything but its main process: stop that listener
# (no session can exist then) and start the service properly, which recreates /run/sshd. Checked on every run, so node-sync and every boot repair it.
ssh_listener() { ss -ltnpH 'sport = :22' 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u; }
if ! systemctl is-active ssh.service >/dev/null 2>&1 || [ "$(ssh_listener | head -1)" != "$(systemctl show -p MainPID --value ssh.service)" ]; then
  systemctl stop ssh.service >/dev/null 2>&1; for p in $(ssh_listener); do kill "$p" 2>/dev/null; done; sleep 1
  systemctl reset-failed ssh.service >/dev/null 2>&1; systemctl start ssh.service >/dev/null 2>&1
  log "sshd: ssh.service was not serving port 22 (orphaned listener) -> restarted: $(systemctl is-active ssh.service), /run/sshd $([ -d /run/sshd ] && echo present || echo MISSING)"
fi

# SoftRoCE on the rails (NVIDIA network-operator lab, site-a-nx, operator decisions 2026-09-24). The rdma-shared-dev-plugin serves the RDMA devices
# of the rail NICs; the virtio rails have none, so each gpuN gets a SoftRoCE device rxe_gpuN (rdma_rxe lives in linux-modules-extra, which rdma-prep.sh
# installs). mlx5_core is loaded as well, with no hardware to bind: the plugin's init container waits for it (lsmod | grep mlx5_core), exactly as it
# waits for the DOCA/OFED driver in production. Every run re-checks, so a boot or node-sync restores both.
# Keyed on rdma_rxe being installed (only rdma-prep.sh installs it, only for this profile), not on node.env alone: a container created before
# the flag existed keeps its old environment, and node-sync mirrors that.
if [ "${RAIL_NICS:-0}" -gt 0 ] 2>/dev/null && { [ "${RAIL_NADS:-}" = operator ] || modinfo rdma_rxe >/dev/null 2>&1; }; then
  modprobe mlx5_core 2>/dev/null
  # ib_uverbs + rdma_ucm: the character devices /dev/infiniband/uverbsN and rdma_cm. rdma-shared-dev-plugin refuses a device without rdma_cm
  # ("RDMA device rdma_cm not found", 2026-09-24); in production the DOCA/OFED driver loads both, the in-box stack only on demand.
  if modprobe rdma_rxe 2>/dev/null && modprobe ib_uverbs 2>/dev/null && modprobe rdma_ucm 2>/dev/null; then n=0; h=
    for r in $(seq 0 $((RAIL_NICS - 1))); do
      # a device whose GSI QP (QP1, the RDMA CM / MAD path) is in ERR never sends a CM message again: RDMA CM from a pod network namespace does
      # that on kernels before 7.1 (rdma_rxe is init_net-only there; seen 2026-09-24). Only re-creating the device clears it.
      rdma res show qp link "rxe_gpu$r/1" 2>/dev/null | grep -q "type GSI state ERR" && { rdma link delete "rxe_gpu$r" 2>/dev/null; h="$h rxe_gpu$r"; }
      rdma link show "rxe_gpu$r/1" >/dev/null 2>&1 || rdma link add "rxe_gpu$r" type rxe netdev "gpu$r" 2>/dev/null
      rdma link show "rxe_gpu$r/1" >/dev/null 2>&1 && n=$((n + 1)); done
    log "SoftRoCE: $n/$RAIL_NICS rxe devices on the rail NICs${h:+ (re-created, QP1 was in ERR:$h)}, rdma_cm $([ -e /dev/infiniband/rdma_cm ] && echo present || echo MISSING), mlx5_core $(lsmod | grep -q '^mlx5_core' && echo loaded || echo MISSING)"
  else log "SoftRoCE: rdma_rxe not available -- linux-modules-extra-$(uname -r) missing (rdma-prep.sh installs it)"; fi
fi

log "$DATA_DEV ${NODE_IP}/${NODE_PREFIX:-24} mtu $MTU via $NODE_GW; dns $DNS_SERVER; api.${DOMAIN}=${API_VIP}"
