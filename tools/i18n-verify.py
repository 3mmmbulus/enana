#!/usr/bin/env python3
"""检查 data/i18n/en.tsv 是否覆盖了源码里所有会显示给用户的中文提示 (并用真实的 awk 引擎逐条试译)。
用法: python3 tools/i18n-verify.py [--engine]
(independent of tools/i18n-ignore.txt on purpose: the skip rules below are the *semantic* ones - what is not a message)
"""
import re, sys, os, subprocess
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import importlib.util
_spec = importlib.util.spec_from_file_location('lex', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'i18n-lex.py')); lex = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(lex)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TSV = ROOT + '/data/i18n/en.tsv'
HAN = re.compile(r'[\u4e00-\u9fff\u3000-\u303f\uff00-\uffef]')

# strings that are not messages (code, data formats, file markers, menu "key:label" option lists, job step lists)
SKIP_EXACT = {
    '准备|下载规则集|生成配置|校验配置|应用并重启|等待就绪', '检查新版本|下载并校验新版本|安装并重新生成配置|完成',
    '查询最新版本|下载并校验新核心|用新核心校验现有配置|重启服务', '准备|下载规则集|应用规则集|完成', '重启服务|等待服务就绪',
    '查询本机与各线路的出口 IP|完成', '生成配置|校验配置|应用并重启|等待就绪', '准备|测试国内 DNS|测试海外 DNS|完成', '生成快照|加密|上传', '修改系统代理|确认结果',
    '直连||\\n', '本地代理(自动选线)|http://127.0.0.1:%s|\\n',
    '# enana 快捷命令', '^# (tproxy|ereldaili|tokyo-proxy) 快捷命令$',
    'chain:GitHub 官方包(多线路+校验)', '*|local:本地安装包', 'zh:中文|en:English', 'skip:已就绪',
    '{"ok":false,"error":"日志类型无效"}',      # logs.sh: unreachable (api.sh validates the type first)
    '*: 系统代理已*',                         # os-darwin.sh: $v is 开启/关闭 (bare words); the two real sentences are in en.tsv
    '* (保留 * 里的数据)', '*, 并删除 * (含你的服务器 / 订阅配置)',   # install.sh uninstall: pieces of one confirm message
    '其他', '备用线路 %s|%s://%s:%s|%s%s%s',
    '官方-',                                      # lib/official.sh: the reserved tag prefix of official nodes (data, never shown through _t)     # awk-internal: apps group id (UI maps it) / dl-route label (see patterns)
}
SKIP_SUB = ['BEGIN {', 'function esc(', 'function str(', '($0 ~ /中文/)', '(tproxy|ereldaili|tokyo-proxy) 快捷命令',
            'if (core != 1', '--- file ', '#about=', '#privacy=', '#route-reasons=']        # logs.sh: awk 脚本 / 诊断导出文件里的说明行 (文件内容, 不是界面提示, 只用中文)
# bare (unquoted) words that ARE real msgids
BARE_OK = {'无响应', '请选择', '推荐', '开启代理', '关闭代理', '切换代理模式'}
# default-word fragments (${v:-中文}) that are passed to _t as a whole; the other defaults are parts of bigger messages
DEFAULT_OK = {'完成', 'DNS 设置无效', '* 失败: 没有可应用的更改'}
JSONV = re.compile(r'"([A-Za-z_]+)":"((?:[^"\\]|\\.)*)"')


def load():
    ex, pats = {}, []
    for l in open(TSV, encoding='utf-8'):
        l = l.rstrip('\n')
        if not l or l.startswith('#') or '\t' not in l: continue
        zh, en = l.split('\t', 1)
        if '*' in zh: pats.append(zh)
        else: ex[zh] = en
    return ex, pats


def covered(s, ex, pats):
    if s in ex: return True
    for p in pats:
        if re.match('^' + '.*'.join(re.escape(x) for x in p.split('*')) + '$', s, re.S): return True
    return False


def effective(items):
    """lexer items -> [(where, kind, msgid, line)] after dropping non-messages and splitting JSON fragments"""
    out = []
    for rel, ln, kind, text, line in items:
        w = '%s:%d' % (rel, ln)
        if text in SKIP_EXACT or any(x in text for x in SKIP_SUB):
            if '"desc":"' not in text and '\\"desc\\":\\"' not in text and '"match":"' not in text: continue
        if kind == 'default' and text not in DEFAULT_OK: continue
        if kind == 'bare':
            if text in BARE_OK: out.append((w, kind, text, line))
            continue
        if kind == 'awk' and text not in ('自定义规则集', '自定义链接') and '"desc"' not in text:
            continue
        t = text.replace('\\"', '"')
        if ('"match":"' in t or '"desc":"' in t or '"error":"' in t) and kind in ('dq', 'sq', 'awk'):
            for k, v in JSONV.findall(t):
                if HAN.search(v): out.append((w, 'json:' + k, v, line))
            continue
        if kind == 'awk': out.append((w, kind, t, line)); continue
        out.append((w, kind, text, line))
    return out


def gather():
    files = sorted(lex.glob.glob(ROOT + '/lib/*.sh')) + [ROOT + '/install.sh']
    allw = []
    for f in files:
        res, warn = lex.extract(f)
        for w in warn: print('LEXWARN', f, w)
        allw += res
    return allw


def main():
    ex, pats = load()
    eff = effective(gather())
    seen, miss = set(), []
    for w, kind, key, line in eff:
        if key in seen: continue
        seen.add(key)
        if not covered(key, ex, pats): miss.append((w, kind, key, line))
    print('effective msgids: %d distinct, uncovered by en.tsv: %d' % (len(seen), len(miss)))
    for w, kind, key, line in miss:
        print('%s\t%s\t%s\t| %s' % (w, kind, key.replace('\n', '\\N')[:170], line[:110]))
    if '--engine' in sys.argv: engine(eff)
    if '--samples' in sys.argv: samples()


def engine(eff):
    """run every effective msgid (stars -> Q1 Q2 ...) through lib/i18n.awk and flag leftovers"""
    tests = []
    for w, kind, text, line in eff:
        i = [0]
        def fill(m):
            i[0] += 1; return 'Q%d' % i[0]
        tests.append((w, kind, text, re.sub(r'\*', fill, text).replace('\n', ' '), i[0]))
    inp = '\n'.join(t[3] for t in tests) + '\n'
    out = subprocess.run(['awk', '-v', 'tbl=' + TSV, '-f', ROOT + '/lib/i18n.awk'], input=inp.encode('utf-8'), capture_output=True,
                         env=dict(os.environ, LC_ALL='C')).stdout.decode('utf-8').split('\n')
    bad = 0
    for t, o in zip(tests, out):
        w, kind, text, sample, n = t
        probs = []
        if HAN.search(o): probs.append('Chinese left in output')
        if o == sample: probs.append('unchanged')
        for k in range(1, n + 1):
            if 'Q%d' % k not in o: probs.append('capture Q%d lost' % k)
        if probs:
            bad += 1
            print('ENGINE %s [%s] %s\n    in : %s\n    out: %s' % (w, ','.join(probs), kind, sample[:150], o[:220]))
    print('engine-tested %d strings, %d suspicious' % (len(tests), bad))



def samples():
    """hand-written realistic RUNTIME strings (stars filled in with real values) -> show what the user would see"""
    sp = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'i18n-samples.txt')
    if not os.path.exists(sp): print('没有 tools/i18n-samples.txt'); return
    lines = [l.rstrip('\n') for l in open(sp, encoding='utf-8') if l.strip() and not l.startswith('#')]
    out = subprocess.run(['awk', '-v', 'tbl=' + TSV, '-f', ROOT + '/lib/i18n.awk'], input=('\n'.join(lines) + '\n').encode('utf-8'), capture_output=True,
                         env=dict(os.environ, LC_ALL='C')).stdout.decode('utf-8').split('\n')
    bad = 0
    for a, b in zip(lines, out):
        flag = '  <-- CHINESE LEFT' if HAN.search(b) else ''
        if flag: bad += 1
        print('%s\n  => %s%s' % (a, b, flag))
    print('samples: %d, with Chinese left: %d' % (len(lines), bad))


if __name__ == '__main__':
    main()
