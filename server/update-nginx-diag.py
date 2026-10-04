#!/usr/bin/env python3
"""Add the two diagnostic upload routes to the api.enana.cc server block.

Exact paths only; the larger request-body limits apply to these two locations and nowhere else.
Usage: update-nginx-diag.py <current enana.cc.conf> <output file>   (then nginx -t, then a graceful reload)
"""
import pathlib,sys

ROUTES='''    # 诊断上传 (pb_hooks/enana_diag.pb.js): 摘要 <= 128k, 完整诊断压缩包 <= 9m; 只对这两个精确路径放宽请求体上限。
    location = /api/enana/v1/diag {
        limit_except POST DELETE { deny all; }
        client_max_body_size 128k;
        limit_req zone=enana_apihost burst=10 nodelay;
        expires -1;
        proxy_pass http://enana_pb;
    }
    location = /api/enana/v1/diag/full {
        limit_except POST { deny all; }
        client_max_body_size 9m;
        limit_req zone=enana_apihost burst=3 nodelay;
        expires -1;
        proxy_pass http://enana_pb;
    }
'''

def update(text):
    if 'location = /api/enana/v1/diag {' in text:
        raise ValueError('diagnostic routes already installed; review instead of overwriting')
    anchor='    # 同步快照:'
    if text.count(anchor)!=1:
        raise ValueError('unexpected sync section: expected exactly one "%s" anchor'%anchor.strip())
    return text.replace(anchor,ROUTES+anchor)

if __name__=='__main__':
    source,target=map(pathlib.Path,sys.argv[1:3])
    target.write_text(update(source.read_text()))
