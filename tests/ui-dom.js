// A small fake browser for the dashboard UI tests (no browser, no network, no real storage): enough of Element / Event / document /
// window for the real ui/core.js, ui/data.js, ui/ui.js, ui/auth.js and the page scripts. Used by tests/table-rows-ui.test.js and
// tests/sudo-session.test.js. Events bubble (target -> parents -> document) like in a browser; selectors are the small subset ui.js uses
// (tag.class[attr=value] with :not(...), comma lists). Timers never fire on their own (tests drive everything explicitly).
'use strict';
const fs = require('fs'), path = require('path'), vm = require('vm'), assert = require('assert');

function attrOk(el, a) {
  const m = /^\[([\w-]+)(?:=(?:"([^"]*)"|'([^']*)'|([^\]]*)))?\]$/.exec(a); assert(m, 'unsupported selector ' + a);
  const v = el.getAttribute(m[1]), want = m[2] !== undefined ? m[2] : m[3] !== undefined ? m[3] : m[4];
  return want === undefined ? v !== null : v === want;
}
function matches(el, sel) {
  if (el.nodeType !== 1) return false;
  return sel.split(',').some(part => {
    const nots = []; part = part.trim().replace(/:not\(([^)]*)\)/g, (_, x) => { nots.push(x); return ''; });
    const m = /^([a-z]*)((?:\.[\w-]+)*)((?:\[[^\]]+\])*)$/i.exec(part); assert(m, 'unsupported selector ' + part);
    if (m[1] && el.tagName !== m[1].toLowerCase()) return false;
    if (m[2].split('.').filter(Boolean).some(c => !el.classList.contains(c))) return false;
    if ((m[3].match(/\[[^\]]+\]/g) || []).some(x => !attrOk(el, x))) return false;
    return !nots.some(x => attrOk(el, x));
  });
}

function makeBrowser(o) {
  o = o || {};
  const win = {}, docListeners = { capture: {}, bubble: {} };
  const phase = opt => (opt === true || !!(opt && opt.capture) ? 'capture' : 'bubble');
  class El {
    constructor(tag) {
      this.nodeType = tag === '#text' ? 3 : 1; this.tagName = tag; this.nodeName = tag.toUpperCase();
      this.children = []; this.attrs = {}; this.events = {}; this.text = ''; this.className = ''; this.parentNode = null;
      this.disabled = false; this.hidden = false; this.checked = false; this.title = ''; this.value = ''; this.open = false;
      this.style = { setProperty() {}, removeProperty() {} }; this.offsetParent = null; this.offsetWidth = 0; this.offsetHeight = 0;
      const self = this;
      this.classList = {
        contains: c => self.className.split(' ').includes(c), add: c => self.classList.toggle(c, true), remove: c => self.classList.toggle(c, false),
        toggle: (c, on) => { const s = new Set(self.className.split(' ').filter(Boolean)); if (on === undefined) on = !s.has(c); if (on) s.add(c); else s.delete(c); self.className = [...s].join(' '); return !!on; }
      };
    }
    get textContent() { return this.text + this.children.map(x => x.textContent).join(''); }
    set textContent(s) { this.children.forEach(c => { c.parentNode = null; }); this.children = []; this.text = String(s); }
    get firstChild() { return this.children[0] || null; }
    get lastChild() { return this.children[this.children.length - 1] || null; }
    get nextSibling() { const p = this.parentNode; if (!p) return null; return p.children[p.children.indexOf(this) + 1] || null; }
    get options() { return this.children.filter(c => c.tagName === 'option'); }
    get id() { return this.attrs.id || ''; }
    set id(v) { this.attrs.id = String(v); }
    get tabIndex() { return this.attrs.tabindex == null ? -1 : +this.attrs.tabindex; }
    set tabIndex(v) { this.attrs.tabindex = String(v); }
    setAttribute(k, v) { if (k === 'class') this.className = String(v); else this.attrs[k] = String(v); }
    getAttribute(k) { return k === 'class' ? (this.className || null) : (k in this.attrs ? this.attrs[k] : null); }
    hasAttribute(k) { return this.getAttribute(k) !== null; }
    removeAttribute(k) { if (k === 'title') this.title = ''; delete this.attrs[k]; }
    appendChild(c) { if (c.parentNode) c.parentNode.removeChild(c); this.children.push(c); c.parentNode = this; return c; }
    insertBefore(c, ref) { if (!ref) return this.appendChild(c); if (c.parentNode) c.parentNode.removeChild(c); const i = this.children.indexOf(ref); assert(i >= 0, 'insertBefore: ref is not a child'); this.children.splice(i, 0, c); c.parentNode = this; return c; }
    removeChild(c) { const i = this.children.indexOf(c); assert(i >= 0, 'removeChild of a node that is not a child'); this.children.splice(i, 1); c.parentNode = null; return c; }
    replaceChild(c, old) { this.insertBefore(c, old); this.removeChild(old); return old; }
    addEventListener(e, fn) { (this.events[e] = this.events[e] || []).push(fn); }
    removeEventListener(e, fn) { const a = this.events[e] || [], i = a.indexOf(fn); if (i >= 0) a.splice(i, 1); }
    /* 和浏览器一样: 先是 document 上的捕获监听 (capture), 再从目标冒泡: 目标 -> 父节点 … -> document; stopPropagation 之后不再往下传。返回事件对象 */
    dispatch(type, init) {
      const ev = Object.assign({ type, target: this, currentTarget: null, bubbles: true, defaultPrevented: false, button: 0, detail: 0, key: '', isComposing: false, repeat: false, _stop: false,
        preventDefault() { this.defaultPrevented = true; }, stopPropagation() { this._stop = true; } }, init || {});
      ev.currentTarget = doc; (docListeners.capture[type] || []).slice().forEach(fn => fn(ev));
      for (let n = this; n && !ev._stop; n = n.parentNode) { ev.currentTarget = n; (n.events[type] || []).slice().forEach(fn => fn(ev)); }
      if (!ev._stop) { ev.currentTarget = doc; (docListeners.bubble[type] || []).slice().forEach(fn => fn(ev)); }
      return ev;
    }
    click() { return this.dispatch('click'); }
    contains(x) { for (let n = x; n; n = n.parentNode) if (n === this) return true; return false; }
    querySelectorAll(sel) { const out = []; (function walk(n) { for (const c of n.children) { if (matches(c, sel)) out.push(c); walk(c); } })(this); return out; }
    querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
    closest(sel) { for (let n = this; n && n.nodeType === 1; n = n.parentNode) if (matches(n, sel)) return n; return null; }
    focus() { doc.activeElement = this; }
    blur() { if (doc.activeElement === this) doc.activeElement = null; }
    select() {}
    scrollIntoView() {}
    showModal() { this.open = true; this.attrs.open = ''; }
    close() { this.open = false; delete this.attrs.open; }
    getBoundingClientRect() { return { left: 0, right: 0, top: 0, bottom: 0, width: 0, height: 0 }; }
  }
  const doc = {
    body: new El('body'), documentElement: new El('html'), activeElement: null, hidden: false,
    createTextNode: s => { const x = new El('#text'); x.text = String(s); return x; },
    createElement: tag => new El(String(tag).toLowerCase()),
    querySelectorAll: sel => doc.body.querySelectorAll(sel), querySelector: sel => doc.body.querySelector(sel),
    getElementById: id => doc.body.querySelectorAll('[id="' + id + '"]')[0] || null,
    contains: x => doc.body.contains(x),
    addEventListener: (e, fn, opt) => { const m = docListeners[phase(opt)]; (m[e] = m[e] || []).push(fn); },
    removeEventListener: (e, fn, opt) => { const a = docListeners[phase(opt)][e] || [], i = a.indexOf(fn); if (i >= 0) a.splice(i, 1); },
    listenerCount: (e, opt) => (docListeners[phase(opt)][e] || []).length
  };
  const timers = [];
  win.window = win; win.self = win;
  win.document = doc; win.console = console;
  win.location = { pathname: '/enana/admin/sites', search: '', hash: '' };
  win.history = { pushState() {}, replaceState() {} };
  win.navigator = { language: 'zh-CN' };
  win.innerWidth = 1280; win.innerHeight = 800;
  win.addEventListener = () => {}; win.removeEventListener = () => {};
  win.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} });
  win.selection = { isCollapsed: true, anchorNode: null, toString: () => '' };          // 测试可以换成「选中了一段文字」
  win.getSelection = () => win.selection;
  win.setTimeout = (fn, ms) => { timers.push({ fn, ms }); return timers.length; };
  win.clearTimeout = () => {}; win.setInterval = () => 0; win.clearInterval = () => {};
  win.URL = URL; win.URLSearchParams = URLSearchParams; win.AbortController = AbortController;
  win.sessionStorage = o.sessionStorage || storage(); win.localStorage = o.localStorage || storage();
  if (o.Date) win.Date = o.Date;
  win.fetch = o.fetch || (() => Promise.reject(new Error('no network in tests')));
  vm.createContext(win);
  return {
    win, doc, El, timers,
    load(file) { vm.runInContext(fs.readFileSync(path.join(__dirname, '..', file), 'utf8'), win, { filename: file }); },
    all(root, pred) { const out = []; (function walk(n) { for (const c of n.children) { if (pred(c)) out.push(c); walk(c); } })(root); return out; }
  };
}

/* sessionStorage / localStorage: 值是对象自己的属性 (和浏览器一样 Object.keys 能列出来); throwing = 隐私模式下读写都抛异常 */
function storage(throwing) {
  const s = {};
  const guard = fn => function () { if (throwing) throw new Error('SecurityError: storage is disabled'); return fn.apply(null, arguments); };
  Object.defineProperties(s, {
    getItem: { value: guard(k => (Object.prototype.hasOwnProperty.call(s, k) ? s[k] : null)) },
    setItem: { value: guard((k, v) => { s[k] = String(v); }) },
    removeItem: { value: guard(k => { delete s[k]; }) }
  });
  return s;
}

/* 词典的替身: t(键, 变量) = 键 (+ 变量的 JSON), 这样断言能看出用了哪个键、带了什么值 */
function fakeI18n(o) {
  o = o || {};
  const has = o.has || (() => false);
  return {
    lang: 'zh', available: [{ code: 'zh', name: 'ZH' }, { code: 'en', name: 'EN' }],
    t: (k, v) => (v ? k + ' ' + JSON.stringify(v) : k), L: (k, v) => (v ? k + ' ' + JSON.stringify(v) : k),
    isL: () => false, has, pick: (x, k) => x[k], attr: (e, k, v) => e.setAttribute(k, v), text: x => String(x),
    onChange() {}, setLang: () => false,
    intl: { num: n => String(n), date: () => 'DATE', rel: (n, u) => n + ' ' + u }
  };
}

const tick = () => new Promise(r => setImmediate(r));
async function settle(n) { for (let i = 0; i < (n || 6); i++) await tick(); }

module.exports = { makeBrowser, storage, fakeI18n, tick, settle, matches };
