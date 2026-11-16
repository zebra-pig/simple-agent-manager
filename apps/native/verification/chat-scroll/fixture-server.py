"""Loopback-only paginated conversation for real ChatView UI tests."""
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

lock = threading.Lock()
state = {"older": 0, "completedOlder": 0, "inFlight": 0, "polls": 0, "delay": 0.1, "generation": 0, "mixed": False}
scroll_samples = []
layout_samples = []
history_gate = threading.Event()
history_gate.set()


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path == "/layout-samples":
            sample = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            with lock:
                layout_samples.append(sample)
                del layout_samples[:-1000]
            self.send_response(204)
            self.end_headers()
            return
        if self.path != "/scroll-samples":
            self.send_error(404)
            return
        samples = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with lock:
            if state.get("releaseArmed"):
                movement = next((sample for sample in samples if sample["time"] >= state["armedAt"] and sample["y"] > state["releaseY"] + 50), None)
                if movement:
                    state["releaseArmed"] = False
                    state["releasedDuringJump"] = True
                    state["releaseDistance"] = movement["bottom"] - movement["y"]
                    history_gate.set()
            scroll_samples.extend(samples)
            del scroll_samples[:-20000]
        self.send_response(204)
        self.end_headers()

    def do_GET(self):
        global history_gate
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        if url.path == "/reset":
            with lock:
                scroll_samples.clear()
                layout_samples.clear()
                history_gate.set()
                history_gate = threading.Event()
                if query.get("hold", ["false"])[0] != "true":
                    history_gate.set()
                state.update(older=0, completedOlder=0, inFlight=0, polls=0,
                             generation=state["generation"] + 1,
                             provisioning=query.get("provisioning", ["false"])[0] == "true",
                             releaseArmed=False, releasedDuringJump=False,
                             step="node_provisioning", startedAt=int(time.time() * 1000) - 10000,
                             mixed=query.get("mixed", ["false"])[0] == "true",
                             delay=float(query.get("delay", [0.1])[0]))
            body = state.copy()
        elif url.path == "/provisioning":
            with lock:
                state["step"] = query["step"][0]
                body = state.copy()
        elif url.path == "/api/projects/fixture/tasks/setup":
            with lock:
                body = {"id": "setup", "status": "queued", "executionStep": state["step"]}
        elif url.path == "/release-on-scroll":
            with lock:
                state.update(releaseArmed=True, releasedDuringJump=False, armedAt=time.time(),
                             releaseY=scroll_samples[-1]["y"])
                body = state.copy()
        elif url.path == "/release-history":
            history_gate.set()
            body = {"released": True}
        elif url.path == "/layout":
            with lock:
                body = {"samples": layout_samples[-4:]}
        elif url.path == "/trace":
            after = float(query.get("after", [0])[0])
            with lock:
                body = {"samples": sorted((sample for sample in scroll_samples if sample["time"] >= after), key=lambda sample: sample["time"])}
        elif url.path == "/stats":
            with lock:
                body = state.copy()
        elif url.path == "/api/projects/fixture/sessions/fixture":
            before = json.loads(query["before"][0])[0] if "before" in query else 96
            after = json.loads(query["after"][0])[0] if "after" in query else None
            with lock:
                if "before" in query:
                    state["older"] += 1
                    state["inFlight"] += 1
                else:
                    state["polls"] += 1
                snapshot = state.copy()
                gate = history_gate
            if "before" in query:
                gate.wait(timeout=60)
                time.sleep(snapshot["delay"])
                with lock:
                    if state["generation"] == snapshot["generation"]:
                        state["inFlight"] -= 1
                        state["completedOlder"] += 1
                        if state.get("releasedDuringJump") and scroll_samples:
                            sample = max(scroll_samples, key=lambda sample: sample["time"])
                            state["completionDistance"] = sample["bottom"] - sample["y"]
            first = max(0, before - 12) if after is None else after + 1
            rows = []
            for index in range(first, before):
                content = f"Message {index}\n" + ("Variable-height conversation detail. " * (index % 9 + 2))
                if index == 94:
                    content = f"Streaming update {snapshot['polls']}\n" + "Live detail. " * (snapshot['polls'] % 8 + 1)
                if index == 95:
                    content = "LATEST MESSAGE"
                role, metadata = "user", None
                if snapshot["mixed"] and index < 94:
                    if index % 7 in (1, 5):
                        role = "assistant"
                        content = (f"### Assistant response {index}\n\n"
                                   + "A longer streamed explanation. " * (index % 8 + 1)
                                   + "\n\n```swift\nfor page in history {\n    print(page.id)\n}\n```\n"
                                   + "\n| Check | Status |\n| --- | --- |\n| Pagination | Loaded |\n| Scroll | Pending |")
                    elif index % 7 == 3:
                        role = "tool"
                        metadata = {"toolCallId": f"call-{index}", "title": "Read chat history and run tests",
                                    "kind": "execute", "status": "completed"}
                        content = "Output line with variable width.\n" * 20
                    elif index % 7 == 4:
                        role, content = "thinking", "Checking the page boundary and stable reading position. " * 4
                rows.append({"id": f"m-{index}", "createdAt": index, "role": role,
                             "content": content, "toolMetadata": metadata})
            if snapshot.get("provisioning"):
                rows = [{"id": "setup-message", "createdAt": 1, "role": "user", "content": "Build an app"}]
            body = {"session": {"id": "fixture", "topic": "Scroll regression", "status": "active", "isMine": True},
                    "messages": rows, "hasMore": first > 0 if after is None else False}
            if snapshot.get("provisioning"):
                body["hasMore"] = False
                body["session"].update(taskId="setup", startedAt=snapshot["startedAt"],
                                       task={"id": "setup", "status": "queued", "executionStep": snapshot["step"]})
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
