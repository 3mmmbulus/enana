(function () {
  'use strict';
  var token = new URLSearchParams(location.hash.slice(1)).get('token') || '';
  // Keep verification tokens out of referrers, browser history and analytics.
  history.replaceState(null, '', location.pathname);
  var button = document.getElementById('verify-submit');
  var status = document.getElementById('verify-status');
  var busy = false;
  if (!/^[A-Za-z0-9_.-]{30,4096}$/.test(token)) {
    token = ''; button.disabled = true;
    status.textContent = '验证链接无效。请在 enana 仪表盘重新发送验证邮件。';
  }
  button.addEventListener('click', async function () {
    if (busy || !token) return;
    busy = true; button.disabled = true; button.textContent = '正在验证…';
    try {
      var response = await fetch('https://api.enana.cc/api/collections/users/confirm-verification', {
        method: 'POST', credentials: 'omit', redirect: 'error',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ token: token }), signal: AbortSignal.timeout(15000)
      });
      if (!response.ok) {
        token = '';
        status.textContent = '验证链接已失效或已经使用。请返回 enana 检查邮箱状态；尚未验证时可重新发送。';
        button.textContent = '链接已失效'; return;
      }
      token = ''; status.textContent = '邮箱验证成功。现在可以返回 enana 仪表盘。';
      button.textContent = '已验证';
    } catch (_) {
      status.textContent = '暂时无法连接验证服务，请稍后重试。';
      button.disabled = false; button.textContent = '重试验证';
    } finally { busy = false; }
  });
}());
