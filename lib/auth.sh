# 仪表盘登录 / 注册: 使用 enana.cc 的中心账号 (邮箱 + 密码)。依赖 common.sh (config.sh 的 proxy_set_enabled 在退出账号时用)。
#
# 本机不生成、不保存任何管理员密码。流程:
#   登录 → 向 ACCOUNT_URL (默认 https://api.enana.cc) 的 PocketBase 账号服务校验 → 通过后记为「已登录」, 返回令牌 (= 核心 Clash API 的 secret)。
#   注册 → 本地辅助服务代用户向 enana.cc 创建账号 (邮箱 + 密码, 用本机网络) → 成功后自动登录。
#   任何有效的 enana.cc 账号都可以在这台电脑上登录; 换账号 = 退出账号再登录另一个。
#   在线时每次登录都向服务器校验 (密码在网站上改了立刻生效); 连不上服务器时, 「上一次在这台电脑上登录成功的账号」
#   可用本机缓存的「加盐 PBKDF2 校验值」离线登录 (不保存明文密码); 其它账号必须在线校验。暂不支持找回密码。
#   设备限制: 同一账号同一平台最多同时在线 2 台设备 (云端强制); 超出时登录被拒并列出在线设备, 用户可下线其中一台后自动登录。
#   退出账号 = 自动关闭代理 (全部直连) + 令牌立刻失效 (所有浏览器都要重新登录) + 释放云端的设备名额; 必须重新登录后才能在仪表盘里再次开启代理。
#
#   $H/account.conf  当前登录账号的离线校验信息: id= email= salt= iter= hash= updated=   权限 600 (hash 仅用于离线校验; 退出账号即删除)
#   $H/loggedin      存在 = 当前处于登录状态 (内容: 邮箱 时间戳); 终端的 enana on 靠它判断能不能开启代理
#   $H/secret        32 位十六进制随机串 = sing-box Clash API 的 secret = 仪表盘登录后拿到的令牌 (安装时生成)
#   $H/auth.fail / reg.log  最近失败登录 / 注册尝试的时间戳 (本机限流用)
# 密码通过 stdin 传给 perl / curl (不进命令行与环境变量, `ps` 看不到); 绝不写日志。macOS 自带 /usr/bin/perl (含 Digest::SHA)。

AUTH_ITER=120000
AUTH_LOCK_N=5          # 连续失败多少次锁定
AUTH_LOCK_SEC=300      # 锁定多久 (也是统计窗口)
AUTH_REG_N=8           # 10 分钟内最多尝试注册几次
AUTH_REG_SEC=600

auth_rand_hex() { od -An -N"${1:-16}" -tx1 /dev/urandom | tr -d ' \n'; }
auth_secret() { local s; [ -s "$H/secret" ] && IFS= read -r s < "$H/secret"; printf '%s' "${s:-}"; }
auth_secret_new() { # 生成新的令牌 (调用方随后 apply_config 让核心换上)
  mkdir -p "$H"; auth_rand_hex 16 > "$H/secret.new" && chmod 600 "$H/secret.new" && mv "$H/secret.new" "$H/secret"
}
auth_init() { [ -s "$H/secret" ] || auth_secret_new; }   # 安装时调用: 保证核心的 Clash API 从一开始就有密钥保护

auth_pbkdf2() { # auth_pbkdf2 <salt_hex> <iter>   密码来自 stdin  -> 打印 64 位十六进制
  if [ -x /usr/bin/perl ] && /usr/bin/perl -MDigest::SHA -e 1 2>/dev/null; then
    /usr/bin/perl -MDigest::SHA=hmac_sha256 -e '
      my ($salt_hex, $iter) = @ARGV; local $/; my $pw = <STDIN>; $pw = "" unless defined $pw;
      my $salt = pack("H*", $salt_hex);
      my $u = hmac_sha256($salt . pack("N", 1), $pw); my $t = $u;
      for (my $i = 2; $i <= $iter; $i++) { $u = hmac_sha256($u, $pw); $t ^= $u; }
      print unpack("H*", $t);' "$1" "$2"
  else
    return 1
  fi
}

# ---------- 状态 ----------
auth_logged_in() { [ -f "$H/loggedin" ]; }
auth_current_email() { auth_logged_in && cut -d' ' -f1 "$H/loggedin" 2>/dev/null; }
auth_mark_in() { printf '%s %s\n' "$1" "$(date +%s)" > "$H/loggedin.new" && chmod 600 "$H/loggedin.new" && mv "$H/loggedin.new" "$H/loggedin"; }
auth_cache_has() { [ -s "$H/account.conf" ]; }
auth_acc_get() { sed -n "s/^$1=//p" "$H/account.conf" 2>/dev/null | head -1; }
auth_mask_email() { # name@example.com -> n***@e***.com
  local e=$1 u d dn tld
  case $e in *@*) ;; *) printf '***'; return ;; esac
  u=${e%%@*}; d=${e#*@}
  case $d in *.*) dn=${d%%.*}; tld=${d#*.}; printf '%s***@%s***.%s' "${u:0:1}" "${dn:0:1}" "$tld" ;; *) printf '%s***@%s***' "${u:0:1}" "${d:0:1}" ;; esac
}
auth_hint() { auth_cache_has && auth_mask_email "$(auth_acc_get email)"; }

auth_valid_email() { [ ${#1} -le 254 ] && printf '%s' "$1" | LC_ALL=C grep -Eq "^[A-Za-z0-9._%+'-]{1,64}@[A-Za-z0-9.-]{1,190}\.[A-Za-z]{2,24}$"; }
auth_valid_password() { [ ${#1} -ge 1 ] && [ ${#1} -le 128 ]; }
auth_lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

# ---------- 本机限流 ----------
# 5 分钟内登录失败 5 次 -> 锁定到最早那次失败后的 5 分钟; 10 分钟内注册尝试 8 次 -> 暂停
_auth_wait() { # <文件> <窗口秒> <次数>  打印还需等待的秒数 (0 = 可以尝试)
  local f=$1 w=$2 n=$3 now_ cnt oldest
  now_=$(date +%s); [ -f "$f" ] || { echo 0; return; }
  awk -v n="$now_" -v w="$w" '$1 > n - w' "$f" > "$f.new" 2>/dev/null && mv "$f.new" "$f"
  cnt=$(wc -l < "$f" | tr -d ' ')
  if [ "$cnt" -ge "$n" ]; then oldest=$(sort -n "$f" | head -1); echo $(( oldest + w - now_ )); else echo 0; fi
}
auth_wait_seconds() { _auth_wait "$H/auth.fail" "$AUTH_LOCK_SEC" "$AUTH_LOCK_N"; }
auth_fail_record() { date +%s >> "$H/auth.fail"; chmod 600 "$H/auth.fail" 2>/dev/null || true; }
auth_fail_clear() { rm -f "$H/auth.fail"; }
auth_reg_wait_seconds() { _auth_wait "$H/reg.log" "$AUTH_REG_SEC" "$AUTH_REG_N"; }
auth_reg_record() { date +%s >> "$H/reg.log"; chmod 600 "$H/reg.log" 2>/dev/null || true; }

# ---------- 与云端通信 (先直连; 直连不通且本地代理在运行时再走本地代理; 凭据只通过 stdin 交给 curl; CLOUD_MAXTIME / CLOUD_CONNECT 可缩短超时) ----------
# _cloud_req <方法> <路径> <JSON 正文> <输出文件> [额外请求头…]  -> 打印 HTTP 状态码 (000 = 没连上); 正文通过管道交给 curl (不落盘、不进进程参数)
_cloud_req() {
  local method=$1 path=$2 body=$3 out=$4 code='' route base h; shift 4
  local hdrs=(); for h in "$@"; do hdrs+=(-H "$h"); done
  for base in $ACCOUNT_URL; do
    for route in direct proxy; do
      local args=(-sS -m "${CLOUD_MAXTIME:-15}" --connect-timeout "${CLOUD_CONNECT:-8}" -o "$out" -w '%{http_code}' -X "$method" -H 'Content-Type: application/json' -H 'Accept: application/json' ${hdrs[@]+"${hdrs[@]}"})
      [ -n "$body" ] && args+=(--data-binary @-)
      if [ "$route" = proxy ]; then nc -z 127.0.0.1 "$PORT" 2>/dev/null || continue; args+=(-x "http://127.0.0.1:$PORT"); else args+=(--noproxy '*'); fi
      code=$(printf '%s' "$body" | curl "${args[@]}" "${base%/}$path" 2>/dev/null) || code=000
      case $code in 000|5??|404) continue ;; *) printf '%s' "$code"; return 0 ;; esac    # 网络不通 / 服务异常: 换下一条线路
    done
  done
  printf '%s' "${code:-000}"
}

# auth_remote_login <邮箱> <密码> [要下线的设备 uid]
#   0 = 通过 (设置 ACC_ID ACC_EMAIL SESS_ID CLOUD_TOKEN)   1 = 账号或密码错误   2 = 连不上云端 (或服务异常)   3 = 对方限流 (429)
#   4 = 本平台在线设备已满 (设置 DEV_PLATFORM DEV_LIMIT DEV_LIST: 云端返回的设备数组 JSON)
auth_remote_login() {
  local email=$1 pw=$2 kick=${3:-} tmp code rc=2
  ACC_ID=''; ACC_EMAIL=''; SESS_ID=''; CLOUD_TOKEN=''; DEV_PLATFORM=''; DEV_LIMIT=''; DEV_LIST=''
  tmp=$(mktemp)
  code=$(_cloud_req POST /api/enana/v1/auth/login "{\"email\":\"$(jesc "$email")\",\"password\":\"$(jesc "$pw")\",\"device\":$(device_json),\"kick_device_uid\":\"$(jesc "$kick")\"}" "$tmp")
  case $code in
    200)
      CLOUD_TOKEN=$(sed -n 's/.*"token":"\([^"]*\)".*/\1/p' "$tmp" | head -1)
      SESS_ID=$(sed -n 's/.*"session":{[^}]*"id":"\([A-Za-z0-9_-]*\)".*/\1/p' "$tmp" | head -1)
      ACC_ID=$(sed -n 's/.*"user":{[^}]*"id":"\([A-Za-z0-9_-]*\)".*/\1/p' "$tmp" | head -1)
      ACC_EMAIL=$(sed -n 's/.*"user":{[^}]*"email":"\([^"]*\)".*/\1/p' "$tmp" | head -1); [ -n "$ACC_EMAIL" ] || ACC_EMAIL=$email
      if [ -n "$CLOUD_TOKEN" ] && [ -n "$SESS_ID" ] && [ -n "$ACC_ID" ]; then rc=0; fi ;;
    409)
      DEV_LIST=$(sed -n 's/.*"devices":\(\[.*\]\).*/\1/p' "$tmp" | head -1 | tr -d '\000-\037' | cut -c1-16000)
      DEV_PLATFORM=$(sed -n 's/.*"platform":"\([a-z]*\)"[^[]*$/\1/p' "$tmp" | head -1); DEV_LIMIT=$(sed -n 's/.*"limit":\([0-9]*\).*/\1/p' "$tmp" | head -1)
      [ -n "$DEV_LIST" ] && rc=4 ;;
    400|401|403) rc=1 ;;
    429) rc=3 ;;
  esac
  rm -f "$tmp"
  return $rc
}

# auth_remote_register <邮箱> <密码>
#   0 = 已创建   1 = 被拒 (设置 AUTH_CODE: E_EMAIL_TAKEN / E_WEAK_PASSWORD / E_INVALID)   2 = 连不上云端   3 = 对方限流 (429)
auth_remote_register() {
  local email=$1 pw=$2 tmp code rc=2
  tmp=$(mktemp)
  code=$(_cloud_req POST /api/collections/users/records "{\"email\":\"$(jesc "$email")\",\"password\":\"$(jesc "$pw")\",\"passwordConfirm\":\"$(jesc "$pw")\"}" "$tmp")
  case $code in
    200|201) rc=0 ;;
    400)
      rc=1
      if grep -q '"email":{"code":"validation_not_unique"' "$tmp"; then AUTH_CODE=E_EMAIL_TAKEN
      elif grep -q '"email":{"code":' "$tmp"; then AUTH_CODE=E_INVALID
      elif grep -q '"password":{"code":' "$tmp"; then AUTH_CODE=E_WEAK_PASSWORD
      else AUTH_CODE=E_INVALID; fi ;;
    429) rc=3 ;;
  esac
  rm -f "$tmp"
  return $rc
}

auth_lock() { local i=0; while ! mkdir "$H/.auth.lock" 2>/dev/null; do
    if [ -n "$(find "$H/.auth.lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then rmdir "$H/.auth.lock" 2>/dev/null || true; continue; fi
    i=$((i+1)); [ "$i" -gt 40 ] && return 1; sleep 0.25; done; }
auth_unlock() { rmdir "$H/.auth.lock" 2>/dev/null || true; }

auth_cache_write() { # <id> <email> <密码>  记录「上一次登录成功的账号」与离线校验值
  local salt hash
  salt=$(auth_rand_hex 16)
  hash=$(printf '%s' "$3" | auth_pbkdf2 "$salt" "$AUTH_ITER") && [ ${#hash} -eq 64 ] || return 1
  printf 'id=%s\nemail=%s\nsalt=%s\niter=%s\nhash=%s\nupdated=%s\n' "$1" "$(auth_lower "$2")" "$salt" "$AUTH_ITER" "$hash" "$(date +%s)" > "$H/account.conf.new" \
    && chmod 600 "$H/account.conf.new" && mv "$H/account.conf.new" "$H/account.conf"
}
auth_offline_verify() { # <邮箱> <密码>  (0 = 与本机缓存一致; 只对「上一次登录成功的账号」有效)
  local salt iter want got
  auth_cache_has || return 1
  [ "$(auth_lower "$1")" = "$(auth_acc_get email)" ] || { printf '%s' "$2" | auth_pbkdf2 00 1000 >/dev/null 2>&1; return 1; }   # 邮箱不对也做一次计算, 耗时不泄露信息
  salt=$(auth_acc_get salt); iter=$(auth_acc_get iter); want=$(auth_acc_get hash)
  got=$(printf '%s' "$2" | auth_pbkdf2 "$salt" "${iter:-$AUTH_ITER}") || return 1
  [ -n "$got" ] && [ "$got" = "$want" ]
}

# auth_login <邮箱> <密码> [要下线的设备 uid]
#   成功: 返回 0, 设置 AUTH_VIA=online|offline AUTH_EMAIL
#   失败: 返回 1, 设置 AUTH_CODE (E_INVALID E_LOCKED E_BAD_CREDENTIALS E_DEVICE_LIMIT E_ACCOUNT_UNREACHABLE E_BUSY) AUTH_WAIT (秒, E_LOCKED 时)
#         E_DEVICE_LIMIT 时另设 DEV_PLATFORM DEV_LIMIT DEV_LIST (云端返回的在线设备)
auth_login() {
  local email=$1 pw=$2 kick=${3:-} w rc
  AUTH_CODE=''; AUTH_WAIT=0; AUTH_VIA=''; AUTH_EMAIL=''
  email=$(auth_lower "$email")
  if ! auth_valid_email "$email" || ! auth_valid_password "$pw"; then AUTH_CODE=E_INVALID; return 1; fi
  w=$(auth_wait_seconds); if [ "${w:-0}" -gt 0 ]; then AUTH_CODE=E_LOCKED; AUTH_WAIT=$w; return 1; fi
  auth_init
  auth_remote_login "$email" "$pw" "$kick"; rc=$?
  case $rc in
    0) auth_lock || { AUTH_CODE=E_BUSY; return 1; }
       auth_cache_write "$ACC_ID" "$ACC_EMAIL" "$pw" || { auth_unlock; AUTH_CODE=E_INVALID; return 1; }   # 记住当前账号 + 离线校验值
       session_save "$CLOUD_TOKEN" "$SESS_ID"
       rm -f "$H/notice" "$H/hb.fail"
       auth_mark_in "$(auth_lower "$ACC_EMAIL")"; auth_unlock
       AUTH_VIA=online; AUTH_EMAIL=$ACC_EMAIL; auth_fail_clear
       sync_on_login "$ACC_ID" "$pw"                                     # 端到端同步的密钥由登录密码派生 (只在本机, 退出账号即删除)
       return 0 ;;
    1) auth_fail_record; AUTH_CODE=E_BAD_CREDENTIALS; return 1 ;;
    3) AUTH_CODE=E_LOCKED; AUTH_WAIT=20; return 1 ;;
    4) AUTH_CODE=E_DEVICE_LIMIT; return 1 ;;
    *) # 连不上云端: 只有「当前仍处于登录状态的账号」(换了浏览器 / 令牌丢了) 能用本机缓存离线登录; 离线登录不会创建云端会话
       if auth_logged_in && auth_offline_verify "$email" "$pw"; then
         AUTH_VIA=offline; AUTH_EMAIL=$(auth_acc_get email); auth_fail_clear
         sync_on_login "$(auth_acc_get id)" "$pw"; return 0
       fi
       if auth_logged_in && [ "$email" = "$(auth_acc_get email)" ]; then auth_fail_record; AUTH_CODE=E_BAD_CREDENTIALS; return 1; fi
       AUTH_CODE=E_ACCOUNT_UNREACHABLE; return 1 ;;
  esac
}

# auth_register <邮箱> <密码>  成功后自动登录; 返回 0 / 1, 设置同 auth_login (+ E_EMAIL_TAKEN E_WEAK_PASSWORD)
auth_register() {
  local email=$1 pw=$2 w rc
  AUTH_CODE=''; AUTH_WAIT=0; AUTH_VIA=''; AUTH_EMAIL=''
  email=$(auth_lower "$email")
  auth_valid_email "$email" || { AUTH_CODE=E_INVALID; return 1; }
  [ ${#pw} -ge 8 ] && [ ${#pw} -le 128 ] || { AUTH_CODE=E_WEAK_PASSWORD; return 1; }
  w=$(auth_reg_wait_seconds); if [ "${w:-0}" -gt 0 ]; then AUTH_CODE=E_LOCKED; AUTH_WAIT=$w; return 1; fi
  auth_reg_record
  auth_remote_register "$email" "$pw"; rc=$?
  case $rc in
    0) auth_login "$email" "$pw"; return $? ;;                 # 创建成功 -> 立刻用同一组凭据登录 (得到令牌 + 会话, 记住账号)
    1) return 1 ;;                                              # AUTH_CODE 已设置
    3) AUTH_CODE=E_LOCKED; AUTH_WAIT=30; return 1 ;;
    *) AUTH_CODE=E_ACCOUNT_UNREACHABLE; return 1 ;;
  esac
}

# 本机退出登录 (不通知云端; 云端已经撤销了会话时用): 关闭代理 + 令牌轮换 + 清除登录状态 / 会话 / 离线缓存 / 提示
auth_logout_local() {
  proxy_set_enabled 0
  rm -f "$H/loggedin" "$H/auth.fail" "$H/account.conf" "$H/notice" "$H/sudo.tokens"
  sync_on_logout
  session_clear
  auth_secret_new
}
# 用户主动退出账号: 通知云端释放设备名额 (后台) + 本机退出登录 (调用方随后 apply_config 让核心换上新令牌, 期间核心已是全部直连)
auth_logout() { session_logout_remote; auth_logout_local; }

# ---------- 敏感操作需要再次输入登录密码 (step-up) ----------
# 已经登录的情况下, 删除服务器 / 查看凭据 / 导出备份 / 清日志 / 下线设备 … 还要再验证一次当前账号的密码 (防止别人趁你离开时点按钮或看到凭据)。
# 流程: POST /api/auth/verify 密码正确 → 发一个 5 分钟有效的 sudo 令牌 → 敏感接口要带 X-Enana-Sudo 头 (api.sh 里有一张白名单)。
# 密码在本机用「加盐 PBKDF2 校验值」验证 (登录时在线校验过, 不需要联网); 失败与登录共用同一个锁定计数 (连续错 5 次锁 5 分钟)。令牌只存哈希, 退出账号即清空。
SUDO_TTL=300
auth_sudo_hash() { printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1; }
auth_sudo_issue() { # 打印新令牌
  local tok n_; tok=$(auth_rand_hex 16); n_=$(date +%s)
  { awk -v n="$n_" '$2 > n' "$H/sudo.tokens" 2>/dev/null | tail -n 19; printf '%s %s\n' "$(auth_sudo_hash "$tok")" "$((n_ + SUDO_TTL))"; } > "$H/sudo.tokens.new" \
    && chmod 600 "$H/sudo.tokens.new" && mv "$H/sudo.tokens.new" "$H/sudo.tokens"
  printf '%s' "$tok"
}
auth_sudo_ok() { # <令牌>  0 = 有效 (没过期)
  case $1 in ''|*[!0-9a-f]*) return 1 ;; esac
  [ ${#1} -eq 32 ] || return 1
  awk -v h="$(auth_sudo_hash "$1")" -v n="$(date +%s)" '$1 == h && $2 > n { f = 1 } END { exit f ? 0 : 1 }' "$H/sudo.tokens" 2>/dev/null
}
# auth_check_password <密码>  与「当前登录账号」的本机校验值比对  0 = 正确   1 = 失败, AUTH_CODE: E_AUTH E_INVALID E_LOCKED(+AUTH_WAIT) E_BAD_CREDENTIALS   (失败计数和登录共用)
auth_check_password() {
  local w
  AUTH_CODE=''; AUTH_WAIT=0
  auth_logged_in || { AUTH_CODE=E_AUTH; return 1; }
  auth_valid_password "$1" || { AUTH_CODE=E_INVALID; return 1; }
  w=$(auth_wait_seconds); if [ "${w:-0}" -gt 0 ]; then AUTH_CODE=E_LOCKED; AUTH_WAIT=$w; return 1; fi
  if auth_offline_verify "$(auth_acc_get email)" "$1"; then auth_fail_clear; return 0; fi
  auth_fail_record; AUTH_CODE=E_BAD_CREDENTIALS; return 1
}
# auth_step_up <密码>  密码正确时发一个 5 分钟有效的 sudo 令牌 (SUDO_TOKEN); 失败同 auth_check_password
auth_step_up() { SUDO_TOKEN=''; auth_check_password "$1" || return 1; SUDO_TOKEN=$(auth_sudo_issue); return 0; }

# ---------- 在本机修改账号密码 ----------
# auth_change_password <旧密码> <新密码>   向云端提交 (必须在线, 有云端会话): 云端校验旧密码, 当前设备保持登录 (拿到新令牌), 账号下其它设备全部下线。
#   0 = 已修改 (本机刷新令牌和离线校验值)   1 = 失败, AUTH_CODE: E_AUTH E_INVALID E_WEAK_PASSWORD E_LOCKED(+AUTH_WAIT) E_BAD_CREDENTIALS E_ACCOUNT_UNREACHABLE
auth_change_password() {
  local old=$1 new=$2 w tmp code tok sid
  AUTH_CODE=''; AUTH_WAIT=0
  auth_logged_in || { AUTH_CODE=E_AUTH; return 1; }
  auth_valid_password "$old" || { AUTH_CODE=E_INVALID; return 1; }
  [ ${#new} -ge 8 ] && [ ${#new} -le 71 ] && [ "$new" != "$old" ] || { AUTH_CODE=E_WEAK_PASSWORD; return 1; }
  w=$(auth_wait_seconds); if [ "${w:-0}" -gt 0 ]; then AUTH_CODE=E_LOCKED; AUTH_WAIT=$w; return 1; fi
  [ -n "$(session_id)" ] || { AUTH_CODE=E_ACCOUNT_UNREACHABLE; return 1; }                  # 离线登录时没有云端会话: 改密码必须在线
  tmp=$(mktemp)
  code=$(session_call "$tmp" POST /api/enana/v1/account/password "{\"old_password\":\"$(jesc "$old")\",\"new_password\":\"$(jesc "$new")\"}")
  case $code in
    200)
      tok=$(sed -n 's/.*"token":"\([^"]*\)".*/\1/p' "$tmp" | head -1); sid=$(sed -n 's/.*"session":{[^}]*"id":"\([A-Za-z0-9_-]*\)".*/\1/p' "$tmp" | head -1)
      rm -f "$tmp"
      [ -n "$tok" ] && session_save "$tok" "$sid"
      auth_cache_write "$(auth_acc_get id)" "$(auth_acc_get email)" "$new" || true         # 刷新离线校验值
      sync_rekey "$new" || true                                                              # 同步密钥由密码派生: 换新密钥, 并把云端的快照重新加密
      rm -f "$H/sudo.tokens"; auth_fail_clear; return 0 ;;
    400)
      if grep -q '"code":"weak_password"' "$tmp"; then AUTH_CODE=E_WEAK_PASSWORD; else auth_fail_record; AUTH_CODE=E_BAD_CREDENTIALS; fi
      rm -f "$tmp"; return 1 ;;
    401)    # 会话已经被云端撤销: 让心跳来收尾 (本机退出登录并关闭代理), 这里只告诉前端登录已失效
      rm -f "$tmp"; session_heartbeat >/dev/null 2>&1 || true; AUTH_CODE=E_AUTH; return 1 ;;
    429) rm -f "$tmp"; AUTH_CODE=E_LOCKED; AUTH_WAIT=30; return 1 ;;
    *)   rm -f "$tmp"; AUTH_CODE=E_ACCOUNT_UNREACHABLE; return 1 ;;
  esac
}

auth_status_json() { # GET /api/auth/status 的主体
  local hint='' offline=false w; w=$(auth_wait_seconds)
  if auth_cache_has; then hint=$(auth_hint); [ -n "$(auth_acc_get hash)" ] && offline=true; fi
  printf '"required":true,"account_hint":"%s","offline_ok":%s,"notice":"%s","account_url":"%s","wait":%s' \
    "$(jesc "$hint")" "$offline" "$(jesc "$(session_notice)")" "$(jesc "${ACCOUNT_SITE%/}")" "${w:-0}"
}
