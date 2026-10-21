#!/usr/bin/env python3
"""fw-merge-vlans.py <override.xml> [out.xml]: apply the site-a-nx VLAN design (gen.fw_vlans) to the operator's firewall config capture.

The office PA-VM boots from bootstrap/fw-override.xml (the operator's running-config capture, written by fw-backup.sh), so gen.py's own fw.xml
never reaches it. This applies EXACTLY the transformation gen.py applies to fw.xml -- same function -- to that capture, keeping everything else the
operator has in it (admin account, UI edits). Writes out.xml (default: <override>.vlans) and prints what changed; the original is not touched.
Operator decision 2026-09-23: "merge into override, remove everything that is not needed for this new design".
"""
import os, sys, xml.etree.ElementTree as ET
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen

if not gen.MULTI: sys.exit(f"profile {gen.PROFILE} has no VLAN design (vlans=True): nothing to merge")
src = sys.argv[1]; dst = sys.argv[2] if len(sys.argv) > 2 else src + ".vlans"
tree = ET.parse(src); root = tree.getroot()

def inventory(r):
    vs = r.find("devices/entry/vsys/entry"); net = r.find("devices/entry/network"); sysx = r.find("devices/entry/deviceconfig/system")
    return dict(
        zones={z.get("name"): sorted(m.text for m in z.findall("network/layer3/member")) for z in vs.findall("zone/entry")},
        rules=[e.get("name") for e in vs.findall("rulebase/security/rules/entry")],
        snat_from=sorted(m.text for m in vs.findall("rulebase/nat/rules/entry[@name='internet-snat']/from/member")),
        subifs=sorted(u.get("name") for u in net.findall("interface/ethernet/entry/layer3/units/entry")),
        addresses={**{e.get("name"): sorted(i.get("name") for i in e.findall("layer3/ip/entry")) or ["(none)"] for e in net.findall("interface/ethernet/entry/layer3/..")},
                   **{u.get("name"): sorted(i.get("name") for i in u.findall("ip/entry")) or ["(none)"] for u in net.findall("interface/ethernet/entry/layer3/units/entry")}},
        router_ifs=sorted(m.text for m in net.findall("virtual-router/entry/interface/member")),
        rule_zones={e.get("name"): ",".join(m.text for m in e.findall("from/member")) + " -> " + ",".join(m.text for m in e.findall("to/member"))
                    for e in vs.findall("rulebase/*/rules/entry")},
        bgp_peers={p.get("name"): p.findtext("local-address/interface") for p in net.findall("virtual-router/entry/protocol/bgp/peer-group/entry/peer/entry")},
        services=sorted(s.get("name") for s in vs.findall("service/entry")),
        dns=[c.tag + "=" + (c.text or "") for c in (sysx.find("dns-setting/servers") if sysx.find("dns-setting/servers") is not None else [])],
        ntp=[(n.text or "") for n in sysx.findall("ntp-servers/*/ntp-server-address")],
        service_routes={e.get("name"): e.findtext("source/interface") for e in sysx.findall("route/service/entry")})

before = inventory(root)
gen.fw_vlans(root)
after = inventory(root)
tree.write(dst, encoding="utf-8", xml_declaration=False)
print(f"{src} -> {dst}")
for k in before:
    if before[k] == after[k]: print(f"  {k:15} unchanged"); continue
    if isinstance(before[k], dict):
        for z in sorted(set(before[k]) | set(after[k])):
            if before[k].get(z) != after[k].get(z): print(f"  {k:15} {z}: {before[k].get(z)} -> {after[k].get(z)}")
    else:
        add = [x for x in after[k] if x not in before[k]]; rem = [x for x in before[k] if x not in after[k]]
        print(f"  {k:15} +{add} -{rem}")
