/* enana · v-import.js — 添加 / 导入服务器 (弹窗)
 * 标签 1) 导入: 一个文本框接受任何内容 (订阅链接 / 分享链接 / Clash·Stash YAML / sing-box JSON / Base64)
 *     步骤: 识别格式 -> 下载订阅 -> 解析节点 -> 预览确认 -> (二次确认) 写入并应用配置 -> 测速
 * 标签 2) 手动添加单个服务器: 表单 -> 生成分享链接 -> 交给 TPImporter.parse -> (二次确认) 同一套写入流程
 * 预览、角色选择、进度都留在同一个弹窗里; 最后的「确认写入」还会再确认一次 (汇总会改变什么)。
 * 密码只在提交的瞬间读取, 确认后立即清空输入框; 不记录、不保存。 */
(function () {
  'use strict';
  var TP = window.TP, S = TP.S, h = TP.h, ui = TP.ui, setText = TP.setText, fmt = TP.fmt, enc = TP.enc, I = window.I18N, t = I.t, L = I.L;
  var imp = TP.imp = {};
  var cur = null;                                                     // 当前打开的弹窗会话 (同一时间只有一个)
  var UAS = ['auto', 'clash', 'v2ray'];                                // auto = sing-box 格式 (最完整); 解析为 0 个节点时依次换 clash、v2ray
  var UA_KEY = { auto: 'imp.ua.auto', clash: 'imp.ua.clash', v2ray: 'imp.ua.v2ray' };
  var TYPE_LABEL = { http: 'HTTP', socks: 'SOCKS5', shadowsocks: 'Shadowsocks', hysteria2: 'Hysteria2', tuic: 'TUIC', vless: 'VLESS', trojan: 'Trojan', vmess: 'VMess', anytls: 'AnyTLS' };
  var ROLES = ['auto', 'pin', 'dl', 'off'];
  var SUB_NAME_RE = /^[A-Za-z0-9._ -]{1,40}$/;                          // 与辅助服务的校验一致
  var MTYPES = [
    { v: 'trojan', label: 'Trojan', port: 443, tls: true, secret: 'imp.man.password' },
    { v: 'hysteria2', label: 'Hysteria2', port: 443, tls: true, secret: 'imp.man.password' },
    { v: 'tuic', label: 'TUIC', port: 443, tls: true, secret: 'imp.man.uuid', secret2: true },
    { v: 'vless', label: 'VLESS', port: 443, tls: true, secret: 'imp.man.uuid' },
    { v: 'shadowsocks', label: 'Shadowsocks', port: 8388, method: true, secret: 'imp.man.password' },
    { v: 'http', label: 'HTTP / HTTPS', port: 8080, user: true, tlsOpt: true, secret: 'imp.man.passwordOpt' },
    { v: 'socks', label: 'SOCKS5', port: 1080, user: true, secret: 'imp.man.passwordOpt' }
  ];
  var SS_METHODS = ['aes-128-gcm', 'aes-256-gcm', 'chacha20-ietf-poly1305', '2022-blake3-aes-128-gcm', '2022-blake3-aes-256-gcm', '2022-blake3-chacha20-poly1305'];

  function typeLabel(ob) { return ob.type === 'http' && ob.tls && ob.tls.enabled ? 'HTTPS' : (TYPE_LABEL[ob.type] || ob.type); }
  function canDl(ty) { return ty === 'http' || ty === 'socks'; }
  function cleanSubName(s) { s = String(s || '').replace(/[^A-Za-z0-9._ -]/g, '').trim().slice(0, 40); return s || 'sub'; }
  function allTags() { return TP.servers().map(function (s) { return s.tag; }); }
  imp.busy = function () { return !!(cur && (cur.st.phase === 'working' || cur.st.phase === 'committing')); };

  /* ---------- 导入器给出的原因 / 警告是中文原文: 用中文词典里的模板反查, 再换成当前语言 ---------- */
  var reasonIdx = null;
  function buildReasonIdx() {
    var d = I.dict('zh'), out = [];
    Object.keys(d).forEach(function (k) {
      if (k.indexOf('import.reason.') !== 0 && k.indexOf('import.warn.') !== 0) return;
      var names = [], src = String(d[k]).replace(/[.*+?^$()|[\]\\]/g, '\\$&').replace(/\{(\w+)\}/g, function (m, n) { names.push(n); return '(.*)'; });
      out.push({ key: k, names: names, re: new RegExp('^' + src + '$') });
    });
    return out;
  }
  function importerText(raw) {
    raw = String(raw == null ? '' : raw);
    if (!reasonIdx) reasonIdx = buildReasonIdx();
    var i, m, vars, j, zhUnknown = I.dict('zh')['import.word.unknown'];
    for (i = 0; i < reasonIdx.length; i++) {
      m = reasonIdx[i].re.exec(raw);
      if (!m) continue;
      vars = {};
      for (j = 0; j < reasonIdx[i].names.length; j++) vars[reasonIdx[i].names[j]] = m[j + 1] === zhUnknown ? t('import.word.unknown') : m[j + 1];
      return t(reasonIdx[i].key, vars);
    }
    return raw;
  }
  imp.reasonText = importerText;

  /* ================= 订阅下载 + 解析 (导入弹窗与「刷新订阅」共用) =================
   * o: {url | name, existingTags, onStage(stage, msg), onNote(msg)}
   * ua 顺序: auto(sing-box) -> clash -> v2ray; 不信任 Content-Type, 正文直接交给 TPImporter.parse */
  imp.fetchSub = async function (o) {
    var last = null, lastErr = null, usage = null, interval = 0, i, ua, r, p, t0, timer;
    for (i = 0; i < UAS.length; i++) {
      ua = UAS[i];
      if (o.onStage) o.onStage('download', i ? t('imp.msg.retryUa', { name: t(UA_KEY[ua]) }) : t('imp.msg.downloading'), i);
      t0 = Date.now();
      timer = setInterval(function () { if (o.onNote) o.onNote(t('imp.msg.waited', { sec: Math.round((Date.now() - t0) / 1000) })); }, 1000);
      try {
        r = await TP.helper('POST', '/api/sub/fetch', { q: { ua: ua, name: o.name || '' }, body: o.name ? '' : o.url, text: true, timeout: 60000 });
      } catch (e) {
        clearInterval(timer); lastErr = e;
        if (e.kind === 'unreachable' || e.kind === 'auth') break;
        continue;
      }
      clearInterval(timer);
      usage = usage || fmt.parseUserinfo(r.headers.get('X-Subscription-Userinfo'));
      interval = interval || parseInt(r.headers.get('X-Profile-Update-Interval'), 10) || 0;
      if (o.onStage) o.onStage('parse', t('imp.msg.parsing'), i);
      p = TPImporter.parse(r.text, { role: 'auto', existingTags: o.existingTags || [] });
      last = { servers: p.servers, skipped: p.skipped, format: p.format, ua: ua };
      if (p.servers.length) break;
      await TP.sleep(60);
    }
    if (!last) throw lastErr || TP.mkErr('http', t('imp.err.download'));
    last.usage = usage; last.interval = interval;
    return last;
  };

  /* ================= 打开弹窗 ================= */
  /* 模式: 'import' (粘贴) | 'manual' (手动填写一台) | 'vps-password' / 'vps' (我的服务器 · 密码登录) | 'vps-key' (我的服务器 · 密钥登录) */
  function norm(m) {
    if (m === 'manual') return { top: 'import', mode: 'manual' };
    if (m === 'vps' || m === 'vps-password') return { top: 'vps-password', mode: 'import' };
    if (m === 'vps-key') return { top: 'vps-key', mode: 'import' };
    return { top: 'import', mode: 'import' };
  }
  imp.open = function (mode) {
    var why = TP.why.helper();
    if (why) { ui.toast(why, 'warn', 5200); return null; }
    if (cur) { cur.setMode(mode); return cur.api; }
    cur = session(mode);
    return cur.api;
  };
  TP.on('lang', function () { if (cur && cur.relang) cur.relang(); });

  function session(mode0) {
    var n0 = norm(mode0);
    var st = { phase: 'idle', mode: n0.mode, top: n0.top, sources: [], rows: [], filter: '' };      // phase: idle | working | preview | committing | done;  top: import | vps-password | vps-key
    var el = {}, mf = {}, api = null, detTimer = 0, vps = {}, vpsBusy = false;
    var steps = ['detect', 'download', 'parse', 'preview', 'write', 'test'].map(function (k) { return { key: k, state: 'todo', note: '' }; });
    var ses = { st: st };

    function stepsView() { return steps.map(function (s) { return { label: t('imp.step.' + s.key), state: s.state, note: s.note }; }); }
    function syncSteps() { ui.renderSteps(el.stepOl, stepsView()); }
    function setStep(i, state, note) { steps[i].state = state; steps[i].note = note || ''; syncSteps(); }
    function setMsg(text, cls) { setText(el.stepMsg, text || ''); el.stepMsg.className = 'step-msg' + (cls ? ' ' + cls : ''); }

    /* ---------- 骨架 ---------- */
    el.tabs = ui.tabs(L('imp.tabs.aria'), [
      { id: 'import', label: L('imp.tab.import'), icon: 'file-down' },
      { id: 'vps-password', label: L('imp.tab.vpsPwd'), icon: 'server' },
      { id: 'vps-key', label: L('imp.tab.vpsKey'), icon: 'key-round' }], function (id) { if (id === 'import') setMode(st.mode); else setTop(id); });
    /* 「导入」标签里的两种输入方式: 粘贴内容 / 手动填写一台 */
    el.sub = ui.seg(L('imp.sub.aria'), [{ v: 'import', label: L('imp.sub.paste'), icon: 'file-down' }, { v: 'manual', label: L('imp.sub.hand'), icon: 'plus' }], function (v) { el.sub.set(st.mode); setMode(v); });
    el.subRow = h('div', { class: 'imp-sub' }, el.sub.el);
    el.paneVps = h('div', { class: 'pane imp-vps', hidden: true });

    /* --- 导入 --- */
    el.ta = h('textarea', { class: 'ta', rows: 7, spellcheck: 'false', autocomplete: 'off', 'aria-label': L('imp.ta.aria'), placeholder: L('imp.ta.ph') });
    el.ta.addEventListener('input', liveDetect);
    ['dragover', 'dragenter'].forEach(function (ev) { el.ta.addEventListener(ev, function (e) { e.preventDefault(); el.ta.classList.add('drop'); }); });
    ['dragleave', 'drop'].forEach(function (ev) { el.ta.addEventListener(ev, function () { el.ta.classList.remove('drop'); }); });
    el.ta.addEventListener('drop', function (e) { e.preventDefault(); var f = e.dataTransfer && e.dataTransfer.files && e.dataTransfer.files[0]; if (f) readFile(f); });
    el.file = h('input', { type: 'file', accept: '.txt,.yaml,.yml,.json,.conf,.list,.sub,text/*,application/json', hidden: true, 'aria-label': L('imp.file.aria') });
    el.file.addEventListener('change', function () { if (el.file.files[0]) readFile(el.file.files[0]); el.file.value = ''; });
    el.pick = ui.btn(L('imp.pick'), { icon: 'folder-open' }); ui.act(el.pick, function () { el.file.click(); });
    el.clr = ui.btn(L('imp.clear'), { kind: 'ghost', icon: 'x' }); ui.act(el.clr, function () { el.ta.value = ''; resetRun(); liveDetect(); el.ta.focus(); });
    el.detect = h('span', { class: 'chip detect', hidden: true });
    el.paneImp = h('div', { class: 'pane' },
      h('p', { class: 'muted sm' }, L('imp.intro')),
      el.ta, el.file,
      h('div', { class: 'row wrap' }, el.pick, el.clr, el.detect));

    /* --- 手动 --- */
    buildManual();

    /* --- 过程 --- */
    el.stepOl = h('ol', { class: 'steps h' });
    el.stepMsg = h('div', { class: 'step-msg', 'aria-live': 'polite' });
    el.stepBox = h('div', { class: 'stepbox', hidden: true }, el.stepOl, el.stepMsg);
    el.job = h('div'); el.preview = h('div'); el.result = h('div');
    /* 功能开关 (GET /api/plan features.vps_deploy): 不可用时「密码 / 密钥」标签不是死按钮 —— 点击说明原因并可打开说明弹窗; Pro 功能带 Pro 小徽标 */
    function paintGate() {
      var f = TP.plan.feature('vps_deploy'), bd = f.pro && f.enabled ? TP.plan.badge('vps_deploy') : null;
      ['vps-password', 'vps-key'].forEach(function (id) {
        var tb = el.tabs.btn(id);
        el.tabs.avail(id, f.enabled ? '' : t('plan.gate.reason', { name: TP.plan.name('vps_deploy') }), f.enabled ? null : { label: t('plan.f.more'), fn: function () { TP.plan.explain('vps_deploy'); } });
        var old = tb.querySelector('.badge'); if (old) tb.removeChild(old);
        if (!f.enabled) tb.appendChild(ui.badge(L(f.comingSoon ? 'plan.soon' : 'plan.pro'), f.comingSoon ? 'info' : 'pro', 'lock'));
        else if (bd) tb.appendChild(TP.plan.badge('vps_deploy'));
      });
    }
    TP.on('plan', paintGate); paintGate(); TP.plan.load(false);
    el.tabSub = h('p', { class: 'imp-tabsub muted sm', 'aria-live': 'polite' });
    /* 「保存到云端」: 默认勾选 —— 这次添加的服务器 (和订阅) 加密后同步到我的账号, 其它电脑登录同一账号时自动恢复; 不勾选就只留在这台电脑上 */
    el.saveCb = h('input', { type: 'checkbox', checked: true });
    el.saveCb.addEventListener('change', function () { el.saveCb._touched = true; });
    el.saveNote = h('span', { class: 'muted sm imp-save-n' });
    el.saveBox = h('label', { class: 'chk-inline imp-save' }, el.saveCb, h('span', null, L('imp.save')), el.saveNote);
    function paintSave(d) { if (!el.saveCb._touched) el.saveCb.checked = !!d.checked; setText(el.saveNote, d.off ? t('imp.saveOff') : ''); el.saveNote.hidden = !d.off; }
    if (TP.sync && TP.sync.prime) TP.sync.prime().then(paintSave);
    el.root = h('div', { class: 'imp-in' }, el.tabs.el, el.tabSub, el.subRow, el.paneImp, el.paneMan, el.paneVps, el.stepBox, el.job, el.preview, el.result);

    api = ui.modal({
      title: t('imp.title'), icon: 'plus', iconKind: 'pri', size: 'lg', cls: 'imp', body: el.root,
      dirty: function () { return st.phase === 'preview' || (st.phase === 'idle' && hasInput()) || Object.keys(vps).some(function (k) { return vps[k].dirty(); }); },
      lock: function () { return st.phase === 'working' || st.phase === 'committing' || vpsBusy; },
      onClose: function () { wipe(); Object.keys(vps).forEach(function (k) { try { vps[k].wipe(); } catch (e) { /* 忽略 */ } }); cur = null; },
      actions: []
    });
    ses.api = api;
    syncSteps();
    if (st.top === 'import') setMode(st.mode); else setTop(st.top);
    footer();

    function hasInput() {
      if (el.ta.value.trim()) return true;
      return ['host', 'name', 'secret', 'secret2', 'user', 'pem', 'port'].some(function (k) { return mf[k] && String(mf[k].value || '').trim(); });
    }
    function wipe() {                                                // 关闭时不再保留解析出的凭据和表单里的密码
      st.sources = []; st.rows = [];
      ['secret', 'secret2', 'user', 'pem', 'host', 'name', 'sni', 'port'].forEach(function (k) { if (mf[k]) mf[k].value = ''; });
      el.ta.value = '';
    }

    function setMode(m) {
      st.mode = m === 'manual' ? 'manual' : 'import'; st.top = 'import';
      el.tabs.set('import'); el.sub.set(st.mode); paintTabSub();
      var idle = st.phase === 'idle';
      el.tabs.el.hidden = !idle; el.subRow.hidden = !idle; el.paneVps.hidden = true;
      el.paneImp.hidden = !idle || st.mode !== 'import'; el.paneMan.hidden = !idle || st.mode !== 'manual';
      if (st.mode === 'manual') prepManual();
      footer();
      setTimeout(function () { try { if (idle && st.top === 'import') (st.mode === 'manual' ? mf.host : el.ta).focus({ preventScroll: true }); } catch (e) { /* 忽略 */ } }, 40);
    }
    function paintTabSub() { setText(el.tabSub, t(st.top === 'vps-password' ? 'imp.tabsub.pwd' : st.top === 'vps-key' ? 'imp.tabsub.key' : 'imp.tabsub.import')); el.tabSub.hidden = st.phase !== 'idle'; }
    TP.on('lang', function () { if (el.tabSub && el.tabSub.isConnected) paintTabSub(); });
    /* 「我的服务器」两个标签: 面板由 TP.vps.pane 提供 (SSH 一键部署), 弹窗只负责标签 / 底部按钮 / 忙碌锁定 / 关闭时清除密码 */
    function setTop(id) {
      if (!TP.vps || !TP.vps.pane) { ui.toast(t('imp.vps.missing'), 'warn'); setMode(st.mode); return; }
      if (!TP.plan.feature('vps_deploy').enabled) { setMode(st.mode); TP.plan.explain('vps_deploy'); return; }       // 套餐不包含这项功能: 说明原因, 回到「导入」
      st.top = id; el.tabs.set(id); paintTabSub();
      el.subRow.hidden = true; el.paneImp.hidden = true; el.paneMan.hidden = true; el.paneVps.hidden = false;
      if (!vps[id]) {
        vps[id] = TP.vps.pane(id === 'vps-key' ? 'key' : 'password', {
          setActions: function (list) { if (st.top === id) api.setActions(list); },
          setBusy: function (b) { vpsBusy = !!b; api.setBusy(!!b); },
          setTabsHidden: function (b) { el.tabs.el.hidden = !!b; },
          close: function (v) { api.close(v); },
          goServers: function () { api.close('done'); TP.go('servers'); }
        });
        el.paneVps.appendChild(vps[id].el);
      }
      Object.keys(vps).forEach(function (k) { vps[k].el.hidden = k !== id; });
      vps[id].start();
    }
    ses.setMode = function (m) { var n = norm(m); if (n.top === 'import') setMode(n.mode); else setTop(n.top); };

    /* ---------- 底部按钮 (随阶段变化) ---------- */
    function footer() {
      if (st.top !== 'import') return;                                  // 「我的服务器」面板自己管理底部按钮
      var p = st.phase, list;
      if (p === 'idle') {
        list = [{ label: t('common.cancel'), cancel: true }];
        if (st.mode === 'manual') list.push({ label: t('imp.man.add'), kind: 'primary', icon: 'check', id: 'go', keep: true, onClick: function () { return manualSubmit().then(function () { return false; }); } });
        else list.push({ label: t('imp.recognize'), kind: 'primary', icon: 'search', id: 'go', keep: true, onClick: function () { return recognize().then(function () { return false; }); } });
      } else if (p === 'preview') {
        list = [{ label: t('imp.back'), id: 'back', keep: true, onClick: function () { backToInput(); return false; } },
          { label: t('imp.importN', { n: selCount() }), kind: 'primary', icon: 'check', id: 'go', keep: true, onClick: function () { return commitFlow().then(function () { return false; }); } }];
      } else if (p === 'done') {
        list = [{ label: t('imp.more'), id: 'more', keep: true, onClick: function () { resetRun(); setMode(st.mode); return false; } },
          { label: t('imp.toServers'), id: 'srv', onClick: function () { TP.go('servers'); } },
          { label: t('common.close'), kind: 'primary', id: 'close', cancel: true }];
      } else list = [];
      api.setActions(list);
      if (p === 'idle' || p === 'preview') api.foot.insertBefore(el.saveBox, api.foot.firstChild);        // 底部左侧: 「保存到云端」
      api.setBusy(p === 'working' || p === 'committing');
      if (p === 'preview') refresh();
    }
    function backToInput() { resetRun(); setMode(st.mode); }

    function resetRun() {
      st.phase = 'idle'; st.sources = []; st.rows = []; st.filter = '';
      steps.forEach(function (s) { s.state = 'todo'; s.note = ''; }); syncSteps();
      TP.clear(el.preview); TP.clear(el.result); TP.clear(el.job); el.preview.hidden = false;
      el.stepBox.hidden = true; setMsg('');
      setMode(st.mode);
    }

    /* ---------- 实时识别提示 ---------- */
    function liveDetect() {
      clearTimeout(detTimer);
      detTimer = setTimeout(function () {
        var text = el.ta.value, c, parts = [], f, bad = false;
        if (!text.trim()) { el.detect.hidden = true; return; }
        c = TPImporter.classify(text);
        if (c.urls.length) parts.push(t('imp.detect.urls', { n: c.urls.length }));
        if (c.content.trim()) {
          f = TPImporter.detectFormat(c.content);
          bad = f === 'unknown';
          parts.push(f === 'links' ? t('imp.detect.links', { n: c.content.split('\n').filter(function (l) { return /:\/\//.test(l); }).length }) : t('imp.fmt.' + f));
        }
        setText(el.detect, t('imp.detect.is', { list: parts.join(' + ') })); el.detect.hidden = false;
        el.detect.classList.toggle('bad', bad);
      }, 200);
    }
    function readFile(f) {
      if (f.size > 5 * 1024 * 1024) { ui.toast(t('imp.file.big'), 'warn'); return; }
      var rd = new FileReader();
      rd.onload = function () { el.ta.value = String(rd.result || ''); liveDetect(); ui.toast(t('imp.file.loaded', { name: f.name, size: fmt.bytes(f.size) }), 'ok'); };
      rd.onerror = function () { ui.toast(t('imp.file.fail'), 'err'); };
      rd.readAsText(f);
    }

    /* ================= 识别流程 ================= */
    function hostOf(url) { var u = TPImporter.parseUri(url); return u ? String(u.host || '').toLowerCase() : ''; }
    function defaultSubName(url) {
      var host = hostOf(url), subs = (S.state && S.state.subs) || [], i;
      for (i = 0; i < subs.length; i++) if (subs[i].host === host) return subs[i].name;     // 同一个订阅: 沿用原名, 导入时整体替换
      return cleanSubName(host);
    }
    function tagsExcludingSub(name) { return TP.servers().filter(function (s) { return s.sub !== name; }).map(function (s) { return s.tag; }); }
    function describeFormat(c) {
      var p = [];
      if (c.urls.length) p.push(t('imp.detect.urlsX', { n: c.urls.length }));
      if (c.content.trim()) p.push(t('imp.fmt.' + TPImporter.detectFormat(c.content)));
      return p.join(' + ');
    }

    async function recognize() {
      var text = el.ta.value;
      if (!text.trim()) { ui.toast(t('imp.needInput'), 'warn'); el.ta.focus(); return; }
      var why = TP.why.helper(); if (why) { ui.toast(why, 'warn'); return; }
      resetRun(); st.phase = 'working'; el.stepBox.hidden = false; el.paneImp.hidden = true; el.tabs.el.hidden = true; footer();
      var sources = [], nSrv = 0;
      try {
        setStep(0, 'run'); setMsg(t('imp.msg.detecting'));
        await TP.sleep(150);
        var c = TPImporter.classify(text);
        if (!c.urls.length && !c.content.trim()) throw new Error(t('imp.err.nothing'));
        setStep(0, 'done', describeFormat(c));
        var used = allTags().slice(), i, nFail = 0;

        /* 订阅链接: 下载 + 解析 */
        if (c.urls.length) {
          for (i = 0; i < c.urls.length; i++) {
            var url = c.urls[i], name = defaultSubName(url), pre = c.urls.length > 1 ? '(' + (i + 1) + '/' + c.urls.length + ') ' : '';
            var src = { kind: 'sub', url: url, host: hostOf(url), name: name, save: true, servers: [], skipped: [], usage: null, interval: 0, error: '' };
            sources.push(src);
            try {
              var others = tagsExcludingSub(name), ex = others.concat(used.filter(function (x) { return others.indexOf(x) < 0 && allTags().indexOf(x) < 0; }));
              var own = {}; TP.servers().forEach(function (s) { if (s.sub === name) own[s.tag] = s.role; });
              var r = await imp.fetchSub({
                url: url, existingTags: ex,
                onStage: function (stage, msg) {
                  if (stage === 'download') { setStep(1, 'run', c.urls.length > 1 ? (i + 1) + '/' + c.urls.length : ''); setStep(2, 'todo'); }
                  else { setStep(1, 'done'); setStep(2, 'run'); }
                  setMsg(pre + msg);
                },
                onNote: function (m) { setMsg(pre + m); }
              });
              src.servers = r.servers; src.skipped = r.skipped; src.usage = r.usage; src.interval = r.interval; src.format = r.format; src.ua = r.ua;
              src.servers.forEach(function (s) { s.role = own[s.outbound.tag] || 'auto'; s.sel = !s.warn; used.push(s.outbound.tag); });
            } catch (e) { if (e && e.kind === 'auth') throw e; src.error = TP.errMsg(e); }
          }
          sources.forEach(function (x) { if (x.error) nFail++; });
          setStep(1, nFail === c.urls.length ? 'error' : 'done', nFail ? t('imp.step.failedN', { n: nFail }) : '');
        } else { setStep(1, 'skip'); }

        /* 其余内容: 直接解析 */
        if (c.content.trim()) {
          setStep(2, 'run'); setMsg(t('imp.msg.parsing'));
          await TP.sleep(120);
          var p = TPImporter.parse(c.content, { role: 'auto', existingTags: used });
          var csrc = { kind: 'content', url: '', host: '', name: '', save: false, servers: p.servers, skipped: p.skipped, usage: null, format: p.format, error: '' };
          csrc.servers.forEach(function (s) { s.role = 'auto'; s.sel = !s.warn; });
          sources.push(csrc);
        }
        sources.forEach(function (x) { nSrv += x.servers.length; });
        st.sources = sources;
        if (!nSrv) {
          var dlFail = c.urls.length > 0 && nFail === c.urls.length && !c.content.trim();      // 全是下载失败 (不是内容有问题)
          setStep(2, dlFail ? 'todo' : 'error'); st.phase = 'idle';
          setMsg(t(dlFail ? 'imp.err.dlFailed' : 'imp.err.noServers'), 'bad-t');
          renderNoResult(); footer(); retryUi();
          return;
        }
        setStep(2, 'done', t('imp.step.nodes', { n: nSrv }));
        setStep(3, 'run'); setMsg(t('imp.msg.confirm'));
        st.phase = 'preview';
        buildPreview(); footer();
      } catch (e) {
        st.phase = 'idle';
        steps.forEach(function (s) { if (s.state === 'run') s.state = 'error'; }); syncSteps();
        setMsg(e && e.kind === 'auth' ? '' : TP.errMsg(e), 'bad-t');
        footer(); retryUi();
      }
    }
    /* 没有结果时让用户能直接回到输入框修改 */
    function retryUi() { el.paneImp.hidden = false; el.tabs.el.hidden = false; el.tabs.set(st.mode); }

    /* 一个有效结果都没有: 给出原因与建议 */
    function renderNoResult() {
      var box = TP.clear(el.preview), any = false;
      st.sources.forEach(function (s) {
        if (s.error) { any = true; box.appendChild(h('p', { class: 'hint bad' }, (s.host ? t('imp.sub.of', { host: s.host }) + ' ' : '') + s.error)); }
        else if (s.kind === 'sub') { any = true; box.appendChild(h('p', { class: 'hint warn' }, t('imp.err.emptySub', { host: s.host || '' }))); }
        if (s.skipped.length) box.appendChild(skippedBlock(s.skipped));
      });
      if (!any) box.appendChild(h('p', { class: 'hint warn' }, t('imp.err.nothingUsable')));
    }
    function skippedBlock(list) {
      var ul = h('ul', { class: 'skip-list' });
      list.slice(0, 300).forEach(function (s) { ul.appendChild(h('li', null, h('b', null, s.name || t('imp.noName')), h('span', { class: 'muted' }, ' — ' + importerText(s.reason)))); });
      if (list.length > 300) ul.appendChild(h('li', { class: 'muted' }, t('imp.moreN', { n: list.length - 300 })));
      return h('div', { class: 'skipped' }, ui.detailsBtn(t('imp.skipped', { n: list.length }), t('imp.skipped', { n: list.length }), function () { return ul; }));
    }

    /* ================= 预览确认 ================= */
    function roleSelect(type, val) {
      var sel = h('select', { class: 'sel sm', 'aria-label': t('imp.role.aria') }, ROLES.map(function (k) {
        var o = TP.opt(k, k === 'dl' && !canDl(type) ? t('servers.role.dlSuffix', { name: TP.name.role(k) }) : TP.name.role(k));
        if (k === 'dl' && !canDl(type)) { o.disabled = true; o.title = t('servers.dlOnly'); }
        return o;
      }));
      sel.value = val; if (sel.value !== val) sel.value = 'auto';
      return sel;
    }
    function selCount() { var n = 0; st.sources.forEach(function (s) { s.servers.forEach(function (x) { if (x.sel) n++; }); }); return n; }

    function buildPreview() {
      var box = TP.clear(el.preview), rows = st.rows = [], total = 0, skippedN = 0, types = {};
      el.preview.hidden = false;
      st.sources.forEach(function (s) { total += s.servers.length; skippedN += s.skipped.length; s.servers.forEach(function (sv) { var l = typeLabel(sv.outbound); types[l] = (types[l] || 0) + 1; }); });

      el.sum = h('b');
      el.allCb = h('input', { type: 'checkbox', 'aria-label': t('imp.pv.allAria') });
      el.allCb.addEventListener('change', function () { rows.forEach(function (r) { if (!r.tr.hidden) { r.cb.checked = el.allCb.checked; r.sv.sel = el.allCb.checked; } }); refresh(); });
      el.typeSel = h('select', { class: 'sel sm', 'aria-label': t('imp.pv.typeAria') }, TP.opt('', t('imp.pv.allTypes', { n: total })));
      Object.keys(types).sort(function (a, b) { return types[b] - types[a]; }).forEach(function (l) { el.typeSel.appendChild(TP.opt(l, l + ' (' + types[l] + ')')); });
      el.typeSel.value = st.filter;
      el.typeSel.addEventListener('change', function () { st.filter = el.typeSel.value; refresh(); });
      el.bulk = h('select', { class: 'sel sm', 'aria-label': t('imp.pv.bulkAria') }, ROLES.map(function (k) { return TP.opt(k, TP.name.role(k)); }));
      el.bulkBtn = ui.btn(t('common.apply'), { sm: true });
      ui.act(el.bulkBtn, function () {
        var n = 0;
        rows.forEach(function (r) { if (r.tr.hidden) return; if (el.bulk.value === 'dl' && !canDl(r.sv.outbound.type)) return; r.sv.role = el.bulk.value; r.sel.value = el.bulk.value; n++; });
        ui.toast(t('imp.pv.bulkDone', { n: n, role: TP.name.role(el.bulk.value) }), 'ok', 2000);
      });
      box.appendChild(h('div', { class: 'pv-head' },
        h('div', null, h('b', null, t('imp.pv.found', { n: total })), skippedN ? h('span', { class: 'muted sm' }, ' · ' + t('imp.pv.skippedN', { n: skippedN })) : null, h('div', { class: 'sm' }, el.sum)),
        h('div', { class: 'pv-ctl' },
          h('label', { class: 'chk-all' }, el.allCb, h('span', null, t('imp.pv.all'))),
          el.typeSel,
          h('span', { class: 'pv-bulk' }, h('span', { class: 'muted sm' }, t('imp.pv.bulk')), el.bulk, el.bulkBtn))));
      box.appendChild(h('p', { class: 'hint' + (TP.hasRole('pin') ? '' : ' warn') }, (TP.hasRole('pin') ? '' : t('imp.pv.noPin') + ' ') + t('imp.pv.hintPin')));

      /* 每个来源一块 */
      st.sources.forEach(function (src) {
        var blk = h('div', { class: 'pv-src' });
        if (src.kind === 'sub') {
          var u = fmt.usage(src.usage);
          blk.appendChild(h('div', { class: 'pv-src-h' },
            h('b', null, t('imp.sub.of', { host: src.host })), src.format ? h('span', { class: 'chip' }, t('imp.fmt.' + src.format)) : null,
            src.ua && src.ua !== 'auto' ? h('span', { class: 'chip' }, t('imp.sub.usedUa', { name: t(UA_KEY[src.ua]) })) : null,
            u ? h('span', { class: 'chip ok' }, u) : null,
            src.interval ? h('span', { class: 'muted sm' }, t('imp.sub.every', { n: src.interval })) : null));
          if (src.error) blk.appendChild(h('p', { class: 'hint bad' }, t('imp.sub.failed', { reason: src.error })));
          if (src.servers.length) {
            var cb = h('input', { type: 'checkbox', 'aria-label': t('imp.sub.saveAria') }), nm = h('input', { class: 'inp sm', type: 'text', value: src.name, maxlength: 40, 'aria-label': t('imp.sub.nameAria'), spellcheck: 'false' }), er = h('span', { class: 'fld-h bad-t', hidden: true });
            cb.checked = src.save;
            var note = h('p', { class: 'muted sm' }, t('imp.sub.saveNote'));
            var sync = function () {
              src.save = cb.checked; src.name = nm.value.trim(); nm.readOnly = !cb.checked; note.hidden = !cb.checked;
              var bad = cb.checked && !SUB_NAME_RE.test(src.name);
              er.hidden = !bad; setText(er, bad ? t('imp.sub.nameBad') : ''); src.badName = bad; refresh();
            };
            cb.addEventListener('change', sync); nm.addEventListener('input', sync);
            blk.appendChild(h('div', { class: 'pv-save' },
              h('label', { class: 'chk-inline' }, cb, h('span', null, t('imp.sub.save'))),
              h('label', { class: 'pv-name' }, h('span', { class: 'muted sm' }, t('imp.sub.name')), nm), er));
            blk.appendChild(note);
          }
        } else {
          blk.appendChild(h('div', { class: 'pv-src-h' }, h('b', null, t('imp.pv.pasted')), h('span', { class: 'chip' }, t('imp.fmt.' + src.format))));
        }
        if (src.servers.length) blk.appendChild(table(src, rows));
        if (src.skipped.length) blk.appendChild(skippedBlock(src.skipped));
        box.appendChild(blk);
      });
      el.errBox = h('div', { class: 'hint bad', hidden: true });
      box.appendChild(el.errBox);
      refresh();
    }

    function table(src, rows) {
      var tb = h('tbody');
      src.servers.forEach(function (sv) {
        var ob = sv.outbound;
        var cb = h('input', { type: 'checkbox', 'aria-label': t('imp.pv.pickAria', { tag: ob.tag }) }); cb.checked = !!sv.sel;
        var sel = roleSelect(ob.type, sv.role);
        var tr = h('tr', { class: sv.warn ? 'has-warn' : '' },
          h('td', { class: 'c-cb' }, cb),
          h('td', { class: 'c-name' }, h('div', { class: 'srv-n' }, ob.tag), sv.warn ? h('div', { class: 'warn-t sm' }, ui.icon('warning', 13, 'ci'), ' ' + t('imp.pv.warnDefault', { warn: importerText(sv.warn) })) : null),
          h('td', { 'data-l': t('servers.col.type') }, h('span', { class: 'chip' }, typeLabel(ob))),
          h('td', { class: 'mono sm', 'data-l': t('servers.col.addr') }, ob.server + ':' + ob.server_port),
          h('td', { class: 'c-role', 'data-l': t('servers.col.role') }, sel));
        cb.addEventListener('change', function () { sv.sel = cb.checked; refresh(); });
        sel.addEventListener('change', function () { sv.role = sel.value; });
        rows.push({ tr: tr, cb: cb, sel: sel, sv: sv, src: src });
        tb.appendChild(tr);
      });
      var pg = ui.pager('imp.preview', { def: 20 }); src._pg = pg; pg.onChange(function () { refresh(); });          // 预览表格分页 (订阅里可能有上百个节点)
      return h('div', { class: 'pv-tblbox' }, h('div', { class: 'pv-scroll' }, h('table', { class: 'tbl pv-tbl' },
        h('thead', null, h('tr', null, h('th', { class: 'c-cb', scope: 'col' }, t('imp.col.sel')), ['servers.col.name', 'servers.col.type', 'servers.col.addr', 'servers.col.role'].map(function (k) { return h('th', { scope: 'col' }, t(k)); }))), tb)), pg.el);
    }

    /* 更新筛选 / 计数 / 导入按钮 */
    function refresh() {
      var rows = st.rows, vis = 0, visSel = 0, sel = 0, bad = false;
      rows.forEach(function (r) {
        r._f = !!st.filter && typeLabel(r.sv.outbound) !== st.filter;                // 被类型筛选排除
        if (!r._f) { vis++; if (r.sv.sel) visSel++; }
        if (r.sv.sel) sel++;
      });
      st.sources.forEach(function (sc) {                                              // 每个来源一个分页器: 只显示当前页的行 (全选 / 计数仍按筛选后的全部行)
        if (!sc._pg) return;
        var vr = rows.filter(function (r) { return r.src === sc && !r._f; }), rg = sc._pg.update(vr.length);
        rows.forEach(function (r) { if (r.src === sc && r._f) r.tr.hidden = true; });
        vr.forEach(function (r, i) { r.tr.hidden = !(i >= rg.start && i < rg.end); });
      });
      if (el.allCb) { el.allCb.checked = vis > 0 && visSel === vis; el.allCb.indeterminate = visSel > 0 && visSel < vis; }
      st.sources.forEach(function (s) { if (s.badName && s.save && s.servers.some(function (x) { return x.sel; })) bad = true; });
      if (el.sum) setText(el.sum, t('imp.pv.selected', { sel: sel, total: rows.length }) + (st.filter ? ' · ' + t('imp.pv.shown', { n: vis }) : ''));
      var go = api && api.getBtn('go');
      if (go && st.phase === 'preview') {
        ui.setBtn(go, t('imp.importN', { n: sel }));
        ui.avail(go, !sel ? t('imp.pv.pickOne') : bad ? t('imp.sub.nameBad') : '');
      }
    }

    /* ================= 写入并应用 ================= */
    function buildGroups() {
      var groups = [], oneoff = [];
      st.sources.forEach(function (src) {
        var sel = src.servers.filter(function (s) { return s.sel; });
        if (!sel.length) return;                                                 // 一个都没选: 绝不对订阅做「整体替换」
        if (src.kind === 'sub' && src.save) groups.push({ sub: src.name, mode: 'replace', url: src.url, servers: sel });
        else oneoff.push.apply(oneoff, sel);
      });
      if (oneoff.length) groups.push({ sub: '', mode: 'merge', url: '', servers: oneoff });
      return groups;
    }
    function groupLabel(g) { return g.sub ? t('imp.group.sub', { name: g.sub }) : t('imp.group.servers', { n: g.servers.length }); }

    /* 第二次确认: 汇总「将会改变什么」 */
    async function commitFlow() {
      var groups = buildGroups();
      if (!groups.length) { ui.toast(t('imp.pv.pickOne'), 'warn'); return; }
      var why = TP.why.helper(); if (why) { ui.toast(why, 'warn'); return; }
      var lines = [], cnt = { pin: 0, auto: 0, dl: 0, off: 0 }, total = 0;
      groups.forEach(function (g) {
        total += g.servers.length; g.servers.forEach(function (s) { cnt[s.role] = (cnt[s.role] || 0) + 1; });
        if (g.sub) {
          var old = TP.servers().filter(function (s) { return s.sub === g.sub; }).length;
          lines.push(t(old ? 'imp.cf.subReplace' : 'imp.cf.subNew', { name: g.sub, n: g.servers.length, old: old }));
        } else lines.push(t('imp.cf.single', { n: g.servers.length }));
      });
      lines.push(t('imp.cf.roles', { pin: cnt.pin, auto: cnt.auto, dl: cnt.dl, off: cnt.off }));
      lines.push(t(el.saveCb.checked ? 'imp.cf.saveYes' : 'imp.cf.saveNo'));
      lines.push(t('imp.cf.apply'));
      var ok = await ui.confirmDialog({ title: t('imp.cf.title'), message: t('imp.cf.msg', { n: total }), detail: lines, confirmText: t('imp.cf.go') });
      if (!ok) return;
      el.errBox.hidden = true;
      var r = await runCommit(groups);
      if (!r.ok && el.errBox) { el.errBox.hidden = false; setText(el.errBox, t('imp.err.commit', { reason: TP.errMsg(r.error) })); }
    }

    /* 写入一批分组, 在弹窗内显示进度; 成功后展示结果与「测速」入口 */
    async function runCommit(groups) {
      st.phase = 'committing'; footer();
      el.stepBox.hidden = false;
      setStep(3, st.mode === 'manual' ? 'skip' : 'done'); setStep(4, 'run'); setMsg(t('imp.msg.writing'));
      var card = ui.taskCard(t('imp.card.applying'), { horizontal: false });
      TP.clear(el.job); el.job.appendChild(card.el); card.set({ pct: 0, msg: t('imp.msg.submitting') });
      el.preview.hidden = true; el.paneImp.hidden = true; el.paneMan.hidden = true; el.tabs.el.hidden = true;             // 提交期间收起预览, 避免重复点击
      var total = { added: 0, replaced: 0, removed: 0, errors: [] }, tags = [], gi, g, res, base, span, save = el.saveCb.checked ? 1 : 0;
      try {
        for (gi = 0; gi < groups.length; gi++) {
          g = groups[gi]; base = gi / groups.length * 100; span = 100 / groups.length;
          card.set({ pct: base, msg: t('imp.msg.writingGroup', { label: groupLabel(g) }) });
          if (g.sub && g.url) await TP.helper('POST', '/api/sub/save', { q: { name: g.sub, save: save }, body: g.url });
          res = await TP.helper('POST', '/api/servers/import', { q: { sub: g.sub, mode: g.mode, save: save }, body: TPImporter.toJSONL(g.servers, g.sub) });
          total.added += +res.added || 0; total.replaced += +res.replaced || 0; total.removed += +res.removed || 0;
          total.errors = total.errors.concat(res.errors || []);
          g.servers.forEach(function (s) { tags.push(s.outbound.tag); });
          if (res.job) {
            await TP.jobs.follow(res.job, { fromJob: (function (b, sp) { return function (j) { card.set({ pct: b + (+j.pct || 0) / 100 * sp, msg: j.msg || t('job.applying'), steps: j.steps || [] }); }; })(base, span) });
          }
        }
      } catch (e) {
        card.setTitle(t('imp.card.failed')); card.fail(TP.errMsg(e)); setStep(4, 'error'); setMsg(t('imp.msg.writeFail'), 'bad-t');
        el.preview.hidden = false;
        if (st.mode === 'manual') { st.sources = []; st.rows = []; st.phase = 'idle'; el.paneMan.hidden = false; el.tabs.el.hidden = false; }
        else st.phase = 'preview';
        footer(); TP.afterApply();
        if (!(e && e.kind === 'auth')) ui.toast(t('imp.toast.fail', { reason: TP.errMsg(e) }), 'err');
        return { ok: false, error: e };
      }
      card.setTitle(t('imp.card.done')); card.done(t('imp.msg.applied')); setStep(4, 'done');
      st.phase = 'done'; TP.clear(el.preview); el.preview.hidden = false;
      st.sources = []; st.rows = [];                                      // 不在内存里继续保留解析出的凭据
      if (st.mode !== 'manual') el.ta.value = '';
      el.detect.hidden = true;
      setMsg(t('imp.msg.finished'));
      footer();
      ui.toast(t('imp.toast.done', { n: tags.length }), 'ok');
      TP.afterApply();
      await TP.loadState();
      renderDone(total, tags);
      return { ok: true, total: total, tags: tags };
    }

    function renderDone(total, tags) {
      var box = TP.clear(el.result);
      var line = t('imp.done.line', { added: total.added, replaced: total.replaced }) + (total.removed ? ' · ' + t('imp.done.removed', { n: total.removed }) : '');
      var noPin = !TP.hasRole('pin');
      var testBtn = ui.btn(t('imp.done.test', { n: tags.length }), { kind: 'primary', icon: 'speed' });
      var tBar = ui.bar(); tBar.el.hidden = true;
      ui.act(testBtn, async function () {
        setStep(5, 'run', ''); tBar.el.hidden = false; tBar.set(null);
        for (var k = 0; k < 4 && !tags.some(function (x) { return S.proxies[x]; }); k++) { await TP.loadProxies(); if (!tags.some(function (x) { return S.proxies[x]; })) await TP.sleep(1000); }
        var r = await TP.V.servers.testTags(tags, function (i, n, tag) { tBar.set(i / n * 100); setMsg(tag ? t('servers.test.progress', { i: i + 1, n: n, tag: tag }) : ''); });
        if (r) { tBar.set(100, 'ok'); setStep(5, 'done', r.best ? r.best.ms + ' ms' : ''); setMsg(t('servers.test.done', { ok: r.ok, n: r.total }) + (r.best ? ' · ' + t('servers.test.best', { tag: r.best.tag, ms: r.best.ms }) : '')); }
        else { tBar.el.hidden = true; setStep(5, 'skip'); }
        ui.setBtn(testBtn, t('servers.test.again'));
      });
      box.appendChild(h('div', { class: 'done-box' },
        h('div', { class: 'done-t' }, h('span', { class: 'ck ok' }, ui.icon('check', 13)), h('b', null, t('imp.done.title')), h('span', { class: 'muted' }, line)),
        total.errors.length ? h('div', { class: 'skipped' }, ui.detailsBtn(t('imp.done.ignored', { n: total.errors.length }), t('imp.done.ignored', { n: total.errors.length }), function () { return h('ul', { class: 'skip-list' }, total.errors.slice(0, 100).map(function (e) { return h('li', null, String(e)); })); })) : null,
        noPin ? h('p', { class: 'hint warn' }, t('imp.done.noPin')) : null,
        tBar.el,
        h('div', { class: 'row wrap' }, testBtn)));
    }

    /* ================= 手动添加单个服务器 ================= */
    function buildManual() {
      mf.type = h('select', { class: 'sel', 'aria-label': L('imp.man.type') }, MTYPES.map(function (x) { return TP.opt(x.v, x.label); }));
      mf.name = h('input', { class: 'inp', type: 'text', 'aria-label': L('imp.man.nameOpt'), maxlength: 60, placeholder: L('imp.man.namePh'), autocomplete: 'off' });
      mf.host = h('input', { class: 'inp', type: 'text', 'aria-label': L('imp.man.host'), placeholder: L('imp.man.hostPh'), autocomplete: 'off', spellcheck: 'false', 'aria-required': 'true' });
      mf.port = h('input', { class: 'inp', type: 'text', 'aria-label': L('imp.man.port'), inputmode: 'numeric', placeholder: '443', autocomplete: 'off', 'aria-required': 'true' });
      mf.user = h('input', { class: 'inp', type: 'text', 'aria-label': L('imp.man.userOpt'), autocomplete: 'off', spellcheck: 'false' });
      mf.secret = h('input', { class: 'inp', type: 'password', autocomplete: 'new-password', spellcheck: 'false' });
      mf.secret2 = h('input', { class: 'inp', type: 'password', 'aria-label': L('imp.man.password'), autocomplete: 'new-password', spellcheck: 'false' });
      mf.method = h('select', { class: 'sel', 'aria-label': L('imp.man.method') }, SS_METHODS.map(function (m) { return TP.opt(m, m); })); mf.method.value = 'aes-256-gcm';
      mf.tls = h('input', { type: 'checkbox', 'aria-label': L('imp.man.tls') });
      mf.sni = h('input', { class: 'inp', type: 'text', 'aria-label': L('imp.man.sni'), placeholder: L('imp.man.sniPh'), autocomplete: 'off', spellcheck: 'false' });
      mf.skip = h('input', { type: 'checkbox', 'aria-label': L('imp.man.skipCert') });
      mf.role = h('select', { class: 'sel', 'aria-label': L('imp.man.role') }, ROLES.map(function (k) { return TP.opt(k, t('name.role.' + k)); }));
      mf.pem = h('textarea', { class: 'ta sm', 'aria-label': L('imp.man.pem'), rows: 4, spellcheck: 'false', placeholder: '-----BEGIN CERTIFICATE-----\n…\n-----END CERTIFICATE-----' });
      mf.err = h('div', { class: 'fld-h bad-t', role: 'alert', hidden: true });
      mf.secretLbl = h('span', { class: 'fld-l' });
      mf.w = {
        user: ui.field(L('imp.man.userOpt'), mf.user),
        secret: h('label', { class: 'fld' }, mf.secretLbl, mf.secret),
        secret2: ui.field(L('imp.man.password'), mf.secret2),
        method: ui.field(L('imp.man.method'), mf.method),
        tls: h('label', { class: 'chk-inline fld' }, mf.tls, h('span', null, L('imp.man.tls'))),
        sni: ui.field(L('imp.man.sni'), mf.sni, L('imp.man.sniHint')),
        skip: h('label', { class: 'chk-inline fld' }, mf.skip, h('span', null, L('imp.man.skipCert'))),
        pem: h('div', { class: 'fld pem' }, h('span', { class: 'fld-l' }, L('imp.man.pemTitle')), h('p', { class: 'muted sm' }, L('imp.man.pemHelp')), mf.pem)
      };
      var form = h('form', { class: 'mform', novalidate: true },
        h('div', { class: 'fgrid' },
          ui.field(L('imp.man.type'), mf.type), ui.field(L('imp.man.nameOpt'), mf.name), ui.field(L('imp.man.host'), mf.host), ui.field(L('imp.man.port'), mf.port),
          mf.w.user, mf.w.secret, mf.w.secret2, mf.w.method, ui.field(L('imp.man.role'), mf.role, L('imp.man.roleHint'))),
        mf.w.tls, mf.w.sni, mf.w.skip, mf.w.pem, mf.err,
        h('p', { class: 'muted sm' }, L('imp.man.privacy')));
      form.addEventListener('submit', function (ev) { ev.preventDefault(); var b = api && api.getBtn('go'); if (b) b.click(); });
      mf.type.addEventListener('change', applyType);
      mf.tls.addEventListener('change', applyType);
      el.paneMan = h('div', { class: 'pane', hidden: true }, h('p', { class: 'muted sm' }, L('imp.man.intro')), form);
      applyType();
    }
    function curType() { var v = mf.type.value; return MTYPES.filter(function (x) { return x.v === v; })[0]; }
    function applyType() {
      var ty = curType(), tlsOn = ty.tls || (ty.tlsOpt && mf.tls.checked);
      mf.w.user.hidden = !ty.user; mf.w.method.hidden = !ty.method; mf.w.secret2.hidden = !ty.secret2; mf.w.tls.hidden = !ty.tlsOpt;
      mf.w.sni.hidden = !tlsOn; mf.w.skip.hidden = !tlsOn; mf.w.pem.hidden = !tlsOn;
      setText(mf.secretLbl, t(ty.secret)); mf.secret.setAttribute('aria-label', t(ty.secret));
      mf.port.placeholder = String(ty.port);
    }
    function prepManual() { mf.role.value = TP.hasRole('pin') ? 'auto' : 'pin'; mf.err.hidden = true; applyType(); }

    function hostPart(x) { return x.indexOf(':') >= 0 && x.charAt(0) !== '[' ? '[' + x + ']' : x; }
    function buildLink(f) {    // 凭据一律百分号编码, 再交给 TPImporter.parse, 保证与导入的结果一致
      var ty = f.type, hp = hostPart(f.host) + ':' + f.port, q = [], frag = f.name ? '#' + enc(f.name) : '', cred;
      if (f.sni) q.push('sni=' + enc(f.sni));
      if (f.skip) q.push('insecure=1');
      var qs = q.length ? '?' + q.join('&') : '';
      switch (ty) {
        case 'trojan': return 'trojan://' + enc(f.secret) + '@' + hp + qs + frag;
        case 'hysteria2': return 'hysteria2://' + enc(f.secret) + '@' + hp + qs + frag;
        case 'tuic': return 'tuic://' + enc(f.secret) + ':' + enc(f.secret2) + '@' + hp + qs + frag;
        case 'vless': return 'vless://' + enc(f.secret) + '@' + hp + '?' + ['security=tls', 'type=tcp'].concat(q).join('&') + frag;
        case 'shadowsocks': return 'ss://' + enc(f.method) + ':' + enc(f.secret) + '@' + hp + frag;
        case 'http': cred = (f.user || f.secret) ? enc(f.user) + ':' + enc(f.secret) + '@' : ''; return (f.tls ? 'https' : 'http') + '://' + cred + hp + (f.tls ? qs : '') + frag;
        case 'socks': cred = (f.user || f.secret) ? enc(f.user) + ':' + enc(f.secret) + '@' : ''; return 'socks5://' + cred + hp + frag;
      }
      return '';
    }
    function validHost(x) { return /^[A-Za-z0-9._-]+$/.test(x) || /^[0-9A-Fa-f:]+$/.test(x) || /^\[[0-9A-Fa-f:]+\]$/.test(x); }
    function mErr(msg, focus) { mf.err.hidden = !msg; setText(mf.err, msg || ''); if (focus) focus.focus(); return !msg; }

    async function manualSubmit() {
      var ty = curType(), tlsOn = ty.tls || (ty.tlsOpt && mf.tls.checked);
      var f = { type: ty.v, name: mf.name.value.trim(), host: mf.host.value.trim().replace(/^\[|\]$/g, ''), port: parseInt(mf.port.value.trim() || String(ty.port), 10),
        user: mf.user.value.trim(), secret: mf.secret.value, secret2: mf.secret2.value, method: mf.method.value, tls: !!(ty.tlsOpt && mf.tls.checked),
        sni: tlsOn ? mf.sni.value.trim() : '', skip: !!(tlsOn && mf.skip.checked), role: mf.role.value, pem: tlsOn ? mf.pem.value.trim() : '' };
      var why = TP.why.helper(); if (why) { ui.toast(why, 'warn'); return; }
      if (!f.host || !validHost(f.host)) { mErr(t('imp.man.err.host'), mf.host); return; }
      if (!(f.port >= 1 && f.port <= 65535)) { mErr(t('imp.man.err.port'), mf.port); return; }
      if (!ty.user && !f.secret) { mErr(t('imp.man.err.need', { what: t(ty.secret) }), mf.secret); return; }
      if (ty.secret2 && !f.secret2) { mErr(t('imp.man.err.need', { what: t('imp.man.password') }), mf.secret2); return; }
      if ((ty.v === 'vless' || ty.v === 'tuic') && !/^[0-9a-fA-F-]{32,40}$/.test(f.secret)) { mErr(t('imp.man.err.uuid'), mf.secret); return; }
      if (f.role === 'dl' && !canDl(ty.v)) { mErr(t('imp.man.err.dl'), mf.role); return; }
      if (f.pem && !/-----BEGIN CERTIFICATE-----[\s\S]+-----END CERTIFICATE-----/.test(f.pem)) { mErr(t('imp.man.err.pem'), mf.pem); return; }
      mErr('');

      var link = buildLink(f), res = TPImporter.parse(link, { role: f.role, existingTags: allTags() }), pem = f.pem;
      link = '';
      if (!res.servers.length) { mErr(res.skipped[0] ? importerText(res.skipped[0].reason) : t('imp.man.err.build')); return; }
      var sv = res.servers[0]; sv.role = f.role; sv.sel = true;
      var summary = [t('imp.man.cf.type', { type: ty.label }), t('imp.man.cf.addr', { addr: hostPart(f.host) + ':' + f.port }), t('imp.man.cf.role', { role: TP.name.role(f.role) })];
      if (pem) summary.push(t('imp.man.cf.cert'));
      summary.push(t(el.saveCb.checked ? 'imp.cf.saveYes' : 'imp.cf.saveNo'));
      summary.push(t('imp.cf.apply'));
      var ok = await ui.confirmDialog({ title: t('imp.man.cf.title'), message: t('imp.man.cf.msg', { tag: sv.outbound.tag }), detail: summary, confirmText: t('imp.cf.go') });
      f = null;
      if (!ok) return;                                                    // 取消: 表单保持原样, 用户可以继续修改
      ['secret', 'secret2', 'user', 'pem', 'host', 'name', 'sni', 'port'].forEach(function (k) { mf[k].value = ''; });       // 确认后立即清空输入框

      resetRun(); st.mode = 'manual'; st.phase = 'working'; el.stepBox.hidden = false; el.paneMan.hidden = true; el.tabs.el.hidden = true; footer();
      setStep(0, 'done', t('imp.man.typed')); setStep(1, 'skip'); setStep(2, 'done', t('imp.step.nodes', { n: 1 }));
      if (pem) {
        setMsg(t('imp.man.uploadingCert'));
        try {
          // 证书文件名: 只保留 ASCII, 再加上由完整名称算出的短哈希, 避免两个纯中文名称的服务器互相覆盖证书
          var tagHash = 0, ti; for (ti = 0; ti < sv.outbound.tag.length; ti++) tagHash = (tagHash * 31 + sv.outbound.tag.charCodeAt(ti)) >>> 0;
          var safe = (sv.outbound.tag.replace(/[^A-Za-z0-9_-]+/g, '_').replace(/^_+|_+$/g, '').slice(0, 30) || 'server') + '-' + tagHash.toString(36);
          var cr = await TP.helper('POST', '/api/cert', { q: { name: safe }, body: pem });
          sv.outbound.tls = sv.outbound.tls || { enabled: true };
          sv.outbound.tls.certificate_path = cr.ref;
          if (sv.outbound.tls.insecure && cr.ref) delete sv.outbound.tls.insecure;   // 有了证书就不需要跳过验证
        } catch (e) { st.phase = 'idle'; setStep(2, 'error'); setMsg(e && e.kind === 'auth' ? '' : t('imp.man.certFail', { reason: TP.errMsg(e) }), 'bad-t'); el.paneMan.hidden = false; el.tabs.el.hidden = false; footer(); return; }
      }
      st.sources = [{ kind: 'content', servers: [sv], skipped: [] }];
      var r = await runCommit([{ sub: '', mode: 'merge', url: '', servers: [sv] }]);
      if (!r.ok) setMsg(t('imp.man.writeFail', { reason: TP.errMsg(r.error) }), 'bad-t');
    }

    /* 切换语言: 重新生成底部按钮、步骤名、预览 */
    ses.relang = function () {
      syncSteps(); footer(); applyType();
      if (st.phase === 'preview' && st.sources.length) buildPreview();
    };
    return ses;
  }
})();
