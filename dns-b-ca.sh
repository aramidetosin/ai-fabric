#!/bin/bash
# dns-b-ca.sh [profile]: the lab certificate authority (site-a-nx; operator decisions 2026-09-23). Run it on the Mac -- the only machine that
# reaches dns-b (ssh alias) -- like dns-b-zones.sh. Idempotent.
#   1. dns-b     root "ai-fabric Lab Root CA": RSA 4096, 10 y, pathlen 1. NO passphrase (operator decision): key 0400 in /root/ai-fabric-ca (0700).
#                Created once; every signing is kept in /root/ai-fabric-ca/issued.
#   2. site-a intermediate keys + CSRs in the HOST-ONLY /root/ai-fabric/ca (0700). Never shared/: that is a read-write 9p mount on every guest.
#                Created once and reused by every rebuild (gen.py binds the directory into the init node only).
#   3. dns-b     signs an intermediate only when its certificate is missing, does not match its key or the current root, or expires within 90 days
#                (FORCE=1: always). 5 y, pathlen 0, critical name constraints from gen.CA_INTERMEDIATES.
#   4. proves it on site-a: chain to the root, key = certificate, constraints present, and throw-away leaves INSIDE the constraints verify
#      while leaves OUTSIDE them (another domain, another address) are REJECTED.
set -euo pipefail
cd "$(dirname "$0")"
PROFILE=${1:-site-a-nx}; HOST=${EVE:-site-a}; DNS=${DNS_B:-dns-b}; D=/root/ai-fabric/ca
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
AI_FABRIC_PROFILE=$PROFILE python3 - > "$T/ca.env" <<'PY'
import gen, shlex, sys
if not gen.LAB_CA: sys.exit(f"profile {gen.PROFILE} has no lab CA (lab_ca=True)")
print(f"ROOT_SUBJ={shlex.quote(gen.CA_ROOT_SUBJ)}")
for n, c in gen.CA_INTERMEDIATES.items(): print(f"SUBJ_{n}={shlex.quote(c['subj'])}; NC_{n}={shlex.quote(c['nc'])}; KEY_{n}={shlex.quote(c['key'])}")
print(f"NAMES={shlex.quote(' '.join(gen.CA_INTERMEDIATES))}")
PY
. "$T/ca.env"
q() { printf '%q' "$1"; }

echo "== 1. root on $DNS"
ssh "$DNS" "sudo ROOT_SUBJ=$(q "$ROOT_SUBJ") bash -s" > "$T/root.crt" <<'REMOTE'
set -euo pipefail; R=/root/ai-fabric-ca; umask 077; mkdir -p $R/issued; chmod 700 $R
if [ ! -s $R/root.key ]; then openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out $R/root.key 2>/dev/null; chmod 400 $R/root.key; echo "   root key created" >&2; fi
if [ ! -s $R/root.crt ]; then
  printf '[req]\ndistinguished_name = dn\n[dn]\n[v3_root]\nbasicConstraints = critical,CA:TRUE,pathlen:1\nkeyUsage = critical,keyCertSign,cRLSign\nsubjectKeyIdentifier = hash\n' > $R/root.cnf
  openssl req -x509 -new -key $R/root.key -sha256 -days 3650 -subj "$ROOT_SUBJ" -config $R/root.cnf -extensions v3_root -out $R/root.crt
  chmod 444 $R/root.crt; echo "   root certificate created" >&2
fi
echo "   $(openssl x509 -in $R/root.crt -noout -subject) | $(openssl x509 -in $R/root.crt -noout -enddate) | $(openssl x509 -in $R/root.crt -noout -fingerprint -sha256 | cut -d= -f2)" >&2
cat $R/root.crt
REMOTE
grep -q "BEGIN CERTIFICATE" "$T/root.crt" || { echo "no root certificate came back from $DNS"; exit 1; }

echo "== 2. intermediate keys + CSRs on $HOST:$D (host-only)"
scp -q "$T/root.crt" "$HOST:/tmp/ai-fabric-root.crt"
ssh "$HOST" "NAMES=$(q "$NAMES") SUBJ_platform=$(q "$SUBJ_platform") SUBJ_kubernetes=$(q "$SUBJ_kubernetes") KEY_platform=$(q "$KEY_platform") KEY_kubernetes=$(q "$KEY_kubernetes") FORCE=${FORCE:-} bash -s" > "$T/todo" <<'REMOTE'
set -euo pipefail; D=/root/ai-fabric/ca; umask 077; mkdir -p $D; chmod 700 $D
install -m 0644 /tmp/ai-fabric-root.crt $D/root.crt; rm -f /tmp/ai-fabric-root.crt
for n in $NAMES; do
  s=SUBJ_$n; k=KEY_$n
  if [ ! -s $D/$n.key ]; then
    case "${!k}" in "EC P-256") openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out $D/$n.key ;; "RSA 2048") openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out $D/$n.key 2>/dev/null ;; *) echo "unknown key type ${!k}" >&2; exit 1 ;; esac
    chmod 600 $D/$n.key; echo "   $n: key created (${!k})" >&2
  fi
  openssl req -new -key $D/$n.key -subj "${!s}" -out $D/$n.csr
  why=""
  if [ -n "${FORCE:-}" ]; then why="FORCE"
  elif [ ! -s $D/$n.crt ]; then why="no certificate yet"
  elif [ "$(openssl pkey -in $D/$n.key -pubout)" != "$(openssl x509 -in $D/$n.crt -noout -pubkey)" ]; then why="certificate does not match the key"
  elif ! openssl verify -CAfile $D/root.crt $D/$n.crt >/dev/null 2>&1; then why="certificate does not chain to the current root"
  elif ! openssl x509 -in $D/$n.crt -noout -checkend 7776000 >/dev/null; then why="expires within 90 days"; fi
  [ -n "$why" ] && { echo "   $n: sign ($why)" >&2; echo "$n"; } || echo "   $n: certificate current, not re-signed" >&2
done
REMOTE

for n in $(cat "$T/todo"); do
  echo "== 3. $DNS signs the $n CA"
  scp -q "$HOST:$D/$n.csr" "$T/$n.csr"; scp -q "$T/$n.csr" "$DNS:/tmp/ai-fabric-$n.csr"
  nc=NC_$n
  ssh "$DNS" "sudo N=$n NC=$(q "${!nc}") bash -s" > "$T/$n.crt" <<'REMOTE'
set -euo pipefail; R=/root/ai-fabric-ca; umask 077
printf 'basicConstraints = critical,CA:TRUE,pathlen:0\nkeyUsage = critical,keyCertSign,cRLSign,digitalSignature\nsubjectKeyIdentifier = hash\nauthorityKeyIdentifier = keyid:always\nnameConstraints = critical,%s\n' "$NC" > $R/$N.ext
out=$R/issued/$N-$(date -u +%Y%m%dT%H%M%SZ).crt
openssl x509 -req -in /tmp/ai-fabric-$N.csr -CA $R/root.crt -CAkey $R/root.key -set_serial 0x$(openssl rand -hex 16) -days 1826 -sha256 -extfile $R/$N.ext -out $out 2>/dev/null
rm -f /tmp/ai-fabric-$N.csr; chmod 444 $out; echo "   signed: $(openssl x509 -in $out -noout -subject) | $(openssl x509 -in $out -noout -enddate) | kept as $out" >&2
cat $out
REMOTE
  grep -q "BEGIN CERTIFICATE" "$T/$n.crt" || { echo "no $n certificate came back from $DNS"; exit 1; }
  scp -q "$T/$n.crt" "$HOST:$D/$n.crt"; ssh "$HOST" "chmod 644 $D/$n.crt"
done

echo "== 4. proof on $HOST"
ssh "$HOST" 'bash -s' <<'REMOTE'
set -uo pipefail; D=/root/ai-fabric/ca; W=$(mktemp -d); trap 'rm -rf "$W"' EXIT; bad=0
ok() { echo "   ok    $*"; }; no() { echo "   FAIL  $*"; bad=1; }
leaf() { # ca, name, SAN list -> signed throw-away leaf in $W/<name>.crt
  openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout $W/$2.key -subj "/CN=$2" -out $W/$2.csr 2>/dev/null
  printf 'basicConstraints = CA:FALSE\nsubjectAltName = %s\n' "$3" > $W/$2.ext
  openssl x509 -req -in $W/$2.csr -CA $D/$1.crt -CAkey $D/$1.key -set_serial 0x$(openssl rand -hex 8) -days 1 -sha256 -extfile $W/$2.ext -out $W/$2.crt 2>/dev/null; }
vfy() { openssl verify -CAfile $D/root.crt -untrusted $D/$1.crt $W/$2.crt 2>&1 | grep -E ": OK$|^error [0-9]+ at" | head -1; }   # "<file>: OK" or the FIRST error = the reason
for n in platform kubernetes; do
  openssl verify -CAfile $D/root.crt $D/$n.crt >/dev/null 2>&1 && ok "$n CA chains to the root" || no "$n CA does not chain to the root"
  [ "$(openssl pkey -in $D/$n.key -pubout)" = "$(openssl x509 -in $D/$n.crt -noout -pubkey)" ] && ok "$n key matches its certificate" || no "$n key/certificate mismatch"
  openssl x509 -in $D/$n.crt -noout -text | grep -q "X509v3 Name Constraints: critical" && ok "$n CA carries critical name constraints" || no "$n CA has no name constraints"
  openssl x509 -in $D/$n.crt -noout -text | grep -q "CA:TRUE, pathlen:0" && ok "$n CA: CA:TRUE, pathlen 0" || no "$n CA basic constraints"
done
leaf platform in1 "DNS:*.platform.lab.ai";  [ "$(vfy platform in1)" = "$W/in1.crt: OK" ] && ok "platform: *.platform.lab.ai verifies" || no "platform: *.platform.lab.ai: $(vfy platform in1)"
leaf platform in2 "DNS:storage-mgmt.lab.ai,IP:10.1.20.18"; [ "$(vfy platform in2)" = "$W/in2.crt: OK" ] && ok "platform: storage-mgmt.lab.ai + 10.1.20.18 verify" || no "platform storage: $(vfy platform in2)"
leaf platform in3 "DNS:fw-mgmt.lab.ai,IP:172.21.21.30"; [ "$(vfy platform in3)" = "$W/in3.crt: OK" ] && ok "platform: fw-mgmt.lab.ai + 172.21.21.30 verify" || no "platform fw: $(vfy platform in3)"
leaf platform out1 "DNS:www.google.com"; r=$(vfy platform out1); [[ $r == *"subtree violation"* ]] && ok "platform: www.google.com REJECTED (name constraint)" || no "platform: www.google.com NOT rejected: $(vfy platform out1)"
leaf platform out2 "DNS:x.lab.ai,IP:192.168.1.1"; r=$(vfy platform out2); [[ $r == *"subtree violation"* ]] && ok "platform: IP 192.168.1.1 REJECTED" || no "platform: 192.168.1.1 NOT rejected: $(vfy platform out2)"
leaf kubernetes kin1 "DNS:api.lab.ai,DNS:ctrl1,DNS:kubernetes,DNS:kubernetes.default,DNS:kubernetes.default.svc,DNS:kubernetes.default.svc.cluster.local,DNS:kubernetes.default.svc.lab.ai,IP:10.43.0.1,IP:10.1.1.11,IP:10.1.1.20"
[ "$(vfy kubernetes kin1)" = "$W/kin1.crt: OK" ] && ok "kubernetes: every kube-apiserver SAN kubeadm uses verifies" || no "kubernetes apiserver SANs: $(vfy kubernetes kin1)"
leaf kubernetes kout1 "DNS:www.google.com"; r=$(vfy kubernetes kout1); [[ $r == *"subtree violation"* ]] && ok "kubernetes: www.google.com REJECTED (name constraint)" || no "kubernetes: www.google.com NOT rejected: $(vfy kubernetes kout1)"
leaf kubernetes kout2 "DNS:api.lab.ai,IP:172.21.21.30"; r=$(vfy kubernetes kout2); [[ $r == *"subtree violation"* ]] && ok "kubernetes: IP 172.21.21.30 REJECTED" || no "kubernetes: 172.21.21.30 NOT rejected: $(vfy kubernetes kout2)"
ls -l $D | sed 's/^/   /'
exit $bad
REMOTE
