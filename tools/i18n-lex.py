#!/usr/bin/env python3
"""Shell 源码里的中文字符串提取器 (给 tools/i18n-verify.py 用)。

A small recursive scanner for bash source that, unlike tools/i18n-extract.py, understands
  - "...$(...  "nested" ...)..." (quotes inside command substitution inside double quotes)
  - ${var:-default} (the default word is reported as its own string)
  - $'...' / `...` / $(( )) / case-patterns inside $( )
  - bare (unquoted) words that contain CJK (v=开启, echo 无, _t 推荐 ...)
  - awk string literals inside single-quoted awk programs
Output: one line per CJK-bearing literal:  file:line<TAB>kind<TAB>msgid<TAB>ctx
  kind: sq | dq | default | bare | awk | heredoc
  msgid: what the runtime string looks like (nested expansions become *, dq escapes are resolved)
"""
import re, sys, os, glob

HAN = re.compile(r'[一-鿿　-〿＀-￯]')
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

class Str:
    __slots__ = ('off', 'kind', 'text', 'raw')
    def __init__(self, off, kind, text, raw=''):
        self.off, self.kind, self.text, self.raw = off, kind, text, raw

class Lexer:
    def __init__(self, src):
        self.s = src; self.n = len(src); self.out = []; self.warn = []
        self.lines = [0]
        for m in re.finditer('\n', src): self.lines.append(m.end())

    def line_of(self, off):
        lo, hi = 0, len(self.lines) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if self.lines[mid] <= off: lo = mid
            else: hi = mid - 1
        return lo + 1

    def rec(self, rec, off, kind, text, raw=''):
        if rec is not None and HAN.search(text): rec.append(Str(off, kind, text, raw))

    # ---------------------------------------------------------- double-quoted body
    def dq_body(self, i, end, rec, term='"'):
        """parse from i until an unescaped `term` (or index `end` if term is None). returns (next_index, normalized_text)"""
        s = self.s; buf = []; start = i
        while i < (end if end is not None else self.n):
            c = s[i]
            if term and c == term: return i + 1, ''.join(buf)
            if c == '\\' and i + 1 < self.n:
                d = s[i + 1]
                if d in '$"\\`': buf.append(d)
                elif d == '\n': pass
                else: buf.append('\\' + d)
                i += 2; continue
            if c == '$' and i + 1 < self.n:
                d = s[i + 1]
                if d == '(':
                    if s[i + 2:i + 3] == '(':
                        i = self.skip_arith(i); buf.append('*'); continue
                    i = self.cmdsub(i, rec); buf.append('*'); continue
                if d == '{':
                    i = self.brace(i, rec); buf.append('*'); continue
                if d == "'" :   # $'..' inside dq is literal $ then '
                    buf.append('$'); i += 1; continue
                if re.match(r'[A-Za-z_]', d):
                    m = re.compile(r'[A-Za-z0-9_]+').match(s, i + 1); i = m.end(); buf.append('*'); continue
                if d in '0123456789@*#?$!-': i += 2; buf.append('*'); continue
                buf.append('$'); i += 1; continue
            if c == '`':
                j = s.find('`', i + 1); j = self.n - 1 if j < 0 else j
                buf.append('*'); i = j + 1; continue
            buf.append(c); i += 1
        return i, ''.join(buf)

    def dq(self, i, rec):
        """i at the opening quote"""
        j, text = self.dq_body(i + 1, None, rec, '"')
        text = re.sub(r'\*+', '*', text)
        self.rec(rec, i, 'dq', text)
        return j

    # ---------------------------------------------------------- ${...}
    def skip_arith(self, i):
        s = self.s; depth = 0; j = i + 1
        while j < self.n:
            if s[j] == '(': depth += 1
            elif s[j] == ')':
                depth -= 1
                if depth == 0: return j + 1
            j += 1
        return self.n

    def brace(self, i, rec):
        """i at '${' -> index after matching '}'. default-words are recorded as their own strings."""
        s = self.s; j = i + 2; depth = 1; wstart = None
        m = re.compile(r'[!#]?([A-Za-z_][A-Za-z0-9_]*|[0-9]+|[@*?$!#-])(\[[^\]]*\])?').match(s, j)
        k = m.end() if m else j
        mo = re.compile(r':?[-=+?]').match(s, k)
        if mo: wstart = mo.end()
        # find the matching }
        while j < self.n:
            c = s[j]
            if c == '\\': j += 2; continue
            if c == "'":
                e = s.find("'", j + 1); j = (e if e >= 0 else self.n) + 1; continue
            if c == '"':
                j = self.dq(j, None); continue
            if c == '$' and s[j + 1:j + 2] == '(':
                j = self.skip_arith(j) if s[j + 2:j + 3] == '(' else self.cmdsub(j, None); continue
            if c == '$' and s[j + 1:j + 2] == '{':
                j = self.brace(j, None); continue
            if c == '{': depth += 1
            elif c == '}':
                depth -= 1
                if depth == 0: break
            j += 1
        end = j
        if wstart is not None and wstart < end and rec is not None:
            sub = s[wstart:end]
            if HAN.search(sub):
                _, text = self.dq_body(wstart, end, rec, None)
                text = re.sub(r'\*+', '*', text)
                self.rec(rec, wstart, 'default', text)
        return end + 1

    # ---------------------------------------------------------- $( ... )
    def cmdsub(self, i, rec):
        """i at '$(' -> index after the matching ')'"""
        j = self.code(i + 2, rec, in_sub=True)
        return j

    # ---------------------------------------------------------- generic code scanner
    def code(self, i, rec, in_sub=False):
        s = self.s; n = self.n; depth = 0; case_depth = 0
        word = []; wstart = i; prev = ' '
        def flush(at):
            nonlocal word, case_depth
            w = ''.join(word); word = []
            if w and HAN.search(w): self.rec(rec, at, 'bare', w)
            if w == 'case': case_depth += 1
            elif w == 'esac': case_depth = max(0, case_depth - 1)
            return w
        while i < n:
            c = s[i]
            # comment: '#' at word start, not part of a variable
            if c == '#' and not word and (prev in ' \t\n;(|&{' or i == 0):
                flush(i)
                while i < n and s[i] != '\n': i += 1
                continue
            if c in ' \t\n':
                flush(i)
                prev = c; i += 1; continue
            if c == '\\':
                if i + 1 < n and s[i + 1] != '\n': word.append(s[i + 1])
                i += 2; prev = 'x'; continue
            if c == "'":
                flush(i); e = s.find("'", i + 1)
                if e < 0: self.warn.append('unterminated single quote at line %d' % self.line_of(i)); return n
                raw = s[i + 1:e]
                if rec is not None and HAN.search(raw):
                    self.rec(rec, i, 'sq', raw, raw)
                    for m in re.finditer(r'"((?:[^"\\]|\\.)*)"', raw):
                        if HAN.search(m.group(1)): rec.append(Str(i + 1 + m.start(), 'awk', m.group(1)))
                i = e + 1; prev = 'x'; continue
            if c == '"':
                flush(i); i = self.dq(i, rec); prev = 'x'; continue
            if c == '$':
                d = s[i + 1:i + 2]
                if d == "'":
                    flush(i); j = i + 2; buf = []
                    while j < n and s[j] != "'":
                        if s[j] == '\\': buf.append(s[j:j + 2]); j += 2; continue
                        buf.append(s[j]); j += 1
                    self.rec(rec, i, 'sq', ''.join(buf)); i = j + 1; prev = 'x'; continue
                if d == '(':
                    flush(i); i = self.skip_arith(i) if s[i + 2:i + 3] == '(' else self.cmdsub(i, rec); prev = 'x'; continue
                if d == '{':
                    flush(i); i = self.brace(i, rec); prev = 'x'; continue
                if d and (d.isalnum() or d in '_@*#?$!-'):
                    m = re.compile(r'[A-Za-z_][A-Za-z0-9_]*|[0-9]|[@*#?$!-]').match(s, i + 1); i = m.end(); prev = 'x'; continue
                word.append('$'); i += 1; prev = '$'; continue
            if c == '`':
                flush(i); e = s.find('`', i + 1); i = (e if e >= 0 else n) + 1; prev = 'x'; continue
            if c == '(':
                flush(i); depth += 1; i += 1; prev = c; continue
            if c == ')':
                flush(i)
                if case_depth > 0 and depth == 0: i += 1; prev = c; continue     # case pattern terminator
                if depth == 0 and in_sub: return i + 1
                depth -= 1; i += 1; prev = c; continue
            if c in ';|&<>{}':
                flush(i); i += 1; prev = c; continue
            word.append(c); i += 1; prev = c
        flush(i)
        return n

def extract(path):
    src = open(path, encoding='utf-8').read()
    lx = Lexer(src); rec = []
    lx.code(0, rec, in_sub=False)
    res = []
    for st in rec:
        ln = lx.line_of(st.off)
        line = src.splitlines()[ln - 1] if ln - 1 < len(src.splitlines()) else ''
        res.append((os.path.relpath(path, ROOT), ln, st.kind, st.text, line.strip()))
    return res, lx.warn

def main():
    files = sorted(glob.glob(os.path.join(ROOT, 'lib/*.sh'))) + [os.path.join(ROOT, 'install.sh')]
    files.sort(key=lambda p: (os.path.basename(p) != 'install.sh', p))
    for f in files:
        res, warn = extract(f)
        for w in warn: print('WARN', f, w, file=sys.stderr)
        for rel, ln, kind, text, line in res:
            print('%s:%d\t%s\t%s\t%s' % (rel, ln, kind, text.replace('\n', '\\N'), line[:150]))

if __name__ == '__main__': main()
