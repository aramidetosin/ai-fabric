#!/usr/bin/env python3
# Run CLI commands on a vrnetlab OcNOS node through the serial console session the launcher leaves logged in (tcp/5000 in the container).
# The console serves ONE client: a leftover `telnet 127.0.0.1 5000` (e.g. an orphaned docker exec) blocks it -> "CONSOLE BUSY", exit 3.
import socket, sys, time, re
cmds = sys.argv[1:]
try:
    s = socket.create_connection(("127.0.0.1", 5000), timeout=5)
except OSError as e:
    print(f"CONSOLE BUSY ({e}): another client holds tcp/5000 -- check `ps | grep telnet` inside this container"); sys.exit(3)
s.settimeout(1.5)
def rd(t=1.5):
    buf = b""; end = time.time() + t
    while time.time() < end:
        try:
            d = s.recv(65535)
            if not d: break
            buf += d; end = time.time() + 0.6
        except socket.timeout: break
    return buf
def clean(b): return re.sub(r"\xff[\xfb-\xfe].", "", b.decode(errors="replace").replace("\r", ""))
s.sendall(b"\n"); banner = clean(rd())
if "login:" in banner or "Password" in banner:
    print("CONSOLE NOT LOGGED IN - stopping (this helper never enters credentials)"); sys.exit(2)
s.sendall(b"end\n"); rd(0.8)
s.sendall(b"terminal length 0\n"); rd(0.8)
for c in cmds:
    s.sendall(c.encode() + b"\n"); out = clean(rd(3))
    print(f"##### {c}\n{out.strip()}\n")
