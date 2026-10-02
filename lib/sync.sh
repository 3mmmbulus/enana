# 云端同步 (端到端加密): 登录同一个 enana 账号的另一台电脑可以一键同步 服务器 / 订阅 / 应用与网站策略 / DNS / 规则库选择 / 偏好 / 语言等设置。
# 依赖 common.sh auth.sh session.sh snapshot.sh prefs.sh ops.sh jobs.sh。加密实现在 lib/sync.pl, 快照格式在 lib/snapshot.pl (方案说明见各文件开头)。
#
# 端到端: 密钥由「账号密码」在本机派生 (PBKDF2-SHA256 200000 次), 只在登录时派生并保存在本机 (600 权限), 退出账号即删除; 云端只存密文, 看不到服务器地址和密码。
# 永远不同步: SSH 密码 / 私钥, 令牌, 设备编号, 端口, 代理总开关, 开机自启 (快照白名单里没有它们)。
# 密码在网站上 (或别的电脑上) 改了之后, 新密码派生的密钥解不开旧密文: 拉取时返回 E_SYNC_KEY, 让用户输入「旧密码」重试, 成功后用新密钥重新加密上传。
#
#   $H/sync.conf   ENABLED AUTO ACCOUNT BASE_VERSION SYNCED_HASH LAST_PULL LAST_PUSH CHECKED CONFLICT   (KEY=VALUE, 600)
#   $H/sync.key    第 1 行 加密口令 (hex), 第 2 行 校验密钥 (hex)   (600)
#   BASE_VERSION = 本机内容所基于的云端版本 (推送 / 拉取成功后更新); SYNCED_HASH = 那一刻本机可同步内容的哈希 (和现在比较就知道有没有没上传的改动)

SYNC_ITER=200000
SYNC_ERR=''; SYNC_CODE=''
R_EXISTS=0; R_VERSION=0; R_UPDATED=0; R_SIZE=0; R_DEVICE=''

sync_get() { sed -n "s/^$1=//p" "$H/sync.conf" 2>/dev/null | head -1; }
sync_set() { local f="$H/sync.conf" k=$1 v=$2; { grep -v "^$k=" "$f" 2>/dev/null || true; printf '%s=%s\n' "$k" "$v"; } > "$f.new" && chmod 600 "$f.new" && mv "$f.new" "$f"; }
sync_enabled() { [ "$(sync_get ENABLED)" = 1 ]; }
sync_auto() { [ "$(sync_get AUTO)" = 1 ]; }
sync_have_key() { [ -s "$H/sync.key" ]; }
snap_hash() { /usr/bin/perl "$LIB/snapshot.pl" hash "$H"; }
sync_local_has_data() { [ -s "$H/servers.sync" ] || [ -s "$H/subs.sync" ] || [ -s "$H/overrides.tsv" ] || [ -s "$H/custom-rulesets.tsv" ]; }      # 本机有没有用户自己的配置 (自动同步在本机有数据时不会静默覆盖)

# 登录 / 退出时调用: 换了账号就重置版本信息 (同一账号再登录保留, 不会多出「冲突」提示)
sync_on_login() { # <账号 id> <密码>   (best-effort: 失败只是不能同步, 不影响登录)
  local id=$1 pw=$2
  [ -n "$id" ] || return 0
  [ "$(sync_get ACCOUNT)" = "$id" ] || { sync_set BASE_VERSION 0; sync_set SYNCED_HASH ''; sync_set CONFLICT 0; sync_set ACCOUNT "$id"; }
  sync_key_derive "$id" "$pw" || true
}
sync_on_logout() { rm -f "$H/sync.key" "$H/sync.key.old" "$H/sync-incoming.json" "$H/sync-incoming.b64" "$H/sync.remote"; }

# sync_key_derive <账号 id> <密码> [输出文件]  -> 0 成功
sync_key_derive() {
  local id=$1 pw=$2 out=${3:-$H/sync.key}
  printf '%s' "$pw" | /usr/bin/perl "$LIB/sync.pl" kdf "$id" "$SYNC_ITER" > "$out.new" 2>/dev/null && [ "$(wc -l < "$out.new" | tr -d ' ')" = 2 ] \
    && chmod 600 "$out.new" && mv "$out.new" "$out" || { rm -f "$out.new"; return 1; }
}

# ---------- 云端快照 ----------
# sync_remote_meta  取云端快照信息 -> R_EXISTS R_VERSION R_UPDATED R_SIZE R_DEVICE   0 = 取到 (可能不存在)  1 = 连不上  2 = 会话已失效   (最近 20 秒内的结果有缓存)
sync_remote_meta() {
  local out code now_ at; now_=$(now)
  R_EXISTS=0; R_VERSION=0; R_UPDATED=0; R_SIZE=0; R_DEVICE=''
  [ -n "$(session_id)" ] || return 1
  at=0; [ -s "$H/sync.remote" ] && at=$(sed -n 's/^at=//p' "$H/sync.remote" | head -1)
  if [ -s "$H/sync.remote" ] && [ $(( now_ - ${at:-0} )) -lt 20 ]; then
    R_EXISTS=$(sed -n 's/^exists=//p' "$H/sync.remote"); R_VERSION=$(sed -n 's/^version=//p' "$H/sync.remote"); R_UPDATED=$(sed -n 's/^updated=//p' "$H/sync.remote")
    R_SIZE=$(sed -n 's/^size=//p' "$H/sync.remote"); R_DEVICE=$(sed -n 's/^device=//p' "$H/sync.remote"); return 0
  fi
  out=$(mktemp); code=$(CLOUD_MAXTIME=10 CLOUD_CONNECT=5 session_call "$out" GET /api/enana/v1/sync/snapshot)
  case $code in
    200)
      if grep -q '"exists":true' "$out"; then
        R_EXISTS=1; R_VERSION=$(sed -n 's/.*"version":\([0-9]*\).*/\1/p' "$out" | head -1); R_UPDATED=$(sed -n 's/.*"updated":\([0-9]*\).*/\1/p' "$out" | head -1)
        R_SIZE=$(sed -n 's/.*"size":\([0-9]*\).*/\1/p' "$out" | head -1); R_DEVICE=$(sed -n 's/.*"device":"\([^"]*\)".*/\1/p' "$out" | head -1)
        R_VERSION=${R_VERSION:-0}; R_UPDATED=${R_UPDATED:-0}; R_SIZE=${R_SIZE:-0}
      fi
      printf 'at=%s\nexists=%s\nversion=%s\nupdated=%s\nsize=%s\ndevice=%s\n' "$now_" "$R_EXISTS" "$R_VERSION" "$R_UPDATED" "$R_SIZE" "$R_DEVICE" > "$H/sync.remote"
      rm -f "$out"; return 0 ;;
    401) rm -f "$out"; return 2 ;;
    *)   rm -f "$out"; return 1 ;;
  esac
}
sync_remote_forget() { rm -f "$H/sync.remote"; }       # 推送 / 拉取 / 清除之后让缓存失效

# sync_fetch  下载云端快照的密文 -> $H/sync-incoming.b64 (600), SYNC_IN_VERSION   0 = 成功  1 = 连不上  2 = 会话已失效  4 = 云端还没有数据  5 = 内容格式不对
sync_fetch() {
  local out code
  SYNC_IN_VERSION=0
  [ -n "$(session_id)" ] || return 1
  out=$(mktemp); code=$(CLOUD_MAXTIME=20 CLOUD_CONNECT=6 session_call "$out" GET '/api/enana/v1/sync/snapshot?payload=1')
  case $code in 200) ;; 401) rm -f "$out"; return 2 ;; *) rm -f "$out"; return 1 ;; esac
  grep -q '"exists":true' "$out" || { rm -f "$out"; return 4; }
  SYNC_IN_VERSION=$(sed -n 's/.*"version":\([0-9]*\).*/\1/p' "$out" | head -1)
  sed -n 's/.*"payload":"\([A-Za-z0-9+\/=]*\)".*/\1/p' "$out" | head -1 > "$H/sync-incoming.b64"; rm -f "$out"
  chmod 600 "$H/sync-incoming.b64"
  [ -s "$H/sync-incoming.b64" ] || { rm -f "$H/sync-incoming.b64"; return 5; }
  return 0
}
# sync_decrypt <密钥文件>  解密 $H/sync-incoming.b64 -> $H/sync-incoming.json (600)   0 = 成功  3 = 密钥对不上 / 被篡改 (SYNC_CODE=E_SYNC_KEY)  5 = 内容格式不对
sync_decrypt() {
  local rc
  /usr/bin/perl "$LIB/sync.pl" open "$1" "$H/sync-incoming.b64" "$H/sync-incoming.json" 2>/dev/null; rc=$?
  rm -f "$H/sync-incoming.b64"
  case $rc in
    0) /usr/bin/perl "$LIB/snapshot.pl" info "$H/sync-incoming.json" >/dev/null 2>&1 || { rm -f "$H/sync-incoming.json"; return 5; }; return 0 ;;
    3) SYNC_CODE=E_SYNC_KEY; rm -f "$H/sync-incoming.json"; return 3 ;;
    *) rm -f "$H/sync-incoming.json"; return 5 ;;
  esac
}
# sync_open_remote [旧密码]  下载并解密云端快照 -> $H/sync-incoming.json, SYNC_IN_VERSION, SYNC_USED_OLD
#   0 = 成功  1 = 连不上云端  2 = 会话已失效  3 = 密钥对不上 (E_SYNC_KEY)  4 = 云端还没有数据  5 = 内容格式不对  6 = 没有本机密钥 / 旧密码派生失败
sync_open_remote() {
  local old=${1:-} keyf=$H/sync.key rc
  SYNC_USED_OLD=0
  if [ -n "$old" ]; then                                   # 用「旧密码」派生的密钥解密 (密码在网站上或别的电脑上改过)
    [ -n "$(auth_acc_get id)" ] && sync_key_derive "$(auth_acc_get id)" "$old" "$H/sync.key.old" || return 6
    keyf=$H/sync.key.old; SYNC_USED_OLD=1
  else
    sync_have_key || return 6
  fi
  sync_fetch; rc=$?
  [ "$rc" = 0 ] || { rm -f "$H/sync.key.old"; return $rc; }
  sync_decrypt "$keyf"; rc=$?
  rm -f "$H/sync.key.old"; return $rc
}

# 改密码之后: 云端的快照是旧密钥加密的 → 用旧密钥解开, 用新密钥重新加密上传 (best-effort; 失败时用户下次拉取会被要求输入旧密码)
sync_rekey() { # <新密码>
  local id; id=$(auth_acc_get id)
  [ -n "$id" ] || return 0
  if sync_have_key && sync_enabled; then
    cp -p "$H/sync.key" "$H/sync.key.prev"
    sync_key_derive "$id" "$1" || { rm -f "$H/sync.key.prev"; return 1; }
    if sync_fetch && sync_decrypt "$H/sync.key.prev"; then sync_push_core 1 >/dev/null 2>&1 || true; fi
    rm -f "$H/sync.key.prev" "$H/sync-incoming.json" "$H/sync-incoming.b64"
  else
    sync_key_derive "$id" "$1" || true
  fi
  return 0
}

# ---------- 状态 (GET /api/sync 的主体) ----------
sync_state_json() {
  local en=false au=false online=true remote=null dirty=false lv lh nowh lp lq
  sync_enabled && en=true; sync_auto && au=true
  if sync_remote_meta; then
    if [ "$R_EXISTS" = 1 ]; then remote="{\"exists\":true,\"version\":$R_VERSION,\"updated\":$R_UPDATED,\"size\":$R_SIZE,\"device\":\"$(jesc "$R_DEVICE")\"}"; else remote='{"exists":false}'; fi
  else online=false; fi
  lv=$(sync_get BASE_VERSION); lh=$(sync_get SYNCED_HASH); nowh=$(snap_hash)
  if [ -n "$lh" ]; then [ "$lh" != "$nowh" ] && dirty=true; else sync_local_has_data && dirty=true; fi       # 从没同步过: 本机有数据才算「有没上传的改动」
  lp=$(sync_get LAST_PULL); lq=$(sync_get LAST_PUSH)
  printf '"enabled":%s,"auto":%s,"decided":%s,"has_key":%s,"account":"%s","remote":%s,"local":{"version":%s,"dirty":%s},"conflict":%s,"last_pull":%s,"last_push":%s,"online":%s' \
    "$en" "$au" "$([ -n "$(sync_get ENABLED)" ] && echo true || echo false)" "$(sync_have_key && echo true || echo false)" "$(jesc "$(auth_current_email)")" "$remote" "${lv:-0}" "$dirty" \
    "$([ "$(sync_get CONFLICT)" = 1 ] && echo true || echo false)" "${lp:-0}" "${lq:-0}" "$online"
}

# ---------- 推送 (后台任务 sync-push) ----------
# sync_push_core <force 0|1>  成功 0 (BASE_VERSION / SYNCED_HASH 已更新)  1 = 失败 (SYNC_ERR 原因)  2 = 云端有更新的版本 (SYNC_CODE=E_SYNC_CONFLICT, R_VERSION)
sync_push_core() {
  local force=${1:-0} base h plain b64 out code body size ver rc
  SYNC_ERR=''; SYNC_CODE=''
  sync_have_key || { SYNC_ERR="没有同步密钥: 请退出账号后重新登录一次"; SYNC_CODE=E_SYNC_KEY; return 1; }
  base=$(sync_get BASE_VERSION); base=${base:-0}
  sync_remote_forget; sync_remote_meta; rc=$?
  case $rc in 0) ;; 2) SYNC_ERR="登录已失效"; SYNC_CODE=E_AUTH; return 1 ;; *) SYNC_ERR="连不上 enana.cc"; SYNC_CODE=E_ACCOUNT_UNREACHABLE; return 1 ;; esac
  if [ "$R_EXISTS" = 0 ]; then base=0                                            # 云端还没有 (或被清除了): 从头开始
  elif [ "$force" = 1 ]; then base=$R_VERSION                                    # 用本机覆盖云端
  elif [ "$R_VERSION" != "$base" ]; then SYNC_CODE=E_SYNC_CONFLICT; SYNC_ERR="云端有更新的版本"; return 2
  fi
  plain=$(mktemp); b64=$(mktemp)
  h=$(snap_hash)
  snap_build > "$plain" || { rm -f "$plain" "$b64"; SYNC_ERR="配置太大, 无法同步"; return 1; }
  /usr/bin/perl "$LIB/sync.pl" seal "$H/sync.key" "$plain" "$b64" 2>/dev/null || { rm -f "$plain" "$b64"; SYNC_ERR="加密失败"; return 1; }
  rm -f "$plain"
  size=$(wc -c < "$b64" | tr -d ' ')
  [ "$size" -le 1000000 ] || { rm -f "$b64"; SYNC_ERR="加密后的配置超过 1 MB, 无法同步"; return 1; }
  body="{\"base_version\":$base,\"payload\":\"$(cat "$b64")\",\"size\":$size}"; rm -f "$b64"
  out=$(mktemp); code=$(CLOUD_MAXTIME=30 CLOUD_CONNECT=8 session_call "$out" PUT /api/enana/v1/sync/snapshot "$body")
  case $code in
    200)
      ver=$(sed -n 's/.*"version":\([0-9]*\).*/\1/p' "$out" | head -1); rm -f "$out"
      sync_set BASE_VERSION "${ver:-0}"; sync_set SYNCED_HASH "$h"; sync_set LAST_PUSH "$(now)"; sync_set CONFLICT 0; sync_remote_forget; return 0 ;;
    409) R_VERSION=$(sed -n 's/.*"version":\([0-9]*\).*/\1/p' "$out" | head -1); rm -f "$out"; SYNC_CODE=E_SYNC_CONFLICT; SYNC_ERR="云端有更新的版本"; return 2 ;;
    401) rm -f "$out"; SYNC_ERR="登录已失效"; SYNC_CODE=E_AUTH; return 1 ;;
    *)   rm -f "$out"; SYNC_ERR="连不上 enana.cc"; SYNC_CODE=E_ACCOUNT_UNREACHABLE; return 1 ;;
  esac
}
sync_push_job() { # <force 0|1>
  local rc
  job_step 0 10 "生成快照"
  job_step 1 40 "加密"
  job_step 2 70 "上传"
  sync_push_core "${1:-0}"; rc=$?
  case $rc in
    0) oplog "${OP_WHO:-dashboard}" "云端同步: 上传" "" ok; job_ok "已上传 (云端版本 $(sync_get BASE_VERSION))" ;;
    2) oplog "${OP_WHO:-dashboard}" "云端同步: 上传" "冲突" error
       job_write "$JOB_ID" "$JOB_NAME" error 2 100 "云端有更新的版本, 请选择以哪一份为准" "{\"code\":\"E_SYNC_CONFLICT\",\"version\":${R_VERSION:-0}}" ;;
    *) oplog "${OP_WHO:-dashboard}" "云端同步: 上传" "$SYNC_ERR" error
       job_write "$JOB_ID" "$JOB_NAME" error 2 100 "${SYNC_ERR:-上传失败}" "{\"code\":\"${SYNC_CODE:-E_NETWORK}\"}" ;;
  esac
}

# ---------- 拉取 (后台任务 sync-pull; 下载 + 解密在接口里已经做完, 这里只负责「应用」) ----------
txn_sync_apply() { # <replace|merge>  内容来自 $H/sync-incoming.json
  local res
  [ -s "$H/sync-incoming.json" ] || { TXN_ERR="没有可应用的云端配置"; return 1; }
  res=$(snap_apply "$H/sync-incoming.json" "$1" 2>/dev/null) || { TXN_ERR="云端的配置格式不对, 已放弃"; return 1; }
  case $res in *'"prefs.json"'*) prefs_touch || true ;; esac          # 偏好变了: 前端据 prefs_version 重新读取
  load_settings                                                       # 设置 (语言 / 日志) 可能变了
  return 0
}
sync_pull_job() { # <replace|merge> <用旧密码解的 0|1> <云端版本>
  local mode=${1:-replace} used_old=${2:-0} ver=${3:-0} h
  if op_txn "云端同步: 拉取 ($mode)" txn_sync_apply "$mode"; then
    if [ "$mode" = replace ]; then h=$(snap_hash); else h=$(/usr/bin/perl "$LIB/snapshot.pl" hashfile "$H/sync-incoming.json" 2>/dev/null || true); fi
    sync_set BASE_VERSION "$ver"; sync_set SYNCED_HASH "$h"; sync_set LAST_PULL "$(now)"; sync_set CONFLICT 0; sync_remote_forget
    rm -f "$H/sync-incoming.json"
    [ "$used_old" = 1 ] && { sync_push_core 1 >/dev/null 2>&1 || true; }       # 旧密码解开的: 用现在的密钥重新加密上传, 以后就不需要旧密码了
    return 0
  fi
  rm -f "$H/sync-incoming.json"; return 1
}

# ---------- 自动同步 (在 tick 里每 10 分钟检查一次): 本机有改动且云端没变 → 上传; 云端有新版本且本机没改动 → 拉取; 两边都变了 → 标记冲突, 让用户决定 ----------
sync_auto_tick() {
  local last now_ lh nowh base dirty=0 rc
  sync_enabled && sync_auto && sync_have_key && auth_logged_in && [ -n "$(session_id)" ] || return 0
  now_=$(now); last=$(sync_get CHECKED)
  [ -f "$H/.sync-pending" ] && { rm -f "$H/.sync-pending"; last=0; }                  # 刚勾选了「保存到云端」: 不等 10 分钟, 这一分钟就同步
  [ $(( now_ - ${last:-0} )) -ge 600 ] || return 0
  sync_set CHECKED "$now_"; sync_remote_forget
  sync_remote_meta || return 0
  base=$(sync_get BASE_VERSION); base=${base:-0}; lh=$(sync_get SYNCED_HASH); nowh=$(snap_hash)
  if [ -n "$lh" ]; then [ "$lh" != "$nowh" ] && dirty=1; else sync_local_has_data && dirty=1; fi
  if [ "$R_EXISTS" = 1 ] && [ "$R_VERSION" -gt "$base" ]; then
    if [ -n "$lh" ] && [ "$dirty" = 1 ]; then sync_set CONFLICT 1; return 0; fi        # 两边都变了
    if [ -z "$lh" ] && sync_local_has_data; then sync_set CONFLICT 1; return 0; fi     # 这台电脑从没同步过但已经有自己的配置: 不能静默覆盖, 让用户选
    if sync_open_remote; then OP_WHO=terminal sync_pull_job replace 0 "$SYNC_IN_VERSION" >/dev/null 2>&1 || true; fi
  elif [ "$dirty" = 1 ]; then
    OP_WHO=terminal; sync_push_core 0 >/dev/null 2>&1; rc=$?
    [ "$rc" = 2 ] && sync_set CONFLICT 1
  fi
  return 0
}

# ---------- 添加服务器时的「保存到云端」+ 登录后自动同步 ----------
# sync_after_save: 添加 / 导入 / 部署服务器时勾选了「保存到云端」之后调用: 第一次用就自动打开云端同步 (在设置里明确关闭过的不动), 并让这一分钟的 tick 立刻上传。
# 老版本添加的服务器 (清单里没有) 不会被连带上传, 只有这次勾选的才会。
sync_after_save() {
  sync_have_key || return 0
  case "$(sync_get ENABLED)" in
    0) return 0 ;;
    1) ;;
    *) sync_set ENABLED 1; [ -n "$(sync_get AUTO)" ] || sync_set AUTO 1 ;;
  esac
  : > "$H/.sync-pending"
}
# sync_login_auto (登录之后的后台任务): 云端有这个账号保存的服务器就自动取回来 —— 合并进本机, 本机已有的保留, 不覆盖; 在设置里明确关闭过同步的不动。
# 取回来的服务器记入同步清单, 之后和这台电脑的改动一起继续同步 (由 tick 上传)。解不开 (改过密码) / 连不上云端时静默放弃, 由设置里的同步卡片处理。
sync_login_auto() {
  local id
  sync_have_key && auth_logged_in || return 0
  [ "$(sync_get ENABLED)" = 0 ] && return 0
  id=$(auth_acc_get id)
  sync_remote_forget; sync_remote_meta || return 0
  [ "$R_EXISTS" = 1 ] || return 0                                                      # 云端还没有数据: 等第一次勾选「保存到云端」
  if [ "$(sync_get ACCOUNT)" = "$id" ] && [ "$R_VERSION" = "$(sync_get BASE_VERSION)" ] && [ -n "$(sync_get SYNCED_HASH)" ]; then return 0; fi     # 这台电脑已经是最新的
  sync_open_remote || return 0
  case "$(sync_get ENABLED)" in 1) ;; *) sync_set ENABLED 1; [ -n "$(sync_get AUTO)" ] || sync_set AUTO 1 ;; esac
  OP_WHO=terminal sync_pull_job merge 0 "$SYNC_IN_VERSION" || true
}
