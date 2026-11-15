import json,time,sys
from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def do_GET(self):
  if self.path=='/api/projects':
   body={'projects':[{'id':'p1','name':'Project One','repository':'example/project-one','activeSessionCount':1},{'id':'p2','name':'Mobile Client','repository':'example/mobile-client','activeSessionCount':2},{'id':'p3','name':'Long project name — 日本語 — layout check','repository':'example/a-repository-with-a-long-name-that-wraps-on-a-narrow-screen','activeSessionCount':0},{'id':'p4','name':'Empty Project','repository':None,'activeSessionCount':0}]}
  elif '/sessions?' in self.path:
   body={'sessions':[{'id':'s1','topic':'First agent conversation','status':'active','startedAt':int(time.time()*1000)-120000},{'id':'s2','topic':'A long conversation title that should wrap naturally within a standard native list row','status':'sleeping','startedAt':int(time.time()*1000)-3600000},{'id':'s3','topic':'Completed work','status':'stopped','startedAt':int(time.time()*1000)-86400000}]}
  elif self.path.endswith('/agent-profiles'): body={'items':[]}
  else: body={}
  data=json.dumps(body).encode();self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
open(sys.argv[1],'w').write(str(server.server_port))
server.serve_forever()
