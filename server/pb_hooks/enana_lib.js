// enana 云端接口的实现 (CommonJS 模块, 由 enana_v1.pb.js 里每个处理函数在函数体内 require 进来)。
// PocketBase 的 JS 处理函数各自运行在隔离的上下文里, 不能共用文件级变量, 所以共享代码放在这个模块里。
// 模块在所有请求之间共享注册表: 这里只放纯函数和常量, 不保存任何会变的全局状态。
//
// 接口约定见 enana 仓库的 docs/CLOUD_API.md。要点:
//   - 调用方只有本机辅助服务 (网站只是一个静态首页, 不调用任何接口)。除登录外, 每个接口都要带
//     Authorization: Bearer <token> + X-Enana-Session: <会话 id>, 令牌和会话两者都要有效。
//   - 会话被撤销 / 过期后, 即使 JWT 还没到期也立即拒绝 (JWT 只证明「密码登录过」, 会话才决定「这台设备现在能不能用」)。
//   - 令牌本身被 PocketBase 拒绝 (过期 / 改密码后作废) 时, 也返回 401 session_revoked (带上能查到的真实原因, 否则 expired),
//     设备据此自己退出登录。
//   - 绝不记录密码、令牌、同步密文。
'use strict'

const ONLINE_WINDOW = 600          // 秒: 心跳在这个窗口内才算「在线」
const SESSION_TTL = 30 * 86400     // 会话绝对有效期 30 天
const HEARTBEAT_SECS = 120
const DEFAULT_LIMIT = 2            // 套餐里没填 max_devices_per_platform 时每个平台最多同时在线几台
const MAX_DEVICE_ROWS = 40         // 每个账号最多保留多少条设备记录 (防止刷设备记录)
const FAIL_WINDOW = 600            // 登录失败计数窗口 (秒)
const FAIL_LIMIT_EMAIL = 8         // 窗口内同一邮箱失败多少次后 429
const FAIL_LIMIT_IP = 20           // 窗口内同一 IP 失败多少次后 429
const PLATFORMS = ['macos', 'windows', 'linux']
const MAX_PAYLOAD = 1048576        // 同步密文最多多少个字符 (与 sync_snapshots.payload 的 max 一致)
const SYNC_BODY_MAX = 1572864      // 同步请求体上限 (字节)
const SMALL_BODY_MAX = 16384       // 其它接口请求体上限
const SID_RE = /^[a-z0-9]{15}$/    // PocketBase 记录 id

// 功能目录: 代码里写死「有哪些功能、属于哪一档、是否已上线」; 每个套餐能用哪些功能写在 plans.features (JSON 数组, 管理后台里可改)。
// coming_soon = 还没上线: 即使套餐包含也不会 enabled。官方线路没有写死的 coming_soon: 只要 official_nodes 里至少有一个新鲜、已批准的节点就自动上线,
// 否则照旧显示「即将推出」(needs_nodes)。needs_verified = 还要求邮箱已验证 (节点只发给已验证邮箱的 Pro 账号)。
const FEATURES = {
  core:           { tier: 'free' },
  sync:           { tier: 'free' },
  vps_deploy:     { tier: 'free' },
  official_proxy: { tier: 'pro', needs_nodes: true, needs_verified: true },
}

// ---------------------------------------------------------------- 基础工具

function nowSec() { return Math.floor(Date.now() / 1000) }
// PocketBase 的日期格式: 2026-10-02 06:48:37.000Z
function iso(sec) { return new Date(sec * 1000).toISOString().replace('T', ' ') }
function unixOf(rec, field) {
  const d = rec.getDateTime(field)
  return (d && !d.isZero()) ? d.unix() : 0
}
// 写完响应后返回 true: 前置检查函数用 {res: true} 表示「响应已经写好, 调用方直接结束」(e.json 本身的返回值是空的, 不能拿来判断)
function reply(e, status, body) { e.json(status, body); return true }
function fail(e, status, code, message, extra) {
  const body = { code: code, message: message }
  if (extra) for (const k in extra) body[k] = extra[k]
  return reply(e, status, body)
}
// 设备名等客户端自报的文字: 去掉控制字符 (C0 / DEL / C1 / 行分隔符 / 双向文字覆盖符), 按「字符」而不是 UTF-16 单位截断
// (中文、emoji 原样保存; 不能把一个 emoji 从中间切开)。
function clean(v, max) {
  if (typeof v !== 'string') return ''
  const s = v.replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029\u202a-\u202e\u2066-\u2069]/g, '').trim()
  return Array.from(s).slice(0, max).join('').trim()
}
function readJSON(e, maxBytes) {
  let text = ''
  try { text = toString(e.request.body, maxBytes) } catch (_) { return null }
  try {
    const v = JSON.parse(text)
    return (v && typeof v === 'object' && !Array.isArray(v)) ? v : null
  } catch (_) { return null }
}

// 打码: IPv4 → 203.0.*.*; IPv6 → 只留前两组
function maskIP(ip) {
  if (!ip) return ''
  if (ip.indexOf(':') >= 0) {
    const g = ip.split(':')
    return g.slice(0, 2).join(':') + ':*:*:*:*:*:*'
  }
  const p = ip.split('.')
  return p.length === 4 ? (p[0] + '.' + p[1] + '.*.*') : '*'
}

// 登录失败计数用的哈希前缀 (不存邮箱 / IP 明文; 密钥是 users 集合的令牌密钥, 只在服务器上)
function hkey(app, text) {
  let secret = 'enana'
  try { secret = app.findCachedCollectionByNameOrId('users').authToken.secret || secret } catch (_) { /* 用默认值 */ }
  return $security.hs256(String(text).toLowerCase(), secret).slice(0, 16)
}

function audit(app, type, o) {
  try {
    const r = new Record(app.findCachedCollectionByNameOrId('audit_events'))
    r.set('type', type)
    if (o.user) r.set('user', o.user)
    if (o.device) r.set('device', o.device)
    r.set('ip_masked', o.ip || '')
    r.set('detail', o.detail || {})
    app.save(r)
  } catch (_) { /* 审计失败不能影响主流程 */ }
}

// ---------------------------------------------------------------- 套餐

function freePlan(app) {
  return app.findFirstRecordByData('plans', 'code', 'free')
}
// 账号当前生效的套餐: 订阅有效 (active 且未过期) 且套餐本身启用 (plans.active) 才用订阅里的套餐, 否则退回 free。
// 没有订阅记录时顺手补一条 (自愈)。expired = 订阅是付费档但已过期 / 取消 (用于功能里的 reason: expired)。
function planFor(app, user, t) {
  let sub = null
  try { sub = app.findFirstRecordByFilter('subscriptions', 'user = {:u}', { u: user.id }) } catch (_) { sub = null }
  let plan = null
  let expiresAt = null
  let expired = false
  if (sub) {
    const exp = unixOf(sub, 'expires_at')
    expiresAt = exp || null
    let subPlan = null
    try { subPlan = app.findRecordById('plans', sub.getString('plan')) } catch (_) { subPlan = null }
    if (sub.getString('status') === 'active' && (!exp || exp > t)) {
      if (subPlan && subPlan.getBool('active')) plan = subPlan
    } else if (subPlan && subPlan.getString('code') !== 'free') {
      expired = true
    }
  } else {
    try {
      const s = new Record(app.findCachedCollectionByNameOrId('subscriptions'))
      s.set('user', user.id); s.set('plan', freePlan(app).id); s.set('status', 'active'); s.set('source', 'default')
      app.save(s)
    } catch (_) { /* 并发时另一个请求已经补过了 */ }
  }
  if (!plan) plan = freePlan(app)
  let granted = []
  try { granted = JSON.parse(toString(plan.get('features')) || '[]') } catch (_) { granted = [] }
  if (!Array.isArray(granted)) granted = []
  return {
    code: plan.getString('code'),
    title: plan.getString('title'),
    limit: plan.getInt('max_devices_per_platform') || DEFAULT_LIMIT,
    granted: granted,
    expired: expired,
    expires_at: expiresAt,
  }
}

// 权益 (docs/API.md「会员 / 套餐」): features.<key> = {enabled, tier, [reason: upgrade|expired|verify], [coming_soon]}
// ctx = {nodes: 新鲜且已批准的官方节点数, verified: 邮箱是否已验证}; 不传 ctx = 没有节点、未验证。
function entitlements(p, ctx) {
  const c = ctx || {}
  const out = {}
  for (const key in FEATURES) {
    const def = FEATURES[key]
    const granted = p.granted.indexOf(key) >= 0
    const soon = !!def.coming_soon || (!!def.needs_nodes && !(c.nodes > 0))
    const needVerify = granted && !soon && !!def.needs_verified && !c.verified
    const f = { enabled: granted && !soon && !needVerify, tier: def.tier }
    if (!granted) f.reason = p.expired ? 'expired' : 'upgrade'
    else if (needVerify) f.reason = 'verify'
    if (soon) f.coming_soon = true
    out[key] = f
  }
  return out
}

// ---------------------------------------------------------------- 官方线路节点 (official_nodes, 由 enana_official.js 定时从私有配置的订阅源同步)

// 新鲜 (fresh_until 未过期)、已批准、已启用的官方节点。集合没有任何 API 规则 = 只有超级用户和这里的服务端代码能读。
const OFFICIAL_FRESH = "origin = 'official' AND enabled = 1 AND approved = 1 AND fresh_until > {:t}"
function officialCount(app, t) {
  try { return app.countRecords('official_nodes', $dbx.exp(OFFICIAL_FRESH, { t: iso(t) })) } catch (_) { return 0 }
}
// 返回 [{outbound}], 按节点名排序 (同一份数据永远得到相同的字节, 客户端据此判断「没有变化」); outbound 的键顺序: type, tag, 其余按字母序。
function officialRows(app, t) {
  let rows = []
  try { rows = app.findAllRecords('official_nodes', $dbx.exp(OFFICIAL_FRESH, { t: iso(t) })) } catch (_) { return [] }
  const out = []
  for (const r of rows) {
    let o = null
    try { o = JSON.parse(toString(r.get('outbound'))) } catch (_) { o = null }
    if (!o || typeof o !== 'object' || typeof o.type !== 'string' || typeof o.tag !== 'string') continue
    const ordered = { type: o.type, tag: o.tag }
    Object.keys(o).filter((k) => k !== 'type' && k !== 'tag').sort().forEach((k) => { ordered[k] = o[k] })
    out.push({ outbound: ordered })
  }
  out.sort((a, b) => (a.outbound.tag < b.outbound.tag ? -1 : a.outbound.tag > b.outbound.tag ? 1 : 0))
  return out
}
// 谁有资格拿节点: 当前生效的套餐包含 official_proxy (订阅有效且套餐启用) 并且邮箱已验证。与「现在有没有节点」无关 (没有节点时返回空列表)。
function officialAccess(p, verified) {
  const granted = p.granted.indexOf('official_proxy') >= 0
  return { granted: granted, entitled: granted && !!verified }
}

// ---------------------------------------------------------------- 设备与会话

function parseDevice(d) {
  if (!d || typeof d !== 'object') return { error: 'device is required' }
  const uid = typeof d.uid === 'string' ? d.uid.trim() : ''
  const platform = typeof d.platform === 'string' ? d.platform.trim().toLowerCase() : ''
  if (!/^[A-Za-z0-9._-]{8,64}$/.test(uid)) return { error: 'device.uid must be 8-64 characters of A-Z a-z 0-9 . _ -' }
  if (PLATFORMS.indexOf(platform) < 0) return { error: 'device.platform must be one of macos, windows, linux' }
  return { uid: uid, platform: platform, name: clean(d.name, 100), os: clean(d.os, 64), arch: clean(d.arch, 32), app: clean(d.app, 32) }
}

function findDevice(app, userId, uid) {
  return app.findFirstRecordByFilter('devices', 'user = {:u} && device_uid = {:d}', { u: userId, d: uid })
}

function upsertDevice(tx, user, d, ipMasked, t) {
  let dev
  try {
    dev = findDevice(tx, user.id, d.uid)
  } catch (_) {
    // 新设备: 记录数太多时先清掉最久没出现、且当前没有未撤销会话的旧记录
    const all = tx.findRecordsByFilter('devices', 'user = {:u}', 'last_seen_at', 500, 0, { u: user.id })
    if (all.length >= MAX_DEVICE_ROWS) {
      for (const old of all) {
        if (all.length < MAX_DEVICE_ROWS) break
        const open = tx.countRecords('device_sessions', $dbx.exp("device = {:d} AND revoked_at = ''", { d: old.id }))
        if (open === 0) { tx.delete(old); all.splice(all.indexOf(old), 1) }
      }
    }
    dev = new Record(tx.findCachedCollectionByNameOrId('devices'))
    dev.set('user', user.id)
    dev.set('device_uid', d.uid)
  }
  dev.set('platform', d.platform)
  dev.set('name', d.name)
  dev.set('os_version', d.os)
  dev.set('arch', d.arch)
  dev.set('app_version', d.app)
  dev.set('last_seen_at', iso(t))
  dev.set('last_ip_masked', ipMasked)
  tx.save(dev)
  return dev
}

// 在线 = 未撤销 && 未过期 && 窗口内有心跳
function activeSessions(app, userId, t) {
  return app.findRecordsByFilter('device_sessions',
    "user = {:u} && revoked_at = '' && expires_at > {:now} && last_heartbeat_at > {:cut}",
    '-last_heartbeat_at', 500, 0, { u: userId, now: iso(t), cut: iso(t - ONLINE_WINDOW) })
}

// 某平台上当前在线的 [{session, device}]; exceptSessionId 用于心跳「排除自己」。
// 两次查询 (该平台的设备 + 在线会话), 在内存里按 device id 对上, 没有逐会话再查设备的 N+1。
function activeOnPlatform(app, userId, platform, t, exceptSessionId) {
  const devs = {}
  for (const d of app.findRecordsByFilter('devices', 'user = {:u} && platform = {:p}', '', 200, 0, { u: userId, p: platform })) devs[d.id] = d
  const out = []
  for (const s of activeSessions(app, userId, t)) {
    if (exceptSessionId && s.id === exceptSessionId) continue
    const d = devs[s.getString('device')]
    if (d) out.push({ session: s, device: d })
  }
  return out
}

function deviceJSON(d, online, current) {
  const o = {
    uid: d.getString('device_uid'),
    name: d.getString('name'),
    platform: d.getString('platform'),
    os: d.getString('os_version'),
    arch: d.getString('arch'),
    app: d.getString('app_version'),
    last_seen: unixOf(d, 'last_seen_at'),
    online: !!online,
    ip_hint: d.getString('last_ip_masked'),
  }
  if (current !== undefined) o.current = !!current
  return o
}

// 撤销某设备所有未撤销的会话 (无论是否在线); 返回撤销了几个
function revokeDeviceSessions(tx, userId, deviceId, reason, byDeviceId, t) {
  const list = tx.findRecordsByFilter('device_sessions', "user = {:u} && device = {:d} && revoked_at = ''", '', 200, 0, { u: userId, d: deviceId })
  for (const s of list) {
    s.set('revoked_at', iso(t))
    s.set('revoked_reason', reason)
    if (byDeviceId) s.set('revoked_by_device', byDeviceId)
    tx.save(s)
  }
  return list.length
}

// ---------------------------------------------------------------- 请求前置检查

// 取当前登录用户 (必须是 users 集合); 停用账号一律 403。返回 {user} 或 {res} (已经写好的响应)
function needUser(e) {
  const u = e.auth
  if (!u) {
    // 带了令牌却没有登录态 = 令牌被 PocketBase 拒绝了 (过期 / 改密码后作废 / 乱写): 与「会话被撤销」同一种 401, 设备据此自己退出登录
    if ((e.request.header.get('Authorization') || '').trim()) return { res: tokenRejected(e) }
    return { res: fail(e, 401, 'unauthorized', 'A valid token is required.') }
  }
  if (u.collection().name !== 'users') return { res: fail(e, 401, 'unauthorized', 'A valid token is required.') }
  if (u.getBool('disabled')) return { res: fail(e, 403, 'account_disabled', 'This account is disabled.') }
  return { user: u }
}

// 校验 X-Enana-Session 里的会话: 属于当前用户、未撤销、未过期。
// 返回 {session} 或 {revoked: 原因 [, expired: true, session]} 或 {missing: true}。app 可以是 $app 或事务里的 txApp。
function checkSession(app, user, sid, t) {
  if (!sid) return { missing: true }
  if (!SID_RE.test(sid)) return { revoked: 'expired' }
  let s
  try { s = app.findRecordById('device_sessions', sid) } catch (_) { return { revoked: 'expired' } }
  if (s.getString('user') !== user.id) return { revoked: 'expired' }
  if (unixOf(s, 'revoked_at')) return { revoked: s.getString('revoked_reason') || 'expired' }
  if (unixOf(s, 'expires_at') <= t) return { revoked: 'expired', expired: true, session: s }
  return { session: s }
}

function sessionHeader(e) { return (e.request.header.get('X-Enana-Session') || '').trim() }

function revokedReply(e, reason) { return reply(e, 401, { code: 'session_revoked', reason: reason, message: 'This session is no longer valid.' }) }

// 令牌被拒绝时的响应。请求里带着的会话 id 如果已被撤销, 就告诉设备真实原因 (比如在别的设备上改了密码 → password_changed),
// 查不到 / 没撤销就是 expired。只会透露「撤销原因」, 会话 id 本身是 15 位随机串, 猜不到。
function tokenRejected(e) {
  let reason = 'expired'
  const sid = sessionHeader(e)
  if (SID_RE.test(sid)) {
    try {
      const s = $app.findRecordById('device_sessions', sid)
      if (unixOf(s, 'revoked_at')) reason = s.getString('revoked_reason') || 'expired'
    } catch (_) { /* 没有这个会话: expired */ }
  }
  return revokedReply(e, reason)
}

// 设备调用的接口: 令牌 + 会话都要有效
function needSession(e) {
  const g = needUser(e)
  if (g.res) return g
  const c = checkSession($app, g.user, sessionHeader(e), nowSec())
  if (c.missing) return { res: fail(e, 401, 'session_required', 'The X-Enana-Session header is required.') }
  if (c.revoked) {
    if (c.expired) {
      try { c.session.set('revoked_at', iso(nowSec())); c.session.set('revoked_reason', 'expired'); $app.save(c.session) } catch (_) { /* 下次再标记 */ }
    }
    return { res: revokedReply(e, c.revoked) }
  }
  return { user: g.user, session: c.session }
}

// ---------------------------------------------------------------- 登录限流 (按邮箱 / 按 IP, 数据来自 audit_events)

function failuresWait(app, emailKey, ipKey, t) {
  const cut = iso(t - FAIL_WINDOW)
  let wait = 0
  const checks = [['em', emailKey, FAIL_LIMIT_EMAIL], ['ip', ipKey, FAIL_LIMIT_IP]]
  for (let i = 0; i < checks.length; i++) {
    const k = checks[i][0], v = checks[i][1], limit = checks[i][2]
    if (!v) continue
    const where = "type = 'login_failed' AND created > {:cut} AND json_extract(detail, {:path}) = {:v}"
    const params = { cut: cut, path: '$.' + k, v: v }
    const n = app.countRecords('audit_events', $dbx.exp(where, params))
    if (n >= limit) {
      // 再等多久才会有足够多的旧记录滑出窗口: 第 (n - limit) 条最旧记录过期之后失败次数就低于上限了
      const row = new DynamicModel({ created: '' })
      try {
        app.db().newQuery('SELECT created FROM audit_events WHERE ' + where + ' ORDER BY created ASC LIMIT 1 OFFSET ' + (n - limit)).bind(params).one(row)
        const at = Math.floor(new Date(String(row.created).replace(' ', 'T')).getTime() / 1000) + FAIL_WINDOW
        wait = Math.max(wait, at - t)
      } catch (_) { wait = Math.max(wait, FAIL_WINDOW) }
      wait = Math.max(wait, 1)
    }
  }
  return wait
}

// ---------------------------------------------------------------- POST /auth/login

function login(e) {
  const t = nowSec()
  const body = readJSON(e, SMALL_BODY_MAX)
  if (!body) return fail(e, 400, 'bad_request', 'The body must be a JSON object.')
  const email = typeof body.email === 'string' ? body.email.trim() : ''
  const password = typeof body.password === 'string' ? body.password : ''
  if (!email || email.length > 255 || !password || password.length > 255) return fail(e, 400, 'bad_request', 'email and password are required.')
  const dev = parseDevice(body.device)
  if (dev.error) return fail(e, 400, 'bad_request', dev.error)
  const kickUid = typeof body.kick_device_uid === 'string' ? body.kick_device_uid.trim() : ''
  if (kickUid && !/^[A-Za-z0-9._-]{8,64}$/.test(kickUid)) return fail(e, 400, 'bad_request', 'kick_device_uid is not valid.')

  const ip = e.realIP()
  const ipMasked = maskIP(ip)

  // 1) 限流 (失败次数过多 → 429 + Retry-After); 与 PocketBase 自带的按 IP 限流叠加
  const emailKey = hkey($app, email)
  const ipKey = ip ? hkey($app, ip) : ''
  const wait = failuresWait($app, emailKey, ipKey, t)
  if (wait > 0) {
    e.response.header().set('Retry-After', String(wait))
    return fail(e, 429, 'too_many_attempts', 'Too many failed attempts. Try again later.', { retry_after: wait })
  }

  // 2) 校验密码 (用 PocketBase 自己的密码校验, 不自己实现哈希); 邮箱不存在也做一次等价的计算, 避免时间差泄露
  let user = null
  try { user = $app.findAuthRecordByEmail('users', email) } catch (_) { user = null }
  let ok = false
  if (user) {
    ok = user.validatePassword(password)
  } else {
    try { $app.findFirstRecordByFilter('users', "id != ''").validatePassword(password) } catch (_) { /* 没有任何用户时跳过 */ }
  }
  if (!ok) {
    audit($app, 'login_failed', { user: user ? user.id : '', ip: ipMasked, detail: { em: emailKey, ip: ipKey } })
    return fail(e, 400, 'bad_credentials', 'Wrong email or password.')
  }
  if (user.getBool('disabled')) return fail(e, 403, 'account_disabled', 'This account is disabled.')

  // 3) 同一个事务里: 设备登记 + 踢人 (可选) + 统计 + 建会话。PocketBase 的 SQLite 同一时刻只有一个写事务,
  //    所以两个并发登录不可能同时看到「还剩一个名额」。
  let out
  $app.runInTransaction((tx) => { out = loginTx(tx, user, dev, kickUid, ipMasked, t) })
  if (out.status !== 200) return reply(e, out.status, out.body)

  return reply(e, 200, {
    token: user.newAuthToken(),
    user: { id: user.id, email: user.email() },
    session: { id: out.session.id, expires_at: t + SESSION_TTL },
    plan: { code: out.plan.code, max_devices_per_platform: out.plan.limit },
    heartbeat_secs: HEARTBEAT_SECS,
  })
}

function loginTx(tx, user, d, kickUid, ipMasked, t) {
  const plan = planFor(tx, user, t)
  const device = upsertDevice(tx, user, d, ipMasked, t)

  // 同一台设备重新登录: 它之前没撤销的会话先作废, 不占名额
  revokeDeviceSessions(tx, user.id, device.id, 'logout', '', t)

  // 用户在登录界面选了某台设备「下线」: 必须是同账号、同平台的另一台设备
  if (kickUid && kickUid !== d.uid) {
    let target = null
    try { target = findDevice(tx, user.id, kickUid) } catch (_) { target = null }
    if (!target || target.getString('platform') !== d.platform) {
      return { status: 400, body: { code: 'bad_request', message: 'kick_device_uid is not another device of this account on this platform.' } }
    }
    const n = revokeDeviceSessions(tx, user.id, target.id, 'kicked', device.id, t)
    if (n > 0) audit(tx, 'kick', { user: user.id, device: target.id, ip: ipMasked, detail: { by: d.uid, sessions: n } })
  }

  const active = activeOnPlatform(tx, user.id, d.platform, t, '')
  if (active.length >= plan.limit) {
    audit(tx, 'limit_blocked', { user: user.id, device: device.id, ip: ipMasked, detail: { platform: d.platform, limit: plan.limit } })
    return {
      status: 409,
      body: {
        code: 'device_limit', platform: d.platform, limit: plan.limit,
        devices: active.map((x) => { const j = deviceJSON(x.device, true); delete j.arch; return j }),   // uid name platform os app last_seen online ip_hint
      },
    }
  }

  const s = new Record(tx.findCachedCollectionByNameOrId('device_sessions'))
  s.set('user', user.id)
  s.set('device', device.id)
  s.set('last_heartbeat_at', iso(t))
  s.set('expires_at', iso(t + SESSION_TTL))
  tx.save(s)
  audit(tx, 'login', { user: user.id, device: device.id, ip: ipMasked, detail: { platform: d.platform, app: d.app } })
  return { status: 200, session: s, plan: plan }
}

// ---------------------------------------------------------------- POST /session/heartbeat

function heartbeat(e) {
  const g = needUser(e)
  if (g.res) return g.res
  const sid = sessionHeader(e)
  if (!sid) return fail(e, 401, 'session_required', 'The X-Enana-Session header is required.')
  const t = nowSec()
  const ipMasked = maskIP(e.realIP())
  let out
  $app.runInTransaction((tx) => { out = heartbeatTx(tx, g.user, sid, ipMasked, t) })
  if (out.revoked) return revokedReply(e, out.revoked)
  return reply(e, 200, { ok: true, token: g.user.newAuthToken(), expires_at: out.expires_at })
}

function heartbeatTx(tx, user, sid, ipMasked, t) {
  const c = checkSession(tx, user, sid, t)
  if (c.revoked) {
    if (c.expired) {
      c.session.set('revoked_at', iso(t)); c.session.set('revoked_reason', 'expired'); tx.save(c.session)
    }
    return { revoked: c.revoked }
  }
  const s = c.session
  const dev = tx.findRecordById('devices', s.getString('device'))

  // 重新激活规则: 这个会话超过 10 分钟没有心跳 (比如电脑睡了很久), 期间名额可能已被别的设备占用。
  // 如果该平台已经有 limit 个别的在线会话, 这个会话作废 (reason=limit), 设备需要重新登录。
  if (unixOf(s, 'last_heartbeat_at') <= t - ONLINE_WINDOW) {
    const plan = planFor(tx, user, t)
    const others = activeOnPlatform(tx, user.id, dev.getString('platform'), t, s.id)
    if (others.length >= plan.limit) {
      s.set('revoked_at', iso(t)); s.set('revoked_reason', 'limit'); tx.save(s)
      audit(tx, 'session_revoked', { user: user.id, device: dev.id, ip: ipMasked, detail: { reason: 'limit' } })
      return { revoked: 'limit' }
    }
  }
  s.set('last_heartbeat_at', iso(t))
  tx.save(s)
  dev.set('last_seen_at', iso(t))
  dev.set('last_ip_masked', ipMasked)
  tx.save(dev)
  return { expires_at: unixOf(s, 'expires_at') }
}

// ---------------------------------------------------------------- POST /session/logout, GET /session/check

function logout(e) {
  const g = needUser(e)
  if (g.res) return g.res
  const sid = sessionHeader(e)
  const t = nowSec()
  const c = checkSession($app, g.user, sid, t)
  // 已经被撤销 / 过期的会话再登出: 照样返回 ok (幂等), 设备本来就要退出
  if (c.session) {
    const s = c.session
    $app.runInTransaction((tx) => {
      const cur = tx.findRecordById('device_sessions', s.id)
      if (!unixOf(cur, 'revoked_at')) {
        cur.set('revoked_at', iso(t)); cur.set('revoked_reason', 'logout'); tx.save(cur)
        audit(tx, 'logout', { user: g.user.id, device: cur.getString('device'), ip: maskIP(e.realIP()), detail: {} })
      }
    })
  }
  return reply(e, 200, { ok: true })
}

// 给 nginx 的 auth_request 用: 只做一次按 id 的查询, 成功 204, 否则 401
function check(e) {
  const u = e.auth
  if (!u || u.collection().name !== 'users' || u.getBool('disabled')) return reply(e, 401, { code: 'unauthorized' })
  const c = checkSession($app, u, sessionHeader(e), nowSec())
  if (c.session) { e.noContent(204); return true }
  return reply(e, 401, { code: 'session_revoked', reason: c.revoked || 'expired' })
}

// ---------------------------------------------------------------- 设备列表 / 踢设备 / 套餐

function devices(e) {
  const g = needSession(e)
  if (g.res) return g.res
  const t = nowSec()
  const plan = planFor($app, g.user, t)
  const online = {}
  for (const s of activeSessions($app, g.user.id, t)) online[s.getString('device')] = true
  const list = $app.findRecordsByFilter('devices', 'user = {:u}', '-last_seen_at', 200, 0, { u: g.user.id })
  const currentDevice = g.session.getString('device')
  let platform = null
  const out = list.map((d) => {
    if (d.id === currentDevice) platform = d.getString('platform')
    return deviceJSON(d, online[d.id], d.id === currentDevice)
  })
  return reply(e, 200, { limit: plan.limit, platform: platform, devices: out })
}

function kick(e) {
  const g = needSession(e)
  if (g.res) return g.res
  const body = readJSON(e, SMALL_BODY_MAX)
  const uid = body && typeof body.device_uid === 'string' ? body.device_uid.trim() : ''
  if (!/^[A-Za-z0-9._-]{8,64}$/.test(uid)) return fail(e, 400, 'bad_request', 'device_uid is required.')
  let target
  try { target = findDevice($app, g.user.id, uid) } catch (_) { return fail(e, 404, 'device_not_found', 'No such device on this account.') }
  const selfDevice = g.session.getString('device')
  if (target.id === selfDevice) return fail(e, 400, 'cannot_kick_self', 'Use logout to sign this device out.')
  const t = nowSec()
  const ipMasked = maskIP(e.realIP())
  $app.runInTransaction((tx) => {
    const n = revokeDeviceSessions(tx, g.user.id, target.id, 'kicked', selfDevice, t)
    audit(tx, 'kick', { user: g.user.id, device: target.id, ip: ipMasked, detail: { sessions: n } })
  })
  return reply(e, 200, { ok: true })
}

// 套餐 + 权益 (docs/API.md「会员 / 套餐」): 界面提示用; 真正的限制在云端 (比如官方线路只有核对订阅后才下发)
function plan(e) {
  const g = needSession(e)
  if (g.res) return g.res
  const t = nowSec()
  const p = planFor($app, g.user, t)
  const n = officialCount($app, t)
  const ent = entitlements(p, { nodes: n, verified: g.user.verified() })
  const on = ent.official_proxy.enabled
  return reply(e, 200, {
    plan: { code: p.code, title: p.title, max_devices_per_platform: p.limit },
    expires_at: p.expires_at,
    limits: { devices_per_platform: p.limit },
    features: ent,
    official: { available: on, nodes: on ? n : 0 },
  })
}

// 官方线路节点 (会员功能): 只发给「套餐有效 (Pro) 且邮箱已验证」的账号, 其它人永远得到空列表。
// 响应 {entitled, nodes:[{outbound}]}; 没有新鲜节点 (订阅源暂时不可用) 时 entitled 仍然是 true、nodes 为空 —— 客户端据此保留本机已有的节点直到宽限期结束。
// 不返回订阅源的任何信息 (编号 / 地址 / 令牌)。
function nodes(e) {
  const g = needSession(e)
  if (g.res) return g.res
  const t = nowSec()
  const acc = officialAccess(planFor($app, g.user, t), g.user.verified())
  // The body is serialised here and written as a string: e.json() hands the object to Go, which does not keep the
  // key order, and the client's awk depends on `type` then `tag` being the first two keys of every outbound.
  const out = acc.entitled ? { entitled: true, nodes: officialRows($app, t) } : { entitled: false, nodes: [] }
  e.response.header().set('Cache-Control', 'no-store')
  e.response.header().set('Content-Type', 'application/json; charset=utf-8')
  e.string(200, JSON.stringify(out))
  return true
}

// ---------------------------------------------------------------- POST /account/password

function utf8Len(str) { return unescape(encodeURIComponent(str)).length }

// 改密码: 先用 PocketBase 自己的校验确认旧密码, 再设置新密码; 当前设备保持登录 (返回新令牌), 账号下其它设备的会话全部撤销。
function changePassword(e) {
  const g = needSession(e)
  if (g.res) return g.res
  const body = readJSON(e, SMALL_BODY_MAX)
  const oldPw = body && typeof body.old_password === 'string' ? body.old_password : ''
  const newPw = body && typeof body.new_password === 'string' ? body.new_password : ''
  if (!oldPw || !newPw || oldPw.length > 255 || newPw.length > 255) return fail(e, 400, 'bad_request', 'old_password and new_password are required.')
  const t = nowSec()
  const ip = e.realIP()
  const ipMasked = maskIP(ip)

  // 这个接口会验证旧密码, 不能让偷到令牌的人用它无限次试密码: 与登录共用失败计数 (按邮箱 / 按 IP)
  const emailKey = hkey($app, g.user.email())
  const ipKey = ip ? hkey($app, ip) : ''
  const wait = failuresWait($app, emailKey, ipKey, t)
  if (wait > 0) {
    e.response.header().set('Retry-After', String(wait))
    return fail(e, 429, 'too_many_attempts', 'Too many failed attempts. Try again later.', { retry_after: wait })
  }
  if (!g.user.validatePassword(oldPw)) {
    audit($app, 'login_failed', { user: g.user.id, ip: ipMasked, detail: { em: emailKey, ip: ipKey } })
    return fail(e, 400, 'bad_credentials', 'The old password is wrong.')
  }
  // 新密码: 8~71 个字符 (与 users 集合的规则一致), bcrypt 只看前 72 个字节 → 字节数也不能超过 72; 不能与旧密码相同
  const chars = Array.from(newPw).length
  if (chars < 8 || chars > 71 || utf8Len(newPw) > 72 || newPw === oldPw) {
    return fail(e, 400, 'weak_password', 'The new password must be 8-71 characters (at most 72 bytes) and different from the old one.')
  }

  let out
  $app.runInTransaction((tx) => {
    const c = checkSession(tx, g.user, g.session.id, t)         // 事务里再确认一次: 刚被踢掉的设备不能改密码
    if (c.revoked) { out = { revoked: c.revoked }; return }
    const u = tx.findRecordById('users', g.user.id)
    u.setPassword(newPw)
    u.refreshTokenKey()                                          // 旧令牌立即作废 (所有设备手里的 JWT)
    tx.save(u)
    const others = tx.findRecordsByFilter('device_sessions', "user = {:u} && revoked_at = '' && id != {:s}", '', 500, 0, { u: u.id, s: g.session.id })
    for (const s of others) {
      s.set('revoked_at', iso(t)); s.set('revoked_reason', 'password_changed'); tx.save(s)
    }
    audit(tx, 'password_changed', { user: u.id, device: g.session.getString('device'), ip: ipMasked, detail: { revoked: others.length } })
    out = { user: u }
  })
  if (out.revoked) return revokedReply(e, out.revoked)
  return reply(e, 200, { ok: true, token: out.user.newAuthToken(), session: { id: g.session.id, expires_at: unixOf(g.session, 'expires_at') } })
}

// ---------------------------------------------------------------- 同步快照 (密文)

function snapshotRow(app, userId) {
  try { return app.findFirstRecordByFilter('sync_snapshots', 'user = {:u}', { u: userId }) } catch (_) { return null }
}

function syncGet(e) {
  const wantPayload = e.request.url.query().get('payload') === '1'
  const g = needSession(e)
  if (g.res) return g.res
  const row = snapshotRow($app, g.user.id)
  if (!row) return reply(e, 200, { exists: false })
  const out = { exists: true, version: row.getInt('version'), updated: unixOf(row, 'updated'), size: row.getInt('size'), device: row.getString('source_device') }
  if (wantPayload) {
    out.payload = row.getString('payload')
    audit($app, 'sync_pull', { user: g.user.id, device: g.session.getString('device'), ip: maskIP(e.realIP()), detail: { version: out.version } })
  }
  return reply(e, 200, out)
}

function syncPut(e) {
  const g = needSession(e)
  if (g.res) return g.res
  const body = readJSON(e, SYNC_BODY_MAX)
  if (!body) return fail(e, 400, 'bad_request', 'The body must be a JSON object.')
  const base = body.base_version
  const payload = body.payload
  const size = body.size
  if (!Number.isInteger(base) || base < 0) return fail(e, 400, 'bad_request', 'base_version must be an integer >= 0.')
  if (typeof payload !== 'string' || !payload.length || payload.length > MAX_PAYLOAD || !/^[A-Za-z0-9+\/_=-]+$/.test(payload)) {
    return fail(e, 400, 'bad_request', 'payload must be a base64 string of 1 to ' + MAX_PAYLOAD + ' characters.')
  }
  if (!Number.isInteger(size) || size < 0 || size > MAX_PAYLOAD) return fail(e, 400, 'bad_request', 'size must be an integer between 0 and ' + MAX_PAYLOAD + '.')
  const dev = $app.findRecordById('devices', g.session.getString('device'))
  const ipMasked = maskIP(e.realIP())
  let out
  $app.runInTransaction((tx) => {
    // 事务里重新确认会话还有效 (别让刚被踢掉的设备写进去)
    const c = checkSession(tx, g.user, g.session.id, nowSec())
    if (c.revoked) { out = { revoked: c.revoked }; return }
    let row = snapshotRow(tx, g.user.id)
    const cur = row ? row.getInt('version') : 0
    if (cur !== base) { out = { conflict: cur }; return }
    if (!row) { row = new Record(tx.findCachedCollectionByNameOrId('sync_snapshots')); row.set('user', g.user.id) }
    row.set('version', cur + 1)
    row.set('payload', payload)
    row.set('size', size)
    row.set('source_device', dev.getString('name') || dev.getString('device_uid'))
    tx.save(row)
    audit(tx, 'sync_push', { user: g.user.id, device: dev.id, ip: ipMasked, detail: { version: cur + 1, size: size } })
    out = { version: cur + 1 }
  })
  if (out.revoked) return revokedReply(e, out.revoked)
  if (out.conflict !== undefined) return reply(e, 409, { code: 'conflict', version: out.conflict })
  return reply(e, 200, { version: out.version })
}

function syncDelete(e) {
  const g = needSession(e)
  if (g.res) return g.res
  const row = snapshotRow($app, g.user.id)
  if (row) {
    $app.delete(row)
    audit($app, 'sync_clear', { user: g.user.id, device: g.session.getString('device'), ip: maskIP(e.realIP()), detail: {} })
  }
  return reply(e, 200, { ok: true })
}

// ---------------------------------------------------------------- 注册钩子 / 定时清理

// users 创建成功后: 给新账号建 free 订阅 (已存在就跳过); 登录时 planFor 也会补, 这里是主路径
function onUserCreated(user) {
  try {
    const s = new Record($app.findCachedCollectionByNameOrId('subscriptions'))
    s.set('user', user.id); s.set('plan', freePlan($app).id); s.set('status', 'active'); s.set('source', 'default')
    $app.save(s)
  } catch (_) { /* 已存在 */ }
}
function onUserCreateRequest(e) {
  audit($app, 'register', { user: e.record.id, ip: maskIP(e.realIP()), detail: {} })
}

// 每天一次: 登录失败记录 14 天、其它审计记录 180 天、已撤销 / 过期的会话 30 天后清理 (原生 SQL, 不触发钩子)
function gc() {
  const t = nowSec()
  const db = $app.db()
  db.newQuery("DELETE FROM audit_events WHERE type = 'login_failed' AND created < {:a}").bind({ a: iso(t - 14 * 86400) }).execute()
  db.newQuery('DELETE FROM audit_events WHERE created < {:a}').bind({ a: iso(t - 180 * 86400) }).execute()
  db.newQuery("DELETE FROM device_sessions WHERE (revoked_at != '' AND revoked_at < {:a}) OR (expires_at != '' AND expires_at < {:a})").bind({ a: iso(t - 30 * 86400) }).execute()
}

module.exports = {
  login: login, heartbeat: heartbeat, logout: logout, check: check,
  devices: devices, kick: kick, plan: plan, nodes: nodes, changePassword: changePassword,
  syncGet: syncGet, syncPut: syncPut, syncDelete: syncDelete,
  onUserCreated: onUserCreated, onUserCreateRequest: onUserCreateRequest, gc: gc,
  needSession: needSession, planFor: planFor, readJSON: readJSON, entitlements: entitlements, officialAccess: officialAccess,
  reply: reply, fail: fail, clean: clean, nowSec: nowSec, iso: iso,       // 给 enana_diag.js 用
}
