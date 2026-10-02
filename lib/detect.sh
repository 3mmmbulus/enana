# 系统与网络识别 + 安装推荐。依赖 common.sh os-darwin.sh fetch.sh servers.sh。
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

detect_others() { # 其它正在运行的代理软件 -> OTHER_PROXY (逗号分隔, 可能为空)
  OTHER_PROXY=$(ps -axo comm= 2>/dev/null | awk -F/ '{print $NF}' | grep -iE '^(ClashX|Clash Verge|clash-verge|mihomo|Stash|Surge|V2rayU|V2rayN|Shadowsocks|ShadowsocksX|Qv2ray|sing-box)' | sort -u | paste -sd, - || true)
  # 本程序自己的 sing-box 不算
  [ -n "${OTHER_PROXY:-}" ] && [ -n "$(os_service_pid 2>/dev/null)" ] && OTHER_PROXY=$(printf '%s' "$OTHER_PROXY" | sed 's/,\{0,1\}sing-box//' | sed 's/^,//')
  return 0
}

detect_state() { # 当前安装状态 -> ST_core ST_service ST_helper ST_sysproxy ST_shortcut ST_rules ST_servers ST_v1
  ST_core=0; core_ok && ST_core=1
  ST_service=0; os_service_running && ST_service=1
  ST_helper=0; launchctl print "$GUI/$LABEL_API" >/dev/null 2>&1 && ST_helper=1
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
