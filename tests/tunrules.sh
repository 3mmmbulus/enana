#!/bin/bash
# TUN 规则同步助手 (lib/tunrules-helper.pl · lib/enhanced.sh · lib/config.sh): 几秒钟, 不需要 sing-box / 真实的 launchd / 管理员权限。
#   · 助手 (在临时目录里, 路径和 uid 在临时副本里替换): 合法数据包写进规则集目录 (原地覆盖, inode 不变); 任何一项不合格 → 一个文件都不动
#   · 校验: 文件名 / 版本 / 结构 / 匹配键 / 值的类型和长度 / 控制字符 / 数量 / 总大小 / 符号链接 / 目录归属 / 多余参数
#   · apply_config 的决策: 只有应用 / 网站策略变了且助手可用 → 免密同步、不重启; 助手没有 / 被拒绝 / 其它文件或配置变了 → 完整安装 (要管理员授权)
# 全部使用假 sudo (tests/fakebin); 助手只写测试沙箱里的目录。
set -u
HERE=$(cd "$(dirname "$0")" && pwd -P); REPO=$(dirname "$HERE")
W=$(mktemp -d /tmp/enana-tunrules.XXXXXX); W=$(cd "$W" && pwd -P)
trap 'rm -rf "$W"' EXIT; : > "$W/.pass"; : > "$W/.fail"
tpass() { echo p >> "$W/.pass"; echo "  ✓ $1"; }
tfail() { echo f >> "$W/.fail"; echo "  ✗ $1"; [ -n "${2:-}" ] && printf '      ↳ %s\n' "$(printf '%s' "$2" | head -c 600)"; return 0; }
eq()    { if [ "$2" = "$3" ]; then tpass "$1"; else tfail "$1" "期望 [$3] 实际 [$2]"; fi; }
hs()    { if printf '%s\n' "$3" | grep -Eq -- "$2"; then tpass "$1"; else tfail "$1" "没有找到 /$2/ 于: $3"; fi; }
command -v perl >/dev/null && command -v python3 >/dev/null || { echo "跳过: 需要 perl / python3"; exit 77; }

ME=$(id -u)
mkdir -p "$W/snap/rules" "$W/bin"
HV=$(sed -n 's/^TUNRULES_HELPER_VERSION=\([0-9][0-9]*\).*/\1/p' "$REPO/lib/enhanced.sh")      # 助手版本以 enhanced.sh 为准 (enana 只信任版本一致的助手)
LBL=com.enana.proxy.tun.$ME
# 假 launchctl (助手的 restart 动作只会调用它): 记录收到的全部参数; 存在 $W/lc-fail 时失败
cat > "$W/bin/mock-launchctl" <<MOCK
#!/bin/sh
echo "\$*" >> "$W/lc.calls"
[ ! -f "$W/lc-fail" ] || exit 1
exit 0
MOCK
chmod +x "$W/bin/mock-launchctl"
# 助手的临时副本: 快照目录 / 目录归属 uid / 版本 / 守护进程标签 / launchctl 路径写成测试值 (生产里由 root 安装脚本写成真实路径、0、/bin/launchctl)
mkhelper() { # <输出文件> [版本] [标签] [launchctl 路径] [目录归属 uid]
  sed -e "s|@ROOT@|$W/snap|g" -e "s|@ROOTUID@|${5:-$ME}|g" -e "s|@VERSION@|${2:-$HV}|g" -e "s|@LABEL@|${3:-$LBL}|g" -e "s|@LAUNCHCTL@|${4:-$W/bin/mock-launchctl}|g" "$REPO/lib/tunrules-helper.pl" > "$1"
}
mkhelper "$W/helper.pl"
H() { perl "$W/helper.pl" "$@"; }                           # H sync < 数据包
rules() { python3 - "$@" <<'PY'
import json,sys
# rules <name> <key> <value...> -> 一个规则集 JSON (version 3, 一条规则)
name,key,*vals=sys.argv[1:]
print(json.dumps({"version":3,"rules":[{key:vals}]}))
PY
}
bundle() { python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])))' "$1"; }
snap() { cat "$W/snap/rules/$1" 2>/dev/null; }
inode() { stat -f %i "$W/snap/rules/$1" 2>/dev/null; }

echo "== T1. 助手: 合法数据包 → 原地写进规则集目录"
eq "version 输出版本号 ($HV: 第 2 版增加了 restart)" "$(H version)" "$HV"
B1='{"ovr-pin.json":{"version":3,"rules":[{"process_path_regex":["(?i)/ChatGPT\\.app/"]},{"domain_suffix":["openai.com","chatgpt.com"]}]},"ovr-apppin-1.json":{"version":3,"rules":[{"process_name":["curl"]}]},"ovr-direct.json":{"version":3,"rules":[{"domain":["enana-placeholder.invalid"]}]}}'
printf '%s' "$B1" | H sync >"$W/out" 2>&1; rc=$?
eq "合法数据包: 退出码 0, 写了 3 个文件" "$rc:$(cat "$W/out")" "0:3 files synced"
eq "内容是规范化的 JSON (一行 + 换行)" "$(snap ovr-pin.json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["rules"]), d["version"])')" "2 3"
I0=$(inode ovr-pin.json)
printf '%s' '{"ovr-pin.json":{"version":3,"rules":[{"domain":["a.example"]}]}}' | H sync >/dev/null 2>&1
eq "再次同步: 原地覆盖 (inode 不变, 核心的文件监视继续有效)" "$(inode ovr-pin.json)" "$I0"
eq "…新内容比旧内容短: 没有残留旧内容的尾巴" "$(snap ovr-pin.json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["rules"])')" "[{'domain': ['a.example']}]"
eq "没有出现在数据包里的文件原样保留" "$(snap ovr-direct.json | python3 -c 'import json,sys; print(json.load(sys.stdin)["rules"][0]["domain"][0])')" "enana-placeholder.invalid"
printf '%s' '{"ovr-auto.json":{"version":3,"rules":[{"process_name":["微信","Tabby"]}]}}' | H sync >/dev/null 2>&1; rc=$?
eq "新文件 + 中文应用名: 允许" "$rc:$(snap ovr-auto.json | python3 -c 'import json,sys; print(json.load(sys.stdin)["rules"][0]["process_name"][0])')" "0:微信"

echo "== T2. 助手: 任何一项不合格 → 拒绝, 而且一个文件都不动"
printf '%s' '{"ovr-pin.json":{"version":3,"rules":[{"domain":["keep.example"]}]}}' | H sync >/dev/null 2>&1
BASE=$(snap ovr-pin.json)
rej() { # <描述> <数据包 JSON 文本>  好文件 ovr-direct.json 排在前面: 即使它合法, 也不能被写
  local d=$1 body=$2 out rc
  body=$(python3 -c 'import json,sys; good={"ovr-direct.json":{"version":3,"rules":[{"domain":["MUST-NOT-APPEAR.example"]}]}}; bad=json.loads(sys.argv[1]); good.update(bad); print(json.dumps(good))' "$body")
  printf '%s' "$body" | H sync >"$W/out" 2>&1; rc=$?
  if [ "$rc" != 0 ] && ! snap ovr-direct.json | grep -q MUST-NOT-APPEAR && [ "$(snap ovr-pin.json)" = "$BASE" ]; then tpass "$d"; else tfail "$d" "rc=$rc out=$(cat "$W/out") direct=$(snap ovr-direct.json)"; fi
}
R() { printf '{"version":3,"rules":%s}' "$1"; }
rej "文件名: ../ 路径穿越"                   "{\"../evil.json\":$(R '[{"domain":["a"]}]')}"
rej "文件名: 核心配置 config.json"            "{\"config.json\":$(R '[{"domain":["a"]}]')}"
rej "文件名: 不在固定集合里 (ovr-x.json)"     "{\"ovr-x.json\":$(R '[{"domain":["a"]}]')}"
rej "文件名: 多余后缀 (ovr-pin.json.bak)"     "{\"ovr-pin.json.bak\":$(R '[{"domain":["a"]}]')}"
rej "文件名: 序号超过 2 位 (ovr-pin-100.json)" "{\"ovr-pin-100.json\":$(R '[{"domain":["a"]}]')}"
rej "版本不是 3"                              '{"ovr-pin.json":{"version":2,"rules":[{"domain":["a"]}]}}'
rej "规则集里多了别的键 (outbound)"            '{"ovr-pin.json":{"version":3,"rules":[{"domain":["a"]}],"outbound":"direct"}}'
rej "规则集缺少 rules"                         '{"ovr-pin.json":{"version":3}}'
rej "rules 为空"                               "{\"ovr-pin.json\":$(R '[]')}"
rej "rules 超过 8 条"                          "{\"ovr-pin.json\":$(R '[{"domain":["a"]},{"domain":["b"]},{"domain":["c"]},{"domain":["d"]},{"domain":["e"]},{"domain":["f"]},{"domain":["g"]},{"domain":["h"]},{"domain":["i"]}]')}"
rej "一条规则里有两个匹配键"                    "{\"ovr-pin.json\":$(R '[{"domain":["a"],"domain_suffix":["b"]}]')}"
rej "未知的匹配键 (outbound)"                  "{\"ovr-pin.json\":$(R '[{"outbound":["direct"]}]')}"
rej "未知的匹配键 (process_path / exec)"       "{\"ovr-pin.json\":$(R '[{"exec":["/bin/sh"]}]')}"
rej "匹配值不是数组"                            "{\"ovr-pin.json\":$(R '[{"domain":"a"}]')}"
rej "匹配值数组为空"                            "{\"ovr-pin.json\":$(R '[{"domain":[]}]')}"
rej "值里有数字"                               "{\"ovr-pin.json\":$(R '[{"domain":[1]}]')}"
rej "值里有 null"                              "{\"ovr-pin.json\":$(R '[{"domain":[null]}]')}"
rej "值里有对象"                               "{\"ovr-pin.json\":$(R '[{"domain":[{"a":1}]}]')}"
rej "值是空字符串"                              "{\"ovr-pin.json\":$(R '[{"domain":[""]}]')}"
rej "值里有控制字符 (换行)"                      "{\"ovr-pin.json\":$(R '[{"domain":["a\nb"]}]')}"
rej "值里有控制字符 (\\u0001)"                   "{\"ovr-pin.json\":$(R '[{"domain":["a\u0001b"]}]')}"
rej "值超过 400 个字符"                          "$(python3 -c 'import json; print(json.dumps({"ovr-pin.json":{"version":3,"rules":[{"domain":["x"*401]}]}}))')"
rej "一条规则超过 5000 个值"                     "$(python3 -c 'import json; print(json.dumps({"ovr-pin.json":{"version":3,"rules":[{"domain":["d%d.example"%i for i in range(5001)]}]}}))')"
rej "总条数超过 20000"                          "$(python3 -c 'import json; print(json.dumps({"ovr-pin.json":{"version":3,"rules":[{"domain":["a%d"%i for i in range(5000)]} for _ in range(5)]}}))')"
for bad in '[]' '"x"' '{}' 'not json' ''; do
  printf '%s' "$bad" | H sync >/dev/null 2>&1; rc=$?
  eq "整体不是合法的数据包 ($(printf '%s' "$bad" | head -c 12)…): 拒绝" "$([ $rc != 0 ] && echo rejected || echo accepted)" "rejected"
done
python3 -c 'import sys; sys.stdout.write("{\"ovr-pin.json\":{\"version\":3,\"rules\":[{\"domain\":[\"" + "a"*2100000 + "\"]}]}}")' | H sync >/dev/null 2>&1
eq "输入超过 2 MB: 拒绝" "$([ $? != 0 ] && echo rejected || echo accepted)" "rejected"
eq "上面所有拒绝之后, 已有文件一个字节都没变" "$(snap ovr-pin.json)" "$BASE"

echo "== T3. 助手: 符号链接 / 目录归属 / 参数"
printf 'TOP-SECRET' > "$W/secret.txt"; rm -f "$W/snap/rules/ovr-apppin.json"; ln -s "$W/secret.txt" "$W/snap/rules/ovr-apppin.json"
printf '%s' '{"ovr-apppin.json":{"version":3,"rules":[{"domain":["a"]}]}}' | H sync >/dev/null 2>&1; rc=$?
eq "目标文件是符号链接: 拒绝, 链接指向的文件没被改" "$([ $rc != 0 ] && echo rejected || echo accepted):$(cat "$W/secret.txt")" "rejected:TOP-SECRET"
rm -f "$W/snap/rules/ovr-apppin.json"
mv "$W/snap/rules" "$W/snap/rules.real"; ln -s "$W/snap/rules.real" "$W/snap/rules"
printf '%s' '{"ovr-pin.json":{"version":3,"rules":[{"domain":["a"]}]}}' | H sync >/dev/null 2>&1
eq "规则集目录本身是符号链接: 拒绝" "$([ $? != 0 ] && echo rejected || echo accepted)" "rejected"
rm -f "$W/snap/rules"; mv "$W/snap/rules.real" "$W/snap/rules"
mkhelper "$W/helper-other.pl" "$HV" "$LBL" "$W/bin/mock-launchctl" "$((ME + 1))"
printf '%s' '{"ovr-pin.json":{"version":3,"rules":[{"domain":["a"]}]}}' | perl "$W/helper-other.pl" sync >/dev/null 2>&1
eq "目录不归预期的 uid (生产里是 root): 拒绝" "$([ $? != 0 ] && echo rejected || echo accepted)" "rejected"
printf '%s' '{}' | H sync extra >/dev/null 2>&1; eq "多余参数: 拒绝" "$([ $? != 0 ] && echo rejected || echo accepted)" "rejected"
H bogus </dev/null >/dev/null 2>&1; eq "不认识的命令: 拒绝" "$([ $? != 0 ] && echo rejected || echo accepted)" "rejected"
H </dev/null >/dev/null 2>&1; eq "没有命令: 拒绝" "$([ $? != 0 ] && echo rejected || echo accepted)" "rejected"
sed -e "s|@ROOT@|$W/nonexistent|g" -e "s|@ROOTUID@|$ME|g" -e "s|@VERSION@|$HV|g" -e "s|@LABEL@|$LBL|g" -e "s|@LAUNCHCTL@|$W/bin/mock-launchctl|g" "$REPO/lib/tunrules-helper.pl" > "$W/helper-nodir.pl"
printf '%s' '{"ovr-pin.json":{"version":3,"rules":[{"domain":["a"]}]}}' | perl "$W/helper-nodir.pl" sync >/dev/null 2>&1
eq "快照里还没有规则集目录 (TUN 没装过): 拒绝, 不会凭空创建" "$([ $? != 0 ] && echo rejected || echo accepted):$([ -e "$W/nonexistent" ] && echo created || echo untouched)" "rejected:untouched"

echo "== T3b. 助手: restart 动作只能重启这个用户自己的守护进程 (launchctl kickstart -k <写死的标签>)"
: > "$W/lc.calls"; rm -f "$W/lc-fail"
H restart >"$W/out" 2>&1; rc=$?
eq "restart: 退出码 0, 输出 restarted" "$rc:$(cat "$W/out")" "0:restarted"
eq "…只调用了一次 launchctl, 参数固定为 kickstart -k system/<标签>" "$(cat "$W/lc.calls")" "kickstart -k system/$LBL"
: > "$W/lc.calls"; LABEL=com.apple.evil LAUNCHCTL=/bin/false ROOT=/etc SYSTEM_LABEL=x H restart >/dev/null 2>&1
eq "…环境变量 (LABEL / LAUNCHCTL / ROOT) 改不了它: 仍然是同一条命令" "$(cat "$W/lc.calls")" "kickstart -k system/$LBL"
norun() { # <描述> <命令…>  被拒绝 (退出码非 0) 而且 launchctl 一次都没有被调用
  local d=$1 rc; shift; : > "$W/lc.calls"
  "$@" </dev/null >"$W/out" 2>&1; rc=$?
  if [ "$rc" != 0 ] && [ ! -s "$W/lc.calls" ]; then tpass "$d"; else tfail "$d" "rc=$rc calls=$(cat "$W/lc.calls") out=$(cat "$W/out")"; fi
}
norun "restart 带别的标签 (system/com.apple.mDNSResponder): 拒绝, 不调用 launchctl" H restart system/com.apple.mDNSResponder
norun "restart -k: 拒绝" H restart -k
norun "restart 带两个参数: 拒绝" H restart a b
norun "sync 带 restart: 拒绝" H sync restart
norun "命令大小写不同 (RESTART): 拒绝" H RESTART
norun "命令后带空白 (\"restart \"): 拒绝" H "restart "
norun "不认识的命令 (kickstart / bootout): 拒绝" H kickstart
norun "写死的标签不合规 (带分号的字符串): 拒绝" perl "$(mkhelper "$W/helper-bad1.pl" "$HV" 'x; rm -rf /'; echo "$W/helper-bad1.pl")" restart
norun "写死的标签不是 com.enana.proxy.tun.<数字> (com.apple.mDNSResponder): 拒绝" perl "$(mkhelper "$W/helper-bad2.pl" "$HV" com.apple.mDNSResponder; echo "$W/helper-bad2.pl")" restart
norun "写死的 launchctl 路径含空格: 拒绝" perl "$(mkhelper "$W/helper-bad3.pl" "$HV" "$LBL" '/tmp/a b/launchctl'; echo "$W/helper-bad3.pl")" restart
if [ "$ME" != 0 ]; then
  mkhelper "$W/helper-rootuid.pl" "$HV" "$LBL" "$W/bin/mock-launchctl" 0
  norun "按生产配置 (目录归 root) 由非 root 调用: restart 同样拒绝 (和 sync 一样, 只有 sudo 才能用)" perl "$W/helper-rootuid.pl" restart
fi
touch "$W/lc-fail"; : > "$W/lc.calls"; H restart >"$W/out" 2>&1; rc=$?
eq "launchctl 失败: 助手退出码非 0 (不假装成功)" "$([ "$rc" != 0 ] && echo failed || echo ok):$(cat "$W/lc.calls")" "failed:kickstart -k system/$LBL"
rm -f "$W/lc-fail"
echo "== T3c. 固定出口很多时: 12 个固定名字的规则集 + 每个固定出口 3 个 (网站 / 应用 / 浏览器) —— OVR_PIN_MAX=32 个出口 = 108 个文件, 一个数据包同步完; 超过上限的数据包被拒"
big() { # big <文件数> <域名>  -> 数据包 JSON: 11 个固定名字 + ovr-pin-N / ovr-apppin-N / ovr-browserpin-N (N 从 1 起, 最多两位)
  python3 -c '
import json, sys
n, dom = int(sys.argv[1]), sys.argv[2]
names = ["ovr-" + b + ".json" for b in "direct appdirect browserdirect browserauto browserpin browserpinauto pin pinauto apppin apppinauto appauto auto".split()]
i = 1
while len(names) < n:
    for p in ("pin", "apppin", "browserpin"):
        if len(names) < n: names.append("ovr-%s-%d.json" % (p, i))
    i += 1
print(json.dumps({x: {"version": 3, "rules": [{"domain": [dom]}]} for x in names}))' "$1" "$2"
}
big 108 a.example | H sync >"$W/out" 2>&1; rc=$?
eq "32 个固定出口 (108 个文件): 一次同步完" "$rc:$(cat "$W/out")" "0:108 files synced"
eq "…序号最大的 ovr-browserpin-32 / ovr-pin-32 都写进去了" "$(snap ovr-browserpin-32.json | grep -c a.example):$(snap ovr-pin-32.json | grep -c a.example)" "1:1"
big 160 a.example | H sync >"$W/out" 2>&1; rc=$?
eq "上限 160 个文件: 通过 (留有余量)" "$rc:$(cat "$W/out")" "0:160 files synced"
big 161 b.example | H sync >"$W/out" 2>&1; rc=$?
eq "161 个文件: 整个数据包被拒, 已有文件一个字节都没变" "$([ "$rc" != 0 ] && echo rejected):$(snap ovr-pin-1.json | grep -c a.example):$(snap ovr-pin-1.json | grep -c b.example)" "rejected:1:0"
rm -f "$W"/snap/rules/ovr-*-[0-9]*.json

echo "== T4. apply_config 的决策: 免密同步 还是 完整安装 (要管理员授权)"
export HOME=$W/home ENANA_HOME=$W/h LC_ALL=C ENANA_LANG=zh ENANA_PLATFORM=darwin PORT=37970 UI_PORT=37971 API_PORT=37972 SPEED_PORT=37973 ENANA_NO_DIAG=1
export FAKE_STATE=$W/state ENANA_ROOT_PREFIX=$W/root FAKE_SUDOERS_DIR=$W/root/etc/sudoers.d ENANA_TUN_ROOT=$W/snap
mkdir -p "$HOME" "$ENANA_HOME" "$FAKE_STATE" "$ENANA_ROOT_PREFIX"
export PATH="$HERE/fakebin:$PATH"
. "$REPO/lib/common.sh"; init_paths "$REPO/install.sh"; LIB=$REPO/lib; DATA=$REPO/data
for _f in i18n jobs servers fetch os-darwin enhanced auth device session cloud dns logs health update config ops; do . "$LIB/$_f.sh"; done
load_settings; QUIET=1; mkdir -p "$H/rules" "$LOGS"
[ "$H" = "$W/h" ] || { echo "REFUSING: 数据目录不是临时目录 ($H)"; exit 1; }
printf 'NETWORK_MODE=tun\n' > "$H/settings.env"
printf '#!/bin/sh\nexit 0\n' > "$H/sing-box"; chmod +x "$H/sing-box"; SB=$H/sing-box
# 把 apply_config 依赖的东西换成假的: 配置固定不变, 只统计「核心被重启了几次」
RESTARTS=0
gen_config() { printf '{"fixed":"config"}' > "$H/config.json.new"; }
ovr_sync() { :; }; _apply_step() { :; }
os_service_restart() { RESTARTS=$((RESTARTS + 1)); return 0; }
os_service_loaded() { return 0; }; os_service_pid() { echo 1; }; wait_port() { return 0; }; proxy_sync_mode() { :; }
enhanced_ready() { return 0; }; enhanced_loaded() { return 0; }
# 助手: 用测试副本安装到沙箱的「/usr/local/libexec」, sudoers 规则写进沙箱的「/etc/sudoers.d」
install_helper() {
  local h; h=$(enhanced_helper_path); mkdir -p "$(dirname "$h")" "$FAKE_SUDOERS_DIR"
  cp "$W/helper.pl" "$h"; chmod 755 "$h"
  printf '%s ALL=(root) NOPASSWD: %s\n' "$(id -un)" "$h" > "$FAKE_SUDOERS_DIR/enana-tunrules-$ME"
}
state() { # 把「现状」记成基线: 配置, 再让真实的 enhanced_record_install 记下完整安装之后留下的东西 (核心指纹 / 策略指纹 / 模式)
  cp "$H/config.json.new" "$H/config.json" 2>/dev/null || printf '{"fixed":"config"}' > "$H/config.json"
  enhanced_record_install
}
ovr() { printf '{"version":3,"rules":[{"domain_suffix":["%s"]}]}\n' "$1" > "$H/rules/ovr-pin.json"; }
reset() { rm -rf "$H/rules" "$W/snap/rules" "$W/root" "$LOGS"; mkdir -p "$H/rules" "$W/snap/rules" "$LOGS"; : > "$W/snap/rules/ovr-pin.json"; RESTARTS=0; ovr base.example; printf 'x' > "$H/rules/geosite-cn.srs"; gen_config; state; }
ops() { cat "$LOGS"/ops-*.log 2>/dev/null; }

reset; install_helper
apply_config; rc=$?
eq "什么都没变: 返回 0, 没有重启, 没有同步" "$rc:$RESTARTS:$(ops | grep -c 同步策略规则)" "0:0:0"
reset; install_helper; ovr changed.example
apply_config; rc=$?
eq "应用 / 网站策略变了 + 助手可用: 返回 0, 核心没有重启 (= 不弹管理员密码)" "$rc:$RESTARTS" "0:0"
eq "…新规则已经写进 root 快照 (核心热加载这个文件)" "$(grep -c changed.example "$W/snap/rules/ovr-pin.json")" "1"
eq "…策略指纹已更新, 再来一次什么都不做" "$(enhanced_ovr_fingerprint)" "$(cat "$H/.enhanced-ovr-fingerprint")"
hs "…操作记录里写明是免密同步、没有重启" "同步策略规则	mode=tun via=helper restart=no	ok" "$(ops)"
RESTARTS=0; apply_config; eq "…第二次 apply: 无事可做" "$RESTARTS" "0"
reset; ovr changed.example
apply_config; rc=$?
eq "策略变了但助手还没装 (旧版本升级后的第一次): 走完整安装 (重启一次, 要管理员授权)" "$rc:$RESTARTS" "0:1"
hs "…操作记录写明原因 no-helper" "同步策略规则	mode=tun via=helper restart=yes err=no-helper" "$(ops)"
reset; install_helper; printf '{"version":2,"rules":[{"domain":["a"]}]}\n' > "$H/rules/ovr-pin.json"
apply_config; rc=$?
eq "助手拒绝了这份数据 (版本不对): 退回完整安装, 不会假装成功" "$rc:$RESTARTS" "0:1"
hs "…操作记录写明 rejected" "restart=yes err=rejected" "$(ops)"
reset; install_helper; printf 'changed' > "$H/rules/geosite-cn.srs"
apply_config
eq "规则库 (geosite) 变了 (不是策略): 必须完整安装" "$RESTARTS" "1"
reset; install_helper; printf '{"fixed":"config","new":1}' > "$H/config.json.new"; gen_config() { printf '{"fixed":"config","new":1}' > "$H/config.json.new"; }
apply_config
eq "核心配置变了: 必须完整安装" "$RESTARTS" "1"
gen_config() { printf '{"fixed":"config"}' > "$H/config.json.new"; }
reset; install_helper; chmod 775 "$(enhanced_helper_path)"; ovr changed.example
apply_config
eq "助手文件别人可写 (不可信): 不使用, 完整安装" "$RESTARTS" "1"
reset; install_helper; rm -f "$FAKE_SUDOERS_DIR"/*; ovr changed.example
apply_config
eq "sudoers 规则不在了 (sudo -n 要密码): 完整安装" "$RESTARTS" "1"
reset; install_helper; NETWORK_MODE=system; printf 'NETWORK_MODE=system\n' > "$H/settings.env"; ovr changed.example
apply_config; rc=$?
eq "系统代理模式: 完全不涉及助手 (规则本来就是热加载的)" "$rc:$RESTARTS:$(ops | grep -c 同步策略规则)" "0:0:0"
printf 'NETWORK_MODE=tun\n' > "$H/settings.env"

echo "== T5. 指纹: 策略规则文件不再计入「核心」指纹"
reset; F0=$(enhanced_fingerprint); O0=$(enhanced_ovr_fingerprint)
ovr other.example
eq "改 ovr-*.json: 核心指纹不变, 策略指纹变" "$([ "$(enhanced_fingerprint)" = "$F0" ] && echo core-same):$([ "$(enhanced_ovr_fingerprint)" != "$O0" ] && echo ovr-changed)" "core-same:ovr-changed"
reset; F0=$(enhanced_fingerprint); O0=$(enhanced_ovr_fingerprint)
printf 'y' > "$H/rules/geosite-cn.srs"
eq "改 geosite-cn.srs: 核心指纹变, 策略指纹不变" "$([ "$(enhanced_fingerprint)" != "$F0" ] && echo core-changed):$([ "$(enhanced_ovr_fingerprint)" != "$O0" ] && echo ovr-changed || echo ovr-same)" "core-changed:ovr-same"

echo "== T5b. 指纹: 只有真的会让 root 快照不同的东西才计入 (记账文件 / 开关模式不算)"
fp_same() { [ "$(enhanced_fingerprint)" = "$1" ] && echo same || echo changed; }
reset; printf '1\n' > "$H/rules/.updated"; F0=$(enhanced_fingerprint)
printf '2\n' > "$H/rules/.updated"
eq "rules/.updated 被改写 (每次 enana update / 每日维护都写, 即使没有任何规则变化): 指纹不变" "$(fp_same "$F0")" "same"
printf 'x' > "$H/rules/geosite-cn.srs.new"; printf 'x' > "$H/rules/ovr-pin.json.tmp"; printf 'x' > "$H/rules/.DS_Store"; mkdir -p "$H/certs"; printf 'x' > "$H/certs/.DS_Store"
eq "下载 / 写入过程中的 *.new *.tmp 和 .DS_Store: 指纹不变" "$(fp_same "$F0")" "same"
printf 'y' > "$H/rules/geosite-cn.srs"
eq "…但 .srs 的内容变了: 指纹变 (必须完整安装)" "$(fp_same "$F0")" "changed"
reset; F0=$(enhanced_fingerprint); printf 'n' > "$H/rules/geosite-new.srs"
eq "新增一个 .srs: 指纹变" "$(fp_same "$F0")" "changed"
reset; F0=$(enhanced_fingerprint); mkdir -p "$H/certs"; printf 'cert' > "$H/certs/a.crt"
eq "新增 / 改动证书: 指纹变" "$(fp_same "$F0")" "changed"
reset; printf '{"a":1,"clash_api":{"default_mode":"Direct"}}' > "$H/config.json"; F0=$(enhanced_fingerprint)
printf '{"a":1,"clash_api":{"default_mode":"Global"}}' > "$H/config.json"
eq "config.json 只有 default_mode 变了 (总开关 / 模式切换会改写它): 指纹不变" "$(fp_same "$F0")" "same"
printf '{"a":2,"clash_api":{"default_mode":"Global"}}' > "$H/config.json"
eq "config.json 别的内容变了: 指纹变" "$(fp_same "$F0")" "changed"
printf '{"a":1,"clash_api":{"default_mode":"Global"}}' > "$H/config.json"; F1=$(enhanced_fingerprint); AUTOSTART=0
eq "开机自启设置变了: 指纹变 (守护进程的 plist 不同)" "$(fp_same "$F1")" "changed"; AUTOSTART=1
# Windows 的指纹 (没有免密助手, 策略规则集仍然计入): 同样不受 .updated / default_mode 影响, 真正的变化仍然计入
(
  eval "$(sed -n '/^enhanced_fingerprint()/,/^}/p' "$LIB/enhanced-windows.sh")"
  command -v sha256sum >/dev/null 2>&1 || { printf '#!/bin/sh\nexec shasum -a 256 "$@"\n' > "$W/bin/sha256sum"; chmod +x "$W/bin/sha256sum"; PATH="$W/bin:$PATH"; }
  mkdir -p "$H/windows"; printf 'a' > "$H/windows/tun.ps1"; printf 'b' > "$H/windows/common.ps1"; reset
  printf '{"a":1,"clash_api":{"default_mode":"Direct"}}' > "$H/config.json"; printf '1\n' > "$H/rules/.updated"; F0=$(enhanced_fingerprint)
  printf '2\n' > "$H/rules/.updated"; printf '{"a":1,"clash_api":{"default_mode":"Rule"}}' > "$H/config.json"; printf 'x' > "$H/rules/geosite-cn.srs.new"
  eq "Windows 指纹: .updated / default_mode / *.new 变了, 指纹不变" "$(fp_same "$F0")" "same"
  printf 'y' > "$H/rules/geosite-cn.srs"
  eq "Windows 指纹: .srs 变了, 指纹变" "$(fp_same "$F0")" "changed"
  reset; printf '{"a":1}' > "$H/config.json"; F0=$(enhanced_fingerprint); ovr other.example
  eq "Windows 指纹: 策略规则集 (ovr-*.json) 变了, 指纹变 (Windows 没有免密助手, 仍需要完整安装)" "$(fp_same "$F0")" "changed"
)

echo "== T4b. 只是记账内容 / 总开关模式变了: 不重启核心 (= 不弹管理员密码框); 真的变了才重启"
(
  gen_config() { printf '{"fixed":"config","clash_api":{"default_mode":"%s"}}' "$(proxy_clash_mode)" > "$H/config.json.new"; }
  printf 'NETWORK_MODE=tun\n' > "$H/settings.env"; load_settings
  reset
  eq "(准备) 完整安装之后记下的模式 = 当时的模式 (总开关关 = Direct)" "$(cat "$H/.enhanced-mode")" "Direct"
  printf '1\n' > "$H/rules/.updated"; state
  printf '2\n' > "$H/rules/.updated"; RESTARTS=0
  apply_config; rc=$?
  eq "rules/.updated 被改写: 返回 0, 配置无变化, 核心没有重启 (以前每次 enana update 都会走完整安装)" "$rc:$RESTARTS:$APPLY_CHANGED" "0:0:0"
  # 总开关 / 模式: 真实的 _proxy_set → proxy_apply_mode 会改写磁盘上的 default_mode (这正是以前让指纹对不上的原因)
  reset; MODE_SYNCS=0; LIVE=Direct
  proxy_sync_mode() { MODE_SYNCS=$((MODE_SYNCS + 1)); }
  clash() { if [ "$1" = GET ]; then printf '{"mode":"%s","mode-list":["Rule","Global","Direct"]}' "$LIVE"; fi; return 0; }
  _proxy_set PROXY_ENABLED 1
  eq "(准备) 总开关打开: 磁盘配置里的 default_mode 变成 Rule, 而安装时记下的是 Direct" "$(grep -c '"default_mode":"Rule"' "$H/config.json"):$(cat "$H/.enhanced-mode")" "1:Direct"
  RESTARTS=0; MODE_SYNCS=0; LIVE=Rule
  apply_config; rc=$?
  eq "只改了总开关: 返回 0, 配置无变化, 核心没有重启 (以前会走完整安装 = 弹管理员密码框)" "$rc:$RESTARTS:$APPLY_CHANGED" "0:0:0"
  eq "…运行中的核心补同步了一次模式 (它报告 Rule), 并记下" "$MODE_SYNCS:$(cat "$H/.enhanced-mode")" "1:Rule"
  apply_config; eq "…再 apply 一次: 不再重复同步, 仍然没有重启" "$RESTARTS:$MODE_SYNCS" "0:1"
  _proxy_set PROXY_MODE global; RESTARTS=0; MODE_SYNCS=0; LIVE=Rule
  apply_config
  eq "模式改成 global 时核心没有报告新模式 (比如切换那一刻核心没在运行, 推送丢了): 不重启, 但也不记下" "$RESTARTS:$MODE_SYNCS:$(cat "$H/.enhanced-mode")" "0:1:Rule"
  apply_config; eq "…下一次 apply 还会再试" "$MODE_SYNCS" "2"
  LIVE=Global; apply_config; eq "…核心报告 Global 之后记下, 不再重试" "$(cat "$H/.enhanced-mode")" "Global"
  # 配置里真的有别的变化 (+ 模式也变了): 仍然要完整安装
  printf 'NETWORK_MODE=tun\n' > "$H/settings.env"; load_settings; reset
  gen_config() { printf '{"fixed":"config","servers":2,"clash_api":{"default_mode":"%s"}}' "$(proxy_clash_mode)" > "$H/config.json.new"; }
  _proxy_set PROXY_ENABLED 1; RESTARTS=0
  apply_config
  eq "default_mode 和别的内容一起变了: 必须完整安装" "$RESTARTS" "1"
  reset; state; printf 'z' > "$H/rules/geosite-cn.srs"; printf '3\n' > "$H/rules/.updated"; RESTARTS=0
  apply_config
  eq ".updated 和 .srs 一起变了 (每日更新真的下载到新规则): 必须完整安装" "$RESTARTS" "1"
)

echo "== T6. 重启核心 (os_service_restart): 指纹没变 + 助手可信 → 用助手重启, 不弹管理员密码框; 其它情形走完整安装"
(
  eval "$(sed -n '/^os_service_restart()/,/^}/p' "$LIB/os-darwin.sh")"        # 前面把它换成了只计数的假函数; 这里要跑真实的那个
  FULL=0; SYS=0
  os_service_start() { FULL=$((FULL + 1)); return 0; }
  os_system_service_restart() { SYS=$((SYS + 1)); return 0; }
  gen_config() { printf '{"fixed":"config","inbounds":[{"type":"tun"}]}' > "$H/config.json.new"; }
  lc() { cat "$W/lc.calls" 2>/dev/null; }
  fresh() { reset; install_helper; : > "$W/lc.calls"; rm -f "$W/lc-fail"; FULL=0; SYS=0; }
  fresh
  os_service_restart; rc=$?
  eq "TUN 已安装 + 配置 / 规则没变 + 助手可信: 返回 0, 完整安装一次都没走" "$rc:$FULL" "0:0"
  eq "…助手只做了一件事: kickstart -k 这个用户自己的守护进程" "$(lc)" "kickstart -k system/$LBL"
  hs "…操作记录写明是助手重启" "重启核心方式	mode=tun via=helper	ok" "$(ops)"
  hs "…sudo 调用的是助手本身, 带 restart 参数, 而且是 -n (不等密码)" "^sudo -n $(enhanced_helper_path) restart" "$(cat "$FAKE_STATE/calls.log" 2>/dev/null)"
  fresh; ovr changed.example
  os_service_restart
  eq "还有没同步的应用 / 网站策略: 先同步进 root 快照, 再用助手重启 (仍然不走完整安装)" "$FULL:$(grep -c changed.example "$W/snap/rules/ovr-pin.json"):$(lc)" "0:1:kickstart -k system/$LBL"
  reset; : > "$W/lc.calls"; FULL=0
  os_service_restart
  eq "助手还没装 (旧版本升级后的第一次): 走完整安装, 不调用助手" "$FULL:$(lc)" "1:"
  hs "…操作记录写明原因 no-helper" "重启核心方式	mode=tun via=admin why=no-helper	ok" "$(ops)"
  fresh; mkhelper "$W/helper-v1.pl" 1; cp "$W/helper-v1.pl" "$(enhanced_helper_path)"
  os_service_restart
  eq "助手是旧版本 (版本 1, 没有 restart): 视为不可用, 走完整安装 (装上新版本)" "$FULL:$(lc)" "1:"
  fresh; printf 'changed' > "$H/rules/geosite-cn.srs"
  os_service_restart
  eq "规则库 (.srs) 变了: 快照要更新, 走完整安装, 不调用助手" "$FULL:$(lc)" "1:"
  hs "…操作记录写明 changed" "via=admin why=changed" "$(ops)"
  fresh; AUTOSTART=0
  os_service_restart
  eq "开机自启设置变了 (守护进程的 plist 要重写): 走完整安装" "$FULL:$(lc)" "1:"
  AUTOSTART=1
  fresh; touch "$W/lc-fail"
  os_service_restart
  eq "助手运行失败 (launchctl 报错): 退回完整安装, 不假装成功" "$FULL:$(lc)" "1:kickstart -k system/$LBL"
  hs "…操作记录写明 rejected" "via=admin why=rejected" "$(ops)"
  fresh; enhanced_loaded() { return 1; }
  os_service_restart
  eq "守护进程没加载: 走完整安装" "$FULL:$(lc)" "1:"
  enhanced_loaded() { return 0; }
  fresh; chmod 775 "$(enhanced_helper_path)"
  os_service_restart
  eq "助手别人可写 (不可信): 走完整安装" "$FULL:$(lc)" "1:"
  fresh; rm -f "$FAKE_SUDOERS_DIR"/*
  os_service_restart
  eq "sudoers 规则不在了: 走完整安装" "$FULL:$(lc)" "1:"
  fresh; gen_config() { printf '{"fixed":"config"}' > "$H/config.json.new"; }; gen_config; state
  os_service_restart
  eq "配置里已经没有 tun (正在切回系统代理) 但守护进程还在: 走 os_service_start (它会停掉 root 核心), 不用助手重启" "$FULL:$(lc)" "1:"
  fresh; enhanced_loaded() { return 1; }; enhanced_configured() { return 1; }
  os_service_restart
  eq "System Proxy (既没配 TUN 也没加载): 重启用户自己的核心, 完全不涉及助手 / 完整安装" "$FULL:$SYS:$(lc)" "0:1:"
)

echo "== T7. 停止已经停掉的守护进程不要管理员授权 (stop 之后 plist 还在; 更完整的覆盖在 tests/enhanced.sh)"
(
  eval "$(sed -n -e '/^enhanced_idle()/,/^}/p' -e '/^enhanced_stop()/,/^}/p' "$LIB/enhanced.sh")"        # 真实的函数 (前面没有换成假的, 这里只换掉特权调用和 launchd)
  ADMIN=0; enhanced_admin() { ADMIN=$((ADMIN + 1)); return 0; }
  enhanced_paths() { TUN_UID=501; TUN_LABEL=com.enana.proxy.tun.501; TUN_PLIST="$W/stop.plist"; }; : > "$W/stop.plist"
  LOADED=1; enhanced_loaded() { [ "$LOADED" = 1 ]; }
  launchctl() { return 1; }                                   # launchd 查不到 print-disabled: 只能靠本机记录
  rm -f "$H/.enhanced-stopped"
  enhanced_stop; eq "守护进程在运行: 停止要授权一次" "$ADMIN" "1"
  LOADED=0; enhanced_stop; enhanced_stop; eq "停掉之后 (plist 还在): 再停止 / System Proxy 启动都不再要授权" "$ADMIN" "1"
  rm -f "$H/.enhanced-stopped"; ADMIN=0
  launchctl() { [ "$1" = print-disabled ] && printf '\t"com.enana.proxy.tun.501" => disabled\n'; }
  enhanced_stop; eq "launchd 说这个任务已禁用 (stop 做的就是这个): 没有任何记录也不要授权" "$ADMIN" "0"
  launchctl() { [ "$1" = print-disabled ] && printf '\t"com.enana.proxy.tun.501" => enabled\n'; }
  enhanced_stop; eq "没加载但仍是启用状态 (被手动 bootout 过): 下次开机会回来, 所以仍要 stop (顺带禁用)" "$ADMIN" "1"
)

echo "== T8. 内容没变的订阅刷新不改动 servers.jsonl (否则文件顺序变 → 配置变 → 核心重启, TUN 下还要管理员授权)"
(
  SF="$H/servers.jsonl"
  m() { printf '{"role":"auto","outbound":{"type":"trojan","tag":"%s","server":"%s.example","server_port":443,"password":"pw"}}\n' "$1" "$1"; }
  s() { printf '{"role":"auto","sub":"%s","outbound":{"type":"trojan","tag":"%s","server":"%s.example","server_port":443,"password":"pw"}}\n' "$1" "$2" "$2"; }
  tags() { sed -n 's/.*"tag":"\([^"]*\)".*/\1/p' "$SF" | paste -sd, -; }
  { m M1; s A A1; s A A2; s B B1; m M2; s B B2; } > "$SF"; cp "$SF" "$W/before"
  r1=$({ s A A1; s A A2; } | srv_import A replace); r2=$({ s B B1; s B B2; } | srv_import B replace)
  eq "两个订阅和手动服务器交错, 内容相同的刷新: servers.jsonl 一个字节没变" "$(cmp -s "$SF" "$W/before" && echo same || echo changed):$r1:$r2" "same:0 2 0:0 2 0"
  { s A A1; s A A3; } | srv_import A replace >/dev/null
  eq "订阅 A 换了一个节点: A2 消失, A3 追加到末尾, 其它每个节点的位置不变" "$(tags)" "M1,A1,B1,M2,B2,A3"
)

P=$(wc -l < "$W/.pass" | tr -d ' '); F=$(wc -l < "$W/.fail" | tr -d ' ')
echo; echo "tunrules.sh: $P passed, $F failed"; [ "$F" = 0 ]
