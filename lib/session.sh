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

# session_upload <输出文件> <路径> <文件>  -> HTTP 状态码 (完整诊断用 multipart 上传; 没有云端会话 = 000)
session_upload() {
  local tok sid; tok=$(session_token); sid=$(session_id)
  [ -n "$tok" ] && [ -n "$sid" ] || { printf '000'; return 0; }
  _cloud_upload "$2" "$3" "$1" "$VERSION" "Authorization: Bearer $tok" "X-Enana-Session: $sid"
}

# 退出登录时通知云端释放名额 (后台进行, 最多几秒; 联网失败也无所谓: 云端 10 分钟没有心跳就不再占名额)
session_logout_remote() {
  local tok sid; tok=$(session_token); sid=$(session_id)
  [ -n "$tok" ] && [ -n "$sid" ] || return 0
  ( _cloud_req POST /api/enana/v1/session/logout '{}' /dev/null "Authorization: Bearer $tok" "X-Enana-Session: $sid" >/dev/null 2>&1 ) >/dev/null 2>&1 &
}

# 同步通知云端释放名额: 卸载用 (本机数据马上要删除, 后台任务来不及); 最多几秒, 联网失败也无所谓 (云端 10 分钟没有心跳就不再占名额)。0 = 云端已确认 (或本来就没有会话)
session_logout_wait() {
  local tok sid code; tok=$(session_token); sid=$(session_id)
  [ -n "$tok" ] && [ -n "$sid" ] || return 0
  code=$(CLOUD_MAXTIME=6 CLOUD_CONNECT=4 _cloud_req POST /api/enana/v1/session/logout '{}' /dev/null "Authorization: Bearer $tok" "X-Enana-Session: $sid" 2>/dev/null)
  case $code in 2??|401) return 0 ;; *) return 1 ;; esac      # 401 = 云端早就撤销了这个会话
}

# 心跳状态 ($H/hb.state, 诊断导出的 session.* 读它): 最近一次尝试的时间 / HTTP 状态码 / 最近一次成功的时间。
# 被退出登录时「距离上次成功过了多久」是判断原因的关键证据 (一直成功后突然 401 = 云端撤销; 早就连不上 = 离线宽限)。
session_hb_note() { # <HTTP 状态码>
  local now_ okts; now_=$(date +%s)
  okts=$(sed -n 's/^ok=//p' "$H/hb.state" 2>/dev/null | head -1)
  [ "$1" = 200 ] && okts=$now_
  printf 'last=%s\ncode=%s\nok=%s\n' "$now_" "$1" "${okts:-}" > "$H/hb.state.new" 2>/dev/null && mv "$H/hb.state.new" "$H/hb.state"
  return 0
}
session_hb_get() { sed -n "s/^$1=//p" "$H/hb.state" 2>/dev/null | head -1; }

# 在本机结束登录 (被下线 / 离线过久): 关闭代理 + 令牌轮换 + 记下原因 (登录框会显示) + 让核心换上新令牌
session_local_end() { # <原因> [云端返回的 HTTP 状态码] [补充信息 (k=v …)]
  local reason=$1 http=${2:-} okts sid; okts=$(session_hb_get ok); sid=$(session_id)
  oplog auto "已被退出登录" "$(kv reason "$reason" http "$http" proxy_was "${PROXY_ENABLED:-0}" since_ok_s "${okts:+$(( $(date +%s) - okts ))}" session "${sid: -4}" via "$(call_chain 2 5)")${3:+ $3}" ok      # 只有心跳会走到这里 (来源是 auto); since_ok_s = 距上次心跳成功多少秒
  auth_logout_local
  mkdir -p "$H"; printf '%s\n' "$reason" > "$H/notice"
  op_sync_secret
}

# session_heartbeat: 0 = 在线 (或暂时连不上但还在宽限期内) · 1 = 会话已被撤销, 本机已自动退出登录
session_heartbeat() {
  local code reason now_ first age tok out rcode raw
  auth_logged_in || return 0
  [ -n "$(session_id)" ] || return 0                      # 没有云端会话 (例如离线登录时): 没有可汇报的
  out=$(mktemp); code=$(session_call "$out" POST /api/enana/v1/session/heartbeat '{}')
  session_hb_note "$code"
  case $code in
    200)
      tok=$(sed -n 's/.*"token":"\([^"]*\)".*/\1/p' "$out" | head -1); [ -n "$tok" ] && session_save "$tok" ''
      if [ -f "$H/hb.fail" ]; then IFS= read -r first < "$H/hb.fail"; oplog auto "会话心跳恢复" "$(kv down_s "$(( $(date +%s) - ${first:-0} ))")" ok; fi      # 连不上云端的这段时间有多长 (超过 7 天会被自动退出登录)
      rm -f "$out" "$H/hb.fail"; return 0 ;;
    401)
      reason=$(sed -n 's/.*"reason":"\([a-z_]*\)".*/\1/p' "$out" | head -1); rcode=$(sed -n 's/.*"code":"\([a-z_]*\)".*/\1/p' "$out" | head -1); rm -f "$out"
      raw=$reason
      case $reason in kicked|limit|logout|expired) ;; *) reason=kicked ;; esac
      # raw_reason 为空 + resp_code=unauthorized = 令牌被云端直接拒绝 (不是会话被撤销); 上面把未知原因归为 kicked 只是为了登录框的提示
      session_local_end "$reason" 401 "$(kv raw_reason "$raw" resp_code "$rcode")"; return 1 ;;
    *)
      rm -f "$out"; now_=$(date +%s)
      if [ -f "$H/hb.fail" ]; then IFS= read -r first < "$H/hb.fail"; else first=$now_; printf '%s\n' "$now_" > "$H/hb.fail"; oplog auto "会话心跳失败" "$(kv http "$code" note "cannot reach the cloud; the session is kept for $HB_OFFLINE_DAYS days offline")" error; fi
      age=$(( now_ - ${first:-$now_} ))
      if [ "$age" -gt $(( HB_OFFLINE_DAYS * 86400 )) ]; then session_local_end offline_expired "$code"; return 1; fi
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
