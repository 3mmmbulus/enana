/// <reference path="../pb_data/types.d.ts" />
// Official route nodes: hourly import from the privately configured subscription sources (enana_official.js).
// The source list lives in /etc/enana/official.json (see server/README.md); nothing about it is public.
// A healthy source is only fetched every ~3 hours; a failing one is retried hourly and keeps serving its existing
// nodes until their fresh_until passes. Every handler requires the module inside its own body (isolated contexts).
cronAdd('enana_official_sync', '23 * * * *', () => {
  try { require(`${__hooks}/enana_official.js`).sync(false) } catch (_) { /* next hour */ }
})

// Operator routes: superuser only (restricted to loopback by the settings migration) and not in the public nginx allow-list.
//   POST /api/enana/admin/official/sync   fetch every enabled source now -> {ok, sources:[{id, ok, nodes, skipped, error}]}
//   GET  /api/enana/admin/official/status per source: stored / fresh node counts and last success (no URL, no credentials)
routerAdd('POST', '/api/enana/admin/official/sync',
  (e) => e.json(200, { ok: true, sources: require(`${__hooks}/enana_official.js`).sync(true) }),
  $apis.requireSuperuserAuth())
routerAdd('GET', '/api/enana/admin/official/status',
  (e) => e.json(200, Object.assign({ ok: true }, require(`${__hooks}/enana_official.js`).status())),
  $apis.requireSuperuserAuth())
