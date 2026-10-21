#!/usr/bin/env python3
"""production AI fabric, 32 GPU nodes (256 GPUs): HLD/LLD topology sheet (rev 4, 2026-09-24).
Sources of every drawn value: operator decisions, the AI_FABRIC Cluster-1 800G production configs and B300 onboarding notes, the Cisco
N9300-GX2 data sheet (native 100G on QSFP-DD ports), and arithmetic on those. Frontend/OOB addresses and ASNs are not assigned
yet: placeholders in angle brackets. No em dashes in labels; lines, not arrows.
Frontend leaf-spine and dual-homing were the last two open points; both closed 2026-09-20, so the TBD box is gone.
Frontend leaves: 6 (two GPU leaf pairs + one control/bastion/FlashBlade pair) + the border pair.
Rev 4, operator decisions 2026-09-24: FlashBlade management moved off OOB to the control leaves (1 port per appliance, each to
its own leaf, unbonded); three frontend VLANs, each its own VRF (<data VLAN> / k8s, <stor-mgmt VLAN> / stor-mgmt, <bastion
VLAN> / bastion), every inter-VRF flow through the firewall on per-VRF dot1q sub-interfaces (zones data, stor-mgmt, bastion);
dual-homing vPC Fabric Peering with the peer-keepalive over mgmt0; OSPF unnumbered underlay + iBGP EVPN, one <fe-asn>, the
spines as route reflectors, the firewall peering with <fe-asn>. VNIs are placeholders (NX-OS VNIs start at 4096, so the old
VNI 10 / L3 VNI 1000 could not be configured); every frontend VLAN ID (data included), subnet and VIP is a placeholder.
Confirmed later on 2026-09-24: backend uplinks BGP unnumbered; the FlashBlade data bond scope as drawn; FlashBlade management
= 1G via a QSA adapter + 1000BASE-T SFP in the 100G leaf port; backend PFC + ECN as in the production switch configuration
(AI-Leaf / AI-Spine ECN_PFC_Lossless templates: PFC priority 3, ECN random-detect)."""
import json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))   # vendored excalidraw_helpers.py
from excalidraw_helpers import rect, text, ctext, line, doc

INK, GRAY = "#1e1e1e", "#868e96"
RAIL = {1: "#1971c2", 2: "#2f9e44", 3: "#e8590c", 4: "#9c36b5", 5: "#c92a2a", 6: "#0c8599", 7: "#f08c00", 8: "#c2255c"}
FEA, FEB = "#364fc7", "#5c940d"
STM = "#7048e8"                                   # storage management (FlashBlade mgmt ports, VRF stor-mgmt)
E = []

def fine(el, w=1):
    el["roughness"] = 0; el["strokeWidth"] = w; return el

def mono(x, y, s, size=15, color=INK):
    el = text(x, y, s, size=size, color=color); el["fontFamily"] = 3
    el["width"] = max(len(l) for l in s.split("\n")) * size * 0.6; return el

def box(x, y, w, h, label, stroke=INK, bg="transparent", size=14, dash=False, width=2, tcolor=INK):
    E.append(rect(x, y, w, h, stroke=stroke, bg=bg, dash=dash, width=width))
    n = len(label.split("\n")); E.append(ctext(x + w / 2, y + (h - n * size * 1.25) / 2, label, size=size, color=tcolor))

def seg(x1, y1, x2, y2, color=GRAY, width=2, dash=False, rough=True):
    el = line(x1, y1, x2, y2, color=color, width=width)
    if dash: el["strokeStyle"] = "dashed"
    if not rough: el["roughness"] = 0
    E.append(el); return el

def sq(cx, cy, color, s=8):
    el = rect(cx - s / 2, cy - s / 2, s, s, stroke=color, bg=color, round=False); fine(el); E.append(el)

# ------------------------------------------------------------------ geometry
GX0, PITCH, NW, NH = 2300, 100, 92, 110          # GPU node row
NODE_Y = 700; NODE_B = NODE_Y + NH
OOB_Y, FEA_Y, FEB_Y = 600, 626, 648
BUS_Y = {r: 860 + (r - 1) * 24 for r in RAIL}
GX1 = GX0 + 31 * PITCH + NW
GMID = GX0 + 16 * PITCH
LEAF_Y, LEAF_H, SPINE_Y, SPINE_H = 1130, 112, 1480, 112
FL_Y, FL_H, FS_Y, FS_H = 400, 100, 170, 100

# background bands
b = rect(820, 140, GX1 - 820 + 40, 380, stroke="transparent", bg="#edf5ff"); b["roughness"] = 0; E.append(b)
b = rect(GX0 - 40, 838, GX1 - GX0 + 80, 800, stroke="transparent", bg="#fff8e6"); b["roughness"] = 0; E.append(b)

# ------------------------------------------------------------------ title
E.append(text(40, 10, "production AI fabric", size=44))
E.append(text(40, 72, "32 GPU nodes (256 GPUs). Frontend: Cisco Nexus EVPN-VXLAN, six leaves in three vPC pairs (vPC Fabric Peering) plus a border pair. Backend: rail-optimised OcNOS fabric "
              "on UfiSpace S9321-64E, plane 1. Frontend and OOB addresses / ASNs are not assigned yet: <placeholders>.", size=20, color="#495057"))
E.append(text(1320, 128, "FRONTEND FABRIC   EVPN-VXLAN, THREE VLANs, each its own VRF: <data VLAN> (VRF k8s), <stor-mgmt VLAN> (VRF stor-mgmt), <bastion VLAN> (VRF bastion); "
              "anycast gateway per VRF, VNIs <placeholders>, every inter-VRF flow through the firewall. Dual-homing: vPC Fabric Peering on every leaf pair "
              "(virtual peer-link over the spines, peer-keepalive over mgmt0). Server ports: native 100G, no breakout.", size=20, color=FEA))
E.append(text(GX0, 1612, "BACKEND FABRIC, PLANE 1   rail optimised: GPU NIC N of every node lands on rail leaf N. Same rail = L2 on the leaf (VLAN N0). "
              "Cross rail = leaf > spine > leaf over ROUTED links: eBGP + BFD on every uplink, ECMP over 16 uplinks (4 spines x 4), RoCEv2, PFC + ECN (production switch config), MTU 9216.", size=20, color="#d9480f"))

# ------------------------------------------------------------------ outside, enterprise, firewall, OOB switch
FWX, FWY, FWW, FWH = 60, 170, 330, 150
box(FWX, FWY, FWW, FWH, "fw: firewall, eBGP AS <fw-asn>\nhandoff to fe-border1/2: one dot1q\nsub-interface + eBGP session per VRF:\nzones data, stor-mgmt, bastion\nOOB gateway (zone oob)\noriginates each VRF's default route (type-5),\nall inter-VRF policy", stroke="#c92a2a", bg="#fff0f0", size=12)
box(60, 560, 290, 80, "oob-sw  (OOB / BMC switch)\nOOB network <OOB subnet>/24\ngateway = firewall", stroke=GRAY, bg="#f1f3f5", size=13)
seg(150, FWY + FWH, 190, 560, color=GRAY, dash=True); E.append(text(215, 400, "the OOB network is reached\nonly through the firewall; no rule\nfrom data, stor-mgmt or bastion\ninto oob (storage management\nnow sits on the control leaves)", size=12, color="#495057"))
seg(350, OOB_Y, GX1, OOB_Y, color=GRAY, dash=True, rough=False)
E.append(text(420, OOB_Y - 60, "OOB / BMC <OOB subnet>/24: one BMC port\nper server, switch mgmt0 (vPC peer-keepalive),\ngateway on the firewall", size=13, color="#495057"))

# ------------------------------------------------------------------ frontend spines + leaves (6 leaves in 3 vPC pairs + border pair)
FS = {1: 2050, 2: 2650}
for s, x in FS.items():
    box(x, FS_Y, 400, FS_H, f"fe-spine{s}\nCisco N9364D-GX2A (64 x 400G QSFP-DD)\nAS <fe-asn>, iBGP route reflector   lo <ip>", stroke=FEA, bg="#dbe4ff", size=13)
FL = [("fe-border1", 840, 190, "border: eBGP to firewall\none sub-if per VRF, <fe-asn>"), ("fe-border2", 1070, 190, "border: eBGP to firewall\none sub-if per VRF, <fe-asn>"),
      ("fe-ctrl-leaf1", 1380, 220, "control + bastion + FlashBlade\n11 x 100G + 1G storage mgmt\n<fe-asn>"), ("fe-ctrl-leaf2", 1640, 220, "control + bastion + FlashBlade\n11 x 100G + 1G storage mgmt\n<fe-asn>"),
      ("fe-gpu-leaf1", 2860, 230, "16 x 100G native to gpu1..16\n<fe-asn>"), ("fe-gpu-leaf2", 3110, 230, "16 x 100G native to gpu1..16\n<fe-asn>"),
      ("fe-gpu-leaf3", 4460, 230, "16 x 100G native to gpu17..32\n<fe-asn>"), ("fe-gpu-leaf4", 4710, 230, "16 x 100G native to gpu17..32\n<fe-asn>")]
MH = [("fe-ctrl-leaf1", "fe-ctrl-leaf2"), ("fe-gpu-leaf1", "fe-gpu-leaf2"), ("fe-gpu-leaf3", "fe-gpu-leaf4")]   # vPC Fabric Peering pairs
LC = {}; FLX = {}
for name, x, w, role in FL:
    box(x, FL_Y, w, FL_H, f"{name}\nCisco N9332D-GX2B\n{role}", stroke=FEA, bg="#e7f5ff", size=12)
    LC[name] = x + w / 2; FLX[name] = (x, w)
    for s, sx in FS.items():
        seg(x + w / 2 + (-12 if s == 1 else 12), FL_Y, sx + 200 + (LC[name] - 2550) / 40, FS_Y + FS_H, color="#91a7ff", width=2)
E.append(text(3130, 160, "every leaf to both spines:\n2 x 400G to EACH spine = 4 x 400G per leaf\n(1.6 Tb/s up vs 16 x 100G down: 1:1),\nOSPF unnumbered underlay, iBGP EVPN overlay,\nthe spines are route reflectors", size=13, color=FEA))
for a, b2 in MH:    # vPC Fabric Peering: the peer-link is VIRTUAL, carried over the spines. There is NO physical link
    xa = FLX[a][0] + FLX[a][1]; xb = FLX[b2][0]   # between the two leaves, so nothing is drawn here: a line would assert a cable that does not exist.
    E.append(ctext((xa + xb) / 2, FL_Y - 20, "vPC fabric peering (no peer-link cable)", size=11, color=FEA))   # above the pair: the gap is 20-40 wide
seg(FWX + FWW, 250, LC["fe-border1"], FL_Y, color="#c92a2a"); seg(FWX + FWW, 210, LC["fe-border2"], FL_Y, color="#c92a2a")
E.append(text(840, 510, "border pair: VRF-lite handoff, one dot1q sub-interface\nand eBGP session per VRF (k8s, stor-mgmt, bastion).\nEach VRF's default route from the firewall becomes an\nEVPN type-5 route for every leaf. Not a vPC pair (L3 only).", size=12, color="#495057"))

# ------------------------------------------------------------------ control nodes, bastion, FlashBlade: all on the control leaf pair
def host(x, name, sub, la, lb, bg="#f1f3f5", w=NW, i=0):
    E.append(rect(x, NODE_Y, w, NH, bg=bg)); E.append(ctext(x + w / 2, NODE_Y + 30, name, size=14)); E.append(ctext(x + w / 2, NODE_Y + 52, sub, size=11, color="#495057"))
    for cx, leaf, col in ((x + 18, la, FEA), (x + 40, lb, FEB)):
        sq(cx, NODE_Y, col); seg(cx, NODE_Y - 4, LC[leaf] - 100 + i * 18, FL_Y + FL_H, color=col, width=1)
    sq(x + w - 16, NODE_Y, GRAY); fine(seg(x + w - 16, NODE_Y - 4, x + w - 16, OOB_Y, color=GRAY, width=1, dash=True))
for i, (n, sub) in enumerate([(f"ctrl{k}", "<ip>\ncontrol\nnode") for k in range(1, 7)] + [("bastion", "<ip>\nkubectl")]):
    host(1020 + i * 100, n, sub, "fe-ctrl-leaf1", "fe-ctrl-leaf2", i=i)
E.append(text(1020, NODE_B + 8, "6 control nodes + 1 bastion: 2 x 100G each,\none leg per leaf, LACP bond0 as a vPC. ctrl1-6 in\n<data VLAN> (VRF k8s), the bastion in <bastion VLAN>\n(VRF bastion). kube API VIP, Gateway VIP, LB pool:\ntop of the data subnet (ADDRESS PLAN).", size=12, color="#495057"))
E.append(text(1760, NODE_B + 8, "Pure Storage FlashBlade, 2 PB (appliance pair):\n4 x 100G per appliance, 8 x 100G in ONE LACP bond\n(vPC), <data VLAN> TAGGED, 2 links per appliance to\neach control leaf. Management: 1 port per appliance\nto its own control leaf, unbonded, <stor-mgmt VLAN>\n(VRF stor-mgmt), 1G: QSA + 1000BASE-T in a 100G port.", size=11, color="#495057"))
for u, SX in enumerate((1760, 1980)):
    SW = 200; E.append(rect(SX, NODE_Y, SW, NH, bg="#f3f0ff")); E.append(ctext(SX + SW / 2, NODE_Y + 22, f"flashblade-{u + 1}", size=14))
    E.append(ctext(SX + SW / 2, NODE_Y + 46, "Pure Storage FlashBlade\n<ip>  (data, <data VLAN> tagged)\nmgmt/API <stor-mgmt ip>", size=10, color="#495057"))
    for k in range(4):
        cx = SX + 40 + k * 40; leaf, col = ("fe-ctrl-leaf1", FEA) if k < 2 else ("fe-ctrl-leaf2", FEB)
        sq(cx, NODE_Y, col); seg(cx, NODE_Y - 4, LC[leaf] + 34 + (k % 2) * 16 + u * 32, FL_Y + FL_H, color=col, width=1)
    # storage management: ONE unbonded port per appliance, flashblade-1 -> fe-ctrl-leaf1, flashblade-2 -> fe-ctrl-leaf2 (no longer OOB)
    mleaf = ("fe-ctrl-leaf1", "fe-ctrl-leaf2")[u]
    sq(SX + SW - 12, NODE_Y, STM); seg(SX + SW - 12, NODE_Y - 4, LC[mleaf] + 96, FL_Y + FL_H, color=STM, width=2)

# ------------------------------------------------------------------ 32 GPU nodes: frontend legs, BMC, 8 rail NICs
for (x0, x1, la, lb) in ((GX0, GMID - PITCH + NW, "fe-gpu-leaf1", "fe-gpu-leaf2"), (GMID, GX1, "fe-gpu-leaf3", "fe-gpu-leaf4")):
    fine(seg(x0 + 18, FEA_Y, x1 - NW + 18, FEA_Y, color=FEA, width=2, rough=False), 2); fine(seg(x0 + 40, FEB_Y, x1 - NW + 40, FEB_Y, color=FEB, width=2, rough=False), 2)
    seg(LC[la], FL_Y + FL_H, LC[la], FEA_Y, color=FEA, width=4); seg(LC[lb], FL_Y + FL_H, LC[lb], FEB_Y, color=FEB, width=4)
    E.append(text(LC[la] + 10, 566, "16 x 100G (leg A\nof each bond0)", size=12, color=FEA)); E.append(text(LC[lb] + 10, 566, "16 x 100G (leg B\nof each bond0)", size=12, color=FEB))
E.append(text(GX0, 516, "GPU node frontend: 2 x 100G per server, LACP bond0\nas a vPC. 32 nodes over TWO GPU leaf pairs:\ngpu1-16 on leaf1/2, gpu17-32 on leaf3/4 = 16 native\n100G server ports per leaf (QSFP28 in QSFP-DD ports,\nno breakout); all in <data VLAN>.", size=12, color="#495057"))
for n in range(1, 33):
    x = GX0 + (n - 1) * PITCH
    E.append(fine(rect(x, NODE_Y, NW, NH, bg="#ebfbee"), 2)); E.append(ctext(x + NW / 2, NODE_Y + 20, f"gpu{n}", size=15))
    E.append(ctext(x + NW / 2, NODE_Y + 46, "B300\n8 GPU\n8 x CX8", size=10, color="#495057"))
    for cx, by, col in ((x + 18, FEA_Y, FEA), (x + 40, FEB_Y, FEB)):
        sq(cx, NODE_Y, col); fine(seg(cx, NODE_Y - 4, cx, by, color=col, rough=False))
    sq(x + NW - 16, NODE_Y, GRAY); fine(seg(x + NW - 16, NODE_Y - 4, x + NW - 16, OOB_Y, color=GRAY, dash=True, rough=False))
    for r, col in RAIL.items():
        cx = x + 8 + (r - 1) * 11; sq(cx, NODE_B, col); fine(seg(cx, NODE_B + 4, cx, BUS_Y[r], color=col, rough=False))

# ------------------------------------------------------------------ rail buses, rail leaves, spines
LX = {r: GX0 + (r - 1) * 400 + 50 for r in RAIL}; LW = 300
SPX = {s: GX0 + (s - 1) * 800 + 190 for s in (1, 2, 3, 4)}; SPW = 420
for r, col in RAIL.items():
    fine(seg(GX0 + 8 + (r - 1) * 11, BUS_Y[r], GX1 - NW + 8 + (r - 1) * 11, BUS_Y[r], color=col, rough=False), 2)
    cx = LX[r] + LW / 2; seg(cx, BUS_Y[r], cx, LEAF_Y, color=col, width=4)
    E.append(text(GX0 - 36, BUS_Y[r] - 9, f"R{r}", size=13, color=col))
    E.append(text(cx + 8, LEAF_Y - 40, "32 x 400G\n(16 x 800G ports, 2X400g)", size=11, color=col))
    box(LX[r], LEAF_Y, LW, LEAF_H, f"be-leaf{r}   RAIL {r}\nUfiSpace S9321-64E (64 x 800G), OcNOS\nAS {65200 + r}   lo 192.168.1.{r}\nVLAN {r * 10}   172.16.{r}.0/24   gw 172.16.{r}.1", stroke=col, bg="#ffffff", size=12)
    for s in SPX:
        seg(cx + (s - 2.5) * 22, LEAF_Y + LEAF_H, SPX[s] + SPW / 2 + (r - 4.5) * 40, SPINE_Y, color="#adb5bd", width=3)
for s, x in SPX.items():
    box(x, SPINE_Y, SPW, SPINE_H, f"be-spine{s}\nUfiSpace S9321-64E (64 x 800G), OcNOS\nAS 65200   lo 192.168.100.{s}\n32 routed 800G links = 32 eBGP sessions (8 leaves x 4)", stroke="#d9480f", bg="#ffe8cc", size=13)
E.append(text(GX0, 1648, "Every grey line = 4 x 800G ROUTED links (3.2 Tb/s per leaf-spine pair), each its own eBGP + BFD session, BGP unnumbered. "
              "Leaf uplinks ethernet48..63 = 16 x 800G = 12.8 Tb/s = the 32 x 400G facing the GPUs: 1:1, non-blocking.", size=17, color="#d9480f"))

# ------------------------------------------------------------------ inset: one GPU node
IX, IY = 40, 905
E.append(rect(IX, IY, 720, 430, bg="#f8fff9")); E.append(text(IX + 16, IY + 12, "ONE GPU NODE (B300), identical x 32", size=18))
for k in range(1, 9):
    y = IY + 52 + (k - 1) * 34; col = RAIL[k]
    E.append(fine(rect(IX + 16, y, 150, 26, stroke=col, bg="#ffffff"), 2)); E.append(text(IX + 24, y + 5, f"GPU{k}  CX8 #{k}  gpu{k - 1}", size=12, color=col))
    fine(seg(IX + 166, y + 8, IX + 250, y + 8, color=col, rough=False), 3); fine(seg(IX + 166, y + 19, IX + 250, y + 19, color=GRAY, dash=True, rough=False), 1)
    E.append(text(IX + 258, y - 1, f"port 1: 400G > be-leaf{k} (rail {k}, VLAN {k * 10}), 172.16.{k}.(10+n)", size=12, color=col))
    E.append(text(IX + 258, y + 13, "port 2: 400G, not cabled (no plane 2 for now)", size=11, color=GRAY))
E.append(text(IX + 16, IY + 330, "ConnectX-8 in Ethernet mode = 2 x 400G per NIC. One 400G per plane; plane 1 only, no plane 2 for now.\n"
              "8 single-homed rail NICs, no bonding. MTU 9000 on the host, RoCEv2. n = node number 1..32.\n"
              "Frontend: bond0 = 2 x 100G LACP, vPC across the pair, one leg per leaf.   BMC: 1 port to the OOB switch.\n"
              "Kubernetes: Multus + whereabouts give pods one interface per rail, pod range 172.16.N.100-199.", size=12, color="#343a40"))

# ------------------------------------------------------------------ tables
TX, TY = 800, 905
E.append(rect(TX, TY, 1420, 268, bg="#ffffff")); E.append(text(TX + 16, TY + 10, "BACKEND RAILS", size=18))
rows = ["rail  leaf      AS     loopback      VLAN  subnet          gateway      node n           gpu1         gpu32"]
rows += [f"{r:<5} be-leaf{r}  {65200 + r}  192.168.1.{r:<3}  {r * 10:<5} 172.16.{r}.0/24   172.16.{r}.1   172.16.{r}.(10+n)  172.16.{r}.11  172.16.{r}.42" for r in RAIL]
rows += ["spines be-spine1..4: AS 65200, loopbacks 192.168.100.1..4. Every leaf in its own AS (65201..65208): eBGP, max-paths ebgp 64, fall-over bfd.",
         "uplinks: BGP unnumbered per routed link (`bgp unnumbered-mode`, `neighbor ethernetN peergroup IPV4_UNDERLAY`)."]
E.append(mono(TX + 16, TY + 42, "\n".join(rows), size=14))

PY = TY + 288
E.append(rect(TX, PY, 1420, 300, bg="#ffffff")); E.append(text(TX + 16, PY + 10, "RAIL LEAF PORT MAP (identical on all 8 leaves)", size=18))
pm = ["`port ethernetP breakout 2X400g`: the two 400G legs P/1 and P/2 of one 800G port go to TWO DIFFERENT servers.",
      "gpu n  >  ethernet floor((n-1)/2) / (1 if n is odd, 2 if n is even)", ""]
for a in range(0, 16, 4):
    pm.append("    ".join((f"eth{p}/1".ljust(8) + f"gpu{2 * p + 1}".ljust(7) + f"eth{p}/2".ljust(8) + f"gpu{2 * p + 2}".ljust(5)) for p in range(a, a + 4)))
pm += ["", "ethernet0..15    16 x 800G ports in 2X400g breakout = 32 x 400G, one per GPU node",
       "ethernet16..47   32 x 800G ports free",
       "ethernet48..63   16 x 800G ROUTED uplinks, 4 to each of be-spine1..4, one eBGP + BFD session each. Contiguous block per spine:",
       "                 eth48-51 > be-spine1    eth52-55 > be-spine2    eth56-59 > be-spine3    eth60-63 > be-spine4",
       "                 rule: ethernet(48 + 4 x (s-1) + k) > be-spine s, k = 0..3. Mirrors the spine side, which is grouped by leaf.",
       "spine side       4 x 800G per leaf x 8 leaves = 32 of 64 ports, grouped by leaf (L1 first): ports 4 x (L-1) + k > be-leaf L"]
E.append(mono(TX + 16, PY + 42, "\n".join(pm), size=14))

CY = PY + 320
E.append(rect(40, CY - 140, 720, 300, bg="#ffffff")); E.append(text(56, CY - 130, "CAPACITY", size=18))
cap = ["GPU links        32 nodes x 8 rails = 256 x 400G",
       "per rail leaf    down 32 x 400G = 12.8 Tb/s",
       "                 up   16 x 800G = 12.8 Tb/s   > 1:1",
       "                 32 of 64 ports used",
       "per spine        8 x 4 x 800G = 25.6 Tb/s, 32 of 64 ports",
       "leaf-spine       8 x 4 x 4 = 128 x 800G links",
       "cross-rail       102.4 Tb/s leaf-to-spine in total",
       "frontend         32 x 2 x 100G = 64 x 100G GPU-node links,",
       "                 16 native 100G per GPU leaf, 2 GPU leaf pairs",
       "                 control leaf pair: 7 x 2 x 100G control/bastion",
       "                 + FlashBlade 8 x 100G data + 2 x 1G mgmt",
       "                 = 12 ports per leaf"]
E.append(mono(56, CY - 96, "\n".join(cap), size=14))

OY = PY + 320
E.append(rect(TX, OY, 1420, 520, stroke="#2f9e44", bg="#f4fce3")); E.append(text(TX + 16, OY + 10, "DESIGN DECISIONS and ADDRESS PLAN", size=18, color="#2b8a3e"))
dec = ["1  Frontend leaves        six: two GPU leaf pairs (gpu1-16, gpu17-32) and one control leaf pair (ctrl1-6, bastion, FlashBlade), plus the border pair.",
       "2  Frontend dual-homing   vPC Fabric Peering on every leaf pair; every server bond0 = 2 x 100G LACP, one leg per leaf (vPC).",
       "                          Virtual peer-link over the spines (no peer-link cabling), peer-keepalive over mgmt0. Border pair: L3 only, not a vPC pair.",
       "3  Frontend server ports  native 100G (QSFP28) in the N9332D-GX2B QSFP-DD ports, no breakout. Cisco N9300-GX2 data sheet:",
       "                          \"QSFP-DD ports also support native 200G (QSFP56), 100G (QSFP28), and 40G (QSFP+)\". 16 server ports per GPU leaf,",
       "                          12 per control leaf (6 control + bastion + 4 FlashBlade data + 1 FlashBlade management, 1G via QSA); the rest stay for uplinks.",
       "4  Backend leaf-spine     4 x 800G ROUTED links per pair, one eBGP + BFD session per link (16 per leaf), ECMP over all 16, BGP unnumbered.",
       "5  Frontend leaf-spine    2 x 400G from every leaf to EACH spine = 4 x 400G per leaf (1.6 Tb/s), against 16 x 100G of access: 1:1 non-blocking.",
       "                          OSPF unnumbered underlay, iBGP EVPN overlay, the spines as route reflectors. Uses 4 of the 32 QSFP-DD ports per leaf.",
       "6  Plane                  plane 1 only: port 2 of every ConnectX-8 uncabled; ethernet16..47 (32 x 800G) free on every rail leaf.",
       "7  Storage                one Pure Storage FlashBlade (appliance pair), 2 PB: 4 x 100G per appliance, 8 x 100G in ONE LACP bond (vPC), <data VLAN> tagged.",
       "                          Management: 1 port per appliance to its own control leaf (flashblade-1 > fe-ctrl-leaf1, flashblade-2 > fe-ctrl-leaf2),",
       "                          unbonded, <stor-mgmt VLAN>, 1G: QSA adapter + 1000BASE-T SFP in the 100G leaf port, RJ45. Moved off the OOB network.",
       "8  VLANs and VRFs         <data VLAN> (VRF k8s): ctrl1-6, gpu1-32, FlashBlade data.   <stor-mgmt VLAN> (VRF stor-mgmt): FlashBlade management.",
       "                          <bastion VLAN> (VRF bastion): the bastion. Anycast gateway per VRF. Every inter-VRF flow crosses the firewall on its own",
       "                          dot1q sub-interface of the border-firewall links (zones data, stor-mgmt, bastion): data > stor-mgmt tcp/443; bastion > data and",
       "                          stor-mgmt tcp 22/80/443/6443; all other inter-VRF traffic denied. The fabric > oob rule is gone.",
       "",
       "ADDRESS PLAN  addresses, VNIs and ASNs to be assigned: placeholders",
       "  data       <FE subnet>/24, <data VLAN> / <data L2VNI>        stor-mgmt  <stor-mgmt subnet>/24, <stor-mgmt VLAN> / <stor-mgmt L2VNI>",
       "  bastion    <bastion subnet>/24, <bastion VLAN> / <bastion L2VNI>        L3VNIs  <k8s L3VNI>  <stor-mgmt L3VNI>  <bastion L3VNI>",
       "  <gw>  anycast gateway per VRF (all leaves)      <svi>  one SVI per VLAN on each leaf, carrying only the anycast <gw> (no per-leaf address)",
       "  data: <ctrl1..6>  <flashblade-1/2>  <API VIP>      <gpu1..32>  one address per GPU node",
       "  <Gateway VIP> + <LB pool>  reserved at the TOP of the data subnet, clear of the node range",
       "  stor-mgmt: <flashblade-1/2 mgmt>  <stor-mgmt API VIP>      bastion: <bastion>",
       "  ASNs: <fe-asn> for the spines, leaves and borders (iBGP, the spines are route reflectors); the firewall <fw-asn> peers with <fe-asn>",
       "  on every VRF sub-interface.  OOB <OOB subnet>/24: BMC per server + switch mgmt0 (vPC peer-keepalive), gateway on the firewall.",
       "  Backend: rails as in the table (fixed); loopbacks 192.168.1.L / 192.168.100.S; uplinks unnumbered."]
E.append(mono(TX + 16, OY + 42, "\n".join(dec), size=13, color="#2b3d1f"))
# No TBD box: frontend leaf-spine (2 x 400G to each spine) and dual-homing were the last open design points (2026-09-20;
# dual-homing changed to vPC Fabric Peering, keepalive over mgmt0, on 2026-09-24). Everything that remains unassigned is an
# address, a VLAN, a VNI or an ASN, all marked as <placeholders>. FlashBlade management speed/media, bond scope, backend
# BGP unnumbered and backend PFC/ECN were confirmed on 2026-09-24.

# ------------------------------------------------------------------ legend
LY = CY + 180
E.append(rect(40, LY, 720, 185, bg="#ffffff")); E.append(text(130, LY + 10, "every stub = ONE dedicated link to the leaf of the same colour; the buses are a drawing aid", size=12, color="#495057")); E.append(text(56, LY + 8, "LEGEND", size=16))
items = [(RAIL[1], 3, False, "400G rail link, plane 1 (colour = rail 1..8)"), ("#adb5bd", 3, False, "leaf-spine: 4 x 800G routed links per line"),
         (FEA, 2, False, "frontend 100G, bond leg A (leaf 1 of the pair)"), (FEB, 2, False, "frontend 100G, bond leg B (leaf 2 of the pair)"),
         (GRAY, 1, True, "OOB / BMC, or not cabled"), ("#c92a2a", 2, False, "firewall links"),
         (STM, 2, False, "storage management 1G, 1 per FlashBlade appliance")]
for i, (c, w, d, t) in enumerate(items):
    yy = LY + 40 + (i // 2) * 34; xx = 56 + (i % 2) * 350
    fine(seg(xx, yy + 8, xx + 50, yy + 8, color=c, dash=d, rough=False), w); E.append(text(xx + 58, yy, t, size=12))

out = sys.argv[1]
json.dump(doc(E), open(out, "w"), indent=1)
alltext = " ".join(e["text"] for e in E if e["type"] == "text")
bad = [w for w in ("\u2014", "Palo", "PAN-OS", "PA-VM", "fw e", "e1 /", "e3:", "/30", "office", "Office", " lab", "Lab", "tested", "10.80.15", "10.1.1.", "10.1.2.", "10.66.", "10.1.254", "PROPOSED", "OcNOS VM", "stor-leaf", "nternet", "utside", "e5", "e4 /", "e4:", "e6", "pc-", "enterprise", "Cluster", "cluster-1", "SRV", "AI_FABRIC", "ai-fabric") if w in alltext]
print(f"{out}: {len(E)} elements, forbidden words present: {bad}")
