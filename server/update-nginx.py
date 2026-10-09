#!/usr/bin/env python3
"""Add exact enana routes while retaining the existing host configuration."""
import pathlib,sys

def update(text):
    if 'location = /verify {' in text:
        raise ValueError('verification routes already installed; review instead of overwriting')
    old=r'^/(?:site\.css|site\.js|favicon\.svg|robots\.txt|sitemap\.xml|og\.jpg)$'
    new=r'^/(?:site\.css|site\.js|verify\.js|favicon\.svg|robots\.txt|sitemap\.xml|og\.jpg)$'
    assert text.count(old)==1, 'unexpected static allowlist'
    text=text.replace(old,new)
    anchor='    # ---- 安装脚本与下载'
    assert text.count(anchor)==1, 'unexpected website section'
    verify='''    # Email token stays in the fragment; only this page may connect to our API.
    location = /verify {
        rewrite ^ /verify.html break;
        expires -1;
        add_header Content-Security-Policy "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src https://api.enana.cc; base-uri 'none'; form-action 'none'; frame-ancestors 'none'" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header Referrer-Policy "no-referrer" always;
        add_header X-Frame-Options "DENY" always;
        add_header Permissions-Policy "accelerometer=(), camera=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), payment=(), usb=()" always;
    }

'''
    text=text.replace(anchor,verify+anchor)
    old='auth/login|session/heartbeat|session/logout|devices|devices/kick|plan|account/password|nodes'
    new=old+'|billing|billing/checkout|billing/order|billing/order/recheck|billing/cancel|billing/purchase|billing/auto-renew|email/status|email/send'
    assert text.count(old)==1, 'unexpected API allowlist'
    text=text.replace(old,new)
    anchor='    # 同步快照:'
    assert text.count(anchor)==1, 'unexpected sync section'
    confirm='''    location = /api/collections/users/confirm-verification {
        limit_except POST OPTIONS { deny all; }
        limit_req zone=enana_apihost burst=10 nodelay;
        expires -1;
        proxy_pass http://enana_pb;
    }
    # /api/enana/internal/billing/* remains excluded from the public allowlist.
'''
    return text.replace(anchor,confirm+anchor)

if __name__=='__main__':
    source,target=map(pathlib.Path,sys.argv[1:3])
    target.write_text(update(source.read_text()))
