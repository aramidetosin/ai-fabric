#!/usr/bin/env python3
"""ai-fabric figures as Excalidraw (the figures carry no lab, site or host name: operator decision 2026-10-04). Source of record for both diagrams: edit here, regenerate, export.

  python3 diagram/ai_fabric.py
  python3 diagram/export1x.py diagram/ai-fabric-1-topology.excalidraw diagram/ai-fabric-1-topology.png
  python3 diagram/export1x.py diagram/ai-fabric-2-flows.excalidraw diagram/ai-fabric-2-flows.png

Figure 1: the detailed network topology (external network, firewall, enterprise PCs, Nexus frontend, servers, OcNOS rail backend, OOB, management,
Kubernetes layer). Figure 2: every traffic flow hop by hop, one lane per flow.
Every value comes from the lab's own sources: gen.py, the containerlab topology, configs/, the firewall running config,
mgmt-hosts.txt, urls.txt, README.md and the audits of 2026-10-04 (e2e, rail, PVC, RDMA probe, AI workload). Nothing is assumed.
Label rules: lab values exactly as they exist; no em dashes; no secrets."""
import json, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))   # vendored excalidraw_helpers.py
from excalidraw_helpers import ctext, doc, line, rect, text  # noqa: E402

INK, GRAY, SUB = "#1e1e1e", "#868e96", "#495057"
C1, C2, STO, OOB, OI, WAN, BE, FW = "#1971c2", "#2f9e44", "#e8590c", "#9c36b5", "#0c8599", "#5c636e", "#a61e4d", "#c92a2a"
INF, UND, RAILL = "#3b5bdb", "#91a7ff", "#e599b7"
BG = {C1: "#d0ebff", C2: "#d3f9d8", STO: "#ffe8cc", OOB: "#f3d9fa", OI: "#e3fafc", WAN: "#f1f3f5", BE: "#ffdeeb", FW: "#fff0f0", INK: "#ffffff", INF: "#dbe4ff"}


class Canvas:
    """Copy of the small drawing class of reference-poc/diagram/reference-poc_hld.py (node / link / poly / frame / text / save)."""
    def __init__(self): self.frames, self.lines, self.top, self.box = [], [], [], {}
    def node(self, name, cx, cy, w, h, label, sub="", stroke=INK, bg=None, size=16, ssize=12, width=2):
        x, y = cx - w / 2, cy - h / 2
        self.top.append(rect(x, y, w, h, stroke=stroke, bg=bg or BG.get(stroke, "#ffffff"), width=width))
        n = 1 + (sub.count("\n") + 1 if sub else 0)
        th = size * 1.25 + (ssize * 1.25 * (n - 1) if sub else 0)
        y0 = cy - th / 2
        self.top.append(ctext(cx, y0, label, size=size))
        if sub: self.top.append(ctext(cx, y0 + size * 1.25 + 2, sub, size=ssize, color=SUB))
        self.box[name] = (x, y, w, h)
    def pt(self, name, side, f=0.5):
        x, y, w, h = self.box[name]
        return {"t": (x + w * f, y), "b": (x + w * f, y + h), "l": (x, y + h * f), "r": (x + w, y + h * f)}[side]
    def poly(self, pts, color, width=2, style="solid", arrow=False):
        x0, y0 = pts[0]
        el = line(x0, y0, pts[-1][0], pts[-1][1], color=color, width=width)
        el["points"] = [[x - x0, y - y0] for x, y in pts]
        el["width"] = max(abs(x - x0) for x, _ in pts) or 1; el["height"] = max(abs(y - y0) for _, y in pts) or 1
        el["strokeStyle"] = style; el["roundness"] = None
        if arrow:
            el["type"] = "arrow"; el.update({"startArrowhead": None, "endArrowhead": "arrow", "elbowed": False, "startBinding": None, "endBinding": None})
        self.lines.append(el); return el
    def link(self, a, b, color=GRAY, width=2, sa=None, sb=None, fa=0.5, fb=0.5, style="solid", arrow=False):
        xa, ya, wa, ha = self.box[a]; xb, yb, wb, hb = self.box[b]
        if sa is None:
            if yb >= ya + ha: sa, sb = "b", "t"
            elif ya >= yb + hb: sa, sb = "t", "b"
            elif xb >= xa + wa: sa, sb = "r", "l"
            else: sa, sb = "l", "r"
        self.poly([self.pt(a, sa, fa), self.pt(b, sb, fb)], color, width, style, arrow)
    def frame(self, x, y, w, h, title, color, sub=None, bg=None, tx=None):
        r = rect(x, y, w, h, stroke=color, dash=True, width=2, bg=bg or "transparent"); self.frames.append(r)
        if title: self.top.append(text((tx or x) + 16, y + 10, title, size=20, color=color))
        if sub: self.top.append(text((tx or x) + 16, y + 38, sub, size=13, color=SUB))
    def text(self, x, y, s, size=13, color=SUB, center=False):
        self.top.append(ctext(x, y, s, size=size, color=color) if center else text(x, y, s, size=size, color=color))
    def square(self, x, y, s, col):
        sq = rect(x, y, s, s, stroke=col, bg=col); sq["roughness"] = 0; self.top.append(sq)
    def save(self, name):
        out = os.path.join(HERE, name); json.dump(doc(self.frames + self.lines + self.top), open(out, "w"), indent=1); print(out, len(self.frames) + len(self.lines) + len(self.top), "elements")


# ====================================================================================================== figure 1: topology
def topology():
    c = Canvas()
    c.text(40, 14, "ai-fabric: network topology", size=32, color=INK)
    c.text(40, 60, "AI cluster POC under containerlab: Cisco Nexus 9300v frontend (VXLAN EVPN, vPC Fabric Peering), OcNOS rail backend (4 spines + 8 rail leaves), PA-VM firewall, Juniper vEX OOB switch, "
                   "6 control nodes, 32 simulated GPU nodes, a storage node, a bastion and 2 enterprise PCs. One Kubernetes cluster, domain lab.ai.", size=15)

    # ---------------------------------------------------------------- legend
    c.frame(40, 110, 900, 260, "LEGEND", INK)
    y = 152
    for col, t in ((C1, "Frontend VLAN 100 DATA, VRF k8s (nodes, storage data)"), (STO, "VLAN 200 STOR-MGMT, VRF stor-mgmt"), (C2, "VLAN 300 BASTION, VRF bastion"),
                   (FW, "Firewall and its routed handoff to the borders"), (OI, "Enterprise PCs (zone enterprise)"), (WAN, "External network (zone internet)"),
                   (OOB, "OOB / BMC network (zone oob)"), (BE, "Backend rails (OcNOS)")):
        c.square(60, y, 18, col); c.text(88, y - 2, t, size=13, color=INK); y += 26
    y = 152
    for st, col, w, t in (("solid", UND, 2, "underlay link: OSPF area 0, IP unnumbered"),
                          ("dashed", C1, 3, "vPC Fabric Peering: virtual peer-link over\nthe spines (no cable), keepalive on mgmt0"),
                          ("solid", C1, 2, "server bond: LACP into a vPC on both leaves"),
                          ("solid", FW, 4, "border > firewall: one dot1q /30 per VRF\n(.100 / .200 / .300), eBGP"),
                          ("dotted", OOB, 2, "BMC NIC, access port on oob-sw"),
                          ("solid", BE, 2, "rail NIC r > be-leaf r")):
        c.poly([(500, y + 9), (560, y + 9)], col, w, st); c.text(574, y - 2, t, size=13, color=INK); y += 28 + 17 * t.count("\n")

    # ---------------------------------------------------------------- external network
    c.frame(980, 110, 2240, 260, "EXTERNAL NETWORK  -  10.80.15.0/24 on the host bridge pnet0 (firewall zone internet)", WAN)
    c.node("lan-gw", 1240, 225, 320, 80, "external gateway", "10.80.15.1\nnext hop of the firewall's default route", stroke=WAN, ssize=12)
    c.node("lan-dns", 1700, 225, 420, 80, "dns-b", "10.80.15.53: DNS + NTP for nodes, switches, firewall\nlab zones: *.platform.lab.ai > 10.1.1.200", stroke=WAN, ssize=12)
    c.node("lan-host", 2200, 225, 420, 80, "lab host", "10.80.15.10, runs containerlab and the bridge pnet0\nexternal-network client of the e2e trace", stroke=WAN, ssize=12)
    c.node("lan-ws", 2790, 225, 580, 80, "winserver-rev3 / ubuntu-desktop", "10.80.15.100 / 10.80.15.103, external workstations\nhosts file: published names > 10.80.15.121, api.lab.ai > 10.1.1.20", stroke=WAN, ssize=12)
    c.node("pnet0", 2080, 328, 2000, 44, "pnet0  -  external-network bridge on the lab host, port fw-ext > firewall ethernet1/5", stroke=WAN, size=14)
    for n in ("lan-gw", "lan-dns", "lan-host", "lan-ws"):
        x = c.box[n][0] + c.box[n][2] / 2
        c.poly([(x, 265), (x, 306)], WAN, 2)

    # ---------------------------------------------------------------- enterprise PCs
    c.frame(40, 410, 480, 340, "ENTERPRISE PCs", OI)
    c.node("pc-1", 280, 530, 400, 76, "pc-1", "10.66.10.10/24, gateway 10.66.10.1\neth1 > firewall eth4; mgmt 172.21.21.161", stroke=OI, ssize=12)
    c.node("pc-2", 280, 660, 400, 76, "pc-2", "10.66.20.10/24, gateway 10.66.20.1\neth1 > firewall eth6; mgmt 172.21.21.162", stroke=OI, ssize=12)

    # ---------------------------------------------------------------- firewall
    c.frame(560, 410, 1980, 340, "FIREWALL  fw  -  Palo Alto PA-VM 12.1.2", FW,
            "virtual router default, BGP AS 65500, static default > 10.80.15.1 redistributed to the borders; management 172.21.21.30")
    c.node("fw-e4", 760, 530, 360, 76, "ethernet1/4", "zone enterprise\n10.66.10.1/24 (pc-1)", stroke=FW, ssize=12)
    c.node("fw-e6", 760, 660, 360, 76, "ethernet1/6", "zone enterprise\n10.66.20.1/24 (pc-2)", stroke=FW, ssize=12)
    c.node("fw-e5", 1750, 540, 440, 96, "ethernet1/5", "zone internet, 10.80.15.121/24 (outside address)\nNAT internet-snat: source NAT for every inside zone\nNAT dnat-gateway-vip: 10.80.15.121:443 > 10.1.1.200", stroke=FW, ssize=12, width=3)
    c.node("fw-e3", 2290, 540, 380, 76, "ethernet1/3", "zone oob\n10.1.2.254/24, gateway of the OOB / BMC network", stroke=FW, ssize=12)
    c.node("fw-e1", 1650, 675, 400, 104, "ethernet1/1  >  fe-border1 Eth1/3", ".100  zone data  10.1.254.2/30\n.200  zone stor-mgmt  10.1.254.10/30\n.300  zone bastion  10.1.254.18/30", stroke=FW, ssize=12, width=3)
    c.node("fw-e2", 2090, 675, 400, 104, "ethernet1/2  >  fe-border2 Eth1/3", ".100  zone data  10.1.254.6/30\n.200  zone stor-mgmt  10.1.254.14/30\n.300  zone bastion  10.1.254.22/30", stroke=FW, ssize=12, width=3)
    c.text(970, 486, "security rules (the last one is deny-all-log)\n"
                     "enterprise-to-data, enterprise-to-oob, data-to-enterprise: any service\n"
                     "internet-to-inside-vips: tcp 80 / 443 / 6443 to 10.1.1.0/24\n"
                     "data-to-stor-mgmt: tcp 443, 10.1.1.0/24 > 10.1.20.0/24\n"
                     "bastion-to-data, bastion-to-stor-mgmt: tcp 22 / 80 / 443 / 6443\n"
                     "data-, enterprise-, oob-, stor-mgmt-, bastion-to-internet", size=12.5, color=FW)
    c.text(970, 628, "eBGP peer group fabric: AS 65500 <> 65104 (the borders' local-as)\n"
                     "one session per VRF and border on the .100 / .200 / .300 /30s\n"
                     "everything between VLANs 100, 200 and 300 crosses this firewall", size=12.5, color=FW)
    c.link("pc-1", "fw-e4", OI, width=2, sa="r", sb="l"); c.link("pc-2", "fw-e6", OI, width=2, sa="r", sb="l")
    c.poly([(1750, 350), (1750, 492)], WAN, 3)

    # ---------------------------------------------------------------- frontend fabric
    c.frame(40, 790, 2500, 660, "FRONTEND FABRIC  -  Cisco Nexus 9300v, NX-OS 10.6(1)F: VXLAN EVPN, vPC Fabric Peering", C1,
            "underlay: OSPF area 0 on IP unnumbered links (loopback0), hello 1 s / dead 3 s, one link per spine   |   overlay: iBGP EVPN AS 65100, spines = route reflectors, ingress replication\n"
            "anycast gateway = the subnet's .1 on every leaf, MAC 000a.00c1.0001   |   vPC domains: 1 = fe-gpu-leaf1/2, 2 = fe-gpu-leaf3/4, 3 = fe-ctrl-leaf1/2   |   server ports: LACP, rate fast", bg="#f8fbff")
    for i, (col, t, s) in enumerate(((C1, "VLAN 100  DATA", "VRF k8s, 10.1.1.0/24, gateway 10.1.1.1\nL2 VNI 10100, RT 100:100\nL3 VLAN 3001, L3 VNI 11000, RT 1000:1000\nevery leaf pair: nodes + storage data"),
                                     (STO, "VLAN 200  STOR-MGMT", "VRF stor-mgmt, 10.1.20.0/24, gateway 10.1.20.1\nL2 VNI 10200, RT 200:200\nL3 VLAN 3002, L3 VNI 12000, RT 2000:2000\ncontrol pair only: storage management"),
                                     (C2, "VLAN 300  BASTION", "VRF bastion, 10.1.30.0/24, gateway 10.1.30.1\nL2 VNI 10300, RT 300:300\nL3 VLAN 3003, L3 VNI 13000, RT 3000:3000\ncontrol pair only: the bastion"))):
        c.node(f"vlan{i}", 230 + i * 350, 945, 336, 116, t, s, stroke=col, ssize=12)
    c.node("fe-border1", 1650, 945, 400, 110, "fe-border1", "lo0 10.0.0.17, VTEP lo1 10.0.1.17, no vPC\nEth1/3.100 / .200 / .300 = 10.1.254.1 / .9 / .17 (/30)\nVRF k8s / stor-mgmt / bastion (L3 VNIs only)\neBGP to the firewall: local-as 65104 <> 65500", stroke=C1, ssize=12, width=3)
    c.node("fe-border2", 2090, 945, 400, 110, "fe-border2", "lo0 10.0.0.18, VTEP lo1 10.0.1.18, no vPC\nEth1/3.100 / .200 / .300 = 10.1.254.5 / .13 / .21 (/30)\nVRF k8s / stor-mgmt / bastion (L3 VNIs only)\neBGP to the firewall: local-as 65104 <> 65500", stroke=C1, ssize=12, width=3)
    c.link("fw-e1", "fe-border1", FW, width=4); c.link("fw-e2", "fe-border2", FW, width=4)
    c.node("fe-spine1", 1050, 1135, 400, 84, "fe-spine1", "lo0 10.0.0.1, iBGP AS 65100, EVPN route reflector\nEth1/1-4 GPU leaves, 1/5-6 control leaves, 1/7-8 borders", stroke=C1, ssize=12)
    c.node("fe-spine2", 1490, 1135, 400, 84, "fe-spine2", "lo0 10.0.0.2, iBGP AS 65100, EVPN route reflector\nEth1/1-4 GPU leaves, 1/5-6 control leaves, 1/7-8 borders", stroke=C1, ssize=12)
    leaves = [("fe-ctrl-leaf1", 330, "lo0 10.0.0.15, VTEP lo1 10.0.1.15\nvPC domain 3, pair VIP 10.0.1.103\npeer-link lo2 10.0.2.15 > 10.0.2.16\nVLAN 100 + 200 + 300"),
              ("fe-ctrl-leaf2", 790, "lo0 10.0.0.16, VTEP lo1 10.0.1.16\nvPC domain 3, pair VIP 10.0.1.103\npeer-link lo2 10.0.2.16 > 10.0.2.15\nVLAN 100 + 200 + 300"),
              ("fe-gpu-leaf1", 1320, "lo0 10.0.0.11, VTEP lo1 10.0.1.11\nvPC domain 1, pair VIP 10.0.1.101\npeer-link lo2 10.0.2.11 > 10.0.2.12\nVLAN 100"),
              ("fe-gpu-leaf2", 1660, "lo0 10.0.0.12, VTEP lo1 10.0.1.12\nvPC domain 1, pair VIP 10.0.1.101\npeer-link lo2 10.0.2.12 > 10.0.2.11\nVLAN 100"),
              ("fe-gpu-leaf3", 2010, "lo0 10.0.0.19, VTEP lo1 10.0.1.19\nvPC domain 2, pair VIP 10.0.1.102\npeer-link lo2 10.0.2.19 > 10.0.2.20\nVLAN 100"),
              ("fe-gpu-leaf4", 2350, "lo0 10.0.0.20, VTEP lo1 10.0.1.20\nvPC domain 2, pair VIP 10.0.1.102\npeer-link lo2 10.0.2.20 > 10.0.2.19\nVLAN 100")]
    for n, x, s in leaves:
        c.node(n, x, 1355, 290, 108, n, s, stroke=C1, ssize=12)
        for i, sp in enumerate(("fe-spine1", "fe-spine2")): c.link(n, sp, UND, fb=0.3 + 0.4 * i)
    for b in ("fe-border1", "fe-border2"):
        for i, sp in enumerate(("fe-spine1", "fe-spine2")): c.link(b, sp, UND, fa=0.4 + 0.2 * i, fb=0.4 + 0.2 * i)
    for a, b in (("fe-ctrl-leaf1", "fe-ctrl-leaf2"), ("fe-gpu-leaf1", "fe-gpu-leaf2"), ("fe-gpu-leaf3", "fe-gpu-leaf4")):
        c.link(a, b, C1, width=3, sa="r", sb="l", style="dashed")
    c.text(560, 1326, "vPC domain 3\nFabric Peering", size=11, color=C1, center=True)
    c.text(100, 1140, "every leaf and border: Eth1/1 > fe-spine1, Eth1/2 > fe-spine2\nno leaf-to-leaf cabling", size=13, color=C1)

    # ---------------------------------------------------------------- servers
    SY = 1575
    c.node("ctrl-cp", 170, SY, 220, 130, "ctrl1 .. ctrl3", "control plane\nbond0: 10.1.1.11 - .13\nEth1/3-5, vPC 1-3\nBMC NIC 10.1.2.11 - .13", stroke=C1, ssize=12)
    c.node("ctrl-w", 410, SY, 220, 130, "ctrl4 .. ctrl6", "workers\nbond0: 10.1.1.14 - .16\nEth1/6-8, vPC 4-6\nBMC NIC 10.1.2.14 - .16", stroke=C1, ssize=12)
    c.node("bastion", 640, SY, 200, 130, "bastion", "VLAN 300\nbond0: 10.1.30.17\nEth1/9, vPC 7\nBMC NIC 10.1.2.17", stroke=C2, ssize=12)
    c.node("storage", 940, SY, 360, 130, "storage", "bond0: 8 NICs, Eth1/10-13 on each leaf, vPC 8\ntrunk, VLAN 100 tagged: bond0.100 = 10.1.1.18\nFM1 10.1.20.11 > fe-ctrl-leaf1 Eth1/14 (VLAN 200)\nFM2 10.1.20.12 > fe-ctrl-leaf2 Eth1/14 (VLAN 200)\nmanagement VIP 10.1.20.18; no BMC NIC", stroke=STO, ssize=12)
    c.node("gpu-a", 1490, SY, 620, 130, "gpu1 .. gpu16", "bond0 (eth1 + eth2, LACP): VLAN 100, 10.1.1.21 - .36\nEth1/3-18 on fe-gpu-leaf1 and fe-gpu-leaf2, vPC 1-16\n8 rail NICs gpu0-gpu7 (eth4-eth11): NIC r > be-leaf r eth5-20, 172.16.r.11 - .26\nBMC NIC eth3 > oob-sw eth1-16, 10.1.2.21 - .36", stroke=C1, ssize=12)
    c.node("gpu-b", 2180, SY, 620, 130, "gpu17 .. gpu32", "bond0 (eth1 + eth2, LACP): VLAN 100, 10.1.1.37 - .52\nEth1/3-18 on fe-gpu-leaf3 and fe-gpu-leaf4, vPC 1-16\n8 rail NICs gpu0-gpu7 (eth4-eth11): NIC r > be-leaf r eth21-36, 172.16.r.27 - .42\nBMC NIC eth3 > oob-sw eth17-32, 10.1.2.37 - .52", stroke=C1, ssize=12)
    for n, col, f1, f2, w in (("ctrl-cp", C1, 0.12, 0.10, 2), ("ctrl-w", C1, 0.30, 0.26, 2), ("bastion", C2, 0.50, 0.42, 2), ("storage", C1, 0.68, 0.60, 4)):
        c.link(n, "fe-ctrl-leaf1", col, width=w, sa="t", sb="b", fa=0.35, fb=f1); c.link(n, "fe-ctrl-leaf2", col, width=w, sa="t", sb="b", fa=0.65, fb=f2)
    c.link("storage", "fe-ctrl-leaf1", STO, width=2, sa="t", sb="b", fa=0.2, fb=0.88); c.link("storage", "fe-ctrl-leaf2", STO, width=2, sa="t", sb="b", fa=0.85, fb=0.8)
    c.link("gpu-a", "fe-gpu-leaf1", C1, sa="t", sb="b", fa=0.3); c.link("gpu-a", "fe-gpu-leaf2", C1, sa="t", sb="b", fa=0.7)
    c.link("gpu-b", "fe-gpu-leaf3", C1, sa="t", sb="b", fa=0.3); c.link("gpu-b", "fe-gpu-leaf4", C1, sa="t", sb="b", fa=0.7)

    # ---------------------------------------------------------------- OOB bus (BMC NICs) and the OOB switch in the right column
    BUS = 1680
    c.poly([(170, BUS), (2620, BUS)], OOB, 3, "dotted")
    for x in (170, 410, 640, 1230, 1920): c.poly([(x, SY + 65), (x, BUS)], OOB, 2, "dotted")
    c.text(700, BUS + 8, "BMC / OOB NICs (eth3 of every node and of the bastion) > oob-sw access ports, VLAN OOB", size=12, color=OOB)

    # ---------------------------------------------------------------- backend
    BY = 1730
    c.frame(40, BY, 3180, 470, "BACKEND RAILS  -  OcNOS SP VM 7.0.0-262, rail-optimised: rail R = be-leaf R", BE,
            "rail R: VLAN R x 10, 172.16.R.0/24, gateway .1 on vlan1.<R x 10>, bridged on its leaf (same rail never reaches a spine)   |   eBGP: spines AS 65200, leaf L AS 65200 + L\n"
            "numbered /31 underlay 10.255.<spine>.x, BFD, 4-way ECMP, MTU 9198   |   pods: macvlan net-rail-0..7 on gpu0..gpu7, whereabouts .64 - .254, no routes: rails stay separate", bg="#fff5f8")
    HAR = BY + 112
    LX = [235 + i * 393 for i in range(8)]
    for i, x in enumerate(LX):
        r = i + 1
        c.node(f"be-leaf{r}", x, BY + 200, 300, 100, f"be-leaf{r}", f"rail {r}: VLAN {r * 10}, 172.16.{r}.0/24\nAS {65200 + r}, lo 192.168.1.{r}\neth1-4 = be-spine1-4, eth5-36 = gpu1-32", stroke=BE, ssize=12)
        c.poly([(x, HAR), (x, BY + 150)], BE, 2)
        c.text(x + 10, HAR + 9, f"NIC {r} = gpu{r - 1} (eth{3 + r})", size=12, color=BE)
    SX = [431, 1217, 2003, 2789]
    for j, x in enumerate(SX):
        s = j + 1
        c.node(f"be-spine{s}", x, BY + 395, 380, 84, f"be-spine{s}", f"AS 65200, lo 192.168.100.{s}\neth1-8 = be-leaf1-8, 10.255.{s}.0/31 .. 10.255.{s}.14/31", stroke=BE, ssize=12)
    for r in range(1, 9):
        for s in range(1, 5): c.link(f"be-leaf{r}", f"be-spine{s}", RAILL, width=1.5, fa=0.2 + 0.2 * (s - 1), fb=0.1 + 0.114 * (r - 1))
    c.poly([(LX[0], HAR), (LX[7], HAR)], BE, 4)
    T1, T2 = 1610, 2400
    c.poly([(T1, SY + 65), (T1, HAR)], BE, 4); c.poly([(T2, SY + 65), (T2, HAR)], BE, 4)
    c.text(T1 + 20, HAR - 26, "8 rail NICs per GPU node: NIC r of gpuN > be-leaf r port eth(4 + N), address 172.16.r.(10 + N)", size=12, color=BE)

    # ---------------------------------------------------------------- right column: Kubernetes layer, management network, OOB network
    RX, RW = 2580, 640; RC = RX + RW / 2
    c.frame(RX, 410, RW, 540, "KUBERNETES LAYER", C1, "one cluster, domain lab.ai, Kubernetes v1.35.8, Cilium 1.19.7")
    c.node("k-gw", RC, 535, 590, 96, "Gateway VIP 10.1.1.200", "Cilium Gateway (Envoy), L2-announced on bond0 by a control node\n(ctrl3 in the traces); LB pool 10.1.1.200 - 10.1.1.209\nTLS: *.platform.lab.ai certificate of the lab CA", stroke=C1, ssize=12)
    c.text(RX + 26, 592, "published (urls.txt): https://<name>.platform.lab.ai with <name> = demo, harbor,\nheadlamp, hubble, inference, longhorn, s3-console, s3, webui", size=12.5, color=C1)
    c.node("k-api", RC, 668, 590, 60, "API VIP 10.1.1.20", "api.lab.ai:6443, control plane ctrl1 - ctrl3", stroke=C1, ssize=12)
    c.node("k-sm", RC, 755, 590, 84, "Storage management VIP 10.1.20.18", "VLAN 200 (VRF stor-mgmt), on the storage node's FM1 10.1.20.11 / FM2 10.1.20.12\nmanagement API tcp 443, reached from VLAN 100 only through the firewall", stroke=STO, ssize=12)
    c.text(RX + 26, 808, "nodes: ctrl1-3 control-plane, ctrl4-6 worker, gpu1-32 gpu, storage\n"
                         "pods 10.42.0.0/16, services 10.43.0.0/16, geneve between nodes\n"
                         "Cilium devices bond0, bond0.100; node MTU 9000\n"
                         "rails: Multus macvlan net-rail-0..7 (whereabouts), SoftRoCE rxe_gpu0..7\n"
                         "Longhorn (RWX = share-manager, NFS); Harbor on ctrl4-6; MinIO S3 on the storage node\n"
                         "language model: llama-server on gpu2 / gpu25 + RPC workers over rails 3 / 6 (Service llm)\n"
                         "= a model of the inference gateway (Envoy > APISIX > LiteLLM > east-west to the GPU nodes)\n"
                         "DNS for every name: dns-b 10.80.15.53", size=12.5, color=INK)

    c.frame(RX, 980, RW, 390, "MANAGEMENT NETWORK OF THE LAB HOST", INK, "containerlab management network, 172.21.21.0/24")
    c.node("m-host", RC, 1095, 590, 92, "lab host", "172.21.21.1 = gateway of the management network\nNAT 172.21.21.0/24 > pnet0; SNMP trap target udp 162\nfrom the Mac: Tailscale route to 172.21.21.0/24", stroke=INK, ssize=12)
    c.text(RX + 26, 1154, "fe-spine1 / 2:  .11 / .12\nfe-gpu-leaf1 / 2:  .13 / .14\nfe-gpu-leaf3 / 4:  .22 / .23\nfe-ctrl-leaf1 / 2:  .17 / .18\nfe-border1 / 2:  .19 / .20\noob-sw:  .21\nfw (web UI, https):  .30", size=12, color=INK)
    c.text(RX + 330, 1154, "be-spine1-4:  .41 - .44\nbe-leaf1-8:  .51 - .58\nctrl1-6:  .111 - .116\nbastion:  .117\nstorage:  .118\ngpu1-32:  .121 - .152\npc-1 / pc-2:  .161 / .162", size=12, color=INK)
    c.text(RX + 26, 1270, "Nexus: mgmt0 in VRF management, default route 172.21.21.1; the vPC\n"
                          "peer-keepalive of each pair runs over mgmt0. Switches and firewall take\n"
                          "NTP from 10.80.15.53 on their management ports. Access: ssh with the\n"
                          "operator keys; kubectl from the bastion container.", size=12.5, color=SUB)

    c.frame(RX, 1400, RW, 310, "OOB / BMC NETWORK", OOB, "10.1.2.0/24, gateway 10.1.2.254 = firewall ethernet1/3 (zone oob)")
    c.text(RX + 26, 1466, "eth1-32: BMC NICs of gpu1-32, 10.1.2.21 - .52\n"
                          "eth33-38: BMC NICs of ctrl1-6, 10.1.2.11 - .16\n"
                          "eth39: bastion, 10.1.2.17      eth41: firewall ethernet1/3\n"
                          "storage node: no BMC NIC in this profile (management on VLAN 200)\n"
                          "on a node the BMC subnet's route lives only in table 100", size=12.5, color=OOB)
    c.node("oob-sw", RC + 10, 1640, 560, 92, "oob-sw", "Juniper vEX (vJunos-switch 26.2R1.7), Layer 2 only\nVLAN OOB (vlan-id 100), access ports ge-0/0/0 .. ge-0/0/40 (eth1 .. eth41), LLDP\nmanagement 172.21.21.21", stroke=OOB, ssize=12, width=3)
    c.poly([(2480, 540), (2560, 540), (2560, 1620), (2620, 1620)], OOB, 3)
    c.text(2594, 1596, "eth41", size=12, color=OOB)

    c.text(40, BY + 490, "Drawn by diagram/ai_fabric.py. Sources: gen.py, the containerlab topology, configs/ (Nexus, OcNOS, vEX), fw-running-config-set-format.txt, mgmt-hosts.txt, urls.txt, README.md, audits of 2026-10-04.", size=12)
    c.save("ai-fabric-1-topology.excalidraw")


# ====================================================================================================== figure 2: flows
XS = [230 + i * 330 for i in range(9)]; W, H = 300, 120


def lane(c, y, col, tag, sub, boxes, labels):
    """One flow: a coloured title, an evidence line, boxes left to right, a short label above every arrow.
    A label starting with "|" leaves a gap (a new sub-flow starts; the rest of the label names it); a label starting with "~" draws a
    dashed arrow (an attempt that must fail)."""
    c.square(40, y - H / 2 - 100, 22, col)
    c.text(72, y - H / 2 - 104, tag, size=18, color=col)
    c.text(72, y - H / 2 - 76, sub, size=12.5, color=SUB)
    ids = []
    for i, (t, s) in enumerate(boxes):
        n = f"{tag[:7]}-{y}-{i}"; ids.append(n)
        c.node(n, XS[i], y, W, H, t, s, stroke=col, width=3, size=15, ssize=12)
    for i, l in enumerate(labels):
        if i + 1 >= len(ids): break
        mid = (XS[i] + XS[i + 1]) / 2
        if l.startswith("|"):
            if l[1:]: c.text(mid + 22, y - H / 2 - 32, l[1:], size=12, color=SUB)
            continue
        dash = l.startswith("~"); l = l.lstrip("~")
        c.link(ids[i], ids[i + 1], col, width=3, arrow=True, style="dashed" if dash else "solid")
        c.text(mid, y - H / 2 - 32, l, size=12, color=col, center=True)


def flows():
    c = Canvas()
    c.text(40, 14, "ai-fabric: every flow, hop by hop", size=32, color=INK)
    c.text(40, 60, "One lane per flow, left to right, with the real hop names, interfaces and addresses of the traces. Frontend: VLAN 100 DATA 10.1.1.0/24 (VRF k8s, L2 VNI 10100, L3 VNI 11000), VLAN 200 STOR-MGMT 10.1.20.0/24 (L3 VNI 12000), "
                   "VLAN 300 BASTION 10.1.30.0/24 (L3 VNI 13000). Backend: rail R = be-leaf R = VLAN R x 10 = 172.16.R.0/24. OOB 10.1.2.0/24. Management 172.21.21.0/24.", size=15)
    c.frame(40, 110, 3000, 150, "LEGEND", INK)
    x = 70
    for col, t in ((OI, "enterprise user"), (WAN, "external network (DNAT)"), (C1, "frontend fabric"), (STO, "storage management"), (BE, "backend rails"), (OOB, "OOB / management"), (C2, "AI training"), (INF, "AI inference")):
        c.square(x, 158, 24, col); c.text(x + 36, 160, t, size=15, color=col); x += 365
    c.poly([(70, 222), (150, 222)], INK, 3, "solid", arrow=True); c.text(164, 213, "hop seen in a trace or stated by the configs", size=12.5, color=INK)
    c.poly([(620, 222), (700, 222)], INK, 3, "dashed", arrow=True); c.text(714, 213, "attempt that must fail (asserted by the trace)", size=12.5, color=INK)
    c.text(1180, 213, "Evidence of 2026-10-04: end-to-end trace through the inference gateway 38 / 0, AI workload trace 19 / 0 (training) and 29 / 0 (inference), "
                      "rail trace 17 / 0 + 1 known limit, PVC traces from ctrl1 and gpu32 27 / 0 each, SoftRoCE probe 7 passed + 3 known limits.", size=12.5, color=SUB)
    Y, s = 462, 236

    lane(c, Y, OI, "F1  enterprise user > LLM on the GPU nodes: pc-1 / pc-2 > firewall > fe-border1 > VXLAN > Envoy on ctrl3 > APISIX > LiteLLM > east-west > gpu2 / gpu25",
         "End-to-end trace: https://inference.platform.lab.ai (the inference gateway) with a bearer key, model Qwen/Qwen2.5-0.5B-Instruct, answered HTTP 200. North-south to the Gateway VIP, through the gateway chain, then east-west to the model on the GPU nodes; the reply returns the same way, through either border leaf.",
         [("pc-1 / pc-2", "10.66.10.10 / 10.66.20.10\ninference.platform.lab.ai\nresolves to 10.1.1.200 (dns-b)"),
          ("fw ethernet1/4 / 1/6", "zone enterprise\nrule enterprise-to-data\nno NAT on the way in"),
          ("fw ethernet1/1.100 > fe-border1", "zone data, tag 100, eBGP 65500 <> 65104\nthe firewall's ONE active route (no ECMP)\nreplies return via fe-border1 or 2"),
          ("fe-border1 > fe-spine1 / 2", "10.1.1.200/32 = EVPN type-2 host route\nVXLAN L3 VNI 11000 to 10.0.1.103\nECMP over the OSPF underlay"),
          ("fe-ctrl-leaf pair > ctrl3", "decapsulate, VLAN 100, vPC Eth1/5\nEnvoy (Gateway VIP 10.1.1.200) ends TLS\nHTTPRoute inference"),
          ("APISIX on ctrl5", "the API gateway\none route per model: /models/<id>/proxy/\ngeneve between nodes"),
          ("LiteLLM on ctrl4", "checks the bearer key\npicks the model's backend:\nService llm (ai-sim), tcp 8080"),
          ("east-west: spines > GPU leaf pairs", "Geneve 10.1.1.14 > 10.1.1.22 / .45\ninside VXLAN L2 VNI 10100\nEth1/4 (gpu2), Eth1/11 (gpu25)"),
          ("gpu2 / gpu25: the model", "llama-server pods llm-a, llm-b\n+ RPC workers over rail 3 / rail 6\nHTTP 200 with the answer")],
         ["tcp 443", "policy", "802.1Q tag 100", "VXLAN, L3 VNI 11000", "HTTPRoute", "http", "east-west", "vPC"])

    lane(c, Y + s, WAN, "F2  external-network client > firewall outside address 10.80.15.121 (DNAT) > Gateway VIP 10.1.1.200 > gateway chain > east-west > gpu2 / gpu25",
         "End-to-end trace, client 10.80.15.10: HTTP 200. External-network hosts can also route to 10.1.1.0/24 through the firewall without NAT (rule internet-to-inside-vips, tcp 80 / 443 / 6443).",
         [("external host", "10.80.15.10 (the lab host)\nname pinned to 10.80.15.121\nhttps://inference.platform.lab.ai"),
          ("pnet0", "external-network bridge, 10.80.15.0/24\nport fw-ext"),
          ("fw ethernet1/5", "zone internet\noutside address 10.80.15.121\nrule internet-to-inside-vips"),
          ("NAT dnat-gateway-vip", "10.80.15.121:443 > 10.1.1.200\nclient address preserved\nnothing for .121 leaks into the fabric"),
          ("fw ethernet1/1.100 > fe-border1", "zone data, tag 100, the active route\nreply: NAT reversed, back to .121"),
          ("fe-border > fe-spine", "VRF k8s, VXLAN L3 VNI 11000\nto the control pair VIP 10.0.1.103"),
          ("fe-ctrl-leaf1 / fe-ctrl-leaf2", "VLAN 100\nvPC bond, Eth1/5"),
          ("ctrl3: Gateway VIP 10.1.1.200", "Envoy sees client 10.80.15.10\nthen as F1: APISIX > LiteLLM >\neast-west to the model, HTTP 200")],
         ["tcp 443", "fw-ext", "DNAT", "route", "802.1Q tag 100", "VXLAN", "vPC, Eth1/5"])

    lane(c, Y + 2 * s, C1, "F3  node to node on the frontend: same leaf pair (VLAN 100 on the vPC pair) and across leaf pairs (VXLAN L2 VNI 10100)",
         "From the generated switch configs (the audit set has no east-west trace). Routed traffic of VRF k8s to and from the borders uses L3 VNI 11000; VLAN 200 / 300 exist on the control pair only; between VLANs the only path is the firewall.",
         [("gpu1", "bond0 10.1.1.21\neth1 + eth2, LACP, VLAN 100"),
          ("fe-gpu-leaf1 / fe-gpu-leaf2", "vPC domain 1 (Fabric Peering)\nEth1/3 (vPC 1) > Eth1/4 (vPC 2)\nbridged in VLAN 100, no VXLAN"),
          ("gpu2", "bond0 10.1.1.22\nsame VLAN, same leaf pair"),
          ("gpu1", "bond0 10.1.1.21\n10.1.1.0/24 is on every leaf pair"),
          ("fe-gpu-leaf1 / fe-gpu-leaf2", "VLAN 100 = L2 VNI 10100\nVTEP: pair VIP 10.0.1.101\ningress replication (BGP)"),
          ("fe-spine1 / fe-spine2", "OSPF area 0, IP unnumbered\nECMP, one link per spine"),
          ("fe-gpu-leaf3 / fe-gpu-leaf4", "pair VIP 10.0.1.102\ndecapsulate to VLAN 100\nvPC domain 2, Eth1/3 (vPC 1)"),
          ("gpu17", "bond0 10.1.1.37"),
          ("the control leaf pair", "ctrl1-6 10.1.1.11 - .16, storage 10.1.1.18\nfe-ctrl-leaf1 / 2, pair VIP 10.0.1.103\nsame L2 VNI 10100")],
         ["bond0", "vPC", "|across leaf pairs:", "bond0", "L2 VNI 10100", "VXLAN", "vPC", "|likewise:"])

    lane(c, Y + 3 * s, STO, "F4  storage: a PVC through the storage management API (zone data > firewall > zone stor-mgmt), management VIP 10.1.20.18 on VLAN 200, then the volume's data path",
         "PVC traces from ctrl1 (10.1.1.11) and gpu32 (10.1.1.52). tcp 8443 and ICMP reach the firewall and are dropped there; control check: bastion > 10.1.20.18 tcp 22 is allowed (rule bastion-to-stor-mgmt).",
         [("ctrl1 / gpu32: pvc-tool.sh", "10.1.1.11 / 10.1.1.52\nPOST https://10.1.20.18/api/2.4/file-systems\nvia the gateway 10.1.1.1 on bond0"),
          ("server leaf pair", "fe-ctrl-leaf1 / 2 port 3 (ctrl1)\nfe-gpu-leaf3 / 4 port 18 (gpu32)\nvrf k8s: type-5 default from the firewall"),
          ("fe-border1 / fe-border2", "VRF k8s\nEth1/3.100 > firewall"),
          ("fw ethernet1/1.100 or 1/2.100", "zone data > zone stor-mgmt\nrule data-to-stor-mgmt, tcp 443 only\nno NAT, routed hop (TTL one lower)"),
          ("fw ethernet1/1.200 or 1/2.200", "the same ports, tag 200\nzone stor-mgmt\n10.1.254.10/30, 10.1.254.14/30"),
          ("fe-border1 / 2, VRF stor-mgmt", "Eth1/3.200\nVXLAN to the control leaf pair"),
          ("fe-ctrl-leaf1 / fe-ctrl-leaf2", "VLAN 200, gateway 10.1.20.1\nEth1/14 = FM1 / FM2 links (no bond)"),
          ("storage: VIP 10.1.20.18", "FM1 10.1.20.11, FM2 10.1.20.12\nAPI logs the node's fabric address\nHTTP 201, PVC Bound (Longhorn)"),
          ("data path", "a pod mounts the Longhorn volume\nover the fabric, writes, reads back\nthen DELETE through the API")],
         ["bond0, VLAN 100", "VXLAN L3 VNI 11000", "tag 100", "policy", "tag 200", "VXLAN L3 VNI 12000", "VLAN 200, Eth1/14", "PVC"])

    lane(c, Y + 4 * s, BE, "F5  backend rails: GPU pod to GPU pod on the same rail (bridged on the rail leaf), rails stay separate, SoftRoCE probe on rail 1",
         "Rail trace gpu1 <> gpu8 and SoftRoCE probe gpu1 <> gpu2. Known limits of the virtual platform: the RDMA plugin discovers no SoftRoCE device, pod-to-pod RoCE over the pods' own GIDs fails (kernel 6.8), RDMA CM from a pod is not run.",
         [("pod rt-a on gpu1", "net1 172.16.1.64 (rail 1)\nmacvlan on gpu0, NAD net-rail-0\nwhereabouts range .64 - .254"),
          ("be-leaf1 (rail 1, VLAN 10)", "eth5 > eth12, bridged on the leaf\n0 frames on its 4 uplinks\njumbo 8972 bytes DF passes"),
          ("pod rt-b on gpu8", "net1 172.16.1.65\nno spine, no routing"),
          ("rt-a rail 2 (net2)", "172.16.2.64, ping bound to net2\nonly the connected /24 of each rail\nno 172.16.0.0/16 route in the pod"),
          ("be-leaf2, spines, be-leaf5", "no frame of the attempt on any\nrail capture point: leaf ports,\nuplinks, spine ports"),
          ("rt-b rail 5 address", "172.16.5.64 on gpu8\n100% loss: rails are\nseparate networks"),
          ("gpu1: rxe_gpu0", "SoftRoCE on the rail NIC gpu0\nRoCE v2 GID 172.16.1.11"),
          ("be-leaf1 (rail 1, VLAN 10)", "bridged on the leaf\nRoCE v2 = udp 4791"),
          ("gpu2: rxe_gpu0", "RoCE v2 GID 172.16.1.12\nhost verbs 5.78, RDMA CM 5.89 Gbit/s\npods through host GIDs 5.86 Gbit/s")],
         ["rail 1", "rail 1", "|rail 2 to rail 5:", "~must fail", "~must fail", "|RoCE probe:", "RoCE v2", "RoCE v2"])

    lane(c, Y + 5 * s, OOB, "F6  out-of-band and management access: BMC network behind the firewall, the bastion (VLAN 300), the lab host's management network",
         "From the firewall running config, the oob-sw config, gen.py and the README. The audit set traces none of these paths, except the PVC trace's control check (bastion > 10.1.20.18 tcp 22: open).",
         [("pc-1 / pc-2", "zone enterprise\n10.66.10.10 / 10.66.20.10"),
          ("fw ethernet1/4, 1/6 > 1/3", "rule enterprise-to-oob\nzone oob, gateway 10.1.2.254"),
          ("oob-sw", "Juniper vEX, Layer 2\nVLAN OOB, access ports\neth41 = firewall"),
          ("BMC NIC of a node", "eth3, 10.1.2.<host octet>\ngpu1-32, ctrl1-6, bastion\n(the storage node has none)"),
          ("bastion", "bond0 10.1.30.17, VLAN 300\nfe-ctrl-leaf1 / 2 Eth1/9, VRF bastion\nkubectl"),
          ("fw .300 > .100 / .200", "rules bastion-to-data and\nbastion-to-stor-mgmt\ntcp 22 / 80 / 443 / 6443"),
          ("nodes, API VIP, storage", "10.1.1.0/24, api.lab.ai 10.1.1.20:6443\n10.1.20.0/24, VIP 10.1.20.18"),
          ("operator", "Mac: Tailscale route to 172.21.21.0/24\nor the lab host itself, 172.21.21.1"),
          ("management port of a device", "172.21.21.x (mgmt0 / eth0)\nssh with the operator keys\nfirewall web UI https://172.21.21.30")],
         ["any service", "eth41", "access port", "|bastion:", "L3 VNI 13000, tag 300", "policy", "|management:", "ssh / https"])

    lane(c, Y + 6 * s, C2, "F7  AI training (PyTorch DistributedDataParallel, 4 ranks on gpu1, gpu8, gpu17, gpu32): T1 dataset + T3 checkpoints over the frontend, T2 gradients over rail 1, T4 collective ring on rails 2-8",
         "AI workload trace (3 epochs x 10 steps). gpu1 and gpu8 hang off the first frontend leaf pair, gpu17 and gpu32 off the second; all four ranks share rail 1.",
         [("T1 / T3: rank 0 pod on gpu1", "stages 4 shards x 41.1 MB, each rank\nreads its own (T1); rank 0 writes a\n4.0 MB checkpoint per epoch (T3)"),
          ("fe-gpu-leaf1 / fe-gpu-leaf2 eth3", "gpu1 bond0, VLAN 100\nCilium, geneve gpu1 > ctrl1"),
          ("share-manager pod on ctrl1", "Longhorn ReadWriteMany volume\nNFS tcp 2049\ndataset shards + 3 checkpoints"),
          ("T2: rank 0 on gpu1", "net1 172.16.1.64, gloo over TCP\nall-reduce after each of the 30 steps\n4.0 MB of gradients per step"),
          ("be-leaf1 (rail 1, VLAN 10)", "host ports eth5, eth12, eth21, eth36\nbridged; 0 frames on the 4 uplinks\n180 - 188 MB per port and direction"),
          ("ranks 1-3: gpu8, gpu17, gpu32", "172.16.1.66, 172.16.1.65, 172.16.1.67\none weight checksum on all ranks"),
          ("T4: the same 4 pods", "ring rank i > i + 1 on each of the\nrails 2-8 at once\n28 of 28 iperf3 flows completed"),
          ("be-leaf2 .. be-leaf8", "one rail leaf per rail\nframes on be-leafR eth5, R = 2 .. 8"),
          ("next rank in the ring", "same rail end to end\n(GPU r of a node to GPU r\nof the next node)")],
         ["geneve", "NFS tcp 2049", "|T2 gradients:", "rail 1", "rail 1", "|T4 collective:", "rail R", "rail R"])

    lane(c, Y + 7 * s, INF, "F8 / I1  AI inference, model load: qwen2.5-0.5b-instruct on llama.cpp, two replicas; at start each llama-server ships the model's layers to its two RPC workers over its rail",
         "AI workload trace: 395.5 MB from each server (137.1 MB + 258.5 MB to its workers), 3 s for both replicas; the RPC traffic stays on the rail leaf (0 frames on its 4 uplinks).",
         [("replica A: llm-a on gpu2", "llama-server pod\nsends 395.5 MB of model layers\ninto be-leaf3 eth6"),
          ("be-leaf3 (rail 3, VLAN 30)", "eth6 > eth13 and eth22\nbridged on the leaf"),
          ("RPC workers on gpu9, gpu18", "ggml-rpc-server\n172.16.3.68 (137.1 MB)\n172.16.3.69 (258.5 MB)"),
          ("replica B: llm-b on gpu25", "llama-server pod\nsends 395.5 MB of model layers\ninto be-leaf6 eth29"),
          ("be-leaf6 (rail 6, VLAN 60)", "eth29 > eth20 and eth35\nbridged on the leaf"),
          ("RPC workers on gpu16, gpu31", "ggml-rpc-server\n172.16.6.69 (137.1 MB)\n172.16.6.68 (258.5 MB)")],
         ["rail 3", "rail 3", "|replica B:", "rail 6", "rail 6"])

    lane(c, Y + 8 * s, INF, "F8 / I2  AI inference, request path: client > firewall > border leaves > VXLAN > control leaf pair > ctrl3 (Envoy, Gateway VIP) > Service llm > a replica > its RPC workers over the rail, and back",
         "AI workload trace: 9 of 9 chat completions answered HTTP 200 (pc-1, pc-2 and the external network, 3 each); without the bearer key HTTP 401. The model's direct route (llm-sim.platform.lab.ai: Envoy > Service llm); F1 and F2 reach the same replicas through the inference gateway.",
         [("pc-1 / pc-2 / external host", "10.66.10.10, 10.66.20.10 > 10.1.1.200\n10.80.15.10 > 10.80.15.121\nllm-sim.platform.lab.ai, bearer key"),
          ("fw in", "enterprise: ethernet1/4, 1/6\nexternal network: ethernet1/5\nDNAT 10.80.15.121 > 10.1.1.200"),
          ("fw ethernet1/1 > fe-border1", "requests: all out on ethernet1/1\nreplies: back on 1/1 or 1/2"),
          ("fe-border1 > fe-spine1 / 2", "VXLAN to the control leaf pair"),
          ("fe-ctrl-leaf1 / fe-ctrl-leaf2", "eth5 on both leaves\nto ctrl3"),
          ("ctrl3: Gateway VIP 10.1.1.200", "the node announcing the VIP\nEnvoy"),
          ("Service llm (namespace ai-sim)", "balances over the two replicas\nserved: A 3, B 6 of 9 requests"),
          ("llm-a on gpu2 / llm-b on gpu25", "llama-server, tcp 8080\nreached east-west from ctrl3"),
          ("RPC workers over the rail", "A: gpu9, gpu18 via be-leaf3 eth6\nB: gpu16, gpu31 via be-leaf6 eth29\ntcp 50052, then the answer returns")],
         ["tcp 443", "policy / DNAT", "ethernet1/1", "VXLAN", "eth5", "Envoy", "tcp 8080", "rail 3 / rail 6"])

    c.text(40, Y + 8 * s + 92, "Drawn by diagram/ai_fabric.py. Sources: audits of 2026-10-04 (e2e_trace, rail_trace, pvc_trace_ctrl, pvc_trace_gpu, rdma probe, ai_workload), gen.py, the containerlab topology, configs/, "
                               "fw-running-config-set-format.txt, README.md, ai-workload.sh.", size=12)
    c.save("ai-fabric-2-flows.excalidraw")


if __name__ == "__main__":
    topology(); flows()
