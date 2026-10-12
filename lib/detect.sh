# 系统与网络识别 + 安装推荐 + 外部代理内核清单。依赖 common.sh os-darwin.sh enhanced.sh fetch.sh servers.sh。
# 识别的目的: 给出「最适合这台电脑」的安装选项推荐, 用户仍可用键盘逐项修改。

_probe() { # 名称 URL  -> 在 $PROBE_DIR/名称 写入毫秒数 (0=不通)
  local out code t
  out=$(curl -s -o /dev/null -m 6 --connect-timeout 5 --noproxy '*' -w '%{http_code} %{time_total}' "$2" 2>/dev/null || true)
  code=${out%% *}; t=${out##* }
  if [ -n "$code" ] && [ "$code" != 000 ]; then awk -v t="$t" 'BEGIN{printf "%d\n", t*1000}'; else echo 0; fi > "$PROBE_DIR/$1"
}

probe_net() { # 并行探测, 设置 NET_GITHUB NET_JSD NET_GOOGLE NET_BAIDU NET_REGION (ENANA_SKIP_PROBE=1 跳过, 用于离线/测试)
  if [ -n "${ENANA_SKIP_PROBE:-}" ]; then NET_GITHUB=${NET_GITHUB:-300}; NET_JSD=${NET_JSD:-100}; NET_GOOGLE=${NET_GOOGLE:-0}; NET_BAIDU=${NET_BAIDU:-30}; NET_REGION=mainland; return 0; fi
  PROBE_DIR=$(mktemp -d)
  _probe github https://github.com &
  _probe jsd    https://fastly.jsdelivr.net &
  _probe google http://www.gstatic.com/generate_204 &
  _probe baidu  https://www.baidu.com &
  wait
  NET_GITHUB=$(cat "$PROBE_DIR/github"); NET_JSD=$(cat "$PROBE_DIR/jsd"); NET_GOOGLE=$(cat "$PROBE_DIR/google"); NET_BAIDU=$(cat "$PROBE_DIR/baidu")
  rm -rf "$PROBE_DIR"
  if [ "$NET_GOOGLE" -gt 0 ]; then NET_REGION=overseas
  elif [ "$NET_BAIDU" -gt 0 ]; then NET_REGION=mainland
  else NET_REGION=offline; fi
}

detect_others() { # 其它正在运行的代理软件 -> OTHER_PROXY (逗号分隔, 可能为空); sing-box 按可执行文件路径判断: 本程序自己的核心不算
  OTHER_PROXY=$({ ps -axo comm= 2>/dev/null | awk -F/ '{print $NF}' | grep -iE '^(ClashX|Clash Verge|clash-verge|mihomo|Stash|Surge|V2rayU|V2rayN|Shadowsocks|ShadowsocksX|Qv2ray)' || true; _foreign_sb_procs | sed 's/.*/sing-box/' || true; } | sort -u | paste -sd, - || true)
  return 0
}

# ---------- 外部代理内核 (只读清单: 不结束、不卸载、不修改任何东西, 只记名称、路径、进程号, 不读取配置内容) ----------
# 本程序自己的 sing-box 只按可执行文件路径认: 用户态核心 $SB, 以及增强模式 TUN 根目录下的任何文件 (root 副本, 暂存中的 .prepare.*); 名字相同、路径不同的都是外部的
_enana_core_path() { enhanced_paths; [ "$1" = "$SB" ] && return 0; case $1 in "$TUN_ROOT"/*) return 0 ;; esac; return 1; }
_pid_path() { ps -o comm= -p "$1" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }   # macOS 的 comm 是完整路径; 进程已退出则为空
_sb_procs() { ps -axo pid=,comm= 2>/dev/null | awk '{ pid = $1; sub(/^[ \t]*[0-9]+[ \t]+/, ""); p = $0; sub(/.*\//, "", p); if (p == "sing-box") print pid "\t" $0 }'; }
_foreign_sb_procs() { _sb_procs | while IFS="$(printf '\t')" read -r _pid _path; do _enana_core_path "$_path" || printf '%s\t%s\n' "$_pid" "$_path"; done; }
_enana_owned() { # 进程号 路径 端口 本程序的服务进程号 -> 0 = 本程序自己的 (核心 / 后台服务 / launchd 代管的本程序辅助端口)
  _enana_core_path "$2" && return 0
  [ -n "$4" ] && [ "$1" = "$4" ] && return 0
  [ "${2##*/}" = launchd ] && [ "$3" = "$API_PORT" ] && os_label_loaded "$LABEL_API" && return 0
  return 1
}
_brew_core() { # Homebrew 装的 sing-box 的真实路径 (enana 的 core_from_brew 就是从这里拷贝的): 不算外部程序; 没有 brew 就空
  [ -n "${BREW:-}" ] || return 0
  resolve_path "$("$BREW" --prefix 2>/dev/null)/bin/sing-box" 2>/dev/null || true
}
_fg_records() { # 每行 类别<TAB>内容 (不运行任何 sing-box, 不读取配置内容)
  local d p pid svc iface addr brewbin ports
  local -a dirs
  svc=$(os_service_pid 2>/dev/null || true)
  brewbin=$(_brew_core)
  if [ -n "$(test_env ENANA_SINGBOX_DIRS)" ]; then IFS=: read -r -a dirs <<< "$(test_env ENANA_SINGBOX_DIRS)"
  else dirs=(/usr/local/bin /opt/homebrew/bin /usr/bin "$HOME/.local/bin"); fi
  { command -v sing-box 2>/dev/null || true; for d in "${dirs[@]}"; do printf '%s\n' "$d/sing-box"; done; } | while IFS= read -r p; do
    [ -x "$p" ] || continue
    p=$(resolve_path "$p")
    _enana_core_path "$p" && continue
    [ -n "$brewbin" ] && [ "$p" = "$brewbin" ] && continue
    printf 'sing-box-binary\t%s\n' "$p"
  done
  launchctl list 2>/dev/null | awk -F'\t' 'NR > 1 && tolower($3) ~ /sing-box/ && $3 !~ /^com\.enana\./ { print "launchd-job\t" $3 "\tpid=" $1 }'
  for d in "$PLIST_DIR" "$(test_env ENANA_TUN_PLIST_DIR /Library/LaunchDaemons)"; do
    find "$d" -maxdepth 1 -iname '*sing-box*.plist' ! -name 'com.enana.*' 2>/dev/null | while IFS= read -r p; do printf 'launchd-plist\t%s\n' "$p"; done
  done
  _foreign_sb_procs | while IFS="$(printf '\t')" read -r pid p; do printf 'process\tpid=%s\t%s\n' "$pid" "$p"; done
  for d in "$HOME/.config/sing-box" "$(test_env ENANA_ROOT_PREFIX)/etc/sing-box" "$HOME/Library/Application Support/sing-box"; do
    [ -d "$d" ] && printf 'config-dir\t%s\n' "$d"
  done
  iface=$(route -n get default 2>/dev/null | awk '/interface:/ { print $2; exit }')
  case $iface in utun*) ifconfig "$iface" 2>/dev/null | grep -q 'inet 172\.19\.0\.1 ' || printf 'default-route-tun\t%s\n' "$iface" ;; esac
  ports=" $PORT $UI_PORT $API_PORT $SPEED_PORT "
  lsof -nP -iTCP -sTCP:LISTEN -Fpn 2>/dev/null | awk '/^p/ { pid = substr($0, 2) } /^n/ { print pid "\t" substr($0, 2) }' | sort -u | while IFS="$(printf '\t')" read -r pid addr; do
    case $ports in *" ${addr##*:} "*) ;; *) continue ;; esac              # 只记 enana 自己的四个端口 (清单用来解释端口冲突)
    p=$(_pid_path "$pid"); [ -n "$p" ] || continue                        # 查的时候已经退出了: 不记
    _enana_owned "$pid" "$p" "${addr##*:}" "$svc" || printf 'tcp-listener\t%s\tpid=%s\t%s\n' "$addr" "$pid" "$p"
  done
}
_fg_count() { printf '%s\n' "$FOREIGN_TEXT" | awk -F'\t' -v k="$1" '$1 == k { n++ } END { print n + 0 }'; }
detect_foreign() { # 外部 sing-box 清单 -> FOREIGN_TEXT (每行 类别<TAB>内容) 与个数: FOREIGN_BIN 程序 · FOREIGN_LAUNCHD 已加载的 launchd 任务 · FOREIGN_PLIST 只有配置文件 · FOREIGN_PROC 运行中的进程 · FOREIGN_CFG 配置目录 · FOREIGN_TUN(0/1) 默认路由经过别的 TUN · FOREIGN_TUN_IF · FOREIGN_LISTEN
  FOREIGN_TEXT=$(_fg_records | sort -u)
  FOREIGN_BIN=$(_fg_count sing-box-binary); FOREIGN_LAUNCHD=$(_fg_count launchd-job); FOREIGN_PLIST=$(_fg_count launchd-plist)
  FOREIGN_PROC=$(_fg_count process); FOREIGN_CFG=$(_fg_count config-dir)
  FOREIGN_TUN=$(_fg_count default-route-tun); FOREIGN_LISTEN=$(_fg_count tcp-listener)
  FOREIGN_TUN_IF=$(printf '%s\n' "$FOREIGN_TEXT" | awk -F'\t' '$1 == "default-route-tun" { print $2; exit }')
  return 0
}
foreign_write_inventory() { # 清单写进安装目录, 供支持人员查看 (只有名称、路径、进程号); 临时文件在 umask 077 下创建, 再原子替换
  local f="$H/foreign-inventory.txt" t
  t=$(umask 077; mktemp "$H/.foreign-inventory.XXXXXX") || return 1
  { printf 'enana foreign sing-box inventory | %s | enana %s | own core %s\n' "$(date '+%F %T')" "$VERSION" "$SB"
    printf 'names, paths and process IDs only; configuration files are never read\n'
    if [ -n "$FOREIGN_TEXT" ]; then printf '%s\n' "$FOREIGN_TEXT" | awk -F'\t' '{ s = $1; for (i = 2; i <= NF; i++) s = s "  " $i; print s }'
    else printf 'nothing foreign found\n'; fi
  } > "$t" && chmod 600 "$t" && mv -f "$t" "$f" || { rm -f "$t"; return 1; }
}
_noninteractive() { [ -n "${ENANA_YES:-}" ] || [ ! -t 0 ]; }    # 与 confirm 的判断一致: --yes / --upgrade, 或者没有终端
foreign_check() { # 安装 / 升级前: 写清单、打印摘要。只有「运行中的外部进程」「已加载的外部 launchd 任务」, 以及增强模式 (tun) 下默认路由经过别的 TUN 网卡, 才提醒并询问 (默认 n, 回车 = 取消); 其余只是信息
  local ask=0
  detect_foreign; foreign_write_inventory
  [ $((FOREIGN_BIN + FOREIGN_LAUNCHD + FOREIGN_PLIST + FOREIGN_PROC + FOREIGN_CFG + FOREIGN_TUN)) -gt 0 ] || return 0
  if [ $((FOREIGN_PROC + FOREIGN_LAUNCHD)) -gt 0 ]; then ask=1; warn "发现外部 sing-box: 程序 $FOREIGN_BIN 个 · launchd 任务 $FOREIGN_LAUNCHD 个 · 运行中的进程 $FOREIGN_PROC 个 · 配置目录 $FOREIGN_CFG 个"
  elif [ $((FOREIGN_BIN + FOREIGN_PLIST + FOREIGN_CFG)) -gt 0 ]; then info "发现外部 sing-box 文件 (未运行, 仅供参考): 程序 $FOREIGN_BIN 个 · launchd 配置 $FOREIGN_PLIST 个 · 配置目录 $FOREIGN_CFG 个"; fi
  if [ "$FOREIGN_TUN" -gt 0 ]; then
    if [ "${NETWORK_MODE:-system}" = tun ]; then ask=1; warn "默认路由经过别的 TUN 网卡 ($FOREIGN_TUN_IF): 其它 VPN / 代理软件可能与增强模式冲突"
    else info "默认路由经过别的 TUN 网卡 ($FOREIGN_TUN_IF) (VPN / 代理软件; 系统代理模式不受影响, 只有增强模式才可能冲突)"; fi
  fi
  info "清单已写入 $H/foreign-inventory.txt (只含名称、路径、进程号, 不含配置内容)"
  [ "$ask" = 1 ] || return 0
  oplog "${OP_WHO:-terminal}" "检测到外部代理内核" "$(kv bin "$FOREIGN_BIN" launchd "$FOREIGN_LAUNCHD" proc "$FOREIGN_PROC" tun "$FOREIGN_TUN_IF" cfg "$FOREIGN_CFG")" ok
  if _noninteractive; then warn "非交互模式: 照常继续安装; 外部程序没有被关闭、卸载或修改"
  else confirm "继续? (外部程序不会被关闭或修改)" n || die "已取消"; fi
}
port_state() { # 端口 标签 -> free 空闲 · own 只有本程序在用 · unseen 有人在用但看不到是谁 (增强模式的 root 核心) · foreign 别的程序在用
  local p=$1 lbl=$2 running=0 svc pids pid path gone i
  if [ "$lbl" = "$LABEL" ]; then os_service_loaded && running=1; else os_label_loaded "$lbl" && running=1; fi
  svc=$(os_service_pid 2>/dev/null || true)
  for i in 1 2 3; do
    port_busy "$p" || { echo free; return 0; }
    pids=$(lsof -nP -iTCP:"$p" -sTCP:LISTEN -Fp 2>/dev/null | sed -n 's/^p//p' | sort -u)
    if [ -z "$pids" ]; then                                       # 查不到监听者: 刚好退出了就再查一次, 否则就是看不见的 root 核心
      port_busy "$p" || continue
      [ "$running" = 1 ] && echo unseen || echo foreign; return 0
    fi
    gone=0
    for pid in $pids; do
      path=$(_pid_path "$pid")
      [ -n "$path" ] || { gone=1; break; }                        # lsof 与 ps 之间已经退出: 整个重新检查, 不把它算成外部程序
      _enana_owned "$pid" "$path" "$p" "$svc" || { echo foreign; return 0; }
    done
    [ "$gone" = 1 ] || { echo own; return 0; }
  done
  [ "$running" = 1 ] && echo unseen || echo foreign
}

detect_state() { # 当前安装状态 -> ST_core ST_service ST_helper ST_sysproxy ST_shortcut ST_rules ST_servers ST_v1
  ST_core=0; core_ok && ST_core=1
  ST_service=0; os_service_running && ST_service=1
  ST_helper=0; os_api_loaded && ST_helper=1
  ST_sysproxy=0; os_sysproxy_ok && ST_sysproxy=1
  ST_shortcut=0; shortcut_path >/dev/null 2>&1 && ST_shortcut=1
  ST_rules=0; [ -d "$H/rules" ] && [ -z "$(rules_missing)" ] && ST_rules=1
  ST_servers=$(srv_count 2>/dev/null || echo 0)
  ST_v1=0; [ -f "$H/config.env" ] && ST_v1=1
  return 0
}

detect_all() {
  os_detect
  probe_net
  detect_others
  detect_state
}

print_detection() {
  local net
  pf '\n%s识别结果%s\n' "$B" "$N"
  pf '  系统      macOS %s · %s · %s\n' "$MACOS" "$ARCH" "$CHIP"
  pf '  管理员    %s\n' "$([ "$IS_ADMIN" = 1 ] && echo '是' || echo '否 (无法设置系统代理)')"
  net=$( [ "$NET_GITHUB" -gt 0 ] && echo "GitHub ✓${NET_GITHUB}ms" || echo 'GitHub ✗')
  net="$net  $( [ "$NET_JSD" -gt 0 ] && echo "jsDelivr ✓${NET_JSD}ms" || echo 'jsDelivr ✗')"
  net="$net  $( [ "$NET_GOOGLE" -gt 0 ] && echo "Google ✓${NET_GOOGLE}ms" || echo 'Google ✗')"
  net="$net  $( [ "$NET_BAIDU" -gt 0 ] && echo "百度 ✓${NET_BAIDU}ms" || echo '百度 ✗')"
  pf '  网络      %s\n' "$net"
  case $NET_REGION in
    mainland) pf '  判断      中国大陆网络: 下载环境将自动尝试 直连 → 镜像/备用线路; 规则集用 jsDelivr 镜像\n' ;;
    overseas) pf '  判断      可直连国际网络\n' ;;
    *)        pf '  判断      网络几乎不通: 请先检查网络; 也可离线安装 (见提示)\n' ;;
  esac
  [ -n "$BREW" ] && pf '  Homebrew  已安装 (%s)\n' "$BREW"
  pf '  应用      已识别 %s 个已安装应用 (推荐设置在仪表盘「应用」页给出; 新装应用默认关闭)\n' "$(apps_installed | wc -l | tr -d ' ')"
  if [ "$ST_core" = 1 ]; then
    pf '  已有环境  sing-box %s%s%s\n' "$(core_version)" "$([ "$ST_service" = 1 ] && echo ' · 服务运行中')" "$([ "$ST_sysproxy" = 1 ] && echo ' · 系统代理已设置')"
  elif [ "$ST_v1" = 1 ]; then pf '  已有环境  检测到 v1 安装, 将原地升级 (服务器自动迁移)\n'
  else pf '  已有环境  无 (全新安装)\n'; fi
  [ -n "${OTHER_PROXY:-}" ] && pf '  %s注意%s      检测到其它代理软件: %s — 建议先退出它们, 否则会互相冲突\n' "$Y" "$N" "$OTHER_PROXY"
  return 0
}

# 推荐 -> REC_core(chain|brew|local) REC_rules REC_autostart REC_updater REC_sysproxy REC_shortcut 以及理由 WHY_*
recommend() {
  REC_core=chain; WHY_core="GitHub 官方发布包 + SHA-256 校验; 失败自动换线路"
  if [ "$NET_GITHUB" -eq 0 ] && [ -n "$BREW" ]; then REC_core=brew; WHY_core="GitHub 不通, 检测到 Homebrew → 推荐用 Homebrew"
  elif [ "$NET_GITHUB" -eq 0 ]; then WHY_core="GitHub 不通: 将依次尝试镜像; 也可手动下载安装包 (SINGBOX_TGZ=…)"; fi
  if [ "$ST_core" = 1 ]; then REC_core=skip; WHY_core="已安装 sing-box $(core_version), 无需重装 (enana upgrade 可升级)"; fi
  REC_rules=1; WHY_rules="国内直连 / 海外分流 / AI 规则 (SagerNet 社区规则集, 约 1 MB)"
  [ "$ST_rules" = 1 ] && WHY_rules="规则集已就绪, 将检查更新"
  REC_autostart=1; WHY_autostart="登录后自动启动, 崩溃自动重启"
  REC_updater=1; WHY_updater="每 3 天更新规则集 / 订阅 (后台静默, 失败不影响使用)"
  REC_sysproxy=1; WHY_sysproxy="让 Claude App / 浏览器等自动走本地代理 (需要管理员密码)"
  if [ "$IS_ADMIN" != 1 ]; then REC_sysproxy=0; WHY_sysproxy="当前账户不是管理员, 无法设置系统代理 (之后可用管理员账户运行 enana on)"; fi
  if [ "$ST_sysproxy" = 1 ]; then WHY_sysproxy="系统代理已指向本程序, 无需重设"; fi
  REC_shortcut=1; WHY_shortcut="之后在任何终端输入 enana 即可打开控制台"
  [ "$ST_shortcut" = 1 ] && WHY_shortcut="快捷命令已存在"
  return 0
}
