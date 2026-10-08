# 命令行控制台: 在任何终端输入 `enana` 即可打开。显示运行状态, 一键重启 / 暂停 / 更新 / 诊断 / 解除账号绑定 / 卸载。
# 服务器、订阅、应用和网站设置都在仪表盘里操作, 这里只负责「环境」。依赖 config.sh (clash) 与 os-darwin.sh。

_cs_delay() { # 标签 outfile : 测延迟 (毫秒), 失败写空
  local r; r=$(clash GET "/proxies/$1/delay?url=http%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=3000" 2>/dev/null)
  printf '%s' "$r" | sed -n 's/.*"delay":\([0-9]*\).*/\1/p' > "$2"
}
console_gather() {
  local T; T=$(mktemp -d)
  CS_svc=0; os_service_running && CS_svc=1
  CS_pid=$(os_service_pid); CS_up=''; [ -n "$CS_pid" ] && CS_up=$(ps -o etime= -p "$CS_pid" 2>/dev/null | tr -d ' ')
  CS_ver=$(core_version); CS_sp=0; os_sysproxy_ok && CS_sp=1
  CS_srv=$(srv_count 2>/dev/null || echo 0); CS_new=$(apps_new_count 2>/dev/null || echo 0)
  CS_acc=''; auth_logged_in && CS_acc=$(auth_mask_email "$(auth_current_email)")
  CS_upd=''; update_has_new && CS_upd=$(sed -n 's/.*"latest":"\([^"]*\)".*/\1/p' "$H/update.json" 2>/dev/null | head -1)
  CS_mode=''; CS_pin=''; CS_auto=''; CS_pin_ms=''; CS_auto_ms=''
  if [ "$CS_svc" = 1 ]; then
    CS_mode=$(clash GET /configs 2>/dev/null | sed -n 's/.*"mode":"\([^"]*\)".*/\1/p')
    CS_pin=$(clash GET /proxies/PIN 2>/dev/null | sed -n 's/.*"now": *"\([^"]*\)".*/\1/p')
    CS_auto=$(clash GET /proxies/AUTO 2>/dev/null | sed -n 's/.*"now": *"\([^"]*\)".*/\1/p')
    if [ "$CS_srv" -gt 0 ]; then
      [ -n "$CS_pin" ] && [ "$CS_pin" != direct ] && _cs_delay PIN "$T/pin" &
      [ -n "$CS_auto" ] && _cs_delay AUTO "$T/auto" &
      wait
      CS_pin_ms=$(cat "$T/pin" 2>/dev/null); CS_auto_ms=$(cat "$T/auto" 2>/dev/null)
    fi
  fi
  rm -rf "$T"
}
_cs_dot() { if [ "$1" = 1 ]; then printf '%s●%s' "$G" "$N"; else printf '%s●%s' "$R" "$N"; fi; }
_cs_ms()  { [ -n "$1" ] && printf '%s%sms%s' "$G" "$1" "$N" || printf '%s%s%s' "$Y" "$(_t 无响应)" "$N"; }
_cs_rule() { printf '%s ─────────────────────────────────────────────────────────%s\n' "$DIM" "$N"; }

console_draw() {
  printf '\033[2J\033[H'
  pf '%s enana 代理控制台%s   v%s%s\n' "$B" "$N" "$VERSION" "${CS_upd:+   $Y$(_t "有新版本") v$CS_upd$N}"
  _cs_rule
  if [ "$CS_svc" = 1 ]; then pf '  服务      %s 运行中   sing-box %s%s\n' "$(_cs_dot 1)" "$CS_ver" "${CS_up:+  ($(_t "已运行") $CS_up)}"
  else pf '  服务      %s 未运行   (按 2 启动)\n' "$(_cs_dot 0)"; fi
  if [ "$CS_sp" = 1 ]; then pf '  系统代理  %s 已开启   127.0.0.1:%s\n' "$(_cs_dot 1)" "$PORT"
  else pf '  系统代理  %s 未开启   (按 s 开启)\n' "$(_cs_dot 0)"; fi
  if [ "$CS_mode" = Direct ]; then pf '  代理      %s已关闭%s — 全部直连 (登录后按 3 或在仪表盘里打开总开关)\n' "$Y" "$N"; elif [ -n "$CS_mode" ]; then pf '  代理      已开启 (规则分流)\n'; fi
  if [ "$CS_srv" -gt 0 ] && [ "$CS_svc" = 1 ]; then
    pf '  固定出口  %s  %s\n' "${CS_pin:-—}" "$(_cs_ms "$CS_pin_ms")"
    [ "$(health_pin_state)" != empty ] || pf '            %s⚠ 没有设置固定出口: 选了「固定出口」的应用 / 服务 (如 ChatGPT) 现在会直连 (真实 IP); 到仪表盘「服务器」页设置%s\n' "$Y" "$N"
    [ "$(health_orphans)" = 0 ] || pf '            %s⚠ 有 %s 个应用 / 网站指定的固定出口已经不存在, 暂时在用默认固定出口 (出口 IP 可能变了); 到仪表盘「服务器」页的「出口分配」处理%s\n' "$Y" "$(health_orphans)" "$N"
    [ -n "$CS_auto" ] && pf '  自动线路  %s  %s\n' "$CS_auto" "$(_cs_ms "$CS_auto_ms")"
  fi
  if [ -n "$CS_acc" ]; then pf '  账号      已登录 %s\n' "$CS_acc"; else pf '  账号      未登录 (打开仪表盘, 用 enana.cc 账号登录或注册)\n'; fi
  pf '  后台地址  %s%s%s\n' "$C" "$UI_URL" "$N"
  if [ "$CS_srv" -eq 0 ]; then pf '\n  %s提示%s 还没有添加服务器 → 按 1 打开仪表盘, 在「服务器」页添加\n' "$Y" "$N"
  elif [ "$CS_new" -gt 0 ]; then pf '\n  %s提示%s 发现 %s 个新应用 (默认关闭) → 按 1 到仪表盘「应用」页处理\n' "$Y" "$N" "$CS_new"; fi
  _cs_rule
  pf '  [1] 打开仪表盘\n'
  pf '  [2] 重启服务\n'
  pf '  [3] %s\n' "$([ "$CS_mode" = Direct ] && _t '开启代理' || _t '关闭代理(全部直连)')"
  pf '  [4] 更新规则/订阅\n'
  pf '  [5] 查看日志\n'
  pf '  [6] 诊断\n'
  pf '  [7] 退出账号 (关闭代理并清除登录)\n'
  pf '  [8] 更新 enana\n'
  pf '%s  [9] 卸载%s\n' "$R" "$N"
  pf '  [s] %s\n' "$([ "$CS_sp" = 1 ] && _t '关闭系统代理' || _t '开启系统代理')"
  pf '  [l] 语言 / Language\n'
  pf '  [r] 刷新\n'
  pf '  [q] 退出\n'
  _cs_rule
}

console_pause() { printf '\n  %s%s%s' "$DIM" "$(_t '按 Enter 返回…')" "$N"; IFS= read -r _k || true; }

console_main() {
  local key
  [ -t 0 ] && [ -t 1 ] || { cmd_status; return; }
  printf '\033[?25l'; trap 'printf "\033[?25h"' EXIT
  console_gather
  while :; do
    console_draw
    printf '\033[?25h\n  %s: ' "$(_t '请选择 (输入选项后按 Enter)')"
    IFS= read -r key || break
    printf '\033[?25l'
    case $key in
      1) os_open "$UI_URL" ;;
      2) printf '\033[?25h\n'; cmd_restart; console_pause; printf '\033[?25l'; console_gather ;;
      3) if [ "$CS_mode" = Direct ]; then
           if auth_logged_in; then proxy_set_enabled 1; oplog terminal "开启代理" "$(kv enabled 1 via console)" ok; else printf '\033[?25h\n'; warn "还没有登录: 请先打开仪表盘用 enana.cc 账号登录, 再开启代理"; console_pause; printf '\033[?25l'; fi
         else proxy_set_enabled 0; oplog terminal "关闭代理" "$(kv enabled 0 via console)" ok; fi
         console_gather ;;
      4) printf '\033[?25h\n'; cmd_update; console_pause; printf '\033[?25l'; console_gather ;;
      5) printf '\033[2J\033[H'; tail -n 60 "$H/sing-box.log" 2>/dev/null || _t "(暂无日志)"; console_pause ;;
      6) printf '\033[?25h\033[2J\033[H'; cmd_doctor; console_pause; printf '\033[?25l' ;;
      7) printf '\033[?25h\n'; cmd_logout; console_pause; printf '\033[?25l'; console_gather ;;
      8) printf '\033[?25h\n'; update_check force >/dev/null 2>&1 || true; if update_has_new; then cmd_self_update; else ok "已经是最新版本 (v$VERSION)"; fi; console_pause; printf '\033[?25l'; console_gather ;;
      9) printf '\033[?25h\n'; if cmd_uninstall; then return 0; fi; console_pause; printf '\033[?25l'; console_gather ;;
      s|S) printf '\033[?25h\n'; if [ "$CS_sp" = 1 ]; then os_sysproxy_set off; else os_sysproxy_set on; fi; console_pause; printf '\033[?25l'; console_gather ;;
      l|L) printf '\033[?25h\033[2J\033[H'; ARG1=''; cmd_lang; printf '\033[?25l' ;;
      r|R) console_gather ;;
      q|Q|$'\033') printf '\033[?25h\033[2J\033[H'; return 0 ;;
    esac
  done
}
