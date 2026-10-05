/* enana · v-logs.js — 日志页 (操作记录 / 网站访问 / 代理日志) + 日志设置 (保留时长 / 三种日志各自的开关 / 占用空间)
 *
 * 日志页 (view id: logs): 页内标签 + 日期选择 + 搜索 (服务端, 防抖 300 ms) + 筛选 (全部 / 直连 / 代理 / 失败 ...) + 实时刷新 + 导出 (一个按钮, 二次弹窗选内容和时间范围) + 清除… + 日志设置;
 *   列表按页浏览, 点一行 (或时间按钮) 打开详情弹窗 (可用 ‹ › 在本页的各条之间切换, 可复制)。
 *   网站访问: 每条连接 = 时间 · 网站 (失败时带失败类型) · 应用 (图标) · 线路 · 出口 (直连时写「为什么直连」); 上面一行汇总 (直连 / 代理 / 失败 + 直连原因分布 + 失败最多的网站)。
 *   GET  /api/logs?type&day&q&limit&offset&f -> {total, days[], rows[], summary}  (新→旧; f = 筛选: ops error | access direct proxy error | proxy warn error)
 *   GET  /api/logs/bundle?hours=<1..720|all>&sections=ops,access,proxy,snapshot -> 纯文本 (诊断导出: 自描述的一个文件, 格式见 docs/DIAGNOSTICS.md)
 *   POST /api/logs/clear 表单 type(+before) -> {freed}      (需要再次输入登录密码: TP.helper 自己弹出密码框, 取消 = e.kind 'cancel', 安静地忽略)
 * 日志设置 (TP.logs): 设置页与日志页共用 —— 保留时长 (12 小时 – 30 天) / 操作记录 / 网站访问 / 代理核心日志 (三个开关) / 占用空间。
 *   TP.logs.settingsCard() -> 自更新的 <section class="card"> (设置页嵌入);  TP.logs.openSettings() -> 同样的控件放进弹窗。
 *   数据来自 TP.loadSettings() 的 S.prefs: {settings:{log_hours, log_hours_min/max, log_ops, access_log, log_core}, usage:{ops, access, proxy, total}}; 每次修改后重新加载。
 * 偏好 (TP.prefs): logs.tab (上次打开的标签); 每页条数 / 页码由 ui.pager 记在 table.logs.<类型>.* (页码每次打开页面时回到最新的第 1 页); sort.logs.<类型> (列头排序, ui.sorter)。
 * 列头排序: 每个标签一个 ui.sorter。服务端一次只给一页 (新→旧), 所以排序只重排「当前读到的这一页」, 不是整个日志 (想看整个日志的排序请用搜索 / 筛选缩小范围); 没选排序 = 新→旧 (和以前一样)。
 *
 * 约定: 日志里的文字 (域名 / 应用 / 详情 / 消息) 一律只用 textContent。
 * 性能: 日志行里不用 I18N.L() (每个 L 都会进语言注册表) 也不用 fmt.hms (每次调用都新建 Intl 对象, 约 0.3 ms);
 *       行文字用 t(), 切换语言时整体重建 (最多是当前这一页)。 */
(function () {
  'use strict';
  var TP = window.TP, S = TP.S, h = TP.h, ui = TP.ui, fmt = TP.fmt, setText = TP.setText, I = window.I18N, t = I.t, L = I.L;
  var V = TP.V.logs = { id: 'logs' };
  var LG = TP.logs = {};

  var PK = { tab: 'logs.tab' };                                                                                               // i18n-ignore (偏好键, 不是词典键)
  var HT = { page: 'logs.page', tabs: 'logs.tabs', retention: 'logs.retention', access: 'logs.access', clear: 'logs.clear', ops: 'logs.ops', core: 'logs.core' };   // i18n-ignore (「!」说明的话题: 词典键是 help.<话题>.*)
  var CAP = 5000;                // 翻页最多提供最新的这么多条 (再往后请用搜索 / 换一天 / 导出)
  var LIVE_MS = 5000;            // 「实时」: 每 5 秒重新读一次
  var TYPES = ['ops', 'access', 'proxy'];
  var TAB_ICON = { ops: 'history', access: 'globe', proxy: 'terminal' };
  var FILTERS = { ops: ['', 'error'], access: ['', 'direct', 'proxy', 'error'], proxy: ['', 'warn', 'error'] };
  var REASONS = { mode: 1, lan: 1, site: 1, app: 1, cn: 1, policy: 1 };
  var YMD = /^\d{4}-\d{2}-\d{2}$/, TIME_RE = /^\d{4}-\d{2}-\d{2}[ T](\d{2}:\d{2}:\d{2})(?:\.\d+)?$/;
  var COLS = {                   // [单元格类名, 列名词典键, 排序键 (SORT_COLS 里的列)]
    ops: [['log-t', 'logs.col.time', 'time'], ['log-who', 'logs.col.who', 'who'], ['log-act', 'logs.col.action', 'action'], ['log-d', 'logs.col.detail', 'detail'], ['log-res', 'logs.col.result', 'result']],
    access: [['log-t', 'logs.col.time', 'time'], ['log-host', 'logs.col.site', 'site'], ['log-app', 'logs.col.app', 'app'], ['log-route', 'logs.col.route', 'route'], ['log-node', 'logs.col.node', 'node']],
    proxy: [['log-t', 'logs.col.time', 'time'], ['log-lv', 'logs.col.level', 'level'], ['log-msg', 'logs.col.msg', 'msg']]
  };
  var LEVEL = { INFO: 'info', DEBUG: '', TRACE: '', WARN: 'warn', WARNING: 'warn', ERROR: 'bad', FATAL: 'bad', PANIC: 'bad' };      // 级别颜色: INFO 蓝灰 · WARN 琥珀 · ERROR 红
  var ROUTE_ICON = { pin: 'pin', auto: 'auto', direct: 'direct' };

  var el = {}, tabsCtl = null, T = {}, PG = {}, SO = {}, lastSize = {}, quiet = 0, segs = {}, liveTimer = 0;
  var cur = pickType(TP.prefs.get(PK.tab, 'ops')), day = '', days = [], qTimer = 0;
  TYPES.forEach(function (k) { T[k] = fresh(); });

  /* 每个类型一份状态。rows = 当前这一页 (服务端的顺序: 新→旧); view = 实际显示的顺序 (列头排序之后; 点行打开详情时按它翻页); pos = 行 -> 它在 rows 里的序号 (排序时间相同的行时保持新旧次序); base = 最近一次「新读取」时的总数 (分页的基准, 翻页期间日志又新增的在最新一端, 另外提示); total = 最近一次响应里的总数;
   * gen = rows 被整体替换的次数 (DOM 据此决定要不要重建); f = 筛选; sum = 服务端给的汇总 (筛选按钮上的数字) */
  function fresh() { return { rows: [], view: [], pos: null, total: 0, base: 0, q: '', f: '', sum: null, key: '', loaded: false, loading: false, err: null, seq: 0, gen: 0, at: 0, pageNo: 0 }; }

  /* ================= 小工具 ================= */
  function active() { return TP.tab === 'logs'; }
  function pickType(v) { return TYPES.indexOf(v) >= 0 ? v : 'ops'; }
  function own(o, k) { return Object.prototype.hasOwnProperty.call(o, k); }
  function boolOf(v) { return v === true || v === 1 || v === '1' || v === 'true'; }
  function prefs() { return (S.prefs && S.prefs.settings) || null; }
  function usageOf() { return (S.prefs && S.prefs.usage) || null; }
  function keepHours() { var p = prefs(), n = p ? +p.log_hours : 0; return n > 0 ? n : 72; }
  function hoursLabel(n) { return n % 24 === 0 ? t('logs.ret.days', { n: n / 24 }) : t('logs.ret.hours', { n: n }); }
  function flag(key, dflt) { var p = prefs(); return p && p[key] != null ? boolOf(p[key]) : dflt; }          // 开关: 还不知道时用默认值
  function opsOn() { return flag('log_ops', true); }
  function accessOn() { var p = prefs(); return p && p.access_log != null ? boolOf(p.access_log) : null; }   // null = 还不知道
  function coreOn() { return flag('log_core', true); }
  function diagOn() { return flag('diag_upload', true); }          // 诊断摘要自动上传 (官方云端, 不含网站 / 应用名 / IP / 服务器地址)
  function pad2(n) { return n < 10 ? '0' + n : String(n); }
  function ymd(d) { return d.getFullYear() + '-' + pad2(d.getMonth() + 1) + '-' + pad2(d.getDate()); }
  function stamp() { var d = new Date(); return ymd(d).replace(/-/g, '') + '-' + pad2(d.getHours()) + pad2(d.getMinutes()) + pad2(d.getSeconds()); }
  /* 行内时间: 后端给 "2026-10-02 13:44:21" (本机时间, 没有时区) -> 直接取时分秒; 其他格式 (unix 秒 / 带时区的 ISO) 交给 fmt.hms (会换算成本地时间) */
  function clock(ts) { var m = typeof ts === 'string' ? TIME_RE.exec(ts) : null; return m ? m[1] : fmt.hms(ts); }
  function dayLabel(s) {
    var m = YMD.test(s || '') ? s.split('-') : null;
    return m ? I.intl.date(new Date(+m[0], +m[1] - 1, +m[2]), { year: 'numeric', month: 'short', day: 'numeric' }) : String(s || '');
  }
  function cleanDays(a) {
    var out = [];
    (Array.isArray(a) ? a : []).forEach(function (d) { d = String(d); if (YMD.test(d) && out.indexOf(d) < 0) out.push(d); });
    return out.sort().reverse();                                       // 新→旧
  }
  function qkey(k) { return [day, T[k].q, T[k].f, PG[k].page(), PG[k].size()].join('|'); }
  function str(v) { return v == null ? '' : String(v); }
  function withHelp(node, topic) { return h('span', { class: 'log-hp' }, node, ui.help(topic)); }
  function setPage(k, n) { quiet++; try { PG[k].setPage(n); } finally { quiet--; } }                 // 程序自己翻页 (不触发读取)
  /* 用户翻页以后, 如果工具栏已经滚出了屏幕, 滚回来, 这样新一页是从头开始看的 */
  function toTop(node) {
    var sc = TP.byId('scroll'), r, s;
    if (!sc || !node) return;
    r = node.getBoundingClientRect(); s = sc.getBoundingClientRect();
    if (r.top < s.top) sc.scrollTop += r.top - s.top - 8;
  }

  /* 设置读取只发一次 (日志页、设置卡片、弹窗可能同时要) */
  var prefsReq = null;
  function loadPrefs() {
    if (S.locked) return Promise.resolve(null);
    if (!prefsReq) prefsReq = TP.loadSettings().then(function (r) { prefsReq = null; return r; }, function () { prefsReq = null; return null; });
    return prefsReq;
  }

  function download(name, text) {
    var url = URL.createObjectURL(new Blob([text], { type: 'text/plain;charset=utf-8' })), a = h('a', { href: url, download: name, hidden: true });
    document.body.appendChild(a); a.click(); document.body.removeChild(a);
    setTimeout(function () { URL.revokeObjectURL(url); }, 5000);
  }

  /* 应用图标: 用「应用」页同一个图标盒子 (有图标显示图标, 没有 / 加载失败用字母头像) */
  var icCache = { src: null, map: {} };
  function iconOf(name) {
    var arr = (S.apps && S.apps.apps) || [];
    if (icCache.src !== arr) { icCache.src = arr; icCache.map = {}; arr.forEach(function (a) { if (a && a.name && a.icon) icCache.map[a.name] = a.icon; }); }
    return icCache.map[name] || '';
  }
  function appBox(name) {
    if (!name || !TP.appIc) return null;
    var box = TP.appIc.mk(18); TP.appIc.paint(box, name, iconOf(name));
    return box;
  }

  /* ================= 日志行 (textContent only) ================= */
  function badge(text) { return h('span', { class: 'badge' }, text); }
  function openBtn(ts, what) { var c = clock(ts); return h('button', { class: 'log-open', type: 'button', 'aria-label': t('logs.dt.openAria', { time: c, what: what }) }, c); }
  function actText(act) { var key = 'ops.' + act; return act !== '' && I.has(key) ? t(key) : act; }
  function hostText(r) {
    var host = str(r.host), port = +r.port > 0 ? ':' + (+r.port) : '';
    if (host.indexOf(':') >= 0 && host.charAt(0) !== '[') host = '[' + host + ']';           // IPv6
    return host + port;
  }
  function reasonText(r) { return r && own(REASONS, r) ? t('logs.reason.' + r) : ''; }
  function errText(e) { return e ? (I.has('logs.err.' + e) ? t('logs.err.' + e) : e) : ''; }
  function routeKind(route) { return own(ROUTE_ICON, route) ? route : route === 'none' ? 'none' : 'other'; }
  function routeBadge(route) {
    var rt = routeKind(route);
    return h('span', { class: 'badge log-rb r-' + rt }, own(ROUTE_ICON, rt) ? ui.icon(ROUTE_ICON[rt], 13, 'ci') : null, rt === 'other' ? t('logs.route.other') : rt === 'none' ? t('logs.route.none') : TP.name.route(rt));
  }
  /* 列表里的「详情」: key=value 的记录显示成「标签 值 · 标签 值」(和详情弹窗用同一套标签); 不是这种格式的 (旧记录) 原样显示。kvParse / kvLabel / kvValue 在下面定义 */
  function detailInline(raw, act) {
    var pairs = kvParse(raw), out;
    if (!pairs || !pairs.length) return str(raw);
    out = h('span', { class: 'log-kvi' });
    pairs.forEach(function (p, i) {
      if (i) out.appendChild(document.createTextNode(' · '));
      out.appendChild(h('span', { class: 'log-kl' }, kvLabel(p[0], act) + ' '));
      out.appendChild(h('span', { class: 'log-kvv' }, kvValue(p[0], p[1])));
    });
    return out;
  }
  function opsRow(r) {
    var act = str(r.action), key = 'ops.' + act, known = act !== '' && I.has(key), who = str(r.who), wk = 'logs.who.' + who, res = r.result;
    return h('li', { class: 'log-row log-ops' + (res === 'error' ? ' is-err' : '') },
      h('span', { class: 'log-c log-t' }, openBtn(r.ts, actText(act) || who)),
      h('span', { class: 'log-c log-who' }, who ? badge(I.has(wk) ? t(wk) : who) : null),
      h('span', { class: 'log-c log-act' + (known ? '' : ' mono'), title: known ? act : null }, known ? t(key) : act),
      h('span', { class: 'log-c log-d' }, detailInline(r.detail, act)),
      h('span', { class: 'log-c log-res' }, res === 'error' ? ui.chip(t('logs.result.error'), 'bad', 'error') : res === 'ok' ? ui.chip(t('logs.result.ok'), 'ok', 'success') : (res ? ui.chip(str(res)) : null)));
  }
  function nodeText(r) { return routeKind(r.route) === 'direct' ? (reasonText(r.reason) || str(r.node)) : str(r.node); }      // 「出口」列的文字: 直连时写「为什么直连」
  function accessRow(r) {
    var rt = routeKind(r.route), node = str(r.node), bad = !!r.err, nodeTxt = nodeText(r);
    return h('li', { class: 'log-row log-access' + (bad ? ' is-err' : '') },
      h('span', { class: 'log-c log-t' }, openBtn(r.ts, hostText(r))),
      h('span', { class: 'log-c log-host' }, h('span', { class: 'log-hn' }, hostText(r)), bad ? h('span', { class: 'chip bad log-ec', title: str(r.errmsg) }, errText(r.err)) : null),
      h('span', { class: 'log-c log-app' + (r.app ? '' : ' is-na') }, appBox(r.app), h('span', { class: 'log-an' }, str(r.app) || '—')),
      h('span', { class: 'log-c log-route' }, routeBadge(rt)),
      h('span', { class: 'log-c log-node' + (nodeTxt ? '' : ' is-na'), title: rt === 'direct' ? node : null }, nodeTxt || '—'));
  }
  function proxyRow(r) {
    var lv = str(r.level).toUpperCase(), cls = own(LEVEL, lv) ? LEVEL[lv] : '';
    return h('li', { class: 'log-row log-proxy' + (cls === 'bad' ? ' is-err' : cls === 'warn' ? ' is-warn' : '') },
      h('span', { class: 'log-c log-t' }, openBtn(r.ts, lv || str(r.msg).slice(0, 40))),
      h('span', { class: 'log-c log-lv' }, lv ? h('span', { class: 'chip log-chip' + (cls ? ' ' + cls : '') }, lv) : null),
      h('span', { class: 'log-c log-msg' }, str(r.msg)));
  }
  var ROW = { ops: opsRow, access: accessRow, proxy: proxyRow };

  /* ================= 列头排序 (每个标签一个 ui.sorter; 只排当前读到的这一页) ================= */
  var LV_RANK = { TRACE: 0, DEBUG: 1, INFO: 2, WARN: 3, WARNING: 3, ERROR: 4, FATAL: 5, PANIC: 5 };                          // 代理日志级别: 按严重程度排
  function nz(v) { return v == null || v === '' ? null : v; }
  function sortCol(type, get) { return { type: type, get: function (r) { return r ? get(r) : null; } }; }
  /* 时间 = 行的时间戳 (毫秒); 同一秒里的几行再按服务端的新→旧次序区分 (每一行在 rows 里的序号 × 0.001 ms), 这样升序 = 真的从旧到新 */
  function timeCol(k) {
    return sortCol('num', function (r) {
      var d = fmt.toDate(r.ts), p = T[k].pos && T[k].pos.get(r);
      return d ? d.getTime() - (p || 0) * 0.001 : null;
    });
  }
  var SORT_COLS = {
    ops: {
      time: timeCol('ops'),
      who: sortCol('text', function (r) { var who = str(r.who), wk = 'logs.who.' + who; return who ? (I.has(wk) ? t(wk) : who) : null; }),      // 用显示出来的文字排 (和列表里看到的一致)
      action: sortCol('text', function (r) { return nz(actText(str(r.action))); }),
      detail: sortCol('text', function (r) { return nz(str(r.detail)); }),
      result: sortCol('text', function (r) { return nz(str(r.result)); })
    },
    access: {
      time: timeCol('access'),
      site: sortCol('text', function (r) { return nz(str(r.host)); }),
      app: sortCol('text', function (r) { return nz(str(r.app)); }),
      route: sortCol('text', function (r) { return nz(str(r.route)); }),
      node: sortCol('text', function (r) { return nz(nodeText(r)); })
    },
    proxy: {
      time: timeCol('proxy'),
      level: sortCol('num', function (r) { var lv = str(r.level).toUpperCase(); return own(LV_RANK, lv) ? LV_RANK[lv] : null; }),
      msg: sortCol('text', function (r) { return nz(str(r.msg)); })
    }
  };

  /* 这一页的行: 数据整体替换 (gen 变了) / 语言变了 / 换了标签才重建 (最多一页, 几十行) */
  function syncRows(k) {
    var tb = T[k], b = el.list._b, st = SO[k].state(), ss = st ? st.key + ':' + st.dir : '', frag, i, li;
    if (b && b.k === k && b.gen === tb.gen && b.lang === I.lang && b.sort === ss) return;
    TP.clear(el.list);
    el.list._b = { k: k, gen: tb.gen, lang: I.lang, sort: ss };
    if (st) {                                                                                  // 列头排序: 只重排这一页 (没选排序时 view = rows = 新→旧)
      tb.pos = new Map(); tb.rows.forEach(function (r, n) { if (r) tb.pos.set(r, n); });
      tb.view = SO[k].apply(tb.rows);
    } else { tb.pos = null; tb.view = tb.rows; }
    frag = document.createDocumentFragment();
    for (i = 0; i < tb.view.length; i++) {
      try { li = ROW[k](tb.view[i] || {}); li._i = i; frag.appendChild(li); } catch (e) { console.error('[logs] bad row', e); }
    }
    el.list.appendChild(frag);
  }
  function syncHead(k) {
    var sig = k + '|' + I.lang;
    if (el.head._sig === sig) return;
    el.head._sig = sig; TP.clear(el.head); el.head.className = 'log-head log-' + k;
    COLS[k].forEach(function (c) {
      var cell = h('span', { class: 'log-c ' + c[0] });
      SO[k].attach(cell, c[2], function () { return t(c[1]); });                               // 列头 = 排序按钮 (升序 → 降序 → 恢复新→旧)
      el.head.appendChild(cell);
    });
  }

  /* ================= 日志详情弹窗 ================= */
  var BOOL_KEYS = { on: 1, enabled: 1, auto: 1, force: 1, registered: 1, leak_guard: 1, ads_block: 1, access_log: 1, log_ops: 1, log_core: 1, diag_upload: 1, auto_sites: 1, save: 1, was_enabled: 1 };
  var APP_STATES = { follow: 1, direct: 1, pin: 1, auto: 1 }, ROUTE_VALUES = { pin: 1, auto: 1, direct: 1 };
  /* 操作记录的「详情」是 key=value 对 (值里有空格时用引号): 解析成 [[key, value], …]; 不是这种格式 (例如旧版后端的自由文字) 或被截断了就返回 null */
  function kvParse(s) {
    s = String(s || '').trim();
    if (!s) return [];
    var out = [], n = s.length, i = 0, key, val, c;
    while (i < n) {
      while (i < n && /\s/.test(s.charAt(i))) i++;
      if (i >= n) break;
      key = ''; while (i < n && /[A-Za-z0-9_.\-]/.test(s.charAt(i))) key += s.charAt(i++);
      if (!key || s.charAt(i) !== '=') return null;
      i++; val = '';
      if (s.charAt(i) === '"') {
        i++;
        while (i < n && s.charAt(i) !== '"') { c = s.charAt(i++); if (c === '\\' && i < n) c = s.charAt(i++); val += c; }
        if (s.charAt(i) !== '"') return null;
        i++;
        if (i < n && !/\s/.test(s.charAt(i))) return null;
      } else { while (i < n && !/\s/.test(s.charAt(i))) val += s.charAt(i++); }
      out.push([key, val]);
    }
    return out;
  }
  function kvLabel(key, act) { return I.has('logs.dt.k.' + act + '.' + key) ? t('logs.dt.k.' + act + '.' + key) : I.has('logs.dt.k.' + key) ? t('logs.dt.k.' + key) : key; }       // 先找「这个操作专用」的标签
  /* 值: 已知的值翻译成当前语言, 原始值放在后面的小字里 */
  function kvValue(key, v) {
    var tx = null;
    if (key === 'code' && /^E_[A-Z_]+$/.test(v) && I.has('error.' + v)) tx = t('error.' + v);
    else if (own(BOOL_KEYS, key) && (v === '1' || v === '0')) tx = t(v === '1' ? 'common.yes' : 'common.no');
    else if ((key === 'state' || key === 'from' || key === 'to') && own(APP_STATES, v)) tx = TP.name.app(v);
    else if (key === 'policy' && own(ROUTE_VALUES, v)) tx = TP.name.route(v);
    else if (key === 'role') tx = TP.name.role(v);
    else if (key === 'via' && (v === 'PIN' || v === 'Global')) tx = TP.name.policy(v);
    else if (key === 'type' && own({ ops: 1, access: 1, proxy: 1 }, v)) tx = t('logs.tab.' + v);
    else if (key === 'err' && I.has('logs.err.' + v)) tx = t('logs.err.' + v);
    else if (key === 'src' && v === 'auto') tx = t('sites.src.auto');
    else if (I.has('logs.dt.v.' + v)) tx = t('logs.dt.v.' + v);
    return tx != null && tx !== v && v !== '' ? h('span', null, tx, ' ', h('code', { class: 'lgd-code' }, v)) : (v === '' ? '—' : v);
  }
  function fullTime(ts) {
    var d = fmt.toDate(ts), raw = str(ts);
    return h('span', null, d ? fmt.dateTime(ts) : raw, d && raw ? h('span', { class: 'muted sm lgd-raw' }, ' ' + raw) : null);
  }
  function resultBadge(res) { return res === 'error' ? ui.badge(t('logs.result.error'), 'bad', 'error') : res === 'ok' ? ui.badge(t('logs.result.ok'), 'ok', 'success') : (res ? ui.badge(str(res), 'neutral') : '—'); }
  function levelBadge(lv) { var u = str(lv).toUpperCase(); return u ? h('span', { class: 'chip log-chip' + (own(LEVEL, u) && LEVEL[u] ? ' ' + LEVEL[u] : '') }, u) : '—'; }
  function detailNode(raw, act) {
    var pairs = kvParse(raw);
    if (!str(raw).trim()) return h('span', { class: 'muted' }, t('logs.dt.noDetail'));
    if (!pairs || !pairs.length) return h('span', { class: 'mono lgd-text' }, str(raw));
    return h('table', { class: 'lgd-kvt' }, h('tbody', null, pairs.map(function (p) {
      return h('tr', null, h('th', { scope: 'row' }, kvLabel(p[0], act)), h('td', { class: 'mono' }, kvValue(p[0], p[1])));
    })));
  }
  /* 一条记录的全部字段: [[标签, 节点, 纯文本], …] */
  function fieldsOf(k, r) {
    var f = [], act = str(r.action), known = act !== '' && I.has('ops.' + act), who = str(r.who), wk = 'logs.who.' + who, port = +r.port > 0 ? String(+r.port) : '', why;
    f.push([t('logs.col.time'), fullTime(r.ts), str(r.ts)]);
    if (k === 'ops') {
      f.push([t('logs.col.who'), who ? badge(I.has(wk) ? t(wk) : who) : '—', I.has(wk) ? t(wk) : who]);
      f.push([t('logs.col.action'), h('span', null, known ? t('ops.' + act) : act || '—', known ? h('code', { class: 'lgd-code' }, act) : null), known ? t('ops.' + act) + ' (' + act + ')' : act]);
      f.push([t('logs.col.detail'), detailNode(r.detail, act), str(r.detail)]);
      f.push([t('logs.col.result'), resultBadge(r.result), str(r.result)]);
    } else if (k === 'access') {
      why = reasonText(r.reason);
      f.push([t('logs.col.site'), h('span', { class: 'mono lgd-text' }, str(r.host) || '—'), str(r.host)]);
      f.push([t('logs.dt.port'), h('span', { class: 'mono' }, port || '—'), port]);
      f.push([t('logs.dt.proto'), h('span', { class: 'mono' }, str(r.net).toUpperCase() || '—'), str(r.net).toUpperCase()]);
      f.push([t('logs.col.app'), h('span', { class: 'log-dtapp' }, appBox(r.app), h('span', null, str(r.app) || '—')), str(r.app)]);
      if (r.path) f.push([t('logs.dt.path'), h('span', { class: 'mono lgd-text' }, str(r.path)), str(r.path)]);
      if (r.user) f.push([t('logs.dt.user'), h('span', { class: 'mono' }, str(r.user)), str(r.user)]);
      f.push([t('logs.col.route'), routeBadge(r.route), own(ROUTE_ICON, r.route) ? TP.name.route(r.route) : t('logs.route.other')]);
      f.push([t('logs.col.node'), r.node ? h('span', { class: 'mono lgd-text' }, str(r.node)) : '—', str(r.node)]);
      if (why) f.push([t('logs.dt.reason'), why, why]);
      f.push([t('logs.dt.result'), r.err ? ui.badge(errText(r.err), 'bad', 'error') : ui.badge(t('logs.result.ok'), 'ok', 'success'), r.err ? errText(r.err) : t('logs.result.ok')]);
      if (r.errmsg) f.push([t('logs.dt.errmsg'), h('span', { class: 'mono lgd-msg' }, str(r.errmsg)), str(r.errmsg)]);
      if (r.dur && r.err) f.push([t('logs.dt.dur'), h('span', { class: 'mono' }, str(r.dur)), str(r.dur)]);
      if (r.capture) f.push([t('logs.dt.capture'), r.capture === 'tun' ? 'TUN' : 'System Proxy', r.capture]);
      if (r.ips) f.push([t('logs.dt.ips'), h('span', { class: 'mono lgd-text' }, str(r.ips)), str(r.ips)]);
    } else {
      f.push([t('logs.col.level'), levelBadge(r.level), str(r.level).toUpperCase()]);
      f.push([t('logs.col.msg'), h('span', { class: 'mono lgd-msg' }, str(r.msg) || '—'), str(r.msg)]);
    }
    return f;
  }
  function openRow(k, i) {
    var rows = T[k].view.slice(), idx = i, api, f = {}, body;                              // 按列表里显示的顺序 (排序后) 翻页
    if (!rows.length || !rows[idx]) return;
    f.prev = ui.ibtn('chevron-left', L('logs.dt.prev')); f.next = ui.ibtn('chevron-right', L('logs.dt.next'));
    f.prev.addEventListener('click', function () { if (f.prev._un) ui.unavailable(f.prev); else step(-1); });
    f.next.addEventListener('click', function () { if (f.next._un) ui.unavailable(f.next); else step(1); });
    f.pos = h('span', { class: 'lgd-pos sm', 'aria-live': 'polite' });
    f.box = h('dl', { class: 'lgd-kv' });
    body = h('div', { class: 'lgd' }, h('div', { class: 'lgd-top' }, h('span', { class: 'lgd-type muted sm' }, ui.icon(TAB_ICON[k], 14, 'ci'), L('logs.tab.' + k)), h('span', { class: 'lgd-nav' }, f.prev, f.pos, f.next)), f.box);
    function step(d) { idx = Math.max(0, Math.min(rows.length - 1, idx + d)); paint(); }
    function paint() {
      var r = rows[idx] || {};
      setText(f.pos, t('logs.dt.pos', { i: idx + 1, n: rows.length }));
      ui.avail(f.prev, idx > 0 ? '' : t('logs.dt.first')); ui.avail(f.next, idx < rows.length - 1 ? '' : t('logs.dt.last'));
      TP.clear(f.box);
      fieldsOf(k, r).forEach(function (x) { f.box.appendChild(h('div', { class: 'lgd-r' }, h('dt', null, x[0]), h('dd', null, x[1]))); });
    }
    api = ui.modal({
      title: t('logs.dt.title'), icon: TAB_ICON[k], iconKind: 'info', size: 'md', body: body,
      actions: [
        { label: t('common.copy'), icon: 'copy', keep: true, onClick: function () {
          ui.copy(fieldsOf(k, rows[idx] || {}).map(function (x) { return x[0] + ': ' + x[2]; }).join('\n'));
          return false;
        } },
        { label: t('common.close'), kind: 'primary', cancel: true }
      ]
    });
    api.el.addEventListener('keydown', function (ev) {                    // ← → 在本页的各条之间切换
      if ((ev.key !== 'ArrowLeft' && ev.key !== 'ArrowRight') || /^(INPUT|TEXTAREA|SELECT)$/.test(ev.target.tagName)) return;
      ev.preventDefault(); step(ev.key === 'ArrowLeft' ? -1 : 1);
    });
    paint();
  }

  /* ================= 加载 ================= */
  function rowSig(r) { return r ? [r.ts, r.who, r.action, r.detail, r.result, r.host, r.port, r.app, r.route, r.node, r.reason, r.err, r.level, r.msg].join('\u0001') : ''; }
  function sameRows(a, b) {
    var m;
    if (a.length !== b.length) return false;
    if (!a.length) return true;
    m = a.length >> 1;
    return rowSig(a[0]) === rowSig(b[0]) && rowSig(a[m]) === rowSig(b[m]) && rowSig(a[a.length - 1]) === rowSig(b[b.length - 1]);
  }
  /* 换了日期 / 清除了日志: 所有标签的数据作废, 页码回到第 1 页 */
  function invalidate() {
    TYPES.forEach(function (k) { var tb = T[k]; tb.rows = []; tb.total = tb.base = 0; tb.sum = null; tb.key = ''; tb.loaded = tb.loading = false; tb.err = null; tb.gen++; tb.seq++; setPage(k, 1); });
  }

  /* mode: 'fresh' = 新读取 (刷新 / 换标签 / 换日期 / 换搜索 / 改每页条数): 返回的总数成为新的基准;
   *       'page'  = 翻页: offset 要加上「翻页期间新增的条数」(日志新→旧, 新增的在最前面, 不加的话相邻两页会重复几行), 总数基准不变, 新增的另外提示。
   * 翻页请求用的「新增条数」是上一次响应里的总数算出来的; 如果这次响应显示又新增了, 读到的这页就偏了几行, 再用新的条数重读一次 (只重读一次)。
   * 过期的响应 (seq 不匹配) 一律丢弃。 */
  async function load(k, mode, retried) {
    k = k || cur; mode = mode || 'fresh';
    var tb = T[k], pg = PG[k], my, size, page, off, r, rows, total, today, pr, used;
    if (S.locked) return;
    my = ++tb.seq; size = pg.size(); page = pg.page();
    used = mode === 'page' ? Math.max(0, tb.total - tb.base) : 0;
    off = (page - 1) * size + used;
    tb.loading = true;
    if (k === cur) render();
    try {
      r = await TP.helper('GET', '/api/logs', { q: { type: k, day: day, q: tb.q, f: tb.f, limit: size, offset: off }, timeout: 30000 });
    } catch (e) {
      if (my !== tb.seq) return;
      tb.loading = false;
      if (!(e && e.kind === 'auth')) {
        if (tb.loaded) { ui.toast(TP.errMsg(e), 'err'); if (tb.pageNo && tb.pageNo !== pg.page()) setPage(k, tb.pageNo); }     // 已有数据: 保留, 只提示 (分页条回到还显示着的那一页)
        else { tb.rows = []; tb.gen++; tb.err = e; }
      }
      if (k === cur) render();
      return;
    }
    if (my !== tb.seq) return;
    rows = Array.isArray(r && r.rows) ? r.rows : [];
    total = +(r && r.total); if (!(total >= 0)) total = rows.length;
    days = cleanDays(r && r.days);
    tb.sum = r && r.summary && typeof r.summary === 'object' ? r.summary : null;
    today = ymd(new Date());                                                                    // 决定显示哪一天 (第一次: 服务端按「今天」回答)
    if (!day) {
      if (days.indexOf(today) >= 0) day = today;
      else if (days.length) { day = days[0]; invalidate(); return load(k); }
    } else if (days.indexOf(day) < 0) {
      day = days.length ? days[0] : '';
      invalidate();
      if (day) return load(k);
      rows = []; total = 0;
    }
    if (mode === 'page' && !retried && Math.max(0, total - tb.base) !== used) { tb.total = total; return load(k, 'page', true); }
    tb.err = null; tb.loading = false; tb.at = Date.now();
    if (mode !== 'page') tb.base = total;
    tb.total = total;
    pr = pg.update(Math.min(tb.base, CAP));                                                     // 分页条按基准总数 (最多 CAP 条); 总数变少了页码会被钳制 -> 重新读那一页
    if (pr.page !== page) return load(k);
    if (!(tb.loaded && tb.key === qkey(k) && sameRows(tb.rows, rows))) { tb.rows = rows; tb.gen++; }
    tb.key = qkey(k); tb.loaded = true; tb.pageNo = page;
    if (k === cur) render();
  }

  /* ================= 渲染 ================= */
  function render() {
    if (!el.list || !active()) return;
    renderToolbar(); renderFilters(); renderNotice(); renderBody();
    setText(el.foot, t('logs.foot', { keep: hoursLabel(keepHours()) }));
  }
  V.render = render;

  function renderToolbar() {
    var k = cur, tb = T[k], why = TP.why.helper(), sig = I.lang + '|' + days.join(','), ph = t('logs.search.' + k);
    if (el.day._sig !== sig) {
      el.day._sig = sig; TP.clear(el.day);
      if (days.length) days.forEach(function (d) { el.day.appendChild(TP.opt(d, fmt.day(d))); });
      else el.day.appendChild(TP.opt('', t('logs.day.none')));
    }
    if (days.length && el.day.value !== day) el.day.value = day;
    ui.avail(el.day, days.length ? '' : t('logs.day.noneWhy'));
    if (el.q.placeholder !== ph) { el.q.placeholder = ph; el.q.setAttribute('aria-label', ph); }
    ui.avail(el.exp, why);
    ui.avail(el.clr, why || (tb.loaded && !days.length ? t('logs.clear.nothing') : ''));
    el.liveWrap.hidden = k === 'ops';                                                           // 操作记录不会「实时」滚动, 不显示这个开关
  }

  /* 筛选按钮: 每个标签一组, 只显示当前标签的; 按钮上的数字来自服务端的汇总 (搜索之后、筛选之前) */
  function setSegLabel(seg, v, text) {
    var inp = seg.inputs[v], sl = inp && inp.parentNode && inp.parentNode.querySelector('.sl');
    if (sl && sl.textContent !== text) sl.textContent = text;
  }
  function renderFilters() {
    var k = cur, sm = T[k].sum || {}, seg;
    TYPES.forEach(function (x) { segs[x].el.hidden = x !== k; });
    seg = segs[k];
    FILTERS[k].forEach(function (v) {
      var n = v === '' ? sm.all : v === 'error' ? sm.error : v === 'warn' ? (+sm.warn || 0) + (+sm.error || 0) : v === 'direct' ? sm.direct : v === 'proxy' ? sm.proxy : null;
      setSegLabel(seg, v, t('logs.f.' + (v || 'all') + (k === 'proxy' && v === 'error' ? 'Only' : '')) + (n != null && T[k].loaded ? ' ' + fmt.num(+n || 0) : ''));
    });
    seg.set(T[k].f);
    renderSummary();
  }
  /* 汇总行 (网站访问): 直连原因分布 + 失败最多的网站 (点一下就把它填进搜索框) */
  function renderSummary() {
    var k = cur, sm = T[k].sum, box = el.sumx, parts = [], rs, top;
    TP.clear(box);
    if (k !== 'access' || !sm || !T[k].loaded || !(+sm.all > 0)) { box.hidden = true; return; }
    rs = sm.reasons && typeof sm.reasons === 'object' ? sm.reasons : {};
    Object.keys(rs).filter(function (r) { return own(REASONS, r) && rs[r] > 0; }).sort(function (a, b) { return rs[b] - rs[a]; }).forEach(function (r) { parts.push(t('logs.sum.reason', { why: reasonText(r), n: fmt.num(rs[r]) })); });
    if (parts.length) box.appendChild(h('span', { class: 'log-sx' }, h('b', null, t('logs.sum.direct')), ' ', parts.join(' · ')));
    top = Array.isArray(sm.top_fail) ? sm.top_fail : [];
    if (top.length) {
      box.appendChild(h('span', { class: 'log-sx' }, h('b', null, t('logs.sum.fail')), ' ', top.map(function (x) {
        var b = h('button', { class: 'log-tf', type: 'button', title: t('logs.sum.failTip', { host: str(x.host) }) }, str(x.host), h('i', null, ' ×' + fmt.num(+x.n || 0)), x.err ? h('span', { class: 'muted' }, ' ' + errText(x.err)) : null);
        b.addEventListener('click', function () { el.q.value = str(x.host); applySearch(); });
        return b;
      })));
    }
    box.hidden = !box.childNodes.length;
  }

  /* 提示条: 关闭了对应的记录 / 代理总开关关闭 / 现在没有流量经过 enana */
  function renderNotice() {
    var k = cur, tb = T[k], st = S.state, off = null, key = '', info = '', flow = false;
    if (k === 'ops' && !opsOn()) key = 'logs.opsOff.banner';
    else if (k === 'proxy' && !coreOn()) key = 'logs.coreOff.banner';
    else if (k === 'access' && accessOn() === false && tb.loaded && tb.rows.length > 0) key = 'logs.accOff.banner';
    else if (k === 'proxy' && accessOn() === false) key = 'logs.proxyQuiet.banner';
    el.notice.hidden = !key; if (key) setText(el.noticeTxt, t(key));
    if (k === 'access' && st && st.env) flow = st.env.sysproxy === false || st.env.service === false;       // 系统代理没有指向 enana / 服务没有运行: 浏览器的流量不经过这里
    if (k === 'access' && !flow && st && st.proxy && st.proxy.enabled === false) info = 'logs.note.master';
    el.flow.hidden = !flow; el.info.hidden = !info; if (info) setText(el.infoTxt, t(info));
  }

  function renderBody() {
    var k = cur, tb = T[k], n = tb.rows.length, mode = !tb.loaded ? (tb.err ? 'error' : 'loading') : (n ? 'list' : 'empty'), q = tb.q;
    el.panel.setAttribute('aria-labelledby', tabsCtl.btn(k).id);
    el.panel.setAttribute('aria-busy', tb.loading ? 'true' : 'false');
    el.head.hidden = el.list.hidden = mode !== 'list';
    el.list.classList.toggle('is-loading', tb.loading && tb.loaded);
    TYPES.forEach(function (x) { PG[x].wrap.hidden = x !== k || mode !== 'list'; });
    if (mode === 'list') { syncHead(k); syncRows(k); }
    else if (el.list._b) { TP.clear(el.list); el.list._b = null; }                          // 不显示列表时, 释放已渲染的行
    if (mode === 'loading') el.empty.show({ icon: 'refresh', text: t('common.loading') });
    else if (mode === 'error') {
      el.empty.show({ icon: 'warning', text: tb.err.kind === 'unreachable' ? (TP.why.helper() || TP.errMsg(tb.err)) : TP.errMsg(tb.err), action: { label: t('common.retry'), icon: 'refresh', fn: function () { return load(cur); } } });
    } else if (mode === 'empty') {
      if (q) el.empty.show({ icon: 'search', text: t('logs.empty.search', { q: q }), hint: t('logs.empty.searchHint'), action: { label: t('logs.empty.clearSearch'), icon: 'x', fn: clearSearch } });
      else if (tb.f) el.empty.show({ icon: 'funnel', text: t('logs.empty.filter'), hint: t('logs.empty.filterHint'), action: { label: t('logs.empty.clearFilter'), icon: 'x', fn: function () { setFilter(cur, ''); } } });
      else if (k === 'access' && accessOn() === false) el.empty.show({ icon: 'eye-off', text: t('logs.accOff.title'), hint: t('logs.accOff.hint'), action: { label: t('logs.accOff.action'), icon: 'settings', fn: function () { return LG.openSettings(); } } });
      else if (k === 'ops' && !opsOn()) el.empty.show({ icon: 'eye-off', text: t('logs.opsOff.title'), hint: t('logs.opsOff.hint'), action: { label: t('logs.accOff.action'), icon: 'settings', fn: function () { return LG.openSettings(); } } });
      else if (k === 'proxy' && !coreOn()) el.empty.show({ icon: 'eye-off', text: t('logs.coreOff.title'), hint: t('logs.coreOff.hint'), action: { label: t('logs.accOff.action'), icon: 'settings', fn: function () { return LG.openSettings(); } } });
      else if (!days.length) el.empty.show({ icon: 'history', text: t('logs.empty.none'), hint: t('logs.empty.noneHint') });
      else el.empty.show({ icon: 'history', text: t('logs.empty.day'), hint: t('logs.empty.dayHint') });
    } else el.empty.hide();

    // 摘要 (总数以「新读取」时的为准; 之后新增的在最新一端, 另外提示) + 超过上限的说明
    var capped = mode === 'list' && tb.base > CAP, newer = mode === 'list' ? Math.max(0, tb.total - tb.base) : 0;
    el.sum.hidden = mode !== 'list';
    if (mode === 'list') setText(el.sumTxt, t('logs.count', { n: tb.base, num: fmt.num(tb.base) }));
    el.newerBtn.hidden = !newer || liveOn();
    if (newer && !liveOn()) ui.setBtn(el.newerBtn, t('logs.newer', { n: newer, num: fmt.num(newer) }), 'refresh');
    el.capNote.hidden = !capped;
    if (capped) setText(el.capNote, t('logs.capNote', { n: fmt.num(CAP) }));
  }

  /* ================= 交互 ================= */
  function pickTab(id, noSave) {
    if (TYPES.indexOf(id) < 0) return;
    clearTimeout(qTimer);
    cur = id; if (!noSave) TP.prefs.set(PK.tab, id); tabsCtl.set(id);
    el.q.value = T[id].q;
    if (!active()) return;
    if (!T[id].loaded || T[id].key !== qkey(id) || Date.now() - T[id].at > 20000) load(id); else render();
  }
  function applySearch() {
    clearTimeout(qTimer);
    var v = el.q.value.trim(), tb = T[cur];
    if (v === tb.q) return;
    tb.q = v; setPage(cur, 1); load(cur);
  }
  function clearSearch() { el.q.value = ''; applySearch(); }
  function setFilter(k, v) {
    if (T[k].f === v) return;
    T[k].f = v; setPage(k, 1); load(k);
  }
  function setDay(want) {
    if (!want || want === day) return;
    day = want; invalidate();
    return load(cur);
  }
  /* 用户翻页 / 改每页条数 (其它标签的分页条被改 (别的设备同步过来) 时, 只作废它的数据, 下次切过去再读) */
  function onPager(k) {
    var size = PG[k].size(), sizeChanged = size !== lastSize[k];
    lastSize[k] = size;
    if (quiet) return;
    if (k !== cur || !active()) { T[k].key = ''; T[k].at = 0; return; }
    toTop(el.bar);
    load(k, sizeChanged ? 'fresh' : 'page');
  }

  /* 实时: 每 5 秒重新读一次当前标签 (只在日志页可见、选的是今天、停在第 1 页、没有请求在路上时); 只在内容真的变了才重画 */
  function liveOn() { return !!(el.liveSw && el.liveSw.checked) && cur !== 'ops'; }
  function liveTick() {
    var tb = T[cur];
    if (!liveOn() || !active() || document.hidden || tb.loading || S.locked || PG[cur].page() !== 1 || day !== ymd(new Date())) return;
    load(cur);
  }
  function setLive(on) {
    clearInterval(liveTimer); liveTimer = 0;
    if (on) { liveTimer = setInterval(liveTick, LIVE_MS); liveTick(); }
    render();
  }

  /* ================= 导出: 一个按钮 → 选内容和时间范围 → 一个自描述的文本文件 (含环境与策略快照, 方便排查问题) ================= */
  var EXP_SECS = [{ id: 'ops', icon: 'history' }, { id: 'access', icon: 'globe' }, { id: 'proxy', icon: 'terminal' }, { id: 'snapshot', icon: 'file-text' }];
  function openExport() {
    var why = TP.why.helper();
    if (why) { ui.toast(why, 'warn'); return Promise.resolve(); }
    var sel = {}, range = '24', boxes = {}, rInputs = {}, rLabs = {}, go, note, api, u = usageOf(), keep = keepHours();
    EXP_SECS.forEach(function (x) { sel[x.id] = true; });
    function approx(hours) {                                                       // 大致大小: 全部保留的日志按实际占用; 其它按占「保留时长」的比例估算
      if (!u || !(u.total > 0)) return '';
      return fmt.bytes(hours === 'all' ? u.total : Math.min(u.total, u.total * (+hours) / keep));
    }
    function syncGo() {
      var none = !EXP_SECS.some(function (x) { return sel[x.id]; });
      if (go) ui.avail(go, none ? t('logs.exp.pickOne') : '');
    }
    var secBox = h('div', { class: 'log-opts pri', role: 'group', 'aria-label': t('logs.exp.contentAria') }, EXP_SECS.map(function (x) {
      var inp = h('input', { type: 'checkbox' }), lab;
      inp.checked = true; boxes[x.id] = inp;
      lab = h('label', { class: 'log-opt on' }, inp, h('span', { class: 'log-opt-ic' }, ui.icon(x.icon, 18, 'ci')), h('span', { class: 'log-opt-b' }, h('b', null, t('logs.exp.sec.' + x.id)), h('span', { class: 'muted sm' }, t('logs.exp.sec.' + x.id + '.d'))));
      inp.addEventListener('change', function () { sel[x.id] = inp.checked; lab.classList.toggle('on', inp.checked); syncGo(); });
      return lab;
    }));
    var rangeBox = h('div', { class: 'log-opts pri', role: 'radiogroup', 'aria-label': t('logs.exp.rangeAria') }, ['6', '24', 'all'].map(function (v) {
      var inp = h('input', { type: 'radio', name: 'log-exp-range', value: v }), lab, hint = v === 'all' ? t('logs.exp.range.allHint', { keep: hoursLabel(keep), size: approx('all') || '—' }) : (approx(v) ? t('logs.exp.range.hint', { size: approx(v) }) : '');
      inp.checked = v === range; rInputs[v] = inp;
      lab = h('label', { class: 'log-opt' + (v === range ? ' on' : '') }, inp, h('span', { class: 'log-opt-b' }, h('b', null, t('logs.exp.range.' + v)), hint ? h('span', { class: 'muted sm' }, hint) : null));
      rLabs[v] = lab;
      inp.addEventListener('change', function () { range = v; Object.keys(rLabs).forEach(function (k) { rLabs[k].classList.toggle('on', k === v); }); });
      return lab;
    }));
    note = h('p', { class: 'muted sm log-exp-note', 'aria-live': 'polite' }, t('logs.exp.privacy'));
    api = ui.modal({
      title: t('logs.exp.title'), icon: 'download', iconKind: 'pri', size: 'md',
      body: h('div', { class: 'log-exp' }, h('p', { class: 'muted' }, t('logs.exp.intro')), secBox, h('div', { class: 'fld-l' }, t('logs.exp.rangeAria')), rangeBox, note),
      actions: [
        { label: t('common.cancel'), cancel: true },
        { label: t('logs.exp.go'), kind: 'primary', icon: 'download', id: 'go', onClick: async function (a) {
          var secs = EXP_SECS.filter(function (x) { return sel[x.id]; }).map(function (x) { return x.id; }), r, txt, name, why2 = TP.why.helper();
          if (!secs.length) { ui.toast(t('logs.exp.pickOne'), 'warn'); return false; }
          if (why2) { ui.toast(why2, 'warn'); return false; }
          setText(note, t(secs.indexOf('snapshot') >= 0 ? 'logs.exp.busy' : 'common.loading'));   // i18n-ignore (分区名 snapshot 不是词典键)
          a.setBusy(true);
          try { r = await TP.helper('GET', '/api/logs/bundle', { q: { hours: range, sections: secs.join(',') }, text: true, timeout: 180000 }); }
          finally { a.setBusy(false); setText(note, t('logs.exp.privacy')); }
          txt = r && typeof r.text === 'string' ? r.text : '';
          if (!txt.trim()) { ui.toast(t('logs.export.none'), 'warn'); return false; }
          name = 'enana-diagnostics-' + stamp() + '.txt';
          download(name, txt);
          ui.toast(t('logs.export.done', { name: name }), 'ok');
        } }
      ]
    });
    go = api.getBtn('go'); syncGo();
    return api.closed;
  }

  /* 清除: 选范围 -> 危险确认 (说清楚删什么、不能撤销) -> POST (需要再次输入登录密码: 密码框由 TP.helper 弹出, 取消 = 安静地回到这个对话框) -> 提示释放的空间 -> 重新加载
   * 注意: 「网站访问」是从代理日志里归并出来的, 两者共用同一批文件, 清除其中一个就是清除两个 (后端 logs_clear 的行为)。 */
  function openClear() {
    var why = TP.why.helper();
    if (why) { ui.toast(why, 'warn'); return Promise.resolve(); }
    var type = cur, selDay = day, tname = t('logs.tab.' + type), older = selDay ? days.filter(function (d) { return d < selDay; }).length : 0;
    var u = usageOf(), choice = older ? 'before' : 'type', inputs = {}, note, group, api;
    var opts = [
      { v: 'type', label: t('logs.clear.optType', { type: tname }), desc: u ? t('logs.clear.use', { size: fmt.bytes(type === 'ops' ? u.ops : u.proxy) }) : '' },
      { v: 'before', label: t('logs.clear.optBefore', { type: tname, day: selDay ? dayLabel(selDay) : '' }), desc: t('logs.clear.keepDay'), why: !selDay ? t('logs.clear.noDay') : older ? '' : t('logs.clear.noOlder') },
      { v: 'all', label: t('logs.clear.optAll'), desc: u ? t('logs.clear.use', { size: fmt.bytes(u.total) }) : '' }
    ];
    function sync() {
      Object.keys(inputs).forEach(function (v) { inputs[v].checked = v === choice; inputs[v].parentNode.classList.toggle('on', v === choice); });
      note.hidden = !(type !== 'ops' && choice !== 'all');
    }
    note = h('p', { class: 'hint warn' }, t('logs.clear.sharedNote'));
    group = h('div', { class: 'log-opts', role: 'radiogroup', 'aria-label': t('logs.clear.aria') }, opts.map(function (o) {
      var inp = h('input', { type: 'radio', name: 'log-clear', value: o.v }), lab = h('label', { class: 'log-opt' + (o.why ? ' unavail' : '') }, inp, h('span', { class: 'log-opt-b' }, h('b', null, o.label), o.desc ? h('span', { class: 'muted sm' }, o.desc) : null));
      if (o.why) { inp.setAttribute('aria-disabled', 'true'); lab.title = o.why; }
      inp.addEventListener('click', function (ev) {
        if (o.why) { ev.preventDefault(); ui.toast(o.why, 'warn', 4200); return; }
        choice = o.v; sync();
      });
      inputs[o.v] = inp;
      return lab;
    }));
    api = ui.modal({
      title: t('logs.clear.title'), icon: 'delete', iconKind: 'bad', size: 'md',
      body: h('div', { class: 'log-clear' }, h('p', { class: 'muted' }, t('logs.clear.intro')), group, note),
      actions: [
        { label: t('common.cancel'), cancel: true },
        { label: t('logs.clear.go'), kind: 'danger', icon: 'delete', id: 'go', onClick: async function (a) {
          var why2 = TP.why.helper(), form = { type: choice === 'all' ? 'all' : type }, msg, det = [], ok, r, freed;
          if (why2) { ui.toast(why2, 'warn'); return false; }
          if (choice === 'before') { form.before = selDay; msg = t('logs.clear.msgBefore', { type: tname, day: dayLabel(selDay) }); det.push(t('logs.clear.dBefore', { day: dayLabel(selDay) })); }
          else if (choice === 'type') msg = t('logs.clear.msgType', { type: tname });
          else msg = t('logs.clear.msgAll');
          if (choice !== 'all' && type !== 'ops') det.push(t('logs.clear.sharedNote'));
          det.push(t('logs.clear.irreversible'));
          ok = await ui.confirmDialog({ title: t('logs.clear.confirmTitle'), message: msg, detail: det, confirmText: t('logs.clear.confirmGo'), danger: true });
          if (!ok) return false;
          a.setBusy(true);
          try { r = await TP.helper('POST', '/api/logs/clear', { form: form, timeout: 60000 }); } finally { a.setBusy(false); }      // 403 E_SUDO_REQUIRED: TP.helper 弹出密码框并重试; 取消 -> 抛出 kind 'cancel' (ui.modal 安静地忽略)
          freed = r && +r.freed > 0 ? +r.freed : 0;
          ui.toast(freed ? t('logs.clear.freed', { size: fmt.bytes(freed) }) : t('logs.clear.freedNone'), 'ok');
          loadPrefs(); invalidate(); load(cur);
        } }
      ]
    });
    if (TP.sudo && TP.sudo.mark) TP.sudo.mark(api.getBtn('go'));
    sync();
    return api.closed;
  }

  /* ================= 页面 ================= */
  V.init = function (root) {
    tabsCtl = ui.tabs(L('logs.tabs.aria'), TYPES.map(function (k) { return { id: k, label: L('logs.tab.' + k), icon: TAB_ICON[k] }; }), pickTab);
    tabsCtl.set(cur);

    el.day = h('select', { class: 'sel log-day', 'aria-label': L('logs.day.aria') });
    ui.selectAct(el.day, function () { return day; }, function (want) { return setDay(want); });
    el.q = h('input', { class: 'inp', type: 'search', autocomplete: 'off', spellcheck: 'false', on: {
      input: function () { clearTimeout(qTimer); qTimer = setTimeout(applySearch, 300); },
      search: applySearch,
      keydown: function (e) { if (e.key === 'Enter') applySearch(); }
    } });
    el.refresh = ui.ibtn('refresh', L('common.refresh')); ui.act(el.refresh, function () { return load(cur); });
    el.liveSw = h('input', { type: 'checkbox', role: 'switch', 'aria-label': L('logs.live.aria') });
    el.liveSw.addEventListener('change', function () { setLive(el.liveSw.checked); });
    el.liveWrap = h('label', { class: 'log-live', title: L('logs.live.tip') }, h('span', { class: 'sw' }, el.liveSw, h('span', { class: 'sw-ui' })), h('span', { class: 'log-live-t' }, L('logs.live')));
    el.exp = ui.btn(L('common.export'), { icon: 'download', title: L('logs.export.tip') }); ui.act(el.exp, openExport);
    el.clr = ui.btn(L('logs.clear.btn'), { icon: 'delete', cls: 'soft-bad' }); ui.act(el.clr, openClear);
    if (TP.sudo && TP.sudo.mark) TP.sudo.mark(el.clr);
    el.set = ui.btn(L('logs.settings.btn'), { icon: 'settings' }); ui.act(el.set, function () { return LG.openSettings(); });

    el.noticeTxt = h('span');
    el.noticeBtn = ui.btn(L('logs.accOff.action'), { sm: true, icon: 'settings' }); ui.act(el.noticeBtn, function () { return LG.openSettings(); });
    el.notice = h('div', { class: 'hint warn log-notice', role: 'status', hidden: true }, el.noticeTxt, el.noticeBtn);
    el.infoTxt = h('span');
    el.info = h('div', { class: 'hint info log-notice', role: 'status', hidden: true }, ui.icon('info', 16, 'ci'), el.infoTxt);
    el.flowBtn = ui.btn(L('logs.note.noflowGo'), { sm: true, icon: 'nav-overview' }); ui.act(el.flowBtn, function () { TP.go('overview'); });
    el.flow = h('div', { class: 'hint warn log-notice', role: 'status', hidden: true }, h('span', null, L('logs.note.noflow')), el.flowBtn);
    el.sumTxt = h('span');
    el.newerBtn = ui.btn(L('logs.newer', { n: 0, num: '0' }), { sm: true, icon: 'refresh', cls: 'soft-warn' }); el.newerBtn.hidden = true;
    ui.act(el.newerBtn, function () { setPage(cur, 1); return load(cur); });
    el.sum = h('div', { class: 'muted sm log-sum', hidden: true }, el.sumTxt, el.newerBtn);
    el.sumx = h('div', { class: 'log-sumx muted sm', hidden: true });
    el.head = h('div', { class: 'log-head', hidden: true });                                   // 列头里有排序按钮, 不能 aria-hidden
    el.list = h('ul', { class: 'log-list', 'aria-label': L('logs.list.aria'), hidden: true });
    el.empty = ui.emptyBox();
    el.capNote = h('p', { class: 'muted sm log-cap', hidden: true });
    el.pgBox = h('div', { class: 'log-pg' });
    TYPES.forEach(function (k) {
      SO[k] = ui.sorter('logs.' + k, SORT_COLS[k], { onChange: function () { render(); } });     // 只重排已读到的这一页, 不换页 (服务端分页)
      PG[k] = ui.pager('logs.' + k, { sizes: [20, 50, 100], def: 50 });
      lastSize[k] = PG[k].size();
      PG[k].wrap = h('div', { class: 'log-pgw', hidden: true }, PG[k].el);
      PG[k].onChange(function () { onPager(k); });
      el.pgBox.appendChild(PG[k].wrap);
      setPage(k, 1);                                                                           // 每次打开页面都从最新的一页看起 (每页条数照常记住)
      segs[k] = ui.seg(L('logs.filter.aria'), FILTERS[k].map(function (v) { return { v: v, label: L('logs.f.' + (v || 'all') + (k === 'proxy' && v === 'error' ? 'Only' : '')) }; }), function (v) { setFilter(k, v); }, { onSame: function () { } });
      segs[k].set('');
    });
    el.filt = h('div', { class: 'log-filt' }, TYPES.map(function (k) { return segs[k].el; }));
    el.panel = h('div', { class: 'log-panel', role: 'tabpanel' }, el.notice, el.flow, el.info, el.sumx, el.sum, h('section', { class: 'card flush log-card' }, el.head, el.list, el.empty.el, el.pgBox), el.capNote);
    el.foot = h('p', { class: 'muted sm log-foot' });
    el.bar = h('div', { class: 'toolbar log-bar' }, el.day, el.q, el.refresh, el.liveWrap, el.exp, withHelp(el.clr, HT.clear), el.set);

    root.appendChild(h('div', { class: 'intro' }, h('p', { class: 'muted' }, L('logs.intro'), ' ', ui.help(HT.page))));
    root.appendChild(h('div', { class: 'log-tabs' }, tabsCtl.el, ui.help(HT.tabs)));
    root.appendChild(el.bar);
    root.appendChild(el.filt);
    root.appendChild(el.panel);
    root.appendChild(el.foot);

    /* 点一行 = 打开详情 (链接 / 输入框自己处理; 正在选中文字时不打开 —— 日志里的文字是要拿来复制的) */
    el.list.addEventListener('click', function (ev) {
      var li = ev.target.closest ? ev.target.closest('li.log-row') : null, sel = window.getSelection ? window.getSelection() : null;
      if (!li || li._i == null || ev.target.closest('a,input,select,textarea')) return;
      if (sel && !sel.isCollapsed && String(sel).length && li.contains(sel.anchorNode)) return;
      openRow(cur, li._i);
    });

    TP.on('lang', function () { render(); });
    TP.on('helper', function (up) { if (!active()) return; if (up && T[cur].err) load(cur); else render(); });
    TP.on('settings', function () { if (active()) render(); });
    TP.on('state', function () { if (active()) renderNotice(); });
    TP.on('auth', function (ok) { if (ok && active()) V.show(); });
    TP.on('prefs', function (d) {                                                              // 别的设备同步过来 / 登录后读到本机的偏好
      if (!d || !(d.all || d.key === PK.tab)) return;
      var id = pickType(TP.prefs.get(PK.tab, 'ops'));
      if (id !== cur) pickTab(id, true);
    });
  };

  /* 从别的页面跳到「日志」并搜索 (应用详情的「查看访问记录」): 先设好标签和搜索词, 再切到日志页 (V.show 会按这个搜索读数据) */
  LG.search = function (type, q) {
    if (!el.q || TYPES.indexOf(type) < 0) { TP.go('logs'); return; }
    pickTab(type, true);
    T[type].q = String(q || '').trim(); el.q.value = T[type].q; setPage(type, 1);
    TP.go('logs');
  };
  V.show = function () {
    loadPrefs();
    render();
    load(cur);
  };

  /* ================= 日志设置 (设置页的卡片 / 日志页的弹窗共用) ================= */
  var panels = [], busy = {}, want = {};            // busy[开关] = 正在应用 (核心重启) / want[开关] = 用户想要的值

  function setRow(main, ctl) { return h('div', { class: 'log-set-row' }, h('div', { class: 'log-set-main' }, main), ctl); }
  function swRow(kind, helpTopic, inp) {
    return setRow([h('div', { class: 'log-set-hd' }, h('b', { class: 'log-set-t' }, L('logs.' + kind + '.title')), helpTopic ? ui.help(helpTopic) : null), h('div', { class: 'muted sm' }, L('logs.' + kind + '.desc'))], h('label', { class: 'sw' }, inp, h('span', { class: 'sw-ui' })));
  }
  var KIND = { ops: opsOn, acc: function () { return accessOn() === true; }, core: coreOn, diag: diagOn };      // 开关 -> 当前值 (acc = 网站访问)

  function makePanel() {
    var P = { seen: false };
    P.warn = h('p', { class: 'hint warn log-set-warn', hidden: true });
    P.keep = h('b', { class: 'log-set-t' });
    P.chg = ui.btn(L('logs.set.change'), { sm: true, icon: 'edit' }); ui.act(P.chg, openRetention);
    P.sw = {};
    ['ops', 'acc', 'core', 'diag'].forEach(function (k) {
      var inp = h('input', { type: 'checkbox', role: 'switch', 'aria-label': L('logs.' + k + '.aria') });
      ui.switchAct(inp, function () { return busy[k] ? want[k] : KIND[k](); }, function (w) { return toggleLog(k, w); });
      P.sw[k] = inp;
    });
    P.send = ui.btn(L('logs.diag.send'), { sm: true, icon: 'upload' }); ui.act(P.send, sendDiag);
    P.del = ui.btn(L('logs.diag.del'), { sm: true, icon: 'trash' }); ui.act(P.del, deleteDiag);
    P.useSum = h('span', { class: 'muted sm' });
    P.bar = h('div', { class: 'log-use-bar', role: 'img' });
    P.leg = h('ul', { class: 'log-use-leg' });
    P.useNote = h('p', { class: 'muted sm log-use-note' });
    P.el = h('div', { class: 'log-set-body' },
      P.warn,
      setRow([h('div', { class: 'log-set-hd' }, P.keep, ui.help(HT.retention)), h('div', { class: 'muted sm' }, L('logs.set.keepHint'))], P.chg),
      swRow('ops', HT.ops, P.sw.ops),
      swRow('acc', HT.access, P.sw.acc),
      swRow('core', HT.core, P.sw.core),
      swRow('diag', null, P.sw.diag),
      setRow([h('div', { class: 'log-set-hd' }, h('b', { class: 'log-set-t' }, L('logs.diag.sendTitle'))), h('div', { class: 'muted sm' }, L('logs.diag.sendDesc'))], h('div', null, P.send, ' ', P.del)),
      h('div', { class: 'log-set-row log-use' }, h('div', { class: 'log-set-main' }, h('div', { class: 'log-use-h' }, h('b', { class: 'log-set-t' }, L('logs.use.title')), P.useSum), P.bar, P.leg, P.useNote)));
    P.render = function () {
      var p = prefs(), why = TP.why.helper(), wait = p ? '' : t('logs.set.loadingWhy');
      setText(P.keep, p ? t('logs.set.keep', { keep: hoursLabel(keepHours()) }) : t('logs.set.loading'));
      P.warn.hidden = !why; setText(P.warn, why);
      ui.avail(P.chg, why || wait);
      ui.avail(P.send, why || wait); ui.avail(P.del, why || wait);
      ['ops', 'acc', 'core', 'diag'].forEach(function (k) {
        var on = busy[k] ? want[k] : KIND[k]();
        if (P.sw[k].checked !== on) P.sw[k].checked = on;
        ui.avail(P.sw[k], why || wait || (busy[k] ? t('logs.acc.busy') : ''));
      });
      renderUsage(P);
    };
    panels.push(P);
    return P;
  }

  /* 占用空间: 组成条 (没有「配额」, 所以显示的是各部分占多少, 不是「用了百分之几」) + 图例。
   * 「网站访问」从代理日志里归并出来, 与代理日志是同一批文件: total = ops + proxy, 网站访问不再单独计入 (API.md 示例也是这样)。 */
  function renderUsage(P) {
    var u = usageOf(), sig = I.lang + '|' + (u ? [u.ops, u.access, u.proxy, u.total].join(',') : '-'), ops, acc, prx, total, shared, segs2;
    if (P._usig === sig) return;
    P._usig = sig; TP.clear(P.bar); TP.clear(P.leg);
    if (!u) { setText(P.useSum, t('logs.set.loading')); P.bar.hidden = P.leg.hidden = P.useNote.hidden = true; return; }
    ops = Math.max(0, +u.ops || 0); acc = Math.max(0, +u.access || 0); prx = Math.max(0, +u.proxy || 0); total = Math.max(0, +u.total || 0);
    shared = Math.abs(total - (ops + prx)) <= Math.abs(total - (ops + prx + acc));
    segs2 = [['ops', ops], ['proxy', prx]]; if (!shared) segs2.push(['access', acc]);
    P.bar.hidden = P.leg.hidden = !(total > 0); P.useNote.hidden = !(total > 0 && shared && acc > 0);
    setText(P.useSum, total > 0 ? t('logs.use.total', { size: fmt.bytes(total) }) : t('logs.use.none'));
    setText(P.useNote, t('logs.use.shared'));
    P.bar.setAttribute('aria-label', t('logs.use.aria', { list: I.intl.list([['ops', ops], ['access', acc], ['proxy', prx]].map(function (s) { return t('logs.tab.' + s[0]) + ' ' + fmt.bytes(s[1]); })) }));
    if (!(total > 0)) return;
    segs2.forEach(function (s) {
      if (!(s[1] > 0)) return;
      var seg = h('i', { class: 'log-k-' + s[0] });
      seg.style.width = (s[1] / total * 100).toFixed(2) + '%';                       // CSSOM (不用 style 属性, 兼容严格 CSP)
      P.bar.appendChild(seg);
    });
    [['ops', ops], ['access', acc], ['proxy', prx]].forEach(function (s) {
      P.leg.appendChild(h('li', null, h('span', { class: 'log-dot log-k-' + (s[0] === 'access' && shared ? 'proxy' : s[0]) }), h('span', null, t('logs.tab.' + s[0])), h('b', { class: 'num' }, fmt.bytes(s[1]))));
    });
  }

  function renderPanels() {
    panels = panels.filter(function (P) { P.seen = P.seen || document.contains(P.el); return !P.seen || document.contains(P.el); });     // 弹窗关掉后自动清理
    panels.forEach(function (P) { try { P.render(); } catch (e) { console.error('[logs] settings panel', e); } });
  }
  ['settings', 'lang', 'helper'].forEach(function (ev) { TP.on(ev, renderPanels); });
  TP.on('auth', function (ok) { if (ok && panels.length) loadPrefs(); });

  /* ---- 保留时长 (12 小时 – 30 天): 常用时长 + 自己填 (数字 + 单位) ---- */
  var PRESETS = [12, 24, 72, 168, 720];
  function openRetention() {
    var p = prefs(), why = TP.why.helper();
    if (!p) { ui.toast(t('logs.set.loadingWhy'), 'warn'); loadPrefs(); return Promise.resolve(); }
    if (why) { ui.toast(why, 'warn'); return Promise.resolve(); }
    var oldH = keepHours(), min = Math.max(1, +p.log_hours_min || 12), max = Math.max(min, +p.log_hours_max || 720), chips = {}, inp, unit, msg, group, form, api;
    inp = h('input', { class: 'inp log-days', type: 'number', min: '1', max: String(max), step: '1', inputmode: 'numeric', 'aria-label': t('logs.ret.custom') });
    unit = h('select', { class: 'sel log-unit', 'aria-label': t('logs.ret.unit') }, TP.opt('h', t('logs.ret.unitH')), TP.opt('d', t('logs.ret.unitD')));
    function put(hours) { var d = hours % 24 === 0 && hours >= 24; unit.value = d ? 'd' : 'h'; inp.value = String(d ? hours / 24 : hours); }
    function hoursNow() {
      var s = inp.value.trim(), n = /^\d{1,4}$/.test(s) ? parseInt(s, 10) : 0, hh = unit.value === 'd' ? n * 24 : n;
      return hh >= min && hh <= max ? hh : 0;
    }
    function sync() {
      var n = hoursNow();
      TP.setCls(msg, 'fld-h' + (n ? '' : ' bad-t')); setText(msg, n ? '' : t('logs.ret.err'));
      Object.keys(chips).forEach(function (k) { chips[k].setAttribute('aria-pressed', String(+k === n)); });
    }
    msg = h('div', { class: 'fld-h', 'aria-live': 'polite' });
    group = h('div', { class: 'log-presets', role: 'group', 'aria-label': t('logs.ret.presets') }, PRESETS.filter(function (n) { return n >= min && n <= max; }).map(function (n) {
      var b = h('button', { class: 'fchip', type: 'button', 'aria-pressed': 'false' }, hoursLabel(n));
      b.addEventListener('click', function () { put(n); sync(); });
      chips[n] = b;
      return b;
    }));
    inp.addEventListener('input', sync); unit.addEventListener('change', sync);
    put(oldH);
    form = h('form', { class: 'mform log-ret', novalidate: true }, h('p', { class: 'muted' }, t('logs.ret.intro')), group,
      ui.field(t('logs.ret.custom'), h('div', { class: 'log-ret-in' }, inp, unit), t('logs.ret.hint')), msg);
    api = ui.modal({
      title: t('logs.ret.title'), icon: 'history', iconKind: 'pri', size: 'sm', body: form,
      dirty: function () { return hoursNow() !== oldH; },
      actions: [
        { label: t('common.cancel'), cancel: true },
        { label: t('logs.ret.go'), kind: 'primary', icon: 'check', id: 'go', onClick: async function (a) {
          var n = hoursNow(), why2 = TP.why.helper(), shrink, ok;
          if (!n) { sync(); inp.focus(); return false; }
          if (n === oldH) { ui.toast(t('logs.ret.same', { keep: hoursLabel(n) }), ''); return false; }
          if (why2) { ui.toast(why2, 'warn'); return false; }
          shrink = n < oldH;
          ok = await ui.confirmDialog({
            title: t('logs.ret.confirmTitle'), message: t('logs.ret.confirmMsg', { old: hoursLabel(oldH), keep: hoursLabel(n) }),
            detail: shrink ? [t('logs.ret.dShrink', { keep: hoursLabel(n) }), t('logs.ret.irreversible')] : [t('logs.ret.dGrow'), t('logs.ret.dNothing')],
            confirmText: t('logs.ret.go'), danger: shrink
          });
          if (!ok) return false;
          a.setBusy(true);
          try { await TP.helper('POST', '/api/settings', { form: { log_hours: n } }); } finally { a.setBusy(false); }
          ui.toast(t('logs.ret.saved', { keep: hoursLabel(n) }), 'ok');
          await loadPrefs();
        } }
      ]
    });
    form.addEventListener('submit', function (ev) { ev.preventDefault(); var b = api.getBtn('go'); if (b) b.click(); });
    sync();
    return api.closed;
  }

  /* ---- 三个开关: 操作记录 (立即生效) / 网站访问 · 代理核心日志 (改配置需要重启核心: 先确认, 再用任务卡片跟进) ---- */
  var FORM = { ops: 'log_ops', acc: 'access_log', core: 'log_core', diag: 'diag_upload' };
  async function toggleLog(kind, w) {
    var why = TP.why.helper(), keep = hoursLabel(keepHours()), restart = kind === 'acc' || kind === 'core', ok, detail;
    if (why) { ui.toast(why, 'warn'); return; }
    if (busy[kind]) return;
    detail = w ? [t('logs.' + kind + '.onD1'), t('logs.' + kind + '.onD2', { keep: keep })] : [t('logs.' + kind + '.offD1')];
    if (restart) detail.push(t('logs.acc.restart'));
    ok = await ui.confirmDialog({
      title: t('logs.' + kind + (w ? '.onTitle' : '.offTitle')), message: t('logs.' + kind + (w ? '.onMsg' : '.offMsg')), detail: detail,
      confirmText: t('logs.' + kind + (w ? '.onGo' : '.offGo')), kind: w ? 'success' : 'warning'
    });
    if (!ok) return;
    busy[kind] = true; want[kind] = w; renderPanels();
    try {
      var form = {}; form[FORM[kind]] = w ? 1 : 0;
      if (restart) await TP.jobs.runInDock(t('logs.acc.job'), function () { return TP.helper('POST', '/api/settings', { form: form }); });
      else { await TP.helper('POST', '/api/settings', { form: form }); ui.toast(t('logs.' + kind + (w ? '.onDone' : '.offDone')), 'ok'); }
    } finally { busy[kind] = false; }
    await loadPrefs();
    renderPanels();
    if (active()) { invalidate(); load(cur); }
  }

  /* 发送完整诊断给开发者 (含访问过的域名 / 应用名, 所以必须用户确认) → 报告编号; 删除已上传的诊断 */
  function showReportCode(code) {
    var copy = ui.btn(t('common.copy'), { sm: true, icon: 'copy' });
    ui.act(copy, async function () { try { await navigator.clipboard.writeText(code); ui.toast(t('common.copied'), 'ok'); } catch (e) { ui.toast(t('common.copyFail'), 'warn'); } });
    return ui.modal({ title: t('logs.diag.sentTitle'), icon: 'upload', iconKind: 'pri', size: 'sm', body: h('div', null, h('p', null, t('logs.diag.sentMsg')), h('p', null, h('code', { class: 'mono' }, code), ' ', copy)), actions: [{ label: t('common.close'), kind: 'primary', cancel: true }] });
  }
  async function sendDiag() {
    var why = TP.why.helper(), ok, r, m;
    if (why) { ui.toast(why, 'warn'); return; }
    ok = await ui.confirmDialog({ title: t('logs.diag.sendTitle'), message: t('logs.diag.sendMsg'), detail: [t('logs.diag.sendD1'), t('logs.diag.sendD2')], confirmText: t('logs.diag.sendGo'), kind: 'warning' });
    if (!ok) return;
    r = await TP.jobs.runInDock(t('logs.diag.job'), function () { return TP.helper('POST', '/api/diag/send', { form: { hours: 24 } }); });
    m = r && r.ok && r.job && /[A-Za-z0-9]{15}/.exec(r.job.msg || '');
    if (m) showReportCode(m[0]);
  }
  async function deleteDiag() {
    var why = TP.why.helper(), ok, r;
    if (why) { ui.toast(why, 'warn'); return; }
    ok = await ui.confirmDialog({ title: t('logs.diag.delTitle'), message: t('logs.diag.delMsg'), confirmText: t('logs.diag.delGo'), kind: 'warning' });
    if (!ok) return;
    try { r = await TP.helper('POST', '/api/diag/delete'); ui.toast(t('logs.diag.delDone', { n: (r && r.deleted) || 0 }), 'ok'); }
    catch (e) { ui.toast(TP.errMsg(e) || t('logs.diag.delFail'), 'err'); }
  }

  LG.settingsCard = function () {
    var P = makePanel(), card = h('section', { class: 'card log-set' }, h('div', { class: 'card-h' }, ui.icon('nav-logs', 20, 'ci'), h('h2', null, L('logs.set.title')), h('span', { class: 'muted sm' }, L('logs.set.sub'))), P.el);
    P.render();
    return card;
  };
  LG.openSettings = function () {
    var P = makePanel(), api = ui.modal({ title: t('logs.settings.btn'), icon: 'settings', iconKind: 'pri', size: 'md', body: P.el, actions: [{ label: t('common.close'), kind: 'primary', cancel: true }] });
    P.render(); loadPrefs();
    return api.closed;
  };
})();
