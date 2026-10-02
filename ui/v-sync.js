/* enana · v-sync.js — 云端同步 (端到端加密): 设置页的「云端同步」卡片 + 新电脑登录后的「检测到云端配置」提示
 *
 *   TP.sync.settingsCard()    -> 自更新的 <section class="card"> (设置页嵌入一次; card._reload() 立即重新读取)
 *   TP.sync.offerAfterLogin() -> 每次登录成功且 S.state 已加载后调用: 本机没有服务器、云端有配置、同步还没开、用户没拒绝过 -> 弹一次窗问是否一键同步
 *
 * 接口 (docs/API.md「云端同步」):
 *   GET  /api/sync            -> {enabled, auto, account, remote:{exists,version,updated,size,device}, local:{version,dirty}, last_pull, last_push, online}
 *   POST /api/sync/settings   表单 enabled=0|1 auto=0|1
 *   POST /api/sync/push       -> {job}; E_SYNC_CONFLICT = 云端比本机新。表单 force=1 = 用本机覆盖云端 (提议新增, API.md 里还没有)
 *   POST /api/sync/pull       表单 mode=replace|merge [old_password] -> {job}; E_SYNC_KEY = 要输入旧密码 (只放内存, 用完立刻清掉, 从不保存或写日志)
 *   POST /api/sync/clear      -> {ok}
 * 错误码可能出现在两处: POST 本身 (e.code) 或失败的任务 (e.data.code / e.data.result.code) —— codeOf() 两处都看。
 * 约定: 来自网络的字符串 (设备名 / 邮箱) 一律只用 textContent; 不用 disabled, 暂时不能用的控件用 ui.avail 说明原因; 每个会改动数据的操作先确认。
 * 状态是模块级单例 (D): 卡片、恢复弹窗、冲突弹窗、新电脑提示共用同一份, 任何动作之后都重新读取。 */
(function () {
  'use strict';
  var TP = window.TP, S = TP.S, h = TP.h, ui = TP.ui, fmt = TP.fmt, setText = TP.setText, I = window.I18N, t = I.t, L = I.L;
  var SY = TP.sync = {};

  var D = null;                     // 最近一次成功读取的同步状态 (GET /api/sync, 已整理)
  var loadErr = null;               // 最近一次读取失败的错误 (读取成功后清空)
  var loading = false, loadedAt = 0, seq = 0, inflight = null;
  var busy = '';                    // 正在进行的动作: '' | 'save' | 'push' | 'pull' | 'clear' (同一时间只允许一个)
  var pend = null;                  // 开关请求进行中: 界面上先显示「想要的值」{enabled, auto}
  var cards = [], modals = [], uid = 0, offerRun = false, offered = {};

  /* 「这台电脑 vs 云端」的关系 -> 芯片 */
  var REL = {
    dirty: { key: 'sync.rel.dirty', kind: 'warn', icon: 'warning' },
    both: { key: 'sync.rel.both', kind: 'warn', icon: 'warning' },
    behind: { key: 'sync.rel.behind', kind: 'warn', icon: 'info' },
    offline: { key: 'sync.rel.offline', kind: '', icon: 'wifi-off' },
    none: { key: 'sync.rel.none', kind: '', icon: 'info' },
    ok: { key: 'sync.rel.ok', kind: 'ok', icon: 'success' }
  };

  /* ================= 小工具 ================= */
  function active() { return TP.tab === 'settings'; }
  function str(v) { return v == null ? '' : String(v); }
  function pos(v) { v = +v; return v > 0 ? v : 0; }
  function yes(v) { return v === true || v === 1 || v === '1' || v === 'true'; }

  /* 错误码: POST 直接返回的 (e.code) 或失败任务里的 (顶层 code / result.code) */
  function codeOf(e) {
    var d = e && e.data;
    return String((e && e.code) || (d && (d.code || (d.result && d.result.code))) || '');
  }
  /* 同上 TP.errMsg, 只是同步里「连不上 enana.cc」要说得贴切些 (error.E_ACCOUNT_UNREACHABLE 讲的是登录) */
  function errText(e) {
    var c = codeOf(e);
    if (c === 'E_ACCOUNT_UNREACHABLE') return t('sync.err.unreachable');
    if (c && I.has('error.' + c)) return t('error.' + c);
    return (e && e.message) || t('error.unknown');
  }
  function norm(r) {
    if (!r || typeof r !== 'object') return null;
    var rm = r.remote || {}, lc = r.local || {};
    return {
      enabled: yes(r.enabled), auto: yes(r.auto), decided: yes(r.decided), account: str(r.account), online: !(r.online === false || r.online === 0 || r.online === '0'),
      remote: { exists: yes(rm.exists), version: pos(rm.version), updated: pos(rm.updated), size: pos(rm.size), device: str(rm.device), servers: rm.servers == null || rm.servers === '' ? -1 : pos(rm.servers) },   // servers: 可选扩展, -1 = 不知道
      local: { version: pos(lc.version), dirty: yes(lc.dirty) },
      lastPull: pos(r.last_pull), lastPush: pos(r.last_push)
    };
  }
  function ver(n) { return n > 0 ? t('sync.ver', { n: fmt.num(n) }) : '—'; }
  function devName(rm) { return rm.device || t('sync.device.unknown'); }
  function brief(rm) { return t('sync.remote.brief', { ver: ver(rm.version), device: devName(rm), when: fmt.rel(rm.updated) }); }
  function relOf(d) {
    var behind = d.remote.exists && d.remote.version > d.local.version;
    if (d.local.dirty) return behind ? 'both' : 'dirty';
    if (!d.online) return 'offline';
    if (behind) return 'behind';
    return d.remote.exists ? 'ok' : 'none';
  }
  function setTime(dd, sec) {
    setText(dd, sec ? fmt.rel(sec) : t('time.never'));
    if (sec) dd.title = fmt.dateTime(sec); else dd.removeAttribute('title');
  }
  /* 开关上显示的值: 请求进行中先显示「想要的值」; 同步关着时自动同步一定是关的 */
  function shown() {
    var en = pend ? pend.enabled : !!(D && D.enabled), au = pend ? pend.auto : !!(D && D.auto);
    return { enabled: en, auto: en && au };
  }

  /* ================= 读取 (合并并发请求; 过期的响应丢弃) ================= */
  /* soft=true: 已有请求在进行 / 刚读过 (3 秒内) 就不重复读; 否则总是发新请求 */
  function load(soft) {
    if (S.locked) return Promise.resolve(D);
    if (soft && inflight) return inflight;
    if (soft && D && !loadErr && Date.now() - loadedAt < 3000) return Promise.resolve(D);
    var my = ++seq, p;
    loading = true; renderAll();
    p = TP.helper('GET', '/api/sync', { timeout: 25000 }).then(function (r) { return { r: r }; }, function (e) { return { e: e }; }).then(function (x) {
      var n = null;
      if (my !== seq) return D;                                                  // 已经有更新的请求 (或已退出登录)
      if (x.e) { if (x.e.kind !== 'auth') loadErr = x.e; }
      else if ((n = norm(x.r))) { D = n; loadErr = null; loadedAt = Date.now(); }
      else loadErr = TP.mkErr('http', t('error.generic'));
      loading = false; inflight = null; renderAll();
      return D;
    });
    inflight = p;
    return p;
  }

  /* ================= 「暂不可用」的原因: {reason, fix} | null ================= */
  function retryFix() { return { label: t('common.retry'), fn: TP.safe(function () { return load(); }) }; }
  function turnOnFix() { return { label: t('sync.fix.turnOn'), fn: TP.safe(function () { return setEnabled(true); }) }; }
  function baseWhy() {
    var why = TP.why.helper();
    if (why) return { reason: why };
    if (!D) return loadErr ? { reason: t('sync.why.loadFailed'), fix: retryFix() } : { reason: t('sync.why.loading') };
    if (busy) return { reason: t('sync.why.busy') };
    return null;
  }
  function pushWhy() {
    var w = baseWhy();
    if (w) return w;
    if (!D.enabled) return { reason: t('sync.why.off'), fix: turnOnFix() };
    if (!D.online) return { reason: t('sync.why.offline'), fix: retryFix() };
    if (!D.local.dirty && D.remote.exists) return { reason: t('sync.why.nothingToUpload') };
    return null;
  }
  function pullWhy() {
    var w = baseWhy();
    if (w) return w;
    if (!D.enabled) return { reason: t('sync.why.off'), fix: turnOnFix() };
    if (!D.online) return { reason: t('sync.why.offline'), fix: retryFix() };
    if (!D.remote.exists) return { reason: t('sync.why.noRemote'), fix: pushWhy() ? null : { label: t('sync.btn.push'), fn: TP.safe(doPush) } };
    return null;
  }
  function clearWhy() {
    var w = baseWhy();
    if (w) return w;
    if (!D.online) return { reason: t('sync.why.offline'), fix: retryFix() };
    if (!D.remote.exists) return { reason: t('sync.why.noRemoteClear') };
    return null;
  }
  function applyWhy(el, w) { ui.avail(el, w ? w.reason : '', w ? w.fix : null); }
  /* 动作开始时再检查一次: 不可用 -> 提示原因 (和点灰色按钮一样) 并返回 true */
  function guard(w) {
    if (!w) return false;
    ui.toast(w.reason, 'warn', 5200, w.fix ? { action: w.fix } : null);
    return true;
  }

  /* ================= 设置卡片 ================= */
  function makeCard() {
    var C = { id: 'syn' + (++uid), seen: false, sig: null }, id = C.id;
    function kv(dl, key) { var dd = h('dd'), row = h('div', { class: 'syn-kvr' }, h('dt', null, L(key)), dd); dl.appendChild(row); return { row: row, dd: dd }; }
    function panel(key, icon) {
      var dl = h('dl', { class: 'syn-kv' });
      return { dl: dl, el: h('section', { class: 'syn-panel' }, h('h4', { class: 'syn-panel-h' }, ui.icon(icon, 16, 'ci'), h('span', null, L(key))), dl) };
    }
    function line(icon, cls, tkey, dkey) { return h('p', { class: 'syn-line ' + cls }, ui.icon(icon, 16, 'ci'), h('span', null, tkey ? h('b', null, L(tkey), ' ') : null, L(dkey))); }
    function setRow(inp, tkey, dkey, topic) {
      return h('div', { class: 'syn-set' }, h('div', { class: 'syn-set-main' }, h('b', { class: 'syn-set-t', id: inp.getAttribute('aria-labelledby') }, L(tkey)), topic ? ui.help(topic) : null, h('div', { class: 'muted sm', id: inp.getAttribute('aria-describedby') }, L(dkey))),
        h('label', { class: 'sw' }, inp, h('span', { class: 'sw-ui' })));
    }

    /* 头部 */
    C.sub = h('span', { class: 'muted sm syn-sub' });
    C.refresh = ui.ibtn('refresh', L('common.refresh'), { cls: 'syn-refresh' }); ui.act(C.refresh, function () { return load(); });
    /* 提示条 (离线 / 读取失败 / 辅助服务不可用) */
    C.alertTxt = h('span', { class: 'syn-alert-t' });
    C.alertBtn = ui.btn(L('common.retry'), { sm: true, icon: 'refresh' }); ui.act(C.alertBtn, function () { return load(); });
    C.alert = h('div', { class: 'hint warn syn-alert', hidden: true }, ui.icon('warning', 16, 'ci'), C.alertTxt, C.alertBtn);
    /* 同步什么 / 不同步什么 / 加密 (一直可见) + 展开的详细说明 */
    C.what = h('div', { class: 'syn-what' },
      line('success', 'ok', 'sync.what.syncedT', 'sync.what.synced'),
      line('ban', 'no', 'sync.what.neverT', 'sync.what.never'),
      line('lock', 'sec', '', 'sync.what.e2ee'),
      C.moreBtn = ui.btn(L('common.details'), { sm: true, kind: 'ghost', icon: 'info', cls: 'syn-more-b' }));
    ui.act(C.moreBtn, function () {                                   // 详情: 弹窗 (不在卡片里行内展开)
      return ui.modal({ title: t('sync.what.moreTitle'), icon: 'info', iconKind: 'info', size: 'sm', body: h('ul', { class: 'syn-more-l' }, ['d1', 'd2', 'd3', 'd4', 'd5'].map(function (k) { return h('li', null, t('sync.what.' + k)); })), actions: [{ label: t('common.close'), kind: 'primary', cancel: true }] });
    });
    /* 两个开关 */
    C.sw = h('input', { type: 'checkbox', role: 'switch', 'aria-labelledby': id + '-s1t', 'aria-describedby': id + '-s1d' });
    ui.switchAct(C.sw, function () { return shown().enabled; }, setEnabled);
    C.swAuto = h('input', { type: 'checkbox', role: 'switch', 'aria-labelledby': id + '-s2t', 'aria-describedby': id + '-s2d' });
    ui.switchAct(C.swAuto, function () { return shown().auto; }, setAuto);
    C.sets = h('div', { class: 'syn-sets' }, setRow(C.sw, 'sync.on.title', 'sync.on.desc', 'sync.enable'), setRow(C.swAuto, 'sync.auto.title', 'sync.auto.desc', 'sync.auto')); // i18n-ignore: help topic ids
    /* 状态: 连接 + 这台电脑 + 云端 */
    C.conn = h('span', { class: 'syn-conn' });
    C.empty = ui.emptyBox(); C.empty.el.classList.add('syn-empty');
    var pl = panel('sync.st.local', 'nav-overview'), pr = panel('sync.st.remote', 'cloud-download');
    C.lv = kv(pl.dl, 'sync.st.version'); C.ls = kv(pl.dl, 'sync.st.state'); C.lp = kv(pl.dl, 'sync.st.lastPush'); C.ll = kv(pl.dl, 'sync.st.lastPull');
    C.rv = kv(pr.dl, 'sync.st.version'); C.ru = kv(pr.dl, 'sync.st.updated'); C.rd = kv(pr.dl, 'sync.st.device'); C.rs = kv(pr.dl, 'sync.st.size');
    C.rnT = h('b'); C.rnH = h('span', { class: 'muted sm' }); C.rn = h('div', { class: 'syn-note' }, C.rnT, C.rnH); pr.dl.parentNode.insertBefore(C.rn, pr.dl);
    C.panels = h('div', { class: 'syn-panels' }, pl.el, pr.el);
    C.status = h('div', { class: 'syn-status' },
      h('div', { class: 'syn-status-h' }, h('h3', null, L('sync.st.title'), ui.help('sync.status')), C.conn), C.empty.el, C.panels);
    /* 三个按钮 */
    C.bPush = ui.btn('', { kind: 'primary', icon: 'upload', title: L('sync.btn.push.tip') }); ui.act(C.bPush, doPush);
    C.bPull = ui.btn('', { icon: 'download-cloud', title: L('sync.btn.pull.tip') }); ui.act(C.bPull, openRestore);
    C.bClear = ui.btn('', { icon: 'delete', cls: 'danger-t syn-clear', title: L('sync.btn.clear.tip') }); ui.act(C.bClear, doClear);
    TP.sudo.mark(C.bClear);                                          // 清除云端数据: 敏感操作, 再次输入登录密码
    C.btns = h('div', { class: 'syn-btns' }, C.bPush, C.bPull, C.bClear, ui.help('sync.actions'));
    C.live = h('div', { class: 'sr', role: 'status', 'aria-live': 'polite' });

    C.el = h('section', { class: 'card syn', 'aria-labelledby': id + '-t' },
      h('div', { class: 'card-h' }, ui.icon('cloud-download', 20, 'ci'), h('h2', { id: id + '-t' }, L('sync.title'), ui.help('sync.page')), C.sub, C.refresh),
      C.alert, C.what, C.sets, C.status, C.btns, C.live);

    C.render = function () {
      var d = D, why = TP.why.helper(), sh = shown(), b = baseWhy(), mode = d ? 'data' : (loadErr || why ? 'error' : 'loading');
      var acct = (d && d.account) || (TP.auth && TP.auth.email ? TP.auth.email() : ''), al = null;
      setText(C.sub, acct ? t('sync.sub', { account: acct }) : t('sync.sub.plain'));
      C.refresh.classList.toggle('is-busy', loading);
      /* 提示条: 有旧数据可显示时, 同一时间只说最要紧的一件事; 一点数据都没有时, 由下面的空状态说明原因 */
      if (d) {
        if (why) al = { text: why };
        else if (!d.online) al = { text: t('sync.alert.offline'), retry: true };
        else if (loadErr) al = { text: t('sync.alert.stale', { reason: errText(loadErr) }), retry: true };
      }
      C.alert.hidden = !al;
      if (al) { setText(C.alertTxt, al.text); C.alertBtn.hidden = !al.retry; ui.setBtn(C.alertBtn, t('common.retry'), 'refresh'); }
      /* 开关 */
      if (C.sw.checked !== sh.enabled) C.sw.checked = sh.enabled;
      if (C.swAuto.checked !== sh.auto) C.swAuto.checked = sh.auto;
      applyWhy(C.sw, b);
      applyWhy(C.swAuto, b || (sh.enabled ? null : { reason: t('sync.auto.why.off'), fix: turnOnFix() }));
      /* 状态 */
      C.panels.hidden = mode !== 'data'; C.conn.hidden = mode !== 'data' || !!why;      // 辅助服务不可用时, 「已连接 enana.cc」是旧数据, 不显示
      C.status.classList.toggle('is-stale', !!why || !!loadErr);
      if (mode === 'loading') C.empty.show({ icon: 'refresh', text: t('sync.loading') });
      else if (mode === 'error') C.empty.show({ icon: 'warning', text: why || t('sync.alert.loadFailed', { reason: errText(loadErr) }), action: S.locked ? null : { label: t('common.retry'), icon: 'refresh', fn: function () { return load(); } } });
      else C.empty.hide();
      if (d) {
        var rel = relOf(d), R = REL[rel], rm = d.remote, sig = [d.online, rel, rm.exists, rm.version].join('|');
        ui.memo(C.conn, d.online ? 'on' : 'off', function () { return d.online ? ui.chip(t('sync.st.online'), 'ok', 'wifi') : ui.chip(t('sync.st.offline'), 'warn', 'wifi-off'); });
        setText(C.lv.dd, ver(d.local.version));
        ui.memo(C.ls.dd, rel, function () { return ui.chip(t(R.key), R.kind, R.icon); });
        setTime(C.lp.dd, d.lastPush); setTime(C.ll.dd, d.lastPull);
        [C.rv, C.ru, C.rd, C.rs].forEach(function (r) { r.row.hidden = !rm.exists; });
        C.rn.hidden = rm.exists;
        if (rm.exists) {
          setText(C.rv.dd, ver(rm.version)); setTime(C.ru.dd, rm.updated);
          setText(C.rd.dd, rm.device || '—'); setText(C.rs.dd, rm.size ? fmt.bytes(rm.size) : '—');
        } else {
          setText(C.rnT, t(d.online ? 'sync.remote.none' : 'sync.remote.offline'));
          setText(C.rnH, d.online ? t('sync.remote.noneHint') : '');
        }
        if (C.sig !== null && C.sig !== sig) setText(C.live, d.online ? t('sync.live.state', { state: t(R.key) }) : t('sync.alert.offline'));    // 状态变了才读出来 (第一次渲染不读)
        C.sig = sig;
      }
      /* 按钮 */
      ui.setBtn(C.bPush, t(busy === 'push' ? 'sync.btn.pushing' : 'sync.btn.push'), busy === 'push' ? 'refresh' : 'upload');
      ui.setBtn(C.bPull, t(busy === 'pull' ? 'sync.btn.pulling' : 'sync.btn.pull'), busy === 'pull' ? 'refresh' : 'download-cloud');
      ui.setBtn(C.bClear, t(busy === 'clear' ? 'sync.btn.clearing' : 'sync.btn.clear'), busy === 'clear' ? 'refresh' : 'delete');
      [[C.bPush, 'push', pushWhy], [C.bPull, 'pull', pullWhy], [C.bClear, 'clear', clearWhy]].forEach(function (x) {
        x[0].classList.toggle('is-busy', busy === x[1]);
        if (busy === x[1]) x[0].setAttribute('aria-busy', 'true'); else x[0].removeAttribute('aria-busy');
        applyWhy(x[0], x[2]());
      });
    };
    cards.push(C);
    return C;
  }

  function renderAll() {
    cards = cards.filter(function (C) { C.seen = C.seen || document.contains(C.el); return !C.seen || document.contains(C.el); });     // 从页面上拿掉的卡片自动清理
    cards.forEach(function (C) { try { C.render(); } catch (e) { console.error('[sync] render', e); } });
  }

  /* ================= 弹窗阶段 (恢复 / 冲突 / 新电脑提示 共用) =================
   * 一个弹窗 = 一个 flow st: 关闭后 st.closed=true, 并唤醒所有在等用户选择的 Promise; 阶段之间直接替换弹窗内容 (选择 -> 进度 -> 旧密码 -> 出错重试)。 */
  function newFlow() { return { closed: false, hooks: [], live: null }; }
  function openModal(o, st) {
    var entry = null, inner = o.onClose, api;
    st.live = h('div', { class: 'sr', role: 'status', 'aria-live': 'polite' });
    o.cls = 'syn-dlg' + (o.cls ? ' ' + o.cls : '');
    o.onClose = function (v) {
      st.closed = true;
      modals = modals.filter(function (m) { return m !== entry; });
      st.hooks.splice(0).forEach(function (f) { try { f(v); } catch (e) { console.error('[sync]', e); } });
      if (inner) inner(v);
    };
    api = ui.modal(o);
    entry = { api: api, st: st };
    if (!st.closed) modals.push(entry);
    if (api.el.firstChild) api.el.firstChild.appendChild(st.live);
    return api;
  }
  function say(st, text) { if (st.live) setText(st.live, text); }
  /* 在弹窗底部放几个按钮, 等用户选一个 (返回它的 value); 弹窗被 ✕ / ESC 关掉 -> 'closed' */
  function decide(api, st, list) {
    return new Promise(function (resolve) {
      if (st.closed) { resolve('closed'); return; }
      st.hooks.push(function () { resolve('closed'); });
      api.setActions(list.map(function (a) {
        return { label: a.label, kind: a.kind, icon: a.icon, id: a.id, autofocus: a.autofocus, onClick: function () { resolve(a.value); return false; } };
      }));
      var b = api.foot.querySelector('[data-autofocus]') || api.foot.querySelector('.btn');          // 内容换了: 焦点放到默认按钮上, 键盘用户可以直接操作
      if (b) { try { b.focus({ preventScroll: true }); } catch (e) { /* 忽略 */ } }
    });
  }
  function showProgress(api, st, title) {
    var card = ui.taskCard(''), box = h('div', { class: 'syn-prog', tabindex: '-1', 'aria-busy': 'true' }, card.el);     // 标题放在弹窗标题栏里, 进度卡不再重复
    api.setTitle(title); TP.clear(api.body); api.body.appendChild(box); api.setActions([]); api.setBusy(true);
    card.set({ pct: null, msg: t('job.submitting') });
    try { box.focus({ preventScroll: true }); } catch (e) { /* 忽略 */ }
    return card;
  }
  function feed(card, fallbackKey) { return { fromJob: function (j) { card.set({ pct: j.pct, msg: j.msg || t(fallbackKey), steps: j.steps || [] }); } }; }

  /* 旧密码: 返回输入的密码 (字符串) 或 null (取消)。只在内存里, 取走后输入框立刻清空 (JS 字符串没法真正擦除, 尽量缩短存活时间)。 */
  function askOldPassword(api, st, retry) {
    return new Promise(function (resolve) {
      var settled = false, k = 'syn-k' + (++uid);
      var inp = h('input', { class: 'inp', type: 'password', autocomplete: 'off', autocapitalize: 'off', spellcheck: 'false', 'data-lpignore': 'true', 'data-1p-ignore': '', 'aria-labelledby': k + 'l', 'aria-describedby': k + 'h' });
      var eye = ui.ibtn('eye', t('sync.key.show'), { size: 18 }), err = h('p', { class: 'syn-key-err bad-t', role: 'alert', hidden: !retry }, retry ? t('sync.key.wrong') : '');
      var form = h('form', { class: 'syn-key', novalidate: true },
        h('p', { class: 'syn-key-m' }, t('sync.key.intro')),
        h('div', { class: 'fld' }, h('span', { class: 'fld-l', id: k + 'l' }, t('sync.key.label')), h('span', { class: 'syn-pw' }, inp, eye), h('span', { class: 'fld-h', id: k + 'h' }, t('sync.key.hint'))),
        err);
      function finish(v) { if (settled) return; settled = true; inp.value = ''; resolve(v); }
      function submit() {
        var v = inp.value;
        if (!v) { err.hidden = false; setText(err, t('sync.key.empty')); inp.focus(); return false; }
        finish(v); v = '';
        return false;
      }
      eye.classList.add('syn-eye'); eye.setAttribute('aria-pressed', 'false');
      eye.addEventListener('click', function () {
        var show = inp.type === 'password', lab = t(show ? 'sync.key.hide' : 'sync.key.show');
        inp.type = show ? 'text' : 'password';
        eye.setAttribute('aria-pressed', show ? 'true' : 'false'); eye.setAttribute('aria-label', lab); eye.title = lab; eye._tip = lab;
        eye.replaceChild(ui.icon(show ? 'eye-off' : 'eye', 18, 'bi'), eye.firstChild); eye._iconEl = eye.firstChild; inp.focus();
      });
      form.addEventListener('submit', function (ev) { ev.preventDefault(); submit(); });
      st.hooks.push(function () { finish(null); });
      api.setTitle(t('sync.key.title')); TP.clear(api.body); api.body.appendChild(form); api.setBusy(false);
      api.setActions([
        { label: t('common.cancel'), onClick: function () { finish(null); return false; } },
        { label: t('sync.key.go'), kind: 'primary', icon: 'key-round', id: 'go', onClick: submit }
      ]);
      say(st, retry ? t('sync.key.wrong') : t('sync.key.title'));
      try { inp.focus(); } catch (e) { /* 忽略 */ }
    });
  }

  /* 在弹窗里执行一次恢复 (pull): 进度 -> (E_SYNC_KEY: 旧密码) -> (出错: 重试 / 关闭)。
   * o: {title (进度卡标题), before: async 函数, 第一次尝试前执行一次 (新电脑提示用它先开启同步)}
   * 返回 {ok} | {ok:false, cancelled} | {ok:false, auth} ; 成功时弹窗保持打开 (由调用方收尾)。 */
  async function runPullIn(api, st, mode, o) {
    o = o || {};
    var oldPw = '', asked = false, pre = !o.before, card, r, pw, again, msg, code;
    busy = 'pull'; renderAll();
    try {
      for (;;) {
        if (st.closed) return { ok: false };
        card = showProgress(api, st, o.title || t('sync.res.running'));
        say(st, t('sync.res.running'));
        try {
          if (!pre) { await o.before(); pre = true; }
          r = await TP.helper('POST', '/api/sync/pull', { form: oldPw ? { mode: mode, old_password: oldPw } : { mode: mode }, timeout: 25000 });
          oldPw = '';                                                           // 已经发出去了: 立刻丢掉
          if (r && r.job) await TP.jobs.follow(r.job, feed(card, 'sync.res.running'));
          return { ok: true };
        } catch (e) {
          oldPw = '';
          if (e && e.kind === 'auth') return { ok: false, auth: true };
          if (st.closed) return { ok: false };
          api.setBusy(false);
          code = codeOf(e);
          if (code === 'E_SYNC_KEY') {
            pw = await askOldPassword(api, st, asked); asked = true;
            if (pw === null) return { ok: false, cancelled: true };
            oldPw = pw; pw = '';
            continue;
          }
          msg = errText(e);
          card.set({ pct: 100, msg: msg, cls: 'err' });
          say(st, t('sync.res.failedSay', { reason: msg }));
          if (code === 'E_ACCOUNT_UNREACHABLE') load();                          // 顺便刷新「连不上 enana.cc」的状态
          again = await decide(api, st, [
            { label: t('common.close'), value: 'close' },
            { label: t('common.retry'), kind: 'primary', icon: 'refresh', value: 'retry', autofocus: true }
          ]);
          if (again !== 'retry') return { ok: false };
        }
      }
    } finally { oldPw = ''; busy = ''; renderAll(); }
  }
  /* 恢复成功之后: 刷新本机数据 (服务器 / 策略 / 设置) 和同步状态 */
  function afterPull() {
    try { if (TP.afterApply) TP.afterApply(); } catch (e) { console.error('[sync]', e); }
    TP.loadState(); TP.loadSettings(); load();
  }

  /* 每个阶段都能看清「云端是什么 / 这台电脑是什么」 */
  function facts(d) {
    var rm = d.remote, dl = h('dl', { class: 'syn-kv syn-facts' });
    function row(k, v) { dl.appendChild(h('div', { class: 'syn-kvr' }, h('dt', null, t(k)), h('dd', null, v))); }
    row('sync.facts.cloud', rm.size ? t('sync.facts.cloudSize', { brief: brief(rm), size: fmt.bytes(rm.size) }) : brief(rm));
    row('sync.facts.local', d.local.dirty ? t('sync.facts.localDirty', { ver: ver(d.local.version) }) : ver(d.local.version));
    return dl;
  }

  /* ================= 开关 ================= */
  async function saveSettings(v) {                                    // v: {enabled, auto}
    busy = 'save'; pend = { enabled: v.enabled, auto: v.auto }; renderAll();
    try { await TP.helper('POST', '/api/sync/settings', { form: { enabled: v.enabled ? 1 : 0, auto: v.auto ? 1 : 0 } }); }
    finally { busy = ''; pend = null; renderAll(); }
    if (D) { D.enabled = v.enabled; D.auto = v.auto; renderAll(); }
    await load();
  }
  async function setEnabled(want) {
    if (guard(baseWhy())) return;
    var ok = await ui.confirmDialog(want
      ? { title: t('sync.on.confirmTitle'), message: t('sync.on.confirmMsg'), detail: [t('sync.on.d1'), t('sync.never.short'), t('sync.on.d3')], confirmText: t('sync.on.go') }
      : { title: t('sync.off.confirmTitle'), message: t('sync.off.confirmMsg'), detail: [t('sync.off.d1'), t('sync.d.localSame')], confirmText: t('sync.off.go') });
    if (!ok) return;
    await saveSettings({ enabled: want, auto: want ? !!(D && D.auto) : false });         // 关闭同步时一并关掉自动同步
    ui.toast(t(want ? 'sync.on.done' : 'sync.off.done'), 'ok', 3200);
  }
  async function setAuto(want) {
    if (guard(baseWhy() || (D.enabled ? null : { reason: t('sync.auto.why.off'), fix: turnOnFix() }))) return;
    var ok = await ui.confirmDialog(want
      ? { title: t('sync.auto.onTitle'), message: t('sync.auto.onMsg'), detail: [t('sync.auto.onD1'), t('sync.never.short')], confirmText: t('sync.auto.onGo') }
      : { title: t('sync.auto.offTitle'), message: t('sync.auto.offMsg'), confirmText: t('sync.auto.offGo'), rememberKey: 'syncAutoOff' });
    if (!ok) return;
    await saveSettings({ enabled: true, auto: want });
    ui.toast(t(want ? 'sync.auto.onDone' : 'sync.auto.offDone'), 'ok', 3200);
  }

  /* ================= 立即上传 ================= */
  async function doPush() {
    if (guard(pushWhy())) return;
    var rm = D.remote, ok = await ui.confirmDialog({
      title: t('sync.push.confirmTitle'), message: rm.exists ? t('sync.push.confirmMsg', { brief: brief(rm) }) : t('sync.push.confirmFirst'),
      detail: [t('sync.push.d1'), t('sync.push.d2')], confirmText: t('sync.push.go'), rememberKey: 'syncPush'
    });
    if (!ok || guard(pushWhy())) return;
    return runPush(false);
  }
  /* force=true: 用本机覆盖云端 (冲突弹窗里用户已经确认过) */
  async function runPush(force) {
    if (busy) { ui.toast(t('sync.why.busy'), 'warn'); return; }
    var title = t('sync.push.job'), card = ui.taskCard(title), conflict = false, j;
    busy = 'push'; renderAll();
    ui.dock(card); card.set({ pct: null, msg: t('job.submitting') });
    try {
      var r = await TP.helper('POST', '/api/sync/push', { form: force ? { force: 1 } : undefined, timeout: 25000 });
      if (r && r.job) j = await TP.jobs.follow(r.job, feed(card, 'sync.push.running'));
      card.done((j && j.msg) || t('sync.push.done')); setTimeout(card.close, 6000);
      ui.toast(t('sync.push.done'), 'ok');
    } catch (e) {
      if (e && e.kind === 'auth') card.close();
      else if (!force && codeOf(e) === 'E_SYNC_CONFLICT') { conflict = true; card.close(); }
      else { card.fail(errText(e)); ui.toast(t('job.failToast', { title: title, reason: errText(e) }), 'err'); }
    } finally { busy = ''; renderAll(); }
    await load();
    if (conflict) await openConflict();
  }

  /* 冲突: 云端比这台电脑新。两个明确的选择, 每个都要再确认一次 (危险) */
  function openConflict() {
    var d = D, st = newFlow(), api;
    if (!d) return Promise.resolve();
    function choice(icon, cls, tkey, dkey, handler) {
      var b = h('button', { class: 'syn-choice' + (cls ? ' ' + cls : ''), type: 'button' }, ui.icon(icon, 22, 'syn-choice-ic'), h('span', { class: 'syn-choice-b' }, h('b', null, t(tkey)), h('span', { class: 'muted sm' }, t(dkey))));
      ui.act(b, handler);
      return b;
    }
    api = openModal({
      title: t('sync.conf.title'), icon: 'warning', iconKind: 'bad', size: 'md',
      body: h('div', { class: 'syn-conf' }, h('p', { class: 'syn-conf-m' }, t('sync.conf.intro')), facts(d),
        h('div', { class: 'syn-choices', role: 'group', 'aria-label': t('sync.conf.choices') },
          choice('download-cloud', '', 'sync.conf.cloud.t', 'sync.conf.cloud.d', async function () {
            var ok = await ui.confirmDialog({ title: t('sync.conf.cloud.confirmTitle'), message: t('sync.conf.cloud.confirmMsg', { brief: brief(d.remote) }),
              detail: [t('sync.res.rep.d2'), d.local.dirty ? t('sync.res.rep.dDirty') : '', t('sync.res.d.safe'), t('sync.res.d.rollback')], confirmText: t('sync.conf.cloud.go'), danger: true });
            if (!ok || st.closed) return;
            var res = await runPullIn(api, st, 'replace', {});
            if (res.ok) { afterPull(); ui.toast(t('sync.pull.done'), 'ok'); }
            if (!st.closed) { api.setBusy(false); api.close(res.ok ? 'cloud' : 'cancel'); }
          }),
          choice('upload', 'danger', 'sync.conf.local.t', 'sync.conf.local.d', async function () {
            var ok = await ui.confirmDialog({ title: t('sync.conf.local.confirmTitle'), message: t('sync.conf.local.confirmMsg', { brief: brief(d.remote) }),
              detail: [t('sync.d.localSame'), t('sync.d.noUndo')], confirmText: t('sync.conf.local.go'), danger: true });
            if (!ok || st.closed) return;
            api.close('local');
            await runPush(true);
          }))),
      actions: [{ label: t('common.cancel'), cancel: true }]
    }, st);
    return api.closed;
  }

  /* ================= 从云端恢复 ================= */
  function openRestore() {
    if (guard(pullWhy())) return Promise.resolve();
    var d = D, st = newFlow(), mode = 'merge', inputs = {}, api, group, warn;
    var OPTS = [['merge', 'sync.res.merge.t', 'sync.res.merge.d'], ['replace', 'sync.res.replace.t', 'sync.res.replace.d']];
    function sync() { Object.keys(inputs).forEach(function (v) { inputs[v].checked = v === mode; inputs[v].parentNode.classList.toggle('on', v === mode); }); }
    group = h('div', { class: 'syn-opts', role: 'radiogroup', 'aria-label': t('sync.res.modeAria') }, OPTS.map(function (o) {
      var inp = h('input', { type: 'radio', name: 'syn-mode-' + (++uid), value: o[0] });
      if (o[0] === mode) inp.setAttribute('data-autofocus', '');
      inp.addEventListener('change', function () { if (inp.checked) { mode = o[0]; sync(); } });
      inputs[o[0]] = inp;
      return h('label', { class: 'syn-opt' }, inp, h('span', { class: 'syn-opt-b' }, h('b', null, t(o[1])), h('span', { class: 'muted sm' }, t(o[2]))));
    }));
    warn = d.local.dirty ? h('p', { class: 'hint warn' }, t('sync.res.dirtyWarn')) : null;
    api = openModal({
      title: t('sync.res.title'), icon: 'download-cloud', iconKind: 'pri', size: 'md',
      body: h('div', { class: 'syn-res' }, h('p', { class: 'syn-res-m' }, t('sync.res.intro')), facts(d), group, warn),
      actions: [
        { label: t('common.cancel'), cancel: true },
        { label: t('sync.res.go'), kind: 'primary', icon: 'download-cloud', id: 'go', onClick: async function (a) {
          if (guard(pullWhy())) return false;
          var rep = mode === 'replace', rm = d.remote, det = [], ok, res;
          det.push(t(rep ? 'sync.res.rep.d1' : 'sync.res.mrg.d1'));
          det.push(t(rep ? 'sync.res.rep.d2' : 'sync.res.mrg.d2'));
          if (rep && d.local.dirty) det.push(t('sync.res.rep.dDirty'));
          det.push(t('sync.res.d.safe')); det.push(t('sync.res.d.rollback'));
          ok = await ui.confirmDialog({ title: t(rep ? 'sync.res.confirmTitleRep' : 'sync.res.confirmTitleMrg'), message: t(rep ? 'sync.res.confirmMsgRep' : 'sync.res.confirmMsgMrg', { brief: brief(rm) }),
            detail: det, confirmText: t(rep ? 'sync.res.goRep' : 'sync.res.goMrg'), danger: rep });
          if (!ok || st.closed) return false;
          res = await runPullIn(a, st, mode, {});
          if (res.ok) { afterPull(); ui.toast(t('sync.pull.done'), 'ok'); }
          if (!st.closed) { a.setBusy(false); a.close(res.ok ? 'done' : 'cancel'); }
          return false;
        } }
      ]
    }, st);
    sync();
    return api.closed;
  }

  /* ================= 清除云端数据 (两步确认: 先说明, 再输入确认词) ================= */
  function openClearWord() {
    return new Promise(function (resolve) {
      var word = t('sync.clear.word'), done = false, st = newFlow(), api, inp, form;
      function matches() { var v = inp.value.trim().toLowerCase(); return v !== '' && (v === word.toLowerCase() || v === 'delete'); }
      function refresh() { var b = api && api.getBtn('go'); if (b) ui.avail(b, matches() ? '' : t('sync.clear.mismatch', { word: word })); }
      inp = h('input', { class: 'inp syn-word-inp', type: 'text', autocomplete: 'off', autocapitalize: 'off', spellcheck: 'false' });
      inp.addEventListener('input', refresh);
      form = h('form', { class: 'mform syn-clearf', novalidate: true },
        h('p', { class: 'syn-clear-m' }, I.rich('sync.clear.type', { word: h('code', { class: 'syn-word' }, word) })),
        ui.field(t('sync.clear.field'), inp, t('sync.clear.fieldHint')));
      api = openModal({
        title: t('sync.clear.title2', { word: word }), icon: 'delete', iconKind: 'bad', size: 'sm', body: form,
        actions: [
          { label: t('common.cancel'), cancel: true },
          { label: t('sync.clear.go'), kind: 'danger', icon: 'delete', id: 'go', onClick: async function (a) {
            if (!matches()) { inp.focus(); return false; }
            if (guard(clearWhy())) return false;
            a.setBusy(true); busy = 'clear'; renderAll();
            try { await TP.helper('POST', '/api/sync/clear', { timeout: 25000 }); }
            catch (e) { if (!(e && e.kind === 'auth')) ui.toast(errText(e), 'err', 7000); return false; }
            finally { a.setBusy(false); busy = ''; renderAll(); }
            done = true;
          } }
        ],
        onClose: function () { resolve(done); }
      }, st);
      form.addEventListener('submit', function (ev) { ev.preventDefault(); var b = api.getBtn('go'); if (b) b.click(); });
      refresh();
    });
  }
  async function doClear() {
    if (guard(clearWhy())) return;
    var rm = D.remote, det = [t('sync.d.localSame'), t('sync.clear.d2')], ok;
    if (D.enabled && D.auto) det.push(t('sync.clear.d3'));
    det.push(t('sync.d.noUndo'));
    ok = await ui.confirmDialog({ title: t('sync.clear.confirmTitle'), message: t('sync.clear.confirmMsg', { brief: brief(rm) }), detail: det, confirmText: t('sync.clear.next'), danger: true });
    if (!ok) return;
    if (await openClearWord()) { ui.toast(t('sync.clear.done'), 'ok'); await load(); }
  }

  /* ================= 新电脑登录后: 检测到云端配置 ================= */
  function noMap() { var m = TP.ls.get('syncNo', {}); return m && typeof m === 'object' && !Array.isArray(m) ? m : {}; }
  function declined(who) { return !!who && !!noMap()[who]; }
  function rememberNo(who) { if (!who) return; var m = noMap(); m[who] = Math.floor(Date.now() / 1000); TP.ls.set('syncNo', m); }

  function openOffer(d, who) {
    return new Promise(function (resolve) {
      var st = newFlow(), rm = d.remote, enabledByUs = false, api;
      var msg = rm.servers >= 0 ? t('sync.offer.msgN', { n: rm.servers, device: devName(rm), when: fmt.rel(rm.updated) }) : t('sync.offer.msg', { ver: ver(rm.version), device: devName(rm), when: fmt.rel(rm.updated) });
      api = openModal({
        title: t('sync.offer.title'), icon: 'cloud-download', iconKind: 'pri', size: 'md',
        body: h('div', { class: 'syn-offer' }, h('p', { class: 'syn-offer-m' }, msg),
          h('ul', { class: 'cfm-list' }, h('li', null, t('sync.offer.d1')), h('li', null, t('sync.never.short'))),
          h('p', { class: 'muted sm' }, t('sync.offer.later'))),
        actions: [
          { label: t('sync.offer.no'), id: 'no', onClick: function () {
            rememberNo(who);
            ui.toast(t('sync.offer.declined'), '', 8000, { action: { label: t('sync.offer.openSettings'), fn: function () { TP.go('settings'); } } });
          } },
          { label: t('sync.offer.go'), kind: 'primary', icon: 'download-cloud', id: 'go', autofocus: true, onClick: async function (a) {
            var why = TP.why.helper(), res;
            if (why) { ui.toast(why, 'warn'); return false; }
            res = await runPullIn(a, st, 'replace', {
              title: t('sync.offer.job'),
              before: async function () { await TP.helper('POST', '/api/sync/settings', { form: { enabled: 1, auto: 0 } }); enabledByUs = true; }
            });
            if (res.ok) { afterPull(); ui.toast(t('sync.offer.done'), 'ok', 5200); }
            else if (enabledByUs && !res.auth) {                                  // 没同步成功: 把我们刚打开的同步关回去, 不留下半开的状态
              try { await TP.helper('POST', '/api/sync/settings', { form: { enabled: 0, auto: 0 } }); } catch (e) { /* 忽略: 用户可以在设置里关 */ }
              ui.toast(t('sync.offer.revert'), 'warn', 8000);
              load();
            }
            if (!st.closed) { a.setBusy(false); a.close(res.ok ? 'done' : 'cancel'); }
            return false;
          } }
        ],
        onClose: function () { resolve(); }
      }, st);
    });
  }

  /* 添加服务器时的「保存到云端」: 默认勾选; 只有用户在设置里明确关闭过同步时默认不勾选 (勾选会重新开启) */
  SY.prime = function () { return load(true).then(function () { return SY.saveDefault(); }, function () { return SY.saveDefault(); }); };
  SY.saveDefault = function () {
    var off = !!(D && D.decided && !D.enabled);
    return { checked: !off, off: off };
  };

  SY.offerAfterLogin = async function () {
    if (offerRun) return;
    offerRun = true;
    try {
      var sv = S.state && S.state.servers;                                      // 调用方保证 S.state 已加载; 还没有就不提示
      if (S.locked || !Array.isArray(sv) || sv.length) return;                  // 本机已经有服务器: 不打扰
      await TP.sleep(3000);                                                     // 登录时辅助服务会自动取回云端的服务器 (后台任务): 等它先做完, 已经同步了就不再提示
      var d = await load(), who;
      if (!d || S.locked || !d.online || !d.remote.exists || d.enabled) return;
      who = (d.account || (TP.auth && TP.auth.email ? TP.auth.email() : '')).toLowerCase();
      if (offered[who] || declined(who)) return;
      offered[who] = true;                                                      // 同一个账号, 一次页面加载里最多提示一次
      await openOffer(d, who);
    } catch (e) { console.error('[sync] offer', e); }                           // 提示只是锦上添花: 出错不要变成全局的「未处理错误」提示
    finally { offerRun = false; }
  };

  /* ================= 设置页卡片入口 ================= */
  /* 设置页重新显示时立即刷新: 监听所在 .view 的 hidden 属性 (卡片在 init 里先创建、随后才挂到页面上, 所以等一拍再找) */
  function watchView(C) {
    var v = C.el.closest ? C.el.closest('.view') : null;
    if (!v || !window.MutationObserver) return;
    new MutationObserver(function () { if (!v.hidden && !S.locked) load(true); }).observe(v, { attributes: true, attributeFilter: ['hidden'] });
  }
  SY.settingsCard = function () {
    var C = makeCard();
    C.el._reload = function () { return load(); };
    C.render();
    setTimeout(function () { watchView(C); }, 0);
    if (!S.locked) load(true);
    return C.el;
  };

  /* ================= 事件 ================= */
  TP.on('auth', function (ok) {
    if (ok) { if (cards.length) load(); return; }
    seq++; D = null; loadErr = null; loading = false; inflight = null; loadedAt = 0; busy = ''; pend = null;      // 退出 / 锁定: 丢掉上一个账号的数据, 关掉所有同步弹窗 (含旧密码输入框)
    modals.slice().forEach(function (m) { try { m.api.close('lock'); } catch (e) { console.error('[sync]', e); } });
    renderAll();
  });
  TP.on('helper', function (up) { if (up && !S.locked && cards.length) load(true); else renderAll(); });
  TP.on('lang', renderAll);
  TP.on('settings', function () { if (active() && cards.length) load(true); });
  TP.poll(function () { return cards.length ? load(true) : null; }, 60000, { when: active, delay: 3000 });       // 设置页打开时每 60 秒刷新一次
})();
