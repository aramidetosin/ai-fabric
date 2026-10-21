#!/usr/bin/env python3
"""Render the supplied production physical design. No lab or network commands are run.

Writes SVG, editable draw.io and Excalidraw files using only the Python stdlib.
PNG rendering is a separate rsvg-convert command. Sources are the adjacent
physical-design generator, cabling CSVs, and LAB_ANALYSIS.md.
"""
from pathlib import Path
import csv
import html
import json
import math
import xml.etree.ElementTree as ET

OUT = Path(__file__).resolve().parent
BASE = OUT.parent.parent
W, H = 2400, 1780
INK = '#172B4D'
MUTED = '#53657E'
FE = '#4167B2'
BE = '#BA702A'
OOB = '#778395'
RAILS = ['#236FAD', '#258068', '#B96D22', '#765BA7', '#AE5360', '#287F8A', '#8B781D', '#9A567F']


class Canvas:
    def __init__(self, name, slug):
        self.name, self.slug, self.items, self.index = name, slug, [], {}

    def box(self, x, y, w, h, fill='#FFFFFF', stroke='#CCD6E2', radius=12, width=1.5):
        self.items.append(dict(kind='rect', x=x, y=y, w=w, h=h, fill=fill, stroke=stroke, radius=radius, width=width))

    def text(self, x, y, value, size=24, color=INK, bold=False, align='left', width=None):
        lines = value.split('\n')
        width = width or max(len(s) for s in lines) * size * .59 + 8
        self.items.append(dict(kind='text', x=x, y=y, w=width, h=len(lines)*size*1.28+4,
                               value=value, size=size, color=color, bold=bold, align=align))

    def node(self, id, x, y, w, h, title, body, color=FE, fill='#FFFFFF', size=21):
        d = dict(kind='node', id=id, x=x, y=y, w=w, h=h, title=title, body=body,
                 color=color, fill=fill, size=size)
        self.items.append(d)
        self.index[id] = d
        return id

    def edge(self, points, color='#B2C1D9', width=2, dashed=False, source=None, target=None):
        self.items.append(dict(kind='edge', points=points, color=color, width=width,
                               dashed=dashed, source=source, target=target))

    def header(self, title, subtitle, number):
        self.text(55, 32, title, 43, bold=True)
        self.text(57, 92, subtitle, 23, MUTED)
        self.text(2100, 43, f'PHYSICAL DESIGN  /  {number}', 18, MUTED, width=245)
        self.text(2100, 74, '24 SEPTEMBER 2026', 17, MUTED, width=245)

    def footer(self, text):
        self.edge([(55, 1710), (2345, 1710)], '#CCD6E2', 1)
        self.text(55, 1728, text, 19, MUTED, width=2280)


def overview():
    c = Canvas('Physical topology', 'physical-topology')
    c.header('production AI network topology', '32 B300 servers / 256 GPUs · Frontend EVPN-VXLAN · Eight backend rails · Plane 1', '01')
    c.box(40, 145, 1910, 715, '#F3F6FC', '#DCE4F0')
    c.box(1980, 145, 380, 715, '#F5F7F9', '#DCE2E9')
    c.text(65, 164, 'FRONTEND  /  Cisco Nexus', 23, FE, True)
    c.text(2000, 164, 'OOB / MANAGEMENT', 22, OOB, True)

    leafs = [('fe-border1',65,175),('fe-border2',265,175),
             ('fe-ctrl-leaf1',500,195),('fe-ctrl-leaf2',725,195),
             ('fe-gpu-leaf1',1020,195),('fe-gpu-leaf2',1245,195),
             ('fe-gpu-leaf3',1540,195),('fe-gpu-leaf4',1765,175)]
    # Bundled connections, two physical 400G links per drawn leaf/spine line.
    for i,(name,x,w) in enumerate(leafs):
        for s,sx in [(1,820),(2,1290)]:
            c.edge([(x+w/2+(-13 if s==1 else 13),450), (sx+100+i*26,315)],
                   '#A5B9DD', 2.2, source=name,target=f'fe-spine{s}')
    c.text(70, 226, '2 × 400G from every leaf to EACH spine', 25, FE, width=720)
    c.text(70, 267, '32 fabric links · OSPF unnumbered · iBGP EVPN, spines RR', 21, MUTED, width=720)
    c.text(70, 301, '<data VLAN> · VRF k8s  |  <stor-mgmt VLAN> · VRF stor-mgmt\n<bastion VLAN> · VRF bastion  |  VNIs: placeholders', 21, MUTED, width=720)

    for s,x in [(1,820),(2,1290)]:
        c.node(f'fe-spine{s}',x,215,400,100,f'fe-spine{s}','Cisco N9364D-GX2A · iBGP RR\nPhysical IP / ASN: TBD',FE,'#E4ECFB')
    for name,x,w in leafs:
        c.node(name,x,450,w,100,name,'N9332D-GX2B\nIP / ASN: TBD',FE,size=18)

    # Access pair links are independent bond legs, not inter-leaf peer-links.
    for lx,ln,hid,hx,hw,count in [(500,'fe-ctrl-leaf1','ctrl-hosts',500,420,11),
                                 (725,'fe-ctrl-leaf2','ctrl-hosts',500,420,11),
                                 (1020,'fe-gpu-leaf1','gpu-a',1020,420,16),
                                 (1245,'fe-gpu-leaf2','gpu-a',1020,420,16),
                                 (1540,'fe-gpu-leaf3','gpu-b',1540,400,16),
                                 (1765,'fe-gpu-leaf4','gpu-b',1540,400,16)]:
        left = ln.endswith(('1','3'))
        c.edge([(lx+(175 if lx==1765 else 195)/2,550),(hx+hw*(.25 if left else .75),680)],
               FE if left else '#469485',3,source=ln,target=hid)
    for x,w in [(493,435),(1013,435),(1533,412)]:
        c.box(x,560,w,81,'#F3F6FC','#F3F6FC',radius=0,width=0)
    c.text(526, 568, '11 × 100G + 1 × 1G mgmt per leaf',20,FE)
    c.text(1045,568,'16 × 100G per leaf',20,FE)
    c.text(1556,568,'16 × 100G per leaf',20,FE)
    c.text(521,610,'vPC Fabric Peering · no peer-link cable',18,MUTED)
    c.text(1035,610,'vPC Fabric Peering · no peer-link cable',18,MUTED)
    c.text(1542,610,'vPC Fabric Peering · no peer-link cable',18,MUTED)

    c.node('ctrl-hosts',500,680,420,150,'Control, bastion and storage',
           'ctrl1–6 + bastion: 2 × 100G each\nFlashBlade ×2: 4 × 100G data each\n+ 1 × 1G mgmt each (QSA) → own leaf\nOne 8 × 100G bond (vPC), <data VLAN>',FE,'#FFFFFF',19)
    c.node('gpu-a',1020,680,420,130,'gpu1–gpu16  /  16 B300 servers',
           '128 GPUs · 2 × 100G per server\n8 × 400G rail NICs per server\n1 × 1G BMC per server',FE,'#EDFAF5',21)
    c.node('gpu-b',1540,680,400,130,'gpu17–gpu32  /  16 B300 servers',
           '128 GPUs · 2 × 100G per server\n8 × 400G rail NICs per server\n1 × 1G BMC per server',FE,'#EDFAF5',20)
    c.edge([(152,550),(152,680)],'#BC6666',3,source='fe-border1',target='fw')
    c.edge([(352,550),(352,680)],'#BC6666',3,source='fe-border2',target='fw')
    c.box(72,568,355,67,'#F3F6FC','#F3F6FC',radius=0,width=0)
    c.text(78,575,'Border ↔ firewall handoff',20,'#A44F4F',width=350)
    c.node('fw',65,680,375,150,'Firewall',
           'Sub-interface per VRF; zones\ndata · stor-mgmt · bastion\neBGP default per VRF → type-5\nOOB gateway (zone oob)', '#B76565','#FFF2F1',21)
    c.text(84,838,'Borders are L3-only; not a vPC pair.',17,MUTED)

    c.node('oob',2000,215,340,100,'Logical OOB switch',
           'Model / switch count: TBD\nOOB subnet: TBD',OOB,'#FFFFFF',21)
    c.edge([(2170,315),(2170,362)],OOB,2,True,source='oob',target='oob-endpoints')
    c.node('oob-endpoints',2000,362,340,204,'51 recorded 1G links',
           '12 backend switch management\n32 GPU server BMC\n6 control + 1 bastion BMC\n(FlashBlade management moved\nto the control leaves)',OOB,'#FFFFFF',20)
    c.box(2000,590,340,250,'#FFF8E9','#DEC59B')
    c.text(2018,610,'Capacity and policy',23,'#91652A',True)
    c.text(2018,652,'Add 10 frontend mgmt0 ports\n(vPC peer-keepalive) + 1 fw\nuplink: 62 ports before spares.\n\ndata → stor-mgmt: TCP 443\nvia the firewall. No fabric\nzone reaches OOB.',19,MUTED,width=310)
    # Routed/OOB handoff is represented by an annotated stub, not a data-fabric link.
    c.edge([(440,770),(467,770),(467,883),(1964,883),(1964,266),(2000,266)],OOB,2,True,source='fw',target='oob')
    c.text(650,894,'OOB gateway on the firewall',18,OOB,width=1000)

    c.box(40,921,2320,669,'#FBF7F0','#EBDDCA')
    c.text(65,943,'BACKEND  /  UfiSpace S9321-64E + OcNOS',23,BE,True)
    c.text(65,986,'Each coloured line below represents 32 dedicated 400G links to one rail leaf.',20,MUTED,width=920)
    c.edge([(1230,810),(1230,933)],'#258068',3,source='gpu-a',target='rail-bundle')
    c.edge([(1740,810),(1740,933)],'#258068',3,source='gpu-b',target='rail-bundle')
    c.node('rail-bundle',1030,933,890,78,'Every B300 server connects to all eight rails',
           '256 × 400G independent links · NIC R → be-leafR · CX8 port 2 uncabled','#258068','#EFF8F3',20)
    # Rail fanout. Bundle annotation prevents the drawing from implying a shared Ethernet bus.
    for r in range(1,9):
        x=65+(r-1)*286;cx=x+127
        c.edge([(1060+(r-1)*117,1011),(cx,1100)],RAILS[r-1],3,source='rail-bundle',target=f'be-leaf{r}')
    for r in range(1,9):
        lx=65+(r-1)*286;cx=lx+127
        for s,sx in [(1,280),(2,810),(3,1340),(4,1870)]:
            c.edge([(cx+(s-2.5)*19,1230),(sx+20+r*30,1415)],'#C4B7A6',2.1,source=f'be-leaf{r}',target=f'be-spine{s}')
    c.box(685,1283,1340,103,'#FBF7F0','#EBDDCA',radius=9,width=1)
    c.text(705,1300,'Each grey line = 4 × 800G routed links  /  128 physical links total',24,BE,width=1230)
    c.text(714,1345,'eBGP + BFD · 16 uplinks per leaf · BGP unnumbered · PFC + ECN (production switch config)',22,MUTED,width=1220)
    for r in range(1,9):
        x=65+(r-1)*286
        c.node(f'be-leaf{r}',x,1100,254,130,f'be-leaf{r}  /  rail {r}',
               f'AS {65200+r} · VLAN {r*10}\n172.16.{r}.0/24 · gateway .1\n32 × 400G server links',RAILS[r-1],size=19)
    for s,x in [(1,280),(2,810),(3,1340),(4,1870)]:
        c.node(f'be-spine{s}',x,1415,360,115,f'be-spine{s}',
               f'AS 65200 · 192.168.100.{s}\n32 × 800G ports toward 8 leaves',BE,'#FFFFFF',21)
    c.text(65,1550,'Per rail leaf: 12.8 Tb/s down + 12.8 Tb/s up in nominal port capacity. Same rail stays L2; cross-rail uses leaf → spine → leaf.',22,MUTED,width=2240)

    c.box(40,1610,2320,78,'#FFF8E9','#DEC59B')
    c.text(60,1625,'TO FINALIZE',19,'#91652A',True)
    c.text(228,1625,'FE/OOB addresses, VLANs, VNIs and ASNs · FE uplink ports',21,INK,width=2090)
    c.text(228,1657,'Links are bundled for readability. Rates are design values. Backend PFC (priority 3) + ECN as in the production switch configuration (AI-Leaf / AI-Spine ECN_PFC_Lossless).',18,MUTED,width=2070)
    c.footer('Source: existing production physical design and cabling matrices. This diagram intentionally does not substitute the virtual lab’s IPs or switch models.')
    return c


def load_csv(name):
    with (BASE/'cabling'/name).open(newline='') as f:
        return list(csv.DictReader(f))


def table(c,x,y,width,headers,rows,colw,rowh=39):
    c.box(x,y,width,rowh*(len(rows)+1),'#FFFFFF','#CAD5E3',radius=0)
    c.box(x,y,width,rowh,'#E7EDF6','#CAD5E3',radius=0)
    for j,header in enumerate(headers):
        c.text(x+sum(colw[:j])+12,y+10,header,19,INK,True,width=colw[j]-16)
    for i,row in enumerate(rows):
        yy=y+(i+1)*rowh
        if i%2==1:c.box(x,yy,width,rowh,'#F7F9FC','#F7F9FC',radius=0,width=0)
        for j,cell in enumerate(row):c.text(x+sum(colw[:j])+12,yy+10,str(cell),19,MUTED,width=colw[j]-16)


def detail():
    be,fe,oob=load_csv('backend-cabling.csv'),load_csv('frontend-cabling.csv'),load_csv('oob-cabling.csv')
    assert (len(be),len(fe),len(oob))==(384,88,51)
    for rows in [be,fe,oob]:
        endpoints=[(r[k+'_device'],r[k+'_port']) for r in rows for k in ['a','b']]
        assert len(endpoints)==len(set(endpoints)), 'Duplicate cable endpoint'
    c=Canvas('Server and port map','physical-port-map')
    c.header('production server and port map','Physical cabling extracted from the CSV matrices · UfiSpace ports are zero-based; Cisco ports are one-based', '02')
    c.box(40,145,2320,92,'#F3F6FC','#DCE4F0')
    c.text(60,163,'Per B300 server',25,FE,True)
    c.text(320,163,'2 × 100G frontend + 8 × 400G backend + 1 × 1G BMC = 11 physical links',26,INK,width=1950)
    c.text(320,205,'The backend port shown is used on every rail leaf; NIC R attaches to leaf R. Rail host address = 172.16.R.(10 + node number).',20,MUTED,width=1960)
    rows=[]
    for n in range(1,33):
        name=f'gpu{n}'
        b=[r for r in be if r['a_device']==name]
        f=[r for r in fe if r['a_device']==name]
        o=[r for r in oob if r['a_device']==name]
        assert len(b)==8 and len(f)==2 and len(o)==1
        assert len({r['b_port'] for r in b})==1
        pair='leaf1 + leaf2' if n<=16 else 'leaf3 + leaf4'
        rows.append([name,pair,f[0]['b_port'].replace('Ethernet','Eth'),b[0]['b_port'].replace('ethernet','eth'),o[0]['b_port'].replace('port ','')])
    c.text(55,264,'GPU group A  /  fe-gpu-leaf1 + fe-gpu-leaf2',26,FE,True)
    c.text(1240,264,'GPU group B  /  fe-gpu-leaf3 + fe-gpu-leaf4',26,FE,True)
    headers=['Server','Frontend pair','Port / FE leaf','Port / BE leaf','OOB port']
    widths=[135,290,230,260,200]
    table(c,55,310,1115,headers,rows[:16],widths,39)
    table(c,1230,310,1115,headers,rows[16:],widths,39)
    c.text(55,994,'Backend rail address plan',27,BE,True)
    railrows=[[str(r),f'be-leaf{r}',str(r*10),f'172.16.{r}.0/24',f'172.16.{r}.1',f'6520{r}'] for r in range(1,9)]
    table(c,55,1038,1115,['Rail','Leaf','VLAN','Subnet','Gateway','ASN'],railrows,[100,180,130,300,260,145],41)
    c.text(1240,994,'Control, storage and uplink ports',27,FE,True)
    c.box(1230,1038,1115,368,'#F7F9FC','#CAD5E3',radius=0)
    c.text(1254,1060,'On BOTH control leaves (native 100G)',23,INK,True)
    c.text(1254,1100,'Eth1/1–6 → ctrl1–6     Eth1/7 → bastion\nEth1/8–9 → flashblade-1     Eth1/10–11 → flashblade-2\nEth1/12 (proposed) → flashblade-1 mgmt on leaf1, -2 on leaf2; 1G via QSA',22,MUTED,width=1050)
    c.text(1254,1200,'On EACH backend rail leaf (800G physical ports)',23,INK,True)
    c.text(1254,1237,'eth0–15 → 2 × 400G breakout; 32 servers\neth16–47 → spare\neth48–51 → spine1     eth52–55 → spine2\neth56–59 → spine3     eth60–63 → spine4',22,MUTED,width=1050)
    c.text(1254,1372,'Spine S ports 4 × (leaf number − 1) + [0..3] face that leaf.',20,MUTED,width=1035)
    c.box(55,1434,1115,240,'#F5F7F9','#CAD5E3')
    c.text(77,1453,'OOB port allocation  /  51 recorded links',25,OOB,True)
    c.text(77,1499,'1–8 backend leaves     9–12 backend spines\n13–44 gpu1–gpu32     45–50 ctrl1–ctrl6\n51 bastion     52–53 free (FlashBlade mgmt moved to the control leaves)',23,MUTED,width=1060)
    c.text(77,1611,'10 frontend management ports (mgmt0, vPC peer-keepalive) + firewall uplink are additional.\nSelect OOB hardware for at least 62 logical ports, plus required spares.',20,INK,width=1060)
    c.box(1230,1434,1115,240,'#FFF8E9','#DEC59B')
    c.text(1254,1453,'Design items that remain open',25,'#91652A',True)
    c.text(1254,1497,'Frontend uplinks require FOUR ports per leaf; exact ports unresolved.\nFrontend/OOB IPs, VLANs, VNIs and ASNs to finalize.\nSettled 24 Sep: backend uplinks BGP unnumbered; FlashBlade bond\nas drawn; FlashBlade mgmt 1G via QSA + 1000BASE-T; backend\nPFC + ECN as in the production switch configuration.',21,MUTED,width=1060)
    c.footer('523 links are listed in the source matrices: 384 backend + 88 frontend access + 51 OOB. Frontend fabric, firewall and additional management cabling are excluded.')
    return c


def svg(c):
    out=[f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" role="img">',
         f'<title>{html.escape(c.name)}</title>',
         '<desc>production physical design, 24 September 2026. Unresolved design decisions are explicitly labelled.</desc>',
         '<rect width="100%" height="100%" fill="#FFFFFF"/>']
    def rect(x,y,w,h,fill,stroke,r=12,sw=1.5):
        out.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{fill}" stroke="{stroke}" stroke-width="{sw}"/>')
    def text(x,y,value,size,color,bold=False,align='left',width=0):
        anchor='middle' if align=='center' else 'start'
        xx=x+width/2 if align=='center' else x
        for i,line in enumerate(value.split('\n')):
            out.append(f'<text x="{xx}" y="{y+size*.9+i*size*1.28}" text-anchor="{anchor}" font-family="Arial, Helvetica, sans-serif" font-size="{size}" font-weight="{700 if bold else 400}" fill="{color}">{html.escape(line)}</text>')
    for e in c.items:
        k=e['kind']
        if k=='rect':rect(e['x'],e['y'],e['w'],e['h'],e['fill'],e['stroke'],e['radius'],e['width'])
        elif k=='text':text(e['x'],e['y'],e['value'],e['size'],e['color'],e['bold'],e['align'],e['w'])
        elif k=='edge':
            pts=' '.join(f'{x},{y}' for x,y in e['points'])
            dash=' stroke-dasharray="8 7"' if e['dashed'] else ''
            out.append(f'<polyline points="{pts}" fill="none" stroke="{e["color"]}" stroke-width="{e["width"]}" stroke-linejoin="round"{dash}/>')
        elif k=='node':
            rect(e['x'],e['y'],e['w'],e['h'],e['fill'],e['color'],10,2)
            rect(e['x'],e['y'],5,e['h'],e['color'],e['color'],2,0)
            text(e['x']+10,e['y']+14,e['title'],e['size']+2,INK,True,'center',e['w']-20)
            text(e['x']+10,e['y']+48,e['body'],e['size']-1,MUTED,False,'center',e['w']-20)
    out.append('</svg>')
    (OUT/f'{c.slug}.svg').write_text('\n'.join(out))


def drawio(canvases):
    mx=ET.Element('mxfile',host='app.diagrams.net',agent='production topology generator',version='24.7.17')
    for ci,c in enumerate(canvases):
        d=ET.SubElement(mx,'diagram',id=f'page{ci+1}',name=c.name)
        model=ET.SubElement(d,'mxGraphModel',dx='2400',dy='1780',grid='1',gridSize='10',guides='1',tooltips='1',connect='1',arrows='1',fold='1',page='1',pageScale='1',pageWidth=str(W),pageHeight=str(H),math='0',shadow='0')
        root=ET.SubElement(model,'root');ET.SubElement(root,'mxCell',id='0');ET.SubElement(root,'mxCell',id='1',parent='0')
        for i,e in enumerate(c.items):
            id=e.get('id',f'item-{i}')
            k=e['kind']
            if k=='edge':
                style=f'endArrow=none;startArrow=none;strokeColor={e["color"]};strokeWidth={e["width"]};rounded=0;'
                if e['dashed']:style+='dashed=1;dashPattern=8 7;'
                attrs=dict(id=id,edge='1',parent='1')
                for side,key in [('source','exit'),('target','entry')]:
                    nid=e[side]
                    if nid:
                        node=c.index[nid];p=e['points'][0 if side=='source' else -1]
                        style+=f'{key}X={(p[0]-node["x"])/node["w"]};{key}Y={(p[1]-node["y"])/node["h"]};{key}Dx=0;{key}Dy=0;{key}Perimeter=0;'
                        attrs[side]=nid
                cell=ET.SubElement(root,'mxCell',**attrs,style=style)
                g=ET.SubElement(cell,'mxGeometry',relative='1',**{'as':'geometry'})
                for typ,p in [('sourcePoint',e['points'][0]),('targetPoint',e['points'][-1])]:ET.SubElement(g,'mxPoint',x=str(p[0]),y=str(p[1]),**{'as':typ})
                if len(e['points'])>2:
                    a=ET.SubElement(g,'Array',**{'as':'points'})
                    for x,y in e['points'][1:-1]:ET.SubElement(a,'mxPoint',x=str(x),y=str(y))
                continue
            if k=='node':
                value=f'<b>{html.escape(e["title"])}</b><br><br>'+html.escape(e['body']).replace('\n','<br>')
                style=f'rounded=1;whiteSpace=wrap;html=1;fillColor={e["fill"]};strokeColor={e["color"]};strokeWidth=2;fontColor={INK};fontSize={e["size"]};fontFamily=Arial;spacing=8;'
            elif k=='text':
                value=html.escape(e['value']).replace('\n','<br>')
                style=f'text;html=1;strokeColor=none;fillColor=none;align={e["align"]};verticalAlign=top;whiteSpace=wrap;rounded=0;fontSize={e["size"]};fontColor={e["color"]};fontStyle={1 if e["bold"] else 0};fontFamily=Arial;spacing=0;'
            else:
                value='';style=f'rounded={1 if e["radius"] else 0};whiteSpace=wrap;html=1;fillColor={e["fill"]};strokeColor={e["stroke"]};strokeWidth={e["width"]};'
            cell=ET.SubElement(root,'mxCell',id=id,value=value,style=style,vertex='1',parent='1')
            ET.SubElement(cell,'mxGeometry',x=str(e['x']),y=str(e['y']),width=str(e['w']),height=str(e['h']),**{'as':'geometry'})
    ET.indent(mx)
    ET.ElementTree(mx).write(OUT/'network-topology.drawio',encoding='utf-8',xml_declaration=True)


def excalidraw(canvases):
    elems=[];seq=0
    def base(typ,x,y,w,h,stroke,background='transparent',sw=1):
        nonlocal seq
        seq+=1
        return dict(id=f'{seq}',type=typ,x=x,y=y,width=w,height=h,angle=0,strokeColor=stroke,
                    backgroundColor=background,fillStyle='solid',strokeWidth=sw,strokeStyle='solid',roughness=0,
                    opacity=100,groupIds=[],frameId=None,roundness=None,seed=seq,version=1,versionNonce=seq,
                    isDeleted=False,boundElements=None,updated=0,link=None,locked=False)
    def txt(x,y,w,value,size,color,bold=False,align='left'):
        # Excalidraw's standard sans-serif font keeps the document broadly editable.
        e=base('text',x,y,w,len(value.split('\n'))*size*1.28,color)
        e.update(text=value,originalText=value,fontSize=size,fontFamily=2,textAlign=align,verticalAlign='top',
                 containerId=None,lineHeight=1.28,autoResize=False)
        elems.append(e)
    for ci,c in enumerate(canvases):
        ox=ci*(W+120)
        bg=base('rectangle',ox,0,W,H,'#FFFFFF','#FFFFFF',0);elems.append(bg)
        for e in c.items:
            k=e['kind']
            if k=='edge':
                p=e['points'];x0,y0=p[0]
                xs=[x for x,y in p];ys=[y for x,y in p]
                ee=base('line',x0+ox,y0,max(xs)-min(xs),max(ys)-min(ys),e['color'],sw=e['width'])
                ee.update(points=[[x-x0,y-y0] for x,y in p],startBinding=None,endBinding=None,startArrowhead=None,endArrowhead=None,lastCommittedPoint=None)
                if e['dashed']:ee['strokeStyle']='dashed'
                elems.append(ee)
            elif k=='text':txt(e['x']+ox,e['y'],e['w'],e['value'],e['size'],e['color'],e['bold'],e['align'])
            else:
                col=e['color'] if k=='node' else e['stroke']
                ee=base('rectangle',e['x']+ox,e['y'],e['w'],e['h'],col,e['fill'],2 if k=='node' else e['width'])
                if k=='node' or e['radius']:ee['roundness']={'type':3}
                elems.append(ee)
                if k=='node':
                    txt(e['x']+ox+10,e['y']+14,e['w']-20,e['title'],e['size']+2,INK,True,'center')
                    txt(e['x']+ox+10,e['y']+48,e['w']-20,e['body'],e['size']-1,MUTED,False,'center')
    scene=dict(type='excalidraw',version=2,source='production physical topology generator',elements=elems,
               appState=dict(viewBackgroundColor='#FFFFFF',gridSize=None),files={})
    (OUT/'network-topology.excalidraw').write_text(json.dumps(scene,ensure_ascii=False,indent=2))


if __name__=='__main__':
    canvases=[overview(),detail()]
    for c in canvases:svg(c)
    drawio(canvases);excalidraw(canvases)
    print('Generated two SVG views and editable draw.io / Excalidraw documents.')
    print('Checked CSV link counts, unique endpoints and all 32 GPU server mappings.')
