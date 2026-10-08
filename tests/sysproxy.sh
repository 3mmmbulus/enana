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
hs()    { if printf '%s\n' "$3" | grep -Eq -- "$2"; then tpass "$1"; else tfail "$1" "没有找到 /$2/ 于: $3"; fi; }
hsnt()  { if ! printf '%s\n' "$3" | grep -Eq -- "$2"; then tpass "$1"; else tfail "$1" "不应出现 /$2/: $3"; fi; }
t_ok()  { if "${@:2}" >/dev/null 2>&1; then tpass "$1"; else tfail "$1" "命令失败: ${*:2}"; fi; }
hasnt() { if ! grep -q -- "$2" "$3" 2>/dev/null; then tpass "$1"; else tfail "$1" "$(cat "$3" 2>/dev/null)"; fi; }

export FAKE_STATE=$W/state HOME=$W/home ENANA_HOME=$W/h LC_ALL=C ENANA_LANG=zh PORT=37890 UI_PORT=37891 API_PORT=37892 SPEED_PORT=37893 FAKE_PORT=37890
mkdir -p "$FAKE_STATE" "$HOME" "$ENANA_HOME"
export PATH="$HERE/fakebin:$PATH"
# 系统代理助手会写 /usr/local/libexec 和 /etc/sudoers.d: 测试里全部重定向到沙箱 (假 install 也会拒绝沙箱之外的任何目标)
export ENANA_ROOT_PREFIX="$W/root" ENANA_NETWORKSETUP="$HERE/fakebin/networksetup" FAKE_SUDOERS_DIR="$W/root/etc/sudoers.d"
mkdir -p "$W/root"
for c in networksetup sudo osascript; do
  case "$(command -v $c)" in "$HERE"/fakebin/*) ;; *) echo "REFUSING: 真实的 $c 出现在 PATH 中, 为防止改动系统已中止"; exit 1 ;; esac
done
. "$REPO/lib/common.sh"; init_paths "$REPO/install.sh"
LIB=$REPO/lib; DATA=$REPO/data
for _f in i18n os-darwin enhanced logs jobs ops; do . "$LIB/$_f.sh"; done
load_settings; QUIET=1
[ "$H" = "$W/h" ] || { echo "REFUSING: 数据目录不是临时目录 ($H)"; exit 1; }
CALLS=$FAKE_STATE/calls.log
reset() { rm -rf "$W/root"; mkdir -p "$W/root"; rm -f "$FAKE_STATE/sysproxy-on"; : > "$CALLS"; unset FAKE_NS_NEEDS_ADMIN FAKE_DIALOG FAKE_SUDO_NOPASS FAKE_SERVICES FAKE_ADMIN; rm -rf "$H/logs"; }
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
eq "同样可以关闭: 第一次授权时助手已装好, 关闭不再弹框 (方式 helper)" "$rc:$SYSPROXY_METHOD" "0:helper"
eq "密码框总共还是只弹了一次" "$(grep -c '^osascript -e do shell script' "$CALLS")" "1"

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


echo "== S6. 系统代理助手: 授权一次, 之后打开 / 关闭系统代理都不再弹密码框"
if [ "$(uname)" != Darwin ] || ! command -v visudo >/dev/null 2>&1; then
  echo "  (跳过: 需要 macOS 的 stat / visudo)"
else
HELPER=$(os_sysproxy_helper_path); SUDOERS=$(os_sysproxy_sudoers_path); ME=$(id -un)
TXT=$(os_sysproxy_helper_text)
hsnt "助手脚本里没有残留的 @占位符@" "@[A-Z]+@" "$TXT"
hs "端口写死在脚本里" "^NS=.*; PORT=$PORT; VERSION=$SYSPROXY_HELPER_VERSION$" "$TXT"
printf '%s\n' "$TXT" > "$W/helper.sh"; chmod 755 "$W/helper.sh"
ok_syntax() { bash -n "$W/helper.sh"; }; t_syntax=$(ok_syntax 2>&1 && echo ok)
eq "助手脚本语法正确" "$t_syntax" "ok"
reset; export FAKE_NS_NEEDS_ADMIN=1
eq "助手: version 输出版本号" "$(FAKE_ADMIN=1 "$W/helper.sh" version)" "$SYSPROXY_HELPER_VERSION"
FAKE_ADMIN=1 "$W/helper.sh" bogus >/dev/null 2>&1; eq "助手: 不认识的参数 → 退出码 2" "$?" "2"
FAKE_ADMIN=1 "$W/helper.sh" on extra >/dev/null 2>&1; eq "助手: 多余参数 → 退出码 2 (不接受任何别的输入)" "$?" "2"
FAKE_ADMIN=1 "$W/helper.sh" >/dev/null 2>&1; eq "助手: 没有参数 → 退出码 2" "$?" "2"
FAKE_ADMIN=1 "$W/helper.sh" on >/dev/null 2>&1; eq "助手: on 在管理员环境里成功" "$?" "0"
has "助手: 每个网络服务的 Web / SOCKS 都指向 127.0.0.1:$PORT" "networksetup -setsocksfirewallproxy Ethernet 127.0.0.1 $PORT" "$CALLS"
"$W/helper.sh" on >/dev/null 2>&1; eq "助手: 没有管理员权限时 networksetup 失败 → 助手退出码非 0 (不假装成功)" "$([ $? != 0 ] && echo failed || echo ok)" "failed"
: > "$CALLS"; FAKE_PORT=9999 FAKE_ADMIN=1 "$W/helper.sh" off >/dev/null 2>&1
eq "助手: off 不动别的软件设置的代理 (端口不是 $PORT 就不关)" "$(grep -c 'state' "$CALLS")" "0"
: > "$CALLS"; FAKE_ADMIN=1 "$W/helper.sh" off >/dev/null 2>&1
has "助手: off 关掉正指向 enana 的服务" "networksetup -setwebproxystate Wi-Fi off" "$CALLS"

echo "-- S6a. 第一次: 弹一次密码框, 同一次授权里装好助手 + 免密规则"
reset; export FAKE_NS_NEEDS_ADMIN=1 FAKE_SUDO_NOPASS=0
os_sysproxy_apply on </dev/null >/dev/null 2>&1; rc=$?
eq "第一次打开: 弹密码框成功 (dialog), 助手同时装好 (installed)" "$rc:$SYSPROXY_METHOD:$SYSPROXY_HELPER" "0:dialog:installed"
eq "只弹了一次密码框" "$(grep -c '^osascript -e do shell script' "$CALLS")" "1"
t_ok "助手文件已安装" test -x "$HELPER"
hs "sudoers 片段: 只给当前用户开放这一个文件的免密" "^$ME ALL=\(root\) NOPASSWD: $HELPER\$" "$(cat "$SUDOERS")"
eq "sudoers 片段只有这一条规则 (没有通配符 / 别的命令)" "$(grep -c . "$SUDOERS")" "1"
eq "sudoers 片段权限 440" "$(stat -f %Lp "$SUDOERS")" "440"
eq "sudoers 片段通过 visudo -cf 校验" "$(/usr/sbin/visudo -cf "$SUDOERS" >/dev/null 2>&1 && echo valid || echo invalid)" "valid"
eq "助手文件权限 755 (组 / 其他人不可写)" "$(stat -f %Lp "$HELPER")" "755"
sysproxy_record terminal on 0
hs "操作记录里记着 helper=installed" "开启系统代理	method=dialog helper=installed" "$(oplines)"

echo "-- S6b. 之后: 打开 / 关闭都走助手, 不再弹框"
os_sysproxy_apply off </dev/null >/dev/null 2>&1; rc=$?
eq "第二次 (关闭): 方式 helper, 助手 used" "$rc:$SYSPROXY_METHOD:$SYSPROXY_HELPER" "0:helper:used"
os_sysproxy_apply on </dev/null >/dev/null 2>&1; rc=$?
eq "第三次 (再打开): 仍是 helper" "$rc:$SYSPROXY_METHOD:$SYSPROXY_HELPER" "0:helper:used"
os_sysproxy_apply off </dev/null >/dev/null 2>&1; os_sysproxy_apply on </dev/null >/dev/null 2>&1
eq "反复开关 4 次之后, 密码框总共还是只弹了 1 次" "$(grep -c '^osascript -e do shell script' "$CALLS")" "1"
has "是 sudo -n 调用助手的 (不在终端里等密码)" "^sudo -n $HELPER o" "$CALLS"
eq "回读确认: 最终系统代理确实指向 enana" "$(os_sysproxy_ok && echo on || echo off)" "on"

echo "-- S6c. 不信任的情况: 版本不对 / 别人可写 / 符号链接 → 重新授权, 不盲目使用"
sed -i '' "s/^NS=\(.*\); PORT=\([0-9]*\); VERSION=.*/NS=\1; PORT=\2; VERSION=0/" "$HELPER"
eq "版本号不对: 视为没装好" "$(os_sysproxy_helper_ok && echo trusted || echo untrusted)" "untrusted"
os_sysproxy_apply off </dev/null >/dev/null 2>&1
eq "版本不对 → 弹一次框重装 (升级), 装好后版本恢复" "$(grep -c '^osascript -e do shell script' "$CALLS"):$(os_sysproxy_helper_ok && echo trusted || echo untrusted)" "2:trusted"
chmod 775 "$HELPER"
eq "组可写: 不信任" "$(os_sysproxy_helper_ok && echo trusted || echo untrusted)" "untrusted"
chmod 755 "$HELPER"; chmod 757 "$HELPER"
eq "其他人可写: 不信任" "$(os_sysproxy_helper_ok && echo trusted || echo untrusted)" "untrusted"
chmod 755 "$HELPER"
mv "$HELPER" "$HELPER.real"; ln -s "$HELPER.real" "$HELPER"
eq "助手是符号链接: 不信任" "$(os_sysproxy_helper_ok && echo trusted || echo untrusted)" "untrusted"
rm -f "$HELPER"; mv "$HELPER.real" "$HELPER"
rm -f "$SUDOERS"
eq "sudoers 规则不在了 (用户或系统删了): 不信任 (sudo -n 要密码)" "$(os_sysproxy_helper_ok && echo trusted || echo untrusted)" "untrusted"

echo "-- S6c2. 端口被重新分配: 助手里写死的还是旧端口 → 不信任 (否则会把系统代理指向旧端口、还报告成功), 下一次授权时重装"
reset; export FAKE_NS_NEEDS_ADMIN=1 FAKE_SUDO_NOPASS=0
os_sysproxy_apply on </dev/null >/dev/null 2>&1
OLD_PORT=$PORT
eq "(准备) 助手装好了, 写死的端口 = 当前端口" "$(os_sysproxy_helper_ok && echo trusted || echo untrusted):$(os_sysproxy_helper_port)" "trusted:$OLD_PORT"
PORT=$((OLD_PORT + 11)); export FAKE_PORT=$PORT; rm -f "$FAKE_STATE/sysproxy-on"
eq "端口变了: 版本对, 但写死的端口不一致 → 不信任" "$(os_sysproxy_helper_ok && echo trusted || echo untrusted)" "untrusted"
os_sysproxy_apply on </dev/null >/dev/null 2>&1; rc=$?
eq "…下一次打开系统代理: 弹一次框重装助手 (新端口写进去), 之后可信" "$rc:$SYSPROXY_METHOD:$SYSPROXY_HELPER:$(os_sysproxy_helper_ok && echo trusted || echo untrusted):$(os_sysproxy_helper_port)" "0:dialog:installed:trusted:$PORT"
os_sysproxy_apply off </dev/null >/dev/null 2>&1
eq "…重装之后又走助手 (不再弹框)" "$SYSPROXY_METHOD" "helper"
PORT=$OLD_PORT; export FAKE_PORT=$OLD_PORT

echo "-- S6d. 不装助手的情况: 用户名不合法 / 明确关闭 / 本来就有免密 sudo / 授权被取消"
reset; export FAKE_NS_NEEDS_ADMIN=1 FAKE_SUDO_NOPASS=0
id() { case ${1:-} in -un) printf 'bad user;name' ;; *) command id "$@" ;; esac; }
os_sysproxy_apply on </dev/null >/dev/null 2>&1; rc=$?
eq "用户名含空格 / 分号: 系统代理照样设置成功, 但不安装助手 (不写 sudoers)" "$rc:$SYSPROXY_METHOD:$SYSPROXY_HELPER:$([ -e "$SUDOERS" ] && echo sudoers || echo none)" "0:dialog::none"
unset -f id
reset; export FAKE_NS_NEEDS_ADMIN=1 FAKE_SUDO_NOPASS=0
ENANA_NO_SYSPROXY_HELPER=1 os_sysproxy_apply on </dev/null >/dev/null 2>&1; rc=$?
eq "ENANA_NO_SYSPROXY_HELPER=1: 照常弹框设置, 不装助手" "$rc:$SYSPROXY_METHOD:$SYSPROXY_HELPER:$([ -e "$HELPER" ] && echo helper || echo none)" "0:dialog::none"
reset; export FAKE_NS_NEEDS_ADMIN=1 FAKE_SUDO_NOPASS=1
os_sysproxy_apply on </dev/null >/dev/null 2>&1; rc=$?
eq "本来就有免密 sudo: 直接用, 不装助手 (不多改 sudoers)" "$rc:$SYSPROXY_METHOD:$SYSPROXY_HELPER:$([ -e "$HELPER" ] && echo helper || echo none)" "0:sudo-nopass::none"
reset; export FAKE_NS_NEEDS_ADMIN=1 FAKE_SUDO_NOPASS=0 FAKE_DIALOG=cancel
os_sysproxy_apply on </dev/null >/dev/null 2>&1; rc=$?
eq "用户取消授权: 失败 (user-canceled), 没有装助手, 也没有留下 sudoers" "$rc:$SYSPROXY_ERR:$([ -e "$HELPER" ] && echo helper || echo none):$([ -e "$SUDOERS" ] && echo sudoers || echo none)" "1:user-canceled:none:none"

echo "-- S6e. 助手装了半截 (visudo 校验失败) 不会留下规则, 也不会挡住系统代理设置"
reset; export FAKE_NS_NEEDS_ADMIN=1 FAKE_SUDO_NOPASS=0
mkdir -p "$W/badbin"; printf '#!/bin/sh\nexit 1\n' > "$W/badbin/visudo"; chmod +x "$W/badbin/visudo"
PATH="$W/badbin:$PATH" os_sysproxy_apply on </dev/null >/dev/null 2>&1; rc=$?
eq "visudo 校验失败: 系统代理仍然设置成功" "$rc:$SYSPROXY_METHOD" "0:dialog"
eq "…且没有写入 sudoers 规则" "$([ -e "$SUDOERS" ] && echo sudoers || echo none)" "none"
eq "…助手即使装上了也不可用 (没有规则 → 不信任), 下次照常授权" "$(os_sysproxy_helper_ok && echo trusted || echo untrusted)" "untrusted"

echo "-- S6f. 卸载: 助手和免密规则一并删除"
reset; export FAKE_NS_NEEDS_ADMIN=1 FAKE_SUDO_NOPASS=0
os_sysproxy_apply on </dev/null >/dev/null 2>&1
t_ok "(准备) 助手和规则都在" test -e "$HELPER" -a -e "$SUDOERS"
os_sysproxy_helper_remove
eq "卸载后助手和 sudoers 规则都被删除" "$([ -e "$HELPER" ] && echo helper || echo none):$([ -e "$SUDOERS" ] && echo sudoers || echo none)" "none:none"
t_ok "没有残留的空目录 (助手目录)" test ! -d "$(dirname "$HELPER")"
os_sysproxy_helper_remove; eq "没装过 / 已删除时再调用是空操作" "$?" "0"
fi

P=$(grep -c . "$W/.pass"); F=$(grep -c . "$W/.fail")
echo; echo "系统代理测试: $P 通过, $F 失败"
[ "$F" = 0 ]
