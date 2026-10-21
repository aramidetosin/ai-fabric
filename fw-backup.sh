#!/bin/bash
# fw-backup.sh: save the firewall's RUNNING configuration as the one the lab boots from.
#
# Why this is needed: the PA-VM's overlay disk lives INSIDE its container (/PA-VM-KVM-*-overlay.qcow2), so it is thrown away by
# every ./down.sh + ./up.sh. The firewall then boots from clab-ai-fabric/fw/config/startup-config.xml, which containerlab copies from
# the topology's startup-config. Anything you changed in the web UI and committed is therefore LOST on the next redeploy unless it
# is either in gen.py or captured here.
#
#   ssh -t <host> <repo>/fw-backup.sh            save the running config as bootstrap/fw-override.xml
#   ssh -t <host> <repo>/fw-backup.sh --show     show whether an override is active and how it differs, change nothing
#   rm <repo>/bootstrap/fw-override.xml          go back to the generated configuration
#
# While bootstrap/fw-override.xml exists, gen.py points the firewall at it and STOPS applying its own firewall changes. That is the
# point (your edits win), but it also means a later generator change -- a new DNAT because the Gateway VIP moved, SNMP, a new zone --
# will NOT reach the firewall until you re-run this script to re-capture, or delete the override.
set -uo pipefail
cd "$(dirname "$0")"; . ./lib.sh
OVR=bootstrap/fw-override.xml; GEN=bootstrap/fw.xml; FWM=$(mgmt fw)

if [ "${1:-}" = --show ]; then
  if [ -s "$OVR" ]; then
    echo "override ACTIVE: $OVR  ($(stat -c %s "$OVR") bytes, saved $(stat -c %y "$OVR" | cut -c1-19))"
    echo "the firewall boots from it; gen.py's own firewall configuration is NOT applied"
    command -v xmllint >/dev/null 2>&1 && { echo "--- elements only in the override vs the generated config:"
      diff <(xmllint --c14n "$GEN" 2>/dev/null | tr '<' '\n' | grep -o '^[a-z-]*' | sort -u) \
           <(xmllint --c14n "$OVR" 2>/dev/null | tr '<' '\n' | grep -o '^[a-z-]*' | sort -u) | head -20; }
  else echo "no override: the firewall boots from the generated $GEN"; fi
  exit 0
fi

[ -t 0 ] || { echo "refusing: this prompts for the firewall password, so it needs a terminal -- run it as:  ssh -t <host> <repo>/fw-backup.sh" >&2; exit 1; }
printf 'firewall admin password for %s (not echoed, never stored): ' "$FWM"
stty -echo 2>/dev/null; read -r PW; stty echo 2>/dev/null; echo
[ -n "$PW" ] || { echo "nothing entered, nothing changed" >&2; exit 1; }

KEY=$(curl -sk --max-time 30 "https://$FWM/api/?type=keygen&user=${FW_USER:-admin}" --data-urlencode "password=$PW" | sed -n 's|.*<key>\(.*\)</key>.*|\1|p')
unset PW
[ -n "$KEY" ] || { echo "could not get an API key: wrong password, or the firewall's management plane is not up yet" >&2; exit 1; }

TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
curl -sk --max-time 60 "https://$FWM/api/?type=config&action=show" --data-urlencode "key=$KEY" > "$TMP"
unset KEY
grep -q "<config" "$TMP" || { echo "the firewall did not return a configuration:" >&2; head -c 300 "$TMP" >&2; echo >&2; exit 1; }

# The API wraps the running config in <response><result>...</result></response>. Lift out the <config> element itself, which is
# exactly the shape the generated fw.xml has and the shape the vrnetlab launcher imports, and prove it parses before installing it.
python3 - "$TMP" "$OVR" "${KEEP_USERS:-0}" <<'PY' || { echo "the returned configuration did not parse: nothing was changed" >&2; exit 1; }
import sys, xml.etree.ElementTree as ET
src, dst, keep = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
root = ET.parse(src).getroot()
cfg = root if root.tag == "config" else root.find(".//config")
if cfg is None: raise SystemExit("no <config> element in the response")
for must in ("devices",):
    if cfg.find(must) is None: raise SystemExit(f"<config> has no <{must}>: refusing to install a truncated configuration")
# <mgt-config> carries the admin and __vm_series password hashes. The vrnetlab launcher sets the PA-VM's password itself during
# boot, and the GENERATED fw.xml deliberately has no mgt-config -- that is the path proven to boot this lab. Shipping a captured
# mgt-config means the launcher's expected login and the hash in the config must agree, and a PA-VM that disagrees wedges on boot
# (see README). So drop it by default and let vrnetlab stay authoritative for credentials; KEEP_USERS=1 keeps it if you really
# changed the admin account in the UI and want that to survive.
m = cfg.find("mgt-config")
if m is not None and not keep:
    cfg.remove(m); note = "  (dropped <mgt-config>: vrnetlab owns the PA-VM password; KEEP_USERS=1 to keep it)"
else: note = "  (kept <mgt-config>)" if m is not None else ""
ET.ElementTree(cfg).write(dst, encoding="unicode", xml_declaration=False)
print(f"saved {dst}: {len(ET.tostring(cfg))} bytes, {len(list(cfg.iter()))} elements")
print(note) if note else None
PY

echo
echo "the firewall will now boot from $OVR on every ./up.sh (gen.py stops applying its own firewall configuration)"
echo "check it any time with:  ./fw-backup.sh --show     revert with:  rm $OVR"
