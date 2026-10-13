#!/bin/bash
# 外部代理内核与端口归属 (安装 / 升级, macOS) 的隔离测试。不碰真实的 ~/.enana、~/Library、/Library、/etc、launchd 或任何进程, 也不联网:
#   ps / lsof / launchctl / nc / route / ifconfig / networksetup / curl 是 PATH 里的假命令; kill / sudo / osascript / open / pkill / killall 只记录, 不执行。
#   加载的是真实的 install.sh (只执行 version 子命令, 不安装任何东西), 测试的是真实的函数; 路径覆盖只在 ENANA_TEST=1 下生效。
# 用法: bash tests/detect.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd -P); REPO=$(dirname "$HERE")
W=$(mktemp -d /tmp/enana-detect.XXXXXX); W=$(cd "$W" && pwd -P); trap 'rm -rf "$W"' EXIT
: > "$W/.pass"; : > "$W/.fail"
tpass() { echo p >> "$W/.pass"; echo "  ✓ $1"; }
tfail() { echo f >> "$W/.fail"; echo "  ✗ $1"; [ -n "${2:-}" ] && printf '      ↳ %s\n' "$(printf '%s' "$2" | head -c 600)"; return 0; }
eq()    { if [ "$2" = "$3" ]; then tpass "$1"; else tfail "$1" "期望 [$3] 实际 [$2]"; fi; }
has()   { case $2 in *"$3"*) tpass "$1" ;; *) tfail "$1" "没有 [$3]" ;; esac; }
hasnt() { case $2 in *"$3"*) tfail "$1" "不应该出现 [$3]" ;; *) tpass "$1" ;; esac; }

# ---------- 假命令 ----------
mkdir -p "$W/bin"
cat > "$W/bin/ps" <<'SH'
#!/bin/bash
# 假的 ps: $FAKE_PS 每行 "进程号 可执行文件路径"; -axo comm= 只要路径, -axo pid=,comm= 要进程号, -o comm= -p N 只查一个
case " $* " in
  *" -p "*) want=''; while [ $# -gt 0 ]; do [ "$1" = -p ] && want=$2; shift; done
            awk -v p="$want" '$1 == p { sub(/^[0-9]+ +/, ""); print; exit }' "$FAKE_PS" ;;
  *pid=*) cat "$FAKE_PS" ;;
  *) awk '{ sub(/^[0-9]+ +/, ""); print }' "$FAKE_PS" ;;
esac
SH
cat > "$W/bin/lsof" <<'SH'
#!/bin/bash
# 假的 lsof: $FAKE_LSOF 每行 "端口 进程号 地址" (只有 LISTEN); 支持 -iTCP:端口 与 -Fpn
port=''; fields=p
for a in "$@"; do case $a in -iTCP:*) port=${a#-iTCP:} ;; -Fpn) fields=pn ;; esac; done
awk -v port="$port" -v f="$fields" '($1 == port || port == "") { print "p" $2; if (f == "pn") print "n" $3 ":" $1 }' "$FAKE_LSOF" | awk '!seen[$0]++'
SH
cat > "$W/bin/nc" <<'SH'
#!/bin/bash
# 假的 nc: 只回答有没有人在听 (FAKE_BUSY 里的端口算有人在听)
for p in ${FAKE_BUSY:-}; do [ "$p" = "${!#}" ] && exit 0; done
exit 1
SH
cat > "$W/bin/launchctl" <<'SH'
#!/bin/bash
# 假的 launchctl: 只读查询按 FAKE_* 回答; 其它子命令 (bootout / bootstrap / kickstart / enable / disable / remove …) 只记录, 并失败
echo "launchctl $*" >> "$FAKE_CALLS"
case $1 in
  print)
    case $2 in
      gui/*/com.enana.proxy) [ -n "${FAKE_SVC_PID:-}" ] || exit 113; printf 'gui/501/com.enana.proxy = {\n\tstate = running\n\tpid = %s\n}\n' "$FAKE_SVC_PID" ;;
      gui/*/com.enana.proxy.api) [ -n "${FAKE_API:-}" ] || exit 113; printf 'gui/501/com.enana.proxy.api = {\n\tstate = not running\n}\n' ;;
      system/*) [ -n "${FAKE_TUN_PID:-}" ] || exit 113; printf 'system/com.enana.proxy.tun.501 = {\n\tstate = running\n\tpid = %s\n}\n' "$FAKE_TUN_PID" ;;
      *) exit 113 ;;
    esac ;;
  list) cat "$FAKE_LIST" ;;
  *) echo "launchctl 替身拒绝: $1" >&2; exit 1 ;;
esac
SH
cat > "$W/bin/route" <<'SH'
#!/bin/bash
[ "$*" = "-n get default" ] && { printf '   route to: default\n    interface: %s\n' "${FAKE_DEFAULT_IF:-en0}"; exit 0; }
exit 1
SH
cat > "$W/bin/ifconfig" <<'SH'
#!/bin/bash
printf '%s: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1380\n\tinet %s --> 10.0.0.1 netmask 0xffffffff\n' "$1" "${FAKE_TUN_INET:-10.7.0.2}"
SH
cat > "$W/bin/networksetup" <<'SH'
#!/bin/bash
case $1 in
  -listallnetworkservices) printf 'An asterisk (*) denotes that a network service is disabled.\nWi-Fi\n' ;;
  -getwebproxy)
    if [ -n "${FAKE_PROXY_PORT:-}" ]; then printf 'Enabled: Yes\nServer: %s\nPort: %s\n' "${FAKE_PROXY_SERVER:-127.0.0.1}" "$FAKE_PROXY_PORT"
    elif [ -n "${FAKE_FOREIGN_PROXY:-}" ]; then printf 'Enabled: Yes\nServer: 10.1.1.1\nPort: 8080\n'
    else printf 'Enabled: No\nServer: \nPort: 0\n'; fi ;;
  *) printf 'Enabled: No\nServer: \nPort: 0\n' ;;
esac
SH
cat > "$W/bin/curl" <<'SH'
#!/bin/bash
# 假的 curl: 从不联网, 只记录; 退出码 7 (连不上)
echo "curl $*" >> "$FAKE_CALLS"; exit 7
SH
cat > "$W/bin/_refuse" <<'SH'
#!/bin/bash
echo "$(basename "$0") $*" >> "$FAKE_CALLS"; exit 99
SH
for c in sudo osascript open pkill killall; do ln -sf "$W/bin/_refuse" "$W/bin/$c"; done
chmod +x "$W"/bin/*
for c in ps lsof nc launchctl route ifconfig networksetup curl sudo osascript open pkill killall; do
  case "$(PATH="$W/bin:/usr/bin:/bin:/usr/sbin:/sbin" command -v "$c")" in "$W/bin/"*) ;; *) echo "REFUSING: $c 解析到的不是假命令, 为防止改动系统已中止"; exit 1 ;; esac
done

# ---------- 用例环境 ----------
mkcase() { local d; d=$(mktemp -d "$W/case.XXXXXX") && (cd "$d" && pwd -P); }
enter() { # 进入一个隔离用例: 导出全部环境 (HOME、安装目录、假的系统状态), 再加载真实的 install.sh (只执行 version, 不安装)
  local c=$1 rc
  mkdir -p "$c/home" "$c/h" "$c/LaunchAgents" "$c/LaunchDaemons" "$c/fbin" "$c/root"
  export HOME="$c/home" ENANA_HOME="$c/h" ENANA_PLIST_DIR="$c/LaunchAgents" ENANA_TUN_PLIST_DIR="$c/LaunchDaemons"
  export ENANA_TEST=1 ENANA_TUN_ROOT="$c/Library/Application Support/enana-501" ENANA_ROOT_PREFIX="$c/root" ENANA_SINGBOX_DIRS="$c/fbin"
  export ENANA_LANG=zh ENANA_SKIP_PROBE=1 LC_ALL=C PORT=39700 UI_PORT=39701 API_PORT=39702 SPEED_PORT=39703
  export FAKE_CALLS="$c/calls" FAKE_PS="$c/ps" FAKE_LSOF="$c/lsof" FAKE_LIST="$c/list"
  export PATH="$W/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  : > "$c/calls"; : > "$c/ps"; : > "$c/lsof"; printf 'PID\tStatus\tLabel\n' > "$c/list"
  unset ENANA_YES FAKE_SVC_PID FAKE_TUN_PID FAKE_API FAKE_BUSY FAKE_DEFAULT_IF FAKE_TUN_INET FAKE_FOREIGN_PROXY FAKE_PROXY_PORT FAKE_PROXY_SERVER
  set -- version
  . "$REPO/install.sh" > "$c/load.out" 2>&1; rc=$?
  [ "$rc" = 0 ] || { tfail "加载真实的 install.sh 失败 (退出码 $rc)" "$(head -c 600 "$c/load.out")"; exit 1; }
  STEPS=4; MACOS=14.5; MACOS_MAJOR=14; ARCH=arm64; SEL_sysproxy=0
  kill() { echo "kill $*" >> "$FAKE_CALLS"; return 0; }    # 函数会盖过内建的 kill: 只记录, 不结束任何进程
}
nomut() { # 这个用例里没有结束进程、没有卸载或修改 launchd、没有提权或弹窗
  local bad
  bad=$(grep -E '^(kill|pkill|killall|sudo|osascript|open)( |$)|^launchctl (bootout|bootstrap|kickstart|enable|disable|remove|unload|load|start|stop|submit|kill)( |$)' "$FAKE_CALLS" || true)
  if [ -z "$bad" ]; then tpass "$1: 没有 kill / launchd 改动 / 提权"; else tfail "$1: 出现了不该有的调用" "$bad"; fi
}

echo "== 1. 外部 sing-box 的识别 (detect_others): 按可执行文件路径认, enana 自己的核心 (含增强模式的 root 副本与暂存文件, 路径有空格) 不报告"
(
  c=$(mkcase); enter "$c"
  printf '100 %s\n200 /opt/homebrew/bin/sing-box\n' "$H/sing-box" > "$FAKE_PS"; export FAKE_SVC_PID=100
  detect_others
  eq "enana 正在运行时, 别的 sing-box 仍然报告 (旧版会因为 enana 在运行而把它去掉)" "$OTHER_PROXY" "sing-box"
  nomut "1a"
)
(
  c=$(mkcase); enter "$c"
  printf '100 %s\n101 %s\n' "$H/sing-box" "$ENANA_TUN_ROOT/sing-box" > "$FAKE_PS"; export FAKE_SVC_PID=100
  detect_others
  eq "只有 enana 自己的核心 (用户态 + 增强模式的 root 副本) 时不报告" "$OTHER_PROXY" ""
  nomut "1b"
)
(
  c=$(mkcase); enter "$c"
  printf '300 /Applications/Clash Verge.app/Contents/MacOS/clash-verge\n' > "$FAKE_PS"
  detect_others
  eq "其它代理软件 (按名字) 照常报告" "$OTHER_PROXY" "clash-verge"
  nomut "1c"
)
(
  c=$(mkcase); enter "$c"
  printf '101 %s\n' "$ENANA_TUN_ROOT/.prepare.123/sing-box" > "$FAKE_PS"
  detect_others
  eq "增强模式 TUN 根目录下暂存中的核心 (.prepare.*) 也是 enana 自己的" "$OTHER_PROXY" ""
  nomut "1d"
)

echo "== 2. 只读清单 (detect_foreign): 只有名称、路径、进程号; 不读取配置内容, 不运行任何 sing-box"
(
  c=$(mkcase); enter "$c"
  printf '100 %s\n200 /opt/homebrew/bin/sing-box\n' "$H/sing-box" > "$FAKE_PS"; export FAKE_SVC_PID=100
  detect_foreign
  eq "运行中的外部 sing-box: 1 个进程 (enana 自己的核心不计)" "$FOREIGN_PROC" "1"
  has "清单里有外部进程的进程号和路径" "$FOREIGN_TEXT" "pid=200"
  hasnt "清单里没有 enana 自己的核心" "$FOREIGN_TEXT" "pid=100"
  nomut "2a"
)
(
  c=$(mkcase); enter "$c"
  printf '#!/bin/sh\nexit 0\n' > "$c/fbin/sing-box"; chmod +x "$c/fbin/sing-box"
  printf 'PID\tStatus\tLabel\n-\t0\thomebrew.mxcl.sing-box\n4321\t0\tcom.enana.proxy\n-\t0\tcom.enana.sing-box-old\n' > "$FAKE_LIST"
  : > "$c/LaunchAgents/homebrew.mxcl.sing-box.plist"; : > "$c/LaunchAgents/com.enana.proxy.plist"; : > "$c/LaunchAgents/com.enana.sing-box-old.plist"
  : > "$c/LaunchDaemons/com.enana.proxy.tun.501.plist"
  mkdir -p "$c/home/.config/sing-box"; printf '{"token":"SECRET-SENTINEL-7f3a"}\n' > "$c/home/.config/sing-box/config.json"
  detect_foreign
  eq "外部 sing-box 程序: 1 个 (ENANA_SINGBOX_DIRS 里的)" "$FOREIGN_BIN" "1"
  eq "已加载的外部 launchd 任务: 1 个 (com.enana.* 不算)" "$FOREIGN_LAUNCHD" "1"
  eq "只有配置文件、没有加载的 launchd: 1 个 (com.enana.* 不算)" "$FOREIGN_PLIST" "1"
  eq "配置目录: 1 个" "$FOREIGN_CFG" "1"
  has "程序写的是解析后的真实路径" "$FOREIGN_TEXT" "$c/fbin/sing-box"
  has "launchd 任务的名字" "$FOREIGN_TEXT" "homebrew.mxcl.sing-box"
  hasnt "com.enana.* 不列出" "$FOREIGN_TEXT" "com.enana"
  foreign_write_inventory
  inv=$(cat "$H/foreign-inventory.txt")
  hasnt "清单文件里没有配置内容" "$inv" "SECRET-SENTINEL"
  has "清单文件只写配置目录的路径" "$inv" "$c/home/.config/sing-box"
  eq "清单文件权限 600" "$(stat -f %Lp "$H/foreign-inventory.txt")" "600"
  eq "写清单没有留下临时文件" "$(find "$H" -name '.foreign-inventory.*' | wc -l | tr -d ' ')" "0"
  nomut "2b"
)
(
  c=$(mkcase); enter "$c"; export FAKE_DEFAULT_IF=utun5 FAKE_TUN_INET=10.7.0.2
  detect_foreign
  eq "默认路由经过别的 utun: 计 1 个, 写明网卡名" "$FOREIGN_TUN:$FOREIGN_TUN_IF" "1:utun5"
  export FAKE_TUN_INET=172.19.0.1
  detect_foreign
  eq "enana 自己的增强模式网卡 (172.19.0.1) 不计" "$FOREIGN_TUN" "0"
  nomut "2c"
)
(
  c=$(mkcase); enter "$c"
  printf '100 %s\n1 /sbin/launchd\n200 /opt/homebrew/bin/sing-box\n' "$H/sing-box" > "$FAKE_PS"; export FAKE_SVC_PID=100 FAKE_API=1
  printf '39700 100 127.0.0.1\n39702 1 127.0.0.1\n39703 200 127.0.0.1\n5353 200 *\n' > "$FAKE_LSOF"
  detect_foreign
  eq "TCP 监听: 只列 enana 四个端口上的外部监听 (核心 / launchd 代管的 API 不算)" "$FOREIGN_LISTEN" "1"
  has "外部进程在 enana 端口上的监听写进清单" "$FOREIGN_TEXT" "127.0.0.1:39703"
  hasnt "别的端口 (5353) 的监听不写进清单" "$FOREIGN_TEXT" "5353"
  nomut "2d"
)
(
  c=$(mkcase); enter "$c"
  printf '100 %s\n' "$H/sing-box" > "$FAKE_PS"; export FAKE_SVC_PID=100
  printf '39700 999 127.0.0.1\n' > "$FAKE_LSOF"
  detect_foreign
  eq "监听者在 lsof 与 ps 之间已经退出: 不计入清单 (不算外部程序)" "$FOREIGN_LISTEN" "0"
  nomut "2e"
)
(
  c=$(mkcase); enter "$c"
  unset ENANA_SINGBOX_DIRS; export HOME="$c/home dir"
  mkdir -p "$HOME/.local/bin"; printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/sing-box"; chmod +x "$HOME/.local/bin/sing-box"
  detect_foreign
  has "默认目录列表带空格的 HOME 不会被拆开: 找到 ~/.local/bin 下的 sing-box" "$FOREIGN_TEXT" "$HOME/.local/bin/sing-box"
  nomut "2f"
)

echo "== 3. 端口归属 (pick_ports): enana 自己在用的保持不变 (升级不换端口); 被别的程序占着的换一个; 看不见的诚实说明"
(
  c=$(mkcase); enter "$c"
  printf '100 %s\n200 /opt/homebrew/bin/sing-box\n' "$H/sing-box" > "$FAKE_PS"
  printf '39700 200 127.0.0.1\n' > "$FAKE_LSOF"; export FAKE_SVC_PID=100 FAKE_BUSY=39700
  pick_ports > "$c/out" 2>&1
  eq "enana 服务在运行, 但代理端口被外部进程占着: 换成别的端口" "$([ "$PORT" = 39700 ] && echo same || echo moved)" "moved"
  has "提示同原来一样: 已被其它程序占用, 已自动改用" "$(cat "$c/out")" "本地端口 39700 已被其它程序占用, 已自动改用"
  has "新端口写进设置" "$(cat "$H/settings.env")" "PORT=$PORT"
  eq "UI / API / 测速端口没有被误换" "$UI_PORT/$API_PORT/$SPEED_PORT" "39701/39702/39703"
  eq "检查确实跑过 (允许打印「端口可用」)" "$PORTS_VERIFIED:$UNSEEN_PORTS" "1:"
  has "服务状态是从 launchctl 替身读取的" "$(cat "$FAKE_CALLS")" "launchctl print gui/"
  nomut "3a"
)
(
  c=$(mkcase); enter "$c"
  printf '100 %s\n' "$H/sing-box" > "$FAKE_PS"
  printf '39700 100 127.0.0.1\n39701 100 127.0.0.1\n39703 100 127.0.0.1\n' > "$FAKE_LSOF"; export FAKE_SVC_PID=100 FAKE_BUSY='39700 39701 39703'
  pick_ports > "$c/out" 2>&1
  eq "升级: enana 自己的核心占着的端口原样保留" "$PORT/$UI_PORT/$SPEED_PORT" "39700/39701/39703"
  eq "没有换端口的提示" "$(cat "$c/out")" ""
  eq "检查确实跑过" "$PORTS_VERIFIED" "1"
  nomut "3b"
)
(
  c=$(mkcase); enter "$c"
  printf '1 /sbin/launchd\n' > "$FAKE_PS"; printf '39702 1 127.0.0.1\n' > "$FAKE_LSOF"
  export FAKE_TUN_PID=300 FAKE_API=1 FAKE_BUSY='39700 39701 39702 39703'
  pick_ports > "$c/out" 2>&1
  eq "增强模式 (root 核心普通账户看不见): 端口保持不变" "$PORT/$UI_PORT/$API_PORT/$SPEED_PORT" "39700/39701/39702/39703"
  eq "没能逐项确认 → 不算验证过" "$PORTS_VERIFIED" "0"
  eq "只列出没能确认的端口 (API 由 launchd 代管, 已确认)" "$UNSEEN_PORTS" "39700 / 39701 / 39703"
  nomut "3c"
)
(
  c=$(mkcase); enter "$c"
  export FAKE_BUSY=39700
  pick_ports > "$c/out" 2>&1
  eq "没有任何 enana 服务, 端口被看不见的程序占着: 换端口 (旧行为保留)" "$([ "$PORT" = 39700 ] && echo same || echo moved)" "moved"
  eq "检查跑过" "$PORTS_VERIFIED" "1"
  nomut "3d"
)
(
  c=$(mkcase); enter "$c"
  printf '100 %s\n200 /opt/homebrew/bin/sing-box\n' "$H/sing-box" > "$FAKE_PS"
  printf '39702 200 127.0.0.1\n' > "$FAKE_LSOF"; export FAKE_SVC_PID=100 FAKE_BUSY=39702
  pick_ports > "$c/out" 2>&1
  eq "API 端口被别的程序占着: 只换这一个" "$PORT/$UI_PORT/$SPEED_PORT/$([ "$API_PORT" = 39702 ] && echo same || echo moved)" "39700/39701/39703/moved"
  nomut "3e"
)
(
  c=$(mkcase); enter "$c"
  printf '100 %s\n1 /sbin/launchd\n' "$H/sing-box" > "$FAKE_PS"
  printf '39700 100 127.0.0.1\n39701 100 127.0.0.1\n39702 1 127.0.0.1\n' > "$FAKE_LSOF"; export FAKE_SVC_PID=100 FAKE_API=1 FAKE_BUSY='39700 39701 39702 39703'
  pick_ports > "$c/out" 2>&1
  eq "升级 (辅助服务由 launchd 代管, 核心在用其余端口): 全部保持, 不换端口" "$PORT/$UI_PORT/$API_PORT/$SPEED_PORT" "39700/39701/39702/39703"
  eq "升级: 没有任何提示" "$(cat "$c/out")" ""
  eq "升级: 测速端口没有看见监听者 → 只列出它, 不算验证过" "$PORTS_VERIFIED:$UNSEEN_PORTS" "0:39703"
  nomut "3f"
)
(
  c=$(mkcase); enter "$c"
  printf '1 /sbin/launchd\n100 %s\n' "$H/sing-box" > "$FAKE_PS"
  printf '39700 100 127.0.0.1\n39701 100 127.0.0.1\n39702 1 127.0.0.1\n39703 100 127.0.0.1\n' > "$FAKE_LSOF"; export FAKE_SVC_PID=100 FAKE_API=1 FAKE_BUSY='39700 39701 39702 39703'
  pick_ports > "$c/out" 2>&1
  eq "全部端口都是本程序自己的: 检查通过, 没有「没能确认」的端口" "$PORTS_VERIFIED:$UNSEEN_PORTS" "1:"
  nomut "3g"
)
(
  c=$(mkcase); enter "$c"
  printf '1 /sbin/launchd\n100 %s\n' "$H/sing-box" > "$FAKE_PS"; export FAKE_SVC_PID=100 FAKE_BUSY='39700 39701 39702 39703'
  port_state() { echo ''; }                                     # 没有明确的结论: 不能当作空闲或本程序的
  pick_ports > "$c/out" 2>&1
  eq "没有明确结论的端口: 保持原样, 不换端口" "$PORT/$UI_PORT/$API_PORT/$SPEED_PORT" "39700/39701/39702/39703"
  eq "没有明确结论: 不算验证过" "$PORTS_VERIFIED" "0"
  has "给出提示: 没能确认本地端口的占用情况" "$(cat "$c/out")" "没能确认本地端口 39700 的占用情况"
  eq "没有改写设置" "$(cat "$H/settings.env" 2>/dev/null)" ""
  nomut "3h"
)
(
  c=$(mkcase); enter "$c"
  printf '1 /sbin/launchd\n' > "$FAKE_PS"; printf '39700 999 127.0.0.1\n' > "$FAKE_LSOF"
  n=0; port_busy() { n=$((n + 1)); [ "$n" -eq 1 ]; }            # 第一次看见有人在听, 查 lsof 时它已经退出
  eq "监听者在 lsof 与 ps 之间退出: 重新检查后空闲, 不算外部程序" "$(port_state 39700 "$LABEL")" "free"
  nomut "3i"
)

echo "== 4. 安装前检查 (st_preflight): 运行中的外部进程 / 已加载的 launchd 任务 / tun 模式下的外部默认路由才询问; 其余只是信息; 回车 = 取消"
(
  c=$(mkcase); enter "$c"
  printf '200 /opt/homebrew/bin/sing-box\n' > "$FAKE_PS"; export ENANA_YES=1
  ( st_preflight ) > "$c/out" 2>&1; rc=$?
  out=$(cat "$c/out")
  eq "--yes: 退出码 0 (没有询问, 没有取消)" "$rc" "0"
  has "摘要: 运行中的外部进程" "$out" "运行中的进程 1 个"
  has "非交互: 照常继续, 并且写明没有改动外部程序" "$out" "非交互模式: 照常继续安装"
  hasnt "没有出现「已取消」" "$out" "已取消"
  has "清单写进了安装目录" "$(cat "$H/foreign-inventory.txt")" "/opt/homebrew/bin/sing-box"
  has "操作记录里留下了这次检测 (log)" "$(cat "$H"/logs/ops-*.log)" "检测到外部代理内核"
  has "端口检查照常完成" "$out" "可用"
  nomut "4a"
)
(
  c=$(mkcase); enter "$c"
  export ENANA_YES=1 FAKE_DEFAULT_IF=utun5 FAKE_TUN_INET=10.7.0.2
  ( st_preflight ) > "$c/out" 2>&1; rc=$?
  out=$(cat "$c/out")
  eq "--yes, 系统代理模式: 外部 TUN 默认路由只是信息, 退出码 0" "$rc" "0"
  has "写明外部 TUN 默认路由 (网卡名)" "$out" "默认路由经过别的 TUN 网卡 (utun5)"
  hasnt "没有询问, 也不需要「非交互」提示" "$out" "非交互模式"
  nomut "4b"
)
(
  c=$(mkcase); enter "$c"
  export FAKE_DEFAULT_IF=utun5 FAKE_TUN_INET=10.7.0.2
  _noninteractive() { return 1; }
  confirm() { echo "confirm $*" >> "$FAKE_CALLS"; return 1; }
  ( st_preflight ) < /dev/null > "$c/out" 2>&1; rc=$?
  out=$(cat "$c/out")
  eq "交互, 系统代理模式, 只有 VPN 默认路由: 信息, 不询问, 退出码 0 (默认是「继续」)" "$rc" "0"
  hasnt "没有调用询问" "$(cat "$FAKE_CALLS")" "confirm"
  has "信息里写明 VPN 默认路由" "$out" "默认路由经过别的 TUN 网卡 (utun5)"
  nomut "4b2"
)
(
  c=$(mkcase); enter "$c"
  export FAKE_DEFAULT_IF=utun5 FAKE_TUN_INET=10.7.0.2; NETWORK_MODE=tun
  _noninteractive() { return 1; }
  ( st_preflight ) < /dev/null > "$c/out" 2>&1; rc=$?
  eq "交互, 增强模式, 外部 TUN 默认路由: 询问, 回车 (默认 n) 取消, 退出码 1" "$rc" "1"
  has "取消的提示" "$(cat "$c/out")" "已取消"
  nomut "4b3"
)
(
  c=$(mkcase); enter "$c"
  export ENANA_YES=1 FAKE_DEFAULT_IF=utun5 FAKE_TUN_INET=10.7.0.2; NETWORK_MODE=tun
  ( st_preflight ) > "$c/out" 2>&1; rc=$?
  out=$(cat "$c/out")
  eq "--yes, 增强模式, 外部 TUN 默认路由: 照常继续, 退出码 0" "$rc" "0"
  has "非交互: 照常继续, 写明没有改动外部程序" "$out" "非交互模式: 照常继续安装"
  nomut "4b4"
)
(
  c=$(mkcase); enter "$c"
  printf '200 /opt/homebrew/bin/sing-box\n' > "$FAKE_PS"
  _noninteractive() { return 1; }
  ( st_preflight ) < /dev/null > "$c/out" 2>&1; rc=$?
  eq "交互 (默认 n): 没有回答 y 就取消安装" "$rc" "1"
  has "取消的提示" "$(cat "$c/out")" "已取消"
  nomut "4c"
)
(
  c=$(mkcase); enter "$c"
  printf '#!/bin/sh\nexit 0\n' > "$c/fbin/sing-box"; chmod +x "$c/fbin/sing-box"
  : > "$c/LaunchAgents/homebrew.mxcl.sing-box.plist"
  _noninteractive() { return 1; }
  confirm() { echo "confirm $*" >> "$FAKE_CALLS"; return 1; }
  ( st_preflight ) < /dev/null > "$c/out" 2>&1; rc=$?
  out=$(cat "$c/out")
  eq "只有没有运行、没有加载的外部程序和 plist (休眠): 不询问, 退出码 0" "$rc" "0"
  hasnt "没有调用询问" "$(cat "$FAKE_CALLS")" "confirm"
  has "信息: 未运行, 仅供参考" "$out" "发现外部 sing-box 文件 (未运行, 仅供参考)"
  has "清单里记了这个程序" "$(cat "$H/foreign-inventory.txt")" "$c/fbin/sing-box"
  nomut "4c2"
)
(
  c=$(mkcase); enter "$c"
  printf 'PID\tStatus\tLabel\n-\t0\thomebrew.mxcl.sing-box\n' > "$FAKE_LIST"
  _noninteractive() { return 1; }
  ( st_preflight ) < /dev/null > "$c/out" 2>&1; rc=$?
  eq "已加载的外部 launchd 任务 (没有运行的进程): 询问, 回车取消, 退出码 1" "$rc" "1"
  has "发现外部 sing-box 的摘要 (launchd 任务)" "$(cat "$c/out")" "launchd 任务 1 个"
  nomut "4c3"
)
(
  c=$(mkcase); enter "$c"
  printf '200 /usr/local/bin/otherapp\n' > "$FAKE_PS"; printf '39700 200 127.0.0.1\n' > "$FAKE_LSOF"
  export ENANA_YES=1 FAKE_BUSY=39700 FAKE_FOREIGN_PROXY=1; SEL_sysproxy=1
  os_sysproxy_backup() { echo "backup" >> "$FAKE_CALLS"; return 0; }
  os_sysproxy_set() { echo "sysproxy-set $*" >> "$FAKE_CALLS"; return 0; }
  st_preflight > "$c/out" 2>&1; rc=$?
  eq "系统代理被别人占着 + 端口也被占着换了 + --yes: 不覆盖, 把「设置系统代理」这一步去掉" "$SEL_sysproxy:$STEPS" "0:3"
  eq "退出码 0" "$rc" "0"
  has "原设置照样备份" "$(cat "$FAKE_CALLS")" "backup"
  hasnt "没有调用修改系统代理" "$(cat "$FAKE_CALLS")" "sysproxy-set"
  has "写明没有覆盖, 并说明 enana on 会替换、已备份" "$(cat "$c/out")" "运行 enana on 会替换现有设置, 原设置已备份到"
  nomut "4d"
)
(
  c=$(mkcase); enter "$c"
  SEL_sysproxy=1; export FAKE_FOREIGN_PROXY=1
  os_sysproxy_backup() { echo "backup" >> "$FAKE_CALLS"; return 0; }
  _noninteractive() { return 1; }
  ( st_preflight ) < /dev/null > "$c/out" 2>&1; rc=$?
  eq "系统代理被别人占着 + 交互: 默认「否」, 取消安装" "$rc" "1"
  has "取消的提示" "$(cat "$c/out")" "已取消"
  nomut "4e"
)
(
  c=$(mkcase); enter "$c"
  st_preflight > "$c/out" 2>&1; rc=$?
  out=$(cat "$c/out")
  eq "什么外部程序都没有: 退出码 0" "$rc" "0"
  hasnt "没有外部程序时不打扰用户" "$out" "发现外部"
  has "端口检查照常完成 (可用)" "$out" "可用"
  has "清单文件也写上 (表示什么都没找到)" "$(cat "$H/foreign-inventory.txt")" "nothing foreign found"
  nomut "4f"
)
(
  # 端口被别的程序占着换了端口, 系统代理还指着旧端口 (127.0.0.1): 也算别人的设置。enana 没有记录哪个系统代理是自己设置的, 这时它多半属于
  # 正占着这个端口的程序 (例如 Clash 也默认用 7890), 所以和其它代理设置一样: 先备份, 非交互跳过, 不覆盖 (以前当成本程序留下的, 不问就改成新端口)
  c=$(mkcase); enter "$c"
  printf '200 /usr/local/bin/otherapp\n' > "$FAKE_PS"; printf '39700 200 127.0.0.1\n' > "$FAKE_LSOF"
  export ENANA_YES=1 FAKE_BUSY=39700 FAKE_PROXY_PORT=39700 FAKE_PROXY_SERVER=127.0.0.1; SEL_sysproxy=1
  os_sysproxy_backup() { echo "backup" >> "$FAKE_CALLS"; return 0; }
  os_sysproxy_set() { echo "sysproxy-set $*" >> "$FAKE_CALLS"; return 0; }
  st_preflight > "$c/out" 2>&1; rc=$?
  out=$(cat "$c/out")
  eq "新装 (--yes): 旧端口上 127.0.0.1 的系统代理算别人的: 退出码 0" "$rc" "0"
  eq "端口已换, 去掉「设置系统代理」这一步" "$([ "$PORT" = 39700 ] && echo same || echo moved):$SEL_sysproxy:$STEPS" "moved:0:3"
  has "原设置照样备份" "$(cat "$FAKE_CALLS")" "backup"
  has "提醒已有其它系统代理设置" "$out" "已有其它系统代理设置"
  has "写明没有覆盖, 本次跳过" "$out" "本次跳过系统代理设置"
  hasnt "不再说它是本程序之前设置的" "$out" "本程序之前设置的"
  hasnt "没有调用修改系统代理" "$(cat "$FAKE_CALLS")" "sysproxy-set"
  nomut "4g"
)
(
  # 同样的情况, 交互安装: 和其它代理设置一样询问, 默认「否」, 回车取消
  c=$(mkcase); enter "$c"
  printf '200 /usr/local/bin/otherapp\n' > "$FAKE_PS"; printf '39700 200 127.0.0.1\n' > "$FAKE_LSOF"
  export FAKE_BUSY=39700 FAKE_PROXY_PORT=39700 FAKE_PROXY_SERVER=127.0.0.1; SEL_sysproxy=1
  os_sysproxy_backup() { echo "backup" >> "$FAKE_CALLS"; return 0; }
  _noninteractive() { return 1; }
  ( st_preflight ) < /dev/null > "$c/out" 2>&1; rc=$?
  eq "交互安装: 旧端口上的系统代理也要询问, 默认「否」, 取消安装" "$rc" "1"
  has "询问之前先备份" "$(cat "$FAKE_CALLS")" "backup"
  has "提醒已有其它系统代理设置 (交互)" "$(cat "$c/out")" "已有其它系统代理设置"
  has "取消的提示" "$(cat "$c/out")" "已取消"
  nomut "4g2"
)
(
  # 升级 (--upgrade 不动系统代理, SEL_sysproxy=0): 端口换过、旧端口上有系统代理 → 照旧不动 (和 2.3.23 一样), 不打开「设置系统代理」这一步
  c=$(mkcase); enter "$c"
  printf '200 /usr/local/bin/otherapp\n' > "$FAKE_PS"; printf '39700 200 127.0.0.1\n' > "$FAKE_LSOF"
  export ENANA_YES=1 FAKE_BUSY=39700 FAKE_PROXY_PORT=39700 FAKE_PROXY_SERVER=127.0.0.1; SEL_sysproxy=0
  os_sysproxy_backup() { echo "backup" >> "$FAKE_CALLS"; return 0; }
  os_sysproxy_set() { echo "sysproxy-set $*" >> "$FAKE_CALLS"; return 0; }
  st_preflight > "$c/out" 2>&1; rc=$?
  eq "升级 --upgrade (--yes): 旧端口上的系统代理不动: 退出码 0, 步骤不变" "$rc:$SEL_sysproxy:$STEPS" "0:0:4"
  hasnt "升级: 没有「将改为新端口」的提示" "$(cat "$c/out")" "将改为新端口"
  hasnt "升级: 没有调用修改系统代理" "$(cat "$FAKE_CALLS")" "sysproxy-set"
  nomut "4h"
)
(
  # 增强模式: 不碰系统代理 (由 TUN 管理), 所以端口变了也不改
  c=$(mkcase); enter "$c"
  printf '200 /usr/local/bin/otherapp\n' > "$FAKE_PS"; printf '39700 200 127.0.0.1\n' > "$FAKE_LSOF"
  export ENANA_YES=1 FAKE_BUSY=39700 FAKE_PROXY_PORT=39700 FAKE_PROXY_SERVER=127.0.0.1; SEL_sysproxy=0; NETWORK_MODE=tun
  st_preflight > "$c/out" 2>&1; rc=$?
  eq "增强模式: 不因为旧端口的系统代理而打开系统代理设置: 退出码 0, 不改 SEL_sysproxy" "$rc:$SEL_sysproxy" "0:0"
  hasnt "增强模式: 没有「系统代理还指向旧端口」的提示" "$(cat "$c/out")" "系统代理还指向旧端口"
  nomut "4i"
)
(
  # 旧端口上是别人的系统代理 (10.1.1.1:8080), 端口又换了: 仍然是别人的设置, 非交互跳过
  c=$(mkcase); enter "$c"
  printf '200 /usr/local/bin/otherapp\n' > "$FAKE_PS"; printf '39700 200 127.0.0.1\n' > "$FAKE_LSOF"
  export ENANA_YES=1 FAKE_BUSY=39700 FAKE_FOREIGN_PROXY=1; SEL_sysproxy=1
  os_sysproxy_backup() { echo "backup" >> "$FAKE_CALLS"; return 0; }
  st_preflight > "$c/out" 2>&1; rc=$?
  eq "端口换过 + 系统代理是别人的 (10.1.1.1): 非交互跳过, 不覆盖: 退出码 0, SEL_sysproxy 0" "$rc:$SEL_sysproxy" "0:0"
  has "跳过的提示" "$(cat "$c/out")" "本次跳过系统代理设置"
  nomut "4j"
)

echo "== 5. 启动之后的验证 (st_verify): 端口仍被别的程序占着 → 明确提示代理没有生效; 归本程序所有 → 不提示"
(
  c=$(mkcase); enter "$c"
  printf '100 %s\n200 /opt/homebrew/bin/sing-box\n' "$H/sing-box" > "$FAKE_PS"
  printf '39700 200 127.0.0.1\n' > "$FAKE_LSOF"; export FAKE_SVC_PID=100 FAKE_BUSY=39700
  st_verify > "$c/out" 2>&1
  has "提示: 代理端口被别的程序占用, 代理没有生效" "$(cat "$c/out")" "代理端口 39700 被别的程序占用"
  has "操作记录里留下了绑定失败" "$(cat "$H"/logs/ops-*.log)" "代理端口绑定失败"
  nomut "5a"
)
(
  c=$(mkcase); enter "$c"
  printf '100 %s\n' "$H/sing-box" > "$FAKE_PS"
  printf '39700 100 127.0.0.1\n' > "$FAKE_LSOF"; export FAKE_SVC_PID=100 FAKE_BUSY=39700
  st_verify > "$c/out" 2>&1
  hasnt "端口是本程序自己的核心在用: 不报绑定失败" "$(cat "$c/out")" "被别的程序占用"
  nomut "5b"
)

echo "== 6. 测试本身有效: 加载的是真实函数, 替身确实能记录 kill (上面的「没有 kill」才有意义); 加载 install.sh 的退出码不屏蔽"
(
  c=$(mkcase); enter "$c"
  kill 4242
  has "kill 的替身有记录" "$(cat "$FAKE_CALLS")" "kill 4242"
  eq "真实的 pick_ports / st_preflight 已加载" "$(type -t pick_ports):$(type -t st_preflight):$(type -t port_state)" "function:function:function"
)

echo
PASS=$(wc -l < "$W/.pass" | tr -d ' '); FAIL=$(wc -l < "$W/.fail" | tr -d ' ')
echo "外部代理内核 / 端口归属测试: ${PASS:-0} 通过, ${FAIL:-0} 失败"
[ "${FAIL:-0}" = 0 ]
