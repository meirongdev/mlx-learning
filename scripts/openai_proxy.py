#!/usr/bin/env python3
"""Simple OpenAI-compatible proxy for MLX VLM server.
Forwards /v1/chat/completions -> /chat/completions and /v1/models -> /models
"""
import argparse
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
import threading
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument('--host', default='127.0.0.1')
parser.add_argument('--port', type=int, default=5101)
parser.add_argument('--mlx-base', default='http://127.0.0.1:5001')
parser.add_argument('--default-model', default='models/mlx-community__gemma-4-26b-a4b-it-4bit')
args = parser.parse_args()

MLX_BASE = args.mlx_base
DEFAULT_MODEL = args.default_model

class ProxyHandler(BaseHTTPRequestHandler):
    def _proxy_post(self, path_target):
        length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(length) if length else b''
        try:
            j = json.loads(body.decode() or '{}')
        except Exception:
            j = {}
        # ensure model field
        if 'model' not in j or not j.get('model'):
            j['model'] = DEFAULT_MODEL
        elif isinstance(j.get('model'), str) and not j['model'].startswith('models/'):
            # leave as-is; assume user supplied a valid model name or mapping
            pass
        payload = json.dumps(j).encode('utf-8')
        req = urllib.request.Request(MLX_BASE + path_target, data=payload, headers={'Content-Type':'application/json'})
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                resp = r.read()
                code = r.getcode()
                h = r.getheaders()
        except urllib.error.HTTPError as e:
            resp = e.read()
            code = e.code
            h = e.headers.items()
        self.send_response(code)
        for k,v in h:
            if k.lower() == 'transfer-encoding':
                continue
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(resp)

    def do_POST(self):
        if self.path == '/v1/chat/completions':
            return self._proxy_post('/chat/completions')
        elif self.path == '/v1/responses':
            return self._proxy_post('/responses')
        else:
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b'Not Found')

    def do_GET(self):
        if self.path == '/v1/models':
            # call MLX /models
            req = urllib.request.Request(MLX_BASE + '/models')
            try:
                with urllib.request.urlopen(req, timeout=30) as r:
                    data = json.load(r)
            except Exception:
                data = {'object': 'list', 'data': []}
            # convert to OpenAI-style list
            out = {'object':'list', 'data': []}
            # if MLX returns list-like under data, try to map
            if isinstance(data, dict) and 'data' in data:
                items = data['data']
            elif isinstance(data, list):
                items = data
            else:
                items = []
            for item in items:
                name = item.get('id') if isinstance(item, dict) and item.get('id') else (item if isinstance(item, str) else None)
                if not name:
                    continue
                out['data'].append({'id': name, 'object': 'model'})
            self.send_response(200)
            self.send_header('Content-Type','application/json')
            self.end_headers()
            self.wfile.write(json.dumps(out).encode())
            return
        self.send_response(404)
        self.end_headers()
        self.wfile.write(b'Not Found')

    def log_message(self, format, *args):
        # reduce noise
        return

if __name__ == '__main__':
    server = HTTPServer((args.host, args.port), ProxyHandler)
    print(f'OpenAI-compat proxy listening on http://{args.host}:{args.port} -> MLX {MLX_BASE}')
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()
