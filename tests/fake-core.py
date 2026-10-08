#!/usr/bin/env python3
"""A minimal fake of sing-box's Clash API for tests/exits.sh (no sing-box needed, no network).

Usage: fake-core.py <port> <state.json>
Implements only what lib/exits.sh and lib/api.sh use:
  GET  /proxies            -> {"proxies": {tag: {type, name, now, all}}}
  GET  /proxies/<tag>      -> {type, name, now, all}
  PUT  /proxies/<tag>      body {"name": "..."} -> 204; 400 {"message": ...} when the name is not an option (like the real core)
State file: {"selectors": {"PIN": {"now": "Pin-A", "all": ["Pin-A", "Pin-B"]}, "svc-chatgpt": {"now": "PIN", "all": [...]}}}
The tests edit the state file directly; it is re-read on every request. Binds to 127.0.0.1 only."""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import unquote

PORT, STATE = int(sys.argv[1]), sys.argv[2]


def load():
    with open(STATE, encoding='utf-8') as f:
        return json.load(f)


def save(s):
    with open(STATE + '.tmp', 'w', encoding='utf-8') as f:
        json.dump(s, f)
    os.replace(STATE + '.tmp', STATE)


def entry(tag, v):
    return {'type': 'Selector', 'name': tag, 'now': v['now'], 'all': v['all'], 'history': []}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, obj=None):
        # compact like the real core (Go's encoding/json): lib/exits.sh and lib/health.sh read "now":"..." with sed
        body = b'' if obj is None else json.dumps(obj, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        sel = load()['selectors']
        if self.path == '/proxies':
            self.reply(200, {'proxies': {k: entry(k, v) for k, v in sel.items()}})
        elif self.path.startswith('/proxies/'):
            tag = unquote(self.path[len('/proxies/'):].split('?')[0])
            if tag in sel:
                self.reply(200, entry(tag, sel[tag]))
            else:
                self.reply(404, {'message': 'resource not found'})
        else:
            self.reply(404, {'message': 'not found'})

    def do_PUT(self):
        n = int(self.headers.get('Content-Length') or 0)
        try:
            name = json.loads(self.rfile.read(n) or b'{}').get('name')
        except ValueError:
            return self.reply(400, {'message': 'bad body'})
        s = load()
        sel = s['selectors']
        tag = unquote(self.path[len('/proxies/'):].split('?')[0]) if self.path.startswith('/proxies/') else ''
        if tag not in sel:
            return self.reply(404, {'message': 'resource not found'})
        if name not in sel[tag]['all']:
            return self.reply(400, {'message': 'Selector update error: not found'})
        sel[tag]['now'] = name
        save(s)
        self.reply(204)


HTTPServer(('127.0.0.1', PORT), H).serve_forever()
