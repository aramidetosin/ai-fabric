#!/bin/bash
# ca-certs.sh: the leaf certificates the lab Platform CA issues besides the platform wildcard (site-a-nx, operator decisions 2026-09-23):
#   storage   storage-mgmt.<domain> + the management VIP     -> the storage node's management API (/etc/ai-fabric/fb/{cert,key}.pem)
#   fw        fw-mgmt.<domain> + the firewall mgmt address  -> the firewall UI; imported by the OPERATOR with fw-ui-cert.sh (PAN-OS needs its password)
# Subject = CN <first DNS name>, O ai-fabric lab: PAN-OS refuses a key pair whose certificate has an empty subject ("missing subject field").
# cert-manager issues and renews them (Certificates in namespace cert-manager, from gen.CA_LEAVES; 1 year, renewed 30 days before expiry). This script
# applies them, waits until they are Ready, and installs the storage one on the storage node. The node pulls it from the cluster itself, so the key
# never crosses the lab host. flashblade-api restarts only when the certificate changed. finish.sh runs it (stage 6); re-run it after a renewal.
#   CHECK=1   only report (validation): issued + Ready, not expiring within 30 days, the storage API SERVES the current certificate and verifies against
#             the lab root, and whether the firewall UI already presents its lab certificate.
cd "$(dirname "$0")"; . ./lib.sh
MANI=$(python3 - <<'PY'
import gen
if gen.LAB_CA:
    for n, c in gen.CA_LEAVES.items():
        pk = "{algorithm: ECDSA, size: 256}" if c["key"] == "ECDSA" else "{algorithm: RSA, size: 2048}"
        print(f"""---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {{name: {c['secret']}, namespace: cert-manager}}
spec:
  secretName: {c['secret']}
  commonName: {c['dns'][0]}
  subject: {{organizations: [ai-fabric lab]}}
  duration: 8760h
  renewBefore: 720h
  dnsNames: {c['dns']}
  ipAddresses: {c['ip']}
  privateKey: {pk}
  usages: [server auth, digital signature, key encipherment]
  issuerRef: {{name: cluster-ca, kind: ClusterIssuer, group: cert-manager.io}}""".replace("'", ""))
PY
)
[ -n "$MANI" ] || { echo "lab CA: not in this profile (nothing to do)"; exit 0; }
read -r SSEC FSEC FBA FWM CN <<< "$(python3 -c 'import gen; print(gen.CA_LEAVES["storage"]["secret"], gen.CA_LEAVES["fw"]["secret"], gen.FB_API, gen.FW["mgmt"], gen.CLUSTER)')"
CAF=/shared/$CN/cluster-ca.crt; RC=0
notafter() { K "kubectl -n cert-manager get certificate $1 -o jsonpath={.status.notAfter}" | tail -1; }
ready() { K "kubectl -n cert-manager get certificate $1 -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}'" | tail -1; }

if [ -z "${CHECK:-}" ]; then
  KT=300 K "cat <<'EOF' | kubectl apply -f - >/dev/null && kubectl -n cert-manager wait --for=condition=Ready certificate/$SSEC certificate/$FSEC --timeout=240s | sed 's/^/   /'
$MANI
EOF" || { echo "lab CA: certificates not Ready"; exit 1; }
  # the storage node pulls its certificate + key from the cluster (admin kubeconfig on /shared) and swaps them in only when they changed
  o=$(H storage "k=\"kubectl --kubeconfig /shared/$CN/kubeconfig -n cert-manager get secret $SSEC -o jsonpath\"; d=/etc/ai-fabric/fb; umask 077
    \$k={.data.tls\\\\.crt} | base64 -d > \$d/cert.new && \$k={.data.tls\\\\.key} | base64 -d > \$d/key.new && [ -s \$d/cert.new ] && [ -s \$d/key.new ] || { echo FETCH-FAILED; exit 1; }
    if cmp -s \$d/cert.new \$d/cert.pem && cmp -s \$d/key.new \$d/key.pem; then rm -f \$d/*.new; echo unchanged
    else mv \$d/cert.new \$d/cert.pem; mv \$d/key.new \$d/key.pem; chmod 644 \$d/cert.pem; chmod 600 \$d/key.pem; systemctl restart flashblade-api; echo installed; fi")
  echo "   storage management API certificate: $o"; [ "$o" = unchanged ] || [ "$o" = installed ] || RC=1
fi
for s in $SSEC $FSEC; do
  r=$(ready "$s"); na=$(notafter "$s"); left=$(( ($(date -d "${na:-1970-01-01T00:00:00Z}" +%s) - $(date +%s)) / 86400 ))
  [ "$r" = True ] && [ "$left" -gt 30 ] && echo "   $s: Ready, expires $na ($left days)" || { echo "   $s: NOT OK (Ready=$r, expires ${na:-?})"; RC=1; }
done
# served, verified: from a data-VLAN node through the firewall (data -> stor-mgmt tcp/443), against the lab root, by name and by address
for u in "https://$FBA/api/api_version" "--resolve storage-mgmt.lab.ai:443:$FBA https://storage-mgmt.lab.ai/api/api_version"; do
  # up to 3 tries: the first flow to an idle VIP can time out while the leaf resolves its ARP entry (seen on every fresh build; not TLS)
  for try in 1 2 3; do c=$(H ctrl3 "curl -s --cacert $CAF -m 10 -o /dev/null -w %{http_code} $u" | tail -1); [ "$c" = 200 ] && break; sleep 3; done
  [ "$c" = 200 ] && echo "   storage API $(echo $u | awk '{print $NF}'): TLS verified against the lab root (HTTP 200)" || { echo "   storage API $(echo $u | awk '{print $NF}'): NOT verified (HTTP ${c:-none})"; RC=1; }
done
# the firewall UI (informational until the operator has run fw-ui-cert.sh)
iss=$(timeout 10 openssl s_client -connect "$FWM:443" -servername fw-mgmt.lab.ai </dev/null 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null | sed 's/^issuer=//')
case "$iss" in *"ai-fabric Platform CA"*) echo "   firewall UI: presents the lab certificate (issuer: $iss)" ;;
               *) echo "   firewall UI: still its own certificate (issuer: ${iss:-unreachable}) -- operator step: ssh -t <host> <repo>/fw-ui-cert.sh" ;; esac
exit $RC
