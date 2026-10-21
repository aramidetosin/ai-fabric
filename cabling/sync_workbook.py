#!/usr/bin/env python3
"""sync_workbook.py: refresh the DATA of ai-fabric-cabling.xlsx from the generators, in place.

The workbook is the operator's (their Summary wording, freeze panes and column widths stay). This rewrites only:
  Backend / Frontend / OOB   the data rows under each sheet's header row (row 3), from gen_cabling.py / gen_oob.py,
                             with the same banding and borders the sheets already use; each sheet's auto-filter follows
  row 1 notes                of Frontend and OOB, where they describe the FlashBlade management ports
  Summary                    the link counts (derived from the rows) and the FlashBlade management wording
2026-09-24: FlashBlade management moved from oob-sw ports 52-53 to the control leaves (Ethernet1/12, PROPOSED).
"""
import csv, re, subprocess, sys
from openpyxl import load_workbook
from openpyxl.styles import PatternFill, Border, Side
from openpyxl.utils import get_column_letter
from gen_oob import oob_rows

WB = "ai-fabric-cabling.xlsx"
BANDS = {"400G": "FFF2CC", "800G": "FCE4D6", "100G": "E2EFDA", "1G": "DEEBF7"}    # as make_xlsx.py; 1G = the OOB sheet's band
OOB_BAND = "DEEBF7"                                               # as add_oob_sheet.py
thin = Side(style="thin", color="BFBFBF")

def gen(cmd):
    out = subprocess.run([sys.executable, "gen_cabling.py", cmd], capture_output=True, text=True, check=True).stdout
    return [r for r in csv.reader(out.splitlines())][1:]

def refill(ws, rows, band_of):
    hdr = [c.value for c in ws[3]]; ncol = len([h for h in hdr if h])
    if ws.max_row > 3: ws.delete_rows(4, ws.max_row - 3)
    for r in rows: ws.append(list(r))
    for i in range(4, 4 + len(rows)):
        fill = band_of(ws.cell(row=i, column=hdr.index("speed") + 1).value)
        for c in range(1, ncol + 1):
            cell = ws.cell(row=i, column=c); cell.border = Border(bottom=thin)
            cell.fill = PatternFill("solid", fgColor=fill) if fill else PatternFill(fill_type=None)
    ws.auto_filter.ref = f"A3:{get_column_letter(ncol)}{3 + len(rows)}"

wb = load_workbook(WB)
be, fe, oob = gen("backend"), gen("frontend"), oob_rows()
refill(wb["Backend"], be, BANDS.get)
refill(wb["Frontend"], fe, BANDS.get)
refill(wb["OOB"], oob, lambda s: OOB_BAND)

fw = wb["Frontend"]
FBM = (" FlashBlade management: 1 port per appliance to its own control leaf (Ethernet1/12, PROPOSED), <stor-mgmt VLAN>, "
       "1G via a QSA adapter + 1000BASE-T SFP in the 100G leaf port.")
fw["A1"] = (fw["A1"].value or "").split(" FlashBlade management:")[0].rstrip() + FBM
wb["OOB"]["A1"] = ("OOB / BMC: one BMC port per server, one management port per backend switch. <OOB subnet>/24, gateway on the firewall. "
                   "oob-sw model and port count still to be selected; ports are sequential. FlashBlade management moved to the "
                   "control leaves on 2026-09-24 (Frontend sheet).")

s = wb["Summary"]
row = {s.cell(row=r, column=1).value: r for r in range(1, s.max_row + 1)}
n_fbm = sum(1 for r in fe if r[0].startswith("flashblade") and r[1] == "mgmt")
s.cell(row=row["Backend"], column=2, value=len(be))
s.cell(row=row["Frontend"], column=2, value=len(fe))
# strip only OUR suffix(es) " + N x <speed> FlashBlade mgmt (...)"; a term may not span " + ", so the operator's wording before it stays
d = re.sub(r"(?: \+ \d+ x (?:(?! \+ ).)+? FlashBlade mgmt(?: \([^)]*\))?)+$", "", s.cell(row=row["Frontend"], column=3).value or "")
s.cell(row=row["Frontend"], column=3, value=d.rstrip() + f" + {n_fbm} x 1G FlashBlade mgmt (QSA + 1000BASE-T)")
s.cell(row=row["OOB / BMC"], column=2, value=len(oob))
d = s.cell(row=row["OOB / BMC"], column=3).value or ""
s.cell(row=row["OOB / BMC"], column=3, value=d.replace(" + 2 FlashBlade mgmt", ""))
s.cell(row=row["TOTAL"], column=2, value=len(be) + len(fe) + len(oob))
# the firewall is someone else's (operator, 2026-09-24): no firewall interface names in the workbook, only "the firewall"
for r in s.iter_rows():
    for c in r:
        if isinstance(c.value, str) and "fw e3" in c.value: c.value = c.value.replace("fw e3", "the firewall")
wb.save(WB)
print(f"{WB}: Backend {len(be)}, Frontend {len(fe)} ({n_fbm} FlashBlade mgmt), OOB {len(oob)}, TOTAL {len(be) + len(fe) + len(oob)}")
