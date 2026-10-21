#!/usr/bin/env python3
"""gen_oob.py: OOB / BMC cabling for the production AI fabric, appended to the existing cabling workbook.

Grounded in the HLD sheet (diagrams/ai-fabric-32gpu.excalidraw), which states:
  "OOB / BMC <OOB subnet>/24: one BMC port per server, FlashBlade management, gateway on the firewall"
  "BMC: 1 port to the OOB switch"                       (per GPU node)
  "oob-sw (OOB / BMC switch) ... gateway = firewall"
  (FlashBlade management was on OOB until 2026-09-24; it now lands on the control leaves, see gen_cabling.py)

Operator decisions taken 2026-09-21 (everything the sheet did NOT specify):
  CPU nodes        = ctrl1-6 AND the bastion (7 BMC ports) - the sheet's rule is one BMC port per server
  ports per device = 1 per switch
  OOB switch       = a single logical `oob-sw`, sequential ports; model/port count still to be selected
  link             = 1G copper RJ45 (Cat6)

Port order on oob-sw follows the order the categories were requested in:
  1..12   backend switches  (be-leaf1-8, then be-spine1-4)
  13..44  GPU nodes         (gpu1..gpu32)
  45..51  CPU nodes         (ctrl1..ctrl6, then bastion)
Change the order in oob_rows() if the physical layout wants something else.

Operator decision 2026-09-24: the FlashBlade management ports (1 per appliance) moved OFF the OOB switch to the frontend
control leaves, in their own storage-management VLAN / VRF (gen_cabling.py frontend_ctrl). oob-sw ports 52-53 are free.
"""
SPEED, MEDIA = "1G", "RJ45 Cat6"
NOTE_SW  = "switch management port -> OOB, <OOB subnet>/24, gateway on the firewall"
NOTE_BMC = "BMC / lights-out port, one per server, <OOB subnet>/24, gateway on the firewall"

def oob_rows():
    rows, p = [], 1
    def add(dev, port_label, note):
        nonlocal p
        rows.append((dev, port_label, "oob-sw", f"port {p}", SPEED, MEDIA, note))
        p += 1
    for l in range(1, 9):  add(f"be-leaf{l}",  "mgmt0", NOTE_SW)
    for s in range(1, 5):  add(f"be-spine{s}", "mgmt0", NOTE_SW)
    for n in range(1, 33): add(f"gpu{n}",      "BMC",   NOTE_BMC)
    for i in range(1, 7):  add(f"ctrl{i}",     "BMC",   NOTE_BMC)
    add("bastion", "BMC", NOTE_BMC)
    return rows

if __name__ == "__main__":
    import csv, sys
    w = csv.writer(sys.stdout, lineterminator="\n")
    w.writerow(["a_device", "a_port", "b_device", "b_port", "speed", "media", "notes"])
    w.writerows(oob_rows())
    print(f"# {len(oob_rows())} links", file=sys.stderr)
