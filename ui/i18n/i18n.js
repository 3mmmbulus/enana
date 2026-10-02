/* enana · i18n.js — 多语言引擎 (无依赖)
 *
 *   I18N.t('nav.overview')                      翻译; {name} 插值; 值为 {one, other} 时按 vars.n 选复数
 *   I18N.L('nav.overview', vars)                「懒」文案: 放进 h() 的子节点或 title/aria-label/placeholder 属性里, 切换语言后自动更新
 *   I18N.setLang('en') / I18N.lang / I18N.available   切换 / 当前语言 / [{code, name}]
 *   I18N.register('fr', {...})                  新增语言: 只需要一个词典文件 + index.html 里一行 <script>
 *   data-i18n / data-i18n-title / data-i18n-placeholder / data-i18n-aria   静态标记, 只写 textContent / 属性, 绝不用 innerHTML
 *   I18N.pick(obj, 'name')                      后端提供的双语字段: name_en / name (中文) ...
 * 词典键用点号分隔的扁平字符串。缺键时依次回退: 当前语言 -> en -> zh -> 键名本身。 */
(function (root) {
  'use strict';
  var dicts = {}, listeners = [], reg = [], inited = false, lang = 'zh', KEY = 'enana.lang';
  var plurals = {};

  function store(get, k, v) {
    try { if (get) return localStorage.getItem(k); localStorage.setItem(k, v); } catch (e) { /* 隐私模式: 忽略 */ }
    return null;
  }
  function pluralFor(code, n) {
    try { var pr = plurals[code] || (plurals[code] = new Intl.PluralRules(code)); return pr.select(n); } catch (e) { return n === 1 ? 'one' : 'other'; }
  }
  function lookup(key) {
    var v = dicts[lang] && dicts[lang][key];
    if (v === undefined && dicts.en) v = dicts.en[key];
    if (v === undefined && dicts.zh) v = dicts.zh[key];
    return v;
  }
  function t(key, vars) {
    var v = lookup(key);
    if (v === undefined) return key;
    if (v !== null && typeof v === 'object') {
      var n = vars && vars.n != null ? +vars.n : 0;
      v = v[pluralFor(lang, n)] || v.other || v.one || '';
    }
    v = String(v);
    if (!vars || v.indexOf('{') < 0) return v;
    return v.replace(/\{(\w+)\}/g, function (m, k) { return vars[k] != null ? vars[k] : m; });
  }

  function isL(x) { return !!x && x.__i18n === 1; }
  function L(key, vars) { return { __i18n: 1, key: key, vars: vars || null }; }
  function text(d) { return t(d.key, d.vars); }

  /* 把一个「懒」文案变成会自动更新的文本节点 / 属性 */
  function node(d) { var n = document.createTextNode(text(d)); reg.push({ k: 't', n: n, d: d }); if (reg.length > 4000) prune(); return n; }
  function attr(el, name, d) { el.setAttribute(name, text(d)); reg.push({ k: 'a', n: el, a: name, d: d }); if (reg.length > 4000) prune(); }
  function prune() { reg = reg.filter(function (r) { return document.contains(r.n); }); }
  function refresh() {
    prune();
    reg.forEach(function (r) {
      var s = text(r.d);
      if (r.k === 't') { if (r.n.nodeValue !== s) r.n.nodeValue = s; }
      else if (r.n.getAttribute(r.a) !== s) r.n.setAttribute(r.a, s);
    });
  }

  /* 静态标记: data-i18n (文字) / data-i18n-title / data-i18n-placeholder / data-i18n-aria (aria-label); data-i18n-vars='{"n":3}' */
  var ATTRS = [['data-i18n-title', 'title'], ['data-i18n-placeholder', 'placeholder'], ['data-i18n-aria', 'aria-label']];
  function varsOf(el) { var s = el.getAttribute('data-i18n-vars'); if (!s) return null; try { return JSON.parse(s); } catch (e) { return null; } }
  function apply(rootEl) {
    var r = rootEl || document, list, i, el, k;
    list = r.querySelectorAll('[data-i18n]');
    for (i = 0; i < list.length; i++) { el = list[i]; k = t(el.getAttribute('data-i18n'), varsOf(el)); if (el.textContent !== k) el.textContent = k; }
    ATTRS.forEach(function (p) {
      list = r.querySelectorAll('[' + p[0] + ']');
      for (i = 0; i < list.length; i++) { el = list[i]; el.setAttribute(p[1], t(el.getAttribute(p[0]), varsOf(el))); }
    });
  }

  function available() {
    return Object.keys(dicts).map(function (c) { return { code: c, name: dicts[c]['lang.name'] || c }; })
      .sort(function (a, b) { return a.code === 'zh' ? -1 : b.code === 'zh' ? 1 : a.code === 'en' ? -1 : b.code === 'en' ? 1 : a.code < b.code ? -1 : 1; });
  }
  function detect() {
    var s = store(true, KEY), nav = String((root.navigator && (root.navigator.language || (root.navigator.languages || [])[0])) || '').toLowerCase(), i, a;
    if (s && dicts[s]) return s;
    a = available();
    for (i = 0; i < a.length; i++) if (nav === a[i].code || nav.indexOf(a[i].code + '-') === 0) return a[i].code;     // zh-CN -> zh, en-GB -> en
    return dicts.en ? 'en' : (a[0] && a[0].code) || 'zh';
  }

  var I18N = root.I18N = {
    get lang() { return lang; },
    set lang(v) { I18N.setLang(v); },
    available: [],
    t: t, L: L, isL: isL, text: text, node: node, attr: attr, apply: apply, refresh: refresh,
    has: function (key) { return lookup(key) !== undefined; },
    dict: function (code) { return dicts[code] || {}; },
    register: function (code, dict) {
      dicts[code] = Object.assign(dicts[code] || {}, dict);
      I18N.available = available();
    },
    /* 带节点的模板: I18N.rich('auth.forgot', {cmd: codeNode}) -> DocumentFragment (词典里写 {cmd}, 各语言可以自己决定语序)。切换语言后需要重新生成。 */
    rich: function (key, vars) {
      var raw = lookup(key), f = document.createDocumentFragment();
      if (raw === undefined) { f.appendChild(document.createTextNode(key)); return f; }
      String(raw).split(/(\{\w+\})/).forEach(function (part) {
        var m = /^\{(\w+)\}$/.exec(part), v = m && vars ? vars[m[1]] : undefined;
        if (v && v.nodeType) f.appendChild(v);
        else if (part) f.appendChild(document.createTextNode(m && v != null ? String(v) : part));
      });
      return f;
    },
    /* 第一次使用前调用 (幂等): 决定语言并处理静态标记 */
    init: function () {
      if (inited) return lang;
      inited = true; lang = detect();
      try { document.documentElement.lang = lang === 'zh' ? 'zh-CN' : lang; } catch (e) { /* 忽略 */ }
      apply(document);
      return lang;
    },
    setLang: function (code) {
      if (!dicts[code]) return false;
      inited = true; lang = code;
      store(false, KEY, code);
      try { document.documentElement.lang = code === 'zh' ? 'zh-CN' : code; } catch (e) { /* 忽略 */ }
      apply(document); refresh();
      listeners.slice().forEach(function (fn) { try { fn(code); } catch (e) { console.error(e); } });
      return true;
    },
    onChange: function (fn) { listeners.push(fn); },
    /* 后端给的双语字段: obj.name_en / obj.name; 当前语言没有对应字段时用默认 (中文) 字段 */
    pick: function (obj, field) {
      if (!obj) return '';
      var v = lang !== 'zh' ? obj[field + '_' + lang] : undefined;
      return v != null && v !== '' ? String(v) : (obj[field] != null ? String(obj[field]) : '');
    },
    /* 数字 / 日期 / 相对时间: 一律用 Intl 和当前语言 */
    intl: {
      num: function (n, o) { try { return new Intl.NumberFormat(lang, o).format(n); } catch (e) { return String(n); } },
      date: function (d, o) { try { return new Intl.DateTimeFormat(lang, o).format(d); } catch (e) { return d.toISOString(); } },
      rel: function (v, unit) { try { return new Intl.RelativeTimeFormat(lang, { numeric: 'auto' }).format(v, unit); } catch (e) { return v + ' ' + unit; } },
      list: function (a) { try { return new Intl.ListFormat(lang, { style: 'short', type: 'conjunction' }).format(a); } catch (e) { return a.join(', '); } }
    }
  };
})(typeof window !== 'undefined' ? window : this);
