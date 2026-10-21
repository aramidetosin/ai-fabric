#!/bin/bash
# publish.sh: build the workstation kit for ai-fabric from the LIVE lab. Office-LAN workstations (ubuntu-desktop, winserver-rev3; both have
# an interface in 10.80.15.0/24 = the firewall's "internet" zone) reach the platform THROUGH THE FIREWALL, the convention of the
# sibling labs already present on those machines:
#   route   <node subnet> via <firewall outside address>            (firewall rule internet-to-inside-vips: tcp 80,443,6443)
#   DNS     the lab's bastion BIND as the first DNS server           (rule internet-to-bastion-dns; BIND forwards everything else upstream)
#   trust   the lab's cluster CA in the system store (+ browser NSS stores on Linux)
# A client without the route can use the DNAT instead: https://<name>/ resolved to the firewall outside address (dnat-gateway-vip).
# The kit holds only public material. Re-run after every `./down.sh wipe` redeploy: the CA changes.
#   ./publish.sh   -> writes publish/ ; copy it to the workstation and run the script THERE as its administrator.
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh
P=publish; rm -rf "$P"; mkdir -p "$P"; CA=shared/ai-fabric/cluster-ca.crt
[ -s "$CA" ] || { echo "no $CA yet (cluster not bootstrapped)"; exit 1; }
read -r DNS NET FWOUT DOMAIN <<< "$(python3 -c "import gen; print(gen.DNS_NTP or gen.BASTION_IP, gen.FE_NET, gen.FW['e5'].split('/')[0], gen.DOMAIN)")"; VIP=$(gw_vip)   # site-a-nx: dns-b serves lab.ai
NAMES=$(K "kubectl get httproute -A -o jsonpath='{range .items[*]}{.spec.hostnames[0]} {end}'" | tr ' ' '\n' | grep . | sort -u)
[ -n "$NAMES" ] || { echo "no HTTPRoute hostnames found"; exit 1; }
cp "$CA" "$P/ai-fabric-cluster-ca.crt"
for n in $NAMES; do echo "https://$n/"; done > "$P/urls.txt"
# LANPFX follows the firewall's outside address instead of being written out, so the kit is right on any profile.
printf 'DNS=%s\nNET=%s\nFWOUT=%s\nVIP=%s\nDOMAIN=%s\nLANPFX=%s.\n' "$DNS" "$NET" "$FWOUT" "$VIP" "$DOMAIN" "${FWOUT%.*}" > "$P/lab.env"
# A hosts block is all a client needs when it cannot take the route + DNS setup, or sits off the LAN entirely (the Mac reaches
# this address over a Tailscale /32): every name points at the firewall's outside address and dnat-gateway-vip forwards 443 to
# the Gateway VIP. Regenerated here because a redeploy can change both the names and the address.
# + the API VIP by name (operator 2026-09-23): office clients keep their own DNS servers, and the office LAN may reach the API on tcp/6443
# through the firewall (rule internet-to-inside-vips) over the route to the node subnet.
API=$(python3 -c 'import gen; print(gen.API_VIP)')
# + the firewall UI by the name on its lab CA certificate (operator 2026-09-23; site-a-nx only)
FWN=$(python3 -c 'import gen; print(gen.FW["mgmt"] + " fw-mgmt." + gen.DOMAIN if gen.LAB_CA else "")')
{ echo '# BEGIN ai-fabric'; echo "$FWOUT $(echo $NAMES | tr '\n' ' ' | sed 's/ *$//')"; echo "$API api.$DOMAIN"; [ -n "$FWN" ] && echo "$FWN"; echo '# END ai-fabric'; } > "$P/hosts-block.txt"

cat > "$P/ubuntu-desktop.sh" <<'EOS'
#!/bin/bash
# ai-fabric workstation setup (Ubuntu + NetworkManager). Run ON the workstation:   sudo bash ~/ai-fabric-publish/ubuntu-desktop.sh
# Idempotent. Adds a persistent route to the lab's node subnet via the lab firewall, puts the lab's bastion BIND first in the DNS
# server list (existing servers are kept after it), trusts the lab CA (system store + the user's NSS databases). Nothing is removed.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
D=$(cd "$(dirname "$0")" && pwd); . "$D/lab.env"; U=${SUDO_USER:-$(logname 2>/dev/null || echo root)}; UH=$(getent passwd "$U" | cut -d: -f6)
DEV=$(ip -o -4 addr show | awk -v p="$LANPFX" 'index($4, p) == 1 {print $2; exit}'); [ -n "$DEV" ] || { echo "no interface in ${LANPFX}0/24"; exit 1; }
CON=$(nmcli -t -f NAME,DEVICE connection show --active | awk -F: -v d="$DEV" '$2 == d {print $1; exit}'); [ -n "$CON" ] || { echo "no active NetworkManager connection on $DEV"; exit 1; }
echo "interface $DEV, connection '$CON'"
nmcli -g ipv4.routes connection show "$CON" | grep -q "$NET" || nmcli connection modify "$CON" +ipv4.routes "$NET $FWOUT"
NEW=$DNS; for s in $(nmcli -g ipv4.dns connection show "$CON" | tr ',' ' '); do [ "$s" = "$DNS" ] || NEW="$NEW,$s"; done
nmcli connection modify "$CON" ipv4.dns "$NEW" ipv4.ignore-auto-dns yes
nmcli device reapply "$DEV" >/dev/null; sleep 2; resolvectl flush-caches 2>/dev/null || true
echo "route: $(ip route show "$NET")"; echo "dns:   $(resolvectl dns "$DEV" 2>/dev/null)"
if grep -q '^# BEGIN ai-fabric' /etc/hosts; then cp /etc/hosts "/etc/hosts.bak.ai-fabric.$(date +%s)"; sed -i '/^# BEGIN ai-fabric/,/^# END ai-fabric/d' /etc/hosts; echo "hosts: removed the earlier bastion pass-through block"; fi
install -m 644 "$D/ai-fabric-cluster-ca.crt" /usr/local/share/ca-certificates/ai-fabric-cluster-ca.crt; update-ca-certificates 2>&1 | tail -1
if command -v certutil >/dev/null 2>&1; then
  for db in "$UH/.pki/nssdb" "$UH"/.mozilla/firefox/*.default* "$UH"/snap/firefox/common/.mozilla/firefox/*.default*; do
    [ -d "$db" ] || continue
    sudo -u "$U" certutil -D -n "ai-fabric cluster-ca" -d "sql:$db" >/dev/null 2>&1 || true
    sudo -u "$U" certutil -A -n "ai-fabric cluster-ca" -t "C,," -i "$D/ai-fabric-cluster-ca.crt" -d "sql:$db" && echo "nss: trusted in $db"
  done
fi
echo "--- check: name -> address (from the bastion BIND), path (via the firewall), TLS (system trust store)"
while read -r u; do h=${u#https://}; h=${h%/}
  printf "  %-36s -> %-10s via %-14s HTTP %s\n" "$h" "$(getent ahostsv4 "$h" | awk '{print $1; exit}')" "$(ip route get "$VIP" | awk '{for (i = 1; i < NF; i++) if ($i == "via") print $(i + 1)}')" "$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' "$u" 2>&1 | tail -1)"
done < "$D/urls.txt"
EOS

cat > "$P/windows.ps1" <<'EOS'
# ai-fabric workstation setup (Windows). Run ON the workstation in an elevated PowerShell:
#   powershell -ExecutionPolicy Bypass -File $HOME\ai-fabric-publish\windows.ps1
# Idempotent. Adds a persistent route to the lab's node subnet via the lab firewall, puts the lab's bastion BIND first in the interface's
# DNS server list (existing servers are kept after it), trusts the lab CA in LocalMachine\Root. Nothing is removed.
$ErrorActionPreference = "Stop"
$D = Split-Path -Parent $MyInvocation.MyCommand.Path
$e = @{}; Get-Content "$D\lab.env" | ForEach-Object { $k, $v = $_ -split '=', 2; $e[$k] = $v }
$if = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress.StartsWith($e.LANPFX) } | Select-Object -First 1).InterfaceAlias
if (-not $if) { throw "no interface in $($e.LANPFX)0/24" }
if (-not (Get-NetRoute -DestinationPrefix $e.NET -ErrorAction SilentlyContinue)) { New-NetRoute -DestinationPrefix $e.NET -InterfaceAlias $if -NextHop $e.FWOUT | Out-Null }
$old = (Get-DnsClientServerAddress -InterfaceAlias $if -AddressFamily IPv4).ServerAddresses
Set-DnsClientServerAddress -InterfaceAlias $if -ServerAddresses (@($e.DNS) + @($old | Where-Object { $_ -ne $e.DNS }))
Clear-DnsClientCache
"interface {0}: route {1} via {2}; dns {3}" -f $if, $e.NET, $e.FWOUT, ((Get-DnsClientServerAddress -InterfaceAlias $if -AddressFamily IPv4).ServerAddresses -join ",")
$hosts = "$env:SystemRoot\System32\drivers\etc\hosts"
if (Select-String -Path $hosts -Pattern '^# BEGIN ai-fabric' -Quiet) {
  Copy-Item $hosts "$hosts.bak.ai-fabric.$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"; $keep = New-Object System.Collections.Generic.List[string]; $skip = $false
  foreach ($l in Get-Content $hosts) { if ($l -match '^# BEGIN ai-fabric') { $skip = $true }; if (-not $skip) { $keep.Add($l) }; if ($l -match '^# END ai-fabric') { $skip = $false } }
  Set-Content -Path $hosts -Value $keep -Encoding ASCII; "hosts: removed the earlier bastion pass-through block"
}
Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -match 'O=ai-fabric' } | Remove-Item
$c = Import-Certificate -FilePath "$D\ai-fabric-cluster-ca.crt" -CertStoreLocation Cert:\LocalMachine\Root
"trust: " + $c.Subject + "  thumbprint " + $c.Thumbprint
"--- check: name -> address (from the bastion BIND), path (via the firewall), TLS (Windows store; curl.exe needs --ssl-no-revoke: lab certificates carry no revocation info)"
Get-Content "$D\urls.txt" | ForEach-Object { $h = ([uri]$_).Host; $a = (Resolve-DnsName $h -Type A -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress
  $code = & curl.exe -sS --ssl-no-revoke --max-time 10 -o NUL -w "%{http_code}" $_ 2>&1 | Select-Object -Last 1; "  {0,-36} -> {1,-10} HTTP {2}" -f $h, $a, $code }
EOS
chmod +x "$P/ubuntu-desktop.sh"
echo "kit in $(pwd)/$P:"; ls -1 "$P"; echo; cat "$P/lab.env"; echo; cat "$P/urls.txt"
