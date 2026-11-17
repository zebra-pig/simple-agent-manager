"""Loopback-only SAM API for the native session tools (Related, Automation,
Comments, Share, Report, Retry and Fork). Records every mutation for the UI
tests to assert. No live data."""
import json
import pathlib
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

lock = threading.Lock()
calls = []
NOW = int(time.time() * 1000)
MINUTE = 60_000


def initial_state():
    return {
        "threads": [
            {"id": "t-review", "anchor": {"kind": "message", "messageId": "a1", "quote": "retry the token refresh"},
             "author": {"kind": "human", "id": "bo", "name": "Bo Lindqvist"},
             "body": "Should this also cover expired refresh tokens?", "status": "open",
             "createdAt": NOW - 25 * MINUTE, "replies": []},
            {"id": "t-sent", "anchor": {"kind": "message", "messageId": "u1", "quote": None},
             "author": {"kind": "human", "id": "me", "name": "Léa Martin"},
             "body": "Please add a regression test for this.", "status": "sent",
             "createdAt": NOW - 3 * 60 * MINUTE,
             "replies": [{"id": "r1", "author": {"kind": "agent", "id": "agent", "displayName": "Claude"},
                          "body": "Added in auth_refresh.test.ts.", "createdAt": NOW - 2 * 60 * MINUTE}]},
            {"id": "t-done", "anchor": {"kind": "message", "messageId": "a1", "quote": None},
             "author": {"kind": "human", "id": "me", "name": "Léa Martin"},
             "body": "Looks good.", "status": "resolved", "createdAt": NOW - 26 * 60 * MINUTE, "replies": []},
        ],
        "grants": [
            {"id": "g-bo", "sessionId": "s", "grantee": {"id": "bo", "name": "Bo Lindqvist"},
             "grantedBy": {"id": "me", "name": "Léa Martin"}, "parentGrantId": None,
             "createdAt": NOW - 5 * MINUTE, "expiresAt": NOW + 25 * MINUTE, "durationMinutes": 30},
        ],
        "waits": [
            {"id": "w-ci", "state": "active", "owner": {"type": "agent", "id": "agent"}, "createdAt": NOW - 12 * MINUTE,
             "expiresAt": NOW + 6 * 60 * MINUTE, "filter": {"version": 1, "source": "github",
             "eventType": ["check_run.completed", "check_suite.completed", "workflow_run.completed"],
             "subjectType": "pull_request", "subjectId": "42"}, "deliveryPreference": {"target": {"sessionId": "s"}}},
            {"id": "w-review", "state": "active", "owner": {"type": "agent", "id": "agent"}, "createdAt": NOW - 40 * MINUTE,
             "lastMatchedAt": NOW - 8 * MINUTE, "filter": {"version": 1, "source": "github",
             "eventType": "pull_request_review.submitted", "subjectType": "pull_request", "subjectId": "42"},
             "deliveryPreference": {"target": {"sessionId": "s"}}},
            {"id": "w-relay", "state": "active", "owner": {"type": "agent", "id": "agent"}, "createdAt": NOW - 50 * MINUTE,
             "filter": {"version": 1, "source": "sam.agent_channel", "subjectType": "agent_channel", "subjectId": "agent-dm.a.b"}},
        ],
    }


state = initial_state()

SESSION = {
    "id": "s", "topic": "Fix **login** token refresh", "status": "active", "viewerAccess": "owner",
    "isMine": True, "startedAt": NOW - 4 * 60 * MINUTE, "workspaceId": "w", "taskId": "t",
    "task": {"id": "t", "status": "failed", "errorMessage": "Tests failed: auth_refresh.test.ts",
             "outputBranch": "sam/fix-login-refresh"},
}
MESSAGES = [
    {"id": "u1", "role": "user", "content": "The login session expires after an hour. Please fix the token refresh.", "createdAt": NOW - 4 * 60 * MINUTE},
    {"id": "a1", "role": "assistant", "content": "I found the bug: the client did not retry the token refresh after a 401. I fixed it and opened PR #42.", "createdAt": NOW - 3 * 60 * MINUTE},
]


def members():
    def m(user, role, name, email):
        return {"userId": user, "role": role, "status": "active", "user": {"name": name, "email": email}}
    return {"members": [m("me", "owner", "Léa Martin", "lea@example.com"), m("bo", "admin", "Bo Lindqvist", "bo@example.com"),
                        m("ana", "maintainer", "Ana Souza", "ana@example.com"), m("kim", "maintainer", "Kim Park", "kim@example.com"),
                        m("vic", "viewer", "Vic Reader", "vic@example.com")]}


def access():
    return {"sessionId": "s", "viewerAccess": "owner", "owner": {"id": "me", "name": "Léa Martin"},
            "grants": state["grants"], "serverTime": int(time.time() * 1000)}


class API(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def record(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        body = json.loads(raw) if raw else None
        with lock:
            calls.append({"method": self.command, "path": self.path, "body": body})
        return body

    def do_GET(self):
        global state
        path = urlsplit(self.path).path
        if path == "/test/reset":
            with lock:
                calls.clear()
                state = initial_state()
            return self.reply(200, {"reset": True})
        if path == "/test/calls":
            with lock:
                return self.reply(200, {"calls": list(calls)})
        routes = {
            "/api/auth/get-session": {"user": {"id": "me", "name": "Léa Martin", "email": "lea@example.com"}},
            "/api/projects/p/sessions/s": {"session": SESSION, "messages": MESSAGES, "hasMore": False},
            "/api/notifications": {"notifications": [], "nextCursor": None},
            "/api/report-issue/config": {"enabled": True},
            "/api/projects/p/members": members(),
            "/api/projects/p/sessions/s/links": {
                "ideas": {"items": [{"ideaId": "i1", "title": "Silent session renewal", "status": "in_progress", "relations": ["works_on", "edited"]}], "total": 1, "truncated": False, "totalIsLowerBound": False},
                "files": {"items": [{"fileId": "f1", "filename": "auth-flow.md", "directory": "/specs", "relations": ["read"]}], "total": 1, "truncated": False, "totalIsLowerBound": False},
                "pullRequests": {"items": [
                    {"url": "https://github.com/example/app/pull/42", "number": 42, "source": "task_output", "state": {"state": "open", "isDraft": False, "title": "Retry token refresh after 401", "checksState": "failure", "stale": False}},
                    {"url": "https://github.com/example/app/pull/38", "number": 38, "source": "explicit_link", "state": {"state": "merged", "isDraft": False, "title": "Move auth client to fetch", "checksState": "success", "stale": False}}],
                    "total": 2, "truncated": False, "totalIsLowerBound": False}},
            "/api/projects/p/event-subscriptions": {"subscriptions": state["waits"], "hasMore": False},
            "/api/projects/p/schedules": {"schedules": [
                {"id": "sch1", "state": "pending", "dueAt": NOW + 3 * 60 * MINUTE, "reason": "Check whether CI is green again",
                 "action": {"kind": "message_session", "sessionId": "s", "prompt": "Check CI"}}], "nextCursor": None},
            "/api/projects/p/standing-watches": {"watches": [
                {"id": "wat1", "state": "active", "reason": None, "filter": {"source": "github", "eventType": "issue_comment.created"},
                 "action": {"kind": "message_session", "sessionId": "s"}, "executionCount": 2, "maxExecutions": 10}], "nextCursor": None},
            "/api/projects/p/sessions/s/comments": {"threads": state["threads"], "hasMore": False},
            "/api/projects/p/sessions/s/access": access(),
            "/api/projects/p/tasks/t": {"id": "t", "description": "Fix the login token refresh so sessions survive past one hour."},
            "/api/projects/p/agent-profiles": {"items": [{"id": "prof", "name": "Claude Code", "agentType": "claude-code"}]},
            "/api/projects/p/agent-profiles/picker": {"usage": [], "hiddenProfileIds": []},
            "/api/projects/p/cached-commands": {"commands": []},
            "/api/projects/p/sessions": {"sessions": [SESSION], "hasMore": False},
        }
        if path in routes:
            return self.reply(200, routes[path])
        return self.reply(404, {"error": "NOT_FOUND", "message": "Not in fixture"})

    def do_POST(self):
        body = self.record()
        path = urlsplit(self.path).path
        with lock:
            if path == "/api/projects/p/event-subscriptions/w-ci/cancel":
                state["waits"] = [w for w in state["waits"] if w["id"] != "w-ci"]
                return self.reply(200, {"changed": True, "idempotent": False})
            if path == "/api/projects/p/schedules":
                return self.reply(201, {"schedule": {"id": "new"}, "changed": True, "idempotent": False})
            if path == "/api/projects/p/sessions/s/comments":
                thread = {"id": "t-new", "anchor": {"kind": "message", "messageId": body["messageId"], "quote": body.get("quote")},
                          "author": {"kind": "human", "id": "me", "name": "Léa Martin"}, "body": body["body"],
                          "status": "open", "createdAt": int(time.time() * 1000), "replies": []}
                state["threads"].insert(0, thread)
                return self.reply(201, {"thread": thread, "idempotent": False})
            if path.endswith("/replies"):
                thread = next(t for t in state["threads"] if t["id"] == path.split("/")[-2])
                reply = {"id": f"r{len(calls)}", "author": {"kind": "human", "id": "me", "name": "Léa Martin"},
                         "body": body["body"], "createdAt": int(time.time() * 1000)}
                thread["replies"].append(reply)
                return self.reply(201, {"thread": thread, "reply": reply, "idempotent": False})
            for action, status in (("send", "sent"), ("resolve", "resolved"), ("reopen", "open")):
                if path.endswith("/" + action):
                    thread = next(t for t in state["threads"] if t["id"] == path.split("/")[-2])
                    thread["status"] = status
                    if action == "send" and thread["replies"]:
                        thread["replies"][-1]["sentToAgent"] = True
                    return self.reply(200, {"thread": thread, "idempotent": False})
            if path == "/api/projects/p/sessions/s/access/grants":
                grant = {"id": "g-" + body["userId"], "sessionId": "s", "grantee": {"id": body["userId"], "name": "Ana Souza"},
                         "grantedBy": {"id": "me", "name": "Léa Martin"}, "parentGrantId": None, "createdAt": int(time.time() * 1000),
                         "expiresAt": int(time.time() * 1000) + body["durationMinutes"] * MINUTE, "durationMinutes": body["durationMinutes"]}
                state["grants"].append(grant)
                return self.reply(201, {"grant": grant, "created": True, "renewed": False, "access": access()})
            if path == "/api/report-issue":
                keys = sorted((body.get("refs") or {}).keys())
                return self.reply(201, {"ideaId": "idea-123", "status": "draft", "refsAttached": bool(keys), "attachedRefKeys": keys,
                                        "message": f"Report submitted with {len(keys)} technical reference(s) attached."})
            if path == "/api/projects/p/tasks/submit":
                return self.reply(202, {"taskId": "t2", "sessionId": "s2", "branchName": "sam/retry", "status": "queued"})
        return self.reply(404, {"error": "NOT_FOUND"})

    def do_DELETE(self):
        self.record()
        path = urlsplit(self.path).path
        with lock:
            user = path.rsplit("/", 1)[-1]
            state["grants"] = [g for g in state["grants"] if g["grantee"]["id"] != user]
            return self.reply(200, {"revokedGrantIds": ["g-" + user], "cancelledDeliveryIds": [], "access": access()})


if __name__ == "__main__" and len(sys.argv) > 1 and sys.argv[1] == "--serve":
    server = ThreadingHTTPServer(("127.0.0.1", int(sys.argv[2])), API)
    pathlib.Path(sys.argv[3]).write_text(str(server.server_port))
    server.serve_forever()
