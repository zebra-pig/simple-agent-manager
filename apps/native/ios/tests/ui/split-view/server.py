"""Offline SAM API: real Rust transport/models feed the production SwiftUI views."""
import json
import pathlib
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

PROJECTS = [
    {"id": "atlas", "name": "Atlas", "repository": "example/atlas", "activeSessionCount": 1},
    {"id": "orchard", "name": "Orchard", "repository": "example/orchard", "activeSessionCount": 1},
    {"id": "research", "name": "Research", "repository": None, "activeSessionCount": 0},
]
TOPICS = {"atlas": "Build the dashboard", "orchard": "Improve onboarding"}
REPLIES = {"atlas": "The dashboard layout is ready for review.",
           "orchard": "The onboarding flow now explains each step."}


def session(project):
    return {"id": project + "-session", "topic": TOPICS[project], "status": "active",
            "isMine": True, "isIdle": True, "startedAt": 1794819600000, "messageCount": 2}


def make_server(port=0):
    reads = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            path = urlsplit(self.path).path
            authenticated = self.headers.get("Cookie") == "fixture=split-view"
            reads.append({"path": path, "authenticated": authenticated})
            print(json.dumps(reads[-1]), flush=True)
            status, body = 200, {}
            if not authenticated:
                status = 401
            elif path == "/api/auth/get-session":
                body = {"user": {"id": "fixture-user", "name": "Sample User", "email": "sample@example.com"}}
            elif path == "/api/sam/settings":
                body = {"enabled": False, "available": False}
            elif path == "/api/projects":
                time.sleep(0.5)  # Exercise a notification while its sidebar data is still arriving.
                body = {"projects": PROJECTS, "nextCursor": None}
            elif path == "/api/notifications":
                body = {"notifications": [], "nextCursor": None}
            elif path == "/api/report-issue/config":
                body = {"enabled": False}
            elif path.startswith("/api/projects/"):
                parts = path.split("/")
                project = parts[3]
                if path.endswith("/agent-profiles"):
                    body = {"items": []}
                elif path.endswith("/agent-profiles/picker"):
                    body = {"recentIds": [], "hiddenIds": []}
                elif path.endswith("/sessions"):
                    body = {"sessions": [session(project)] if project in TOPICS else []}
                elif len(parts) == 6 and parts[4] == "sessions" and project in TOPICS:
                    # Reject a stale conversation paired with a newly selected project.
                    assert parts[5] == project + "-session", self.path
                    body = {"session": session(project), "hasMore": False, "messages": [
                        {"id": project + "-user", "role": "user", "content": "Please prepare the next iteration.",
                         "createdAt": 1794819600000, "sequence": 1},
                        {"id": project + "-agent", "role": "assistant", "content": REPLIES[project],
                         "createdAt": 1794819601000, "sequence": 2},
                    ]}
                else:
                    status = 404
            else:
                status = 404
            data = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    return ThreadingHTTPServer(("127.0.0.1", port), Handler), reads


if __name__ == "__main__" and len(sys.argv) > 1 and sys.argv[1] == "--serve":
    server, _ = make_server(int(sys.argv[2]))
    pathlib.Path(sys.argv[3]).write_text(str(server.server_port))
    server.serve_forever()
