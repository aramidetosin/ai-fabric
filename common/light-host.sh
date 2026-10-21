#!/bin/sh
# Lightweight stand-in for a ai-fabric VM node (gen.py --light): same cabling and the same NIC layout as images/vm-node/netsetup.sh,
# without the guest or Kubernetes. eth1..N = 802.3ad bond0 (tagged bond0.<vlan> on the storage node), eth(N+1) = OOB/BMC,
# eth(N+2).. = GPU rails gpu0.. addressed <RAIL_PREFIX>.R.<idx>/24 and source-routed through the rail gateway.
: "${NODE_IP:?}" "${NODE_GW:?}"
MTU=${NODE_MTU:-9000}; N=${FABRIC_NICS:-2}; RN=${RAIL_NICS:-0}; RB=$((N + 2)); OOBDEV="eth$((N + 1))"
for i in $(seq 1 120); do ip link show "eth$N" >/dev/null 2>&1 && break; sleep 1; done
if ! ip link show bond0 >/dev/null 2>&1; then
  ip link add bond0 type bond mode 802.3ad lacp_rate fast miimon 100 xmit_hash_policy layer3+4
  [ -n "${NODE_MAC:-}" ] && ip link set bond0 address "$NODE_MAC"
  for k in $(seq 1 "$N"); do ip link set "eth$k" down; ip link set "eth$k" master bond0; ip link set "eth$k" mtu "$MTU"; done
  ip link set bond0 mtu "$MTU"; for k in $(seq 1 "$N"); do ip link set "eth$k" up; done; ip link set bond0 up
fi
DEV=bond0
if [ -n "${NODE_VLAN:-}" ]; then
  DEV="bond0.${NODE_VLAN}"; ip link show "$DEV" >/dev/null 2>&1 || ip link add link bond0 name "$DEV" type vlan id "$NODE_VLAN"
  ip link set "$DEV" mtu "$MTU"; ip link set "$DEV" up
fi
ip addr replace "${NODE_IP}/${NODE_PREFIX:-24}" dev "$DEV"
# The management table is 150, not 200, everywhere in this lab: Cilium reserves table 200 for IPsec
# (linux_defaults.RouteTableIPSec) and flushes it on every agent start, which silently emptied the guests' table on
# 2026-09-21. Nothing here runs Cilium, but one number across all node types keeps the convention readable.
MGMT_TABLE=150
MGMT_IP=$(ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1 | head -1); MGMT_GW=$(ip -4 route show default dev eth0 | awk '{print $3}' | head -1)
if [ -n "$MGMT_IP" ] && [ -n "$MGMT_GW" ]; then     # management keeps its own table; the default route goes through the fabric and the firewall (as the VM nodes)
  ip route replace default via "$MGMT_GW" dev eth0 table "$MGMT_TABLE"; ip rule add from "$MGMT_IP" lookup "$MGMT_TABLE" 2>/dev/null; ip route del default via "$MGMT_GW" dev eth0 2>/dev/null
  while ip rule show | grep -q "from $MGMT_IP lookup 200"; do ip rule del from "$MGMT_IP" lookup 200 2>/dev/null || break; done
fi
ip route replace default via "$NODE_GW" dev "$DEV"
if [ -n "${OOB_IP:-}" ] && ip link show "$OOBDEV" >/dev/null 2>&1; then
  ip link set "$OOBDEV" up; ip addr replace "${OOB_IP}/${OOB_PREFIX:-24}" dev "$OOBDEV"
  ip rule add from "${OOB_IP}" lookup 100 2>/dev/null; ip route replace default via "$OOB_GW" dev "$OOBDEV" table 100
  NET=$(ip -o -4 route show dev "$OOBDEV" table main | awk '/proto kernel/ {print $1; exit}')
  [ -n "$NET" ] && { ip route del "$NET" dev "$OOBDEV" table main 2>/dev/null; ip route replace "$NET" dev "$OOBDEV" src "$OOB_IP" table 100; }
fi
if [ "$RN" -gt 0 ] && [ -n "${NODE_RAIL_INDEX:-}" ]; then
  for r in $(seq 0 $((RN - 1))); do
    ip link show "gpu$r" >/dev/null 2>&1 || { ip link set "eth$((RB + r))" down; ip link set "eth$((RB + r))" name "gpu$r"; }
    ip link set "gpu$r" mtu "$MTU" up
    RIP="${RAIL_PREFIX}.$((r + 1)).${NODE_RAIL_INDEX}"; T=$((300 + r)); GW="${RAIL_PREFIX}.$((r + 1)).1"
    ip addr replace "$RIP/24" dev "gpu$r"
    ip route replace "${RAIL_PREFIX}.$((r + 1)).0/24" dev "gpu$r" src "$RIP" table "$T"; ip route replace default via "$GW" dev "gpu$r" table "$T"
    ip rule add from "$RIP" lookup "$T" 2>/dev/null
    echo 0 > "/proc/sys/net/ipv4/conf/gpu$r/rp_filter"; echo 1 > "/proc/sys/net/ipv4/conf/gpu$r/arp_ignore"; echo 2 > "/proc/sys/net/ipv4/conf/gpu$r/arp_announce"
  done
fi
# storage management (site-a-nx, VLAN 200): FM1 = eth(N+1), FM2 = eth(N+2), each answering from its own table; the VIP sits on FM1 (the full lab's
# fb-vip.sh floats it). A socat listener on VIP:443 stands in for the management API, so the light lab can test VLAN 100 -> firewall -> VLAN 200.
if [ -n "${NODE_SM_FM1:-}" ]; then
  SMPFX=${NODE_SM_PREFIX:-24}; SMNET=$(python3 -c 'import ipaddress, sys; print(ipaddress.ip_interface(sys.argv[1]).network)' "$NODE_SM_GW/$SMPFX"); k=1
  for fm in "$NODE_SM_FM1" "$NODE_SM_FM2"; do dev="eth$((N + k))"; tb=$((100 + k))
    for i in $(seq 1 60); do ip link show "$dev" >/dev/null 2>&1 && break; sleep 1; done
    ip link set "$dev" up; echo 1 > "/proc/sys/net/ipv4/conf/$dev/arp_ignore"; echo 2 > "/proc/sys/net/ipv4/conf/$dev/arp_announce"; echo 0 > "/proc/sys/net/ipv4/conf/$dev/rp_filter"
    ip addr replace "$fm/$SMPFX" dev "$dev" noprefixroute
    ip route replace "$SMNET" dev "$dev" src "$fm" table "$tb"; ip route replace default via "$NODE_SM_GW" dev "$dev" table "$tb"; ip rule add from "$fm" lookup "$tb" 2>/dev/null
    k=$((k + 1)); done
  ip addr replace "$NODE_SM_VIP/$SMPFX" dev "eth$((N + 1))" noprefixroute
  ip route replace "$SMNET" dev "eth$((N + 1))" src "$NODE_SM_VIP" table 100; ip route replace default via "$NODE_SM_GW" dev "eth$((N + 1))" table 100
  ip rule add from "$NODE_SM_VIP" lookup 100 2>/dev/null
  pgrep -f "TCP-LISTEN:443,bind=$NODE_SM_VIP" >/dev/null || nohup socat "TCP-LISTEN:443,bind=$NODE_SM_VIP,fork,reuseaddr" SYSTEM:"echo ai-fabric-storage-mgmt" >/dev/null 2>&1 &
fi
sysctl -qw net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1
echo "[light-host] $DEV ${NODE_IP}/${NODE_PREFIX:-24} via $NODE_GW; oob ${OOB_IP:-none}; rails $RN; storage mgmt ${NODE_SM_VIP:-none}"
