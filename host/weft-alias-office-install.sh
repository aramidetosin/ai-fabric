#!/bin/bash
# OPERATOR STEP on site-a: installs /etc/nftables.d/weft-alias-office.nft + weft-alias-office.service (reboot-persistent, own nft table
# `weft_alias`, one masquerade rule for 172.29.129.0/24 -> 172.21.121.0/24 out of tailscale0). Nothing else on the host is changed.
# Undo: systemctl disable --now weft-alias-office.service; rm /etc/systemd/system/weft-alias-office.service /etc/nftables.d/weft-alias-office.nft
set -euo pipefail
cd "$(dirname "$0")"
install -D -m 644 weft-alias-office.nft /etc/nftables.d/weft-alias-office.nft
install -m 644 weft-alias-office.service /etc/systemd/system/weft-alias-office.service
systemctl daemon-reload; systemctl enable weft-alias-office.service >/dev/null 2>&1; systemctl restart weft-alias-office.service
nft list table ip weft_alias | sed 's/^/  /'
