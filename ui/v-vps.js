/* enana · v-vps.js — 添加自己的服务器 (SSH 一键部署): 向导面板 + 「我的服务器」列表 + 重新识别出口 IP
 * 对外: TP.vps = { pane(mode, host), listCard(), openRedetect(record) }   (没有 TP.V 视图; 面板由 v-import.js 的弹窗承载)
 *
 * 向导: 表单 -> 探测 (只读) -> 结果 (系统 / 依赖 / 出口 IP / 主机指纹, 勾选确认指纹) -> 确认 1 (缺失依赖) -> 确认 2 (将执行的全部操作) -> 部署 -> 完成
 *       部署完成但本机验证没通过 (端口没放行等) = 「待验证的部署」: 原因和端口来自任务结果 (节点实际使用的端口, 界面不假设任何固定端口), 修好后「重新验证」只在本机验证, 不重新部署
 * 安全: SSH 密码 / 私钥 / 口令 / sudo 密码只放在闭包变量和输入框里 (autocomplete 关闭, 不用 <form>), 只通过 POST 表单体交给本机辅助服务;
 *       不进 URL / 存储 / 控制台 / 提示 / 错误文字。探测提交后立即清空输入框; 部署成功或退出失败页时清掉闭包里的凭据; 关闭弹窗 (wipe) 时全部清除。
 * 文案全部来自词典 (vps.*)。来自服务器的字符串 (系统名 / 说明 / 节点名 / IP) 一律用 textContent 渲染。 */
(function () {
  'use strict';
  var TP = window.TP, S = TP.S, h = TP.h, ui = TP.ui, setText = TP.setText, fmt = TP.fmt, I = window.I18N, t = I.t, L = I.L;
  var vps = TP.vps = {};
  var uid = 0, panes = [], cards = [], reOpen = null, shared = typeof WeakMap === 'function' ? new WeakMap() : null;
  var MAX_KEY = 64 * 1024;                      // 私钥文件 / 文本上限
  var VERIFY_STEP = 6, STEP_COUNT = 9;          // 部署任务共 9 步, 第 7 步 (下标 6) 是「验证连通」
  var LIST_MAX = 8;                             // 列表里最多显示的芯片数
  var USER_RE = /^[A-Za-z0-9._-]{1,32}$/, NAME_RE = /^[A-Za-z0-9._-]{1,40}$/;
  var VERIFY_RE = new RegExp(String.fromCharCode(0x9a8c, 0x8bc1) + '|verif', 'i');       // 步骤名里的 "验证" / verify: 步骤数对不上时的后备判断 (用字符码构造, 源码保持纯 ASCII)
  var CAN_MASK = (function () { try { return !!(window.CSS && CSS.supports && CSS.supports('-webkit-text-security', 'disc')); } catch (e) { return false; } })();

  /* 错误码 -> [说明, 解决办法] 词典键 (SSH / 服务器相关; 其它错误码走 TP.errMsg) */
  var ERR = {
    E_SSH_NO_CLIENT: ['vps.err.E_SSH_NO_CLIENT', 'vps.hint.E_SSH_NO_CLIENT'],
    E_SSH_UNREACHABLE: ['vps.err.E_SSH_UNREACHABLE', 'vps.hint.E_SSH_UNREACHABLE'],
    E_SSH_AUTH: ['vps.err.E_SSH_AUTH', 'vps.hint.E_SSH_AUTH'],
    E_SSH_KEY: ['vps.err.E_SSH_KEY', 'vps.hint.E_SSH_KEY'],
    E_SSH_HOSTKEY: ['vps.err.E_SSH_HOSTKEY', 'vps.hint.E_SSH_HOSTKEY'],
    E_VPS_PRIVILEGE: ['vps.err.E_VPS_PRIVILEGE', 'vps.hint.E_VPS_PRIVILEGE'],
    E_VPS_UNSUPPORTED: ['vps.err.E_VPS_UNSUPPORTED', 'vps.hint.E_VPS_UNSUPPORTED'],
    E_VPS_DEPS: ['vps.err.E_VPS_DEPS', 'vps.hint.E_VPS_DEPS']
  };
  var SUP = { full: 'vps.sup.full', best_effort: 'vps.sup.best', no: 'vps.sup.no' };
  var SUP_NOTE = { best_effort: 'vps.sup.bestNote', no: 'vps.sup.noNote' };
  var PRIV = { root: 'vps.priv.root', sudo_nopass: 'vps.priv.nopass', sudo_password: 'vps.priv.pass', none: 'vps.priv.none' };
  var FW = { ufw_active: 'vps.fw.active', ufw_inactive: 'vps.fw.inactive', none: 'vps.fw.none' };
  var ARCH = { amd64: 'x86_64 (amd64)', x86_64: 'x86_64', arm64: 'arm64', aarch64: 'arm64 (aarch64)' };

  /* ================= 小工具 ================= */
  function own(map, key) { return Object.prototype.hasOwnProperty.call(map, key) ? map[key] : undefined; }       // 服务器给的字符串当键时, 不能读到原型上的属性
  function isIPv4(s) {
    var m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(s);
    return !!m && +m[1] < 256 && +m[2] < 256 && +m[3] < 256 && +m[4] < 256;
  }
  function isIPv6(s) {
    if (s.indexOf(':') < 0 || !/^[0-9A-Fa-f:.]+$/.test(s)) return false;
    try { return new URL('http://[' + s + ']/').hostname !== ''; } catch (e) { return false; }      // 交给浏览器的解析器判断
  }
  function isHostname(s) {       // 只接受 ASCII 域名 (国际化域名请填 punycode)
    return s.length <= 253 && !/^[\d.]+$/.test(s) && /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$/.test(s);
  }
  function cleanHost(s) { return String(s || '').trim().replace(/^\[(.*)\]$/, '$1'); }
  function validHost(s) { return !!s && (isIPv4(s) || isIPv6(s) || isHostname(s)); }
  function addrOf(host, port) { host = String(host == null ? '' : host); return (host.indexOf(':') >= 0 ? '[' + host + ']' : host) + ':' + port; }
  /* 默认节点名 my-vps-<host>: 只保留允许的字符, 最长 40 */
  function defName(host) {
    var s = String(host || '').replace(/[^A-Za-z0-9._-]+/g, '-').replace(/^[-.]+|[-.]+$/g, '');
    return ('my-vps-' + s).replace(/-+$/, '').slice(0, 40);
  }
  function normKey(s) { s = String(s || '').replace(/\r\n?/g, '\n').trim(); return s ? s + '\n' : ''; }       // ssh 要求私钥文件以换行结尾
  /* 私钥文本的问题 -> 词典键 ('' = 没问题) */
  function keyProblem(k) {
    if (!k) return 'vps.v.keyNeed';
    if (k.length > MAX_KEY) return 'vps.v.keyBig';
    if (/^PuTTY-User-Key-File/.test(k)) return 'vps.v.keyPpk';
    if (!/-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/.test(k)) return /^(ssh-|ecdsa-|-----BEGIN PUBLIC)/.test(k) ? 'vps.v.keyPublic' : 'vps.v.keyFormat';
    return '';
  }
  function osName(p) { var o = (p && p.os) || {}; return String(o.pretty || [o.id, o.version].filter(Boolean).join(' ') || t('common.unknown')); }
  function missingOf(p) { return Array.isArray(p && p.missing) ? p.missing.map(String) : []; }
  /* 探测结果里的「依赖」表: 列头可点击排序 (ui.sorter 'vps-deps', 所有这类表共用一个, 点了以后重排正在显示的那几张) */
  var depsSo = null, depsTabs = [];
  function depsSorter() {
    if (!depsSo) depsSo = ui.sorter('vps-deps', {
      name: { get: function (r) { return r.d.name; } },
      state: { type: 'num', get: function (r) { return r.d.installed ? 1 : 0; } },                       // 升序: 缺失的在前
      version: { get: function (r) { return r.d.installed && r.d.version ? r.d.version : null; } }       // 没装 / 没有版本号 (显示 —) 排最后
    }, { onChange: function () {
      depsTabs = depsTabs.filter(function (x) { if (x.tb.isConnected) x.seen = true; return !x.seen || x.tb.isConnected; });   // 已经从页面上拿掉的表不再管
      depsTabs.forEach(function (x) { x.fill(); });
    } });
    return depsSo;
  }
  /* 出口 IP: [{local, public, v}] (只算有公网地址的); 兼容字符串元素 */
  function ipsOf(p) {
    return (Array.isArray(p && p.ips) ? p.ips : []).map(function (x) {
      return typeof x === 'string' ? { local: '', public: x, v: x.indexOf(':') >= 0 ? 6 : 4 } : x;
    }).filter(function (x) { return x && x.public; });
  }
  function v6Of(p) { return (Array.isArray(p && p.ipv6) ? p.ipv6 : []).map(function (x) { return typeof x === 'string' ? x : String((x && (x.public || x.ip || x.local)) || ''); }).filter(Boolean); }
  function supportOf(p) { var s = String((p && p.support) || ''); return own(SUP, s) ? s : ((p && p.supported === false) ? 'no' : 'full'); }
  function focusSoon(node) { setTimeout(function () { try { if (node && node.isConnected) node.focus({ preventScroll: true }); } catch (e) { /* 忽略 */ } }, 40); }
  function toTop(node) { var b = node && node.closest ? node.closest('.dlg-b') : null; if (b) b.scrollTop = 0; }
  function chips(list) {
    var box = h('span', { class: 'vps-chips' });
    list.slice(0, 24).forEach(function (x) { box.appendChild(h('span', { class: 'chip mono' }, String(x))); });
    if (list.length > 24) box.appendChild(h('span', { class: 'muted sm' }, t('vps.row.more', { n: list.length - 24 })));
    return box;
  }
  function kv(rows) {
    var dl = h('dl', { class: 'vps-kv' });
    rows.forEach(function (r) { if (r) { dl.appendChild(h('dt', null, r[0])); dl.appendChild(h('dd', null, r[1])); } });
    return dl;
  }
  function copyText(text) {
    var ok = function () { ui.toast(t('vps.copied'), 'ok', 1800); }, no = function () { ui.toast(t('vps.copyFail'), 'warn'); };
    function legacy() {          // 没有 clipboard API 时: 临时文本框 + execCommand (要放进最上层的弹窗里才选得中)
      var ta = h('textarea', { class: 'sr', readonly: true, 'aria-hidden': 'true', tabindex: '-1' });
      ta.value = text; ui.topHost().appendChild(ta); ta.select();
      var done = false; try { done = document.execCommand('copy'); } catch (e) { done = false; }
      if (ta.parentNode) ta.parentNode.removeChild(ta);
      if (done) ok(); else no();
    }
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(ok, legacy); else legacy();
  }

  /* ================= 错误: 任务失败时 e.data 是完整的任务对象, 错误码在 e.data.result.code (或 e.data.code / e.code) ================= */
  function codeOf(e) {
    var d = (e && e.data) || {}, r = d.result || {};
    return String(r.code || d.code || (e && e.code) || '');
  }
  /* -> {code, msg, hint, detail, steps, verify} (msg / hint 已是当前语言) */
  function explain(e, where) {
    var code = codeOf(e), d = (e && e.data) || {}, steps = Array.isArray(d.steps) ? d.steps : [], bad = -1, i, raw = e && e.message ? String(e.message) : '';
    var known = own(ERR, code), verify = code === 'E_VPS_VERIFY', res = d.result || {}, out = { code: code, steps: steps, msg: '', hint: '', detail: '', verify: false, pending: '', info: null };
    for (i = 0; i < steps.length; i++) if (steps[i] && steps[i].state === 'error') { bad = i; break; }
    if (where === 'provision' && !known && !verify && bad >= 0) verify = steps.length === STEP_COUNT ? bad === VERIFY_STEP : VERIFY_RE.test(String(steps[bad].label || ''));
    if (known) { out.msg = t(known[0]); out.hint = t(known[1]); }
    else if (verify && res.pending) { out.pending = String(res.pending); out.info = res; out.msg = t('vps.err.pendLead'); }          // 部署完成, 本机验证没通过: 原因 / 端口都用任务结果里的, 不假设固定端口
    else if (verify) { out.msg = raw || t('vps.err.verify'); out.hint = t('vps.hint.verifyRemote'); }                          // 服务器上的部署脚本自己报告的失败 (例如服务没有启动成功): 说明在任务消息里
    else {
      out.msg = code === 'E_INVALID' && raw ? raw : TP.errMsg(e);          // 参数校验失败: 后端的具体说明 (哪个字段不对) 比通用文字有用
      out.hint = e && e.kind === 'unreachable' ? t('why.helper') : t('vps.hint.generic');
    }
    if (raw && raw !== out.msg) out.detail = raw;
    if (where === 'probe' && d.result && d.result.attempt) out.hint += ' ' + t('vps.err.attempts', { n: d.result.attempt, max: d.result.max_attempts });
    out.verify = verify;
    return out;
  }

  /* ================= 部署完成但验证没通过: 原因与处理办法 =================
   * 全部来自任务结果里的结构化字段 (reason / port(s) / tcp / remote / nodes), 没有任何写死的端口; 证据不足时说「无法确定」, 不断言是防火墙。 */
  var VF_REASON = { blocked_cloud: 1, blocked_server: 1, blocked_unknown: 1, not_listening: 1, refused: 1, unreachable: 1, handshake: 1, unknown: 1 };
  var VF_TCP = { ok: 1, timeout: 1, refused: 1, unreachable: 1, mixed: 1, none: 1 };
  var VF_FW = { ufw_active: 'vps.vf.fw.ufwOn', ufw_inactive: 'vps.vf.fw.ufwOff', none: 'vps.vf.fw.none', firewalld_active: 'vps.vf.fw.fwdOn' };
  function vfReason(info) { var r = String((info && info.reason) || ''); return own(VF_REASON, r) ? r : 'unknown'; }
  function vfPorts(info) {
    var ps = (Array.isArray(info && info.ports) ? info.ports : []).map(Number).filter(function (n) { return n > 0 && n < 65536; });
    if (!ps.length && info && +info.port > 0 && +info.port < 65536) ps = [+info.port];
    return ps;
  }
  function vfPortText(info) { return vfPorts(info).join(', ') || '?'; }
  function codeNode(text) { return h('code', null, String(text)); }
  function vfSteps(info) {
    var p1 = vfPorts(info)[0] || 0;
    return I.rich('vps.vf.r.' + vfReason(info) + '.steps', { port: vfPortText(info), ufw: codeNode('ufw allow ' + p1 + '/tcp'),
      fwd: codeNode('firewall-cmd --permanent --add-port=' + p1 + '/tcp && firewall-cmd --reload'), status: codeNode('systemctl status enana-singbox'), ss: codeNode('ss -ltn | grep :' + p1) });
  }
  function vfStatus(info) {
    var ul = h('ul', { class: 'vps-vf-list' }), port = vfPortText(info), rm = (info && info.remote) || {}, tcp = own(VF_TCP, String(info.tcp || '')) ? String(info.tcp) : 'none', fw = own(VF_FW, String(rm.firewall || ''));
    function li(kind, text) { ul.appendChild(h('li', { class: 'is-' + kind }, ui.icon(kind === 'ok' ? 'check' : kind === 'bad' ? 'x' : 'info', 14, 'ci'), h('span', null, text))); }
    li('ok', t('vps.vf.s1', { port: port }));
    li('bad', t('vps.vf.s2', { n: +info.nodes || 0 }));
    li(tcp === 'ok' ? 'ok' : tcp === 'none' ? 'info' : 'bad', t('vps.vf.tcp.' + tcp, { port: port }));
    if (rm.checked) li(rm.listening ? 'ok' : 'bad', t(rm.listening ? 'vps.vf.listen' : 'vps.vf.nolisten', { port: port }));
    else li('info', t('vps.vf.listenUnknown'));
    if (fw) li('info', t(fw));
    li('info', t('vps.vf.cloud'));
    return ul;
  }
  function vfPanel(info) {
    var box = h('div', { class: 'vps-vf' });
    box.appendChild(h('p', { class: 'vps-err-m' }, t('vps.vf.r.' + vfReason(info) + '.msg', { port: vfPortText(info) })));
    box.appendChild(h('div', { class: 'vps-vf-st' }, h('h4', { class: 'vps-h4' }, t('vps.vf.status')), vfStatus(info)));
    box.appendChild(h('p', { class: 'hint warn vps-vf-steps' }, ui.icon('info', 15, 'ci'), h('span', null, vfSteps(info))));
    return box;
  }
  /* 放弃一条待验证的部署记录 (只删本机保存的待验证节点, 不改动服务器); 返回 true = 已删除 */
  async function discardPending(pd) {
    var ok = await ui.confirmDialog({ title: t('vps.vf.discardTitle'), message: t('vps.vf.discardMsg', { name: pd.name || pd.host }), detail: [t('vps.vf.discardD1'), t('vps.vf.discardD2')], confirmText: t('vps.vf.discardGo'), danger: true });
    if (!ok) return false;
    await TP.helper('POST', '/api/vps/pending/discard', { form: { id: String(pd.id) } });
    ui.toast(t('vps.vf.discarded'), 'ok', 2400);
    return true;
  }

  /* 提交一个远程任务并跟随进度 (凭据只在 form 里, 即请求体); card = ui.taskCard; quiet = 只读任务 (探测): 不让顶栏变成「正在应用配置…」 */
  async function remote(path, form, card, defMsg, quiet, control) {
    card.set({ pct: null, msg: t('vps.job.submit') });
    var r;
    try { r = await TP.helper('POST', path, { form: form, timeout: 20000 }); }
    finally { if (control) { control.job = r && r.job || ''; control.ready(); } }
    if (!r || !r.job) throw TP.mkErr('api', t('vps.err.noJob'));
    return TP.jobs.follow(r.job, {
      fromJob: function (j) {
        var c = j.result && j.result.connection, msg = j.msg || defMsg;
        if (c) msg = t('vps.connect.' + c.stage, { n: c.attempt, max: c.max_attempts, elapsed: c.elapsed, timeout: c.timeout });
        if (control && control.cancelled) msg = t('vps.cancel.running');
        card.set({ pct: +j.pct > 0 ? +j.pct : null, msg: msg, steps: j.steps || [] });
      }
    }, { maxFails: 60, quiet: !!quiet });
  }
  /* 通用凭据字段 (只带有值的可选字段) */
  function formOf(c, sudoExtra) {
    var f = { host: c.host, port: String(c.port), user: c.user, mode: c.mode }, sudo = sudoExtra || c.sudo;
    if (c.mode === 'key') { f.key = c.key; if (c.passphrase) f.passphrase = c.passphrase; } else f.password = c.password;
    if (sudo) f.sudo_password = sudo;
    return f;
  }

  /* ================= 表单控件 ================= */
  /* 带标签 / 提示 / 错误行的输入项: box.setErr(词典键, 变量) 显示错误 (aria-invalid + aria-describedby), 输入后自动清除 */
  function fieldBox(label, control, hint, wrap, help) {
    var id = 'vps-f' + (++uid), box = h('div', { class: 'fld vps-fld' }), err = h('span', { class: 'fld-h bad-t', id: id + 'e', hidden: true });
    var hintEl = hint ? h('span', { class: 'fld-h', id: id + 'h' }, hint) : null;
    control.id = id;
    control.setAttribute('aria-describedby', (hintEl ? id + 'h ' : '') + id + 'e');
    box.appendChild(help ? h('div', { class: 'fld-lw' }, h('label', { class: 'fld-l', for: id }, label), ui.help(help)) : h('label', { class: 'fld-l', for: id }, label));
    box.appendChild(wrap || control);
    if (hintEl) box.appendChild(hintEl);
    box.appendChild(err);
    box.setErr = function (key, vars) {
      TP.clear(err);
      if (key) { err.appendChild(I.node(L(key, vars))); err.hidden = false; control.setAttribute('aria-invalid', 'true'); }
      else { err.hidden = true; control.removeAttribute('aria-invalid'); }
    };
    control.addEventListener('input', function () { if (!err.hidden) box.setErr(''); });
    return box;
  }
  /* 密码类输入: type=password + 显示/隐藏按钮 (aria-pressed); autocomplete=new-password, 不让浏览器 / 密码管理器自动填充或保存 */
  function secretInput(eyeKey) {
    var inp = h('input', { class: 'inp', type: 'password', autocomplete: 'new-password', autocapitalize: 'off', spellcheck: 'false', 'data-lpignore': 'true', 'data-1p-ignore': 'true', 'data-bwignore': 'true' });
    var eye = ui.ibtn('eye', L(eyeKey), { size: 18 }), s = { inp: inp, eye: eye };
    eye.classList.add('pw-eye'); eye.setAttribute('aria-pressed', 'false');
    s.wrap = h('span', { class: 'pw' }, inp, eye);
    s.show = function (on) {
      inp.type = on ? 'text' : 'password'; eye.setAttribute('aria-pressed', on ? 'true' : 'false');
      eye.replaceChild(ui.icon(on ? 'eye-off' : 'eye', 18, 'bi'), eye.firstChild); eye._iconEl = eye.firstChild;
    };
    s.clear = function () { inp.value = ''; s.show(false); };
    eye.addEventListener('click', function () { s.show(inp.type === 'password'); inp.focus(); });
    return s;
  }

  /* 凭据表单 (向导与「重新识别」共用)
   * o: {mode, host (固定主机: 不显示输入框), port, user, withNode (节点名 + 角色), onEnter(), onChange(snapshot)}
   * -> c: {el, mode, setMode(m), check() -> 值|null, read(), wipeSecrets(), reset(), hasInput(), snapshot(), apply(s), refreshDefaults(), firstInput()} */
  function credForm(o) {
    var c = { mode: o.mode === 'key' ? 'key' : 'password', touched: { name: false, role: false } }, f = {}, b = {}, sec = {}, fixedHost = o.host ? String(o.host) : '';
    function text(extra) { return h('input', Object.assign({ class: 'inp', type: 'text', autocomplete: 'off', autocapitalize: 'off', spellcheck: 'false' }, extra)); }
    if (!fixedHost) f.host = text({ inputmode: 'url', placeholder: '203.0.113.10', 'aria-required': 'true' });
    f.port = text({ inputmode: 'numeric', maxlength: 5, placeholder: '22', 'aria-required': 'true' });
    f.user = text({ placeholder: 'root', 'aria-required': 'true' });
    sec.pw = secretInput('vps.eye.password'); sec.pass = secretInput('vps.eye.passphrase'); sec.sudo = secretInput('vps.eye.sudo');
    f.key = h('textarea', { class: 'ta vps-key' + (CAN_MASK ? ' is-masked' : ''), rows: 5, autocomplete: 'off', autocapitalize: 'off', spellcheck: 'false', 'data-lpignore': 'true', 'data-1p-ignore': 'true', 'aria-required': 'true', placeholder: '-----BEGIN OPENSSH PRIVATE KEY-----\n…\n-----END OPENSSH PRIVATE KEY-----' });
    f.file = h('input', { type: 'file', hidden: true, tabindex: '-1', 'aria-label': L('vps.f.keyFile') });

    b.host = f.host ? fieldBox(L('vps.f.host'), f.host, L('vps.f.hostHint'), null, 'vps.host') : null; // i18n-ignore: help topic ids
    b.port = fieldBox(L('vps.f.port'), f.port, null, null, 'vps.port'); // i18n-ignore: help topic ids
    b.user = fieldBox(L('vps.f.user'), f.user, null, null, 'vps.user'); // i18n-ignore: help topic ids
    b.pw = fieldBox(L('vps.f.password'), sec.pw.inp, null, sec.pw.wrap);
    b.pass = fieldBox(L('vps.f.passphrase'), sec.pass.inp, L('vps.f.passphraseHint'), sec.pass.wrap, 'vps.passphrase'); // i18n-ignore: help topic ids
    var sudoHintPw = h('span', null, L('vps.f.sudoHintPw')), sudoHintKey = h('span', null, L('vps.f.sudoHintKey'));
    b.sudo = fieldBox(L('vps.f.sudo'), sec.sudo.inp, h('span', null, sudoHintPw, sudoHintKey), sec.sudo.wrap, 'vps.sudo'); // i18n-ignore: help topic ids
    b.key = fieldBox(L('vps.f.key'), f.key, L('vps.f.keyHint'), null, 'vps.key'); // i18n-ignore: help topic ids

    /* 私钥: 文本框 (可以只显示圆点) + 选择文件 (FileReader 只在本机读取, 不上传; 上限 64 KB, 必须像私钥) */
    var keyNote = h('span', { class: 'muted sm vps-keynote', 'aria-live': 'polite' }), pick = ui.btn(L('vps.f.keyPick'), { icon: 'folder-open' }), keyEye = null;
    function setNote(name) { TP.clear(keyNote); if (name) keyNote.appendChild(I.node(L('vps.f.keyLoaded', { name: name }))); }
    pick.addEventListener('click', function () { f.file.click(); });
    f.file.addEventListener('change', function () {
      var fl = f.file.files && f.file.files[0]; f.file.value = '';
      if (!fl) return;
      if (fl.size > MAX_KEY) { b.key.setErr('vps.v.keyBig'); return; }
      var rd = new FileReader();
      rd.onload = function () {
        var k = normKey(String(rd.result || '')), bad = keyProblem(k);
        if (bad) { b.key.setErr(bad); setNote(''); return; }
        f.key.value = k; b.key.setErr(''); setNote(fl.name);
      };
      rd.onerror = function () { b.key.setErr('vps.v.keyRead'); };
      rd.readAsText(fl);
    });
    f.key.addEventListener('input', function () { setNote(''); });
    if (CAN_MASK) {
      keyEye = ui.ibtn('eye', L('vps.eye.key'), { size: 18 }); keyEye.setAttribute('aria-pressed', 'false');
      keyEye.addEventListener('click', function () {
        var show = f.key.classList.contains('is-masked');
        f.key.classList.toggle('is-masked', !show); keyEye.setAttribute('aria-pressed', show ? 'true' : 'false');
        keyEye.replaceChild(ui.icon(show ? 'eye-off' : 'eye', 18, 'bi'), keyEye.firstChild); keyEye._iconEl = keyEye.firstChild;
      });
    }
    var keyBlock = h('div', { class: 'vps-keyblock' }, b.key, h('div', { class: 'vps-keyrow' }, pick, keyEye, f.file, keyNote));

    function grp(titleKey, help) { var kids = Array.prototype.slice.call(arguments, 2); return h('div', { class: 'vps-grp' }, h('div', { class: 'vps-grp-h' }, h('b', null, L(titleKey)), help ? ui.help(help) : null), kids); }
    var parts = [grp('vps.g.server', 'vps.server', h('div', { class: 'vps-grid vps-g-srv' }, b.host, b.port, b.user)), grp('vps.g.cred', 'vps.cred', keyBlock, h('div', { class: 'vps-grid vps-g-cred' }, b.pw, b.pass, b.sudo))]; // i18n-ignore: help topic ids

    /* 节点名 + 角色 (只有向导需要) */
    var rolePin, roleAuto, roleSug;
    if (o.withNode) {
      f.name = text({ maxlength: 40, placeholder: 'my-vps-203.0.113.10' });
      f.role = h('select', { class: 'sel' }, h('option', { value: 'pin' }, L('name.role.pin')), h('option', { value: 'auto' }, L('name.role.auto')));
      rolePin = h('span', null, L('vps.f.rolePin')); roleAuto = h('span', null, L('vps.f.roleAuto')); roleSug = h('span', { class: 'vps-sug' }, L('vps.f.roleSuggest'));
      b.name = fieldBox(L('vps.f.name'), f.name, L('vps.f.nameHint'), null, 'vps.name'); // i18n-ignore: help topic ids
      b.role = fieldBox(L('vps.f.role'), f.role, h('span', null, rolePin, roleAuto, roleSug), null, 'vps.role'); // i18n-ignore: help topic ids
      f.save = h('input', { type: 'checkbox', checked: true }); f.save.addEventListener('change', function () { f.save._touched = true; });      // 「保存到云端」: 默认勾选
      b.save = h('label', { class: 'chk-inline vps-save' }, f.save, h('span', null, L('imp.save')));
      if (TP.sync && TP.sync.prime) TP.sync.prime().then(function (d) { if (!f.save._touched) f.save.checked = !!d.checked; });
      parts.push(grp('vps.g.node', 'vps.node', h('div', { class: 'vps-grid vps-g-node' }, b.name, b.role), b.save)); // i18n-ignore: help topic ids
    }
    c.el = h('div', { class: 'vps-fields' }, parts);

    function paintRole() { if (!f.role) return; var pin = f.role.value === 'pin'; rolePin.hidden = !pin; roleAuto.hidden = pin; roleSug.hidden = !(pin && !TP.hasRole('pin')); }
    function syncName() { if (f.name && !c.touched.name) f.name.value = defName(f.host ? cleanHost(f.host.value) : ''); }
    function changed() { if (o.onChange) o.onChange(c.snapshot()); }
    if (f.host) { f.host.addEventListener('input', syncName); f.host.addEventListener('input', changed); }
    [f.port, f.user].forEach(function (x) { x.addEventListener('input', changed); });
    if (f.name) {
      f.name.addEventListener('input', function () { c.touched.name = true; changed(); });
      f.name.addEventListener('blur', function () { if (!f.name.value.trim()) { c.touched.name = false; syncName(); changed(); } });
      f.role.addEventListener('change', function () { c.touched.role = true; paintRole(); changed(); });
    }
    if (o.onEnter) {            // 回车提交 (输入法组字中的回车不算)
      [f.host, f.port, f.user, sec.pw.inp, sec.pass.inp, sec.sudo.inp, f.name].forEach(function (x) {
        if (x) x.addEventListener('keydown', function (ev) { if (ev.key === 'Enter' && !ev.isComposing) { ev.preventDefault(); o.onEnter(); } });
      });
    }

    c.setMode = function (m) {
      var key = m === 'key';
      if (c.mode !== (key ? 'key' : 'password')) { sec.pw.clear(); sec.pass.clear(); f.key.value = ''; setNote(''); b.pw.setErr(''); b.pass.setErr(''); b.key.setErr(''); }
      c.mode = key ? 'key' : 'password';
      b.pw.hidden = key; b.pass.hidden = !key; keyBlock.hidden = !key; sudoHintPw.hidden = key; sudoHintKey.hidden = !key;
      if (c.seg) c.seg.set(c.mode);
    };
    c.read = function () {
      var key = c.mode === 'key';
      return {
        host: fixedHost || cleanHost(f.host.value), port: f.port.value.trim(), user: f.user.value.trim(), mode: c.mode,
        password: key ? '' : sec.pw.inp.value, key: key ? normKey(f.key.value) : '', passphrase: key ? sec.pass.inp.value : '', sudo: sec.sudo.inp.value,
        name: f.name ? f.name.value.trim() : '', role: f.role ? f.role.value : '', save: f.save ? (f.save.checked ? 1 : 0) : 1
      };
    };
    /* 校验: 全部通过 -> 返回读到的值 (只读一次); 否则在字段下显示错误、聚焦第一个有问题的字段并返回 null */
    c.check = function () {
      var v = c.read(), first = null, pn = /^\d{1,5}$/.test(v.port) ? +v.port : 0, kp;
      function bad(box, ctl, key) { box.setErr(key); if (!first) first = ctl; }
      if (b.host) { if (!v.host) bad(b.host, f.host, 'vps.v.hostNeed'); else if (!validHost(v.host)) bad(b.host, f.host, 'vps.v.host'); }
      if (!(pn >= 1 && pn <= 65535)) bad(b.port, f.port, 'vps.v.port');
      if (!USER_RE.test(v.user)) bad(b.user, f.user, 'vps.v.user');
      if (v.mode === 'password') { if (!v.password) bad(b.pw, sec.pw.inp, 'vps.v.pwNeed'); }
      else { kp = keyProblem(v.key); if (kp) bad(b.key, f.key, kp); }
      if (b.name && v.name && !NAME_RE.test(v.name)) bad(b.name, f.name, 'vps.v.name');
      if (first) { try { first.focus(); } catch (e) { /* 忽略 */ } return null; }
      return v;
    };
    c.wipeSecrets = function () { sec.pw.clear(); sec.pass.clear(); sec.sudo.clear(); f.key.value = ''; f.file.value = ''; setNote(''); if (keyEye && !f.key.classList.contains('is-masked')) keyEye.click(); };
    c.refreshDefaults = function () { if (f.role && !c.touched.role) { f.role.value = TP.hasRole('pin') ? 'auto' : 'pin'; } paintRole(); };
    c.reset = function () {
      c.touched.name = false; c.touched.role = false;
      if (f.save) { f.save._touched = false; f.save.checked = true; }
      if (f.host) f.host.value = '';
      f.port.value = String(o.port || 22); f.user.value = o.user || 'root';
      c.wipeSecrets(); syncName();
      Object.keys(b).forEach(function (k) { if (b[k] && b[k].setErr) b[k].setErr(''); });      // (b.save 是「保存到云端」的勾选框, 不是输入框, 没有 setErr; 以前在这里抛 TypeError, 整个「添加自己的服务器」面板打不开)
      c.refreshDefaults();
    };
    c.hasInput = function () { return !!((f.host && f.host.value.trim()) || sec.pw.inp.value || sec.pass.inp.value || sec.sudo.inp.value || f.key.value.trim() || (f.name && c.touched.name)); };
    c.snapshot = function () { return { host: f.host ? f.host.value : '', port: f.port.value, user: f.user.value, name: f.name ? f.name.value : '', nameTouched: c.touched.name, role: f.role ? f.role.value : '', roleTouched: c.touched.role, save: f.save ? f.save.checked : true }; };
    c.apply = function (s) {
      if (!s) return;
      if (f.host) f.host.value = s.host;
      f.port.value = s.port; f.user.value = s.user;
      if (f.name) { f.name.value = s.name; c.touched.name = !!s.nameTouched; c.touched.role = !!s.roleTouched; if (s.role) f.role.value = s.role; paintRole(); }
      if (f.save && s.save != null) f.save.checked = !!s.save;
    };
    c.firstInput = function () { return f.host || (c.mode === 'key' ? f.key : sec.pw.inp); };
    c.setMode(c.mode); c.reset();
    return c;
  }

  /* 同一个弹窗里的「密码」和「私钥」两个面板共享非敏感字段 (主机 / 端口 / 用户 / 节点名 / 角色): 以最近的 <dialog> 为键 (宿主给每个面板各传一个 host 对象也没关系) */
  function sharedOf(key) {
    var s = key && shared ? shared.get(key) : null;
    if (!s) { s = { snap: null }; if (key && shared) shared.set(key, s); }
    return s;
  }

  /* ================================================================================
   * 向导面板: TP.vps.pane(mode, host) -> {el, start(), dirty(), busy(), wipe()}
   * 阶段 st.phase: form | probing | probeErr | result | provisioning | provErr | done
   * ================================================================================ */
  vps.pane = function (mode, host) {
    mode = mode === 'key' ? 'key' : 'password';
    var P = { _seen: false };
    var st = { phase: 'form', run: 0, creds: null, probe: null, meta: null, fpOk: false, sudoIn: '', res: null, err: null, card: null, control: null, cancelling: false };
    var live = h('div', { class: 'sr', role: 'status', 'aria-live': 'polite' }), cbFp = null, sudoInp = null;
    var cf = credForm({ mode: mode, withNode: true, onEnter: function () { detect(); }, onChange: function (s) { sh().snap = s; } });
    var formBox = h('div', { class: 'vps-form' },
      h('p', { class: 'vps-intro muted sm' }, L(mode === 'key' ? 'vps.intro.key' : 'vps.intro.password'), ui.help('vps.wizard')), // i18n-ignore: help topic ids
      h('p', { class: 'hint ok vps-privacy' }, ui.icon('lock', 15, 'ci'), h('span', null, L('vps.privacy'))),
      cf.el);
    var view = h('div', { class: 'vps-view', hidden: true });
    var el = h('div', { class: 'vps' }, formBox, view, live);
    P.el = el;

    function sh() { return sharedOf((el.closest && el.closest('dialog')) || host); }
    function visible() { return el.isConnected && el.getClientRects().length > 0; }
    function say(text) { live.textContent = ''; setTimeout(function () { live.textContent = text; }, 60); }
    function isBusy() { return st.phase === 'probing' || st.phase === 'provisioning' || st.phase === 'verifying'; }
    function needSudoInline() { return !!st.probe && st.probe.privilege === 'sudo_password' && !(st.creds && st.creds.sudo); }
    function sudoValue() { return st.sudoIn || (st.creds && st.creds.sudo) || ''; }
    function focusFp() { if (cbFp) { cbFp.scrollIntoView({ block: 'center' }); cbFp.focus(); } }
    function focusSudo() { if (sudoInp) { sudoInp.scrollIntoView({ block: 'center' }); sudoInp.focus(); } }

    /* 为什么现在不能「继续」(null = 可以): 先说真正的阻碍, 最后才是「勾选指纹」 */
    function contReason() {
      var p = st.probe || {}, why = TP.why.helper();
      if (why) return { reason: why };
      if (supportOf(p) === 'no' || p.supported === false) return { reason: t('vps.why.unsupported') };
      if (p.privilege === 'none') return { reason: t('vps.why.noPriv') };
      if (!ipsOf(p).length) return { reason: t('vps.why.noIps') };
      if (!p.hostkey) return { reason: t('vps.why.noHostkey') };
      if (p.privilege === 'sudo_password' && st.creds && st.creds.mode === 'key' && !sudoValue()) return { reason: t('vps.why.needSudo'), fix: { label: t('vps.fix.sudo'), fn: focusSudo } };
      if (!st.fpOk) return { reason: t(p.hostkey_changed ? 'vps.why.confirmFpNew' : 'vps.why.confirmFp'), fix: { label: t('vps.fix.fp'), fn: focusFp } };
      return null;
    }

    /* ---------- 底部按钮 ---------- */
    function footer() {
      var ph = st.phase, why;
      if (ph === 'form') {
        why = TP.why.helper();
        return [{ label: t('common.cancel'), cancel: true },
          { label: t('vps.detect'), kind: 'primary', icon: 'search', id: 'go', keep: true, unavail: why ? { reason: why } : null, onClick: async function () { await detect(); return false; } }];
      }
      if (ph === 'probeErr' || ph === 'provErr') {
        var pend = ph === 'provErr' && st.err && st.err.pending, acts = [{ label: t('vps.backEdit'), icon: 'chevron-left', id: 'back', keep: true, onClick: function () { backToForm(); return false; } }];
        if (pend && st.creds && st.probe) acts.push({ label: t('vps.vf.redeploy'), icon: 'rocket', id: 'redeploy', keep: true, onClick: async function () { await onContinue(true); return false; } });      // 明确的「重新部署」: 默认的主操作是不重新部署的「重新验证」
        acts.push({ label: t(pend ? 'vps.vf.go' : 'common.retry'), kind: 'primary', icon: 'refresh', id: 'retry', keep: true, onClick: async function () { await retry(); return false; } });
        return acts;
      }
      if (ph === 'result') {
        return [{ label: t('common.back'), icon: 'chevron-left', id: 'back', keep: true, onClick: function () { backToForm(); return false; } },
          { label: t('vps.continue'), kind: 'primary', icon: 'arrow-right', id: 'go', keep: true, unavail: contReason(), onClick: async function () { await onContinue(false); return false; } }];
      }
      if (ph === 'done') {
        return [{ label: t('vps.done.again'), icon: 'plus', id: 'again', keep: true, onClick: function () { again(); return false; } },
          { label: t('vps.done.servers'), icon: 'nav-servers', id: 'srv', onClick: function () { host.goServers(); } },
          { label: t('vps.done.speed'), icon: 'speed', id: 'speed', onClick: function () { host.close(true); TP.go('speed'); } },
          { label: t('common.close'), kind: 'primary', id: 'close', cancel: true }];
      }
      if (ph === 'probing') return [{ label: t(st.cancelling ? 'vps.cancel.running' : 'vps.cancel'), icon: 'x', id: 'cancelProbe', keep: true, allowBusy: true, disabled: st.cancelling,
        onClick: async function () { await cancelProbe(); return false; } }];
      if (isBusy()) return [{ label: t('common.loading'), icon: 'refresh', id: 'progress', keep: true }];
      return [];
    }
    function setFoot(force) { if (force || (P._seen && visible())) host.setActions(footer()); }

    /* ---------- 阶段切换 ---------- */
    function setPhase(p) {
      st.phase = p;
      render();
      host.setTabsHidden(p !== 'form');
      host.setBusy(isBusy());
      setFoot(true);
      toTop(el); focusSoon(p === 'form' ? cf.firstInput() : view.querySelector('.vps-h'));
      if (p === 'probing') say(t('vps.say.probing'));
      else if (p === 'provisioning') say(t('vps.say.provisioning'));
      else if (p === 'verifying') say(t('vps.say.verifying'));
      else if (p === 'result') say(t('vps.say.result', { os: osName(st.probe) }));
      else if (p === 'done') say(t('vps.say.done'));
      else if (st.err) say(st.err.msg);
    }
    function render() {
      var p = st.phase;
      formBox.hidden = p !== 'form'; view.hidden = p === 'form';
      cbFp = null; sudoInp = null;
      if (p === 'form') return;
      TP.clear(view);
      if (p === 'probing' || p === 'provisioning' || p === 'verifying') view.appendChild(stageView());
      else if (p === 'result') view.appendChild(resultView());
      else if (p === 'probeErr' || p === 'provErr') view.appendChild(errView());
      else if (p === 'done') view.appendChild(doneView());
    }

    /* ---------- 凭据只保存在这里 (闭包); 用完立刻清掉 ---------- */
    function forgetSecrets() { st.creds = null; st.sudoIn = ''; cf.wipeSecrets(); if (sudoInp) sudoInp.value = ''; }
    function wipeAll() { forgetSecrets(); st.probe = null; st.fpOk = false; st.err = null; st.card = null; st.res = null; }
    function backToForm() { st.run++; wipeAll(); setPhase('form'); }
    function again() { st.run++; wipeAll(); st.meta = null; cf.reset(); sh().snap = cf.snapshot(); setPhase('form'); }
    function retry() {
      if (st.phase === 'probeErr') return runProbe();
      if (st.err && st.err.pending) return runVerify(st.err.pending);          // 服务器上已经部署好了: 重试 = 只在本机重新验证, 不再部署
      return onContinue(true);
    }

    /* ---------- 1. 表单 -> 探测 ---------- */
    function detect() {
      var why = TP.why.helper(); if (why) { ui.toast(why, 'warn'); return; }
      if (st.phase !== 'form') return;
      var v = cf.check();
      if (!v) return;
      st.creds = { host: v.host, port: +v.port, user: v.user, mode: v.mode, password: v.password, key: v.key, passphrase: v.passphrase, sudo: v.sudo };
      st.meta = { name: v.name || defName(v.host), role: v.role, save: v.save ? 1 : 0 };
      v = null; cf.wipeSecrets();                                   // 输入框里的秘密立即清空, 之后只剩闭包里这一份
      return runProbe();
    }
    async function runProbe() {
      var my = ++st.run, control = { job: '', cancelled: false };
      control.whenReady = new Promise(function (resolve) { control.ready = resolve; });
      control.whenFinished = new Promise(function (resolve) { control.finished = resolve; });
      st.control = control; st.cancelling = false;
      st.card = ui.taskCard(t('vps.card.progress'), { horizontal: false });
      setPhase('probing');
      try {
        var j = await remote('/api/vps/probe', formOf(st.creds), st.card, t('vps.probe.running'), true, control);
        if (!j.result || typeof j.result !== 'object') throw TP.mkErr('api', t('vps.err.noResult'));
        control.result = j.result;
      } catch (e) {
        control.error = e;
      } finally {
        control.done = true; control.finished();
        if (my === st.run && !control.cancelled) applyProbeOutcome(control);
      }
    }
    function applyProbeOutcome(control) {
      if (control.error) { st.err = explain(control.error, 'probe'); setPhase('probeErr'); }
      else { st.probe = control.result; st.fpOk = false; st.sudoIn = ''; setPhase('result'); }
    }
    async function cancelProbe() {
      if (st.phase !== 'probing' || st.cancelling || !st.control) return;
      var control = st.control;
      st.cancelling = true; control.cancelled = true;
      setFoot(true); st.card.set({ pct: null, msg: t('vps.cancel.running') });
      try {
        await control.whenReady;
        if (control.job) await TP.helper('POST', '/api/vps/cancel', { form: { id: control.job } });
        await control.whenFinished;
        backToForm(); ui.toast(t('vps.cancel.done'), 'ok');
      } catch (e) {
        control.cancelled = false; st.cancelling = false;
        // A failed cancel request must not hide a result that arrived meanwhile.
        if (control.done) applyProbeOutcome(control); else setFoot(true);
        ui.toast(TP.errMsg(e), 'err');
      }
    }

    /* ---------- 2. 结果 -> 确认 1 (缺失依赖) -> 确认 2 (全部操作) -> 部署 ---------- */
    async function onContinue(isRetry) {
      var why = contReason();
      if (why) { ui.toast(why.reason, 'warn', 5200, why.fix ? { action: why.fix } : null); return; }
      var p = st.probe, miss = missingOf(p), target = st.creds.user + '@' + addrOf(st.creds.host, st.creds.port), ok;
      if (miss.length && !isRetry) {
        ok = await ui.confirmDialog({
          title: t('vps.cf1.title'), message: t(p.all_missing ? 'vps.cf1.msgAll' : 'vps.cf1.msg', { target: target, list: miss.join(', ') }),
          detail: [t('vps.cf1.d1', { list: miss.join(' ') }), t('vps.cf1.d2'), t('vps.cf1.d3')], confirmText: t('vps.cf1.go')
        });
        if (!ok) return;                                          // 拒绝: 回到结果页 (部署需要这些依赖)
      }
      ok = await ui.confirmDialog({ title: t('vps.cf2.title'), message: t('vps.cf2.msg', { target: target }), detail: planOf(p), confirmText: t('vps.cf2.go') });
      if (!ok) return;
      await runProvision();
    }
    function planPort(p) { var n = p && p.plan && +p.plan.port; return n > 0 && n < 65536 ? n : 0; }
    /* 确认 2: 逐条列出将在服务器和本机上做的事 */
    function planOf(p) {
      var ips = ipsOf(p).map(function (x) { return String(x.public); }), miss = missingOf(p), d = [];
      d.push(miss.length ? t('vps.cf2.pkgs', { list: miss.join(', ') }) : t('vps.cf2.noPkgs'));
      if (!(p.singbox && p.singbox.installed)) d.push(t('vps.cf2.install'));
      var pp = planPort(p);          // 云端的探测脚本告诉了「将要用哪个端口」就写出来, 没有就不假设 —— 部署完成后以节点实际使用的端口为准
      d.push(pp ? t('vps.cf2.config', { n: ips.length, ips: ips.join(', '), port: pp }) : t('vps.cf2.configAuto', { n: ips.length, ips: ips.join(', ') }));
      d.push(t('vps.cf2.start'));
      if (p.firewall === 'ufw_active') d.push(pp ? t('vps.cf2.ufw', { port: pp }) : t('vps.cf2.ufwAuto'));
      if ((p.singbox && p.singbox.installed) || (Array.isArray(p.listening) && p.listening.length > 1)) d.push(t('vps.cf2.keep'));
      d.push(t('vps.cf2.verify'));
      d.push(t('vps.cf2.save', { n: ips.length, name: st.meta.name, role: TP.name.role(st.meta.role) }));
      d.push(t(st.meta.save ? 'imp.cf.saveYes' : 'imp.cf.saveNo'));
      if (p.node && p.node.installed) d.push(t('vps.cf2.node'));
      d.push(pp ? t('vps.cf2.cloud', { port: pp }) : t('vps.cf2.cloudAuto'));
      return d;
    }
    async function runProvision() {
      var my = ++st.run, p = st.probe, f = formOf(st.creds, st.sudoIn);
      f.hostkey = String(p.hostkey); f.name = st.meta.name; f.role = st.meta.role; f.install_deps = missingOf(p).length ? '1' : '0'; f.save = st.meta.save ? '1' : '0';
      st.card = ui.taskCard(t('vps.card.progress'), { horizontal: false });
      setPhase('provisioning');
      try {
        var j = await remote('/api/vps/provision', f, st.card, t('vps.prov.running'));
        f = null;
        if (my !== st.run) return;
        st.res = j.result && typeof j.result === 'object' ? j.result : {};
        forgetSecrets();                                          // 部署成功: 凭据立即清除
        st.probe = null; st.fpOk = false;
        st.card.done(t('vps.prov.done'));
        TP.afterApply();
        await TP.loadState();
        reloadCards();
        if (my !== st.run) return;
        setPhase('done');
      } catch (e) {
        f = null;
        if (my !== st.run) return;
        st.err = explain(e, 'provision'); setPhase('provErr');    // 凭据仍在内存里, 「重试」不用重新输入
      }
    }

    /* ---------- 3. 部署已完成、验证没通过: 只在本机重新验证 (没有 SSH, 不重新部署, 不需要凭据) ---------- */
    async function runVerify(pid) {
      var my = ++st.run;
      st.card = ui.taskCard(t('vps.card.progress'), { horizontal: false });
      setPhase('verifying');
      try {
        var j = await remote('/api/vps/verify', { id: String(pid) }, st.card, t('vps.vf.running'));
        if (my !== st.run) return;
        st.res = j.result && typeof j.result === 'object' ? j.result : {};
        forgetSecrets(); st.probe = null; st.fpOk = false;
        st.card.done(t('vps.vf.done'));
        TP.afterApply();
        await TP.loadState();
        reloadCards();
        if (my !== st.run) return;
        setPhase('done');
      } catch (e) {
        if (my !== st.run) return;
        st.err = explain(e, 'verify'); setPhase('provErr');         // 记录还在: 可以再验证; 原因更新为这一次的结果
      }
    }

    /* ---------- 视图 ---------- */
    function sec(titleKey, body, cls) { return h('section', { class: 'vps-sec' + (cls ? ' ' + cls : '') }, h('h4', { class: 'vps-h4' }, t(titleKey), ui.help(titleKey === 'vps.sec.packages' ? 'vps.deps' : titleKey === 'vps.sec.system' ? 'vps.os' : titleKey === 'vps.sec.network' ? 'vps.network' : 'vps.software')), body); } // i18n-ignore: help topic ids
    function stageView() {
      var prov = st.phase === 'provisioning', ver = st.phase === 'verifying', c = st.creds || {};
      return h('div', { class: 'vps-stage' },
        h('h3', { class: 'vps-h', tabindex: '-1' }, ui.icon(prov ? 'rocket' : ver ? 'refresh' : 'search', 20, 'ci'), t(prov ? 'vps.prov.head' : ver ? 'vps.vf.head' : 'vps.probe.head')),
        !ver && c.host ? h('p', { class: 'muted sm vps-target' }, t('vps.target', { target: String(c.user) + '@' + addrOf(c.host, c.port) })) : null,
        st.card ? st.card.el : null,
        h('p', { class: 'muted sm' }, t(prov ? 'vps.prov.note' : ver ? 'vps.vf.note' : 'vps.probe.note')));
    }

    function resultView() {
      var p = st.probe || {}, c = st.creds || {}, root = h('div', { class: 'vps-res' });
      root.appendChild(h('h3', { class: 'vps-h', tabindex: '-1' }, ui.icon('server', 20, 'ci'), t('vps.res.title')));
      root.appendChild(h('p', { class: 'muted sm vps-ro' }, t('vps.res.readonly')));
      root.appendChild(supportBlock(p));
      root.appendChild(hostkeyBlock(p));
      if (p.pending) root.appendChild(pendingBlock(p.pending));
      if (needSudoInline()) root.appendChild(sudoBlock());
      root.appendChild(h('div', { class: 'vps-cols' }, sec('vps.sec.system', systemBlock(p, c)), sec('vps.sec.network', networkBlock(p)), sec('vps.sec.software', softwareBlock(p))));
      root.appendChild(sec('vps.sec.packages', packagesBlock(p), 'vps-wide'));
      root.appendChild(ipsBlock(p));
      return root;
    }
    function supportBlock(p) {
      var sup = supportOf(p), kind = sup === 'full' ? 'ok' : sup === 'best_effort' ? 'warn' : 'bad', note = String(p.support_note || '').trim();
      var box = h('div', { class: 'vps-sup is-' + kind }, h('div', { class: 'vps-sup-h' }, ui.chip(t(SUP[sup]), kind, kind === 'ok' ? 'success' : kind === 'warn' ? 'warning' : 'error'), h('b', { class: 'vps-os' }, osName(p))));
      if (sup !== 'full') box.appendChild(h('p', { class: 'vps-sup-n' }, note || t(SUP_NOTE[sup])));          // 完全支持时不重复显示说明
      if (sup === 'no') box.appendChild(h('p', { class: 'sm vps-sup-n' }, t('vps.sup.matrix')));
      return box;
    }
    function hostkeyBlock(p) {
      var changed = !!p.hostkey_changed, fp = String(p.hostkey || ''), cb = h('input', { type: 'checkbox' }), copy = ui.ibtn('copy', t('vps.copyFp'), { size: 16 });
      cb.checked = st.fpOk; cbFp = cb;
      cb.addEventListener('change', function () { st.fpOk = cb.checked; setFoot(); });
      copy.addEventListener('click', function () { copyText(fp); });
      return h('section', { class: 'vps-fp' + (changed ? ' is-changed' : '') },
        h('h4', { class: 'vps-h4' }, ui.icon(changed ? 'shield-alert' : 'secure', 16, 'ci'), t('vps.fp.title'), ui.help('vps.fp')), // i18n-ignore: help topic ids
        changed ? h('p', { class: 'hint bad vps-fp-warn', role: 'alert' }, ui.icon('shield-alert', 15, 'ci'), h('span', null, t('vps.fp.changed'))) : null,
        h('div', { class: 'vps-fp-row' }, h('code', { class: 'vps-fp-code' }, fp || t('vps.fp.none')), fp ? copy : null),
        h('p', { class: 'muted sm vps-fp-help' }, I.rich('vps.fp.help', { cmd: h('code', null, 'ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub') })),
        h('label', { class: 'chk-inline vps-confirm' + (changed ? ' is-strong' : '') }, cb, h('span', null, t(changed ? 'vps.fp.confirmNew' : 'vps.fp.confirm'))));
    }
    /* 这台服务器上有一次「部署完成但验证没通过」的记录: 服务器上其实已经有节点了, 不需要重新部署, 直接重新验证 */
    function pendingBlock(pd) {
      var verify = ui.btn(t('vps.pend.verify'), { icon: 'refresh', kind: 'primary', sm: true }), drop = ui.btn(t('vps.pend.discard'), { icon: 'trash', sm: true });
      ui.act(verify, async function () { await runVerify(pd.id); });
      ui.act(drop, async function () { if (await discardPending(pd)) { if (st.probe) st.probe.pending = null; render(); setFoot(true); } });
      return h('section', { class: 'vps-sec vps-pend', role: 'group' }, h('h4', { class: 'vps-h4' }, ui.icon('warning', 16, 'ci'), t('vps.pend.title')),
        h('p', { class: 'sm' }, t('vps.pend.msg', { ports: (Array.isArray(pd.ports) ? pd.ports : []).join(', ') || '?', n: +pd.nodes || 0 })),
        pd.reason && pd.reason !== 'pending' ? h('p', { class: 'muted sm' }, t('vps.pl.reason.' + (own(VF_REASON, String(pd.reason)) ? pd.reason : 'unknown'))) : null,
        h('div', { class: 'vps-pend-acts' }, verify, drop));
    }
    function sudoBlock() {
      var s = secretInput('vps.eye.sudo'), key = st.creds && st.creds.mode === 'key';
      sudoInp = s.inp; s.inp.value = st.sudoIn;
      s.inp.addEventListener('input', function () { st.sudoIn = s.inp.value; setFoot(); });
      s.inp.addEventListener('keydown', function (ev) { if (ev.key === 'Enter' && !ev.isComposing) { ev.preventDefault(); onContinue(false); } });
      return h('section', { class: 'vps-sec vps-sudo' }, h('h4', { class: 'vps-h4' }, ui.icon('lock', 16, 'ci'), t('vps.sudo.title')),
        h('p', { class: 'sm' }, t(key ? 'vps.sudo.needKey' : 'vps.sudo.needPw')), fieldBox(t(key ? 'vps.sudo.label' : 'vps.f.sudo'), s.inp, null, s.wrap));
    }
    function systemBlock(p, c) {
      var pk = p.privilege, who = String(p.user || c.user || ''), priv = h('span', { class: pk === 'none' ? 'bad-t' : '' }, own(PRIV, pk) ? t(PRIV[pk], { user: who }) : who);
      return kv([[t('vps.k.server'), h('span', { class: 'mono' }, addrOf(p.host || c.host, p.port || c.port))], [t('vps.k.os'), osName(p)],
        [t('vps.k.arch'), own(ARCH, p.arch) || String(p.arch || t('common.unknown'))], [t('vps.k.init'), String(p.init || t('common.unknown'))], [t('vps.k.login'), priv]]);
    }
    function networkBlock(p) {
      var ports = (Array.isArray(p.listening) ? p.listening : []).map(Number).filter(Boolean), box = h('div', { class: 'vps-net' });
      box.appendChild(kv([[t('vps.k.firewall'), own(FW, p.firewall) ? t(FW[p.firewall]) : t('common.unknown')], [t('vps.k.listening'), ports.length ? chips(ports) : t('common.none')]]));
      var pp = planPort(p);
      if (pp) box.appendChild(h('p', { class: 'hint ok' }, ui.icon('info', 15, 'ci'), h('span', null, t(p.plan.reason === 'default_busy' ? 'vps.net.planBusy' : 'vps.net.plan', { port: pp }))));
      if (ports.length > 1 || (p.singbox && p.singbox.installed)) box.appendChild(h('p', { class: 'hint' }, ui.icon('info', 15, 'ci'), h('span', null, t('vps.net.keep'))));      // 已有的服务 / 端口: 不会被动
      box.appendChild(h('p', { class: 'hint vps-cloud' }, ui.icon('info', 15, 'ci'), h('span', null, pp ? t('vps.cloud.note', { port: pp }) : t('vps.cloud.noteAuto'))));
      return box;
    }
    function softwareBlock(p) {
      var sb = p.singbox || {}, node = p.node || {}, box = h('div', null);
      box.appendChild(kv([
        [t('vps.k.singbox'), sb.installed ? ui.chip(sb.version ? t('vps.sb.installedV', { v: sb.version }) : t('vps.sb.installed'), 'ok', 'check') : ui.chip(t('vps.sb.none'), '', 'minus')],
        [t('vps.k.node'), node.installed ? ui.chip(t(p.pending ? 'vps.node.pending' : 'vps.node.exists'), 'warn', 'warning') : ui.chip(t('vps.node.none'), '', 'minus')]]));
      if (node.installed) box.appendChild(h('p', { class: 'hint warn' }, ui.icon('warning', 15, 'ci'), h('span', null, t(p.pending ? 'vps.node.pendHint' : 'vps.node.hint'))));
      return box;
    }
    function packagesBlock(p) {
      var deps = Array.isArray(p.deps) ? p.deps : [], miss = missingOf(p), box = h('div', null), tb = h('tbody'), so = depsSorter();
      if (!deps.length) { box.appendChild(h('p', { class: 'muted sm' }, t('vps.deps.none'))); return box; }
      var rows = deps.map(function (d) {                          // 行只建一次; 排序只改变它们的顺序
        return { d: d, tr: h('tr', null,
          h('td', { class: 'c-name vps-dn mono' }, String(d.name)),
          h('td', { 'data-l': t('vps.deps.state') }, d.installed ? ui.chip(t('vps.deps.ok'), 'ok', 'check') : ui.chip(t('vps.deps.missing'), 'warn', 'x')),
          h('td', { class: 'mono sm', 'data-l': t('vps.deps.version') }, d.installed && d.version ? String(d.version) : '—')) };
      });
      function fill() { so.apply(rows).forEach(function (r) { tb.appendChild(r.tr); }); }
      depsTabs.push({ tb: tb, fill: fill, seen: false }); fill();
      box.appendChild(h('div', { class: 'tbl-wrap' }, h('table', { class: 'tbl rt vps-tbl' },
        h('thead', null, h('tr', null, so.th('name', function () { return t('vps.deps.name'); }), so.th('state', function () { return t('vps.deps.state'); }), so.th('version', function () { return t('vps.deps.version'); }))), tb)));
      box.appendChild(h('p', { class: 'hint' + (miss.length ? ' warn' : ' ok') }, miss.length ? t('vps.deps.missingN', { n: miss.length, list: miss.join(', ') }) : t('vps.deps.allOk')));
      return box;
    }
    function ipsBlock(p) {
      var ips = ipsOf(p), v6 = v6Of(p), box = h('section', { class: 'vps-sec vps-wide' }, h('h4', { class: 'vps-h4' }, t('vps.sec.ips'), ui.help('vps.ips'))); // i18n-ignore: help topic ids
      if (!ips.length) box.appendChild(h('p', { class: 'hint bad' }, ui.icon('error', 15, 'ci'), h('span', null, t('vps.ips.none'))));
      else {
        var ul = h('ul', { class: 'vps-ips' });
        ips.forEach(function (x) {
          var pub = String(x.public), loc = String(x.local || '');
          ul.appendChild(h('li', { class: 'vps-ip' }, h('span', { class: 'badge' }, +x.v === 6 ? 'IPv6' : 'IPv4'),
            loc && loc !== pub ? h('span', { class: 'mono sm muted' }, loc) : null, loc && loc !== pub ? ui.icon('arrow-right', 14, 'ci') : null, h('b', { class: 'mono' }, pub)));
        });
        box.appendChild(ul);
        box.appendChild(h('p', { class: 'muted sm' }, t('vps.ips.note', { n: ips.length })));
      }
      if (v6.length) box.appendChild(h('div', { class: 'vps-line' }, h('span', { class: 'muted sm' }, t('vps.ips.v6')), chips(v6)));
      return box;
    }

    function errView() {
      var e = st.err || { msg: '', hint: '', detail: '', steps: [] }, prov = st.phase === 'provErr', root = h('div', { class: 'vps-err' });
      root.appendChild(h('h3', { class: 'vps-h bad-t', tabindex: '-1' }, ui.icon('error', 20, 'ci'), t(e.pending ? 'vps.err.pendTitle' : prov ? 'vps.err.provTitle' : 'vps.err.probeTitle')));
      root.appendChild(h('p', { class: e.pending ? 'vps-err-lead' : 'vps-err-m' }, e.msg));
      if (e.pending && e.info) root.appendChild(vfPanel(e.info));          // 部署已完成、验证没通过: 当前状态 + 原因 + 处理办法
      if (e.hint) root.appendChild(h('p', { class: 'hint warn' }, ui.icon('info', 15, 'ci'), h('span', null, e.hint)));
      if (prov) {
        if (e.steps && e.steps.length) { var ol = h('ol', { class: 'steps vps-steps' }); ui.renderSteps(ol, e.steps.map(function (s) { return { label: String(s.label || ''), state: s.state }; })); root.appendChild(ol); }
        if (!e.pending) root.appendChild(h('p', { class: 'muted sm' }, t('vps.err.partial')));
      }
      if (e.detail) root.appendChild(h('div', { class: 'skipped' }, ui.detailsBtn(t('common.details'), t('common.details'), function () { return h('p', { class: 'mono sm vps-raw' }, e.detail); })));
      return root;
    }

    function doneView() {
      var res = st.res || {}, nodes = Array.isArray(res.nodes) ? res.nodes : [], role = st.meta && st.meta.role, root = h('div', { class: 'vps-done' });
      var ips = Array.isArray(res.ips) && res.ips.length ? res.ips.map(String) : nodes.map(function (n) { return String(n.egress || ''); }).filter(Boolean);
      root.appendChild(h('div', { class: 'done-box' }, h('div', { class: 'done-t' }, h('span', { class: 'ck ok' }, ui.icon('check', 13)), h('h3', { class: 'vps-h vps-plain', tabindex: '-1' }, t('vps.done.title'))), h('p', { class: 'vps-done-m' }, t('vps.done.msg', { n: nodes.length }))));
      if (nodes.length) {
        var ul = h('ul', { class: 'vps-nodes' });
        nodes.forEach(function (n) {
          var r = (S.svMap && S.svMap[n.tag] && S.svMap[n.tag].role) || role || '';
          ul.appendChild(h('li', { class: 'vps-node' }, h('b', { class: 'vps-node-t' }, String(n.tag)),
            h('span', { class: 'vps-node-m' },
              h('span', { class: 'mono sm' }, addrOf(n.server, n.port)),
              n.egress ? h('span', { class: 'chip mono' }, ui.icon('globe', 13, 'ci'), String(n.egress)) : (n.verified === false ? ui.chip(t('vps.done.unverified'), 'warn', 'warning') : null),
              r ? h('span', { class: 'badge ' + (r === 'pin' ? 'pin' : 'auto') }, ui.icon(r === 'pin' ? 'pin' : 'auto', 12, 'ci'), TP.name.role(r)) : null)));
        });
        root.appendChild(h('div', null, h('h4', { class: 'vps-h4' }, t('vps.done.nodes')), ul));
      }
      if (ips.length) root.appendChild(h('div', { class: 'vps-line' }, h('span', { class: 'muted sm' }, t('vps.done.ips')), chips(ips)));
      root.appendChild(h('p', { class: 'muted sm' }, t('vps.done.next')));
      if (TP.actions && TP.actions.proxyOn && TP.actions.proxyOn() === false) root.appendChild(h('p', { class: 'hint warn' }, ui.icon('power', 15, 'ci'), h('span', null, t('vps.done.proxyOff'))));
      return root;
    }

    /* ---------- 对外接口 ---------- */
    P.start = function () {
      P._seen = true;
      if (st.phase === 'form') { cf.apply(sh().snap); cf.refreshDefaults(); }
      host.setTabsHidden(st.phase !== 'form');
      host.setBusy(isBusy());
      host.setActions(footer());
      if (st.phase === 'form') focusSoon(cf.firstInput());
    };
    P.relang = function () {
      if (st.phase !== 'form') { if (st.card) st.card.setTitle(t('vps.card.progress')); render(); }
      setFoot();
    };
    P.refreshFoot = function () { if (st.phase === 'form' || st.phase === 'result') setFoot(); };
    P.wipe = function () {
      st.run++; wipeAll(); st.meta = null; sh().snap = null;
      cf.reset(); st.phase = 'form'; TP.clear(view); view.hidden = true; formBox.hidden = false;
    };
    panes.push(P);
    return {
      el: el,
      start: P.start,
      dirty: function () { return st.phase === 'form' && cf.hasInput(); },
      busy: isBusy,
      wipe: P.wipe
    };
  };

  /* ================================================================================
   * 我的服务器 (列表卡片): TP.vps.listCard() -> <section class="card"> (自己更新; card._reload() 重新读取)
   * ================================================================================ */
  function reloadCards() { pruneList(cards); cards.forEach(function (c) { c.reload(); }); }
  function pruneList(list) { var i; for (i = list.length - 1; i >= 0; i--) if (list[i]._seen && !list[i].el.isConnected) list.splice(i, 1); }

  vps.listCard = function () {
    var C = { _seen: false }, data = [], pending = [], loaded = false, loading = false, err = null, at = 0, busy = {};
    var card = h('section', { class: 'card vps-card' }), empty = ui.emptyBox();
    var addBtn = ui.btn(L('vps.list.add'), { icon: 'plus', kind: 'primary', sm: true });
    var note = h('p', { class: 'hint warn', hidden: true }), list = h('tbody'), pendBox = h('section', { class: 'vps-pl', hidden: true });
    /* 列头可点击排序 (ui.sorter 'vps-list'; 先排序再分页, 没排序时保持服务器给的顺序); 「操作」列不排序 */
    var so = ui.sorter('vps-list', {
      name: { get: function (r) { return r.name || r.id; } },
      addr: { get: function (r) { return r.host ? addrOf(r.host, r.ssh_port || 22) : null; } },
      user: { get: function (r) { return r.user; } },
      os: { get: function (r) { return r.os; } },
      ips: { type: 'num', get: function (r) { return Array.isArray(r.ips) ? r.ips.length : 0; } },          // 芯片列: 按个数排
      nodes: { type: 'num', get: function (r) { return Array.isArray(r.nodes) ? r.nodes.length : 0; } },
      updated: { type: 'date', get: function (r) { return r.updated || null; } }                             // 秒级时间戳; 没有 (显示「从未」) 排最后
    }, { onChange: function () { if (pg.page() !== 1) pg.setPage(1); else render(); } });                     // setPage 会触发分页的 onChange 重画
    var table = h('div', { class: 'tbl-wrap vps-table' }, h('table', { class: 'tbl' },
      h('thead', null, h('tr', null, ['name', 'addr', 'user', 'os', 'ips', 'nodes', 'updated', 'actions'].map(function (k) {
        return k === 'actions' ? h('th', { scope: 'col' }, L('vps.col.' + k)) : so.th(k, function () { return t('vps.col.' + k); });
      }))), list));
    function openWizard() { return TP.imp.open('vps-password'); }
    ui.act(addBtn, openWizard);
    var titleId = 'vps-card-t' + (++uid);
    card.setAttribute('aria-labelledby', titleId);
    card.appendChild(h('div', { class: 'card-h' }, ui.icon('server', 20, 'ci'), h('h3', { id: titleId }, L('vps.list.title'), ui.help('vps.list')), h('span', { class: 'muted sm' }, L('vps.list.sub')), addBtn));
    var pg = ui.pager('vps.list', { def: 10 }); pg.onChange(function () { render(); });
    card.appendChild(note); card.appendChild(pendBox); card.appendChild(table); card.appendChild(empty.el); card.appendChild(pg.el);
    C.el = card;

    function tip(b, text) { b._tip = text; b.setAttribute('aria-label', text); if (!b._un) b.title = text; }
    function line(label, box) { return h('div', { class: 'vps-line' }, label, box); }
    function setChips(box, items, none) {
      items = Array.isArray(items) ? items.map(String) : [];
      ui.memo(box, items.join('|') + '#' + none, function () {
        var f = document.createDocumentFragment();
        if (!items.length) { f.appendChild(h('span', { class: 'muted sm' }, none)); return f; }
        items.slice(0, LIST_MAX).forEach(function (x) { f.appendChild(h('span', { class: 'chip mono' }, x)); });
        if (items.length > LIST_MAX) f.appendChild(h('span', { class: 'muted sm' }, t('vps.row.more', { n: items.length - LIST_MAX })));
        return f;
      });
    }
    function makeRow() {
      var r = {}, row;
      r.name = h('b', { class: 'vps-name' }); r.addr = h('span', { class: 'mono sm' }); r.user = h('span', { class: 'chip' }); r.os = h('span', { class: 'chip' });
      r.lIps = h('span', { class: 'vps-lbl muted sm' }); r.lNodes = h('span', { class: 'vps-lbl muted sm' });
      r.ips = h('span', { class: 'vps-chips' }); r.nodes = h('span', { class: 'vps-chips' }); r.upd = h('div', { class: 'muted sm' });
      r.re = ui.ibtn('scan-search', t('vps.row.redetectShort')); r.fg = ui.ibtn('unbind', t('vps.row.forgetShort'), { cls: 'danger-t' });
      row = h('tr', null,
        h('td', null, r.name), h('td', null, r.addr), h('td', null, r.user), h('td', null, r.os),
        h('td', null, r.ips), h('td', null, r.nodes), h('td', null, r.upd), h('td', { class: 'c-act' }, h('div', { class: 'acts' }, r.re, r.fg)));
      row._r = r;
      ui.act(r.re, function () { return vps.openRedetect(row._rec); });
      ui.act(r.fg, function () { return forget(row._rec); });
      return row;
    }
    function updateRow(row, rec) {
      var r = row._r, why = TP.why.helper(), nm = rec.name || rec.id;
      row._rec = rec;
      setText(r.name, nm); setText(r.addr, addrOf(rec.host, rec.ssh_port || 22));
      setText(r.user, rec.user || ''); r.user.hidden = !rec.user;
      setText(r.os, rec.os || ''); r.os.hidden = !rec.os;
      setText(r.lIps, t('vps.row.ips')); setText(r.lNodes, t('vps.row.nodes'));
      setChips(r.ips, rec.ips, t('vps.row.noIps')); setChips(r.nodes, rec.nodes, t('vps.row.noNodes'));
      setText(r.upd, t('vps.row.updated', { when: fmt.rel(rec.updated) }));
      tip(r.re, t('vps.row.redetect', { name: nm })); tip(r.fg, t('vps.row.forget', { name: nm }));
      ui.avail(r.re, why || (busy[rec.id] ? t('vps.row.busy') : '')); ui.avail(r.fg, why || (busy[rec.id] ? t('vps.row.busy') : ''));
    }
    /* 待验证的部署: 服务器上已经部署好, 但本机验证没通过 (节点还没有添加); 这里可以重新验证 (不重新部署) 或放弃 */
    function renderPending() {
      var why = TP.why.helper();
      pendBox.hidden = !pending.length;
      TP.clear(pendBox);
      if (!pending.length) return;
      pendBox.appendChild(h('div', { class: 'vps-pl-h' }, ui.icon('warning', 16, 'ci'), h('b', null, t('vps.pl.title')), h('span', { class: 'muted sm' }, t('vps.pl.sub'))));
      pending.forEach(function (pd) {
        var ports = (Array.isArray(pd.ports) ? pd.ports : []).map(String), reason = own(VF_REASON, String(pd.reason || '')) ? String(pd.reason) : (pd.reason === 'pending' ? 'pending' : 'unknown');
        var vb = ui.btn(t('vps.pl.verify'), { icon: 'refresh', kind: 'primary', sm: true }), db = ui.btn(t('vps.pl.discard'), { icon: 'trash', sm: true });
        ui.act(vb, function () { return vps.openVerify(pd); });
        ui.act(db, async function () { if (await discardPending(pd)) load(); });
        ui.avail(vb, why); ui.avail(db, why);
        pendBox.appendChild(h('div', { class: 'vps-pl-row' },
          h('div', { class: 'vps-pl-main' }, h('b', { class: 'vps-name' }, String(pd.name || pd.host)), h('span', { class: 'mono sm' }, addrOf(pd.host, pd.ssh_port || 22)),
            ports.length ? h('span', { class: 'vps-chips' }, ports.map(function (x) { return h('span', { class: 'chip mono' }, 'TCP ' + x); })) : null),
          h('div', { class: 'muted sm' }, t('vps.pl.reason.' + reason), ' · ', t('vps.pl.nodes', { n: +pd.nodes || 0 }), pd.updated ? ' · ' + t('vps.row.updated', { when: fmt.rel(pd.updated) }) : ''),
          h('div', { class: 'vps-pl-acts' }, vb, db)));
      });
    }
    function render() {
      var why = TP.why.helper(), rows = loaded && data.length > 0;
      renderPending();
      C._seen = C._seen || card.isConnected;
      addBtn.hidden = !rows; ui.avail(addBtn, why);
      table.hidden = !rows; note.hidden = !(rows && err);
      if (!note.hidden) setText(note, t('vps.list.stale'));
      var pr = pg.update(rows ? data.length : 0);
      if (rows) { ui.syncList(list, so.apply(data).slice(pr.start, pr.end), function (x) { return x.id; }, makeRow, updateRow); empty.hide(); return; }
      ui.syncList(list, [], function (x) { return x.id; }, makeRow, updateRow);
      if (!loaded && !err) empty.show({ icon: 'refresh', text: S.locked ? t('why.locked') : t('common.loading') });
      else if (!loaded) empty.show({ icon: why ? 'wifi-off' : 'warning', text: why || t('vps.list.loadFail'), hint: why ? '' : TP.errMsg(err), action: { label: t('common.retry'), icon: 'refresh', fn: load } });
      else empty.show({ icon: 'server', text: t('vps.list.empty'), hint: t('vps.list.emptyHint'), action: { label: t('vps.list.add'), icon: 'plus', fn: openWizard } });
    }
    async function load() {
      if (S.locked || loading) return;
      loading = true; render();
      try {
        var r = await TP.helper('GET', '/api/vps');
        data = Array.isArray(r && r.vps) ? r.vps : []; loaded = true; err = null;
        try { var pr = await TP.helper('GET', '/api/vps/pending'); pending = Array.isArray(pr && pr.pending) ? pr.pending : []; } catch (e2) { /* 待验证列表读不到不影响主列表 */ }
      } catch (e) { if (e && e.kind === 'auth') { loading = false; return; } err = e; }
      loading = false; at = Date.now(); render();
    }
    async function forget(rec) {
      var why = TP.why.helper(), n = Array.isArray(rec.nodes) ? rec.nodes.length : 0;
      if (why) { ui.toast(why, 'warn'); return; }
      var ok = await ui.confirmDialog({
        title: t('vps.fg.title'), message: t('vps.fg.msg', { name: rec.name, host: rec.host }),
        detail: [t('vps.fg.d1'), t('vps.fg.d2', { n: n }), t('vps.fg.d3')], confirmText: t('vps.fg.go'), danger: true
      });
      if (!ok) return;
      busy[rec.id] = true; render();
      try { await TP.helper('POST', '/api/vps/forget', { form: { id: rec.id } }); }
      finally { delete busy[rec.id]; render(); }
      ui.toast(t('vps.fg.done', { name: rec.name }), 'ok');
      reloadCards();
    }
    C.reload = load; C.relang = render; C.refresh = render;
    card._reload = load;
    if (window.IntersectionObserver) {          // 卡片重新出现在屏幕上 (切换到服务器页 / 滚动到可见) 时刷新一次
      new IntersectionObserver(function (es) { if (es.some(function (e) { return e.isIntersecting; }) && Date.now() - at > 3000) load(); }).observe(card);
    }
    cards.push(C);
    render();
    if (!S.locked) load();
    return card;
  };

  /* ================================================================================
   * 重新识别出口 IP: TP.vps.openRedetect(record) — 重新输入凭据 (不预填), 确认, 进度, 结果
   * ================================================================================ */
  vps.openRedetect = function (rec) {
    var why = TP.why.helper();
    if (why) { ui.toast(why, 'warn', 5200); return null; }
    if (reOpen) return reOpen.api;
    var port = rec.ssh_port || 22, target = String(rec.user || '') + '@' + addrOf(rec.host, port);
    var phase = 'form', run = 0, creds = null, card = null, errInfo = null, out = null, api = null;
    var cf = credForm({ mode: 'password', host: rec.host, port: port, user: rec.user || 'root', onEnter: function () { go(); } });
    var seg = ui.seg(L('vps.mode.aria'), [{ v: 'password', label: L('vps.mode.password'), icon: 'lock' }, { v: 'key', label: L('vps.mode.key'), icon: 'key-round' }], function (v) { cf.setMode(v); });
    cf.seg = seg; seg.set('password');
    var formBox = h('div', { class: 'vps-form' },
      h('p', { class: 'vps-intro muted sm' }, L('vps.re.intro')),
      h('div', { class: 'vps-re-sum' }, ui.icon('server', 18, 'ci'), h('b', null, rec.name || rec.id), h('span', { class: 'mono sm muted' }, target)),
      seg.el, cf.el,
      h('p', { class: 'hint vps-privacy' }, ui.icon('lock', 15, 'ci'), h('span', null, L('vps.privacy'))));
    var view = h('div', { class: 'vps-view', hidden: true }), live = h('div', { class: 'sr', role: 'status', 'aria-live': 'polite' });
    var body = h('div', { class: 'vps vps-re' }, formBox, view, live);

    function footer() {
      var why = TP.why.helper();
      if (phase === 'form') return [{ label: t('common.cancel'), cancel: true }, { label: t('vps.re.go'), kind: 'primary', icon: 'scan-search', id: 'go', keep: true, unavail: why ? { reason: why } : null, onClick: async function () { await go(); return false; } }];
      if (phase === 'error') return [{ label: t('vps.backEdit'), icon: 'chevron-left', id: 'back', keep: true, onClick: function () { back(); return false; } }, { label: t('common.retry'), kind: 'primary', icon: 'refresh', id: 'retry', keep: true, onClick: async function () { await runIt(); return false; } }];
      if (phase === 'result') return [{ label: t('common.close'), kind: 'primary', id: 'close', cancel: true }];
      return [];
    }
    function paint(keepFocus) {
      formBox.hidden = phase !== 'form'; view.hidden = phase === 'form';
      if (phase !== 'form') {
        TP.clear(view);
        if (phase === 'run') view.appendChild(h('div', { class: 'vps-stage' }, h('h3', { class: 'vps-h', tabindex: '-1' }, ui.icon('scan-search', 20, 'ci'), t('vps.re.head')), h('p', { class: 'muted sm vps-target' }, t('vps.target', { target: target })), card.el, h('p', { class: 'muted sm' }, t('vps.re.note'))));
        else if (phase === 'error') view.appendChild(h('div', { class: 'vps-err' }, h('h3', { class: 'vps-h bad-t', tabindex: '-1' }, ui.icon('error', 20, 'ci'), t('vps.err.reTitle')), h('p', { class: 'vps-err-m' }, errInfo.msg),
          errInfo.hint ? h('p', { class: 'hint warn' }, ui.icon('info', 15, 'ci'), h('span', null, errInfo.hint)) : null,
          errInfo.detail ? h('div', { class: 'skipped' }, ui.detailsBtn(t('common.details'), t('common.details'), function () { return h('p', { class: 'mono sm vps-raw' }, errInfo.detail); })) : null));
        else if (phase === 'result') view.appendChild(resultView());
      }
      api.setBusy(phase === 'run'); api.setActions(footer());
      if (!keepFocus) { toTop(body); focusSoon(phase === 'form' ? cf.firstInput() : view.querySelector('.vps-h')); }
    }
    function resultView() {
      var n = out.nodes.length, root = h('div', { class: 'vps-done' });
      root.appendChild(h('div', { class: 'done-box' }, h('div', { class: 'done-t' }, h('span', { class: 'ck ok' }, ui.icon('check', 13)), h('h3', { class: 'vps-h vps-plain', tabindex: '-1' }, t(out.known ? (out.ips.length ? 'vps.re.found' : 'vps.re.none') : 'vps.re.finished'))),
        h('p', { class: 'vps-done-m' }, out.known ? (out.ips.length ? t('vps.re.summary', { n: out.ips.length }) : t('vps.re.noneMsg')) : t('vps.re.finishedMsg'))));
      if (out.ips.length) root.appendChild(h('div', { class: 'vps-line' }, h('span', { class: 'muted sm' }, t('vps.re.newIps')), chips(out.ips)));
      if (n) root.appendChild(h('div', { class: 'vps-line' }, h('span', { class: 'muted sm' }, t('vps.re.newNodes')), chips(out.nodes)));
      return root;
    }
    function back() { run++; creds = null; cf.wipeSecrets(); phase = 'form'; errInfo = null; paint(); }
    function wipe() { run++; creds = null; cf.wipeSecrets(); card = null; }

    /* 确认 -> 提交 (凭据在请求体里; 提交后立即清空输入框, 只剩闭包里这一份用于「重试」) */
    async function go() {
      var why = TP.why.helper(); if (why) { ui.toast(why, 'warn'); return; }
      if (phase !== 'form') return;
      var v = cf.check();
      if (!v) return;
      var ok = await ui.confirmDialog({
        title: t('vps.re.cfTitle'), message: t('vps.re.cfMsg', { name: rec.name || rec.id, target: target }),
        detail: [t('vps.re.cf1'), t('vps.re.cf2'), t('vps.re.cf3'), t('vps.re.cf4')], confirmText: t('vps.re.cfGo')
      });
      if (!ok) { v = null; return; }                                  // 取消: 表单保持原样
      creds = { host: v.host, port: +v.port, user: v.user, mode: v.mode, password: v.password, key: v.key, passphrase: v.passphrase, sudo: v.sudo };
      v = null; cf.wipeSecrets();
      return runIt();
    }
    async function fetchRecord() {
      try { var r = await TP.helper('GET', '/api/vps'); return (Array.isArray(r && r.vps) ? r.vps : []).filter(function (x) { return x.id === rec.id; })[0] || null; } catch (e) { return null; }
    }
    async function runIt() {
      var my = ++run, f = formOf(creds);
      f.id = rec.id;
      if (rec.hostkey) f.hostkey = String(rec.hostkey);               // 记录里带了指纹 (docs/API.md 建议的字段) 就固定校验, 防中间人
      card = ui.taskCard(t('vps.card.progress'), { horizontal: false });
      phase = 'run'; paint(); live.textContent = t('vps.say.reRunning');
      try {
        await remote('/api/vps/redetect', f, card, t('vps.re.running'));
        f = null;
        if (my !== run) return;
        var after = await fetchRecord(), bi = Array.isArray(rec.ips) ? rec.ips : [], bn = Array.isArray(rec.nodes) ? rec.nodes : [];
        out = after ? { known: true, ips: (after.ips || []).filter(function (x) { return bi.indexOf(x) < 0; }), nodes: (after.nodes || []).filter(function (x) { return bn.indexOf(x) < 0; }) }
          : { known: false, ips: [], nodes: [] };
        creds = null; cf.wipeSecrets();                                 // 成功: 凭据立即清除
        TP.afterApply(); TP.loadState(); reloadCards();
        phase = 'result'; paint();
        ui.toast(out.known && out.ips.length ? t('vps.re.toast', { n: out.ips.length }) : t('vps.re.toastNone'), 'ok');
      } catch (e) {
        f = null;
        if (my !== run) return;
        errInfo = explain(e, 'redetect'); phase = 'error'; paint();
      }
    }

    api = ui.modal({
      title: t('vps.re.title'), icon: 'scan-search', iconKind: 'pri', size: 'md', cls: 'vps-dlg', body: body,
      dirty: function () { return phase === 'form' && cf.hasInput(); },
      lock: function () { return phase === 'run'; },
      onClose: function () { wipe(); reOpen = null; },
      actions: footer()
    });
    reOpen = { api: api, refresh: function () { if (phase === 'form') api.setActions(footer()); }, relang: function () { api.setTitle(t('vps.re.title')); if (card) card.setTitle(t('vps.card.progress')); paint(true); } };
    focusSoon(cf.firstInput());
    return api;
  };

  /* ================================================================================
   * 重新验证待验证的部署: TP.vps.openVerify(pending) — 只在本机验证 (没有 SSH, 不重新部署, 不需要任何凭据); 通过后节点才加到本机
   * ================================================================================ */
  var vOpen = null;
  vps.openVerify = function (pd) {
    var why = TP.why.helper();
    if (why) { ui.toast(why, 'warn', 5200); return null; }
    if (vOpen) return vOpen.api;
    var phase = 'run', run = 0, card = null, errInfo = null, out = null, api = null, target = addrOf(pd.host, pd.ssh_port || 22);
    var view = h('div', { class: 'vps-view' }), live = h('div', { class: 'sr', role: 'status', 'aria-live': 'polite' }), body = h('div', { class: 'vps vps-re' }, view, live);
    function footer() {
      if (phase === 'error') return [{ label: t('vps.vf.discard'), icon: 'trash', id: 'discard', keep: true, onClick: async function () { if (await discardPending(pd)) { reloadCards(); api.close(true); } return false; } },
        { label: t('common.close'), id: 'close', cancel: true }, { label: t('vps.vf.go'), kind: 'primary', icon: 'refresh', id: 'retry', keep: true, onClick: async function () { await runIt(); return false; } }];
      if (phase === 'result') return [{ label: t('common.close'), kind: 'primary', id: 'close', cancel: true }];
      return [];
    }
    function paint() {
      TP.clear(view);
      if (phase === 'run') view.appendChild(h('div', { class: 'vps-stage' }, h('h3', { class: 'vps-h', tabindex: '-1' }, ui.icon('refresh', 20, 'ci'), t('vps.vf.head')), h('p', { class: 'muted sm vps-target' }, t('vps.target', { target: target })), card.el, h('p', { class: 'muted sm' }, t('vps.vf.note'))));
      else if (phase === 'error') {
        view.appendChild(h('div', { class: 'vps-err' }, h('h3', { class: 'vps-h bad-t', tabindex: '-1' }, ui.icon('error', 20, 'ci'), t(errInfo.pending ? 'vps.err.pendTitle' : 'vps.vf.failTitle')),
          h('p', { class: errInfo.pending ? 'vps-err-lead' : 'vps-err-m' }, errInfo.msg), errInfo.pending && errInfo.info ? vfPanel(errInfo.info) : null,
          errInfo.hint ? h('p', { class: 'hint warn' }, ui.icon('info', 15, 'ci'), h('span', null, errInfo.hint)) : null,
          errInfo.detail ? h('div', { class: 'skipped' }, ui.detailsBtn(t('common.details'), t('common.details'), function () { return h('p', { class: 'mono sm vps-raw' }, errInfo.detail); })) : null));
      } else if (phase === 'result') {
        var nodes = Array.isArray(out.nodes) ? out.nodes : [], ul = h('ul', { class: 'vps-nodes' });
        nodes.forEach(function (n) { ul.appendChild(h('li', { class: 'vps-node' }, h('b', { class: 'vps-node-t' }, String(n.tag)), h('span', { class: 'vps-node-m' }, h('span', { class: 'mono sm' }, addrOf(n.server, n.port)), n.egress ? h('span', { class: 'chip mono' }, ui.icon('globe', 13, 'ci'), String(n.egress)) : null))); });
        view.appendChild(h('div', { class: 'vps-done' }, h('div', { class: 'done-box' }, h('div', { class: 'done-t' }, h('span', { class: 'ck ok' }, ui.icon('check', 13)), h('h3', { class: 'vps-h vps-plain', tabindex: '-1' }, t('vps.vf.doneTitle'))),
          h('p', { class: 'vps-done-m' }, t('vps.vf.doneMsg', { n: nodes.length }))), nodes.length ? ul : null));
      }
      api.setBusy(phase === 'run'); api.setActions(footer());
      focusSoon(view.querySelector('.vps-h'));
    }
    async function runIt() {
      var my = ++run;
      card = ui.taskCard(t('vps.card.progress'), { horizontal: false });
      phase = 'run'; paint(); live.textContent = t('vps.say.verifying');
      try {
        var j = await remote('/api/vps/verify', { id: String(pd.id) }, card, t('vps.vf.running'));
        if (my !== run) return;
        out = j.result && typeof j.result === 'object' ? j.result : {};
        TP.afterApply(); TP.loadState(); reloadCards();
        phase = 'result'; paint();
        ui.toast(t('vps.vf.done'), 'ok');
      } catch (e) {
        if (my !== run) return;
        errInfo = explain(e, 'verify'); phase = 'error'; paint();
        reloadCards();
      }
    }
    api = ui.modal({
      title: t('vps.vf.title'), icon: 'refresh', iconKind: 'pri', size: 'md', cls: 'vps-dlg', body: body,
      lock: function () { return phase === 'run'; },
      onClose: function () { run++; card = null; vOpen = null; },
      actions: []
    });
    vOpen = { api: api, relang: function () { api.setTitle(t('vps.vf.title')); if (card) card.setTitle(t('vps.card.progress')); } };
    runIt();
    return api;
  };

  /* ================= 模块级事件: 切换语言 / 辅助服务状态变化 / 登录 ================= */
  TP.on('lang', function () { pruneList(panes); panes.forEach(function (p) { p.relang(); }); cards.forEach(function (c) { c.relang(); }); if (reOpen) reOpen.relang(); if (vOpen) vOpen.relang(); });
  TP.on('helper', function () { pruneList(panes); panes.forEach(function (p) { p.refreshFoot(); }); cards.forEach(function (c) { c.refresh(); }); if (reOpen) reOpen.refresh(); });
  TP.on('auth', function (ok) { if (ok) cards.forEach(function (c) { c.reload(); }); });
  TP.on('state', function () { cards.forEach(function (c) { if (c.el.isConnected && c.el.getClientRects().length) c.refresh(); }); });     // 「更新于 N 分钟前」随状态轮询刷新
})();
