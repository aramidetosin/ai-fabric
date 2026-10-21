#!/bin/sh
# PC client (network-multitool, Alpine): single-homed access port on its own leaf/VLAN, resolves through the
# bastion's BIND, trusts the cluster CA published by the init master, SSH via dropbear.
# Logins: admin / admin, root / <LAB_ROOT_PASSWORD>, plus the operator key from /pc-authorized_keys. Run by clab `exec`.
: "${PC_IP:?}" "${PC_GW:?}" "${DOMAIN:?}" "${DNS_SERVER:?}" "${CLUSTER_NAME:?}"
ip link set eth1 mtu "${NODE_MTU:-9000}"; ip link set eth1 up
ip addr replace "${PC_IP}/${PC_PREFIX:-24}" dev eth1
ip route replace "${FABRIC_CIDR:-10.167.0.0/16}" via "$PC_GW" dev eth1
# internet through the lab (PC-1 via the fabric and the firewall, PC-2 straight into the firewall); management keeps table 150
# Same idempotency trap as netsetup.sh on the VM guests: the last line of this block deletes eth0's default from the main
# table, so a RE-RUN reads nothing back and would skip the block, leaving the `from <mgmt ip> lookup <mgmt table>` rule pointing at an
# empty table -- replies to the management network (Weft's polls) would then leave via the client's own default instead. clab
# runs this once per deploy so it has not bitten here, unlike the guests, but the fallback chain costs nothing: eth0's default
# in main, then the one already in the management table, then MGMT_GW from the topology.
# The management table is 150, not 200, everywhere in this lab: Cilium reserves table 200 for IPsec
# (linux_defaults.RouteTableIPSec) and flushes it on every agent start, which silently emptied the guests' table on
# 2026-09-21. Nothing here runs Cilium, but one number across all node types keeps the convention readable.
MGMT_TABLE=150
MGMT_IP=$(ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1 | head -1)
_G=$(ip -4 route show default | awk '/dev eth0/ {print $3}' | head -1)
[ -n "$_G" ] || _G=$(ip -4 route show default dev eth0 table "$MGMT_TABLE" | awk '{print $3}' | head -1)
MGMT_GW=${_G:-${MGMT_GW:-}}
if [ -n "$MGMT_IP" ] && [ -n "$MGMT_GW" ]; then
  ip route replace default via "$MGMT_GW" dev eth0 table "$MGMT_TABLE"; ip rule add from "$MGMT_IP" lookup "$MGMT_TABLE" 2>/dev/null; ip route del default via "$MGMT_GW" dev eth0 2>/dev/null
  while ip rule show | grep -q "from $MGMT_IP lookup 200"; do ip rule del from "$MGMT_IP" lookup 200 2>/dev/null || break; done
fi
ip route replace default via "$PC_GW" dev eth1
printf 'search %s\nnameserver %s\n' "$DOMAIN" "$DNS_SERVER" > /etc/resolv.conf

# LLDP, so a client is visible to whatever it is cabled to exactly like the servers are. A PC is a plain container wired with a
# veth straight to its peer, so unlike the VM guests there is no bridge in the path and no group_fwd_mask to open. eth0 is the
# containerlab management network and is excluded. NOTE: pc-1/pc-2 are cabled only to the FIREWALL, and PAN-OS does not run LLDP
# unless it is enabled per interface -- until that is done these advertise but see no neighbour back.
command -v lldpd >/dev/null 2>&1 || apk add --no-cache lldpd >/dev/null 2>&1
mkdir -p /etc/lldpd.d
printf '%s\n' 'configure system interface pattern *,!eth0,!lo' 'configure lldp portidsubtype ifname' 'configure system description "ai-fabric client"' > /etc/lldpd.d/ai-fabric.conf
pgrep lldpd >/dev/null 2>&1 || lldpd 2>/dev/null
# accounts + ssh (dropbear is in the image; admin already exists)
echo "root:${LAB_ROOT_PASSWORD:-admin}" | chpasswd >/dev/null 2>&1
id admin >/dev/null 2>&1 || adduser -D -s /bin/bash admin
echo "admin:admin" | chpasswd >/dev/null 2>&1
for h in /root /home/admin; do
  mkdir -p "$h/.ssh"; [ -f /pc-authorized_keys ] && cp /pc-authorized_keys "$h/.ssh/authorized_keys"
  chmod 700 "$h/.ssh"; chmod 600 "$h/.ssh/authorized_keys" 2>/dev/null
done
chown -R admin:admin /home/admin/.ssh 2>/dev/null
mkdir -p /etc/dropbear; pgrep -x dropbear >/dev/null 2>&1 || dropbear -R -p 22 >/dev/null 2>&1
( until [ -f "/shared/${CLUSTER_NAME}/cluster-ca.crt" ]; do sleep 10; done
  mkdir -p /usr/local/share/ca-certificates
  cp "/shared/${CLUSTER_NAME}/cluster-ca.crt" "/usr/local/share/ca-certificates/${CLUSTER_NAME}-cluster-ca.crt"
  # the multitool image may ship without update-ca-certificates: append the CA to the bundle curl reads
  command -v update-ca-certificates >/dev/null 2>&1 && update-ca-certificates >/dev/null 2>&1
  # newer multitool images ship an update-ca-certificates that does not rebuild the bundle curl reads: make sure the CA really is in it
  grep -q "$(sed -n 2p "/shared/${CLUSTER_NAME}/cluster-ca.crt")" /etc/ssl/certs/ca-certificates.crt || cat "/shared/${CLUSTER_NAME}/cluster-ca.crt" >> /etc/ssl/certs/ca-certificates.crt
  echo "[pc] cluster CA trusted" ) > /var/log/pc-init.log 2>&1 &
echo "[pc] eth1 ${PC_IP}/24 mtu ${NODE_MTU:-9000} via ${PC_GW}; dns ${DNS_SERVER}; ssh admin/root (passwords from .env) + key"
