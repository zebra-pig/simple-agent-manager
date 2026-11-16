"""Loopback-only paginated conversation for real ChatView UI tests."""
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

lock = threading.Lock()
state = {"older": 0, "polls": 0, "delay": 0.1}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        if url.path == "/reset":
            with lock:
                state.update(older=0, polls=0, delay=float(query.get("delay", [0.1])[0]))
            body = state.copy()
        elif url.path == "/stats":
            with lock:
                body = state.copy()
        elif url.path == "/api/projects/fixture/sessions/fixture":
            before = json.loads(query["before"][0])[0] if "before" in query else 96
            after = json.loads(query["after"][0])[0] if "after" in query else None
            with lock:
                if "before" in query:
                    state["older"] += 1
                else:
                    state["polls"] += 1
                snapshot = state.copy()
            if "before" in query:
                time.sleep(snapshot["delay"])
            first = max(0, before - 12) if after is None else after + 1
            rows = []
            for index in range(first, before):
                content = f"Message {index}\n" + ("Variable-height conversation detail. " * (index % 9 + 2))
                if index == 94:
                    content = f"Streaming update {snapshot['polls']}\n" + "Live detail. " * (snapshot['polls'] % 8 + 1)
                if index == 95:
                    content = "LATEST MESSAGE"
                rows.append({"id": f"m-{index}", "createdAt": index, "role": "user", "content": content})
            body = {"session": {"id": "fixture", "topic": "Scroll regression", "status": "active", "isMine": True},
                    "messages": rows, "hasMore": first > 0 if after is None else False}
        elif url.path == "/api/notifications":
            body = {"notifications": [], "nextCursor": None}
        elif url.path == "/api/report-issue/config":
            body = {"enabled": False}
        else:
            self.send_error(404)
            return
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 18874), Handler).serve_forever()
