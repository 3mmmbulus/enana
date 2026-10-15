#!/bin/bash
# 「我的设备」的客户端部分 (lib/session.sh): 心跳正文带上 enana 版本和系统版本 (云端据此更新设备记录, 升级后不再显示登录时的旧版本)。
#   · 正文是合法 JSON {"app","os"}; 引号 / 反斜杠 / 控制字符不会弄坏它; 系统版本最多 64 个字符
#   · 系统版本一天只读一次 (Windows 上每读一次要启动 PowerShell), 过期 / 时间倒退时重读; 读不到就发空值且不缓存 (下次再读)
#   · session_heartbeat 把它发到 POST /api/enana/v1/session/heartbeat
# 不联网、不需要管理员权限, macOS 和 Linux 都能跑。云端的规则见 tests/devices-pocketbase.test.js, 界面见 tests/devices-ui.test.js。
set -u
HERE=$(cd "$(dirname "$0")" && pwd -P); REPO=$(dirname "$HERE")
W=$(mktemp -d /tmp/enana-devices.XXXXXX); W=$(cd "$W" && pwd -P)
trap 'rm -rf "$W"' EXIT; : > "$W/.pass"; : > "$W/.fail"
tpass() { echo p >> "$W/.pass"; echo "  ✓ $1"; }
tfail() { echo f >> "$W/.fail"; echo "  ✗ $1"; [ -n "${2:-}" ] && printf '      ↳ %s\n' "$(printf '%s' "$2" | head -c 700)"; return 0; }
eq()    { if [ "$2" = "$3" ]; then tpass "$1"; else tfail "$1" "期望 [$3] 实际 [$2]"; fi; }
command -v python3 >/dev/null || { echo "跳过: 需要 python3"; exit 77; }

export HOME=$W/home ENANA_HOME=$W/h LC_ALL=C ENANA_LANG=zh ENANA_PLATFORM=darwin
mkdir -p "$HOME" "$ENANA_HOME"
. "$REPO/lib/common.sh"; init_paths "$REPO/install.sh"
LIB=$REPO/lib
for _f in i18n logs auth device session; do . "$LIB/$_f.sh"; done
[ "$H" = "$W/h" ] || { echo "REFUSING: 数据目录不是临时目录 ($H)"; exit 1; }
[ -n "$VERSION" ] || { echo "REFUSING: 没有读到 VERSION"; exit 1; }

# 替身: 系统版本 (每读一次记一笔) / 云端请求 (记下方法、路径和正文)
OSV='15.6.1'; OSRC=0
os_version() { echo x >> "$W/os.calls"; [ "$OSRC" = 0 ] || return "$OSRC"; printf '%s\n' "$OSV"; }
calls() { [ -f "$W/os.calls" ] && wc -l < "$W/os.calls" | tr -d ' ' || echo 0; }
field() { printf '%s' "$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert sorted(d)==["app","os"], d; print(d[sys.argv[1]], end="")' "$2" 2>&1; }

echo "== D1. 心跳正文: 当前版本 + 系统版本, 合法 JSON"
B=$(session_hb_body)
eq "app = 这份代码的 VERSION ($VERSION)" "$(field "$B" app)" "$VERSION"
eq "os = 系统版本" "$(field "$B" os)" "15.6.1"
eq "读了一次系统版本" "$(calls)" "1"

echo "== D2. 系统版本一天读一次"
session_hb_body >/dev/null; session_hb_body >/dev/null
eq "一天之内再发心跳: 不再读系统版本 (用缓存)" "$(calls)" "1"
OSV='15.7'
eq "…缓存里还是上次读到的值" "$(field "$(session_hb_body)" os)" "15.6.1"
printf '%s 15.6.1\n' "$(( $(date +%s) - 86401 ))" > "$H/hb.os"
eq "缓存超过一天: 重读, 发新的系统版本 (升级系统之后)" "$(field "$(session_hb_body)" os):$(calls)" "15.7:2"
printf '%s 15.7\n' "$(( $(date +%s) + 86400 ))" > "$H/hb.os"
eq "缓存的时间在未来 (时钟被调回去了): 重读" "$(field "$(session_hb_body)" os):$(calls)" "15.7:3"
printf 'garbage\n' > "$H/hb.os"
eq "缓存文件坏了: 重读" "$(field "$(session_hb_body)" os):$(calls)" "15.7:4"

echo "== D3. 读不到系统版本"
rm -f "$H/hb.os"; OSRC=1
eq "读不到: 发空值 (云端忽略空值, 不会把记录清空)" "$(field "$(session_hb_body)" os)" ""
eq "…也不缓存空值: 下一次心跳再读" "$([ -e "$H/hb.os" ] && echo cached || echo none):$(field "$(session_hb_body)" os):$(calls)" "none::6"
OSRC=0; OSV=''
eq "读到空字符串: 同样不缓存" "$(field "$(session_hb_body)" os):$([ -e "$H/hb.os" ] && echo cached || echo none)" ":none"

echo "== D4. 特殊字符不会弄坏 JSON, 长度有上限"
rm -f "$H/hb.os"; OSV=$(printf 'Win "11" \\ Pro\001\033x\177y')
eq "引号 / 反斜杠照常转义, 控制字符去掉" "$(field "$(session_hb_body)" os)" 'Win "11" \ Proxy'
rm -f "$H/hb.os"; OSV=$(printf '%080d' 7)
eq "最多 64 个字符 (云端也只收 64 个)" "$(field "$(session_hb_body)" os | wc -c | tr -d ' ')" "64"
rm -f "$H/hb.os"; OSV=$(printf '15.6.1\nsecond line')
eq "只取第一行" "$(field "$(session_hb_body)" os)" "15.6.1"

echo "== D5. session_heartbeat 把它发出去"
rm -f "$H/hb.os"; OSV='15.6.1'
mkdir -p "$H"; : > "$H/loggedin"; printf 'sid-1\n' > "$H/session"; printf 'tok-1\n' > "$H/cloud.token"
session_call() { printf '%s %s %s' "$2" "$3" "${4:-}" > "$W/req"; printf '{"ok":true,"token":"tok-2"}' > "$1"; printf '200'; }
session_heartbeat; rc=$?
eq "心跳成功" "$rc" "0"
REQ=$(cat "$W/req" 2>/dev/null)
eq "POST /api/enana/v1/session/heartbeat" "${REQ%% \{*}" "POST /api/enana/v1/session/heartbeat"
eq "…正文带上 app 和 os (以前是 {})" "$(field "{${REQ#* \{}" app):$(field "{${REQ#* \{}" os)" "$VERSION:15.6.1"
eq "…并照常换上云端返回的新令牌" "$(cat "$H/cloud.token")" "tok-2"

P=$(wc -l < "$W/.pass" | tr -d ' '); F=$(wc -l < "$W/.fail" | tr -d ' ')
echo "通过 $P · 失败 $F"
[ "$F" = 0 ]
