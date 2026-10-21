#!/bin/sh
# fb-vip.sh: the storage management VIP of a FlashBlade-style pair of management ports (site-a-nx, operator decision 2026-09-23: two links, one per
# control leaf, NOT bonded). FM1 = eth(N+1) on the first leaf, FM2 = eth(N+2) on the second, each with its own address and routing table (netsetup.sh).
# Every 2 s: the VIP belongs on FM1 while FM1 reaches the VLAN 200 gateway, else on FM2 while FM2 does. On a move: re-point table 100 (replies from the
# VIP) and send a gratuitous ARP so the leaves re-learn the VIP behind the other link. Exits quietly where there is no VIP (other profiles).
# Every 30 s the owner announces the VIP again (gratuitous ARP, as a VRRP master refreshes it): the VIP sends nothing by itself, and the announcement made at
# guest boot is lost when the fabric comes up after the guest (site-a 2026-10-04: the firewall could not resolve the VIP until the node spoke from it).
. /etc/ai-fabric/node.env
[ -n "${NODE_SM_VIP:-}" ] || exit 0
N=${FABRIC_NICS:-2}; P="eth$((N + 1))"; B="eth$((N + 2))"; VIP=$NODE_SM_VIP; GW=$NODE_SM_GW; PFX=${NODE_SM_PREFIX:-24}
NET=$(python3 -c 'import ipaddress, sys; print(ipaddress.ip_interface(sys.argv[1]).network)' "$GW/$PFX")
reach() { ping -c 1 -W 1 -I "$1" "$GW" >/dev/null 2>&1; }       # $1 = FM address: source routing sends it out of its own NIC
garp() { python3 - "$1" "$2" <<'PY'
import socket, struct, sys
dev, ip = sys.argv[1], sys.argv[2]
mac = bytes.fromhex(open(f"/sys/class/net/{dev}/address").read().strip().replace(":", "")); a = socket.inet_aton(ip)
s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW); s.bind((dev, 0))
for _ in range(3): s.send(b"\xff" * 6 + mac + b"\x08\x06" + struct.pack("!HHBBH6s4s6s4s", 1, 0x0800, 6, 4, 1, mac, a, b"\x00" * 6, a))
PY
}
tick=0
while true; do
  if reach "$NODE_SM_FM1"; then want=$P; elif reach "$NODE_SM_FM2"; then want=$B; else want=""; fi
  have=$(ip -4 -o addr show | awk -v v="$VIP/" 'index($4, v) == 1 {print $2; exit}')
  if [ -n "$want" ] && [ "$want" != "$have" ]; then
    [ -n "$have" ] && ip addr del "$VIP/$PFX" dev "$have"
    ip addr replace "$VIP/$PFX" dev "$want" noprefixroute
    ip route replace "$NET" dev "$want" src "$VIP" table 100; ip route replace default via "$GW" dev "$want" table 100
    garp "$want" "$VIP"; logger -t fb-vip "management VIP $VIP now on $want ($([ "$want" = "$P" ] && echo FM1 || echo FM2)); was on ${have:-nothing}"
  fi
  tick=$((tick + 1)); [ $((tick % 15)) = 0 ] && [ -n "$want" ] && garp "$want" "$VIP"
  sleep 2
done
