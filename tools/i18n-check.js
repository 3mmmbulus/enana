#!/usr/bin/env node
/* enana · tools/i18n-check.js — 界面文案检查 (无依赖, 只用 Node 自带模块)
 *
 * 用法 (在仓库根目录):
 *   node tools/i18n-check.js [--quiet] [--json] [--dict-dir <目录>] [--root <仓库根>] [--self-test]
 *     --quiet       只输出有问题的部分 (没有问题时什么都不输出)
 *     --json        输出 JSON (给脚本用)
 *     --dict-dir    词典目录, 默认 <root>/ui/i18n (里面要有 zh.js 和 en.js)
 *     --root        仓库根目录, 默认是本文件所在目录的上一级 (源码从 <root>/ui 扫描)
 *     --self-test   跑内置的小测试 (词法分析 / 键收集 / 占位符)
 *   退出码: 0 = 前四项没有问题; 1 = 有问题; 2 = 没法检查 (词典缺失 / 格式错误 / 参数错误)
 *
 * What it checks (zh.js / en.js are evaluated in a vm sandbox that only provides window and I18N.register):
 *   Parity         zh and en define the same keys; both define lang.name
 *   Placeholders   for every key, the {placeholder} names are identical in zh and en (and across plural forms).
 *                  Exception: the count {n} may be left out of the singular forms (one / zero / two), e.g. one: "Disconnected 1 connection".
 *   CJK in code    ui/*.js (except importer.js, icons.js), ui/*.html, ui/*.css, ui/css/*.css must not contain CJK characters
 *                  (U+3400-9FFF, U+3000-303F, U+FF00-FFEF) outside comments: // ... , block comments, <!-- -->, CSS comments.
 *                  A small tokenizer understands JS strings, template literals and regex literals, so a // inside them is not a comment.
 *   Undefined keys every dictionary key the code uses must exist in BOTH dictionaries. Used keys are found in
 *                  t('k') L('k') I.t( I.L( I18N.t( I18N.L( I.rich('k') I18N.has('k') I.has('k'), t(a ? 'k1' : 'k2'),
 *                  data-i18n / data-i18n-title / data-i18n-placeholder / data-i18n-aria in HTML, and any string literal that
 *                  looks like a key (ns.name.sub) whose first segment is a namespace of the dictionaries (so keys kept in tables count).
 *                  'prefix.' + x (or a literal ending with '.') is a dynamic prefix: at least one key with that prefix must exist.
 *   Unused keys    (information only) dictionary keys nobody references. error. ops. name. txt. import.reason. are built at run
 *                  time and are listed separately.
 * Escape hatches: a comment containing "i18n-ignore" on the same line skips key detection for that line (e.g. a localStorage key
 * that happens to look like a dictionary key); string literals passed to ls/ss/localStorage get/set/del calls are skipped automatically.
 * Limits: the tokenizer decides "regex or division" from the previous token (good enough for this code base, not a full parser);
 * if it finds an unterminated string/template it prints a scanner warning. */
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const CJK_RE = /[\u3400-\u9FFF\u3000-\u303F\uFF00-\uFFEF]/;
const KEY_RE = /^[a-z][A-Za-z0-9]*(\.[A-Za-z0-9_-]+)+$/;            // a dictionary key
const PREFIX_RE = /^[a-z][A-Za-z0-9]*(\.[A-Za-z0-9_-]+)*\.$/;       // 'prefix.' -- a key that is built with +
const PLURAL = ['zero', 'one', 'two', 'few', 'many', 'other'];
const HELP_FN = ['help', 'hl', 'helpOpen'];                            // ui.help('topic') / hl('topic'): the argument is a help topic id (dictionary keys help.<topic>.*), not a key
const DYNAMIC_NS = ['error.', 'ops.', 'name.', 'txt.', 'import.reason.'];     // built at run time: not expected to be referenced literally
const INTERNAL_KEYS = ['lang.name'];                                // read by i18n.js itself (which is not scanned)
const SKIP_JS = ['importer.js', 'icons.js'];
const STORAGE_OBJ = ['ls', 'ss', 'localStorage', 'sessionStorage'];
const STORAGE_FN = ['get', 'set', 'del', 'keys', 'getItem', 'setItem', 'removeItem'];
const REGEX_AFTER = ['return', 'typeof', 'instanceof', 'in', 'of', 'new', 'delete', 'void', 'throw', 'case', 'do', 'else', 'yield', 'await'];
const USAGE = 'usage: node tools/i18n-check.js [--quiet] [--json] [--dict-dir <dir>] [--root <repo>] [--self-test]\n' +
  '  --quiet      print only the problems (nothing when there are none)\n  --json       machine-readable output\n' +
  '  --dict-dir   folder with zh.js and en.js (default <root>/ui/i18n)\n  --root       repository root (default: the parent of tools/)\n' +
  '  --self-test  run the built-in tokenizer / key-collection tests\n  exit code: 0 = clean, 1 = findings, 2 = cannot check (missing or malformed dictionary, bad arguments)\n';
const ATTR_RE = /\bdata-i18n(?:-title|-placeholder|-aria)?\s*=\s*(?:"([^"]*)"|'([^']*)')/g;

/* ================= 参数 / 退出 ================= */
function fail(msg, o) {
  if (o && o.json) process.stdout.write(JSON.stringify({ ok: false, error: msg }) + '\n');
  else process.stderr.write('i18n-check: ' + msg + '\n');
  process.exit(2);
}
function parseArgs(argv) {
  const o = { quiet: false, json: false, selfTest: false, root: path.resolve(__dirname, '..'), dictDir: '' };
  for (let i = 0; i < argv.length; i++) {
    let a = argv[i], v;
    const eq = a.indexOf('=');
    if (a.slice(0, 2) === '--' && eq > 0) { v = a.slice(eq + 1); a = a.slice(0, eq); }
    const val = () => { if (v !== undefined) return v; if (i + 1 >= argv.length) fail(a + ' needs a value', o); return argv[++i]; };
    if (a === '--quiet' || a === '-q') o.quiet = true;
    else if (a === '--json') o.json = true;
    else if (a === '--self-test') o.selfTest = true;
    else if (a === '--root') o.root = path.resolve(val());
    else if (a === '--dict-dir') o.dictDir = path.resolve(val());
    else if (a === '--help' || a === '-h') { process.stdout.write(USAGE); process.exit(0); }
    else fail('unknown option ' + a + ' (try --help)', o);
  }
  if (!o.dictDir) o.dictDir = path.join(o.root, 'ui', 'i18n');
  return o;
}

/* ================= 词典: 在 vm 沙箱里执行 zh.js / en.js ================= */
function validValue(v) {
  if (typeof v === 'string') return true;
  if (!v || typeof v !== 'object' || Array.isArray(v)) return false;
  const ks = Object.keys(v);
  return typeof v.other === 'string' && ks.every((k) => PLURAL.indexOf(k) >= 0 && typeof v[k] === 'string');
}
function loadDict(file, code, rel, o) {
  let src;
  try { src = fs.readFileSync(file, 'utf8'); } catch (e) { fail(rel + ': cannot read (' + (e.code || e.message) + '). Create it, or point --dict-dir at the folder with zh.js and en.js.', o); }
  const dict = {};
  const I18N = { register(c, d) { if (d && typeof d === 'object') Object.assign(dict[c] || (dict[c] = {}), d); } };
  const box = { I18N: I18N, console: { log() { }, warn() { }, error() { } } };
  box.window = box.self = box.globalThis = box;
  try { new vm.Script(src, { filename: file }).runInNewContext(box, { timeout: 3000 }); }
  catch (e) { const ln = /:(\d+)\n/.exec(String(e.stack)); fail(rel + ': malformed (' + String(e.message).split('\n')[0] + (ln ? ', line ' + ln[1] : '') + ')', o); }
  if (!dict[code]) fail(rel + ": malformed (it never calls I18N.register('" + code + "', {...}))", o);
  const bad = Object.keys(dict[code]).filter((k) => !validValue(dict[code][k]));
  if (bad.length) fail(rel + ': malformed (' + bad.length + ' value(s) are neither a string nor a {one, other} object: ' + bad.slice(0, 8).join(', ') + (bad.length > 8 ? ', ...' : '') + ')', o);
  return dict[code];
}
function forms(v, label) { return typeof v === 'string' ? [{ label: label, text: v }] : Object.keys(v).sort().map((k) => ({ label: label + '.' + k, text: v[k] })); }
function phSet(text) {
  const s = new Set(); let m;
  const re = /\{(\w+)\}/g;                                          // the same pattern I18N.t substitutes
  while ((m = re.exec(text))) s.add(m[1]);
  return Array.from(s).sort();
}
const phText = (a) => (a.length ? a.map((x) => '{' + x + '}').join(' ') : '(none)');

/* ================= 词法分析 (JS): 找出注释、字符串、模板、正则 ================= */
function unescape_(raw) {
  return raw.replace(/\\(?:\r\n|[\n\r])/g, '').replace(/\\(?:u([0-9a-fA-F]{4})|x([0-9a-fA-F]{2})|([\s\S]))/g, (m, u, x, c) => (u || x ? String.fromCharCode(parseInt(u || x, 16)) : ({ n: '\n', t: '\t', r: '\r' }[c] || c)));
}
/* -> {toks, comments:[{a,b}], warns:[{i,msg}]}   toks: {k:'str'|'tpl'|'re'|'id'|'num'|'p', i, v?, parts?, at?} (注释不在其中) */
function lex(src) {
  const toks = [], comments = [], warns = [], n = src.length;
  let i = 0, prev = null;
  const push = (t) => { toks.push(t); prev = t; return t; };
  // 正则还是除号: 看前一个记号 (值之后 = 除号; ) 和 ] 之后也当除号; 其它标点和 return 之类的关键字之后 = 正则)
  const regexOk = () => !prev || (prev.k === 'p' ? prev.v !== ')' && prev.v !== ']' : prev.k === 'id' && REGEX_AFTER.indexOf(prev.v) >= 0);
  const lineEnd = (a) => { const e = src.indexOf('\n', a); return e < 0 ? n : e; };
  function readRegex(s) {
    let cls = false;
    for (let j = s + 1; j < n; j++) {
      const c = src[j];
      if (c === '\n') return -1;
      if (c === '\\') j++;
      else if (c === '[') cls = true;
      else if (c === ']') cls = false;
      else if (c === '/' && !cls) { j++; while (j < n && /[a-z]/i.test(src[j])) j++; return j; }
    }
    return -1;
  }
  function readTemplate() {
    const start = i, at = toks.length, parts = [];
    let from = ++i;
    while (i < n && src[i] !== '`') {
      if (src[i] === '\\') { i += 2; continue; }
      if (src[i] === '$' && src[i + 1] === '{') { parts.push(src.slice(from, i)); push({ k: 'p', v: '${', i: i }); i += 2; run(true); from = i; continue; }
      i++;
    }
    if (i >= n) warns.push({ i: start, msg: 'unterminated template literal' });
    parts.push(src.slice(from, Math.min(i, n)));
    i = Math.min(i + 1, n);
    push({ k: 'tpl', i: start, at: at, parts: parts });
  }
  function run(inExpr) {                                            // inExpr: 模板里 ${ ... } 的内部, 遇到配对的 } 就返回
    let depth = 0;
    while (i < n) {
      const c = src[i];
      if (c === ' ' || c === '\t' || c === '\r' || c === '\n') { i++; continue; }
      if (c === '/' && src[i + 1] === '/') { const e = lineEnd(i); comments.push({ a: i, b: e }); i = e; continue; }
      if (c === '/' && src[i + 1] === '*') { let e = src.indexOf('*/', i + 2); e = e < 0 ? n : e + 2; comments.push({ a: i, b: e }); i = e; continue; }
      if (c === '"' || c === "'") {
        let j = i + 1;
        while (j < n && src[j] !== c && src[j] !== '\n') j += src[j] === '\\' ? 2 : 1;
        if (src[j] !== c) warns.push({ i: i, msg: 'unterminated string literal' });
        push({ k: 'str', i: i, v: unescape_(src.slice(i + 1, Math.min(j, n))) });
        i = Math.min(j + 1, n); continue;
      }
      if (c === '`') { readTemplate(); continue; }
      if (c === '/') {
        const e = regexOk() ? readRegex(i) : -1;
        if (e > 0) { push({ k: 're', i: i }); i = e; } else { push({ k: 'p', v: '/', i: i }); i++; }
        continue;
      }
      if (/[0-9]/.test(c) || (c === '.' && /[0-9]/.test(src[i + 1] || ''))) { let j = i + 1; while (j < n && /[\w.]/.test(src[j])) j++; push({ k: 'num', i: i }); i = j; continue; }
      if (/[A-Za-z_$]/.test(c) || c > '\x7f') { let j = i + 1; while (j < n && (/[\w$]/.test(src[j]) || src[j] > '\x7f')) j++; push({ k: 'id', i: i, v: src.slice(i, j) }); i = j; continue; }
      if (c === '{') depth++;
      else if (c === '}') { if (inExpr && depth === 0) { i++; return; } depth--; }
      push({ k: 'p', v: c, i: i }); i++;
    }
  }
  if (src.slice(0, 2) === '#!') { i = lineEnd(0); comments.push({ a: 0, b: i }); }          // 首行 #! 当作注释
  run(false);
  return { toks: toks, comments: comments, warns: warns };
}
/* 把注释 / 范围用空格盖掉 (保留换行), 长度不变, 位置不变 */
function blank(text, ranges) {
  const a = text.split('');
  ranges.forEach((r) => { for (let j = r.a; j < r.b; j++) if (a[j] !== '\n' && a[j] !== '\r') a[j] = ' '; });
  return a.join('');
}
function cssComments(src) {                                         // CSS 只有 /* */ 注释; 字符串里的 /* 不算
  const out = []; const n = src.length; let i = 0;
  while (i < n) {
    const c = src[i];
    if (c === '/' && src[i + 1] === '*') { let e = src.indexOf('*/', i + 2); e = e < 0 ? n : e + 2; out.push({ a: i, b: e }); i = e; }
    else if (c === '"' || c === "'") { i++; while (i < n && src[i] !== c && src[i] !== '\n') i += src[i] === '\\' ? 2 : 1; i++; }
    else i++;
  }
  return out;
}
function lineIndex(text) {                                          // index -> 行号 (从 1 开始)
  const starts = [0];
  for (let j = 0; j < text.length; j++) if (text[j] === '\n') starts.push(j + 1);
  return (idx) => { let lo = 0, hi = starts.length - 1; while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (starts[mid] <= idx) lo = mid; else hi = mid - 1; } return lo + 1; };
}

/* ================= 在记号流里找词典键 ================= */
/* add(kind, value, line): kind = 'key' | 'prefix'。ns: 词典里出现过的命名空间 (第一段) */
function collectKeys(toks, lineAt, ignored, ns, add) {
  const isLit = (t) => t.k === 'str' || t.k === 'tpl';
  const before = (idx, k) => toks[(toks[idx].k === 'tpl' ? toks[idx].at : idx) - k];    // 字面量之前的第 k 个记号
  const explicit = new Set();
  // 1) 显式调用的第一个参数: t('k') L('k') I.t( I.L( I18N.t( I18N.L( I.rich( I18N.has( ...; 三元表达式的两个分支也算
  for (let p = 0; p < toks.length; p++) {
    if (toks[p].k !== 'p' || toks[p].v !== '(') continue;
    const f = toks[p - 1], dot = toks[p - 2], obj = toks[p - 3];
    if (!f || f.k !== 'id') continue;
    const member = !!dot && dot.k === 'p' && dot.v === '.', viaI = member && !!obj && obj.k === 'id' && (obj.v === 'I' || obj.v === 'I18N');
    const ok = (f.v === 't' || f.v === 'L') ? (viaI || (!member && !(dot && dot.k === 'id' && dot.v === 'function'))) : ((f.v === 'has' || f.v === 'rich') && viaI);
    if (!ok) continue;
    let end = p + 1;
    for (let depth = 0; end < toks.length; end++) {                      // 第一个参数 = 到顶层逗号或配对的 ) 为止
      const t = toks[end];
      if (t.k !== 'p') continue;
      if ('([{'.indexOf(t.v) >= 0) depth++;
      else if (')]}'.indexOf(t.v) >= 0) { if (depth === 0) break; depth--; }
      else if (t.v === ',' && depth === 0) break;
    }
    const concat = toks.slice(p + 1, end).some((t) => t.k === 'p' && t.v === '+');
    for (let q = p + 1; q < end; q++) {
      if (!isLit(toks[q])) continue;
      const a = before(q, 1), b = toks[q + 1];
      // 独占一个操作数: 前面是 ( ? : || && , 后面是 ) , : || &&; 有 + 拼接时只有后面紧跟 + 的字面量 (前缀) 才算, (x || 'direct') 这类后备值不是键
      if (a && a.k === 'p' && '(?:|&'.indexOf(a.v) >= 0 && b && b.k === 'p' && (concat ? b.v === '+' : '),:|&'.indexOf(b.v) >= 0)) explicit.add(q);
    }
  }
  // 2) 每一个字符串 / 模板字面量
  toks.forEach((t, idx) => {
    if (!isLit(t)) return;
    const line = lineAt(t.i);
    if (ignored.has(line)) return;
    const dyn = t.k === 'tpl' && t.parts.length > 1, v = t.k === 'tpl' ? t.parts[0] : t.v, next = toks[idx + 1];
    const plus = !!next && next.k === 'p' && next.v === '+';
    if (explicit.has(idx)) { if (v) add(dyn || plus ? 'prefix' : 'key', v, line); return; }
    const o = before(idx, 4), fn = before(idx, 2), dot = before(idx, 3);                   // localStorage / sessionStorage 的键不是词典键
    if (o && fn && dot && o.k === 'id' && STORAGE_OBJ.indexOf(o.v) >= 0 && fn.k === 'id' && STORAGE_FN.indexOf(fn.v) >= 0 && dot.v === '.') return;
    const hp = before(idx, 1), hf = before(idx, 2);
    const hd = before(idx, 3), ho = before(idx, 4), isUiHelp = hf && hf.v === 'help' && hd && hd.k === 'p' && hd.v === '.' && ho && ho.k === 'id' && ho.v === 'ui';
    if (hp && hf && hp.k === 'p' && hp.v === '(' && hf.k === 'id' && hf.v === 'pager') return;                         // ui.pager('表格id'): 表格 id 不是词典键
    if (hp && hf && hp.k === 'p' && hp.v === ':' && hf.k === 'id' && hf.v === 'help' && !dyn && ns.has(v.split('.')[0]) && KEY_RE.test(v)) { add('either', v, line); return; }   // { help: 'x' } 属性: 要么是词典键, 要么是帮助话题 (help.x.title / help.x.what)
    if (hp && hf && hp.k === 'p' && hp.v === '(' && hf.k === 'id' && (isUiHelp || hf.v === 'hl' || hf.v === 'helpOpen')) {           // 帮助话题 id: ui.help('x') / hl('x'): 词典里必须有 help.<话题>.title 和 help.<话题>.what
      if (!dyn && /^[a-z][a-zA-Z0-9]*(\.[a-zA-Z0-9]+)*$/.test(v)) { add('key', 'help.' + v + '.title', line); add('key', 'help.' + v + '.what', line); }
      return;
    }
    if (hp && hf && hp.k === 'p' && hp.v === '(' && hf.k === 'id' && hf.v === 'help') return;   // 本地的 help('x') 包装函数: 参数不是词典键
    if (hp && hf && hp.k === 'p' && hp.v === '(' && hf.k === 'id' && (hf.v === 'get' || hf.v === 'set') && o && o.k === 'id' && o.v === 'prefs' && dot && dot.v === '.') return;   // TP.prefs.get/set('ns.key'): 偏好键, 不是词典键
    if (!ns.has(v.split('.')[0])) return;                                                   // 第一段不是词典里的命名空间: 不是键
    if (!dyn && KEY_RE.test(v)) add('key', v, line);
    else if (PREFIX_RE.test(v)) add('prefix', v, line);
  });
}

/* ================= 扫描各类文件 ================= */
function snippetOf(text, lineStartIdx, idx) {                      // 以第一个中文字符为中心, 截取一小段
  const lineEnd = text.indexOf('\n', lineStartIdx), s = text.slice(lineStartIdx, lineEnd < 0 ? text.length : lineEnd).replace(/\r$/, '');
  const at = idx - lineStartIdx, a = Math.max(0, at - 40), b = Math.min(s.length, at + 60);
  return (a > 0 ? '\u2026' : '') + s.slice(a, b).replace(/\s+/g, ' ').trim() + (b < s.length ? '\u2026' : '');
}
/* masked: 已去掉注释的文本。每一行只报一次。lineAt: 本段文本里的 index -> 文件里的行号 */
function cjkFindings(masked, lineAt, file, out) {
  const seen = new Set(); const re = new RegExp(CJK_RE.source, 'g'); let m;
  while ((m = re.exec(masked))) {
    const line = lineAt(m.index);
    if (seen.has(line)) continue;
    seen.add(line);
    const ls = masked.lastIndexOf('\n', m.index) + 1;
    out.push({ file: file, line: line, text: snippetOf(masked, ls, m.index) });
  }
}
function scanJs(text, file, base, lineAt, ctx) {                    // base: 这段文本在文件里的偏移 (内嵌 <script> 用)
  const L = lex(text), fl = (i) => lineAt(base + i);
  cjkFindings(blank(text, L.comments), (i) => fl(i), file, ctx.cjk);
  const ignored = new Set(L.comments.filter((c) => /i18n-ignore/.test(text.slice(c.a, c.b))).map((c) => fl(c.a)));
  collectKeys(L.toks, fl, ignored, ctx.ns, (kind, value, line) => ctx.use(kind, value, file, line));
  L.warns.forEach((w) => ctx.warns.push({ file: file, line: fl(w.i), msg: w.msg + ' (the scanner may be out of sync after this point)' }));
}
function scanCss(text, file, base, lineAt, ctx) { cjkFindings(blank(text, cssComments(text)), (i) => lineAt(base + i), file, ctx.cjk); }
function scanHtml(text, file, ctx) {
  const lineAt = lineIndex(text), cm = [];
  text.replace(/<!--[\s\S]*?-->/g, (m, off) => { cm.push({ a: off, b: off + m.length }); return m; });
  let s = blank(text, cm);                                          // 去掉 <!-- --> 注释
  const inner = [];
  s.replace(/<(script|style)\b([^>]*)>([\s\S]*?)<\/\1\s*>/gi, (m, tag, attrs, body, off) => {
    const a = off + m.indexOf('>') + 1;
    if (tag.toLowerCase() === 'style') scanCss(body, file, a, lineAt, ctx);
    else if (!/\bsrc\s*=/i.test(attrs) && !/\btype\s*=\s*["']?(?!text\/javascript|module|application\/javascript)/i.test(attrs)) scanJs(body, file, a, lineAt, ctx);
    else return m;
    inner.push({ a: a, b: a + body.length });
    return m;
  });
  s = blank(s, inner);                                              // 内嵌脚本 / 样式已单独处理
  cjkFindings(s, lineAt, file, ctx.cjk);
  let m; ATTR_RE.lastIndex = 0;
  while ((m = ATTR_RE.exec(s))) ctx.use('key', m[1] !== undefined ? m[1] : m[2], file, lineAt(m.index));
}

/* ================= 主流程 ================= */
function run(o) {
  const rel = (f) => path.relative(o.root, f).split(path.sep).join('/');
  const uiDir = path.join(o.root, 'ui');
  if (!fs.existsSync(uiDir)) fail('cannot find ' + rel(uiDir) + ' (use --root <repo>)', o);
  const zh = loadDict(path.join(o.dictDir, 'zh.js'), 'zh', rel(path.join(o.dictDir, 'zh.js')), o);
  const en = loadDict(path.join(o.dictDir, 'en.js'), 'en', rel(path.join(o.dictDir, 'en.js')), o);
  const zk = Object.keys(zh), ek = Object.keys(en), all = Array.from(new Set(zk.concat(ek))).sort();
  const ns = new Set(all.map((k) => k.split('.')[0]));

  // ---- 1 + 2: 词典 ----
  const parity = { missingInEn: zk.filter((k) => !(k in en)).sort(), missingInZh: ek.filter((k) => !(k in zh)).sort(), noLangName: ['zh', 'en'].filter((c) => !(('lang.name' in (c === 'zh' ? zh : en)))) };
  const placeholders = [];
  all.forEach((k) => {
    if (!(k in zh) || !(k in en)) return;
    const fl = forms(zh[k], 'zh').concat(forms(en[k], 'en')).map((f) => ({ label: f.label, ph: phSet(f.text), one: /\.(zero|one|two)$/.test(f.label) }));
    const ref = fl.filter((f) => !f.one)[0] || fl[0], names = (f, noN) => (noN ? f.ph.filter((x) => x !== 'n') : f.ph).join();
    // 「1 个」这样的单数形式可以直接写 1 / one, 不带 {n}; 其它占位符 (以及 other 形式) 必须一致
    if (fl.some((f) => names(f, f.one || ref.one) !== names(ref, f.one || ref.one))) placeholders.push({ key: k, forms: fl.map((f) => f.label + ' ' + phText(f.ph)) });
  });

  // ---- 3 + 4: 源码 ----
  const ctx = { ns: ns, cjk: [], warns: [], keys: new Map(), prefixes: new Map(), eithers: new Map() };
  ctx.use = (kind, value, file, line) => { const m = kind === 'key' ? ctx.keys : kind === 'either' ? ctx.eithers : ctx.prefixes; if (!m.has(value)) m.set(value, []); m.get(value).push({ file: file, line: line }); };
  const list = (dir, re, skip) => { try { return fs.readdirSync(dir).filter((f) => re.test(f) && (skip || []).indexOf(f) < 0).sort().map((f) => path.join(dir, f)); } catch (e) { return []; } };
  const jsFiles = list(uiDir, /\.js$/, SKIP_JS), htmlFiles = list(uiDir, /\.html$/), cssFiles = list(uiDir, /\.css$/).concat(list(path.join(uiDir, 'css'), /\.css$/));
  const read = (f) => fs.readFileSync(f, 'utf8').replace(/^\uFEFF/, '');
  jsFiles.forEach((f) => { const t = read(f); scanJs(t, rel(f), 0, lineIndex(t), ctx); });
  htmlFiles.forEach((f) => scanHtml(read(f), rel(f), ctx));
  cssFiles.forEach((f) => { const t = read(f); scanCss(t, rel(f), 0, lineIndex(t), ctx); });

  const undef = [], dynamic = [];
  ctx.keys.forEach((uses, k) => {
    const missing = ['zh', 'en'].filter((c) => !(k in (c === 'zh' ? zh : en)));
    if (missing.length) uses.forEach((u) => undef.push({ file: u.file, line: u.line, key: k, kind: 'key', missing: missing }));
  });
  ctx.eithers.forEach((uses, k) => {
    const missing = ['zh', 'en'].filter((c) => { const d = c === 'zh' ? zh : en; return !(k in d) && !(('help.' + k + '.title') in d && ('help.' + k + '.what') in d); });
    if (missing.length) uses.forEach((u) => undef.push({ file: u.file, line: u.line, key: k, kind: 'key', missing: missing }));
  });
  ctx.prefixes.forEach((uses, p) => {
    const miss = ['zh', 'en'].filter((c) => !Object.keys(c === 'zh' ? zh : en).some((k) => k.indexOf(p) === 0));
    dynamic.push({ prefix: p, keys: all.filter((k) => k.indexOf(p) === 0).length, uses: uses.map((u) => u.file + ':' + u.line) });
    if (miss.length) uses.forEach((u) => undef.push({ file: u.file, line: u.line, key: p, kind: 'prefix', missing: miss }));
  });
  const byPos = (a, b) => (a.file < b.file ? -1 : a.file > b.file ? 1 : a.line - b.line);
  undef.sort(byPos); ctx.cjk.sort(byPos);

  // ---- 5: 没人引用的键 ----
  const prefixes = Array.from(ctx.prefixes.keys());
  const unusedAll = all.filter((k) => !ctx.keys.has(k) && !ctx.eithers.has(k) && !ctx.eithers.has(k.replace(/^help\.(.+)\.(title|what|how|note|more)$/, '$1')) && INTERNAL_KEYS.indexOf(k) < 0 && !prefixes.some((p) => k.indexOf(p) === 0));
  const skippedDynamic = {}; const unused = [];
  unusedAll.forEach((k) => { const d = DYNAMIC_NS.filter((p) => k.indexOf(p) === 0)[0]; if (d) skippedDynamic[d] = (skippedDynamic[d] || 0) + 1; else unused.push(k); });

  return {
    dict: { dir: rel(o.dictDir), zh: zk.length, en: ek.length }, scanned: { js: jsFiles.length, html: htmlFiles.length, css: cssFiles.length },
    parity: parity, placeholders: placeholders, cjk: ctx.cjk, undefinedKeys: undef, unused: unused, skippedDynamic: skippedDynamic,
    dynamicPrefixes: dynamic.sort((a, b) => (a.prefix < b.prefix ? -1 : 1)), warnings: ctx.warns
  };
}

/* ================= 输出 ================= */
function wrap(items, indent, width) {
  const lines = []; let cur = '';
  items.forEach((x) => { if (cur && (indent + cur + ' ' + x).length > width) { lines.push(cur); cur = x; } else cur += (cur ? ' ' : '') + x; });
  if (cur) lines.push(cur);
  return lines.map((l) => ' '.repeat(indent) + l);
}
function report(r, o) {
  const p = r.parity, parityN = p.missingInEn.length + p.missingInZh.length + p.noLangName.length;
  const sections = [
    { name: 'Parity', n: parityN, lines: () => [].concat(
      p.noLangName.length ? ['  lang.name is missing in: ' + p.noLangName.join(', ')] : [],
      p.missingInEn.length ? ['  missing in en (' + p.missingInEn.length + '):'].concat(wrap(p.missingInEn, 4, 110)) : [],
      p.missingInZh.length ? ['  missing in zh (' + p.missingInZh.length + '):'].concat(wrap(p.missingInZh, 4, 110)) : []) },
    { name: 'Placeholders', n: r.placeholders.length, lines: () => r.placeholders.map((x) => '  ' + x.key + ': ' + x.forms.join(' | ')) },
    { name: 'CJK in code', n: r.cjk.length, lines: () => r.cjk.map((x) => '  ' + x.file + ':' + x.line + ': ' + x.text) },
    { name: 'Undefined keys', n: r.undefinedKeys.length, lines: () => r.undefinedKeys.map((x) => '  ' + x.file + ':' + x.line + ': ' + (x.kind === 'prefix' ? "no key starts with '" + x.key + "'" : x.key) + ' (missing in ' + x.missing.join(' and ') + ')') }
  ];
  const failures = sections.reduce((a, s) => a + s.n, 0), out = [];
  if (!o.quiet) out.push('i18n-check: ' + r.dict.dir + ' (zh ' + r.dict.zh + ' keys, en ' + r.dict.en + ' keys); scanned ' + r.scanned.js + ' js, ' + r.scanned.html + ' html, ' + r.scanned.css + ' css', '');
  sections.forEach((s) => {
    if (s.n) out.push(s.name + ': ' + s.n + ' finding(s)', ...s.lines());
    else if (!o.quiet) out.push(s.name + ': OK');
  });
  if (!o.quiet) {
    const skipped = Object.keys(r.skippedDynamic).map((k) => k + ' ' + r.skippedDynamic[k]).join(', ');
    out.push('', 'Unused keys (info): ' + r.unused.length + ' never referenced' + (skipped ? ' (not counted, built at run time: ' + skipped + ')' : ''));
    const groups = {};
    r.unused.forEach((k) => { const g = k.split('.')[0]; (groups[g] = groups[g] || []).push(k); });
    Object.keys(groups).sort().forEach((g) => out.push('  ' + g + ' (' + groups[g].length + '):', ...wrap(groups[g], 4, 110)));
    out.push('', 'Dynamic key prefixes (info): ' + r.dynamicPrefixes.length);
    r.dynamicPrefixes.forEach((d) => out.push('  ' + d.prefix + '  ' + d.keys + ' key(s)  e.g. ' + d.uses[0]));
    if (r.warnings.length) out.push('', 'Scanner warnings (info): ' + r.warnings.length, ...r.warnings.map((w) => '  ' + w.file + ':' + w.line + ': ' + w.msg));
  }
  if (failures) out.push('', 'FAIL: ' + failures + ' finding(s)'); else if (!o.quiet) out.push('', 'OK');
  if (out.length) process.stdout.write(out.join('\n') + '\n');
  return failures;
}

/* ================= 自测: node tools/i18n-check.js --self-test ================= */
function selfTest() {
  const assert = require('assert');
  const ns = new Set(['a', 'nav']);
  const keys = (src) => { const k = [], pre = []; const L = lex(src); collectKeys(L.toks, lineIndex(src), new Set(), ns, (kind, v) => (kind === 'key' ? k : pre).push(v)); return { k: k, pre: pre }; };
  // 1) 注释 / 字符串 / 模板 / 正则 / 除号
  let s = "var a = 'http://x 中'; // 注释 '\nvar r = /\\/\\/中/; /* 块 */ var d = x / 2 / y; var t = `//${f('a.k')} 模板`;\n";
  let c = [], L = lex(s);
  cjkFindings(blank(s, L.comments), lineIndex(s), 'x.js', c);
  assert.deepStrictEqual(c.map((x) => x.line), [1, 2], 'CJK only in code (string line 1; regex + template line 2)');
  assert.strictEqual(L.toks.filter((t) => t.k === 're').length, 1, 'x / 2 / y is a division, not a regex');
  assert.strictEqual(L.comments.length, 2);
  // 2) 键: 调用 / 三元 / 前缀 / 表格 / 不算的情况
  const r = keys("t('a.b'); L(c ? 'a.c' : 'a.d'); I18N.t('a.e.' + x); foo.t('zz.q'); TP.ls.get('a.s'); var o = {k: 'a.tbl', u: 'zz.no', w: 'example.com'}; I.rich('nav.r'); I.has(`a.${y}`); // 'a.cm'\n");
  assert.deepStrictEqual(r.k.sort(), ['a.b', 'a.c', 'a.d', 'a.tbl', 'nav.r'], JSON.stringify(r));
  assert.deepStrictEqual(r.pre.sort(), ['a.', 'a.e.'], JSON.stringify(r));
  const r2 = keys("t('a.p.' + (x || 'direct')); t(c ? 'a.x' : 'a.y.' + z); t(u || 'nav.fb');\n");
  assert.deepStrictEqual(r2.k.sort(), ['a.x', 'nav.fb'], JSON.stringify(r2));
  assert.deepStrictEqual(r2.pre.sort(), ['a.p.', 'a.y.'], JSON.stringify(r2));
  // 3) 占位符
  assert.deepStrictEqual(phSet('{n} of {total}, {n}'), ['n', 'total']);
  assert.strictEqual(validValue({ one: 'x', other: 'y' }), true);
  assert.strictEqual(validValue({ one: 'x' }), false);
  process.stdout.write('i18n-check self-test: OK\n');
}

(function main() {
  const o = parseArgs(process.argv.slice(2));
  if (o.selfTest) { selfTest(); return; }
  let r;
  try { r = run(o); } catch (e) { fail('internal error: ' + (e && e.stack ? e.stack.split('\n').slice(0, 3).join(' | ') : e), o); }
  if (o.json) {
    const j = Object.assign({ ok: false }, r);
    j.ok = !(r.parity.missingInEn.length + r.parity.missingInZh.length + r.parity.noLangName.length + r.placeholders.length + r.cjk.length + r.undefinedKeys.length);
    if (o.quiet) { delete j.unused; delete j.skippedDynamic; delete j.dynamicPrefixes; delete j.warnings; }
    process.stdout.write(JSON.stringify(j, null, 2) + '\n');
    process.exitCode = j.ok ? 0 : 1;
  } else process.exitCode = report(r, o) ? 1 : 0;
})();
