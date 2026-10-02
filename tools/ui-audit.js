/* 仪表盘「点一遍」检查: 找 JS 报错 (未捕获的异常 / 未处理的 Promise 拒绝 / console.error)。
 * 用法: 登录仪表盘 (本机 mock 或开发实例都行, 不要在装着真实数据的实例上点), 把这个文件整个粘进浏览器的控制台, 然后逐页运行:
 *     for (const p of ['overview','apps','sites','rules','dns','servers','conns','traffic','speed','logs','settings']) console.log(await __audit(p));
 *     __errs        // 每一条都带「在哪一页、点了哪个按钮」
 * 它会依次点这一页上所有可见的按钮 / 标签 / 分段控件 (删除 / 退出 / 重启 / 开关代理 / 保存 / 部署 这类会改东西的跳过), 点开弹窗后再逐个点弹窗里的标签页, 然后关掉。
 * 每次最多跑 budgetMs (默认 25 秒), 页面按钮多时重复运行同一页会接着往下点。 */
(function () {
  window.__errs = []; window.__where = 'init';
  const rec = (kind, msg) => window.__errs.push(window.__where + ' :: ' + kind + ': ' + String(msg).slice(0, 300));
  window.addEventListener('error', (e) => rec('error', e.message + ' @' + (e.filename || '').split('/').pop() + ':' + e.lineno));
  window.addEventListener('unhandledrejection', (e) => rec('rejection', (e.reason && (e.reason.stack || e.reason.message)) || e.reason));
  const ce = console.error;
  console.error = function () { try { rec('console.error', Array.prototype.slice.call(arguments).map((x) => (x && x.message) || String(x)).join(' ')); } catch (e) { /* 忽略 */ } return ce.apply(console, arguments); };
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const DANGER = /删除|清除|退出|下线|卸载|重置|撤销|断开|重启|开启代理|关闭代理|停用|应用更新|更新到|检查更新|开始测速|重新测速|停止|确认|忘记|解除|踢|开启|关闭|采纳|全部保持|保存|提交|部署|添加服务器$|导入并|检测服务器|登录|注册|Delete|Remove|Clear|Sign out|Log ?out|Restart|Reset|Uninstall|Kick|Stop|Undo|Disconnect|Update to|Turn o|Save|Submit|Deploy|Sign in|Register/;
  const visible = (e) => e && e.offsetParent !== null && !e.disabled && e.getAttribute('aria-disabled') !== 'true';
  const label = (b) => ((b.textContent || '').trim() || b.getAttribute('aria-label') || b.title || '').replace(/\s+/g, ' ').slice(0, 40);
  async function closeDialogs() {
    for (let i = 0; i < 4; i++) {
      const d = document.querySelector('dialog[open]'); if (!d) return;
      const c = [...d.querySelectorAll('button')].find((b) => /^(取消|关闭|Cancel|Close|知道了|好)$/.test(label(b)) || b.getAttribute('aria-label') === '关闭');
      if (c) c.click(); else document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
      await sleep(150);
      if (document.querySelector('dialog[open]') === d) { try { d.close(); } catch (e) { /* 忽略 */ } await sleep(100); }
    }
  }
  window.__audit = async function (p, budgetMs) {
    const t0 = Date.now(); budgetMs = budgetMs || 25000;
    window.__where = 'page ' + p;
    try { window.TP.go(p); } catch (e) { rec('go-failed', e.message); }
    await sleep(900);
    const main = document.querySelector('main') || document.body;
    const seen = (window.__seen = window.__seen || {}); const sk = seen[p] = seen[p] || new Set(); let n = 0, left = 0;
    for (let round = 0; round < 3; round++) {
      const btns = [...main.querySelectorAll('button, [role=tab], [role=radio], summary')].filter(visible);
      let progressed = false;
      for (const b of btns) {
        const lab = label(b), key = lab + '|' + (b.getAttribute('data-id') || b.getAttribute('aria-controls') || '');
        if (sk.has(key) || DANGER.test(lab)) continue;
        if (Date.now() - t0 > budgetMs) { left++; continue; }
        sk.add(key); progressed = true;
        window.__where = 'page ' + p + ' · click "' + lab + '"';
        try { b.click(); } catch (e) { rec('click-throw', e.message); }
        n++;
        await sleep(300);
        const d = document.querySelector('dialog[open]');
        if (d) {
          const tabs = [...d.querySelectorAll('[role=tab]')].filter(visible);
          for (const t of tabs) { window.__where = 'page ' + p + ' · "' + lab + '" dialog tab "' + label(t) + '"'; try { t.click(); } catch (e) { rec('click-throw', e.message); } await sleep(350); }
          await closeDialogs();
        }
      }
      if (!progressed) break;
    }
    return { page: p, clicked: n, left: left, errors: window.__errs.length };
  };
  console.log('ui-audit 已就绪: await __audit("overview") …  结果看 __errs');
})();
