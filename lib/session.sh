# 登录会话 (与云端同步): 设备在线名额、心跳、被其它设备下线、退出登录。依赖 common.sh auth.sh device.sh config.sh(proxy_set_enabled) ops.sh(op_sync_secret)。
#
#   $H/cloud.token   云端令牌 (JWT, 每次心跳刷新; 600)        $H/session   云端会话 id (600)
#   $H/hb.fail       连续联网失败的起始时间 (成功一次就清除)   $H/notice    这台设备上一次被退出登录的原因 (kicked / offline_expired / limit)
# 心跳: 定时任务每 ~2 分钟运行 `enana heartbeat`: 告诉云端「我还在线」; 云端说会话被撤销 (被同账号另一台设备下线 / 超限) 时,
# 本机自动退出登录并关闭代理。连续 7 天连不上云端也会自动退出登录 (离线宽限)。离线登录不会创建云端会话。

HB_OFFLINE_DAYS=7

session_id()    { local s; [ -s "$H/session" ] && IFS= read -r s < "$H/session"; printf '%s' "${s:-}"; }
session_token() { local s; [ -s "$H/cloud.token" ] && IFS= read -r s < "$H/cloud.token"; printf '%s' "${s:-}"; }
session_save() { # <token> <session id>
  mkdir -p "$H"
  [ -n "$1" ] && { printf '%s\n' "$1" > "$H/cloud.token.new" && chmod 600 "$H/cloud.token.new" && mv "$H/cloud.token.new" "$H/cloud.token"; }
  [ -n "$2" ] && { printf '%s\n' "$2" > "$H/session.new" && chmod 600 "$H/session.new" && mv "$H/session.new" "$H/session"; }
  return 0
}
session_clear() { rm -f "$H/cloud.token" "$H/session" "$H/hb.fail"; }
session_notice() { local n; [ -s "$H/notice" ] && IFS= read -r n < "$H/notice"; printf '%s' "${n:-}"; }

# session_call <输出文件> <GET|POST|PUT|DELETE> <路径> [JSON 正文]  -> 响应体写入输出文件, 打印 HTTP 状态码 (000 = 没连上 / 没有云端会话)
# (在 $(...) 里调用, 所以输出文件由调用方创建并传入)
session_call() {
  local out=$1 m=$2 path=$3 body=${4:-} tok sid
  tok=$(session_token); sid=$(session_id)
  [ -n "$tok" ] && [ -n "$sid" ] || { printf '000'; return 0; }
  _cloud_req "$m" "$path" "$body" "$out" "Authorization: Bearer $tok" "X-Enana-Session: $sid"
}

# 退出登录时通知云端释放名额 (后台进行, 最多几秒; 联网失败也无所谓: 云端 10 分钟没有心跳就不再占名额)
session_logout_remote() {
  local tok sid; tok=$(session_token); sid=$(session_id)
  [ -n "$tok" ] && [ -n "$sid" ] || return 0
  ( _cloud_req POST /api/enana/v1/session/logout '{}' /dev/null "Authorization: Bearer $tok" "X-Enana-Session: $sid" >/dev/null 2>&1 ) >/dev/null 2>&1 &
}

# 在本机结束登录 (被下线 / 离线过久): 关闭代理 + 令牌轮换 + 记下原因 (登录框会显示) + 让核心换上新令牌
session_local_end() { # <原因>
  local reason=$1
  oplog "${OP_WHO:-terminal}" "已被退出登录" "$reason" ok
  auth_logout_local
  mkdir -p "$H"; printf '%s\n' "$reason" > "$H/notice"
  op_sync_secret
}

# session_heartbeat: 0 = 在线 (或暂时连不上但还在宽限期内) · 1 = 会话已被撤销, 本机已自动退出登录
session_heartbeat() {
  local code reason now_ first age tok out
  auth_logged_in || return 0
  [ -n "$(session_id)" ] || return 0                      # 没有云端会话 (例如离线登录时): 没有可汇报的
  out=$(mktemp); code=$(session_call "$out" POST /api/enana/v1/session/heartbeat '{}')
  case $code in
    200)
      tok=$(sed -n 's/.*"token":"\([^"]*\)".*/\1/p' "$out" | head -1); [ -n "$tok" ] && session_save "$tok" ''
      rm -f "$out" "$H/hb.fail"; return 0 ;;
    401)
      reason=$(sed -n 's/.*"reason":"\([a-z_]*\)".*/\1/p' "$out" | head -1); rm -f "$out"
      case $reason in kicked|limit|logout|expired) ;; *) reason=kicked ;; esac
      session_local_end "$reason"; return 1 ;;
    *)
      rm -f "$out"; now_=$(date +%s)
      if [ -f "$H/hb.fail" ]; then IFS= read -r first < "$H/hb.fail"; else first=$now_; printf '%s\n' "$now_" > "$H/hb.fail"; fi
      age=$(( now_ - ${first:-$now_} ))
      if [ "$age" -gt $(( HB_OFFLINE_DAYS * 86400 )) ]; then session_local_end offline_expired; return 1; fi
      return 0 ;;
  esac
}

# 我的设备 (GET /api/devices 的主体)
session_devices_json() {
  local code arr limit platform out; out=$(mktemp)
  code=$(session_call "$out" GET /api/enana/v1/devices)
  if [ "$code" != 200 ]; then rm -f "$out"; return 1; fi
  arr=$(sed -n 's/.*"devices":\(\[.*\]\).*/\1/p' "$out" | head -1 | tr -d '\000-\037' | cut -c1-16000)
  limit=$(sed -n 's/.*"limit":\([0-9]*\).*/\1/p' "$out" | head -1); platform=$(sed -n 's/.*"platform":"\([a-z]*\)"[^[]*$/\1/p' "$out" | head -1)
  rm -f "$out"
  [ -n "$arr" ] || arr='[]'
  printf '"platform":"%s","limit":%s,"devices":%s' "${platform:-$(device_platform)}" "${limit:-2}" "$arr"
}
session_kick() { # <device uid>  0 = 成功
  local code out; out=$(mktemp)
  code=$(session_call "$out" POST /api/enana/v1/devices/kick "{\"device_uid\":\"$(jesc "$1")\"}")
  rm -f "$out"; [ "$code" = 200 ]
}
