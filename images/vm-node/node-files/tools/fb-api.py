#!/usr/bin/env python3
"""FlashBlade-style storage management API for the ai-fabric-refplat lab, served on the storage node's OOB / management
address (10.125.31.231:443). The real platform's CSI driver provisions file systems by calling the FlashBlade REST API on
that address; in the lab this server plays that role and provisions Longhorn PersistentVolumeClaims in the cluster
(kubeconfig from the lab's shared directory). Every request is logged with its client address, which proves the call
arrived through the fabric, the firewall rule fabric -> oob tcp/443 and the OOB network.

  GET    /api/api_version                          -> versions
  GET    /api/2.4/file-systems[?names=n1,n2]       -> the PVCs (all namespaces, or the named ones)
  POST   /api/2.4/file-systems?names=<name>        body {"provisioned": <bytes>, "namespace": "<ns>"} -> create PVC
  DELETE /api/2.4/file-systems?names=<name>[&namespace=<ns>] -> delete PVC
  GET    /api/2.4/arrays                           -> array identity (this node)
Header api-token: <token> (see --token). Stdlib only."""
import argparse, json, os, socket, ssl, subprocess, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

def kubectl(args, kubeconfig, stdin=None):
    p = subprocess.run(["kubectl", "--kubeconfig", kubeconfig] + args, input=stdin, capture_output=True, text=True, timeout=60)
    return p.returncode, p.stdout, p.stderr

class H(BaseHTTPRequestHandler):
    server_version = "FlashBlade-lab/2.4"
    def log_message(self, fmt, *a):
        sys.stdout.write("%s client=%s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S"), self.client_address[0], fmt % a)); sys.stdout.flush()
    def send(self, code, obj):
        b = json.dumps(obj, indent=1).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def auth(self):
        if self.headers.get("api-token") != self.server.token:
            self.send(401, {"errors": [{"message": "invalid api-token"}]}); return False
        return True
    def do_GET(self):
        u = urlparse(self.path); q = parse_qs(u.query)
        if u.path == "/api/api_version": return self.send(200, {"versions": ["2.4"]})
        if not self.auth(): return
        if u.path == "/api/2.4/arrays":
            return self.send(200, {"items": [{"name": socket.gethostname(), "os": "Purity//FB (lab stand-in)", "version": "4.x-lab", "mgmt_address": self.server.bind}]})
        if u.path == "/api/2.4/file-systems":
            rc, out, err = kubectl(["get", "pvc", "-A", "-o", "json"], self.server.kubeconfig)
            if rc: return self.send(500, {"errors": [{"message": err.strip()}]})
            names = set(q.get("names", [""])[0].split(",")) - {""}
            items = []
            for it in json.loads(out)["items"]:
                n = it["metadata"]["name"]
                if names and n not in names: continue
                items.append({"name": n, "namespace": it["metadata"]["namespace"], "provisioned": it["spec"]["resources"]["requests"].get("storage"),
                              "state": it["status"].get("phase"), "volume": it["spec"].get("volumeName"), "created": it["metadata"]["creationTimestamp"]})
            return self.send(200, {"items": items, "total_item_count": len(items)})
        self.send(404, {"errors": [{"message": "not found"}]})
    def do_POST(self):
        u = urlparse(self.path); q = parse_qs(u.query)
        if not self.auth(): return
        if u.path != "/api/2.4/file-systems" or not q.get("names"): return self.send(400, {"errors": [{"message": "POST /api/2.4/file-systems?names=<name>"}]})
        n = int(self.headers.get("Content-Length") or 0); body = json.loads(self.rfile.read(n) or b"{}")
        name = q["names"][0]; ns = body.get("namespace", "default"); size = body.get("provisioned", 1 << 30)
        size_str = size if isinstance(size, str) else "%dMi" % max(1, int(size) // (1 << 20))
        pvc = {"apiVersion": "v1", "kind": "PersistentVolumeClaim", "metadata": {"name": name, "namespace": ns, "labels": {"ai-fabric.lab/provisioned-by": "flashblade-lab-api"},
               "annotations": {"ai-fabric.lab/requested-from": self.client_address[0]}},
               "spec": {"accessModes": ["ReadWriteOnce"], "storageClassName": self.server.storageclass, "resources": {"requests": {"storage": size_str}}}}
        rc, out, err = kubectl(["apply", "-f", "-"], self.server.kubeconfig, stdin=json.dumps(pvc))
        if rc: return self.send(500, {"errors": [{"message": err.strip()}]})
        phase = "Pending"
        for _ in range(60):
            rc, out, err = kubectl(["-n", ns, "get", "pvc", name, "-o", "jsonpath={.status.phase} {.spec.volumeName}"], self.server.kubeconfig)
            phase = (out.split() + [""])[0]
            if phase == "Bound": break
            time.sleep(2)
        vol = (out.split() + ["", ""])[1]
        self.send(201 if phase == "Bound" else 202, {"items": [{"name": name, "namespace": ns, "provisioned": size_str, "state": phase, "volume": vol, "requested_from": self.client_address[0]}]})
    def do_DELETE(self):
        u = urlparse(self.path); q = parse_qs(u.query)
        if not self.auth(): return
        if u.path != "/api/2.4/file-systems" or not q.get("names"): return self.send(400, {"errors": [{"message": "DELETE /api/2.4/file-systems?names=<name>"}]})
        rc, out, err = kubectl(["-n", q.get("namespace", ["default"])[0], "delete", "pvc", q["names"][0], "--ignore-not-found"], self.server.kubeconfig)
        self.send(200 if not rc else 500, {"message": (out or err).strip()})

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--bind", required=True); ap.add_argument("--port", type=int, default=443)
    ap.add_argument("--cert", required=True); ap.add_argument("--key", required=True); ap.add_argument("--kubeconfig", required=True)
    ap.add_argument("--token", required=True); ap.add_argument("--storageclass", default="longhorn"); a = ap.parse_args()
    while not os.path.exists(a.kubeconfig): time.sleep(5)
    srv = ThreadingHTTPServer((a.bind, a.port), H); srv.token = a.token; srv.kubeconfig = a.kubeconfig; srv.storageclass = a.storageclass; srv.bind = a.bind
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(a.cert, a.key); srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    print("flashblade-lab api on https://%s:%d (kubeconfig %s, storageclass %s)" % (a.bind, a.port, a.kubeconfig, a.storageclass)); sys.stdout.flush()
    srv.serve_forever()
if __name__ == "__main__": main()
