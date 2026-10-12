#!/bin/bash
# root 脚本的完整性 (lib/enhanced-root.sh 与 lib/enhanced.sh 的 4.x / 6.x / 10 节): 全部在临时目录里, 假的系统命令 (tests/root-fixture.sh), 绝不碰真实系统。
#   · 配置路径检查 (check-config, enana 预检和 root 共用)  · 暂存目录被改动 / 有符号链接 / 有多余文件: root 在改动任何东西之前拒绝
#   · 弹框之前的预检 (核心来源 / 核心被改 / 引用的文件缺失 / 符号链接): 一次管理员调用都没有
#   · 快照文件的筛选 · 助手可信与否只看字节 · 目录链 · 命令环境 (BASH_ENV / PERL5OPT 不会被 root 执行) · 命令形状
set -u
HERE=$(cd "$(dirname "$0")" && pwd -P)
W=$(mktemp -d /tmp/enana-integrity.XXXXXX); W=$(cd "$W" && pwd -P); trap 'rm -rf "$W"' EXIT
. "$HERE/root-fixture.sh"
rf_setup "$W"
ME=$(id -u); fails=0; HDIR=$W/Library/PrivilegedHelperTools/com.enana.proxy; HELPER=$HDIR/tunrules-$ME
check() { local n=$1; shift; if "$@" >/dev/null 2>&1; then echo "  ✓ $n"; else echo "  ✗ $n"; fails=$((fails + 1)); fi; }
root_sig() { find "$ROOT" -print0 2>/dev/null | xargs -0 shasum -a 256 2>/dev/null | LC_ALL=C sort; }
calls_of() { grep -c "^$1" "$W/calls" 2>/dev/null; }
# check-config: 期望通过 / 期望失败并且指出哪个位置 (ROOT 占位符换成夹具里的根目录)
cc() { printf '%s' "$1" | sed "s|ROOT|$ROOT|g" > "$W/c.json"; bash "$LIBT/enhanced-root.sh" check-config "$W/c.json" "$ROOT" > "$W/cc.out" 2> "$W/cc.err"; }
cc_pass() { cc "$1"; [ "$?" = 0 ]; }
cc_fail() { cc "$1"; [ "$?" = 4 ] && grep -q "config-path: $2" "$W/cc.err"; }
echo "== A. 配置路径检查 (check-config)"
check "合法配置: DNS https 的 path、ws 传输的 path 都放行 (M3); 证书 / 规则集的引用被列出" cc_pass '{"log":{"output":"ROOT/sing-box.log"},"dns":{"servers":[{"type":"https","server":"d.example","path":"/dns-query"}]},"outbounds":[{"type":"vless","transport":{"type":"ws","path":"/ws"},"tls":{"enabled":true,"certificate_path":"ROOT/certs/Tokyo.crt","key_path":"ROOT/certs/k.pem"}}],"route":{"rule_set":[{"type":"local","tag":"g","path":"ROOT/rules/geo/geo.srs"}]},"experimental":{"cache_file":{"path":"ROOT/cache.db"}}}'
check "列出的引用包含证书和规则集" grep -q '^certs/Tokyo.crt$' "$W/cc.out"
check "log.output 指向 ROOT 之外: 拒绝" cc_fail '{"log":{"output":"/etc/x"}}' /log/output
check "任何字符串里的 .. 路径段: 拒绝 (即使是不认识的键)" cc_fail '{"x":"/a/../b"}' /x
check "experimental.clash_api.external_ui: 拒绝 (enana 从不生成)" cc_fail '{"experimental":{"clash_api":{"external_ui":"ROOT/ui"}}}' /experimental/clash_api/external_ui
check "规则集路径多一层: 拒绝" cc_fail '{"route":{"rule_set":[{"type":"local","path":"ROOT/rules/geo/x/geo.srs"}]}}' /route/rule_set/0/path
check "证书不在 certs/ 下: 拒绝" cc_fail '{"outbounds":[{"tls":{"certificate_path":"ROOT/rules/x.crt"}}]}' /outbounds/0/tls/certificate_path
check "client_key_path 指向 ROOT 之外: 拒绝 (M3: 不再只看列出的几个键)" cc_fail '{"outbounds":[{"type":"trojan","tls":{"client_key_path":"/etc/shadow"}}]}' /outbounds/0/tls/client_key_path
check "ech.config_path 指向 ROOT 之外: 拒绝 (M3)" cc_fail '{"outbounds":[{"type":"vless","tls":{"ech":{"config_path":"/etc/hosts"}}}]}' /outbounds/0/tls/ech/config_path
check "client_key_path 在 ROOT 之下: 放行" cc_pass '{"outbounds":[{"type":"trojan","tls":{"client_key_path":"ROOT/certs/k.pem"}}]}'
check "shadowsocks 的 plugin (要运行的程序): 拒绝 (M7)" cc_fail '{"outbounds":[{"type":"shadowsocks","plugin":"/bin/sh"}]}' /outbounds/0/plugin
check "hosts 类型的 path 在 ROOT 之外: 拒绝 (M7)" cc_fail '{"dns":{"servers":[{"type":"hosts","path":"/etc/hosts"}]}}' /dns/servers/0/path
# sing-box 解码时键名不分大小写 (Go encoding/json 的折叠匹配), 检查也必须一样: 换个大小写 / 用折叠成 k、s 的字符都不能绕过
check "键名换成大写 (sing-box 照样认): log.Output 指向 ROOT 之外 → 拒绝" cc_fail '{"log":{"Output":"/etc/x"}}' /log/output
check "…clash_api 的 External_UI → 拒绝" cc_fail '{"experimental":{"clash_api":{"External_UI":"ROOT/ui"}}}' /experimental/clash_api/external_ui
check "…Experimental.Cache_File.Path 指向 ROOT 之外 → 拒绝" cc_fail '{"Experimental":{"Cache_File":{"Path":"/etc/x"}}}' /experimental/cache_file/path
check "…U+212A (开尔文符号, sing-box 当成 k) 拼的 key_path → 拒绝" cc_fail '{"outbounds":[{"type":"trojan","tls":{"Key_path":"/etc/shadow"}}]}' /outbounds/0/tls/key_path
check "…U+017F (长 s, 当成 s) 拼的 tls: 证书照样必须在 certs/ 里" cc_fail '{"outbounds":[{"tlſ":{"certificate_path":"ROOT/rules/x.crt"}}]}' /outbounds/0/tls/certificate_path
check "…Type / Path 大写的 local 规则集: 路径照样只能是 rules/目录/文件" cc_fail '{"route":{"rule_set":[{"Type":"local","Path":"ROOT/rules/geo/x/geo.srs"}]}}' /route/rule_set/0/path
check "…同一个对象里 output 和 Output (折叠后重复; 两个值都在 ROOT 之下也不行) → 拒绝" cc_fail '{"log":{"output":"ROOT/a.log","Output":"ROOT/b.log"}}' /log/output
check "请求头这类自由的键名 (Host) 不受影响: 放行" cc_pass '{"outbounds":[{"type":"vless","transport":{"type":"ws","path":"/ws","headers":{"Host":"a.example"}}}]}'
# 文件类的键写成字符串列表 (sing-box 同样接受): 每一项都要检查
check "hosts 的 path 写成列表, 指向 ROOT 之外 → 拒绝, 指出是哪一项" cc_fail '{"dns":{"servers":[{"type":"hosts","path":["/etc/hosts"]}]}}' /dns/servers/0/path/0
check "…client_certificate_path 列表里第二项在 ROOT 之外 → 拒绝" cc_fail '{"outbounds":[{"type":"trojan","tls":{"client_certificate_path":["ROOT/certs/a.crt","/etc/x"]}}]}' /outbounds/0/tls/client_certificate_path/1
check "…证书库的 certificate_directory_path 列表 → 拒绝" cc_fail '{"certificate":{"certificate_directory_path":["/etc"]}}' /certificate/certificate_directory_path/0
check "…列表的每一项都在 ROOT 之下: 放行" cc_pass '{"dns":{"servers":[{"type":"hosts","path":["ROOT/hosts","ROOT/hosts2"]}]}}'
# 以前按名字认文件类的键是区分大小写的: 后缀大写 (_PATH)、hosts 的 Path 都认不出来
check "后缀大写的 client_key_PATH 指向 ROOT 之外 → 拒绝" cc_fail '{"outbounds":[{"type":"trojan","tls":{"client_key_PATH":"/etc/x"}}]}' /outbounds/0/tls/client_key_path
check "…hosts 的 Path 指向 ROOT 之外 → 拒绝" cc_fail '{"dns":{"servers":[{"type":"hosts","Path":"/etc/hosts"}]}}' /dns/servers/0/path
check "名字就叫 directory 的键 (文件服务的目录) 指向 ROOT 之外 → 拒绝" cc_fail '{"outbounds":[{"type":"direct","x":{"directory":"/etc"}}]}' /outbounds/0/x/directory
# 入站只能是 tun 和 127.0.0.1 上的 mixed (enana 只生成这两种)
check "入站是 hysteria2 (masquerade 能把目录当文件服务器) → 拒绝" cc_fail '{"inbounds":[{"type":"hysteria2","listen":"127.0.0.1","masquerade":"file:///etc"}]}' /inbounds/0/type
check "…mixed 监听 0.0.0.0 → 拒绝" cc_fail '{"inbounds":[{"type":"mixed","listen":"0.0.0.0","listen_port":1080}]}' /inbounds/0/listen
check "…tun 加上 127.0.0.1 上的 mixed: 放行" cc_pass '{"inbounds":[{"type":"tun","tag":"tun-in"},{"type":"mixed","tag":"in","listen":"127.0.0.1","listen_port":1080}]}'

echo "== B. 快照文件的筛选 (3.4): 规则集 rules/目录/文件, 证书 certs/名字.crt"
mkdir -p "$H/rules/app/deep" "$H/certs"
printf x > "$H/rules/app/ovr-pin.json"; printf x > "$H/rules/app/.DS_Store"; printf x > "$H/rules/app/deep/x.srs"
printf x > "$H/rules/app/a.srs.new"; printf x > "$H/rules/flat.srs"; printf x > "$H/certs/.hidden.crt"; printf x > "$H/certs/Tokyo.crt"; printf x > "$H/certs/notes.txt"
LIST=$(enhanced_snapshot_files)
has() { printf '%s\n' "$LIST" | grep -qx "$1"; }
skipped() { printf '%s\n' "$LIST" | grep -Eq 'DS_Store|deep|\.new$|flat\.srs|notes'; }
check "ovr-*.json 在快照里" has rules/app/ovr-pin.json
check "以点开头的证书 (api 可以建) 在快照里" has certs/.hidden.crt
check "隐藏文件 / 深层文件 / *.new / 旧的扁平 .srs / 非 .crt 都不在" test "$(skipped; echo $?)" = 1
rm -rf "$H/rules/app" "$H/certs"

echo "== C. 弹框之前的预检: 不调用一次管理员命令"
rf_reset
rm -f "$H/core-provenance"; rf_enana_start; rc=$?
check "核心来源不明 (没有 core-provenance): 返回 6, 没有管理员调用" test "$rc:$(rf_admin_calls)" = "6:0"
check "…原因写进 enhanced-check.log" grep -q 'preflight-core-unpinned' "$H/enhanced-check.log"
printf 'pinned 1.12.0 %s\n' "$(shasum -a 256 "$H/sing-box" | awk '{print $1}')" > "$H/core-provenance"
printf '%064d\n' 0 > "$H/core-binary.sha256"; rf_enana_start; rc=$?
check "核心被改动过 (和校验记录不同): 返回 6, 没有管理员调用" test "$rc:$(rf_admin_calls)" = "6:0"
shasum -a 256 "$H/sing-box" | awk '{print $1}' > "$H/core-binary.sha256"
cp "$H/config.json" "$W/config.bak"
printf '%s\n' '{"log":{"output":"'"$H"'/sing-box.log"},"route":{"rule_set":[{"type":"local","tag":"g","path":"'"$H"'/rules/nope/nope.srs"}]}}' > "$H/config.json"
rf_enana_start; rc=$?
check "引用的规则集不在快照里: 返回 6, 没有管理员调用, 原因是 preflight-ref-missing" test "$rc:$(rf_admin_calls)" = "6:0"
check "…原因是 preflight-ref-missing" grep -q 'preflight-ref-missing' "$H/enhanced-check.log"
cp "$W/config.bak" "$H/config.json"
ln -s /etc/hosts "$H/rules/geo/link.srs"; rf_enana_start; rc=$?
check "规则目录里有符号链接: 返回 6, 没有管理员调用" test "$rc:$(rf_admin_calls)" = "6:0"
rm -f "$H/rules/geo/link.srs"
big_check() { local big; big=$(head -c 70000 /dev/zero | tr '\0' a); enhanced_admin "$big"; [ "$?" = 6 ] && [ "$(rf_admin_calls)" = 0 ]; }
nl_check() { enhanced_admin "$(printf 'a\nb')"; [ "$?" = 6 ] && [ "$(rf_admin_calls)" = 0 ]; }
check "命令超过 64 KB: enhanced_admin 返回 6, 不调用 sudo" big_check
check "命令含换行: enhanced_admin 返回 6, 不调用 sudo" nl_check

echo "== D. 暂存之后被改动: root 在改动任何东西之前拒绝 (退出码 3)"
rf_reset; rf_enana_start; before=$(root_sig); b0=$(calls_of bootout)
export RF_HOOK='printf x >> "$(cat "$RF_W/stage.path")/sing-box"'
rf_enana_start; rc=$?
check "核心在暂存之后被换掉: 退出码 3, 没有 bootout" test "$rc:$(calls_of bootout)" = "3:$b0"
check "…根目录没有变化" test "$(root_sig)" = "$before"
check "…拒绝的原因是 sing-box-digest (不是别的 3: M5)" grep -q 'refused: sing-box-digest' "$H/enhanced-check.log"
export RF_HOOK='printf " " >> "$(cat "$RF_W/stage.path")/config.json"'
rf_enana_start; rc=$?; check "配置被换掉: 退出码 3, 原因 config-digest" test "$rc:$(grep -c 'refused: config-digest' "$H/enhanced-check.log")" = "3:1"
export RF_HOOK='printf "\n" >> "$(cat "$RF_W/stage.path")/manifest"'
rf_enana_start; rc=$?; check "清单被换掉: 退出码 3, 原因 manifest-digest" test "$rc:$(grep -c 'refused: manifest-digest' "$H/enhanced-check.log")" = "3:1"
export RF_HOOK='printf x > "$(cat "$RF_W/stage.path")/extra"'
rf_enana_start; rc=$?; check "暂存目录里多出一个文件: 退出码 3, 原因 stage-extra" test "$rc:$(grep -c 'refused: stage-extra' "$H/enhanced-check.log")" = "3:1"
export RF_HOOK='ln -s /etc/hosts "$(cat "$RF_W/stage.path")/link"'
rf_enana_start; rc=$?; check "暂存目录里有符号链接: 退出码 3, 原因 stage-link" test "$rc:$(grep -c 'refused: stage-link' "$H/enhanced-check.log")" = "3:1"
export RF_HOOK='mkfifo "$(cat "$RF_W/stage.path")/fifo"'
rf_enana_start; rc=$?; check "暂存目录里有 FIFO: 立即拒绝 (不会卡住), 原因 stage-extra" test "$rc:$(grep -c 'refused: stage-extra' "$H/enhanced-check.log")" = "3:1"
rf_reset; rm -f "$W/stage-leak"
export RF_HOOK='[ ! -e "$(cat "$RF_W/stage.path")/refs" ] && [ ! -e "$(cat "$RF_W/stage.path")/list" ] || printf x > "$RF_W/stage-leak"'
rf_enana_start; rc=$?; unset RF_HOOK
check "正常安装: 管理员命令运行时暂存目录里没有 refs / list (B1: 只有 root 认的文件)" test "$rc:$(test -e "$W/stage-leak" && echo leak || echo clean)" = "0:clean"
check "以上拒绝都没有改动正在运行的系统" test "$(root_sig)" = "$before"
inband_bad() { bash "$LIBT/enhanced-root.sh" inband "$(printf '0%.0s' $(seq 1 64))" install >/dev/null 2>&1; [ "$?" = 3 ] && [ "$(root_sig)" = "$before" ]; }
check "脚本摘要不符 (inband SHA 错): 退出码 3, 没有改动" inband_bad

echo "== E. 助手可信与否只看字节 (10 节 T10); 目录链; 命令环境"
trust_ok() { os_helper_trusted "$HELPER" "$(enhanced_helper_expected)"; }
trust_bad() { ! os_helper_trusted "$HELPER" 0000000000000000000000000000000000000000000000000000000000000000; }
rf_reset; rf_enana_start
check "字节一致 (且 sudo -n -l 通过): 可信" trust_ok
echo '# 同版本号但字节不同' >> "$HELPER"
check "字节不同: 不可信 (而且不运行它)" trust_bad
rf_reset; mkdir -p "$W/elsewhere"; ln -s "$W/elsewhere" "$W/Library/PrivilegedHelperTools"
rf_enana_start; rc=$?
check "PrivilegedHelperTools 是符号链接: 安装照常成功, 助手和免密规则都没有, 链接另一端也没有建任何东西" test "$rc:$(test -e "$HELPER" && echo y || echo n):$(test -e "$W/sudoers.d/enana-tunrules-$ME" && echo y || echo n):$(ls -A "$W/elsewhere" | wc -l | tr -d ' ')" = "0:n:n:0"
rf_reset; mkdir -m 755 "$W/Library/PrivilegedHelperTools"; mkdir -p "$W/elsewhere/com.enana.proxy"; ln -s "$W/elsewhere/com.enana.proxy" "$HDIR"
rf_enana_start; rc=$?
check "…com.enana.proxy 是符号链接: 同样不装 (不写进链接另一端)" test "$rc:$(ls -A "$W/elsewhere/com.enana.proxy" | wc -l | tr -d ' '):$(test -e "$W/sudoers.d/enana-tunrules-$ME" && echo y || echo n)" = "0:0:n"
rm -rf "$W/elsewhere"
rf_reset; rf_enana_start                                       # 先装好: 助手和免密规则都在
chmod +a "group:staff allow add_file,add_subdirectory,delete_child" "$HDIR"     # 权限位还是 755, ACL 却让 staff 组能往里写
rf_enana_start; rc=$?
chmod -N "$HDIR"
check "com.enana.proxy 带 ACL (权限位看不出来): 安装照常成功, 已有的助手和免密规则都删掉" test "$rc:$(test -e "$HELPER" && echo y || echo n):$(test -e "$W/sudoers.d/enana-tunrules-$ME" && echo y || echo n)" = "0:n:n"
rf_reset; rf_enana_start
check "root 建的目录是 755 (umask 077 之下)" test "$(stat -f %Lp "$HDIR"):$(stat -f %Lp "$W/Library/PrivilegedHelperTools")" = "755:755"
rf_reset; chmod g+w "$W/Library"; rf_enana_start; rc=$?; chmod g-w "$W/Library"
check "最上一级 (/Library) 组可写: 安装照常成功, 助手和免密规则都没有" test "$rc:$(test -e "$HELPER" && echo y || echo n):$(test -e "$W/sudoers.d/enana-tunrules-$ME" && echo y || echo n)" = "0:n:n"
rf_reset; rmdir "$W/Library"; rf_enana_start; rc=$?
check "/Library 不在: root 不建它 (也不建下面两级), 安装照常成功, 没有助手" test "$rc:$(test -e "$W/Library" && echo y || echo n):$(test -e "$W/sudoers.d/enana-tunrules-$ME" && echo y || echo n)" = "0:n:n"
rf_reset; mkdir -m 1755 "$W/Library/PrivilegedHelperTools"; rf_enana_start; rc=$?
check "Apple 建的 PrivilegedHelperTools (root:wheel 1755, 带粘滞位): 照常装上助手, 不改它的权限" test "$rc:$(test -f "$HELPER" && echo y || echo n):$(stat -f '%Mp%Lp' "$W/Library/PrivilegedHelperTools")" = "0:y:1755"     # %Lp 只有 rwx 三位, 粘滞位在 %Mp
check "…enana 一侧也信任这个助手" trust_ok
printf 'package Canary; open my $f, ">>", "$ENV{RF_W}/canary.txt"; print $f "ran\\n"; close $f; 1;\n' > "$W/Canary.pm"
rf_reset
export RF_HOOK='export PERL5OPT="-I$RF_W -MCanary"'         # 只在管理员命令里设置 (假 sudo 的环境); root 的 perl 必须看不到它
rf_enana_start; rc=$?; unset RF_HOOK
check "PERL5OPT 的替身没有被 root 的 perl 运行 (root 命令清空环境)" test "$rc:$(cat "$W/canary.txt" 2>/dev/null | wc -l | tr -d ' ')" = "0:0"
check "管理员命令以 /usr/bin/env -i 开头 (清空环境)" grep -q "/bin/sh -c /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin " "$W/sudo.log"
no_lib_argv() { ! grep -q "$LIBT/[^ ']*[.]sh" "$W/sudo.log"; }
check "管理员命令的 argv 里没有 lib 目录里的 .sh 路径 (sudo -n 不会收到它们)" no_lib_argv
# 只查 shell 代码: 内嵌的 Perl 程序 (*_PL='…', 交给 /usr/bin/perl -e 运行) 换成空行 (行号不变), 里面的 sort / grep 是 Perl 的内建函数, 不是命令
root_shell() { awk '/^[A-Z_]+_PL=\047/ {p=1} {print (p ? "" : $0)} p && /\047$/ {p=0}' "$RF_REPO/lib/enhanced-root.sh"; }
bare_names() { root_shell | grep -nE '(^|[;&|(]) *(chown|install|mkdir|rm|cp|mv|chmod|stat|find|awk|sed|grep|head|tr|dirname|id|touch|base64|shasum|perl|route|ifconfig|sleep|cat|sort|mktemp|visudo|tee|launchctl|env|osascript) ' | grep -qv '^[0-9]*:[[:space:]]*#'; }
bare_free() { ! bare_names; }
check "root 脚本里没有裸的命令名 (每个命令都是绝对路径)" bare_free

echo "== F. 弹框分支的拒绝 (M1) · 删除时根目录是符号链接 (M4)"
rf_reset
# 原生弹框: osascript 把 root 的退出码包成 1, 原因只在输出的文字里; enhanced_start 必须仍然认出是拒绝 (不再重试、不另弹框)
enhanced_admin() { printf 'execution error: enana-root: refused: config-path: /log/output (4)\n' >&2; ENHANCED_ADMIN_ERR=failed; return 1; }
enhanced_start >/dev/null 2>&1
check "弹框分支的拒绝 (退出码 1): ENHANCED_REFUSED=1, 原因 config-path: /log/output" test "$ENHANCED_REFUSED:$ENHANCED_REFUSED_WHY" = "1:config-path: /log/output"
rf_reset; rm -rf "$ROOT"; mkdir -p "$W/elsewhere/bin"; : > "$W/elsewhere/bin/keep"; ln -s "$W/elsewhere" "$ROOT"
sha=$(shasum -a 256 "$LIBT/enhanced-root.sh" | awk '{print $1}')
bash "$LIBT/enhanced-root.sh" inband "$sha" remove "$ME" >/dev/null 2>&1; rc=$?
check "inband 删除, 根目录是符号链接: 退出码 3, 链接另一端的文件还在" test "$rc:$(test -f "$W/elsewhere/bin/keep" && echo y || echo n)" = "3:y"
rm -f "$ROOT"; mkdir -p "$ROOT"

echo
if [ "$fails" = 0 ]; then echo 'PASS: config path checks, staged-tamper refusals, preflight without prompts, snapshot filter, byte-trusted helper, directory chain, command environment'
else echo "FAIL: $fails check(s) failed"; exit 1; fi
