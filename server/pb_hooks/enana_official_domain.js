'use strict';
// Official route nodes: pure parsing / sanitising of a third-party subscription (no PocketBase globals, no
// network, no secrets), so it can be unit-tested in plain Node (tests/official-domain.test.js) and is loaded
// unchanged by the PocketBase JS VM (goja, ES2015+).
//
// The source returns a complete sing-box JSON when asked with a `sing-box/<version>` User-Agent. We keep only
// real proxy outbounds of the types the client's srv_check_line accepts, drop group / built-in outbounds and the
// "traffic left / expires" information pseudo-nodes, rebuild every outbound from a per-protocol allow-list (so an
// upstream cannot smuggle `detour`, local file paths, bind interfaces, DNS settings ... into a client config),
// force the key order the client's awk depends on (`type` first, `tag` second), sort the remaining keys so the
// bytes are stable between syncs, and prefix every tag with the reserved official prefix.
//
// Nothing here ever logs or returns the source URL; callers only get counts and short error codes.

const TYPES = ['trojan', 'http', 'socks', 'tuic', 'hysteria2', 'vless', 'vmess', 'shadowsocks', 'anytls']
const RESERVED_PREFIX = '官方-'            // user imports with this tag prefix are rejected by the client (lib/servers.sh)
const MAX_NODES = 300                      // per source
const MAX_SCANNED = 1000                   // outbounds looked at per source
const MAX_TAG_BYTES = 80
const MAX_STRING = 4096
const MAX_OUTBOUND_JSON = 12000            // official_nodes.outbound is limited to 16000 bytes
const GROUP_TYPES = ['direct', 'block', 'dns', 'selector', 'urltest', 'tun', 'mixed', 'socks-in', 'http-in', 'redirect', 'tproxy']
const INFO_NAME = /^(剩余流量|套餐到期|距离下次|到期时间|过期时间|流量重置|重置|官网|客服|网址|最新|订阅|Traffic|Expire|Reset|Website)/i

// Allowed keys per nested object. A key that is not listed is dropped. `certificate_path`, `key_path`,
// `config_path` and every other local-file reference are deliberately absent: server data must never point
// the client at a file on the user's computer.
const TLS_KEYS = ['enabled', 'server_name', 'insecure', 'alpn', 'min_version', 'max_version', 'cipher_suites', 'curve_preferences', 'certificate', 'disable_sni', 'utls', 'reality', 'ech']
const NESTED = {
  tls: TLS_KEYS,
  utls: ['enabled', 'fingerprint'],
  reality: ['enabled', 'public_key', 'short_id'],
  ech: ['enabled', 'config', 'query_server_name'],
  transport: ['type', 'host', 'path', 'headers', 'method', 'max_early_data', 'early_data_header_name', 'service_name', 'idle_timeout', 'ping_timeout', 'permit_without_stream'],
  multiplex: ['enabled', 'protocol', 'max_connections', 'min_streams', 'max_streams', 'padding', 'brutal'],
  brutal: ['enabled', 'up_mbps', 'down_mbps'],
  obfs: ['type', 'password'],
  udp_over_tcp: ['enabled', 'version'],
}
const TOP = {
  http: ['username', 'password', 'path', 'headers', 'tls'],
  socks: ['version', 'username', 'password', 'network', 'udp_over_tcp'],
  trojan: ['password', 'network', 'tls', 'multiplex', 'transport'],
  vless: ['uuid', 'flow', 'network', 'tls', 'packet_encoding', 'multiplex', 'transport'],
  vmess: ['uuid', 'security', 'alter_id', 'global_padding', 'authenticated_length', 'network', 'tls', 'packet_encoding', 'multiplex', 'transport'],
  shadowsocks: ['method', 'password', 'plugin', 'plugin_opts', 'network', 'udp_over_tcp', 'multiplex'],
  tuic: ['uuid', 'password', 'congestion_control', 'udp_relay_mode', 'udp_over_stream', 'zero_rtt_handshake', 'heartbeat', 'network', 'tls'],
  hysteria2: ['server_ports', 'hop_interval', 'up_mbps', 'down_mbps', 'obfs', 'password', 'network', 'tls', 'brutal_debug'],
  anytls: ['password', 'idle_session_check_interval', 'idle_session_timeout', 'min_idle_session', 'tls'],
}
const FREE_MAPS = { headers: true }        // {name: string | [string]} : header names are free-form but constrained

function utf8Len(s) { return unescape(encodeURIComponent(s)).length }
function isObj(v) { return v !== null && typeof v === 'object' && !Array.isArray(v) }
function has(o, k) { return Object.prototype.hasOwnProperty.call(o, k) }

// A scalar string: no control characters, bounded, and never containing the client's cert placeholder.
function str(v) {
  if (typeof v !== 'string' || v.length > MAX_STRING || v.indexOf('@CERTS@') >= 0) return undefined
  if (/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f\u2028\u2029]/.test(v)) return undefined
  return v
}
function scalar(v) {
  if (typeof v === 'string') return str(v)
  if (typeof v === 'number') return isFinite(v) ? v : undefined
  if (typeof v === 'boolean') return v
  return undefined
}

// Recursively rebuild `v` keeping only allow-listed keys; keys are emitted sorted so equal data gives equal bytes.
// A key that is not on the allow-list is dropped silently, but a value that IS on the list and is malformed (wrong
// type, too long, control characters, the client's cert placeholder ...) makes the whole value undefined, so the
// caller drops the whole node instead of shipping a half-broken one. `null` counts as "not set".
function sub(v, name, depth) { return (has(NESTED, name) || has(FREE_MAPS, name) || Array.isArray(v) || isObj(v)) ? rebuild(v, name, depth) : scalar(v) }
function rebuild(v, name, depth) {
  if (depth > 4) return undefined
  if (Array.isArray(v)) {
    if (v.length > 64) return undefined
    const out = []
    for (let i = 0; i < v.length; i++) {
      const x = isObj(v[i]) || Array.isArray(v[i]) ? undefined : scalar(v[i])
      if (x === undefined) return undefined
      out.push(x)
    }
    return out
  }
  if (isObj(v)) {
    const out = {}
    if (has(FREE_MAPS, name)) {
      const keys = Object.keys(v).sort()
      if (keys.length > 32) return undefined
      for (const k of keys) {
        if (v[k] === null) continue
        if (!/^[A-Za-z0-9._-]{1,64}$/.test(k)) return undefined
        const x = Array.isArray(v[k]) ? rebuild(v[k], k, depth + 1) : scalar(v[k])
        if (x === undefined) return undefined
        out[k] = x
      }
      return out
    }
    const allowed = NESTED[name]
    if (!allowed) return undefined
    for (const k of allowed.slice().sort()) {
      if (!has(v, k) || v[k] === null) continue
      const x = sub(v[k], k, depth + 1)
      if (x === undefined) return undefined
      out[k] = x
    }
    return out
  }
  if (has(NESTED, name) && name !== 'udp_over_tcp') return undefined         // an object was expected (tls / transport / ...)
  if (has(FREE_MAPS, name)) return undefined
  return scalar(v)
}

// 1 .. 65535 as a JSON number
function port(v) { return typeof v === 'number' && isFinite(v) && Math.floor(v) === v && v >= 1 && v <= 65535 ? v : 0 }
function hostOk(h) {
  if (typeof h !== 'string' || !h || h.length > 253) return false
  if (/^(127\.|0\.0\.0\.0|localhost$|::1$)/i.test(h)) return false                       // information pseudo-nodes use loopback addresses
  return /^[A-Za-z0-9._:-]+$/.test(h)                                                   // host name, IPv4 or bare IPv6 (no brackets / quotes / spaces)
}

function cleanTag(s) {
  let t = String(s == null ? '' : s).replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029"\\]/g, '').replace(/\s+/g, ' ').trim()
  return t
}
function cutBytes(s, max) {
  const chars = Array.from(s)
  while (chars.length && utf8Len(chars.join('')) > max) chars.pop()
  return chars.join('').trim()
}
// The configured prefix always starts with the reserved one, so a source cannot produce tags that a user import could.
function normalizePrefix(p) {
  let x = cleanTag(typeof p === 'string' ? p : '')
  if (x.length > 16) x = x.slice(0, 16)
  if (x.indexOf(RESERVED_PREFIX) !== 0) x = RESERVED_PREFIX + x
  return x
}

// One upstream outbound -> {outbound} | {skip: reason}. `tag` is assigned by parseSingBox (prefix, uniqueness).
function sanitizeOutbound(o) {
  if (!isObj(o)) return { skip: 'shape' }
  const type = o.type
  if (typeof type !== 'string') return { skip: 'shape' }
  if (GROUP_TYPES.indexOf(type) >= 0) return { skip: 'group' }
  if (TYPES.indexOf(type) < 0) return { skip: 'type' }
  const server = o.server, sp = port(o.server_port)
  if (!hostOk(server) || !sp) return { skip: 'address' }
  const rawTag = cleanTag(o.tag)
  if (INFO_NAME.test(rawTag)) return { skip: 'info' }
  const out = { type: type, tag: rawTag, server: server, server_port: sp }
  const keys = TOP[type].slice().sort()
  for (const k of keys) {
    if (!has(o, k) || o[k] === null) continue
    const x = sub(o[k], k, 1)
    if (x === undefined) return { skip: 'shape' }
    out[k] = x
  }
  // stable order: type, tag, then the rest sorted (server / server_port are part of the rest)
  const ordered = { type: out.type, tag: out.tag }
  Object.keys(out).filter(k => k !== 'type' && k !== 'tag').sort().forEach(k => { ordered[k] = out[k] })
  return { outbound: ordered, label: rawTag }
}

// parseSingBox(text, {prefix}) -> {nodes: [{tag, outbound}], skipped: {group,type,address,info,shape,limit}, total} | {error}
function parseSingBox(text, opts) {
  opts = opts || {}
  const prefix = normalizePrefix(opts.prefix)
  let doc
  try { doc = JSON.parse(text) } catch (_) { return { error: 'bad_format' } }
  const list = Array.isArray(doc) ? doc : (isObj(doc) && Array.isArray(doc.outbounds) ? doc.outbounds : null)
  if (!list) return { error: 'bad_format' }
  const skipped = { group: 0, type: 0, address: 0, info: 0, shape: 0, limit: 0 }
  const nodes = [], used = {}
  for (let i = 0; i < list.length; i++) {
    if (i >= MAX_SCANNED) { skipped.limit += list.length - i; break }
    const r = sanitizeOutbound(list[i])
    if (r.skip) { skipped[r.skip]++; continue }
    if (nodes.length >= MAX_NODES) { skipped.limit++; continue }
    let base = cutBytes(prefix + (r.label || (r.outbound.server + ':' + r.outbound.server_port)), MAX_TAG_BYTES), tag = base, n = 2
    while (used[tag]) { tag = cutBytes(base, MAX_TAG_BYTES - 4) + ' ' + (n++) }
    used[tag] = true
    r.outbound.tag = tag
    if (JSON.stringify(r.outbound).length > MAX_OUTBOUND_JSON) { skipped.shape++; delete used[tag]; continue }
    nodes.push({ tag: tag, outbound: r.outbound })
  }
  if (!nodes.length) return { error: 'no_nodes' }
  return { nodes: nodes, skipped: skipped, total: list.length }
}

// Stable database key for a node of a source: the source id plus a hash of the final tag. `sha256` is injected so the
// same code works in Node (crypto) and PocketBase ($security.sha256).
function nodeKey(sourceId, tag, sha256) { return sourceId + '~' + sha256(sourceId + '\u0000' + tag).slice(0, 32) }

// Validate one source from the private configuration. Returns {id,url,ua,prefix,enabled} or null (never throws,
// never echoes the URL).
function normalizeSource(s) {
  if (!isObj(s)) return null
  const id = typeof s.id === 'string' ? s.id : ''
  if (!/^[a-z0-9][a-z0-9-]{0,15}$/.test(id)) return null
  const url = typeof s.url === 'string' ? s.url.trim() : ''
  if (!/^https:\/\/[^\s\u0000-\u001f]+$/i.test(url) || url.length > 2048 || /^https:\/\/[^\/?#]*@/i.test(url)) return null   // https only, no user:pass@
  let ua = typeof s.ua === 'string' ? s.ua.trim() : ''
  if (!ua) ua = 'sing-box/1.12.0'
  if (!/^[\x20-\x7e]{1,100}$/.test(ua)) return null
  return { id: id, url: url, ua: ua, prefix: normalizePrefix(s.prefix), enabled: s.enabled !== false }
}
function normalizeConfig(c) {
  const out = { sources: [], ttl: 86400 }
  if (!isObj(c)) return out
  const seen = {}
  if (Array.isArray(c.sources)) {
    for (const raw of c.sources) {
      const s = normalizeSource(raw)
      if (!s || seen[s.id]) continue
      seen[s.id] = true
      out.sources.push(s)
      if (out.sources.length >= 8) break
    }
  }
  const h = c.ttl_hours
  if (typeof h === 'number' && isFinite(h)) out.ttl = Math.max(2, Math.min(168, Math.floor(h))) * 3600
  return out
}

module.exports = {
  TYPES: TYPES, RESERVED_PREFIX: RESERVED_PREFIX, MAX_NODES: MAX_NODES,
  parseSingBox: parseSingBox, sanitizeOutbound: sanitizeOutbound, nodeKey: nodeKey,
  normalizePrefix: normalizePrefix, normalizeSource: normalizeSource, normalizeConfig: normalizeConfig,
}
