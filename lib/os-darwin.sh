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
os_service_info() { # 一次 launchctl 调用得到 SVC_LOADED SVC_RUNNING SVC_PID
  local out; SVC_LOADED=0; SVC_RUNNING=0; SVC_PID=''
  out=$(launchctl print "$GUI/$LABEL" 2>/dev/null) || return 0
  SVC_LOADED=1
  case $out in *"state = running"*) SVC_RUNNING=1 ;; esac
  SVC_PID=$(printf '%s\n' "$out" | awk '/^[[:space:]]*pid = /{print $3; exit}')
}
os_service_loaded()  { launchctl print "$GUI/$LABEL" >/dev/null 2>&1; }
os_service_running() { launchctl print "$GUI/$LABEL" 2>/dev/null | grep -q 'state = running'; }
os_service_pid()     { launchctl print "$GUI/$LABEL" 2>/dev/null | awk '/^[[:space:]]*pid = /{print $3; exit}'; }
os_service_restart() { launchctl kickstart -k "$GUI/$LABEL" >/dev/null 2>&1 || os_service_start; }
os_service_start() {
  local i; launchctl bootout "$GUI/$LABEL" 2>/dev/null || true; sleep 1
  for i in 1 2 3; do launchctl bootstrap "$GUI" "$PLIST" 2>/dev/null && { launchctl kickstart "$GUI/$LABEL" >/dev/null 2>&1 || true; return 0; }; sleep 1; done
  return 1
}
os_service_stop() { launchctl bootout "$GUI/$LABEL" 2>/dev/null || true; }

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
<key>RunAtLoad</key>$([ "${AUTOSTART:-1}" = 1 ] && echo '<true/>' || echo '<false/>')
<key>KeepAlive</key>$([ "${AUTOSTART:-1}" = 1 ] && echo '<true/>' || echo '<false/>')
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
os_sysproxy_foreign() { # 打印正在使用其它代理设置的网络服务 (用于安装前提醒)
  local s k out
  while IFS= read -r s; do
    for k in webproxy securewebproxy socksfirewallproxy; do
      out=$(networksetup -get$k "$s" 2>/dev/null) || continue
      if printf '%s\n' "$out" | grep -q '^Enabled: Yes' && ! printf '%s\n' "$out" | grep -q "^Port: $PORT\$"; then printf '%s\n' "$s"; break; fi
    done
  done < <(os_sysproxy_services)
}
os_sysproxy_mine() { # 任何网络服务的代理指向本地端口 -> 0
  local s k out
  while IFS= read -r s; do
    for k in webproxy securewebproxy socksfirewallproxy; do
      out=$(networksetup -get$k "$s" 2>/dev/null) || continue
      printf '%s\n' "$out" | grep -q '^Enabled: Yes' && printf '%s\n' "$out" | grep -q "^Port: $PORT\$" && printf '%s\n' "$out" | grep -q '^Server: 127.0.0.1' && return 0
    done
  done < <(os_sysproxy_services)
  return 1
}
os_sysproxy_backup() {
  local s k
  : > "$H/proxy-backup.txt"
  while IFS= read -r s; do
    for k in webproxy securewebproxy socksfirewallproxy; do printf '[%s %s]\n%s\n' "$s" "$k" "$(networksetup -get$k "$s" 2>/dev/null)" >> "$H/proxy-backup.txt"; done
  done < <(os_sysproxy_services)
}
os_sysproxy_set() { # on|off  (需要管理员密码)
  local s k v; [ "$1" = on ] && v=开启 || v=关闭
  rm -f "$H/.cache-sysproxy"
  sudo -v || return 1
  while IFS= read -r s; do
    if [ "$1" = on ]; then
      sudo networksetup -setwebproxy "$s" 127.0.0.1 "$PORT"
      sudo networksetup -setsecurewebproxy "$s" 127.0.0.1 "$PORT"
      sudo networksetup -setsocksfirewallproxy "$s" 127.0.0.1 "$PORT"
      sudo networksetup -setproxybypassdomains "$s" localhost 127.0.0.1 '*.local' 169.254/16 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16
    else
      for k in webproxy securewebproxy socksfirewallproxy; do sudo networksetup -set${k}state "$s" off; done
    fi
    ok "$s: 系统代理已$v"
  done < <(os_sysproxy_services)
}

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
    if [ -L "$p" ] && [ "$(resolve_path "$p")" = "$H/enana" ]; then rm -f "$p" 2>/dev/null || sudo rm -f "$p"; fi
  done < <(shortcut_dirs)
  rm -f "$HOME/.config/fish/conf.d/enana.fish"
  for rc in "$HOME/.zshrc" "$HOME/.bash_profile"; do
    if [ -f "$rc" ] && grep -qF '# enana 快捷命令' "$rc"; then   # 只删除我们加的两行 (标记行 + 紧随其后的 export)
      awk -v m='# enana 快捷命令' '$0==m {skip=1; next} skip && /^export PATH="\$HOME\/\.local\/bin:\$PATH"$/ {skip=0; next} {skip=0; print}' "$rc" > "$rc.tmp" && cat "$rc.tmp" > "$rc"; rm -f "$rc.tmp"
    fi
  done
  return 0
}

os_open() { open "$1" >/dev/null 2>&1 || true; }

os_date_minus_days() { date -v-"${1:-0}"d +%F; }      # N 天前的日期 (YYYY-MM-DD); macOS 的 BSD date

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
