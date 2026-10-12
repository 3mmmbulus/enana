#!/bin/bash
# TUN 的 root 安装 / 回滚 / 停止 / 删除 (新协议: 每个文件只读一次、按摘要核对、一条命令; 见 lib/enhanced-root.sh 与 lib/enhanced.sh)。
#   全部在临时目录里: 假的 launchctl / install / chown / route / ifconfig / sleep / sudo (见 tests/root-fixture.sh); 绝不碰真实的 /Library、/usr/local 或 launchd。
set -u
HERE=$(cd "$(dirname "$0")" && pwd -P)
W=$(mktemp -d /tmp/enana-tun-service.XXXXXX); W=$(cd "$W" && pwd -P); trap 'rm -rf "$W"' EXIT
. "$HERE/root-fixture.sh"
rf_setup "$W"
ME=$(id -u); HELPER=$W/usr/local/libexec/enana/tunrules-$ME; SUDOERS=$W/sudoers.d/enana-tunrules-$ME; PLIST=$W/daemons/com.enana.proxy.tun.$ME.plist
fails=0
check() { local n=$1; shift; if "$@" >/dev/null 2>&1; then echo "  ✓ $n"; else echo "  ✗ $n"; fails=$((fails + 1)); fi; }
root_sig() { find "$ROOT" -print0 2>/dev/null | xargs -0 shasum -a 256 2>/dev/null | LC_ALL=C sort; }
set_level() { printf '%s\n' '{"log":{"level":"'"$1"'","output":"'"$H"'/sing-box.log"},"inbounds":[{"type":"tun","tag":"tun-in"}],"route":{"rule_set":[{"type":"local","tag":"geo","path":"'"$H"'/rules/geo/geo.srs"}],"final":"direct"}}' > "$H/config.json"; }
cfg_matches() { cmp -s "$ROOT/config.json" <(enhanced_stage_config "$H/config.json" "$H" "$ROOT"); }
line_no() { grep -n "^$1" "$W/calls" | head -1 | cut -d: -f1; }
in_order() { [ -n "$1" ] && [ -n "$2" ] && [ "$1" -lt "$2" ]; }

echo "== 1. 正常安装: 字节一致, 一次管理员授权, launchctl 顺序 bootout → bootstrap → kickstart"
rf_reset
rf_enana_start; rc=$?
check "安装成功 (退出码 0)" test "$rc" = 0
check "配置与暂存时的字节一致" cfg_matches
check "sing-box 与当前核心一致" cmp -s "$ROOT/sing-box" "$H/sing-box"
check "规则集逐字节一致" cmp -s "$ROOT/rules/geo/geo.srs" "$H/rules/geo/geo.srs"
check "root 脚本副本 = lib 原文" cmp -s "$ROOT/bin/enhanced-root.sh" "$LIBT/enhanced-root.sh"
check "规则助手 = 渲染结果" test "$(shasum -a 256 < "$HELPER" | awk '{print $1}')" = "$(enhanced_helper_expected)"
check "免密规则只有这一条, 权限 440" test "$(cat "$SUDOERS")" = "$(id -un) ALL=(root) NOPASSWD: $HELPER"
check "只调用了一次管理员命令" test "$(rf_admin_calls)" = 1
check "launchctl 顺序正确" in_order "$(line_no 'bootout system')" "$(line_no 'bootstrap system')"
check "kickstart 在 bootstrap 之后" in_order "$(line_no 'bootstrap system')" "$(line_no 'kickstart system')"
check "暂存目录用完即删" test -z "$(ls -d "$W"/stg.* 2>/dev/null)"

echo "== 2. bootstrap 失败: 回滚到安装之前的 sing-box / 配置 / 助手 / 免密规则"
rf_reset; rf_enana_start
set_level debug
cfg_before=$(shasum -a 256 < "$ROOT/config.json"); helper_before=$(shasum -a 256 < "$HELPER"); sudo_before=$(cat "$SUDOERS")
: > "$W/fail-bootstrap"
rf_enana_start; rc=$?
check "失败返回 1 (已回滚)" test "$rc" = 1
check "配置恢复为安装之前的字节" test "$(shasum -a 256 < "$ROOT/config.json")" = "$cfg_before"
check "助手恢复为安装之前的字节" test "$(shasum -a 256 < "$HELPER")" = "$helper_before"
check "免密规则恢复" test "$(cat "$SUDOERS")" = "$sudo_before"
check "旧守护进程重新加载" test -f "$W/loaded"
check "没有残留的回滚 / 准备目录" test -z "$(find "$ROOT" -name '.prepare.*' -o -name '.rollback.*')"

echo "== 3. 路由没有归到我们的 utun: 回滚"
rf_reset; rf_enana_start
printf '#!/bin/sh\necho "inet 10.0.0.1 netmask 0xffffff00"\n' > "$W/bin/ifconfig"
rf_enana_start; rc=$?
printf '#!/bin/sh\necho "inet 172.19.0.1 netmask 0xfffffffc"\n' > "$W/bin/ifconfig"
check "路由不对: 失败 (退出码 1)" test "$rc" = 1

echo "== 4. 暂存目录里有符号链接: root 拒绝 (退出码 3), 正在运行的系统一个字节都不动"
rf_reset; rf_enana_start; before=$(root_sig)
export RF_HOOK='ln -s /etc/hosts "$(cat "$RF_W/stage.path")/link"'
rf_enana_start; rc=$?
unset RF_HOOK
check "拒绝 (退出码 3)" test "$rc" = 3
check "根目录没有变化" test "$(root_sig)" = "$before"

echo "== 5. 停止 / 删除: 运行的是 root 副本 (不是 lib 里被改过的文件); 删除把副本、助手、免密规则、plist 全部删掉"
rf_reset; rf_enana_start
printf '# edited after install\n' >> "$LIBT/enhanced-root.sh"
enhanced_stop; rc=$?
check "停止成功" test "$rc" = 0
check "停止运行的是 root 副本" grep -q "bin/enhanced-root.sh' 'root' 'stop'" "$W/sudo.log"
enhanced_remove; rc=$?
check "删除成功" test "$rc" = 0
check "根目录没了" test ! -e "$ROOT"
check "助手没了" test ! -e "$HELPER"
check "免密规则没了" test ! -e "$SUDOERS"
check "plist 没了" test ! -e "$PLIST"

echo "== 6. 旧版本没有 root 副本: 停止 / 删除走一次性的 inband 形式, 仍然只要一次授权"
rf_reset; rf_enana_start; rm -rf "$ROOT/bin"
enhanced_stop; check "inband 停止成功" test $? = 0
check "inband 形式: 脚本随命令带进去" grep -q "enana-root '" "$W/sudo.log"

echo "== 7. 停止成功之后再停止: 不再要管理员授权 (enhanced_idle)"
rf_reset; rf_enana_start; : > "$W/sudo.log"
enhanced_stop; enhanced_stop
check "第二次停止没有新的管理员调用" test "$(rf_admin_calls)" = 1

echo "== 8. 备份现有的助手失败 (第 d 步还没动它们): 回滚 TUN 文件, 现有的助手和免密规则原样保留"
rf_reset; rf_enana_start
set_level debug
cfg_before=$(shasum -a 256 < "$ROOT/config.json"); helper_before=$(shasum -a 256 < "$HELPER"); sudo_before=$(cat "$SUDOERS")
chmod 000 "$HELPER"                                   # 假 root 就是当前用户: 读不了它, cp -p 备份就失败 (set -e 退出, 走回滚)
rf_enana_start; rc=$?
chmod 755 "$HELPER" 2>/dev/null
check "失败返回 1 (已回滚)" test "$rc" = 1
check "配置恢复为安装之前的字节" test "$(shasum -a 256 < "$ROOT/config.json")" = "$cfg_before"
check "现有的助手还在, 字节不变" test "$(shasum -a 256 < "$HELPER" 2>/dev/null)" = "$helper_before"
check "现有的免密规则还在" test "$(cat "$SUDOERS" 2>/dev/null)" = "$sudo_before"
check "没有残留的回滚 / 准备目录" test -z "$(find "$ROOT" -name '.prepare.*' -o -name '.rollback.*')"

echo "== 9. 回滚时有一步失败 (plist 目录不可写): 其余的照样恢复, 临时目录照样清掉"
rf_reset; rf_enana_start
cfg_before=$(shasum -a 256 < "$ROOT/config.json"); helper_before=$(shasum -a 256 < "$HELPER"); sudo_before=$(cat "$SUDOERS")
printf '# 新版本的助手模板: 渲染出来的字节和装着的不同\n' >> "$LIBT/tunrules-helper.pl"
set_level debug
printf '#!/bin/sh\necho "inet 10.0.0.1 netmask 0xffffff00"\n' > "$W/bin/ifconfig"      # 路由一直不是我们的: 安装失败, 走回滚
printf '#!/bin/sh\nchmod 555 "%s"\n' "$W/daemons" > "$W/bin/sleep"                  # 等路由的时候把 plist 目录改成只读: 回滚里删除 / 换回 plist 都会失败
rf_enana_start; rc=$?
chmod 755 "$W/daemons"; printf '#!/bin/sh\nexit 0\n' > "$W/bin/sleep"; printf '#!/bin/sh\necho "inet 172.19.0.1 netmask 0xfffffffc"\n' > "$W/bin/ifconfig"
cp "$RF_REPO/lib/tunrules-helper.pl" "$LIBT/"
check "失败返回 1" test "$rc" = 1
check "配置恢复为安装之前的字节" test "$(shasum -a 256 < "$ROOT/config.json")" = "$cfg_before"
check "plist 那一步失败之后: 助手仍然恢复为安装之前的字节" test "$(shasum -a 256 < "$HELPER" 2>/dev/null)" = "$helper_before"
check "…免密规则恢复" test "$(cat "$SUDOERS" 2>/dev/null)" = "$sudo_before"
check "…临时目录照样清掉 (没有残留的回滚 / 准备目录)" test -z "$(find "$ROOT" -name '.prepare.*' -o -name '.rollback.*')"

echo
if [ "$fails" = 0 ]; then echo 'PASS: root snapshot install, bootstrap / route rollback, staged symlink refusal, stop and remove from the root copy, rollback without a helper backup and past a failed step'
else echo "FAIL: $fails check(s) failed"; exit 1; fi
