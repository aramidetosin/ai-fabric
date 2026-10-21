#!/bin/bash
# dns-refresh.sh: rewrite the bastion's BIND configuration and zone files on the RUNNING lab, then reload named.
# Same code the bastion runs at boot (images/bastion/bastion-dns.sh), so this and a redeploy produce identical DNS.
#
# Use it after changing the reverse-DNS inputs in gen.py (extra_ptrs(), the profile's lan_ptrs / lan_cidr) when you do not
# want to rebuild the bastion image. A redeploy picks the same content up on its own.
#   ./dns-refresh.sh          rewrite + reload
#   ./dns-refresh.sh check    show what the bastion answers now, change nothing
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh
B=$LAB-bastion
docker inspect "$B" >/dev/null 2>&1 || { echo "no bastion container ($B)" >&2; exit 1; }

if [ "${1:-}" = check ]; then
  echo "zones the bastion is authoritative for:"; docker exec "$B" awk '/^zone/ {print "  " $2}' /etc/bind/named.conf.local
  echo "listen-on / allow-query:"; docker exec "$B" grep -E "listen-on \{|allow-query" /etc/bind/named.conf.options | sed 's/^/  /'
  exit 0
fi

PTRS=$(python3 -c "import gen; print(gen.extra_ptrs())")
CIDRS=$(python3 -c "import gen; print(gen.PF.get('lan_cidr', ''))")

docker cp images/bastion/bastion-dns.sh "$B":/usr/local/bin/bastion-dns.sh >/dev/null
docker exec "$B" chmod +x /usr/local/bin/bastion-dns.sh
docker exec -e EXTRA_PTRS="$PTRS" -e EXTRA_QUERY_CIDRS="$CIDRS" "$B" bash -c '
  /usr/local/bin/bastion-dns.sh
  named-checkconf || { echo "named-checkconf FAILED -- named left running on the previous configuration" >&2; exit 1; }
  rndc reload >/dev/null 2>&1 || { pkill named; sleep 1; named -u bind; }
  echo "reloaded"'
echo "zones now served:"; docker exec "$B" awk '/^zone/ {print "  " $2}' /etc/bind/named.conf.local
