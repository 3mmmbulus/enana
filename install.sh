#!/bin/bash
# enana — 代理环境安装器与命令行控制台 (macOS)
#
#   bash install.sh            安装 / 升级 / 修复 (交互式: 识别系统 → 推荐 → 键盘选择); 重复运行安全, 已就绪的部分会跳过
#   enana                  安装后在任何终端输入它, 打开控制台 (状态 / 一键重启 / 解除账号绑定 / 卸载 …)
#   enana <命令>           status start stop restart on off update upgrade self-update doctor diag logs open env logout lang uninstall help
#
# 终端只负责「安装环境」。服务器、订阅、应用与网站设置全部在仪表盘 (后台) 里完成: http://127.0.0.1:<端口>/enana/admin/ (安装完成后会打印; enana open 也能打开)
# 仪表盘的登录账号是你在 https://enana.cc 注册的账号 (本机不生成任何密码)。本仓库不含任何服务器地址/密码。
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"          # 被 zsh/sh 误调用时切回 bash
set -u

# --- 定位 lib (支持符号链接, 如 /usr/local/bin/enana) ---
_p="${BASH_SOURCE[0]}"
while [ -L "$_p" ]; do _l=$(readlink "$_p"); case $_l in /*) _p=$_l ;; *) _p=$(dirname "$_p")/$_l ;; esac; done
_d=$(cd "$(dirname "$_p")" && pwd -P)
. "$_d/lib/common.sh"
init_paths "$_p"
for _f in i18n jobs servers apps autosites sites fetch os enhanced auth device session cloud dns logs health update config ops speed stats prefs snapshot plan official sync vps diag menu detect console; do . "$LIB/$_f.sh"; done
[ "$ENANA_PLATFORM" != windows ] || . "$LIB/enhanced-windows.sh"
load_settings

FORCE=''; QUIET=${QUIET:-}; UPGRADE=''; CMD=''; ARG1=''; ARG2=''
parse_args() {
  local a n=0 want_lang=0
  for a in "$@"; do
    if [ "$want_lang" = 1 ]; then ENANA_LANG=$a; export ENANA_LANG; want_lang=0; continue; fi
    case $a in
      --yes|-y) ENANA_YES=1; export ENANA_YES ;;
      --force) FORCE=1 ;;
      --keep-data) die "完整卸载会删除全部本机数据; 请先导出需要保留的数据, 再执行 enana uninstall" ;;
      --quiet) QUIET=1 ;;
      --upgrade) UPGRADE=1; ENANA_YES=1; export ENANA_YES ;;
      --lang) want_lang=1 ;;
      --lang=*) ENANA_LANG=${a#--lang=}; export ENANA_LANG ;;
      *) n=$((n+1)); case $n in 1) CMD=$a ;; 2) ARG1=$a ;; 3) ARG2=$a ;; esac ;;
    esac
  done
  [ -n "${ENANA_LANG:-}" ] && i18n_init
  return 0
}
progress() { [ "${ENANA_PROGRESS:-}" = 1 ] && printf '##job %s %s %s\n' "$1" "$2" "$3"; return 0; }   # 供 get.sh / 仪表盘「更新」任务读取进度

# ============================== 安装 ==============================
banner() {
  pf '\n%s  enana · 代理环境安装器%s  v%s\n' "$B" "$N" "$VERSION"
  pf '  %s终端只安装环境; 服务器 / 订阅 / 应用 / 网站设置请在安装完成后打开的仪表盘里操作。%s\n' "$DIM" "$N"
}

build_menu() {
  local core_opts='chain:GitHub 官方包(多线路+校验)'
  [ -n "$BREW" ] && core_opts="$core_opts|brew:Homebrew"
  core_opts="$core_opts|local:本地安装包"
  menu_reset
  menu_add lang     "界面语言 / Language" choice "$LANG_UI" 'zh:中文|en:English' "终端与仪表盘共用的界面语言 (安装后也可在仪表盘「设置」里改) / Used by the terminal and the dashboard"
  if [ "$REC_core" = skip ]; then menu_add core "sing-box 核心 (已安装 $(core_version))" choice skip 'skip:已就绪' "$WHY_core" 1
  else menu_add core "sing-box 核心 · 来源" choice "$REC_core" "$core_opts" "$WHY_core"; fi
  menu_add rules    "社区规则集 (国内直连 / 海外分流 / AI)" toggle "$REC_rules" '' "$WHY_rules"
  menu_add dash     "仪表盘 + 本地辅助服务" toggle 1 '' "必装: 服务器、订阅、应用、网站的设置与监控都在仪表盘里完成" 1
  menu_add autostart "开机自启 + 崩溃自动重启" toggle "$REC_autostart" '' "$WHY_autostart"
  menu_add updater  "每 3 天自动更新规则集 / 订阅" toggle "$REC_updater" '' "$WHY_updater"
  menu_add sysproxy "设置系统代理 (需管理员密码)" toggle "$REC_sysproxy" '' "$WHY_sysproxy"
  menu_add shortcut "快捷命令 enana" toggle "$REC_shortcut" '' "$WHY_shortcut"
}

install_files() { # 把程序文件复制到 $H (源码目录与 $H 相同时跳过)
  mkdir -p "$H" "$H/ui" "$H/certs"; chmod 700 "$H"
  if [ "$SRC" != "$H" ]; then
    rm -rf "$H/lib" "$H/data"; cp -R "$SRC/lib" "$H/lib"; cp -R "$SRC/data" "$H/data"
    cp -R "$SRC/ui/." "$H/ui/"
    [ ! -d "$SRC/windows" ] || { mkdir -p "$H/windows"; cp -R "$SRC/windows/." "$H/windows/"; }
    local f; for f in VERSION CHANGELOG.md get.sh get.ps1; do [ -f "$SRC/$f" ] && cp "$SRC/$f" "$H/$f"; done
    cp "$SRC/install.sh" "$H/enana.new" && chmod 755 "$H/enana.new" && mv -f "$H/enana.new" "$H/enana"   # 原子替换: 正在运行的旧进程不受影响
  fi
  : > "$H/.enana-home"
  local k; for k in PORT UI_PORT API_PORT SPEED_PORT; do grep -q "^$k=" "$H/settings.env" 2>/dev/null || settings_set "$k" "${!k}"; done   # 端口写进设置 (辅助服务 / 定时任务不继承安装时的环境变量)
}

migrate_v1_domains() { # v1 的 domains.txt: 目录里没有的域名保留为「固定出口」的自定义网站
  local d n=0
  [ -f "$H/domains.txt" ] || return 0
  while IFS= read -r d; do
    d=$(printf '%s' "$d" | sed 's/#.*//' | tr -d '[:space:]' | tr 'A-Z' 'a-z'); [ -n "$d" ] || continue
    grep -qE "(^|[|,])$d(,|\|)" "$(content_file services.conf)" && continue
    ovr_valid site "$d" && { ovr_set site "$d" pin ack; n=$((n+1)); }
  done < "$H/domains.txt"
  mv "$H/domains.txt" "$H/domains.txt.v1.bak"
  [ "$n" -gt 0 ] && info "已迁移 $n 个 v1 自定义域名 (在仪表盘「网站」页可见)"
  return 0
}

# 品牌更名前的安装 (~/.tokyo-proxy) -> ~/.enana: 停掉旧服务与旧命令, 数据目录整体搬过来 (服务器 / 订阅 / 设置原样保留)
migrate_legacy() {
  local old="$HOME/$LEGACY_HOME_NAME" moved=0
  if [ -d "$old" ] && [ ! -f "$H/.enana-home" ]; then
    os_legacy_cleanup
    if [ -d "$H" ] && [ -z "$(ls -A "$H" 2>/dev/null)" ]; then rmdir "$H"; fi
    if [ ! -e "$H" ]; then mv "$old" "$H" && moved=1; fi
    rm -f "$H/tproxy" "$H/ereldaili" "$H/.tproxy-home"
    if [ "$moved" = 1 ]; then ok "已把旧版安装 ($old) 迁移到 $H, 服务器与设置原样保留"; else warn "发现旧版安装目录 $old, 但 $H 已存在, 没有自动迁移 (需要的话请手动复制 servers.jsonl 等文件)"; fi
  else
    os_legacy_cleanup
  fi
  return 0
}

# 本地端口 (默认 代理 7890 / 核心控制 9090 / 辅助服务+后台 9091 / 测速 7892): 被别的程序占着就自动换一个随机的空闲端口, 并写进设置。
# 已经由我们自己的服务占着的不算冲突 (如 off 之后重新安装 / 升级)。
port_busy() { nc -z 127.0.0.1 "$1" >/dev/null 2>&1; }
port_random() { # 随机空闲端口 (20000-59999), 避开 $1 里已经选了的; 打印端口, 找不到返回 1
  local n=0 p
  while [ "$n" -lt 300 ]; do
    p=$((20000 + (RANDOM * 32768 + RANDOM) % 40000)); n=$((n + 1))
    case " $1 " in *" $p "*) continue ;; esac
    port_busy "$p" || { printf '%s' "$p"; return 0; }
  done
  return 1
}
pick_ports() {
  local spec name lbl cur new used=" $PORT $UI_PORT $API_PORT $SPEED_PORT "
  for spec in "PORT:$LABEL" "UI_PORT:$LABEL" "API_PORT:$LABEL_API" "SPEED_PORT:$LABEL"; do
    name=${spec%%:*}; lbl=${spec#*:}; cur=${!name}
    # A root TUN core owns the same ports but has no GUI LaunchAgent.
    # Treating it as foreign silently changes ports during an upgrade.
    [ "$lbl" != "$LABEL" ] || ! os_service_loaded || continue
    os_label_loaded "$lbl" && continue
    port_busy "$cur" || continue
    new=$(port_random "$used") || die "找不到空闲的本地端口" "请先关闭一些占用端口的程序, 再重新运行安装命令"
    warn "本地端口 $cur 已被其它程序占用, 已自动改用 $new"
    printf -v "$name" '%s' "$new"; export "$name"; settings_set "$name" "$new"; used="$used$new "
  done
  set_ui_url
}

st_preflight() {
  step "检查环境"
  [ "$MACOS_MAJOR" -ge 12 ] || warn "macOS $MACOS 较旧: 官方 sing-box 1.14 可能无法在此运行 (Intel 会自动尝试兼容包)"
  ok "macOS $MACOS · $ARCH"
  mkdir -p "$H"
  pick_ports
  ok "本地端口 $PORT / $UI_PORT / $API_PORT / $SPEED_PORT 可用"
  if [ "$SEL_sysproxy" = 1 ]; then
    local foreign; foreign=$(os_sysproxy_foreign | paste -sd, -)
    if [ -n "$foreign" ]; then
      os_sysproxy_backup
      warn "网络服务「$foreign」已有其它系统代理设置, 继续会覆盖 (原设置已备份到 $H/proxy-backup.txt)"
      confirm "继续?" y || die "已取消"
    fi
  fi
}

st_core() {
  step "安装 sing-box 核心 (代理引擎)"
  if [ "$SEL_core" = skip ] && [ -z "$FORCE" ]; then ok "已安装 sing-box $(core_version), 无需重装"; return 0; fi
  [ "$SEL_core" = skip ] && SEL_core=chain
  core_install "$SEL_core"; local rc=$?
  case $rc in
    0) ok "sing-box $(core_version) 安装完成" ;;
    2) die "sing-box 已下载但无法在这台 Mac 上运行" "你的系统是 macOS $MACOS ($ARCH); 请把这行信息反馈出来, 或升级系统" ;;
    *) die "sing-box 下载失败 (已尝试: 直连 / 本地代理 / 备用线路 / 镜像)" \
         "离线安装: 用浏览器从 https://github.com/SagerNet/sing-box/releases 下载 sing-box-<版本>-darwin-$ARCH.tar.gz 放到 ~/Downloads, 再运行 bash install.sh (自动发现), 或 SINGBOX_TGZ=/路径/文件.tar.gz bash install.sh" ;;
  esac
}

st_rules() {
  step "下载社区规则集 (国内直连 / 海外分流 / AI)"
  local age=999999
  [ -s "$H/rules/.updated" ] && age=$(( $(now) - $(rules_updated_at) ))
  if [ -z "$(rules_missing)" ] && [ -z "$FORCE" ] && [ "$age" -lt 604800 ]; then ok "规则集已就绪 ($(human_age "$age")前更新), 跳过"; return 0; fi
  if rules_update; then ok "规则集就绪 ($RULES_CHANGED 个更新, $RULES_FAILED 个失败)"
  else warn "规则集下载失败: 国内网站暂时会走代理; 稍后运行 enana update 重试 (不影响其余功能)"; fi
}

st_config() {
  step "生成配置"
  install_files
  auth_init                                   # 令牌 (= 核心 Clash API 的密钥) 从一开始就存在; 仪表盘登录成功后才会拿到它
  if srv_migrate_v1; then ok "已从 v1 迁移你的服务器配置 (无需重新输入, 在仪表盘「服务器」页可见)"; fi
  migrate_v1_domains
  sb_ver
  [ "$SB_MAJOR" -gt 1 ] || [ "$SB_MINOR" -ge 12 ] || warn "sing-box $(core_version) 偏旧, 建议 enana upgrade"
  if lock_take; then apps_scan >/dev/null 2>&1 || true; lock_drop; fi     # 识别已安装的应用 (升级时顺便修好 2.1.0 留下的「浏览器被设成直连」); 这之后才装的应用才算「新应用」
  local rc
  if op_lock; then apply_config; rc=$?; op_unlock; else apply_config; rc=$?; fi      # 和仪表盘里的配置任务排队: 两边同时改 config.json 会让社区规则集被临时停用
  case $rc in
    0) ;;
    3) die "新配置没能让代理核心启动, 已回滚到原来的配置" "日志: $H/sing-box.log   $(tail -n 3 "$H/sing-box.log" 2>/dev/null | tr '\n' ' ')" ;;
    *) die "生成的配置没有通过 sing-box 校验" "$(head -c 400 "$H/check.log" 2>/dev/null | tr '\n' ' ') — 请把这段信息反馈出来" ;;
  esac
  ok "配置已生成并通过 sing-box 校验 (服务器 $(srv_count) 台 · 目录 $(catalog_list | wc -l | tr -d ' ') 项)"
}

st_service() {
  step "注册后台服务"
  local n
  os_write_plists; n=$?
  if ! os_service_running || [ "$n" -gt 0 ]; then os_service_start || die "后台服务注册失败" "运行 enana doctor 查看原因"; fi
  wait_port "$PORT" 15 || die "服务没有启动" "日志: $H/sing-box.log   $(tail -n 3 "$H/sing-box.log" 2>/dev/null | tr '\n' ' ')"
  proxy_sync_mode
  [ "$n" -gt 0 ] && os_aux_load
  os_service_running && ok "代理服务运行中 (127.0.0.1:$PORT)$([ "${AUTOSTART:-1}" = 1 ] && echo ' · 开机自启')"
  os_api_loaded || os_aux_load
  ok "本地辅助服务就绪 (127.0.0.1:$API_PORT, 仪表盘用)"
}

st_sysproxy() {
  [ "${NETWORK_MODE:-system}" != tun ] || { info "Enhanced/TUN: 保留现有系统代理设置"; return 0; }
  step "设置系统代理 (让 Claude App / 浏览器等自动走本地代理)"
  if os_sysproxy_ok && [ -z "$FORCE" ]; then ok "系统代理已指向本程序, 无需密码"; return 0; fi
  os_sysproxy_backup
  info "需要输入 Mac 登录密码 (仅用于修改系统代理设置):"
  os_sysproxy_set on || warn "系统代理没有设置成功; 之后可运行 enana on"
}

st_shortcut() {
  step "安装快捷命令"
  SHORTCUT=''; SHORTCUT_RC=''
  if shortcut_path >/dev/null 2>&1; then ok "快捷命令已存在: $(shortcut_path)"; return 0; fi
  if shortcut_install; then
    ok "已安装: $SHORTCUT  → 以后在任何终端输入 ${B}enana${N} 即可打开控制台"
    [ -n "$SHORTCUT_RC" ] && warn "$(dirname "$SHORTCUT") 还不在当前终端的 PATH 里: 已写入 $SHORTCUT_RC, 重新打开终端后生效 (想立刻用: export PATH=\"\$HOME/.local/bin:\$PATH\")"
  else warn "快捷命令安装失败; 仍可用 $H/enana"; fi
}

st_verify() {
  step "验证"
  local code
  os_service_running && ok "代理服务运行中" || warn "代理服务没有运行"
  code=$(curl -s -o /dev/null -m 6 --noproxy '*' -w '%{http_code}' "$UI_URL" || true)
  [ "$code" = 200 ] && ok "仪表盘可访问" || warn "仪表盘暂时打不开 (HTTP ${code:-无响应})"
  if curl -s -m 6 --noproxy '*' -H 'X-Enana: 1' "http://127.0.0.1:$API_PORT/api/auth/status" | grep -q '"ok":true'; then ok "本地辅助服务可用"
  else warn "本地辅助服务没有响应 (仪表盘里的写操作会不可用): 运行 enana doctor"; fi
  code=$(curl -s -o /dev/null -m 12 -x "http://127.0.0.1:$PORT" -w '%{http_code}' https://www.apple.com || true)
  if [ -n "$code" ] && [ "$code" != 000 ]; then ok "经本地代理访问网站正常 (直连路径 · HTTP $code)"; else warn "经本地代理访问网站失败, 请检查网络"; fi
  os_sysproxy_ok && ok "系统代理已开启" || warn "系统代理未开启 (enana on)"
  [ "$(srv_count)" = 0 ] && info "尚未添加服务器 — 当前所有流量直连; 请在仪表盘里添加"
  return 0
}

cmd_install() {
  os_detect
  [ "$OS" != Windows ] || { cmd_install_windows; return; }
  [ "$OS" = Darwin ] || die "目前只支持 macOS" "Windows 请用 PowerShell 一行命令安装 (见 README); Linux 计划见 docs/ROADMAP.md"
  [ "$(id -u)" -ne 0 ] || die "请不要用 sudo 运行" "直接: bash install.sh  (需要管理员权限的步骤会自己要密码)"
  migrate_legacy
  [ -n "$UPGRADE" ] || banner
  [ -n "$UPGRADE" ] || pf '\n  %s正在识别系统与网络…%s\n' "$DIM" "$N"
  probe_net; detect_others; mkdir -p "$H"; detect_state
  [ -n "$UPGRADE" ] || print_detection
  recommend
  [ -n "$FORCE" ] && [ "$REC_core" = skip ] && REC_core=chain
  if [ -n "$UPGRADE" ]; then                   # 升级: 沿用已有选择, 不动系统代理 / 不弹菜单; 核心低于本版固定版本时才重装
    REC_sysproxy=0
    if [ "$ST_core" = 1 ]; then
      if version_gt "$CORE_PIN" "$(core_version)"; then REC_core=chain; WHY_core="本版本要求 sing-box $CORE_PIN, 将升级核心"; else REC_core=skip; fi
    fi
    [ "$ST_rules" = 1 ] && REC_rules=0
  fi
  build_menu
  if menu_interactive; then pf '\n%s选择要安装的内容%s (已按识别结果给出推荐; 用键盘修改):\n\n' "$B" "$N"; elif [ -z "$UPGRADE" ]; then pf '\n%s非交互模式: 按识别结果的推荐设置安装%s\n' "$B" "$N"; fi
  menu_run || die "已取消"
  LANG_UI=$(menu_val lang); I18N_LANG=$LANG_UI; settings_set LANG_UI "$LANG_UI"
  SEL_core=$(menu_val core); SEL_rules=$(menu_val rules); SEL_autostart=$(menu_val autostart)
  SEL_updater=$(menu_val updater); SEL_sysproxy=$(menu_val sysproxy); SEL_shortcut=$(menu_val shortcut); SEL_helper=1
  [ -n "$UPGRADE" ] || { settings_set AUTOSTART "$SEL_autostart"; settings_set AUTO_UPDATE "$SEL_updater"; }   # 升级沿用已保存的选择
  load_settings
  STEPS=4                                               # 检查环境 · 生成配置 · 注册服务 · 验证
  { [ "$SEL_core" = skip ] && [ -z "$FORCE" ]; } || STEPS=$((STEPS+1))   # 核心 (已安装且未强制时只打印一行, 仍占一步)
  [ "$SEL_core" = skip ] && [ -z "$FORCE" ] && STEPS=$((STEPS+1))
  [ "$SEL_rules" = 1 ] && STEPS=$((STEPS+1))
  [ "$SEL_sysproxy" = 1 ] && STEPS=$((STEPS+1))
  [ "$SEL_shortcut" = 1 ] && STEPS=$((STEPS+1))
  progress 2 30 "检查环境"
  st_preflight
  st_core
  progress 2 50 "更新规则集"
  [ "$SEL_rules" = 1 ] && st_rules
  progress 2 70 "生成配置并重启服务"
  st_config
  st_service
  [ "$SEL_sysproxy" = 1 ] && st_sysproxy
  [ "$SEL_shortcut" = 1 ] && st_shortcut
  progress 2 95 "验证"
  st_verify
  if [ -n "$UPGRADE" ]; then ok "已升级到 enana v$VERSION"; return 0; fi
  pf '\n%s════════════════ 环境安装完成 ════════════════%s\n' "$G$B" "$N"
  pf '  %s后台地址%s   %s%s%s   (已尝试自动打开; 以后在终端输入 enana open 也能打开)\n' "$B" "$N" "$C$B" "$UI_URL" "$N"
  pf '  %s登录%s     仪表盘需要登录才能使用: 用 enana.cc 账号 (邮箱 + 密码) 登录; 还没有账号? 直接在登录框里点「注册」\n' "$B" "$N"
  pf '  %s代理%s     默认是关闭的 (全部直连): 登录后在仪表盘里打开「代理」总开关才会生效; 退出账号会自动关闭代理\n' "$B" "$N"
  pf '  接下来在仪表盘里完成 (终端不需要再做任何事):\n'
  pf '    ① 添加固定出口服务器 (如日本)    ② 导入其它代理 / 订阅链接 (自动识别)\n'
  pf '    ③ 确认应用与网站的推荐设置       ④ 新装的应用会自动识别, 默认关闭\n'
  pf '  命令行控制台   在任何终端输入 %senana%s  (状态 · 一键重启 · 退出账号 · 卸载 …)\n' "$B" "$N"
  [ -n "${SHORTCUT_RC:-}" ] && pf '                 注意: 要先重新打开终端 (或在当前终端运行 %sexport PATH="$HOME/.local/bin:$PATH"%s); 现在也可以直接运行 %s%s/enana%s\n' "$B" "$N" "$B" "$H" "$N"
  pf '\n'
  os_open "$UI_URL"
}

# Native PowerShell stages verified dependencies before entering shared logic.
cmd_install_windows() {
  [ -x "$SB" ] && core_ok || die 'Windows core is missing' 'Run the PowerShell installer, not install.sh directly.'
  STEPS=4; mkdir -p "$H"; install_files
  settings_set LANG_UI "${ENANA_LANG:-${LANG_UI:-zh}}"; load_settings
  [ "${ENANA_SKIP_RULES:-0}" = 1 ] || st_rules
  st_config; st_service
  step '验证'
  wait_port "$API_PORT" 15 || die 'Windows dashboard did not start' "$H/api.log"
  local code; code=$(curl -s --noproxy '*' -m 8 -o /dev/null -w '%{http_code}' "$UI_URL" || true)
  [ "$code" = 200 ] || die 'Windows dashboard health check failed' "$H/api.log"
  ok "enana $VERSION · Windows · $ARCH"; info "$UI_URL"
}

# ============================== 日常命令 ==============================
cmd_status() {
  info "capture.mode=${NETWORK_MODE:-system}"
  if os_service_running; then ok "服务运行中 (sing-box $(core_version))"; else warn "服务未运行 (enana start)"; fi
  if os_sysproxy_ok; then ok "系统代理: 已开启"; else warn "系统代理: 未开启 (enana on)"; fi
  if auth_logged_in; then ok "账号: 已登录 $(auth_mask_email "$(auth_current_email)")"; else info "账号: 未登录 — 打开仪表盘, 用 enana.cc 账号登录 (没有账号可以直接注册)"; fi
  if [ "${PROXY_ENABLED:-0}" = 1 ]; then ok "代理: 已开启 (按规则分流)"; else info "代理: 已关闭 (全部直连) — 登录后在仪表盘里打开「代理」总开关"; fi
  update_has_new && warn "有新版本 (enana self-update 更新)"
  info "服务器 $(srv_count) 台 · 后台地址 $UI_URL"
}
cmd_start() { os_service_start && wait_port "$PORT" 15 && enhanced_ready && { proxy_sync_mode; ok "已启动"; } || warn "启动失败: enana doctor"; }
cmd_restart() { info "正在重启服务…"; if os_service_restart && wait_port "$PORT" 15 && enhanced_ready; then proxy_sync_mode; ok "已重启"; oplog terminal "重启服务" "" ok; else warn "没有在 15 秒内启动: 运行 enana doctor"; fi; }
cmd_network_mode() { network_mode_set "$ARG1"; }
cmd_on() { # 开启代理: 必须先在仪表盘登录 enana.cc 账号
  if ! auth_logged_in; then warn "还没有登录: 请先打开仪表盘 ($UI_URL) 用 enana.cc 账号登录, 再开启代理"; return 1; fi
  cmd_start && proxy_set_enabled 1 && { oplog terminal "开启代理" "$(kv enabled 1 via 'enana on')" ok; [ "$NETWORK_MODE" = tun ] || os_sysproxy_set on; }
}
cmd_off() { proxy_set_enabled 0; oplog terminal "关闭代理" "$(kv enabled 0 via 'enana off')" ok; if os_sysproxy_mine; then os_sysproxy_set off || { warn "系统代理没有关闭成功 (需要管理员密码), 服务未停止以免断网; 请重试 enana off"; return 1; }; fi; os_service_stop || return 1; ok "已关闭系统代理并停止服务"; }
cmd_open() { os_open "$UI_URL"; echo "$UI_URL"; }
cmd_env() { echo "export http_proxy=http://127.0.0.1:$PORT https_proxy=http://127.0.0.1:$PORT all_proxy=socks5://127.0.0.1:$PORT no_proxy=localhost,127.0.0.1,::1"; }
cmd_logs() { tail -n "${ARG1:-100}" "$H/sing-box.log" 2>/dev/null || _t "(暂无日志)"; }
cmd_diag_preview() { diag_summary_json; }      # 打印下一份「诊断摘要」(自动上传的内容): 只有结构化的状态 / 判定 / 操作记录, 没有网站、应用名、IP、服务器地址
cmd_diag_upload() { # 立刻传一份诊断摘要 (不管设置里的自动上传开关, 但需要已登录)
  local DIAG_UPLOAD=1
  diag_enabled || die "没有登录, 或者不是 macOS" "先登录账号 (enana 里按 1 打开仪表盘)"
  if diag_upload manual; then ok "已上传诊断摘要 (enana diag-preview 可以看到传了什么)"; else die "上传失败" "看操作记录里的「诊断上传」: enana logs"; fi
}
cmd_diag_send() { # 把完整诊断 (含访问过的域名 / 应用名) 发给 enana 开发者: enana diag-send [小时数]; 成功后给一个报告编号
  local hours=${ARG1:-24}
  case $hours in ''|*[!0-9]*) die "时间范围无效" "用法: enana diag-send [小时数]" ;; esac
  info "完整诊断包含你访问过的域名和应用名, 只发给 enana 开发者, 云端 7 天后自动删除; 不含密码和令牌。"
  confirm "确认发送?" n || { info "已取消"; return 1; }
  if diag_send_full "$hours"; then ok "已发送。报告编号: $DIAG_ID (把它告诉开发者)"; else die "发送失败 (${DIAG_ERR:-unknown})" "没有登录就先登录; 太大就缩短时间范围; 看操作记录: enana logs"; fi
}
cmd_diag_delete() { # 删除自己已经上传的全部诊断
  local n; n=$(diag_delete) || die "没能删除" "没有登录, 或者联系不上云端"
  ok "已删除云端上你的 $n 份诊断"
}
cmd_diag() { # 诊断导出 (和仪表盘「日志 → 导出」同一份文件, 格式见 docs/DIAGNOSTICS.md): enana diag [小时数|all]; 终端里保存成文件, 接管道时直接输出
  local hours=${ARG1:-24} out
  case $hours in all) ;; ''|*[!0-9]*) die "时间范围无效" "用法: enana diag [小时数 1-$LOG_HOURS_MAX | all]" ;; esac
  if [ -t 1 ]; then
    local d; out=''
    for d in "$HOME/Downloads" "$H"; do      # 下载文件夹没有写入权限 (系统隐私设置) 时, 退回安装目录
      [ -d "$d" ] || continue
      out="$d/enana-diagnostics-$(date +%Y%m%d-%H%M%S).txt"
      { logs_bundle "$hours" ops,access,proxy,snapshot > "$out"; } 2>/dev/null && [ -s "$out" ] && break
      rm -f "$out"; out=''
    done
    [ -n "$out" ] || die "导出失败" "运行 enana doctor 查看原因"
    oplog terminal "导出诊断日志" "$(kv hours "$hours" sections ops,access,proxy,snapshot bytes "$(wc -c < "$out" | tr -d ' ')")" ok
    ok "已导出: $out ($(wc -c < "$out" | tr -d ' ') 字节, 不含密码; 含访问过的域名和应用名, 请只发给你信任的人)"
  else
    logs_bundle "$hours" ops,access,proxy,snapshot
  fi
}

cmd_update() {
  info "更新规则集…"; rules_update || warn "规则集下载失败, 保留旧版本"
  info "刷新订阅…"; op_subs_refresh "${QUIET:+1}"
  op_apply >/dev/null 2>&1 && ok "已更新" || warn "应用配置失败: enana doctor"
}
cmd_maintain() { op_maintain; }
cmd_content() { # 拉取并应用云端内容 (登录后下发的服务目录 / 规则库 / 应用推荐), 然后显示状态
  auth_logged_in || { warn "还没有登录: 云端内容需要先在仪表盘登录 enana 账号"; return 1; }
  TXN_FORCE=${FORCE:+1}; op_txn "更新云端内容" txn_content
  info "内容来源: $(cloud_status_json | sed -n 's/.*"source":"\([a-z]*\)".*/\1/p') · 序号 $(cloud_seq) $(cloud_version)"
}
cmd_tick() { # 每分钟一次 (launchd): 流量统计采样; 每 ~2 分钟一次登录会话心跳; 自动识别打不开的网站; 每小时一次日志切分 + 清理
  local last=0
  stats_collect
  health_tick || true                          # 连接健康记录: 每分钟探测服务器端口 + 记录状态变化, 每 ~5 分钟经代理访问关键站点 (见 lib/health.sh); 排在心跳之前, 状态时间点才准
  [ -f "$H/.hb.last" ] && IFS= read -r last < "$H/.hb.last"
  if [ $(( $(now) - ${last:-0} )) -ge 110 ]; then now > "$H/.hb.last"; session_heartbeat; fi
  sync_auto_tick || true                       # 自动同步 (打开了才工作; 每 10 分钟检查一次)
  official_tick || true                        # 官方线路 (会员): 每 4 小时向云端取一次节点, 失败退避; 节点没变化就什么都不做 (见 lib/official.sh)
  autosite_tick || true                        # 自动识别无法访问的网站 (设置里打开了才工作); 必须排在日志切分之前
  logs_tick || true                            # 日志: 每小时切分 / 压缩 / 按保留期 (最短 12 小时) 清理
  diag_tick || true                            # 诊断摘要: 操作记录里有「值得上报」的新事件才上传一次 (见 lib/diag.sh; 设置里可关)
  return 0
}

cmd_upgrade() { # 升级核心: 先下载, 用新核心校验现有配置, 通过才替换 (op_core_upgrade 里完成并打印结果)
  info "当前 sing-box $(core_version); 查询最新版本…"
  op_core_upgrade "${ARG1:-latest}"
}
cmd_self_update() { # 升级 enana 本体: 交给 get.sh (下载 → SHA-256 校验 → 替换 → 重新生成配置); 会先询问确认
  if [ "$ENANA_PLATFORM" = windows ]; then win_bridge self-update; return; fi
  [ -f "$H/get.sh" ] || die "找不到升级脚本" "重新运行安装命令: curl -fsSL https://enana.cc/get.sh | bash"
  update_check force >/dev/null 2>&1 || true
  if ! update_has_new && [ -z "$FORCE" ]; then ok "已经是最新版本 (v$VERSION)"; return 0; fi
  exec bash "$H/get.sh" --upgrade ${ENANA_YES:+--yes}
}

cmd_logout() { # 退出账号: 关闭代理 + 令牌立刻失效 + 清除本机的离线登录缓存; 之后要重新登录才能再开启代理
  if ! auth_logged_in && ! auth_cache_has; then info "当前没有登录, 也没有本机登录缓存"; return 0; fi
  info "退出账号后: 代理会被关闭 (全部直连), 所有已打开的仪表盘需要重新登录, 本机保存的离线登录缓存也会清除。"
  info "之后在仪表盘里用 enana.cc 账号 (可以换另一个账号, 也可以直接注册) 登录, 再手动开启代理。"
  confirm "确认退出账号?" n || { info "已取消"; return 1; }
  op_logout purge
}
cmd_lang() { # enana lang [zh|en]
  local l=${ARG1:-}
  if [ -z "$l" ]; then
    menu_reset; menu_add lang "界面语言 / Language" choice "$LANG_UI" 'zh:中文|en:English' "按 ←/→ 切换, Enter 确认 / Use ←/→ then Enter"
    menu_interactive || { echo "$LANG_UI"; return 0; }
    menu_run || return 1; l=$(menu_val lang)
  fi
  case " $I18N_LANGS " in *" $l "*) ;; *) die "不支持的语言: $l" "可选: $I18N_LANGS" ;; esac
  settings_set LANG_UI "$l"; LANG_UI=$l; I18N_LANG=$l
  ok "界面语言已设为 $l (终端与仪表盘)"
}

cmd_doctor() { _doctor_body 2>&1 | i18n_filter; }      # 整段输出逐行翻译 (诊断信息里的系统命令输出本来就是英文, 原样保留)
_doctor_body() { # 诊断信息 (不含任何密码/订阅链接), 出问题时把输出发给开发者
  echo "== 环境 =="; echo "enana $VERSION · $(os_name) $(os_version) $(os_arch) · bash $BASH_VERSION · 安装目录 $H · 语言 $LANG_UI"
  echo "核心: $(core_version) $(core_ok && echo OK || echo 无法运行)"
  echo "== 服务 =="; os_service_info
  printf 'service.loaded=%s\nservice.running=%s\nservice.pid=%s\n' "$SVC_LOADED" "$SVC_RUNNING" "$SVC_PID"
  os_api_loaded && echo "辅助服务: 已加载" || echo "辅助服务: 未加载"
  os_maintenance_loaded && echo "每日维护: 已加载" || echo "每日维护: 未加载"
  for _p in $PORT $UI_PORT $API_PORT $SPEED_PORT; do nc -z 127.0.0.1 "$_p" 2>/dev/null && echo "端口 $_p: 监听中" || echo "端口 $_p: 未监听"; done
  echo "后台地址: $UI_URL"
  echo "== 账号 =="; if auth_logged_in; then echo "已登录 $(auth_mask_email "$(auth_current_email)")"; else echo "未登录"; fi; echo "离线登录缓存: $(auth_cache_has && echo "有 ($(auth_hint))" || echo 无) · 代理总开关: $([ "${PROXY_ENABLED:-0}" = 1 ] && echo 开启 || echo 关闭)"
  echo "账号服务: ${ACCOUNT_URL%/} → HTTP $(curl -s -o /dev/null -m 8 --noproxy '*' -w '%{http_code}' "${ACCOUNT_URL%/}/api/health" || echo 000)"
  echo "== 配置 =="; "$SB" check -c "$H/config.json" 2>&1 | head -5 && echo "(配置校验结束)"
  echo "服务器 $(srv_count) 台, 订阅 $(awk 'END{print NR}' "$H/subs.tsv" 2>/dev/null) 个, 应用覆盖 $(awk -F'|' '$1=="app"{n++} END{print n+0}' "$H/overrides.tsv" 2>/dev/null) 个"
  echo "规则集缺失: $(rules_missing | paste -sd, -)"
  echo "== 更新 =="; echo "$(update_available)"
  echo "== Capture =="; network_diagnostics
  echo "== 系统代理 =="; if [ "$ENANA_PLATFORM" = windows ]; then win_bridge sysproxy-diagnostics
  else while IFS= read -r _s; do printf '%s: ' "$_s"; networksetup -getsecurewebproxy "$_s" | tr '\n' ' '; echo; done < <(os_sysproxy_services); fi
  echo "== 网络 =="; probe_net; echo "GitHub ${NET_GITHUB}ms · jsDelivr ${NET_JSD}ms · Google ${NET_GOOGLE}ms · 百度 ${NET_BAIDU}ms → $NET_REGION"
  date "+系统时间: %F %T %Z"
  echo "== 日志最后 20 行 =="; tail -n 20 "$H/sing-box.log" 2>/dev/null || echo "(无日志)"
}

cmd_uninstall() {
  [ -f "$H/.enana-home" ] || { warn "没有找到安装目录 ($H)"; return 1; }
  [ -n "$H" ] && [ "$H" != / ] && [ "$H" != "$HOME" ] && [ ! -L "$H" ] || { warn "安装目录不安全, 未执行卸载"; return 1; }
  local msg="确认完整卸载? 将还原系统代理、停止服务、删除快捷命令和全部本机数据 (账号、服务器、订阅、设置、日志与缓存)"
  confirm "$msg" n || { info "已取消"; return 1; }
  # 本机数据 (包括设备编号) 马上要删除, 重装后会被云端当成一台新设备: 先同步告诉云端释放这台设备占用的名额, 否则要等 10 分钟没有心跳才会释放 (同账号每个平台最多 2 台)
  if auth_logged_in && [ -n "$(session_id)" ]; then
    if session_logout_wait; then info "已通知云端释放这台设备的在线名额"; else warn "没能联系上云端: 这台设备的在线名额会在 10 分钟没有心跳后自动释放"; fi
  fi
  os_sysproxy_uninstall || return 1
  os_service_stop || return 1; enhanced_remove || return 1; os_aux_unload || return 1
  os_stop_owned_jobs || return 1
  rm -f "$PLIST" "$PLIST_API" "$PLIST_UPD" "$PLIST_TICK" || return 1
  shortcut_remove || return 1
  if [ "${ENANA_PLATFORM:-darwin}" = windows ]; then
    # A Windows executable cannot delete its own loaded PortableGit runtime.
    # The native CLI finishes removal after this Bash process has returned.
    printf '\n' > "$H/.windows-uninstall"
    return 0
  fi
  rm -rf "$H" || { warn "删除安装数据失败, 卸载未完成"; return 1; }
  [ ! -e "$H" ] || { warn "删除安装数据失败, 卸载未完成"; return 1; }
  ok "已完整卸载, 本机数据已删除"
  return 0
}

cmd_help() {
  _t "enana $VERSION — 代理环境控制台 (服务器/订阅/应用/网站请在仪表盘里设置: $UI_URL)"; echo
  cat <<EOF

$(_t "  enana                打开控制台 (状态 · 一键重启 · 暂停 · 更新 · 日志 · 诊断 · 退出账号 · 卸载)")
$(_t "  enana status         查看运行状态")
$(_t "  enana restart        重启代理服务")
$(_t "  enana on | off       开启 / 关闭 (系统代理 + 服务)")
$(_t "  enana start | stop   仅启动 / 停止服务 (stop 同时会关闭系统代理, 避免断网)")
$(_t "  enana update         更新规则集 + 订阅 (--quiet 只刷新到期的订阅)")
$(_t "  enana self-update    更新 enana 本体 (先询问确认; --yes 跳过)")
$(_t "  enana upgrade [版本]  升级 sing-box 核心 (先校验现有配置, 不通过自动回退)")
$(_t "  enana logout         退出账号: 关闭代理, 清除本机登录信息 (之后要重新登录才能再开启代理)")
$(_t "  enana lang [zh|en]   切换界面语言 (终端与仪表盘)")
  enana network-mode system|tun   System Proxy / Enhanced (管理员授权)
$(_t "  enana doctor         诊断信息 (不含密码, 反馈问题时贴出来)")
$(_t "  enana logs [行数]     查看日志")
$(_t "  enana diag [小时数]   导出诊断文件 (操作记录 + 网站访问 + 代理日志 + 当前状态, 默认最近 24 小时; 接管道直接输出)")
$(_t "  enana diag-preview   看下一份自动上传的诊断摘要 (没有网站 / 应用名 / IP / 服务器地址); diag-upload 立刻传一份")
$(_t "  enana diag-send [小时数] 发送完整诊断给开发者 (含域名和应用名, 7 天后自动删除), 给一个报告编号; diag-delete 删除已上传的")
$(_t "  enana open           打开仪表盘")
$(_t "  enana env            打印终端代理变量 (命令行工具不读系统代理): eval \"\$(enana env)\"")
$(_t "  enana uninstall      完整卸载 (删除全部本机数据)")
$(_t "选项: --yes 全部采用推荐值 · --force 强制重装环境 · --quiet 静默 · --lang zh|en 指定语言")
EOF
}

# ============================== 入口 ==============================
parse_args "$@"
case ${CMD:-auto} in
  auto)      # 仓库里的 install.sh = 安装器 (git pull 后再运行即可升级/修复); 已安装的 enana 命令 = 控制台
             if [ "$SRC" = "$H" ] && core_ok && [ -t 0 ] && [ -t 1 ]; then console_main; elif [ "$SRC" = "$H" ]; then cmd_status; else cmd_install; fi ;;
  install|reinstall) cmd_install ;;
  console)   console_main ;;
  status)    cmd_status ;;
  start)     cmd_start ;;
  stop|off)  cmd_off ;;
  restart)   cmd_restart ;;
  on)        cmd_on ;;
  update)    cmd_update ;;
  maintain)  cmd_maintain ;;
  tick|heartbeat) cmd_tick ;;
  content)   cmd_content ;;
  upgrade)   cmd_upgrade ;;
  self-update|selfupdate) cmd_self_update ;;
  logout|unbind|passwd|reset-password) cmd_logout ;;
  lang)      cmd_lang ;;
  doctor)    cmd_doctor ;;
  logs)      cmd_logs ;;
  diag|diagnostics) cmd_diag ;;
  diag-preview) cmd_diag_preview ;;
  diag-upload) cmd_diag_upload ;;
  diag-send) cmd_diag_send ;;
  diag-delete) cmd_diag_delete ;;
  open)      cmd_open ;;
  env)       cmd_env ;;
  network-mode) cmd_network_mode ;;
  uninstall) cmd_uninstall ;;
  version|--version) echo "enana $VERSION" ;;
  help|-h|--help) cmd_help ;;
  _job)      shift; job_dispatch "$@" ;;
  apply)     if op_lock; then apply_config; _rc=$?; op_unlock; else apply_config; _rc=$?; fi
             [ "$_rc" = 0 ] && ok "配置已应用" || die "配置无效" "$(head -c 300 "$H/check.log" 2>/dev/null)" ;;
  *)         cmd_help; exit 1 ;;
esac
