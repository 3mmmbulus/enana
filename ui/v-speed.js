/* enana · v-speed.js — 测速页 (view id: speed)
 * A) IP 卡片: 本机 (直连) + 每条线路的出口 IP, 状态徽标, 眼睛开关遮住所有 IP (prefs: speed.mask), 手动刷新 POST /api/net/refresh -> GET /api/net/info。
 * B) 测速面板: 模式 / 是否测下载 / 节点 (≤12) / 测速目标 (分组可折叠, 每组 全选 / 清除 / 默认; 「管理测速目标」弹窗) -> POST /api/speedtest/start。
 *    选择记在 prefs (speed.sel.targets / nodes / mode / speed), 每次读到 plan 后按它校验: 已不存在的 id 丢掉, 新增的默认目标不会自动勾选。
 *    运行中按钮变「停止」, 每秒轮询 GET /api/speedtest/status?id= (切到别的页签时 3 秒一次, 完成后用 toast 通知); 运行中的任务 id 记在 sessionStorage (speed.run), 刷新页面后自动接上。
 * C) 结果矩阵: 行 = 目标 (按分组), 列 = 线路, 单元格边测边出; 点单元格 / 线路表头的「详情」打开弹窗 (连接 / 首字节 / HTTP / 错误 …), 不在页面里行内展开; 下面是下载速度条。
 *    打开页面时用 GET /api/speedtest/last 立刻显示上次的结果。
 * D) 管理测速目标 (弹窗): GET /api/speedtest/targets 的全部目标按分组列出 (内置 / 已修改 / 自定义 / 已隐藏), 搜索 + 筛选 + 分页 (ui.pager),
 *    添加 / 编辑 (内置的保存为覆盖) / 隐藏 (内置) 或删除 (自定义) / 恢复 / 全部还原: POST /api/speedtest/targets[/delete|/restore|/reset] (都不是任务)。
 *    每次改动后重新读取 plan, 页面上的选择器和已保存的选择随之更新; 测速进行中这些按钮「暂不可用」并说明原因。
 * 约定: 来自接口的字符串 (IP / 节点名 / 网站名 / 网址 / 说明) 一律经 h() 当文本渲染, 绝不拼 HTML; 控件暂时不能用时用 ui.avail + toast 说明原因, 不用 disabled。 */
(function () {
  'use strict';
  var TP = window.TP, S = TP.S, h = TP.h, ui = TP.ui, I = window.I18N, t = I.t, L = I.L, fmt = TP.fmt, setText = TP.setText;
  var V = TP.V.speed = { id: 'speed' };

  var runDialog = null, runDialogSig = '';
  var MAX_NODES = 12;                                   // POST /api/speedtest/start: nodes ≤ 12
  var BULLET = '•', DASH = '—', SEP = '\u0001';
  var GROUPS = ['global', 'cn', 'carrier', 'dev', 'media'];             // 目标分组的显示顺序; 其它分组按出现顺序排在后面
  var GICON = { global: 'globe', cn: 'map-pin', carrier: 'wifi', dev: 'terminal', media: 'play', other: 'link' };    // 分组图标, 也是目标没有 (或不认识) 图标时的后备
  var ICONS = ['globe', 'search', 'bot', 'sparkles', 'terminal', 'database', 'server', 'cloud-download', 'hard-drive', 'play', 'book-open', 'mail', 'monitor', 'wifi', 'zap', 'map-pin'];   // 自定义目标可选的图标 (都在 icons.js 里)
  var EXPECT_DEF = '200,204,301,302';
  var PK = { mask: 'speed.mask', targets: 'speed.sel.targets', nodes: 'speed.sel.nodes', mode: 'speed.sel.mode', speed: 'speed.sel.speed', open: 'speed.groups.open' };   // i18n-ignore (prefs 键, 不是词典键)
  var STATES = {
    normal: { cls: 'ok', icon: 'ip-normal' }, limited: { cls: 'warn', icon: 'ip-limited' },
    blocked: { cls: 'bad', icon: 'ip-blocked' }, unknown: { cls: 'mute', icon: 'ip-unknown' }
  };
  var KNOWN_ERR = { timeout: 1, dns: 1, reset: 1, refused: 1, tls: 1, error: 1 };   // 单元格 err / IP 查询 reason 里有译文的代码
  var PHASES = { ip: 1, direct: 1, nodes: 1, speed: 1 };
  var ROLES = { pin: 1, auto: 1 }, nodeQ = '';
  var CELL_ST = { ok: 1, slow: 1, limited: 1, fail: 1, skip: 1, pending: 1 };       // 不认识的状态都按「还没测到」显示
  var ST_BADGE = { ok: ['ok', 'success'], slow: ['warn', 'clock'], limited: ['warn', 'warning'], fail: ['bad', 'error'], pending: ['neutral', 'clock'], skip: ['neutral', 'minus'] };   // 状态 -> [徽标颜色, 图标]
  var FLT = ['all', 'builtin', 'custom', 'modified', 'hidden'];                      // 管理弹窗的筛选

  var el = {}, built = false, masked = TP.prefs.get(PK.mask, false) === true, writing = 0;
  var openG = Object.create(null);                                                                // 展开的目标分组 (prefs: speed.groups.open); 默认全部折叠
  var net = { st: 'idle', data: null, err: null, warn: null, busy: false, refreshing: false };   // GET /api/net/info
  var plan = { st: 'idle', data: null, err: null, busy: false, seq: 0 };                         // GET /api/speedtest/plan
  var sel = { mode: 'both', speed: true, nodes: [], targets: Object.create(null) };              // 用户的选择 (来自 prefs, 按 plan 校验)
  var last = { st: 'idle', res: null, err: null, busy: false };                                  // GET /api/speedtest/last
  var run = { id: '', res: null, stopping: false, stopAt: 0, fails: 0 };                         // 正在跟踪的测速
  var poll = { timer: 0, busy: false };
  var mx = { sig: '', cells: Object.create(null), heads: Object.create(null) };                  // 结果矩阵的节点索引
  var tg = { st: 'idle', list: [], err: null, warn: null, busy: false, seq: 0 };                 // GET /api/speedtest/targets (管理弹窗)
  var mg = null;                                                                                 // 管理弹窗打开时的状态 {api, q, flt, el}
  var detail = null;                                                                             // 打开着的 单元格 / 线路 详情弹窗: {update(), page()}
  var pgT = null, pgR = null;                                                                    // 分页器 (各只创建一次, 弹窗打开时挂到弹窗里)

  /* ================= 小工具 ================= */
  function active() { return TP.tab === 'speed'; }
  function own(o, k) { return Object.prototype.hasOwnProperty.call(o, k); }
  function arr(x) { return Array.isArray(x) ? x : []; }
  function okId(s) { return typeof s === 'string' && /^[A-Za-z0-9._-]{1,80}$/.test(s); }
  function addFix() { return { label: t('why.addServer'), fn: function () { TP.goAdd('manual'); } }; }
  function dash() { return h('span', { class: 'muted' }, DASH); }
  /* 遮住 IP: 每个数字 / 十六进制字符换成圆点, 分隔符 (. :) 保留 */
  function mask(s) { return String(s).replace(/[0-9a-fA-F]/g, BULLET); }
  /* 两位国家码 -> 旗帜 emoji (区域指示符号); 不是两个字母就返回空 */
  function flagOf(cc) {
    cc = String(cc || '').toUpperCase();
    if (!/^[A-Z]{2}$/.test(cc)) return '';
    return String.fromCodePoint(0x1F1E6 + cc.charCodeAt(0) - 65, 0x1F1E6 + cc.charCodeAt(1) - 65);
  }
  function ms(n) { return t('speed.ms', { n: fmt.num(Math.round(+n || 0)) }); }
  function msOr(v) { return +v > 0 ? ms(v) : DASH; }                                      // 没有这个数字 (失败的格子 / 0) 显示破折号, 不显示「0 ms」
  /* kbps 字段的单位其实是 KB/s: >= 1024 换成 MB/s */
  function speedText(kb) {
    kb = +kb || 0;
    if (kb >= 1024) return t('speed.unit.mbs', { n: fmt.num(kb / 1024, { minimumFractionDigits: 1, maximumFractionDigits: 1 }) });
    return t('speed.unit.kbs', { n: fmt.num(kb, { maximumFractionDigits: 0 }) });
  }
  function dur(sec) {
    sec = Math.max(1, Math.round(+sec || 0));
    if (sec < 45) return t('speed.dur.sec', { n: fmt.num(Math.max(5, Math.round(sec / 5) * 5)) });
    return t('speed.dur.min', { n: fmt.num(Math.max(1, Math.round(sec / 60))) });
  }
  function groupName(g) { return I.has('speed.group.' + g) ? t('speed.group.' + g) : String(g); }
  function groupIcon(g) { return GICON[g] || GICON.other; }
  /* 目标图标: 接口给的名字在 icons.js 里就用它, 否则 (youtube / github 这类品牌名) 退回分组图标 */
  function targetIcon(x) { var n = x && x.icon; return n && window.Icons && window.Icons.has(n) ? n : groupIcon(x && x.group); }
  function expectStr(e) { return Array.isArray(e) ? e.join(',') : (e == null ? '' : String(e)); }
  function isDirect(r) { return r.kind === 'direct' || r.id === 'direct'; }
  function routeLabel(r) { return isDirect(r) ? t('speed.route.direct') : String(r.name || r.id); }
  function roleBadge(r) {
    if (isDirect(r) || !own(ROLES, r.role)) return null;
    return h('span', { class: 'spd-role ' + r.role }, TP.name.role(r.role));
  }
  /* IP 查询失败原因 / 单元格 err 的文字: 已知代码有译文, http_NNN 单独处理, 其它显示原始代码 */
  function reasonText(code) {
    code = String(code || 'error');
    var m = /^http_(\d{3})$/.exec(code);
    if (m) return t('speed.reason.http', { code: m[1] });
    if (own(KNOWN_ERR, code)) return t('speed.reason.' + code);
    return t('speed.reason.other', { code: code });
  }
  function reasonNode(code) {
    code = String(code || 'error');
    if (/^http_\d{3}$/.test(code) || own(KNOWN_ERR, code)) return h('span', null, reasonText(code));
    return h('span', null, I.rich('speed.reason.other', { code: h('code', { class: 'mono' }, code) }));
  }
  /* 分组: [{id, items}], 已知分组在前 (海外 国内 运营商 开发者与云 影音), 其它按出现顺序 */
  function groupedTargets(list) {
    var map = Object.create(null), order = [];
    list.forEach(function (x) { var g = x.group || 'other'; if (!map[g]) { map[g] = []; order.push(g); } map[g].push(x); });
    return GROUPS.filter(function (g) { return map[g]; }).concat(order.filter(function (g) { return GROUPS.indexOf(g) < 0; })).map(function (g) { return { id: g, items: map[g] }; });
  }
  function flatTargets(list) { var out = []; groupedTargets(list).forEach(function (g) { g.items.forEach(function (x) { out.push(x); }); }); return out; }
  /* 写 prefs: 自己写的不再触发「prefs 变了, 重新读取」 */
  function setPref(k, v) { writing++; try { TP.prefs.set(k, v); } finally { writing--; } }
  function loadOpen() { openG = Object.create(null); arr(TP.prefs.get(PK.open, [])).forEach(function (g) { if (typeof g === 'string') openG[g] = true; }); }

  /* ================= 构建 ================= */
  V.init = function (root) {
    loadOpen();
    root.appendChild(h('div', { class: 'intro spd-intro' }, h('p', { class: 'muted' }, L('speed.intro')), ui.help('speed.page')));
    el.speedPanels = {};
    var views = ['test', 'ip', 'results'], current = TP.prefs.get('speed.tab', 'test');
    if (views.indexOf(current) < 0) current = 'test';
    el.resultCard = buildResult();
    var contents = { test: buildTest(), ip: buildIp(), results: el.resultCard };
    var tabs = ui.tabs(L('speed.tabs.aria'), views.map(function (id) { return { id: id, label: L('speed.tab.' + id), icon: id === 'ip' ? 'globe' : 'speed' }; }), function (id) {
      tabs.set(id); views.forEach(function (k) { el.speedPanels[k].hidden = id !== k; }); TP.prefs.set('speed.tab', id);
    });
    root.appendChild(tabs.el); tabs.set(current);
    views.forEach(function (id) { el.speedPanels[id] = h('div', { role: 'tabpanel', id: 'speed-panel-' + id, 'aria-labelledby': tabs.btn(id).id }, contents[id]); tabs.btn(id).setAttribute('aria-controls', el.speedPanels[id].id); el.speedPanels[id].hidden = id !== current; root.appendChild(el.speedPanels[id]); });
    built = true;
    TP.on('lang', function () {
      renderAll();
      if (S.locked) return;
      if (active()) loadPlan(true);                                    // 目标名字由后端按语言给出: 切换语言后重新读取
      if (mg) loadTargets(true);
    });
    TP.on('prefs', function (d) {                                      // 登录后读到本机的偏好 / 别的设备同步过来
      if (!built || writing || !d || !(d.all || /^speed\./.test(String(d.key || '')))) return;
      masked = TP.prefs.get(PK.mask, false) === true; loadOpen(); loadSel(); renderAll();
    });
    TP.on('helper', function (up) {
      if (!built) return;
      renderIpCtl(); renderAction();
      if (up && active() && !S.locked) {                        // 辅助服务回来了: 补读之前失败的块
        if (net.st === 'err') loadInfo(true);
        if (plan.st === 'err') loadPlan(true);
        if (last.st === 'err') loadLast(true);
      }
    });
    TP.on('auth', function (ok) {
      if (!built) return;
      renderIpCtl(); renderAction();                           // 锁定 / 解锁后按钮的可用状态跟着变
      if (!ok) return;
      if (active()) V.show();
      else if (run.id) kickPoll(0);
      else { var sid = TP.ss.get('speed.run', ''); if (okId(sid)) attach(sid); }     // 刷新页面前正在测的任务: 后台继续跟踪, 完成时提示
    });
    var svSig = null;
    TP.on('state', function (st) {
      if (!built) return;
      var sig = JSON.stringify(arr(st && st.servers).map(function (x) { return [x.tag, x.role]; })), changed = svSig !== null && sig !== svSig;
      svSig = sig;
      if (changed && active() && !S.locked) loadPlan(true);      // 添加 / 删除服务器后, 节点列表和可用的模式跟着变
    });
    window.addEventListener('online', function () { if (built) renderIpCtl(); });
    window.addEventListener('offline', function () { if (built) renderIpCtl(); });
    document.addEventListener('visibilitychange', function () { if (!document.hidden && run.id) kickPoll(0); });
    renderAll();
  };

  /* 页面显示时: 读取 IP 缓存 / 测速计划; 有在跑的测速就接上, 否则读取上一次的结果。不做后台自动刷新。 */
  V.show = function () {
    if (!built) return;
    renderAll();
    if (S.locked) return;
    loadInfo(); loadPlan();
    if (run.id) { kickPoll(0); return; }
    var sid = TP.ss.get('speed.run', '');
    if (okId(sid)) attach(sid); else loadLast();
  };
  V.render = function () { renderAll(); };
  function renderAll() { if (!built) return; renderIp(); renderTest(); renderResult(); if (mg) renderMgr(); }

  /* ---------- A) IP 卡片 ---------- */
  function buildIp() {
    el.ipEye = ui.ibtn('eye', L('speed.mask.label'), { size: 16 });
    el.ipEye.setAttribute('aria-pressed', masked ? 'true' : 'false');
    el.ipEye.addEventListener('click', TP.safe(function () { masked = !masked; setPref(PK.mask, masked); renderIp(); }));
    el.ipBtn = ui.btn(t('common.refresh'), { sm: true, icon: 'refresh' });
    ui.act(el.ipBtn, refreshInfo);
    el.ipStat = h('div', { class: 'spd-statbox' });
    el.ipWarn = h('p', { class: 'hint warn', hidden: true });
    el.ipJob = h('div', { class: 'spd-job', hidden: true });
    el.ipCards = h('div', { class: 'spd-ipgrid' });
    el.ipEmpty = ui.emptyBox();
    return h('section', { class: 'card spd-sec', 'aria-labelledby': 'spd-h-ip' },
      h('div', { class: 'spd-hd' },
        h('div', { class: 'spd-hd-t' }, h('span', { class: 'spd-ht' }, h('h3', { id: 'spd-h-ip' }, L('speed.ip.title')), ui.help('speed.ip')), h('span', { class: 'muted sm' }, L('speed.ip.sub'))),
        h('div', { class: 'spd-acts' }, el.ipEye, ui.help('speed.mask'), el.ipBtn)),
      el.ipStat, el.ipWarn, el.ipJob, el.ipCards, el.ipEmpty.el);
  }

  /* IP 文本: 遮住时圆点代替, 并给读屏器一个「已隐藏」说明 */
  function ipNode(ip) {
    var s = String(ip || '');
    if (!s) return dash();
    if (!masked) return h('span', { class: 'spd-ip mono' }, s);
    return h('span', { class: 'spd-ip mono', role: 'img', 'aria-label': L('speed.mask.hidden'), title: L('speed.mask.tip') }, mask(s));
  }
  function kv(k, v) { return h('div', { class: 'spd-kv' }, h('span', { class: 'spd-k' }, k), h('span', { class: 'spd-v' }, v)); }
  function countryNode(o) {
    var cc = String(o.country || '').toUpperCase(), fl = flagOf(cc), name = o.country_name ? String(o.country_name) : '';
    if (!cc) return dash();
    return h('span', { class: 'spd-cc', title: name || null },
      fl ? h('span', { class: 'spd-flag', 'aria-hidden': 'true' }, fl) : null,
      h('span', { 'aria-hidden': name ? 'true' : null }, cc),
      name ? h('span', { class: 'spd-sr' }, name) : null);
  }
  function joinUniq(list) { return list.filter(function (x, i, a) { return x && a.indexOf(x) === i; }).join(' · '); }

  /* 出口信息的几行: 成功 -> IP / 国家 / 位置 / 网络; 失败 -> 原因 (已知代码有译文) + 提示 */
  function exitRows(o, key) {
    if (!o) return [kv(t(key), dash())];
    if (o.ok === false || !o.ip) {
      return [kv(t(key), h('span', { class: 'spd-fail' }, ui.icon('error', 14, 'spd-ci'), ' ', reasonNode(o.reason))), h('p', { class: 'muted sm spd-ipc-n' }, t('speed.ip.failHint'))];
    }
    var place = joinUniq([o.city, o.region]), netw = joinUniq([o.isp, o.asn]);
    return [kv(t(key), ipNode(o.ip)), kv(t('speed.k.country'), countryNode(o)), kv(t('speed.k.place'), place || dash()), kv(t('speed.k.network'), netw || dash())];
  }
  function cardShell(cls, icon, title, rows) {
    return h('article', { class: 'spd-ipc ' + cls }, h('div', { class: 'spd-ipc-h' }, h('span', { class: 'spd-ipc-ic' }, ui.icon(icon, 18)), h('h4', null, title)), rows);
  }
  function localCard(d) {
    var lan = d.lan || {}, rows = [kv(t('speed.k.lan'), lan.ip ? h('span', null, ipNode(lan.ip), lan.iface ? h('span', { class: 'muted' }, ' (' + lan.iface + ')') : null) : dash())];
    return cardShell('is-direct', TP.POLICY_ICON.direct, t('speed.card.local'), rows.concat(exitRows(d.direct, 'speed.k.public')));
  }
  function routeCard(r) {
    var pol = r.id === 'PIN' || r.id === 'Global';
    return cardShell(r.id === 'PIN' ? 'is-pin' : r.id === 'Global' ? 'is-auto' : '', (pol && TP.POLICY_ICON[r.id]) || 'server', pol ? TP.name.policy(r.id) : String(r.name || r.id), exitRows(r, 'speed.k.exit'));
  }
  /* routes 为空 = 还没有节点 (不是失败): 说明 + 「添加服务器」 */
  function noRoutesCard() {
    var b = ui.btn(t('why.addServer'), { kind: 'primary', sm: true, icon: 'plus' });
    ui.act(b, function () { TP.goAdd('manual'); });
    return h('article', { class: 'spd-ipc is-empty' }, h('div', { class: 'spd-ipc-h' }, h('span', { class: 'spd-ipc-ic' }, ui.icon('server', 18)), h('h4', null, t('speed.routes.title'))),
      h('p', { class: 'muted sm spd-ipc-n' }, t('speed.routes.none')), b);
  }
  function cardsNode(d) {
    var f = document.createDocumentFragment(), routes = arr(d.routes);
    f.appendChild(localCard(d));
    if (!routes.length) f.appendChild(noRoutesCard());
    else routes.forEach(function (r) { if (r) f.appendChild(routeCard(r)); });
    return f;
  }
  function statNode(d) {
    var s = own(STATES, d.state) ? d.state : 'unknown', m = STATES[s];
    return h('div', { class: 'spd-stat ' + m.cls },
      h('span', { class: 'spd-stat-ic' }, ui.icon(m.icon, 24)),
      h('div', { class: 'spd-stat-b' }, h('b', null, t('speed.state.' + s)), d.reason ? h('div', { class: 'spd-stat-r' }, String(d.reason)) : null),
      h('span', { class: 'spd-stat-time muted sm', title: fmt.dateTime(d.checked) }, t('speed.ip.checked', { time: fmt.clock(d.checked) })));
  }

  function refreshWhy() {
    if (net.refreshing) return t('speed.ip.refreshing');
    var w = TP.why.helper();
    if (w) return w;
    if (navigator.onLine === false) return t('speed.ip.offline');
    if (run.id) return t('speed.ip.testRunning');          // 测速占着线路选择器; 它自己会在开头刷新 IP
    return '';
  }
  function renderIpCtl() {
    if (!built) return;
    ui.setBtn(el.ipBtn, t(net.refreshing ? 'speed.ip.checking' : 'common.refresh'), 'refresh');
    el.ipBtn.classList.toggle('is-busy', net.refreshing);
    if (net.refreshing) el.ipBtn.setAttribute('aria-busy', 'true'); else el.ipBtn.removeAttribute('aria-busy');
    ui.avail(el.ipBtn, refreshWhy());
    el.ipEye.setAttribute('aria-pressed', masked ? 'true' : 'false');
    ui.setBtnIcon(el.ipEye, masked ? 'eye-off' : 'eye', 16);
  }
  function renderIp() {
    if (!built) return;
    var d = net.data, has = !!d && +d.checked > 0, warn = net.warn ? t('speed.ip.staleWarn', { reason: TP.errMsg(net.warn) }) : '';
    renderIpCtl();
    el.ipJob.hidden = !net.refreshing;
    el.ipWarn.hidden = !warn; setText(el.ipWarn, warn);
    if (!has) {
      ui.memo(el.ipStat, 'none', function () { return null; });
      ui.memo(el.ipCards, 'none', function () { return null; });
      if (net.refreshing) el.ipEmpty.hide();
      else if (!d && net.st === 'err') el.ipEmpty.show({ icon: 'wifi-off', text: t('speed.ip.loadFailed'), hint: TP.errMsg(net.err), action: { label: t('common.retry'), icon: 'refresh', fn: function () { return loadInfo(true); } } });
      else if (!d) el.ipEmpty.show({ icon: 'refresh', text: t('common.loading') });
      else el.ipEmpty.show({ icon: 'ip-unknown', text: t('speed.ip.never'), hint: t('speed.ip.neverHint'), action: { label: t('speed.ip.checkNow'), icon: 'refresh', fn: refreshInfo } });
      return;
    }
    el.ipEmpty.hide();
    ui.memo(el.ipStat, JSON.stringify([d.state, d.reason, d.checked]), function () { return statNode(d); });
    ui.memo(el.ipCards, JSON.stringify([masked, d]), function () { return cardsNode(d); });
  }

  async function loadInfo(force) {
    if (S.locked || (net.busy && !force)) return;
    net.busy = true;
    if (!net.data) { net.st = 'loading'; renderIp(); }
    try {
      var r = await TP.helper('GET', '/api/net/info');
      net.data = r; net.st = 'ok'; net.err = null; net.warn = null;
    } catch (e) {
      if (e && e.kind === 'auth') { if (!net.data) net.st = 'idle'; }
      else if (net.data) net.warn = e; else { net.st = 'err'; net.err = e; }
    }
    net.busy = false; renderIp();
  }

  /* 自己跟踪 net-info 任务 (不用 TP.jobs.follow: 它会把顶栏标成「正在应用配置」, 而这只是查询 IP, 不改配置) */
  async function followJob(id, card) {
    var fails = 0, t0 = Date.now(), j;
    for (;;) {
      try { j = await TP.helper('GET', '/api/job', { q: { id: id }, timeout: 8000 }); fails = 0; }
      catch (e) {
        if (e.kind === 'api' || e.kind === 'auth' || ++fails > 12) throw e;
        await TP.sleep(500); continue;
      }
      card.fromJob(j);
      if (j.state === 'done') return j;
      if (j.state === 'error') throw TP.mkErr('job', j.msg || t('speed.ip.failed'), j);
      if (Date.now() - t0 > 90000) throw TP.mkErr('job', t('speed.ip.timeout'));
      await TP.sleep(500);
    }
  }
  async function refreshInfo() {
    var why = refreshWhy();
    if (why) { ui.toast(why, 'warn'); return; }
    var card = ui.taskCard(t('speed.ip.job'));
    net.refreshing = true;
    TP.clear(el.ipJob); el.ipJob.appendChild(card.el);
    card.set({ pct: null, msg: t('speed.ip.jobStart') });
    renderIp(); renderAction();
    try {
      var r = await TP.helper('POST', '/api/net/refresh');
      if (r && r.job) await followJob(r.job, card);
      await loadInfo(true);
      if (active()) ui.toast(t('speed.ip.done'), 'ok', 2400);          // 用户已经离开本页时不打扰
    } finally {
      net.refreshing = false; TP.clear(el.ipJob); renderIp(); renderAction();
    }
  }

  /* ---------- B) 测速面板 ---------- */
  function buildTest() {
    /* 分段的值不用 'direct': 外壳样式会把选中的 data-v=direct 涂成灰底白字, 深色主题下看不清 (接口里的 mode 仍是 direct|node|both) */
    el.mode = ui.seg(L('speed.mode.aria'), [
      { v: 'direct-only', label: L('speed.mode.direct'), title: L('speed.mode.directTip') },
      { v: 'node', label: L('speed.mode.node'), title: L('speed.mode.nodeTip') },
      { v: 'both', label: L('speed.mode.both'), title: L('speed.mode.bothTip') }
    ], TP.safe(function (v) { sel.mode = v === 'direct-only' ? 'direct' : v; setPref(PK.mode, sel.mode); renderTest(); }), { onSame: function () { } });
    el.spd = h('input', { type: 'checkbox', role: 'switch', 'aria-labelledby': 'spd-sw-l', 'aria-describedby': 'spd-sw-d',
      on: { change: TP.safe(function () { sel.speed = el.spd.checked; setPref(PK.speed, sel.speed); renderTest(); }) } });
    el.spdHint = h('span', { class: 'muted sm', id: 'spd-sw-d' });
    el.nodeCount = h('span', { class: 'muted sm' });
    el.nodeDef = ui.btn(L('speed.nodes.defaults'), { sm: true, kind: 'ghost', icon: 'rotate-ccw' });
    ui.act(el.nodeDef, function () { setPref(PK.nodes, undefined); loadSel(); renderTest(); });         // 不再保存选择 -> 回到 plan 推荐的节点
    el.nodeAll = ui.btn(L('speed.sel.all'), { sm: true, kind: 'ghost', icon: 'check' }); ui.act(el.nodeAll, function () { setNodes(nodesBulkSelected() ? 'none' : 'all'); });
    el.nodeNone = ui.btn(L('speed.sel.none'), { sm: true, kind: 'ghost', icon: 'x' }); ui.act(el.nodeNone, function () { setNodes('none'); });
    /* 节点: 表格 (选择框 | 名称 | 角色 | 类型 | 延迟), 点整行也能选; 节点多时有搜索框 */
    el.nodeAllCb = h('input', { type: 'checkbox', 'aria-label': L('speed.nodes.allAria') });
    el.nodeAllCb.addEventListener('change', TP.safe(function () { setNodes(el.nodeAllCb.checked ? 'all' : 'none'); }));
    el.nodeBody = h('tbody');
    el.nodeQ = h('input', { class: 'inp sm spd-nq', type: 'search', placeholder: L('speed.nodes.search'), 'aria-label': L('speed.nodes.search'), autocomplete: 'off', hidden: true, on: { input: function () { nodeQ = el.nodeQ.value.trim().toLowerCase(); renderTest(); } } });
    el.nodeEmpty = h('p', { class: 'muted sm spd-nempty', hidden: true }, L('speed.nodes.empty'));
    el.nodeList = h('div', { class: 'spd-nodes', role: 'group', 'aria-label': L('speed.nodes.aria') }, el.nodeQ,
      h('div', { class: 'spd-ntw' }, h('table', { class: 'tbl spd-ntbl' },
        h('thead', null, h('tr', null, h('th', { class: 'c-ck' }, el.nodeAllCb), h('th', null, L('speed.nodes.col.name')), h('th', null, L('speed.nodes.col.role')), h('th', { class: 'spd-ntype' }, L('speed.nodes.col.type')), h('th', { class: 'num' }, L('speed.nodes.col.delay')))),
        el.nodeBody)), el.nodeEmpty);
    el.nodeNote = h('div', { class: 'spd-note' });
    el.form = h('div', { class: 'spd-form' },
      h('div', { class: 'spd-row' }, h('span', { class: 'spd-lab' }, L('speed.mode.label'), ui.help('speed.mode')), el.mode.el),
      h('div', { class: 'spd-swrow' },
        h('label', { class: 'spd-sw' }, h('span', { class: 'sw' }, el.spd, h('span', { class: 'sw-ui' })),
          h('span', { class: 'spd-sw-t' }, h('b', { id: 'spd-sw-l' }, L('speed.measure')), el.spdHint)),
        ui.help('speed.download')),
      h('div', { class: 'spd-block' }, h('div', { class: 'spd-lab-row' }, h('span', { class: 'spd-lab' }, L('speed.nodes.title'), ui.help('speed.nodes')), el.nodeCount, h('span', { class: 'spd-lab-r' }, el.nodeAll, el.nodeDef)), el.nodeList, el.nodeNote));

    /* 测速目标: 标题行 (含「管理测速目标」) 在测速进行中也保留, 按钮「暂不可用」并说明原因; 选择器本体 (el.tgBody) 在测速时隐藏 */
    el.tgCount = h('span', { class: 'muted sm', 'aria-live': 'polite' });
    el.mgrBtn = ui.btn(L('speed.tg.manage'), { sm: true, icon: 'list-checks' });
    ui.act(el.mgrBtn, openManage);
    el.tgDef = ui.btn(L('speed.sel.defaults'), { sm: true }); ui.act(el.tgDef, function () { setTargets('def'); });
    el.tgAll = ui.btn(L('speed.sel.all'), { sm: true }); ui.act(el.tgAll, function () { setTargets(selectedTargets().length === arr(plan.data && plan.data.targets).length ? 'none' : 'all'); });
    el.tgNone = ui.btn(L('speed.sel.none'), { sm: true }); ui.act(el.tgNone, function () { setTargets('none'); });
    el.tgBar = h('div', { class: 'spd-tgbar' }, el.tgDef, el.tgAll);
    el.groupList = h('div', { class: 'spd-groups', role: 'group', 'aria-label': L('speed.targets.aria') });
    el.groupNone = h('p', { class: 'muted sm', hidden: true }, L('speed.targets.none'));
    el.tgBody = h('div', { class: 'spd-tgbody' }, el.tgBar, el.groupList, el.groupNone);
    el.tgBox = h('div', { class: 'spd-block spd-tgbox' },
      h('div', { class: 'spd-lab-row' }, h('span', { class: 'spd-lab' }, L('speed.targets.title'), ui.help('speed.targets')), el.tgCount,
        h('span', { class: 'spd-lab-r' }, el.mgrBtn, ui.help('speed.manage'))),
      el.tgBody);

    el.runBar = ui.bar(); I.attr(el.runBar.el, 'aria-label', L('speed.run.aria'));
    el.runTitle = h('b'); el.runElapsed = h('span', { class: 'muted sm' });
    el.runPhase = h('div', { class: 'spd-run-p', 'aria-live': 'polite' });
    el.runMsg = h('div', { class: 'muted sm spd-run-m' });
    el.runNote = h('p', { class: 'hint warn', hidden: true });
    el.run = h('div', { class: 'spd-run', hidden: true }, h('div', { class: 'spd-run-h' }, el.runTitle, el.runElapsed), el.runBar.el, el.runPhase, el.runMsg, el.runNote);

    el.go = ui.btn(t('speed.startPlain'), { kind: 'primary', icon: 'speed' });
    ui.act(el.go, function () { return run.id ? stopTest() : startTest(); });
    el.est = h('p', { class: 'spd-est muted sm', 'aria-live': 'polite' });
    el.planBox = ui.emptyBox();
    return h('section', { class: 'card spd-sec', 'aria-labelledby': 'spd-h-test' },
      h('div', { class: 'spd-hd' }, h('div', { class: 'spd-hd-t' }, h('h3', { id: 'spd-h-test' }, L('speed.test.title')), h('span', { class: 'muted sm' }, L('speed.test.sub')))),
      h('div', { class: 'spd-actions' }, el.go, el.est), el.planBox.el, el.form, el.tgBox, el.run);
  }

  function directOk(p) { return !!p && p.direct_available !== false; }
  function nodeOk(p) { return !!p && p.node_available !== false && arr(p.nodes).length > 0; }
  function groupsOf(p) { return groupedTargets(arr(p.targets)); }
  function selectedTargets() { return plan.data ? arr(plan.data.targets).filter(function (x) { return sel.targets[x.id]; }) : []; }
  /* 默认勾选的目标: 接口给了 default 标记就用它; 一个标记都没有 (旧版辅助服务) 就当作全部 */
  function hasDefFlags(p) { return arr(p.targets).some(function (x) { return typeof x.default === 'boolean'; }); }
  function defaultTargets(p) { var f = hasDefFlags(p); return arr(p.targets).filter(function (x) { return !f || x.default; }); }
  /* 当前模式不可用时退到可用的 (没有节点 -> 直连; 没有直连 -> 节点) */
  function fixMode(m, p) {
    var d = directOk(p), n = nodeOk(p);
    if (m === 'direct' && !d) return n ? 'node' : m;
    if ((m === 'node' || m === 'both') && !n) return d ? 'direct' : m;
    if (m === 'both' && !d) return 'node';
    return m;
  }
  /* prefs 里保存的 id 列表按 plan 校验: 已不存在的丢掉并写回; 全都不存在了 (例如全部还原删掉了自定义目标) -> 忘掉这次选择, 回到默认。
   * 返回有效的列表, 没有保存过 / 已忘掉则返回 null。显式保存的空列表 (用户清空了选择) 原样保留。 */
  function pruneSaved(key, valid) {
    var cur = TP.prefs.get(key);
    if (!Array.isArray(cur)) return null;
    var keep = cur.filter(function (x) { return typeof x === 'string' && own(valid, x); });
    if (keep.length === cur.length) return keep;
    if (keep.length) { setPref(key, keep); return keep; }
    setPref(key, undefined);
    return null;
  }
  /* 把 prefs + plan.defaults 合成当前选择 (第一次读到 plan / 添加删除服务器 / 目标变了 / 偏好从别处同步过来之后都会调用) */
  function loadSel() {
    var p = plan.data;
    if (!p) return;
    var def = p.defaults || {}, tags = Object.create(null), ids = Object.create(null), v, saved;
    arr(p.nodes).forEach(function (n) { if (n && n.tag != null) tags[n.tag] = 1; });
    arr(p.targets).forEach(function (x) { ids[x.id] = 1; });
    v = TP.prefs.get(PK.mode);
    sel.mode = fixMode((v === 'direct' || v === 'node' || v === 'both') ? v : (def.mode === 'direct' || def.mode === 'node' || def.mode === 'both') ? def.mode : (nodeOk(p) ? 'both' : 'direct'), p);
    v = TP.prefs.get(PK.speed);
    sel.speed = typeof v === 'boolean' ? v : def.speed !== false;
    saved = Object.keys(tags).length ? pruneSaved(PK.nodes, tags) : null;                  // 暂时一个节点都没有 (读不到 / 还没添加): 不动已保存的选择
    sel.nodes = (saved || arr(def.nodes).filter(function (x) { return own(tags, x); })).slice(0, MAX_NODES);
    saved = Object.keys(ids).length ? pruneSaved(PK.targets, ids) : null;
    sel.targets = Object.create(null);
    (saved || defaultTargets(p).map(function (x) { return x.id; })).forEach(function (id) { sel.targets[id] = true; });
  }
  function applyPlan(p) {
    if (!p || typeof p !== 'object') throw TP.mkErr('api', t('speed.plan.failed'));
    plan.data = Object.assign({}, p, {
      targets: arr(p.targets).filter(function (x) { return x && x.id != null; }).map(function (x) { return Object.assign({}, x, { id: String(x.id), group: x.group ? String(x.group) : 'other', name: String(x.name || x.id) }); })
    });
    loadSel();
  }
  async function loadPlan(force) {
    if (S.locked || (plan.busy && !force)) return;
    var my = ++plan.seq;
    plan.busy = true;
    if (!plan.data) { plan.st = 'loading'; renderTest(); }
    try {
      var p = await TP.helper('GET', '/api/speedtest/plan', { timeout: 25000 });
      if (my === plan.seq) { applyPlan(p); plan.st = 'ok'; plan.err = null; }
    } catch (e) {
      if (my === plan.seq) {
        if (e && e.kind === 'auth') { if (!plan.data) plan.st = 'idle'; }
        else if (!plan.data) { plan.st = 'err'; plan.err = e; }          // 有旧数据时安静地沿用
      }
    }
    if (my === plan.seq) { plan.busy = false; renderTest(); }
  }

  /* 估算 (线性模型): 秒数 = 6 (查 IP) + 每条被探测的线路 3 × ceil(目标数 / 8) (同时探测 8 个) + 每个下载文件 8
   * (直连 2 个: 国内 + 海外, 每个节点 1 个海外文件, 每个文件最多 8 秒 / 8 MB)。plan.est 是辅助服务按 plan.defaults 估出来的:
   * 用它来校准 —— 显示值 = est × 模型(当前选择) / 模型(默认选择); 流量同理按「文件个数」折算。没有 est 时用模型本身。 */
  function model(mode, nodesN, speed, targetsN) {
    var probes = (mode !== 'node' ? 1 : 0) + (mode !== 'direct' ? nodesN : 0);
    var files = speed ? (mode !== 'node' ? 2 : 0) + (mode !== 'direct' ? nodesN : 0) : 0;
    return { secs: 6 + probes * 3 * Math.ceil(targetsN / 8) + files * 8, files: files };
  }
  function estimate() {
    var p = plan.data, def = p.defaults || {}, e = p.est || {};
    var d = model(def.mode || (nodeOk(p) ? 'both' : 'direct'), arr(def.nodes).length, def.speed !== false, defaultTargets(p).length);
    var s = model(sel.mode, sel.nodes.length, sel.speed, selectedTargets().length);
    var k = +e.seconds > 0 && d.secs > 0 ? e.seconds / d.secs : 1, perFile = +e.mb > 0 && d.files > 0 ? e.mb / d.files : 8;
    return { sec: Math.round(s.secs * k), mb: Math.round(s.files * perFile) };
  }

  /* 开始按钮暂时不能点的原因 (null = 可以) */
  function startWhy() {
    var p = plan.data, w = TP.why.helper();
    if (w) return { reason: w };
    if (!p) return plan.st === 'err'
      ? { reason: t('speed.start.noPlan'), fix: { label: t('common.retry'), fn: function () { loadPlan(true); } } }
      : { reason: t('speed.start.loading') };
    if (net.refreshing) return { reason: t('speed.start.ipBusy') };
    if (!directOk(p) && !nodeOk(p)) return { reason: t('speed.start.nothing'), fix: addFix() };
    if (!arr(p.targets).length) return { reason: t('speed.targets.none'), fix: { label: t('speed.tg.manage'), fn: openManage } };
    if (!selectedTargets().length) return { reason: t('speed.start.noTarget'), fix: { label: t('speed.sel.defaults'), fn: function () { setTargets('def'); } } };
    if (sel.mode !== 'direct' && !sel.nodes.length) return nodeOk(p) ? { reason: t('speed.start.noNode') } : { reason: t('speed.noNodes.reason'), fix: addFix() };
    return null;
  }

  function makeNode() {
    var ck = h('input', { type: 'checkbox' }), tr = h('tr', { class: 'spd-nrow' });
    tr._ck = ck; tr._name = h('span', { class: 'spd-nn' }); tr._role = h('span', { class: 'spd-role' }); tr._type = h('td', { class: 'spd-ntype muted sm' }); tr._delay = h('td', { class: 'num spd-nd' });
    tr.appendChild(h('td', { class: 'c-ck' }, ck)); tr.appendChild(h('td', null, tr._name)); tr.appendChild(h('td', null, tr._role)); tr.appendChild(tr._type); tr.appendChild(tr._delay);
    ck.addEventListener('change', TP.safe(function () { toggleNode(tr._tag); }));
    tr.addEventListener('click', TP.safe(function (ev) { if (ev.target !== ck) toggleNode(tr._tag); }));            // 点整行 = 选 / 取消
    return tr;
  }
  function updateNode(tr, n) {
    var on = sel.nodes.indexOf(n.tag) >= 0, d = +n.delay > 0 ? +n.delay : 0, sv = S.svMap && S.svMap[n.tag];
    tr._tag = n.tag;
    setText(tr._name, String(n.tag));
    if (tr._ck.checked !== on) tr._ck.checked = on;
    tr._ck.setAttribute('aria-label', String(n.tag));
    tr.setAttribute('aria-selected', on ? 'true' : 'false'); tr.classList.toggle('is-on', on);
    TP.setCls(tr._role, 'spd-role ' + (own(ROLES, n.role) ? n.role : ''));
    tr._role.hidden = !own(ROLES, n.role); setText(tr._role, own(ROLES, n.role) ? TP.name.role(n.role) : '');
    setText(tr._type, sv && sv.type ? String(sv.type) : DASH);
    setText(tr._delay, d ? ms(d) : DASH);
    tr.title = d ? t('speed.nodes.delayTip', { ms: ms(d) }) : t('speed.nodes.noDelay');
  }
  /* 节点「全选 / 全不选」: 一次最多测 MAX_NODES 个, 节点更多时只选前 MAX_NODES 个并说明 */
  function nodesBulk() { return arr(plan.data && plan.data.nodes).filter(function (n) { return n && (!nodeQ || String(n.tag).toLowerCase().indexOf(nodeQ) >= 0); }).map(function (n) { return n.tag; }).slice(0, MAX_NODES); }
  function nodesBulkSelected() { var tags = nodesBulk(); return tags.length > 0 && tags.every(function (tag) { return sel.nodes.indexOf(tag) >= 0; }); }
  function setNodes(how) {
    var tags = nodesBulk();
    sel.nodes = how === 'all' ? tags.slice(0, MAX_NODES) : [];
    if (how === 'all' && tags.length > MAX_NODES) ui.toast(t('speed.nodes.allMax', { n: MAX_NODES, total: tags.length }), 'warn', 5200);
    setPref(PK.nodes, sel.nodes.slice()); renderTest();
  }
  function toggleNode(tag) {
    var i = sel.nodes.indexOf(tag);
    if (i >= 0) sel.nodes.splice(i, 1);
    else {
      if (sel.nodes.length >= MAX_NODES) { ui.toast(t('speed.nodes.max', { n: MAX_NODES }), 'warn'); renderTest(); return; }          // renderTest: 把刚被点上的勾选框恢复回去
      sel.nodes.push(tag);
    }
    setPref(PK.nodes, sel.nodes.slice()); renderTest();
  }

  /* ----- 测速目标选择器: 分组可折叠, 每组显示「已选 N / 共 M」和 全选 / 清除 / 默认 ----- */
  function saveTargets() { setPref(PK.targets, selectedTargets().map(function (x) { return x.id; })); }
  function setTargets(how) {                              // how: 'all' | 'none' | 'def' (只选默认)
    var p = plan.data;
    if (!p) return;
    sel.targets = Object.create(null);
    arr(p.targets).forEach(function (x) { if (how === 'all' || (how === 'def' && (!hasDefFlags(p) || x.default))) sel.targets[x.id] = true; });
    saveTargets(); renderTest();
  }
  function setGroup(g, how) {
    var p = plan.data;
    if (!p) return;
    arr(p.targets).forEach(function (x) {
      if ((x.group || 'other') !== g) return;
      if (how === 'all' || (how === 'def' && (!hasDefFlags(p) || x.default))) sel.targets[x.id] = true; else delete sel.targets[x.id];
    });
    saveTargets(); renderTest();
  }
  function toggleTarget(id) {
    if (sel.targets[id]) delete sel.targets[id]; else sel.targets[id] = true;
    saveTargets(); renderTest();
  }
  function toggleOpen(g) {
    if (openG[g]) delete openG[g]; else openG[g] = true;
    setPref(PK.open, Object.keys(openG)); renderTest();
  }
  function makeChip() {
    var b = h('button', { class: 'spd-tc', type: 'button', 'aria-pressed': 'false' });
    b._ck = h('span', { class: 'spd-ck' }, ui.icon('check', 11, 'spd-ci')); b._ic = h('span', { class: 'spd-tc-ic' }); b._nm = h('span', { class: 'spd-nn' });
    b.appendChild(b._ck); b.appendChild(b._ic); b.appendChild(b._nm);
    b.addEventListener('click', TP.safe(function () { toggleTarget(b._id); }));
    return b;
  }
  function updateChip(b, x) {
    var ic = targetIcon(x);
    b._id = x.id;
    if (b._icn !== ic) { b._icn = ic; TP.clear(b._ic); b._ic.appendChild(ui.icon(ic, 14)); }
    setText(b._nm, x.name);
    b.setAttribute('aria-pressed', sel.targets[x.id] ? 'true' : 'false');
    b.title = x.url ? String(x.url) : '';
  }
  function makeGroup() {
    var row = h('section', { class: 'spd-tg' }), r = {};
    r.ic = h('span', { class: 'spd-tg-ic' }); r.name = h('b', { class: 'spd-tg-n' }); r.cnt = h('span', { class: 'chip' });
    r.t = h('button', { class: 'spd-tg-t', type: 'button', 'aria-expanded': 'false' }, ui.icon('chevron-right', 16, 'spd-tg-chev'), r.ic, r.name, r.cnt);
    r.bAll = ui.btn(L('speed.sel.gAll'), { sm: true, kind: 'ghost' }); r.bNone = ui.btn(L('speed.sel.gNone'), { sm: true, kind: 'ghost' }); r.bDef = ui.btn(L('speed.sel.gDef'), { sm: true, kind: 'ghost' });
    r.body = h('div', { class: 'spd-tg-b', hidden: true });
    r.t.addEventListener('click', TP.safe(function () { toggleOpen(row._id); }));
    r.bAll.addEventListener('click', TP.safe(function () { setGroup(row._id, row._allSelected ? 'none' : 'all'); }));
    r.bNone.addEventListener('click', TP.safe(function () { setGroup(row._id, 'none'); }));
    r.bDef.addEventListener('click', TP.safe(function () { setGroup(row._id, 'def'); }));
    row.appendChild(h('div', { class: 'spd-tg-h' }, r.t, h('span', { class: 'spd-tg-a', role: 'group' }, r.bAll, r.bDef)));
    row.appendChild(r.body);
    row._r = r;
    return row;
  }
  function updateGroup(row, g) {
    var r = row._r, open = !!openG[g.id], n = 0, name = groupName(g.id), all = g.items.length;
    row._id = g.id;
    g.items.forEach(function (x) { if (sel.targets[x.id]) n++; });
    if (!r.icSet) { r.icSet = true; r.ic.appendChild(ui.icon(groupIcon(g.id), 16)); }
    setText(r.name, name);
    setText(r.cnt, t('speed.sel.groupCount', { n: n, total: all }));
    TP.setCls(r.cnt, 'chip' + (n === all ? ' rec' : n > 0 ? ' info' : ''));
    r.t.setAttribute('aria-expanded', open ? 'true' : 'false');
    r.t.setAttribute('aria-label', t('speed.sel.toggleAria', { name: name, n: n, total: all }));
    row._allSelected = n === all; ui.setBtn(r.bAll, t(n === all ? 'speed.sel.gNone' : 'speed.sel.gAll'));
    r.bAll.setAttribute('aria-label', t('speed.sel.allAria', { name: name })); r.bNone.setAttribute('aria-label', t('speed.sel.noneAria', { name: name })); r.bDef.setAttribute('aria-label', t('speed.sel.defaultsAria', { name: name }));
    r.body.hidden = !open; row.classList.toggle('is-open', open);
    if (open) ui.syncList(r.body, g.items, function (x) { return x.id; }, makeChip, updateChip);
  }
  function renderTargets(p) {
    var total = arr(p.targets).length;
    setText(el.tgCount, total ? t('speed.sel.count', { n: selectedTargets().length, total: total }) : '');
    el.tgBar.hidden = !total;
    ui.setBtn(el.tgAll, t(total && selectedTargets().length === total ? 'speed.sel.none' : 'speed.sel.all'), 'check');
    ui.syncList(el.groupList, groupsOf(p), function (g) { return g.id; }, makeGroup, updateGroup);
    el.groupNone.hidden = total > 0;
  }

  function renderForm(p) {
    var dOk = directOk(p), nOk = nodeOk(p), showChips = nOk && sel.mode !== 'direct', e = estimate();
    el.mode.set(sel.mode === 'direct' ? 'direct-only' : sel.mode);
    el.mode.avail('direct-only', dOk ? '' : t('speed.mode.directUnavail'));
    ['node', 'both'].forEach(function (m) { el.mode.avail(m, nOk ? '' : t('speed.noNodes.reason'), nOk ? null : addFix()); });
    el.spd.checked = !!sel.speed;
    setText(el.spdHint, sel.speed ? t('speed.measure.on', { mb: fmt.num(e.mb) }) : t('speed.measure.off'));
    el.nodeList.hidden = !showChips; el.nodeNote.hidden = showChips; el.nodeDef.hidden = !showChips; el.nodeAll.hidden = !showChips; el.nodeNone.hidden = true;
    ui.setBtn(el.nodeAll, nodesBulkSelected() ? t('speed.sel.none') : nodesBulk().length < arr(p.nodes).length ? t('speed.nodes.selectMax', { n: MAX_NODES }) : t('speed.sel.all'), 'check');
    el.nodeAll.setAttribute('aria-label', t('speed.nodes.allAria')); el.nodeNone.setAttribute('aria-label', t('speed.nodes.noneAria'));
    setText(el.nodeCount, showChips ? t('speed.nodes.count', { n: sel.nodes.length, max: MAX_NODES }) : '');
    if (showChips) {
      var all = arr(p.nodes).filter(Boolean), shown = nodeQ ? all.filter(function (n) { return String(n.tag).toLowerCase().indexOf(nodeQ) >= 0; }) : all, nsel = shown.filter(function (n) { return sel.nodes.indexOf(n.tag) >= 0; }).length;
      el.nodeQ.hidden = all.length <= 8; el.nodeEmpty.hidden = shown.length > 0;
      ui.syncList(el.nodeBody, shown, function (n) { return n.tag; }, makeNode, updateNode);
      el.nodeAllCb.checked = nodesBulkSelected(); el.nodeAllCb.indeterminate = nsel > 0 && nsel < shown.length;
    }
    else ui.memo(el.nodeNote, nOk ? 'direct' : 'none', function () {
      if (nOk) return h('span', { class: 'muted' }, t('speed.nodes.directNote'));
      var b = ui.btn(t('why.addServer'), { kind: 'primary', sm: true, icon: 'plus' });
      ui.act(b, function () { TP.goAdd('manual'); });
      return h('span', null, h('span', null, t('speed.nodes.none')), ' ', b);
    });
  }
  function renderTest() {
    if (!built) return;
    var p = plan.data;
    if (!p) {
      el.form.hidden = true; el.tgBox.hidden = true;
      if (plan.st === 'err') el.planBox.show({ icon: 'wifi-off', text: t('speed.plan.failed'), hint: TP.errMsg(plan.err), action: { label: t('common.retry'), icon: 'refresh', fn: function () { return loadPlan(true); } } });
      else el.planBox.show({ icon: 'refresh', text: t('common.loading') });
    } else {
      el.planBox.hide();
      el.form.hidden = !!run.id; el.tgBox.hidden = false; el.tgBody.hidden = !!run.id;
      if (!run.id) { renderForm(p); renderTargets(p); }
      else setText(el.tgCount, t('speed.sel.count', { n: selectedTargets().length, total: arr(p.targets).length }));
    }
    renderRun(); renderAction();
  }
  function renderAction() {
    if (!built) return;
    var b = el.go, running = !!run.id, why, e;
    ui.avail(el.mgrBtn, mgrWhy());                                   // 测速进行中 / 辅助服务不可用: 管理按钮暂不可用 (说明原因)
    if (mg) renderMgr();
    b.classList.toggle('primary', !running); b.classList.toggle('danger', running);
    el.est.hidden = running;
    if (running) {
      ui.setBtn(b, t(run.stopping ? 'speed.stopping' : 'speed.stop'), 'stop');
      b._renderBusy = run.stopping; b.disabled = run.stopping || !!b._busy;
      ui.avail(b, run.stopping ? t('speed.stopping.reason') : TP.why.helper());
      return;
    }
    b._renderBusy = false; b.disabled = !!b._busy;
    why = startWhy(); e = plan.data ? estimate() : null;
    ui.setBtn(b, e ? t(sel.speed ? 'speed.start' : 'speed.startLatency', { dur: dur(e.sec) }) : t('speed.startPlain'), 'speed');
    ui.avail(b, why ? why.reason : '', why && why.fix);
    setText(el.est, e ? t(sel.speed ? 'speed.est.speed' : 'speed.est.latency', { dur: dur(e.sec), mb: fmt.num(e.mb) }) : '');
  }
  function showRunDialog() {
    if (runDialog) return;
    var runParent = el.run.parentNode, resultParent = el.resultCard.parentNode;
    runDialog = ui.modal({ title: t('speed.test.title'), icon: 'speed', size: 'lg', cls: 'spd-dialog',
      body: h('div', null, el.run, el.resultCard),
      actions: [], onClose: function () { runParent.appendChild(el.run); resultParent.appendChild(el.resultCard); runDialog = null; runDialogSig = ''; renderAll(); }
    });
    runDialogSig = ''; renderRunDialog();
  }
  function renderRunDialog() {
    if (!runDialog) return;
    var sig = !!run.id + '|' + run.stopping;
    if (sig === runDialogSig) return;
    runDialogSig = sig;
    runDialog.setActions(run.id ? [
      { label: t('speed.run.background'), cancel: true },
      { label: t(run.stopping ? 'speed.stopping' : 'speed.stop'), icon: 'stop', kind: 'danger', keep: true,
        disabled: run.stopping, unavail: run.stopping ? { reason: t('speed.stopping.reason') } : null, onClick: async function () { await stopTest(); return false; } }
    ] : [{ label: t('common.close'), cancel: true }]);
  }
  function renderRun() {
    if (!built) return;
    renderRunDialog();
    el.run.hidden = !run.id;
    if (!run.id) return;
    var r = run.res, pct = r ? Math.max(0, Math.min(100, +r.pct || 0)) : 0;
    el.runBar.set(r ? pct : null);
    setText(el.runTitle, r ? t(run.stopping ? 'speed.run.stopping' : 'speed.run.title', { pct: fmt.num(Math.round(pct)) }) : t('speed.run.starting'));
    setText(el.runElapsed, r ? t('speed.run.elapsed', { n: fmt.num(Math.max(0, Math.round(+r.elapsed || 0))) }) : '');
    setText(el.runPhase, r && own(PHASES, r.phase) ? t('speed.phase.' + r.phase) : '');
    setText(el.runMsg, r && r.msg ? String(r.msg) : '');
    el.runNote.hidden = run.fails < 3; setText(el.runNote, run.fails >= 3 ? t('speed.run.lost') : '');
  }

  /* ---------- 开始 / 停止 / 跟踪 ---------- */
  async function startTest() {
    var form = { mode: sel.mode, speed: sel.speed ? '1' : '0', targets: selectedTargets().map(function (x) { return x.id; }).join(',') }, r;
    if (sel.mode !== 'direct') form.nodes = sel.nodes.join(',');
    try { r = await TP.helper('POST', '/api/speedtest/start', { form: form }); }
    catch (e) {
      if (e && e.code === 'E_RUNNING') { await attachRunning(e); return; }
      if (e && e.code === 'E_NO_SERVERS') { ui.toast(t('speed.toast.noServers'), 'warn', 6500, { action: addFix() }); loadPlan(true); return; }
      if (e && e.code === 'E_INVALID') loadPlan(true);                 // 目标 / 节点在别处被改掉了: 重新读取计划, 选择会按它校验
      throw e;
    }
    if (!r || !okId(r.id)) throw new Error(t('speed.toast.noId'));
    attach(r.id); showRunDialog();
  }
  /* E_RUNNING: 先用错误里带的 id; 没有就问 status (不带 id) 当前在跑哪个; 都不行就只提示 */
  async function attachRunning(e) {
    var id = e.data && okId(e.data.id) ? e.data.id : '';
    if (!id) {
      try { var s = await TP.helper('GET', '/api/speedtest/status', { timeout: 8000 }); if (s && s.state === 'running' && okId(s.id)) id = s.id; }
      catch (x) { if (x && x.kind === 'auth') return; }
    }
    if (id) { attach(id); showRunDialog(); ui.toast(t('speed.toast.attached'), '', 4200); }
    else ui.toast(t('speed.toast.running'), 'warn');
  }
  async function stopTest() {
    if (!run.id || run.stopping) return;
    run.stopping = true; run.stopAt = Date.now(); renderRun(); renderAction();
    try { await TP.helper('POST', '/api/speedtest/stop', { q: { id: run.id } }); kickPoll(0); }
    catch (e) { run.stopping = false; renderRun(); renderAction(); throw e; }
  }
  function attach(id) {
    run.id = id; run.res = null; run.stopping = false; run.fails = 0;
    TP.ss.set('speed.run', id);
    renderAll();
    kickPoll(0);
  }
  function drop() {
    clearTimeout(poll.timer); poll.timer = 0;
    run.id = ''; run.res = null; run.stopping = false; run.fails = 0;
    TP.ss.del('speed.run');
  }
  /* 串行轮询: 在本页 1 秒一次, 别的页签 / 页面隐藏时 3 秒一次; 任务结束或丢失后停止 */
  function kickPoll(delay) {
    if (!run.id || poll.busy) return;
    clearTimeout(poll.timer);
    poll.timer = setTimeout(tick, delay || 0);
  }
  async function tick() {
    poll.timer = 0;
    if (!run.id || S.locked) return;                       // 锁定时停下, 登录后由 'auth' 事件接着跟踪
    var id = run.id, r = null, err = null, stop = false;
    poll.busy = true;
    try { r = await TP.helper('GET', '/api/speedtest/status', { q: { id: id }, timeout: 8000 }); } catch (e) { err = e; }
    poll.busy = false;
    if (run.id !== id) { kickPoll(0); return; }            // 期间换了任务 / 已放弃
    try { stop = onStatus(r, err); } catch (e) { console.error('[speed.poll]', e); }       // 渲染出错也不能让轮询停下
    if (!stop && run.id && !poll.timer) poll.timer = setTimeout(tick, active() && !document.hidden && run.fails < 3 ? 1000 : 3000);
  }
  /* 处理一次轮询结果; 返回 true = 不再继续轮询 (已结束 / 丢失 / 需要登录) */
  function onStatus(r, err) {
    if (err) {
      if (err.kind === 'auth') return true;                // 登录框已弹出, 静默
      if (err.code === 'E_NOT_FOUND') { drop(); renderAll(); loadLast(true); return true; }
      run.fails++;
      if (run.fails > 40) { drop(); renderAll(); ui.toast(t('speed.toast.lost'), 'warn'); loadLast(true); return true; }
      renderRun();
      return false;
    }
    if (r && r.state === 'running') {
      run.fails = 0; run.res = r;
      if (run.stopping && Date.now() - run.stopAt > 10000) { run.stopping = false; renderAction(); }       // 停止请求 10 秒后任务还在跑: 让用户可以再点一次
      renderRun(); renderResult(); return false;
    }
    if (r && r.state) { finish(r); return true; }
    run.fails++; renderRun();
    return false;
  }
  function finish(r) {
    var away = !active(), view = away ? { action: { label: t('speed.view'), fn: function () { TP.go('speed'); } } } : null;
    drop();
    last.res = r; last.st = 'ok'; last.err = null;
    renderAll();
    if (r.state === 'done') ui.toast(t('speed.toast.done'), 'ok', away ? 9000 : 3800, view);
    else if (r.state === 'stopped') { if (away) ui.toast(t('speed.toast.stopped'), 'warn', 7000, view); }
    else ui.toast(t('speed.toast.failed', { reason: r.msg || t('speed.toast.unknown') }), 'err', 9000, view);
    if (active() && !S.locked) loadInfo(true);             // 测速开头刷新过 IP 缓存
  }

  async function loadLast(force) {
    if (S.locked || (last.busy && !force)) return;
    last.busy = true;
    if (!last.res) { last.st = 'loading'; renderResult(); }
    try {
      var r = await TP.helper('GET', '/api/speedtest/last');
      if (r && !r.none && r.state) { last.res = r; last.st = 'ok'; } else { last.res = null; last.st = 'none'; }
      last.err = null;
    } catch (e) {
      if (e && e.kind === 'auth') { if (!last.res) last.st = 'idle'; }
      else if (!last.res) { last.st = 'err'; last.err = e; }
    }
    last.busy = false; renderResult();
  }

  /* ---------- C) 结果 ---------- */
  function legendItem(kind, key) {
    var mark = kind === 'ok' || kind === 'slow' ? h('i', { class: 'spd-dot ' + kind })
      : ui.icon(kind === 'limited' ? 'warning' : kind === 'fail' ? 'x' : kind === 'pending' ? 'clock' : 'minus', 13, 'spd-ci ' + kind);
    return h('span', { class: 'spd-lg' }, mark, h('span', null, L(key)));
  }
  function buildResult() {
    el.resStrip = h('div', { class: 'spd-strip' });
    el.resEmpty = ui.emptyBox();
    el.mxHint = h('p', { class: 'hint', hidden: true });
    el.mxScroll = h('div', { class: 'spd-scroll', tabindex: '0', role: 'region', 'aria-label': L('speed.mx.region'), hidden: true });
    el.legend = h('div', { class: 'spd-legend', hidden: true },
      legendItem('ok', 'speed.legend.ok'), legendItem('slow', 'speed.legend.slow'), legendItem('limited', 'speed.legend.limited'),
      legendItem('fail', 'speed.legend.fail'), legendItem('pending', 'speed.legend.pending'), legendItem('skip', 'speed.legend.skip'));
    el.dlBody = h('div', { class: 'spd-dl-body' });
    el.dl = h('div', { class: 'spd-dl' }, h('div', { class: 'spd-ht' }, h('h4', { class: 'spd-dl-t' }, L('speed.dl.title')), ui.help('speed.numbers')), el.dlBody);
    el.resBody = h('div', { class: 'spd-sec', hidden: true }, el.mxHint, el.mxScroll, el.legend, el.dl);
    return h('section', { class: 'card spd-sec', 'aria-labelledby': 'spd-h-res' },
      h('div', { class: 'spd-hd' }, h('div', { class: 'spd-hd-t' }, h('span', { class: 'spd-ht' }, h('h3', { id: 'spd-h-res' }, L('speed.res.title')), ui.help('speed.matrix')), h('span', { class: 'muted sm' }, L('speed.res.sub')))),
      el.resStrip, el.resEmpty.el, el.resBody);
  }
  function viewRes() { return run.id ? run.res : last.res; }
  function renderResult() {
    if (!built) return;
    var r = viewRes();
    if (!r) {
      el.resStrip.hidden = true; el.resBody.hidden = true;
      if (run.id) el.resEmpty.show({ icon: 'speed', text: t('speed.res.starting'), hint: t('speed.res.startingHint') });
      else if (last.st === 'err') el.resEmpty.show({ icon: 'wifi-off', text: t('speed.res.loadFailed'), hint: TP.errMsg(last.err), action: { label: t('common.retry'), icon: 'refresh', fn: function () { return loadLast(true); } } });
      else if (last.st === 'none') el.resEmpty.show({ icon: 'speed', text: t('speed.res.none'), hint: t('speed.res.noneHint') });
      else el.resEmpty.show({ icon: 'refresh', text: t('common.loading') });
      if (detail) detail.update();
      return;
    }
    el.resEmpty.hide(); el.resStrip.hidden = false; el.resBody.hidden = false;
    renderStrip(r); renderMatrix(r); renderSpeeds(r);
    if (detail) detail.update();                           // 打开着的详情弹窗跟着测速进度刷新
  }
  /* 标题条: 运行中 / 已完成 / 已停止 / 出错 (带 msg) + 上次测速时间 */
  function renderStrip(r) {
    var running = r.state === 'running', st = running ? 'running' : r.state === 'done' ? 'done' : r.state === 'stopped' ? 'stopped' : 'error';
    var started = +r.started > 0 ? fmt.dateTime(r.started) : '', took = !running && +r.elapsed > 0 ? Math.round(+r.elapsed) : 0;
    ui.memo(el.resStrip, JSON.stringify([st, started, took, st === 'error' ? r.msg : '']), function () {
      var chip = st === 'running' ? ui.chip(t('speed.res.running'), '', 'refresh') : st === 'done' ? ui.chip(t('speed.res.done'), 'ok', 'success')
        : st === 'stopped' ? ui.chip(t('speed.res.stopped'), 'warn', 'stop') : ui.chip(t('speed.res.error'), 'bad', 'error');
      var when = started ? t(running ? 'speed.res.started' : 'speed.res.last', { time: started }) + (took ? ' · ' + t('speed.res.took', { n: fmt.num(took) }) : '') : '';
      return h('div', { class: 'spd-strip-in' }, chip, when ? h('span', { class: 'spd-strip-t' }, when) : null, st === 'error' && r.msg ? h('div', { class: 'spd-strip-m bad-t' }, String(r.msg)) : null);
    });
  }

  function routesOf(r) {
    var rs = arr(r.routes).filter(function (x) { return x && x.id != null; }).map(function (x) { return Object.assign({}, x, { id: String(x.id) }); });
    return rs.filter(isDirect).concat(rs.filter(function (x) { return !isDirect(x); }));        // 「本地直连」排第一
  }
  function targetsOf(r) { return arr(r.targets).filter(function (x) { return x && x.id != null; }).map(function (x) { return Object.assign({}, x, { id: String(x.id) }); }); }
  /* 每条线路: 平均延迟 / 正常数 / 总数 (接口给了 summary 就用它, 否则自己从 cells 算) */
  function routeStats(r, id) {
    var sm = r.summary || {}, cs, good, okn, tot, avg;
    if (sm.ok && sm.total && own(sm.ok, id) && own(sm.total, id)) {
      okn = +sm.ok[id] || 0; tot = +sm.total[id] || 0; avg = sm.avg_ms ? +sm.avg_ms[id] || 0 : 0;
    } else {
      cs = arr(r.cells).filter(function (c) { return c && c.r === id; });
      good = cs.filter(function (c) { return c.st === 'ok' || c.st === 'slow'; });
      okn = good.length; tot = cs.filter(function (c) { return c.st !== 'pending' && c.st !== 'skip'; }).length;
      avg = okn ? good.reduce(function (a, c) { return a + (+c.ms || 0); }, 0) / okn : 0;
    }
    return { ok: okn, total: tot, avg: avg };
  }
  /* 「最佳」只在完整测完后标出 (边测边变的结论没有意义, 手动停止的也不完整), 且它至少要有一个正常的结果 */
  function bestOf(r, routes) {
    var sm = r.summary || {};
    return r.state === 'done' && routes.length > 1 && sm.best != null && sm.ok && +sm.ok[sm.best] > 0 ? String(sm.best) : '';
  }
  function renderMatrix(r) {
    var routes = routesOf(r), targets = targetsOf(r), running = r.state === 'running';
    if (!routes.length || !targets.length) {
      mx.sig = ''; el.mxScroll.hidden = true; el.legend.hidden = true;
      el.mxHint.hidden = false; setText(el.mxHint, t(running ? 'speed.mx.waiting' : 'speed.mx.empty'));
      return;
    }
    el.mxHint.hidden = true; el.mxScroll.hidden = false; el.legend.hidden = false;
    var sig = I.lang + '|' + JSON.stringify([routes.map(function (x) { return [x.id, x.name, x.kind, x.role]; }), targets.map(function (x) { return [x.id, x.group, x.name]; })]);
    if (mx.sig !== sig) { mx.sig = sig; buildMatrix(routes, targets); }
    updateMatrix(r, routes, targets);
  }
  function buildMatrix(routes, targets) {
    var head = h('tr', null, h('th', { class: 'spd-c1', scope: 'col' }, t('speed.mx.site'))), table;
    mx.cells = Object.create(null); mx.heads = Object.create(null);
    routes.forEach(function (r) {
      var hd = { th: h('th', { class: 'spd-rh', scope: 'col' }), best: h('span', { class: 'spd-best', hidden: true }, ui.icon('success', 12), t('speed.best')), avg: h('span'), ok: h('span') };
      var more = ui.btn(t('speed.dt.open'), { sm: true, kind: 'ghost', icon: 'list-checks', aria: t('speed.dt.openAria', { name: routeLabel(r) }), cls: 'spd-rmore' });
      more.addEventListener('click', TP.safe(function () { openRoute(r.id); }));
      hd.th.appendChild(h('div', { class: 'spd-rt' }, h('span', { class: 'spd-rn' }, routeLabel(r)), roleBadge(r), hd.best));
      hd.th.appendChild(h('div', { class: 'spd-rs muted' }, hd.avg, hd.ok));
      hd.th.appendChild(more);
      mx.heads[r.id] = hd; head.appendChild(hd.th);
    });
    table = h('table', { class: 'spd-mx' }, h('caption', { class: 'spd-sr' }, t('speed.mx.caption')), h('thead', null, head));
    groupedTargets(targets).forEach(function (g) {
      var tb = h('tbody', null, h('tr', { class: 'spd-grp' }, h('th', { class: 'spd-c1', scope: 'rowgroup' }, groupName(g.id)), h('td', { colspan: routes.length })));
      g.items.forEach(function (tgt) {
        var tr = h('tr', null, h('th', { class: 'spd-c1', scope: 'row' }, String(tgt.name || tgt.id)));
        routes.forEach(function (r) {
          var td = h('td', { class: 'spd-cell s-pending' });
          mx.cells[tgt.id + SEP + r.id] = { td: td, tid: tgt.id, rid: r.id, site: String(tgt.name || tgt.id), route: routeLabel(r), sig: '' };
          tr.appendChild(td);
        });
        tb.appendChild(tr);
      });
      table.appendChild(tb);
    });
    TP.clear(el.mxScroll); el.mxScroll.appendChild(table);
  }
  function updateMatrix(r, routes, targets) {
    var map = Object.create(null), best = bestOf(r, routes);
    arr(r.cells).forEach(function (c) { if (c) map[c.t + SEP + c.r] = c; });
    routes.forEach(function (rt) {
      var hd = mx.heads[rt.id], s;
      if (!hd) return;
      s = routeStats(r, rt.id);
      setText(hd.avg, s.avg > 0 ? t('speed.mx.avg', { ms: ms(s.avg) }) : DASH);
      setText(hd.ok, s.total > 0 ? t('speed.mx.okTotal', { ok: fmt.num(s.ok), total: fmt.num(s.total) }) : '');
      hd.best.hidden = rt.id !== best; hd.th.classList.toggle('is-best', rt.id === best);
    });
    targets.forEach(function (tgt) {
      routes.forEach(function (rt) {
        var k = tgt.id + SEP + rt.id, n = mx.cells[k], c = map[k] || { st: 'pending' }, isBest = rt.id === best, sig;
        if (!n) return;
        sig = [c.st, c.ms, c.connect, c.ttfb, c.http, c.err, isBest].join('|');
        if (n.sig !== sig) { n.sig = sig; paintCell(n, c, isBest); }
      });
    });
  }
  function cellState(c) { return c && own(CELL_ST, c.st) ? c.st : 'pending'; }
  /* 一个单元格: 有结果的 (正常 / 较慢 / 受限 / 失败) 是一个按钮, 点开 (或键盘回车) 看所有数字; 还没测到 / 不适用的只是文字。
   * 可见部分 aria-hidden 的单元格另带 .spd-sr 说明; 按钮用 aria-label 读出完整说明。 */
  function paintCell(n, c, best) {
    var st = cellState(c), say, vis = h('span', { class: 'spd-cv' }), act = true;
    if (st === 'ok' || st === 'slow') {
      vis.appendChild(h('i', { class: 'spd-dot ' + st })); vis.appendChild(document.createTextNode(ms(c.ms)));
      say = t(st === 'ok' ? 'speed.cell.ok' : 'speed.cell.slow', { ms: ms(c.ms) });
    } else if (st === 'limited') {
      vis.appendChild(ui.icon('warning', 14, 'spd-ci')); if (c.http) vis.appendChild(document.createTextNode(String(c.http)));
      say = t('speed.cell.limited', { http: c.http || DASH });
    } else if (st === 'fail') {
      vis.appendChild(ui.icon('x', 14, 'spd-ci'));
      say = t('speed.cell.fail', { why: reasonText(c.err) });
    } else {
      act = false;
      vis.appendChild(ui.icon(st === 'skip' ? 'minus' : 'clock', 14, 'spd-ci')); say = t(st === 'skip' ? 'speed.cell.skip' : 'speed.cell.pending');
    }
    TP.clear(n.td);
    n.td.className = 'spd-cell s-' + st + (act ? ' has-b' : '') + (best ? ' is-best' : '');
    if (act) {
      var b = h('button', { class: 'spd-cb', type: 'button', 'aria-haspopup': 'dialog', 'aria-label': t('speed.cell.aria', { site: n.site, route: n.route, say: say }), title: say }, vis);
      b.addEventListener('click', TP.safe(function () { openCell(n.tid, n.rid); }));
      n.td.removeAttribute('title'); n.td.appendChild(b);
    } else {
      vis.setAttribute('aria-hidden', 'true');
      n.td.title = say; n.td.appendChild(vis); n.td.appendChild(h('span', { class: 'spd-sr' }, say));
    }
  }

  /* 下载速度: 每种文件 (global 海外 / cn 国内) 一组, 每条线路一根条, 按该组的最大值取比例 */
  function renderSpeeds(r) {
    var routes = routesOf(r), sp = arr(r.speeds).filter(function (x) { return x && x.r != null; }), finished = r.state !== 'running';
    var latencyOnly = r.speed === false || (finished && !sp.length);
    ui.memo(el.dlBody, JSON.stringify([routes.map(function (x) { return [x.id, x.name, x.kind, x.role]; }), sp, latencyOnly, finished]), function () {
      var f = document.createDocumentFragment();
      if (!sp.length) { f.appendChild(h('p', { class: 'muted sm' }, t(latencyOnly ? 'speed.dl.latencyOnly' : 'speed.dl.waiting'))); return f; }
      ['global', 'cn'].forEach(function (kind) {
        var rows = sp.filter(function (x) { return x.kind === kind; }), max = 0, box;
        if (!rows.length) return;
        rows.forEach(function (x) { if (+x.kbps > max) max = +x.kbps; });
        rows.sort(function (a, b) { return routeIndex(routes, a.r) - routeIndex(routes, b.r); });
        box = h('div', { class: 'spd-dl-k' }, h('div', { class: 'spd-dl-kt' }, t('speed.dl.' + kind)));
        rows.forEach(function (x) {
          var rt = routes.filter(function (y) { return y.id === String(x.r); })[0] || { id: String(x.r), name: String(x.r) }, kb = +x.kbps || 0;
          var bar = h('i');
          bar.style.width = (kb > 0 && max > 0 ? Math.max(2, Math.round(kb / max * 100)) : 0) + '%';
          box.appendChild(h('div', { class: 'spd-sp ' + (isDirect(rt) ? 'is-direct' : rt.role === 'pin' ? 'is-pin' : rt.role === 'auto' ? 'is-auto' : '') },
            h('span', { class: 'spd-sp-n' }, h('span', null, routeLabel(rt)), roleBadge(rt)), h('span', { class: 'spd-sp-b', 'aria-hidden': 'true' }, bar),
            h('span', { class: 'spd-sp-v' + (kb > 0 ? '' : ' bad-t') }, kb > 0 ? speedText(kb) : t('speed.dl.failed'))));
        });
        f.appendChild(box);
      });
      if (!f.querySelector('.spd-dl-k')) f.appendChild(h('p', { class: 'muted sm' }, t('speed.dl.waiting')));
      return f;
    });
  }
  function routeIndex(routes, id) {
    for (var i = 0; i < routes.length; i++) if (routes[i].id === String(id)) return i;
    return routes.length;
  }

  /* ---------- 详情弹窗 (点单元格 / 线路表头的「详情」): 所有测得的数字。弹窗打开时跟着测速进度刷新。 ---------- */
  function byId(list, id) { for (var i = 0; i < list.length; i++) if (String(list[i].id) === String(id)) return list[i]; return null; }
  function findCell(r, tid, rid) { var cs = arr(r.cells); for (var i = 0; i < cs.length; i++) if (cs[i] && String(cs[i].t) === String(tid) && String(cs[i].r) === String(rid)) return cs[i]; return null; }
  function stBadge(st) { var m = ST_BADGE[st] || ST_BADGE.pending; return ui.badge(t('speed.st.' + (ST_BADGE[st] ? st : 'pending')), m[0], m[1]); }
  function kvList(rows) {
    var dl = h('dl', { class: 'spd-kv2' });
    rows.forEach(function (r) { if (r) dl.appendChild(h('div', { class: 'spd-kv2-r' }, h('dt', null, r[0]), h('dd', null, r[1]))); });
    return dl;
  }
  /* 目标的网址 / 可接受的状态码: 管理列表里有 expect, 没读过管理列表时只有 plan 里的网址 */
  function targetInfo(id) { return byId(tg.list, id) || (plan.data ? byId(arr(plan.data.targets), id) : null); }
  function explainCell(st, c) {
    if (st === 'ok') return t('speed.dt.ex.ok');
    if (st === 'slow') return t('speed.dt.ex.slow');
    if (st === 'limited') return t('speed.dt.ex.limited', { http: c.http || DASH });
    if (st === 'fail') return t('speed.dt.ex.fail', { why: reasonText(c.err) });
    return t(st === 'skip' ? 'speed.dt.ex.skip' : 'speed.dt.ex.pending');
  }
  function openCell(tid, rid) {
    if (detail) return null;
    var box = h('div', { class: 'spd-dt' }), api, r0 = viewRes();
    var tgt0 = r0 && byId(targetsOf(r0), tid), rt0 = r0 && byId(routesOf(r0), rid);
    function render() {
      var r = viewRes(), tgt, rt, c, st, info;
      TP.clear(box);
      if (!r) { box.appendChild(h('p', { class: 'muted' }, t('speed.dt.gone'))); return; }
      tgt = byId(targetsOf(r), tid) || { id: tid, name: tid, group: 'other' }; rt = byId(routesOf(r), rid) || { id: rid, name: rid };
      c = findCell(r, tid, rid) || { st: 'pending' }; st = cellState(c); info = targetInfo(tid);
      api.setTitle(t('speed.dt.cellTitle', { site: String(tgt.name || tgt.id), route: routeLabel(rt) }));
      box.appendChild(h('div', { class: 'spd-dt-top' }, stBadge(st), (st === 'ok' || st === 'slow') && +c.ms > 0 ? h('span', { class: 'spd-dt-big' }, ms(c.ms)) : null));
      box.appendChild(h('p', { class: 'spd-dt-say' }, explainCell(st, c)));
      box.appendChild(kvList([
        [t('speed.dt.site'), h('span', null, String(tgt.name || tgt.id), h('span', { class: 'muted' }, ' · ' + groupName(tgt.group || 'other')))],
        info && info.url ? [t('speed.dt.url'), h('span', { class: 'mono' }, String(info.url))] : null,
        [t('speed.dt.route'), h('span', null, routeLabel(rt), roleBadge(rt))],
        [t('speed.dt.latency'), msOr(c.ms)], [t('speed.dt.connect'), msOr(c.connect)], [t('speed.dt.ttfb'), msOr(c.ttfb)],
        [t('speed.dt.http'), c.http ? String(c.http) : DASH],
        info && info.expect ? [t('speed.dt.expect'), h('span', { class: 'mono' }, info.expect)] : null,
        [t('speed.dt.error'), c.err ? reasonNode(c.err) : DASH]
      ]));
    }
    api = ui.modal({
      title: t('speed.dt.cellTitle', { site: tgt0 ? String(tgt0.name || tgt0.id) : tid, route: rt0 ? routeLabel(rt0) : rid }), icon: 'activity', iconKind: 'info', size: 'sm', body: box,
      actions: [{ label: L('common.close'), kind: 'primary', cancel: true, autofocus: true }],
      onClose: function () { detail = null; }
    });
    detail = { update: render, page: render };
    render();
    if (tg.st !== 'ok') loadTargets();                    // 没读过管理列表就顺便读一次, 为了显示「可接受的状态码」
    return api;
  }
  function openRoute(rid) {
    if (detail) return null;
    var f = 'all', api, top = h('div', { class: 'spd-dt-top' }), note = h('p', { class: 'muted sm spd-dt-n' }), dls = h('div', { class: 'spd-dt-dl muted sm' });
    var chips = h('div', { class: 'chips', role: 'group', 'aria-label': L('speed.dt.filter') }), wrap = h('div', { class: 'tbl-wrap' }), empty = ui.emptyBox(), cb = {};
    ['all', 'issues'].forEach(function (k) {
      var b = h('button', { class: 'fchip', type: 'button', 'aria-pressed': 'false' }, h('span', null, L('speed.dt.f.' + k)), h('span', { class: 'fchip-n' }));
      b._n = b.lastChild; cb[k] = b;
      b.addEventListener('click', function () { if (f !== k) { f = k; draw(true); } });
      chips.appendChild(b);
    });
    if (!pgR) { pgR = ui.pager('speed.route', { def: 10 }); pgR.onChange(function () { if (detail && detail.page) detail.page(); }); }   // i18n-ignore
    var box = h('div', { class: 'spd-dt' }, top, dls, note, chips, wrap, empty.el, pgR.el);
    function head() {
      return h('tr', null, ['speed.dt.col.site', 'speed.dt.col.result', 'speed.dt.col.latency', 'speed.dt.col.connect', 'speed.dt.col.ttfb', 'speed.dt.col.http', 'speed.dt.col.error'].map(function (k, i) { return h('th', { class: i >= 2 && i <= 5 ? 'num' : '' }, t(k)); }));
    }
    function draw(first) {
      var r = viewRes(), rt, rows = [], issues, list, pg, cm = Object.create(null), skipped = 0, s, sp, tb;
      if (!r) { TP.clear(top); TP.clear(wrap); setText(note, t('speed.dt.gone')); pgR.update(0); return; }
      rt = byId(routesOf(r), rid) || { id: rid, name: rid };
      api.setTitle(t('speed.dt.routeTitle', { name: routeLabel(rt) }));
      arr(r.cells).forEach(function (c) { if (c && String(c.r) === String(rid)) cm[String(c.t)] = c; });
      flatTargets(targetsOf(r)).forEach(function (x) {
        var c = cm[x.id] || { st: 'pending' }, st = cellState(c);
        if (st === 'skip') skipped++; else rows.push({ tg: x, c: c, st: st });
      });
      issues = rows.filter(function (x) { return x.st === 'slow' || x.st === 'limited' || x.st === 'fail'; });
      list = f === 'issues' ? issues : rows;
      cb.all._n.textContent = String(rows.length); cb.issues._n.textContent = String(issues.length);
      cb.all.setAttribute('aria-pressed', f === 'all' ? 'true' : 'false'); cb.issues.setAttribute('aria-pressed', f === 'issues' ? 'true' : 'false');
      s = routeStats(r, rid);
      TP.clear(top);
      top.appendChild(h('b', null, routeLabel(rt))); if (roleBadge(rt)) top.appendChild(roleBadge(rt));
      if (bestOf(r, routesOf(r)) === String(rid)) top.appendChild(ui.badge(t('speed.best'), 'info', 'success'));
      top.appendChild(h('span', { class: 'chip' }, s.avg > 0 ? t('speed.mx.avg', { ms: ms(s.avg) }) : DASH));
      top.appendChild(h('span', { class: 'chip' + (s.total > 0 && s.ok === s.total ? ' ok' : s.total > 0 && s.ok === 0 ? ' bad' : s.total > 0 ? ' warn' : '') }, s.total > 0 ? t('speed.mx.okTotal', { ok: fmt.num(s.ok), total: fmt.num(s.total) }) : DASH));
      sp = arr(r.speeds).filter(function (x) { return x && String(x.r) === String(rid); });
      TP.clear(dls);
      if (sp.length) sp.forEach(function (x) { dls.appendChild(h('span', { class: 'spd-dt-sp' }, t('speed.dl.' + (x.kind === 'cn' ? 'cn' : 'global')) + ': ', h('b', { class: +x.kbps > 0 ? '' : 'bad-t' }, +x.kbps > 0 ? speedText(x.kbps) : t('speed.dl.failed')))); });
      dls.hidden = !sp.length;
      setText(note, skipped ? t('speed.dt.skipped', { n: skipped }) : ''); note.hidden = !skipped;
      pg = pgR.update(list.length);
      if (first && pg.page !== 1) { pgR.setPage(1); return; }          // 翻页后 onChange 会再调用一次 draw
      tb = h('tbody', null, list.slice(pg.start, pg.end).map(function (x) {
        var c = x.c, info = targetInfo(x.tg.id);
        return h('tr', null,
          h('td', { class: 'c-name', 'data-l': '' }, h('b', null, String(x.tg.name || x.tg.id)), h('div', { class: 'muted sm' }, groupName(x.tg.group || 'other'))),
          h('td', { 'data-l': t('speed.dt.col.result') }, stBadge(x.st)),
          h('td', { class: 'num', 'data-l': t('speed.dt.col.latency') }, msOr(c.ms)), h('td', { class: 'num', 'data-l': t('speed.dt.col.connect') }, msOr(c.connect)),
          h('td', { class: 'num', 'data-l': t('speed.dt.col.ttfb') }, msOr(c.ttfb)), h('td', { class: 'num', 'data-l': t('speed.dt.col.http') }, c.http ? String(c.http) : DASH),
          h('td', { 'data-l': t('speed.dt.col.error') }, c.err ? reasonNode(c.err) : (info && x.st === 'limited' && info.expect ? h('span', { class: 'muted' }, t('speed.dt.expectShort', { codes: info.expect })) : DASH)));
      }));
      TP.clear(wrap);
      wrap.appendChild(h('table', { class: 'tbl rt spd-rtbl' }, h('caption', { class: 'spd-sr' }, t('speed.dt.routeCaption', { name: routeLabel(rt) })), h('thead', null, head()), tb));
      wrap.hidden = !list.length;
      if (!list.length) empty.show({ icon: f === 'issues' ? 'success' : 'info', text: t(f === 'issues' ? 'speed.dt.noIssues' : 'speed.dt.noRows') }); else empty.hide();
    }
    api = ui.modal({
      title: t('speed.dt.routeTitle', { name: rid }), icon: 'list-checks', iconKind: 'info', size: 'lg', body: box,
      actions: [{ label: L('common.close'), kind: 'primary', cancel: true, autofocus: true }],
      onClose: function () { detail = null; }
    });
    detail = { update: function () { draw(false); }, page: function () { draw(false); } };
    draw(true);
    if (tg.st !== 'ok') loadTargets();
    return api;
  }

  /* ================= D) 管理测速目标 (弹窗) ================= */
  /* 改动目标暂时不能做的原因 (空 = 可以): 辅助服务不可用, 或测速正在进行 */
  function mgrWhy() { return TP.why.helper() || (run.id ? t('speed.tg.busy') : ''); }
  function normTarget(x) {
    return { id: String(x.id), group: x.group ? String(x.group) : 'other', name: String(x.name || x.id), url: String(x.url || ''), expect: expectStr(x.expect), icon: x.icon ? String(x.icon) : '',
      builtin: x.builtin === true, modified: x.modified === true, hidden: x.hidden === true, default: x.default === true };
  }
  async function loadTargets(force) {
    if (S.locked || (tg.busy && !force)) return;
    var my = ++tg.seq;
    tg.busy = true;
    if (tg.st !== 'ok') { tg.st = 'loading'; if (mg) renderMgr(); }
    try {
      var r = await TP.helper('GET', '/api/speedtest/targets', { timeout: 20000 });
      if (my === tg.seq) { tg.list = arr(r && r.targets).filter(function (x) { return x && x.id != null; }).map(normTarget); tg.st = 'ok'; tg.err = null; tg.warn = null; }
    } catch (e) {
      if (my === tg.seq) {
        if (e && e.kind === 'auth') { if (tg.st === 'loading') tg.st = 'idle'; }
        else if (tg.list.length) { tg.st = 'ok'; tg.warn = e; }          // 有旧数据: 继续显示, 另加一行提示
        else { tg.st = 'err'; tg.err = e; }
      }
    }
    if (my === tg.seq) { tg.busy = false; if (mg) renderMgr(); if (detail) detail.update(); }
  }
  /* 任何改动之后: 重新读取目标列表和 plan (页面上的选择器和已保存的选择都按它更新); 用户刚添加 / 恢复的目标顺手勾选上 */
  async function changed(opt) {
    await Promise.all([loadTargets(true), loadPlan(true)]);
    if (opt && opt.select && plan.data && byId(arr(plan.data.targets), opt.select)) { sel.targets[opt.select] = true; saveTargets(); renderTest(); }
  }
  function tgCounts() {
    var c = { all: 0, builtin: 0, custom: 0, modified: 0, hidden: 0 };
    tg.list.forEach(function (x) { if (x.hidden) { c.hidden++; return; } c.all++; if (x.builtin) c.builtin++; else c.custom++; if (x.modified) c.modified++; });
    return c;
  }
  function tgBlob(x) {
    if (!x._b || x._bl !== I.lang) { x._bl = I.lang; x._b = [x.id, x.name, x.url, x.expect, groupName(x.group)].join(' ').toLowerCase(); }
    return x._b;
  }
  /* 已隐藏的目标只出现在「已隐藏」筛选里 (从其它筛选里「移走」了) */
  function tgMatch(x) {
    var f = mg.flt;
    if (f === 'hidden' ? !x.hidden : x.hidden) return false;
    if (f === 'builtin' ? !x.builtin : f === 'custom' ? x.builtin : f === 'modified' ? !x.modified : false) return false;
    return !mg.q || tgBlob(x).indexOf(mg.q) >= 0;
  }
  function tgBadges(x) {
    var b = [x.builtin ? ui.badge(t('speed.tg.b.builtin'), 'info') : ui.badge(t('speed.tg.b.custom'), 'ok')];
    if (x.modified) b.push(ui.badge(t('speed.tg.b.modified'), 'warn'));
    if (x.hidden) b.push(ui.badge(t('speed.tg.b.hidden'), 'neutral'));
    return b;
  }

  function openManage() {
    if (mg) return null;
    var why = mgrWhy();
    if (why) { ui.toast(why, 'warn'); return null; }
    mg = { q: '', flt: 'all', api: null, el: {} };
    if (!pgT) { pgT = ui.pager('speed.targets', { def: 10 }); pgT.onChange(function () { if (mg) renderList(); }); }   // i18n-ignore
    pgT.update(0);
    mg.api = ui.modal({
      title: L('speed.tg.title'), icon: 'list-checks', iconKind: 'pri', size: 'lg', cls: 'spd-mgdlg',
      body: buildMgr,
      actions: [
        { label: L('speed.tg.reset'), kind: 'danger', icon: 'restart', id: 'reset', keep: true, onClick: function () { return resetAll(); } },
        { label: L('common.close'), kind: 'primary', cancel: true }
      ],
      onClose: function () { mg = null; }
    });
    var rb = mg.api.getBtn('reset');
    if (rb) rb.parentNode.insertBefore(ui.help('speed.reset', { cls: 'spd-tg-rhelp' }), rb.nextSibling);      // 「!」说明紧跟在「全部还原」后面, 并把这一组推到左边
    renderMgr();
    loadTargets(true);
    return mg.api;
  }
  function buildMgr() {
    var e = mg.el, fine = window.matchMedia && window.matchMedia('(pointer:fine)').matches;
    e.q = h('input', { class: 'inp', type: 'search', placeholder: L('speed.tg.search'), 'aria-label': L('speed.tg.search'), autocomplete: 'off', spellcheck: 'false',
      on: { input: function () { mg.q = e.q.value.trim().toLowerCase(); applyFilter(); } } });
    e.add = ui.btn(L('speed.tg.add'), { kind: 'primary', icon: 'plus' });
    ui.act(e.add, function () { return openForm(null); });
    e.chips = h('div', { class: 'spd-mg-chips', role: 'group', 'aria-label': L('speed.tg.filter') }); e.chip = {}; e.chipN = {};
    FLT.forEach(function (k) {
      var n = h('span', { class: 'fchip-n' }), b = h('button', { class: 'fchip', type: 'button', 'aria-pressed': 'false' }, h('span', null, L('speed.tg.flt.' + k)), n);
      b.addEventListener('click', function () { if (mg.flt !== k) { mg.flt = k; applyFilter(); } });
      e.chip[k] = b; e.chipN[k] = n; e.chips.appendChild(b);
      if (k === 'hidden') e.chips.appendChild(ui.help('speed.hidden'));
    });
    (fine ? e.q : e.chip.all).setAttribute('data-autofocus', '');            // 触屏上不自动聚焦搜索框 (会弹出软键盘)
    e.note = h('p', { class: 'hint warn', hidden: true });
    e.warn = h('p', { class: 'hint bad', hidden: true }, L('speed.tg.staleWarn'));
    e.list = h('div', { class: 'spd-mg-list' });
    e.empty = ui.emptyBox();
    return h('div', { class: 'spd-mg' }, h('div', { class: 'spd-mg-bar' }, e.q, e.add), e.chips, e.note, e.warn, e.list, e.empty.el, pgT.el);
  }
  function applyFilter() {                                                    // 搜索词 / 筛选变了: 回到第一页
    if (!mg) return;
    pgT.update(flatTargets(tg.list.filter(tgMatch)).length);
    pgT.setPage(1);
    renderMgr();
  }
  function renderMgr() {
    if (!mg || !mg.el.list) return;
    var e = mg.el, c = tgCounts(), why = mgrWhy(), nothing = !(c.custom || c.hidden || c.modified), rb = mg.api && mg.api.getBtn('reset');
    FLT.forEach(function (k) { setText(e.chipN[k], String(c[k])); e.chip[k].setAttribute('aria-pressed', mg.flt === k ? 'true' : 'false'); });
    e.note.hidden = !why; setText(e.note, why);
    e.warn.hidden = !tg.warn;
    ui.avail(e.add, why);
    if (rb) ui.avail(rb, why || (tg.st !== 'ok' ? t('speed.tg.loading') : nothing ? t('speed.tg.reset.nothing') : ''));
    renderList();
  }
  function renderList() {
    var e = mg.el, list, r, items = [], counts = Object.create(null), lastG = null;
    if (tg.st !== 'ok') {
      pgT.update(0); ui.syncList(e.list, [], function (it) { return it.k; }, makeMgRow, updateMgRow);
      if (tg.st === 'err') e.empty.show({ icon: 'wifi-off', text: t('speed.tg.loadFailed'), hint: TP.errMsg(tg.err), action: { label: t('common.retry'), icon: 'refresh', fn: function () { return loadTargets(true); } } });
      else e.empty.show({ icon: 'refresh', text: t('common.loading') });
      return;
    }
    list = flatTargets(tg.list.filter(tgMatch));
    r = pgT.update(list.length);
    list.forEach(function (x) { counts[x.group] = (counts[x.group] || 0) + 1; });
    list.slice(r.start, r.end).forEach(function (x) {                         // 标题行和目标行在同一个列表里 (按 key 复用, 操作后焦点不丢)
      if (x.group !== lastG) { lastG = x.group; items.push({ k: 'h:' + x.group, head: x.group, n: counts[x.group] }); }
      items.push({ k: 't:' + x.id, tg: x });
    });
    ui.syncList(e.list, items, function (it) { return it.k; }, makeMgRow, updateMgRow);
    if (list.length) { e.empty.hide(); return; }
    if (mg.q) e.empty.show({ icon: 'search', text: t('speed.tg.noMatch'), hint: t('speed.tg.noMatchHint') });
    else if (mg.flt === 'hidden') e.empty.show({ icon: 'eye-off', text: t('speed.tg.noHidden'), hint: t('speed.tg.noHiddenHint') });
    else if (mg.flt === 'custom') e.empty.show({ icon: 'plus', text: t('speed.tg.noCustom'), hint: t('speed.tg.noCustomHint'), action: { label: t('speed.tg.add'), icon: 'plus', fn: function () { return openForm(null); } } });
    else if (mg.flt === 'modified') e.empty.show({ icon: 'edit', text: t('speed.tg.noModified'), hint: t('speed.tg.noModifiedHint') });
    else if (tgCounts().hidden) e.empty.show({ icon: 'eye-off', text: t('speed.tg.allHidden'), hint: t('speed.tg.allHiddenHint'), action: { label: t('speed.tg.showHidden'), icon: 'eye', fn: function () { mg.flt = 'hidden'; applyFilter(); } } });
    else e.empty.show({ icon: 'info', text: t('speed.tg.noTargets') });
  }
  function makeMgRow(it) {
    var row, r = {};
    if (it.head) {
      row = h('h4', { class: 'spd-mg-gh' }, h('span', { class: 'spd-tg-ic' }), h('span'), h('span', { class: 'chip' }));
      row._head = true; row._ic = row.children[0]; row._nm = row.children[1]; row._n = row.children[2];
      return row;
    }
    row = h('div', { class: 'spd-mg-row', role: 'group' });
    r.ic = h('span', { class: 'spd-mg-ic' }); r.name = h('b', { class: 'spd-mg-name' }); r.badges = h('span', { class: 'badges' });
    r.url = h('div', { class: 'spd-mg-url mono' }); r.meta = h('div', { class: 'spd-mg-meta muted sm' });
    r.edit = ui.btn(L('speed.tg.edit'), { sm: true, icon: 'edit' });
    r.revert = ui.btn(L('speed.tg.revert'), { sm: true, kind: 'ghost', icon: 'rotate-ccw', cls: 'spd-link-ok' });
    r.hide = ui.btn(L('speed.tg.hide'), { sm: true, kind: 'ghost', icon: 'eye-off' });
    r.del = ui.btn(L('speed.tg.delete'), { sm: true, kind: 'ghost', icon: 'delete', cls: 'danger-t' });
    r.show = ui.btn(L('speed.tg.restore'), { sm: true, kind: 'ghost', icon: 'rotate-ccw', cls: 'spd-link-ok' });
    ui.act(r.edit, function () { return openForm(row._tg); });
    ui.act(r.revert, function () { return restoreTarget(row._tg); });
    ui.act(r.show, function () { return restoreTarget(row._tg); });
    ui.act(r.hide, function () { return deleteTarget(row._tg); });
    ui.act(r.del, function () { return deleteTarget(row._tg); });
    row.appendChild(r.ic);
    row.appendChild(h('div', { class: 'spd-mg-main' }, h('div', { class: 'spd-mg-t' }, r.name, r.badges), r.url, r.meta));
    row.appendChild(h('div', { class: 'spd-mg-acts' }, r.edit, r.revert, r.hide, r.del, r.show));
    row._r = r;
    return row;
  }
  function updateMgRow(row, it) {
    var why = mgrWhy(), x, r, ic, sig;
    if (it.head) {
      if (!row._icSet) { row._icSet = true; row._ic.appendChild(ui.icon(groupIcon(it.head), 16)); }
      setText(row._nm, groupName(it.head)); setText(row._n, t('speed.tg.groupN', { n: it.n }));
      return;
    }
    x = it.tg; r = row._r; row._tg = x;
    ic = targetIcon(x);
    if (r.icn !== ic) { r.icn = ic; TP.clear(r.ic); r.ic.appendChild(ui.icon(ic, 18)); }
    setText(r.name, x.name);
    sig = I.lang + [x.builtin, x.modified, x.hidden].join('|');
    if (r.sig !== sig) { r.sig = sig; TP.clear(r.badges); tgBadges(x).forEach(function (b) { r.badges.appendChild(b); }); }
    setText(r.url, x.url || DASH);
    setText(r.meta, x.expect ? t('speed.tg.meta', { codes: x.expect }) : '');
    row.setAttribute('aria-label', x.name); row.classList.toggle('is-hidden', x.hidden);
    r.edit.hidden = x.hidden; r.revert.hidden = x.hidden || !(x.builtin && x.modified); r.hide.hidden = x.hidden || !x.builtin; r.del.hidden = x.hidden || x.builtin; r.show.hidden = !x.hidden;
    r.edit.setAttribute('aria-label', t('speed.tg.editAria', { name: x.name })); r.revert.setAttribute('aria-label', t('speed.tg.revertAria', { name: x.name }));
    r.hide.setAttribute('aria-label', t('speed.tg.hideAria', { name: x.name })); r.del.setAttribute('aria-label', t('speed.tg.deleteAria', { name: x.name })); r.show.setAttribute('aria-label', t('speed.tg.restoreAria', { name: x.name }));
    [r.edit, r.revert, r.hide, r.del, r.show].forEach(function (b) { ui.avail(b, why); });
  }

  async function postTarget(path, form) {
    try { return await TP.helper('POST', '/api/speedtest/targets' + path, form ? { form: form } : {}); }
    catch (e) { if (e && e.code === 'E_NOT_FOUND') await changed(null); throw e; }          // 这个目标已经在别处被删掉了: 重新读取列表, 再把错误告诉用户
  }
  /* 删除: 内置 = 隐藏 (可在「已隐藏」里恢复); 自定义 = 永久删除 (红色确认) */
  async function deleteTarget(x) {
    var why = mgrWhy(), custom = !x.builtin;
    if (why) { ui.toast(why, 'warn'); return; }
    var ok = await ui.confirmDialog({
      title: t(custom ? 'speed.tg.del.titleC' : 'speed.tg.del.titleB'), message: t(custom ? 'speed.tg.del.msgC' : 'speed.tg.del.msgB', { name: x.name }),
      detail: custom ? [x.url, t('speed.tg.del.dC')] : [t('speed.tg.del.dB')],
      confirmText: t(custom ? 'speed.tg.del.goC' : 'speed.tg.del.goB'), confirmIcon: custom ? 'delete' : 'eye-off', danger: custom, kind: custom ? 'primary' : 'warning'
    });
    if (!ok) return;
    await postTarget('/delete', { id: x.id });
    ui.toast(t(custom ? 'speed.tg.deleted' : 'speed.tg.hidden', { name: x.name }), 'ok');
    await changed(null);
  }
  /* 恢复: 已隐藏的 -> 重新显示 (同时撤销对它的修改); 只是修改过的 -> 还原成内置设置 */
  async function restoreTarget(x) {
    var why = mgrWhy();
    if (why) { ui.toast(why, 'warn'); return; }
    var ok = await ui.confirmDialog({
      title: t(x.hidden ? 'speed.tg.rs.titleH' : 'speed.tg.rs.titleM'), message: t(x.hidden ? 'speed.tg.rs.msgH' : 'speed.tg.rs.msgM', { name: x.name }),
      detail: x.hidden && x.modified ? t('speed.tg.rs.dBoth') : '',
      confirmText: t(x.hidden ? 'speed.tg.rs.goH' : 'speed.tg.rs.goM'), confirmIcon: 'rotate-ccw', kind: x.hidden ? 'success' : 'warning'
    });
    if (!ok) return;
    await postTarget('/restore', { id: x.id });
    ui.toast(t(x.hidden ? 'speed.tg.restoredH' : 'speed.tg.restoredM', { name: x.name }), 'ok');
    await changed(x.hidden && x.default ? { select: x.id } : null);
  }
  /* 全部还原: 清除全部自定义 / 隐藏 / 修改, 回到内置默认 (红色, 说明各有几项) */
  async function resetAll() {
    var why = mgrWhy();
    if (why) { ui.toast(why, 'warn'); return; }
    var nC = tg.list.filter(function (x) { return !x.builtin; }).length, nH = tg.list.filter(function (x) { return x.hidden; }).length, nM = tg.list.filter(function (x) { return x.builtin && x.modified; }).length;
    var ok = await ui.confirmDialog({
      title: t('speed.tg.reset.title'), message: t('speed.tg.reset.msg'),
      detail: [nC ? t('speed.tg.reset.dC', { n: nC }) : '', nH ? t('speed.tg.reset.dH', { n: nH }) : '', nM ? t('speed.tg.reset.dM', { n: nM }) : ''].filter(Boolean),
      confirmText: t('speed.tg.reset.go'), confirmIcon: 'restart', danger: true
    });
    if (!ok) return;
    await postTarget('/reset');
    ui.toast(t('speed.tg.reset.done'), 'ok');
    if (mg) { mg.flt = 'all'; mg.q = ''; if (mg.el.q) mg.el.q.value = ''; pgT.setPage(1); }
    await changed(null);
  }

  /* ---------- 添加 / 编辑 (嵌套弹窗) ---------- */
  var formSeq = 0;
  function vName(v) { v = v.trim(); return !v ? 'nameEmpty' : Array.from(v).length > 40 ? 'nameLong' : /[|\\<>"\u0000-\u001f]/.test(v) ? 'nameChars' : ''; }
  function vUrl(v) {
    v = v.trim();
    if (!v) return 'urlEmpty';
    if (v.length > 300) return 'urlLong';
    if (/\s/.test(v)) return 'urlSpace';
    if (/["'`]/.test(v)) return 'urlQuote';
    if (/[<>\\|]/.test(v)) return 'urlChars';
    if (!/^https?:\/\//i.test(v)) return 'urlScheme';
    var u = null;
    try { u = new URL(v); } catch (e) { return 'urlHost'; }
    return !u.hostname ? 'urlHost' : (u.username || u.password) ? 'urlUser' : '';
  }
  /* 状态码: 逗号分隔, 每个 100–599, 至少一个; 返回 {err, value (去重后规范化)} */
  function vExpect(v) {
    var parts = v.split(',').map(function (x) { return x.trim(); }).filter(Boolean), seen = Object.create(null), out = [], i;
    if (!parts.length) return { err: 'expectEmpty' };
    for (i = 0; i < parts.length; i++) {
      if (!/^[1-5]\d\d$/.test(parts[i])) return { err: 'expectBad' };
      if (!seen[parts[i]]) { seen[parts[i]] = 1; out.push(parts[i]); }
    }
    return out.length > 12 ? { err: 'expectMany' } : { err: '', value: out.join(',') };
  }
  function iconPicker(f, nm) {
    var box = h('div', { class: 'spd-icons', role: 'radiogroup', 'aria-label': L('speed.tg.f.icon') }), inputs = {};
    function opt(val) {
      var key = val ? 'speed.tg.icon.' + val : 'speed.tg.icon.none';
      var inp = h('input', { type: 'radio', name: nm, value: val, 'aria-label': L(key) });
      inputs[val] = inp;
      inp.addEventListener('change', function () { if (inp.checked) f.icon = val; });
      return h('label', { class: 'spd-ico', title: L(key) }, inp, h('span', null, val ? ui.icon(val, 18) : h('span', { class: 'spd-ico-n' }, L('speed.tg.icon.auto'))));
    }
    box.appendChild(opt(''));
    ICONS.filter(function (n) { return window.Icons && window.Icons.has(n); }).forEach(function (n) { box.appendChild(opt(n)); });
    if (own(inputs, f.icon)) inputs[f.icon].checked = true;
    return box;
  }
  function openForm(x) {
    if (!mg) return null;
    var edit = !!x, uid = 'spd-f' + (++formSeq), api, form, shown = Object.create(null);
    var init = edit ? { name: x.name, group: x.group, url: x.url, expect: x.expect || EXPECT_DEF, icon: x.icon } : { name: '', group: 'global', url: '', expect: EXPECT_DEF, icon: '' }, f = { icon: init.icon };
    var gs = GROUPS.slice(); if (init.group && gs.indexOf(init.group) < 0) gs.push(init.group);
    var name = h('input', { class: 'inp', type: 'text', id: uid + 'n', maxlength: 40, autocomplete: 'off', spellcheck: 'false', 'aria-describedby': uid + 'nm', value: init.name });
    var group = h('select', { class: 'sel', id: uid + 'g' }, gs.map(function (g) { return TP.opt(g, groupName(g)); }));
    var url = h('input', { class: 'inp mono', type: 'text', id: uid + 'u', inputmode: 'url', autocapitalize: 'off', autocomplete: 'off', spellcheck: 'false', placeholder: L('speed.tg.f.urlPh'), 'aria-describedby': uid + 'um', value: init.url });
    var expect = h('input', { class: 'inp mono', type: 'text', id: uid + 'e', autocomplete: 'off', spellcheck: 'false', placeholder: EXPECT_DEF, 'aria-describedby': uid + 'em', value: init.expect });
    var nameM = h('div', { class: 'fld-h', id: uid + 'nm', 'aria-live': 'polite' }), urlM = h('div', { class: 'fld-h', id: uid + 'um', 'aria-live': 'polite' }), expM = h('div', { class: 'fld-h', id: uid + 'em', 'aria-live': 'polite' });
    var err = h('div', { class: 'hint bad', role: 'alert', hidden: true });
    group.value = init.group;
    function paint(k, inp, msg, code, hintKey) {                      // 出错 (用户动过这个字段后才显示) -> 红色说明; 否则是灰色提示
      var bad = !!code && !!shown[k];
      msg.className = 'fld-h' + (bad ? ' bad-t' : ''); setText(msg, t(bad ? 'speed.tg.err.' + code : hintKey));
      if (bad) inp.setAttribute('aria-invalid', 'true'); else inp.removeAttribute('aria-invalid');
    }
    function check(all) {
      if (all) { shown.name = shown.url = shown.expect = true; }
      var en = vName(name.value), eu = vUrl(url.value), ee = vExpect(expect.value).err;
      paint('name', name, nameM, en, 'speed.tg.f.nameHint'); paint('url', url, urlM, eu, 'speed.tg.f.urlHint'); paint('expect', expect, expM, ee, 'speed.tg.f.expectHint');
      return en ? name : eu ? url : ee ? expect : null;
    }
    [['name', name], ['url', url], ['expect', expect]].forEach(function (p) {
      p[1].addEventListener('input', function () { err.hidden = true; if (p[1].value.trim()) shown[p[0]] = true; check(false); });
      p[1].addEventListener('blur', function () { shown[p[0]] = true; check(false); });
    });
    group.addEventListener('change', function () { err.hidden = true; });
    check(false);
    form = h('form', { class: 'spd-tf', novalidate: true },
      edit && x.builtin ? h('p', { class: 'hint' }, t('speed.tg.f.builtinNote')) : null,
      h('div', { class: 'fld' }, h('label', { class: 'fld-l', for: uid + 'n' }, t('speed.tg.f.name')), name, nameM),
      h('div', { class: 'fld' }, h('label', { class: 'fld-l', for: uid + 'g' }, t('speed.tg.f.group')), group),
      h('div', { class: 'fld' }, h('label', { class: 'fld-l', for: uid + 'u' }, t('speed.tg.f.url')), url, urlM),
      h('div', { class: 'fld' }, h('span', { class: 'fld-l spd-fl' }, h('label', { for: uid + 'e' }, t('speed.tg.f.expect')), ui.help('speed.expect')), expect, expM),
      h('div', { class: 'fld' }, h('span', { class: 'fld-l' }, t('speed.tg.f.icon')), iconPicker(f, uid + 'i'),
        init.icon && ICONS.indexOf(init.icon) < 0 ? h('span', { class: 'fld-h' }, t('speed.tg.f.iconKeep', { name: init.icon })) : null),
      err);
    api = ui.modal({
      title: t(edit ? 'speed.tg.form.edit' : 'speed.tg.form.add'), icon: edit ? 'edit' : 'plus', iconKind: 'pri', size: 'md', body: form,
      dirty: function () { return name.value !== init.name || group.value !== init.group || url.value !== init.url || expect.value !== init.expect || f.icon !== init.icon; },
      actions: [
        { label: t('common.cancel'), cancel: true },
        { label: t(edit ? 'common.save' : 'speed.tg.add'), kind: 'primary', icon: 'check', id: 'go', onClick: function () { return saveForm(); } }
      ]
    });
    function submit() { var b = api.getBtn('go'); if (b) b.click(); }
    form.addEventListener('submit', function (ev) { ev.preventDefault(); submit(); });
    form.addEventListener('keydown', function (ev) {                    // 表单里有好几个文本框又没有提交按钮 (保存在弹窗底栏): 浏览器不会因回车自动提交, 这里自己处理
      if (ev.key === 'Enter' && ev.target && ev.target.type === 'text' && !ev.isComposing && ev.keyCode !== 229) { ev.preventDefault(); submit(); }       // 输入法选字时的回车不算 (Safari 的 keyCode 229)
    });
    async function saveForm() {
      var bad = check(true), why = mgrWhy(), r, v;
      if (bad) { bad.focus(); return false; }
      if (why) { ui.toast(why, 'warn'); return false; }
      v = { name: name.value.trim(), group: group.value, url: url.value.trim(), expect: vExpect(expect.value).value };
      err.hidden = true;
      try { r = await TP.helper('POST', '/api/speedtest/targets', { form: { id: edit ? x.id : '', name: v.name, group: v.group, url: v.url, expect: v.expect, icon: f.icon } }); }
      catch (e) {
        if (e && e.code === 'E_INVALID') { setText(err, e.message || TP.errMsg(e)); err.hidden = false; return false; }      // 后端的 E_INVALID 原因直接显示在表单里
        throw e;
      }
      ui.toast(t(edit ? 'speed.tg.saved' : 'speed.tg.added', { name: v.name }), 'ok');
      await changed(!edit && r && r.id != null ? { select: String(r.id) } : null);
    }
    return api;
  }
})();
