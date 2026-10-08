/* enana · data.js
 * 数据层: 读取 env.json / catalog.json, 加载辅助服务状态与 Clash 数据, 连接分类与速度计算。
 * 视图只订阅事件 (state / apps / proxies / conns / mode / core / catalog / monitor), 不直接发请求读取这些数据。 */
(function () {
  'use strict';
  var TP = window.TP, S = TP.S, enc = TP.enc, HIST = 90;

  S.state = null;          // GET /api/state
  S.apps = null;           // GET /api/apps
  S.svMap = {};            // tag -> state.servers 条目
  S.proxies = {};          // Clash /proxies
  S.mode = ''; S.modes = ['Rule', 'Direct'];
  S.core = '';             // "sing-box 1.14.2"
  S.catalog = null; S.svcByTag = {};
  S.conns = []; S.connTotals = null;
  S.speed = { pin: { d: 0, u: 0 }, auto: { d: 0, u: 0 }, direct: { d: 0, u: 0 } };
  S.speedAt = 0;           // 上一次有效速度采样时间 (0 = 还没有)
  S.hist = { pin: [], auto: [], direct: [] };
  S.delays = {};           // tag -> {ms, t}  (ms=-1 表示超时/失败)
  S.monitor = TP.ls.get('monitor', true) !== false;
  S.scanning = false;

  /* ---------- 运行配置 ---------- */
  TP.loadEnv = async function () {
    var j = {};
    try { var r = await TP.fetchT('env.json', {}, 4000); if (r.ok) j = await r.json(); } catch (e) { j = {}; }
    var c = TP.cfg;
    c.apiPort = +j.apiPort || c.apiPort; c.proxyPort = +j.proxyPort || c.proxyPort; c.uiPort = +j.uiPort || c.uiPort; c.version = j.version || '';
    c.probe = (j.probe && typeof j.probe === 'object') ? j.probe : {};   // 可选: 覆盖探测地址 (开发/离线测试用)
    c.apiBase = (typeof j.apiBase === 'string') ? j.apiBase.replace(/\/+$/, '') : '';                                  // 仪表盘由辅助服务提供, 接口默认同源
    c.clashBase = (typeof j.clashBase === 'string') ? j.clashBase.replace(/\/+$/, '') : '';                          // 代理核心的控制接口 (Clash API) 在另一个端口, 跨域访问 (带令牌)
  };

  /* 网站目录 (schema 2/3): groups={id:名称}, groups_en={id:English}, order=[分组显示顺序], entries=[{id,tag,name,name_en,group,default,desc,desc_en,domains,rulesets,cidrs}] */
  TP.loadCatalog = async function () {
    var cat = { groups: {}, groups_en: {}, order: [], entries: [], failed: false, schema: 0 };
    try {
      var r = await TP.fetchT('catalog.json', {}, 8000);
      if (!r.ok) throw new Error('HTTP ' + r.status);
      var j = await r.json();
      cat.schema = +j.schema || 2; cat.groups = j.groups || {}; cat.groups_en = j.groups_en || {}; cat.entries = Array.isArray(j.entries) ? j.entries : [];
      var seen = {};
      (Array.isArray(j.order) ? j.order : Object.keys(cat.groups)).forEach(function (g) { if (!seen[g]) { seen[g] = 1; cat.order.push(g); } });
      cat.entries.forEach(function (e) { if (!seen[e.group]) { seen[e.group] = 1; cat.order.push(e.group); } });
    } catch (e) { cat.failed = true; }
    S.catalog = cat; S.svcByTag = {};
    cat.entries.forEach(function (e) { S.svcByTag[e.tag || ('svc-' + e.id)] = e; });
    TP.emit('catalog');
  };

  TP.groupName = function (g) {
    var c = S.catalog;
    if (!c) return g;
    if (window.I18N.lang !== 'zh' && c.groups_en && c.groups_en[g]) return c.groups_en[g];
    return c.groups[g] || g;
  };
  var RISK = { ai: 1, account: 1, exchange: 1 };       // 对 IP 变化敏感: 换出口可能触发风控
  TP.riskGroup = function (g) { return !!RISK[g]; };

  /* ---------- 辅助服务数据 ---------- */
  /* 服务器列表: 优先用辅助服务的状态; 辅助服务不可用 (从未读到状态) 时, 用 Clash 的节点顶替,
   * 这样「测速」和「固定节点」等只依赖 Clash API 的功能照常可用 (derived:true 的行不能改角色/删除)。 */
  TP.servers = function () {
    if (S.state && S.state.servers) return S.state.servers;
    var P = S.proxies, out = [];
    Object.keys(P).forEach(function (tag) {
      var p = P[tag];
      if (p.all || tag === 'direct' || /^(Direct|Selector|URLTest|Fallback|LoadBalance|Reject|Block|DNS)$/i.test(p.type || '')) return;
      out.push({ tag: tag, type: String(p.type || '').toLowerCase(), server: '', port: '', role: P.PIN && P.PIN.all && P.PIN.all.indexOf(tag) >= 0 ? 'pin' : 'auto', sub: '', derived: true });
    });
    return out;
  };
  TP.hasRole = function (role) { return TP.servers().some(function (s) { return s.role === role; }); };

  TP.loadState = async function () {
    try {
      var st = await TP.helper('GET', '/api/state');
      S.state = st; S.svMap = {};
      (st.servers || []).forEach(function (s) { S.svMap[s.tag] = s; });
      TP.emit('state', st);
    } catch (e) { if (e.kind !== 'unreachable') console.warn('state:', e.message); }
  };

  var appsScanPending = null, APPS_SCAN_INTERVAL = 60000;
  async function readApps(scan, background) {
    if (scan) { S.scanning = true; TP.emit('scanning', true); }
    try {
      var r = scan ? await TP.helper('POST', '/api/apps/scan') : await TP.helper('GET', '/api/apps');
      if (r.job) {
        if (background) {
          // Automatic discovery may apply new app rules, but is not a user
          // switching capture modes. Follow it without a card/success toast.
          await TP.jobs.follow(r.job, null);
          if (TP.afterApply) TP.afterApply();
        } else {
          var done = await TP.jobs.runInDock(window.I18N.t('apps.scanJob'), function () { return Promise.resolve(r); });
          if (!done.ok) return null;
        }
        r = await TP.helper('GET', '/api/apps');
      }
      S.apps = r; TP.emit('apps'); return r;
    } catch (e) { if (e.kind !== 'unreachable') console.warn('apps:', e.message); }
    finally { if (scan) { S.scanning = false; TP.emit('scanning', false); } }
    return null;
  }
  TP.loadApps = function (scan, o) {
    var background = !!(o && o.background), age;
    if (scan && appsScanPending) return appsScanPending;
    if (scan && background) {
      // Persist the cadence across page reloads. Visibility kicks refresh the
      // list immediately, without repeatedly starting another apply job.
      age = Date.now() - (+TP.ls.get('apps.scanAt', 0) || 0);
      if (age >= 0 && age < APPS_SCAN_INTERVAL) scan = false;
    }
    if (!scan) return readApps(false, background);
    TP.ls.set('apps.scanAt', Date.now());
    appsScanPending = readApps(true, background);
    appsScanPending.then(function () { appsScanPending = null; }, function () { appsScanPending = null; });
    return appsScanPending;
  };
  TP.scanAppsBackground = function () {
    return TP.noHelper() || TP.isApplying() ? null : TP.loadApps(true, { background: true });
  };

  /* 设置 / 日志用量 / 账号摘要 (GET /api/settings -> S.prefs, 事件 'settings') */
  S.prefs = null;
  TP.loadSettings = async function () {
    try {
      var r = await TP.helper('GET', '/api/settings');
      S.prefs = r; TP.emit('settings', r);
      return r;
    } catch (e) { if (e.kind !== 'unreachable' && e.kind !== 'auth') console.warn('settings:', e.message); return null; }
  };

  /* 设置覆盖 (应用 / 网站); 网站 state=follow 表示删除该行 */
  /* target (只对 pin 有意义): 空 = 默认固定出口 · 'PINAUTO' = 在固定出口里自动选一个 · 其它 = 指定走这一个固定出口 (固定出口有 2 个以上时才能选) */
  TP.override = async function (kind, value, state, target) {
    var q = { kind: kind, value: value, state: state };
    if (state === 'pin' && target) q.target = target;
    var r = await TP.helper('POST', '/api/override', { q: q });
    if (r.job) await TP.jobs.runInDock(window.I18N.t('job.override'), function () { return Promise.resolve(r); });
    return r;
  };
  /* 可以单独指定的固定出口: 配置里前 TP.PIN_MAX 个 role=pin 的服务器 (和 lib/apps.sh 的 OVR_PIN_MAX、lib/config.sh 的规则集序号一致); 不到 2 个就没有「指定」这回事 (只有一个时也能看到走的是它, 见 exits.js) */
  TP.PIN_MAX = 32;
  TP.pinServers = function () { return TP.servers().filter(function (s) { return s.role === 'pin'; }).slice(0, TP.PIN_MAX).map(function (s) { return s.tag; }); };
  TP.canPickPin = function () { return TP.pinServers().length >= 2; };
  TP.hasPin = function () { return TP.pinServers().length >= 1; };
  /* 一个出口选择 (selector 当前选中的名字 / 覆盖的 target) 是不是「某个具体的固定出口」: 返回 'PINAUTO' | 服务器名 | '' */
  TP.pinTargetOf = function (v) { return v === 'PINAUTO' || TP.pinServers().indexOf(v) >= 0 ? v : ''; };


  /* ---------- Clash 数据 ---------- */
  TP.loadProxies = async function () {
    var a = TP.clash('GET', '/proxies').then(function (r) { S.proxies = (r && r.proxies) || {}; TP.emit('proxies'); }, function () { /* 状态点已记录 */ });
    var b = TP.clash('GET', '/configs').then(function (c) {
      if (c && c.mode && c.mode !== S.mode) { S.mode = c.mode; if (c['mode-list']) S.modes = c['mode-list']; TP.emit('mode'); }
    }, function () { });
    await Promise.all([a, b]);
  };
  TP.loadVersion = async function () {
    try {
      var v = await TP.clash('GET', '/version');
      var s = (v && v.version) || '';
      if (s !== S.core) { S.core = s; TP.emit('core'); }
    } catch (e) { /* 忽略 */ }
  };

  /* 沿着 selector/urltest 找到最终的出站 (叶子) */
  TP.leaf = function (tag) {
    var p = S.proxies[tag], n = 0;
    if (!p) return '';
    while (p && p.all && p.now && n++ < 8) { tag = p.now; p = S.proxies[tag]; }
    return tag;
  };

  /* 自动线路是否被用户手动固定到某个节点 (只有 Global 里有 AUTO 选项时才算「手动」) */
  TP.globalPinned = function () {
    var g = S.proxies.Global;
    return !!(g && g.now && g.now !== 'AUTO' && g.all && g.all.indexOf('AUTO') >= 0);
  };

  /* 切换一个策略开关 (网站 / 默认出口 / 节点选择): 由辅助服务代为切换并写进操作记录 (原来 → 现在), 不再由浏览器直接改核心 */
  TP.setPolicy = async function (tag, name) {
    var r = await TP.helper('POST', '/api/policy', { form: { tag: tag, name: name } });
    if (S.proxies[tag]) S.proxies[tag].now = name;
    TP.emit('proxies');
    setTimeout(TP.loadProxies, 400);
    return r;
  };
  /* 浏览器直接对核心做的操作 (断开连接) 事后补一条操作记录; 记录失败不影响操作本身 */
  TP.audit = function (ev, o) { return TP.helper('POST', '/api/audit', { form: Object.assign({ ev: ev }, o || {}) }).catch(function () { }); };

  TP.testDelay = async function (tag) {
    var url = (TP.cfg.probe && TP.cfg.probe.delayUrl) || 'http://www.gstatic.com/generate_204', ms = -1;
    try {
      var r = await TP.clash('GET', '/proxies/' + enc(tag) + '/delay?url=' + enc(url) + '&timeout=5000', null, { timeout: 8000 });
      ms = r && +r.delay > 0 ? +r.delay : -1;
    } catch (e) { ms = -1; }
    S.delays[tag] = { ms: ms, t: Date.now() };
    return ms;
  };
  /* 最近一次延迟 (自己测的 与 Clash history 取较新的) */
  TP.delayOf = function (tag) {
    var d = S.delays[tag], p = S.proxies[tag], hs = p && p.history, last = hs && hs.length ? hs[hs.length - 1] : null, hv = null;
    if (last) hv = { ms: +last.delay > 0 ? +last.delay : -1, t: Date.parse(last.time) || 0 };
    if (d && (!hv || d.t >= hv.t)) return d;
    return hv;
  };

  /* ---------- 连接分类 / 速度 ---------- */
  /* chains[0] = 叶子出站, 最后一个 = 策略组 (svc-<id> / Final ...) */
  TP.routeOf = function (c) {
    var ch = c.chains || [], leaf = ch[0] || '', grp = ch.length ? ch[ch.length - 1] : '', cls, sv;
    if (!ch.length || /^direct(-[a-z]+)?$/.test(leaf)) cls = 'direct';             // direct-mode / -lan / -site / -app / -cn 都是直连 (后缀是直连的原因, 见 lib/config.sh)
    else if (ch.indexOf('PIN') >= 0) cls = 'pin';
    else if (ch.indexOf('Global') >= 0 || ch.indexOf('AUTO') >= 0) cls = 'auto';
    else { sv = S.svMap[leaf]; cls = sv && sv.role === 'pin' ? 'pin' : 'auto'; }
    return { cls: cls, node: cls === 'direct' ? '' : leaf, svc: /^svc-/.test(grp) ? grp : '', why: cls === 'direct' ? leaf : '' };      // why = 直连的原因 (出口名)
  };
  /* /Applications/Claude.app/Contents/MacOS/Claude -> Claude (取最外层 .app); C:\Program Files\X\x.exe -> x */
  TP.appName = function (p) {
    p = String(p || '');
    var m = p.match(/([^\/\\]+)\.app(?:[\/\\]|$)/i);
    if (m) return m[1];
    return (p.split(/[\/\\]/).pop() || '').replace(/\.exe$/i, '');
  };
  TP.svcName = function (tag) { var e = S.svcByTag[tag]; return e ? (window.I18N.pick(e, 'name') || e.name) : tag.replace(/^svc-/, ''); };

  /* 速度 = 最近约 3 秒的平均: 核心按数据块累计字节, 逐秒相减会出现「这一秒 0、下一秒翻倍」的抖动 (慢速下载时尤其明显) */
  var SPEED_WIN = 2500, ZERO = function () { return { pin: { d: 0, u: 0 }, auto: { d: 0, u: 0 }, direct: { d: 0, u: 0 } }; };
  var prev = null;                                                  // {t, h}: h[连接 id] = 最近几次采样 [[时间, 上传, 下载], …]
  TP.resetConnBaseline = function () { prev = null; };
  function processConns(r) {
    var list = (r && r.connections) || [], t = performance.now(), dt = prev ? (t - prev.t) / 1000 : 0;
    var base = !prev || dt > 6 || dt < 0.2;                        // 第一次采样只作基线; 间隔过长也重置
    var sp = ZERO(), hs = {}, rows = new Array(list.length), i, c, rt, up, dn, sd, su, a, o, w;
    for (i = 0; i < list.length; i++) {
      c = list[i]; rt = TP.routeOf(c); up = +c.upload || 0; dn = +c.download || 0; sd = 0; su = 0;
      a = !base && prev.h[c.id] ? prev.h[c.id] : [];
      if (!base) {
        o = a[0];                                                  // 窗口里最老的一次采样; 新连接没有 (它是上次采样之后才出现的): 窗口就是这一次的间隔
        w = o ? (t - o[0]) / 1000 : dt;
        sd = (o ? dn - o[2] : dn) / w; su = (o ? up - o[1] : up) / w;
        if (sd < 0) sd = 0; if (su < 0) su = 0;
        sp[rt.cls].d += sd; sp[rt.cls].u += su;
      }
      a = a.slice(); a.push([t, up, dn]);
      while (a.length > 2 && t - a[0][0] > SPEED_WIN) a.shift();
      hs[c.id] = a;
      rows[i] = { c: c, rt: rt, up: up, dn: dn, sd: sd, su: su };
    }
    prev = { t: t, h: hs };
    S.conns = rows; S.connTotals = { down: +(r && r.downloadTotal) || 0, up: +(r && r.uploadTotal) || 0 };
    if (!base) {
      S.speed = sp; S.speedAt = Date.now();
      ['pin', 'auto', 'direct'].forEach(function (k) { var a = S.hist[k]; a.push(sp[k].d + sp[k].u); if (a.length > HIST) a.shift(); });
    }
    TP.emit('conns');
  }
  /* 核心连不上 (停了 / 正在重启): 旧的连接和速度已经不存在, 不能继续显示 (不然表格和数字会一直停在最后一次读到的样子, 像是实时的); 速度曲线落回 0 */
  function dropConns() {
    prev = null;
    ['pin', 'auto', 'direct'].forEach(function (k) { var a = S.hist[k]; if (a.length) { a.push(0); if (a.length > HIST) a.shift(); } });
    S.conns = []; S.connTotals = null; S.speed = ZERO(); S.speedAt = 0;
    TP.emit('conns');
  }
  TP.loadConns = async function () {
    if (!S.monitor) return;
    try { processConns(await TP.clash('GET', '/connections', null, { timeout: 3000 })); }
    catch (e) { if (S.clash !== 'ok' && (S.conns.length || S.speedAt || S.connTotals)) dropConns(); }       // 偶尔一次超时 (状态还是正常) 保留上一份数据; 状态不正常了才清掉
  };
  TP.setMonitor = function (on) {
    S.monitor = !!on; TP.ls.set('monitor', S.monitor);
    prev = null;                                                   // 恢复后重新取基线, 避免速度尖峰
    if (!S.monitor) { S.speedAt = 0; S.speed = { pin: { d: 0, u: 0 }, auto: { d: 0, u: 0 }, direct: { d: 0, u: 0 } }; S.conns = []; }
    TP.emit('monitor', S.monitor);
    if (S.monitor && TP.pollers) TP.pollers.conns.kick();
  };

  /* ---------- 「为什么现在不能点」的原因 (空字符串 = 可用) ---------- */
  var t = window.I18N.t;
  TP.why = {
    helper: function () { return S.locked ? t('why.locked') : (S.helperUp === false ? t('why.helper') : ''); },
    clash: function () { return S.locked ? t('why.locked') : (S.clash === 'down' ? t('why.clash') : ''); },
    pin: function () { return S.proxies.PIN ? '' : t('why.pin'); },
    auto: function () { return S.proxies.AUTO ? '' : t('why.auto'); }
  };
  TP.hasPinPool = function () { return !!S.proxies.PIN; };
  TP.hasAutoPool = function () { return !!S.proxies.AUTO; };
  /* 是否为「核心没在运行」(辅助服务在, 但 Clash 连不上) */
  TP.coreStopped = function () { return S.clash === 'down' && S.helperUp !== false; };

  /* ---------- 确认框里的说明文字: 每个确认都要说清楚「什么会变」 ---------- */
  TP.txt = {
    policy: function (name, from, to, group) {       // 网站/服务策略 (PIN | Global | direct)
      var d = [];
      if (TP.riskGroup(group) && to !== 'PIN') d.push(t('txt.policy.risk'));
      d.push(t(to === 'PIN' ? 'txt.policy.toPin' : to === 'Global' ? 'txt.policy.toAuto' : 'txt.policy.toDirect'));
      return { message: t('txt.policy.msg', { name: name, from: from ? TP.name.policy(from) : t('txt.unset'), to: TP.name.policy(to) }), detail: d };
    },
    app: function (name, from, to) {                   // 应用状态 (follow | direct | pin | auto)
      return { message: t('txt.app.msg', { name: name, from: TP.name.app(from || 'follow'), to: TP.name.app(to) }), detail: t('txt.app.' + to) };
    },
    role: function (tag, from, to) {
      return { message: t('txt.role.msg', { name: tag, from: TP.name.role(from), to: TP.name.role(to) }), detail: [t('txt.role.' + to), t('txt.role.apply')] };
    }
  };

  /* 切换语言: 立即生效 (不用刷新), 并把选择同步给后端 (终端里的语言跟着变) */
  TP.setLang = function (code) {
    if (!window.I18N.setLang(code)) return;
    TP.emit('lang', code);
    if (!S.locked && S.helperUp !== false) TP.helper('POST', '/api/settings', { form: { lang: code } }).catch(function () { /* 同步失败不影响界面 */ });
  };

  /* ---------- 刷新 ---------- */
  TP.pollers = {};
  TP.refreshAll = function () {
    ['state', 'proxies'].forEach(function (k) { if (TP.pollers[k]) TP.pollers[k].kick(); });
    TP.loadApps(false);
  };
  TP.afterApply = function () { TP.refreshAll(); setTimeout(TP.refreshAll, 2500); };
})();
