#!/bin/bash
# TUN 的 root 安装 / 回滚 / 停止 / 删除 (新协议: 每个文件只读一次、按摘要核对、一条命令; 见 lib/enhanced-root.sh 与 lib/enhanced.sh)。
#   全部在临时目录里: 假的 launchctl / install / chown / route / ifconfig / sleep / sudo (见 tests/root-fixture.sh); 绝不碰真实的 /Library、/usr/local 或 launchd。
set -u
HERE=$(cd "$(dirname "$0")" && pwd -P)
W=$(mktemp -d /tmp/enana-tun-service.XXXXXX); W=$(cd "$W" && pwd -P); trap 'rm -rf "$W"' EXIT
. "$HERE/root-fixture.sh"
rf_setup "$W"
ME=$(id -u); HDIR=$W/Library/PrivilegedHelperTools/com.enana.proxy; HELPER=$HDIR/tunrules-$ME; SUDOERS=$W/sudoers.d/enana-tunrules-$ME; PLIST=$W/daemons/com.enana.proxy.tun.$ME.plist
LDIR=$W/usr/local/libexec/enana; LEGACY=$LDIR/tunrules-$ME                  # 2.3.23 及更早版本的位置 (沙箱里)
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
check "规则助手 = 渲染结果 (装在 /Library/PrivilegedHelperTools/com.enana.proxy)" test "$(shasum -a 256 < "$HELPER" | awk '{print $1}')" = "$(enhanced_helper_expected)"
check "免密规则只有这一条, 权限 440" test "$(cat "$SUDOERS")" = "$(id -un) ALL=(root) NOPASSWD: $HELPER"
check "enana 一侧认这个助手 (可信, sudo -n 调用的是新位置的写死路径)" test "$(enhanced_helper_root)" = "/Library/PrivilegedHelperTools/com.enana.proxy/tunrules-$ME"
check "旧位置什么都没建" test ! -e "$LDIR"
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
check "空了的 com.enana.proxy 目录也删了, PrivilegedHelperTools 本身留着" test "$(test -e "$HDIR" && echo y || echo n):$(test -d "$W/Library/PrivilegedHelperTools" && echo y || echo n)" = "n:y"

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

echo "== 10. 安装时目录链不合格 (com.enana.proxy 组可写): 助手和免密规则删掉; 之后安装失败回滚, 也不把它们装回不安全的目录"
rf_reset; rf_enana_start
cfg_before=$(shasum -a 256 < "$ROOT/config.json")
set_level debug
chmod g+w "$HDIR"
: > "$W/fail-bootstrap"
rf_enana_start; rc=$?
chmod g-w "$HDIR"
check "失败返回 1 (已回滚)" test "$rc" = 1
check "配置恢复为安装之前的字节" test "$(shasum -a 256 < "$ROOT/config.json")" = "$cfg_before"
check "助手没有被装回不安全的目录" test ! -e "$HELPER"
check "…免密规则也没有恢复" test ! -e "$SUDOERS"
check "没有残留的回滚 / 准备目录" test -z "$(find "$ROOT" -name '.prepare.*' -o -name '.rollback.*')"

# 2.3.23 及更早版本的安装: 规则助手在 /usr/local/libexec/enana, 免密规则指向那里 (老的 Homebrew 会把 /usr/local 改成用户可写)
legacy_setup() { mkdir -p "$LDIR"; printf '# 2.3.23 helper\n' > "$LEGACY"; chmod 755 "$LEGACY"; printf '%s ALL=(root) NOPASSWD: %s\n' "$(id -un)" "$LEGACY" > "$SUDOERS"; chmod 440 "$SUDOERS"; }
echo "== 11. 升级迁移: 旧位置的助手 + 指向旧位置的免密规则 → 安装之后助手在新位置、规则指向新路径, 旧文件删掉, 空了的旧目录也删掉"
rf_reset; legacy_setup
rf_enana_start; rc=$?
check "安装成功" test "$rc" = 0
check "助手装在新位置 (字节 = 渲染结果)" test "$(shasum -a 256 < "$HELPER" 2>/dev/null | awk '{print $1}')" = "$(enhanced_helper_expected)"
check "免密规则改写成新路径 (旧路径作废)" test "$(cat "$SUDOERS")" = "$(id -un) ALL=(root) NOPASSWD: $HELPER"
check "旧位置的助手删掉了" test ! -e "$LEGACY"
check "…空了的旧目录也删掉了 (/usr/local/libexec 不动)" test "$(test -e "$LDIR" && echo y || echo n):$(test -d "$W/usr/local/libexec" && echo y || echo n)" = "n:y"
rf_reset; legacy_setup; printf 'sysproxy helper\n' > "$LDIR/sysproxy-$ME"
rf_enana_start; rc=$?
check "旧目录里还有系统代理助手: 只删规则助手, 目录和系统代理助手都留着 (它由自己的安装来迁移)" test "$rc:$(test -e "$LEGACY" && echo y || echo n):$(cat "$LDIR/sysproxy-$ME" 2>/dev/null)" = "0:n:sysproxy helper"
rf_reset; rm -rf "$W/usr"; mkdir -p "$W/usr/local" "$W/elsewhere/enana"; printf 'keep\n' > "$W/elsewhere/enana/tunrules-$ME"; ln -s "$W/elsewhere" "$W/usr/local/libexec"
rf_enana_start; rc=$?
check "旧位置在符号链接后面 (/usr/local/libexec 是链接): 安装照常, 助手在新位置; 链接另一端的同名文件不删" test "$rc:$(test -f "$HELPER" && echo y || echo n):$(cat "$W/elsewhere/enana/tunrules-$ME" 2>/dev/null)" = "0:y:keep"
rm -f "$W/usr/local/libexec"; rm -rf "$W/elsewhere"

echo "== 12. 迁移的那次安装失败 (回滚): 指向旧位置的免密规则不放回去 (旧位置的助手已经删了, 规则不能指向一个别人可能建得出来的文件)"
rf_reset; legacy_setup
: > "$W/fail-bootstrap"
rf_enana_start; rc=$?
check "失败返回 1 (已回滚)" test "$rc" = 1
check "指向旧位置的免密规则没有放回去" test ! -e "$SUDOERS"
check "…新位置的助手也不在 (回到「没有助手」)" test ! -e "$HELPER"
check "…旧位置的助手也不在" test ! -e "$LEGACY"
check "没有残留的回滚 / 准备目录" test -z "$(find "$ROOT" -name '.prepare.*' -o -name '.rollback.*')"

echo "== 11. 系统代理的旧免密规则 (2.3.23 装的, 指向旧位置): 旧位置不安全时 TUN 的安装顺便撤销它; 旧位置安全 / 新位置已经有系统代理助手时不动"
SPR=$W/sudoers.d/enana-sysproxy-$ME
sp_rule() { printf '%s ALL=(root) NOPASSWD: %s\n' "$(id -un)" "/usr/local/libexec/enana/sysproxy-$ME" > "$SPR"; }
rf_reset; mkdir -p "$W/usr/local/libexec/enana"; sp_rule
rf_enana_start; rc=$?
check "旧位置安全: 安装成功, 系统代理的规则照旧" test "$rc:$(test -e "$SPR" && echo y || echo n)" = "0:y"
rf_reset; mkdir -p "$W/usr/local/libexec/enana"; sp_rule; chmod g+w "$W/usr/local"
rf_enana_start; rc=$?; chmod g-w "$W/usr/local"
check "旧位置不安全 (/usr/local 组可写, 别人能在那里放文件再 sudo -n): 安装成功, 系统代理的规则被撤销" test "$rc:$(test -e "$SPR" && echo y || echo n)" = "0:n"
rf_reset; mkdir -p "$W/usr/local/libexec/enana" "$W/Library/PrivilegedHelperTools/com.enana.proxy"; : > "$W/Library/PrivilegedHelperTools/com.enana.proxy/sysproxy-$ME"; sp_rule; chmod g+w "$W/usr/local"
rf_enana_start; rc=$?; chmod g-w "$W/usr/local"
check "新位置已经有系统代理助手 (规则已经改写成新路径): 不动它" test "$rc:$(test -e "$SPR" && echo y || echo n)" = "0:y"

echo "== 13. 网站的域名列表 (rules/site-<id>/site-<id>.json): 完整安装时随快照逐字节交给 root; 之后 enana 生成的数据包通过 root 助手的检查, 原地覆盖快照里的那一份"
rf_reset
mkdir -p "$H/rules/site-claude"; printf '%s\n' '{"version":3,"rules":[{"domain_suffix":["claude.ai","anthropic.com"]}]}' > "$H/rules/site-claude/site-claude.json"
printf '%s\n' '{"log":{"level":"info","output":"'"$H"'/sing-box.log"},"inbounds":[{"type":"tun","tag":"tun-in"}],"route":{"rule_set":[{"type":"local","tag":"geo","path":"'"$H"'/rules/geo/geo.srs"},{"type":"local","tag":"site-claude","format":"source","path":"'"$H"'/rules/site-claude/site-claude.json"}],"rules":[{"rule_set":["site-claude"],"action":"route","outbound":"direct"}],"final":"direct"}}' > "$H/config.json"
rf_enana_start; rc=$?
check "安装成功 (退出码 0)" test "$rc" = 0
check "root 快照里的 site-claude.json 和 enana 这边逐字节一致" cmp -s "$ROOT/rules/site-claude/site-claude.json" "$H/rules/site-claude/site-claude.json"
check "安装后记下的策略指纹算上了这个文件 (之后改域名, 策略指纹一变就走助手同步)" test "$(cat "$H/.enhanced-ovr-fingerprint")" = "$(enhanced_ovr_fingerprint)"
check "…核心指纹不算它 (改域名不触发完整安装)" test "$(cat "$H/.enhanced-fingerprint")" = "$(enhanced_fingerprint)"
# 装好的助手只给 root 用 (目录归 root, uid 写死成 0): 这里用同一个模板渲染一份 uid = 当前用户的副本, 验证 enana 的数据包和 root 的检查对得上
sed -e "s|@ROOT@|$ROOT|g" -e "s|@ROOTUID@|$ME|g" -e "s|@VERSION@|$TUNRULES_HELPER_VERSION|g" -e "s|@LABEL@|com.enana.proxy.tun.$ME|g" -e "s|@LAUNCHCTL@|$W/bin/launchctl|g" "$RF_REPO/lib/tunrules-helper.pl" > "$W/helper-me.pl"
printf '%s\n' '{"version":3,"rules":[{"domain_suffix":["claude.ai","new-claude.example"]}]}' > "$H/rules/site-claude/site-claude.json"
ino=$(stat -f %i "$ROOT/rules/site-claude/site-claude.json")
check "改了域名: 核心指纹不变 (不重装), 策略指纹变 (助手同步)" test "$([ "$(cat "$H/.enhanced-fingerprint")" = "$(enhanced_fingerprint)" ] && echo core-same):$([ "$(cat "$H/.enhanced-ovr-fingerprint")" != "$(enhanced_ovr_fingerprint)" ] && echo ovr-changed)" = "core-same:ovr-changed"
enhanced_ovr_bundle | perl "$W/helper-me.pl" sync > "$W/sync.out" 2>&1; rc=$?
check "enana 的数据包 (只有被引用的 site-claude.json): root 助手校验通过, 写了 1 个文件" test "$rc:$(cat "$W/sync.out")" = "0:1 files synced"
check "…快照里的那一份原地覆盖 (inode 不变): 新域名在, anthropic.com 没了" test "$(stat -f %i "$ROOT/rules/site-claude/site-claude.json"):$(grep -c new-claude.example "$ROOT/rules/site-claude/site-claude.json"):$(grep -c anthropic.com "$ROOT/rules/site-claude/site-claude.json")" = "$ino:1:0"
rm -rf "$H/rules/site-claude"

echo
if [ "$fails" = 0 ]; then echo 'PASS: root snapshot install, bootstrap / route rollback, staged symlink refusal, stop and remove from the root copy, rollback without a helper backup, past a failed step and without restoring a helper into an unsafe directory, migration from /usr/local/libexec'
else echo "FAIL: $fails check(s) failed"; exit 1; fi
