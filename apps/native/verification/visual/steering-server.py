"""Offline API for the production ChatView simulator fixture. No credentials."""
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

class API(BaseHTTPRequestHandler):
    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def do_GET(self):
        if self.path == '/api/projects/fixture/sessions/chat':
            mode = Path('/tmp/sam-steering-mode').read_text().strip()
            self.reply(200, {
                'session': {'id':'chat', 'topic':'Polish the project dashboard', 'status':'active', 'isMine':True, 'isIdle':False, 'startedAt':1},
                'state': {'activity':'prompting', 'steeringSupported':mode != 'unsupported'},
                'messages':[
                    {'id':'1', 'role':'user', 'content':'Make the project dashboard easier to scan. Keep the layout calm and focused.', 'createdAt':1},
                    {'id':'2', 'role':'assistant', 'content':'I’ll simplify the project cards and bring the active tasks into focus. I’m checking the existing layout first.', 'createdAt':2},
                    {'id':'3', 'role':'user', 'content':'Keep the current colors. Focus on spacing and hierarchy.', 'createdAt':3, 'toolMetadata':{'deliveryIntent':'steer','steerOutcome':'steered'}},
                    {'id':'4', 'role':'assistant', 'content':'Understood — I’ll keep the palette and adjust the spacing. The active task will stay at the top.', 'createdAt':4},
                    {'id':'5', 'role':'tool', 'content':'', 'createdAt':5, 'toolMetadata':{'toolCallId':'layout','title':'Updating the dashboard layout','kind':'edit','status':'in_progress'}}]})
        elif 'notifications' in self.path: self.reply(200, {'notifications':[]})
        else: self.reply(404, {'message':'Offline fixture'})
    def do_POST(self):
        if self.path.endswith('/cancel'):
            mode = Path('/tmp/sam-steering-mode').read_text().strip()
            if mode == 'interrupting': time.sleep(30)
            self.reply(503 if mode == 'error' else 200, {'message':'Couldn’t interrupt the agent. Try again.'} if mode == 'error' else {})
        else: self.reply(202, {})

ThreadingHTTPServer(('127.0.0.1',18973), API).serve_forever()
