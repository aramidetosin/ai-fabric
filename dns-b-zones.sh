#!/bin/bash
# dns-b-zones.sh [profile]: publish the lab's DNS zones on the office DNS server dns-b (site-a-nx: DNS moved off the bastion, operator decision
# 2026-09-23, "you apply them, permission given"). Run it on the Mac: that is where the `dns-b` ssh alias lives. Idempotent.
#   zone files -> dns-b:/etc/bind/zones/ai-fabric/  (a directory of their own; dns-b's office.lab / 10.80.15 / 172.29.129 zones are not touched)
#   named.conf.ai-fabric -> dns-b:/etc/bind/  + ONE include line in named.conf.local (backed up the first time)
#   named-checkconf + named-checkzone BEFORE the reload; a failing check leaves the running server untouched
# Re-run after gen.py changes node names or addresses.
# The home lab uses the home server the same way (operator decision 2026-10-01):  DNS_B=dns-a KEEP=dns-a.home.lab ./dns-b-zones.sh site-b-nx
set -euo pipefail
cd "$(dirname "$0")"
PROFILE=${1:-site-a-nx}; HOST=${DNS_B:-dns-b}; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
AI_FABRIC_PROFILE=$PROFILE python3 gen.py --dns-zones "$T/z"
DOMAIN=$(AI_FABRIC_PROFILE=$PROFILE python3 -c 'import gen; print(gen.DOMAIN)')
scp -q -r "$T/z" "$HOST:/tmp/ai-fabric-zones"
# the remote part runs as root: on dns-a /etc/bind is not readable for the login user, so a glob over the new zone directory would not expand (2026-10-01)
ssh "$HOST" "sudo DOMAIN=$DOMAIN SRV=$HOST KEEP=${KEEP:-dns-b.office.lab} bash -s" <<'REMOTE'
set -euo pipefail
S=/tmp/ai-fabric-zones; Z=/etc/bind/zones/ai-fabric; C=/etc/bind/named.conf.ai-fabric; L=/etc/bind/named.conf.local
sudo mkdir -p "$Z.new"; sudo rm -f "$Z.new"/*; sudo cp "$S"/db.* "$Z.new/"
for f in "$Z.new"/db.*; do z=${f##*/db.}; sudo named-checkzone -q "$z" "$f" || { echo "zone $z FAILED named-checkzone"; exit 1; }; done
sudo cp "$S/named.conf.ai-fabric" "$C.new"
[ -f "$L.bak-ai-fabric" ] || sudo cp -p "$L" "$L.bak-ai-fabric"
sudo rm -rf "$Z.old"; [ -d "$Z" ] && sudo mv "$Z" "$Z.old"; sudo mv "$Z.new" "$Z"; sudo mv "$C.new" "$C"
grep -q 'include "/etc/bind/named.conf.ai-fabric";' "$L" || echo 'include "/etc/bind/named.conf.ai-fabric";   // ai-fabric lab zones (dns-b-zones.sh)' | sudo tee -a "$L" >/dev/null
sudo chown -R root:bind "$Z" "$C"; sudo chmod 644 "$Z"/* "$C"
if ! sudo named-checkconf; then   # restore the previous state; the running server has not been reloaded yet
  echo "named-checkconf FAILED -- restoring"; sudo rm -rf "$Z"; [ -d "$Z.old" ] && sudo mv "$Z.old" "$Z"; sudo cp -p "$L.bak-ai-fabric" "$L"; exit 1; fi
sudo rndc reload >/dev/null && sudo rm -rf "$Z.old" "$S"
echo "$SRV: $(ls "$Z" | wc -l) ai-fabric zones loaded"
for q in "api.$DOMAIN" "demo.platform.$DOMAIN" "bastion.$DOMAIN" "storage-mgmt.$DOMAIN" "gpu32.$DOMAIN"; do printf '  %-28s %s\n' "$q" "$(dig +short @127.0.0.1 "$q" | tr '\n' ' ')"; done
printf '  %-28s %s\n' "PTR 10.1.20.18" "$(dig +short @127.0.0.1 -x 10.1.20.18)"; printf '  %-28s %s\n' "$KEEP still" "$(dig +short @127.0.0.1 "$KEEP" | tr '\n' ' ')"
REMOTE
