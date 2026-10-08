'use strict';
// Official route nodes: scheduled import of third-party subscription sources into `official_nodes`.
//
// The sources live ONLY in a private root:enana file (default /etc/enana/official.json, override with the
// ENANA_OFFICIAL_CONFIG environment variable, same pattern as the billing configuration):
//   {"sources":[{"id":"main","url":"https://example.invalid/subs/TOKEN","ua":"sing-box/1.12.0","prefix":"官方-","enabled":true}], "ttl_hours":24}
// The URL contains a token. It is read from that file at run time and is never stored in the database, never
// logged, never returned by any route and never put into an error message. Only counts and short error codes
// leave this module. `nodes()` / `plan()` in enana_lib.js serve the rows to entitled users only.
//
// A failed fetch, a non-200 answer, an oversized or unparsable body, or a body with no usable node NEVER changes
// existing rows: they simply age out when their `fresh_until` passes.
const base = require('./enana_lib.js'), D = require('./enana_official_domain.js')

const MAX_BODY = 4 * 1024 * 1024           // $http.send reads the whole body first, so this can only reject, not stop the download
const FETCH_TIMEOUT = 25                   // seconds
const SYNC_INTERVAL = 3 * 3600             // a healthy source is fetched about every 3 hours (the cron itself runs hourly)

function readConfig() {   // null = the file is missing / unreadable / not JSON (callers must not treat that as "no sources")
  try { return JSON.parse(toString($os.readFile($os.getenv('ENANA_OFFICIAL_CONFIG') || '/etc/enana/official.json'))) } catch (_) { return null }
}
function config() { return readConfig() || {} }

function sourceRows(app, id) {
  const out = []
  for (const r of app.findAllRecords('official_nodes', $dbx.exp("origin = 'official'"))) {
    if (r.getString('node_key').indexOf(id + '~') === 0) out.push(r)
  }
  return out
}
function freshUntil(r) { const d = r.getDateTime('fresh_until'); return d && !d.isZero() ? d.unix() : 0 }
function lastOk(rows, ttl) {   // every successful sync stamps fresh_until = now + ttl on all of the source's rows
  let m = 0
  rows.forEach((r) => { m = Math.max(m, freshUntil(r)) })
  return m ? m - ttl : 0
}

function fetchSource(src) {
  let res
  try {
    res = $http.send({ url: src.url, method: 'GET', headers: { 'User-Agent': src.ua, 'Accept': 'application/json, */*;q=0.5' }, timeout: FETCH_TIMEOUT })
  } catch (_) { return { error: 'network' } }                  // never forward the exception text: it can contain the URL
  if (!res || res.statusCode !== 200) return { error: 'http_' + (res ? res.statusCode : 0) }
  const bytes = res.body
  if (!bytes || !bytes.length) return { error: 'empty' }
  if (bytes.length > MAX_BODY) return { error: 'too_large' }
  return { text: toString(bytes) }
}

function store(src, nodes, ttl, t) {
  const until = base.iso(t + ttl), keep = {}
  $app.runInTransaction((tx) => {
    const col = tx.findCollectionByNameOrId('official_nodes')
    const old = {}
    sourceRows(tx, src.id).forEach((r) => { old[r.getString('node_key')] = r })
    nodes.forEach((n) => {
      const key = D.nodeKey(src.id, n.tag, $security.sha256)
      keep[key] = true
      let r = old[key]
      if (!r) {
        r = new Record(col); r.set('node_key', key); r.set('origin', 'official')
        r.set('approved', true); r.set('enabled', true); r.set('consent', false); r.set('capability', 'general')     // only on creation: an operator who disables a row in the admin UI keeps it hidden
      }
      r.set('label', n.tag)
      r.set('outbound', JSON.stringify(n.outbound))             // a string, so the key order (type, tag first) is kept as written
      r.set('fresh_until', until)
      tx.save(r)
    })
    Object.keys(old).forEach((k) => { if (!keep[k]) tx.delete(old[k]) })     // vanished upstream: remove (credentials leave the database)
  })
  return Object.keys(keep).length
}

// One source -> {id, ok, nodes, skipped, error?}. Everything is caught here; the message of an exception is never used.
function syncOne(src, ttl, t) {
  const f = fetchSource(src)
  if (f.error) return log({ id: src.id, ok: false, error: f.error })
  const p = D.parseSingBox(f.text, { prefix: src.prefix })
  if (p.error) return log({ id: src.id, ok: false, error: p.error })
  let n = 0
  try { n = store(src, p.nodes, ttl, t) } catch (_) { return log({ id: src.id, ok: false, error: 'store' }) }
  return log({ id: src.id, ok: true, nodes: n, skipped: p.skipped })
}
function log(r) {
  try {
    if (r.ok) $app.logger().info('official sync', 'source', r.id, 'nodes', r.nodes)
    else $app.logger().warn('official sync failed', 'source', r.id, 'code', r.error)
  } catch (_) { /* logging must never break the job */ }
  return r
}

// Delete the rows of sources that are no longer configured / enabled (only when the file was readable).
function retire(enabled) {
  const ids = {}
  enabled.forEach((s) => { ids[s.id] = true })
  let n = 0
  $app.runInTransaction((tx) => {
    for (const r of tx.findAllRecords('official_nodes', $dbx.exp("origin = 'official'"))) {
      const key = r.getString('node_key'), id = key.split('~')[0]
      if (!ids[id]) { tx.delete(r); n++ }
    }
  })
  return n
}

// force = ignore the per-source interval (operator "sync now"). Returns [{id, ok, nodes?, skipped?, error?, due?}].
function sync(force) {
  const raw = readConfig(), cfg = D.normalizeConfig(raw || {}), t = base.nowSec(), out = []
  for (const src of cfg.sources) {
    if (!src.enabled) continue
    const rows = sourceRows($app, src.id)
    if (!force && rows.length && t - lastOk(rows, cfg.ttl) < SYNC_INTERVAL - 300) { out.push({ id: src.id, ok: true, due: false, nodes: rows.length }); continue }
    out.push(syncOne(src, cfg.ttl, t))
  }
  if (raw) { try { retire(cfg.sources.filter((s) => s.enabled)) } catch (_) { /* retried next hour */ } }
  return out
}

// Operator view (superuser route only): per source, how many nodes are stored / still fresh. No URL, no credentials.
function status() {
  const raw = readConfig(), cfg = D.normalizeConfig(raw || {}), t = base.nowSec()
  return {
    configured: !!raw, ttl_hours: cfg.ttl / 3600,
    sources: cfg.sources.map((s) => {
      const rows = sourceRows($app, s.id)
      let fresh = 0
      rows.forEach((r) => { if (freshUntil(r) > t) fresh++ })
      return { id: s.id, enabled: s.enabled, prefix: s.prefix, ua: s.ua, nodes: rows.length, fresh: fresh, last_ok: lastOk(rows, cfg.ttl) || null }
    }),
  }
}

module.exports = { sync: sync, status: status, config: config }
