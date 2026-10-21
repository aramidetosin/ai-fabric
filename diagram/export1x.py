#!/usr/bin/env python3
"""Render a .excalidraw file to a high-resolution PNG using the real
Excalidraw export code in headless Chrome (authentic hand-drawn rendering).

Usage: excalidraw_export.py input.excalidraw output.png

Requires network (loads @excalidraw/excalidraw from esm.sh) and Google Chrome.
Uses 0.17.6 because 0.18.0's exportToSvg hangs on font loading headlessly.
Respects the scene's appState.viewBackgroundColor (banners use #f4f5f8).
"""
import json, re, subprocess, sys, tempfile, os

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

HTML = """<!doctype html>
<html><head><meta charset="utf-8">
<style>html,body { margin:0; padding:0; background:#ffffff; overflow:hidden; } svg { display:block; }</style>
</head><body>
<script type="module">
const scene = __SCENE__;
try {
  window.EXCALIDRAW_ASSET_PATH = "https://unpkg.com/@excalidraw/excalidraw@0.17.6/dist/";
  let mod = await import("https://esm.sh/@excalidraw/excalidraw@0.17.6?deps=react@18.2.0,react-dom@18.2.0");
  if (!mod.exportToSvg && mod.default) mod = mod.default;
  const svg = await mod.exportToSvg({
    elements: scene.elements,
    appState: { exportBackground: true,
                viewBackgroundColor: (scene.appState && scene.appState.viewBackgroundColor) || "#ffffff",
                exportPadding: 24 },
    files: {},
  });
  document.body.appendChild(svg);
  await document.fonts.ready;
  await new Promise(r => setTimeout(r, 1500));
  const w = Math.ceil(parseFloat(svg.getAttribute("width")));
  const h = Math.ceil(parseFloat(svg.getAttribute("height")));
  const m = document.createElement("meta");
  m.name = "export-size"; m.content = w + "x" + h;
  document.head.appendChild(m);
} catch (e) {
  const pre = document.createElement("pre");
  pre.textContent = "EXPORT ERROR: " + (e.stack || e.message || String(e));
  document.body.appendChild(pre);
}
</script></body></html>
"""


def main():
    src, out = sys.argv[1], sys.argv[2]
    scene = json.load(open(src))
    page = os.path.join(tempfile.mkdtemp(), "export.html")
    open(page, "w").write(HTML.replace("__SCENE__", json.dumps(scene)))

    # pass 1: measure (retry once; esm.sh can be slow on cold cache)
    size = None
    for _ in range(2):
        dom = subprocess.run(
            [CHROME, "--headless=new", "--disable-gpu", "--virtual-time-budget=60000",
             "--dump-dom", f"file://{page}"],
            capture_output=True, text=True).stdout
        m = re.search(r'name="export-size" content="(\d+)x(\d+)"', dom)
        if m:
            size = (int(m.group(1)), int(m.group(2)))
            break
        err = re.search(r"EXPORT ERROR[^<]{0,300}", dom.split("</script>")[-1])
        if err:
            sys.exit(err.group(0))
    if not size:
        # fallback: read size off the svg tag
        m = re.search(r'<svg[^>]*width="([\d.]+)"[^>]*height="([\d.]+)"', dom)
        if not m:
            sys.exit("export produced no svg; check network access to esm.sh")
        size = (int(float(m.group(1))) + 1, int(float(m.group(2))) + 1)

    # pass 2: screenshot at 2x. NOTE: under --force-device-scale-factor=1,
    # --window-size is in PHYSICAL pixels, so pass 2*w,2*h to get a css
    # viewport of w,h. Output PNG lands at 4x logical resolution.
    w, h = size
    subprocess.run(
        [CHROME, "--headless=new", "--disable-gpu", "--force-device-scale-factor=1",
         "--virtual-time-budget=60000", f"--window-size={w},{h}",
         f"--screenshot={out}", f"file://{page}"],
        capture_output=True)
    print(f"{out}: rendered {w}x{h} scene at 1x scale")


if __name__ == "__main__":
    main()
