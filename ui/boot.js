/* enana · boot.js — 页面绘制之前先应用主题和侧栏状态, 避免闪烁。只读 localStorage (prefs 缓存; 旧版的单独键作后备), 没有其它逻辑。
 * 侧栏: >= 1100px 按用户上次的选择 (展开 / 折叠); 760–1099px 自动收成图标栏; < 760px 是抽屉 (app.js 随窗口大小实时切换)。 */
(function () {
  'use strict';
  try {
    var pf = JSON.parse(localStorage.getItem('enana.prefs') || 'null') || {}, r = document.documentElement, w = window.innerWidth || 1280;
    var th = pf['ui.theme'] || JSON.parse(localStorage.getItem('enana.theme')), nv = pf['ui.sidebar'] || JSON.parse(localStorage.getItem('enana.nav'));
    if (th === 'light' || th === 'dark') r.setAttribute('data-theme', th);
    if (pf['ui.density'] === 'compact') r.setAttribute('data-density', 'compact');
    if (w >= 760 && (w < 1100 || nv === 'collapsed')) r.setAttribute('data-nav', 'collapsed');
    r.setAttribute('data-navmode', w < 760 ? 'drawer' : (w < 1100 || nv === 'collapsed') ? 'rail' : 'full');
  } catch (e) { /* 隐私模式 / 禁用存储: 忽略, 用默认外观 */ }
  /* 页面外壳 (.shell) 在登录状态确定之前不显示, 免得退出状态下刷新时先闪一下仪表盘 (auth.js 确定后加 ui-ready); 万一脚本出错, 4 秒后也照常显示 */
  setTimeout(function () { document.documentElement.classList.add('ui-ready'); }, 4000);
})();
