#!/bin/bash
# snmp-enable.sh [switches|servers|all]: SNMP v2c read-only, community from gen.py (SNMP_COMMUNITY = public), on every device of THIS host's lab, so
# Weft can poll them. Idempotent. The switch settings are ALSO part of the generated configs (gen.py), so a redeploy brings them back by itself;
# this script applies them to the running lab. Servers get net-snmp's snmpd (finish.sh runs this part after every deploy).
#   Junos   : apply-junos.sh with the regenerated configs/*.set      (mgmt_junos instance needs routing-instance-access, see gen.py JN_SNMP)
#   OcNOS   : view + community bound to the view + enable, in vrf management        Cumulus : nv set system snmp-server ..., vrf mgmt
#   NX-OS   : part of configs/<switch>.cfg (boot config); this script only reports whether the lines are running
#   PAN-OS  : part of bootstrap/fw.xml (applies at the firewall's next first boot); live change = operator (commit on the firewall)
#   servers : ctrl/gpu/storage guests + bastion + PCs: snmpd on udp/161, readable from the lab management subnet and the Weft VM's subnet
cd "$(dirname "$0")"; . ./lib.sh; EVID=
WHAT=${1:-all}; C=$(python3 -c 'import gen; print(gen.SNMP_COMMUNITY)'); TH=$(python3 -c 'import gen; print(gen.SNMP_TRAP_HOST)'); ALLOW="172.21.21.0/24 172.29.129.0/24"
if [ "$WHAT" != servers ]; then
  if grep -q " junos$" "$MH"; then echo "== Junos: $(./apply-junos.sh 2>&1 | grep -c committed) switches committed"; fi
  if [ "$FE_NOS" = cumulus ]; then echo "== Cumulus"
    CUML="$FE_SPINES $FE_LEAVES $FE_BORDERS"; [ "$OOB_NOS" = cumulus ] && CUML="$CUML oob-sw"
    for n in $CUML; do ( r=$(CVX $n "nv set system snmp-server state enabled >/dev/null && nv set system snmp-server listening-address all vrf mgmt >/dev/null && nv set system snmp-server readonly-community $C access any >/dev/null && nv set system snmp-server trap-destination $TH vrf mgmt community-password $C version 2c >/dev/null && nv set system snmp-server trap-link-down check-frequency 10 >/dev/null && nv set system snmp-server trap-link-up check-frequency 10 >/dev/null && nv set system snmp-server trap-snmp-auth-failures >/dev/null 2>&1; nv config apply -y 2>&1 | grep -c applied; sleep 2; sudo ss -lun | grep -c ':161 '"); echo "  $n: $(echo $r | xargs)" ) & done; wait; fi
  if [ "$FE_NOS" = nxos ]; then echo "== NX-OS (SNMP comes with the boot config; checking it is running)"
    for n in $FE_SPINES $FE_LEAVES $FE_BORDERS; do echo "  $n: $(NX $n "show running-config snmp" 2>/dev/null | grep -c "community $C group network-operator\|snmp-server host $TH") of 3 lines present"; done; fi
  echo "== OcNOS"
  for n in $BE_SPINES $BE_LEAVES; do
    ( OCE $n "configure terminal" "snmp-server view all .1 included vrf management" "commit" "snmp-server community $C view all version v2c ro vrf management" "commit" "snmp-server enable snmp vrf management" "commit" "snmp-server host $TH traps version 2c $C udp-port 162 vrf management" "commit" "snmp-server enable traps bgp" "commit" "snmp-server enable traps snmp authentication" "commit" "end" >/dev/null 2>&1
      echo "  $n: $(OCE $n "show running-config snmp" 2>/dev/null | grep -a -c "community $C view all\|enable snmp vrf management\|snmp-server host $TH") of 3 lines present" ) &
    sleep 1; done; wait
fi
if [ "$WHAT" != switches ] && is_full; then echo "== servers (snmpd)"
  S=$(mktemp); cat > "$S" <<EOS
set -e
command -v snmpd >/dev/null || { export DEBIAN_FRONTEND=noninteractive; apt-get update -qq >/dev/null 2>&1 || true; apt-get install -y -qq snmpd >/dev/null 2>&1; }
[ -f /etc/snmp/snmpd.conf.orig ] || cp /etc/snmp/snmpd.conf /etc/snmp/snmpd.conf.orig 2>/dev/null || true
{ echo "# written by ai-fabric snmp-enable.sh: SNMP v2c read-only for Weft"; echo "agentaddress udp:161"; for a in $ALLOW; do echo "rocommunity $C \$a"; done
  echo "trap2sink $TH $C"; echo "authtrapenable 1"      # coldStart + authentication failures only: link traps would report every pod veth of a k8s node
  echo "sysLocation ai-fabric containerlab"; echo "sysContact lab operator"; echo "dontLogTCPWrappersConnects yes"; } > /etc/snmp/snmpd.conf
systemctl enable snmpd >/dev/null 2>&1; systemctl restart snmpd; sleep 1; systemctl is-active snmpd
EOS
  for n in $CTRLS storage $GPUS; do ( r=$(timeout 600 ssh $SSHO "admin@$(mgmt $n)" "sudo sh -s" < "$S" 2>&1 | tail -1); echo "  $n: $r" ) & [ $(jobs -r | wc -l) -lt 10 ] || wait -n; done; wait; rm -f "$S"
  # bastion + PCs are containers without systemd: snmpd is started directly (their images / pc-init.sh start it again after a redeploy)
  r=$(docker exec $LAB-bastion sh -c "command -v snmpd >/dev/null || { export DEBIAN_FRONTEND=noninteractive; apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq snmpd >/dev/null 2>&1; }; printf 'agentaddress udp:161\nrocommunity $C 172.21.21.0/24\nrocommunity $C 172.29.129.0/24\ntrap2sink $TH $C\nauthtrapenable 1\n' > /etc/snmp/snmpd.conf; pkill snmpd 2>/dev/null; sleep 1; snmpd -Lf /dev/null -p /run/snmpd.pid && echo started" 2>&1 | tail -1); echo "  bastion: $r"
  for p in pc-1 pc-2; do r=$(docker exec $LAB-$p sh -c "command -v snmpd >/dev/null || apk add --no-cache net-snmp >/dev/null 2>&1; mkdir -p /etc/snmp; printf 'agentaddress udp:161\nrocommunity $C 172.21.21.0/24\nrocommunity $C 172.29.129.0/24\ntrap2sink $TH $C\nauthtrapenable 1\n' > /etc/snmp/snmpd.conf; pkill snmpd 2>/dev/null; sleep 1; snmpd -C -c /etc/snmp/snmpd.conf -Lf /dev/null && echo started" 2>&1 | tail -1); echo "  $p: $r"; done
fi
