#!/bin/bash
# host/weft-alias-install.sh -- OPERATOR STEP on site-b (host NAT + Tailscale routing are yours to change, the script only does what is listed):
#   1. installs /etc/nftables.d/ai-fabric-weft-alias.nft + weft-alias-nat.service (reboot-persistent, own nft table `ai_fabric_alias`)
#   2. adds 172.21.121.0/24 to the routes this host ADVERTISES over Tailscale, keeping the ones it already advertises
# Afterwards approve the new route for this machine in the Tailscale admin console (Machines > site-b > Edit route settings).
# Undo: systemctl disable --now weft-alias-nat.service; rm /etc/systemd/system/weft-alias-nat.service /etc/nftables.d/ai-fabric-weft-alias.nft;
#       tailscale set --advertise-routes=<the previous list printed below>
set -euo pipefail
cd "$(dirname "$0")"; ALIAS=172.21.121.0/24
install -D -m 644 weft-alias.nft /etc/nftables.d/ai-fabric-weft-alias.nft
install -m 644 weft-alias-nat.service /etc/systemd/system/weft-alias-nat.service
systemctl daemon-reload; systemctl enable weft-alias-nat.service >/dev/null 2>&1; systemctl restart weft-alias-nat.service
nft list table ip ai_fabric_alias | sed 's/^/  /'
cur=$(tailscale debug prefs | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin).get("AdvertiseRoutes") or []))')
echo "routes advertised before: ${cur:-none}"
case ",$cur," in *",$ALIAS,"*) echo "already advertising $ALIAS";; *) tailscale set --advertise-routes="${cur:+$cur,}$ALIAS"; echo "now advertising: ${cur:+$cur,}$ALIAS";; esac
echo; echo "NEXT: approve $ALIAS for site-b in the Tailscale admin console, then re-run the validation."
