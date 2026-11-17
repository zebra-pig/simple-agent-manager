"""Loopback-only paginated conversation for real ChatView UI tests."""
import json
import struct
import threading
import zlib
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

def png(width, height):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    row = b"\x00" + bytes([40, 120, 200]) * width
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(row * height)) + chunk(b"IEND", b""))


lock = threading.Lock()
state = {"older": 0, "completedOlder": 0, "inFlight": 0, "polls": 0, "delay": 0.1, "generation": 0, "mixed": False, "historyEvents": []}
scroll_samples = []
layout_samples = []
history_gate = threading.Event()
history_gate.set()
request_gate = threading.Event()
request_gate.set()


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/measurements":
            self.send_error(404)
            return
        payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        samples = payload["samples"]
        with lock:
            layout_samples.extend(payload["layouts"])
            del layout_samples[:-1000]
        with lock:
            if state.get("releaseArmed"):
                movement = next((sample for sample in samples if sample["time"] >= state["armedAt"] and sample.get("distanceToLatest", sample["bottom"] - sample["y"]) < state["releaseDistanceAtArm"] - 50), None)
                if movement:
                    state["releaseArmed"] = False
                    state["releasedDuringJump"] = True
                    state["releaseDistance"] = movement.get("distanceToLatest", movement["bottom"] - movement["y"])
                    history_gate.set()
            scroll_samples.extend(samples)
            del scroll_samples[:-20000]
        self.send_response(204)
        self.end_headers()

    def do_GET(self):
        global history_gate, request_gate
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
                request_gate.set()
                request_gate = threading.Event()
                if query.get("holdRequests", ["false"])[0] != "true":
                    request_gate.set()
                state.update(older=0, completedOlder=0, inFlight=0, polls=0,
                             generation=state["generation"] + 1, historyEvents=[],
                             provisioning=query.get("provisioning", ["false"])[0] == "true",
                             releaseArmed=False, releasedDuringJump=False,
                             step="node_provisioning", startedAt=int(time.time() * 1000) - 10000,
                             mixed=query.get("mixed", ["false"])[0] == "true",
                             requests=query.get("requests", ["false"])[0] == "true", requestLoads=0,
                             wide=query.get("wide", ["false"])[0] == "true",
                             attention=query.get("attention", ["false"])[0] == "true",
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
                             releaseY=scroll_samples[-1]["y"],
                             releaseDistanceAtArm=scroll_samples[-1].get("distanceToLatest", scroll_samples[-1]["bottom"] - scroll_samples[-1]["y"]))
                body = state.copy()
        elif url.path == "/release-requests":
            request_gate.set()
            body = {"released": True}
        # Specific fixture request: must precede the generic attention handler.
        elif url.path == "/api/projects/fixture/sessions/fixture/attention/approval-request":
            body = {"canAnswer": True, "request": {
                "status": "pending", "canAnswer": True,
                "reason": ("The native iOS session tools (Related, Automation, Comments, Share, Retry, Fork, Report) "
                           "are done in draft PR https://github.com/zebra-pig/simple-agent-manager/pull/80. "
                           "13 screenshots are in the chat and in the library under /screenshots/native-session-tools/. "
                           "You asked to approve before anything goes further. Please approve, or tell me what to change. "
                           "Once approved, I'll port the same tools to Android and merge."),
                "options": ["Approved: do Android, then merge", "Approved: merge iOS now, Android later",
                            "Change something (describe)"]}}
        elif url.path.startswith("/api/projects/fixture/sessions/fixture/attention/"):
            request_id = url.path.rsplit("/", 1)[1]
            with lock:
                state["requestLoads"] += 1
                gate = request_gate
            gate.wait(timeout=60)
            resolved = request_id.startswith("done")
            body = {"request": {"reason": f"Question {request_id}", "options": ["Yes", "No"],
                                "canAnswer": not resolved, "resolvedAt": 1 if resolved else None,
                                "resolvedAnswer": "Yes" if resolved else None}}
        elif url.path == "/hold-history":
            history_gate.clear()
            body = {"held": True}
        elif url.path == "/release-history":
            history_gate.set()
            body = {"released": True}
        elif url.path == "/layout":
            with lock:
                after = float(query.get("after", [0])[0])
                body = {"samples": sorted((sample for sample in layout_samples if sample["time"] >= after), key=lambda sample: sample["time"])}
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
                    event = {"started": time.time(), "before": before}
                    state["historyEvents"].append(event)
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
                        event["completed"] = time.time()
                        if state.get("releasedDuringJump") and scroll_samples:
                            sample = max(scroll_samples, key=lambda sample: sample["time"])
                            state["completionDistance"] = sample.get("distanceToLatest", sample["bottom"] - sample["y"])
            first = max(0, before - 12) if after is None else after + 1
            rows = []
            for index in range(first, before):
                content = f"Message {index}\n" + ("Variable-height conversation detail. " * (index % 9 + 2))
                if index == 94:
                    content = f"Streaming update {snapshot['polls']}\n" + "Live detail. " * (snapshot['polls'] % 8 + 1)
                if index == 95:
                    content = "LATEST MESSAGE"
                role, metadata = "user", None
                if snapshot.get("requests") and index == 93:
                    # Questions near the end of a conversation; two were already answered.
                    role, content = "tool", "Asked the user"
                    metadata = {"toolCallId": "ask", "title": "Ask the user", "kind": "other", "status": "completed",
                                "rawOutput": [{"humanInputRequest": {"id": request_id}} for request_id in ("done-1", "done-2", "open-1")]}
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
                if snapshot.get("wide") and 88 <= index < 94:
                    # Content whose natural width exceeds a phone: unbroken
                    # tokens, long links, wide tables and long command lines.
                    token = "a1b2c3d4e5f6" * 12
                    link = "https://github.com/zebra-pig/simple-agent-manager/pull/80/files/" + token
                    role, metadata = "assistant", None
                    if index == 88:
                        content = (f"Unbroken token `{token}` and link {link}\n\n"
                                   f"- Item with path /workspaces/{token}/apps/native/ios/SAM/ChatView.swift\n"
                                   f"  - Nested {token}\n\n> Quote {token}\n\n"
                                   "| " + " | ".join(f"Column {n} heading" for n in range(10)) + " |\n"
                                   "| " + " | ".join("---" for _ in range(10)) + " |\n"
                                   "| " + " | ".join(f"value-{token[:30]}" for _ in range(10)) + " |")
                    elif index == 89:
                        role = "tool"
                        metadata = {"toolCallId": f"call-{index}", "title": "git log --format=" + token * 2,
                                    "kind": "execute", "status": "completed", "locations": [f"/workspaces/{token}/x.swift"]}
                        content = (token * 3 + "\n") * 3
                    elif index == 90:
                        role = "user"
                        content = f"User text {token}{token} {link}"
                    elif index == 91:
                        content = f"```\n{'x' * 400}\n```\n\n**Heading:** {token}{token}"
                    elif index == 92:
                        role, content = "thinking", f"Thinking about {token}{token}"
                    else:
                        content = f"# {token}\n\n1. {link}\n2. `{token}{token}`"
                if snapshot.get("attention") and index in (88, 89, 91):
                    # Agent-shared screenshots: tall and wide library images.
                    role, content = "tool", ""
                    metadata = {"toolName": "display_from_library", "toolCallId": f"call-{index}",
                                "rawOutput": {"fileId": str(index), "filename": f"{index}.png", "mimeType": "image/png"}}
                if snapshot.get("attention") and index == 90:
                    role = "user"
                    content = ("Review images\n\n## Attached Files\n\nThe following files have been uploaded to the workspace:\n"
                               + "\n".join(f"- `/workspaces/.private/{n:026d}/{n}.png` (100 bytes, image/png)" for n in range(80, 86))
                               + "\n\nThese are absolute paths inside your workspace container, outside the repository. Open the exact paths listed above to read the attachments; do not look for them relative to the repository.")
                if snapshot.get("attention") and index == 93:
                    role, metadata = "tool", {"toolCallId": "call-attention", "title": "Request human input",
                                              "kind": "other", "status": "completed"}
                    content = ('(tool call)Tool: mcp__sam-mcp__request_human_input(tool call){"message":"Human input request recorded.",'
                               '"humanInputRequest":{"id":"approval-request","sessionId":"fixture"},"notificationScheduled":true}')
                if snapshot.get("attention") and index == 94:
                    role = "assistant"
                    content = ("I haven't stalled; I'm waiting for your approval before going further. The iOS work is finished in draft PR "
                               "[#80](https://github.com/zebra-pig/simple-agent-manager/pull/80), and the 13 screenshots are above.\n\n"
                               "I've sent you an approval request with three choices:\n"
                               "- **Approved, do Android first:** I port the same tools to Android, then merge.\n"
                               "- **Approved, merge iOS now:** I merge this PR and do Android later.\n"
                               "- **Change something:** tell me what, and I'll update the screens and send new screenshots.\n\n"
                               "Nothing will be merged until you reply.")
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
        elif "/library/" in url.path or "/tasks/uploads/" in url.path:
            number = int(url.path.split("/")[-2] if "/library/" in url.path else url.path.split("/uploads/")[1].split("/")[0])
            data = png(240, 120) if number % 2 else png(118, 256)
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
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
    import pathlib, sys
    server = ThreadingHTTPServer(("127.0.0.1", int(sys.argv[2])), Handler)
    pathlib.Path(sys.argv[3]).write_text(str(server.server_port))
    server.serve_forever()
