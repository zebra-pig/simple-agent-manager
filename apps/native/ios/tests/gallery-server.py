"""Offline, paginated chat with user uploads and library images. No live data."""
import json
import struct
import subprocess
import sys
import threading
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs


def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))


def png(number):
    row = bytes([number * 25, 120, 220 - number * 20]) * 240
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 240, 160, 8, 2, 0, 0, 0))
            + chunk(b'sRGB', b'\x00') + chunk(b'IDAT', zlib.compress((b'\x00' + row) * 160)) + chunk(b'IEND', b''))


def library(number):
    return {'id': str(number * 10), 'role': 'tool', 'createdAt': number * 10,
            'toolMetadata': {'toolName': 'display_from_library', 'toolCallId': str(number),
                             'rawOutput': {'fileId': str(number), 'filename': f'{number}.png', 'mimeType': 'image/png'}}}


def uploads(first, last):
    content = 'Review images\n\n## Attached Files\n\nThe following files have been uploaded to the workspace:\n'
    content += '\n'.join(f'- `/workspaces/.private/{n:026d}/{n}.png` (100 bytes, image/png)' for n in range(first, last + 1))
    content += '\n\nThese are absolute paths inside your workspace container, outside the repository. Open the exact paths listed above to read the attachments; do not look for them relative to the repository.'
    return {'id': str(first * 10), 'role': 'user', 'createdAt': first * 10, 'content': content}


history_reads = []
history_completed = []
mode = 'normal'
gates = {70: threading.Event(), 40: threading.Event()}
for gate in gates.values():
    gate.set()
class API(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        global mode
        url = urlsplit(self.path)
        status, body, mime = 200, {}, 'application/json'
        if url.path == '/test/reset':
            mode = parse_qs(url.query).get('mode', ['normal'])[0]
            history_reads.clear()
            history_completed.clear()
            for gate in gates.values():
                if mode == 'held': gate.clear()
                else: gate.set()
        elif url.path == '/test/release':
            query = parse_qs(url.query)
            gate = gates[int(query['before'][0])]
            delay = float(query.get('delay', ['0'])[0])
            if delay: threading.Timer(delay, gate.set).start()
            else: gate.set()
        elif url.path == '/test/stats':
            body = {'reads': history_reads, 'completed': history_completed}
        elif url.path == '/api/projects/p/sessions/s':
            before = parse_qs(url.query).get('before')
            if not before:
                rows, more = ([uploads(7, 8)] if mode == 'held' else [uploads(7, 8), library(9)]), True
            else:
                history_reads.append(before[0])
                position = json.loads(before[0])[0]
                if position in gates:
                    gates[position].wait(timeout=30)
                time.sleep(0.2)
                # Cursor includes the timestamp and row ID. Middle page starts at 40.
                if json.loads(before[0])[0] == 70:
                    rows, more = [uploads(4, 4), library(5), library(6)], True
                else:
                    rows, more = [library(1), uploads(2, 3)], False
                history_completed.append(before[0])
            body = {'session': {'id': 's', 'status': 'stopped', 'startedAt': 1}, 'messages': rows, 'hasMore': more}
        elif '/library/' in url.path or '/tasks/uploads/' in url.path:
            number = int(url.path.split('/')[-2] if '/library/' in url.path else url.path.split('/uploads/')[1].split('/')[0])
            if number == 6:
                status = 404
            else:
                body, mime = png(number), 'image/png'
        elif url.path == '/api/notifications':
            body = {'notifications': [], 'nextCursor': None}
        elif url.path == '/api/report-issue/config':
            body = {'enabled': False}
        else:
            status = 404
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(status)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if len(sys.argv) > 1 and sys.argv[1] == '--serve':
    ThreadingHTTPServer(('127.0.0.1', int(sys.argv[2]) if len(sys.argv) > 2 else 18875), API).serve_forever()
else:
    server = ThreadingHTTPServer(('127.0.0.1', 0), API)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        subprocess.run([sys.argv[1], f'http://127.0.0.1:{server.server_port}', sys.argv[2]], check=True)
        assert len(history_reads) == 2, history_reads
    finally:
        server.shutdown()
        server.server_close()
