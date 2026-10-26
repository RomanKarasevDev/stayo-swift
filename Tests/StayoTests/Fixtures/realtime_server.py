"""Loopback-only real WebSocket fixture; no credentials or third-party dependencies."""
import base64
import hashlib
import http.server
import json
import socket
import socketserver
import struct
import time

class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    connections = 0
    tokens = 0
    ready = 0
    leaks = 0

def receive(stream):
    first, second = stream.read(2)
    length = second & 127
    if length == 126:
        length = struct.unpack('!H', stream.read(2))[0]
    elif length == 127:
        length = struct.unpack('!Q', stream.read(8))[0]
    mask = stream.read(4) if second & 128 else b''
    data = stream.read(length)
    if mask:
        data = bytes(value ^ mask[index % 4] for index, value in enumerate(data))
    return json.loads(data) if first & 15 == 1 else None

def send(stream, message):
    data = json.dumps(message).encode()
    header = bytes([129, len(data)]) if len(data) < 126 else bytes([129, 126]) + struct.pack('!H', len(data))
    stream.write(header + data)
    stream.flush()

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args):
        pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', 0)))
        data = json.dumps(dict(access_token='token-refreshed' if 'refresh_token' in self.path else 'token-first', refresh_token='refresh', expires_in=3600)).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def do_GET(self):
        if self.path == '/rest/v1/redirect':
            self.send_response(302); self.send_header('Location', 'http://localhost:%s/leak' % self.server.server_port)
            self.send_header('Content-Length', '0'); self.end_headers(); return
        if self.path == '/leak':
            self.server.leaks += 1
            self.send_response(200); self.send_header('Content-Length', '2'); self.end_headers(); self.wfile.write(b'{}'); return
        if self.path == '/stats':
            data = json.dumps(dict(connections=self.server.connections, tokens=self.server.tokens, leaks=self.server.leaks, ready=self.server.ready)).encode()
            self.send_response(200); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data); return
        if not self.path.startswith('/realtime/v1/websocket?'):
            self.send_error(404); return
        self.server.connections += 1
        count = self.server.connections
        key = self.headers['Sec-WebSocket-Key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
        self.send_response(101)
        self.send_header('Upgrade', 'websocket'); self.send_header('Connection', 'Upgrade')
        self.send_header('Sec-WebSocket-Accept', base64.b64encode(hashlib.sha1(key.encode()).digest()).decode())
        self.end_headers()
        self.connection.settimeout(5)
        try:
            join = receive(self.rfile)
            assert [item['event'] for item in join['payload']['config']['postgres_changes']] == ['INSERT', 'UPDATE']
            def message(event, payload, reference=None):
                return dict(topic=join['topic'], event=event, payload=payload, ref=reference, join_ref=join['ref'])
            if count == 1:
                send(self.wfile, message('phx_reply', {'status':'ok','response':{}}, join['ref']))
                time.sleep(0.15)  # Simulate ACK arriving before WAL subscription readiness.
                self.server.ready += 1
                send(self.wfile, message('system', {'extension':'postgres_changes','status':'ok'}))
            else:
                self.server.ready += 1
                send(self.wfile, message('system', {'extension':'postgres_changes','status':'ok'}))
                time.sleep(0.15)  # Both message orderings must be supported.
                send(self.wfile, message('phx_reply', {'status':'ok','response':{}}, join['ref']))
            for kind in ['INSERT', 'UPDATE', 'DELETE']:
                send(self.wfile, message('postgres_changes', {'data':dict(type=kind, schema='public', table='notes', record={'id':count}, old_record={})}))
            if count == 1:
                self.connection.shutdown(socket.SHUT_RDWR)
            else:
                while True:
                    event = receive(self.rfile)
                    if event is None: break
                    if event['event'] == 'access_token': self.server.tokens += 1
                    if event['event'] == 'heartbeat':
                        send(self.wfile, dict(topic='phoenix', event='phx_reply', payload={'status':'ok'}, ref=event['ref']))
        except (OSError, ValueError, AssertionError, TypeError):
            pass
        self.close_connection = True

server = Server(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
