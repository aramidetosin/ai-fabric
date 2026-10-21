# shared helpers for the ai-fabric scripts (sourced). Run on eve from /root/ai-fabric. Modelled on <reference-platform>/lib.sh.
LAB=clab-ai-fabric
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; MH="$HERE/mgmt-hosts.txt"
SSHO="-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
# node lists come from mgmt-hosts.txt (written by gen.py), so every script follows the active profile (site-a: Cumulus, 3 ctrl + 8 GPU;
# site-b: Juniper vEX, 6 ctrl + 16 GPU, two GPU leaf pairs)
names() { awk -v re="$1" '$1 ~ re {print $1}' "$MH" | xargs; }
FE_SPINES=$(names '^fe-spine'); FE_LEAVES=$(names '^fe-(gpu|stor|ctrl)-leaf'); FE_BORDERS=$(names '^fe-border')
BE_SPINES=$(names '^be-spine'); BE_LEAVES=$(names '^be-leaf'); GPUS=$(names '^gpu[0-9]+$'); CTRLS=$(names '^ctrl[0-9]+$')
FE_NOS=$(awk '$1 == "fe-spine1" {print $3}' "$MH")          # cumulus | junos | nxos
nos_of() { awk -v n="$1" '$1 == n {print $3; exit}' "$MH"; }   # NOS of ONE node: a Cumulus fabric can carry a vEX OOB switch (site-a at 32 GPUs needs 38 OOB ports, Cumulus VX has 16)
OOB_NOS=$(nos_of oob-sw)
mgmt() { awk -v n="$1" '$1==n {print $2; exit}' "$MH"; }
# ---- COMMAND TRANSCRIPT. Every helper below records what it ran, exactly as an operator would see it on the device: the device prompt, the
# command, then the raw output. When $EVID names a file the block is appended there (one write per block, so parallel collectors do not
# interleave inside a block). validate.sh, the traces, the drills and the audit all set EVID, so none of them shows an output without the
# command that produced it. _run <prompt+command line> <command...> captures, records, re-emits and keeps the exit status.
_evpipe() { local o; o=$(cat); _ev "$1" "$o"; [ -z "$o" ] || printf '%s\n' "$o"; }      # same, for helpers that are pipelines
_ev()  { [ -n "${EVID:-}" ] || return 0; printf '%s\n%s\n\n' "$1" "$2" >> "$EVID"; }
_run() { local line=$1 o rc; shift; o=$("$@" 2>&1); rc=$?; _ev "$line" "$o"; [ -z "$o" ] || printf '%s\n' "$o"; return $rc; }
evnote() { [ -n "${EVID:-}" ] && printf '%s\n' "$*" >> "$EVID"; return 0; }     # section headers and verdicts go into the transcript too
# Junos (vEX): operator keys come from the boot config; the CLI accepts one command per SSH exec
JNX() { _run "admin@$1> $2" timeout 90 ssh -n $SSHO "admin@$(mgmt "$1")" "$2 | no-more"; }
# Cisco NX-OS (Nexus 9300v, profile site-a-nx): user `ops` holds this host's key (gen.py nx_head; NX-OS keeps one sshkey per user, admin has the
# Mac key). _run reads the WHOLE output before anything downstream sees it -- keep it that way: when the reader closes the pipe early (grep -q, awk
# exit, head) an NX-OS exec session does not end and ssh sits there until the timeout (nxprobe 2026-09-23: 90 s instead of 1 s).
NX()  { _run "$1# $2" timeout 90 ssh -n $SSHO "ops@$(mgmt "$1")" "$2"; }
# Cumulus: operator key installed by the launcher
CVX() { _run "cumulus@$1:mgmt:~\$ $2" timeout 90 ssh -n $SSHO "cumulus@$(mgmt "$1")" "$2"; }
# OcNOS over SSH with the operator key (gen.py installs `username admin sshkey`). cmlsh has no exec form, so commands go in on a tty.
OCS() {
  local n=$1; shift
  { sleep 2; printf 'terminal length 0\n'; for c in "$@"; do sleep 0.4; printf '%s\n' "$c"; done; sleep 2.5; printf 'exit\n'; } \
    | timeout 90 ssh -tt $SSHO "admin@$(mgmt "$n")" 2>&1 | tr -d '\r' | awk 'f && NF {print} /terminal length 0/ {f=1}' | _evpipe "# ssh admin@$n   (OcNOS CLI, exec mode; every command is echoed after the prompt below)"
}
# OCE: like OCS but in privileged exec (`enable` asks for no password on this image): the unprivileged prompt refuses half of the show
# commands (route-map, running-config sections, mac table). Two exits: the first leaves privileged exec, the second closes the session.
OCE() {
  local n=$1; shift
  { sleep 2; printf 'enable\nterminal length 0\n'; for c in "$@"; do sleep 0.4; printf '%s\n' "$c"; done; sleep 2.5; printf 'exit\n'; sleep 0.5; printf 'exit\n'; } \
    | timeout 90 ssh -tt $SSHO "admin@$(mgmt "$n")" 2>&1 | tr -d '\r' | awk 'f && NF {print} /terminal length 0/ {f=1}' | grep -v -E "^$n[>#]exit$" | _evpipe "# ssh admin@$n, enable   (OcNOS CLI, privileged exec; every command is echoed after the prompt below)"
}
# OcNOS through the console session vrnetlab leaves logged in (one client at a time; kept alive by `exec-timeout 0 0`)
OCN() { local n=$1; shift; docker cp "$HERE/con.py" "$LAB-$n:/con.py" >/dev/null 2>&1; _run "# console of $n: $(printf '%s ; ' "$@")" timeout 120 docker exec "$LAB-$n" python3 /con.py "$@"; }
X()   { _run "root@$1:/# $2" timeout 120 docker exec "$LAB-$1" sh -c "$2"; }                               # container nodes (light hosts, bastion, PCs)
H()   { _run "admin@$1:~\$ sudo sh -c '$2'" timeout 120 ssh -n $SSHO "admin@$(mgmt "$1")" "sudo sh -c '$2'"; }            # VM-node guests (operator key)
K()   { _run "admin@bastion:/workspace\$ $1" timeout "${KT:-180}" docker exec "$LAB-bastion" bash -lc "$1"; }                       # kubectl from the bastion (KT=<s> for long waits)
# ---- firewall (PAN-OS) CLI over ssh: operational commands as an operator reads them, and the running configuration as SET commands (the XML API has no set
# output). Credentials: FW_PASS / FW_USER when the operator exports them; otherwise the ones containerlab gave the firewall's own vrnetlab launcher, read from
# the container's environment at run time (nothing is stored in this repository, nothing is printed). An operator who changed the password exports FW_PASS.
_fwssh() { local u p; u=${FW_USER:-$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$LAB-fw" 2>/dev/null | sed -n 's/^USERNAME=//p')}
  p=${FW_PASS:-$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$LAB-fw" 2>/dev/null | sed -n 's/^PASSWORD=//p')}; [ -n "$p" ] || { echo "(firewall CLI: no credentials -- export FW_PASS)"; return 1; }
  SSHPASS="$p" timeout "${FWT:-120}" sshpass -e ssh -tt -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o PubkeyAuthentication=no "${u:-admin}@$(mgmt fw)" 2>/dev/null | tr -d '\r'; }
_pancli_raw() { printf 'set cli pager off\n%s\nexit\n' "$1" | _fwssh | grep -vxF -- "$1" | sed -e '/@[^ ]*[>#]/d' -e '/^Last login: /d' -e '/^Number of failed attempts/d' -e '/^set cli pager off$/d' -e '/^exit$/d' | cat -s | sed -e '1{/^$/d}'; }
PANCLI() { _run "admin@ai-fabric-fw> $1" _pancli_raw "$1"; }      # PANCLI "show routing route"
fw_cli_ok() { _pancli_raw "show system info" 2>/dev/null | grep -q '^hostname:'; }      # can this host read the firewall's CLI?
# the running configuration as set commands; password hashes and private keys are replaced by <hidden> (they never leave the firewall)
_panset_raw() { printf 'set cli pager off\nset cli config-output-format set\nconfigure\nshow\nexit\nexit\n' | _fwssh | grep '^set ' | grep -v '^set cli ' | sed -E 's/^(set .* (phash|private-key|password|key|secret|bind-password|auth-password|priv-password)) .*/\1 <hidden>/'; }
PANSET() { _run "admin@ai-fabric-fw> set cli config-output-format set ; configure ; show" _panset_raw; }
health() { docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$LAB-$1" 2>/dev/null; }

# ---------------------------------------------------------------- test framework (validate.sh, drills.sh)
PASS=0; FAIL=0; SKIP=0; KNOWN=0; FAILED=(); KNOWNS=()
ok()   { PASS=$((PASS + 1)); printf "  PASS  %s\n" "$1"; evnote "  ==> PASS  $1"$'\n'; }
bad()  { FAIL=$((FAIL + 1)); FAILED+=("$1${2:+ -> $2}"); printf "  FAIL  %s%s\n" "$1" "${2:+   -> $2}"; evnote "  ==> FAIL  $1${2:+   -> $2}"$'\n'; }
skip() { SKIP=$((SKIP + 1)); printf "  SKIP  %s%s\n" "$1" "${2:+   ($2)}"; evnote "  ==> SKIP  $1${2:+   ($2)}"$'\n'; }
known() { KNOWN=$((KNOWN + 1)); KNOWNS+=("$1"); printf "  KNOWN %s\n        %s\n" "$1" "$2"; evnote "  ==> KNOWN $1"$'\n'; }   # expected failure: a documented limit of the virtual platform, NOT a pass
sec()  { printf "\n== %s\n" "$*"; evnote $'\n'"################################################################ $*"$'\n'; }
chk()  { local label=$1 want=$2 got=$3; [ "$got" = "$want" ] && ok "$label" || bad "$label" "expected $want, got ${got:-nothing}"; }   # exact match
ge()   { local label=$1 min=$2 got=$3; [ "${got:-0}" -ge "$min" ] 2>/dev/null && ok "$label" || bad "$label" "expected >= $min, got ${got:-nothing}"; }
# Batch runner: a list of "label|command" lines is executed INSIDE a guest / container / pod in one round-trip. Each command is
# retried once (the first packets of a new flow through the firewall or a fresh ARP entry are often lost). Output: PASS|label / FAIL|label|detail
BATCH_PRE='t() { l=$1; shift; for a in 1 2; do o=$("$@" 2>&1) && { echo "PASS|$l"; return; }; sleep 1; done; echo "FAIL|$l|$(echo "$o" | tail -1 | cut -c1-90)"; }
p() { l=$1; shift; t "$l" ping -c 2 -W 2 -q "$@"; }'
batch_file() { local f; f=$(mktemp); { echo "$BATCH_PRE"; cat; } > "$f"; echo "$f"; }
tally() { local l; while IFS='|' read -r st lab det; do case "$st" in PASS) ok "$lab";; FAIL) bad "$lab" "$det";; esac; done; }
tally_quiet() { local n=0 f=0 st lab det; while IFS='|' read -r st lab det; do case "$st" in PASS) n=$((n + 1));; FAIL) f=$((f + 1)); bad "$lab" "$det";; esac; done; [ "$f" = 0 ] && ok "$1: $n/$n" || { PASS=$((PASS + n)); }; }
_batch() { sed -n '3,$p' "$1" | sed -E "s/^p '([^']*)' (.*)\$/ping -c 2 -W 2 -q \\2      # \\1/; s/^t '([^']*)' (.*)\$/\\2      # \\1/"; }     # the batch as plain commands (p = ping -c 2 -W 2 -q, t = run and test the exit status; each is retried once)
HS() { _run "admin@$1:~\$ sudo sh -s <<BATCH"$'\n'"$(_batch "$2")"$'\n'"BATCH" timeout 600 ssh $SSHO "admin@$(mgmt "$1")" "sudo sh -s" < "$2"; }                                  # guest: run a script file
XS() { _run "root@$1:/# sh -s <<BATCH"$'\n'"$(_batch "$2")"$'\n'"BATCH" timeout 600 docker exec -i "$LAB-$1" sh -s < "$2"; }                                                 # container node
PS() { _run "admin@bastion:/workspace\$ kubectl -n ${3:-gpu} exec -i $1 -- sh -s <<BATCH"$'\n'"$(_batch "$2")"$'\n'"BATCH" timeout 900 docker exec -i "$LAB-bastion" bash -lc "kubectl -n ${3:-gpu} exec -i $1 -- sh -s" < "$2"; }   # pod (through the bastion's kubectl)
is_full() { docker inspect -f '{{.Config.Image}}' $LAB-gpu1 2>/dev/null | grep -q vm-node; }
summary() { printf "\n== RESULT: %s passed, %s failed, %s known platform limitation(s), %s skipped\n" "$PASS" "$FAIL" "$KNOWN" "$SKIP"
  [ "$KNOWN" = 0 ] || { printf "   known limitations (virtual platform):\n"; printf "     - %s\n" "${KNOWNS[@]}"; }
  [ "$FAIL" = 0 ] || { printf "   failed checks:\n"; printf "     - %s\n" "${FAILED[@]}"; }; [ "$FAIL" = 0 ]; }
# keep_latest <category> <dir just written>: ONE result set per category under audits/. Once a new run is complete the older runs of
# the same category are removed. Only acts on the default location (audits/<category>_<timestamp>); a caller-chosen outdir is left alone.
keep_latest() { local cat=$1 new=${2%/} d; case "$new" in audits/${cat}_[0-9]*) ;; *) return 0;; esac; [ -d "$new" ] || return 0
  for d in audits/${cat}_[0-9]*; do [ -d "$d" ] && [ "$d" != "$new" ] && { rm -rf -- "$d"; echo "removed older $d"; }; done; return 0; }
# gw_vip: the Gateway VIP of the RUNNING cluster (what the lab was deployed with), falling back to gen.py's value. gen.py may carry a newer
# value than the deployed lab (e.g. the .30 -> .200 move), so tests and traces never hardcode it.
gw_vip() { local v; v=$(K "kubectl -n gateway get gateway gateway -o jsonpath='{.status.addresses[0].value}' 2>/dev/null" | grep -oE '^[0-9.]+$'); [ -n "$v" ] && echo "$v" || python3 -c 'import gen; print(gen.GW_VIP)'; }
# ---- frontend helpers that work for every NOS flavour (Cumulus VX / Juniper vEX / Cisco Nexus 9300v)
# leafport <node>: "<leafA> <leafB> <port>" = the leaf pair and the switch port number of the node's first bond leg (container ethN on every NOS)
leafport() { python3 -c 'import gen, sys; n = sys.argv[1]; h = gen.BASTION if n == "bastion" else gen.HOSTS[n]; l = gen.PAIR[h["pair"]]; print(l[0], l[1], h.get("port") or h["members"][0])' "$1"; }
l3vni() { python3 -c 'import gen; print(gen.NX_L3VNI if gen.NXOS else gen.L3VNI)'; }        # the L3 VNI on the wire (NX-OS: 11000, VNIs start at 4096)
nxmac() { echo "$1" | tr -d ':' | sed -E 's/^(....)(....)(....)$/\1.\2.\3/'; }                 # aa:bb:cc:dd:ee:ff -> aabb.ccdd.eeff
# NX-OS prints the EVPN neighbour list twice (the second table = per-route-type counts): count the FIRST table only; a number in column 10 = Established
nx_evpn_up() { NX $1 "show bgp l2vpn evpn summary" | awk '/^Neighbor/ {t++} t == 1 && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $10 ~ /^[0-9]+$/' | wc -l; }
fe_sessions() { case $FE_NOS in junos) JNX $1 "show bgp summary" | grep -cE '^10\.0\.0\.[0-9]+ .* Establ';; nxos) nx_evpn_up $1;;
                *) CVX $1 "sudo vtysh -c 'show bgp l2vpn evpn summary json'" | grep -c '"state":"Established"';; esac; }   # EVPN sessions up
# underlay liveness: BFD sessions on Cumulus/Junos; the Nexus design detects failures with OSPF (1 s hello / 3 s dead), so there: FULL adjacencies
fe_bfd_up()   { case $FE_NOS in junos) JNX $1 "show bfd session" | grep -cE ' Up +ge-';; nxos) NX $1 "show ip ospf neighbors" | grep -c FULL;; *) CVX $1 "sudo ptmctl -b | grep -c ' Up '";; esac; }
fe_vrf_route() { case $FE_NOS in junos) JNX $1 "show route table k8s.inet.0 $2" | tail -n +2 | head -8;; nxos) NX $1 "show ip route $2 vrf k8s" | grep -E "^[0-9]|via" | head -8;;
                 *) CVX $1 "ip route get vrf k8s $2 | head -1; ip route show vrf k8s | grep ^default";; esac; }
fe_vrf_bgp()  { case $FE_NOS in junos) JNX $1 "show bgp summary instance k8s" | tail -3;; nxos) NX $1 "show bgp vrf k8s ipv4 unicast summary" | tail -3;;
                *) CVX $1 "sudo vtysh -c 'show bgp vrf k8s ipv4 unicast summary' | tail -3";; esac; }
fe_underlay() { case $FE_NOS in junos) JNX $1 "show route table inet.0 10.0.0.0/24 terse" | grep -E '^\* ' | head -14;; nxos) NX $1 "show ip route 10.0.0.0/16 longer-prefixes" | grep -E '^10\.|\*via' | head -24;;
                *) CVX $1 "sudo vtysh -c 'show ip route 10.0.0.0/24 longer-prefixes' | grep -E '^B' | head -12";; esac; }
fe_mac()      { case $FE_NOS in junos) JNX $1 "show ethernet-switching table instance FABRIC" | grep -i "$2" | head -3; JNX $1 "show evpn database mac-address $2" | tail -3;;
                nxos) NX $1 "show mac address-table address $(nxmac $2)" | grep -iE "$(nxmac $2)"; NX $1 "show ip arp $3 vrf k8s" | grep -E "^$3 ";;
                *) CVX $1 "sudo /sbin/bridge fdb show | grep -i $2 | head -3; sudo vtysh -c 'show evpn arp-cache vni 10' | grep -E '$3 |Neighbor' | head -3";; esac; }
fe_host_route() { case $FE_NOS in junos) JNX $1 "show route table k8s.inet.0 $2/32 detail" | grep -E "^$2|Protocol next hop|Encapsulation|VNI|AS path" | head -8;;
                  nxos) NX $1 "show ip route $2 vrf k8s" | grep -E "^$2|via"; NX $1 "show bgp l2vpn evpn $2" | grep -E "Route Distinguisher|\[2\]|\[5\]|Received label|Extcommunity|RMAC|10\.0\.1\." | head -12;;
                  *) CVX $1 "sudo vtysh -c 'show bgp l2vpn evpn route type 2' | grep -B1 -A3 -i '$2' | head -12; ip route show vrf k8s $2";; esac; }
fe_ports()    { local n=$1 act=$2; shift 2; local p; for p in "$@"; do docker exec "$LAB-$n" ip link set "eth$p" "$act"; done; }   # fail/restore switch ports at the virtual wire: the far end keeps carrier = a silent failure
fw_out()  { python3 -c 'import gen; print(gen.FW["e5"].split("/")[0])'; }                       # the firewall's outside address on this host's LAN (per profile)
lan_src() { ip -4 route get "$(fw_out)" | grep -oE "src [0-9.]+" | cut -d" " -f2; }              # this host's own address on that LAN = the "outside LAN client" of the tests
