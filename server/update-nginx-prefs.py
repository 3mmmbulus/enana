#!/usr/bin/env python3
"""Add the preferences route (GET / PUT /api/enana/v1/prefs) to the api.enana.cc server block.

Exact path only, GET and PUT only, request body limit 24k (the preferences JSON is at most 16 KB).
Usage: update-nginx-prefs.py <current enana.cc.conf> <output file>   (then nginx -t, then a graceful reload)
"""
import pathlib,sys

ROUTE='''    # 偏好设置 (pb_hooks/enana_v1.pb.js): 只允许 GET / PUT 这一个精确路径; 请求体上限 24k (偏好 JSON <= 16 KB)。
    location = /api/enana/v1/prefs {
        limit_except GET PUT { deny all; }
        client_max_body_size 24k;
        limit_req zone=enana_apihost burst=10 nodelay;
        expires -1;
        proxy_pass http://enana_pb;
    }
'''

def update(text):
    if 'location = /api/enana/v1/prefs {' in text:
        raise ValueError('preferences route already installed; review instead of overwriting')
    anchor='    # 同步快照:'
    if text.count(anchor)!=1:
        raise ValueError('unexpected sync section: expected exactly one "%s" anchor'%anchor.strip())
    return text.replace(anchor,ROUTE+anchor)

if __name__=='__main__':
    source,target=map(pathlib.Path,sys.argv[1:3])
    target.write_text(update(source.read_text()))
