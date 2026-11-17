"""Offline API fixture. Contains no live credentials or workspace data."""
import json
import pathlib
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

public = False
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def reply(self, body, status=200):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def authorized(self):
        if self.headers.get('Cookie') == 'fixture=ports': return True
        self.reply({'error':'Unauthorized'},401)
        return False
    def do_GET(self):
        if not self.authorized(): return
        if self.path == '/api/workspaces/demo':
            self.reply({'portsPublicEnabled':public})
        elif self.path == '/api/workspaces/demo/ports':
            self.reply({'ports':[
                {'port':3000,'label':'Web app','url':'https://ws-demo--3000.localhost/'},
                {'port':8080,'label':'API server','url':'https://ws-demo--8080.localhost/'}]})
        elif self.path.startswith('/api/workspaces/demo/port-access?port='):
            port = int(self.path.split('=')[-1])
            self.reply({'url':f'https://ws-demo--{port}.localhost/?port_token=fixture-only'})
        else: self.reply({},404)
    def do_PATCH(self):
        global public
        if not self.authorized(): return
        if self.path != '/api/workspaces/demo/ports-public': return self.reply({},404)
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        public = body['enabled']
        self.reply({'portsPublicEnabled':public})
if __name__ == '__main__' and len(sys.argv) > 1 and sys.argv[1] == '--serve':
    server = ThreadingHTTPServer(('127.0.0.1', int(sys.argv[2])), Handler)
    pathlib.Path(sys.argv[3]).write_text(str(server.server_port))
    server.serve_forever()
