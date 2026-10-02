#!/usr/bin/env python3
"""检查 data/i18n/en.tsv 的格式与一致性: 单个制表符 · 重复键 · 通配符 * 个数一致 · printf 的 %s 个数一致 · 空译文 · 宽泛模式压住了更具体的模式。
用法: python3 tools/i18n-check.py   (有错误时退出码 1)"""
import os, re, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
p = os.path.join(ROOT, 'data/i18n/en.tsv'); errs = []; warns = []; seen = {}; pats = []
for n, l in enumerate(open(p, encoding='utf-8'), 1):
    l = l.rstrip('\n')
    if not l or l.startswith('#'): continue
    if l.count('\t') != 1: errs.append('%d: 需要且只能有一个制表符: %r' % (n, l[:60])); continue
    zh, en = l.split('\t')
    if not zh.strip() or not en.strip(): errs.append('%d: 空的原文或译文' % n); continue
    if zh in seen: errs.append('%d: 重复的原文 (第 %d 行已有): %s' % (n, seen[zh], zh[:50]))
    seen[zh] = n
    if zh.count('*') != en.count('*'): errs.append('%d: 通配符 * 个数不一致: %s' % (n, zh[:50]))
    if zh.count('%s') != en.count('%s'): errs.append('%d: %%s 个数不一致: %s' % (n, zh[:50]))
    if zh.count('\\n') != en.count('\\n'): warns.append('%d: \\n 个数不一致: %s' % (n, zh[:50]))
    if '*' in zh: pats.append((n, zh))
for i, (n1, a) in enumerate(pats):          # 先出现的模式先匹配: 更具体的模式 (b) 必须排在更宽泛的 (a) 前面
    ra = '^' + '.*'.join(re.escape(x) for x in a.split('*')) + '$'
    for n2, b in pats[i + 1:]:
        if re.match(ra, b.replace('*', 'X')) and a != b: warns.append('%d: 模式压住了后面第 %d 行更具体的模式: %s  ⊃  %s' % (n1, n2, a[:40], b[:40]))
for w in warns: print('警告', w)
for e in errs: print('错误', e)
print('# %d 条译文, %d 个错误, %d 个警告' % (len(seen), len(errs), len(warns)), file=sys.stderr)
sys.exit(1 if errs else 0)
