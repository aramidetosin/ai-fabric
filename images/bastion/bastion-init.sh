#!/bin/bash
# ai-fabric bastion PID 1: fabric bond, BIND9 lab zone (reference style), sshd, kubeconfig + CA pickup.
# Never exits (a PID-1 exit would strand the clab-wired interfaces).
set +e
trap '' TERM HUP
log() { echo "[bastion] $*"; }
: "${DOMAIN:?}" "${CLUSTER_NAME:?}" "${BASTION_IP:?}" "${BASTION_GW:?}" "${API_VIP:?}" "${GW_VIP:?}"
MTU=${NODE_MTU:-9000}
FABRIC_CIDR=${FABRIC_CIDR:-10.167.0.0/16}

# ---- fabric bond0 (eth1+eth2 -> the vPC pair), as the k8s nodes ----
log "waiting for fabric links eth1+eth2 ..."
for i in $(seq 1 240); do ip link show eth1 >/dev/null 2>&1 && ip link show eth2 >/dev/null 2>&1 && break; sleep 1; done
if ! ip link show bond0 >/dev/null 2>&1; then
  ip link add bond0 type bond mode 802.3ad lacp_rate fast miimon 100 xmit_hash_policy layer3+4
  [ -n "${NODE_MAC:-}" ] && ip link set bond0 address "$NODE_MAC"
  ip link set eth1 down; ip link set eth2 down
  ip link set eth1 master bond0; ip link set eth2 master bond0
  ip link set eth1 mtu "$MTU"; ip link set eth2 mtu "$MTU"; ip link set bond0 mtu "$MTU"
  ip link set eth1 up; ip link set eth2 up; ip link set bond0 up
fi
ip addr replace "${BASTION_IP}/${BASTION_PREFIX:-24}" dev bond0
ip route replace "$FABRIC_CIDR" via "$BASTION_GW" dev bond0
# internet via the fabric and the firewall; the management address keeps its own default (table 150) for the operators' path
# The management table is 150, not 200, everywhere in this lab: Cilium reserves table 200 for IPsec
# (linux_defaults.RouteTableIPSec) and flushes it on every agent start, which silently emptied the guests' table on
# 2026-09-21. Nothing here runs Cilium, but one number across all node types keeps the convention readable.
MGMT_TABLE=150
MGMT_IP=$(ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1 | head -1); MGMT_GW=$(ip -4 route show default dev eth0 | awk '{print $3}' | head -1)
if [ -n "$MGMT_IP" ] && [ -n "$MGMT_GW" ]; then
  ip route replace default via "$MGMT_GW" dev eth0 table "$MGMT_TABLE"; ip route replace "$(ip -4 -o route show dev eth0 proto kernel | awk '{print $1; exit}')" dev eth0 src "$MGMT_IP" table "$MGMT_TABLE" 2>/dev/null
  ip rule add from "$MGMT_IP" lookup "$MGMT_TABLE" 2>/dev/null; ip route del default via "$MGMT_GW" dev eth0 2>/dev/null
  while ip rule show | grep -q "from $MGMT_IP lookup 200"; do ip rule del from "$MGMT_IP" lookup 200 2>/dev/null || break; done
fi
ip route replace default via "$BASTION_GW" dev bond0
log "default via $BASTION_GW on bond0 (fabric -> firewall -> internet); management $MGMT_IP keeps eth0 (table $MGMT_TABLE)"

# ---- OOB / BMC NIC (eth3 -> the OOB switch), own routing table so replies leave via eth3 ----
if [ -n "${BASTION_OOB:-}" ]; then
  for i in $(seq 1 60); do ip link show eth3 >/dev/null 2>&1 && break; sleep 1; done
  if ip link show eth3 >/dev/null 2>&1; then
    ip link set eth3 up; ip addr replace "${BASTION_OOB}/${OOB_PREFIX:-27}" dev eth3
    ip rule add from "${BASTION_OOB}" lookup 100 2>/dev/null; ip route replace default via "${OOB_GW:-10.125.31.254}" dev eth3 table 100
    OOB_NET=$(ip -o -4 route show dev eth3 table main | awk '/proto kernel/ {print $1; exit}')   # BMC NIC is not an OS path to the OOB subnet
    [ -n "$OOB_NET" ] && { ip route del "$OOB_NET" dev eth3 table main 2>/dev/null; ip route replace "$OOB_NET" dev eth3 src "${BASTION_OOB}" table 100; }
    log "eth3 (BMC) ${BASTION_OOB}/${OOB_PREFIX:-27} via ${OOB_GW:-10.125.31.254}"
  fi
fi

# BASTION_NTP=0 / BASTION_DNS=0 (site-a-nx, operator decision 2026-09-23): DNS and NTP moved to the office server dns-b; the bastion keeps its
# other roles (kubectl/helm, ssh, the platform pass-through) and itself resolves + syncs through that server like any other client.
NTP_ON=${BASTION_NTP:-1}; DNS_ON=${BASTION_DNS:-1}
# ---- chrony: NTP for the platform hosts (fabric) and the switches (clab management network) ----
printf '%s\n' "pool pool.ntp.org iburst" "server 8.8.8.8 iburst" "driftfile /var/lib/chrony/chrony.drift" "makestep 1 3" "rtcsync" \
  "local stratum 10" "allow 10.0.0.0/8" "allow ${MGMT_CIDR:-172.21.21.0/24}" "allow 169.254.0.0/16" > /etc/chrony/chrony.conf
mkdir -p /var/lib/chrony /run/chrony; chown -R _chrony:_chrony /var/lib/chrony /run/chrony 2>/dev/null
# LLDP so the control leaves and the OOB switch see the bastion like any other lab node (config: /etc/lldpd.d/ai-fabric.conf).
mkdir -p /run/lldpd; lldpd 2>/dev/null && log "lldpd up (fabric + oob, management NIC excluded)" || log "lldpd not started"
if [ "$NTP_ON" = 1 ]; then chronyd -u _chrony 2>/dev/null && log "chronyd up (stratum 10 local, serving 10/8 and the clab management network)" || log "chronyd FAILED to start"
else log "NTP role off (BASTION_NTP=0): the lab's NTP server is ${NTP_SERVER:-?}"; fi

# ---- BIND9: authoritative for the lab zone, recursion + forwarders for the internet ----
# The zone files and named.conf live in bastion-dns.sh so the identical code can refresh DNS on a running bastion
# (docker cp + docker exec + rndc reload) without rebuilding the image or restarting PID 1.
if [ "$DNS_ON" = 1 ]; then . /usr/local/bin/bastion-dns.sh
  named-checkconf && named -u bind && log "named up: zone ${DOMAIN}, forwarders ${DNS_FORWARDERS:-8.8.8.8; 1.1.1.1;}" || log "named FAILED to start"
else log "DNS role off (BASTION_DNS=0): the lab zone ${DOMAIN} is served by ${DNS_SERVER:-?}"; fi

# the bastion resolves through its own BIND (lab names + forwarded internet)
if [ "${BASTION_DNS:-1}" = 1 ]; then printf 'search %s\nnameserver 127.0.0.1\nnameserver 8.8.8.8\n' "$DOMAIN" > /etc/resolv.conf
else printf 'search %s\nnameserver %s\nnameserver 8.8.8.8\n' "$DOMAIN" "${DNS_SERVER:?}" > /etc/resolv.conf; fi
grep -q "api.${DOMAIN}" /etc/hosts || echo "${API_VIP} api.${DOMAIN}" >> /etc/hosts
for kv in ${NODE_HOSTS:-} ${SWITCH_HOSTS:-}; do echo "${kv#*=} ${kv%%=*} ${kv%%=*}.${DOMAIN}" >> /etc/hosts; done

/usr/sbin/sshd && log "sshd up (root/admin logins from .env, operator keys)"
# TLS pass-through for workstations on the management network: TCP 443 on the management address goes unchanged to the
# Gateway address, so <app>.platform.<domain> resolved to this bastion reaches the Gateway with SNI and TLS intact
MGMT_IP=$(ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1)
if command -v socat >/dev/null 2>&1 && [ -n "$MGMT_IP" ]; then
  nohup socat "TCP-LISTEN:443,bind=${MGMT_IP},fork,reuseaddr" "TCP:${GW_VIP}:443" >/dev/null 2>&1 &
  log "gateway pass-through up: ${MGMT_IP}:443 -> ${GW_VIP}:443"
fi

# ---- kubeconfig + cluster CA: published by the init master into /shared/<cluster> ----
(
  S="/shared/${CLUSTER_NAME}"
  until [ -f "$S/ready" ]; do sleep 10; done
  D="/var/opt/ai-fabric/clusters/${CLUSTER_NAME}"; mkdir -p "$D"
  cp "$S/kubeconfig" "$D/kubeconfig.yaml"; chmod 644 "$D/kubeconfig.yaml"
  ln -sfn "$D" /var/opt/ai-fabric/clusters/current
  cp "$S/cluster-ca.crt" "/usr/local/share/ca-certificates/${CLUSTER_NAME}-cluster-ca.crt"
  update-ca-certificates >/dev/null 2>&1
  log "kubeconfig installed at $D/kubeconfig.yaml; cluster CA trusted"
) &

log "bastion ready: bond0 ${BASTION_IP} mtu ${MTU}; dns for ${DOMAIN} on $([ "$DNS_ON" = 1 ] && echo "${BASTION_IP}" || echo "${DNS_SERVER} (dns-b)")"
while true; do
  [ "$DNS_ON" = 1 ] && { pgrep -x named >/dev/null || named -u bind; }
  pgrep -x sshd  >/dev/null || /usr/sbin/sshd
  [ "$NTP_ON" = 1 ] && { pgrep -x chronyd >/dev/null || chronyd -u _chrony 2>/dev/null; }
  pgrep -f "TCP-LISTEN:443" >/dev/null || { command -v socat >/dev/null 2>&1 && nohup socat "TCP-LISTEN:443,bind=${MGMT_IP},fork,reuseaddr" "TCP:${GW_VIP}:443" >/dev/null 2>&1 & }
  sleep 30
done
