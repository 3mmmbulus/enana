#!/bin/bash
# 系统代理 (os_sysproxy_apply / op_sysproxy / 操作记录): 几秒钟, 不需要 sing-box / 网络 / 管理员权限, macOS 和 Linux 都能跑。
#   · 已经指向 enana → 不动 · 直接修改 · 免密 sudo · 原生管理员密码框 (仪表盘没有终端) · 取消授权 / 不是管理员 · 回读确认
#   · 服务名带空格 / 引号时两层引用 (shell + AppleScript) 不出错 · 失败原因写进操作记录和任务消息
# 全部使用 tests/fakebin 里的假命令; 解析到真命令就拒绝运行。
set -u
HERE=$(cd "$(dirname "$0")" && pwd -P); REPO=$(dirname "$HERE")
W=$(mktemp -d /tmp/enana-sysproxy.XXXXXX); W=$(cd "$W" && pwd -P); trap 'rm -rf "$W"' EXIT; : > "$W/.pass"; : > "$W/.fail"
tpass() { echo p >> "$W/.pass"; echo "  ✓ $1"; }
tfail() { echo f >> "$W/.fail"; echo "  ✗ $1"; [ -n "${2:-}" ] && printf '      ↳ %s\n' "$(printf '%s' "$2" | head -c 600)"; return 0; }
eq()    { if [ "$2" = "$3" ]; then tpass "$1"; else tfail "$1" "期望 [$3] 实际 [$2]"; fi; }
has()   { if grep -q -- "$2" "$3" 2>/dev/null; then tpass "$1"; else tfail "$1" "$(cat "$3" 2>/dev/null)"; fi; }
hasnt() { if ! grep -q -- "$2" "$3" 2>/dev/null; then tpass "$1"; else tfail "$1" "$(cat "$3" 2>/dev/null)"; fi; }

export FAKE_STATE=$W/state HOME=$W/home ENANA_HOME=$W/h LC_ALL=C ENANA_LANG=zh PORT=37890 UI_PORT=37891 API_PORT=37892 SPEED_PORT=37893 FAKE_PORT=37890
mkdir -p "$FAKE_STATE" "$HOME" "$ENANA_HOME"
export PATH="$HERE/fakebin:$PATH"
for c in networksetup sudo osascript; do
  case "$(command -v $c)" in "$HERE"/fakebin/*) ;; *) echo "REFUSING: 真实的 $c 出现在 PATH 中, 为防止改动系统已中止"; exit 1 ;; esac
done
. "$REPO/lib/common.sh"; init_paths "$REPO/install.sh"
LIB=$REPO/lib; DATA=$REPO/data
for _f in i18n os-darwin enhanced logs jobs ops; do . "$LIB/$_f.sh"; done
load_settings; QUIET=1
[ "$H" = "$W/h" ] || { echo "REFUSING: 数据目录不是临时目录 ($H)"; exit 1; }
CALLS=$FAKE_STATE/calls.log
reset() { rm -f "$FAKE_STATE/sysproxy-on"; : > "$CALLS"; unset FAKE_NS_NEEDS_ADMIN FAKE_DIALOG FAKE_SUDO_NOPASS FAKE_SERVICES FAKE_ADMIN; rm -rf "$H/logs"; }
sets() { grep -c 'networksetup -set' "$CALLS"; }
oplines() { cat "$H"/logs/ops-*.log 2>/dev/null; }

echo "== S1. 已经指向 enana: 不改任何设置"
reset; touch "$FAKE_STATE/sysproxy-on"
os_sysproxy_apply on; rc=$?
eq "返回 0, 方式 already" "$rc:$SYSPROXY_METHOD" "0:already"
eq "没有调用任何修改命令 / sudo / 密码框" "$(sets)$(grep -c '^sudo\|^osascript' "$CALLS")" "00"
reset
os_sysproxy_apply off; rc=$?
eq "已经关闭: 关闭也是 already" "$rc:$SYSPROXY_METHOD" "0:already"

echo "== S2. 管理员账户直接修改 (不需要任何密码)"
reset
os_sysproxy_apply on; rc=$?
eq "开启成功: 方式 direct" "$rc:$SYSPROXY_METHOD:$SYSPROXY_ERR" "0:direct:"
has "Web / Secure Web / SOCKS 三项都指向 127.0.0.1:$PORT" "networksetup -setsocksfirewallproxy Wi-Fi 127.0.0.1 $PORT" "$CALLS"
has "同时设置了本机 / 局域网绕过列表" "networksetup -setproxybypassdomains Wi-Fi localhost 127.0.0.1 \*.local" "$CALLS"
has "每个已启用的网络服务都改了 (Ethernet)" "networksetup -setwebproxy Ethernet 127.0.0.1 $PORT" "$CALLS"
hasnt "没有用 sudo, 也没有弹密码框" '^sudo\|^osascript do shell\|^osascript -e' "$CALLS"
os_sysproxy_apply off; rc=$?
eq "关闭成功" "$rc:$SYSPROXY_METHOD" "0:direct"
has "关闭用 set*state off" "networksetup -setwebproxystate Wi-Fi off" "$CALLS"
eq "回读确认: 关闭后没有任何服务指向 enana" "$(os_sysproxy_mine && echo mine || echo clean)" "clean"

echo "== S3. 需要管理员权限: 免密 sudo / 原生密码框 (仪表盘里没有终端) / 取消 / 不是管理员"
reset; export FAKE_NS_NEEDS_ADMIN=1 FAKE_SUDO_NOPASS=1
os_sysproxy_apply on </dev/null >/dev/null 2>&1; rc=$?
eq "直接修改被拒绝 → 已有免密 sudo 就用它 (sudo-nopass)" "$rc:$SYSPROXY_METHOD" "0:sudo-nopass"
has "是 sudo -n 执行的 (不在终端里等密码)" '^sudo -n /bin/bash -c' "$CALLS"

reset; export FAKE_NS_NEEDS_ADMIN=1 FAKE_SUDO_NOPASS=0
os_sysproxy_apply on </dev/null >/dev/null 2>&1; rc=$?
eq "没有终端也没有免密 sudo → 弹出 macOS 原生管理员密码框, 用户输入密码后成功 (dialog)" "$rc:$SYSPROXY_METHOD:$SYSPROXY_ERR" "0:dialog:"
has "用的是 do shell script … with administrator privileges" 'osascript -e do shell script .* with administrator privileges' "$CALLS"
has "整套修改只弹一次框 (一条 /bin/bash -c 里改完所有网络服务)" "setsecurewebproxy.*Ethernet" "$CALLS"
eq "只弹了一次密码框" "$(grep -c '^osascript -e do shell script' "$CALLS")" "1"
os_sysproxy_apply off </dev/null >/dev/null 2>&1; rc=$?
eq "同样可以关闭 (再弹一次框)" "$rc:$SYSPROXY_METHOD" "0:dialog"

reset; export FAKE_NS_NEEDS_ADMIN=1 FAKE_SUDO_NOPASS=0 FAKE_DIALOG=cancel
os_sysproxy_apply on </dev/null >/dev/null 2>&1; rc=$?
eq "用户在密码框里点了取消 → 失败, 原因 user-canceled" "$rc:$SYSPROXY_ERR" "1:user-canceled"
eq "取消后系统代理没有被改动" "$(os_sysproxy_ok && echo on || echo off)" "off"

reset; export FAKE_NS_NEEDS_ADMIN=1 FAKE_SUDO_NOPASS=0 FAKE_DIALOG=denied
os_sysproxy_apply on </dev/null >/dev/null 2>&1; rc=$?
eq "macOS 不允许弹授权窗口 (-1743) → not-authorized" "$rc:$SYSPROXY_ERR" "1:not-authorized"

echo "== S4. 服务名带空格 / 引号: shell 和 AppleScript 两层引用都正确"
reset; export FAKE_NS_NEEDS_ADMIN=1 FAKE_SUDO_NOPASS=0 FAKE_SERVICES="USB 10/100 LAN
Bob's Ethernet
Wi-Fi \"Home\""
os_sysproxy_apply on </dev/null >/dev/null 2>&1; rc=$?
eq "三种怪名字的服务都能开启" "$rc:$SYSPROXY_METHOD" "0:dialog"
has "带空格的服务名" "networksetup -setwebproxy USB 10/100 LAN 127.0.0.1 $PORT" "$CALLS"
has "带单引号的服务名" "networksetup -setwebproxy Bob's Ethernet 127.0.0.1 $PORT" "$CALLS"
has "带双引号的服务名" 'networksetup -setwebproxy Wi-Fi "Home" 127.0.0.1' "$CALLS"

echo "== S5. 操作记录: 方式与失败原因都留下痕迹 (以前系统代理没开成功时什么都不记)"
reset; export FAKE_NS_NEEDS_ADMIN=1 FAKE_SUDO_NOPASS=0 FAKE_DIALOG=cancel
os_sysproxy_apply on </dev/null >/dev/null 2>&1; rc=$?; sysproxy_record dashboard on "$rc"
has "失败: 动作「开启系统代理」, 详情带 err=user-canceled, 结果 error" "开启系统代理.*err=user-canceled.*error$" <(oplines)
unset FAKE_DIALOG; reset; export FAKE_NS_NEEDS_ADMIN=1 FAKE_SUDO_NOPASS=0
os_sysproxy_apply on </dev/null >/dev/null 2>&1; rc=$?; sysproxy_record dashboard on "$rc"
has "成功: 详情带 method=dialog, 结果 ok" "开启系统代理.*method=dialog.*ok$" <(oplines)

echo "== S6. 后台任务 op_sysproxy: 成功 / 取消 / TUN 模式不改系统代理"
JOBLOG=$W/job.log
job_step() { :; }
job_ok()   { printf 'OK %s %s\n' "$1" "${2:-}" >> "$JOBLOG"; }
job_fail() { printf 'FAIL %s\n' "$1" >> "$JOBLOG"; }
reset; : > "$JOBLOG"; export FAKE_NS_NEEDS_ADMIN=1 FAKE_SUDO_NOPASS=0
op_sysproxy on </dev/null >/dev/null 2>&1
has "成功: job_ok, 带授权方式" '^OK .*"method":"dialog"' "$JOBLOG"
reset; : > "$JOBLOG"; export FAKE_NS_NEEDS_ADMIN=1 FAKE_SUDO_NOPASS=0 FAKE_DIALOG=cancel
op_sysproxy on </dev/null >/dev/null 2>&1
has "取消: job_fail 用人话说明 (已取消授权, 没有改动)" '^FAIL 已取消授权' "$JOBLOG"
eq "取消后仍没有改动系统代理 (最终状态没变)" "$(os_sysproxy_ok && echo on || echo off)" "off"
reset; : > "$JOBLOG"; NETWORK_MODE=tun op_sysproxy on </dev/null >/dev/null 2>&1
has "Enhanced/TUN: 不使用系统代理, 直接成功且不改任何设置" '^OK Enhanced/TUN' "$JOBLOG"
eq "TUN 模式没有调用 networksetup 修改命令" "$(sets)" "0"
reset; : > "$JOBLOG"; op_sysproxy sideways </dev/null >/dev/null 2>&1
has "参数无效被拒" '^FAIL 参数无效' "$JOBLOG"

P=$(grep -c . "$W/.pass"); F=$(grep -c . "$W/.fail")
echo; echo "系统代理测试: $P 通过, $F 失败"
[ "$F" = 0 ]
