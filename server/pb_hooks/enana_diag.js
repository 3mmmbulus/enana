/// <reference path="../pb_data/types.d.ts" />
// 诊断上传 (摘要 + 用户主动发送的完整诊断), 路由在 enana_diag.pb.js; 数据模型见 pb_migrations/1790000004_enana_diag.js, 说明见 docs/DIAGNOSTICS.md。
// PocketBase 的处理函数在隔离的上下文里执行: 共享模块在函数体里 require, 不能依赖文件级变量。

const SUMMARY_MAX = 98304            // 摘要 JSON 最多多少字符 (diag_reports.payload 的 maxSize 是 131072, 留余量)
const FULL_MAX = 8388608             // 完整诊断压缩包最多多少字节 (与 bundle 字段的 maxSize 一致)
const KEEP_DAYS = 7                  // 保留天数
const KEEP_SUMMARY = 200             // 每台设备最多保留几份摘要
const KEEP_FULL = 5                  // 每台设备最多保留几份完整诊断
const SUMMARY_GAP = 300              // 秒: 同一设备两次摘要之间至少隔多久 (login / register / manual 触发的不受这个限制)
const SUMMARY_DAY = 60               // 每台设备每天最多几份摘要
const FULL_DAY = 3                   // 每台设备每天最多几份完整诊断

const ALLOWED_TOP = ['v', 'generated', 'meta', 'verdict', 'env', 'ops', 'health', 'outages']

// 摘要的形状检查 (客户端按白名单生成, 这里是第二道防线: 限制深度 / 长度 / 数量, 不让任何人把大块任意内容塞进来)
function shapeOk(v, depth) {
  if (depth > 5) return false
  if (v === null || typeof v === 'number' || typeof v === 'boolean') return true
  if (typeof v === 'string') return v.length <= 2000
  if (Array.isArray(v)) { if (v.length > 600) return false; for (let i = 0; i < v.length; i++) if (!shapeOk(v[i], depth + 1)) return false; return true }
  if (typeof v === 'object') {
    const ks = Object.keys(v); if (ks.length > 200) return false
    for (let i = 0; i < ks.length; i++) { if (ks[i].length > 80 || !shapeOk(v[ks[i]], depth + 1)) return false }
    return true
  }
  return false
}

function pruneDevice(app, deviceId, kind, keep) {
  // 超出保留条数的旧记录: 排序后从第 keep 条之后全部删掉 (完整诊断带文件, 必须走 app.delete 才会同时删文件)
  const rows = app.findRecordsByFilter('diag_reports', 'device = {:d} && kind = {:k}', '-created', 50, keep, { d: deviceId, k: kind })
  for (let i = 0; i < rows.length; i++) { try { app.delete(rows[i]) } catch (_) { /* 下次再清 */ } }
}

// POST /api/enana/v1/diag  {trigger, payload}  -> {ok, id}
function uploadSummary(e) {
  const L = require(`${__hooks}/enana_lib.js`)
  const g = L.needSession(e)
  if (g.res) return g.res
  const body = L.readJSON(e, SUMMARY_MAX + 4096)
  if (!body) return L.fail(e, 400, 'bad_request', 'The body must be a JSON object.')
  const payload = body.payload
  if (!payload || typeof payload !== 'object' || Array.isArray(payload) || payload.v !== 1) return L.fail(e, 400, 'bad_request', 'payload must be a v1 summary object.')
  const keys = Object.keys(payload)
  for (let i = 0; i < keys.length; i++) if (ALLOWED_TOP.indexOf(keys[i]) < 0) return L.fail(e, 400, 'bad_request', 'Unknown payload section: ' + keys[i].slice(0, 40))
  if (!shapeOk(payload, 0)) return L.fail(e, 400, 'bad_request', 'The payload is too deeply nested or too large.')
  const text = JSON.stringify(payload)
  if (text.length > SUMMARY_MAX) return L.fail(e, 413, 'too_large', 'The summary is larger than ' + SUMMARY_MAX + ' characters.')
  const trigger = L.clean(typeof body.trigger === 'string' ? body.trigger : '', 40) || 'event'
  const dev = $app.findRecordById('devices', g.session.getString('device'))
  const t = L.nowSec()
  const first = trigger === 'login' || trigger === 'register' || trigger === 'manual'
  if (!first) {
    const recent = $app.countRecords('diag_reports', $dbx.exp("device = {:d} AND kind = 'summary' AND created > {:t}", { d: dev.id, t: L.iso(t - SUMMARY_GAP) }))
    if (recent > 0) return L.fail(e, 429, 'rate_limited', 'Summaries from one device must be at least ' + SUMMARY_GAP + ' seconds apart.', { retry_after: SUMMARY_GAP })
  }
  const today = $app.countRecords('diag_reports', $dbx.exp("device = {:d} AND kind = 'summary' AND created > {:t}", { d: dev.id, t: L.iso(t - 86400) }))
  if (today >= SUMMARY_DAY) return L.fail(e, 429, 'rate_limited', 'Too many summaries from this device today.', { retry_after: 3600 })
  let cause = ''
  try { cause = L.clean(String((payload.verdict && payload.verdict.cause) || ''), 40) } catch (_) { cause = '' }
  const rec = new Record($app.findCachedCollectionByNameOrId('diag_reports'))
  rec.set('user', g.user.id)
  rec.set('device', dev.id)
  rec.set('kind', 'summary')
  rec.set('trigger', trigger)
  rec.set('cause', cause)
  rec.set('app_version', L.clean(String((payload.meta && payload.meta.version) || ''), 32))
  rec.set('payload', payload)
  $app.save(rec)
  pruneDevice($app, dev.id, 'summary', KEEP_SUMMARY)
  return L.reply(e, 200, { ok: true, id: rec.id })
}

// POST /api/enana/v1/diag/full  (multipart: bundle=<.gz>, app=<版本>)  -> {ok, id}   id 就是用户发给开发者的「报告编号」
function uploadFull(e) {
  const L = require(`${__hooks}/enana_lib.js`)
  const g = L.needSession(e)
  if (g.res) return g.res
  let files = []
  try { files = e.findUploadedFiles('bundle') } catch (_) { files = [] }
  if (!files || files.length !== 1) return L.fail(e, 400, 'bad_request', 'Exactly one "bundle" file is required (multipart/form-data).')
  if (files[0].size > FULL_MAX) return L.fail(e, 413, 'too_large', 'The bundle is larger than ' + FULL_MAX + ' bytes.')
  const dev = $app.findRecordById('devices', g.session.getString('device'))
  const t = L.nowSec()
  const today = $app.countRecords('diag_reports', $dbx.exp("device = {:d} AND kind = 'full' AND created > {:t}", { d: dev.id, t: L.iso(t - 86400) }))
  if (today >= FULL_DAY) return L.fail(e, 429, 'rate_limited', 'Too many full diagnostics from this device today.', { retry_after: 3600 })
  let appVer = ''
  try { appVer = L.clean(e.request.formValue('app') || '', 32) } catch (_) { appVer = '' }
  const rec = new Record($app.findCachedCollectionByNameOrId('diag_reports'))
  rec.set('user', g.user.id)
  rec.set('device', dev.id)
  rec.set('kind', 'full')
  rec.set('trigger', 'manual')
  rec.set('app_version', appVer)
  rec.set('bundle', files[0])
  $app.save(rec)
  pruneDevice($app, dev.id, 'full', KEEP_FULL)
  return L.reply(e, 200, { ok: true, id: rec.id })
}

// DELETE /api/enana/v1/diag  -> {ok, deleted}   用户随时可以删除自己已经上传的全部诊断 (所有设备、摘要和完整诊断, 带文件的一并删除)
function deleteMine(e) {
  const L = require(`${__hooks}/enana_lib.js`)
  const g = L.needSession(e)
  if (g.res) return g.res
  let n = 0
  for (let k = 0; k < 20; k++) {      // 一次最多 20 × 200 份
    const rows = $app.findRecordsByFilter('diag_reports', 'user = {:u}', 'created', 200, 0, { u: g.user.id })
    if (!rows.length) break
    for (let i = 0; i < rows.length; i++) { try { $app.delete(rows[i]); n++ } catch (_) { /* 下次再删 */ } }
  }
  return L.reply(e, 200, { ok: true, deleted: n })
}

// 每天一次: 超过保留期的全部清掉 (摘要用原生 SQL; 完整诊断带文件, 逐条走 app.delete 才会同时删文件)
function gc() {
  const L = require(`${__hooks}/enana_lib.js`)
  const cut = L.iso(L.nowSec() - KEEP_DAYS * 86400)
  $app.db().newQuery("DELETE FROM diag_reports WHERE kind = 'summary' AND created < {:a}").bind({ a: cut }).execute()
  for (let n = 0; n < 20; n++) {      // 一次最多清 20 × 200 份完整诊断, 余下的明天继续
    const old = $app.findRecordsByFilter('diag_reports', "kind = 'full' && created < {:a}", 'created', 200, 0, { a: cut })
    if (!old.length) break
    for (let i = 0; i < old.length; i++) { try { $app.delete(old[i]) } catch (_) { /* 下次再清 */ } }
  }
}

module.exports = { uploadSummary: uploadSummary, uploadFull: uploadFull, deleteMine: deleteMine, gc: gc, SUMMARY_MAX: SUMMARY_MAX, FULL_MAX: FULL_MAX, KEEP_DAYS: KEEP_DAYS }
