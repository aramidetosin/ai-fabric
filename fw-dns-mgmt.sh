#!/bin/bash
# fw-dns-mgmt.sh: move the RUNNING firewall's own DNS + NTP (to dns-b) onto its management port. Operator decision 2026-09-23.
#
# Why: the first VLAN cut routed them out of ethernet1/5 (service routes "dns" / "ntp"). PAN-OS runs service-route traffic that leaves a
# data-plane port through the security policy as intrazone internet -> internet, and deny-all-log (above the implicit intrazone allow)
# dropped every query to dns-b (traffic log: 10.80.15.121 -> 10.80.15.53:53, deny-all-log). gen.fw_vlans() and bootstrap/fw-override.xml
# no longer carry those service routes; this makes the same change on the running firewall, so no redeploy is needed.
# The management port reaches dns-b through vrnetlab's NAT and the lab host (the same path the switches use).
#
#   ssh -t <host> <repo>/fw-dns-mgmt.sh     asks for the admin password (not echoed, never stored or logged), deletes the two
#                                                  service routes, commits, shows the result. Idempotent: nothing to delete = no commit.
set -uo pipefail
cd "$(dirname "$0")"; . ./lib.sh
FWM=$(mgmt fw); XP="/config/devices/entry[@name='localhost.localdomain']/deviceconfig/system/route/service"

[ -t 0 ] && [ -t 1 ] || { echo "refusing: this prompts for the firewall password, so it needs a terminal -- run it as:  ssh -t <host> <repo>/fw-dns-mgmt.sh" >&2; exit 1; }
printf 'firewall admin password for %s (not echoed, never stored): ' "$FWM"
stty -echo 2>/dev/null; read -r PW; stty echo 2>/dev/null; echo
[ -n "$PW" ] || { echo "nothing entered, nothing changed" >&2; exit 1; }
KEY=$(curl -sk --max-time 30 "https://$FWM/api/?type=keygen&user=${FW_USER:-admin}" --data-urlencode "password=$PW" | sed -n 's|.*<key>\(.*\)</key>.*|\1|p')
unset PW
[ -n "$KEY" ] || { echo "could not get an API key: wrong password, or the firewall's management plane is not up yet" >&2; exit 1; }
trap 'unset KEY' EXIT
api() { curl -sk --max-time 120 "https://$FWM/api/" --data-urlencode "key=$KEY" "$@"; }      # key in the POST body, never in a URL
routes() { api --data-urlencode type=config --data-urlencode action=get --data-urlencode "xpath=$XP" | grep -oE '<entry name="[a-z-]+"' | cut -d'"' -f2 | paste -sd' '; }

echo "service routes before: $(routes)"
del=0
for s in dns ntp; do
  r=$(api --data-urlencode type=config --data-urlencode action=get --data-urlencode "xpath=$XP/entry[@name='$s']")
  grep -q "<entry name=\"$s\"" <<< "$r" || { echo "  $s: no service route (already on the management port)"; continue; }
  r=$(api --data-urlencode type=config --data-urlencode action=delete --data-urlencode "xpath=$XP/entry[@name='$s']")
  grep -q 'status="success"' <<< "$r" && { echo "  $s: service route deleted (candidate config)"; del=1; } || { echo "  $s: delete FAILED: $(head -c 300 <<< "$r")" >&2; exit 1; }
done
if [ "$del" = 1 ]; then
  r=$(api --data-urlencode type=commit --data-urlencode "cmd=<commit><description>fw-dns-mgmt.sh: DNS + NTP via the management port</description></commit>")
  J=$(sed -n 's|.*<job>\([0-9]*\)</job>.*|\1|p' <<< "$r"); [ -n "$J" ] || { echo "commit was not accepted: $(head -c 300 <<< "$r")" >&2; exit 1; }
  printf 'commit job %s ' "$J"
  for i in $(seq 1 60); do
    r=$(api --data-urlencode type=op --data-urlencode "cmd=<show><jobs><id>$J</id></jobs></show>")
    grep -q '<status>FIN</status>' <<< "$r" && break; printf .; sleep 5; done; echo
  res=$(sed -n 's|.*<result>\([A-Z]*\)</result>.*|\1|p' <<< "$r" | head -1)
  echo "commit result: ${res:-unknown}"; [ "$res" = OK ] || { tr -d '\n' <<< "$r" | grep -oE '<line>[^<]*</line>' | sed 's/<[^>]*>//g' | head -10 >&2; exit 1; }
fi
echo "service routes after: $(routes)"
echo "configured DNS / NTP: $(api --data-urlencode type=config --data-urlencode action=get --data-urlencode "xpath=/config/devices/entry[@name='localhost.localdomain']/deviceconfig/system/dns-setting/servers" | grep -oE '<primary>[^<]*' | cut -d'>' -f2) / $(api --data-urlencode type=config --data-urlencode action=get --data-urlencode "xpath=/config/devices/entry[@name='localhost.localdomain']/deviceconfig/system/ntp-servers" | grep -oE '<ntp-server-address>[^<]*' | cut -d'>' -f2 | paste -sd' ')"
echo "NTP status (can take a few minutes to synchronise after the change):"
api --data-urlencode type=op --data-urlencode "cmd=<show><ntp></ntp></show>" | tr -d '\n' | sed 's/></>\n</g' | grep -E '<(synched|name|status|reachable|authentication-type)>' | sed 's/<[^>]*>/ /g; s/  */ /g' | head -8
