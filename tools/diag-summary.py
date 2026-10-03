#!/usr/bin/env python3
"""enana 诊断导出文件 (docs/DIAGNOSTICS.md) 的解读脚本: 把一个导出文件整理成一份「发生了什么」的摘要。
用法:  python3 tools/diag-summary.py enana-diagnostics-20261003-101500.txt [--app "Google Chrome"] [--host google.com]
输出: 环境 / 策略 / 每个应用的走向 (直连 vs 代理 + 直连原因) / 失败最多的网站 / 策略变化时间线 (操作记录) / 自检结果 / 自动给出的几条判断。
只用标准库, 不联网。"""
import sys, re, collections, argparse

def sections(text):
    """-> (headers {key: value}, {name: (format, [lines])})"""
    hdr, secs, cur = {}, {}, None
    for line in text.splitlines():
        if line.startswith('#'):
            m = re.match(r'#([A-Za-z-]+)[ =](.*)', line)
            if m: hdr[m.group(1)] = m.group(2)
        elif line.startswith('@@SECTION '):
            m = re.match(r'@@SECTION (\S+) format=(\S+)', line)
            cur = m.group(1); secs[cur] = (m.group(2), [])
        elif line.startswith('@@END'):
            cur = None
        elif cur is not None:
            secs[cur][1].append(line)
    return hdr, secs

def kv(lines):
    d = {}
    for l in lines:
        if '=' in l and not l.startswith('---'):
            k, v = l.split('=', 1); d[k] = v
    return d

def tsv(lines):
    if not lines: return []
    cols = lines[0].split('\t')
    out = []
    for l in lines[1:]:
        f = l.split('\t')
        if len(f) < len(cols): f += [''] * (len(cols) - len(f))
        out.append(dict(zip(cols, f)))
    return out

POISON_HINT = re.compile(r'(google|gstatic|youtube|ytimg|googleapis|gmail|ggpht|googleusercontent|chatgpt|openai|claude|anthropic)')
GOOGLE_NETS = ('142.250.', '142.251.', '172.217.', '216.58.', '74.125.', '64.233.', '108.177.', '209.85.', '173.194.', '172.253.', '2404:6800', '2607:f8b0')

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('file'); ap.add_argument('--app'); ap.add_argument('--host')
    a = ap.parse_args()
    text = open(a.file, encoding='utf-8', errors='replace').read()
    hdr, secs = sections(text)
    if not text.startswith('#ENANA-DIAGNOSTICS'):
        print('这不是 enana 诊断导出文件 (第一行应该是 #ENANA-DIAGNOSTICS)'); sys.exit(2)
    meta = kv(secs.get('meta', ('', []))[1]); env = kv(secs.get('env', ('', []))[1])
    print('== 概览'); print(' ', hdr.get('generated', ''), '|', hdr.get('range', ''))
    print('  版本 %s · 核心 %s · %s %s · 语言 %s' % (meta.get('version'), meta.get('core'), meta.get('os'), meta.get('arch'), meta.get('lang')))
    print('  代理总开关 %s · 模式 %s (核心 %s) · 服务器 %s (固定出口 %s / 自动线路 %s)' % (meta.get('proxy.enabled'), meta.get('proxy.mode'), meta.get('clash.mode'), meta.get('servers.total'), meta.get('servers.pin'), meta.get('servers.auto')))
    print('  设置: 操作记录 %s · 网站访问 %s · 核心日志 %s · 保留 %s 小时 · 自动识别 %s' % (meta.get('settings.log_ops'), meta.get('settings.access_log'), meta.get('settings.log_core'), meta.get('settings.log_hours'), meta.get('settings.auto_sites')))
    if env:
        print('  系统代理指向 enana: %s · 配置校验: %s · 端口占用: %s' % (env.get('sysproxy.points_to_enana'), env.get('config.check'), ', '.join('%s=%s' % (k[7:], v) for k, v in env.items() if k.startswith('listen.'))))
        if env.get('other_proxy_software'): print('  !! 检测到其它代理软件:', env['other_proxy_software'])
    capture = meta.get('capture.mode', env.get('capture.mode', 'unknown (old export)'))
    print('  流量接管: %s · TUN configured=%s ready=%s' % (capture, env.get('capture.tun.configured', '?'), env.get('capture.tun.ready', '?')))
    evidence = [line for line in secs.get('env', ('', []))[1] if '\tbypass-system-proxy\t' in line or '\ttun-unobserved\t' in line]
    if evidence:
        print('  OS socket 独立证据 (采样时刻, 非历史请求归因):')
        for line in evidence[:20]: print('   ', line)
    else:
        print('  没有绕过代理的 socket 证据; 不能据此证明应用全部请求进入核心。')
    # ---- 自检
    pr = tsv(secs.get('probes', ('', []))[1])
    if pr:
        print('\n== 实时自检 (经过代理 vs 直连)')
        for r in pr: print('  %-12s %-7s http=%-4s %5sms  %s %s' % (r['probe'], r['via'], r['http'], r['total_ms'], r['remote_ip'], r['note']))
    # ---- 策略
    pol = secs.get('policy', ('', []))[1]
    sel = [l for l in pol if l.startswith('selector ')]
    if sel:
        print('\n== 选择器当前状态')
        for l in sel:
            m = re.match(r'selector tag=(\S+) type=(\S+) now=(.*) members=(\d+)', l)
            if m and (m.group(1) in ('Final', 'Global', 'PIN', 'PINAUTO', 'AUTO') or m.group(1).startswith('svc-')): print('  %-22s -> %s' % (m.group(1), m.group(3)))
    ov = [l for l in pol if re.match(r'^(site|app)\|', l)]
    if ov:
        print('\n== 你的覆盖 (网站 / 应用: 名称|状态|标记|出口)'); [print('  ' + l) for l in ov[:40]]
    # ---- 访问记录
    acc = tsv(secs.get('access', ('', []))[1])
    if acc:
        print('\n== 访问记录: %d 条连接' % len(acc))
        by = collections.defaultdict(collections.Counter)
        for r in acc: by[r['app'] or '?'][(r['route'], r['reason'] or '-', r['result'])] += 1
        for app, c in sorted(by.items(), key=lambda x: -sum(x[1].values()))[:12]:
            tot = sum(c.values()); bad = sum(n for (rt, rs, rsl), n in c.items() if rsl == 'error')
            print('  %-30s %5d 条 失败 %-4d %s' % (app[:30], tot, bad, ' '.join('%s/%s×%d' % (rt, rs, n) for (rt, rs, rsl), n in c.most_common(4))))
        errs = collections.Counter((r['host'], r['err'], r['node']) for r in acc if r['result'] == 'error')
        if errs:
            print('\n  失败最多的网站 (主机 失败类型 出口 次数):')
            for (h, e, n), c in errs.most_common(10): print('   %-42s %-9s %-14s ×%d' % (h[:42], e, n[:14], c))
        # 疑似 DNS 污染: Google 系域名解析到非 Google 网段
        sus = collections.Counter()
        for r in acc:
            if r['ips'] and POISON_HINT.search(r['host']) and not any(ip.startswith(GOOGLE_NETS) for ip in r['ips'].split()): sus[(r['host'], r['ips'].split()[0])] += 1
        if sus:
            print('\n  疑似 DNS 污染 (这些域名解析到了不是它自己的地址, 说明走了本地 DNS 又没走代理):')
            for (h, ip), c in sus.most_common(6): print('   %-42s -> %s ×%d' % (h[:42], ip, c))
        # 每个应用的走向变化: 5 分钟一格, 直连占比从 <30% 跳到 >70% 就报
        flips = []
        for app, _ in by.items():
            buckets = collections.defaultdict(lambda: [0, 0])
            for r in acc:
                if (r['app'] or '?') != app or r['route'] == 'none': continue
                buckets[r['ts'][:15]][0 if r['route'] == 'direct' else 1] += 1
            seq = [(k, v[0] / max(1, v[0] + v[1])) for k, v in sorted(buckets.items()) if v[0] + v[1] >= 3]
            for (k1, f1), (k2, f2) in zip(seq, seq[1:]):
                if f1 < 0.3 and f2 > 0.7: flips.append((app, k2 + '0', 'proxied → direct'))
                if f1 > 0.7 and f2 < 0.3: flips.append((app, k2 + '0', 'direct → proxied'))
        if flips:
            print('\n  走向突变 (5 分钟为一格):')
            for app, k, d in flips[:8]: print('   %s  %s  %s' % (k, app, d))
        if a.app or a.host:
            print('\n  筛选 app=%s host=%s 的记录 (最近 30 条):' % (a.app, a.host))
            for r in [r for r in acc if (not a.app or r['app'] == a.app) and (not a.host or a.host in r['host'])][-30:]:
                print('   %s %-34s %-8s %-14s %-7s %s %s' % (r['ts'][11:], r['host'][:34], r['route'], r['node'][:14], r['reason'], r['err'], r['ips'][:30]))
    # ---- 操作记录: 策略变化时间线
    ops = tsv(secs.get('ops', ('', []))[1])
    if ops:
        key = re.compile(r'策略|应用|代理|模式|设置|服务器|订阅|自动识别|导入|DNS|规则|重启|核心|更新|登录|退出|新应用')
        tl = [o for o in ops if key.search(o['action'])]
        print('\n== 操作记录: %d 条, 其中和路由 / 策略有关的 %d 条 (时间线)' % (len(ops), len(tl)))
        for o in tl[-40:]: print('  %s %-9s %-26s %s %s' % (o['ts'][5:], o['who'], o['action'][:26], o['detail'][:110], '' if o['result'] == 'ok' else '[失败]'))
    # ---- 自动判断
    print('\n== 自动判断')
    notes = []
    if meta.get('proxy.enabled') == '0': notes.append('代理总开关是关闭的: 所有连接都按 direct-mode 直连。')
    if capture != 'tun' and env.get('sysproxy.points_to_enana') == 'no': notes.append('系统代理没有指向 enana: 遵守系统代理且没有其他代理入口的连接可能不进入核心。')
    if env.get('config.check', 'ok') != 'ok': notes.append('配置没有通过 sing-box check: ' + env['config.check'])
    if acc:
        dapp = collections.Counter(r['app'] for r in acc if r['reason'] == 'app')
        for app, c in dapp.most_common(3): notes.append('应用「%s」被设为直连 (关): %d 条连接因此没有走代理。' % (app, c))
        tm = [r for r in acc if r['result'] == 'error' and r['route'] == 'direct']
        if tm: notes.append('有 %d 条直连连接失败 (%s): 这些网站需要走代理, 或者检查为什么被判成直连。' % (len(tm), ', '.join('%s×%d' % (k, v) for k, v in collections.Counter(r['reason'] or 'policy' for r in tm).most_common(3))))
    if pr:
        d = {(r['probe'], r['via']): r for r in pr}
        if d.get(('google_page', 'proxy'), {}).get('http') == '000': notes.append('经过代理访问 google 失败: 检查服务器 / 节点 (见 selector 状态和代理日志)。')
    print('\n'.join('  - ' + n for n in notes) if notes else '  (没有发现明显问题: 看上面的时间线)')

if __name__ == '__main__':
    main()
