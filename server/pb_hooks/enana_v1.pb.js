/// <reference path="../pb_data/types.d.ts" />
// enana 云端接口的路由注册 (实现在 enana_lib.js; 接口说明见 enana 仓库的 docs/CLOUD_API.md)。
// PocketBase 的处理函数各自在隔离的上下文里执行, 看不到文件级变量, 所以每个处理函数都在函数体里 require 共享模块。
// 请求体大小上限: 普通接口 16 KB, 同步快照 1.5 MB (nginx 对 sync/snapshot 也是这个上限)。

routerAdd("POST", "/api/enana/v1/auth/login",
  (e) => { require(`${__hooks}/enana_lib.js`).login(e) },
  $apis.bodyLimit(16384))

// 心跳和 session/check 很频繁, 成功的请求不写活动日志 (失败的仍然记录)
routerAdd("POST", "/api/enana/v1/session/heartbeat",
  (e) => { require(`${__hooks}/enana_lib.js`).heartbeat(e) },
  $apis.bodyLimit(16384), $apis.skipSuccessActivityLog())

routerAdd("POST", "/api/enana/v1/session/logout",
  (e) => { require(`${__hooks}/enana_lib.js`).logout(e) },
  $apis.bodyLimit(16384))

routerAdd("GET", "/api/enana/v1/session/check",
  (e) => { require(`${__hooks}/enana_lib.js`).check(e) },
  $apis.skipSuccessActivityLog())

routerAdd("GET", "/api/enana/v1/devices",
  (e) => { require(`${__hooks}/enana_lib.js`).devices(e) })

routerAdd("POST", "/api/enana/v1/devices/kick",
  (e) => { require(`${__hooks}/enana_lib.js`).kick(e) },
  $apis.bodyLimit(16384))

routerAdd("GET", "/api/enana/v1/plan",
  (e) => { require(`${__hooks}/enana_lib.js`).plan(e) })

// 改密码 (旧密码 + 新密码): 当前设备保持登录, 其它设备的会话全部撤销
routerAdd("POST", "/api/enana/v1/account/password",
  (e) => { require(`${__hooks}/enana_lib.js`).changePassword(e) },
  $apis.bodyLimit(16384))

// 官方线路节点的占位接口 (以后的会员功能): 现在永远是 {"nodes":[],"entitled":false}
routerAdd("GET", "/api/enana/v1/nodes",
  (e) => { require(`${__hooks}/enana_lib.js`).nodes(e) })

routerAdd("GET", "/api/enana/v1/sync/snapshot",
  (e) => { require(`${__hooks}/enana_lib.js`).syncGet(e) })

routerAdd("PUT", "/api/enana/v1/sync/snapshot",
  (e) => { require(`${__hooks}/enana_lib.js`).syncPut(e) },
  $apis.bodyLimit(1572864))

routerAdd("DELETE", "/api/enana/v1/sync/snapshot",
  (e) => { require(`${__hooks}/enana_lib.js`).syncDelete(e) })

// 注册成功: 记一条 register 审计 (这里能拿到客户端 IP) 并给新账号创建 free 订阅。
// 出错只忽略, 不能让注册失败 (登录时 planFor 也会补订阅)。
onRecordCreateRequest((e) => {
  e.next()
  try { require(`${__hooks}/enana_lib.js`).onUserCreateRequest(e) } catch (_) { /* 审计失败不影响注册 */ }
}, "users")

onRecordAfterCreateSuccess((e) => {
  e.next()
  try { require(`${__hooks}/enana_lib.js`).onUserCreated(e.record) } catch (_) { /* 登录时会补 */ }
}, "users")

// 每天 03:17 清理过期的审计记录和旧会话
cronAdd("enana_gc", "17 3 * * *", () => {
  require(`${__hooks}/enana_lib.js`).gc()
})
