/* 服务器导入器: 自动识别用户粘贴的内容, 转换成 sing-box 出站。
 * 无任何依赖 (不用 URL / atob / Buffer), 因此浏览器、node、macOS 自带的
 * `osascript -l JavaScript` (JXA) 都能运行同一份代码。
 *
 * 能识别:
 *   - 订阅链接 (https://host/path...), 含 clash:// sing-box:// shadowrocket:// sub:// 包装, 以及 Shadowrocket 订阅描述 JSON
 *   - Clash / Stash YAML (proxies 段, 块式与流式)
 *   - sing-box JSON (outbounds 数组, 原样接收)
 *   - 整段 Base64 编码的节点列表 (v2rayN / Shadowrocket 订阅常见格式)
 *   - 分享链接: trojan:// hysteria2:// hy2:// tuic:// vless:// vmess:// ss:// http(s):// socks5://
 *
 * API:
 *   TPImporter.classify(text)  -> {urls:[订阅链接...], content:'其余文本'}
 *   TPImporter.parse(text, {role:'auto', existingTags:[]}) -> {format, servers:[{role,outbound,summary}], skipped:[{name,reason}]}
 *   TPImporter.toJSONL(servers, sub) -> 每行 {"role":"auto"[,"sub":"名称"],"outbound":{"type":..,"tag":..,...}}
 *
 * 约定: outbound 的第一个键是 type, 第二个键是 tag (安装端 bash 依赖这个顺序)。
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.TPImporter = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  var RESERVED = ['direct', 'AUTO', 'PIN', 'Global', 'Final'];
  var TYPES = ['trojan', 'http', 'socks', 'tuic', 'hysteria2', 'vless', 'vmess', 'shadowsocks', 'anytls'];

  /* ---------------- 基础工具 ---------------- */
  function clean(s) { return String(s == null ? '' : s).replace(/[\u0000-\u001f"\\]/g, '').replace(/\s+/g, ' ').trim(); }
  function toInt(v) { var n = parseInt(String(v).replace(/[^0-9]/g, ''), 10); return isNaN(n) ? undefined : n; }
  function dec(s) { try { return decodeURIComponent(s); } catch (e) { return s; } }
  function splitList(v) { return (Array.isArray(v) ? v.map(String) : String(v).split(',')).map(function (s) { return s.trim(); }).filter(Boolean); }

  var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  function b64decode(s) { // -> UTF-8 字符串, 失败返回 null (支持 url-safe 与缺失的 =)
    s = String(s).replace(/[\s=]/g, '').replace(/-/g, '+').replace(/_/g, '/');
    if (!s) return null;
    var out = '', buf = 0, bits = 0, i, v;
    for (i = 0; i < s.length; i++) {
      v = B64.indexOf(s.charAt(i));
      if (v < 0) return null;
      buf = ((buf << 6) | v) & 0xFFFF; bits += 6;
      if (bits >= 8) { bits -= 8; out += '%' + ('0' + ((buf >> bits) & 255).toString(16)).slice(-2); }
    }
    try { return decodeURIComponent(out); } catch (e) { return null; }
  }

  function parseUri(s) { // scheme://[userinfo@]host[:port][/path][?query][#frag]
    var m = String(s).trim().match(/^([A-Za-z][A-Za-z0-9+.-]*):\/\/([^\/?#]*)([^?#]*)(?:\?([^#]*))?(?:#(.*))?$/);
    if (!m) return null;
    var auth = m[2], at = auth.lastIndexOf('@'), userinfo = '', hp = auth;
    if (at >= 0) { userinfo = auth.slice(0, at); hp = auth.slice(at + 1); }
    var host = hp, port = '', hm = hp.match(/^(\[[^\]]+\]|[^:]*)(?::(\d*))?$/);
    if (hm) { host = hm[1]; port = hm[2] || ''; }
    var q = {};
    (m[4] || '').split('&').forEach(function (kv) {
      if (!kv) return;
      var i = kv.indexOf('='), k = dec(i < 0 ? kv : kv.slice(0, i)), v = i < 0 ? '' : dec(kv.slice(i + 1).replace(/\+/g, ' '));
      q[k] = v;
    });
    return { scheme: m[1].toLowerCase(), userinfo: userinfo, host: host.replace(/^\[|\]$/g, ''), port: port, path: m[3] || '', query: q, rawQuery: m[4] || '', hash: dec(m[5] || '') };
  }

  /* ---------------- 传输层 / TLS 公共构造 ---------------- */
  function transportOf(net, o) { // net: tcp|ws|grpc|h2|http|httpupgrade
    net = String(net || 'tcp').toLowerCase();
    var t;
    if (net === 'ws' || net === 'websocket') {
      t = { type: 'ws' };
      var p = o.path || '', em = String(p).match(/[?&]ed=(\d+)/);
      if (em) { t.max_early_data = parseInt(em[1], 10); t.early_data_header_name = 'Sec-WebSocket-Protocol'; p = String(p).replace(/[?&]ed=\d+/, ''); }
      if (p) t.path = p;
      if (o.host) t.headers = { Host: o.host };
      return t;
    }
    if (net === 'grpc') return { type: 'grpc', service_name: o.serviceName || '' };
    if (net === 'h2' || net === 'http') { t = { type: 'http' }; if (o.host) t.host = splitList(o.host); if (o.path) t.path = o.path; return t; }
    if (net === 'httpupgrade') { t = { type: 'httpupgrade' }; if (o.host) t.host = o.host; if (o.path) t.path = o.path; return t; }
    return null;
  }
  function tlsOf(o) { // o: {sni, insecure, alpn, fp, pbk, sid}
    var t = { enabled: true };
    if (o.sni) t.server_name = o.sni;
    if (o.insecure) t.insecure = true;
    if (o.alpn && o.alpn.length) t.alpn = o.alpn;
    if (o.pbk) { t.utls = { enabled: true, fingerprint: o.fp || 'chrome' }; t.reality = { enabled: true, public_key: o.pbk, short_id: o.sid || '' }; }
    else if (o.fp) t.utls = { enabled: true, fingerprint: o.fp };
    return t;
  }
  function truthy(v) { return v === true || v === 1 || v === '1' || String(v).toLowerCase() === 'true'; }

  /* ---------------- 极简 YAML (只覆盖 Clash/Stash 的 proxies 段) ---------------- */
  function stripComment(s) {
    var q = null, i, c;
    for (i = 0; i < s.length; i++) {
      c = s.charAt(i);
      if (q) { if (c === q) q = null; }
      else if (c === '"' || c === "'") q = c;
      else if (c === '#' && (i === 0 || /\s/.test(s.charAt(i - 1)))) return s.slice(0, i);
    }
    return s;
  }
  function scalar(v) {
    v = v.trim();
    if (v === '' || v === '~' || v === 'null') return '';
    var f = v.charAt(0), l = v.charAt(v.length - 1);
    if (v.length > 1 && ((f === '"' && l === '"') || (f === "'" && l === "'"))) {
      var inner = v.slice(1, -1);
      return f === "'" ? inner.replace(/''/g, "'") : inner.replace(/\\"/g, '"').replace(/\\\\/g, '\\');
    }
    if (v === 'true') return true;
    if (v === 'false') return false;
    if (/^-?[1-9][0-9]*$/.test(v) || v === '0') return parseInt(v, 10);
    return v;
  }
  function splitTop(s) {
    var out = [], depth = 0, q = null, cur = '', i, c;
    for (i = 0; i < s.length; i++) {
      c = s.charAt(i);
      if (q) { cur += c; if (c === q) q = null; continue; }
      if (c === '"' || c === "'") { q = c; cur += c; continue; }
      if (c === '[' || c === '{') depth++;
      if (c === ']' || c === '}') depth--;
      if (c === ',' && depth === 0) { out.push(cur); cur = ''; continue; }
      cur += c;
    }
    if (cur.trim() !== '') out.push(cur);
    return out;
  }
  function flow(v) {
    v = v.trim();
    var f = v.charAt(0), l = v.charAt(v.length - 1);
    if (f === '[' && l === ']') return splitTop(v.slice(1, -1)).map(flow);
    if (f === '{' && l === '}') {
      var o = {};
      splitTop(v.slice(1, -1)).forEach(function (kv) {
        var k = kv.search(/:(\s|$)/);
        if (k < 0) return;
        o[String(scalar(kv.slice(0, k))).trim()] = flow(kv.slice(k + 1));
      });
      return o;
    }
    return scalar(v);
  }
  function isDash(t) { return /^-(\s|$)/.test(t); }
  function parseBlock(L, i, ind) { return i >= L.length ? ['', i] : (isDash(L[i].t) ? parseList(L, i, ind) : parseMap(L, i, ind)); }
  function parseList(L, i, ind) {
    var out = [], rest, r, m;
    while (i < L.length && L[i].ind === ind && isDash(L[i].t)) {
      rest = L[i].t.replace(/^-\s*/, '');
      if (rest === '') {
        if (i + 1 < L.length && L[i + 1].ind > ind) { r = parseBlock(L, i + 1, L[i + 1].ind); out.push(r[0]); i = r[1]; }
        else { out.push(''); i++; }
      } else if (/^(\{|\[)/.test(rest)) { out.push(flow(rest)); i++; }
      else if (/^("[^"]*"|'[^']*'|[^\s:][^:]*?):(\s|$)/.test(rest)) {
        L[i] = { ind: ind + (L[i].t.length - rest.length), t: rest };
        m = parseMap(L, i, L[i].ind); out.push(m[0]); i = m[1];
      } else { out.push(scalar(rest)); i++; }
    }
    return [out, i];
  }
  function parseMap(L, i, ind) {
    var o = {}, t, k, key, val, nx, r;
    while (i < L.length && L[i].ind === ind && !isDash(L[i].t)) {
      t = L[i].t; k = t.search(/:(\s|$)/);
      if (k < 0) { i++; continue; }
      key = String(scalar(t.slice(0, k))).trim(); val = t.slice(k + 1).trim();
      if (val === '') {
        nx = L[i + 1];
        if (nx && (nx.ind > ind || (nx.ind === ind && isDash(nx.t)))) { r = parseBlock(L, i + 1, nx.ind); o[key] = r[0]; i = r[1]; }
        else { o[key] = ''; i++; }
      } else { o[key] = /^(\{|\[)/.test(val) ? flow(val) : scalar(val); i++; }
    }
    return [o, i];
  }
  function yamlProxies(text) {
    var raw = text.replace(/\r/g, '').split('\n'), start = -1, i, body = [];
    for (i = 0; i < raw.length; i++) if (/^proxies\s*:/.test(raw[i])) { start = i; break; }
    if (start >= 0) {
      var inline = raw[start].replace(/^proxies\s*:/, '').trim();
      if (inline.charAt(0) === '[') return flow(inline);
      for (i = start + 1; i < raw.length; i++) { if (/^[A-Za-z_][\w-]*\s*:/.test(raw[i])) break; body.push(raw[i]); }
    } else body = raw;
    var L = [];
    body.forEach(function (ln) {
      var t = stripComment(ln).replace(/\s+$/, '');
      if (t.trim() === '') return;
      L.push({ ind: t.length - t.replace(/^\s+/, '').length, t: t.trim() });
    });
    if (!L.length) return [];
    var r = parseBlock(L, 0, L[0].ind);
    return Array.isArray(r[0]) ? r[0] : [];
  }

  /* ---------------- Clash 节点 -> sing-box 出站 ---------------- */
  function rate(v) {
    var n = parseFloat(String(v)); if (isNaN(n)) return undefined;
    var u = String(v).toLowerCase();
    if (u.indexOf('g') >= 0) n *= 1000; else if (u.indexOf('k') >= 0) n /= 1000;
    return Math.round(n);
  }
  function clashTls(p, extra) {
    var o = { sni: clean(p.sni || p.servername || p['server-name'] || ''), insecure: p['skip-cert-verify'] === true, alpn: p.alpn ? splitList(p.alpn) : null, fp: p['client-fingerprint'] || p.fingerprint || '' };
    var ro = p['reality-opts'];
    if (ro && typeof ro === 'object') { o.pbk = String(ro['public-key'] || ''); o.sid = String(ro['short-id'] || ''); }
    return tlsOf(o);
  }
  function clashTransport(p) {
    var net = String(p.network || 'tcp').toLowerCase(), ws = p['ws-opts'] || {}, gr = p['grpc-opts'] || {}, h2 = p['h2-opts'] || {};
    if (net === 'ws') return transportOf('ws', { path: ws.path || p['ws-path'] || '', host: (ws.headers && (ws.headers.Host || ws.headers.host)) || p['ws-headers'] && p['ws-headers'].Host || '' });
    if (net === 'grpc') return transportOf('grpc', { serviceName: gr['grpc-service-name'] || '' });
    if (net === 'h2' || net === 'http') return transportOf('h2', { host: h2.host, path: h2.path });
    return null;
  }
  function fromClash(p) {
    var type = String(p.type || '').toLowerCase(), name = clean(p.name), server = clean(p.server), port = toInt(p.port), ob, tr;
    if (!name) name = server + ':' + port;
    if (!server || !port) return { skip: '缺少 server/port', name: name };
    var pw = (p.password == null ? '' : String(p.password));
    switch (type) {
      case 'http':
        ob = { type: 'http', tag: name, server: server, server_port: port };
        if (p.username) ob.username = String(p.username);
        if (pw) ob.password = pw;
        if (p.tls === true) ob.tls = clashTls(p);
        return { outbound: ob };
      case 'socks5': case 'socks':
        if (p.tls === true) return { skip: '暂不支持 SOCKS5 over TLS (sing-box 无此能力)', name: name };
        ob = { type: 'socks', tag: name, server: server, server_port: port, version: '5' };
        if (p.username) ob.username = String(p.username);
        if (pw) ob.password = pw;
        return { outbound: ob };
      case 'trojan':
        ob = { type: 'trojan', tag: name, server: server, server_port: port, password: pw, tls: clashTls(p) };
        tr = clashTransport(p); if (tr) ob.transport = tr;
        return { outbound: ob };
      case 'vless':
        ob = { type: 'vless', tag: name, server: server, server_port: port, uuid: String(p.uuid || '') };
        if (p.flow) ob.flow = String(p.flow);
        if (p.tls === true || p['reality-opts']) ob.tls = clashTls(p);
        tr = clashTransport(p); if (tr) ob.transport = tr;
        return { outbound: ob };
      case 'vmess':
        ob = { type: 'vmess', tag: name, server: server, server_port: port, uuid: String(p.uuid || ''), security: String(p.cipher || 'auto'), alter_id: toInt(p.alterId || p['alter-id'] || 0) || 0 };
        if (p.tls === true) ob.tls = clashTls(p);
        tr = clashTransport(p); if (tr) ob.transport = tr;
        return { outbound: ob };
      case 'tuic':
        ob = { type: 'tuic', tag: name, server: server, server_port: port, uuid: String(p.uuid || ''), password: pw };
        var cc = p['congestion-controller'] || p['congestion-control'] || p.congestion_control;
        if (cc) ob.congestion_control = String(cc);
        if (p['udp-relay-mode']) ob.udp_relay_mode = String(p['udp-relay-mode']);
        ob.tls = clashTls(p);
        return { outbound: ob };
      case 'hysteria2': case 'hy2':
        ob = { type: 'hysteria2', tag: name, server: server, server_port: port, password: pw };
        if (p.up != null && rate(p.up)) ob.up_mbps = rate(p.up);
        if (p.down != null && rate(p.down)) ob.down_mbps = rate(p.down);
        if (p.obfs) ob.obfs = { type: String(p.obfs), password: String(p['obfs-password'] || '') };
        ob.tls = clashTls(p);
        return { outbound: ob };
      case 'ss': case 'shadowsocks':
        if (p.plugin) return { skip: '暂不支持 Shadowsocks 插件', name: name };
        return { outbound: { type: 'shadowsocks', tag: name, server: server, server_port: port, method: String(p.cipher || p.method || ''), password: pw } };
      default:
        return { skip: '暂不支持的类型: ' + (type || '未知'), name: name };
    }
  }

  /* ---------------- 分享链接 -> sing-box 出站 ---------------- */
  function linkTls(q, forceTls) {
    var sec = String(q.security || '').toLowerCase();
    if (!forceTls && sec !== 'tls' && sec !== 'reality' && !q.tls) return null;
    return tlsOf({ sni: q.sni || q.peer || q.servername || '', insecure: truthy(q.allowInsecure) || truthy(q.allow_insecure) || truthy(q['allow-insecure']) || truthy(q.insecure) || q['skip-cert-verify'] === 'true', alpn: q.alpn ? splitList(q.alpn) : null, fp: q.fp || '', pbk: q.pbk || '', sid: q.sid || '' });
  }
  function userPass(ui) { // 兼容 base64(user:pass) 形式的 userinfo (Shadowrocket 的 http/socks 链接)
    var u = dec(ui), i = u.indexOf(':');
    if (i < 0 && u) { var d = b64decode(u); if (d && d.indexOf(':') > 0) { u = d; i = u.indexOf(':'); } }
    return i < 0 ? [u, ''] : [u.slice(0, i), u.slice(i + 1)];
  }
  function fromLink(line) {
    line = line.trim();
    var sch = line.match(/^([A-Za-z][A-Za-z0-9+.-]*):\/\//);
    if (!sch) return null;
    var scheme = sch[1].toLowerCase(), name, ob, t, tr, d;
    if (scheme === 'vmess') {
      d = b64decode(line.slice(8).split('#')[0]);
      var j; try { j = JSON.parse(d); } catch (e) { return { skip: 'vmess 链接无法解析', name: 'vmess' }; }
      name = clean(j.ps) || (j.add + ':' + j.port);
      ob = { type: 'vmess', tag: name, server: clean(j.add), server_port: toInt(j.port), uuid: String(j.id || ''), security: String(j.scy || 'auto'), alter_id: toInt(j.aid || 0) || 0 };
      if (!ob.server || !ob.server_port) return { skip: '缺少地址/端口', name: name };
      if (String(j.tls || '').toLowerCase() === 'tls') ob.tls = tlsOf({ sni: j.sni || j.host || '', alpn: j.alpn ? splitList(j.alpn) : null, fp: j.fp || '', insecure: false });
      tr = transportOf(j.net, { host: j.host, path: j.path, serviceName: j.path }); if (tr) ob.transport = tr;
      return { outbound: ob };
    }
    if (scheme === 'ssr') return { skip: '暂不支持 ssr', name: 'ssr' };
    if (scheme === 'ss') {
      var body = line.slice(5), hash = '', hi = body.indexOf('#');
      if (hi >= 0) { hash = dec(body.slice(hi + 1)); body = body.slice(0, hi); }
      body = body.split('?')[0].replace(/\/$/, '');
      var at = body.lastIndexOf('@'), cred, hp;
      if (at >= 0) { cred = body.slice(0, at); hp = body.slice(at + 1); cred = cred.indexOf(':') < 0 ? b64decode(cred) : dec(cred); }
      else { d = b64decode(body); at = d ? d.lastIndexOf('@') : -1; if (at < 0) return { skip: 'ss 链接无法解析', name: 'ss' }; cred = d.slice(0, at); hp = d.slice(at + 1); }
      var ci = cred ? cred.indexOf(':') : -1, hpm = hp.match(/^(.*):(\d+)$/);
      if (ci < 0 || !hpm) return { skip: 'ss 链接无法解析', name: 'ss' };
      return { outbound: { type: 'shadowsocks', tag: clean(hash) || (hpm[1] + ':' + hpm[2]), server: hpm[1].replace(/^\[|\]$/g, ''), server_port: parseInt(hpm[2], 10), method: cred.slice(0, ci), password: cred.slice(ci + 1) } };
    }
    var u = parseUri(line);
    if (!u || !u.host) return { skip: '链接格式错误', name: line.slice(0, 20) };
    var port = toInt(u.port) || (scheme === 'https' ? 443 : undefined), q = u.query;
    name = clean(u.hash) || (u.host + ':' + port);
    if (!port) return { skip: '缺少端口', name: name };
    var up = userPass(u.userinfo);
    if (scheme === 'trojan') {
      ob = { type: 'trojan', tag: name, server: u.host, server_port: port, password: dec(u.userinfo), tls: linkTls(q, true) };
      tr = transportOf(q.type, { host: q.host, path: q.path, serviceName: q.serviceName }); if (tr) ob.transport = tr;
      return { outbound: ob };
    }
    if (scheme === 'vless') {
      ob = { type: 'vless', tag: name, server: u.host, server_port: port, uuid: dec(u.userinfo) };
      if (q.flow) ob.flow = q.flow;
      t = linkTls(q, false); if (t) ob.tls = t;
      tr = transportOf(q.type, { host: q.host, path: q.path, serviceName: q.serviceName }); if (tr) ob.transport = tr;
      return { outbound: ob };
    }
    if (scheme === 'hysteria2' || scheme === 'hy2') {
      ob = { type: 'hysteria2', tag: name, server: u.host, server_port: port, password: dec(u.userinfo) };
      if (q.obfs) ob.obfs = { type: q.obfs, password: q['obfs-password'] || '' };
      ob.tls = linkTls(q, true); return { outbound: ob };
    }
    if (scheme === 'tuic') {
      ob = { type: 'tuic', tag: name, server: u.host, server_port: port, uuid: up[0], password: up[1] };
      if (q.congestion_control) ob.congestion_control = q.congestion_control;
      if (q.udp_relay_mode) ob.udp_relay_mode = q.udp_relay_mode;
      ob.tls = linkTls(q, true); return { outbound: ob };
    }
    if (scheme === 'http' || scheme === 'https') {
      ob = { type: 'http', tag: name, server: u.host, server_port: port };
      if (up[0]) ob.username = up[0]; if (up[1]) ob.password = up[1];
      if (scheme === 'https' || truthy(q.tls)) ob.tls = linkTls(q, true);
      return { outbound: ob, warn: up[0] ? '' : '链接里没有账号密码' };
    }
    if (scheme === 'socks5' || scheme === 'socks' || scheme === 'socks5h') {
      if (truthy(q.tls) || String(q.security || '').toLowerCase() === 'tls') return { skip: '暂不支持 SOCKS5 over TLS (sing-box 无此能力)', name: name };
      if (port === 443 || port === 8443) return { skip: '端口 ' + port + ' 的 SOCKS5 通常是 TLS 封装 (链接里没有 TLS 标记), sing-box 不支持, 已忽略; 建议改用订阅的 sing-box/Clash 格式', name: name };
      ob = { type: 'socks', tag: name, server: u.host, server_port: port, version: '5' };
      if (up[0]) ob.username = up[0]; if (up[1]) ob.password = up[1];
      return { outbound: ob };
    }
    return { skip: '暂不支持的链接类型: ' + scheme, name: name };
  }

  /* ---------------- sing-box JSON 原样接收 ---------------- */
  function fromSingbox(o) {
    if (!o || typeof o !== 'object' || TYPES.indexOf(o.type) < 0) return { skip: '不是受支持的出站类型: ' + (o && o.type), name: String(o && o.tag || '?') };
    if (!o.server || !o.server_port) return { skip: '缺少 server/server_port', name: String(o.tag || '?') };
    var ob = { type: o.type, tag: clean(o.tag) || (o.server + ':' + o.server_port) }, k;
    for (k in o) if (k !== 'type' && k !== 'tag' && k !== 'detour' && o.hasOwnProperty(k)) ob[k] = o[k];
    return { outbound: ob };
  }

  /* ---------------- 识别与入口 ---------------- */
  var INFO_NAME = /^(剩余流量|套餐到期|距离下次|到期时间|过期时间|流量重置|官网|客服|网址|最新|订阅|Traffic|Expire|Reset|Website)/i;
  function isInfoNode(ob) { return /^(127\.|0\.0\.0\.0|localhost)/i.test(ob.server) || INFO_NAME.test(ob.tag); }

  function isSubUrl(l) {
    var u = parseUri(l);
    return !!(u && /^https?$/.test(u.scheme) && !u.userinfo && u.host && (u.path.length > 1 || u.rawQuery));
  }
  function unwrapSub(l) { // clash://install-config?url=  sing-box://import-remote-profile?url=  shadowrocket://add/sub://BASE64  sub://BASE64
    var u = parseUri(l), d;
    if (u && (u.scheme === 'clash' || u.scheme === 'clashmeta' || u.scheme === 'sing-box' || u.scheme === 'stash') && u.query.url) return u.query.url;
    var m = l.match(/^(?:shadowrocket:\/\/add\/)?sub:\/\/([A-Za-z0-9+\/=_-]+)/i);
    if (m) { d = b64decode(m[1]); if (d && /^https?:\/\//i.test(d.trim())) return d.trim(); }
    m = l.match(/^shadowrocket:\/\/add\/(https?:\/\/.+)$/i);
    return m ? dec(m[1]) : null;
  }
  function classify(text) {
    text = String(text || '').trim();
    var urls = [], rest = [];
    try { // Shadowrocket / 其它客户端导出的订阅描述 JSON: {"type":"Subscribe","host":"https://..."}
      var j = JSON.parse(text);
      if (j && typeof j === 'object' && !Array.isArray(j) && !j.outbounds && !j.proxies) {
        var cand = j.host || j.url || j.subscription;
        if (typeof cand === 'string' && /^https?:\/\//i.test(cand)) return { urls: [cand.trim()], content: '' };
      }
    } catch (e) { /* 不是 JSON */ }
    text.replace(/\r/g, '').split('\n').forEach(function (raw) {
      var ln = raw.trim(), w;
      if (!ln) { rest.push(raw); return; }
      w = unwrapSub(ln);
      if (w) urls.push(w);
      else if (/^https?:\/\//i.test(ln) && isSubUrl(ln)) urls.push(ln);
      else rest.push(raw);                 // 保留原样(含缩进): 块式 YAML 依赖缩进
    });
    var content = rest.join('\n');
    return { urls: urls, content: content.trim() ? content : '' };
  }
  function looksYaml(t) { return /^\s*proxies\s*:/m.test(t) || (/^\s*-\s+(name\s*:|\{)/m.test(t) && /\btype\s*:/.test(t)); }
  function detectFormat(text) {
    var t = String(text || '').trim();
    if (!t) return 'empty';
    if (t.charAt(0) === '{' || t.charAt(0) === '[') { try { JSON.parse(t); return 'singbox-json'; } catch (e) { /* fallthrough */ } }
    if (looksYaml(t)) return 'clash-yaml';
    if (/:\/\//.test(t)) return 'links';
    var compact = t.replace(/\s+/g, '');
    if (compact.length >= 16 && /^[A-Za-z0-9+\/=_-]+$/.test(compact)) {
      var d = b64decode(compact);
      if (d && (/:\/\//.test(d) || looksYaml(d) || /^\s*[\[{]/.test(d))) return 'base64';
    }
    return 'unknown';
  }

  function summary(ob) { return ob.type + ' ' + ob.server + ':' + ob.server_port; }
  function parse(text, opts, depth) {
    opts = opts || {}; depth = depth || 0;
    var role = opts.role || 'auto', existing = {}, servers = [], skipped = [], items = [], fmt = detectFormat(text);
    (opts.existingTags || []).forEach(function (t) { existing[t] = 1; });
    text = String(text || '').trim();
    if (fmt === 'base64' && depth < 2) return parse(b64decode(text.replace(/\s+/g, '')), opts, depth + 1);
    if (fmt === 'singbox-json') {
      var j = JSON.parse(text), arr = Array.isArray(j) ? j : (j.outbounds || j.proxies || []);
      (Array.isArray(arr) ? arr : []).forEach(function (o) {
        if (o && o.type && ['direct', 'block', 'dns', 'selector', 'urltest'].indexOf(o.type) >= 0) return; // 分组/内置出站忽略
        items.push(j.proxies && !j.outbounds ? fromClash(o) : fromSingbox(o));
      });
    } else if (fmt === 'clash-yaml') {
      yamlProxies(text).forEach(function (p) { if (p && typeof p === 'object') items.push(fromClash(p)); });
    } else if (fmt === 'links') {
      text.replace(/\r/g, '').split('\n').forEach(function (ln) {
        ln = ln.trim(); if (!ln || ln.charAt(0) === '#') return;
        items.push(fromLink(ln) || { skip: '无法识别的行', name: ln.slice(0, 24) });
      });
    } else if (fmt !== 'empty') {
      skipped.push({ name: text.slice(0, 24), reason: '无法识别的内容格式' });
    }
    var used = {};
    items.forEach(function (it) {
      if (it.skip) { skipped.push({ name: it.name, reason: it.skip }); return; }
      var ob = it.outbound;
      if (isInfoNode(ob)) { skipped.push({ name: ob.tag, reason: '订阅提示节点(流量/到期信息), 已忽略' }); return; }
      var base = ob.tag.slice(0, 60) || 'node', tag, n = 2;
      /* 官方-… 是官方线路 (会员) 的保留前缀, 安装端会拒绝用户导入占用它的节点: 别的订阅里叫「官方-xx」的节点改成「官方 xx」, 不要整行丢掉 */
      base = base.replace(/^官方-/, '官方 ').replace(/^enana-official-/i, 'enana official ');
      tag = base;
      while (used[tag] || existing[tag] || RESERVED.indexOf(tag) >= 0 || /^svc-/.test(tag)) tag = base + ' ' + (n++);
      used[tag] = 1; ob.tag = tag;
      servers.push({ role: role, outbound: ob, summary: summary(ob), warn: it.warn || '' });
    });
    return { format: fmt, servers: servers, skipped: skipped };
  }
  function toJSONL(servers, sub) {
    return servers.map(function (s) {
      var head = { role: s.role }; if (sub) head.sub = sub;
      head.outbound = s.outbound;
      return JSON.stringify(head);
    }).join('\n') + '\n';
  }
  return { classify: classify, parse: parse, toJSONL: toJSONL, detectFormat: detectFormat, parseUri: parseUri, b64decode: b64decode };
});
