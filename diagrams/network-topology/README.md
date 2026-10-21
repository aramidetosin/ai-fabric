# production physical network topology

Generated on 22 September 2026 from the existing production physical-design drawing and cabling matrices. The original diagrams and lab configuration were preserved.

**Updated 24 September 2026** with the operator's decisions (the HLD sheet `../ai-fabric-32gpu`, rev 4, carries the same):

- FlashBlade management moved **off the OOB switch to the control leaves**: one port per appliance, flashblade-1 → fe-ctrl-leaf1 and flashblade-2 → fe-ctrl-leaf2, Ethernet1/12 on each (proposed, next free port). Speed and media stay open: the port was recorded as 1G RJ45 and the leaf ports are QSFP-DD.
- Three frontend VLANs, each its own VRF: `<data VLAN>` (VRF k8s), `<stor-mgmt VLAN>` (VRF stor-mgmt), `<bastion VLAN>` (VRF bastion). Every inter-VRF flow goes through the firewall on per-VRF dot1q sub-interfaces of the border-firewall links (zones data, stor-mgmt, bastion); no fabric zone reaches OOB any more. New VLANs and all VNIs are placeholders.
- Dual-homing is vPC Fabric Peering (virtual peer-link over the spines, peer-keepalive over mgmt0), replacing all-active ESI-LAG. Underlay OSPF unnumbered, overlay iBGP EVPN with the spines as route reflectors.

The overview shows the Cisco frontend, the firewall (vendor-neutral), logical OOB network, two groups of B300 servers, eight rail leaves and four backend spines. Bundled lines explicitly state their physical link counts. The port map identifies every GPU server's frontend, backend and OOB ports and provides rail addressing, control/storage cabling and backend uplink allocation.

| File | Use |
|---|---|
| `network-topology-handdrawn.excalidraw` | Hand-drawn overview with native Excalidraw strokes and the Virgil handwritten font |
| `network-topology-handdrawn.svg` / `.png` | Rendered Excalidraw-style overview; SVG embeds its font |
| `physical-topology.svg` / `.png` | Overview, scalable vector or image |
| `physical-port-map.svg` / `.png` | Detailed server and port map |
| `network-topology.drawio` | Editable diagram with two pages; network edges are attached to their nodes |
| `network-topology.excalidraw` | Editable scene with the two views placed side by side |
| `generate.py` | Self-contained Python source; reads the existing cabling CSVs |
| `render_handdrawn.py` | Restyles the overview and renders with the pinned Excalidraw 0.17.6 engine in local headless Chrome |

These are physical-design views. Virtual-lab addresses, dedicated emulated storage leaves and the expanded office profile are intentionally not substituted into the physical topology.

Still open, and explicit in the drawing:

- Physical frontend/OOB subnets, VIPs, new VLAN IDs, VNIs and frontend/firewall ASNs are unassigned (placeholders).
- Every frontend leaf has 2 × 400G to each of two spines, requiring four physical uplink ports. Exact port numbers remain unresolved because older cabling notes reserve only ports 31/32.
- OOB has 51 recorded links. Adding ten frontend switch management links (their mgmt0 also carries the vPC peer-keepalive) and the firewall uplink requires 62 logical ports before spares or other management endpoints. The drawing uses one logical block; it does not select a physical switch or switch count.

Settled by the operator on 24 September 2026:

- Backend leaf/spine links: four 800G routed links per pair, **BGP unnumbered** (the cabling notes no longer say /31).
- FlashBlade data: two appliances with four 100G links each, split evenly across the control leaves, in **one eight-member LACP bond (vPC)**, as drawn.
- FlashBlade management: one port per appliance, on the control leaves, **1G through a QSA adapter + 1000BASE-T SFP** in the 100G leaf port (RJ45).
- Backend lossless Ethernet: **PFC (priority 3) + ECN** as in the production switch configuration (`switch-configs/AI_FABRIC CLUSTER1/800g`, the AI-Leaf / AI-Spine ECN_PFC_Lossless templates). Speeds and capacity arithmetic still describe the design, not tested throughput.

The cabling matrices list 523 links: 384 backend, 88 frontend access (including the two FlashBlade management links) and 51 OOB. That count excludes 32 frontend fabric links, two firewall handoffs, frontend management and the firewall/OOB uplink. It is not a complete installed-cable total.

Generation uses Python's standard library. PNG exports use `rsvg-convert`. The generator checks the three CSV row counts, unique cable endpoints, and all 32 GPU servers' two frontend, eight backend and one OOB connection. SVG and editable-file parsing plus a visual review of both PNGs complete the local checks. No vendor compatibility or live network validation was performed during diagram generation.

Source inputs: the parent `gen_topology.py`, the project's `cabling/` CSVs and README, and `/Volumes/Lexar/LAB_ANALYSIS.md`.

The hand-drawn overview preserves all 88 overview text labels. It uses 197 editable objects and is exported at 2420 × 1800 pixels. The renderer loads Excalidraw code and the Virgil font, measures labels to fit the existing geometry, and renders locally. It does not upload the topology to an editor service. The PNG was visually checked and the SVG and editable scene were parsed successfully.
