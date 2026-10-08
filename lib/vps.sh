# 添加自己的服务器 (SSH 一键部署): 用户填「IP / 端口 / 用户名 + 密码或私钥」, 本机通过 SSH 连上去, 检测系统与依赖 → (弹窗确认) → 安装依赖与服务端 →
# 生成节点 → 识别服务器的全部出口 IP → 把节点加到本机。依赖 common.sh servers.sh ops.sh jobs.sh config.sh speed.sh。接口约定见 docs/API.md。
#
# 公开仓库里只有这个「SSH 编排」(连接 / 校验 / 解析输出 / 保存); 真正在服务器上执行的部署脚本 (协议选择、依赖列表、服务端版本与校验值、配置生成) 属于
# enana 云端的签名内容: 登录后随「云端内容」下发到 $H/cloud/content/vps/ (lib.sh probe.sh provision.sh redetect.sh), 没有登录就不能用。
#
# 安全约定:
#   - SSH 密码 / 私钥 / 口令 / sudo 密码只在请求体里临时传给本地辅助服务, 辅助服务把它们写进一个 600 权限的临时文件交给后台任务,
#     任务一开始就读走并删除; 任务期间只存在于一个 700 权限的临时目录 (askpass 脚本读取), 任务结束立即删除。
#     绝不放进命令行参数 / 环境变量 / 日志 / 任务结果 / 同步快照, 也不返回给前端。
#   - 主机指纹: 第一次探测给用户看 (SHA256:…), 之后的请求带 hostkey 做固定校验 (ssh-keyscan 取到的密钥指纹必须一致, 再用 StrictHostKeyChecking=yes 连接)。
#   - 远端脚本经 ssh 标准输入交给 `bash -c 'eval "$(cat)"'` 执行 (先读完再执行, 命令读标准输入时吃不到脚本), 服务器上不留脚本文件。
#   - 远端脚本的输出只认 ##step / ##kv / ##ip / ##action / ##node / ##warn / ##err 这几种行 (见云端 vps/lib.sh), 其它一律丢弃, 不写日志。
#
#   $H/vps.jsonl   已部署的服务器记录 (每行一个 JSON: id name host ssh_port user os hostkey ips nodes updated), 不含任何密码 / 私钥

VPS_FILE=${VPS_FILE:-$H/vps.jsonl}
VPS_ERR=''; VPS_CODE=''
VPS_TIMEOUT=900          # 一次部署最长 15 分钟
VPS_PROBE_TIMEOUT=45     # 只读检测每次最多 45 秒, 最多三次尝试
VPS_HOSTKEY_TIMEOUT=20

vps_cancel_requested() { [ "${JOB_NAME:-}" = vps-probe ] && [ -f "$H/jobs/${JOB_ID:-}.cancel" ]; }
vps_check_cancel() {
  if vps_cancel_requested; then VPS_CODE=E_CANCELLED; VPS_ERR="已取消服务器检测"; return 1; fi
  return 0
}
# Terminate only the child tree started by this task, including ssh/keyscan.
vps_stop_child() {
  local p=$1 child
  for child in $(pgrep -P "$p" 2>/dev/null); do vps_stop_child "$child"; done
  kill "$p" 2>/dev/null || true
}
vps_probe_progress() { # stage, step, percent, start time, timeout
  local stage=$1 idx=$2 pct=$3 elapsed=$(( $(now) - $4 )) limit=$5 label
  case $stage in
    hostkey) label="正在读取 SSH 主机指纹" ;;
    ssh) label="正在建立 SSH 连接并验证登录" ;;
    inspect) label="SSH 已连接, 正在读取系统和网络信息" ;;
    retry) label="连接暂时失败, 准备重试" ;;
  esac
  job_write "$JOB_ID" "$JOB_NAME" running "$idx" "$pct" "$(_t "$label") · ${VPS_ATTEMPT:-1}/${VPS_ATTEMPTS:-3} · $elapsed/$limit s" \
    "{\"connection\":{\"stage\":\"$stage\",\"attempt\":${VPS_ATTEMPT:-1},\"max_attempts\":${VPS_ATTEMPTS:-3},\"elapsed\":$elapsed,\"timeout\":$limit}}"
}

vps_ssh_bin() { printf '%s' "${ENANA_SSH:-ssh}"; }
vps_playbook_ok() { [ -s "$(content_file vps/lib.sh)" ] && [ -s "$(content_file vps/probe.sh)" ] && [ -s "$(content_file vps/provision.sh)" ] && [ -s "$(content_file vps/redetect.sh)" ]; }

# ---------- 参数校验 (后台任务读到凭据后再校验一遍; 接口先校验一遍给出立即的原因) ----------
vps_host_ok() { [ ${#1} -le 253 ] && printf '%s\n' "$1" | LC_ALL=C grep -Eq '^([A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?|[0-9A-Fa-f:]{2,45})$'; }
vps_user_ok() { printf '%s\n' "$1" | LC_ALL=C grep -Eq '^[A-Za-z_][A-Za-z0-9_.-]{0,31}$'; }
vps_port_ok() { case $1 in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
vps_hostkey_ok() { printf '%s\n' "$1" | LC_ALL=C grep -Eq '^SHA256:[A-Za-z0-9+/]{43}$'; }
vps_name_ok() { printf '%s\n' "$1" | LC_ALL=C grep -Eq '^[A-Za-z0-9._-]{1,40}$'; }
# vps_cred_check <host> <port> <user> <mode> <password> <key> <passphrase> <sudo_password> <hostkey>  -> 0 / 1 (VPS_ERR)
vps_cred_check() {
  VPS_ERR=''
  vps_host_ok "$1" || { VPS_ERR="服务器地址不正确 (IP 或域名)"; return 1; }
  vps_port_ok "$2" || { VPS_ERR="SSH 端口不正确 (1-65535)"; return 1; }
  vps_user_ok "$3" || { VPS_ERR="用户名不正确"; return 1; }
  case $4 in
    password) [ -n "$5" ] || { VPS_ERR="请输入 SSH 密码"; return 1; } ;;
    key)      case $6 in *PRIVATE\ KEY*) ;; *) VPS_ERR="私钥格式不对 (需要完整的 PEM / OpenSSH 私钥文本)"; return 1 ;; esac
              [ ${#6} -le 16384 ] || { VPS_ERR="私钥太大"; return 1; } ;;
    *) VPS_ERR="登录方式不正确"; return 1 ;;
  esac
  case "$5$7$8" in *$'\n'*|*$'\r'*) VPS_ERR="密码 / 口令里不能有换行"; return 1 ;; esac
  [ ${#5} -le 256 ] && [ ${#7} -le 256 ] && [ ${#8} -le 256 ] || { VPS_ERR="密码 / 口令太长"; return 1; }
  [ -z "$9" ] || vps_hostkey_ok "$9" || { VPS_ERR="主机指纹格式不对"; return 1; }
  return 0
}

# ---------- 凭据文件 (接口 → 后台任务) ----------
# vps_cred_write <文件> <host> <port> <user> <mode> <password> <key> <passphrase> <sudo_password> <hostkey> <name> <role> <install_deps> <id> <confirm_hostkey> [save]
#   每个字段一行 "键=值" (值里的换行已在校验里排除; 私钥里有换行 → 存成 \n 转义, 读取时还原)
vps_cred_write() {
  local f=$1; shift
  ( umask 077; {
    printf 'host=%s\nport=%s\nuser=%s\nmode=%s\npassword=%s\n' "$1" "$2" "$3" "$4" "$5"
    printf 'key=%s\n' "$(printf '%s' "$6" | awk 'BEGIN { ORS = "" } { gsub(/\r/, ""); print (NR > 1 ? "\\n" : "") $0 }')"
    printf 'passphrase=%s\nsudo_password=%s\nhostkey=%s\nname=%s\nrole=%s\ninstall_deps=%s\nid=%s\nconfirm_hostkey=%s\nsave=%s\n' "$7" "$8" "$9" "${10}" "${11}" "${12}" "${13}" "${14}" "${15:-}"
  } > "$f" )
}
# vps_cred_load <文件>  读出并立刻删除; 设置 V_HOST V_PORT V_USER V_MODE V_PASSWORD V_KEY V_PASSPHRASE V_SUDOPW V_HOSTKEY V_NAME V_ROLE V_DEPS V_ID V_CONFIRM
vps_cred_load() {
  local f=$1 k v
  V_HOST=''; V_PORT=22; V_USER=root; V_MODE=''; V_PASSWORD=''; V_KEY=''; V_PASSPHRASE=''; V_SUDOPW=''; V_HOSTKEY=''; V_NAME=''; V_ROLE=pin; V_DEPS=0; V_ID=''; V_CONFIRM=0; V_SAVE=''
  [ -f "$f" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    k=${line%%=*}; v=${line#*=}
    case $k in
      host) V_HOST=$v ;; port) V_PORT=$v ;; user) V_USER=$v ;; mode) V_MODE=$v ;; password) V_PASSWORD=$v ;;
      key) V_KEY=$(printf '%b' "$v") ;; passphrase) V_PASSPHRASE=$v ;; sudo_password) V_SUDOPW=$v ;; hostkey) V_HOSTKEY=$v ;;
      name) V_NAME=$v ;; role) V_ROLE=$v ;; install_deps) V_DEPS=$v ;; id) V_ID=$v ;; confirm_hostkey) V_CONFIRM=$v ;; save) V_SAVE=$v ;;
    esac
  done < "$f"
  rm -f "$f"
  return 0
}

# ---------- SSH 通道 ----------
# vps_prepare  依据 V_* 在私有临时目录 $VD 里准备 askpass / 私钥 / known_hosts; 之后用 vps_ssh_opts 取得 ssh 参数
vps_prepare() {
  VD=$(mktemp -d "${TMPDIR:-/tmp}/enana-vps.XXXXXX") || return 1
  chmod 700 "$VD"
  : > "$VD/known_hosts"; : > "$VD/err"; : > "$VD/out"; : > "$VD/kv"
  ( umask 077
    printf '%s' "$V_PASSWORD" > "$VD/pass"; printf '%s' "$V_PASSPHRASE" > "$VD/passphrase"
    if [ "$V_MODE" = key ]; then printf '%s\n' "$V_KEY" > "$VD/key"; fi )
  cat > "$VD/askpass" <<'EOF'
#!/bin/sh
d=$(dirname "$0")
case "$1" in *assphrase*) cat "$d/passphrase" ;; *) cat "$d/pass" ;; esac
EOF
  chmod 700 "$VD/askpass"
}
vps_cleanup() {
  [ -z "${VPS_LOCK_ID:-}" ] || { vps_pending_unlock "$VPS_LOCK_ID"; VPS_LOCK_ID=''; }
  [ -n "${VPS_CHILD_PID:-}" ] && { vps_stop_child "$VPS_CHILD_PID"; wait "$VPS_CHILD_PID" 2>/dev/null || true; }
  [ -n "${VD:-}" ] && rm -rf "$VD"
  [ -n "${JOB_ID:-}" ] && rm -f "$H/jobs/$JOB_ID.cred"
  VD=''; VPS_CHILD_PID=''; return 0
}

# vps_fingerprints <host> <port>  用 ssh-keyscan 取服务器公开的主机密钥 -> 每行 "指纹<TAB>类型<TAB>known_hosts 行"
vps_fingerprints() {
  local host=$1 port=$2 f line fp
  f=$(mktemp "${TMPDIR:-/tmp}/enana-ks.XXXXXX")
  ${ENANA_SSH_KEYSCAN:-ssh-keyscan} -T 8 -p "$port" -t ed25519,ecdsa,rsa "$host" 2>/dev/null | grep -v '^#' > "$f" || true
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s\n' "$line" > "$f.one"
    fp=$(ssh-keygen -lf "$f.one" -E sha256 2>/dev/null | awk '{ print $2 }')
    [ -n "$fp" ] && printf '%s\t%s\t%s\n' "$fp" "$(printf '%s' "$line" | awk '{ print $2 }')" "$line"
  done < "$f"
  rm -f "$f" "$f.one"
}

# vps_hostkey_setup  设置 SSH_HK_OPTS (固定校验 / 首次信任) 与 VPS_HOSTKEY (实际使用的指纹)
#   返回: 0 = 可以连  1 = 连不上 (没拿到主机密钥)  2 = 指纹与固定的不一致
vps_hostkey_setup() {
  local fps pick start
  vps_fingerprints "$V_HOST" "$V_PORT" > "$VD/fingerprints" & VPS_CHILD_PID=$!
  start=$(now)
  while kill -0 "$VPS_CHILD_PID" 2>/dev/null; do
    if ! vps_check_cancel; then vps_stop_child "$VPS_CHILD_PID"; wait "$VPS_CHILD_PID" 2>/dev/null; VPS_CHILD_PID=''; return 3; fi
    if [ $(( $(now) - start )) -ge "$VPS_HOSTKEY_TIMEOUT" ]; then vps_stop_child "$VPS_CHILD_PID"; wait "$VPS_CHILD_PID" 2>/dev/null; VPS_CHILD_PID=''; VPS_HOSTKEY=''; return 1; fi
    [ "${JOB_NAME:-}" != vps-probe ] || vps_probe_progress hostkey 0 5 "$start" "$VPS_HOSTKEY_TIMEOUT"
    sleep 0.5
  done
  wait "$VPS_CHILD_PID" 2>/dev/null || true; VPS_CHILD_PID=''
  vps_check_cancel || return 3
  fps=$(cat "$VD/fingerprints")
  [ -n "$fps" ] || { VPS_HOSTKEY=''; SSH_HK_OPTS=(-o StrictHostKeyChecking=no -o "UserKnownHostsFile=$VD/known_hosts"); return 1; }
  if [ -n "$V_HOSTKEY" ]; then
    pick=$(printf '%s\n' "$fps" | awk -F'\t' -v h="$V_HOSTKEY" '$1 == h { print; exit }')
    [ -n "$pick" ] || { VPS_HOSTKEY=$(printf '%s\n' "$fps" | head -1 | cut -f1); return 2; }
    printf '%s\n' "$pick" | cut -f3 > "$VD/known_hosts"
    VPS_HOSTKEY=$V_HOSTKEY; SSH_HK_OPTS=(-o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$VD/known_hosts" -o "HostKeyAlgorithms=$(printf '%s' "$pick" | cut -f2)")
  else
    pick=$(printf '%s\n' "$fps" | awk -F'\t' '$2 == "ssh-ed25519" { print; exit }'); [ -n "$pick" ] || pick=$(printf '%s\n' "$fps" | head -1)
    printf '%s\n' "$pick" | cut -f3 > "$VD/known_hosts"     # 首次信任: 以扫描到的密钥为准 (和之后固定校验用的是同一把)
    VPS_HOSTKEY=$(printf '%s' "$pick" | cut -f1); SSH_HK_OPTS=(-o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$VD/known_hosts" -o "HostKeyAlgorithms=$(printf '%s' "$pick" | cut -f2)")
  fi
  return 0
}

# vps_ssh <远程命令> < 标准输入  -> 输出到 $VD/out, 错误到 $VD/err; 返回 ssh 的退出码
vps_ssh() {
  local cmd=$1 opts=()
  opts=(-p "$V_PORT" -T -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o LogLevel=ERROR -o GlobalKnownHostsFile=/dev/null
        -o ForwardAgent=no -o ForwardX11=no -o PermitLocalCommand=no -o ControlMaster=no -o NumberOfPasswordPrompts=1 ${SSH_HK_OPTS[@]+"${SSH_HK_OPTS[@]}"})
  if [ "$V_MODE" = key ]; then opts+=(-i "$VD/key" -o IdentitiesOnly=yes -o PreferredAuthentications=publickey -o PasswordAuthentication=no)
  else opts+=(-o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no); fi
  SSH_ASKPASS="$VD/askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=${DISPLAY:-:0} "$(vps_ssh_bin)" "${opts[@]}" "$V_USER@$V_HOST" "$cmd" > "$VD/out" 2> "$VD/err"
}

# vps_classify_ssh <退出码>  把 ssh 自身的失败翻译成错误码 (VPS_CODE / VPS_ERR)
vps_classify_ssh() {
  local e; e=$(cat "$VD/err" 2>/dev/null)
  case $e in
    *'HOST IDENTIFICATION HAS CHANGED'*|*'Host key verification failed'*) VPS_CODE=E_SSH_HOSTKEY; VPS_ERR="服务器的主机指纹与之前固定的不一致 (可能被中间人攻击, 或服务器重装过系统)" ;;
    *'incorrect passphrase'*|*'invalid format'*|*'error in libcrypto'*|*'Load key'*|*'bad passphrase'*) VPS_CODE=E_SSH_KEY; VPS_ERR="私钥格式不对, 或私钥口令不对" ;;
    *'Permission denied'*|*'Too many authentication failures'*|*'No more authentication methods'*) VPS_CODE=E_SSH_AUTH; VPS_ERR="用户名、密码或私钥不对 (连得上服务器, 但登录被拒绝)" ;;
    *'sudo: '*|*'Sorry, try again'*|*'incorrect password'*|*'is not in the sudoers'*) VPS_CODE=E_VPS_PRIVILEGE; VPS_ERR="sudo 没有通过: sudo 密码不对, 或这个用户没有 sudo 权限" ;;
    *'Connection refused'*|*'timed out'*|*'No route to host'*|*'Network is unreachable'*|*'Could not resolve hostname'*|*'Connection reset'*|*'Connection closed'*|*'kex_exchange_identification'*)
      VPS_CODE=E_SSH_UNREACHABLE; VPS_ERR="连不上 $V_HOST:$V_PORT (SSH): 地址或端口不对, 服务器没开机, 或防火墙挡住了 SSH 端口" ;;
    *) VPS_CODE=E_SSH_UNREACHABLE; VPS_ERR="SSH 连接失败 (退出码 $1)" ;;
  esac
}

# vps_run <probe|provision|redetect> <root|user|sudo_nopass|sudo_password> [远端脚本参数…]  -> 0 = 脚本成功结束  1 = 失败 (VPS_CODE VPS_ERR 已设置)
#   远端脚本 = 云端的 vps/lib.sh + vps/<名称>.sh; 输出在 $VD/out (后台运行, 边跑边由 vps_watch 推进进度)
vps_run() {
  local what=$1 priv=$2 a cmd='' q rc pid t0 limit=$VPS_TIMEOUT stage
  shift 2
  for a in "$@"; do printf '%s\n' "$a" | LC_ALL=C grep -Eq '^[A-Za-z0-9._=-]{1,64}$' || { VPS_CODE=E_INVALID; VPS_ERR="参数不合法"; return 1; }; cmd="$cmd '$a'"; done
  q="bash -c 'eval \"\$(cat)\"' enana-vps$cmd"
  case $priv in sudo_nopass) q="sudo -n $q" ;; sudo_password) q="sudo -S -p '' $q" ;; esac
  { [ "$priv" = sudo_password ] && printf '%s\n' "${V_SUDOPW:-$V_PASSWORD}"; cat "$(content_file vps/lib.sh)" "$(content_file vps/$what.sh)"; } | vps_ssh "$q" &
  pid=$!; t0=$(now)
  VPS_CHILD_PID=$pid
  [ "${JOB_NAME:-}" != vps-probe ] || limit=$VPS_PROBE_TIMEOUT
  while kill -0 "$pid" 2>/dev/null; do
    if ! vps_check_cancel; then vps_stop_child "$pid"; wait "$pid" 2>/dev/null; VPS_CHILD_PID=''; return 1; fi
    vps_watch
    if [ $(( $(now) - t0 )) -ge "$limit" ]; then
      vps_stop_child "$pid"; wait "$pid" 2>/dev/null; VPS_CHILD_PID=''; VPS_CODE=E_SSH_UNREACHABLE
      if [ "${JOB_NAME:-}" = vps-probe ]; then VPS_ERR="服务器检测超时, 已停止本次连接"; else VPS_ERR="部署超时 (超过 $((VPS_TIMEOUT / 60)) 分钟), 已中止"; fi
      return 1
    fi
    if [ "${JOB_NAME:-}" = vps-probe ]; then
      if grep -q '^##' "$VD/out" 2>/dev/null; then stage=inspect; vps_probe_progress "$stage" 1 40 "$t0" "$limit"
      else stage=ssh; vps_probe_progress "$stage" 0 15 "$t0" "$limit"; fi
    fi
    sleep 0.5
  done
  wait "$pid"; rc=$?; VPS_CHILD_PID=''
  vps_check_cancel || return 1
  vps_watch
  vps_parse_out
  if [ -n "$(vps_kv_all err)" ]; then vps_remote_error; return 1; fi
  if [ "$rc" = 255 ] || { [ "$rc" != 0 ] && ! grep -q '^##' "$VD/out" 2>/dev/null; }; then vps_classify_ssh "$rc"; return 1; fi
  if [ "$rc" != 0 ]; then VPS_CODE=E_VPS_VERIFY; VPS_ERR="部署脚本异常结束 (退出码 $rc)"; return 1; fi
  return 0
}

# ---------- 解析远端输出 ----------
VPS_SEEN=0
vps_watch() { # 读到新的 ##step 行就推进进度 (VPS_STEP_MAP: 远端阶段号 -> 任务步骤序号, 由各任务设置)
  local n s
  [ "${VPS_NO_PROGRESS:-0}" != 1 ] || return 0
  n=$(grep -c '^##step ' "$VD/out" 2>/dev/null || true)
  [ "${n:-0}" -gt "$VPS_SEEN" ] || return 0
  VPS_SEEN=$n
  s=$(grep '^##step ' "$VD/out" | tail -1 | awk '{ print $2 }')
  [ -n "$s" ] && vps_progress "$s"
  return 0
}
vps_progress() { :; }                     # 各任务重新定义: 把远端阶段号映射成 job_step
vps_parse_out() { # 把 $VD/out 里认得的行整理进 $VD/kv ("类型<TAB>内容"); 其它行丢弃
  LC_ALL=C awk '
    /^##kv [A-Za-z0-9_-]+=/ { sub(/^##kv /, ""); i = index($0, "="); print "kv\t" substr($0, 1, i - 1) "\t" substr($0, i + 1); next }
    /^##ip / { sub(/^##ip /, ""); print "ip\t" $0; next }
    /^##action / { sub(/^##action /, ""); print "action\t" $0; next }
    /^##node \{/ { sub(/^##node /, ""); print "node\t" $0; next }
    /^##warn / { sub(/^##warn /, ""); print "warn\t" $0; next }
    /^##err / { sub(/^##err /, ""); print "err\t" $0; next }' "$VD/out" > "$VD/kv"
}
vps_kv() { awk -F'\t' -v k="$1" '$1 == "kv" && $2 == k { print $3; exit }' "$VD/kv"; }              # 第一个同名字段的值
vps_kv_all() { awk -F'\t' -v k="$1" '$1 == k { print $2 (NF > 2 ? "\t" $3 : "") }' "$VD/kv"; }     # 某类全部行 (ip / action / node / warn / err)
vps_kv_multi() { awk -F'\t' -v k="$1" '$1 == "kv" && $2 == k { print $3 }' "$VD/kv"; }             # 同名字段的全部值
vps_remote_error() { # ##err 代码 中文||English
  local line code msg zh en
  line=$(vps_kv_all err | head -1); code=${line%% *}; msg=${line#* }; zh=${msg%%||*}; en=${msg#*||}
  case $code in E_VPS_UNSUPPORTED|E_VPS_PRIVILEGE|E_VPS_DEPS|E_VPS_VERIFY|E_VPS_NOT_DEPLOYED) VPS_CODE=$code ;; *) VPS_CODE=E_VPS_VERIFY ;; esac
  if [ "${I18N_LANG:-zh}" = zh ]; then VPS_ERR=$zh; else VPS_ERR=$en; fi
}

# ---------- 探测 ----------
# vps_probe_json  从 $VD/kv 拼出 probe 的结果 JSON (GET /api/job 的 result)
vps_probe_json() {
  local lang=${I18N_LANG:-zh} deps='' d name val missing ips='' lip pub dev ipv6='' acts='' id zh en support note ports hk_changed=false saved pend=null pid plan=null pport preason node_inst
  for d in curl ca-certificates tar iproute2 gzip; do
    val=$(vps_kv "dep_$d")
    case $val in 1:*) deps="$deps${deps:+,}{\"name\":\"$d\",\"installed\":true,\"version\":\"$(jesc "${val#1:}")\"}" ;; *) deps="$deps${deps:+,}{\"name\":\"$d\",\"installed\":false}" ;; esac
  done
  missing=$(vps_kv missing | awk '{ for (i = 1; i <= NF; i++) printf "%s\"%s\"", (i > 1 ? "," : ""), $i }')
  while read -r lip pub dev; do [ -n "$lip" ] && ips="$ips${ips:+,}{\"local\":\"$lip\",\"public\":\"$pub\",\"v\":4,\"dev\":\"$(jesc "$dev")\"}"; done < <(vps_kv_all ip | tr '\t' ' ')
  for d in $(vps_kv_multi ipv6); do ipv6="$ipv6${ipv6:+,}\"$(jesc "$d")\""; done
  while IFS= read -r line; do
    [ -n "$line" ] || continue; id=${line%%|*}; zh=${line#*|}; en=${zh#*|}; zh=${zh%%|*}
    acts="$acts${acts:+,}{\"id\":\"$(jesc "$id")\",\"text\":\"$(jesc "$([ "$lang" = zh ] && printf '%s' "$zh" || printf '%s' "$en")")\"}"
  done < <(vps_kv_all action)
  ports=$(vps_kv listening | awk '{ for (i = 1; i <= NF; i++) printf "%s%s", (i > 1 ? "," : ""), $i }')
  note=$(vps_kv "support_note_$lang"); [ -n "$note" ] || note=$(vps_kv support_note_en)
  saved=$(vps_saved_field "$V_HOST" "$V_PORT" hostkey); { [ -n "$saved" ] && [ -z "$V_HOSTKEY" ] && [ "$saved" != "$VPS_HOSTKEY" ]; } && hk_changed=true
  # 上一次部署已经完成、但验证没通过 (本机还没有这些节点): 服务器上其实已经有节点了, 不能再显示「尚未部署」。
  pid=$(vps_pending_find "$V_HOST" "$V_PORT"); [ -z "$pid" ] || pend=$(vps_pending_one_json "$pid")
  node_inst=false; { [ "$(vps_kv deployed)" = 1 ] || [ "$pend" != null ]; } && node_inst=true   # 以 enana 是否已部署为准 (node_installed 只表示装了 Node.js)
  # 云端 probe.sh 可以(可选)告诉我们「按现在的占用情况, 将要用哪个端口」: 有就在部署前显示, 没有界面就不假设端口。
  pport=$(vps_kv plan_port); case $pport in ''|*[!0-9]*) ;; *) preason=$(vps_kv plan_reason); case $preason in ''|*[!A-Za-z0-9_-]*) preason='' ;; esac; plan="{\"port\":$pport,\"reason\":\"$preason\"}" ;; esac
  printf '{"host":"%s","port":%s,"user":"%s","hostkey":"%s","hostkey_changed":%s,"os":{"id":"%s","version":"%s","codename":"%s","pretty":"%s"},"arch":"%s","supported":%s,"support":"%s","support_note":"%s","privilege":"%s","init":"%s","deps":[%s],"missing":[%s],"all_missing":%s,"singbox":{"installed":%s,"version":"%s"},"node":{"installed":%s},"deployed":%s,"firewall":"%s","listening":[%s],"ips":[%s],"ipv6":[%s],"actions":[%s],"pending":%s,"plan":%s}' \
    "$(jesc "$V_HOST")" "$V_PORT" "$(jesc "$V_USER")" "$(jesc "${VPS_HOSTKEY:-}")" "$hk_changed" "$(jesc "$(vps_kv os_id)")" "$(jesc "$(vps_kv os_version)")" "$(jesc "$(vps_kv os_codename)")" "$(jesc "$(vps_kv os_pretty)")" "$(jesc "$(vps_kv arch)")" \
    "$([ "$(vps_kv supported)" = 1 ] && echo true || echo false)" "$(jesc "$(vps_kv support)")" "$(jesc "$note")" "$(jesc "$(vps_kv privilege)")" "$(jesc "$(vps_kv init)")" "$deps" "$missing" \
    "$([ "$(vps_kv all_missing)" = 1 ] && echo true || echo false)" "$([ "$(vps_kv singbox_installed)" = 1 ] && echo true || echo false)" "$(jesc "$(vps_kv singbox_version)")" "$node_inst" \
    "$([ "$(vps_kv deployed)" = 1 ] && echo true || echo false)" "$(jesc "$(vps_kv firewall)")" "$ports" "$ips" "$ipv6" "$acts" "$pend" "$plan"
}

# 任务出错: 写进度 + 错误码 (前端从 job.result.code 取)
vps_job_error() { # [步骤序号]   (VPS_RESULT_EXTRA: 以逗号开头的 JSON 片段, 并入失败结果; 用过就清空)
  local extra=''
  [ "$JOB_NAME" != vps-probe ] || extra=",\"attempt\":${VPS_ATTEMPT:-1},\"max_attempts\":${VPS_ATTEMPTS:-3}"
  extra="$extra${VPS_RESULT_EXTRA:-}"; VPS_RESULT_EXTRA=''
  oplog "${OP_WHO:-dashboard}" "添加自己的服务器" "$(kv host "${V_HOST:-${P_HOST:-}}" code "${VPS_CODE:-}" reason "${VPS_REASON:-}" tcp "${VPS_TCP:-}")" error
  job_write "$JOB_ID" "$JOB_NAME" error "${1:-0}" 100 "${VPS_ERR:-失败}" "{\"code\":\"${VPS_CODE:-E_VPS_VERIFY}\"$extra}"
}

# vps_connect  公共前半段: 读凭据 → 校验 → 准备 → 主机指纹; 失败时已写好任务错误并返回 1
vps_prepare_connection() { # <凭据文件>
  vps_check_cancel || { vps_job_error; return 1; }
  vps_cred_load "$1" || { VPS_CODE=E_INVALID; VPS_ERR="没有找到本次任务的凭据"; vps_job_error; return 1; }
  if ! vps_cred_check "$V_HOST" "$V_PORT" "$V_USER" "$V_MODE" "$V_PASSWORD" "$V_KEY" "$V_PASSPHRASE" "$V_SUDOPW" "$V_HOSTKEY"; then VPS_CODE=E_INVALID; VPS_ERR=$VPS_ERR; vps_job_error; return 1; fi
  vps_prepare || { VPS_CODE=E_INVALID; VPS_ERR="无法创建临时目录"; vps_job_error; return 1; }
  command -v "$(vps_ssh_bin)" >/dev/null 2>&1 || { VPS_CODE=E_SSH_NO_CLIENT; VPS_ERR="这台电脑上找不到 ssh 命令"; vps_job_error; return 1; }
}
vps_connect() { # <凭据文件>
  vps_prepare_connection "$1" || return 1
  job_step 0 5 "连接服务器"
  vps_hostkey_setup; case $? in
    0) ;;
    2) VPS_CODE=E_SSH_HOSTKEY; VPS_ERR="服务器的主机指纹与之前固定的不一致 (可能被中间人攻击, 或服务器重装过系统)"; vps_job_error; return 1 ;;
    *) VPS_CODE=E_SSH_UNREACHABLE; VPS_ERR="连不上 $V_HOST:$V_PORT (SSH): 地址或端口不对, 服务器没开机, 或防火墙挡住了 SSH 端口"; vps_job_error; return 1 ;;
  esac
  return 0
}

# ---------- 任务: 探测 (只读) ----------
vps_probe_job() { # <凭据文件>
  local rc attempt retry_start
  trap 'vps_cleanup' EXIT
  printf '%s\n' "$$" > "$H/jobs/$JOB_ID.started"
  vps_prepare_connection "$1" || return 1
  vps_playbook_ok || { VPS_CODE=E_VPS_NO_PLAYBOOK; VPS_ERR="部署脚本由 enana 云端下发: 请先登录, 并等「云端内容」同步完成后再试"; vps_job_error; return 1; }
  VPS_ATTEMPTS=3
  for attempt in 1 2 3; do
    VPS_ATTEMPT=$attempt; VPS_CODE=''; VPS_ERR=''; VPS_SEEN=0
    vps_check_cancel || { vps_job_error; return 1; }
    vps_hostkey_setup; rc=$?
    case $rc in
      0)
        if [ "$V_CONFIRM" = 1 ] && [ -z "$V_HOSTKEY" ]; then
          vps_check_cancel || { vps_job_error; return 1; }
          oplog "${OP_WHO:-dashboard}" "探测服务器主机指纹" "$V_HOST" ok
          job_ok "请确认主机指纹" "{\"host\":\"$(jesc "$V_HOST")\",\"port\":$V_PORT,\"hostkey\":\"$(jesc "$VPS_HOSTKEY")\",\"need_confirm\":true}"; return 0
        fi
        : > "$VD/out"; : > "$VD/err"
        if vps_run probe user; then break; fi ;;
      2) VPS_CODE=E_SSH_HOSTKEY; VPS_ERR="服务器的主机指纹与之前固定的不一致 (可能被中间人攻击, 或服务器重装过系统)" ;;
      3) VPS_CODE=E_CANCELLED; VPS_ERR="已取消服务器检测" ;;
      *) VPS_CODE=E_SSH_UNREACHABLE; VPS_ERR="连不上 $V_HOST:$V_PORT (SSH): 地址或端口不对, 服务器没开机, 或防火墙挡住了 SSH 端口" ;;
    esac
    # Retry only transient connection failures, never rejected credentials or keys.
    if [ "$VPS_CODE" != E_SSH_UNREACHABLE ] || [ "$attempt" = 3 ]; then vps_job_error 1; return 1; fi
    oplog "${OP_WHO:-dashboard}" "服务器检测重试" "$(kv host "$V_HOST:$V_PORT" attempt "$attempt" max 3 code "$VPS_CODE")" error
    retry_start=$(now)
    while [ $(( $(now) - retry_start )) -lt 2 ]; do
      vps_check_cancel || { vps_job_error; return 1; }
      vps_probe_progress retry 0 5 "$retry_start" 2; sleep 0.5
    done
  done
  vps_check_cancel || { vps_job_error; return 1; }
  job_step 2 90 "整理结果"
  oplog "${OP_WHO:-dashboard}" "探测服务器" "$V_HOST ($(vps_kv os_pretty))" ok
  job_ok "探测完成" "$(vps_probe_json)"
}

# ---------- 保存 ----------
vps_id_new() { printf 'v-%s' "$(auth_rand_hex 3)"; }
vps_list() { [ -f "$VPS_FILE" ] && cat "$VPS_FILE"; return 0; }
vps_json() { vps_list | awk 'NF { printf "%s%s", (n++ ? "," : ""), $0 } END { }'; }          # GET /api/vps 的数组内容
vps_saved_field() { # <host> <port> <字段>  已保存记录里的字符串字段 (同 host+port)
  vps_list | awk -v h="\"host\":\"$1\"" -v p="\"ssh_port\":$2," -v f="$3" 'index($0, h) && index($0, p) { k = "\"" f "\":\""; i = index($0, k); if (i) { s = substr($0, i + length(k)); print substr(s, 1, index(s, "\"") - 1); exit } }'
}
vps_forget() { # <id>
  [ -f "$VPS_FILE" ] || return 1
  grep -q "^{\"id\":\"$1\"," "$VPS_FILE" || return 1
  grep -v "^{\"id\":\"$1\"," "$VPS_FILE" > "$VPS_FILE.new" || true; mv "$VPS_FILE.new" "$VPS_FILE"; chmod 600 "$VPS_FILE"
}

# txn_vps_save: 在 op_txn 里把节点加进服务器列表 + 写 / 更新记录。需要变量 VPS_NODES_FILE (每行一个完整的 {"role":…,"outbound":…}) 和 VPS_REC_*。
vps_rec_write() { # 按 VPS_REC_* 写 / 更新记录
  local rec
  rec="{\"id\":\"$VPS_REC_ID\",\"name\":\"$(jesc "$VPS_REC_NAME")\",\"host\":\"$(jesc "$VPS_REC_HOST")\",\"ssh_port\":$VPS_REC_PORT,\"user\":\"$(jesc "$VPS_REC_USER")\",\"os\":\"$(jesc "$VPS_REC_OS")\",\"hostkey\":\"$(jesc "$VPS_REC_HOSTKEY")\",\"ips\":[$VPS_REC_IPS],\"nodes\":[$VPS_REC_TAGS],\"updated\":$(now)}"
  { [ -f "$VPS_FILE" ] && grep -v "^{\"id\":\"$VPS_REC_ID\"," "$VPS_FILE" || true; printf '%s\n' "$rec"; } > "$VPS_FILE.new" && mv "$VPS_FILE.new" "$VPS_FILE" && chmod 600 "$VPS_FILE"
}
# txn_vps_save: 在 op_txn 里把节点加进服务器列表 + 写 / 更新记录。需要变量 VPS_NODES_FILE (每行一个完整的 {"role":…,"outbound":…}) 和 VPS_REC_*。
txn_vps_save() {
  local res a r
  res=$(srv_import "" merge < "$VPS_NODES_FILE" 2>/dev/null) || { TXN_ERR="保存节点失败"; return 1; }
  a=${res%% *}; r=$(printf '%s' "$res" | awk '{print $2}')
  [ $(( ${a:-0} + ${r:-0} )) -gt 0 ] || { TXN_ERR="没有可以保存的节点"; return 1; }
  vps_rec_write
}

# ---------- 部署完成但验证没通过: 「待验证的部署」 ----------
# 远端已经部署好了 (服务和密钥都在服务器上), 但本机连不上或验证没过, 节点还没有加进本机。节点信息 (含节点凭据, 和 servers.jsonl 同样敏感) 存成
# $H/vps-pending/<编号> (目录 700, 文件 600), 这样用户放行端口后可以「重新验证」: 只在本机验证 —— 不再 SSH、不再部署、不需要重新输入任何凭据 ——
# 而不是把整个部署再来一遍。文件: 前面是 键=值 行, 后面是 node<TAB>tag<TAB>server<TAB>port<TAB>type<TAB>行<TAB>出站 (和 $VD/nodes.tsv 一样)。
# 编号 p-xxxxxx; 同一个 host:ssh_port 只保留最新的一条; 7 天后自动清理; 验证并保存成功 / 用户放弃 / 忘记服务器记录都会删除。不进配置快照、导出和云端同步。
VPS_PENDING_DIR=${VPS_PENDING_DIR:-$H/vps-pending}
VPS_PENDING_TTL=${VPS_PENDING_TTL:-604800}
vps_pending_id_ok() { printf '%s\n' "$1" | LC_ALL=C grep -Eq '^p-[0-9a-f]{6}$'; }
vps_pending_file() { printf '%s/%s\n' "$VPS_PENDING_DIR" "$1"; }
vps_pending_field() { sed -n "s/^$2=//p" "$(vps_pending_file "$1")" 2>/dev/null | head -1; }          # <编号> <字段>
vps_clean_field() { printf '%s' "$1" | tr -d '\000-\037' | head -c 200; }
vps_pending_prune() { # 超过保存期限的删掉
  [ -d "$VPS_PENDING_DIR" ] || return 0
  find "$VPS_PENDING_DIR" -maxdepth 1 -type f -name 'p-*' -mtime +$((VPS_PENDING_TTL / 86400)) -exec rm -f {} + 2>/dev/null || true
  find "$VPS_PENDING_DIR" -maxdepth 1 -type d -name 'p-*.lock' -mmin +30 -exec rmdir {} + 2>/dev/null || true
}
vps_pending_find() { # <host> <ssh 端口>  -> 编号 (没有则不打印)
  local f id
  [ -d "$VPS_PENDING_DIR" ] || return 0
  for f in "$VPS_PENDING_DIR"/p-*; do
    [ -f "$f" ] || continue; id=${f##*/}; vps_pending_id_ok "$id" || continue
    if [ "$(vps_pending_field "$id" host)" = "$1" ] && [ "$(vps_pending_field "$id" ssh_port)" = "$2" ]; then printf '%s\n' "$id"; return 0; fi
  done
  return 0
}
vps_pending_delete() { vps_pending_id_ok "$1" && rm -f "$(vps_pending_file "$1")" 2>/dev/null; rmdir "$(vps_pending_file "$1").lock" 2>/dev/null || true; return 0; }
# vps_pending_write <编号> <原因> <次数>  依据 VPS_REC_* (id name host port user os hostkey) / VPS_REC_ROLE / VPS_REC_SAVE 和 $VD/nodes.tsv; 保留原来的创建时间
vps_pending_write() {
  local id=$1 f created
  f=$(vps_pending_file "$id"); created=$(vps_pending_field "$id" created); [ -n "$created" ] || created=$(now)
  mkdir -p "$VPS_PENDING_DIR"; chmod 700 "$VPS_PENDING_DIR"
  ( umask 077; {
    printf 'id=%s\nhost=%s\nssh_port=%s\nuser=%s\nhostkey=%s\nname=%s\nrole=%s\nsave=%s\nos=%s\nvps_id=%s\ncreated=%s\nupdated=%s\ntries=%s\nreason=%s\n' \
      "$id" "$(vps_clean_field "$VPS_REC_HOST")" "$VPS_REC_PORT" "$(vps_clean_field "$VPS_REC_USER")" "$(vps_clean_field "$VPS_REC_HOSTKEY")" "$(vps_clean_field "$VPS_REC_NAME")" "${VPS_REC_ROLE:-pin}" "${VPS_REC_SAVE:-}" \
      "$(vps_clean_field "$VPS_REC_OS")" "$VPS_REC_ID" "$created" "$(now)" "${3:-0}" "$(vps_clean_field "$2")"
    awk '{ printf "node\t%s\n", $0 }' "$VD/nodes.tsv"
  } > "$f.new" ) && mv "$f.new" "$f"
}
# vps_pending_load <编号>  读出 P_* 并把节点写到 $VD/nodes.tsv; 0 = 成功
vps_pending_load() {
  local f; vps_pending_id_ok "$1" || return 1; f=$(vps_pending_file "$1"); [ -f "$f" ] || return 1
  P_ID=$1; P_HOST=$(vps_pending_field "$1" host); P_SSHPORT=$(vps_pending_field "$1" ssh_port); P_USER=$(vps_pending_field "$1" user); P_HOSTKEY=$(vps_pending_field "$1" hostkey)
  P_NAME=$(vps_pending_field "$1" name); P_ROLE=$(vps_pending_field "$1" role); P_SAVE=$(vps_pending_field "$1" save); P_OS=$(vps_pending_field "$1" os)
  P_VPSID=$(vps_pending_field "$1" vps_id); P_TRIES=$(vps_pending_field "$1" tries)
  case $P_ROLE in pin|auto) ;; *) P_ROLE=pin ;; esac
  case $P_TRIES in ''|*[!0-9]*) P_TRIES=0 ;; esac
  awk -F'\t' '$1 == "node" { sub(/^node\t/, ""); print }' "$f" > "$VD/nodes.tsv"
  [ -n "$P_HOST" ] && [ -s "$VD/nodes.tsv" ]
}
# 一条待验证记录的摘要 JSON (不含节点凭据): 给界面显示用
vps_pending_one_json() { # <编号>
  LC_ALL=C awk -F'\t' "$_AWK_ESC"'
    function num(v) { return v ~ /^[0-9]+$/ ? v : 0 }
    $1 == "node" { n++; if (!($3 in sv)) { sv[$3] = 1; ips = ips (ips == "" ? "" : ",") "\"" esc($3) "\"" } if ($4 ~ /^[0-9]+$/ && !($4 in pt)) { pt[$4] = 1; ports = ports (ports == "" ? "" : ",") $4 } next }
    { i = index($0, "="); if (i > 1) kv[substr($0, 1, i - 1)] = substr($0, i + 1) }
    END { printf "{\"id\":\"%s\",\"name\":\"%s\",\"host\":\"%s\",\"ssh_port\":%s,\"user\":\"%s\",\"os\":\"%s\",\"ports\":[%s],\"ips\":[%s],\"nodes\":%d,\"created\":%s,\"updated\":%s,\"tries\":%s,\"reason\":\"%s\"}", \
      esc(kv["id"]), esc(kv["name"]), esc(kv["host"]), num(kv["ssh_port"]), esc(kv["user"]), esc(kv["os"]), ports, ips, n, num(kv["created"]), num(kv["updated"]), num(kv["tries"]), esc(kv["reason"]) }' "$(vps_pending_file "$1")"
}
vps_pending_json() { # GET /api/vps/pending 的数组内容
  local f id out=''
  vps_pending_prune
  [ -d "$VPS_PENDING_DIR" ] || return 0
  for f in "$VPS_PENDING_DIR"/p-*; do
    [ -f "$f" ] || continue; id=${f##*/}; vps_pending_id_ok "$id" || continue
    out="$out${out:+,}$(vps_pending_one_json "$id")"
  done
  printf '%s' "$out"
}
vps_pending_lock() { # 同一条记录同时只允许一个验证任务 (超过 30 分钟的残留锁视为失效)
  local l; l="$(vps_pending_file "$1").lock"
  find "$l" -maxdepth 0 -mmin +30 -exec rmdir {} + 2>/dev/null || true
  mkdir "$l" 2>/dev/null
}
vps_pending_unlock() { rmdir "$(vps_pending_file "$1").lock" 2>/dev/null || true; }

# ---------- 本机到节点端口的 TCP 预检 ----------
# TUN 模式下本机会直接应答任何 TCP 握手 (什么端口都「通」), 所以和健康探测一样把探测的 socket 绑定到物理网卡 (lib/health.pl 的 tcp_probe)。
vps_phys_if() { # 打印物理出口网卡名 (只有 TUN 模式才需要; 其它情况什么也不打印)
  local ifx
  [ "${NETWORK_MODE:-system}" = tun ] || return 0
  ifx=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2; exit}')
  case $ifx in utun*|''|*[!A-Za-z0-9._-]*) ;; *) printf '%s' "$ifx" ;; esac
}
vps_phys_ifindex() { local n; n=$(vps_phys_if); [ -n "$n" ] || return 0; ifconfig -v "$n" 2>/dev/null | sed -n '1s/.* index \([0-9][0-9]*\).*/\1/p'; }
# vps_tcp_probe <文件: 每行 标签<TAB>主机<TAB>端口> [秒]  -> 每行 标签<TAB>结果<TAB>毫秒 (结果: ok timeout refused unreachable dns other)
vps_tcp_probe() { ENANA_PROBE_IFINDEX=$(vps_phys_ifindex) perl "$LIB/health.pl" probe "${2:-6}" < "$1" | awk -F'\t' '{ print $1 "\t" $2 "\t" $3 }'; }
# vps_ob_field <出站 JSON> <tag|server|port|type>
vps_ob_field() {
  case $2 in
    tag)    printf '%s' "$1" | sed -n 's/^{"type":"[a-z0-9]*","tag":"\([^"]*\)".*/\1/p' ;;
    server) printf '%s' "$1" | sed -n 's/.*"server":"\([^"]*\)".*/\1/p' ;;
    port)   printf '%s' "$1" | sed -n 's/.*"server_port":\([0-9]*\).*/\1/p' ;;
    type)   printf '%s' "$1" | sed -n 's/^{"type":"\([a-z0-9]*\)".*/\1/p' ;;
  esac
}
# vps_tcp_precheck <出站文件>  先看端口本身通不通 (几秒钟), 不通的节点不用再等几十秒的真实访问。结果 $VD/tcp: 标签<TAB>结果<TAB>毫秒
# 不走 TCP 的协议 (hysteria2 / tuic) 不检查 (端口是 UDP, TCP 握手没有意义)。
vps_tcp_precheck() {
  local nodes=$1 line tag server port etype i=0
  : > "$VD/tcp"; : > "$VD/tcp.in"; : > "$VD/tcp.map"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    etype=$(vps_ob_field "$line" type); case $etype in vless|vmess|trojan|socks|http|shadowsocks|anytls) ;; *) continue ;; esac
    tag=$(vps_ob_field "$line" tag); server=$(vps_ob_field "$line" server); port=$(vps_ob_field "$line" port)
    [ -n "$tag" ] && [ -n "$server" ] && [ -n "$port" ] || continue
    i=$((i + 1)); printf 'n%s\t%s\t%s\n' "$i" "$server" "$port" >> "$VD/tcp.in"; printf 'n%s\t%s\n' "$i" "$tag" >> "$VD/tcp.map"
  done < "$nodes"
  [ -s "$VD/tcp.in" ] || return 0
  vps_tcp_probe "$VD/tcp.in" 6 | awk -F'\t' 'NR == FNR { m[$1] = $2; next } ($1 in m) { print m[$1] "\t" $2 "\t" $3 }' "$VD/tcp.map" - > "$VD/tcp"
}

# ---------- 验证: 本机起一个临时核心, 逐个节点真实访问一次, 对比出口 IP ----------
# vps_verify <文件: 每行一个出站 JSON>  0 = 至少一个节点能通 (逐个结果在 $VD/verify: tag<TAB>ok|fail<TAB>看到的 IP);  1 = 一个都不通
# 先做 TCP 预检 ($VD/tcp): 端口不通的节点直接记为 fail, 不再等真实访问; 剩下的才起临时核心。TUN 模式下临时核心的出站也绑定物理网卡 (否则它会被 TUN 接管, 经另一条线路去连这台服务器)。
vps_verify() {
  local nodes=$1 n=0 cfg ports='' p tag line ok=0 url sbpid out i ib='' ob='' rr='' base k bi
  cfg="$VD/verify.json"; : > "$VD/verify"
  vps_tcp_precheck "$nodes"
  bi=$(vps_phys_if)
  for k in 1 2 3 4 5 6 7 8; do base=$((21000 + RANDOM % 20000)); nc -z 127.0.0.1 "$base" 2>/dev/null || break; done
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    tag=$(vps_ob_field "$line" tag); [ -n "$tag" ] || continue
    if awk -F'\t' -v t="$tag" '$1 == t && $2 != "ok" { f = 1 } END { exit !f }' "$VD/tcp"; then printf '%s\tfail\t\n' "$tag" >> "$VD/verify"; continue; fi     # 端口都连不上: 不用再试
    [ -z "$bi" ] || line=$(printf '%s' "$line" | sed "s/^{\"type\":\"\([a-z0-9]*\)\",/{\"type\":\"\1\",\"bind_interface\":\"$bi\",/")
    p=$((base + n)); ports="$ports $tag:$p"
    ib="$ib${ib:+,}{\"type\":\"socks\",\"tag\":\"v$n\",\"listen\":\"127.0.0.1\",\"listen_port\":$p}"
    ob="$ob${ob:+,}$line"; rr="$rr${rr:+,}{\"inbound\":[\"v$n\"],\"action\":\"route\",\"outbound\":\"$tag\"}"
    n=$((n + 1))
  done < "$nodes"
  [ "$n" -gt 0 ] || return 1
  printf '{"log":{"level":"error"},"inbounds":[%s],"outbounds":[%s,{"type":"direct","tag":"direct"}],"route":{"rules":[%s],"final":"direct"}}\n' "$ib" "$ob" "$rr" > "$cfg"
  "$SB" check -c "$cfg" >"$VD/check.log" 2>&1 || return 1
  "$SB" run -c "$cfg" >"$VD/core.log" 2>&1 & sbpid=$!
  for i in $(seq 1 24); do nc -z 127.0.0.1 "$base" 2>/dev/null && break; sleep 0.25; done
  for tag in $ports; do
    p=${tag#*:}; tag=${tag%:*}; out=''
    for url in ${ENANA_VERIFY_IP_URL:-https://api.ip.sb/ip https://ifconfig.me/ip https://ipv4.icanhazip.com}; do
      out=$(curl -s -m 12 --connect-timeout 8 -x "socks5h://127.0.0.1:$p" "$url" 2>/dev/null | tr -d ' \r\n' | head -c 64)
      printf '%s\n' "$out" | LC_ALL=C grep -Eq '^[0-9a-fA-F:.]{3,45}$' && break; out=''
    done
    if [ -n "$out" ]; then printf '%s\tok\t%s\n' "$tag" "$out" >> "$VD/verify"; ok=$((ok + 1)); else printf '%s\tfail\t\n' "$tag" >> "$VD/verify"; fi
  done
  kill "$sbpid" 2>/dev/null; wait "$sbpid" 2>/dev/null
  [ "$ok" -gt 0 ]
}

# ---------- 验证没通过: 找原因 ----------
# 服务器端证据 (可选): 登录凭据还在时, 重新跑一遍云端的只读 probe.sh (不新增任何远端脚本), 看节点端口有没有在监听、服务器上有没有启用防火墙。
# 拿不到 (SSH 失败 / 探测里没有这个字段) 就保持「不知道」, 绝不猜。设置 VPS_EV_LISTEN=1|0|'' VPS_EV_FW=<probe 的 firewall 值>|''
vps_remote_evidence() { # <端口 逗号分隔>   (以登录用户身份只读探测, 不需要 sudo)
  local ports=$1 listed pt keep_code=$VPS_CODE keep_err=$VPS_ERR hit=0 VPS_TIMEOUT=60
  VPS_EV_LISTEN=''; VPS_EV_FW=''
  : > "$VD/out"; : > "$VD/err"
  VPS_NO_PROGRESS=1                                  # 这次只是取证据: 不能让任务进度倒退回「检测系统与环境」
  if vps_run probe user; then
    VPS_EV_FW=$(vps_kv firewall); listed=$(vps_kv listening)
    if [ -n "$listed" ]; then
      for pt in $(printf '%s' "$ports" | tr ',' ' '); do case " $listed " in *" $pt "*) hit=1 ;; esac; done
      VPS_EV_LISTEN=$hit
    fi
  fi
  VPS_NO_PROGRESS=0
  VPS_CODE=$keep_code; VPS_ERR=$keep_err
}
# vps_diagnose  依据 $VD/tcp (本机到每个节点端口的 TCP 结果) 和服务器端证据, 设置 VPS_TCP 与 VPS_REASON。
#   VPS_TCP    ok (全部连得上) · timeout · refused · unreachable · mixed (不止一种失败) · none (没有做 TCP 预检)
#   VPS_REASON handshake        端口是通的, 但经节点访问失败 —— 不是防火墙问题 (服务端配置 / 密钥 / 时间 / 服务器出站被限制)
#              not_listening    服务器上没有任何进程在监听这个端口 (服务没起来)
#              refused          服务器明确拒绝了连接 (没有进程监听, 或防火墙配置成拒绝而不是丢弃)
#              unreachable      这台电脑到服务器没有可用路由 (本机网络 / VPN)
#              blocked_server   超时, 服务在监听, 而且服务器上启用了 ufw / firewalld: 可能是服务器自己的防火墙, 也可能是云安全组
#              blocked_cloud    超时, 服务在监听, 没有发现服务器自己的防火墙: 多半是云服务商的安全组 / 网络 ACL
#              blocked_unknown  超时, 但没有服务器端证据: 无法确定是防火墙还是本机网络
#              unknown          其它
vps_diagnose() {
  local total ok_n to_n rf_n un_n
  total=$(awk 'END { print NR + 0 }' "$VD/tcp" 2>/dev/null); total=${total:-0}
  ok_n=$(awk -F'\t' '$2 == "ok" { n++ } END { print n + 0 }' "$VD/tcp"); to_n=$(awk -F'\t' '$2 == "timeout" { n++ } END { print n + 0 }' "$VD/tcp")
  rf_n=$(awk -F'\t' '$2 == "refused" { n++ } END { print n + 0 }' "$VD/tcp"); un_n=$(awk -F'\t' '$2 == "unreachable" { n++ } END { print n + 0 }' "$VD/tcp")
  if [ "$total" -eq 0 ]; then VPS_TCP=none
  elif [ "$ok_n" -eq "$total" ]; then VPS_TCP=ok
  elif [ "$to_n" -eq "$total" ]; then VPS_TCP=timeout
  elif [ "$rf_n" -eq "$total" ]; then VPS_TCP=refused
  elif [ "$un_n" -eq "$total" ]; then VPS_TCP=unreachable
  else VPS_TCP=mixed; fi
  if [ "$ok_n" -gt 0 ]; then VPS_REASON=handshake                            # 至少有一个端口连得上: 防火墙不是原因
  elif [ "${VPS_EV_LISTEN:-}" = 0 ]; then VPS_REASON=not_listening
  else case $VPS_TCP in
    refused) VPS_REASON=refused ;;
    unreachable) VPS_REASON=unreachable ;;
    timeout|mixed)
      if [ "${VPS_EV_LISTEN:-}" = 1 ]; then case ${VPS_EV_FW:-} in ufw_active|firewalld_active) VPS_REASON=blocked_server ;; *) VPS_REASON=blocked_cloud ;; esac
      else VPS_REASON=blocked_unknown; fi ;;
    *) VPS_REASON=unknown ;;
  esac; fi
}
# vps_reason_msg <端口列表> [deploy|redetect]  -> VPS_ERR (原因说明: 只断言证据支持的, 其余明确说「无法确定」; 各段分别翻译后再拼接)
vps_reason_msg() {
  local ports=$1 kind=${2:-deploy} lead clause tail
  if [ "$kind" = redetect ]; then lead=$(_t "新增的节点没有通过验证 (TCP $ports)"); tail=$(_t "处理后再试一次")
  else lead=$(_t "部署完成了, 但新节点没有通过验证 (TCP $ports)"); tail=$(_t "放行或修复后点「重新验证」"); fi
  case $VPS_REASON in
    handshake) clause=$(_t "端口是通的, 但经节点访问失败, 这不是防火墙问题: 可能是服务端配置或密钥不匹配、服务器时间不准, 或这台服务器的出站网络被限制") ;;
    not_listening) clause=$(_t "服务器上没有进程在监听这个端口, 服务可能没有启动成功, 请到服务器上查看服务状态") ;;
    refused) clause=$(_t "服务器明确拒绝了连接: 服务没有在监听这个端口, 或服务器防火墙配置成了拒绝; 这不是云服务商安全组的典型表现") ;;
    unreachable) clause=$(_t "这台电脑到服务器没有可用路由, 请检查这台电脑的网络或 VPN") ;;
    blocked_server) clause=$(_t "服务在监听, 但服务器上启用了防火墙: 它或云服务商的安全组可能没有放行这个端口") ;;
    blocked_cloud) clause=$(_t "服务在监听, 没有发现服务器自己的防火墙拦截, 多半是云服务商的安全组 / 网络 ACL 没有放行这个端口") ;;
    blocked_unknown) clause=$(_t "没有收到服务器的回应, 无法确定原因: 可能是云服务商的安全组或服务器防火墙没有放行, 也可能是这台电脑的网络到该地址不通") ;;
    *) clause=$(_t "原因无法确定, 请检查服务器和网络") ;;
  esac
  VPS_ERR="$lead: $clause; $tail"
}

# ---------- 节点整理 ----------
# vps_collect_nodes <角色>  整理远端的 ##node 行 -> $VD/nodes.tsv: tag<TAB>server<TAB>port<TAB>type<TAB>servers.jsonl 的行<TAB>出站 JSON   0 = 至少一个节点合格
vps_collect_nodes() {
  local role=$1 ob row tag server port etype
  : > "$VD/nodes.tsv"
  while IFS= read -r ob; do
    [ -n "$ob" ] || continue
    row=$(printf '{"role":"%s","outbound":%s}' "$role" "$ob" | tr -d '\r\n')
    srv_check_line "$row" || continue                         # 和手动导入同一道闸门
    tag=$(printf '%s' "$ob" | sed -n 's/^{"type":"[a-z0-9]*","tag":"\([^"]*\)".*/\1/p'); server=$(printf '%s' "$ob" | sed -n 's/.*"server":"\([^"]*\)".*/\1/p')
    port=$(printf '%s' "$ob" | sed -n 's/.*"server_port":\([0-9]*\).*/\1/p'); etype=$(printf '%s' "$ob" | sed -n 's/^{"type":"\([a-z0-9]*\)".*/\1/p')
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$tag" "$server" "${port:-0}" "$etype" "$row" "$ob" >> "$VD/nodes.tsv"
  done < <(vps_kv_all node)
  [ -s "$VD/nodes.tsv" ]
}
# vps_nodes_json <tsv 文件>  -> [{tag,server,port,type,egress}] 的内容 (egress = 验证时从节点出去看到的 IP)
vps_nodes_json() {
  awk -F'\t' -v vf="$VD/verify" "$_AWK_ESC"'
    BEGIN { while ((getline l < vf) > 0) { split(l, a, "\t"); eg[a[1]] = a[3] } }
    { printf "%s{\"tag\":\"%s\",\"server\":\"%s\",\"port\":%s,\"type\":\"%s\",\"egress\":\"%s\",\"verified\":%s}", (n++ ? "," : ""), esc($1), esc($2), $3, $4, esc(eg[$1]), (eg[$1] != "" ? "true" : "false") }' "$1"
}
vps_nodes_ports() { cut -f3 "${1:-$VD/nodes.tsv}" | awk 'NF && $1 ~ /^[0-9]+$/ && !seen[$1]++' | paste -sd, -; }          # 节点实际使用的端口 (去重, 逗号分隔): 以节点本身为准, 不依赖任何固定端口
# vps_verify_extra <待验证编号> <端口列表>  验证没通过时并入任务结果的 JSON 片段: 界面据此说明原因 (原因代码见 vps_diagnose)
vps_verify_extra() {
  local pid=$1 ports=$2 first lst nodes failed checked=false
  first=${ports%%,*}; case $first in ''|*[!0-9]*) first=0 ;; esac
  case ${VPS_EV_LISTEN:-} in 1) lst=true; checked=true ;; 0) lst=false; checked=true ;; *) lst=null ;; esac
  nodes=$(awk 'END { print NR + 0 }' "$VD/nodes.tsv"); failed=$(awk -F'\t' '$2 == "fail" { n++ } END { print n + 0 }' "$VD/verify")
  printf ',"pending":"%s","reason":"%s","port":%s,"ports":[%s],"host":"%s","tcp":"%s","remote":{"checked":%s,"listening":%s,"firewall":"%s"},"nodes":%s,"failed":%s' \
    "$pid" "${VPS_REASON:-unknown}" "$first" "$ports" "$(jesc "${V_HOST:-${P_HOST:-}}")" "${VPS_TCP:-none}" "$checked" "$lst" "$(jesc "${VPS_EV_FW:-}")" "$nodes" "$failed"
}
vps_pending_note() { # <编号> <原因>: 又验证失败了一次 (次数 +1, 记下原因和时间)
  local f t; f=$(vps_pending_file "$1"); [ -f "$f" ] || return 0
  t=$(vps_pending_field "$1" tries); case $t in ''|*[!0-9]*) t=0 ;; esac
  LC_ALL=C awk -F'\t' -v r="$(vps_clean_field "$2")" -v t=$((t + 1)) -v u="$(now)" '$1 == "node" { print; next } /^reason=/ { print "reason=" r; next } /^tries=/ { print "tries=" t; next } /^updated=/ { print "updated=" u; next } { print }' "$f" > "$f.new" \
    && chmod 600 "$f.new" && mv "$f.new" "$f"
}
vps_rec_field() { vps_list | awk -v i="\"id\":\"$1\"" -v f="$2" 'index($0, i) { k = "\"" f "\":\""; j = index($0, k); if (j) { s = substr($0, j + length(k)); print substr(s, 1, index(s, "\"") - 1) }; exit }'; }

# ---------- 任务: 部署 ----------
vps_provision_progress() { case $1 in 1) job_step 1 12 "检测系统与环境" ;; 2) job_step 2 25 "安装依赖" ;; 3) job_step 3 45 "安装服务端" ;; 4) job_step 4 62 "生成配置与密钥" ;; 5) job_step 5 75 "开放端口并启动" ;; esac; }
vps_provision_job() { # <凭据文件>
  local rc role name priv os_pretty id ips tags pid ports
  trap 'vps_cleanup' EXIT
  vps_connect "$1" || return 1
  vps_playbook_ok || { VPS_CODE=E_VPS_NO_PLAYBOOK; VPS_ERR="部署脚本由 enana 云端下发: 请先登录, 并等「云端内容」同步完成后再试"; vps_job_error; return 1; }
  [ -n "$V_HOSTKEY" ] || { VPS_CODE=E_SSH_HOSTKEY; VPS_ERR="需要先确认并固定服务器的主机指纹"; vps_job_error; return 1; }
  role=$V_ROLE; case $role in pin|auto) ;; *) role=pin ;; esac
  name=$V_NAME; vps_name_ok "$name" || name="my-vps-$V_HOST"; vps_name_ok "$name" || name=my-vps
  vps_progress() { vps_provision_progress "$1"; }
  job_step 1 10 "检测系统与环境"
  if ! vps_run probe user; then vps_job_error 1; return 1; fi                  # 先以登录用户身份只读探测一次, 拿到权限信息
  priv=$(vps_kv privilege); os_pretty=$(vps_kv os_pretty)
  [ "$(vps_kv supported)" = 1 ] || { VPS_CODE=E_VPS_UNSUPPORTED; VPS_ERR=$(vps_kv "support_note_${I18N_LANG:-zh}"); [ -n "$VPS_ERR" ] || VPS_ERR="这台服务器的系统不受支持"; vps_job_error 1; return 1; }
  case $priv in root|sudo_nopass|sudo_password) ;; *) VPS_CODE=E_VPS_PRIVILEGE; VPS_ERR="需要 root 权限 (当前用户不是 root, 也没有可用的 sudo)"; vps_job_error 1; return 1 ;; esac
  [ "$priv" != sudo_password ] || [ -n "${V_SUDOPW:-$V_PASSWORD}" ] || { VPS_CODE=E_VPS_PRIVILEGE; VPS_ERR="需要 sudo 密码"; vps_job_error 1; return 1; }
  VPS_SEEN=0
  if ! vps_run provision "$priv" --name "$name" --install-deps "$([ "$V_DEPS" = 1 ] && echo 1 || echo 0)"; then vps_job_error "$(grep -c '^##step ' "$VD/out" 2>/dev/null || echo 1)"; return 1; fi
  job_step 6 85 "验证连通"
  vps_collect_nodes "$role" || { VPS_CODE=E_VPS_VERIFY; VPS_ERR="部署脚本没有返回可用的节点"; vps_job_error 6; return 1; }
  cut -f6 "$VD/nodes.tsv" > "$VD/nodes.out"; cut -f5 "$VD/nodes.tsv" > "$VD/nodes.jsonl"
  ips=$(cut -f2 "$VD/nodes.tsv" | awk 'NF { printf "%s\"%s\"", (n++ ? "," : ""), $0 }'); tags=$(cut -f1 "$VD/nodes.tsv" | awk 'NF { printf "%s\"%s\"", (n++ ? "," : ""), $0 }')
  id=$V_ID; [ -n "$id" ] || id=$(vps_saved_field "$V_HOST" "$V_PORT" id); [ -n "$id" ] || id=$(vps_id_new)
  VPS_NODES_FILE=$VD/nodes.jsonl; VPS_REC_ID=$id; VPS_REC_NAME=$name; VPS_REC_HOST=$V_HOST; VPS_REC_PORT=$V_PORT; VPS_REC_USER=$V_USER; VPS_REC_OS=$os_pretty; VPS_REC_HOSTKEY=$V_HOSTKEY; VPS_REC_IPS=$ips; VPS_REC_TAGS=$tags
  VPS_REC_ROLE=$role; VPS_REC_SAVE=$V_SAVE
  # 服务器上已经部署完成: 先把节点记成「待验证的部署」。之后不管是哪种原因没走完 (端口没放行 / 应用被关掉 / 保存失败), 用户都可以直接「重新验证」, 不用再部署一遍。
  vps_pending_prune
  pid=$(vps_pending_find "$V_HOST" "$V_PORT"); [ -n "$pid" ] || pid=p-$(auth_rand_hex 3)
  vps_pending_write "$pid" pending 0 || pid=''
  if ! vps_verify "$VD/nodes.out"; then
    ports=$(vps_nodes_ports)
    vps_remote_evidence "$ports"; vps_diagnose; vps_reason_msg "$ports"
    VPS_CODE=E_VPS_VERIFY
    if [ -n "$pid" ]; then vps_pending_note "$pid" "$VPS_REASON"; VPS_RESULT_EXTRA=$(vps_verify_extra "$pid" "$ports"); fi
    vps_job_error 6; return 1
  fi
  job_step 7 92 "识别出口 IP"
  job_step 8 96 "保存到本机"
  TXN_RESULT="{\"nodes\":[$(vps_nodes_json "$VD/nodes.tsv")],\"ips\":[$ips],\"vps\":\"$id\"}"
  SRV_SAVE=$V_SAVE; APPLY_QUIET=1; op_txn "添加自己的服务器" txn_vps_save "$V_HOST"; rc=$?; SRV_SAVE=''      # 「保存到云端」: 节点进入云端同步清单 (见 servers.sh)
  if [ "$rc" = 0 ]; then [ -z "$pid" ] || vps_pending_delete "$pid"; [ "$V_SAVE" = 1 ] && sync_after_save; fi
  return $rc
}

# ---------- 任务: 重新验证「部署完成但验证没通过」的节点 (不再 SSH、不再部署、不需要任何凭据) ----------
# 用户放行端口 (或修好别的问题) 之后调用: 读出之前保存的待验证节点 → 本机验证 → 通过就保存到本机 (和部署成功后的保存是同一个事务), 并删掉待验证记录。
# 和本机已有的节点逐个比较, 不会重复添加、也不会动已有节点: 完全一样的原样保留; 同名但内容不同的 (服务器重新部署后换了密钥) 才更新, 并保留你给它设的角色。
# 验证再次失败: 记录保留, 结果里带原因 (和部署时同一套: 端口不通 / 没有监听 / 握手失败 …); 这个任务拿不到服务器端证据, 所以只给本机能确认的原因。
vps_nodes_plan() { # <nodes.tsv>  -> $VD/nodes.save.jsonl (要写入的行) 与 VPS_PLAN_NEW / VPS_PLAN_SAME / VPS_PLAN_UPD
  local tag server port etype row ob cur crole cob
  : > "$VD/nodes.save.jsonl"; VPS_PLAN_NEW=0; VPS_PLAN_SAME=0; VPS_PLAN_UPD=0
  while IFS=$'\t' read -r tag server port etype row ob; do
    [ -n "$tag" ] || continue
    cur=$(srv_emit | awk -F'\t' -v t="$tag" '$2 == t { print $1 "\t" $3; exit }')
    if [ -z "$cur" ]; then printf '%s\n' "$row" >> "$VD/nodes.save.jsonl"; VPS_PLAN_NEW=$((VPS_PLAN_NEW + 1)); continue; fi
    crole=${cur%%$'\t'*}; cob=${cur#*$'\t'}
    if [ "$cob" = "$ob" ]; then VPS_PLAN_SAME=$((VPS_PLAN_SAME + 1)); continue; fi
    case $crole in pin|auto|dl|off) row=$(printf '%s' "$row" | sed "s/^{\"role\":\"[a-z]*\"/{\"role\":\"$crole\"/") ;; esac
    printf '%s\n' "$row" >> "$VD/nodes.save.jsonl"; VPS_PLAN_UPD=$((VPS_PLAN_UPD + 1))
  done < "$1"
}
vps_verify_job() { # <待验证编号>
  local pid=$1 rc ips tags id ports
  trap 'vps_cleanup' EXIT
  VD=$(mktemp -d "${TMPDIR:-/tmp}/enana-vps.XXXXXX") && chmod 700 "$VD" || { VPS_CODE=E_INVALID; VPS_ERR="无法创建临时目录"; vps_job_error 0; return 1; }
  : > "$VD/verify"; : > "$VD/tcp"; : > "$VD/nodes.tsv"
  P_HOST=''
  vps_pending_id_ok "$pid" && [ -f "$(vps_pending_file "$pid")" ] || { VPS_CODE=E_NOT_FOUND; VPS_ERR="找不到这次部署的记录 (可能已经放弃、已经添加, 或超过 7 天被清理了)"; vps_job_error 0; return 1; }
  vps_pending_lock "$pid" || { VPS_CODE=E_BUSY; VPS_ERR="这次部署正在验证中, 请稍等"; vps_job_error 0; return 1; }
  VPS_LOCK_ID=$pid
  vps_pending_load "$pid" || { VPS_CODE=E_NOT_FOUND; VPS_ERR="找不到这次部署的记录 (可能已经放弃、已经添加, 或超过 7 天被清理了)"; vps_job_error 0; return 1; }
  job_step 1 15 "检查端口"
  cut -f6 "$VD/nodes.tsv" > "$VD/nodes.out"
  job_step 2 40 "验证连通"
  if ! vps_verify "$VD/nodes.out"; then
    ports=$(vps_nodes_ports); VPS_EV_LISTEN=''; VPS_EV_FW=''
    vps_diagnose; vps_reason_msg "$ports"; VPS_CODE=E_VPS_VERIFY
    vps_pending_note "$pid" "$VPS_REASON"; VPS_RESULT_EXTRA=$(vps_verify_extra "$pid" "$ports")
    vps_job_error 2; return 1
  fi
  job_step 3 80 "识别出口 IP"
  vps_nodes_plan "$VD/nodes.tsv"
  ips=$(cut -f2 "$VD/nodes.tsv" | awk 'NF { printf "%s\"%s\"", (n++ ? "," : ""), $0 }'); tags=$(cut -f1 "$VD/nodes.tsv" | awk 'NF { printf "%s\"%s\"", (n++ ? "," : ""), $0 }')
  id=$P_VPSID; [ -n "$id" ] || id=$(vps_saved_field "$P_HOST" "$P_SSHPORT" id); [ -n "$id" ] || id=$(vps_id_new)
  VPS_REC_ID=$id; VPS_REC_NAME=$P_NAME; VPS_REC_HOST=$P_HOST; VPS_REC_PORT=$P_SSHPORT; VPS_REC_USER=$P_USER; VPS_REC_OS=$P_OS; VPS_REC_HOSTKEY=$P_HOSTKEY; VPS_REC_IPS=$ips; VPS_REC_TAGS=$tags
  job_step 4 92 "保存到本机"
  TXN_RESULT="{\"nodes\":[$(vps_nodes_json "$VD/nodes.tsv")],\"ips\":[$ips],\"vps\":\"$id\",\"added\":$VPS_PLAN_NEW,\"unchanged\":$VPS_PLAN_SAME,\"updated\":$VPS_PLAN_UPD}"
  if [ -s "$VD/nodes.save.jsonl" ]; then
    VPS_NODES_FILE=$VD/nodes.save.jsonl; SRV_SAVE=$P_SAVE; APPLY_QUIET=1; op_txn "添加自己的服务器" txn_vps_save "$P_HOST"; rc=$?; SRV_SAVE=''
    [ "$rc" = 0 ] && [ "$P_SAVE" = 1 ] && sync_after_save
  else                                                                         # 节点本机都已经有了, 而且完全一样: 只补上服务器记录, 不动核心配置
    vps_rec_write; rc=$?
    oplog "${OP_WHO:-dashboard}" "添加自己的服务器" "$(kv host "$P_HOST" note "nodes already present" count "$VPS_PLAN_SAME")" ok
    job_ok "节点已经在本机的服务器列表里了" "$TXN_RESULT"
  fi
  [ "$rc" = 0 ] && vps_pending_delete "$pid"
  return $rc
}

# ---------- 任务: 重新识别出口 IP (补充新增 IP 的节点) ----------
vps_redetect_progress() { case $1 in 1) job_step 1 15 "检测系统与环境" ;; 2) job_step 2 40 "生成配置与密钥" ;; 5) job_step 3 70 "开放端口并启动" ;; esac; }
vps_redetect_job() { # <凭据文件>
  local role name priv os_pretty id ips tags added ports
  trap 'vps_cleanup' EXIT
  vps_cred_load "$1" || { VPS_CODE=E_INVALID; VPS_ERR="没有找到本次任务的凭据"; vps_job_error; return 1; }
  id=$V_ID
  V_HOSTKEY=$(vps_rec_field "$id" hostkey)                                   # 指纹以本机保存的记录为准 (固定校验)
  [ -n "$V_HOSTKEY" ] || { VPS_CODE=E_NOT_FOUND; VPS_ERR="找不到这台服务器的记录"; vps_job_error; return 1; }
  name=$(vps_rec_field "$id" name); os_pretty=$(vps_rec_field "$id" os)
  [ -n "$V_HOST" ] || V_HOST=$(vps_rec_field "$id" host)
  if ! vps_cred_check "$V_HOST" "$V_PORT" "$V_USER" "$V_MODE" "$V_PASSWORD" "$V_KEY" "$V_PASSPHRASE" "$V_SUDOPW" "$V_HOSTKEY"; then VPS_CODE=E_INVALID; vps_job_error; return 1; fi
  vps_prepare || { VPS_CODE=E_INVALID; VPS_ERR="无法创建临时目录"; vps_job_error; return 1; }
  job_step 0 5 "连接服务器"
  vps_hostkey_setup; case $? in 0) ;; 2) VPS_CODE=E_SSH_HOSTKEY; VPS_ERR="服务器的主机指纹与之前固定的不一致 (可能被中间人攻击, 或服务器重装过系统)"; vps_job_error; return 1 ;; *) VPS_CODE=E_SSH_UNREACHABLE; VPS_ERR="连不上 $V_HOST:$V_PORT (SSH): 地址或端口不对, 服务器没开机, 或防火墙挡住了 SSH 端口"; vps_job_error; return 1 ;; esac
  vps_playbook_ok || { VPS_CODE=E_VPS_NO_PLAYBOOK; VPS_ERR="部署脚本由 enana 云端下发: 请先登录, 并等「云端内容」同步完成后再试"; vps_job_error; return 1; }
  vps_progress() { vps_redetect_progress "$1"; }
  if ! vps_run probe user; then vps_job_error 1; return 1; fi
  priv=$(vps_kv privilege)
  case $priv in root|sudo_nopass|sudo_password) ;; *) VPS_CODE=E_VPS_PRIVILEGE; VPS_ERR="需要 root 权限 (当前用户不是 root, 也没有可用的 sudo)"; vps_job_error 1; return 1 ;; esac
  VPS_SEEN=0
  if ! vps_run redetect "$priv" --name "$name"; then vps_job_error 2; return 1; fi
  role=$(srv_list | awk -F'\t' -v n="$name-" 'index($1, n) == 1 { print $5; exit }'); case $role in pin|auto|dl|off) ;; *) role=pin ;; esac
  vps_collect_nodes "$role" || { VPS_CODE=E_VPS_VERIFY; VPS_ERR="部署脚本没有返回可用的节点"; vps_job_error 3; return 1; }
  : > "$VD/nodes.new.out"; : > "$VD/nodes.new.jsonl"; : > "$VD/nodes.new.tsv"; added=0
  while IFS=$'\t' read -r tag server port etype row ob; do
    srv_has_tag "$tag" && continue
    printf '%s\n' "$ob" >> "$VD/nodes.new.out"; printf '%s\n' "$row" >> "$VD/nodes.new.jsonl"; printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$tag" "$server" "$port" "$etype" "$row" "$ob" >> "$VD/nodes.new.tsv"; added=$((added + 1))
  done < "$VD/nodes.tsv"
  ips=$(cut -f2 "$VD/nodes.tsv" | awk 'NF { printf "%s\"%s\"", (n++ ? "," : ""), $0 }'); tags=$(cut -f1 "$VD/nodes.tsv" | awk 'NF { printf "%s\"%s\"", (n++ ? "," : ""), $0 }')
  job_step 4 80 "验证连通"
  if [ "$added" -gt 0 ] && ! vps_verify "$VD/nodes.new.out"; then
    ports=$(vps_nodes_ports "$VD/nodes.new.tsv"); vps_remote_evidence "$ports"; vps_diagnose; vps_reason_msg "$ports" redetect
    VPS_CODE=E_VPS_VERIFY; VPS_RESULT_EXTRA=$(printf ',"reason":"%s","port":%s,"ports":[%s],"tcp":"%s"' "${VPS_REASON:-unknown}" "${ports%%,*}" "$ports" "${VPS_TCP:-none}"); vps_job_error 4; return 1
  fi
  job_step 5 92 "保存到本机"
  VPS_REC_ID=$id; VPS_REC_NAME=$name; VPS_REC_HOST=$V_HOST; VPS_REC_PORT=$V_PORT; VPS_REC_USER=$V_USER; VPS_REC_OS=$os_pretty; VPS_REC_HOSTKEY=$V_HOSTKEY; VPS_REC_IPS=$ips; VPS_REC_TAGS=$tags
  TXN_RESULT="{\"nodes\":[$(vps_nodes_json "$VD/nodes.new.tsv")],\"ips\":[$ips],\"vps\":\"$id\",\"added\":$added}"
  if [ "$added" -gt 0 ]; then
    VPS_NODES_FILE=$VD/nodes.new.jsonl; APPLY_QUIET=1; op_txn "更新自己的服务器的出口 IP" txn_vps_save "$V_HOST"
  else
    vps_rec_write                                                           # 没有新增: 只刷新记录, 不动核心配置
    oplog "${OP_WHO:-dashboard}" "更新自己的服务器的出口 IP" "$V_HOST (没有新增)" ok
    job_ok "没有发现新的出口 IP" "$TXN_RESULT"
  fi
}
