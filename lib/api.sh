#!/bin/bash
# 本地辅助服务 (CGI 风格): launchd 以 inetd 方式「每个连接启动一次」, 只监听 127.0.0.1。接口约定见 docs/API.md。
# 仪表盘通过它完成所有「写操作」: 登录、应用/网站规则、服务器、订阅、规则库、DNS、设置、日志、更新、测速。不含任何业务密码。
#
# 安全: ① 只接受 Host=127.0.0.1:端口/localhost:端口 (防 DNS 重绑定)
#       ② 所有 /api/ 请求必须带自定义头 X-Enana: 1 (跨站网页发不出带自定义头的请求, 预检会被拒)
#       ③ 除 GET /api/auth/status 与 POST /api/login 外, 都必须带 X-Enana-Token (= 登录后拿到的令牌)
#       ④ CORS 只放行仪表盘自己的来源  ⑤ 所有参数先白名单校验再使用  ⑥ 请求体 ≤ 4 MB  ⑦ 密码只从请求体读取, 不进 URL/日志
# launchd 的 inetd 模式: fd 0 是已连接的套接字 (可读可写)。真机实测写到原来的 stdout 客户端收不到响应,
# 所以先把 stdout 显式指向 fd 0 (在 launchd 与测试里的 inetd 模拟器下都成立)。
[ "${ENANA_API_PIPE:-0}" = 1 ] || exec 1>&0
export LC_ALL=C
_self="${BASH_SOURCE[0]}"; _dir=$(cd "$(dirname "$_self")" && pwd -P)
. "$_dir/common.sh"; init_paths "$_self"
load_settings
QUIET=1; cd "$H" || exit 0

ORIGIN=''; HOST=''; XT=''; TOK=''; SUD=''; LHDR=''; CT=''; CL=0; SFS=''; SFM=''

# ---------- 响应 ----------
set_cors() { # 设置 CORS_H (含结尾 CRLF; 不能用 $(...) 返回, 否则结尾换行会被吞掉)
  local o; CORS_H=''
  for o in "http://127.0.0.1:$API_PORT" "http://localhost:$API_PORT"; do
    if [ -n "$ORIGIN" ] && [ "$o" = "$ORIGIN" ]; then
      printf -v CORS_H 'Access-Control-Allow-Origin: %s\r\nVary: Origin\r\nAccess-Control-Expose-Headers: X-Subscription-Userinfo, X-Profile-Update-Interval, Content-Disposition\r\n' "$o"
    fi
  done
}
send() { # 状态 类型 正文 [额外头(已含 \r\n)]
  printf 'HTTP/1.1 %s\r\nContent-Type: %s; charset=utf-8\r\nContent-Length: %s\r\nCache-Control: no-store\r\nConnection: close\r\n%s%b\r\n%s' \
    "$1" "$2" "${#3}" "$CORS_H" "${4:-}" "$3"
}
send_file() { # 状态 类型 文件 [额外头]
  printf 'HTTP/1.1 %s\r\nContent-Type: %s; charset=utf-8\r\nContent-Length: %s\r\nCache-Control: no-store\r\nConnection: close\r\n%s%b\r\n' \
    "$1" "$2" "$(wc -c < "$3" | tr -d ' ')" "$CORS_H" "${4:-}"
  cat "$3"
}
json() { send 200 application/json "$1"; }
# fail "中文提示" [错误码] [额外 JSON 字段 (不含花括号)]
fail() { json "{\"ok\":false,\"code\":\"${2:-E_INVALID}\",\"error\":\"$(jesc "$(_t "$1")")\"${3:+,$3}}"; exit 0; }
okj()  { json "{\"ok\":true${1:+,$1}}"; }
deny() { send "$1" application/json "{\"ok\":false,\"code\":\"$2\",\"error\":\"$(jesc "$(_t "$3")")\"}"; exit 0; }

# ---------- 请求解析 ----------
IFS= read -r req || exit 0; req=${req%$'\r'}
method=${req%% *}; _rest=${req#* }; target=${_rest%% *}
path=${target%%\?*}; query=''; case $target in *\?*) query=${target#*\?} ;; esac
shopt -s nocasematch                                                  # 头名不区分大小写; 不用 tr, 每个请求少起十几个进程
while IFS= read -r line; do
  line=${line%$'\r'}; [ -z "$line" ] && break
  _hn=${line%%:*}; _hv=${line#*:}; _hv=${_hv# }
  case $_hn in
    host) HOST=$_hv ;; origin) ORIGIN=$_hv ;; x-enana|x-tproxy) XT=$_hv ;; x-enana-token|x-tproxy-token) TOK=$_hv ;; x-enana-sudo) SUD=$_hv ;;
    x-enana-lang) LHDR=$_hv ;; content-type) CT=$_hv ;; content-length) CL=$_hv ;; sec-fetch-site) SFS=$_hv ;; sec-fetch-mode) SFM=$_hv ;;
  esac
done
shopt -u nocasematch
case $CL in ''|*[!0-9]*) CL=0 ;; esac
set_cors

case $HOST in "127.0.0.1:$API_PORT"|"localhost:$API_PORT") ;; *) deny 403 E_FORBIDDEN "拒绝访问" ;; esac

# ---------- 仪表盘 (后台) 的静态文件: /enana/admin/… ----------
# 仪表盘页面由这里直接提供 (和接口同一个来源, 同源请求不需要 CORS 预检)。放在加载其它模块之前处理: 一次打开要取几十个文件, 每个请求都要快。
# 只提供 $H/ui 下白名单扩展名的普通文件: 不跟随符号链接, 不允许 .. / 反斜杠 / 百分号编码 / 隐藏文件。
serve_static() {
  local rel=${path#"$ADMIN_PATH"} f ct len
  case $method in GET|HEAD) ;; *) send 405 text/plain 'Method Not Allowed' 'Allow: GET, HEAD\r\n'; exit 0 ;; esac
  # 别的网站的页面不能把这里的文件当子资源加载 (<img> / <script> 探测装了哪些应用 · 取图标): 浏览器会带 Sec-Fetch-Site; 用户自己打开 / 点链接过来 (navigate) 照常
  if [ "$SFS" = cross-site ] && [ "$SFM" != navigate ]; then send 403 text/plain 'Forbidden'; exit 0; fi
  case $path in
    /|"$ADMIN_PATH") printf 'HTTP/1.1 302 Found\r\nLocation: %s/\r\nContent-Length: 0\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n' "$ADMIN_PATH"; exit 0 ;;
  esac
  case $rel in    # 页面路由 (和 ui/app.js 的 NAV 一致, 加上未登录时的 login / register 两个整页): /enana/admin/apps 等直接给 index.html, 由页面里的路由决定显示哪一页; 末尾带斜杠的跳到不带的 (页面里的相对地址要靠它)
    /overview|/apps|/sites|/rules|/dns|/servers|/conns|/traffic|/speed|/logs|/settings|/login|/register) rel=/index.html ;;
    /overview/|/apps/|/sites/|/rules/|/dns/|/servers/|/conns/|/traffic/|/speed/|/logs/|/settings/|/login/|/register/)
      printf 'HTTP/1.1 302 Found\r\nLocation: %s%s\r\nContent-Length: 0\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n' "$ADMIN_PATH" "${rel%/}"; exit 0 ;;
  esac
  [ "$rel" = / ] && rel=/index.html
  case $rel in *..*|*%*|*\\*|*//*|*/.*) send 404 text/plain 'Not Found'; exit 0 ;; esac
  case ${rel##*.} in
    html) ct='text/html; charset=utf-8' ;; js) ct='text/javascript; charset=utf-8' ;; css) ct='text/css; charset=utf-8' ;;
    json) ct='application/json; charset=utf-8' ;; svg) ct='image/svg+xml' ;; png) ct='image/png' ;; jpg|jpeg) ct='image/jpeg' ;;
    ico) ct='image/x-icon' ;; webp) ct='image/webp' ;; woff2) ct='font/woff2' ;; txt) ct='text/plain; charset=utf-8' ;;
    *) send 404 text/plain 'Not Found'; exit 0 ;;
  esac
  f="$H/ui$rel"
  if [ ! -f "$f" ] || [ -L "$f" ]; then send 404 text/plain 'Not Found'; exit 0; fi
  len=$(wc -c < "$f"); len=${len// /}
  printf 'HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %s\r\nCache-Control: no-cache\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n' "$ct" "$len"
  [ "$method" = HEAD ] || cat "$f"
  exit 0
}
case $path in /favicon.ico) path="$ADMIN_PATH/favicon.png" ;; esac      # 浏览器不管页面里写了什么, 总会顺手请求 /favicon.ico (Safari 尤其): 给它标签页图标, 而不是一个 403
case $path in /|"$ADMIN_PATH"|"$ADMIN_PATH"/*) serve_static ;; esac

# ---------- 以下是 JSON 接口: 到这里才加载其余模块 ----------
for _f in i18n jobs servers apps autosites sites fetch os enhanced auth device session cloud dns logs health update config ops speed stats prefs snapshot plan billing official sync vps diag; do . "$LIB/$_f.sh"; done
[ "$ENANA_PLATFORM" != windows ] || . "$LIB/enhanced-windows.sh"
i18n_init
OP_WHO=dashboard; export OP_WHO
BODY=$(mktemp "${TMPDIR:-/tmp}/enana-body.XXXXXX"); trap 'rm -f "$BODY" "$BODY".*' EXIT
case " $I18N_LANGS " in *" $LHDR "*) [ -n "$LHDR" ] && I18N_LANG=$LHDR ;; esac       # 本次请求的语言 (错误文字 / 任务进度都按它翻译)
: "${I18N_LANG:=${LANG_UI:-zh}}"; export I18N_LANG
if [ "$method" = OPTIONS ]; then
  send 204 text/plain '' "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: X-Enana, X-Enana-Token, X-Enana-Lang, X-Enana-Sudo, Content-Type\r\nAccess-Control-Max-Age: 600\r\n"; exit 0
fi
[ "$XT" = 1 ] || deny 403 E_FORBIDDEN "缺少 X-Enana 请求头"
[ "$CL" -le 4194304 ] || deny 413 E_INVALID "请求内容过大"
if [ "$CL" -gt 0 ]; then head -c "$CL" > "$BODY"; fi
FORM=0; case $CT in application/x-www-form-urlencoded*) FORM=1 ;; esac

# 令牌: 除公开接口外都要求登录
case "$method $path" in
  "GET /api/auth/status"|"POST /api/login"|"POST /api/register") ;;
  *) _s=$(auth_secret); { [ -n "$_s" ] && [ -n "$TOK" ] && [ "$TOK" = "$_s" ]; } || deny 401 E_AUTH "需要登录" ;;
esac

# 敏感操作 (step-up): 已经登录也要再输一次密码, 换到 X-Enana-Sudo 令牌才能调用。以后加功能只要往这张表里加一项 (格式 方法:路径)。
SUDO_ENDPOINTS=" POST:/api/servers/delete POST:/api/sub/delete GET:/api/servers/secret GET:/api/sub/url POST:/api/logs/clear POST:/api/devices/kick POST:/api/sync/clear GET:/api/export "
case "$SUDO_ENDPOINTS" in *" $method:$path "*) auth_sudo_ok "$SUD" || deny 403 E_SUDO_REQUIRED "此操作需要再次输入登录密码" ;; esac

urldecode() { case $1 in *\\*) printf ''; return ;; esac; local s=${1//+/ }; printf '%b' "${s//%/\\x}"; }
qp() { urldecode "$(printf '%s' "$query" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1)"; }          # 查询参数
fp() { # 表单字段: 先取请求体 (urlencoded), 取不到再取查询参数 (敏感字段只应该走请求体)
  local v=''
  if [ "$FORM" = 1 ] && [ -s "$BODY" ]; then v=$(urldecode "$(tr '&' '\n' < "$BODY" | sed -n "s/^$1=//p" | head -1)"); fi
  [ -n "$v" ] || v=$(qp "$1")
  printf '%s' "$v"
}
num() { case $1 in ''|*[!0-9.]*) printf '' ;; *) printf '%s' "$1" ;; esac; }   # 只放行数字
bool() { [ "$1" = 1 ] && printf true || printf false; }
valid_day() { case $1 in '') return 0 ;; [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) return 0 ;; *) return 1 ;; esac; }

# ---------- JSON 片段 ----------
servers_json() { # 用户自己的服务器, 后面接官方线路 (第 7 列 = 1: 带 "official":true, 地址 / 端口为空, 界面据此不允许编辑 / 删除 / 查看凭据)
  { srv_list; official_list; } | awk -F'\t' 'BEGIN{printf "["} { gsub(/["\\]/, "", $1); gsub(/["\\]/, "", $3);
    printf "%s{\"tag\":\"%s\",\"type\":\"%s\",\"server\":\"%s\",\"port\":%s,\"role\":\"%s\",\"sub\":\"%s\"%s}", (NR>1?",":""), $1, $2, $3, ($4==""?0:$4), $5, $6, ($7=="1"?",\"official\":true":"") } END{printf "]"}'
}

# ---------- 账号 / 代理总开关 ----------
ep_auth_status() { json "{\"ok\":true,$(auth_status_json)}"; }
auth_fail_reply() { # 把 auth_login / auth_register 的失败码翻译成响应 (调用方已设置 AUTH_CODE / AUTH_WAIT)
  case $AUTH_CODE in
    E_LOCKED)               fail "尝试次数过多, 请 $AUTH_WAIT 秒后再试" E_LOCKED "\"wait\":$AUTH_WAIT" ;;
    E_BAD_CREDENTIALS)      fail "账号或密码错误" E_BAD_CREDENTIALS "\"wait\":$(auth_wait_seconds)" ;;
    E_EMAIL_TAKEN)          fail "这个邮箱已经注册过了, 请直接登录" E_EMAIL_TAKEN ;;
    E_WEAK_PASSWORD)        fail "密码至少 8 位" E_WEAK_PASSWORD ;;
    E_ACCOUNT_UNREACHABLE)  fail "连不上 enana.cc, 暂时无法完成 (这个账号没有可用的离线登录缓存)。请检查网络后重试" E_ACCOUNT_UNREACHABLE ;;
    E_DEVICE_LIMIT)         fail "这个账号在当前平台上已有 $DEV_LIMIT 台设备在线, 请先下线其中一台" E_DEVICE_LIMIT "\"platform\":\"$(jesc "$DEV_PLATFORM")\",\"limit\":${DEV_LIMIT:-2},\"devices\":$DEV_LIST" ;;
    E_BUSY)                 fail "系统繁忙, 请重试" E_BUSY ;;
    *)                      fail "邮箱或密码格式不正确" E_INVALID ;;
  esac
}
ep_login() {
  local u p k; u=$(fp user); p=$(fp password); k=$(fp kick)
  case $k in ''|*[!A-Za-z0-9-]*) [ -z "$k" ] || fail "设备编号无效" ;; esac
  if auth_login "$u" "$p" "$k"; then
    oplog dashboard "登录" "$(kv user "$(auth_mask_email "$AUTH_EMAIL")" via "$AUTH_VIA")" ok
    [ "$AUTH_VIA" = online ] && { job_spawn content-sync "$RULE_STEPS" >/dev/null; job_spawn sync-login "$RULE_STEPS" >/dev/null; ( plan_refresh >/dev/null 2>&1 & ); }       # 登录后顺带拉取云端内容和套餐 (后台, 失败不影响登录)
    okj "\"token\":\"$(auth_secret)\",\"account\":\"$(jesc "$AUTH_EMAIL")\",\"via\":\"$AUTH_VIA\""
    return
  fi
  [ "$AUTH_CODE" = E_BAD_CREDENTIALS ] && oplog dashboard "登录失败" "$(kv user "$(auth_mask_email "$(auth_lower "$u")")" code "$AUTH_CODE")" error
  auth_fail_reply
}
ep_register() {
  local u p; u=$(fp user); p=$(fp password)
  if auth_register "$u" "$p"; then
    oplog dashboard "注册账号" "$(kv user "$(auth_mask_email "$AUTH_EMAIL")")" ok
    job_spawn content-sync "$RULE_STEPS" >/dev/null
    okj "\"registered\":true,\"token\":\"$(auth_secret)\",\"account\":\"$(jesc "$AUTH_EMAIL")\",\"via\":\"$AUTH_VIA\""
    return
  fi
  auth_fail_reply
}
ep_logout() { # 退出账号: 自动关闭代理 + 令牌立刻失效 + 释放云端设备名额; 核心在后台重启一次换上新令牌 (期间已是全部直连)
  oplog dashboard "退出账号" "$(kv user "$(auth_mask_email "$(auth_current_email)")")" ok
  auth_logout
  job_spawn auth-sync '同步令牌' >/dev/null
  okj
}
ep_sysproxy() { # 单独开启 / 关闭系统代理 (on=0|1) -> 后台任务 (macOS 可能弹出管理员密码窗口, 要等用户输入, 不能卡住这个请求); 进度用 GET /api/job 查询
  local on; on=$(fp on)
  case $on in 0|1) ;; *) fail "参数无效" ;; esac
  okj "\"job\":\"$(job_spawn sysproxy '修改系统代理|确认结果' "$([ "$on" = 1 ] && echo on || echo off)")\""
}
ep_proxy() { # 代理总开关 + 模式 (on=0|1, mode=auto|global; 至少给一个)
  local on mode was_on was_mode sp=''; on=$(fp on); mode=$(fp mode); was_on=${PROXY_ENABLED:-0}; was_mode=${PROXY_MODE:-auto}
  [ -n "$on" ] || [ -n "$mode" ] || fail "参数无效"
  case $on in ''|0|1) ;; *) fail "参数无效" ;; esac
  case $mode in ''|auto|global) ;; *) fail "代理模式无效" ;; esac
  if { [ "$on" = 1 ] || { [ -z "$on" ] && [ "${PROXY_ENABLED:-0}" = 1 ]; }; } && ! os_service_running; then
    os_service_start && wait_port "$PORT" 10 && enhanced_ready || fail "代理服务没有运行, 启动也失败了 (运行 enana doctor 查看原因)" E_NOT_RUNNING
  fi
  [ -n "$mode" ] && proxy_set_mode "$mode"
  [ -n "$on" ] && proxy_set_enabled "$on"
  # 打开总开关时让系统代理一并指向 enana (System Proxy 接管方式): 浏览器和多数 App 只有走系统代理才会进入 enana, 以前总开关打开了却「没有效果」, 必须去终端输入 enana on。
  #   已经指向 enana → 不用动 · 系统里正在用别的代理设置 (其它软件) → 不擅自覆盖, 交给用户在界面上确认 · 否则在后台任务里开启 (可能弹出 macOS 管理员密码窗口)
  if [ "$on" = 1 ] && [ "${NETWORK_MODE:-system}" != tun ]; then
    if os_sysproxy_ok; then sp='"sysproxy":{"state":"on"}'
    elif [ -n "$(os_sysproxy_foreign 2>/dev/null)" ]; then sp='"sysproxy":{"state":"foreign"}'
    else sp="\"sysproxy\":{\"state\":\"pending\",\"job\":\"$(job_spawn sysproxy '修改系统代理|确认结果' on)\"}"; fi
  fi
  oplog dashboard "$([ -n "$on" ] && { [ "$on" = 1 ] && echo 开启代理 || echo 关闭代理; } || echo 切换代理模式)" "$(kv enabled "${PROXY_ENABLED:-0}" mode "${PROXY_MODE:-auto}" was_enabled "$was_on" was_mode "$was_mode" sysproxy "$(printf '%s' "$sp" | sed -n 's/.*"state":"\([a-z]*\)".*/\1/p')")" ok
  okj "\"enabled\":$(bool "${PROXY_ENABLED:-0}"),\"mode\":\"${PROXY_MODE:-auto}\"${sp:+,$sp}"
}
ep_devices() { # 我的设备 (云端)
  auth_logged_in || fail "需要登录" E_AUTH
  local body; body=$(session_devices_json) || fail "连不上云端, 暂时无法读取设备列表" E_ACCOUNT_UNREACHABLE
  json "{\"ok\":true,$body}"
}
ep_devices_kick() {
  local uid; uid=$(fp uid)
  case $uid in ''|*[!A-Za-z0-9-]*) fail "设备编号无效" ;; esac
  session_kick "$uid" || fail "下线失败: 连不上云端, 或这台设备已不在线 / 不能下线自己" E_NETWORK
  oplog dashboard "下线设备" "$(kv device "$uid")" ok
  okj
}
ep_stats() {
  local range; range=$(qp range); [ -n "$range" ] || range=today
  case $range in today|3d|7d|30d|90d) ;; *) fail "统计范围无效" ;; esac
  json "{\"ok\":true,$(stats_json "$range" | sed 's/^{//')"
}
ep_stats_apps() { # 每个应用在这个范围内的流量 (应用页「今日流量」列)
  local range; range=$(qp range); [ -n "$range" ] || range=today
  case $range in today|3d|7d|30d|90d) ;; *) fail "统计范围无效" ;; esac
  json "{\"ok\":true,$(stats_apps_json "$range" | sed 's/^{//')"
}
ep_password() { # 在本机修改账号密码 (旧密码 + 新密码): 云端校验, 当前设备保持登录, 其它设备全部下线
  local old new; old=$(fp old); new=$(fp new)
  if auth_change_password "$old" "$new"; then oplog dashboard "修改密码" "$(kv user "$(auth_mask_email "$(auth_current_email)")")" ok; okj; return; fi
  case $AUTH_CODE in
    E_BAD_CREDENTIALS) oplog dashboard "修改密码失败" "$(kv code E_BAD_CREDENTIALS reason old_password_wrong)" error; fail "当前密码不正确" E_BAD_CREDENTIALS "\"wait\":$(auth_wait_seconds)" ;;
    E_WEAK_PASSWORD)   fail "新密码至少 8 位, 并且不能和旧密码相同" E_WEAK_PASSWORD ;;
    E_AUTH)            deny 401 E_AUTH "登录已失效, 请重新登录" ;;
    E_ACCOUNT_UNREACHABLE) fail "连不上 enana.cc, 修改密码必须在线 (离线登录时不能修改)。请检查网络后重试" E_ACCOUNT_UNREACHABLE ;;
    *) auth_fail_reply ;;
  esac
}
ep_auth_verify() { # 敏感操作前再次输入密码 -> 5 分钟有效的 sudo 令牌
  if auth_step_up "$(fp password)"; then oplog dashboard "二次验证" "$(kv endpoint "$path")" ok; okj "\"sudo\":\"$SUDO_TOKEN\",\"ttl\":$SUDO_TTL"; return; fi
  case $AUTH_CODE in
    E_LOCKED)          fail "尝试次数过多, 请 $AUTH_WAIT 秒后再试" E_LOCKED "\"wait\":$AUTH_WAIT" ;;
    E_BAD_CREDENTIALS) oplog dashboard "二次验证失败" "$(kv code E_BAD_CREDENTIALS)" error; fail "密码不正确" E_BAD_CREDENTIALS "\"wait\":$(auth_wait_seconds)" ;;
    E_AUTH)            deny 401 E_AUTH "需要登录" ;;
    *)                 fail "请输入登录密码" E_INVALID ;;
  esac
}
ep_servers_secret() { # 查看某个节点的密码 / UUID / 密钥 (需 sudo)
  local tag fields rc; tag=$(qp tag)
  [ -n "$tag" ] && ! srv_has_tag "$tag" && official_has_tag "$tag" && fail "官方线路的凭据不能查看" E_FORBIDDEN
  [ -n "$tag" ] && srv_has_tag "$tag" || fail "找不到这个服务器" E_NOT_FOUND
  fields=$(srv_secret_fields "$tag"); rc=$?
  case $rc in 0) ;; 3) fail "官方线路的凭据不能查看" E_FORBIDDEN ;; *) fail "找不到这个服务器" E_NOT_FOUND ;; esac
  oplog dashboard "查看服务器凭据" "$(kv tag "$tag")" ok
  json "{\"ok\":true,\"tag\":\"$(jesc "$tag")\",\"fields\":${fields:-[]}}"
}
ep_sub_url() { # 查看订阅链接 (需 sudo)
  local name url; name=$(qp name)
  url=$(awk -F'|' -v n="$name" '$1 == n { print $2; exit }' "$H/subs.tsv" 2>/dev/null)
  [ -n "$url" ] || fail "找不到这个订阅" E_NOT_FOUND
  oplog dashboard "查看订阅链接" "$(kv sub "$name")" ok
  json "{\"ok\":true,\"name\":\"$(jesc "$name")\",\"url\":\"$(jesc "$url")\"}"
}
ep_export() { # 导出配置备份 (含凭据, 需 sudo)
  local body; body=$(snap_build all) || fail "配置太大, 无法导出" E_INVALID
  oplog dashboard "导出配置备份" "$(kv scope all)" ok
  send 200 application/json "$body" "Content-Disposition: attachment; filename=\"enana-backup-$(date +%Y%m%d).json\"\r\n"
}
ep_sync_settings() { # enabled=0|1 auto=0|1 [password=…: 第一次开启时本机还没有同步密钥 → 用登录密码派生]
  local en au pw; en=$(fp enabled); au=$(fp auto); pw=$(fp password)
  case $en in ''|0|1) ;; *) fail "参数无效" ;; esac; case $au in ''|0|1) ;; *) fail "参数无效" ;; esac
  [ -n "$en$au" ] || fail "参数无效"
  if [ "$en" = 1 ] && ! sync_have_key; then
    [ -n "$pw" ] || fail "开启同步需要再输入一次登录密码 (加密密钥由它派生, 只保存在这台电脑上)" E_SYNC_KEY
    if ! auth_check_password "$pw"; then
      case $AUTH_CODE in E_LOCKED) fail "尝试次数过多, 请 $AUTH_WAIT 秒后再试" E_LOCKED "\"wait\":$AUTH_WAIT" ;; *) fail "密码不正确" E_BAD_CREDENTIALS "\"wait\":$(auth_wait_seconds)" ;; esac
    fi
    sync_key_derive "$(auth_acc_get id)" "$pw" || fail "无法生成同步密钥" E_INVALID
  fi
  [ "$en" = 1 ] && ! sync_enabled && sync_list_all                                    # 在设置里明确打开: 现有的服务器和订阅都开始同步 (和以前「全部同步」一致)
  [ -z "$en" ] || sync_set ENABLED "$en"
  [ -z "$au" ] || sync_set AUTO "$au"
  [ "$en" != 0 ] || sync_set AUTO 0                                                  # 关闭同步时自动同步也一起关
  oplog dashboard "云端同步设置" "$(kv enabled "$en" auto "$au")" ok
  okj
}
sync_open_reply() { # sync_open_remote 的返回码 -> 失败响应 (成功时什么也不做)
  case $1 in
    0) ;;
    1) fail "连不上 enana.cc, 暂时无法同步" E_ACCOUNT_UNREACHABLE ;;
    2) deny 401 E_AUTH "登录已失效, 请重新登录" ;;
    3) fail "这份云端配置不是用当前密码加密的 (可能在别处改过密码): 请输入旧密码后重试" E_SYNC_KEY ;;
    4) fail "云端还没有数据" E_NOT_FOUND ;;
    6) fail "没有同步密钥: 请退出账号后重新登录一次 (密钥由登录密码派生)" E_SYNC_KEY ;;
    *) fail "云端的配置无法读取" E_INVALID ;;
  esac
}
ep_sync_push() {
  local force base; force=$(fp force); case $force in ''|0|1) ;; *) fail "参数无效" ;; esac
  sync_enabled || fail "云端同步没有开启" E_INVALID
  sync_have_key || fail "没有同步密钥: 请退出账号后重新登录一次 (密钥由登录密码派生)" E_SYNC_KEY
  if [ "$force" != 1 ]; then      # 先看一眼云端: 有更新的版本就直接告诉前端 (让用户选以哪一份为准)
    sync_remote_forget; sync_remote_meta
    case $? in 0) ;; 2) deny 401 E_AUTH "登录已失效, 请重新登录" ;; *) fail "连不上 enana.cc, 暂时无法同步" E_ACCOUNT_UNREACHABLE ;; esac
    base=$(sync_get BASE_VERSION)
    if [ "$R_EXISTS" = 1 ] && [ "$R_VERSION" != "${base:-0}" ]; then
      fail "云端有更新的版本 (来自「$R_DEVICE」): 请选择以云端为准还是以本机为准" E_SYNC_CONFLICT "\"remote\":{\"version\":$R_VERSION,\"updated\":$R_UPDATED,\"device\":\"$(jesc "$R_DEVICE")\"}"
    fi
  fi
  okj "\"job\":\"$(job_spawn sync-push '生成快照|加密|上传' "${force:-0}")\""
}
ep_sync_pull() { # mode=replace|merge [old_password]
  local mode old; mode=$(fp mode); old=$(fp old_password); [ -n "$mode" ] || mode=replace
  case $mode in replace|merge) ;; *) fail "参数无效" ;; esac
  sync_enabled || fail "云端同步没有开启" E_INVALID
  sync_open_remote "$old"; sync_open_reply $?                         # 下载 + 解密在这里做完, 失败立刻告诉前端 (密钥不对 → E_SYNC_KEY)
  okj "\"job\":\"$(job_spawn sync-pull "$APPLY_STEPS" "$mode" "${SYNC_USED_OLD:-0}" "$SYNC_IN_VERSION")\""
}
ep_sync_preview() { # 下载并解密云端快照, 只返回摘要 (新电脑第一次登录时问「是否同步到这台电脑」)
  local old info; old=$(fp old_password)
  sync_open_remote "$old"; sync_open_reply $?
  info=$(/usr/bin/perl "$LIB/snapshot.pl" info "$H/sync-incoming.json" 2>/dev/null); rm -f "$H/sync-incoming.json"
  okj "\"summary\":${info:-{\}},\"remote\":{\"version\":$SYNC_IN_VERSION}"
}
ep_sync_clear() { # 删除云端的同步数据 (需 sudo)
  local code
  [ -n "$(session_id)" ] || fail "连不上 enana.cc" E_ACCOUNT_UNREACHABLE
  code=$(session_call /dev/null DELETE /api/enana/v1/sync/snapshot)
  case $code in 200) ;; 401) deny 401 E_AUTH "登录已失效, 请重新登录" ;; *) fail "连不上 enana.cc, 暂时无法清除" E_ACCOUNT_UNREACHABLE ;; esac
  sync_set BASE_VERSION 0; sync_set SYNCED_HASH ''; sync_set CONFLICT 0; sync_remote_forget
  oplog dashboard "云端同步: 清除云端数据" "$(kv scope cloud)" ok
  okj
}
# ---------- 添加自己的服务器 (SSH 一键部署; 凭据只经由 600 权限的临时文件交给后台任务, 见 lib/vps.sh) ----------
vps_form() { # 读表单 -> F_HOST F_PORT F_USER F_MODE F_PASSWORD F_KEY F_PASSPHRASE F_SUDOPW F_HOSTKEY
  F_HOST=$(fp host); F_PORT=$(fp port); [ -n "$F_PORT" ] || F_PORT=22; F_USER=$(fp user); [ -n "$F_USER" ] || F_USER=root; F_MODE=$(fp mode); [ -n "$F_MODE" ] || F_MODE=password
  F_PASSWORD=$(fp password); F_KEY=$(fp key); F_PASSPHRASE=$(fp passphrase); F_SUDOPW=$(fp sudo_password); F_HOSTKEY=$(fp hostkey)
}
vps_launch() { # <任务名> <步骤> <name> <role> <install_deps> <id> <confirm_hostkey> [save]   校验 -> 写凭据文件 -> 启动任务
  local job=$1 steps=$2 id
  vps_cred_check "$F_HOST" "$F_PORT" "$F_USER" "$F_MODE" "$F_PASSWORD" "$F_KEY" "$F_PASSPHRASE" "$F_SUDOPW" "$F_HOSTKEY" || fail "$VPS_ERR" E_INVALID
  command -v "$(vps_ssh_bin)" >/dev/null 2>&1 || fail "这台电脑上找不到 ssh 命令" E_SSH_NO_CLIENT
  vps_playbook_ok || fail "部署脚本由 enana 云端下发: 请先登录, 并等「云端内容」同步完成后再试" E_VPS_NO_PLAYBOOK
  id=$(job_new "$job" "$steps")
  vps_cred_write "$H/jobs/$id.cred" "$F_HOST" "$F_PORT" "$F_USER" "$F_MODE" "$F_PASSWORD" "$F_KEY" "$F_PASSPHRASE" "$F_SUDOPW" "$F_HOSTKEY" "$3" "$4" "$5" "$6" "$7" "${8:-}"
  job_launch "$job" "$id" "$H/jobs/$id.cred"
  okj "\"job\":\"$id\""
}
ep_vps_probe() {
  local cf; vps_form; cf=$(fp confirm_hostkey); case $cf in ''|0|1) ;; *) fail "参数无效" ;; esac
  vps_launch vps-probe '连接服务器|检测系统与环境|整理结果' '' pin 0 '' "${cf:-0}"
}
ep_vps_cancel() { # Only the read-only detection job is cancellable.
  local id state pid; id=$(fp id)
  case $id in *[!A-Za-z0-9_-]*|'') fail "任务编号无效" E_INVALID ;; vps-probe-*) ;; *) fail "只能取消服务器检测任务" E_INVALID ;; esac
  [ -f "$H/jobs/$id.json" ] || fail "找不到该任务" E_NOT_FOUND
  state=$(sed -n 's/.*"name":"vps-probe","state":"\([a-z]*\)".*/\1/p' "$H/jobs/$id.json")
  if [ "$state" = running ]; then
    ( umask 077; : > "$H/jobs/$id.cancel" )
    pid=$(cat "$H/jobs/$id.started" 2>/dev/null)
    case $pid in ''|*[!0-9]*) pid='' ;; esac
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$H/jobs/$id.cred"
      job_write "$id" vps-probe error 0 100 "已取消服务器检测" '{"code":"E_CANCELLED"}'
    fi
    oplog dashboard "取消服务器检测" "$(kv id "$id")" ok
  fi
  okj '"requested":true'
}
ep_vps_provision() {
  local name role deps save; vps_form; name=$(fp name); role=$(fp role); deps=$(fp install_deps); save=$(fp save)
  case $save in ''|0|1) ;; *) fail "参数无效" ;; esac
  [ -n "$F_HOSTKEY" ] || fail "需要先确认并固定服务器的主机指纹 (先调用探测)" E_SSH_HOSTKEY
  case $role in ''|pin|auto) ;; *) fail "角色无效" ;; esac; case $deps in ''|0|1) ;; *) fail "参数无效" ;; esac
  [ -z "$name" ] || vps_name_ok "$name" || fail "服务器名称只能用字母 / 数字 / . _ - (最多 40 个字符)" E_INVALID
  vps_launch vps-provision '连接服务器|检测系统与环境|安装依赖|安装服务端|生成配置与密钥|开放端口并启动|验证连通|识别出口 IP|保存到本机' "$name" "${role:-pin}" "${deps:-0}" '' 0 "$save"
}
ep_vps_redetect() {
  local id; vps_form; id=$(fp id); case $id in v-[0-9a-f]*) ;; *) fail "服务器编号无效" ;; esac
  [ -n "$(vps_rec_field "$id" hostkey)" ] || fail "找不到这台服务器的记录" E_NOT_FOUND
  [ -n "$F_HOST" ] || F_HOST=$(vps_rec_field "$id" host)
  [ -n "$F_HOSTKEY" ] || F_HOSTKEY=$(vps_rec_field "$id" hostkey)
  vps_launch vps-redetect '连接服务器|检测系统与环境|生成配置与密钥|开放端口并启动|验证连通|保存到本机' '' pin 0 "$id" 0
}
ep_vps_forget() {
  local id; id=$(fp id); case $id in v-[0-9a-f]*) ;; *) fail "服务器编号无效" ;; esac
  vps_forget "$id" || fail "找不到这台服务器的记录" E_NOT_FOUND
  oplog dashboard "忘记自己的服务器的记录" "$(kv id "$id")" ok; okj
}
ep_prefs_set() { # 正文是 JSON 对象文本
  prefs_set "$BODY" || fail "$PREFS_ERR" E_INVALID
  okj "\"version\":$PREFS_VERSION"
}
ep_plan() {
  local c age; c=$(plan_checked); age=$(( $(now) - c ))
  if [ -n "$(session_id)" ]; then
    if [ "$(qp refresh)" = 1 ] && [ "$age" -ge 3 ]; then plan_refresh || true      # ?refresh=1 (付款 / 余额购买成功后、手动刷新): 同步向云端取最新套餐, 否则刚付款的用户最长 1 小时还看到免费版 (3 秒内刚刷新过就不重复)
    elif [ "$age" -gt "$PLAN_TTL" ]; then
      if [ "$c" = 0 ]; then plan_refresh || true; else ( plan_refresh >/dev/null 2>&1 & ); fi      # 从没取过: 等一下; 过期了: 先用旧的, 后台刷新
    fi
  fi
  json "{\"ok\":true,$(plan_json)}"
}

ep_billing() {
  local op=$1 route=$2 verb=$3 body='' result id tmp
  if [ "$op" = order ]; then
    id=$(qp id); printf '%s' "$id" | LC_ALL=C grep -Eq '^[a-z0-9]{15}$' || fail "订单编号无效" E_INVALID
    route="$route?id=$id"
  elif [ "$verb" = POST ]; then
    # Resend has no arbitrary recipient: the cloud sends to this account only.
    if [ "$op" = email-send ] && [ ! -s "$BODY" ]; then body='{}'
    else body=$(billing_body "$op" "$BODY") || fail "付款参数无效" E_INVALID; fi
  fi
  # 不能写成 result=$(billing_request …): 命令替换在子 shell 里运行, 设置的 BILLING_CODE 会丢; 所以先写到临时文件, 再在当前 shell 里读出。
  tmp=$(mktemp)
  if billing_request "$verb" "$route" "$body" > "$tmp"; then result=$(cat "$tmp"); rm -f "$tmp"; json "$result"; return 0; fi
  rm -f "$tmp"
  case ${BILLING_CODE:-} in
    E_AUTH)          fail "云端登录已失效、已结束或这台电脑是离线登录，请联网并重新登录后再试" E_AUTH ;;                       # 不用 deny 401: 那会让本机仪表盘也锁住; 这里只是云端会话的问题
    E_SERVER_ERROR)  fail "enana.cc 服务器返回了错误，这次操作可能已生效也可能没有，请先刷新并查看订单和余额" E_SERVER_ERROR ;;
    E_RATE_LIMITED)  fail "请求过于频繁，请稍后再试" E_RATE_LIMITED ;;
    *)               fail "账号服务暂时无法连接，请稍后重试" E_ACCOUNT_UNREACHABLE ;;
  esac
}

# ---------- 状态 ----------
ep_state() {
  local core svc sp sc scmd missing='' t rs=1 osver arch
  core=$(core_version); os_service_info; svc=$SVC_RUNNING; os_sysproxy_cached && sp=1 || sp=0
  sc=$(shortcut_path 2>/dev/null || true)
  if [ -n "$sc" ]; then scmd=enana; else scmd="$H/enana"; fi              # 在终端里能直接运行、打开控制台的完整命令: 装了快捷命令就是 enana, 没装就是脚本的完整路径
  for t in $(rules_missing); do missing="$missing${missing:+,}\"$t\""; rs=0; done
  [ -s "$H/.osver" ] || os_version > "$H/.osver" 2>/dev/null; IFS= read -r osver < "$H/.osver"; arch=$(os_arch)
  json "{\"ok\":true,\"version\":\"$VERSION\",\"prefs_version\":$(prefs_version),\"core\":\"${core:-}\",\"lang\":\"${LANG_UI:-zh}\",\"platform\":{\"os\":\"${ENANA_PLATFORM:-darwin}\",\"osver\":\"${osver:-}\",\"arch\":\"$arch\"},\"ports\":{\"proxy\":$PORT,\"ui\":$UI_PORT,\"api\":$API_PORT,\"speed\":$SPEED_PORT},\"env\":{\"core\":$([ -n "$core" ] && echo true || echo false),\"rules\":$(bool $rs),\"service\":$(bool $svc),\"sysproxy\":$(bool $sp),\"shortcut\":$([ -n "$sc" ] && printf '"%s"' "$sc" || printf null),\"shortcut_cmd\":\"$(jesc "$scmd")\",\"rules_updated\":$(rules_updated_at),\"rules_missing\":[$missing]},\"update\":$(update_available),\"proxy\":{\"enabled\":$(bool "${PROXY_ENABLED:-0}"),\"mode\":\"${PROXY_MODE:-auto}\",\"network_mode\":\"${NETWORK_MODE:-system}\",\"tun_ready\":$(enhanced_ready && enhanced_configured && echo true || echo false)},\"account\":{\"email\":\"$(jesc "$(auth_current_email)")\"},\"servers\":$(servers_json),\"subs\":$(subs_json),\"overrides\":$(overrides_json),\"first_run\":$([ "$(srv_count)" = 0 ] && echo true || echo false)}"
}
apps_resp() {
  [ -f "$H/ui/appicons/index.tsv" ] || ( apps_icons >/dev/null 2>&1 & )          # 第一次: 后台提取应用图标
  json "{\"ok\":true,\"apps\":$(apps_json),\"new_count\":$(apps_new_count),\"scanned_at\":$(now)}"
}
ep_sites_domains_get() {
  local id body; id=$(qp id); case $id in ''|*[!a-z0-9-]*) fail "条目编号无效" ;; esac
  body=$(sites_domains_json "$id") || fail "找不到这个网站条目" E_NOT_FOUND
  json "{\"ok\":true,$body}"
}
ep_sites_domains_post() {
  local id act d new T err; id=$(fp id); act=$(fp action); d=$(fp domain); new=$(fp new)
  case $id in ''|*[!a-z0-9-]*) fail "条目编号无效" ;; esac
  case $act in add|remove|update|restore) ;; *) fail "操作无效" ;; esac
  T=$(mktemp); cp "$H/site-domains.tsv" "$T" 2>/dev/null || true       # 先在副本上「干跑」, 立刻返回具体原因; 真正的写入在后台任务里 (持锁, 失败自动回滚)
  err=$( SITE_EDITS=$T; sites_edit "$id" "$act" "$d" "$new" >/dev/null 2>&1 || printf '%s' "${SITES_ERR:-操作失败}" ); rm -f "$T"
  [ -z "$err" ] || fail "$err" E_INVALID
  okj "\"job\":\"$(job_spawn site-domain "$APPLY_STEPS" "$id" "$act" "$d" "$new")\""
}
ep_sites_domains_reset() {
  local id; id=$(fp id); case $id in ''|*[!a-z0-9-]*) fail "条目编号无效" ;; esac
  [ -n "$(site_entry "$id")" ] || fail "找不到这个网站条目" E_NOT_FOUND
  okj "\"job\":\"$(job_spawn site-domain-reset "$APPLY_STEPS" "$id")\""
}
ep_apps_inspect() { local in; in=$(fp input); json "{\"ok\":true,\"candidates\":[$(apps_inspect "$in")]}"; }
ep_apps_custom() {
  local p st j; p=$(fp path); st=$(fp state)
  case $st in follow|direct|pin|auto) ;; *) fail "状态无效" ;; esac
  j=$(apps_inspect_path "$p")
  case $j in *'"valid":true'*) ;; *) fail "$(printf '%s' "$j" | sed -n 's/.*"reason":"\([^"]*\)".*/\1/p')" E_INVALID ;; esac
  case $j in *'"exists":true'*) fail "这个软件已经在列表里了" E_INVALID ;; esac
  okj "\"job\":\"$(job_spawn app-custom "$APPLY_STEPS" "$p" "$st")\""
}
ep_apps_custom_delete() {
  local n; n=$(fp name); ovr_valid app "$n" || fail "名称格式不正确"
  awk -F'|' -v n="$n" '$1==n {f=1} END{exit f?0:1}' "$H/custom-apps.tsv" 2>/dev/null || fail "找不到这个自定义软件" E_NOT_FOUND
  okj "\"job\":\"$(job_spawn app-custom-delete "$APPLY_STEPS" "$n")\""
}

ep_override() {
  local kind value state target old oldt src
  kind=$(qp kind); value=$(qp value); state=$(qp state); target=$(qp target)
  case $state in follow|direct|pin|auto) ;; *) fail "状态无效" ;; esac
  ovr_valid "$kind" "$value" || fail "名称格式不正确"
  [ "$state" = pin ] || target=''
  ovr_target_valid "$target" || fail "指定的固定出口不存在 (固定出口至少要有 2 个才能单独指定)"
  old=$(ovr_get "$kind" "$value"); oldt=$(ovr_target "$kind" "$value"); [ -n "$old" ] || old=follow
  src=''; [ "$kind" = site ] && autosite_registry_has "$value" && src=auto
  if [ "${NETWORK_MODE:-system}" = tun ]; then
    local j; j=$(job_spawn override "$APPLY_STEPS" "$kind" "$value" "$state" "$target"); okj "\"job\":\"$j\""
    return
  fi
  lock_take || fail "系统繁忙, 请重试" E_BUSY
  if [ "$kind" = site ] && [ "$state" = follow ]; then ovr_delete site "$value"; autosite_forget "$value" dismiss; else ovr_set "$kind" "$value" "$state" ack "$target"; fi
  ovr_sync; lock_drop
  oplog dashboard "修改应用/网站策略" "$(kv kind "$kind" name "$value" from "$old" to "$state" target_from "$oldt" target_to "$target" src "$src")" ok
  okj
}

ep_apps_adopt() { # 采用推荐设置: 不带 names = 所有「新应用」; 带 names (换行分隔) = 只处理这几个 (用户已经看过这一页, 新应用的标记已被确认)
  local names n F=''; names=$(fp names)
  if [ "${NETWORK_MODE:-system}" = tun ]; then
    local j; j=$(job_spawn apps-adopt "$APPLY_STEPS" "$names"); okj "\"job\":\"$j\""; return
  fi
  if [ -n "$names" ]; then F=$(mktemp); printf '%s\n' "$names" > "$F"; fi
  lock_take && { apps_adopt "$F"; lock_drop; }
  [ -z "$F" ] || rm -f "$F"
  oplog dashboard "采用推荐设置" "$(kv scope "${names:+selected}" count "$(printf '%s' "$names" | awk 'NF' | wc -l | tr -d ' ')")" ok
  okj
}

ep_apps_scan() {
  if [ "${NETWORK_MODE:-system}" = tun ]; then
    local j; j=$(job_spawn apps-scan "$APPLY_STEPS"); okj "\"job\":\"$j\""; return
  fi
  lock_take && { apps_scan >/dev/null; lock_drop; }
  ( apps_icons >/dev/null 2>&1 & )
  apps_resp
}

ep_policy() { # 切换一个策略开关 (网站 / 默认出口 / 节点选择): 由辅助服务代为切换, 这样每一次切换都有操作记录 (原来 → 现在)
  local tag name res from sitename=''
  tag=$(fp tag); name=$(fp name)
  case $tag in svc-[a-z0-9-]*|svc-rs-[a-z0-9-]*|Final|Global|PIN) ;; *) fail "策略名称不合法" ;; esac
  [ -n "$name" ] && [ ${#name} -le 120 ] || fail "参数无效"
  res=$(clash GET "/proxies/$tag" | perl -MJSON::PP -e 'local $/; my $j = eval { JSON::PP->new->decode(<STDIN>) } or exit 3; my $n = shift; my %a = map { $_ => 1 } @{ $j->{all} || [] }; print +($a{$n} ? "ok" : "no"), "\t", ($j->{now} // "")' "$name") || fail "代理核心没有运行, 无法切换" E_NOT_RUNNING
  [ "${res%%$'\t'*}" = ok ] || fail "这个选项不存在 (可能节点已经被删除或改名)" E_NOT_FOUND
  from=${res#*$'\t'}
  [ "$from" = "$name" ] || { [ -z "$(clash PUT "/proxies/$tag" "{\"name\":\"$(jesc "$name")\"}")" ] || fail "切换失败, 请稍后重试" E_NOT_RUNNING; }
  case $tag in svc-rs-*) ;; svc-*) sitename=$(awk -F'|' -v id="${tag#svc-}" '$1==id {print $2; exit}' "$(content_file services.conf)" 2>/dev/null) ;; esac
  oplog dashboard "切换策略" "$(kv kind selector tag "$tag" site "$sitename" from "$from" to "$name")" ok
  okj "\"from\":\"$(jesc "$from")\",\"to\":\"$(jesc "$name")\""
}

ep_audit() { # 仪表盘直接对代理核心做的、不经过辅助服务的操作 (目前只有「断开连接」), 事后来这里补一条操作记录
  local ev scope n host; ev=$(fp ev); scope=$(fp scope); n=$(num "$(fp n)"); host=$(fp host)
  case $ev in
    kill)
      case $scope in all|one|host) ;; *) scope=all ;; esac
      printf '%s' "$host" | grep -Eq '^[A-Za-z0-9._:-]{0,120}$' || host=''
      oplog dashboard "断开连接" "$(kv scope "$scope" count "${n:-0}" host "$host")" ok ;;
    *) fail "参数无效" ;;
  esac
  okj
}

ep_sites_auto_clear() { # 撤销所有「自动识别」添加的网站
  if [ "${NETWORK_MODE:-system}" = tun ]; then
    local j; j=$(job_spawn autosites-clear "$APPLY_STEPS"); okj "\"job\":\"$j\""; return
  fi
  local n; n=$(autosite_remove_all)
  oplog dashboard "自动识别: 全部撤销" "$(kv count "${n:-0}")" ok
  okj "\"removed\":${n:-0}"
}

ep_servers_import() { # 先对副本「干跑」, 立即返回数量与逐行错误; 真正的写入在后台任务里 (持锁, 失败自动回滚)
  local sub mode res added replaced removed errs='' id e plan="$BODY.plan" save
  sub=$(qp sub); mode=$(qp mode); [ "$mode" = replace ] || mode=merge
  save=$(qp save); case $save in ''|0|1) ;; *) fail "参数无效" ;; esac            # 1 = 保存到云端 (进入云端同步清单), 0 = 只留在本机, 空 = 不改动 (例如订阅自动刷新)
  [ -z "$sub" ] || sub_valid_name "$sub" || fail "订阅名称不合法"
  [ -s "$BODY" ] || fail "没有收到服务器数据"
  if [ -f "$H/servers.jsonl" ]; then cp "$H/servers.jsonl" "$plan"; else : > "$plan"; fi
  res=$(SRV_FILE="$plan" srv_import "$sub" "$mode" < "$BODY" 2> "$BODY.err")
  set -- $res; added=${1:-0}; replaced=${2:-0}; removed=${3:-0}
  while IFS= read -r e; do [ -n "$e" ] && errs="$errs${errs:+,}\"$(printf '%s' "$(_t "$e")" | tr -d '"\\')\""; done < "$BODY.err"
  [ $((added + replaced)) -gt 0 ] || { json "{\"ok\":false,\"code\":\"E_INVALID\",\"error\":\"$(jesc "$(_t "没有可导入的服务器")")\",\"errors\":[$errs]}"; return; }
  id=$(job_new servers-import "$APPLY_STEPS"); cp "$BODY" "$H/jobs/$id.body"
  job_launch servers-import "$id" "$sub" "$mode" "$(num "$(qp interval)")" "$(num "$(qp used)")" "$(num "$(qp total)")" "$(num "$(qp expire)")" "$save"
  okj "\"added\":$added,\"replaced\":$replaced,\"removed\":$removed,\"errors\":[$errs],\"job\":\"$id\""
}

ep_servers_change() { # delete | role  (校验后交给后台任务)
  local tag role; tag=$(qp tag); role=$(qp role)
  [ -n "$tag" ] && ! srv_has_tag "$tag" && official_has_tag "$tag" && fail "官方线路节点由会员权益提供，不能删除或修改角色" E_FORBIDDEN
  [ -n "$tag" ] && srv_has_tag "$tag" || fail "找不到这台服务器" E_NOT_FOUND
  if [ "$1" = delete ]; then okj "\"job\":\"$(job_spawn servers-delete "$APPLY_STEPS" "$tag")\""
  else case $role in pin|auto|off|dl) okj "\"job\":\"$(job_spawn servers-role "$APPLY_STEPS" "$tag" "$role")\"" ;; *) fail "角色无效" ;; esac; fi
}

ep_cert() {
  local name f; name=$(qp name)
  printf '%s' "$name" | grep -Eq '^[A-Za-z0-9._-]{1,40}$' || fail "证书名称不合法"
  [ -s "$BODY" ] && [ "$(wc -c < "$BODY")" -le 16384 ] || fail "证书内容为空或过大"
  grep -q -- '-----BEGIN CERTIFICATE-----' "$BODY" && openssl x509 -in "$BODY" -noout 2>/dev/null || fail "不是有效的 PEM 证书"
  mkdir -p "$H/certs"; f="$H/certs/$name.crt"; cp "$BODY" "$f"; chmod 600 "$f"
  okj "\"ref\":\"@CERTS@/$name.crt\""
}

ep_sub_fetch() {
  local url name ua out hdr
  name=$(qp name); ua=$(qp ua)
  if [ -n "$name" ]; then url=$(sub_get_url "$name"); else url=$(tr -d '\r\n ' < "$BODY"); fi
  [ -n "$url" ] || fail "没有订阅链接"
  sub_url_ok "$url" || fail "订阅链接不合法 (只支持公网 http/https)"
  out="$BODY.sub"; hdr="$BODY.hdr"
  if ! sub_fetch "$url" "$ua" "$out" "$hdr"; then fail "订阅下载失败 (已尝试直连与已配置的备用线路)" E_NETWORK; fi
  local extra='' v
  v=$(grep -i '^subscription-userinfo:' "$hdr" | head -1 | tr -d '\r' | sed 's/^[^:]*: *//' | tr -cd 'A-Za-z0-9=;_ .-')
  [ -n "$v" ] && extra="${extra}X-Subscription-Userinfo: $v\r\n"
  v=$(grep -i '^profile-update-interval:' "$hdr" | head -1 | tr -d '\r' | sed 's/^[^:]*: *//' | tr -cd '0-9.')
  [ -n "$v" ] && extra="${extra}X-Profile-Update-Interval: $v\r\n"
  send_file 200 text/plain "$out" "$extra"
}

ep_sub_save() { # name + body=url
  local name url; name=$(qp name); url=$(tr -d '\r\n ' < "$BODY")
  local save; save=$(qp save); case $save in ''|0|1) ;; *) fail "参数无效" ;; esac
  sub_valid_name "$name" || fail "订阅名称不合法"
  sub_url_ok "$url" || fail "订阅链接不合法"
  op_lock || fail "系统繁忙, 请重试" E_BUSY; sub_save "$name" "$url"; [ -z "$save" ] || sync_list_set sub "$name" "$save"; op_unlock
  [ "$save" = 1 ] && sync_after_save || true
  oplog dashboard "保存订阅" "$(kv sub "$name")" ok
  okj
}
ep_sub_delete() {
  local name; name=$(qp name)
  sub_valid_name "$name" || fail "订阅名称不合法"
  okj "\"job\":\"$(job_spawn sub-delete "$APPLY_STEPS" "$name")\""
}

ep_log() { # 兼容旧接口: 核心实时日志的最后 n 行 (纯文本)
  local n; n=$(qp n); case $n in ''|*[!0-9]*) n=200 ;; esac; [ "$n" -gt 2000 ] && n=2000
  tail -n "$n" "$H/sing-box.log" > "$BODY.log" 2>/dev/null || : > "$BODY.log"
  send_file 200 text/plain "$BODY.log"
}

# ---------- 设置 ----------
ep_settings_get() {
  json "{\"ok\":true,\"lang\":\"${LANG_UI:-zh}\",$(settings_json),\"ports\":{\"proxy\":$PORT,\"ui\":$UI_PORT,\"api\":$API_PORT,\"speed\":$SPEED_PORT},\"proxy\":{\"enabled\":$(bool "${PROXY_ENABLED:-0}"),\"mode\":\"${PROXY_MODE:-auto}\",\"network_mode\":\"${NETWORK_MODE:-system}\",\"tun_ready\":$(enhanced_ready && enhanced_configured && echo true || echo false)},\"account\":{\"email\":\"$(jesc "$(auth_current_email)")\"}}"
}
ep_settings_set() {
  local lang hours days alog lcore lops asites dup job='' changed=0 oldh restart=''
  lang=$(fp lang); hours=$(fp log_hours); alog=$(fp access_log); lcore=$(fp log_core); lops=$(fp log_ops); asites=$(fp auto_sites); dup=$(fp diag_upload)
  if [ -z "$hours" ]; then days=$(fp log_days); case $days in ''|*[!0-9]*) ;; *) hours=$((days * 24)) ;; esac; fi          # 旧版仪表盘按天提交
  if [ -n "$lang" ]; then case " $I18N_LANGS " in *" $lang "*) ;; *) fail "不支持的语言" ;; esac; fi
  if [ -n "$hours" ]; then case $hours in *[!0-9]*) fail "日志保留时长必须是 12 小时到 30 天" ;; esac; [ "$hours" -ge "$LOG_HOURS_MIN" ] && [ "$hours" -le "$LOG_HOURS_MAX" ] || fail "日志保留时长必须是 12 小时到 30 天"; fi
  for _v in "$alog" "$lcore" "$lops" "$dup"; do case $_v in ''|0|1) ;; *) fail "参数无效" ;; esac; done
  if [ -n "$asites" ]; then
    case $asites in 0|1) ;; *) fail "参数无效" ;; esac
    [ "$asites" = 0 ] || [ "$(srv_count)" -gt 0 ] || fail "需要先添加服务器: 自动识别出打不开的网站后, 才有代理可以加" E_NO_SERVERS
  fi
  [ -n "$lang" ] && { settings_set LANG_UI "$lang"; LANG_UI=$lang; changed=1; }
  if [ -n "$hours" ]; then
    oldh=$(logs_hours); settings_set LOG_HOURS "$hours"; sed -i '' '/^LOG_DAYS=/d' "$H/settings.env" 2>/dev/null || true; LOG_HOURS=$hours; ( logs_purge >/dev/null 2>&1 & ); changed=1
    oplog dashboard "修改设置" "$(kv setting log_hours from "$oldh" to "$hours")" ok
  fi
  if [ -n "$lops" ] && [ "$lops" != "${LOG_OPS:-1}" ]; then                          # 关闭操作记录: 先写下「关闭」这一条, 再停; 开启: 先开再写
    [ "$lops" = 0 ] && oplog_force dashboard "修改设置" "$(kv setting log_ops from 1 to 0)" ok
    settings_set LOG_OPS "$lops"; LOG_OPS=$lops; changed=1
    [ "$lops" = 1 ] && oplog_force dashboard "修改设置" "$(kv setting log_ops from 0 to 1)" ok
  fi
  if [ -n "$dup" ] && [ "$dup" != "${DIAG_UPLOAD:-1}" ]; then                      # 诊断摘要上传: 开关本身的变化一定记下来 (隐私相关)
    oplog_force dashboard "修改设置" "$(kv setting diag_upload from "${DIAG_UPLOAD:-1}" to "$dup")" ok
    settings_set DIAG_UPLOAD "$dup"; DIAG_UPLOAD=$dup; changed=1
  fi
  if [ -n "$asites" ] && [ "$asites" != "${AUTO_SITES:-0}" ]; then
    settings_set AUTO_SITES "$asites"; oplog dashboard "修改设置" "$(kv setting auto_sites from "${AUTO_SITES:-0}" to "$asites")" ok; AUTO_SITES=$asites; changed=1
    [ "$asites" = 1 ] || rm -f "$H/.autosite.off" "$H/.autosite.ev"
  fi
  [ -n "$alog" ] && [ "$alog" != "${ACCESS_LOG:-1}" ] && restart="$restart ACCESS_LOG=$alog"
  [ -n "$lcore" ] && [ "$lcore" != "${LOG_CORE:-1}" ] && restart="$restart LOG_CORE=$lcore"
  if [ -n "$restart" ]; then
    # shellcheck disable=SC2086
    job=$(job_spawn settings-apply '准备|下载规则集|生成配置|校验配置|应用并重启|等待就绪' $restart); changed=1
  fi
  [ "$changed" = 1 ] || fail "没有要修改的设置"
  okj "${job:+\"job\":\"$job\"}"
}

# ---------- 诊断上传 (设置 → 日志; 说明见 docs/DIAGNOSTICS.md) ----------
ep_diag_send() { # POST /api/diag/send  hours=…  把完整诊断 (含访问过的域名 / 应用名) 发给开发者: 后台任务, 完成后任务结果里有报告编号
  auth_logged_in || fail "需要登录" E_AUTH
  local hours; hours=$(fp hours); case $hours in ''|*[!0-9]*) hours=24 ;; esac
  okj "\"job\":\"$(job_spawn diag-send '打包完整诊断|上传' "$hours")\""
}
ep_diag_delete() { # POST /api/diag/delete  删除自己已经上传的全部诊断 (摘要 + 完整诊断)
  auth_logged_in || fail "需要登录" E_AUTH
  local n; n=$(OP_WHO=dashboard diag_delete) || fail "没能联系上云端, 稍后再试" E_ACCOUNT_UNREACHABLE
  okj "\"deleted\":${n:-0}"
}

# ---------- 恢复官方默认规则 (设置 → 代理) ----------
# GET /api/settings/reset 先给确认框要显示的数量 (只读); POST 开始重置 (后台任务, 清掉自己改过的规则 + 重新下载云端官方内容); POST .../undo 把最近一次重置清掉的内容放回去。
ep_reset_run() { okj "\"job\":\"$(job_spawn rules-reset "$RULE_STEPS")\""; }
ep_reset_undo() { [ -n "$(reset_latest_backup)" ] || fail "没有可以撤销的重置" E_NOT_FOUND; okj "\"job\":\"$(job_spawn rules-reset-undo "$RULE_STEPS")\""; }

# ---------- 日志 ----------
ep_logs() {
  local type day q; type=$(qp type); day=$(qp day); q=$(qp q | tr -d '\000-\037' | cut -c1-100)
  case $type in ops|access|proxy) ;; *) fail "日志类型无效" ;; esac
  valid_day "$day" || fail "日期格式不正确"
  json "$(logs_query "$type" "$day" "$q" "$(num "$(qp limit)")" "$(num "$(qp offset)")" "$(qp f)")"
}
ep_logs_export() {
  local type day; type=$(qp type); day=$(qp day); [ -n "$day" ] || day=$(date +%F)
  case $type in ops|access|proxy) ;; *) fail "日志类型无效" ;; esac
  valid_day "$day" || fail "日期格式不正确"
  logs_export "$type" "$day" > "$BODY.exp" 2>/dev/null
  send_file 200 text/plain "$BODY.exp" "Content-Disposition: attachment; filename=\"enana-$type-$day.log\"\r\n"
}
ep_logs_bundle() { # 诊断导出: 一个自描述的文本文件 (格式见 docs/DIAGNOSTICS.md); hours=1..720|all  sections=ops,access,proxy,snapshot
  local hours secs sec bad=0 out
  hours=$(qp hours); secs=$(qp sections); [ -n "$hours" ] || hours=24; [ -n "$secs" ] || secs=ops,access,proxy,snapshot
  case $hours in all) ;; ''|*[!0-9]*) fail "时间范围无效" ;; esac
  for sec in $(printf '%s' "$secs" | tr ',' ' '); do case $sec in ops|access|proxy|snapshot) ;; *) bad=1 ;; esac; done
  [ "$bad" = 0 ] && [ -n "$secs" ] || fail "要导出的内容无效"
  out="$BODY.bundle"
  logs_bundle "$hours" "$secs" > "$out" 2>/dev/null
  oplog dashboard "导出诊断日志" "$(kv hours "$hours" sections "$secs" bytes "$(wc -c < "$out" | tr -d ' ')")" ok
  send_file 200 text/plain "$out" "Content-Disposition: attachment; filename=\"enana-diagnostics-$(date +%Y%m%d-%H%M%S).txt\"\r\n"
}
ep_logs_clear() {
  local type before freed; type=$(fp type); before=$(fp before)
  case $type in ops|access|proxy|all) ;; *) fail "日志类型无效" ;; esac
  valid_day "$before" || fail "日期格式不正确"
  freed=$(logs_clear "$type" "$before")
  oplog dashboard "清除日志" "$(kv type "$type" before "$before" freed "${freed:-0}")" ok
  okj "\"freed\":${freed:-0}"
}

# ---------- 规则库 / DNS ----------
RULE_STEPS='准备|下载规则集|生成配置|校验配置|应用并重启|等待就绪'
ep_rules_toggle() {
  local tag on; tag=$(fp tag); on=$(fp on)
  case $on in 0|1) ;; *) fail "参数无效" ;; esac
  rules_list | awk -F'|' -v t="$tag" '$1==t{f=1} END{exit f?0:1}' || fail "找不到这个规则集" E_NOT_FOUND
  if [ "$on" = 0 ] && [ "$(rules_list | awk -F'|' -v t="$tag" '$1==t{print $7; exit}')" = 1 ]; then fail "必选规则集不能停用"; fi
  okj "\"job\":\"$(job_spawn rules-toggle "$RULE_STEPS" "$tag" "$on")\""
}
ep_rules_add() {
  local name url pol; name=$(fp name); url=$(fp url); pol=$(fp policy)
  custom_rs_valid_name "$name" || fail "名称只能用字母/数字/._- (最多 30 位)"
  sub_url_ok "$url" || fail "链接不合法 (只支持公网 http/https)"
  case $pol in pin|auto|direct) ;; *) fail "策略无效" ;; esac
  okj "\"job\":\"$(job_spawn rules-add "$RULE_STEPS" "$name" "$url" "$pol")\""
}
ep_rules_delete() {
  local tag; tag=$(fp tag)
  grep -q "^$tag|" "$H/custom-rulesets.tsv" 2>/dev/null || fail "找不到这个规则集" E_NOT_FOUND
  okj "\"job\":\"$(job_spawn rules-delete "$APPLY_STEPS" "$tag")\""
}
ep_dns_set() {
  local args=() v err T k
  for k in cn:CN cn_custom:CN_CUSTOM global:GLOBAL global_custom:GLOBAL_CUSTOM via:VIA strategy:STRATEGY leak_guard:LEAK ads_block:ADS; do
    v=$(fp "${k%%:*}"); [ -n "$v" ] || continue
    case ${k%%:*} in leak_guard|ads_block) case $v in true) v=1 ;; false) v=0 ;; esac ;; esac
    args+=("${k##*:}=$v")
  done
  [ ${#args[@]} -gt 0 ] || fail "没有要修改的 DNS 设置"
  # 先对副本「干跑」校验, 立刻返回具体原因; 真正的写入在后台任务里
  T=$(mktemp -d); cp "$H/dns.conf" "$T/" 2>/dev/null
  err=$( H=$T; DNS_ERR=''; dns_set "${args[@]}" >/dev/null 2>&1 || printf '%s' "${DNS_ERR:-DNS 设置无效}" ); rm -rf "$T"
  [ -z "$err" ] || fail "$err"
  okj "\"job\":\"$(job_spawn dns-set "$RULE_STEPS" "${args[@]}")\""
}
ep_dns_hosts() {
  local act d ip nd T err; act=$(fp action); d=$(fp domain); ip=$(fp ip); nd=$(fp new_domain)
  case $act in add|update|remove) ;; *) fail "操作无效" ;; esac
  T=$(mktemp); cp "$H/hosts.tsv" "$T" 2>/dev/null || true        # 先在副本上「干跑」校验, 立刻返回具体原因; 真正的写入在后台任务里 (持锁, 失败自动回滚)
  err=$( DNS_HOSTS_FILE=$T; dns_hosts_edit "$act" "$d" "$ip" "$nd" >/dev/null 2>&1 || printf '%s' "${DNS_ERR:-操作失败}" ); rm -f "$T" "$T.new"
  [ -z "$err" ] || fail "$err" E_INVALID
  okj "\"job\":\"$(job_spawn dns-hosts "$APPLY_STEPS" "$act" "$d" "$ip" "$nd")\""
}
ep_dns_hosts_reset() { okj "\"job\":\"$(job_spawn dns-hosts-reset "$APPLY_STEPS")\""; }
ep_dns_bench() { okj "\"job\":\"$(job_spawn dns-bench '准备|测试国内 DNS|测试海外 DNS|完成')\""; }
ep_dns_test() {
  local name resp t0 t1 ans
  name=$(fp name)
  printf '%s' "$name" | LC_ALL=C grep -Eq '^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,24}$' && [ ${#name} -le 253 ] || fail "域名格式不正确"
  t0=$(perl -MTime::HiRes=time -e 'printf "%d", time()*1000')
  resp=$(clash GET "/dns/query?name=$name&type=A" 2>/dev/null || true)
  t1=$(perl -MTime::HiRes=time -e 'printf "%d", time()*1000')
  ans=$(printf '%s' "$resp" | grep -o '"data":"[0-9a-fA-F:.]*"' | sed 's/"data":"\(.*\)"/\1/' | awk 'BEGIN{printf ""} {printf "%s\"%s\"", (NR>1?",":""), $0}')
  [ -n "$ans" ] || fail "没有解析到结果 (域名不存在, 或 DNS 服务器无响应)" E_NETWORK
  okj "\"name\":\"$(jesc "$name")\",\"answers\":[$ans],\"ms\":$((t1 - t0))"
}

# ---------- 更新 ----------
ep_update_check() {
  local force; force=$(qp force)
  update_check "${force:+force}" >/dev/null 2>&1 || true
  json "{\"ok\":true,$(update_json)}"
}
ep_update_apply() {
  local what; what=$(qp what)
  case $what in
    app)  update_has_new || fail "已经是最新版本"; okj "\"job\":\"$(job_spawn self-update '检查新版本|下载并校验新版本|安装并重新生成配置|完成')\"" ;;
    core) okj "\"job\":\"$(job_spawn core-upgrade '查询最新版本|下载并校验新核心|用新核心校验现有配置|重启服务')\"" ;;
    *)    fail "参数无效" ;;
  esac
}

# ---------- 本机 IP 与测速 ----------
ep_speed_start() {
  local mode spd nodes tgts id rc
  mode=$(fp mode); [ -n "$mode" ] || mode=both
  spd=$(fp speed); [ -n "$spd" ] || spd=1
  nodes=$(fp nodes); tgts=$(fp targets)
  case $spd in true) spd=1 ;; false) spd=0 ;; esac
  # 目标/节点列表里只允许安全字符 (节点名在 speed_start 里还会按现有服务器白名单校验)
  case $tgts in *[!A-Za-z0-9,_-]*) fail "目标无效" ;; esac
  id=$(speed_start "$mode" "$spd" "$nodes" "$tgts"); rc=$?
  case $rc in
    0) job_launch speedtest "$id" "$id"; okj "\"id\":\"$id\"" ;;
    2) fail "已经有测速在运行" E_RUNNING "\"id\":\"$(speed_running)\"" ;;
    3) fail "还没有可测的节点, 请先添加服务器" E_NO_SERVERS ;;
    *) fail "测速参数无效" ;;
  esac
}
ep_speed_targets_save() {
  local id; id=$(fp id); case $id in *[!a-z0-9_-]*) fail "目标编号无效" ;; esac
  speed_target_save "$id" "$(fp name)" "$(fp group)" "$(fp url)" "$(fp expect)" "$(fp icon)" || fail "$SPEED_ERR" E_INVALID
  oplog dashboard "$([ -n "$id" ] && echo 修改测速目标 || echo 添加测速目标)" "$(kv id "$SPEED_ID")" ok; id=$SPEED_ID
  okj "\"id\":\"$id\""
}
ep_speed_targets_op() { # delete|restore|reset
  local id; id=$(fp id); case $id in *[!a-z0-9_-]*) fail "目标编号无效" ;; esac
  case $1 in
    delete)  speed_target_delete "$id" || fail "$SPEED_ERR" E_NOT_FOUND ;;
    restore) speed_target_restore "$id" || fail "$SPEED_ERR" E_NOT_FOUND ;;
    reset)   speed_targets_reset || fail "$SPEED_ERR" E_BUSY ;;
  esac
  oplog dashboard "测速目标: $1" "$(kv id "${id:-all}")" ok; okj
}
ep_speed_status() { local id; id=$(qp id); speed_id_ok "$id" || fail "测速任务编号无效" E_NOT_FOUND; json "$(speed_render "$id")"; }
ep_speed_last() { local id; id=$(speed_last_id); if [ -n "$id" ] && [ -f "$(speed_dir)/$id.meta" ]; then json "$(speed_render "$id")"; else okj '"none":true'; fi; }
ep_speed_stop() { local id; id=$(qp id); speed_id_ok "$id" || fail "测速任务编号无效" E_NOT_FOUND; speed_stop "$id"; okj; }

case "$method $path" in
  "GET /api/auth/status")      ep_auth_status ;;
  "POST /api/login")           ep_login ;;
  "POST /api/register")        ep_register ;;
  "POST /api/logout")          ep_logout ;;
  "POST /api/proxy")           ep_proxy ;;
  "POST /api/sysproxy")        ep_sysproxy ;;
  "GET /api/devices")          ep_devices ;;
  "POST /api/devices/kick")    ep_devices_kick ;;
  "GET /api/stats")            ep_stats ;;
  "GET /api/stats/apps")       ep_stats_apps ;;
  "GET /api/content")          json "{\"ok\":true,$(cloud_status_json)}" ;;
  "POST /api/content/refresh") okj "\"job\":\"$(job_spawn content-sync "$RULE_STEPS" force)\"" ;;
  "POST /api/password")        ep_password ;;
  "POST /api/auth/verify")     ep_auth_verify ;;
  "GET /api/servers/secret")   ep_servers_secret ;;
  "GET /api/sub/url")          ep_sub_url ;;
  "GET /api/export")           ep_export ;;
  "POST /api/vps/probe")       ep_vps_probe ;;
  "POST /api/vps/cancel")      ep_vps_cancel ;;
  "POST /api/vps/provision")   ep_vps_provision ;;
  "POST /api/vps/redetect")    ep_vps_redetect ;;
  "POST /api/vps/forget")      ep_vps_forget ;;
  "GET /api/vps")              json "{\"ok\":true,\"vps\":[$(vps_json)]}" ;;
  "GET /api/sync")             json "{\"ok\":true,$(sync_state_json)}" ;;
  "POST /api/sync/settings")   ep_sync_settings ;;
  "POST /api/sync/push")       ep_sync_push ;;
  "POST /api/sync/pull")       ep_sync_pull ;;
  "POST /api/sync/preview")    ep_sync_preview ;;
  "POST /api/sync/clear")      ep_sync_clear ;;
  "GET /api/prefs")            json "{\"ok\":true,$(prefs_json)}" ;;
  "POST /api/prefs")           ep_prefs_set ;;
  "GET /api/plan")             ep_plan ;;
  "GET /api/billing")          ep_billing status billing GET ;;
  "POST /api/billing/checkout") ep_billing checkout billing/checkout POST ;;
  "GET /api/billing/order")    ep_billing order billing/order GET ;;
  "POST /api/billing/cancel")   ep_billing cancel billing/cancel POST ;;
  "POST /api/billing/purchase") ep_billing purchase billing/purchase POST ;;
  "POST /api/billing/auto-renew") ep_billing auto-renew billing/auto-renew POST ;;
  "GET /api/email/status")     ep_billing email-status email/status GET ;;
  "POST /api/email/send")      ep_billing email-send email/send POST ;;
  "GET /api/state")            ep_state ;;
  "GET /api/settings")         ep_settings_get ;;
  "POST /api/network-mode")
    nm=$(fp mode); case $nm in system|tun) ;; *) fail "流量接管模式无效" ;; esac
    j=$(job_spawn network-mode "$APPLY_STEPS" "$nm"); okj "\"job\":\"$j\"" ;;
  "POST /api/settings")        ep_settings_set ;;
  "GET /api/settings/reset")   json "{\"ok\":true,$(reset_preview_json)}" ;;
  "POST /api/settings/reset")  ep_reset_run ;;
  "POST /api/settings/reset/undo") ep_reset_undo ;;
  "GET /api/apps")             apps_resp ;;
  "POST /api/apps/scan")       ep_apps_scan ;;
  "GET /api/sites/domains")    ep_sites_domains_get ;;
  "POST /api/sites/domains")   ep_sites_domains_post ;;
  "POST /api/sites/domains/reset") ep_sites_domains_reset ;;
  "POST /api/apps/inspect")    ep_apps_inspect ;;
  "POST /api/apps/custom")     ep_apps_custom ;;
  "POST /api/apps/custom/delete") ep_apps_custom_delete ;;
  "POST /api/apps/adopt")      ep_apps_adopt ;;
  "POST /api/apps/ack")        n=$(qp name); [ "$(qp all)" = 1 ] && n=all; [ -n "$n" ] || fail "缺少应用名"; lock_take && { apps_ack "$n"; lock_drop; }; okj ;;
  "POST /api/override")        ep_override ;;
  "POST /api/policy")          ep_policy ;;
  "POST /api/audit")           ep_audit ;;
  "POST /api/sites/auto/clear") ep_sites_auto_clear ;;
  "POST /api/servers/import")  ep_servers_import ;;
  "POST /api/servers/delete")  ep_servers_change delete ;;
  "POST /api/servers/role")    ep_servers_change role ;;
  "POST /api/cert")            ep_cert ;;
  "POST /api/sub/fetch")       ep_sub_fetch ;;
  "POST /api/sub/save")        ep_sub_save ;;
  "POST /api/sub/delete")      ep_sub_delete ;;
  "GET /api/rules")            json "{\"ok\":true,\"sets\":$(rules_json | i18n_json 'name|desc|repo'),\"updated\":$(rules_updated_at)}" ;;
  "POST /api/rules/toggle")    ep_rules_toggle ;;
  "POST /api/rules/custom/add")    ep_rules_add ;;
  "POST /api/rules/custom/delete") ep_rules_delete ;;
  "POST /api/diag/send")       ep_diag_send ;;
  "POST /api/diag/delete")     ep_diag_delete ;;
  "POST /api/update-rules")    okj "\"job\":\"$(job_spawn update-rules '准备|下载规则集|应用规则集|完成')\"" ;;
  "GET /api/dns")              json "$(printf '{"ok":true,%s}' "$(dns_state_json)" | i18n_json 'name|desc|match|server|via|detail')" ;;
  "POST /api/dns")             ep_dns_set ;;
  "POST /api/dns/test")        ep_dns_test ;;
  "POST /api/dns/hosts")       ep_dns_hosts ;;
  "POST /api/dns/hosts/reset") ep_dns_hosts_reset ;;
  "POST /api/dns/bench")       ep_dns_bench ;;
  "POST /api/restart")         okj "\"job\":\"$(job_spawn restart '重启服务|等待服务就绪')\"" ;;
  "GET /api/job")              json "$(job_get "$(qp id)")" ;;
  "GET /api/log")              ep_log ;;
  "GET /api/logs")             ep_logs ;;
  "GET /api/logs/export")      ep_logs_export ;;
  "GET /api/logs/bundle")      ep_logs_bundle ;;
  "POST /api/logs/clear")      ep_logs_clear ;;
  "GET /api/update/check")     ep_update_check ;;
  "POST /api/update/apply")    ep_update_apply ;;
  "GET /api/net/info")         json "{\"ok\":true,$(speed_netinfo_json)}" ;;
  "POST /api/net/refresh")     okj "\"job\":\"$(job_spawn net-info '查询本机与各线路的出口 IP|完成')\"" ;;
  "GET /api/speedtest/plan")   json "{\"ok\":true,$(speed_plan_json)}" ;;
  "GET /api/speedtest/targets") json "{\"ok\":true,$(speed_targets_json)}" ;;
  "POST /api/speedtest/targets") ep_speed_targets_save ;;
  "POST /api/speedtest/targets/delete")  ep_speed_targets_op delete ;;
  "POST /api/speedtest/targets/restore") ep_speed_targets_op restore ;;
  "POST /api/speedtest/targets/reset")   ep_speed_targets_op reset ;;
  "POST /api/speedtest/start") ep_speed_start ;;
  "GET /api/speedtest/status") ep_speed_status ;;
  "GET /api/speedtest/last")   ep_speed_last ;;
  "POST /api/speedtest/stop")  ep_speed_stop ;;
  *)                           deny 404 E_NOT_FOUND "接口不存在" ;;
esac
exit 0
