#!/bin/bash
# fw-ui-cert.sh: give the running firewall's management UI the lab CA's certificate (fw-mgmt.<domain> + its management address, issued by cert-manager
# from the lab Platform CA; see ca-certs.sh). PAN-OS needs its admin password for this, so the OPERATOR runs it:
#   ssh -t <host> <repo>/fw-ui-cert.sh          asks for the password (not echoed, never stored or logged)
# Imports the lab root and the Platform CA as CA certificates (so PAN-OS can send the chain), the UI key pair as PKCS#12 protected by a one-time random
# passphrase that exists only inside this script, and an SSL/TLS service profile "ai-fabric-mgmt" (TLS 1.2+). It then points the management UI at that
# profile, commits, and checks https://<mgmt> against the lab root. Run fw-backup.sh afterwards so a redeploy keeps it: the captured config holds the
# key encrypted with the firewall's master key.
set -uo pipefail
cd "$(dirname "$0")"; . ./lib.sh
read -r FSEC CN DOMAIN <<< "$(python3 -c 'import gen; print(gen.CA_LEAVES["fw"]["secret"] if gen.LAB_CA else "-", gen.CLUSTER, gen.DOMAIN)')"
[ "$FSEC" != - ] || { echo "no lab CA in this profile"; exit 1; }
FWM=$(mgmt fw); XS="/config/shared"; XD="/config/devices/entry[@name='localhost.localdomain']/deviceconfig/system"
[ -t 0 ] && [ -t 1 ] || { echo "refusing: this prompts for the firewall password, so it needs a terminal -- run it as:  ssh -t <host> <repo>/fw-ui-cert.sh" >&2; exit 1; }
W=$(mktemp -d); chmod 700 "$W"; trap 'rm -rf "$W"; unset KEY P12PW' EXIT

# the certificate material: leaf + key from cert-manager, the Platform CA and the lab root from the lab host
# jsonpath in single quotes: K runs it through one more shell (bash -lc in the bastion), which would eat an unquoted backslash (tls\.crt -> tls.crt = empty)
K "kubectl -n cert-manager get secret $FSEC -o jsonpath='{.data.tls\.crt}'" | tail -1 | base64 -d > "$W/chain.pem"
K "kubectl -n cert-manager get secret $FSEC -o jsonpath='{.data.tls\.key}'" | tail -1 | base64 -d > "$W/key.pem"
openssl x509 -in "$W/chain.pem" -out "$W/leaf.pem" 2>/dev/null
cp ca/platform.crt "$W/platform.pem"; cp ca/root.crt "$W/root.pem"      # the lab host's host-only ca/ directory (dns-b-ca.sh)
openssl verify -CAfile "$W/root.pem" -untrusted "$W/platform.pem" "$W/leaf.pem" >/dev/null 2>&1 || { echo "the $FSEC certificate does not verify against the lab root: run ca-certs.sh first" >&2; exit 1; }
P12PW=$(openssl rand -hex 12)     # 24 characters: PAN-OS refuses import passphrases longer than 31
openssl pkcs12 -export -in "$W/leaf.pem" -inkey "$W/key.pem" -certfile "$W/platform.pem" -name ai-fabric-fw-ui -passout "pass:$P12PW" -out "$W/ui.p12" 2>/dev/null
echo "certificate: $(openssl x509 -in "$W/leaf.pem" -noout -subject -ext subjectAltName 2>/dev/null | paste -sd' ' | tr -s ' ') | expires $(openssl x509 -in "$W/leaf.pem" -noout -enddate | cut -d= -f2)"

printf 'firewall admin password for %s (not echoed, never stored): ' "$FWM"
stty -echo 2>/dev/null; read -r PW; stty echo 2>/dev/null; echo
[ -n "$PW" ] || { echo "nothing entered, nothing changed" >&2; exit 1; }
KEY=$(curl -sk --max-time 30 "https://$FWM/api/?type=keygen&user=${FW_USER:-admin}" --data-urlencode "password=$PW" | sed -n 's|.*<key>\(.*\)</key>.*|\1|p')
unset PW
[ -n "$KEY" ] || { echo "could not get an API key: wrong password, or the management plane is not up yet" >&2; exit 1; }
api()  { curl -sk --max-time 120 "https://$FWM/api/" -H "X-PAN-KEY: $KEY" "$@"; }                          # key in a header, never in a URL
okr()  { grep -q 'status="success"' <<< "$1" && echo "  ok    $2" || { echo "  FAIL  $2: $(tr -d '\n' <<< "$1" | sed 's/<[^>]*>/ /g' | tr -s ' ' | cut -c1-200)" >&2; exit 1; }; }
imp()  { api -F type=import -F category="$1" -F certificate-name="$2" -F format="$3" "${@:5}" -F "file=@$4"; }

have() { api --data-urlencode type=config --data-urlencode action=get --data-urlencode "xpath=$XS/certificate/entry[@name='$1']" | grep -q "<entry name=\"$1\""; }   # candidate config: re-runs skip what an earlier run imported
for c in "ai-fabric-lab-root:root.pem:lab root" "ai-fabric-platform-ca:platform.pem:Platform CA"; do
  IFS=: read -r cn cf cd <<< "$c"
  if have "$cn"; then echo "  ok    $cd already present as CA certificate $cn"; else okr "$(imp certificate "$cn" pem "$W/$cf")" "$cd imported as CA certificate $cn"; fi
done
# the key pair: skipped when the firewall already holds this very certificate (re-run), re-imported when it changed (cert-manager renewal).
# PKCS#12 first; if this PAN-OS refuses OpenSSL 3's default PKCS#12 encryption, fall back to PEM (leaf + traditional AES-encrypted RSA key)
cur=$(api --data-urlencode type=config --data-urlencode action=get --data-urlencode "xpath=$XS/certificate/entry[@name='ai-fabric-fw-ui']/public-key" | tr -d '\n\r ' | sed -n 's|.*<public-key[^>]*>\([^<]*\)</public-key>.*|\1|p')
if [ -n "$cur" ] && [ "$cur" = "$(tr -d '\n\r ' < "$W/leaf.pem")" ]; then r='<response status="success"/>'; echo "  ok    UI key pair already present (same certificate)"
else r=$(imp keypair ai-fabric-fw-ui pkcs12 "$W/ui.p12" -F "passphrase=$P12PW"); fi
if ! grep -q 'status="success"' <<< "$r"; then
  echo "  note  PKCS#12 import refused ($(tr -d '\n' <<< "$r" | sed 's/<[^>]*>/ /g' | tr -s ' ' | cut -c1-120)); trying PEM"
  { cat "$W/leaf.pem"; openssl rsa -in "$W/key.pem" -aes256 -traditional -passout "pass:$P12PW" 2>/dev/null; } > "$W/ui.pem"
  r=$(imp keypair ai-fabric-fw-ui pem "$W/ui.pem" -F "passphrase=$P12PW")
fi
if ! grep -q 'status="success"' <<< "$r" && [ -n "$cur" ]; then   # a key pair of that name exists already: keep it; the final check proves what is served
  echo "  note  re-import refused ($(tr -d '\n' <<< "$r" | sed 's/<[^>]*>/ /g' | tr -s ' ' | cut -c1-100)); keeping the existing ai-fabric-fw-ui"; r='<response status="success"/>'; fi
okr "$r" "UI key pair ai-fabric-fw-ui in place"
okr "$(api --data-urlencode type=config --data-urlencode action=set --data-urlencode "xpath=$XS/ssl-tls-service-profile/entry[@name='ai-fabric-mgmt']" \
        --data-urlencode "element=<certificate>ai-fabric-fw-ui</certificate><protocol-settings><min-version>tls1-2</min-version></protocol-settings>")" \
    "SSL/TLS service profile ai-fabric-mgmt (TLS 1.2+)"
okr "$(api --data-urlencode type=config --data-urlencode action=set --data-urlencode "xpath=$XD" --data-urlencode "element=<ssl-tls-service-profile>ai-fabric-mgmt</ssl-tls-service-profile>")" \
    "management UI uses ai-fabric-mgmt"
r=$(api --data-urlencode type=commit --data-urlencode "cmd=<commit><description>fw-ui-cert.sh: lab CA certificate for the management UI</description></commit>")
J=$(sed -n 's|.*<job>\([0-9]*\)</job>.*|\1|p' <<< "$r"); [ -n "$J" ] || { echo "commit was not accepted: $(head -c 300 <<< "$r")" >&2; exit 1; }
printf 'commit job %s ' "$J"
for i in $(seq 1 60); do r=$(api --data-urlencode type=op --data-urlencode "cmd=<show><jobs><id>$J</id></jobs></show>"); grep -q '<status>FIN</status>' <<< "$r" && break; printf .; sleep 5; done; echo
res=$(sed -n 's|.*<result>\([A-Z]*\)</result>.*|\1|p' <<< "$r" | head -1); echo "commit result: ${res:-unknown}"
[ "$res" = OK ] || { tr -d '\n' <<< "$r" | grep -oE '<line>[^<]*</line>' | sed 's/<[^>]*>//g' | head -10 >&2; exit 1; }
unset KEY

echo "checking https://$FWM against the lab root (the web server restarts after the commit) ..."
for i in $(seq 1 24); do
  v=$(timeout 10 openssl s_client -connect "$FWM:443" -servername "fw-mgmt.$DOMAIN" -CAfile "$W/root.pem" </dev/null 2>/dev/null | grep -m1 "Verify return code")
  case "$v" in *"0 (ok)"*) echo "  ok    $v"; break ;; esac; sleep 5; done
case "$v" in *"0 (ok)"*) ;; *) echo "  FAIL  ${v:-no answer}: the UI does not present a chain to the lab root yet" >&2; exit 1 ;; esac
echo "done. Next, so a redeploy keeps it:  ssh -t <host> <repo>/fw-backup.sh"
