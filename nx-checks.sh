# nx-checks.sh - frontend control-plane checks for the Cisco Nexus 9300v frontend (profile site-a-nx), sourced by validate.sh (section B)
# and validate-fabric.sh (light lab). Needs lib.sh (NX, chk, ge, ok, bad). Every expectation is DERIVED from gen.py -- never written out -- so
# the checks follow the profile. Same checks the nxprobe lab proved the design with (containerlab/ai-fabric-nx-probe/test.sh, 2026-09-23).
#   underlay  OSPF area 0, IP unnumbered (loopback0) on every leaf-spine link, one link per spine, ECMP over both spines, LLDP cabling
#   overlay   iBGP EVPN to both spines (route reflectors), NVE peers, L2VNI 10010 / L3VNI 11000
#   pairs     vPC fabric peering: adjacency, keepalive, Virtual-peerlink mode, consistency, fabric ports, every vPC up, members bundled, TCAM carve active
#   border    eBGP to the firewall (presented as AS 65104), default route from the firewall, type-5 default on the server leaves, storage trunk
nx_frontend() {
  local NLB s l b o n e v p exp rc miss me u a
  NLB=$(echo $FE_LEAVES $FE_BORDERS | wc -w)
  # per vPC leaf: name, #vPCs (servers on the pair), #member ports, storage port-channel (or -); per switch: loopback0; pair VIPs; border VTEPs
  declare -A NVPC NMEM STPO LO
  while read -r l a m st; do NVPC[$l]=$a; NMEM[$l]=$m; STPO[$l]=$st; done < <(python3 -c '
import gen
for n, s in gen.FE.items():
    if s.get("role") != "leaf": continue
    m = gen.nx_members(s)
    st = next((str(po) for po, ports, tagged, h in m if tagged), "-")
    print(n, len(m), sum(len(p) for _, p, _, _ in m), st)')
  while read -r l a; do LO[$l]=$a; done < <(python3 -c 'import gen; [print(n, s["lo"]) for n, s in gen.FE.items() if s.get("lo")]')
  VIPS=$(python3 -c 'import gen; print(" ".join(sorted({gen.nx_ids(n)["vip"] for n, s in gen.FE.items() if s.get("pair")})))')
  BVTEP=$(python3 -c 'import gen; print(" ".join(gen.nx_ids(n)["lo1"] for n, s in gen.FE.items() if s["role"] == "border"))')
  B1=$(echo $FE_BORDERS | awk '{print $1}')
  declare -A VNIS ZGW; SMPORT=""; SMVLAN=""
  while read -r l v; do VNIS[$l]=$v; done < <(python3 -c '
import gen
for n, s in gen.FE.items():
    if s.get("role") not in ("leaf", "border"): continue
    z = gen.nx_zones(s.get("pair")) if s["role"] == "leaf" else gen.nx_zones()
    v = ([10000 + x["vlan"] for x in z] if s["role"] == "leaf" else []) + [x["l3vni"] for x in z]
    print(n, " ".join(str(i) for i in sorted(v)))')
  while read -r l v; do ZGW[$l]=$v; done < <(python3 -c '
import gen
for n, s in gen.FE.items():
    if s.get("role") == "leaf": print(n, " ".join(str(z["vlan"]) + ":" + z["gw"] for z in gen.nx_zones(s["pair"])))')
  read -r SMPORT SMVLAN <<< "$(python3 -c 'import gen; print(gen.STOR_MGMT["port"], gen.STOR_MGMT["vlan"]) if gen.MULTI else print("", "")')"
  NZ=$(python3 -c 'import gen; print(len(gen.NX_ZONES))')

  # the boot config really applied: every line of configs/<switch>.cfg is in the running-config. vrnetlab types the file into the console and
  # a rejected line only shows up here. NX-OS hides defaults, so these never appear verbatim (nxprobe 2026-09-23): bare "switchport" /
  # "switchport mode access", "vrf management" on the peer-keepalive, "username X role network-admin" (shown as "password 5 !" = key-only)
  for s in $FE_SPINES $FE_LEAVES $FE_BORDERS; do
    rc=$(NX $s "show running-config" | sed 's/[[:space:]]*$//')
    miss=$(grep -vE '^\s*$|^  switchport$|^  switchport mode access$|^username [a-z]+ role network-admin$|^no feature ' configs/$s.cfg | sed 's/[[:space:]]*$//; s/ vrf management$//' \
           | while IFS= read -r l; do grep -qxF -- "$l" <<< "$rc" || echo "$l"; done)
    # `no feature X` (e.g. telnet, hardening=True) is shown by NX-OS as the ABSENCE of `feature X`: check that instead of the literal line
    for f in $(sed -n 's/^no feature //p' configs/$s.cfg); do grep -qx "feature $f" <<< "$rc" && miss="$miss${miss:+$'\n'}feature $f is enabled"; done
    chk "$s: every line of configs/$s.cfg is in the running-config" "" "$(printf '%s' "$miss" | head -3 | tr '\n' '|')"
  done
  for s in $FE_SPINES; do
    chk "$s: $NLB/$NLB OSPF adjacencies FULL (unnumbered point-to-point)" $NLB "$(NX $s 'show ip ospf neighbors' | grep -c FULL)"
    chk "$s: $NLB/$NLB iBGP EVPN sessions Established (route reflector)" $NLB "$(nx_evpn_up $s)"
    chk "$s: all $NLB fabric links IP unnumbered (loopback0)" $NLB "$(NX $s 'show ip interface brief' | grep -cE '^Eth1/[0-9]+ .*unnumbered')"
  done
  for l in $FE_LEAVES $FE_BORDERS; do
    chk "$l: 2/2 OSPF adjacencies FULL, 2/2 iBGP EVPN sessions" "2 2" "$(NX $l 'show ip ospf neighbors' | grep -c FULL) $(nx_evpn_up $l)"
    chk "$l: both uplinks IP unnumbered (loopback0)" 2 "$(NX $l 'show ip interface brief' | grep -cE '^Eth1/[12] .*unnumbered')"
    chk "$l: underlay ECMP to a border loopback over both spines" 2 "$(NX $l "show ip route ${LO[$B1]}" | grep -c '\*via')"
    o=$(NX $l "show lldp neighbors" | awk '$2 ~ /^Eth1\/[12]$/ {print $2 ">" $1}' | sed -E 's/\.[^>]*$//' | sort | tr '\n' ' ')
    chk "$l: LLDP cabling Eth1/1 -> fe-spine1, Eth1/2 -> fe-spine2" "Eth1/1>fe-spine1 Eth1/2>fe-spine2 " "$o"
    v=$(NX $l "show nve vni" | awk '$1 == "nve1" && $4 == "Up" {print $2}' | sort -n | xargs)
    chk "$l: VNIs Up (${VNIS[$l]})" "${VNIS[$l]}" "$v"
    me=$(python3 -c "import gen; s = gen.FE['$l']; print(gen.nx_ids('$l')['vip'] if s.get('pair') else gen.nx_ids('$l')['lo1'])")   # its own VTEP address
    p=$(NX $l "show nve peers" | awk '$1 == "nve1" {print $2, $3}'); miss=""
    for e in $VIPS $BVTEP; do [ "$e" = "$me" ] && continue; grep -q "^$e Up$" <<< "$p" || miss="$miss $e"; done
    chk "$l: NVE peers Up to every other pair VIP and border VTEP, none down" "|0" "$miss|$(awk '$2 != "Up"' <<< "$p" | grep -c .)"
  done
  for l in $FE_LEAVES; do
    o=$(NX $l "show vpc")
    chk "$l: vPC peer adjacency formed ok / keepalive (mgmt0) alive / Virtual-peerlink mode Enabled / consistency success" "1 1 1 1" \
      "$(grep -c 'peer adjacency formed ok' <<< "$o") $(grep -ci 'keep-alive.*peer is alive' <<< "$o") $(grep -c 'Virtual-peerlink mode *: Enabled' <<< "$o") $(grep -c 'Configuration consistency status *: success' <<< "$o")"
    chk "$l: ${NVPC[$l]} vPCs up + consistent" "${NVPC[$l]}" "$(awk '$1 ~ /^[0-9]+$/ && $2 ~ /^Po[0-9]+$/ && $3 == "up" && $4 == "success"' <<< "$o" | wc -l)"
    chk "$l: both fabric ports (uplinks) up" 2 "$(NX $l 'show vpc fabric-ports' | grep -Eci 'Ethernet1/[12] +up')"
    # NX-OS wraps the member list after three ports (storage: 4 per leaf), so continuation lines count for the port-channel above them
    chk "$l: ${NMEM[$l]} server ports bundled (P) in their port-channels" "${NMEM[$l]}" "$(NX $l 'show port-channel summary' | awk '$1 ~ /^[0-9]+$/ && $2 ~ /^Po/ {cur = $2} cur ~ /^Po[0-9]+\(SU\)$/ && cur != "Po500(SU)" {n += gsub(/\(P\)/, "")} END {print n + 0}')"
    u=$(NX $l "show version" | awk '/Kernel uptime/ {gsub(/[^0-9 ]/, " "); n = split($0, a, " +"); k = 0; for (i = 1; i <= n; i++) if (a[i] != "") v[++k] = a[i]; print v[1]*86400 + v[2]*3600 + v[3]*60 + v[4]}')
    a=$(( $(date +%s) - $(date -d "$(docker inspect -f '{{.State.StartedAt}}' $LAB-$l)" +%s) ))
    [ -n "$u" ] && [ $((a - u)) -gt 150 ] && ok "$l: TCAM carve for fabric peering active (reloaded after provisioning: container ${a}s, switch up ${u}s)" \
      || bad "$l: TCAM carve not active (no reload since provisioning)" "container ${a}s, switch up ${u:-?}s -- run ./nx-tcam-reload.sh"
    chk "$l: anycast gateway MAC 000a.00c1.0001" 1 "$(NX $l 'show running-config | include anycast-gateway-mac' | grep -c 000a.00c1.0001)"
    for zg in ${ZGW[$l]}; do zv=${zg%%:*}; zi=${zg#*:}
      chk "$l: anycast gateway $zi on Vlan$zv (address + anycast mode, interface up)" "2 1" "$(NX $l "show running-config interface Vlan$zv" | grep -cE "ip address ${zi//./\\.}|fabric forwarding mode anycast-gateway") $(NX $l "show interface Vlan$zv" | grep -c "Vlan$zv is up")"
    done
    ge "$l: EVPN host routes (/32) of servers in vrf k8s" 5 "$(NX $l 'show ip route vrf k8s' | grep -cE '^10\.1\.1\.[0-9]+/32')"
    if [ "${STPO[$l]}" != - ]; then o=$(NX $l "show running-config interface port-channel${STPO[$l]}")
      DV=$(python3 -c 'import gen; print(gen.FE_VLAN)')
      grep -q "switchport mode trunk" <<< "$o" && grep -q "switchport trunk allowed vlan $DV$" <<< "$o" && ! grep -q "native vlan" <<< "$o" \
        && ok "$l: storage port-channel${STPO[$l]} carries VLAN $DV TAGGED only (trunk, no native VLAN)" || bad "$l storage trunk" "$(echo $o | cut -c1-100)"
      if [ -n "$SMPORT" ]; then o=$(NX $l "show interface Ethernet1/$SMPORT switchport"; NX $l "show interface Ethernet1/$SMPORT" | head -1)
        chk "$l: storage management port Eth1/$SMPORT up, access VLAN $SMVLAN (not in a port-channel)" "1 1" \
          "$(grep -cE "Ethernet1/$SMPORT is up" <<< "$o") $(grep -cE "Access Mode VLAN: $SMVLAN " <<< "$o")"; fi
    fi
  done
  for b in $FE_BORDERS; do
    for vrf in $(python3 -c 'import gen; print(" ".join(z["vrf"] for z in gen.NX_ZONES))'); do
      chk "$b: eBGP to the firewall Established in vrf $vrf (border presents AS 65104)" 1 "$(NX $b "show bgp vrf $vrf ipv4 unicast summary" | awk '$1 ~ /^10\.1\.254\./ && $10 ~ /^[0-9]+$/' | wc -l)"
      chk "$b: default route from the firewall in vrf $vrf" 1 "$(NX $b "show ip route 0.0.0.0/0 vrf $vrf" | grep -c 'via 10\.1\.254\.')"
    done
  done
  L1=$(echo $FE_LEAVES | awk '{print $1}')
  ge "$L1: type-5 default in vrf k8s via the border VTEPs (encap VXLAN)" 1 "$(NX $L1 'show ip route 0.0.0.0/0 vrf k8s' | grep -c 'encap: VXLAN')"
}
