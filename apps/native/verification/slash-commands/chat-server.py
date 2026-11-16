"""Offline production-ChatView fixture: authenticated reads, no real agent tasks."""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.headers.get("Cookie") != "fixture=local-only":
            self.send_error(401)
            return
        now = int(time.time() * 1000)
        if self.path == "/api/projects/p1/cached-commands":
            body = {"commands": [
                {"name": "release", "description": "Prepare a release for review", "agentType": "codex"},
                {"name": "review", "description": "Review the current code changes", "agentType": "codex"},
            ]}
        elif self.path.startswith("/api/projects/p1/sessions/s1"):
            body = {"session": {"id": "s1", "topic": "Review the settings update", "status": "active",
                                "viewerAccess": "owner", "isMine": True, "isIdle": True,
                                "startedAt": now - 300000},
                    "state": {"activity": "idle"}, "hasMore": False,
                    "messages": [
                        {"id": "m1", "role": "user", "content": "Make the settings easier to navigate.", "createdAt": now - 180000},
                        {"id": "m2", "role": "assistant", "content": "I grouped the settings into **Account**, **Projects**, and **Notifications**.", "createdAt": now - 120000},
                        {"id": "m3", "role": "assistant", "content": "The update is ready for review. The existing preferences are preserved, and the checks pass.", "createdAt": now - 60000},
                    ]}
        elif self.path.startswith("/api/notifications"):
            body = {"notifications": [], "nextCursor": None}
        else:
            body = {}
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        # No fixture code should submit a prompt, task, or other mutation.
        self.send_error(405, "Unexpected write in screenshot fixture")


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w") as port_file:
    port_file.write(str(server.server_port))
server.serve_forever()
