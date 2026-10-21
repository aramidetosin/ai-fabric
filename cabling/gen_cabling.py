#!/usr/bin/env python3
"""gen_cabling.py: cabling matrix for the production AI fabric, generated from the HLD sheet's decisions.

Every value here traces to a decision recorded on diagrams/ai-fabric-32gpu.excalidraw. Nothing is invented:
where the sheet still carries a <placeholder>, this script carries one too.

  BACKEND   rail leaf ethernet0..15 in 2X400g breakout, gpu n -> ethernet floor((n-1)/2) / (1 if n odd, 2 if n even)
            rail leaf ethernet48..63 uplinks, contiguous block per spine: ethernet(48 + 4*(s-1) + k) -> be-spine s
            spine side grouped by leaf, L1 first: port 4*(L-1) + k -> be-leaf L
            Port numbering is 0-based on the UfiSpace S9321-64E, as on the sheet.

  FRONTEND  control leaf pair only: ports 1-30 are the server range, 31 and 32 carry the spine uplinks.
            Cisco Nexus port naming Ethernet1/1..1/32.

  Operator decisions 2026-09-24: dual-homing is vPC Fabric Peering (was EVPN multihoming / ESI-LAG); three frontend VLANs, each its
  own VRF (<data VLAN> / VRF k8s, <stor-mgmt VLAN> / VRF stor-mgmt, <bastion VLAN> / VRF bastion; new VLANs stay placeholders);
  the FlashBlade management ports (1 per appliance) moved from the OOB switch to the control leaves: flashblade-1 -> fe-ctrl-leaf1,
  flashblade-2 -> fe-ctrl-leaf2, on the next free port (Ethernet1/12, PROPOSED).
  Confirmed by the operator 2026-09-24: management = 1G, a QSA adapter + 1000BASE-T SFP in the leaf's 100G port (RJ45); the
  FlashBlade data bond scope as drawn (one 8 x 100G LACP bond across both appliances); backend uplinks BGP unnumbered (not /31).

  usage: ./gen_cabling.py backend | frontend | frontend-gpu | frontend-ctrl
"""
import sys

RAILS, NODES, SPINES = 8, 32, 4
ULINK_BASE, ULINKS_PER_SPINE = 48, 4

def backend():
    rows = []
    # 1. GPU node rail NICs -> rail leaves. Rail-optimised: NIC r of every node lands on rail leaf r.
    for n in range(1, NODES + 1):
        port, leg = (n - 1) // 2, 1 if n % 2 else 2
        for r in range(1, RAILS + 1):
            rows.append((f"gpu{n}", f"ConnectX-8 #{r} port 1", f"be-leaf{r}", f"ethernet{port}/{leg}",
                         "400G", "rail %d, VLAN %d0, plane 1" % (r, r)))
    # 2. Rail leaves -> backend spines. Contiguous block per spine on the leaf; grouped by leaf on the spine.
    for L in range(1, RAILS + 1):
        for s in range(1, SPINES + 1):
            for k in range(ULINKS_PER_SPINE):
                rows.append((f"be-leaf{L}", f"ethernet{ULINK_BASE + ULINKS_PER_SPINE * (s - 1) + k}",
                             f"be-spine{s}", f"ethernet{ULINKS_PER_SPINE * (L - 1) + k}",
                             "800G", "routed, BGP unnumbered, eBGP + BFD, one session per link"))
    return rows


# ---------------------------------------------------------------- frontend control leaf pair
# Scope: the control leaf pair only (ctrl nodes, bastion, FlashBlade). Borders, firewall and uplinks are out of scope.
# From the sheet: every server bond0 = 2 x 100G LACP as a vPC, ONE LEG PER LEAF; the FlashBlade appliance pair has
# 2 links per appliance to EACH control leaf (8 x 100G in one LACP bond (vPC), <data VLAN> TAGGED).
# Ports 1-30 are the server range (31 and 32 carry the spine uplinks), so the 11 server ports per leaf sit at 1..11.
# Order follows the sheet's own listing: 6 control + bastion + 4 FlashBlade. Same port number on both leaves, so a
# server's two legs land on the identical port of each leaf: easiest to cable, label and fault-find.
# Storage management (2026-09-24): ONE port per appliance, unbonded, each appliance to its own control leaf, on the next free
# port (Ethernet1/12 on both leaves, PROPOSED). 1G: QSA adapter + 1000BASE-T SFP in the leaf's 100G port, RJ45 Cat6 to the
# appliance (operator, 2026-09-24).
CTRL_LEAVES = ["fe-ctrl-leaf1", "fe-ctrl-leaf2"]

def frontend_ctrl():
    rows, port = [], 1
    def add_rows(host, nic_fmt, links_per_leaf, note):
        nonlocal port
        for i in range(links_per_leaf):
            p = port + i
            for li, leaf in enumerate(CTRL_LEAVES, start=1):
                nic = nic_fmt.format(n=i * len(CTRL_LEAVES) + li)
                rows.append((host, nic, leaf, f"Ethernet1/{p}", "100G", note))
        port += links_per_leaf
    for i in range(1, 7):
        add_rows(f"ctrl{i}", "bond0 NIC{n}", 1, "bond0 = 2 x 100G vPC, one leg per leaf, <data VLAN> access (VRF k8s)")
    add_rows("bastion", "bond0 NIC{n}", 1, "bond0 = 2 x 100G vPC, one leg per leaf, <bastion VLAN> access (VRF bastion)")
    for a in (1, 2):
        add_rows(f"flashblade-{a}", "NIC{n}", 2,
                 "part of the 8 x 100G LACP bond across both appliances (vPC), <data VLAN> TAGGED (VRF k8s)")
    for a, leaf in ((1, CTRL_LEAVES[0]), (2, CTRL_LEAVES[1])):
        rows.append((f"flashblade-{a}", "mgmt", leaf, f"Ethernet1/{port}", "1G",
                     "storage management / API, 1 port per appliance, no bond, <stor-mgmt VLAN> access (VRF stor-mgmt); "
                     "QSA adapter + 1000BASE-T SFP in the 100G leaf port, RJ45 Cat6; port PROPOSED (next free)"))
    return rows


# ---------------------------------------------------------------- frontend GPU leaf pairs
# From the sheet: "32 nodes over TWO GPU leaf pairs: gpu1-16 on leaf1/2, gpu17-32 on leaf3/4 = 16 native 100G server
# ports per leaf (QSFP28 in QSFP-DD ports, no breakout); all in <data VLAN>", every server bond0 = 2 x 100G vPC with
# ONE LEG PER LEAF. Ports 1-30 are the server range (31 and 32 carry the spine uplinks), so each pair fills 1..16.
GPU_PAIRS = [(["fe-gpu-leaf1", "fe-gpu-leaf2"], range(1, 17)),
             (["fe-gpu-leaf3", "fe-gpu-leaf4"], range(17, 33))]

def frontend_gpu():
    rows = []
    for leaves, nodes in GPU_PAIRS:
        for p, n in enumerate(nodes, start=1):        # each pair starts again at Ethernet1/1
            for li, leaf in enumerate(leaves, start=1):
                rows.append((f"gpu{n}", f"bond0 NIC{li}", leaf, f"Ethernet1/{p}", "100G",
                             "bond0 = 2 x 100G vPC, one leg per leaf, <data VLAN> access (VRF k8s)"))
    return rows

def frontend_all():
    return frontend_gpu() + frontend_ctrl()

if __name__ == "__main__":
    what = sys.argv[1] if len(sys.argv) > 1 else "backend"
    rows = {"backend": backend, "frontend-ctrl": frontend_ctrl,
            "frontend-gpu": frontend_gpu, "frontend": frontend_all}[what]()
    import csv
    w = csv.writer(sys.stdout, lineterminator="\n")   # notes contain commas: quote properly rather than hand-joining
    w.writerow(["a_device", "a_port", "b_device", "b_port", "speed", "notes"])
    w.writerows(rows)
    print(f"# {len(rows)} links", file=sys.stderr)
