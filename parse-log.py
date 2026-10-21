#!/usr/bin/env python3
# usage: parse-log.py <container>  -- lists startup-config lines the OcNOS CLI rejected (from the vrnetlab console trace)
import re,sys,subprocess
c=sys.argv[1]
r=subprocess.run(["docker","logs",c],capture_output=True,text=True,errors="replace")
log=re.sub(r"\x1b\[[0-9;]*m","",r.stdout+r.stderr).replace("\r","")
seg=log[log.index("Writing lines from /config/startup-config.cfg"):]
parts=re.split(r"\n[0-9-]+ [0-9:,]+: vrnetlab\s+DEBUG writing to serial console: ", seg)
bad=tot=0
for p in parts[1:]:
    m=re.match(r"\x27(.*?)\x27\n",p)
    if not m: continue
    tot+=1
    errs=[l.strip() for l in p.splitlines() if l.strip().startswith("%")]
    if errs: bad+=1; print(f"  REJECTED | {m.group(1):70}| {errs[0]}")
print(f"{c}: {tot-bad}/{tot} lines accepted")
