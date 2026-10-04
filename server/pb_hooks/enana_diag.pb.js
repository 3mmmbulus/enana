/// <reference path="../pb_data/types.d.ts" />
// 诊断上传的路由注册 (实现在 enana_diag.js; 说明见 docs/DIAGNOSTICS.md)。
// 请求体大小上限: 摘要 128 KB, 完整诊断 9 MB (nginx 对这两个精确路径放宽到同样的上限, 见 server/update-nginx-diag.py)。

routerAdd("POST", "/api/enana/v1/diag",
  (e) => { require(`${__hooks}/enana_diag.js`).uploadSummary(e) },
  $apis.bodyLimit(131072))

// 删除自己已上传的全部诊断 (设置里「删除已上传的诊断」)
routerAdd("DELETE", "/api/enana/v1/diag",
  (e) => { require(`${__hooks}/enana_diag.js`).deleteMine(e) })

routerAdd("POST", "/api/enana/v1/diag/full",
  (e) => { require(`${__hooks}/enana_diag.js`).uploadFull(e) },
  $apis.bodyLimit(9437184))

// 每天 03:27 清理超过 7 天的诊断 (和 enana_gc 错开几分钟)
cronAdd("enana_diag_gc", "27 3 * * *", () => {
  require(`${__hooks}/enana_diag.js`).gc()
})
