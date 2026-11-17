"""Finite fault injection for the isolated P2.1 ES index, never the course index."""
import json
import sys
import time
import threading
import socketserver
from datetime import datetime, timezone
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit
import requests

ROOT = Path(sys.argv[1]).resolve()
CONTROL = ROOT / 'config/es-faults.json'
LOG = ROOT / 'logs/es-fault-proxy.jsonl'
INDEX = 'p21_20261108_r01'
COUNTS = {}
LOCK = threading.Lock()

def record(value):
    value['utc'] = datetime.now(timezone.utc).isoformat()
    with LOCK:
        with LOG.open('a', encoding='utf-8') as f:
            f.write(json.dumps(value, ensure_ascii=True) + '\n')

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args): pass
    def handle_request(self):
        path = urlsplit(self.path).path
        if not (path == '/' or path.startswith('/' + INDEX + '/')):
            self.send_error(403, 'isolated P2.1 index only')
            return
        data = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        article_id = path.rsplit('/', 1)[-1]
        is_index = self.command in ('PUT','POST') and '/_doc/' in path
        with LOCK:
            if is_index: COUNTS[article_id] = COUNTS.get(article_id, 0) + 1
            n = COUNTS.get(article_id, 0)
        rules = json.loads(CONTROL.read_text(encoding='utf-8')) if CONTROL.exists() else {}
        rule = rules.get(article_id, {})
        if is_index and (rule.get('always_fail') or n <= rule.get('fail_first',0)):
            status = rule.get('status',503)
            body = json.dumps({'error':{'type':'unavailable_shards_exception','reason':'P2.1 controlled fault'},'status':status}).encode()
            record({'id':article_id,'attempt':n,'result':'injected','status':status})
        else:
            session = requests.Session(); session.trust_env=False
            try:
                headers={k:v for k,v in self.headers.items() if k.lower() not in ('host','content-length','connection','transfer-encoding','accept-encoding')}
                response=session.request(self.command,'http://192.168.200.130:9200'+self.path,data=data,headers=headers,timeout=(3,8))
                status,body=response.status_code,response.content
                if is_index:
                    record({'id':article_id,'attempt':n,'result':'forwarded','status':status,'response':response.json()})
                    if rule.get('hold_after_write'):
                        record({'id':article_id,'attempt':n,'result':'holding_after_write'})
                        deadline=time.time()+50
                        while time.time()<deadline:
                            current=json.loads(CONTROL.read_text(encoding='utf-8'))
                            if not current.get(article_id,{}).get('hold_after_write'):break
                            time.sleep(.2)
            except Exception as e:
                status=502; body=json.dumps({'error':{'type':'proxy_exception','reason':type(e).__name__},'status':502}).encode()
                record({'id':article_id,'attempt':n,'result':'proxy_error','type':type(e).__name__})
            finally: session.close()
        try:
            self.send_response(status)
            self.send_header('Content-Type','application/json; charset=UTF-8')
            self.send_header('Content-Length',str(len(body)))
            self.end_headers(); self.wfile.write(body)
        except (BrokenPipeError,ConnectionResetError,ConnectionAbortedError):
            record({'id':article_id,'attempt':n,'result':'client_disconnected'})
    do_GET=do_PUT=do_POST=do_DELETE=do_HEAD=handle_request

class LocalServer(ThreadingHTTPServer):
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name = '127.0.0.1'
        self.server_port = self.server_address[1]

server=LocalServer(('127.0.0.1',19201),Handler)
record({'result':'proxy_started','port':19201,'index':INDEX})
server.serve_forever()
