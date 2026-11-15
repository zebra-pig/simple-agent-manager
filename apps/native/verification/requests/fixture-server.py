import json,sys,time
from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
answered=False
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def do_GET(self):
  global answered
  if self.path=='/fixture/resolve': answered=True; body={'resolved':True}
  elif '/attention/' in self.path:
   done=answered or self.path.endswith('/older')
   body={'request':{'reason':'Continue with this approach?' if not self.path.endswith('/older') else 'An older already answered question','options':['Yes','No'],'canAnswer':not done,'resolvedAt':1234 if done else None,'resolvedAnswer':'Yes' if done else None}}
  elif self.path.startswith('/api/notifications?'):
   body={'notifications':[{'id':'n-old','projectId':'p1','sessionId':'s1','title':'Already answered question','type':'needs_input','metadata':{'attentionMarkerId':'older'}}],'nextCursor':None}
  elif self.path=='/api/projects/p1/sessions/s1':
   now=int(time.time()*1000)
   body={'session':{'id':'s1','topic':'Request card lifecycle','status':'active','viewerAccess':'owner','startedAt':now-10000},'messages':[{'id':'m1','role':'assistant','content':'The conversation stays in the transcript. Resolved request cards should disappear.','createdAt':now-10000},{'id':'m2','role':'tool','content':'','createdAt':now-9000,'toolMetadata':{'rawOutput':{'humanInputRequest':{'id':'a1','sessionId':'s1'}}}}]}
  else: body={}
  data=json.dumps(body).encode();self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
open(sys.argv[1],'w').write(str(server.server_port));server.serve_forever()
