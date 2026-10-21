#!/bin/bash
# audit.sh [outdir]: read-only state dump of every device of ai-fabric (layout of <reference-platform>/audit.sh).
#   audits/ai-fabric_audit_<ts>/<device>/NN_<command>.txt + 00_ALL_OUTPUT.txt per device, ALL_DEVICES_OUTPUT.txt, summary.txt
# Firewall: read over its CLI (ssh), the way an operator reads it: operational state, the traffic / system / config / threat logs and the RUNNING
# configuration as set commands (not XML; password hashes and private keys are replaced by <hidden>). Credentials: FW_PASS / FW_USER when exported,
# otherwise the ones containerlab gave the firewall's launcher (lib.sh _fwssh: read from the container at run time, never stored or printed).
set -u
cd "$(dirname "$0")"; . ./lib.sh
TS=$(date -u +%Y%m%d_%H%M%S); OUT=${1:-audits/ai-fabric_audit_$TS}; mkdir -p "$OUT"
slug() { echo "$1" | sed -E 's/[^A-Za-z0-9._-]+/_/g; s/^_+|_+$//g' | cut -c1-70; }
V() { printf "sudo vtysh -c '%s'" "$1"; }
CVX_COMMON=("grep -E '^(NAME|VERSION)=' /etc/os-release; uname -r; uptime" "ip -br link" "ip -br addr" "sudo lldpcli show neighbors summary" "$(V 'show bgp summary')" "$(V 'show ip route')"
 "$(V 'show bgp ipv4 unicast')" "ip -s link show | grep -A6 -E '^[0-9]+: (swp|bond)' | grep -E '^[0-9]+:|errors|dropped' -A1 | head -120" "nv config show -o commands")
CVX_VTEP=("$(V 'show bgp l2vpn evpn summary')" "$(V 'show bgp l2vpn evpn route')" "$(V 'show bgp l2vpn evpn route type 2')" "$(V 'show bgp l2vpn evpn route type 5')" "$(V 'show evpn')" "$(V 'show evpn vni')"
 "$(V 'show evpn vni detail')" "$(V 'show evpn mac vni all')" "$(V 'show evpn arp-cache vni all')" "$(V 'show evpn rmac vni all')" "$(V 'show evpn next-hops vni all')" "$(V 'show ip route vrf k8s')" "$(V 'show vrf')"
 "ip -d link show type vxlan" "sudo /sbin/bridge vlan show" "sudo /sbin/bridge fdb show | grep -v permanent | head -200")
CVX_MH=("$(V 'show evpn es')" "$(V 'show evpn es detail')" "$(V 'show evpn es-evi')" "$(V 'show evpn access-vlan')" "for b in /proc/net/bonding/bond*; do echo \"== \$b\"; cat \$b; done" "$(V 'show interface vlan10')" "ip -br addr show vlan10; ip -br addr show vlan10-v0; ip -br link show vlan10-v0")
CVX_BORDER=("$(V 'show bgp vrf k8s ipv4 unicast summary')" "$(V 'show bgp vrf k8s ipv4 unicast')" "$(V 'show bgp vrf k8s ipv4 unicast neighbors')" "ip route show vrf k8s")
# OcNOS: every command below was checked against the SP VM CLI in privileged exec (OCE). Hardware-only ones are left out on purpose:
# `show interface counters` ("Can't find interface counters"), `show qos ...` detail, `show logging` (no log file on the VM).
# Juniper vEX (profiles with fe_nos=vex): one CLI command per SSH exec, key-based
JN_COMMON=("show version" "show interfaces terse" "show lldp neighbors" "show bgp summary" "show bfd session" "show route table inet.0" "show route summary"
 "show chassis hardware" "show system alarms" "show configuration | display set")
JN_VTEP=("show evpn instance extensive" "show evpn database" "show ethernet-switching table instance FABRIC" "show ethernet-switching vxlan-tunnel-end-point remote instance FABRIC"
 "show route table bgp.evpn.0" "show route table k8s.inet.0" "show evpn ip-prefix-database" "show interfaces irb.10" "show lacp interfaces" "show interfaces ae1 extensive")
JN_BORDER=("show bgp summary instance k8s" "show route table k8s.inet.0" "show route advertising-protocol bgp 10.1.254.2 table k8s.inet.0" "show route receive-protocol bgp 10.1.254.2 table k8s.inet.0" "show evpn ip-prefix-database")
# Cisco Nexus 9300v (profile site-a-nx): one exec command per SSH session as `ops` (key-based); outputs are read in full (see NX() in lib.sh)
NX_COMMON=("show version" "show interface brief" "show ip interface brief" "show lldp neighbors" "show ip ospf neighbors" "show ip ospf interface brief"
 "show bgp l2vpn evpn summary" "show ip route" "show ip route summary" "show running-config" "show logging last 150")
NX_VTEP=("show nve peers" "show nve vni" "show nve interface nve1 detail" "show bgp l2vpn evpn" "show l2route evpn mac all" "show l2route evpn mac-ip all" "show mac address-table"
 "show ip arp vrf k8s" "show ip route vrf k8s" "show vrf k8s detail" "show interface vlan10" "show running-config interface nve1")
NX_VPC=("show vpc" "show vpc brief" "show vpc fabric-ports" "show vpc virtual-peerlink vlan consistency" "show vpc consistency-parameters global" "show vpc role"
 "show vpc peer-keepalive" "show port-channel summary" "show lacp neighbor" "show hardware access-list tcam region" "show startup-config | include tcam")
NX_BORDER=("show bgp vrf k8s ipv4 unicast summary" "show bgp vrf k8s ipv4 unicast" "show bgp vrf k8s ipv4 unicast neighbors 10.1.254.2 advertised-routes"
 "show bgp vrf k8s ipv4 unicast neighbors 10.1.254.6 advertised-routes" "show ip route vrf k8s")
OCN_COMMON=("show version" "show interface brief" "show ip interface brief" "show lldp neighbors brief" "show ip bgp summary" "show ip bgp neighbors" "show ip bgp" "show ip route" "show ip route summary"
 "show bfd session" "show bfd session detail" "show arp" "show interface" "show running-config bgp" "show route-map" "show running-config prefix-list" "show running-config")
OCN_LEAF=("show vlan brief" "show bridge" "show spanning-tree" "show mac address-table bridge 1" "show running-config qos" "show class-map" "show policy-map" "show priority-flow-control details bridge 1" "show priority-flow-control statistics bridge 1")
HOST_CMDS=("hostname; uname -r; uptime" "ip -br link" "ip -br addr" "ip route show" "ip rule show; ip route show table 100; for t in 300 301 302 303 304 305 306 307; do ip route show table \$t 2>/dev/null | sed \"s/^/table \$t: /\"; done" "ip neigh show"
 "cat /proc/net/bonding/bond0 2>/dev/null || echo no bond0 on this node" "ip -d link show bond0 | head -3" "cat /etc/resolv.conf; grep -v ^# /etc/hosts" "sysctl net.ipv4.ip_forward net.ipv4.conf.all.rp_filter"
 "systemctl is-active kubelet containerd iscsid flashblade-api 2>/dev/null | tr \"\\n\" \" \"; echo" "iscsiadm -m session 2>/dev/null; ls /dev/longhorn 2>/dev/null; df -h /var/lib/longhorn 2>/dev/null"
 "ip -br addr | grep -E ^gpu[0-7]; for r in 0 1 2 3 4 5 6 7; do ethtool -i gpu\$r 2>/dev/null | head -1; done" "rdma link show 2>/dev/null; rdma res show qp 2>/dev/null | grep \"type GSI\"; lsmod | grep -E \"^(rdma_rxe|mlx5_core|ib_uverbs|rdma_ucm) \" || true; ls /dev/infiniband 2>/dev/null | xargs echo" "grep -v -E TOKEN\\|CERT_KEY /etc/ai-fabric/node.env 2>/dev/null" "tail -20 /var/log/ai-fabric-bootstrap.log 2>/dev/null" "journalctl -p warning -n 40 --no-pager 2>/dev/null | cut -c1-240" "ss -ltn | grep :443 || echo nothing listens on :443 here" "timedatectl show -p NTPSynchronized 2>/dev/null; chronyc sources 2>/dev/null | tail -3; true")
K8S_CMDS=("kubectl get nodes -o wide" "kubectl get nodes -L node-role.ai-fabric.lab/gpu,node-role.ai-fabric.lab/storage,node-role.ai-fabric.lab/ingress,node-role.ai-fabric.lab/control" "kubectl get pods -A -o wide" "kubectl get svc -A" "kubectl -n gateway get gateway -o wide" "kubectl get httproute -A"
 "kubectl -n kube-system get lease" "kubectl get ciliumloadbalancerippools,ciliuml2announcementpolicies -A -o yaml" "kubectl -n kube-system exec ds/cilium -- cilium status 2>/dev/null"
 "kubectl get network-attachment-definitions -A -o wide; for n in default/net-rail-0 gpu/rail-1; do kubectl -n \${n%/*} get net-attach-def \${n#*/} -o jsonpath='{.spec.config}' 2>/dev/null && echo; done" "kubectl get nicclusterpolicies.mellanox.com -o yaml 2>/dev/null; kubectl get macvlannetworks.mellanox.com -o wide 2>/dev/null" "kubectl -n nvidia-network-operator get pods -o wide 2>/dev/null; helm list -A 2>/dev/null | grep -E 'network-operator|nfd'" "kubectl get nodefeaturerules 2>/dev/null; kubectl get nodes -l node-role.ai-fabric.lab/gpu=true -o custom-columns=NODE:.metadata.name,PCI15B3:.metadata.labels.feature\\.node\\.kubernetes\\.io/pci-15b3\\.present,RDMA_SHARED:.status.allocatable.rdma/rdma_shared --no-headers 2>/dev/null" "kubectl get ippools.whereabouts.cni.cncf.io -A 2>/dev/null" "kubectl -n kube-system get pods -o wide | grep -E 'multus|whereabouts'"
 "kubectl -n longhorn-system get nodes.longhorn.io,volumes.longhorn.io" "kubectl get sc; kubectl get pvc -A" "kubectl -n inference get all" "kubectl -n webui get all" "kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.devices}'; echo" "kubectl get events -A --sort-by=.lastTimestamp | tail -30" "kubectl get events -A --field-selector type=Warning"
 "kubectl -n harbor get deploy,sts,pvc,httproute 2>/dev/null" "helm -n harbor list 2>/dev/null" "kubectl -n s3 get pods,svc -o wide 2>/dev/null; kubectl -n s3 exec deploy/minio -- sh -c 'du -sh /data/*' 2>/dev/null"
 "kubectl -n longhorn-system get backuptargets.longhorn.io,backupvolumes.longhorn.io,backups.longhorn.io 2>/dev/null" "kubectl -n longhorn-system get sharemanagers.longhorn.io 2>/dev/null")
dump() { # device, role, runner, then the commands
  local n=$1 role=$2 run=$3; shift 3; local d="$OUT/$n" i=1 c f; mkdir -p "$d"; : > "$d/00_ALL_OUTPUT.txt"; echo "$role" > "$d/.role"
  for c in "$@"; do f=$(printf '%s/%02d_%s.txt' "$d" "$i" "$(slug "$c")"); { case $run in JNX) echo "admin@$n> $c";; NX) echo "$n# $c";; CVX) echo "cumulus@$n:mgmt:~\$ $c";; H) echo "admin@$n:~\$ sudo sh -c '$c'";; X) echo "root@$n:/# $c";; K) echo "admin@bastion:/workspace\$ $c";; *) echo "# $n (OcNOS CLI; the command is echoed after the prompt below)";; esac; case $run in CVX) CVX "$n" "$c";; JNX) JNX "$n" "$c";; NX) NX "$n" "$c";; OCE) OCE "$n" "$c";; H) H "$n" "$c";; X) X "$n" "$c";; K) K "$c";; esac; } > "$f" 2>&1
    { echo; cat "$f"; } >> "$d/00_ALL_OUTPUT.txt"; i=$((i + 1)); done; }
echo "audit -> $OUT"
if [ "$FE_NOS" = nxos ]; then
  for s in $FE_SPINES; do dump $s nexus-spine+rr NX "${NX_COMMON[@]}" & done
  for s in $FE_LEAVES; do dump $s nexus-leaf+vtep+vpc-fabric-peering NX "${NX_COMMON[@]}" "${NX_VTEP[@]}" "${NX_VPC[@]}" & done
  for s in $FE_BORDERS; do dump $s nexus-border+type5 NX "${NX_COMMON[@]}" "${NX_VTEP[@]}" "${NX_BORDER[@]}" & done
elif [ "$FE_NOS" = junos ]; then
  for s in $FE_SPINES; do dump $s vex-spine JNX "${JN_COMMON[@]}" & done
  for s in $FE_LEAVES; do dump $s vex-leaf+vtep+esi-lag JNX "${JN_COMMON[@]}" "${JN_VTEP[@]}" & done
  for s in $FE_BORDERS; do dump $s vex-border+type5 JNX "${JN_COMMON[@]}" "${JN_BORDER[@]}" & done
else
  for s in $FE_SPINES; do dump $s cumulus-spine CVX "${CVX_COMMON[@]}" "$(V 'show bgp l2vpn evpn summary')" & done
  for s in $FE_LEAVES; do dump $s cumulus-leaf+vtep+evpn-mh CVX "${CVX_COMMON[@]}" "${CVX_VTEP[@]}" "${CVX_MH[@]}" & done
  for s in $FE_BORDERS; do dump $s cumulus-border+vtep CVX "${CVX_COMMON[@]}" "${CVX_VTEP[@]}" "${CVX_BORDER[@]}" & done
fi
if [ "$OOB_NOS" = junos ]; then dump oob-sw vex-oob JNX "${JN_COMMON[@]}" "show ethernet-switching table" &
else dump oob-sw cumulus-oob CVX "${CVX_COMMON[@]}" "sudo /sbin/bridge fdb show | grep -v permanent" &
fi
for s in $BE_SPINES; do dump $s ocnos-spine OCE "${OCN_COMMON[@]}" & done
for s in $BE_LEAVES; do dump $s ocnos-rail-leaf OCE "${OCN_COMMON[@]}" "${OCN_LEAF[@]}" & done
wait
if is_full; then for v in $CTRLS storage $GPUS; do dump $v host H "${HOST_CMDS[@]}" & done; else for v in $CTRLS storage $GPUS; do dump $v host-light X "${HOST_CMDS[@]}" & done; fi
for h in bastion pc-1 pc-2; do dump $h container X "${HOST_CMDS[@]}" & done; wait
is_full && dump kubernetes cluster K "${K8S_CMDS[@]}"
d="$OUT/fw"; mkdir -p "$d"; echo firewall > "$d/.role"; i=1
FW_CMDS=("show system info" "show interface all" "show interface logical" "show routing route" "show routing protocol bgp summary" "show routing protocol bgp peer" "show routing protocol bgp loc-rib"
 "show routing protocol bgp rib-out" "show arp all" "show running security-policy" "show running nat-policy" "show session info" "show session all" "show counter global filter severity drop"
 "show system setting jumbo-frame" "show high-availability state" "show jobs all" "show log traffic direction equal backward receive_time in last-hour" "show log system direction equal backward receive_time in last-24-hrs"
 "show log config direction equal backward receive_time in last-30-days" "show log threat direction equal backward receive_time in last-24-hrs")      # logs always with a time filter: an unfiltered "show log" walks the whole log and blocks the firewall's CLI for minutes
if fw_cli_ok; then
  for c in "${FW_CMDS[@]}"; do f=$(printf '%s/%02d_%s.txt' "$d" "$i" "$(slug "$c")"); { echo "admin@ai-fabric-fw> $c"; _pancli_raw "$c" | head -4000; } > "$f"; i=$((i + 1)); done
  f=$(printf '%s/%02d_running-config_set-format.txt' "$d" "$i"); i=$((i + 1))
  { echo "admin@ai-fabric-fw> set cli config-output-format set ; configure ; show      (the running configuration as set commands; password hashes and private keys are <hidden>)"; _panset_raw; } > "$f"
else echo "live firewall state not collected: the firewall's CLI does not accept the launcher credentials (the admin password was changed): export FW_PASS=<password> (and FW_USER) before running audit.sh" > "$d/01_live-state-SKIPPED.txt"; i=2; fi
BV=$(printf '%s/%02d_border-leaf-view.txt' "$d" "$i")
{ echo "# fw (as seen from the border leaves)"; for b in $FE_BORDERS; do echo "== $b"; case $FE_NOS in
    nxos) NX $b "show bgp vrf k8s ipv4 unicast summary" | tail -4; NX $b "show ip route vrf k8s" | grep -E -A1 '^(0\.0\.0\.0/0|10\.66\.|10\.1\.2\.)';;
    junos) JNX $b "show bgp summary instance k8s" | tail -4; JNX $b "show route table k8s.inet.0 0.0.0.0/0 exact";;
    *) CVX $b "sudo vtysh -c 'show bgp vrf k8s ipv4 unicast summary' | tail -4; ip route show vrf k8s | grep -E '^default|10.66|10.1.2'";; esac; done; } > "$BV"
: > "$d/00_ALL_OUTPUT.txt"; for f in "$d"/[0-9][0-9]_*; do case "$f" in */00_ALL_OUTPUT.txt) ;; *) { echo; cat "$f"; } >> "$d/00_ALL_OUTPUT.txt";; esac; done
cat "$OUT"/*/00_ALL_OUTPUT.txt > "$OUT/ALL_DEVICES_OUTPUT.txt"
S="$OUT/summary.txt"; { echo "ai-fabric audit $TS ($(is_full && echo full lab || echo light lab))"; echo
if [ "$FE_NOS" = nxos ]; then echo "== frontend (Cisco Nexus 9300v: OSPF unnumbered, iBGP EVPN, vPC fabric peering)"
  for s in $FE_SPINES $FE_LEAVES $FE_BORDERS; do d="$OUT/$s"; printf "  %-15s %-38s ospf full: %-3s evpn peers up: %-3s" "$s" "($(cat $d/.role))" \
    "$(grep -c FULL "$d"/*_show_ip_ospf_neighbors.txt)" "$(awk '/^Neighbor/ {t++} t == 1 && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $10 ~ /^[0-9]+$/' "$d"/*_show_bgp_l2vpn_evpn_summary.txt | wc -l)"
    ls "$d"/*_show_vpc.txt >/dev/null 2>&1 && printf " vpc: %s, virtual peer-link %s, vPCs up: %s" "$(grep -c 'peer adjacency formed ok' "$d"/*_show_vpc.txt | sed 's/1/formed/; s/^0$/NOT formed/')" \
      "$(grep -oE 'Virtual-peerlink mode *: [A-Za-z]+' "$d"/*_show_vpc.txt | awk '{print $NF}')" "$(awk '$1 ~ /^[0-9]+$/ && $2 ~ /^Po[0-9]+$/ && $3 == "up"' "$d"/*_show_vpc.txt | wc -l)"
    ls "$d"/*_vrf_k8s_ipv4_unicast_summary.txt >/dev/null 2>&1 && printf " fw eBGP: %s" "$(awk '$1 ~ /^10\.1\.254\./ {print $1, "pfx", $10}' "$d"/*_vrf_k8s_ipv4_unicast_summary.txt | head -1)"; echo; done
elif [ "$FE_NOS" = junos ]; then echo "== frontend (Juniper vEX, vJunos-switch)"
  for s in $FE_SPINES $FE_LEAVES $FE_BORDERS; do d="$OUT/$s"; printf "  %-15s %-26s evpn sessions: %-3s underlay sessions: %-3s bfd up: %-3s" "$s" "($(cat $d/.role))" \
    "$(grep -cE '^10\.0\.0\.[0-9]+ .* Establ' "$d"/*_show_bgp_summary.txt)" "$(grep -cE '^fe80:.* Establ' "$d"/*_show_bgp_summary.txt)" "$(grep -cE ' Up +ge-' "$d"/*_show_bfd_session.txt)"
    ls "$d"/*show_lacp_interfaces.txt >/dev/null 2>&1 && printf " lacp links up: %-3s" "$(grep -c 'Collecting distributing' "$d"/*show_lacp_interfaces.txt)"
    ls "$d"/*summary_instance_k8s.txt >/dev/null 2>&1 && printf " fw eBGP: %s" "$(grep -E '^10\.1\.254\.' "$d"/*summary_instance_k8s.txt | awk '{print $1, $NF}' | head -1)"; echo; done
else
echo "== frontend (Cumulus VX)"
for s in $FE_SPINES $FE_LEAVES $FE_BORDERS; do d="$OUT/$s"; e=$(grep -cE "^fe-[a-z0-9-]+\(swp[0-9]+\) .* [0-9]+ +[0-9]+ +N/A" "$d"/*show_bgp_l2vpn_evpn_summary*.txt 2>/dev/null | head -1)
  printf "  %-15s %-28s evpn peers up: %-3s" "$s" "($(cat $d/.role))" "${e:-0}"
  ls "$d"/*show_evpn_es_.txt >/dev/null 2>&1 && printf " local ES: %-3s bonds up: %-3s" "$(grep -cE '^03:.* [A-Z]*L[A-Z]* +bond' "$d"/*_show_evpn_es_.txt)" "$(grep -c 'MII Status: up' "$d"/*proc_net_bonding*.txt | awk '{print int($1/1)}')"
  ls "$d"/*vrf_k8s_ipv4_unicast_summary*.txt >/dev/null 2>&1 && printf " fw eBGP: %s" "$(grep -E '^10\.1\.254\.' "$d"/*vrf_k8s_ipv4_unicast_summary*.txt | awk '{print $1, "pfx", $(NF-2)}' | head -1)"; echo; done
fi
echo; echo "== backend (OcNOS SP VM)"
for s in $BE_SPINES $BE_LEAVES; do d="$OUT/$s"; printf "  %-10s %-17s AS %-6s bgp established: %-3s bfd up: %-3s 4-way ecmp routes: %-3s\n" "$s" "($(cat $d/.role))" "$(grep -m1 -oE 'local AS number [0-9]+' "$d"/*show_ip_bgp_summary.txt | awk '{print $NF}')" \
  "$(awk '/Established sessions/ {print $NF}' "$d"/*show_ip_bgp_summary.txt | head -1)" "$(grep -cE 'Single-Hop +Up' "$d"/*_show_bfd_session.txt)" "$(case $s in be-spine*) echo "n/a (every rail is one hop away)";; *) awk '/routes with +4 +ECMP paths/ {print $NF}' "$d"/*show_ip_route_summary.txt | head -1;; esac)"; done
echo; echo "== firewall (PAN-OS, read over its CLI)"; d="$OUT/fw"
if ls "$d"/*_show_system_info.txt >/dev/null 2>&1; then printf "  %-10s %s, PAN-OS %s, up %s; bgp peers established: %s; security rules: %s, nat rules: %s; running config: %s set commands; traffic log entries in the last hour: %s\n" "fw" \
    "$(awk '/^hostname:/ {print $2}' "$d"/*_show_system_info.txt)" "$(awk '/^sw-version:/ {print $2}' "$d"/*_show_system_info.txt)" "$(sed -n 's/^uptime: //p' "$d"/*_show_system_info.txt)" \
    "$(grep -c 'Established' "$d"/*_show_routing_protocol_bgp_summary.txt)" "$(grep -c '^set rulebase security rules [^ ]* action ' "$d"/*_running-config_set-format.txt)" \
    "$(grep -oE '^set rulebase nat rules [^ ]+' "$d"/*_running-config_set-format.txt | sort -u | wc -l)" "$(grep -c '^set ' "$d"/*_running-config_set-format.txt)" "$(grep -cE '^[0-9]{4}/[0-9]{2}/[0-9]{2}' "$d"/*_show_log_traffic_direction_equal_backward*.txt)"
else echo "  fw         live state not collected (see fw/01_live-state-SKIPPED.txt)"; fi
echo; echo "== hosts"; for h in $CTRLS storage $GPUS bastion; do d="$OUT/$h"; printf "  %-9s bond0: %-4s members: %-2s frontend: %-16s rails: %s\n" "$h" "$(grep -m1 'MII Status' "$d"/*cat_proc_net_bonding_bond0.txt | awk '{print $3}')" "$(grep -c 'Slave Interface' "$d"/*cat_proc_net_bonding_bond0.txt)" \
  "$(grep -hoE '10\.1\.1\.[0-9]+/24' "$d"/*_ip_-br_addr.txt | head -1)" "$(grep -hcE '^gpu[0-7] +UP' "$d"/*_ip_-br_addr.txt)"; done
if is_full; then echo; echo "== kubernetes"; grep -hE " Ready | NotReady " "$OUT/kubernetes"/*_kubectl_get_nodes_-o_wide.txt | awk '{print "  "$1, $2, $3, $6}'
  echo "  non-running pods: $(grep -hvcE 'Running|Completed|NAME|^#' "$OUT/kubernetes"/*_kubectl_get_pods_-A_-o_wide.txt)"; grep -h "gateway" "$OUT/kubernetes"/*_kubectl_-n_gateway_get_gateway_-o_wide.txt | tail -1 | sed 's/^/  /'
  echo; echo "== published URLs (office LAN: through the firewall -- route 10.1.1.0/24 via 10.80.15.121, DNS 10.1.1.17; or DNAT https://<name> -> 10.80.15.121)"; grep -hoE '[a-z]+\.platform\.lab\.ai' "$OUT/kubernetes"/*_kubectl_get_httproute_-A.txt | sort -u | sed 's|^|  https://|; s|$|/|'; fi
} > "$S"
echo "summary:"; cat "$S"; echo; echo "files: $(find "$OUT" -type f | wc -l), $(du -sh "$OUT" | cut -f1)"
keep_latest ai-fabric_audit "$OUT"
