# macOS 适配层: 系统代理 / 后台服务 (launchd) / 快捷命令 / 系统识别。
# 将来的 Linux / Windows 版本实现同名函数即可 (lib/os-linux.sh, lib/os-windows.ps1), 其余代码不用改。

os_detect() { # 设置 OS MACOS MACOS_MAJOR ARCH CHIP BREW IS_ADMIN
  OS=$(uname -s); MACOS=$(sw_vers -productVersion 2>/dev/null || echo 0); MACOS_MAJOR=${MACOS%%.*}
  ARCH=amd64; [ "$(uname -m)" = arm64 ] && ARCH=arm64
  [ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" = 1 ] && ARCH=arm64      # Rosetta 终端里也选原生版
  CHIP=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "$ARCH")
  BREW=$(command -v brew 2>/dev/null || true)
  IS_ADMIN=0; id -Gn | tr ' ' '\n' | grep -qx admin && IS_ADMIN=1 || true
}

# ---------- launchd ----------
os_system_service_info() { # 一次 launchctl 调用得到 SVC_LOADED SVC_RUNNING SVC_PID
  local out; SVC_LOADED=0; SVC_RUNNING=0; SVC_PID=''
  out=$(launchctl print "$GUI/$LABEL" 2>/dev/null) || return 0
  SVC_LOADED=1
  case $out in *"state = running"*) SVC_RUNNING=1 ;; esac
  SVC_PID=$(printf '%s\n' "$out" | awk '/^[[:space:]]*pid = /{print $3; exit}')
}
os_system_service_loaded()  { launchctl print "$GUI/$LABEL" >/dev/null 2>&1; }
os_system_service_running() { launchctl print "$GUI/$LABEL" 2>/dev/null | grep -q 'state = running'; }
os_system_service_pid()     { launchctl print "$GUI/$LABEL" 2>/dev/null | awk '/^[[:space:]]*pid = /{print $3; exit}'; }
os_system_service_restart() { launchctl kickstart -k "$GUI/$LABEL" >/dev/null 2>&1 || os_system_service_start; }
os_system_service_start() {
  launchctl enable "$GUI/$LABEL" >/dev/null 2>&1 || return 1
  local i; launchctl bootout "$GUI/$LABEL" 2>/dev/null || true; sleep 1
  for i in 1 2 3; do launchctl bootstrap "$GUI" "$PLIST" 2>/dev/null && { launchctl kickstart "$GUI/$LABEL" >/dev/null 2>&1 || true; return 0; }; sleep 1; done
  return 1
}
os_system_service_stop() { launchctl bootout "$GUI/$LABEL" 2>/dev/null || true; }

_write_if_changed() { # 文件 内容  -> 0=已写入(内容有变化) 1=无变化
  [ -f "$1" ] && [ "$(cat "$1")" = "$2" ] && return 1
  mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"; return 0
}
os_write_plists() { # 写主服务 / 本地辅助服务(inetd) / 每日维护 三个 plist; 返回变化的数量
  local n=0 xml_head='<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>'
  _write_if_changed "$PLIST" "$xml_head
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>$H/sing-box</string><string>run</string><string>-c</string><string>$H/config.json</string><string>-D</string><string>$H</string></array>
<key>RunAtLoad</key>$([ "${AUTOSTART:-1}" = 1 ] && [ "${NETWORK_MODE:-system}" != tun ] && echo '<true/>' || echo '<false/>')
<key>KeepAlive</key>$([ "${AUTOSTART:-1}" = 1 ] && [ "${NETWORK_MODE:-system}" != tun ] && echo '<true/>' || echo '<false/>')
<key>StandardOutPath</key><string>$H/sing-box.log</string>
<key>StandardErrorPath</key><string>$H/sing-box.log</string>
</dict></plist>" && n=$((n+1))
  if [ "${SEL_helper:-1}" = 1 ]; then
    _write_if_changed "$PLIST_API" "$xml_head
<key>Label</key><string>$LABEL_API</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>$H/lib/api.sh</string></array>
<key>inetdCompatibility</key><dict><key>Wait</key><false/></dict>
<key>Sockets</key><dict><key>Listeners</key><dict><key>SockNodeName</key><string>127.0.0.1</string><key>SockServiceName</key><string>$API_PORT</string></dict></dict>
<key>AbandonProcessGroup</key><true/>
<key>EnvironmentVariables</key><dict><key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin</string></dict>
<key>StandardErrorPath</key><string>$H/api.log</string>
</dict></plist>" && n=$((n+1))
  fi
  # 每天凌晨一次的维护任务 (总是安装): 日志按天切分/压缩/按保留期清理 · 检查更新 · (设置里允许时) 每 3 天更新规则集与订阅
  _write_if_changed "$PLIST_UPD" "$xml_head
<key>Label</key><string>$LABEL_UPD</string>
<key>ProgramArguments</key><array><string>$H/enana</string><string>maintain</string><string>--quiet</string></array>
<key>StartCalendarInterval</key><dict><key>Hour</key><integer>3</integer><key>Minute</key><integer>30</integer></dict>
<key>RunAtLoad</key><false/>
<key>StandardOutPath</key><string>$H/update.log</string>
<key>StandardErrorPath</key><string>$H/update.log</string>
</dict></plist>" && n=$((n+1))
  # 每分钟一次的定时任务: 流量统计采样 + 登录会话心跳 (被其它设备下线时本机自动退出登录并关闭代理)
  _write_if_changed "$PLIST_TICK" "$xml_head
<key>Label</key><string>$LABEL_TICK</string>
<key>ProgramArguments</key><array><string>$H/enana</string><string>tick</string><string>--quiet</string></array>
<key>StartInterval</key><integer>60</integer>
<key>RunAtLoad</key><true/>
<key>StandardOutPath</key><string>$H/tick.log</string>
<key>StandardErrorPath</key><string>$H/tick.log</string>
</dict></plist>" && n=$((n+1))
  return $n
}
os_aux_load() { # 加载辅助 plist (已加载的先卸载再加载, 保证拿到新内容)
  local l p
  for l in "$LABEL_API:$PLIST_API" "$LABEL_UPD:$PLIST_UPD" "$LABEL_TICK:$PLIST_TICK"; do
    p=${l#*:}; l=${l%%:*}; [ -f "$p" ] || continue
    launchctl bootout "$GUI/$l" 2>/dev/null || true; launchctl bootstrap "$GUI" "$p" 2>/dev/null || true
  done
}
os_aux_unload() { launchctl bootout "$GUI/$LABEL_API" 2>/dev/null || true; launchctl bootout "$GUI/$LABEL_UPD" 2>/dev/null || true; launchctl bootout "$GUI/$LABEL_TICK" 2>/dev/null || true; }

# The configured file decides the backend during rollback, rather than a
# setting that may still describe the failed transaction.
os_service_info() {
  if enhanced_loaded; then
    local out; out=$(launchctl print "system/$TUN_LABEL" 2>/dev/null)
    SVC_LOADED=1; SVC_RUNNING=0; SVC_PID=''
    case $out in *"state = running"*) SVC_RUNNING=1 ;; esac
    SVC_PID=$(printf '%s\n' "$out" | awk '/^[[:space:]]*pid = /{print $3; exit}')
  else os_system_service_info; fi
}
os_service_loaded() { enhanced_loaded || os_system_service_loaded; }
os_service_running() { os_service_info; [ "$SVC_RUNNING" = 1 ]; }
os_service_pid() { os_service_info; printf '%s' "$SVC_PID"; }
os_service_start() {
  type core_mark_start >/dev/null 2>&1 && core_mark_start
  if enhanced_configured; then enhanced_start
  else
    local selected='' rc=0
    if enhanced_loaded; then selected=$(mktemp); clash GET /proxies > "$selected" 2>/dev/null || true; fi
    if ! enhanced_stop; then [ -z "$selected" ] || rm -f "$selected"; return 1; fi
    enhanced_paths; enhanced_system_log
    # Only a TUN -> System transition needs to restore user autostart settings.
    # Ordinary starts must not rewrite all plists from a differently resolved
    # /tmp vs /private/tmp path and cause a later installer restart.
    [ ! -e "$TUN_PLIST" ] || os_write_plists >/dev/null || true
    os_system_service_start || rc=$?
    if [ -n "$selected" ]; then
      if [ "$rc" = 0 ] && wait_port "$PORT" 15; then enhanced_restore_selectors "$selected"; else rc=1; fi
      rm -f "$selected"
    fi
    return "$rc"
  fi
}
os_service_restart() {
  local rc=0
  type core_mark_start >/dev/null 2>&1 && core_mark_start
  type core_restart_note >/dev/null 2>&1 && core_restart_note
  if enhanced_configured || enhanced_loaded; then
    # TUN: when the root snapshot is exactly what is installed (fingerprint unchanged) and the root helper is trusted, bounce the daemon through the
    # helper's `restart` action: no administrator prompt. Anything else (changed config / binary / rules, no or older helper, helper refused, daemon
    # not loaded) goes through the full install, which asks for administrator authorisation as before.
    if enhanced_restart_fast; then
      type oplog >/dev/null 2>&1 && oplog "${OP_WHO:-auto}" "重启核心方式" "$(kv mode tun via helper)" ok
      return 0
    fi
    if enhanced_configured && type oplog >/dev/null 2>&1; then
      os_service_start; rc=$?                              # 管理员框可能被取消: 结果出来之后才记这一条 (ok / cancelled / error), 失败时带上返回码
      oplog "${OP_WHO:-auto}" "重启核心方式" "$(kv mode tun via admin why "${ENHANCED_FAST_WHY:-}" rc "$([ "$rc" = 0 ] || echo "$rc")")" "$(enhanced_result "$rc")"
      return "$rc"
    fi
    os_service_start
  else os_system_service_restart; fi
}
os_service_stop() { enhanced_stop || return 1; os_system_service_stop; }

# ---------- 系统代理 (所有已启用的网络服务) ----------
os_sysproxy_services() { networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | grep -v '^\*' || true; }
os_sysproxy_ok() { # 所有网络服务的 Web / Secure Web / SOCKS 代理都已指向本地端口
  local s k out any=0
  while IFS= read -r s; do
    any=1
    for k in webproxy securewebproxy socksfirewallproxy; do
      out=$(networksetup -get$k "$s" 2>/dev/null) || return 1
      printf '%s\n' "$out" | grep -q '^Enabled: Yes' || return 1
      printf '%s\n' "$out" | grep -q "^Port: $PORT\$" || return 1
      printf '%s\n' "$out" | grep -q '^Server: 127.0.0.1' || return 1
    done
  done < <(os_sysproxy_services)
  [ "$any" = 1 ]
}
os_sysproxy_cached() { # networksetup 很慢: 结果缓存 20 秒 (设置/关闭系统代理后会清缓存)
  local f="$H/.cache-sysproxy" ts val t; t=$(date +%s)
  if [ -f "$f" ]; then read -r ts val < "$f"; if [ $(( t - ${ts:-0} )) -lt 20 ]; then [ "$val" = 1 ]; return; fi; fi
  if os_sysproxy_ok; then printf '%s 1\n' "$t" > "$f"; return 0; fi
  printf '%s 0\n' "$t" > "$f"; return 1
}
os_sysproxy_foreign() { # [旧端口] 打印正在使用其它代理设置的网络服务 (用于安装前提醒); 127.0.0.1 上的旧端口是本程序自己留下的 (端口后来被换了), 不算
  local s k out old=${1:-}
  while IFS= read -r s; do
    for k in webproxy securewebproxy socksfirewallproxy; do
      out=$(networksetup -get$k "$s" 2>/dev/null) || continue
      printf '%s\n' "$out" | grep -q '^Enabled: Yes' || continue
      printf '%s\n' "$out" | grep -q "^Port: $PORT\$" && continue
      [ -n "$old" ] && printf '%s\n' "$out" | grep -q "^Port: $old\$" && printf '%s\n' "$out" | grep -q '^Server: 127.0.0.1' && continue
      printf '%s\n' "$s"; break
    done
  done < <(os_sysproxy_services)
}
os_sysproxy_mine() { # [端口] 任何网络服务的代理指向本地端口 (默认 $PORT) -> 0
  local s k out
  while IFS= read -r s; do
    for k in webproxy securewebproxy socksfirewallproxy; do
      out=$(networksetup -get$k "$s" 2>/dev/null) || continue
      printf '%s\n' "$out" | grep -q '^Enabled: Yes' && printf '%s\n' "$out" | grep -q "^Port: ${1:-$PORT}\$" && printf '%s\n' "$out" | grep -q '^Server: 127.0.0.1' && return 0
    done
  done < <(os_sysproxy_services)
  return 1
}
os_sysproxy_backup() {
  local s k
  if [ ! -f "$H/proxy-state.json" ]; then
    ( umask 077; osascript -l JavaScript "$LIB/proxy-state.js" snapshot "$PORT" > "$H/proxy-state.json.tmp" ) && chmod 600 "$H/proxy-state.json.tmp" && mv "$H/proxy-state.json.tmp" "$H/proxy-state.json" || { rm -f "$H/proxy-state.json.tmp"; return 1; }
  fi
  : > "$H/proxy-backup.txt"
  while IFS= read -r s; do
    for k in webproxy securewebproxy socksfirewallproxy; do printf '[%s %s]\n%s\n' "$s" "$k" "$(networksetup -get$k "$s" 2>/dev/null)" >> "$H/proxy-backup.txt"; done
  done < <(os_sysproxy_services)
}
os_sysproxy_chain() { # on|off [networksetup 路径] -> 打印要执行的 networksetup 命令串 (每个服务名都做了 shell 引用; 用绝对路径, 因为提权后 PATH 会被换掉); 任何一条命令失败, 整串的退出码就是 1
  # 默认路径写死 (这串大多数要以 root 运行, 不能由环境变量决定); 只有当前用户直接修改 (os_sysproxy_apply ①) 才由测试传入替身的路径
  local s k c='r=0; ' q ns=${2:-/usr/sbin/networksetup}
  while IFS= read -r s; do
    q=$(enhanced_quote "$s")
    if [ "$1" = on ]; then
      c="$c$ns -setwebproxy $q 127.0.0.1 $PORT || r=1; $ns -setsecurewebproxy $q 127.0.0.1 $PORT || r=1; $ns -setsocksfirewallproxy $q 127.0.0.1 $PORT || r=1; $ns -setproxybypassdomains $q localhost 127.0.0.1 '*.local' 169.254/16 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 || r=1; "
    else
      for k in webproxy securewebproxy socksfirewallproxy; do c="$c$ns -set${k}state $q off || r=1; "; done
    fi
  done < <(os_sysproxy_services)
  printf '%sexit $r' "$c"
}
os_sysproxy_verify() { if [ "$1" = on ]; then os_sysproxy_ok; else ! os_sysproxy_mine; fi; }   # 修改之后回读确认: 开 = 所有网络服务都指向本程序; 关 = 没有任何服务还指向本程序
# ---------- 系统代理助手: 一次管理员授权, 之后不再弹密码框 ----------
# osascript 的「with administrator privileges」每次调用都是新进程, macOS 不会记住授权, 所以每次要改系统代理都会弹一次密码框。
# 第一次需要授权时, 在同一次授权里顺便安装一个只做「改系统代理」这一件事的小程序 (root 所有、用户改不了、端口写死, 见 lib/sysproxy-helper.tpl),
# 并给当前用户配置只开放这一个文件的免密 sudo (写入前用 visudo -cf 校验)。之后打开 / 关闭系统代理都直接调用它, 不再弹窗; 卸载时一并删除。
SYSPROXY_HELPER_VERSION=1
# 读 / 可信判断用的路径 (测试可以换成沙箱); 以 root 运行的一律用 *_root 写死的路径 (不经过 test_env)
os_sysproxy_helper_path()  { printf '%s/usr/local/libexec/enana/sysproxy-%s' "$(test_env ENANA_ROOT_PREFIX)" "$(id -u)"; }
os_sysproxy_sudoers_path() { printf '%s/etc/sudoers.d/enana-sysproxy-%s' "$(test_env ENANA_ROOT_PREFIX)" "$(id -u)"; }
os_sysproxy_helper_root()  { printf '/usr/local/libexec/enana/sysproxy-%s' "$(id -u)"; }
os_sysproxy_sudoers_root() { printf '/etc/sudoers.d/enana-sysproxy-%s' "$(id -u)"; }
os_sysproxy_helper_text() { # 把端口 / 版本和写死的 networksetup 路径 (助手以 root 运行, 所以路径不能由环境变量决定) 写进模板, 输出助手脚本全文
  local ns=/usr/sbin/networksetup
  [[ $PORT =~ ^[0-9]+$ ]] || return 1
  sed -e "s|@PORT@|$PORT|g" -e "s|@NETWORKSETUP@|$ns|g" -e "s|@VERSION@|$SYSPROXY_HELPER_VERSION|g" "$LIB/sysproxy-helper.tpl"
}
os_helper_trusted() { # <路径> <期望的 SHA-256>: 普通文件 (不是链接)、归 root (测试里归当前用户)、从它往上直到 /usr/local 的每一级目录都归 root 且组 / 其他人不可写、
  # 字节和期望的完全一样, 并且当前用户可以免密调用它 (sudo -n -l 只查规则, 不运行它: 不能靠运行助手来判断它是不是我们装的那份)。系统代理助手和 TUN 规则助手共用。
  local h=$1 want=$2 p d stop pre want_uid=0 got
  pre=$(test_env ENANA_ROOT_PREFIX)
  [ -z "$pre" ] || want_uid=$(id -u)
  [ -f "$h" ] && [ ! -L "$h" ] && [ "$(stat -f %u "$h" 2>/dev/null)" = "$want_uid" ] || return 1
  p=$(stat -f %Sp "$h" 2>/dev/null); [ "${p:5:1}" != w ] && [ "${p:8:1}" != w ] || return 1      # 组 / 其他人可写就不信任
  stop="$pre/usr/local"; d=$(dirname "$h")
  while :; do
    [ -d "$d" ] && [ ! -L "$d" ] && [ "$(stat -f %u "$d" 2>/dev/null)" = "$want_uid" ] || return 1
    p=$(stat -f %Sp "$d" 2>/dev/null); [ "${p:5:1}" != w ] && [ "${p:8:1}" != w ] || return 1
    [ "$d" != "$stop" ] || break
    [ "$d" != / ] || return 1
    d=$(dirname "$d")
  done
  got=$(shasum -a 256 "$h" 2>/dev/null | awk '{print $1}')
  [ -n "$want" ] && [ "$got" = "$want" ] || return 1
  sudo -n -l "$h" >/dev/null 2>&1
}
os_sysproxy_helper_port() { sed -n 's/^NS=.*; PORT=\([0-9][0-9]*\); VERSION=.*/\1/p' "$(os_sysproxy_helper_path)" 2>/dev/null | head -1; }      # 助手里写死的端口 (文件归 root、别人改不了, 见 os_helper_trusted)
# 版本对还不够: 端口是装助手时写死的, 如果后来端口被重新分配了, 旧助手会把系统代理指向旧端口、还报告成功 —— 所以写死的端口也要和现在的一致, 不一致就当作没装好 (重新授权并重装)。
os_sysproxy_helper_sha() { os_sysproxy_helper_text | shasum -a 256 | awk '{print $1}'; }      # 期望的字节 = 此刻渲染出来的助手 (端口 / 路径 / 版本都在里面, 所以字节一致就包含了端口检查)
os_sysproxy_helper_ok() { os_helper_trusted "$(os_sysproxy_helper_path)" "$(os_sysproxy_helper_sha)"; }
os_sysproxy_helper_files_ok() { # 装完之后核对文件本身: 助手是普通文件、模式 755; 免密规则是普通文件、模式 440 (属主 / 字节 / sudo 规则由 os_helper_trusted 核对)
  local h s; h=$(os_sysproxy_helper_path); s=$(os_sysproxy_sudoers_path)
  [ -f "$h" ] && [ ! -L "$h" ] && [ "$(stat -f %Lp "$h" 2>/dev/null)" = 755 ] && [ -f "$s" ] && [ ! -L "$s" ] && [ "$(stat -f %Lp "$s" 2>/dev/null)" = 440 ]
}
os_sysproxy_helper_install_cmds() { # 以 root 身份执行的命令串 (末尾带分号, 整条一行): 安装助手 + 免密规则 (目录检查同 lib/enhanced-root.sh 的 libexec_ok); 任何一步失败都不影响后面的系统代理设置, 也不会留下半成品规则
  # 路径和 install / visudo 都是写死的 (这串以 root 运行, 环境变量不能决定它写到哪里); 测试由假 sudo 改写 (tests/fakebin/sudo)
  local h s u d sd text b64 sha body own=0
  [ -z "${ENANA_NO_SYSPROXY_HELPER:-}" ] || return 1
  u=$(id -un); [[ $u =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  h=$(os_sysproxy_helper_root); s=$(os_sysproxy_sudoers_root); d=$(dirname "$h"); sd=$(dirname "$s")
  text=$(os_sysproxy_helper_text) || return 1
  b64=$(printf '%s\n' "$text" | base64 | tr -d '\n')
  sha=$(printf '%s\n' "$text" | shasum -a 256 | awk '{print $1}')
  # 主体是固定文本: 所有变量在前面用 enhanced_quote 写成赋值, 不再拼接路径进命令。以 root 运行时 PATH 由调用方用 /usr/bin/env -i 固定。
  body=$(cat <<'BODY'
t=$(/usr/bin/mktemp -d) && printf %s "$B64" > "$t/b64" && /usr/bin/base64 -D < "$t/b64" > "$t/h" && [ "$(/usr/bin/shasum -a 256 "$t/h" | /usr/bin/awk '{print $1}')" = "$SHA" ] && /bin/bash -n "$t/h" && { ( for x in /usr/local/libexec "$D"; do [ -e "$x" ] || [ -L "$x" ] || /usr/bin/install -d -m 755 -o root -g wheel "$x" || exit 1; done; for x in /usr/local /usr/local/libexec "$D"; do [ -d "$x" ] && [ ! -L "$x" ] && [ "$(/usr/bin/stat -f %u "$x")" = "$OWN" ] && p=$(/usr/bin/stat -f %Sp "$x") && [ "${p:5:1}" != w ] && [ "${p:8:1}" != w ] || exit 1; done ) && /bin/rm -f "$H" "$S" && /usr/bin/install -m 755 -o root -g wheel "$t/h" "$H" && /usr/bin/install -d -m 755 -o root -g wheel "$SD" && printf '%s ALL=(root) NOPASSWD: %s\n' "$U" "$H" > "$t/s" && /usr/sbin/visudo -cf "$t/s" >/dev/null && /usr/bin/install -m 440 -o root -g wheel "$t/s" "$S"; } >/dev/null 2>&1; /bin/rm -rf "$t"
BODY
  )
  # OWN 是数字 0, 故意不加引号: 对话框那层还会再套一层 enhanced_quote, 带引号的形式在那里对不上测试的属主改写 (tests/fakebin/rootpaths.sh)
  printf 'H=%s S=%s SD=%s D=%s U=%s SHA=%s B64=%s OWN=%s; %s; ' "$(enhanced_quote "$h")" "$(enhanced_quote "$s")" "$(enhanced_quote "$sd")" "$(enhanced_quote "$d")" \
    "$(enhanced_quote "$u")" "$(enhanced_quote "$sha")" "$(enhanced_quote "$b64")" "$own" "$body"
}
os_sysproxy_helper_remove() { # 卸载: 删掉助手和免密规则 (需要管理员授权; 调用前已经 sudo -v 过)。拒绝授权不阻止卸载, 只是提示手动删除
  local h s hr sr; h=$(os_sysproxy_helper_path); s=$(os_sysproxy_sudoers_path); hr=$(os_sysproxy_helper_root); sr=$(os_sysproxy_sudoers_root)
  [ -e "$h" ] || [ -e "$s" ] || return 0
  if sudo rm -f "$sr" "$hr" 2>/dev/null; then sudo rmdir "$(dirname "$hr")" 2>/dev/null || true; return 0; fi      # 以 root 删除: 只用写死的路径
  warn "没能删除系统代理助手, 可以手动删除: sudo rm -f $sr $hr"; return 0
}
os_admin_dialog() { # <命令串>  弹出 macOS 原生的管理员密码框 (仪表盘的后台服务没有终端): 命令串放进 /usr/bin/env -i (清空环境) + /bin/bash -p -c 里运行; 写法与 enhanced_admin 的对话框分支相同
  local cmd; cmd="/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash -p -c $(enhanced_quote "$1")"
  cmd=$(printf '%s' "$cmd" | sed 's/\\/\\\\/g; s/"/\\"/g')
  osascript -e "do shell script \"$cmd\" with administrator privileges"
}
# 修改系统代理 (所有已启用的网络服务)。打开 / 关闭系统代理都不再要求「必须在终端里输入密码」:
#   ① 当前用户直接修改 (管理员账户多数不需要密码)  ①b 系统代理助手 (授权过一次, 免密)  ② 终端里用 sudo  ③ 已有免密 sudo  ④ 弹出 macOS 原生管理员密码框 (仪表盘用)
# 每次修改后回读确认, 结果记在 SYSPROXY_METHOD (already|direct|helper|sudo|sudo-nopass|dialog)、SYSPROXY_HELPER (used|installed|failed: 系统代理助手这次的情况) 与 SYSPROXY_ERR (失败原因, 英文短码)。
# 这个函数不向标准输出打印任何内容: 仪表盘的辅助服务里标准输出就是 HTTP 响应。
os_sysproxy_apply() { # on|off [force|quiet]  -> 0 = 已是想要的状态 · 1 = 没有改成功; force = 已经是想要的状态也重新写一遍 (修复被改过的绕过列表); quiet = 不弹任何授权框, 需要管理员授权时直接返回 1 (SYSPROXY_ERR=needs-admin)
  local want=$1 c errf msg rc inst quiet=''
  [ "${2:-}" = quiet ] && quiet=1
  SYSPROXY_METHOD=''; SYSPROXY_ERR=''; SYSPROXY_HELPER=''
  [[ $PORT =~ ^[0-9]+$ ]] || { SYSPROXY_ERR=bad-port; return 1; }      # 端口会被拼进以 root 运行的命令串 (os_sysproxy_chain / 安装助手), 只接受数字
  rm -f "$H/.cache-sysproxy"
  if [ "${2:-}" != force ] && os_sysproxy_verify "$want"; then SYSPROXY_METHOD=already; return 0; fi
  if [ "$want" = on ]; then os_sysproxy_backup >/dev/null 2>&1 || { SYSPROXY_ERR=backup-failed; return 1; }; fi
  c=$(os_sysproxy_chain "$want"); [ "$c" != 'r=0; exit $r' ] || { SYSPROXY_ERR=no-network-service; return 1; }
  errf=$(mktemp)
  /bin/bash -c "$(os_sysproxy_chain "$want" "$(test_env ENANA_NETWORKSETUP /usr/sbin/networksetup)")" >/dev/null 2>"$errf"; rc=$?      # ① 直接修改 (当前用户, 不提权: 测试可换成替身路径)
  # 成功 = 所有命令都成功, 或回读确认所有网络服务都已是想要的状态 (个别服务读取出错时, 命令都成功了也不能判失败, 否则会反复要密码)
  if [ "$rc" = 0 ] || os_sysproxy_verify "$want"; then SYSPROXY_METHOD=direct; rm -f "$errf" "$H/.cache-sysproxy"; return 0; fi
  if os_sysproxy_helper_ok; then                                                       # ①b 系统代理助手 (授权过一次): 免密, 不弹窗
    SYSPROXY_METHOD=helper; sudo -n "$(os_sysproxy_helper_root)" "$want" >/dev/null 2>"$errf"; rc=$?
    rm -f "$H/.cache-sysproxy"
    if [ "$rc" = 0 ] || os_sysproxy_verify "$want"; then SYSPROXY_HELPER=used; rm -f "$errf"; return 0; fi
    SYSPROXY_HELPER=failed
  fi
  # 助手还没装 (或失败): 这一次的授权顺便把助手装上 (inst), 以后打开 / 关闭系统代理都不再要密码
  inst=$(os_sysproxy_helper_install_cmds 2>/dev/null || true)
  if [ -z "$quiet" ] && [ -t 0 ] && [ -t 1 ]; then SYSPROXY_METHOD=sudo; sudo /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash -p -c "$inst$c" 2>"$errf" >/dev/null; rc=$?     # ② 终端: 密码提示走 /dev/tty
  elif sudo -n true >/dev/null 2>&1; then SYSPROXY_METHOD=sudo-nopass; sudo -n /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash -p -c "$c" >/dev/null 2>"$errf"; rc=$?   # ③ 本来就有免密 sudo: 不需要助手
  elif [ -n "$quiet" ]; then rm -f "$errf" "$H/.cache-sysproxy"; SYSPROXY_ERR=needs-admin; return 1
  else SYSPROXY_METHOD=dialog; os_admin_dialog "$inst$c" >/dev/null 2>"$errf"; rc=$?; fi                      # ④
  rm -f "$H/.cache-sysproxy"
  if [ -n "$inst" ] && [ "$SYSPROXY_METHOD" != sudo-nopass ]; then
    if os_sysproxy_helper_ok && os_sysproxy_helper_files_ok; then SYSPROXY_HELPER=installed
    elif [ "$rc" = 0 ]; then SYSPROXY_HELPER=failed; fi      # 授权步骤说成功了, 但助手 / 免密规则没有装上 (文件或模式不对): 记下来 (以后每次还是要输入密码)
  fi
  if [ "$rc" = 0 ] || os_sysproxy_verify "$want"; then rm -f "$errf"; return 0; fi
  msg=$(head -c 300 "$errf" 2>/dev/null | tr '\n\t' '  '); rm -f "$errf"
  case $msg in
    *"-128"*|*"User canceled"*|*"user canceled"*) SYSPROXY_ERR=user-canceled ;;
    *"not in the sudoers"*|*"not allowed to"*) SYSPROXY_ERR=not-admin ;;
    *"-1743"*|*"not allowed"*|*"Not authorized"*|*"not authorized"*) SYSPROXY_ERR=not-authorized ;;
    *"incorrect password"*|*"Sorry, try again"*) SYSPROXY_ERR=wrong-password ;;
    *"window server"*|*"WindowServer"*|*"-1708"*) SYSPROXY_ERR=no-gui-session ;;
    '') SYSPROXY_ERR=not-applied ;;
    *) SYSPROXY_ERR=failed ;;
  esac
  return 1
}
os_sysproxy_set() { # on|off  终端里使用: 逐项打印结果; 同样会记入操作记录
  local s v rc; [ "$1" = on ] && v=开启 || v=关闭
  os_sysproxy_apply "$1" force; rc=$?
  sysproxy_record "${OP_WHO:-terminal}" "$1" "$rc"
  if [ "$rc" != 0 ]; then warn "系统代理没有${v}成功 (原因: ${SYSPROXY_ERR:-unknown}); 可以在仪表盘概览里再试一次"; return 1; fi
  [ "$SYSPROXY_HELPER" != failed ] || warn "系统代理助手没有装好: 以后打开 / 关闭系统代理还要输入密码 (重新执行一次可以再试)"
  while IFS= read -r s; do ok "$s: 系统代理已$v"; done < <(os_sysproxy_services)
}
os_sysproxy_restore_root() { # 以 root 恢复系统代理: proxy-state.js 与收据各读一次, 摘要按同一份字节算; root 把它们解码到自己的临时目录再核对摘要, 不一致就不运行 (返回非 0)
  local js rcp jb rb jsb rcb cmd body
  [[ $PORT =~ ^[0-9]+$ ]] || return 1
  js=$(cat "$LIB/proxy-state.js"; printf x); js=${js%x}
  rcp=$(cat "$H/proxy-state.json"; printf x); rcp=${rcp%x}
  jsb=$(printf '%s' "$js" | shasum -a 256 | awk '{print $1}'); rcb=$(printf '%s' "$rcp" | shasum -a 256 | awk '{print $1}')
  jb=$(printf '%s' "$js" | base64 | tr -d '\n'); rb=$(printf '%s' "$rcp" | base64 | tr -d '\n')
  body=$(cat <<'BODY'
t=$(/usr/bin/mktemp -d) && printf %s "$JB" > "$t/j.b64" && /usr/bin/base64 -D < "$t/j.b64" > "$t/proxy-state.js" && printf %s "$RB" > "$t/r.b64" && /usr/bin/base64 -D < "$t/r.b64" > "$t/receipt.json" && [ "$(/usr/bin/shasum -a 256 "$t/proxy-state.js" | /usr/bin/awk '{print $1}')" = "$JSSHA" ] && [ "$(/usr/bin/shasum -a 256 "$t/receipt.json" | /usr/bin/awk '{print $1}')" = "$RCSHA" ] && /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin "$OSA" -l JavaScript "$t/proxy-state.js" restore "$PORT" "$t/receipt.json"; st=$?; /bin/rm -rf "$t"; exit $st
BODY
  )
  cmd=$(printf 'JB=%s RB=%s JSSHA=%s RCSHA=%s PORT=%s OSA=%s; %s' "$(enhanced_quote "$jb")" "$(enhanced_quote "$rb")" "$(enhanced_quote "$jsb")" "$(enhanced_quote "$rcb")" "$(enhanced_quote "$PORT")" "$(enhanced_quote /usr/bin/osascript)" "$body")
  sudo /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash -p -c "$cmd"
}
os_sysproxy_uninstall() {
  # Restore proxy fields/bypass lists, not just Enable=off with localhost still
  # configured. Never erase foreign endpoints installed after enana.
  local status; status=$(osascript -l JavaScript "$LIB/proxy-state.js" check "$PORT" "$H/proxy-state.json") || return 1
  if [ "$status" = changed ]; then
    sudo -v || return 1
    os_sysproxy_restore_root || return 1
  fi
  if [ -e "$(os_sysproxy_helper_path)" ] || [ -e "$(os_sysproxy_sudoers_path)" ]; then sudo -v 2>/dev/null; os_sysproxy_helper_remove; fi      # 一次授权时安装的系统代理助手和免密规则
  return 0
}
os_stop_owned_jobs() { perl "$LIB/stop-jobs.pl" "$H" "$$"; }

# ---------- 快捷命令 enana ----------
# 目标: 装完在任何终端输入 enana 都能打开控制台。优先放进「已经在 PATH 里、当前用户能写」的目录 (马上可用, 不用密码, 不用重开终端);
# 没有这样的目录再用管理员权限放进 /usr/local/bin (macOS 默认 PATH 里一定有它); 都不行才放 ~/.local/bin 并把它写进 shell 配置 (新开的终端才生效)。
SHORTCUT_NAME=enana
SHORTCUT_DIR=${ENANA_SHORTCUT_DIR:-}           # 指定了就只用这个目录 (测试 / 自定义)
_path_has() { case ":$PATH:" in *":$1:"*) return 0 ;; *) return 1 ;; esac; }
shortcut_dirs() { # 可能放着快捷命令的目录 (每行一个), 按优先顺序; ENANA_SHORTCUT_DIRS (空格分隔) 只给测试用
  if [ -n "$SHORTCUT_DIR" ]; then printf '%s\n' "$SHORTCUT_DIR"
  elif [ -n "${ENANA_SHORTCUT_DIRS:-}" ]; then printf '%s\n' $ENANA_SHORTCUT_DIRS
  else printf '%s\n' /usr/local/bin /opt/homebrew/bin "$HOME/.local/bin" "$HOME/bin"; fi
}
shortcut_path() { # 打印已安装的快捷命令路径 (指向本程序的才算)
  local d p
  while IFS= read -r d; do
    p="$d/$SHORTCUT_NAME"
    [ -L "$p" ] && [ "$(readlink "$p")" = "$H/enana" ] && { printf '%s\n' "$p"; return 0; }
  done < <(shortcut_dirs)
  return 1
}
shortcut_rc_file() { # 当前登录 shell 的启动配置文件 (把 ~/.local/bin 加进 PATH 用)
  case ${SHELL:-} in */zsh) printf '%s' "$HOME/.zshrc" ;; */fish) printf '%s' "$HOME/.config/fish/conf.d/enana.fish" ;; *) printf '%s' "$HOME/.bash_profile" ;; esac
}
shortcut_install() { # 成功时设置 SHORTCUT (路径); SHORTCUT_RC 非空 = 当前终端还用不了, 要重新打开终端 (或执行 PATH 那一行)
  local d rc marker='# enana 快捷命令'
  SHORTCUT=''; SHORTCUT_RC=''
  while IFS= read -r d; do                                     # ① 已经在 PATH 里的可写目录
    [ -n "$SHORTCUT_DIR" ] && mkdir -p "$d" 2>/dev/null
    { [ -n "$SHORTCUT_DIR" ] || _path_has "$d"; } && [ -d "$d" ] && [ -w "$d" ] || continue
    ln -sf "$H/enana" "$d/$SHORTCUT_NAME" 2>/dev/null && { SHORTCUT=$d/$SHORTCUT_NAME; return 0; }
  done < <(shortcut_dirs)
  if [ -z "$SHORTCUT_DIR" ] && [ "${IS_ADMIN:-0}" = 1 ] && sudo -v 2>/dev/null && sudo mkdir -p /usr/local/bin && sudo ln -sf "$H/enana" "/usr/local/bin/$SHORTCUT_NAME"; then   # ② 管理员权限 (要密码)
    SHORTCUT=/usr/local/bin/$SHORTCUT_NAME; return 0
  fi
  mkdir -p "$HOME/.local/bin" && ln -sf "$H/enana" "$HOME/.local/bin/$SHORTCUT_NAME" || return 1     # ③ 用户目录 + PATH 配置
  SHORTCUT="$HOME/.local/bin/$SHORTCUT_NAME"
  _path_has "$HOME/.local/bin" && return 0
  rc=$(shortcut_rc_file); mkdir -p "$(dirname "$rc")"
  if ! grep -qF "$marker" "$rc" 2>/dev/null; then
    case $rc in
      */enana.fish) printf '%s\ncontains $HOME/.local/bin $PATH; or set -gx PATH $HOME/.local/bin $PATH\n' "$marker" >> "$rc" ;;
      *) printf '\n%s\nexport PATH="$HOME/.local/bin:$PATH"\n' "$marker" >> "$rc" ;;
    esac
  fi
  SHORTCUT_RC=$rc
}
shortcut_remove() {
  local d p rc
  while IFS= read -r d; do
    p="$d/$SHORTCUT_NAME"
    if [ -L "$p" ] && [ "$(resolve_path "$p")" = "$H/enana" ]; then rm -f "$p" 2>/dev/null || sudo rm -f "$p" || return 1; fi
  done < <(shortcut_dirs)
  for rc in "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.config/fish/conf.d/enana.fish"; do
    if [ -f "$rc" ] && grep -qF '# enana 快捷命令' "$rc"; then   # 只删除我们加的两行 (标记行 + 紧随其后的 export)
      awk -v m='# enana 快捷命令' '$0==m {skip=1; next} skip && (/^export PATH="\$HOME\/\.local\/bin:\$PATH"$/ || /^contains \$HOME\/\.local\/bin \$PATH; or set -gx PATH \$HOME\/\.local\/bin \$PATH$/) {skip=0; next} {skip=0; print}' "$rc" > "$rc.tmp" && cat "$rc.tmp" > "$rc" || { rm -f "$rc.tmp"; return 1; }
      rm -f "$rc.tmp" || return 1
      [ "$rc" != "$HOME/.config/fish/conf.d/enana.fish" ] || [ -s "$rc" ] || rm -f "$rc" || return 1
    fi
  done
  return 0
}

os_open() { open "$1" >/dev/null 2>&1 || true; }

os_date_minus_days() { date -v-"${1:-0}"d +%F; }      # N 天前的日期 (YYYY-MM-DD); macOS 的 BSD date
os_birth_time() { stat -f %B "$1" 2>/dev/null || echo 0; }        # 文件 / 目录的创建时间 (epoch 秒; .app 目录 = 装到这台电脑上的时间, 应用被更新替换后会变)
os_date_at() { date -r "$1" "+%F %T"; }                  # epoch 秒 -> 本地时间 (BSD date)
os_date_minus_hours() { date -v-"${1:-0}"H "+%F %T"; }  # N 小时前的本地时间 (YYYY-MM-DD HH:MM:SS)

# 品牌更名前的安装 (v1 / v2 早期: ~/.tokyo-proxy, launchd 标签 local.tokyo-proxy*, 命令 tproxy / ereldaili) -> 迁移到 ~/.enana
os_legacy_cleanup() { # 卸载旧的 launchd 任务、旧快捷命令、旧 shell 配置里的标记行; 不动数据目录
  local l f p d rc
  for l in local.tokyo-proxy local.tokyo-proxy.api local.tokyo-proxy.update; do
    launchctl bootout "$GUI/$l" 2>/dev/null || true
    rm -f "$PLIST_DIR/$l.plist"
  done
  for f in tproxy ereldaili; do
    for d in /usr/local/bin /opt/homebrew/bin "$HOME/.local/bin" ${SHORTCUT_DIR:+"$SHORTCUT_DIR"}; do
      p="$d/$f"
      [ -L "$p" ] || continue
      case "$(readlink "$p")" in *"/$LEGACY_HOME_NAME/"*|*"/.enana/"*) rm -f "$p" 2>/dev/null || sudo rm -f "$p" ;; esac
    done
  done
  for rc in "$HOME/.zshrc" "$HOME/.bash_profile"; do
    [ -f "$rc" ] && grep -qE '^# (tproxy|ereldaili|tokyo-proxy) 快捷命令$' "$rc" || continue
    awk '/^# (tproxy|ereldaili|tokyo-proxy) 快捷命令$/ {skip=1; next} skip && /^export PATH="\$HOME\/\.local\/bin:\$PATH"$/ {skip=0; next} {skip=0; print}' "$rc" > "$rc.tmp" && cat "$rc.tmp" > "$rc"; rm -f "$rc.tmp"
  done
  return 0
}
