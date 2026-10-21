#!/bin/bash
# host/pa-vm-console-fix.sh: make the PA-VM vrnetlab launcher survive a login prompt that arrives split across two console reads.
# Found on site-b 2026-10-01 (two deploys in a row): PAN-OS printed "Enter old password :" while the kernel logged "tap0: link becomes ready" on
# the same console; the launcher read "E", then "nter old password : [...]". Its expect() matches each read window alone, and its _read() calls
# scrapli's channel.read(), which BLOCKS on a silent console (timeout 3600 s): the 1-second expect window is never honoured, the launcher's own
# "nudge the console" recovery never runs, and after an hour scrapli raises, launch.py exits and the container goes with its links.
# Fix in the image's /vrnetlab.py (class _Console):  _read() returns b"" when nothing is readable (select on the transport socket), and expect()
# carries the unmatched tail of the previous window into the next one, so a split prompt matches. Derived image under the SAME tag (the generator's
# PAN_IMAGE); the original stays as <tag>-orig. Idempotent: an image that already carries the marker is left alone. up.sh runs it for profiles
# with pa_console_fix (site-b-nx); it is safe for any host.
set -euo pipefail
cd "$(dirname "$0")/.."
IMG=$(python3 -c 'import gen; print(gen.PAN_IMAGE)'); MARK="console-fix-20261001"
if docker run --rm --entrypoint grep "$IMG" -q "$MARK" /vrnetlab.py 2>/dev/null; then echo "pa-vm-console-fix: $IMG already carries the fix"; exit 0; fi
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
docker run --rm --entrypoint cat "$IMG" /vrnetlab.py > "$T/vrnetlab.py"
python3 - "$T/vrnetlab.py" "$MARK" <<'PY'
import sys
p, mark = sys.argv[1], sys.argv[2]; s = open(p, encoding="utf-8").read()
old_read = '''    def _read(self):
        data = self._driver.channel.read()
'''
new_read = '''    def _read(self, wait=0.2):
        # %s: channel.read() blocks until data arrives (scrapli timeouts are 3600 s); on a silent console that made every
        # timed expect()/read_until() wait for an hour. Read only when the transport socket is readable.
        sock = getattr(getattr(getattr(self._driver, "transport", None), "socket", None), "sock", None)
        if sock is not None:
            import select
            try:
                readable, _, _ = select.select([sock], [], [], wait)
            except (OSError, ValueError):
                readable = [sock]
            if not readable:
                return b""
        data = self._driver.channel.read()
''' % mark
assert old_read in s, "unexpected _Console._read"; s = s.replace(old_read, new_read, 1)
old_exp = '''        buf = b""
        t_end = time.time() + timeout if timeout else None
        while True:
            data = self._read()
            buf += data
            if not data:
                time.sleep(0.1)
            for i, pat in enumerate(regex_list):
                match = re.search(pat.decode(), buf.decode(errors="ignore"))
                if match:
                    return i, match, buf
            if t_end and time.time() > t_end:
                return -1, None, buf
'''
new_exp = '''        # %s: the unmatched tail of the previous window is carried over, so a prompt split across two windows still matches
        carry = getattr(self, "_carry", b"")
        buf = carry
        t_end = time.time() + timeout if timeout else None
        while True:
            data = self._read()
            buf += data
            for i, pat in enumerate(regex_list):
                match = re.search(pat.decode(), buf.decode(errors="ignore"))
                if match:
                    self._carry = b""
                    return i, match, buf
            if t_end and time.time() > t_end:
                self._carry = buf[-160:]
                return -1, None, buf[len(carry):]      # only what this window read: the callers count silent windows
''' % mark
assert old_exp in s, "unexpected _Console.expect"; s = s.replace(old_exp, new_exp, 1)
open(p, "w", encoding="utf-8").write(s)
PY
python3 -c "import ast,sys; ast.parse(open('$T/vrnetlab.py').read())"
printf 'FROM %s-orig\nCOPY vrnetlab.py /vrnetlab.py\n' "$IMG" > "$T/Dockerfile"
docker image inspect "$IMG-orig" >/dev/null 2>&1 || docker tag "$IMG" "$IMG-orig"
docker build -q -t "$IMG" "$T" >/dev/null
echo "pa-vm-console-fix: $IMG rebuilt with the console fix (original kept as $IMG-orig)"
