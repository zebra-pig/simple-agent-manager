"""Loopback-only delayed SAM responses for native loading verification."""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        time.sleep(3)
        if self.path == '/api/github/installations':
            body = [{'id': 'fixture', 'accountName': 'Example account'}]
        elif self.path == '/api/config/artifacts-enabled':
            body = {'enabled': True}
        elif self.path.endswith('/resource-timeline'):
            body = {'collection': 'collected', 'omittedChunkCount': 0, 'chunks': [{
                'workspaceId': 'fixture', 'rollup': {
                    'start': [1000, 61000, 121000], 'cpuMeanCores': [.25, .5, .35],
                    'memoryMeanBytes': [1048576, 2097152, 3145728],
                    'ioReadBytes': [0, 5, 8], 'ioWriteBytes': [0, 9, 12]}}]}
        else:
            body = {}
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
with open(sys.argv[1], 'w') as port:
    port.write(str(server.server_port))
server.serve_forever()
