"""Offline HTTP fixture for uploaded-preview-macos.swift; never uses real accounts."""
import json
import struct
import tempfile
import zlib
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

upload = "01M7FSHXZ07Z2V7660M26N06SY"
filename = "my photo.png"
def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))


# A valid one-pixel red RGB PNG, generated entirely from mock test data.
png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(b"\x00\xff\x00\x00"))
       + chunk(b"IEND", b""))
reads = []
prompt = (
    "Look at this\n\n## Attached Files\n\nThe following files have been uploaded to the workspace:\n"
    f"- `/workspaces/.private/{upload}/{filename}` ({len(png)} bytes, image/png)\n\n"
    "These are absolute paths inside your workspace container, outside the repository. "
    "Open the exact paths listed above to read the attachments; do not look for them relative to the repository."
)


class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        assert self.headers.get("Cookie") == "preview=fixture"
        url = urlsplit(self.path)
        status, body, mime = 200, {}, "application/json"
        if url.path == "/api/projects/p/sessions/s":
            body = {"session": {"id": "s", "status": "active", "startedAt": 1, "isMine": True},
                    "messages": [{"id": "m", "role": "user", "createdAt": 1, "content": prompt}]}
        elif "/tasks/uploads/" in url.path:
            reads.append("original")
            status = 404  # Deleted staging object or an older API without the new route.
        elif url.path == "/api/projects/p/sessions/s/files/raw":
            assert parse_qs(url.query) == {"path": [f"/workspaces/.private/{upload}/{filename}"]}
            reads.append("workspace")
            body, mime = png, "image/png"
        elif url.path == "/api/notifications":
            body = {"notifications": [], "nextCursor": None}
        elif url.path == "/api/report-issue/config":
            body = {"enabled": False}
        else:
            status = 404
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


server = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    with tempfile.TemporaryDirectory(prefix="sam-preview-fixture-") as directory:
        image = directory + "/original.png"
        with open(image, "wb") as output:
            output.write(png)
        subprocess.run([sys.argv[1], f"http://127.0.0.1:{server.server_port}", image], check=True)
    assert reads == ["original", "workspace"], reads
finally:
    server.shutdown()
    server.server_close()
    thread.join()
