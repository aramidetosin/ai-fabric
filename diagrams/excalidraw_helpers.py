#!/usr/bin/env python3
"""Element builders for authoring .excalidraw files programmatically.

Import these in a per-post generator script, build an element list, then
call doc(elements) and json.dump it to a .excalidraw file. Render with
excalidraw_export.py. Excalidraw re-measures text on load, so width
estimates only need to be rough. Keep colors to the house palette:
blue #1971c2, green #2f9e44, orange #e8590c, red #c92a2a, purple #9c36b5,
gray #868e96, ink #1e1e1e. NO em dashes in any label.
"""
import itertools

_ids = itertools.count(1)
_seed = itertools.count(1000, 7)


def _nid():
    return f"el-{next(_ids):04d}"


def base(t, x, y, w, h, **kw):
    el = {
        "id": _nid(), "type": t, "x": x, "y": y, "width": w, "height": h,
        "angle": 0, "strokeColor": "#1e1e1e", "backgroundColor": "transparent",
        "fillStyle": "solid", "strokeWidth": 2, "strokeStyle": "solid",
        "roughness": 1, "opacity": 100, "groupIds": [], "frameId": None,
        "roundness": {"type": 3} if t == "rectangle" else None,
        "seed": next(_seed), "version": 1, "versionNonce": next(_seed),
        "isDeleted": False, "boundElements": None, "updated": 1751900000000,
        "link": None, "locked": False,
    }
    el.update(kw)
    return el


def rect(x, y, w, h, stroke="#1e1e1e", bg="transparent", dash=False, width=2, round=True):
    el = base("rectangle", x, y, w, h, strokeColor=stroke, backgroundColor=bg,
              strokeStyle="dashed" if dash else "solid", strokeWidth=width)
    if not round:
        el["roundness"] = None
    return el


def ellipse(x, y, w, h, stroke="transparent", bg="#e7e8ea"):
    el = base("ellipse", x, y, w, h, strokeColor=stroke, backgroundColor=bg)
    el["roundness"] = None
    return el


def text(x, y, s, size=16, color="#1e1e1e", align="left"):
    lines = s.split("\n")
    est_w = max(len(l) for l in lines) * size * 0.55
    est_h = len(lines) * size * 1.25
    el = base("text", x, y, est_w, est_h, strokeColor=color)
    el["roundness"] = None
    el.update({"text": s, "fontSize": size, "fontFamily": 1, "textAlign": align,
               "verticalAlign": "top", "containerId": None, "originalText": s,
               "autoResize": True, "lineHeight": 1.25})
    return el


def ctext(cx, y, s, size=16, color="#1e1e1e"):
    """Text horizontally centered on cx."""
    lines = s.split("\n")
    est_w = max(len(l) for l in lines) * size * 0.55
    return text(cx - est_w / 2, y, s, size=size, color=color, align="center")


def arrow(x1, y1, x2, y2, color="#1e1e1e", dash=False, width=2, both=False):
    el = base("arrow", x1, y1, x2 - x1, y2 - y1, strokeColor=color,
              strokeStyle="dashed" if dash else "solid", strokeWidth=width)
    el["roundness"] = {"type": 2}
    el.update({"points": [[0, 0], [x2 - x1, y2 - y1]], "lastCommittedPoint": None,
               "startBinding": None, "endBinding": None,
               "startArrowhead": "arrow" if both else None, "endArrowhead": "arrow",
               "elbowed": False})
    return el


def line(x1, y1, x2, y2, color="#9aa3b2", width=3):
    el = base("line", x1, y1, x2 - x1, y2 - y1, strokeColor=color, strokeWidth=width)
    el["roundness"] = {"type": 2}
    el.update({"points": [[0, 0], [x2 - x1, y2 - y1]], "lastCommittedPoint": None,
               "startBinding": None, "endBinding": None,
               "startArrowhead": None, "endArrowhead": None})
    return el


def doc(elements, bg="#ffffff"):
    return {
        "type": "excalidraw", "version": 2, "source": "https://excalidraw.com",
        "elements": elements,
        "appState": {"gridSize": 20, "gridStep": 5, "gridModeEnabled": False,
                     "viewBackgroundColor": bg},
        "files": {},
    }
