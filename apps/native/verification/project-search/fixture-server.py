"""Offline, authenticated session pagination fixture. No external side effects."""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.headers.get('Cookie') != 'fixture=local-only':
            self.send_error(401)
            return
        if self.path == '/api/projects/p1/sessions?limit=50':
            body = {'sessions': [{'id': 'recent', 'topic': 'Fix login screen', 'status': 'active', 'startedAt': 1794828000000},
                                 {'id': 'untitled', 'topic': None, 'status': 'sleeping', 'startedAt': 1794827000000}], 'hasMore': True}
        elif self.path == '/api/projects/p1/sessions?limit=50&offset=50':
            body = {'sessions': [{'id': 'old-session', 'topic': 'Café release — 日本語', 'status': 'stopped', 'startedAt': 1794000000000}], 'hasMore': False}
        elif self.path.endswith('/agent-profiles'):
            body = {'items': []}
        else:
            body = {}
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
with open(sys.argv[1], 'w') as port_file:
    port_file.write(str(server.server_port))
server.serve_forever()
