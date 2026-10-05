# 诊断上传 (官方云端; 说明见 docs/DIAGNOSTICS.md)。依赖 common.sh auth.sh session.sh logs.sh。
#
#   摘要 (自动): 登录 / 注册成功后传一次, 之后只在「值得上报」的事件发生时传 (总开关被自动关闭 / 系统代理被关 / 核心反复重启 / 固定出口变空 …), 本机 10 分钟内最多一次。
#     内容只有结构化的状态 / 判定 / 操作记录 / 健康汇总, 由 lib/diag.pl 按白名单生成: 没有网站、应用名、IP、服务器地址、密码、令牌。
#     设置里可以关 (DIAG_UPLOAD=0); 每一次上传都会写进「操作记录」(诊断上传), 随时能看到传了什么时候传的; `enana diag-preview` 打印下一份会传什么。
#   完整诊断 (手动): 只在用户点「发送完整诊断给开发者」(或 `enana diag-send`) 时上传, 含访问过的域名和应用名, 用来排查摘要看不出来的问题; 返回一个报告编号发给开发者。
#   云端 7 天后自动清理 (每台设备最多保留 200 份摘要 / 5 份完整诊断), 账号删除时一并删除。

DIAG_GAP=600          # 本机限频 (秒): 两次自动摘要之间至少隔多久 (云端另有每台设备 5 分钟 / 每天 60 份的限制)
DIAG_FULL_MAX=7900000 # 完整诊断压缩后最多多少字节 (云端上限 8 MiB); 超过就缩短时间范围

diag_enabled() { # 自动摘要: macOS 上 (Windows 的健康判定还没做, 之后跟进) · 设置里开着 · 已登录并且有云端会话
  [ -z "${ENANA_NO_DIAG:-}" ] && [ "${ENANA_PLATFORM:-darwin}" = darwin ] && [ "${DIAG_UPLOAD:-1}" = 1 ] && auth_logged_in && [ -n "$(session_id)" ]
}
diag_summary_json() { # 标准输出: 下一份摘要 (只用本机数据, 不联网)
  logs_bundle 24 snapshot,ops 2>/dev/null | perl "$LIB/diag.pl" summary
}
diag_upload() { # <触发原因: login | register | manual | event:<类型>>  生成摘要并上传; 结果写进操作记录
  local trig=$1 body payload out code last now_
  diag_enabled || return 0
  now_=$(now)
  case $trig in
    login|register|manual) ;;
    *) last=$(cat "$H/.diag.last" 2>/dev/null || true); [ $(( now_ - ${last:-0} )) -ge "$DIAG_GAP" ] || return 0 ;;
  esac
  body=$(diag_summary_json) && [ -n "$body" ] || { oplog auto "诊断上传" "$(kv trigger "$trig" err build-failed)" error; return 1; }
  payload=$(printf '{"trigger":"%s","payload":%s}' "$(jesc "$trig")" "$body")
  out=$(mktemp); code=$(session_call "$out" POST /api/enana/v1/diag "$payload"); rm -f "$out"
  printf '%s\n' "$now_" > "$H/.diag.last"
  oplog auto "诊断上传" "$(kv trigger "$trig" http "$code" bytes "${#payload}")" "$([ "$code" = 200 ] && echo ok || echo error)"
  [ "$code" = 200 ]
}
diag_kick() { # 登录 / 注册成功后在后台传一份摘要 (生成要跑几秒探测, 不能拖慢登录); 仪表盘的辅助服务 / 终端里都能活到传完
  diag_enabled || return 0
  ( diag_upload "$1" >/dev/null 2>&1 & ) >/dev/null 2>&1
}
diag_tick() { # 每分钟 (cmd_tick): 只看操作记录里新增的行, 只有「值得上报」的事件才触发一次上传
  diag_enabled || return 0
  local day f pf="$H/.diag.pos" pday='' pn=0 tot want=''
  day=$(date +%F); f="$LOGS/ops-$day.log"
  [ -f "$f" ] || return 0
  tot=$(wc -l < "$f" | tr -d ' ')
  [ -f "$pf" ] && read -r pday pn < "$pf"
  [ "$pday" = "$day" ] || pn=0                     # 新的一天 (或第一次): 从头看 (按日期记, 不记路径: 路径里可能有空格)
  [ "$tot" -ge "${pn:-0}" ] || pn=0                # 日志被清理过: 从头看
  want=$(tail -n +$(( ${pn:-0} + 1 )) "$f" | awk -F'\t' '
    $3 == "总开关变更" && $2 == "auto" && $4 ~ /key=PROXY_ENABLED/ && $4 ~ /to=0/ { print "switch_off"; exit }
    $3 == "环境状态变化" && $4 ~ /item=sysproxy / && $4 ~ /to=0/ { print "sysproxy"; exit }
    $3 == "环境状态变化" && $4 ~ /item=core_running / && $4 ~ /to=0/ { print "core"; exit }
    $3 == "环境状态变化" && $4 ~ /item=tun_ready / && $4 ~ /to=0/ { print "tun"; exit }
    $3 == "环境状态变化" && $4 ~ /item=pin / && $4 ~ /to=empty/ { print "pin"; exit }
    $3 == "核心进程已重启" { print "core_restart"; exit }')
  printf '%s %s\n' "$day" "$tot" > "$pf"
  [ -z "$want" ] || diag_upload "event:$want" || true
}
diag_delete() { # 删除自己已经上传的全部诊断 (所有设备的摘要和完整诊断); 成功时打印删除了几份
  local out code n
  { auth_logged_in && [ -n "$(session_id)" ]; } || return 2
  out=$(mktemp); code=$(session_call "$out" DELETE /api/enana/v1/diag); n=$(sed -n 's/.*"deleted":\([0-9]*\).*/\1/p' "$out" | head -1); rm -f "$out"
  oplog "${OP_WHO:-terminal}" "删除已上传的诊断" "$(kv http "$code" deleted "$n")" "$([ "$code" = 200 ] && echo ok || echo error)"
  [ "$code" = 200 ] || return 1
  printf '%s' "${n:-0}"
}
diag_send_full() { # [小时, 默认 24]  完整诊断 (含访问过的域名 / 应用名) → 云端; 成功时 DIAG_ID = 报告编号, 失败时 DIAG_ERR = 原因
  local hours=${1:-24} f out code id size=0 h; DIAG_ID=''; DIAG_ERR=''
  case $hours in ''|*[!0-9]*) hours=24 ;; esac
  [ -z "${ENANA_NO_DIAG:-}" ] || { DIAG_ERR=disabled; return 1; }
  { auth_logged_in && [ -n "$(session_id)" ]; } || { DIAG_ERR=not-logged-in; return 2; }
  f=$(mktemp); out=$(mktemp)
  for h in "$hours" 6 1; do                        # 太大就缩短时间范围 (云端上限 8 MiB)
    [ "$h" -le "$hours" ] || continue
    logs_bundle "$h" ops,access,proxy,snapshot 2>/dev/null | gzip -c > "$f"
    size=$(wc -c < "$f" | tr -d ' ')
    [ "$size" -le "$DIAG_FULL_MAX" ] && break
  done
  if [ "$size" -gt "$DIAG_FULL_MAX" ]; then rm -f "$f" "$out"; DIAG_ERR=too-large; return 3; fi
  code=$(session_upload "$out" /api/enana/v1/diag/full "$f")
  id=$(sed -n 's/.*"id":"\([A-Za-z0-9]*\)".*/\1/p' "$out" | head -1); rm -f "$f" "$out"
  oplog "${OP_WHO:-terminal}" "发送完整诊断" "$(kv hours "$h" bytes "$size" http "$code" id "$id")" "$([ "$code" = 200 ] && echo ok || echo error)"
  if [ "$code" = 200 ] && [ -n "$id" ]; then DIAG_ID=$id; return 0; fi
  DIAG_ERR="http-$code"; return 1
}
