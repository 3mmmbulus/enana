// 导入器测试 (node): 全部使用占位数据。运行: node tests/importer.test.js
const assert = require('assert'); const I = require('../ui/importer.js');
let n = 0; const t = (name, fn) => { fn(); n++; console.log('  ✓', name); };
const b64 = s => Buffer.from(s).toString('base64');

t('保留前缀: 别的订阅里以「官方-」开头的节点名被改成「官方 」开头 (安装端保留 官方- 给会员的官方线路, 整行被拒绝会丢节点)', () => {
  const r = I.parse(JSON.stringify({ outbounds: [
    { type: 'trojan', tag: '官方-香港', server: 'a.example.com', server_port: 443, password: 'p' },
    { type: 'trojan', tag: '官方 香港', server: 'b.example.com', server_port: 443, password: 'p' },
    { type: 'trojan', tag: 'enana-official-x', server: 'c.example.com', server_port: 443, password: 'p' },
    { type: 'trojan', tag: '官方版', server: 'd.example.com', server_port: 443, password: 'p' }] }));
  assert.deepStrictEqual(r.servers.map(s => s.outbound.tag), ['官方 香港', '官方 香港 2', 'enana official x', '官方版']);
});

t('Clash YAML (块式, 含嵌套列表与 TLS 上的 SOCKS5)', () => {
  const r = I.parse(`proxies:
- name: A
  type: http
  server: example.com
  port: 443
  username: u
  password: p
  tls: true
- alpn:
  - h3
  name: B
  type: tuic
  server: example.org
  port: 443
  uuid: 11111111-2222-3333-4444-555555555555
  password: pw
  congestion-controller: bbr
- name: C
  type: socks5
  server: example.net
  port: 443
  tls: true
rules:
- MATCH,DIRECT`);
  assert.strictEqual(r.format, 'clash-yaml'); assert.strictEqual(r.servers.length, 2); assert.strictEqual(r.skipped.length, 1);
  assert.deepStrictEqual(r.servers[1].outbound.tls.alpn, ['h3']); assert.strictEqual(r.servers[1].outbound.congestion_control, 'bbr');
});
t('Base64 订阅 (vless reality / vmess ws / ss / hysteria2 / trojan)', () => {
  const lines = [
    'vless://11111111-2222-3333-4444-555555555555@203.0.113.7:443?security=reality&sni=www.example.com&fp=chrome&pbk=KEY&sid=ab&type=tcp&flow=xtls-rprx-vision#R',
    'vmess://' + b64(JSON.stringify({ ps: 'V', add: 'vm.example.com', port: '443', id: '11111111-2222-3333-4444-555555555555', aid: '0', net: 'ws', host: 'vm.example.com', path: '/p?ed=2048', tls: 'tls' })),
    'ss://' + b64('aes-256-gcm:pw') + '@203.0.113.8:8388#S', 'hysteria2://pw@203.0.113.2:8443/?insecure=1&sni=a.com#H', 'trojan://pw@example.com:443?sni=example.com#T',
  ].join('\n');
  const r = I.parse(b64(lines));
  assert.deepStrictEqual(r.servers.map(s => s.outbound.type), ['vless', 'vmess', 'shadowsocks', 'hysteria2', 'trojan']);
  assert.ok(r.servers[0].outbound.tls.reality); assert.strictEqual(r.servers[1].outbound.transport.max_early_data, 2048);
});
t('订阅链接 / 包装链接 / Shadowrocket 描述 JSON 被识别为订阅 (不是代理)', () => {
  assert.strictEqual(I.classify('https://sub.example.com/s/TOKEN').urls.length, 1);
  assert.strictEqual(I.classify('clash://install-config?url=' + encodeURIComponent('https://sub.example.com/c/1')).urls[0], 'https://sub.example.com/c/1');
  assert.strictEqual(I.classify(JSON.stringify({ type: 'Subscribe', host: 'https://sub.example.com/s/T' })).urls.length, 1);
  assert.strictEqual(I.classify('https://203.0.113.9:443').urls.length, 0);               // 无路径: 当作 HTTPS 代理
  assert.strictEqual(I.classify('https://u:p@203.0.113.9:443#x').urls.length, 0);          // 带凭据: 代理
});
t('sing-box JSON 原样接收, 去掉 detour 与分组', () => {
  const r = I.parse(JSON.stringify({ outbounds: [{ type: 'direct', tag: 'direct' }, { type: 'selector', tag: 'S', outbounds: [] }, { type: 'vless', tag: 'V', server: 'a.example.com', server_port: 443, uuid: 'u', detour: 'x' }] }));
  assert.strictEqual(r.servers.length, 1); assert.ok(!('detour' in r.servers[0].outbound));
});
t('订阅里的流量/到期提示节点被忽略; 保留名与重名自动改名', () => {
  const r = I.parse(['trojan://pw@127.0.0.1:1#剩余流量: 1G', 'trojan://pw@a.example:443#direct', 'trojan://pw@b.example:443#direct'].join('\n'));
  assert.strictEqual(r.servers.length, 2); assert.notStrictEqual(r.servers[0].outbound.tag, 'direct'); assert.notStrictEqual(r.servers[0].outbound.tag, r.servers[1].outbound.tag);
});
t('JSONL 约定: 每行以 role/outbound 开头, outbound 的 type 与 tag 在最前', () => {
  const r = I.parse('trojan://pw@a.example:443#T'); const l = I.toJSONL(r.servers, 'demo').trim();
  assert.ok(/^\{"role":"auto","sub":"demo","outbound":\{"type":"trojan","tag":"T",/.test(l));
});
t('链接里无 TLS 标记的 443 端口 SOCKS5 被跳过并说明; 缺凭据的 https 代理带警告', () => {
  assert.strictEqual(I.parse('socks5://u:p@203.0.113.5:443#S').skipped.length, 1);
  assert.strictEqual(I.parse('https://203.0.113.4:443#H').servers[0].warn, 'import.warn.noCreds');
});
t('跳过的链接行只给行号, 不回显原文 (界面显示「第 N 行」)', () => {
  const r = I.parse('trojan://pw@a.example:443#T\n# 注释\nfoo bar baz');
  assert.deepStrictEqual(r.skipped.map(s => [s.reason, s.line, s.name]), [['import.reason.badLine', 3, undefined]]);
});
t('classify 保留 YAML 缩进 (回归: 曾经被逐行 trim 导致只解析出 1/3 个节点)', () => {
  const y = 'https://sub.example.com/s/TOKEN\nproxies:\n- name: A\n  type: http\n  server: example.com\n  port: 443\n- name: B\n  type: http\n  server: example.org\n  port: 443\n- name: C\n  type: http\n  server: example.net\n  port: 443\n';
  const c = I.classify(y);
  assert.strictEqual(c.urls.length, 1);
  assert.strictEqual(I.parse(c.content).servers.length, 3);
  assert.strictEqual(I.classify('https://sub.example.com/s/T').content, '');
});
/* 词典: tools/i18n-check.js 不扫描 importer.js, 所以在这里查: importer.js 用到的 import.reason.* / import.warn.* 键, 中英文都要有, 占位符要和调用处传的 vars 一致 */
const fs = require('fs'), path = require('path'), vm = require('vm');
const dictOf = code => {
  const dict = {}, box = { I18N: { register: (c, d) => { Object.assign(dict[c] || (dict[c] = {}), d); } } };
  box.window = box.self = box.globalThis = box;
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../ui/i18n/' + code + '.js'), 'utf8'), box, { filename: code + '.js' });
  return dict[code];
};
const names = s => [...new Set((String(s).match(/\{\w+\}/g) || []).map(m => m.slice(1, -1)))].sort();
t('import.reason.* / import.warn.*: 中英文都有, 占位符与 importer.js 里传的 vars 一致', () => {
  const en = dictOf('en'), zh = dictOf('zh'), used = {};
  fs.readFileSync(path.join(__dirname, '../ui/importer.js'), 'utf8').split('\n').forEach(line => {
    const keys = line.match(/'import\.(?:reason|warn)\.[A-Za-z0-9_.]+'/g) || [], v = /vars:\s*\{([^}]*)\}/.exec(line);
    const got = v ? v[1].split(',').map(s => s.split(':')[0].trim()).filter(Boolean).sort() : [];
    keys.forEach(k => { (used[k.slice(1, -1)] = used[k.slice(1, -1)] || []).push({ got, line }); });
  });
  assert.ok(Object.keys(used).length >= 18, '没有找到 import.reason.* 的用法 (检查上面的正则)');
  for (const key of Object.keys(used)) {
    assert.strictEqual(typeof en[key], 'string', 'en 缺少 ' + key);
    assert.strictEqual(typeof zh[key], 'string', 'zh 缺少 ' + key);
    assert.deepStrictEqual(names(zh[key]), names(en[key]), key + ': 中英文占位符不一致');
    for (const u of used[key]) assert.deepStrictEqual(u.got, names(en[key]), key + ' 调用处的 vars 与词典占位符不一致: ' + u.line.trim());
  }
});

/* 确认窗口的管理员提示 (TP.tunDetail, 定义在 ui/actions.js): 不开 TUN 原样返回; 开了 TUN 时另起一段, 不混进正文或列表 */
t('TP.tunDetail: 不开 TUN 原样返回; 开了 TUN 时提示另起一段 (正文一段 + 提示一段; 列表 + 提示一段)', () => {
  const h = (tag, props, ...kids) => ({ tag, kids: kids.filter(k => k != null && k !== false) });
  const S = { state: { proxy: { network_mode: 'system' } } };
  const TP = { S, h, on() {}, ui: {}, setText() {}, why: { helper: () => '' } };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../ui/actions.js'), 'utf8'),
    { window: { TP, I18N: { t: k => k, L: k => k } }, document: { contains: () => true }, console, setInterval() {}, setTimeout() { return 0; } }, { filename: 'actions.js' });
  const arr = ['一', '二'];
  assert.strictEqual(TP.tunDetail(arr), arr);
  assert.strictEqual(TP.tunDetail('正文'), '正文');
  S.state.proxy.network_mode = 'tun';
  assert.deepStrictEqual(TP.tunDetail('正文').kids.map(k => k.tag), ['p', 'p']);
  const l = TP.tunDetail(['一', '二']);
  assert.deepStrictEqual(l.kids.map(k => k.tag), ['ul', 'p']);
  assert.strictEqual(l.kids[0].kids.length, 2);
});
console.log(n + ' 项通过');
