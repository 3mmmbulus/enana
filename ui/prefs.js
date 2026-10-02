/* enana · prefs.js — 界面习惯 (表格每页条数 / 当前页 / 侧栏 / 主题 / 上次打开的标签页 / 测速选择 / 欢迎卡片 / IP 隐藏 …)
 * 存两处: 浏览器 localStorage 里的缓存 (首屏不闪) + 本机 prefs.json (GET / POST /api/prefs; 开启云端同步后会端到端加密同步到其它电脑)。
 * 以 GET /api/prefs 为准: 登录后读取一次; GET /api/state 里的 prefs_version 变了 (别的设备同步过来了改动) 就重新读取并应用; 本地写入做 500 ms 防抖。
 * 键名分命名空间: table.<id>.pageSize / table.<id>.page · ui.theme · ui.sidebar · ui.tab · ui.settings.tab · ui.welcome · speed.mask · speed.sel.* …
 *   TP.prefs.get(key, 默认值)  TP.prefs.set(key, 值 | undefined=删除)  TP.on('prefs', fn)  (fn 收到 {key} 或 {all:true})
 * 值必须是可 JSON 化的; 整个对象 <= 32 KB。没有登录 / 辅助服务不可用时只用本地缓存, 之后会自动补上传。 */
(function () {
  'use strict';
  var TP = window.TP, S = TP.S, P = TP.prefs = {};
  var KEY = 'prefs', LIMIT = 30000;
  var data = TP.ls.get(KEY, null);
  if (!data || typeof data !== 'object' || Array.isArray(data)) data = {};
  var known = +TP.ls.get('prefs.ver', 0) || 0;          // 最近一次和本机同步过的版本号
  var pending = {}, timer = 0, pushing = false, pulling = false, ready = false;

  function same(a, b) { return JSON.stringify(a) === JSON.stringify(b); }
  function saveLocal() { TP.ls.set(KEY, data); }
  P.get = function (k, d) { return Object.prototype.hasOwnProperty.call(data, k) && data[k] !== undefined ? data[k] : d; };
  P.all = function () { return JSON.parse(JSON.stringify(data)); };
  P.set = function (k, v) {
    if (v === undefined || v === null) { if (!(k in data)) return; delete data[k]; pending[k] = null; }
    else { if (same(data[k], v)) return; data[k] = v; pending[k] = v; }
    saveLocal(); schedule(); TP.emit('prefs', { key: k });
  };
  function schedule() { clearTimeout(timer); timer = setTimeout(push, 500); }

  /* 把整个对象写回本机 (登录之后才会写; 失败就留到下一次) */
  async function push() {
    if (S.locked || pushing || !Object.keys(pending).length) return;
    var body = JSON.stringify(data);
    if (body.length > LIMIT) { console.warn('[prefs] too large, not saved'); return; }
    var sent = Object.keys(pending); pushing = true;
    try {
      var r = await TP.helper('POST', '/api/prefs', { body: body, timeout: 8000 });
      if (r && +r.version) { known = +r.version; TP.ls.set('prefs.ver', known); }
      sent.forEach(function (k) { if (same(pending[k], data[k]) || (pending[k] === null && !(k in data))) delete pending[k]; });
    } catch (e) { /* 失败: 保持 pending, 下次再试 */ }
    pushing = false;
    if (Object.keys(pending).length) schedule();
  }

  /* 从本机读取 (登录后 / prefs_version 变化时) */
  P.pull = async function (force) {
    if (S.locked || pulling) return;
    pulling = true;
    try {
      var r = await TP.helper('GET', '/api/prefs', { timeout: 8000 });
      var ver = +r.version || 0, remote = r && r.prefs && typeof r.prefs === 'object' && !Array.isArray(r.prefs) ? r.prefs : {};
      if (!force && ver === known && ready) return;
      if (ver === 0 && !Object.keys(remote).length && Object.keys(data).length) {        // 本机还没有存过: 把浏览器里已有的习惯迁移过去
        Object.keys(data).forEach(function (k) { pending[k] = data[k]; });
        schedule();
      } else {
        var next = {}; Object.keys(remote).forEach(function (k) { next[k] = remote[k]; });
        Object.keys(pending).forEach(function (k) { if (pending[k] === null) delete next[k]; else next[k] = pending[k]; });     // 还没来得及上传的本地改动优先
        var changed = !same(next, data);
        data = next; saveLocal();
        if (changed) TP.emit('prefs', { all: true });
      }
      known = ver; TP.ls.set('prefs.ver', known);
    } catch (e) { /* 辅助服务暂时不可用: 继续用本地缓存 */ }
    ready = true; pulling = false;
    if (Object.keys(pending).length) schedule();
  };

  TP.on('auth', function (ok) { if (ok) { ready = false; P.pull(true); } else { clearTimeout(timer); } });
  TP.on('state', function () {
    var v = S.state && +S.state.prefs_version;
    if (v && v !== known && !pushing && !Object.keys(pending).length) P.pull(true);
  });
  window.addEventListener('pagehide', function () { if (Object.keys(pending).length && !S.locked) push(); });
})();
