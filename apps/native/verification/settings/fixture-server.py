import json,sys
from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def do_GET(self):
  if self.path=='/api/projects/p1': body={'id':'p1','name':'FilmKit','description':'','repository':'example/filmkit','defaultBranch':'main','repoProvider':'github'}
  elif self.path=='/api/github/installations': body=[{'id':'i1','accountName':'Example'}]
  elif self.path=='/api/config/artifacts-enabled': body={'enabled':True}
  else: body={}
  data=json.dumps(body).encode();self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
open(sys.argv[1],'w').write(str(server.server_port))
server.serve_forever()
