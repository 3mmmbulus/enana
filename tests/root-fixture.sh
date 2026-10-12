#!/bin/bash
# 测试夹具 (由 tests/tun-service.sh 与 tests/enhanced-root-integrity.sh 引用, 不单独运行):
#   · lib/enhanced-root.sh 复制一份到临时目录, 固定路径 / 命令换成临时目录里的替身 (ROOT、plist、sudoers、libexec、launchctl、install、chown、route、ifconfig、sleep)
#   · enana 一侧的函数直接用 lib/enhanced.sh 的原文 (LIB 指向夹具里的副本), 所以两边的摘要、渲染、暂存都是真实代码
#   · 假 sudo 只做两件事: `sudo -n true` 成功; `sudo -n /bin/sh -c CMD` 在本机以当前用户运行 CMD (root 脚本自己的 id 检查已替换成 printf 0)
#   · 绝不运行真实的 launchctl / sudo / osascript / networksetup; 解析到真实命令的 PATH 由调用方检查
# 用法: rf_setup <临时目录>; rf_reset (每个用例前清空); rf_enana_start (调用 enhanced_start, 返回其退出码)

RF_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
rf_setup() {
  W=$1; ME=$(id -u); LIBT=$W/lib; H=$W/home/.enana; ROOTB=$W/support; ROOT=$ROOTB/enana-$ME
  mkdir -p "$W/bin" "$W/fakebin" "$W/daemons" "$W/sudoers.d" "$W/usr/local" "$LIBT" "$H/rules/geo" "$ROOTB"
  cp "$RF_REPO/lib/tunrules-helper.pl" "$LIBT/"
  cp "$RF_REPO/lib/enhanced.sh" "$LIBT/"
  cat > "$W/root.sed" <<SED
s|^root_base=.*|root_base="$ROOTB"|
s|^usr_local=.*|usr_local="$W/usr/local"; libexec="\$usr_local/libexec/enana"; sudoers_dir="$W/sudoers.d"|
s|^launchctl_bin=.*|launchctl_bin="$W/bin/launchctl"|
s|^root_owner=0|root_owner=$ME|
s|/usr/bin/id -u|printf 0|
s|plist="/Library/LaunchDaemons/|plist="$W/daemons/|
s|/usr/sbin/chown|$W/bin/chown|g
s|/usr/bin/install|$W/bin/install|g
s|/sbin/route|$W/bin/route|g
s|/sbin/ifconfig|$W/bin/ifconfig|g
s|/bin/sleep|$W/bin/sleep|g
SED
  sed -f "$W/root.sed" "$RF_REPO/lib/enhanced-root.sh" > "$LIBT/enhanced-root.sh"
  printf '#!/bin/sh\nexit 0\n' > "$W/bin/chown"; printf '#!/bin/sh\nexit 0\n' > "$W/bin/sleep"
  printf '#!/bin/sh\necho "interface: utun42"\n' > "$W/bin/route"
  printf '#!/bin/sh\necho "inet 172.19.0.1 netmask 0xfffffffc"\n' > "$W/bin/ifconfig"
  cat > "$W/bin/install" <<'MOCK'
#!/bin/bash
# 假 install: 忽略 -o/-g, 支持 -d / -m; 只许写进夹具 (ENANA_ROOT_PREFIX 之下)
mode=''; dirs=0; args=(); while [ $# -gt 0 ]; do case $1 in -d) dirs=1; shift ;; -m) mode=$2; shift 2 ;; -o|-g) shift 2 ;; -*) shift ;; *) args+=("$1"); shift ;; esac; done
if [ "$dirs" = 1 ]; then for d in "${args[@]}"; do mkdir -p "$d" && { [ -z "$mode" ] || chmod "$mode" "$d"; } || exit 1; done; exit 0; fi
[ "${#args[@]}" -eq 2 ] || exit 1
cp "${args[0]}" "${args[1]}" && { [ -z "$mode" ] || chmod "$mode" "${args[1]}"; }
MOCK
  cat > "$W/bin/launchctl" <<'MOCK'
#!/bin/sh
# 假 launchctl: 记录每一次调用; "loaded" 标记表示系统守护进程已加载; fail-bootstrap 标记让下一次 bootstrap 失败
echo "$*" >> "$RF_W/calls"
case $1 in
  print) case ${2:-} in gui/*) exit 1 ;; esac; [ -f "$RF_W/loaded" ] && { echo 'pid = 100'; exit 0; }; exit 1 ;;
  bootstrap) if [ -f "$RF_W/fail-bootstrap" ]; then rm -f "$RF_W/fail-bootstrap"; exit 1; fi; : > "$RF_W/loaded"; exit 0 ;;
  bootout) rm -f "$RF_W/loaded"; exit 0 ;;
  asuser) exit 0 ;;
esac
exit 0
MOCK
  cat > "$W/fakebin/sudo" <<'MOCK'
#!/bin/sh
# 假 sudo (见 tests/root-fixture.sh): 记录调用; -n true 成功; -n /bin/sh -c CMD 在本机运行 CMD
[ "$1" = -n ] && shift
[ "$1" = true ] && exit 0
[ "$1" = -l ] && exit 0                  # sudo -n -l PATH: 只查规则 (测试里总是有免密规则), 不运行 PATH
echo "$*" >> "$RF_W/sudo.log"
[ -z "${RF_HOOK:-}" ] || eval "$RF_HOOK" # 用例可以在管理员命令运行之前改动暂存目录 (见 tests/enhanced-root-integrity.sh)
# 以 root 运行的固定路径改写成夹具里的路径: TUN 副本的目录 (/Library/Application Support/enana-UID) 和 libexec (/usr/local)
args=(); for a in "$@"; do args+=("$(printf '%s' "$a" | sed -e "s|/Library/Application Support/enana-$(id -u)|$RF_ROOT|g" -e "s|/usr/local|$RF_W/usr/local|g")"); done
set -- "${args[@]}"
exec "$@"
MOCK
  printf '#!/bin/sh\n[ "$1" = check ]\n' > "$W/sing-box"
  chmod +x "$W/bin/"* "$W/fakebin/sudo" "$W/sing-box"
  printf '%s\n' '{"log":{"level":"info","output":"'"$H"'/sing-box.log"},"inbounds":[{"type":"tun","tag":"tun-in"}],"route":{"rule_set":[{"type":"local","tag":"geo","path":"'"$H"'/rules/geo/geo.srs"}],"final":"direct"},"experimental":{"cache_file":{"enabled":true,"path":"'"$H"'/cache.db"}}}' > "$H/config.json"
  printf 'SRS' > "$H/rules/geo/geo.srs"
  cp "$W/sing-box" "$H/sing-box"
  # 核心来源 / 摘要记录 (6.1 / 6.2): 夹具里的核心是"官方钉死版本"的
  printf 'pinned 1.12.0 %s\n' "$(shasum -a 256 "$H/sing-box" | awk '{print $1}')" > "$H/core-provenance"
  shasum -a 256 "$H/sing-box" | awk '{print $1}' > "$H/core-binary.sha256"
  export RF_W=$W RF_ROOT=$ROOT ENANA_TEST=1 ENANA_TUN_ROOT="$ROOT" ENANA_TUN_PLIST_DIR="$W/daemons" ENANA_ROOT_PREFIX="$W" ENANA_TUN_LAUNCHCTL="$W/bin/launchctl"
  export PATH="$W/fakebin:$PATH"
  rf_load_enana
}
rf_load_enana() { # 只加载 enana 这一侧的函数 (不跑 install.sh / common.sh 的初始化)
  test_env() { local v=''; [ -n "${ENANA_TEST:-}" ] && v=${!1:-}; printf '%s' "${v:-${2:-}}"; }
  _t() { printf '%s' "$1"; }
  clash() { printf '{"proxies":{}}'; }
  logs_rotate() { :; }
  enhanced_supported() { return 0; }
  enhanced_restore_selectors() { :; }
  LABEL=com.enana.proxy; AUTOSTART=1; LIB=$LIBT; SB=$H/sing-box; PORT=37890
  . "$LIBT/enhanced.sh"
  sb_ver() { SB_MAJOR=1; SB_MINOR=14; }         # 核心版本检查在 lib/config.sh; 这里假定核心够新
  . "$RF_REPO/lib/os-darwin.sh"                 # os_helper_trusted: 只定义函数, 没有副作用
}
rf_reset() { # 每个用例前: 回到"已经装过"之前的干净状态
  rm -rf "$ROOTB"/* "$W/daemons"/* "$W/sudoers.d"/* "$W/usr" "$W/calls" "$W/sudo.log" "$W/loaded" "$W/fail-bootstrap" "$W/stage.path" "$W/last.cmd" 2>/dev/null
  mkdir -p "$W/usr/local" "$ROOT"; : > "$W/calls"; : > "$W/sudo.log"
  unset RF_HOOK
}
# enana 的 TUN 启动 (和 os_service_start 调的是同一个函数); stage 路径记在 $W/stage.path, 用例可以在管理员调用之前改动它 (HOOK)
mktemp() { if [ "${1:-}" = -d ]; then local d; d=$(command mktemp -d "$W/stg.XXXXXX") && printf '%s\n' "$d" > "$W/stage.path" && printf '%s\n' "$d"; else command mktemp "$@"; fi; }
rf_enana_start() {
  ( enhanced_start ) >"$W/start.out" 2>&1; local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "  (enhanced_start 退出码 $rc, 输出:)"; sed 's/^/    | /' "$W/start.out" | tail -60
    for f in "$H/enhanced-check.log" "$H/check.log"; do [ -f "$f" ] && { echo "  ($f:)"; sed 's/^/    | /' "$f" | tail -20; }; done
    echo "  (诊断) TUN_ROOT=$ROOT H=$H"
    echo "  (诊断) 原始配置:"; sed 's/^/    cfg| /' "$H/config.json" 2>&1 | head -c 1500; echo
    enhanced_stage_config "$H/config.json" "$H" "$ROOT" > "$W/diag-staged.json" 2>"$W/diag-staged.err"
    echo "  (诊断) 改写后 (rc=$?, err=$(head -c 300 "$W/diag-staged.err")):"; sed 's/^/    st| /' "$W/diag-staged.json" | head -c 1500; echo
    echo "  (诊断) 检查器对改写结果:"; /bin/bash "$LIBT/enhanced-root.sh" check-config "$W/diag-staged.json" "$ROOT" 2>&1 | sed 's/^/    chk| /'
  fi
  return "$rc"
}
rf_admin_calls() { wc -l < "$W/sudo.log" 2>/dev/null | tr -d ' '; }
