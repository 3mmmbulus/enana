/* enana · core.js
 * 公共基础: 命名空间 / 事件 / DOM 助手 / 格式化 (Intl) / 本地存储 / 请求封装 (含登录令牌与语言头) / 轮询 / 后台任务跟踪。
 * 界面组件 (弹窗、确认框、提示、图标按钮、不可用状态) 在 ui.js; 所有文案在 i18n/*.js 词典里。
 * 约定: 来自网络的字符串 (服务器名、域名、应用名) 一律用 textContent 渲染, 绝不拼 HTML。
 * 兼容: ES2018 (不使用 ?. ?? ||= catch{}) */
(function () {
  'use strict';

  var TP = window.TP = {
    cfg: { apiBase: '', clashBase: '', apiPort: 9091, proxyPort: 7890, uiPort: 9090, version: '', probe: {} },      // apiBase / clashBase 为空 = 和页面同源; env.json 可以覆盖 (clashBase: 代理核心控制接口的地址)
    /* 可调常量 */
    CFG: {
      ALLOW_SKIP_CONFIRM: true,     // 低风险开关 (策略切换/监控) 的确认框是否提供「本次登录期间不再询问」
      AUTO_LOCK_MIN: 300,           // 无操作 5 小时后自动锁定 (回到登录框)
      UPDATE_CHECK_HOURS: 6         // 自动检查更新的间隔
    },
    /* 请求头名称 (只在这里定义一次; 后端过渡期内也接受旧名字 X-TProxy / X-TProxy-Token) */
    HDR: { app: 'X-Enana', token: 'X-Enana-Token', lang: 'X-Enana-Lang', sudo: 'X-Enana-Sudo' },
    S: { helperUp: null, clash: null, locked: true },   // locked: 还没登录 / 已锁定 -> 不轮询、不请求
    V: {}, ui: {}, fmt: {}, ls: {}, ss: {}, jobs: {}
  };
  var S = TP.S, ui = TP.ui, fmt = TP.fmt, enc = encodeURIComponent, I = window.I18N, t = I.t;
  TP.enc = enc;

  /* 名称映射: 值是词典键, 用 TP.name.xxx(v) 取当前语言的文字 */
  var MAPS = {
    policy: { PIN: 'name.policy.PIN', Global: 'name.policy.Global', direct: 'name.policy.direct' },   // 策略选择器
    route: { pin: 'name.policy.PIN', auto: 'name.policy.Global', direct: 'name.policy.direct' },      // 连接分类
    role: { pin: 'name.role.pin', auto: 'name.role.auto', dl: 'name.role.dl', off: 'name.role.off' },  // 服务器角色
    app: { follow: 'name.app.follow', direct: 'name.app.direct', pin: 'name.app.pin', auto: 'name.app.auto' }
  };
  TP.name = {};
  Object.keys(MAPS).forEach(function (k) { TP.name[k] = function (v) { return MAPS[k][v] ? t(MAPS[k][v]) : (v == null ? '' : String(v)); }; });
  TP.POLICY_ICON = { PIN: 'pin', Global: 'auto', direct: 'direct', pin: 'pin', auto: 'auto' };

  /* ---------- 事件 ---------- */
  var bus = {};
  TP.on = function (ev, fn) { (bus[ev] = bus[ev] || []).push(fn); };
  TP.emit = function (ev, d) {
    (bus[ev] || []).slice().forEach(function (fn) { try { fn(d); } catch (e) { console.error('[' + ev + ']', e); } });
  };

  /* ---------- 存储 (键自动加 enana. 前缀; 全部 try/catch: 隐私模式/禁用存储时照常工作) ---------- */
  var PFX = 'enana.';
  function store(area) {
    return {
      get: function (k, d) { try { var v = window[area].getItem(PFX + k); return v == null ? d : JSON.parse(v); } catch (e) { return d; } },
      set: function (k, v) { try { window[area].setItem(PFX + k, JSON.stringify(v)); } catch (e) { /* 忽略 */ } },
      del: function (k) { try { window[area].removeItem(PFX + k); } catch (e) { /* 忽略 */ } },
      keys: function (prefix) {
        try { return Object.keys(window[area]).filter(function (k) { return k.indexOf(PFX + (prefix || '')) === 0; }).map(function (k) { return k.slice(PFX.length); }); } catch (e) { return []; }
      }
    };
  }
  var ls = store('localStorage'), ss = store('sessionStorage');
  TP.ls.get = ls.get; TP.ls.set = ls.set; TP.ls.del = ls.del;
  TP.ss.get = ss.get; TP.ss.set = ss.set; TP.ss.del = ss.del; TP.ss.keys = ss.keys;

  /* ---------- DOM 助手 ---------- */
  var PROPS = { checked: 1, disabled: 1, selected: 1, hidden: 1, open: 1, multiple: 1, indeterminate: 1, readOnly: 1 };
  function add(el, kids) {
    for (var i = 0; i < kids.length; i++) {
      var k = kids[i];
      if (k == null || k === false || k === true) continue;
      if (Array.isArray(k)) add(el, k);
      else if (I.isL(k)) el.appendChild(I.node(k));                       // 懒文案: 切换语言后自动更新
      else el.appendChild(k.nodeType ? k : document.createTextNode(String(k)));
    }
  }
  /* h(tag, {class,text,on:{click:fn},value,checked,...属性}, ...children) — 文字和 title/aria-label/placeholder 可以直接传 I18N.L(键) */
  function h(tag, props) {
    var el = document.createElement(tag), late = null, kids = Array.prototype.slice.call(arguments, 2);
    if (props) Object.keys(props).forEach(function (k) {
      var v = props[k];
      if (v == null || v === false) return;
      if (k === 'class') el.className = v;
      else if (k === 'text') { if (I.isL(v)) el.appendChild(I.node(v)); else el.textContent = v; }
      else if (k === 'on') Object.keys(v).forEach(function (ev) { el.addEventListener(ev, v[ev]); });
      else if (k === 'value') late = v;
      else if (PROPS[k]) el[k] = v;
      else if (I.isL(v)) I.attr(el, k, v);
      else el.setAttribute(k, v === true ? '' : String(v));
    });
    add(el, kids);
    if (late != null) el.value = late;     // select 需要在 option 之后赋值
    if ((tag === 'input' || tag === 'select' || tag === 'textarea') && !el.getAttribute('name') && !el.id) el.setAttribute('name', 'f' + (++fieldSeq));     // 没有 id / name 的表单控件, 浏览器 (自动填充 / 开发者工具) 会报警
    return el;
  }
  var fieldSeq = 0;
  TP.h = h;
  TP.clear = function (el) { while (el.firstChild) el.removeChild(el.firstChild); return el; };
  TP.opt = function (value, text) { return h('option', { value: value }, text); };
  TP.setText = function (el, v) { v = String(v); if (el.textContent !== v) el.textContent = v; };
  TP.setCls = function (el, cls) { if (el.className !== cls) el.className = cls; };
  TP.byId = function (id) { return document.getElementById(id); };

  /* 按 key 复用/更新/排序行, 只改变化的部分 (大列表不卡, 保留用户正在操作的控件) */
  ui.syncList = function (parent, items, keyOf, make, update) {
    var old = parent._rows || new Map(), next = new Map(), ref = parent.firstChild;
    items.forEach(function (it) {
      var k = keyOf(it), row = old.get(k);
      if (!row) row = make(it);
      update(row, it);
      next.set(k, row);
      if (row === ref) ref = ref.nextSibling; else parent.insertBefore(row, ref);
    });
    old.forEach(function (row, k) { if (!next.has(k) && row.parentNode === parent) parent.removeChild(row); });
    parent._rows = next;
  };

  /* 内容签名没变就不重建 (避免轮询时打断焦点/点击); 语言变了会自动重建 */
  ui.memo = function (box, sig, build) {
    sig = I.lang + '|' + sig;
    if (box._sig === sig) return false;
    box._sig = sig; TP.clear(box);
    var n = build();
    if (n) box.appendChild(n);
    return true;
  };

  /* ---------- 格式化 (数字 / 日期 / 相对时间都走 Intl, 跟随当前语言) ---------- */
  fmt.num = function (n, o) { return I.intl.num(n, o); };
  fmt.bytes = function (n) {
    n = +n || 0;
    var u = ['B', 'KB', 'MB', 'GB', 'TB'], i = 0, d;
    while (n >= 1024 && i < 4) { n /= 1024; i++; }
    d = (i === 0 || n >= 100) ? 0 : n >= 10 ? 1 : 2;
    return I.intl.num(n, { minimumFractionDigits: d, maximumFractionDigits: d }) + ' ' + u[i];
  };
  fmt.rate = function (n) { return fmt.bytes(n) + '/s'; };
  fmt.mbps = function (bytesPerSec) { return I.intl.num(bytesPerSec * 8 / 1e6, { minimumFractionDigits: 1, maximumFractionDigits: 1 }) + ' Mbps'; };
  fmt.delay = function (ms) { return ms > 0 ? ms + ' ms' : t('common.timeout'); };
  /* 「3 分钟前」/ "3 minutes ago" */
  fmt.rel = function (sec) {
    if (!sec) return t('time.never');
    var d = Date.now() / 1000 - sec;
    if (d < 0) d = 0;
    if (d < 60) return t('time.justNow');
    if (d < 3600) return I.intl.rel(-Math.floor(d / 60), 'minute');
    if (d < 86400) return I.intl.rel(-Math.floor(d / 3600), 'hour');
    return I.intl.rel(-Math.floor(d / 86400), 'day');
  };
  /* 时间戳 -> Date: 兼容 秒 / 毫秒 / ISO 字符串 */
  fmt.toDate = function (ts) {
    if (ts == null || ts === '') return null;
    var n = +ts, d;
    if (!isNaN(n)) d = new Date(n < 1e11 ? n * 1000 : n); else d = new Date(String(ts).replace(' ', 'T'));
    return isNaN(d.getTime()) ? null : d;
  };
  fmt.date = function (sec) { var d = fmt.toDate(sec); return d ? I.intl.date(d, { dateStyle: 'medium' }) : ''; };
  fmt.clock = function (ts) { var d = fmt.toDate(ts); return d ? I.intl.date(d, { hour: '2-digit', minute: '2-digit' }) : ''; };
  fmt.hms = function (ts) { var d = fmt.toDate(ts); return d ? I.intl.date(d, { hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23' }) : String(ts || ''); };
  fmt.dateTime = function (ts) { var d = fmt.toDate(ts); return d ? I.intl.date(d, { dateStyle: 'medium', timeStyle: 'medium', hourCycle: 'h23' }) : String(ts || ''); };
  /* 日志日期 YYYY-MM-DD: 今天 / 昨天 / 本地化日期 */
  fmt.day = function (ymd) {
    var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(ymd || ''); if (!m) return String(ymd || '');
    var d = new Date(+m[1], +m[2] - 1, +m[3]), now = new Date(), a = new Date(now.getFullYear(), now.getMonth(), now.getDate()), diff = Math.round((a - d) / 86400000);
    var s = I.intl.date(d, { year: 'numeric', month: 'short', day: 'numeric', weekday: 'short' });
    return diff === 0 ? t('time.today') + ' · ' + s : diff === 1 ? t('time.yesterday') + ' · ' + s : s;
  };
  /* 订阅用量: 「已用 1.15 GB / 300 GB · 到期 2028-03-02」 */
  fmt.usage = function (u) {
    if (!u || !(+u.total > 0)) return '';
    var o = { used: fmt.bytes(u.used), total: fmt.bytes(u.total) };
    if (+u.expire > 0) { o.date = fmt.date(+u.expire); return t('fmt.usageExpire', o); }
    return t('fmt.usage', o);
  };
  /* X-Subscription-Userinfo: upload=0; download=123; total=456; expire=1700000000 */
  fmt.parseUserinfo = function (s) {
    if (!s) return null;
    var o = {};
    String(s).split(';').forEach(function (kv) { var i = kv.indexOf('='); if (i > 0) o[kv.slice(0, i).trim().toLowerCase()] = parseFloat(kv.slice(i + 1)) || 0; });
    if (!(o.total > 0)) return null;
    return { used: (o.upload || 0) + (o.download || 0), total: o.total, expire: o.expire || 0 };
  };
  fmt.os = function (os) { return os === 'windows' ? 'Windows' : os === 'darwin' ? 'macOS' : os === 'linux' ? 'Linux' : (os || ''); };

  /* ---------- 错误: 后端错误带稳定的 code, 优先用词典里的本地化文字, 否则用后端给的 error ---------- */
  function mkErr(kind, msg, data) {
    var e = new Error(msg); e.kind = kind;
    if (data) { e.data = data; if (data.code) e.code = String(data.code); }
    return e;
  }
  TP.mkErr = mkErr;
  TP.errMsg = function (e) {
    if (e && e.code && I.has('error.' + e.code)) return t('error.' + e.code);
    return (e && e.message) || t('error.unknown');
  };
  /* 事件处理器包装: 任何异常都变成 toast, 不产生未处理的 Promise 拒绝。需要登录的错误由登录框处理, 不再弹 toast */
  TP.safe = function (fn) {
    return function () {
      var self = this, a = arguments;
      return Promise.resolve().then(function () { return fn.apply(self, a); }).catch(function (e) { if (e && (e.kind === 'auth' || e.kind === 'cancel')) return; ui.toast(TP.errMsg(e), 'err'); });
    };
  };

  /* ---------- 请求封装 ---------- */
  function qs(o) {
    var a = [];
    Object.keys(o || {}).forEach(function (k) { if (o[k] != null && o[k] !== '') a.push(enc(k) + '=' + enc(o[k])); });
    return a.length ? '?' + a.join('&') : '';
  }
  TP.qs = qs;
  TP.sleep = function (ms) { return new Promise(function (r) { setTimeout(r, ms); }); };
  function fetchT(url, o, ms) {
    var ctl = new AbortController(), timer = setTimeout(function () { ctl.abort(); }, ms);
    o = Object.assign({ cache: 'no-store', signal: ctl.signal }, o);
    return fetch(url, o).then(function (r) { clearTimeout(timer); return r; }, function (e) { clearTimeout(timer); throw e; });
  }
  TP.fetchT = fetchT;

  /* 登录令牌: 只放在 sessionStorage (关闭标签页即失效), 不进 localStorage、不写日志 */
  var token = ss.get('token', '');
  TP.getToken = function () { return token; };
  TP.setToken = function (v) { token = v || ''; if (token) ss.set('token', token); else ss.del('token'); };

  function setHelper(up) {
    if (S.helperUp !== up) { S.helperUp = up; TP.emit('helper', up); }
  }
  TP.noHelper = function () { return S.helperUp === false; };

  /* 辅助服务 (本页面就是它提供的, 默认同源; env.json 的 apiBase 可以改): 每个请求都带 X-Enana: 1 和 X-Enana-Lang (后端据此本地化任务进度和错误文字), 登录后还带 X-Enana-Token
   * o: {q:{查询参数}, body:文本, form:{表单字段 (urlencoded)}, timeout:毫秒, text:true -> 返回 {text, headers}, noAuth:true -> 不带令牌且 401 不触发重新登录}
   * 不信任 Content-Type: 一律按文本读取, 看起来像 JSON 才解析。 */
  TP.helper = async function (method, path, o) {
    o = o || {};
    var headers = {}, res, text, j = null, body = o.body;
    headers[TP.HDR.app] = '1'; headers[TP.HDR.lang] = I.lang;
    if (token && !o.noAuth) headers[TP.HDR.token] = token;
    if (TP.sudo && (o._retried || TP.sudo.forPath(path)) && TP.sudo.token()) headers[TP.HDR.sudo] = TP.sudo.token();      // 敏感操作: 再次输入密码后 5 分钟内带上 (只在内存里)
    if (o.form) { body = new URLSearchParams(o.form).toString(); headers['Content-Type'] = 'application/x-www-form-urlencoded'; }
    else if (body != null) headers['Content-Type'] = 'text/plain;charset=UTF-8';
    try {
      res = await fetchT(TP.cfg.apiBase + path + qs(o.q), { method: method, headers: headers, body: body }, o.timeout || 15000);
    } catch (e) {
      setHelper(false);
      throw mkErr('unreachable', t(e && e.name === 'AbortError' ? 'error.helperTimeout' : 'error.helperUnreachable'));
    }
    setHelper(true);
    if (res.status === 401 && !o.noAuth) { TP.emit('unauth'); throw mkErr('auth', t('error.sessionExpired')); }
    try { text = await res.text(); } catch (e) { throw mkErr('http', t('error.readFailed')); }
    if (/^\s*\{/.test(text)) { try { j = JSON.parse(text); } catch (e) { j = null; } }
    if (j && j.code === 'E_SUDO_REQUIRED' && !o.noSudo && !o._retried && TP.sudo) {         // 需要再次输入登录密码: 弹出密码框, 通过后带着 X-Enana-Sudo 重试同一个请求
      TP.sudo.clear();
      var stok = await TP.sudo.ask(o.sudoWhy);
      if (stok) return TP.helper(method, path, Object.assign({}, o, { _retried: true }));
      throw mkErr('cancel', t('sudo.cancelled'), j);
    }
    if (j && j.ok === false) throw mkErr('api', j.error || t('error.generic'), j);
    if (!res.ok) throw mkErr('http', (j && j.error) || t('error.helperStatus', { status: res.status }), j);
    if (o.text) return { text: text, headers: res.headers };
    return j || text;
  };

  /* Clash API (TP.cfg.clashBase; 为空 = 同源): 登录后带 Authorization: Bearer <令牌>。核心重启期间的失败是正常现象: 安静处理。 */
  var clashFails = 0, applying = 0, graceUntil = 0;
  function setClash(st) { if (S.clash !== st) { S.clash = st; TP.emit('clash', st); } }
  TP.isApplying = function () { return applying > 0 || Date.now() < graceUntil; };
  TP.clash = async function (method, path, body, o) {
    var res, data = null, headers = {};
    if (body) headers['Content-Type'] = 'application/json';
    if (token) headers.Authorization = 'Bearer ' + token;
    try {
      res = await fetchT(TP.cfg.clashBase + path, { method: method, headers: headers, body: body ? JSON.stringify(body) : undefined }, (o && o.timeout) || 8000);
    } catch (e) {
      clashFails++;
      if (TP.isApplying()) setClash('applying');
      else if (clashFails >= 2 || S.clash == null) setClash('down');
      throw mkErr('unreachable', t('error.coreUnreachable'));
    }
    clashFails = 0; setClash('ok');
    if (res.status === 401) { TP.emit('unauth'); throw mkErr('auth', t('error.sessionExpired')); }
    if (res.status === 204) return null;
    try { data = await res.json(); } catch (e) { data = null; }
    if (!res.ok) throw mkErr('http', (data && data.message) || t('error.coreStatus', { status: res.status }), data);
    return data;
  };

  /* ---------- 轮询 (标签页隐藏时暂停, 回到前台立即补一次; 串行不重叠; 未登录时不请求) ---------- */
  var pollers = [];
  TP.poll = function (fn, ms, opt) {
    opt = opt || {};
    var p = { fn: fn, ms: ms, when: opt.when, t: 0, busy: false, first: true };
    function loop() {
      p.t = 0;
      // 第一次加载不看可见性 (后台打开的标签页切过来时数据已经就绪); 之后隐藏时暂停
      var skip = S.locked || (document.hidden && !p.first) || (p.when && !p.when());
      if (!S.locked) p.first = false;
      if (skip) { p.t = setTimeout(loop, p.ms); return; }
      p.busy = true;
      Promise.resolve().then(p.fn).catch(function () { /* 各加载器自行处理错误 */ }).then(function () { p.busy = false; p.t = setTimeout(loop, p.ms); });
    }
    p.kick = function () { if (p.busy) return; clearTimeout(p.t); loop(); };
    p.t = setTimeout(loop, opt.delay || 0);
    pollers.push(p);
    return p;
  };
  TP.kickAll = function () { pollers.forEach(function (p) { p.kick(); }); };
  document.addEventListener('visibilitychange', function () { if (!document.hidden && !S.locked) TP.kickAll(); });
  TP.on('auth', function (ok) { if (ok) TP.kickAll(); });

  /* ---------- 后台任务 (GET /api/job 每 500ms 轮询; 进度文字和步骤名由后端按 X-Enana-Lang 本地化) ---------- */
  var jobsActive = 0;
  TP.jobs.active = function () { return jobsActive; };
  /* o.maxFails: 连续多少次拿不到进度就放弃 (默认 20 次 ≈ 10 秒; 更新辅助服务时它自己会重启, 调大)
   * o.quiet: 只读任务 (服务器检测 / IP 查询): 不要让顶栏变成「正在应用配置…」, 也不触发配置刷新 */
  TP.jobs.follow = async function (id, card, o) {
    var fails = 0, j, max = (o && o.maxFails) || 20, quiet = !!(o && o.quiet);
    jobsActive++;
    if (!quiet) { applying++; TP.emit('applying', true); }
    try {
      for (;;) {
        try { j = await TP.helper('GET', '/api/job', { q: { id: id }, timeout: 8000 }); fails = 0; }
        catch (e) {
          if (e.kind === 'api' || e.kind === 'auth' || ++fails > max) throw e;     // 任务不存在 / 需要登录 / 辅助服务长时间无响应
          await TP.sleep(500); continue;
        }
        if (card) card.fromJob(j);
        if (j.state === 'done') return j;
        if (j.state === 'error') throw mkErr('job', j.msg || t('error.generic'), j);
        await TP.sleep(500);
      }
    } finally {
      jobsActive--;
      if (!quiet) { applying--; graceUntil = Date.now() + 3000; TP.emit('applying', false); }
    }
  };
  /* 在右下角 dock 里显示一个任务 (进度条 + 步骤): start() 返回 {job:"id"} 的 Promise */
  TP.jobs.runInDock = async function (title, start, o) {
    o = o || {};
    var card = ui.taskCard(title);
    ui.dock(card);
    card.set({ pct: null, msg: t('job.submitting') });
    try {
      var r = await start(), j = null;
      if (r && r.job) j = await TP.jobs.follow(r.job, o.mapCard ? o.mapCard(card) : card);
      card.done((j && j.msg) || o.doneMsg || t('common.done'));
      setTimeout(card.close, 6000);
      ui.toast(t('job.doneToast', { title: title }), 'ok');
      if (TP.afterApply) TP.afterApply();
      return { ok: true, job: j, res: r };
    } catch (e) {
      if (e && (e.kind === 'auth' || e.kind === 'cancel')) { card.close(); return { ok: false, error: e }; }
      card.fail(TP.errMsg(e));
      ui.toast(t('job.failToast', { title: title, reason: TP.errMsg(e) }), 'err');
      if (TP.afterApply) TP.afterApply();
      return { ok: false, error: e };
    }
  };
})();
