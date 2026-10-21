#!/usr/bin/env python3
"""Export the physical overview using Excalidraw's own renderer and Virgil font.

Reads the existing geometry; writes a separate editable scene, SVG and PNG.
Requires Chrome and network access for the pinned Excalidraw renderer/font.
The diagram stays in a local page and is never uploaded to an editor service.
"""
from pathlib import Path
import html
import json
import re
import subprocess
import tempfile
import base64
import time
import os
import signal
import generate

OUT = Path(__file__).resolve().parent
CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
NAME = 'network-topology-handdrawn'
scratch = Path(tempfile.mkdtemp(prefix='excalidraw-'))
generate.OUT = scratch
generate.excalidraw([generate.overview()])
scene = json.loads((scratch/'network-topology.excalidraw').read_text())

palette = {'#172B4D':'#1e1e1e', '#53657E':'#495057', '#4167B2':'#1971c2',
           '#BA702A':'#e8590c', '#778395':'#868e96'}
for e in scene['elements']:
    e['strokeColor'] = palette.get(e['strokeColor'],e['strokeColor'])
    if e['type']=='text':
        e['fontFamily']=1
        e['roughness']=0
    elif e['type']=='line':
        e['roughness']=1.15
    else:
        mask=e['strokeWidth']==0 or e['strokeColor']==e['backgroundColor']
        e['roughness']=0 if mask else 1.5
        if not mask:
            e['roundness']=None
            e['strokeWidth']=max(e['strokeWidth'],1.6)
scene['source']='https://excalidraw.com'

font=subprocess.run(['curl','--fail','--silent','--show-error','--location','--max-time','40',
                     'https://excalidraw.com/Virgil.woff2'],capture_output=True,check=True).stdout
if not font.startswith(b'wOF2'):
    raise RuntimeError('Virgil response is not a WOFF2 font')
font_uri='data:font/woff2;base64,'+base64.b64encode(font).decode()

page='''<!doctype html><html><head><meta charset="utf-8"><style>
html,body{margin:0;padding:0;background:white}svg{display:block}
@font-face{font-family:Virgil;src:url("__FONT__") format("woff2");}
</style></head><body><script type="module">
const scene=__SCENE__;
try {
 const face=new FontFace('Virgil','url("__FONT__")');
 await face.load(); document.fonts.add(face);
 await document.fonts.load('20px Virgil');
 if (!document.fonts.check('20px Virgil')) throw new Error('Virgil not loaded');
 const ctx=document.createElement('canvas').getContext('2d');
 for(const e of scene.elements.filter(e=>e.type==='text')){
   const available=e.width, center=e.x+available/2;
   ctx.font=e.fontSize+'px Virgil';
   const lines=e.text.split('\\n');
   let measured=Math.max(...lines.map(t=>ctx.measureText(t).width));
   if(measured>available){ e.fontSize*=available/measured*.98; ctx.font=e.fontSize+'px Virgil'; }
   e.width=Math.max(...lines.map(t=>ctx.measureText(t).width));
   e.height=lines.length*e.fontSize*e.lineHeight;
   if(e.textAlign==='center')e.x=center-e.width/2;
 }
 window.EXCALIDRAW_ASSET_PATH='https://unpkg.com/@excalidraw/excalidraw@0.17.6/dist/';
 let mod=await import('https://esm.sh/@excalidraw/excalidraw@0.17.6?deps=react@18.2.0,react-dom@18.2.0');
 if(!mod.exportToSvg&&mod.default)mod=mod.default;
 const svg=await mod.exportToSvg({elements:scene.elements,
   appState:{exportBackground:true,viewBackgroundColor:'#ffffff',exportPadding:24},files:{}});
 // Embed the loaded font so the delivered SVG opens without external font requests.
 const fontStyle=document.createElementNS('http://www.w3.org/2000/svg','style');
 fontStyle.textContent='@font-face{font-family:Virgil;src:url("__FONT__") format("woff2");}';
 svg.insertBefore(fontStyle,svg.firstChild);
 svg.querySelectorAll('style').forEach(s=>{s.textContent=s.textContent.replace(/url\\(["']https[^)]*Virgil[^)]*\\)/g,'url("__FONT__")')});
 document.body.append(svg);
 await document.fonts.ready;
 const data=document.createElement('script');data.id='fitted-scene';data.type='application/json';
 data.textContent=JSON.stringify(scene);document.body.append(data);
 document.documentElement.setAttribute('data-export-ready','true');
}catch(e){document.body.append('EXPORT ERROR: '+(e.stack||e));}
</script></body></html>'''.replace('__FONT__',font_uri).replace('__SCENE__',json.dumps(scene))
(scratch/'render.html').write_text(page)
flags=[CHROME,'--headless=new','--disable-gpu','--hide-scrollbars',
       '--disable-background-networking','--password-store=basic',
       '--no-first-run','--no-default-browser-check',f'--user-data-dir={scratch/"chrome-profile"}']
def run_browser(args, tag, image_path=None):
    """macOS Chrome may remain alive after writing its requested output."""
    output=scratch/f'{tag}.dom'
    with output.open('w') as stdout,(scratch/f'{tag}.log').open('w') as stderr:
        proc=subprocess.Popen(args,stdout=stdout,stderr=stderr,start_new_session=True)
        try:
            for _ in range(280):
                if image_path is not None:
                    ready=image_path.exists() and image_path.stat().st_size>1000
                else:
                    ready='</html>' in output.read_text()
                if ready or proc.poll() is not None:break
                time.sleep(.2)
            else:raise RuntimeError(f'Browser output timed out; see {scratch}/{tag}.log')
        finally:
            try:os.killpg(proc.pid,signal.SIGTERM)
            except ProcessLookupError:pass
    return output.read_text()
cmd=flags+['--virtual-time-budget=20000','--dump-dom',(scratch/'render.html').as_uri()]
dom=run_browser(cmd,'render')
if 'data-export-ready="true"' not in dom:
    err=re.findall(r'EXPORT ERROR:[^<]{0,500}',dom)
    raise RuntimeError(f'Excalidraw export incomplete: {err[-1:]}; diagnostics in {scratch}')
svg=re.search(r'(<svg\b(?=[^>]*xmlns="http://www.w3.org/2000/svg")[\s\S]*?</svg>)',dom)
fitted=re.search(r'<script id="fitted-scene" type="application/json">([\s\S]*?)</script>',dom)
if not svg or not fitted:raise RuntimeError('Expected exported SVG and fitted scene')
svg=svg.group(1)
fitted=json.loads(fitted.group(1))
(OUT/f'{NAME}.svg').write_text(svg)
(OUT/f'{NAME}.excalidraw').write_text(json.dumps(fitted,ensure_ascii=False,indent=2))
width=int(float(re.search(r'<svg[^>]*\bwidth="([\d.]+)',svg).group(1)))
height=int(float(re.search(r'<svg[^>]*\bheight="([\d.]+)',svg).group(1)))
(scratch/'preview.html').write_text('<!doctype html><html><head><meta charset="utf-8"><style>html,body{margin:0;padding:0;background:white;overflow:hidden}svg{display:block}</style></head><body>'+svg+'</body></html>')
preview_flags=[v if not v.startswith('--user-data-dir=') else f'--user-data-dir={scratch/"preview-profile"}' for v in flags]
(OUT/f'{NAME}.png').unlink(missing_ok=True)
cmd=preview_flags+[f'--window-size={width},{height}','--force-device-scale-factor=1',
           '--virtual-time-budget=3000',f'--screenshot={OUT/NAME}.png',(scratch/'preview.html').as_uri()]
run_browser(cmd,'preview',OUT/f'{NAME}.png')
if not (OUT/f'{NAME}.png').is_file():raise RuntimeError('PNG export failed')
print(f'Created {NAME}.excalidraw, .svg and .png with native Excalidraw strokes and embedded Virgil.')
print(f'{len(fitted["elements"])} editable objects; canvas {width} x {height}; diagnostics {scratch}')
