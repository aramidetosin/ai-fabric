#!/usr/bin/env python3
"""ai-fabric: an AI cluster with a Cumulus frontend fabric and an OcNOS rail-optimised backend fabric, as a containerlab lab.

Structure follows <reference-platform>/gen.py (parameters -> NOS config builders -> firewall XML -> topology).

FRONTEND (Cumulus VX, conventions from /root/reflab-containerlab): 2 spines, 3 leaf pairs (GPU-compute, storage, control/bastion)
  plus a border pair for the firewall. EVPN-VXLAN, EVPN multihoming (ESI-LAG, no peer-links), eBGP unnumbered underlay.
  One flat VLAN with the AI_FABRIC Cluster-1 100G values: VLAN/VNI 10 DATA, 10.1.1.0/24, anycast gateway 10.1.1.1
  (MAC 000a.00c1.0001), VRF k8s with L3 VNI 1000, route-targets 10:10 / 1000:1000.
BACKEND (OcNOS SP VM 7.0.0-262, mirrors AI_FABRIC Cluster-1 800G AI): 4 spines, 8 rail leaves. GPU NIC N of every server lands on
  leaf N. Rail N = VLAN N*10, 172.16.N.0/24, gateway .1 on SVI vlan1.<N*10>, GPU ports access. Pure L3, redistribute connected.
  BGP is eBGP leaf-spine here (production: iBGP AS 1 + spine route reflectors over unnumbered) -- the only way to get 4-way ECMP on
  the OcNOS VM; see be_bgp().
HOSTS (refplat-style VM nodes, full refplat stack): 8 GPU nodes (2 frontend NICs in bond0 + 8 REAL rail NICs), 3 control nodes,
  1 storage node (8 NICs, one ESI bond, tagged-only trunk, address on bond0.10), 1 bastion (DNS + NTP), OOB/BMC network,
  Palo Alto firewall behind a border leaf pair, two external PCs.

Values marked LAB are lab-only choices that no reference defines; everything else comes from the user or a reference.
Generated: ai-fabric.clab.yml, configs/<switch>.cfg, bootstrap/fw.xml, mgmt-hosts.txt. Edit this file, not the outputs.
"""
import os, re, textwrap
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.abspath(__file__))

def _env(name, default=None):
    """Environment value, treating an EMPTY variable as unset. .env.example ships blank values for
    everything optional, and `set -a; . ./.env` exports those as empty strings -- which would beat
    every default below and generate a topology pointing at "" instead of the documented fallback."""
    v = os.environ.get(name, "")
    return v if v.strip() else default

# One generator, one profile per host. `profile` (a one-line file next to gen.py) or $AI_FABRIC_PROFILE selects it; default = site-a.
#   site-a  the lab as first built: Cumulus VX frontend, 3 control + 8 GPU nodes, one GPU leaf pair
#   site-b    operator decisions 2026-09-18: Juniper vEX (vJunos-switch) frontend, 6 control nodes (ctrl1-3 control plane, ctrl4-6
#               workers), 32 GPU nodes on TWO GPU leaf pairs at 3 GB / 2 vCPU each (32 x 6 GB does not fit in 314 GB next to 184 GB of
#               switches, firewall, control and storage; a GPU node was measured at 1.0 GB in use), firewall outside
#               192.168.1.250 on the home LAN, registry pull-through cache on the management gateway. The OOB switch is a vEX too:
#               the Cumulus VX image has 16 data ports and this lab needs 25.
PROFILES = {
    # 32 GPU nodes at 3 GB: 6 GB x 32 = 192 GB does NOT fit beside this host's other VMs (winserver alone is 64 GB) -- measured 2026-09-20,
    # the host OOM-killed winserver 14 times before the guests were stopped. 3 GB / 2 vCPU is what site-b runs the same 32-node workload on.
    # 6 control nodes like site-b: ctrl1-3 are the control plane, ctrl4-6 join as workers and carry Harbor / cert-manager / inference / Headlamp.
    # That pushes ctrl4-6 onto 10.1.1.14-.16, so the storage node moves to .18 (and its management address to .118), exactly as on site-b.
    "site-a": dict(fe_nos="cumulus", n_ctrl=6, n_gpu=32, gpu_pairs=4, gpu_mem=3072, gpu_cpus=2, pc_mgmt=(161, 162), storage_ip="10.1.1.18", storage_mgmt=118,
                       fw_e5="10.80.15.121/24", fw_e5_gw="10.80.15.1", mirrors="", services="harbor", fw_ui="", eve_cloud="",
                       # 32 GPU nodes on Cumulus VX (16 data ports: 2 uplinks + at most 14 servers) => FOUR GPU leaf pairs of 8, and the OOB
                       # switch must be a vEX: every server has a BMC, so it needs 38 ports (32 GPU + 3 ctrl + bastion + storage + firewall).
                       oob_nos="vex",
                       # Reverse DNS for the office LAN, so the firewall's traffic log names these instead of printing 10.80.15.x. The
                       # bastion becomes authoritative for the /24, so any office address NOT listed here answers NXDOMAIN to the lab's
                       # resolver clients -- drop lan_ptrs if the office DNS ever needs to answer for that subnet instead.
                       lan_cidr="10.80.15.0/24",
                       lan_ptrs="10.80.15.121=fw-outside 10.80.15.10=site-a 10.80.15.103=ubuntu-desktop "
                                "10.80.15.100=winserver-rev3 10.80.15.1=office-gw"),
    "site-b":   dict(fe_nos="vex", n_ctrl=6, n_gpu=32, gpu_pairs=2, gpu_mem=3072, gpu_cpus=2, pc_mgmt=(161, 162),      # GPU nodes use mgmt .121-.152
                       storage_ip="10.1.1.18", storage_mgmt=118,                                                     # LAB: .16 is ctrl6 here
                       fw_e5="192.168.1.250/24", fw_e5_gw="192.168.1.1",
                       mirrors="docker.io=http://172.21.21.1:5005 quay.io=http://172.21.21.1:5002 ghcr.io=http://172.21.21.1:5003 registry.k8s.io=http://172.21.21.1:5004",
                       services="harbor",
                       # firewall web UI without a tunnel: https://<outside address>:8443/ = DNAT to a loopback that carries an HTTPS management
                       # profile (the management NIC 172.21.21.30 is only routed on the lab host). LAB loopback address; clients limited to the LAN.
                       fw_ui=dict(port=8443, loopback="10.1.254.254", permit="192.168.1.0/24"),
                       # EVE-NG cloud joined to the lab's management network (eve-cloud.sh): EVE nodes (an NMS or controller VM,
                       # eth1, 172.21.21.60) then reach every switch's management address, the way Nexus Dashboard reached its containerlab fabric
                       eve_cloud="pnet5", oob_nos=""),      # finish.sh: Harbor + S3 + Longhorn backup target (runs on the worker-role control nodes ctrl4-6)
}
# site-a-nx (operator decisions 2026-09-23, "swap the Cumulus frontend for Cisco Nexus with vPC over fabric"): the same lab with a Cisco Nexus
# 9300v frontend (the release vpcfp proved vPC Fabric Peering on). 2 spines (64-port) + 6 leaves (32-port): TWO GPU leaf pairs of 16
# nodes and ONE control pair that carries ctrl1-6, the bastion AND the storage node (no separate storage pair), plus a separate border pair for the
# firewall (no vPC there: routed /30s as today). vPC FABRIC PEERING on the three pairs (virtual peer-link over the spines, no leaf-to-leaf cabling).
# Underlay OSPF area 0 over IP UNNUMBERED links, one link per spine; overlay iBGP EVPN in a private AS with the spines as route reflectors.
# The OOB/BMC switch stays a vEX. Proven beforehand on the nxprobe lab (containerlab/ai-fabric-nx-probe, evidence/).
PROFILES["site-a-nx"] = dict(PROFILES["site-a"], fe_nos="nxos", gpu_pairs=2, stor_pair=False, lab_ca=True,
                                 # frontend redesign (operator decisions 2026-09-23): VLAN 100 data/k8s/storage, VLAN 200 storage management, VLAN 300
                                 # bastion, each its own VRF with the anycast gateway on the fabric; every inter-VLAN flow crosses the firewall. DNS + NTP
                                 # for nodes, firewall and switches = the office server dns-b (the bastion keeps its other roles).
                                 vlans=True, dns_ntp="10.80.15.53",
                                 # + the production GPU cluster's NVIDIA network-operator stack on the simulated GPU nodes (operator decisions 2026-09-24)
                                 services="harbor network-operator",
                                 # live changes folded in before the 2026-09-28 power-off (a redeploy must reproduce the running lab):
                                 #  ndfc: the lines Nexus Dashboard / NDFC pushed to the 10 N9Kv on 2026-09-26 (fabric Site-4-frontend) + its telemetry
                                 #  hardening: Weft changes of 2026-09-25 -- NX-OS `no feature telnet` (vrnetlab types `feature telnet` before our config)
                                 #             and oob-sw `ssh root-login deny` (vrnetlab's vJunos init.conf sets allow)
                                 ndfc=True, hardening=True)
# site-b-nx (operator decisions 2026-10-01, "move the ai-fabric lab to site-b", with the office topology pasted as "this one"): the Nexus design EXACTLY as
# site-a-nx runs it -- 10 N9Kv with vPC fabric peering, VLAN 100/200/300 in their own VRFs through the firewall, lab CA, network-operator, the NDFC-pushed
# lines, 6 control + 32 GPU nodes at 3 GB -- on the home server. Only what the host forces differs:
#   firewall outside   192.168.1.250 on the home LAN (pnet0), gateway 192.168.1.1; its web UI published on that address (:8443), as the site-b profile
#   DNS + NTP          dns-a (192.168.1.53), the home counterpart of dns-b; the lab's zones are published there (DNS_B=dns-a ./dns-b-zones.sh site-b-nx)
#   lab CA             the SAME root; the two intermediates of site-a copied into the host-only ca/ (the workstations already trust the root)
#   images             through the host's pull-through registry caches (and Harbor's proxy caches once it is up)
#   EVE cloud          pnet5 joined to the management network (for an NMS or controller VM), as the site-b profile
#   reverse DNS        the home LAN stays with dns-a (no lan_ptrs)
# The host needs KSM on (host/ksm-install.sh): 335 GB are declared on 314 GB of RAM; site-a saves ~96 GB the same way.
PROFILES["site-b-nx"] = dict(PROFILES["site-a-nx"], fw_e5="192.168.1.250/24", fw_e5_gw="192.168.1.1", dns_ntp="192.168.1.53",
                               mirrors=PROFILES["site-b"]["mirrors"], fw_ui=PROFILES["site-b"]["fw_ui"], eve_cloud=PROFILES["site-b"]["eve_cloud"],
                               lan_cidr="192.168.1.0/24", lan_ptrs="",
                               # NX-OS user `ops` = the lab host's own root key (lib.sh NX()); found by the pre-flight 2026-10-01: with the office host's
                               # key every script on site-b would have been refused by all 10 Nexus switches
                               host_key="root@site-b",
                               # staggered cold start of the switch VMs (see topology()): this host cannot boot all 23 at once
                               boot_stagger=dict(ocnos=20, nxos_first=240, nxos=60),
                               # the PA-VM launcher deadlocked on a split login prompt in two deploys in a row on this host: up.sh builds the
                               # derived image with the console fix (host/pa-vm-console-fix.sh, reproduced and proven by a test there)
                               pa_console_fix=True)
def _profile():
    n = _env("AI_FABRIC_PROFILE")
    if not n and os.path.exists(os.path.join(ROOT, "profile")): n = open(os.path.join(ROOT, "profile")).read().strip()
    return n or "site-a"
PROFILE = _profile(); PF = PROFILES[PROFILE]; VEX = PF["fe_nos"] == "vex"; NXOS = PF["fe_nos"] == "nxos"
STOR_PAIR = PF.get("stor_pair", True)                   # False: the storage node sits on the control pair (site-a-nx)
VEX_IMAGE = _env("VEX_IMAGE", "SET_IN_ENV/vjunos-switch:TAG")  # vJunos-switch = Juniper vEX; 57 data ports in vrnetlab, 5 GB / 4 vCPU each
CVX_IMAGE = _env("CVX_IMAGE", "SET_IN_ENV/cumulus-vx:TAG")        # the tag reflab proved EVPN-MH on; launcher applies /config/startup-config.cfg
OCNOS_IMAGE = _env("OCNOS_IMAGE", "SET_IN_ENV/ocnos:TAG")
PAN_IMAGE = _env("PAN_IMAGE", "SET_IN_ENV/pa-vm:TAG")
VM_IMAGE = "ai-fabric-vm-node:latest"                        # refplat vm-node + real rail NICs (images/vm-node)
BASTION_IMAGE = "ai-fabric-bastion:latest"                   # refplat bastion + parameterised chrony allow (images/bastion)
PC_IMAGE = "ghcr.io/srl-labs/network-multitool"
BASE_IMG_DIR = os.path.join(ROOT, "images/vm-node/base")      # Ubuntu 24.04 cloud image shared with refplat (read-only bind)
LAB = "ai-fabric"
MGMT_NET, MGMT_SUBNET, M = "ai-fabric-mgmt", "172.21.21.0/24", "172.21.21"     # refplat's management subnet on purpose: this host does not
# masquerade docker networks by itself; the operator keeps a host NAT rule per lab subnet (172.21.21.0/24 -> pnet0 exists). A new subnet
# would leave the guests without internet during cloud-init. ai-fabric and refplat cannot run together anyway (same firewall outside address).
EXT_BRIDGE = "pnet0"                                    # eve's office-LAN bridge: firewall outside interface, as refplat

def operator_keys():
    try: return [l.strip() for l in open(os.path.join(ROOT, "common", "authorized_keys")) if l.strip() and not l.startswith("#")]
    except OSError: return []

# ---------------------------------------------------------------- frontend constants
FE_VLAN, FE_VNI, FE_NAME = 10, 10, "DATA"               # AI_FABRIC Cluster-1 100G: nvo vxlan id 10 / mac vrf DATA
FE_NET, FE_GW, FE_PREFIX = "10.1.1.0/24", "10.1.1.1", "24"
AGW_MAC = "00:0a:00:c1:00:01"                           # AI_FABRIC: evpn irb-forwarding anycast-gateway-mac 000a.00c1.0001
VRF, L3VNI = "k8s", 1000                                # AI_FABRIC: ip vrf k8s / l3vni 1000
L3VLAN = 3001                                           # LAB: Cumulus needs a VLAN behind the L3 VNI (reflab uses 3001)
RT_L2, RT_L3 = "10:10", "1000:1000"                     # AI_FABRIC route-targets; explicit because the leaf pairs sit in different ASNs
MULTI = bool(PF.get("vlans"))                           # site-a-nx: VLAN 100 / 200 / 300 in separate VRFs, inter-VLAN only through the firewall
if MULTI: FE_VLAN, FE_NAME, RT_L2 = 100, "DATA", "100:100"   # operator: data/k8s/storage = VLAN 100 (LAB route target follows the VLAN)
FW_ASN = 65500                                          # LAB (refplat value)
SNMP_TRAP_HOST = f"{M}.1"                                # traps go to the lab host (management gateway): site-a DNATs udp/162 to the Weft VM, site-b relays it over Tailscale with alias source addresses (host/weft-alias.nft)
SNMP_COMMUNITY = "public"                               # SNMP v2c read-only on every device (user, 2026-09-19: Weft polls with community public)
NTP_MGMT = f"{M}.117"                                   # bastion serves NTP to the switches over the management network
DNS_NTP = PF.get("dns_ntp") or ""                       # site-a-nx: office DNS + chrony server (dns-b); switches reach it over the management network, directly
if DNS_NTP: NTP_MGMT = DNS_NTP

# role, ASN, loopback, per-leaf SVI address (LAB: .2-.7), spine port. ASNs/loopbacks LAB, reflab style (a pair shares an ASN).
FE = {
    "fe-spine1":     dict(role="spine",  asn=65100, lo="10.0.0.1",  mgmt=f"{M}.11"),
    "fe-spine2":     dict(role="spine",  asn=65100, lo="10.0.0.2",  mgmt=f"{M}.12"),
    "fe-gpu-leaf1":  dict(role="leaf",   asn=65101, lo="10.0.0.11", mgmt=f"{M}.13", svi="10.1.1.2", sp=1, pair="gpu",  es="44:38:39:be:ef:01"),
    "fe-gpu-leaf2":  dict(role="leaf",   asn=65101, lo="10.0.0.12", mgmt=f"{M}.14", svi="10.1.1.3", sp=2, pair="gpu",  es="44:38:39:be:ef:01"),
    "fe-stor-leaf1": dict(role="leaf",   asn=65102, lo="10.0.0.13", mgmt=f"{M}.15", svi="10.1.1.4", sp=3, pair="stor", es="44:38:39:be:ef:02"),
    "fe-stor-leaf2": dict(role="leaf",   asn=65102, lo="10.0.0.14", mgmt=f"{M}.16", svi="10.1.1.5", sp=4, pair="stor", es="44:38:39:be:ef:02"),
    "fe-ctrl-leaf1": dict(role="leaf",   asn=65103, lo="10.0.0.15", mgmt=f"{M}.17", svi="10.1.1.6", sp=5, pair="ctrl", es="44:38:39:be:ef:03"),
    "fe-ctrl-leaf2": dict(role="leaf",   asn=65103, lo="10.0.0.16", mgmt=f"{M}.18", svi="10.1.1.7", sp=6, pair="ctrl", es="44:38:39:be:ef:03"),
    "fe-border1":    dict(role="border", asn=65104, lo="10.0.0.17", mgmt=f"{M}.19", sp=7, fw_ip="10.1.254.1/30", fw_nh="10.1.254.2"),   # LAB /30s
    "fe-border2":    dict(role="border", asn=65104, lo="10.0.0.18", mgmt=f"{M}.20", sp=8, fw_ip="10.1.254.5/30", fw_nh="10.1.254.6"),
    "oob-sw":        dict(role="oob",    mgmt=f"{M}.21"),
}
for p in range(2, PF["gpu_pairs"] + 1):   # GPU leaf pairs 2..N (LAB values continue the series)
    i = p - 2
    # SVIs: pair 2 continues .8/.9, but pairs 3+ take theirs from the TOP of the subnet -- carrying on with .10, .11 ... would land on ctrl1-3 (10.1.1.11-.13)
    svis = (8 + 2 * i, 9 + 2 * i) if p == 2 else (240 + 2 * (p - 3), 241 + 2 * (p - 3))
    for j in (0, 1):
        FE[f"fe-gpu-leaf{2 * p - 1 + j}"] = dict(role="leaf", asn=65105 + i, lo=f"10.0.0.{19 + 2 * i + j}", mgmt=f"{M}.{22 + 2 * i + j}",
                                                 svi=f"10.1.1.{svis[j]}", sp=9 + 2 * i + j, pair=f"gpu{p}", es=f"44:38:39:be:ef:{4 + i:02d}")
FE["oob-sw"] = FE.pop("oob-sw")   # keep the OOB switch last
if not STOR_PAIR:                 # storage on the control pair: no storage leaves; spine ports renumbered in pair order (GPU pairs, control, border)
    del FE["fe-stor-leaf1"], FE["fe-stor-leaf2"]
    _order = ([n for n, s in FE.items() if s.get("pair", "").startswith("gpu")] + [n for n, s in FE.items() if s.get("pair") == "ctrl"]
              + [n for n, s in FE.items() if s["role"] == "border"])
    for i, n in enumerate(_order): FE[n]["sp"] = i + 1
FE_SPINES = [n for n, s in FE.items() if s["role"] == "spine"]
FE_LEAVES = [n for n, s in FE.items() if s["role"] in ("leaf", "border")]
PAIR = {p: [n for n, s in FE.items() if s.get("pair") == p] for p in ["gpu"] + [f"gpu{i}" for i in range(2, PF["gpu_pairs"] + 1)] + (["stor"] if STOR_PAIR else []) + ["ctrl"]}
def nos(name):   # per node: a Cumulus or Nexus fabric can carry a vEX OOB switch
    if VEX or (name == "oob-sw" and PF["oob_nos"] == "vex"): return "vex"
    return "nxos" if NXOS else "cumulus"
assert not NXOS or PF["oob_nos"] == "vex", "a Nexus frontend profile keeps the vEX OOB switch (no NX-OS OOB builder)"
def fp(node, n): return f"eth{n}" if nos(node) in ("vex", "nxos") else f"swp{n}"   # containerlab endpoint of frontend/OOB port n (vEX: ethN = ge-0/0/(N-1); NX-OS: ethN = Ethernet1/N)
def ge(n): return f"ge-0/0/{n - 1}"

# ---------------------------------------------------------------- backend constants (AI_FABRIC Cluster-1 800G AI)
RAILS, BE_NSPINES = 8, 4
BE_SPINE_ASN, BE_LEAF_ASN = 65200, 65200                # LAB: eBGP -- spines share 65200, rail leaf L = 65200 + L (production: iBGP AS 1, see be_bgp)
RAIL_PREFIX = "172.16"                                  # rail N = 172.16.N.0/24, gateway .1 on vlan1.<N*10>
BE_P2P = "10.255"                                       # LAB: numbered /31 underlay 10.255.<spine>.x -- BGP unnumbered never leaves Idle on the OcNOS VM
BE_MTU = 9198                                           # production 9216; the VM accepts at most 9198 and rejects per-SVI mtu
BE = {}
for s in range(1, BE_NSPINES + 1): BE[f"be-spine{s}"] = dict(role="spine", idx=s, lo=f"192.168.100.{s}", mgmt=f"{M}.{40 + s}")
for l in range(1, RAILS + 1):      BE[f"be-leaf{l}"]  = dict(role="leaf",  idx=l, lo=f"192.168.1.{l}",   mgmt=f"{M}.{50 + l}")
def p2p(s, l): return f"{BE_P2P}.{s}.{2 * (l - 1)}", f"{BE_P2P}.{s}.{2 * (l - 1) + 1}"      # (spine side, leaf side)

# ---------------------------------------------------------------- hosts
DOMAIN, CLUSTER = "lab.ai", "ai-fabric"
# Gateway VIP + LB pool live at the TOP of the /24 (operator decision 2026-09-18, "fix that"): the node scheme gpu n = 10.1.1.(20+n) reaches
# .52 at 32 nodes and would have collided with the earlier .30 / .30-.39. A running lab keeps its deployed values until redeployed.
API_VIP, GW_VIP, LB_START, LB_END = "10.1.1.20", "10.1.1.200", "10.1.1.200", "10.1.1.209"
BASTION_IP = "10.1.30.17" if MULTI else "10.1.1.17"       # site-a-nx: VLAN 300 (keeps the .17 host octet)
OOB_NET, OOB_PREFIX, OOB_GW = "10.1.2.0/24", "24", "10.1.2.254"          # LAB: OOB/BMC subnet, gateway on the firewall
def oob(ip): return "10.1.2." + ip.split(".")[3]                         # LAB: BMC address mirrors the host octet
HOSTS = {}   # name = clab node = hostname = k8s node name
N_CTRL, N_GPU = PF["n_ctrl"], PF["n_gpu"]; GPU_PER_PAIR = N_GPU // PF["gpu_pairs"]
for i in range(1, N_CTRL + 1):    # ctrl1-3 = Kubernetes control plane (etcd quorum of 3); any further control node joins as a worker
    HOSTS[f"ctrl{i}"] = dict(ip=f"10.1.1.{10 + i}", role="init" if i == 1 else ("join-cp" if i <= 3 else "join-worker"), pair="ctrl", port=2 + i, bond=i,
                             mgmt=f"{M}.{110 + i}", mem=8192, cpus=4)
for n in range(1, N_GPU + 1):     # GPU node n sits on GPU leaf pair 1 or 2; port/bond number = its position inside that pair
    k = (n - 1) % GPU_PER_PAIR + 1; pi = (n - 1) // GPU_PER_PAIR + 1
    HOSTS[f"gpu{n}"] = dict(ip=f"10.1.1.{20 + n}", role="join-worker", kind="gpu", rail=10 + n, n=n, pair="gpu" if pi == 1 else f"gpu{pi}", port=2 + k, bond=k,
                            mgmt=f"{M}.{120 + n}", mem=PF["gpu_mem"], cpus=PF["gpu_cpus"])
HOSTS["storage"] = dict(ip=PF["storage_ip"], role="join-worker", kind="storage", pair="stor", members=(3, 4, 5, 6), bond=1, tagged=True, fabric_nics=8,
                        mgmt=f"{M}.{PF['storage_mgmt']}", mem=6144, cpus=4)   # 8 links = ports 3-6 on each storage leaf, one ESI bond, trunk, VLAN 10 tagged, address on bond0.10
if not STOR_PAIR:   # on the control pair, after ctrl1-N (ports 3..) and the bastion: the next four ports on each leaf, bond/vPC number after the bastion's
    HOSTS["storage"].update(pair="ctrl", members=tuple(range(N_CTRL + 4, N_CTRL + 8)), bond=N_CTRL + 2)
BASTION = dict(name="bastion", pair="ctrl", port=2 + N_CTRL + 1, bond=N_CTRL + 1, mgmt=f"{M}.117")
OOB_PORTS = {**{f"gpu{n}": n for n in range(1, N_GPU + 1)}, **{f"ctrl{i}": N_GPU + i for i in range(1, N_CTRL + 1)},
             "bastion": N_GPU + N_CTRL + 1, "storage": N_GPU + N_CTRL + 2}; OOB_FW_PORT = N_GPU + N_CTRL + 3
# site-a-nx: the storage management interface moves from the OOB switch onto the control leaf pair, VLAN 200: two unbonded links, FlashBlade style
# (FM1 on one leaf, FM2 on the other) with a floating management VIP that the storage management API listens on. Port = after the storage data links.
STOR_MGMT = dict(vlan=200, fm=("10.1.20.11", "10.1.20.12"), vip="10.1.20.18", gw="10.1.20.1", prefix="24", port=N_CTRL + 8) if MULTI else None   # LAB addresses
FB_API = STOR_MGMT["vip"] if MULTI else oob(HOSTS["storage"]["ip"])   # where the storage management API answers
PC1 = dict(name="pc-1", ip="10.66.10.10", prefix="24", gw="10.66.10.1", mgmt=f"{M}.{PF['pc_mgmt'][0]}")     # LAB: enterprise side of the firewall (refplat's PC-2 subnet)
PC2 = dict(name="pc-2", ip="10.66.20.10", prefix="24", gw="10.66.20.1", mgmt=f"{M}.{PF['pc_mgmt'][1]}")     # LAB: second enterprise subnet
FW = dict(name="fw", hostname="ai-fabric-fw", mgmt=f"{M}.30", e1="10.1.254.2/30", e2="10.1.254.6/30", e3=OOB_GW + "/24", e4="10.66.10.1/24",
          e5=PF["fw_e5"], e5_gw=PF["fw_e5_gw"],              # outside address on the host's LAN bridge (per profile); internet egress + source NAT
          e6="10.66.20.1/24")
# ---------------------------------------------------------------- lab CA (site-a-nx, operator decisions 2026-09-23): root "ai-fabric Lab Root CA" on dns-b
# (signs rarely, from the Mac: dns-b-ca.sh), two intermediates whose keys live in the HOST-ONLY directory ca/ (never in shared/, which every guest mounts):
#   platform   -> cert-manager ClusterIssuer cluster-ca (wildcard, storage API, firewall UI)
#   kubernetes -> kubeadm /etc/kubernetes/pki/ca.{crt,key} on the init node, pre-placed before kubeadm init
# Both are name-constrained: the root is trusted by the office workstations, so neither key may mint a trusted certificate for an arbitrary site.
LAB_CA = bool(PF.get("lab_ca"))
CA_DIR = "ca"
CA_ROOT_SUBJ = "/O=ai-fabric lab/CN=ai-fabric Lab Root CA"
CA_INTERMEDIATES = dict(
    platform=dict(subj="/O=ai-fabric lab/CN=ai-fabric Platform CA", key="EC P-256",
                  nc=f"permitted;DNS:{DOMAIN},permitted;IP:10.1.0.0/255.255.0.0,permitted;IP:{MGMT_SUBNET.split('/')[0]}/255.255.255.0"),
    kubernetes=dict(subj="/O=ai-fabric lab/CN=ai-fabric Kubernetes CA", key="RSA 2048",
                    nc=",".join([f"permitted;DNS:{d}" for d in (DOMAIN, "kubernetes", "kubernetes.default", "kubernetes.default.svc", "cluster.local")]
                                + [f"permitted;DNS:{n}" for n, h in HOSTS.items() if h["role"] in ("init", "join-cp")] + ["permitted;IP:10.0.0.0/255.0.0.0"])))
# ---------------------------------------------------------------- NVIDIA network-operator (site-a-nx, operator decisions 2026-09-24): the production
# GPU cluster's stack on the simulated GPU nodes. Mirrors production: chart/operator v26.1.1 in namespace nvidia-network-operator, MacvlanNetwork
# net-rail-N with its NAD in namespace default, NicClusterPolicy with production's nodeAffinity verbatim, rdma-shared-dev-plugin (rdma_shared, 63 HCAs),
# NFD as a SEPARATE release. Lab deviations, forced by virtio NICs: no ofedDriver; plugin selector = the rail NICs by name (no 15b3 vendor); RDMA devices =
# SoftRoCE (rdma_rxe on each gpuN, netsetup.sh); the pci-15b3 label is faked by a NodeFeatureRule; rail subnets 172.16.x; IPAM also excludes the node
# rail addresses (.0/26). Production shape = no routes: a pod's rail interface reaches only its own rail. Replaces the bootstrap's gpu/rail-1..8 NADs.
NETOP = dict(chart="26.1.1", ns="nvidia-network-operator", repo="https://helm.ngc.nvidia.com/nvidia",
             nfd_chart="0.18.3", nfd_ns="node-feature-discovery", nfd_repo="https://kubernetes-sigs.github.io/node-feature-discovery/charts",
             rdma_repo="nvcr.io/nvidia/mellanox", rdma_version="network-operator-v26.1.1") if "network-operator" in PF["services"].split() else None
def netop_manifests():
    import json
    ngpu = sum(1 for h in HOSTS.values() if h.get("kind") == "gpu"); assert 10 + ngpu < 64, "node rail addresses must stay inside the excluded .0/26"
    nets = [(r, f"{RAIL_PREFIX}.{r + 1}") for r in range(RAILS)]           # net-rail-0 = gpu0 = 172.16.1.0/24 (the rail fabric numbers rails from 1)
    ifn = [f"gpu{r}" for r, _ in nets]
    rdma = json.dumps({"configList": [{"rdmaHcaMax": 63, "resourceName": "rdma_shared", "selectors": {"ifNames": ifn}}]})
    o = [f"""# generated by gen.py ({PROFILE}) -- the NVIDIA network-operator resources; netop.sh applies them. Edit gen.py, not this file.
apiVersion: nfd.k8s-sigs.io/v1alpha1
kind: NodeFeatureRule
metadata:
  name: ai-fabric-fake-pci-15b3
spec:
  rules:
  # LAB: SoftRoCE (rdma_rxe, loaded by netsetup.sh on the GPU nodes only) stands in for ConnectX, so the NicClusterPolicy affinity stays verbatim
  - name: "ai-fabric: SoftRoCE rail NICs stand in for Mellanox (pci-15b3)"
    labels:
      feature.node.kubernetes.io/pci-15b3.present: "true"
    matchFeatures:
    - feature: kernel.loadedmodule
      matchExpressions:
        rdma_rxe: {{op: Exists}}
---
apiVersion: mellanox.com/v1alpha1
kind: NicClusterPolicy
metadata:
  name: nic-cluster-policy
spec:
  nodeAffinity:                     # production, verbatim
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
      - matchExpressions:
        - {{key: node-role.ai-fabric.lab/gpu, operator: In, values: ["true"]}}
        - {{key: node-role.ai-fabric.lab/worker, operator: In, values: ["true"]}}
        - {{key: feature.node.kubernetes.io/pci-15b3.present, operator: In, values: ["true"]}}
  # production's ofedDriver (DOCA driver container) is left out: no Mellanox hardware; SoftRoCE comes from the in-box rdma_rxe module
  rdmaSharedDevicePlugin:
    config: '{rdma}'
    image: k8s-rdma-shared-dev-plugin
    imagePullSecrets: []
    repository: {NETOP['rdma_repo']}
    version: {NETOP['rdma_version']}
  tolerations:
  - operator: Exists"""]
    for r, net in nets:
        ipam = json.dumps({"type": "whereabouts", "range": f"{net}.0/24", "gateway": f"{net}.1", "exclude": [f"{net}.1/32", f"{net}.0/26"]})
        o.append(f"""---
apiVersion: mellanox.com/v1alpha1
kind: MacvlanNetwork
metadata:
  name: net-rail-{r}
spec:
  networkNamespace: default
  master: gpu{r}
  mode: bridge
  mtu: {K8S['mtu']}
  ipam: '{ipam}'""")
    return "\n".join(o) + "\n"

# leaf certificates the platform CA issues through cert-manager besides the wildcard (ca-certs.sh): name, SANs, key, where it goes
CA_LEAVES = dict(storage=dict(secret="storage-mgmt-tls", dns=[f"storage-mgmt.{DOMAIN}"], ip=[FB_API], key="ECDSA"),
                 fw=dict(secret="fw-mgmt-tls", dns=[f"fw-mgmt.{DOMAIN}"], ip=[FW["mgmt"]], key="RSA")) if LAB_CA else {}
K8S = dict(pod_cidr="10.42.0.0/16", svc_cidr="10.43.0.0/16", k8s_version="v1.35.8", cilium_version="1.19.7", gateway_api_version="v1.4.1",
           multus_version="v4.3.0", whereabouts_version="v0.9.4", longhorn_version="1.12.1", headlamp_chart_version="0.45.0",
           metrics_server_version="v0.9.0", webui_image="ghcr.io/open-webui/open-webui:v0.11.4", webui_model=_env("WEBUI_MODEL", "qwen2.5-0.5b-instruct"),
           # Open WebUI talks to the lab's own model by default: no external API key is needed anywhere in this lab.
           webui_api_base=_env("WEBUI_API_BASE", "http://llm.ai-sim.svc.cluster.local:8080/v1"),
           mtu="9000", fabric_cidr="10.0.0.0/8")               # versions exactly as refplat
CILIUM_DEVICES = f"bond0,bond0.{FE_VLAN}"                # Cilium devices: the bond + the storage node's tagged data VLAN (cilium-devices.sh keeps a running cluster equal)
NODE_HOSTS = " ".join([f"{n}={h['ip']}" for n, h in HOSTS.items()] + [f"bastion={BASTION_IP}", f"{PC1['name']}={PC1['ip']}", f"{PC2['name']}={PC2['ip']}"])

def extra_ptrs():
    """Reverse DNS for everything OUTSIDE the node subnet, as "ip=name" pairs for the bastion BIND.

    The firewall resolves the addresses in Monitor > Traffic by PTR, so without these its SOURCE column stays numeric for
    anything that is not a node. Management and OOB addresses get a -mgmt / -oob suffix so a name still maps back to exactly
    one address. The bastion becomes AUTHORITATIVE for every /24 named here, so an address in one of them that is not listed
    answers NXDOMAIN instead of being forwarded -- which is why the host LAN is opt-in per profile (`lan_ptrs`) and empty by
    default: the home profile's LAN is the user's own home network and must keep resolving through the upstream resolver.
    """
    p = [f"{OOB_GW}=fw-oob", f"{oob(BASTION_IP)}=bastion-oob"]
    p += [f"{oob(h['ip'])}={n}-oob" for n, h in HOSTS.items()]
    p += [f"{PC2['ip']}={PC2['name']}", f"{FW['e4'].split('/')[0]}=fw-pc1", f"{FW['e6'].split('/')[0]}=fw-pc2"]
    p += [f"{s['mgmt']}={n}-mgmt" for n, s in {**FE, **BE}.items()]
    p += [f"{h['mgmt']}={n}-mgmt" for n, h in HOSTS.items() if h.get("mgmt")]
    p += [f"{FW['mgmt']}=fw-mgmt", f"{BASTION['mgmt']}=bastion-mgmt",
          f"{PC1['mgmt']}={PC1['name']}-mgmt", f"{PC2['mgmt']}={PC2['name']}-mgmt", f"{M}.1=lab-host-mgmt"]
    p += PF.get("lan_ptrs", "").split()
    return " ".join(p)

# ---------------------------------------------------------------- Cumulus NVUE builders (nv set lines, applied by the reflab launcher)
def cvx_common(name):
    return [f"nv set system hostname {name}", f"nv set service ntp mgmt server {NTP_MGMT}",
            # SNMP v2c for Weft, on the management VRF (validated live on 5.12: snmpd listens on 0.0.0.0%mgmt:161)
            "nv set system snmp-server state enabled", "nv set system snmp-server listening-address all vrf mgmt",
            f"nv set system snmp-server readonly-community {SNMP_COMMUNITY} access any",
            f"nv set system snmp-server trap-destination {SNMP_TRAP_HOST} vrf mgmt community-password {SNMP_COMMUNITY} version 2c",
            "nv set system snmp-server trap-link-down check-frequency 10", "nv set system snmp-server trap-link-up check-frequency 10",
            "nv set system snmp-server trap-snmp-auth-failures"]

def cvx_underlay(sw, ports, allow_own_as):
    o = [f"nv set interface lo ip address {sw['lo']}/32", "nv set interface lo type loopback",
         f"nv set router bgp autonomous-system {sw['asn']}", "nv set router bgp enable on", f"nv set router bgp router-id {sw['lo']}",
         "nv set vrf default router bgp enable on", "nv set vrf default router bgp address-family ipv4-unicast enable on",
         "nv set vrf default router bgp address-family ipv4-unicast redistribute connected enable on",
         "nv set vrf default router bgp address-family l2vpn-evpn enable on", "nv set evpn enable on", "nv set nve vxlan enable on"]
    for p in ports:
        o += [f"nv set interface {p} type swp", f"nv set interface {p} link mtu 9216",
              f"nv set vrf default router bgp neighbor {p} remote-as external", f"nv set vrf default router bgp neighbor {p} type unnumbered",
              f"nv set vrf default router bgp neighbor {p} address-family l2vpn-evpn enable on",
              # BFD on every underlay session, as in the AI_FABRIC Cluster-1 production frontend (`neighbor IPV4_UNDERLAY fall-over bfd`).
              # Without it a silent link/spine failure is only detected by the BGP hold timer (9 s): drills.sh drill 2 measured 7.6 s of loss.
              f"nv set vrf default router bgp neighbor {p} bfd enable on", f"nv set vrf default router bgp neighbor {p} bfd detect-multiplier 3",
              f"nv set vrf default router bgp neighbor {p} bfd min-rx-interval 300", f"nv set vrf default router bgp neighbor {p} bfd min-tx-interval 300"]
        if allow_own_as:   # both leaves of a pair share an ASN (reflab): accept the partner's routes reflected by the spines
            for af in ("ipv4-unicast", "l2vpn-evpn"):
                o += [f"nv set vrf default router bgp neighbor {p} address-family {af} aspath allow-my-asn enable on",
                      f"nv set vrf default router bgp neighbor {p} address-family {af} aspath allow-my-asn occurrences 1"]
    return o

def cvx_vrf(extra=()):
    return [f"nv set vrf {VRF} evpn enable on", f"nv set vrf {VRF} evpn vlan {L3VLAN}", f"nv set vrf {VRF} evpn vni {L3VNI}",
            f"nv set evpn vni {L3VNI} route-target both {RT_L3}",
            f"nv set vrf {VRF} router bgp enable on", f"nv set vrf {VRF} router bgp address-family ipv4-unicast enable on",
            f"nv set vrf {VRF} router bgp address-family ipv4-unicast redistribute connected enable on",
            f"nv set vrf {VRF} router bgp address-family ipv4-unicast route-export to-evpn enable on", *extra]

def fe_spine(name, sw):
    ports = [f"swp{FE[l]['sp']}" for l in FE_LEAVES]
    return "\n".join(cvx_common(name) + cvx_underlay(sw, ports, False)) + "\n"

def fe_bonds(name, sw):
    """Server-facing ESI bonds of this leaf: compute/control/bastion = access VLAN 10; the storage LAG = tagged-only trunk (refplat pattern)."""
    o = []
    members = [(h["bond"], [f"swp{h['port']}"], False, n) for n, h in HOSTS.items() if h["pair"] == sw["pair"] and not h.get("members")]
    members += [(h["bond"], [f"swp{m}" for m in h["members"]], True, n) for n, h in HOSTS.items() if h["pair"] == sw["pair"] and h.get("members")]
    if BASTION["pair"] == sw["pair"]: members.append((BASTION["bond"], [f"swp{BASTION['port']}"], False, "bastion"))
    for b, swps, tagged, host in sorted(members):
        bn = f"bond{b}"
        o += [f"nv set interface {bn} type bond", f"nv set interface {bn} description {host}", f"nv set interface {bn} bond member {','.join(swps)}",
              f"nv set interface {bn} link mtu 9216", f"nv set interface {bn} evpn multihoming segment enable on",
              f"nv set interface {bn} evpn multihoming segment local-id {b}", f"nv set interface {bn} evpn multihoming segment mac-address {sw['es']}"]
        if tagged: o += [f"nv set interface {bn} bridge domain br_default vlan {FE_VLAN}", f"nv set interface {bn} bridge domain br_default untagged none"]
        else:      o += [f"nv set interface {bn} bridge domain br_default access {FE_VLAN}"]
    return o

def fe_leaf(name, sw):
    o = cvx_common(name) + cvx_underlay(sw, ["swp1", "swp2"], True)
    o += ["nv set evpn multihoming enable on", "nv set interface swp1-2 evpn multihoming uplink on",
          f"nv set nve vxlan source address {sw['lo']}", "nv set nve vxlan arp-nd-suppress on",
          f"nv set bridge domain br_default vlan {FE_VLAN} vni {FE_VNI}", f"nv set evpn vni {FE_VNI} route-target both {RT_L2}"]
    o += fe_bonds(name, sw)
    v = f"vlan{FE_VLAN}"
    o += [f"nv set interface {v} type svi", f"nv set interface {v} vlan {FE_VLAN}", f"nv set interface {v} link mtu 9216",
          f"nv set interface {v} ip vrf {VRF}", f"nv set interface {v} ip address {sw['svi']}/{FE_PREFIX}",
          "nv set router vrr enable on", f"nv set interface {v} ip vrr enable on", f"nv set interface {v} ip vrr address {FE_GW}/{FE_PREFIX}",
          f"nv set interface {v} ip vrr mac-address {AGW_MAC}", f"nv set interface {v} ip vrr state up"]
    return "\n".join(o + cvx_vrf()) + "\n"

def fe_border(name, sw):
    o = cvx_common(name) + cvx_underlay(sw, ["swp1", "swp2"], True) + [f"nv set nve vxlan source address {sw['lo']}"]
    o += ["nv set interface swp3 type swp", "nv set interface swp3 link mtu 9216", f"nv set interface swp3 description {FW['hostname']}",
          f"nv set interface swp3 ip vrf {VRF}", f"nv set interface swp3 ip address {sw['fw_ip']}"]
    o += cvx_vrf([f"nv set vrf {VRF} router bgp neighbor {sw['fw_nh']} remote-as {FW_ASN}", f"nv set vrf {VRF} router bgp neighbor {sw['fw_nh']} type numbered",
                  f"nv set vrf {VRF} router bgp neighbor {sw['fw_nh']} address-family ipv4-unicast enable on"])
    return "\n".join(o) + "\n"

def fe_oob(name, sw):
    n = OOB_FW_PORT
    return "\n".join(cvx_common(name) + [f"nv set interface swp1-{n} type swp", f"nv set interface swp1-{n} bridge domain br_default"]) + "\n"

# ---------------------------------------------------------------- Junos builders (Juniper vEX = vJunos-switch; `set` lines pushed over key-based SSH by
# apply-junos.sh after boot). The boot-time startup-config holds ONLY the operator SSH keys (junos_keys): it is what makes the switches
# reachable without a password, and a rejected statement in a boot config would leave the box unmanageable. Validated on a probe lab
# 2026-09-18 (vJunos-switch 26.2R1.7): eBGP UNNUMBERED underlay (IPv6 link-local auto-discovery + RFC 5549 next hops) works, so the design
# keeps the Cumulus lab's unnumbered underlay; BFD 3 x 300 ms, EVPN-VXLAN in a MAC-VRF, ESI-LAG, anycast gateway and type-5 routing in
# vrf k8s all pass. Platform facts: interface MTU tops out at 9192 (not 9216); commits warn "requires BGP/VXLAN license" (warnings only).
JN_MTU = 9192
def junos_keys():
    ks = operator_keys(); ind = "\n".join(f'                ssh-ed25519 "{k}";' for k in ks); rind = "\n".join(f'        ssh-ed25519 "{k}";' for k in ks)
    return f"system {{\n    root-authentication {{\n{rind}\n    }}\n    login {{\n        user admin {{\n            authentication {{\n{ind}\n            }}\n        }}\n    }}\n}}\n"

JN_SNMP = [f"set snmp community {SNMP_COMMUNITY} authorization read-only",
           # the management port lives in mgmt_junos (management-instance): without these two lines the agent never answers on fxp0 (validated live)
           f"set snmp community {SNMP_COMMUNITY} routing-instance mgmt_junos clients 0.0.0.0/0", "set snmp routing-instance-access access-list mgmt_junos",
           # Traps through the SNMP target/notify framework (v2c) instead of a trap-group, because only it can FILTER: unlicensed vJunos sends a
           # jnxLicense trap (1.3.6.1.4.1.2636.3.63.1.0.5 "VXLAN") every 10 s from every VXLAN switch whatever the trap categories are; the
           # notify-filter drops that MIB and lets everything else through (link, BGP, start, authentication). Validated live on fe-gpu-leaf1.
           f"set snmp v3 target-address WEFT address {SNMP_TRAP_HOST}", "set snmp v3 target-address WEFT port 162", "set snmp v3 target-address WEFT tag-list WEFT",
           "set snmp v3 target-address WEFT routing-instance mgmt_junos", "set snmp v3 target-address WEFT target-parameters WEFT-V2C",
           "set snmp v3 target-parameters WEFT-V2C parameters message-processing-model v2c", "set snmp v3 target-parameters WEFT-V2C parameters security-model v2c",
           "set snmp v3 target-parameters WEFT-V2C parameters security-level none", "set snmp v3 target-parameters WEFT-V2C parameters security-name WEFT",
           "set snmp v3 target-parameters WEFT-V2C notify-filter NOLICENSE", "set snmp v3 notify WEFT type trap", "set snmp v3 notify WEFT tag WEFT",
           "set snmp v3 notify-filter NOLICENSE oid .1 include", "set snmp v3 notify-filter NOLICENSE oid .1.3.6.1.4.1.2636.3.63 exclude",
           "set snmp v3 snmp-community WEFT-TRAP community-name weft-trap-public security-name WEFT tag WEFT"]
def jn_common(name, sw, fab_ports, spine):
    lo = sw["lo"]
    o = [f"set system host-name {name}", f"set system ntp server {NTP_MGMT} routing-instance mgmt_junos", *JN_SNMP, "set protocols lldp interface all",
         "set chassis aggregated-devices ethernet device-count 48",
         f"set interfaces lo0 unit 0 family inet address {lo}/32", f"set routing-options router-id {lo}",
         # both leaves of a pair share an ASN (as in the Cumulus lab): accept the partner's routes reflected by the spines (loops 2)
         f"set routing-options autonomous-system {sw['asn']}" + ("" if spine else " loops 2"),
         "set policy-options policy-statement ECMP then load-balance per-packet", "set routing-options forwarding-table export ECMP",
         "set policy-options policy-statement UNDERLAY-EXPORT term lo from interface lo0.0", "set policy-options policy-statement UNDERLAY-EXPORT term lo then accept",
         "set policy-options policy-statement UNDERLAY-EXPORT term bgp from protocol bgp", "set policy-options policy-statement UNDERLAY-EXPORT term bgp then accept",
         "set policy-options policy-statement UNDERLAY-EXPORT term rest then reject",
         "set policy-options as-list FABRIC members 65000-65535",
         "set protocols bgp group UNDERLAY type external", "set protocols bgp group UNDERLAY family inet unicast extended-nexthop",
         "set protocols bgp group UNDERLAY family inet6 unicast", "set protocols bgp group UNDERLAY dynamic-neighbor FAB peer-auto-discovery family inet6 ipv6-nd",
         "set protocols bgp group UNDERLAY peer-as-list FABRIC", "set protocols bgp group UNDERLAY export UNDERLAY-EXPORT",
         "set protocols bgp group UNDERLAY multipath multiple-as",
         "set protocols bgp group UNDERLAY bfd-liveness-detection minimum-interval 300", "set protocols bgp group UNDERLAY bfd-liveness-detection multiplier 3"]
    if spine: o.append("set protocols bgp group UNDERLAY advertise-peer-as")     # Junos would otherwise hide leaf1's routes from leaf2 (same AS)
    for port, desc in fab_ports:
        o += [f"set interfaces {port} description {desc}", f"set interfaces {port} mtu {JN_MTU}", f"set interfaces {port} unit 0 family inet", f"set interfaces {port} unit 0 family inet6",
              f"set protocols router-advertisement interface {port}.0", f"set protocols bgp group UNDERLAY dynamic-neighbor FAB peer-auto-discovery interface {port}.0"]
    return o

def jn_overlay(sw, peers, spine):
    o = ["set protocols bgp group OVERLAY type external", "set protocols bgp group OVERLAY multihop ttl 2", f"set protocols bgp group OVERLAY local-address {sw['lo']}",
         "set protocols bgp group OVERLAY family evpn signaling", "set protocols bgp group OVERLAY multipath multiple-as"]
    if spine: o += ["set protocols bgp group OVERLAY multihop no-nexthop-change", "set protocols bgp group OVERLAY advertise-peer-as"]
    return o + [f"set protocols bgp group OVERLAY neighbor {FE[n]['lo']} peer-as {FE[n]['asn']}" for n in peers]

def jn_vrf(sw, extra=()):
    return [f"set routing-instances {VRF} instance-type vrf", f"set routing-instances {VRF} route-distinguisher {sw['lo']}:{L3VNI}", f"set routing-instances {VRF} vrf-target target:{RT_L3}",
            f"set routing-instances {VRF} protocols evpn ip-prefix-routes advertise direct-nexthop", f"set routing-instances {VRF} protocols evpn ip-prefix-routes encapsulation vxlan",
            f"set routing-instances {VRF} protocols evpn ip-prefix-routes vni {L3VNI}", f"set routing-instances {VRF} protocols evpn ip-prefix-routes export T5-EXPORT",
            "set policy-options policy-statement T5-EXPORT term direct from protocol direct", "set policy-options policy-statement T5-EXPORT term direct then accept",
            "set policy-options policy-statement T5-EXPORT term bgp from protocol bgp", "set policy-options policy-statement T5-EXPORT term bgp then accept",
            # local hosts as /32 type-5 routes: the borders then route straight to the leaf pair that owns the host (symmetric), as the Cumulus lab did
            "set policy-options policy-statement T5-EXPORT term host from protocol evpn", "set policy-options policy-statement T5-EXPORT term host from route-filter 0.0.0.0/0 prefix-length-range /32-/32",
            "set policy-options policy-statement T5-EXPORT term host then accept",
            # ECMP over the type-5 routes of a leaf PAIR. Without it only one of the two equal routes per host prefix is active, the switch builds a
            # VXLAN tunnel to that leaf only, and L3-VNI packets that arrive FROM the pair's other leaf are dropped (no tunnel for that source VTEP):
            # the storage node lost every flow its bond hashed to fe-stor-leaf2 on the way to the borders (found 2026-09-19, reboot test 3).
            f"set routing-instances {VRF} routing-options multipath", *extra]

def jn_spine(name, sw):
    ports = [(ge(FE[l]["sp"]), l) for l in FE_LEAVES]
    return "\n".join(jn_common(name, sw, ports, True) + jn_overlay(sw, FE_LEAVES, True)) + "\n"

def jn_bonds(sw):
    """Server-facing ESI-LAGs of this leaf: compute/control/bastion = access VLAN 10; the storage LAG = tagged-only trunk (refplat pattern)."""
    o = []; pid = sw["es"].split(":")[-1]
    members = [(h["bond"], [ge(h["port"])], False, n) for n, h in HOSTS.items() if h["pair"] == sw["pair"] and not h.get("members")]
    members += [(h["bond"], [ge(m) for m in h["members"]], True, n) for n, h in HOSTS.items() if h["pair"] == sw["pair"] and h.get("members")]
    if BASTION["pair"] == sw["pair"]: members.append((BASTION["bond"], [ge(BASTION["port"])], False, "bastion"))
    for b, ports, tagged, host in sorted(members):
        ae = f"ae{b}"
        for port in ports: o += [f"set interfaces {port} description {host}", f"set interfaces {port} ether-options 802.3ad {ae}"]
        o += [f"set interfaces {ae} description {host}", f"set interfaces {ae} mtu {JN_MTU}",
              f"set interfaces {ae} esi 00:{sw['es']}:00:00:{b:02x}", f"set interfaces {ae} esi all-active",     # LAB: pair system MAC + bond id, the identifiers the Cumulus lab used
              f"set interfaces {ae} aggregated-ether-options lacp active", f"set interfaces {ae} aggregated-ether-options lacp periodic fast",
              f"set interfaces {ae} aggregated-ether-options lacp system-id {sw['es']}",
              f"set interfaces {ae} unit 0 family ethernet-switching interface-mode {'trunk' if tagged else 'access'}",
              f"set interfaces {ae} unit 0 family ethernet-switching vlan members {FE_NAME}", f"set routing-instances FABRIC interface {ae}.0"]
    return o

def jn_leaf(name, sw):
    o = jn_common(name, sw, [(ge(1), "fe-spine1"), (ge(2), "fe-spine2")], False) + jn_overlay(sw, FE_SPINES, False) + jn_vrf(sw)
    o += ["set routing-instances FABRIC instance-type mac-vrf", "set routing-instances FABRIC service-type vlan-aware", "set routing-instances FABRIC vtep-source-interface lo0.0",
          f"set routing-instances FABRIC route-distinguisher {sw['lo']}:{FE_VNI}", f"set routing-instances FABRIC vrf-target target:{RT_L2}",
          "set routing-instances FABRIC protocols evpn encapsulation vxlan", "set routing-instances FABRIC protocols evpn default-gateway no-gateway-community",
          "set routing-instances FABRIC protocols evpn extended-vni-list all",
          f"set routing-instances FABRIC vlans {FE_NAME} vlan-id {FE_VLAN}", f"set routing-instances FABRIC vlans {FE_NAME} l3-interface irb.{FE_VLAN}",
          f"set routing-instances FABRIC vlans {FE_NAME} vxlan vni {FE_VNI}"]
    o += jn_bonds(sw)
    o += [f"set interfaces irb unit {FE_VLAN} family inet address {sw['svi']}/{FE_PREFIX} virtual-gateway-address {FE_GW}", f"set interfaces irb unit {FE_VLAN} virtual-gateway-v4-mac {AGW_MAC}",
          f"set interfaces irb unit {FE_VLAN} virtual-gateway-accept-data", "set interfaces irb mtu 9000", f"set routing-instances {VRF} interface irb.{FE_VLAN}"]
    return "\n".join(o) + "\n"

def jn_border(name, sw):
    o = jn_common(name, sw, [(ge(1), "fe-spine1"), (ge(2), "fe-spine2")], False) + jn_overlay(sw, FE_SPINES, False)
    o += jn_vrf(sw, [f"set interfaces {ge(3)} description {FW['hostname']}", f"set interfaces {ge(3)} mtu {JN_MTU}", f"set interfaces {ge(3)} unit 0 family inet address {sw['fw_ip']}",
                     f"set routing-instances {VRF} interface {ge(3)}.0",
                     f"set routing-instances {VRF} protocols bgp group FW type external", f"set routing-instances {VRF} protocols bgp group FW peer-as {FW_ASN}",
                     f"set routing-instances {VRF} protocols bgp group FW neighbor {sw['fw_nh']}", f"set routing-instances {VRF} protocols bgp group FW export FW-EXPORT",
                     "set policy-options policy-statement FW-EXPORT term fabric from protocol evpn", "set policy-options policy-statement FW-EXPORT term fabric then accept",
                     "set policy-options policy-statement FW-EXPORT term direct from protocol direct", "set policy-options policy-statement FW-EXPORT term direct then accept",
                     "set policy-options policy-statement FW-EXPORT term rest then reject"])
    return "\n".join(o) + "\n"

def jn_oob(name, sw):
    # "set protocols lldp interface all" as in jn_common: Junos does not run LLDP unless told to, and this builder is separate from
    # jn_common, so the OOB switch was the one fabric device with no LLDP -- it saw none of the servers' BMC NICs while the Cumulus
    # leaves and the OcNOS rail leaves (both LLDP-on by default) saw them all.
    o = [f"set system host-name {name}", f"set system ntp server {NTP_MGMT} routing-instance mgmt_junos", *JN_SNMP,
         "set protocols lldp interface all", "set vlans OOB vlan-id 100"]    # LAB: one flat OOB VLAN
    if PF.get("hardening"): o.append("set system services ssh root-login deny")   # Weft change 2026-09-25 (compliance: no direct root SSH login)
    for n in range(1, OOB_FW_PORT + 1): o += [f"set interfaces {ge(n)} unit 0 family ethernet-switching interface-mode access", f"set interfaces {ge(n)} unit 0 family ethernet-switching vlan members OOB"]
    return "\n".join(o) + "\n"

# ---------------------------------------------------------------- Cisco NX-OS builders (Nexus 9300v, site-a-nx). The boot config IS the configuration:
# vrnetlab types configs/<switch>.cfg into the console of the booted switch and saves it. Ported line for line from the nxprobe lab, where this exact
# text passed (2026-09-23: OSPF unnumbered adjacencies, iBGP EVPN, Virtual-peerlink mode Enabled on both pairs, pair-to-pair VXLAN incl. 9000-byte
# frames, routed path to the firewall, failover). Forced by NX-OS, not choices: VNIs start at 4096 (AI_FABRIC's VNI 10 / L3 VNI 1000 -> LAB 10010 / 11000,
# route-targets stay AI_FABRIC's 10:10 / 1000:1000); the anycast gateway is the gateway address itself on every leaf (no per-leaf SVI address); one sshkey
# per user, so the Mac key logs in as admin and the lab host's key as `ops` (key-only, no usable password).
NX_IMAGE, NX_BIN = _env("NX_IMAGE", "SET_IN_ENV/n9kv:TAG"), _env("NX_BIN", "SET_IN_ENV-nxos.bin")     # build this image with vrnetlab from the vendor qcow2; set NX_IMAGE / NX_BIN in .env
NX_ASN = 65100                                          # LAB: private iBGP AS (operator: "private ASN"); the borders present 65104 to the firewall (local-as)
NX_L2VNI, NX_L3VNI = 10000 + FE_VLAN, 10000 + L3VNI     # LAB: L2 VNI = 10000 + VLAN (10 -> 10010, 100 -> 10100), L3 VNI 11000 (NX-OS minimum VNI is 4096)
NX_PL_PO = 500                                          # LAB: virtual peer-link port-channel (no member ports)
NX_PAIRS = [p for p in PAIR if p != "stor"]             # vPC domain = position: gpu 1, gpu2 2, ctrl 3 (LAB)
def nx_ids(name):   # LAB addressing: lo0 = router-id/BGP/unnumbered source (the existing loopback), lo1 = NVE (+ secondary pair VIP), lo2 = virtual peer-link
    s = FE[name]; x = s["lo"].split(".")[-1]; d = dict(lo1=f"10.0.1.{x}", lo2=f"10.0.2.{x}")
    if s.get("pair"):
        a, b = PAIR[s["pair"]]; dom = NX_PAIRS.index(s["pair"]) + 1
        d.update(dom=dom, vip=f"10.0.1.{100 + dom}", prio=100 if name == a else 200, peer=b if name == a else a)
    return d
def nx_keys():
    # Two operator keys reach the switches: this workstation's key (NX-OS user `admin`) and the LAB HOST's own root
    # key (user `ops`, which lib.sh NX() and nx-wait.sh log in with). The host key is recognised by its comment:
    # LAB_HOST_KEY_COMMENT if set, else the profile's host_key, else any `root@...` key -- so a fresh clone works on
    # a host with any name. Without the `ops` user nx-wait.sh can never succeed and the deploy stalls at the Nexus wait.
    ks = [k.split() for k in operator_keys()]   # type + key + FIRST comment word
    cands = [k for k in ks if len(k) > 2]
    full = lambda k: " ".join(k[:3])
    hostc = _env("LAB_HOST_KEY_COMMENT") or PF.get("host_key", "")
    want = _env("LAB_WORKSTATION_KEY_COMMENT", "")
    host = next((full(k) for k in cands if k[2] == hostc), None) \
        or next((full(k) for k in cands if k[2].startswith("root@")), None)
    mac = next((full(k) for k in cands if k[2].startswith(want)), None) if want \
        else next((full(k) for k in cands if full(k) != host), None)
    return mac, host

NDFC_USER = 'username ndfc password 5 CHANGEME_NXOS_TYPE5_HASH  role network-admin'

# What Nexus Dashboard / NDFC itself pushed to the frontend on 2026-09-26 (fabric Site-4-frontend, "Recalculate & Deploy" + telemetry onboarding),
# captured from `show running-config` of all 10 switches on 2026-09-28 (saved-running-20260928/) and identical within each role. None of it was in
# gen.py, so every redeploy dropped it and ND would have seen the fabric out of sync. Profiles with ndfc=True emit it verbatim (NDFC's template names
# kept: fabric-rmap-redist-subnet, extcon-rmap-filter*). 172.29.129.136:2162 = ND's SNMP trap receiver, 172.29.129.135:57500 = its gRPC collector.
NDFC = PF.get("ndfc", False)
NDFC_BORDER = ["ip prefix-list default-route seq 5 permit 0.0.0.0/0 le 1", "ip prefix-list host-route seq 5 permit 0.0.0.0/0 eq 32",
               "ipv6 prefix-list default-route-v6 seq 5 permit 0::/0", "ipv6 prefix-list host-route-v6 seq 5 permit 0::/0 eq 128",
               "route-map extcon-rmap-filter deny 10", "  match ip address prefix-list default-route",
               "route-map extcon-rmap-filter deny 20", "  match ip address prefix-list host-route", "route-map extcon-rmap-filter permit 1000",
               "route-map extcon-rmap-filter-allow-host deny 10", "  match ip address prefix-list default-route", "route-map extcon-rmap-filter-allow-host permit 1000",
               "route-map extcon-rmap-filter-v6 deny 10", "  match ipv6 address prefix-list default-route-v6",
               "route-map extcon-rmap-filter-v6 deny 20", "  match ipv6 address prefix-list host-route-v6", "route-map extcon-rmap-filter-v6 permit 1000",
               "route-map extcon-rmap-filter-v6-allow-host deny 10", "  match ipv6 address prefix-list default-route-v6", "route-map extcon-rmap-filter-v6-allow-host permit 1000"]
# ND's telemetry block lives in ndfc/telemetry.cfg and is applied AFTER boot by nx-telemetry.sh (see nx_tail).

def nx_head(name, feats, vpc):
    mac, host = nx_keys(); role = FE[name]["role"]
    o = [f"hostname {name}", "no logging console", f"boot nxos bootflash:/{NX_BIN}", "nv overlay evpn"] + [f"feature {f}" for f in feats]
    if NDFC: o += ["feature ngoam", "feature telemetry"] + (["feature nv overlay"] if role == "spine" else ["feature dhcp"]) \
                  + (["feature lacp", "cfs eth distribute"] if role == "border" else [])
    # vrnetlab's launcher types `feature telnet` BEFORE this file; Weft change 2026-09-25 (compliance "Telnet disabled") turned it off on all 10
    if PF.get("hardening"): o.append("no feature telnet")
    if vpc: o.append("cfs ipv4 distribute")
    o.append("no password strength-check")
    if mac: o.append(f"username admin sshkey {mac}")
    if host: o += ["username ops role network-admin", f"username ops sshkey {host}"]
    # Nexus Dashboard (home ND 192.168.1.133, fabric Site-4-frontend) discovers + deploys with ndfc/<password you set>: NDFC refuses passwords under 8
    # characters, so admin/admin cannot be used. The NX-OS type-5 hash of that password (operator 2026-09-25), so this line == running-config.
    # Skip the NDFC user while the hash is still the published placeholder: pushing an invalid
    # `password 5 ...` line to a switch is worse than not creating the user. Replace NDFC_USER
    # with your own NX-OS type-5 hash (see .env.example) to enable it.
    if "CHANGEME" not in NDFC_USER: o.append(NDFC_USER)
    # fabric peering: the ing-flow-redirect region (9300v name `redirect`) >= 512; only active after save + reload (up.sh -> nx-tcam-reload.sh)
    if vpc: o += ["hardware access-list tcam region racl 1024", "hardware access-list tcam region redirect 512"]
    o += ["vrf context management", f"  ip route 0.0.0.0/0 {M}.1", f"ntp server {NTP_MGMT} use-vrf management",
          # SNMP v2c read-only for Weft + traps to the lab host, in the management VRF
          f"snmp-server community {SNMP_COMMUNITY} group network-operator", f"snmp-server host {SNMP_TRAP_HOST} traps version 2c {SNMP_COMMUNITY}",
          f"snmp-server host {SNMP_TRAP_HOST} use-vrf management"]      # link up/down traps are on by default (only `show running-config snmp all` shows them)
    if NDFC:
        o += ["snmp-server host 172.29.129.136 traps version 2c public udp-port 2162", "hardware profile dme load-interval 10", "nxapi http port 80"]
        if role != "spine": o += ["service dhcp", "ip dhcp relay", "ip dhcp relay information option", "ip dhcp relay information option vpn", "ipv6 dhcp relay",
                                  "route-map fabric-rmap-redist-subnet permit 10", "  match tag 12345"]
        if role == "border": o += NDFC_BORDER
    o += ["router ospf UNDERLAY", f"  router-id {FE[name]['lo']}"]      # no log-adjacency-changes: NDFC removes it
    return o

def nx_uplink(port, desc, fabric):
    # one link per spine, IP UNNUMBERED (borrows loopback0). 1 s / 3 s OSPF timers: a shut NIC does not drop carrier at the far end of a virtual
    # wire, so the dead timer is the failure detector (vpcfp: 40 s default dead time = 34 s outage); `port-type fabric` = vPC fabric peering uplink
    o = [f"interface {port}", f"  description {desc}", "  no switchport", "  mtu 9216", "  medium p2p"] + (["  port-type fabric"] if fabric else [])
    # no ip/ipv6 redirects: NDFC's unnumbered_fabric_interface template requires both; without them its brownfield import refuses every fabric link
    return o + ["  no ip redirects", "  ip unnumbered loopback0", "  no ipv6 redirects", "  ip ospf network point-to-point", "  ip ospf hello-interval 1", "  ip ospf dead-interval 3",
                "  ip router ospf UNDERLAY area 0.0.0.0", "  no shutdown"]

def nx_loop(n, addr, desc, sec=None):
    return [f"interface loopback{n}", f"  description {desc}", f"  ip address {addr}/32"] + ([f"  ip address {sec}/32 secondary"] if sec else []) + ["  ip router ospf UNDERLAY area 0.0.0.0"]

NX_PORTS = 64                                           # N9K-C9300v front panel: Ethernet1/1-64

def nx_shut_unused(cfg):
    # Every front-panel port this config does not use is shut: NDFC (fabric Site-4-frontend) raises a CONNECTIVITY_INTERFACE_STATUS
    # anomaly for each admin-up port with no link ("up:down:Link not connected", 518 of them), and it shut them on 2026-09-26.
    # NX-OS prints such a port as just `interface EthernetN` + `shutdown`, so this is also what the config-line check compares.
    used = {int(l.split("/")[1]) for l in cfg.splitlines() if l.startswith("interface Ethernet1/") and "." not in l}
    return cfg + "".join(f"interface Ethernet1/{i}\n  shutdown\n" for i in range(1, NX_PORTS + 1) if i not in used)

def nx_tail(name):
    # Console AND vty never time out. Same reason as OcNOS be_globals(): the vrnetlab launcher leaves a serial console session
    # logged in and the default idle logout drops it, which costs a recovery path when SSH to mgmt0 is not usable. NX-OS takes
    # `exec-timeout <minutes>` (one argument, 0 = never); OcNOS takes `exec-timeout <min> <sec>`, hence `0 0` there and `0` here.
    # ND's telemetry block (ndfc/telemetry.cfg) is NOT typed here: its sub-mode prompts `(conf-tm-...)#` are not `(config...)#`, vrnetlab's
    # scrapli waits for a config prompt forever and the launcher dies (2026-09-28 proof boot). nx-telemetry.sh puts it on after boot (up.sh).
    return ["interface mgmt0", "  vrf member management", f"  ip address {FE[name]['mgmt']}/24",
            "line console", "  exec-timeout 0", "line vty", "  exec-timeout 0"]

# VLAN zones. Each is its own VRF + L3 VNI, with the anycast gateway on the leaves of the pairs that carry it; the borders hand every VRF to the firewall
# (VRF k8s on the untagged /30s, the others on dot1q sub-interfaces), so traffic between VLANs can only cross the firewall. pairs=None = every leaf pair.
def nth(cidr, i): o = cidr.split("/")[0].split("."); return ".".join(o[:3] + [str(int(o[3]) + i)])      # the i-th address of a /30 (1 = border, 2 = firewall)
# tag / fw_nets: the dot1q sub-interface of the zone on the border <-> firewall links (fe-border1 = first /30, fe-border2 = second). Operator 2026-09-23: in the
# VLAN design EVERY VLAN rides a sub-interface, VLAN 100 included (.100 on the same /30s the untagged link used); the parents carry no address.
fw30 = lambda b: nth(FE[b]["fw_ip"], -1) + "/30"
NX_ZONES = [dict(vrf=VRF, vlan=FE_VLAN, name=FE_NAME, l3vlan=L3VLAN, l3vni=NX_L3VNI, rt_l2=RT_L2, rt_l3=RT_L3, gw=f"{FE_GW}/{FE_PREFIX}", pairs=None,
                 tag=FE_VLAN if MULTI else None, fw_nets=(fw30("fe-border1"), fw30("fe-border2")) if MULTI else None)]
if MULTI: NX_ZONES += [   # site-a-nx, LAB values confirmed by the operator 2026-09-23
    dict(vrf="stor-mgmt", vlan=200, name="STOR-MGMT", l3vlan=3002, l3vni=12000, rt_l2="200:200", rt_l3="2000:2000", gw=f"{STOR_MGMT['gw']}/{STOR_MGMT['prefix']}",
         pairs=("ctrl",), tag=200, fw_nets=("10.1.254.8/30", "10.1.254.12/30")),
    dict(vrf="bastion", vlan=300, name="BASTION", l3vlan=3003, l3vni=13000, rt_l2="300:300", rt_l3="3000:3000", gw="10.1.30.1/24",
         pairs=("ctrl",), tag=300, fw_nets=("10.1.254.16/30", "10.1.254.20/30"))]
ZONE = {z["vrf"]: z for z in NX_ZONES}
FZ = "data" if MULTI else "fabric"     # firewall zone of VRF k8s / VLAN 100 (operator 2026-09-23: renamed to data in the VLAN design, rules named after it too)
def fw_rule(name): return re.sub(r"(^|-)fabric(?=-|$)", lambda m: m.group(1) + FZ, name)   # rule name as the firewall carries it: fabric-to-internet -> data-to-internet
def nx_zones(pair=None): return [z for z in NX_ZONES if pair is None or z["pairs"] is None or pair in z["pairs"]]   # pair=None: all (borders)
def host_vlan(host): return ZONE["bastion"]["vlan"] if MULTI and host == "bastion" else FE_VLAN   # the VLAN a server's port-channel carries

def nx_vlans(vs):    # NX-OS writes consecutive VLANs as a range (3001,3002,3003 -> 3001-3003); generate that form so config == running-config
    vs = sorted(set(vs)); out = []; i = 0
    while i < len(vs):
        j = i
        while j + 1 < len(vs) and vs[j + 1] == vs[j] + 1: j += 1
        out.append(str(vs[i]) if i == j else f"{vs[i]}-{vs[j]}"); i = j + 1
    return ",".join(out)

def nx_vrf(zones):
    o = ["route-map RM-DIRECT permit 10"]
    for z in zones:
        o += [f"vrf context {z['vrf']}", f"  vni {z['l3vni']}", "  rd auto", "  address-family ipv4 unicast",
              f"    route-target import {z['rt_l3']}", f"    route-target import {z['rt_l3']} evpn", f"    route-target export {z['rt_l3']}", f"    route-target export {z['rt_l3']} evpn"]
        if NDFC: o += ["    route-target both auto", "    route-target both auto evpn", "  address-family ipv6 unicast", "    route-target both auto", "    route-target both auto evpn"]
        o += [f"interface Vlan{z['l3vlan']}", f"  description {z['vrf']} L3VNI", "  no shutdown", "  mtu 9216", f"  vrf member {z['vrf']}", "  no ip redirects", "  ip forward"]
        # NDFC: ipv6 forward on the L3VNI SVI; `no ipv6 redirects` is automatic on a vPC leaf (peer-gateway), explicit on the borders
        if NDFC: o += ["  ipv6 forward", "  no ipv6 redirects"]
    return o

def nx_bgp(name, zones, extra=lambda z: []):
    s = FE[name]
    o = [f"router bgp {NX_ASN}", f"  router-id {s['lo']}", "  log-neighbor-changes", "  address-family l2vpn evpn"] + (["    advertise-pip"] if s.get("pair") else [])
    o += ["  template peer SPINE", f"    remote-as {NX_ASN}", "    update-source loopback0", "    address-family l2vpn evpn", "      send-community", "      send-community extended"]
    for sp in FE_SPINES: o += [f"  neighbor {FE[sp]['lo']}", "    inherit peer SPINE", f"    description to-{sp}"]      # NDFC's description form
    for z in zones:
        o += [f"  vrf {z['vrf']}", "    address-family ipv4 unicast", "      redistribute direct route-map RM-DIRECT", "      maximum-paths ibgp 4"]
        if NDFC: o += ["      advertise l2vpn evpn", "    address-family ipv6 unicast", "      advertise l2vpn evpn",
                       "      redistribute direct route-map RM-DIRECT", "      maximum-paths ibgp 4"]
        o += extra(z)
    return o

def nx_nve(zones, l2, vpc):
    o = ["interface nve1", "  no shutdown", "  host-reachability protocol bgp"] + (["  advertise virtual-rmac"] if vpc else []) + ["  source-interface loopback1"]
    if l2:
        for z in zones: o += [f"  member vni {10000 + z['vlan']}", "    ingress-replication protocol bgp"]
    return o + [f"  member vni {z['l3vni']} associate-vrf" for z in zones]

def nx_spine(name, sw):
    o = nx_head(name, ["ospf", "bgp", "lldp", "nxapi", "scp-server"], False) + nx_loop(0, sw["lo"], "router-id / BGP / unnumbered source")
    for l in sorted(FE_LEAVES, key=lambda l: FE[l]["sp"]): o += nx_uplink(f"Ethernet1/{FE[l]['sp']}", l, False)
    o += [f"router bgp {NX_ASN}", f"  router-id {sw['lo']}", "  log-neighbor-changes", "  address-family l2vpn evpn", "    retain route-target all",
          "  template peer LEAF", f"    remote-as {NX_ASN}", "    update-source loopback0", "    address-family l2vpn evpn",
          "      send-community", "      send-community extended", "      route-reflector-client"]
    for l in FE_LEAVES: o += [f"  neighbor {FE[l]['lo']}", "    inherit peer LEAF", f"    description to-{l}"]
    return "\n".join(o + nx_tail(name)) + "\n"

def nx_members(sw):
    """This leaf pair's servers: (vPC/port-channel number, [ports], tagged, host). compute/control = access VLAN 100 (10 flat), bastion = its own VLAN
    (300) on site-a-nx, storage = tagged-only trunk with the data VLAN."""
    m = [(h["bond"], h.get("members") or [h["port"]], bool(h.get("tagged")), n) for n, h in HOSTS.items() if h["pair"] == sw["pair"]]
    if BASTION["pair"] == sw["pair"]: m.append((BASTION["bond"], [BASTION["port"]], False, "bastion"))
    return sorted(m)

def nx_leaf(name, sw):
    ids = nx_ids(name); peer = nx_ids(ids["peer"]); zones = nx_zones(sw["pair"])
    o = nx_head(name, ["ospf", "bgp", "fabric forwarding", "interface-vlan", "vn-segment-vlan-based", "lacp", "vpc", "lldp", "nv overlay", "nxapi", "scp-server"], True)
    h = AGW_MAC.replace(":", "")      # 00:0a:00:c1:00:01 -> 000a.00c1.0001 (AI_FABRIC's own notation)
    o.append(f"fabric forwarding anycast-gateway-mac {h[:4]}.{h[4:8]}.{h[8:]}")
    for z in zones: o += [f"vlan {z['vlan']}", f"  name {z['name']}", f"  vn-segment {10000 + z['vlan']}"]
    for z in zones: o += [f"vlan {z['l3vlan']}", f"  name {z['vrf']}-L3VNI", f"  vn-segment {z['l3vni']}"]
    o += ["spanning-tree vlan 1-3967 priority 4096"] + nx_vrf(zones)
    o += (nx_loop(0, sw["lo"], "router-id / BGP / unnumbered source") + nx_loop(1, ids["lo1"], "VTEP (secondary = vPC VIP)", ids["vip"])
          + nx_loop(2, ids["lo2"], "vPC virtual peer-link (not the NVE loopback)"))
    o += [f"vpc domain {ids['dom']}", "  peer-switch", f"  role priority {ids['prio']}",
          f"  peer-keepalive destination {FE[ids['peer']]['mgmt']} source {sw['mgmt']} vrf management",      # LAB: keepalive over mgmt0
          f"  virtual peer-link destination {peer['lo2']} source {ids['lo2']} dscp 56", "  delay restore 150", "  peer-gateway",
          "  auto-recovery reload-delay 360", "  ip arp synchronize", "  ipv6 nd synchronize", "  layer3 peer-router"]      # NDFC's vPC domain intent
    for z in zones:
        o += [f"interface Vlan{z['vlan']}", f"  description {z['name']} anycast gateway", "  no shutdown", "  mtu 9216", f"  vrf member {z['vrf']}", "  no ip redirects",
              f"  ip address {z['gw']}", "  fabric forwarding mode anycast-gateway"]
    # NDFC's intent: the virtual peer-link allows every VLAN (it removed the vpcfp-style list of this pair's VLANs + L3 VLANs; no traffic change)
    o += [f"interface port-channel{NX_PL_PO}", "  description vPC virtual peer-link (no members)", "  switchport", "  switchport mode trunk",
          "  spanning-tree port type network", "  vpc peer-link"]
    mode = lambda tagged, v: (["  switchport mode trunk", f"  switchport trunk allowed vlan {v}"] if tagged else ["  switchport mode access", f"  switchport access vlan {v}"])
    for po, ports, tagged, host in nx_members(sw):
        o += [f"interface port-channel{po}", f"  description {host}", "  switchport", *mode(tagged, host_vlan(host)), "  mtu 9216", "  spanning-tree port type edge" + (" trunk" if tagged else ""), f"  vpc {po}"]
    o += nx_nve(zones, True, True) + nx_uplink("Ethernet1/1", "fe-spine1", True) + nx_uplink("Ethernet1/2", "fe-spine2", True)
    for po, ports, tagged, host in nx_members(sw):
        # lacp rate fast: the switch asks for 1 s LACPDUs (3 s timeout), as vEX `periodic fast` and Cumulus do. Without it a server leg that goes
        # down on the SERVER side (virtual wire: the leaf keeps carrier) blackholed that leaf's flows for 11 s on nxprobe; with it 0.4 s.
        for p in ports: o += [f"interface Ethernet1/{p}", f"  description {host}", "  switchport", *mode(tagged, host_vlan(host)), "  mtu 9216", f"  channel-group {po} mode active", "  lacp rate fast", "  no shutdown"]
    if MULTI and sw["pair"] == HOSTS["storage"]["pair"]:   # storage management: FM1 on the pair's first leaf, FM2 on the second; no bond, no vPC (orphan ports)
        fm = PAIR[sw["pair"]].index(name) + 1
        o += [f"interface Ethernet1/{STOR_MGMT['port']}", f"  description storage fm{fm} management", "  switchport", "  switchport mode access",
              f"  switchport access vlan {ZONE['stor-mgmt']['vlan']}", "  spanning-tree port type edge", "  no shutdown"]
    o += nx_bgp(name, zones) + ["evpn"]
    for z in zones: o += [f"  vni {10000 + z['vlan']} l2", "    rd auto", f"    route-target import {z['rt_l2']}", f"    route-target export {z['rt_l2']}"] \
                         + (["    route-target import auto", "    route-target export auto"] if NDFC else [])
    return "\n".join(o + nx_tail(name)) + "\n"

def nx_border(name, sw):
    zones = nx_zones(); i = int(name[-1]) - 1        # fe-border1 = first /30 of each zone, fe-border2 = second
    o = nx_head(name, ["ospf", "bgp", "fabric forwarding", "interface-vlan", "vn-segment-vlan-based", "lldp", "nv overlay", "nxapi", "scp-server"], False)
    h = AGW_MAC.replace(":", "")      # no anycast SVIs here, but NDFC checks every leaf-type switch (borders too) for the fabric anycast MAC
    o.append(f"fabric forwarding anycast-gateway-mac {h[:4]}.{h[4:8]}.{h[8:]}")
    for z in zones: o += [f"vlan {z['l3vlan']}", f"  name {z['vrf']}-L3VNI", f"  vn-segment {z['l3vni']}"]
    o += nx_vrf(zones)
    o += nx_loop(0, sw["lo"], "router-id / BGP / unnumbered source") + nx_loop(1, nx_ids(name)["lo1"], "VTEP")
    o += nx_nve(zones, False, False) + nx_uplink("Ethernet1/1", "fe-spine1", False) + nx_uplink("Ethernet1/2", "fe-spine2", False)
    o += ["interface Ethernet1/3", f"  description {FW['hostname']}", "  no switchport", "  mtu 9216"] + \
         ([] if ZONE[VRF]["tag"] else [f"  vrf member {VRF}", f"  ip address {sw['fw_ip']}"]) + ["  no shutdown"]     # tagged VLAN 100: the parent only carries the sub-interfaces
    for z in zones:
        if z["tag"]: o += [f"interface Ethernet1/3.{z['tag']}", f"  description {FW['hostname']} {z['vrf']}", f"  encapsulation dot1q {z['tag']}", "  mtu 9216",
                           f"  vrf member {z['vrf']}", f"  ip address {nth(z['fw_nets'][i], 1)}/30", "  no shutdown"]
    # the firewall keeps peering with AS 65104 (fw.xml and the operator's bootstrap/fw-override.xml): the border presents that AS to it alone, in every VRF
    fw_nh = lambda z: sw["fw_nh"] if not z["tag"] else nth(z["fw_nets"][i], 2)
    o += nx_bgp(name, zones, lambda z: [f"    neighbor {fw_nh(z)}", f"      remote-as {FW_ASN}", f"      local-as {sw['asn']} no-prepend replace-as",
                                         f"      description {FW['hostname']}", "      address-family ipv4 unicast"])
    if NDFC: o.append("evpn")      # NDFC leaves a bare `evpn` on the borders (no L2 VNIs there)
    return "\n".join(o + nx_tail(name)) + "\n"

# ---------------------------------------------------------------- OcNOS builders (every block ends in `commit`; one rejected value poisons later commits)
def be_globals():
    # Production lines the VM CLI does not have (hardware only) are left out: load-balance rtag7 *, dynamic-load-balance enable,
    # fault-management enable, default-interface load-interval, vlan-reservation, port breakout, qsfp-dd. maximum-paths 64 needs a reboot; the VM default (8) covers 4 spines.
    # Keep the console session vrnetlab leaves logged in (con.py relies on it; default idle logout ~10 min) and do the same for
    # the SSH/vty lines. OcNOS needs the vty RANGE: bare `line vty` enters (config-all-line), which REJECTS exec-timeout
    # ("% Invalid input detected") -- `line vty 0 871` gives (config-line), which accepts it. Verified live on be-leaf1.
    access = ["line console 0", " exec-timeout 0 0", "exit",
              "line vty 0 871", " exec-timeout 0 0", "exit", "commit"]
    keys = operator_keys()                                                  # operator keys for the vrnetlab admin user (refplat does the same on NX-OS); OcNOS keeps one line per key
    if keys: access += [f"username admin sshkey {k}" for k in keys] + ["commit"]
    # SNMP v2c for Weft in the management VRF (validated live: the community needs its own view binding, `group network-operator` alone answers "No Such Object")
    snmp = ["snmp-server view all .1 included vrf management", f"snmp-server community {SNMP_COMMUNITY} view all version v2c ro vrf management",
            "snmp-server enable snmp vrf management", "commit",
            f"snmp-server host {SNMP_TRAP_HOST} traps version 2c {SNMP_COMMUNITY} udp-port 162 vrf management", "commit",
            "snmp-server enable traps bgp", "snmp-server enable traps snmp authentication", "commit"]       # link linkDown/linkUp traps are on by default
    return access + snmp + ["qos enable", "commit",
            f"default-interface type eth-routed mtu {BE_MTU}", f"default-interface type eth-switchport mtu {BE_MTU}", f"default-interface type svi mtu {BE_MTU}", "commit",
            "bridge 1 protocol mstp", "commit",
            "errdisable cause stp-bpdu-guard", "data-center-bridging enable bridge 1", "priority-flow-control enable bridge 1", "commit",
            "lldp run", "lldp tlv-select basic-mgmt port-description", "lldp tlv-select basic-mgmt system-name", "lldp tlv-select basic-mgmt system-capabilities",
            "lldp tlv-select basic-mgmt system-description", "lldp tlv-select basic-mgmt management-address", "bridge 1 priority 0", "commit"]

def be_bgp(asn, lo, peers, leaf):
    """eBGP leaf-spine (user decision 2026-09-17). Production runs iBGP AS 1 with the spines as route reflectors over BGP unnumbered,
    where every next-hop is the adjacent spine. On the OcNOS VM unnumbered never leaves Idle, a route reflector does not rewrite
    next-hops (next-hop-self and an outbound set ip next-hop are both ignored for reflected routes), and the kernel refuses multipath
    over recursive next-hops -- so iBGP+RR forwards over one spine only. eBGP restores adjacent-spine next-hops and 4-way ECMP with
    production's own `max-paths ebgp 64`. peers = [(address, remote-as)]."""
    o = []
    # Leaves AND spines advertise rails/loopback only -- the prefix set production advertises. Production runs BGP unnumbered on the
    # leaf-spine links, and unnumbered is a property of the LINK, not one end of it: production's spine side has no IPv4 subnet to leak
    # either. Filtering only the leaf was asymmetric and self-defeating -- the spines re-originated all 32 /31s, so every device still
    # held them (measured 2026-09-27: 33 p2p prefixes in be-leaf1's table, all from AS 65200 origin ?, and each spine originated its 8
    # link /31s). `ge 31 le 31` leaves the /32 loopbacks alone so `permit 20` still carries them, and eth0 is in the management VRF so
    # it was never in this BGP. The prefix-list must exist BEFORE the redistribute references it, which is the order used here.
    o += [f"ip prefix-list PL-FABRIC-P2P seq 5 permit {BE_P2P}.0.0/16 ge 31 le 31", "route-map RM-CONNECTED deny 10",
          " match ip address prefix-list PL-FABRIC-P2P", "exit", "route-map RM-CONNECTED permit 20", "exit", "commit"]
    o += [f"router bgp {asn}", f" bgp router-id {lo}", " bgp log-neighbor-changes", " no bgp inbound-route-filter"]
    timers = ["as-origination-interval 1", "advertisement-interval 0", "fall-over bfd"]      # production peer-group settings
    if leaf:   # all four spines share one AS, so production's peer-group shape survives. OcNOS: the group needs its remote-as before members join
        o += [" neighbor IPV4_UNDERLAY peer-group", f" neighbor IPV4_UNDERLAY remote-as {peers[0][1]}"] + [f" neighbor IPV4_UNDERLAY {t}" for t in timers]
        o += [f" neighbor {p} peer-group IPV4_UNDERLAY" for p, _ in peers]
        act = [" neighbor IPV4_UNDERLAY activate"]
    else:      # every leaf is a different AS: a peer-group cannot carry the remote-as, so the same settings go on each neighbour
        for p, ras in peers: o += [f" neighbor {p} remote-as {ras}"] + [f" neighbor {p} {t}" for t in timers]
        act = [f" neighbor {p} activate" for p, _ in peers]
    o += [" address-family ipv4 unicast", " max-paths ebgp 64", " redistribute connected route-map RM-CONNECTED"] + act
    return o + [" exit-address-family", "exit", "commit"]

def be_spine(name, sw):
    s = sw["idx"]; o = be_globals()
    o += ["interface lo", " description ***Router ID***", f" ip address {sw['lo']}/32 secondary", "exit"]
    for l in range(1, RAILS + 1): o += [f"interface eth{l}", f" description *be-leaf{l}*", f" ip address {p2p(s, l)[0]}/31", "exit"]
    o.append("commit")
    return "\n".join(o + be_bgp(BE_SPINE_ASN, sw["lo"], [(p2p(s, l)[1], BE_LEAF_ASN + l) for l in range(1, RAILS + 1)], False)) + "\n"

def be_leaf(name, sw):
    l = sw["idx"]; vlan = l * 10; o = be_globals()
    o += ["vlan database", f" vlan {vlan} bridge 1 name RAIL_{l} state enable", "exit", "commit"]
    for n in range(1, N_GPU + 1):
        o += [f"interface eth{BE_NSPINES + n}", f" description *gpu{n}, GPU{l}*", " switchport", " bridge-group 1", " switchport mode access", f" switchport access vlan {vlan}", "exit"]
    o += ["commit", f"interface vlan1.{vlan}", f" ip address {RAIL_PREFIX}.{l}.1/24", "exit", "commit",
          "interface lo", " description ***Router ID***", f" ip address {sw['lo']}/32 secondary", "exit"]
    for s in range(1, BE_NSPINES + 1): o += [f"interface eth{s}", f" description *be-spine{s}*", f" ip address {p2p(s, l)[1]}/31", "exit"]
    o.append("commit")
    return "\n".join(o + be_bgp(BE_LEAF_ASN + l, sw["lo"], [(p2p(s, l)[0], BE_SPINE_ASN) for s in range(1, BE_NSPINES + 1)], True)) + "\n"

# ---------------------------------------------------------------- PAN-OS (as refplat: XML tree loaded via the API by the vrnetlab launcher)
def fw_xml():
    def ip_entries(ips): return "".join(f'<entry name="{i}"/>' for i in ips)
    def zone(n, members): return f'<entry name="{n}"><network><layer3>{"".join(f"<member>{m}</member>" for m in members)}</layer3></network></entry>'
    def rule(n, frm, to, src, dst, svc, action):
        return (f'<entry name="{n}"><from><member>{frm}</member></from><to><member>{to}</member></to>'
                f'<source><member>{src}</member></source><destination><member>{dst}</member></destination>'
                f'<application><member>any</member></application><service><member>{svc}</member></service>'
                f'<action>{action}</action><log-end>yes</log-end></entry>')
    intfs = {"ethernet1/1": [FW["e1"]], "ethernet1/2": [FW["e2"]], "ethernet1/3": [FW["e3"]], "ethernet1/4": [FW["e4"]], "ethernet1/5": [FW["e5"]], "ethernet1/6": [FW["e6"]]}
    # LLDP on every data interface, with a profile that adds the OPTIONAL TLVs. PAN-OS sends only the mandatory ones by default
    # (ChassisID, PortID, TTL), so the firewall showed up on its neighbours as a bare MAC with no name -- the Cumulus leaves, the
    # OOB vEX and the PCs all had an LLDP entry for it that was easy to mistake for "no neighbour at all". With the profile it
    # advertises SysName ai-fabric-fw and "Palo Alto Networks VM-Series firewall". Schema taken from a validated push, not invented.
    eth = "".join(f'<entry name="{i}"><layer3><ip>{ip_entries(ips)}</ip><mtu>9216</mtu><interface-management-profile>allow-ping</interface-management-profile>'
                  f'<lldp><enable>yes</enable><profile>ai-fabric</profile></lldp></layer3></entry>' for i, ips in intfs.items())
    members = "".join(f"<member>{i}</member>" for i in intfs)
    UI = PF["fw_ui"]; out = FW["e5"].split("/")[0]; ui_prof = ui_lo = ui_svc = ""; inet = ["ethernet1/5"]
    if UI:
        members += "<member>loopback.1</member>"; inet.append("loopback.1")
        ui_prof = f'<entry name="fw-ui"><https>yes</https><ping>yes</ping><permitted-ip><entry name="{UI["permit"]}"/></permitted-ip></entry>'
        ui_lo = (f'<loopback><units><entry name="loopback.1"><ip><entry name="{UI["loopback"]}/32"/></ip>'
                 f'<interface-management-profile>fw-ui</interface-management-profile></entry></units></loopback>')
        ui_svc = f'<entry name="fw-ui-port"><protocol><tcp><port>{UI["port"]}</port></tcp></protocol></entry>'
    routes = (f'<entry name="default-internet"><destination>0.0.0.0/0</destination><interface>ethernet1/5</interface><nexthop><ip-address>{FW["e5_gw"]}</ip-address></nexthop><metric>10</metric></entry>'
              '<entry name="default-discard"><destination>0.0.0.0/0</destination><nexthop><discard/></nexthop><metric>250</metric></entry>')
    def peer(n, intf, local, remote):
        return (f'<entry name="{n}"><peer-as>{FE[n]["asn"]}</peer-as><enable>yes</enable><local-address><interface>{intf}</interface><ip>{local}</ip></local-address>'
                f'<peer-address><ip>{remote}</ip></peer-address></entry>')
    bgp = (f'<protocol><redist-profile><entry name="default-route"><priority>1</priority><action><redist/></action>'
           f'<filter><type><member>static</member></type><destination><member>0.0.0.0/0</member></destination></filter></entry></redist-profile>'
           f'<bgp><enable>yes</enable><router-id>{FW["e1"].split("/")[0]}</router-id><local-as>{FW_ASN}</local-as><install-route>yes</install-route>'
           f'<allow-redist-default-route>yes</allow-redist-default-route><redist-rules><entry name="default-route"><address-family-identifier>ipv4</address-family-identifier><enable>yes</enable></entry></redist-rules>'
           f'<peer-group><entry name="fabric"><type><ebgp><remove-private-as>no</remove-private-as><import-nexthop>original</import-nexthop><export-nexthop>resolve</export-nexthop></ebgp></type><enable>yes</enable><peer>'
           + peer("fe-border1", "ethernet1/1", FW["e1"], FE["fe-border1"]["fw_ip"].split("/")[0]) + peer("fe-border2", "ethernet1/2", FW["e2"], FE["fe-border2"]["fw_ip"].split("/")[0])
           + '</peer></entry></peer-group></bgp></protocol>')
    rules = (rule("enterprise-to-fabric", "enterprise", "fabric", "any", "any", "any", "allow")
             + rule("enterprise-to-oob", "enterprise", "oob", "any", "any", "any", "allow")
             + rule("fabric-to-storage-api", "fabric", "oob", FE_NET, oob(HOSTS["storage"]["ip"]), "tcp-443", "allow")
             + rule("fabric-to-enterprise", "fabric", "enterprise", "any", "any", "any", "allow")
             + rule("fabric-intrazone-bgp", "fabric", "fabric", "any", "any", "any", "allow")     # PAN-OS evaluates its own BGP/ping as fabric->fabric (refplat note)
             + rule("fabric-to-internet", "fabric", "internet", "any", "any", "any", "allow")
             + rule("enterprise-to-internet", "enterprise", "internet", "any", "any", "any", "allow")
             + rule("oob-to-internet", "oob", "internet", "any", "any", "any", "allow")
             # Office-LAN workstations (ubuntu-desktop, winserver: 10.80.15.0/24 = zone internet) reach the platform THROUGH the firewall,
             # as in the sibling Nexus / FTOS labs: a static route to the node subnet via ethernet1/5 (or the DNAT below), the bastion as resolver.
             + (f'<entry name="internet-to-inside-vips"><from><member>internet</member></from><to><member>fabric</member></to>'
                f'<source><member>any</member></source><destination><member>{FE_NET}</member><member>{FW["e5"].split("/")[0]}</member></destination>'   # routed VIPs + the DNAT pre-NAT address
                f'<application><member>any</member></application><service><member>cluster-access</member></service><action>allow</action><log-end>yes</log-end></entry>')
             + (f'<entry name="internet-to-bastion-dns"><from><member>internet</member></from><to><member>fabric</member></to>'
                f'<source><member>any</member></source><destination><member>{BASTION_IP}</member></destination>'
                f'<application><member>any</member></application><service><member>cluster-dns-tcp</member><member>cluster-dns-udp</member></service><action>allow</action><log-end>yes</log-end></entry>')
             + (rule("internet-to-fw-ui", "internet", "internet", UI["permit"], out, "fw-ui-port", "allow") if UI else "")
             + rule("deny-all-log", "any", "any", "any", "any", "any", "deny"))
    nat = ('<entry name="internet-snat"><from><member>fabric</member><member>enterprise</member><member>oob</member></from><to><member>internet</member></to>'
           '<source><member>any</member></source><destination><member>any</member></destination><service>any</service>'
           '<source-translation><dynamic-ip-and-port><interface-address><interface>ethernet1/5</interface></interface-address></dynamic-ip-and-port></source-translation></entry>')
    nat += (f'<entry name="dnat-gateway-vip"><from><member>internet</member></from><to><member>internet</member></to><source><member>any</member></source>'
            f'<destination><member>{FW["e5"].split("/")[0]}</member></destination><service>service-https</service>'
            f'<destination-translation><translated-address>{GW_VIP}</translated-address></destination-translation></entry>')
    if UI:
        nat += (f'<entry name="dnat-fw-ui"><from><member>internet</member></from><to><member>internet</member></to><source><member>any</member></source>'
                f'<destination><member>{out}</member></destination><service>fw-ui-port</service>'
                f'<destination-translation><translated-address>{UI["loopback"]}</translated-address><translated-port>443</translated-port></destination-translation></entry>')
    x = f"""<config version="12.1.0" urldb="paloaltonetworks" detail-version="12.1.2">
  <devices><entry name="localhost.localdomain">
    <network>
      <lldp><enable>yes</enable></lldp>
      <profiles><interface-management-profile><entry name="allow-ping"><ping>yes</ping></entry>{ui_prof}</interface-management-profile>
        <lldp-profile><entry name="ai-fabric"><mode>transmit-receive</mode><option-tlvs><system-name>yes</system-name>
          <system-description>yes</system-description><system-capabilities>yes</system-capabilities><port-description>yes</port-description>
        </option-tlvs></entry></lldp-profile></profiles>
      <interface><ethernet>{eth}</ethernet>{ui_lo}</interface>
      <virtual-router><entry name="default"><interface>{members}</interface>
        <routing-table><ip><static-route>{routes}</static-route></ip></routing-table>{bgp}</entry></virtual-router>
    </network>
    <deviceconfig><system><hostname>{FW['hostname']}</hostname><timezone>UTC</timezone>
      <!-- The management plane resolves log addresses by reverse DNS. Pointing it at the bastion BIND (which holds the
           in-addr.arpa zones for the lab subnets and forwards everything else upstream) makes Monitor > Traffic show
           ctrl1.lab.ai / gpu7.lab.ai in the SOURCE column instead of bare 10.1.1.x, and still resolves public destinations. -->
      <dns-setting><servers><primary>{M}.117</primary><secondary>{M}.1</secondary></servers></dns-setting>
      <service><disable-snmp>no</disable-snmp></service>
      <snmp-setting><access-setting><version><v2c><snmp-community-string>{SNMP_COMMUNITY}</snmp-community-string></v2c></version></access-setting></snmp-setting></system>
      <setting><auto-mac-detect>yes</auto-mac-detect><jumbo-frame><mtu>9216</mtu></jumbo-frame></setting></deviceconfig>
    <vsys><entry name="vsys1">
      <import><network><interface>{members}</interface></network></import>
      <zone>{zone("fabric", ["ethernet1/1", "ethernet1/2"])}{zone("oob", ["ethernet1/3"])}{zone("enterprise", ["ethernet1/4", "ethernet1/6"])}{zone("internet", inet)}</zone>
      <service><entry name="tcp-443"><protocol><tcp><port>443</port></tcp></protocol></entry>{ui_svc}
        <entry name="cluster-access"><protocol><tcp><port>80,443,6443</port></tcp></protocol></entry>
        <entry name="cluster-dns-tcp"><protocol><tcp><port>53</port></tcp></protocol></entry>
        <entry name="cluster-dns-udp"><protocol><udp><port>53</port></udp></protocol></entry></service>
      <rulebase><security><rules>{rules}</rules></security><nat><rules>{nat}</rules></nat></rulebase>
    </entry></vsys>
  </entry></devices>
</config>
"""
    return ET.tostring(fw_vlans(ET.fromstring(x)), encoding="unicode") + "\n" if MULTI else x

# ---------------------------------------------------------------- PAN-OS: the site-a-nx VLAN design as ONE transformation of a config tree. gen.py
# applies it to its own fw.xml (config of record) and fw-merge-vlans.py applies the SAME function to the operator's bootstrap/fw-override.xml, so the two
# cannot drift. Idempotent: running it twice changes nothing. Operator decisions 2026-09-23:
#   add     sub-interfaces .100 / .200 / .300 on ethernet1/1 + 1/2 (towards fe-border1/2), zones stor-mgmt + bastion, one eBGP peer per sub-interface
#           (AS 65104), allow VLAN 100 -> 200 tcp/443, VLAN 300 -> 100 and 300 -> 200 tcp 22/80/443/6443, every VLAN -> internet (DNS/NTP on dns-b + egress,
#           source NAT), intrazone for the firewall's own BGP in the new zones (as fabric-intrazone-bgp); DNS + NTP of the firewall = dns-b over its
#           MANAGEMENT port (operator 2026-09-23, like the switches): no service route, so no data-plane policy is involved
#   move    VLAN 100 (VRF k8s) from the untagged parents to .100 (same /30 addresses; peers fe-border1/2 keep their names); the parents keep their
#           physical settings (MTU, LLDP) and lose address, ping profile, zone and virtual-router membership
#   rename  zone fabric -> data, in every rule / NAT that uses it, and "fabric" in rule names (fabric-to-internet -> data-to-internet). The BGP peer-group
#           "fabric" is not a zone and keeps its name
#   remove  internet-to-bastion-dns (the bastion no longer serves DNS), fabric-to-storage-api (storage management left the OOB network), bastion DNS servers
#   keep    everything else (enterprise, OOB/BMC, office-LAN access to the platform, data -> enterprise)
def fw_vlans(root):
    if not MULTI: return root
    dev = root.find("devices/entry"); net = dev.find("network"); vs = dev.find("vsys/entry")
    def kid(parent, tag, name=None):
        for c in parent.findall(tag):
            if name is None or c.get("name") == name: return c
        c = ET.SubElement(parent, tag)
        if name is not None: c.set("name", name)
        return c
    def text(parent, tag, value): kid(parent, tag).text = value
    def members(parent, values):
        have = {m.text for m in parent.findall("member")}
        for v in values:
            if v not in have: ET.SubElement(parent, "member").text = v
    # zone fabric -> data first (zone, rule / NAT references, rule names), so everything below finds and creates the new names only
    zones = kid(vs, "zone"); old = zones.find("entry[@name='fabric']")
    if FZ != "fabric" and old is not None and zones.find(f"entry[@name='{FZ}']") is None: old.set("name", FZ)
    for m in vs.findall("rulebase/*/rules/entry/from/member") + vs.findall("rulebase/*/rules/entry/to/member"):
        if m.text == "fabric": m.text = FZ
    for r in vs.findall("rulebase/*/rules/entry"): r.set("name", fw_rule(r.get("name")))
    zname = lambda vrf: FZ if vrf == VRF else vrf            # firewall zone of a VRF (VRF k8s = the historical fabric zone)
    tz = [z for z in NX_ZONES if z["tag"]]
    parents = ("ethernet1/1", "ethernet1/2")
    subifs = {}                                             # zone vrf -> [(firewall sub-interface, firewall address, border address, border name)]
    for z in tz:
        for i, parent in enumerate(parents):
            subifs.setdefault(z["vrf"], []).append((f"{parent}.{z['tag']}", f"{nth(z['fw_nets'][i], 2)}/30", nth(z["fw_nets"][i], 1), f"fe-border{i + 1}", parent, z["tag"]))
    eth = net.find("interface/ethernet"); vr = net.find("virtual-router/entry")
    if ZONE[VRF]["tag"]:                                    # VLAN 100 tagged: the parents only carry sub-interfaces (address moves to .100 below)
        for parent in parents:
            l3 = kid(kid(eth, "entry", parent), "layer3")
            for tag in ("ip", "interface-management-profile"):
                for c in l3.findall(tag): l3.remove(c)
        for container in (kid(vr, "interface"), kid(kid(kid(zones, "entry", FZ), "network"), "layer3")):
            for m in list(container.findall("member")):
                if m.text in parents: container.remove(m)
    for vrf, lst in subifs.items():
        for sif, fwip, _, _, parent, tag in lst:
            u = kid(kid(kid(eth, "entry", parent), "layer3"), "units")
            e = kid(u, "entry", sif); text(e, "tag", str(tag)); ips = kid(e, "ip"); kid(ips, "entry", fwip)
            text(e, "mtu", "9216"); text(e, "interface-management-profile", "allow-ping")
    members(kid(vr, "interface"), [s[0] for l in subifs.values() for s in l])
    members(kid(kid(kid(vs, "import"), "network"), "interface"), [s[0] for l in subifs.values() for s in l])
    for vrf, lst in subifs.items(): members(kid(kid(kid(zones, "entry", zname(vrf)), "network"), "layer3"), [s[0] for s in lst])
    peers = vr.find("protocol/bgp/peer-group/entry/peer")
    for vrf, lst in subifs.items():
        for sif, fwip, bip, bname, _, _ in lst:
            pe = kid(peers, "entry", bname if vrf == VRF else f"{bname}-{vrf}"); text(pe, "peer-as", str(FE[bname]["asn"])); text(pe, "enable", "yes")
            la = kid(pe, "local-address"); text(la, "interface", sif); text(la, "ip", fwip); text(kid(pe, "peer-address"), "ip", bip)
    svc = kid(vs, "service"); se = kid(svc, "entry", "bastion-mgmt"); text(kid(kid(se, "protocol"), "tcp"), "port", "22,80,443,6443")
    for s in list(svc):      # only internet-to-bastion-dns (removed below) used these: the bastion no longer serves DNS
        if s.get("name") in ("cluster-dns-tcp", "cluster-dns-udp"): svc.remove(s)
    rules = vs.find("rulebase/security/rules")
    for r in list(rules):
        if r.get("name") in ("internet-to-bastion-dns", fw_rule("fabric-to-storage-api")): rules.remove(r)
    sm, bz = ZONE["stor-mgmt"], ZONE["bastion"]; smnet, bnet = f"{nth(sm['gw'], -1)}/24", f"{nth(bz['gw'], -1)}/24"
    new = [(fw_rule("fabric-to-stor-mgmt"), FZ, "stor-mgmt", FE_NET, smnet, "tcp-443"),
           (fw_rule("bastion-to-fabric"), "bastion", FZ, bnet, FE_NET, "bastion-mgmt"),
           ("bastion-to-stor-mgmt", "bastion", "stor-mgmt", bnet, smnet, "bastion-mgmt"),
           ("stor-mgmt-to-internet", "stor-mgmt", "internet", "any", "any", "any"),
           ("bastion-to-internet", "bastion", "internet", "any", "any", "any"),
           ("stor-mgmt-intrazone-bgp", "stor-mgmt", "stor-mgmt", "any", "any", "any"),      # the firewall's own BGP to the borders (deny-all-log would catch it)
           ("bastion-intrazone-bgp", "bastion", "bastion", "any", "any", "any")]
    deny = rules.find("entry[@name='deny-all-log']")
    for name, frm, to, src, dst, s in new:
        if rules.find(f"entry[@name='{name}']") is not None: continue
        e = ET.Element("entry", name=name)
        for tag, v in (("from", frm), ("to", to), ("source", src), ("destination", dst), ("application", "any"), ("service", s)): ET.SubElement(ET.SubElement(e, tag), "member").text = v
        ET.SubElement(e, "action").text = "allow"; ET.SubElement(e, "log-end").text = "yes"
        rules.insert(list(rules).index(deny) if deny is not None else len(rules), e)
    snat = vs.find("rulebase/nat/rules/entry[@name='internet-snat']/from")
    if snat is not None: members(snat, ["stor-mgmt", "bastion"])
    sysx = dev.find("deviceconfig/system")
    srv = kid(kid(sysx, "dns-setting"), "servers")
    for c in list(srv): srv.remove(c)
    text(srv, "primary", DNS_NTP)
    text(kid(kid(sysx, "ntp-servers"), "primary-ntp-server"), "ntp-server-address", DNS_NTP)
    # the firewall's own DNS/NTP use the management port (PAN-OS default when no service route names them). The first cut routed them out of
    # ethernet1/5: PAN-OS then runs them through the security policy as intrazone internet -> internet, and deny-all-log (above the implicit
    # intrazone allow) dropped every query. Remove such service routes -- and the then-empty <route>, which the operator's capture never had.
    route = sysx.find("route")
    if route is not None:
        service = route.find("service")
        if service is not None:
            for e in list(service.findall("entry")):
                if e.get("name") in ("dns", "ntp"): service.remove(e)
            if len(service) == 0: route.remove(service)
        if len(route) == 0: sysx.remove(route)
    return root

# ---------------------------------------------------------------- containerlab topology
def stor_mgmt_env(n):
    """site-a-nx storage node: no OOB NIC; two management NICs (FM1, FM2) on the control pair, VLAN 200, floating VIP for the management API."""
    if not (MULTI and n == "storage"): return {}
    sm = STOR_MGMT
    return dict(OOB_IP="", NODE_SM_NICS="2", NODE_SM_FM1=sm["fm"][0], NODE_SM_FM2=sm["fm"][1], NODE_SM_VIP=sm["vip"], NODE_SM_GW=sm["gw"], NODE_SM_PREFIX=sm["prefix"])

def topology(light=False):
    k = K8S
    # MGMT_GW is the clab management network's gateway (containerlab gives that bridge the subnet's first address, which is this
    # host). netsetup.sh needs it to (re)build the management table (150), and cannot always read it off eth0: its own first run moves that default
    # out of the main table, so a later run -- node-sync applying network files live, finish.sh stage 3 -- finds nothing there.
    # lab logins reach the guests through the node env (cloud-init renders user-data.tmpl with envsubst)
    _rootpw = _env("LAB_ROOT_PASSWORD", "admin"); _adminpw = _env("LAB_ADMIN_PASSWORD", "admin")
    common = dict(LAB_ROOT_PASSWORD=_rootpw, LAB_ADMIN_PASSWORD=_adminpw, MGMT_GW=f"{M}.1", DOMAIN=DOMAIN, CLUSTER_NAME=CLUSTER, API_VIP=API_VIP, GW_VIP=GW_VIP, LB_MODE="l2", LB_POOL_CIDR=FE_NET,
                  BGP_VLAN="", BGP_PEER_A="", BGP_PEER_B="", BGP_PEER_ASN="", BGP_LOCAL_ASN="", CILIUM_BGP="false", CILIUM_DEVICES=CILIUM_DEVICES,
                  LB_POOL_START=LB_START, LB_POOL_END=LB_END, DNS_SERVER=DNS_NTP or BASTION_IP, NTP_SERVER=DNS_NTP or BASTION_IP, FABRIC_CIDR=k["fabric_cidr"], NODE_MTU=k["mtu"],
                  NODE_HOSTS=NODE_HOSTS, POD_CIDR=k["pod_cidr"], SVC_CIDR=k["svc_cidr"], K8S_VERSION=k["k8s_version"],
                  JOIN_TOKEN=_env("LAB_JOIN_TOKEN", "CHANGEME.generate0a1b2c3d"), CERT_KEY=_env("LAB_CERT_KEY", "CHANGEME_64_HEX_CHARS"), EXPECT_NODES=str(len(HOSTS)),   # LAB bootstrap secrets, lab-internal
                  CILIUM_VERSION=k["cilium_version"], CERTMGR_VERSION="", GATEWAY_API_VERSION=k["gateway_api_version"],
                  DEMO_HOST=f"demo.platform.{DOMAIN}", HUBBLE_HOST=f"hubble.platform.{DOMAIN}", GPU_RAILS=str(RAILS), RAIL_PREFIX=RAIL_PREFIX,
                  MULTUS_VERSION=k["multus_version"], WHEREABOUTS_VERSION=k["whereabouts_version"], LONGHORN_VERSION=k["longhorn_version"],
                  HEADLAMP_CHART_VERSION=k["headlamp_chart_version"], METRICS_SERVER_VERSION=k["metrics_server_version"], WEBUI_IMAGE=k["webui_image"],
                  WEBUI_MODEL=k["webui_model"], WEBUI_API_BASE=k["webui_api_base"], WEBUI_HOST=f"webui.platform.{DOMAIN}", LONGHORN_HOST=f"longhorn.platform.{DOMAIN}",
                  OOB_PREFIX=OOB_PREFIX, OOB_GW=OOB_GW)
    if PF["mirrors"]: common["REGISTRY_MIRRORS"] = PF["mirrors"]
    if NETOP: common["RAIL_NADS"] = "operator"          # the bootstrap leaves the rail NADs to the network-operator (netop.sh: MacvlanNetwork net-rail-N)     # pull-through caches on the management gateway (registry-cache.sh)
    L = [textwrap.dedent(f"""\
    # {LAB}: Cumulus frontend + OcNOS rail backend + refplat-style k8s VM nodes. Generated by gen.py -- edit gen.py, not this file.
    name: {LAB}
    mgmt:
      network: {MGMT_NET}
      ipv4-subnet: {MGMT_SUBNET}
    topology:
      kinds:
        nvidia_cumulusvx:
          image: {CVX_IMAGE}
        juniper_vjunosswitch:
          image: {VEX_IMAGE}
        ipinfusion_ocnos:
          image: {OCNOS_IMAGE}
        paloalto_panos:
          image: {PAN_IMAGE}
        linux:
          dns:
            servers: [8.8.8.8, 1.1.1.1]
      nodes:
    """)]
    if not any(nos(n) == "vex" for n in FE): L[0] = L[0].replace(f"    juniper_vjunosswitch:\n      image: {VEX_IMAGE}\n", "")   # kind block only when a node uses it
    if any(nos(n) == "nxos" for n in FE):     # Nexus 9300v: vrnetlab applies configs/<switch>.cfg at first boot; mgmt0 carries the real management address
        L[0] = L[0].replace("    ipinfusion_ocnos:\n", f"    cisco_n9kv:\n      image: {NX_IMAGE}\n      env:\n        CLAB_MGMT_PASSTHROUGH: \"true\"\n"
                            # a stalled console bootstrap must not kill the node (vpcfp: the default ~1 h scrapli timeout made launch.py exit, links and all)
                            "        SCRAPLI_TIMEOUT: \"604800\"\n    ipinfusion_ocnos:\n", 1)
    # Staggered cold start (profiles with boot_stagger; site-b-nx 2026-10-01): 10 N9Kv + 12 OcNOS + the firewall booting in the same minute overloaded
    # site-b (one PERC volume): N9Kv took 20 min instead of ~10, vrnetlab's console bootstrap lost sync on 7 OcNOS and the PA-VM ("Login incorrect" /
    # stuck at "Enter old password", scrapli timeout after 1 h, container exit 1) and one N9Kv fell to the loader. OcNOS first, 20 s apart; the Nexus
    # switches after them, 60 s apart. containerlab creates the links once every node exists, so the deploy command returns ~13 min later.
    STAG = PF.get("boot_stagger"); nx_i = 0
    vex_i = 0
    for i, (n, s) in enumerate(FE.items()):
        if nos(n) == "vex":   # staggered starts: vrnetlab's make-config.sh races for loop devices when several vJunos nodes start in the same second
            L.append(f"    {n}:\n      kind: juniper_vjunosswitch\n      mgmt-ipv4: {s['mgmt']}\n      group: fe-{s['role']}\n      startup-config: configs/junos-keys.cfg\n      startup-delay: {vex_i * 15}\n")
            vex_i += 1
            continue
        if nos(n) == "nxos":
            L.append(f"    {n}:\n      kind: cisco_n9kv\n      mgmt-ipv4: {s['mgmt']}\n      group: fe-{s['role']}\n      startup-config: configs/{n}.cfg\n"
                     + (f"      startup-delay: {STAG['nxos_first'] + nx_i * STAG['nxos']}\n" if STAG else "")); nx_i += 1
            continue
        L.append(f"    {n}:\n      kind: nvidia_cumulusvx\n      mgmt-ipv4: {s['mgmt']}\n      group: fe-{s['role']}\n      startup-config: configs/{n}.cfg\n"
                 f"      binds:\n        - common:/bootstrap-keys:ro\n")
    for be_i, (n, s) in enumerate(BE.items()):   # clab 0.79 does not mount startup-config for this kind: bind it where the vrnetlab launcher looks
        L.append(f"    {n}:\n      kind: ipinfusion_ocnos\n      mgmt-ipv4: {s['mgmt']}\n      group: be-{s['role']}\n" + (f"      startup-delay: {be_i * STAG['ocnos']}\n" if STAG else "")
                 + f"      binds:\n        - configs/{n}.cfg:/config/startup-config.cfg:ro\n")
        # A RAIL LEAF carries 36 data interfaces (32 servers + 4 uplinks) against a spine's 8, and vrnetlab's default 4096 MB is not
        # enough for it under load: on 2026-09-20 be-leaf7 and be-leaf8 both sat at exactly 4004 MB RSS (their whole allocation) and
        # stopped answering ARP on their rail SVI while BGP stayed 4/4 Established and their CLI went unresponsive -- section G's ring
        # test (32 simultaneous iperf3 flows + 96 traceroutes) tipped them over. The host had 162 GB free and zero OOM kills, so this
        # was the guest running out, not the host. 6144 MB on the eight leaves costs 16 GB and leaves the spines at the default.
        if s["role"] == "leaf": L.append("      env:\n        QEMU_MEMORY: 6144\n")
    L.append(f"    {EXT_BRIDGE}:\n      kind: bridge   # eve's office-LAN bridge: the firewall's outside interface (as refplat)\n")
    # The PA-VM's overlay disk lives INSIDE its container, so every ./up.sh boots it from this startup-config and anything changed
    # in the web UI is otherwise lost. bootstrap/fw-override.xml (written by ./fw-backup.sh from the RUNNING configuration) wins
    # when it exists, so operator edits survive a redeploy -- at the cost that the generator's own firewall changes stop applying
    # until the override is re-captured or removed. fw.xml is still written either way, as the config of record for the audit.
    _fw_start = "bootstrap/fw-override.xml" if os.path.exists(os.path.join(ROOT, "bootstrap", "fw-override.xml")) else "bootstrap/fw.xml"
    if _fw_start.endswith("fw-override.xml"): print("NOTE: firewall boots from bootstrap/fw-override.xml (operator backup); gen.py's firewall configuration is NOT applied")
    L.append(f"    {FW['name']}:\n      kind: paloalto_panos\n      mgmt-ipv4: {FW['mgmt']}\n      group: firewall\n      startup-config: {_fw_start}\n"
             f"      env:\n        QEMU_CPU: host\n        QEMU_SMP: 8\n        QEMU_MEMORY: 16384\n")
    for n, h in HOSTS.items():
        last = int(h["ip"].split(".")[3])
        if light:   # --light: same cabling and NIC layout, no guest and no Kubernetes (fabric validation / network-only flavour of the lab)
            env = dict(NODE_IP=h["ip"], NODE_PREFIX=FE_PREFIX, NODE_GW=FE_GW, FABRIC_NICS=str(h.get("fabric_nics", 2)), NODE_VLAN=str(FE_VLAN) if h.get("tagged") else "",
                       RAIL_NICS=str(RAILS) if h.get("kind") == "gpu" else "", RAIL_PREFIX=RAIL_PREFIX, NODE_RAIL_INDEX=str(h.get("rail", "")),
                       NODE_MAC=f"50:00:22:{last:02x}:00:00", OOB_IP=oob(h["ip"]), OOB_PREFIX=OOB_PREFIX, OOB_GW=OOB_GW, NODE_MTU=k["mtu"])
            env.update(stor_mgmt_env(n))   # site-a-nx storage: OOB_IP cleared, FM1/FM2/VIP added
            L.append(f"    {n}:\n      kind: linux\n      image: {PC_IMAGE}\n      mgmt-ipv4: {h['mgmt']}\n      group: k8s\n      binds:\n        - common/light-host.sh:/light-host.sh:ro\n      env:\n")
            for kk, vv in env.items(): L.append(f'        {kk}: "{vv}"\n')
            L.append("      exec:\n        - sh /light-host.sh\n")
            continue
        env = dict(common, NODE_ROLE=h["role"], NODE_KIND=h.get("kind", ""), NODE_IP=h["ip"], NODE_PREFIX=FE_PREFIX, NODE_GW=FE_GW,
                   FABRIC_NICS=str(h.get("fabric_nics", 2)), NODE_VLAN=str(FE_VLAN) if h.get("tagged") else "",
                   RAIL_NICS=str(RAILS) if h.get("kind") == "gpu" else "",                                   # ai-fabric: REAL rail NICs on the GPU nodes
                   NODE_MAC=f"50:00:22:{last:02x}:00:00", NODE_BGP_IP="", NODE_RAIL_INDEX=str(h.get("rail", "")), NODE_HOSTNAME=n,
                   OOB_IP=oob(h["ip"]), VM_MEM=str(h["mem"]), VM_CPUS=str(h["cpus"]), VM_DISK="40G", VM_DATA="60G")
        env.update(stor_mgmt_env(n))
        L.append(f"    {n}:\n      kind: linux\n      image: {VM_IMAGE}\n      mgmt-ipv4: {h['mgmt']}\n      group: k8s\n      binds:\n"
                 f"        - {BASE_IMG_DIR}:/base:ro\n        - nodes/{n}/vm:/vm\n        - common/authorized_keys:/authorized_keys:ro\n        - shared:/shared\n"
                 + (f"        - {CA_DIR}:/ca:ro\n" if LAB_CA and h["role"] == "init" else "") + "      env:\n")   # lab CA keys: the init node only
        for kk, vv in env.items(): L.append(f'        {kk}: "{vv}"\n')
    bz = ZONE["bastion"] if MULTI else None      # site-a-nx: the bastion lives in VLAN 300 and no longer serves DNS/NTP (dns-b does)
    env = dict(common, BASTION_IP=BASTION_IP, BASTION_PREFIX=bz["gw"].split("/")[1] if bz else FE_PREFIX, BASTION_GW=bz["gw"].split("/")[0] if bz else FE_GW,
               BASTION_OOB=oob(BASTION_IP), NODE_MAC="50:00:22:11:00:17", MGMT_CIDR=MGMT_SUBNET,
               PC_IP=PC1["ip"], PC_NAME=PC1["name"], EXTRA_PTRS=extra_ptrs(), EXTRA_QUERY_CIDRS=PF.get("lan_cidr", ""),
               SWITCH_HOSTS=" ".join(f"{n}={s['mgmt']}" for n, s in {**FE, **BE}.items()) + f" {FW['hostname']}={FW['mgmt']}")
    if MULTI: env.update(BASTION_DNS="0", BASTION_NTP="0")
    L.append(f"    bastion:\n      kind: linux\n      image: {BASTION_IMAGE}\n      mgmt-ipv4: {BASTION['mgmt']}\n      group: k8s\n      binds:\n        - shared:/shared\n      env:\n")
    for kk, vv in env.items(): L.append(f'        {kk}: "{vv}"\n')
    for pc in (PC1, PC2):
        # AI_FABRIC_KEYFILE puts the inference bearer key on /shared (a host bind) instead of the container's own filesystem: a PC is a
        # plain container, so everything written inside it is gone after the next ./up.sh -- which is exactly how the copy of
        # inference-test.sh I had put in /root disappeared in the 2026-09-20 redeploy. On /shared one --save-key covers both PCs
        # and survives redeploys; the script writes it 0600.
        env = dict(LAB_ROOT_PASSWORD=_env("LAB_ROOT_PASSWORD", "admin"),
                   LAB_ADMIN_PASSWORD=_env("LAB_ADMIN_PASSWORD", "admin"), PC_IP=pc["ip"], PC_PREFIX=pc["prefix"], PC_GW=pc["gw"], DOMAIN=DOMAIN, DNS_SERVER=DNS_NTP or BASTION_IP, CLUSTER_NAME=CLUSTER, FABRIC_CIDR=k["fabric_cidr"], NODE_MTU="1500", MGMT_GW=f"{M}.1",
                   AI_FABRIC_KEYFILE=f"/shared/{CLUSTER}/inference-key")
        L.append(f"    {pc['name']}:\n      kind: linux\n      image: {PC_IMAGE}\n      mgmt-ipv4: {pc['mgmt']}\n      group: client\n"
                 f"      binds:\n        - common/pc-init.sh:/pc-init.sh:ro\n        - common/authorized_keys:/pc-authorized_keys:ro\n        - shared:/shared\n"
                 f"        - inference-test.sh:/usr/local/bin/inference-test.sh:ro\n      env:\n")
        for kk, vv in env.items(): L.append(f'        {kk}: "{vv}"\n')
        L.append("      exec:\n        - sh /pc-init.sh\n")

    L.append("  links:\n")
    def link(a, b): L.append(f'    - endpoints: ["{a}", "{b}"]\n')
    # frontend Clos
    for ln in FE_LEAVES:
        for i, sp in enumerate(FE_SPINES): link(f"{ln}:{fp(ln, i + 1)}", f"{sp}:{fp(sp, FE[ln]['sp'])}")
    # backend Clos: spine S ethL <-> leaf L ethS
    for s in range(1, BE_NSPINES + 1):
        for l in range(1, RAILS + 1): link(f"be-spine{s}:eth{l}", f"be-leaf{l}:eth{s}")
    # servers. NIC order inside a VM node (vm-init.sh): eth1..N frontend bond, eth(N+1) OOB/BMC, then the rails
    for n, h in HOSTS.items():
        l1, l2 = PAIR[h["pair"]]
        if h.get("members"):
            ms = h["members"]
            for i, m in enumerate(ms): link(f"{n}:eth{i + 1}", f"{l1}:{fp(l1, m)}")
            for i, m in enumerate(ms): link(f"{n}:eth{i + 1 + len(ms)}", f"{l2}:{fp(l2, m)}")
            nf = 2 * len(ms)
        else:
            link(f"{n}:eth1", f"{l1}:{fp(l1, h['port'])}"); link(f"{n}:eth2", f"{l2}:{fp(l2, h['port'])}"); nf = 2
        if stor_mgmt_env(n):   # site-a-nx: storage NIC N+1 = FM1 -> first control leaf, N+2 = FM2 -> second (both port STOR_MGMT['port']); off the OOB switch
            for i, lf in enumerate(PAIR[h["pair"]]): link(f"{n}:eth{nf + 1 + i}", f"{lf}:{fp(lf, STOR_MGMT['port'])}")
        else: link(f"{n}:eth{nf + 1}", f"oob-sw:{fp('oob-sw', OOB_PORTS[n])}")
        if h.get("kind") == "gpu":
            for r in range(1, RAILS + 1): link(f"{n}:eth{nf + 1 + r}", f"be-leaf{r}:eth{BE_NSPINES + h['n']}")     # GPU NIC r -> rail leaf r
    l1, l2 = PAIR[BASTION["pair"]]
    link("bastion:eth1", f"{l1}:{fp(l1, BASTION['port'])}"); link("bastion:eth2", f"{l2}:{fp(l2, BASTION['port'])}"); link("bastion:eth3", f"oob-sw:{fp('oob-sw', OOB_PORTS['bastion'])}")
    # firewall
    link(f"fe-border1:{fp('fe-border1', 3)}", f"{FW['name']}:eth1"); link(f"fe-border2:{fp('fe-border2', 3)}", f"{FW['name']}:eth2"); link(f"oob-sw:{fp('oob-sw', OOB_FW_PORT)}", f"{FW['name']}:eth3")
    link(f"{PC1['name']}:eth1", f"{FW['name']}:eth4"); link(f"{FW['name']}:eth5", f"{EXT_BRIDGE}:ai-fabric-fw-ext"); link(f"{PC2['name']}:eth1", f"{FW['name']}:eth6")
    return "".join(L)

def dns_zones(ns_ip, serial):
    """The lab's DNS as BIND zone files for an EXTERNAL server (site-a-nx: the office server dns-b took over DNS from the bastion, operator decision
    2026-09-23). Same records as images/bastion/bastion-dns.sh -- api -> API VIP, *.platform -> Gateway VIP, bastion, every node and PC, and a reverse
    zone per lab /24 -- plus the VLAN 200 storage management names. The office LAN /24 is NOT included: dns-b already owns that reverse zone.
    Returns (named.conf snippet, {file name: content})."""
    hosts = [kv.split("=") for kv in NODE_HOSTS.split()]
    extra = [p.split("=") for p in extra_ptrs().split() if not p.split("=")[0].startswith(PF.get("lan_cidr", "0.0.0.0/0").rsplit(".", 1)[0] + ".")]
    fwd = [("ns", ns_ip), ("api", API_VIP), ("*.platform", GW_VIP), ("bastion", BASTION_IP)] + [(h, a) for h, a in hosts if h != "bastion"]
    ptr = [(API_VIP, "api"), (BASTION_IP, "bastion")] + [(a, h) for h, a in hosts] + [(a, n) for a, n in extra]
    if MULTI:
        sm = STOR_MGMT; fwd += [("storage-fm1", sm["fm"][0]), ("storage-fm2", sm["fm"][1]), ("storage-mgmt", sm["vip"])]
        ptr += [(sm["fm"][0], "storage-fm1"), (sm["fm"][1], "storage-fm2"), (sm["vip"], "storage-mgmt")]
        ptr = [(a, n) for a, n in ptr if not (n == "storage-oob")]          # the storage node left the OOB network
    if LAB_CA: fwd.append(("fw-mgmt", FW["mgmt"]))     # the firewall UI certificate's name (its PTR is in the management reverse zone already)
    soa = lambda: [f"$TTL 3600", f"@ IN SOA ns.{DOMAIN}. hostmaster.{DOMAIN}. ( {serial} 3600 600 604800 3600 )", f"@ IN NS ns.{DOMAIN}."]
    files = {f"db.{DOMAIN}": "\n".join([f"; {DOMAIN} for the ai-fabric lab ({PROFILE}) -- generated by gen.py --dns-zones, do not edit on dns-b", f"$ORIGIN {DOMAIN}."] + soa()
                                         + [f"{n} IN A {a}" for n, a in fwd]) + "\n"}
    zones = {}
    for a, n in ptr: zones.setdefault(".".join(reversed(a.split(".")[:3])) + ".in-addr.arpa", {}).setdefault(a.split(".")[3], n)   # first name per address wins
    for z, recs in sorted(zones.items()):
        files[f"db.{z}"] = "\n".join([f"; ai-fabric lab reverse zone -- generated by gen.py --dns-zones", f"$ORIGIN {z}."] + soa()
                                     + [f"{o} IN PTR {n}.{DOMAIN}." for o, n in sorted(recs.items(), key=lambda x: int(x[0]))]) + "\n"
    conf = "\n".join([f"// ai-fabric lab zones ({PROFILE}) -- generated by gen.py --dns-zones"]
                     + [f'zone "{f[3:]}" {{ type primary; file "/etc/bind/zones/ai-fabric/{f}"; allow-transfer {{ none; }}; }};' for f in files]) + "\n"
    return conf, files

def main():
    for d in ("configs", "bootstrap", "shared"): os.makedirs(os.path.join(ROOT, d), exist_ok=True)
    for n in HOSTS: os.makedirs(os.path.join(ROOT, "nodes", n, "vm"), exist_ok=True)
    with open(os.path.join(ROOT, "mgmt-hosts.txt"), "w") as f:   # columns: clab node, management address, role
        for n, s in FE.items(): f.write(f"{n} {s['mgmt']} {dict(vex='junos', nxos='nxos').get(nos(n), 'cumulus')}\n")
        for n, s in BE.items(): f.write(f"{n} {s['mgmt']} ocnos\n")
        f.write(f"{FW['name']} {FW['mgmt']} firewall\n")
        for n, h in HOSTS.items(): f.write(f"{n} {h['mgmt']} host\n")
        f.write(f"bastion {BASTION['mgmt']} host\n")
        for pc in (PC1, PC2): f.write(f"{pc['name']} {pc['mgmt']} host\n")
    if any(nos(n) == "vex" for n in FE):   # vEX boot config = SSH keys only; the real configuration is configs/<switch>.set, pushed by apply-junos.sh
        open(os.path.join(ROOT, "configs", "junos-keys.cfg"), "w").write(junos_keys())
    jn_build = {"spine": jn_spine, "leaf": jn_leaf, "border": jn_border, "oob": jn_oob}
    cv_build = {"spine": fe_spine, "leaf": fe_leaf, "border": fe_border, "oob": fe_oob}
    nx_build = {"spine": nx_spine, "leaf": nx_leaf, "border": nx_border}
    for n, s in FE.items():
        if nos(n) == "vex": open(os.path.join(ROOT, "configs", f"{n}.set"), "w").write(jn_build[s["role"]](n, s))
        elif nos(n) == "nxos": open(os.path.join(ROOT, "configs", f"{n}.cfg"), "w").write(nx_shut_unused(nx_build[s["role"]](n, s)))
        else:               open(os.path.join(ROOT, "configs", f"{n}.cfg"), "w").write(cv_build[s["role"]](n, s))
    for n, s in BE.items(): open(os.path.join(ROOT, "configs", f"{n}.cfg"), "w").write((be_spine if s["role"] == "spine" else be_leaf)(n, s))
    open(os.path.join(ROOT, "bootstrap", "fw.xml"), "w").write(fw_xml())
    if NETOP:
        os.makedirs(os.path.join(ROOT, "netop"), exist_ok=True); open(os.path.join(ROOT, "netop", "manifests.yaml"), "w").write(netop_manifests())
    open(os.path.join(ROOT, f"{LAB}.clab.yml"), "w").write(topology())
    # same lab, same cabling, servers as lightweight containers: deploy this one to validate both fabrics without booting 12 guests
    open(os.path.join(ROOT, f"{LAB}-light.clab.yml"), "w").write(topology(light=True))
    nv = sum(1 for n in FE if nos(n) == "vex"); nn = sum(1 for n in FE if nos(n) == "nxos")
    fe_txt = f"{len(FE)} vEX" if nv == len(FE) else (f"{len(FE) - nv} {'Nexus' if nn else 'Cumulus'} + {nv} vEX" if nv else f"{len(FE)} Cumulus")
    for f in os.listdir(os.path.join(ROOT, "configs")):    # a node that changed NOS leaves the other flavour's file behind; so does a node the profile drops
        n, _, ext = f.rpartition(".")
        if n in FE and ext in ("cfg", "set") and ext != ("set" if nos(n) == "vex" else "cfg"): os.remove(os.path.join(ROOT, "configs", f))
        if n.startswith("fe-") and n not in FE and ext in ("cfg", "set"): os.remove(os.path.join(ROOT, "configs", f))   # e.g. fe-gpu-leaf5-8 / fe-stor-leaf* after the Nexus swap
    print(f"{LAB} [{PROFILE}]: {fe_txt} + {len(BE)} OcNOS + 1 firewall + {len(HOSTS)} VM nodes + bastion + 2 PCs written to {ROOT}")

if __name__ == "__main__":
    import sys, time
    if len(sys.argv) == 3 and sys.argv[1] == "--dns-zones":      # write the lab's zones for an external DNS server (dns-b-zones.sh), nothing else
        out = sys.argv[2]; os.makedirs(out, exist_ok=True)
        conf, files = dns_zones(DNS_NTP or BASTION_IP, time.strftime("%Y%m%d%H"))
        open(os.path.join(out, "named.conf.ai-fabric"), "w").write(conf)
        for f, c in files.items(): open(os.path.join(out, f), "w").write(c)
        print(f"{len(files)} zone files + named.conf.ai-fabric written to {out}")
    else:
        main()
