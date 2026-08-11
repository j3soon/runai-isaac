"""Minimal PUT/GET file endpoint, run inside a Run:ai pod and reached via port-forward.

Moves files on and off /mnt/nfs when FTP is unprovisioned, since `runai ... exec --stdin`
cannot stream binary data. See references/runai-cli.md for the full recipe.

Usage: <python> upload_server.py <root-dir> <token> [port]

Every request path must start with the token; the pod network is shared, so this keeps
stray pods from writing into the NFS user directory. Serve only for as long as the
transfer needs, and delete the staging workspace afterwards.
"""

import http.server
import os
import sys

ROOT = sys.argv[1]
TOKEN = sys.argv[2]
PORT = int(sys.argv[3]) if len(sys.argv) > 3 else 8000


def resolve(path):
    rel = path.lstrip("/")
    prefix = TOKEN + "/"
    if not rel.startswith(prefix):
        return None
    target = os.path.realpath(os.path.join(ROOT, rel[len(prefix):]))
    if target != ROOT and not target.startswith(ROOT + os.sep):
        return None
    return target


class Handler(http.server.BaseHTTPRequestHandler):
    def reply(self, code, body=b""):
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_PUT(self):
        target = resolve(self.path)
        if target is None:
            return self.reply(403, b"forbidden\n")
        os.makedirs(os.path.dirname(target), exist_ok=True)
        remaining = int(self.headers["Content-Length"])
        with open(target, "wb") as f:
            while remaining > 0:
                chunk = self.rfile.read(min(1 << 20, remaining))
                if not chunk:
                    break
                f.write(chunk)
                remaining -= len(chunk)
        self.reply(201, b"ok\n")

    def do_GET(self):
        target = resolve(self.path)
        if target is None or not os.path.isfile(target):
            return self.reply(404, b"not found\n")
        size = os.path.getsize(target)
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(size))
        self.end_headers()
        with open(target, "rb") as f:
            while True:
                chunk = f.read(1 << 20)
                if not chunk:
                    break
                self.wfile.write(chunk)


http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
