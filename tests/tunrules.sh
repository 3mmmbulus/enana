#!/bin/bash
# TUN 规则同步助手 (lib/tunrules-helper.pl · lib/enhanced.sh · lib/config.sh): 几秒钟, 不需要 sing-box / 真实的 launchd / 管理员权限。
#   · 助手 (在临时目录里, 路径和 uid 在临时副本里替换): 合法数据包写进规则集目录 (原地覆盖, inode 不变); 任何一项不合格 → 一个文件都不动
#   · 校验: 文件名 / 版本 / 结构 / 匹配键 / 值的类型和长度 / 控制字符 / 数量 / 总大小 / 符号链接 / 目录归属 / 多余参数
#   · 网站的域名列表 (site-<id>.json, T3d): 只有一条 domain / domain_suffix 规则, 值必须是合法域名, 只覆盖快照里已经有的文件
#   · apply_config 的决策: 只有应用 / 网站策略或网站的域名列表变了且助手可用 → 免密同步、不重启; 助手没有 / 被拒绝 / 其它文件或配置变了 → 完整安装 (要管理员授权)
#   · T10 用真实的 gen_config / apply_config / op_txn: 改网站域名、添加 / 删除自己的网站、改线路、恢复网站默认 → 配置不变, 只经助手同步; 服务器变了 → 完整安装; 2.3.25 快照的迁移
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
snap() { cat "$W/snap/rules/${1%.*}/$1" 2>/dev/null; }
inode() { stat -f %i "$W/snap/rules/${1%.*}/$1" 2>/dev/null; }

echo "== T1. 助手: 合法数据包 → 原地写进规则集目录"
eq "version 输出版本号 ($HV: 第 3 版改为每个规则集一个目录)" "$(H version)" "$HV"
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
rej "文件名: 结尾带换行 (ovr-pin.json\\n: 以前的 \$ 会放过它, 建出名字带换行的目录)" "{\"ovr-pin.json\\n\":$(R '[{"domain":["a"]}]')}"
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
printf 'TOP-SECRET' > "$W/secret.txt"; mkdir -p "$W/snap/rules/ovr-apppin"; rm -f "$W/snap/rules/ovr-apppin/ovr-apppin.json"; ln -s "$W/secret.txt" "$W/snap/rules/ovr-apppin/ovr-apppin.json"
printf '%s' '{"ovr-apppin.json":{"version":3,"rules":[{"domain":["a"]}]}}' | H sync >/dev/null 2>&1; rc=$?
eq "目标文件是符号链接: 拒绝, 链接指向的文件没被改" "$([ $rc != 0 ] && echo rejected || echo accepted):$(cat "$W/secret.txt")" "rejected:TOP-SECRET"
rm -f "$W/snap/rules/ovr-apppin/ovr-apppin.json"
mv "$W/snap/rules" "$W/snap/rules.real"; ln -s "$W/snap/rules.real" "$W/snap/rules"
printf '%s' '{"ovr-pin.json":{"version":3,"rules":[{"domain":["a"]}]}}' | H sync >/dev/null 2>&1
eq "规则集目录本身是符号链接: 拒绝" "$([ $? != 0 ] && echo rejected || echo accepted)" "rejected"
rm -f "$W/snap/rules"; mv "$W/snap/rules.real" "$W/snap/rules"
mkdir -p "$W/evil"; mv "$W/snap/rules/ovr-pin" "$W/snap/rules/ovr-pin.real"; ln -s "$W/evil" "$W/snap/rules/ovr-pin"
printf '%s' '{"ovr-direct.json":{"version":3,"rules":[{"domain":["MUST-NOT-APPEAR.example"]}]},"ovr-pin.json":{"version":3,"rules":[{"domain":["a"]}]}}' | H sync >/dev/null 2>&1; rc=$?
eq "子目录 rules/ovr-pin 是符号链接: 拒绝; 同一包里排在前面的合法文件 ovr-direct 也不写 (先检查全部目标, 再开始写)" "$([ $rc != 0 ] && echo rejected):$(ls "$W/evil" | wc -l | tr -d ' '):$(snap ovr-direct.json | grep -c MUST-NOT-APPEAR)" "rejected:0:0"
rm -f "$W/snap/rules/ovr-pin"; mv "$W/snap/rules/ovr-pin.real" "$W/snap/rules/ovr-pin"
mv "$W/snap/rules/ovr-auto" "$W/snap/rules/ovr-auto.real"; : > "$W/snap/rules/ovr-auto"
printf '%s' '{"ovr-auto.json":{"version":3,"rules":[{"domain":["a"]}]}}' | H sync >/dev/null 2>&1; rc=$?
eq "子目录 rules/ovr-auto 是普通文件: 拒绝" "$([ $rc != 0 ] && echo rejected || echo accepted)" "rejected"
rm -f "$W/snap/rules/ovr-auto"; mv "$W/snap/rules/ovr-auto.real" "$W/snap/rules/ovr-auto"
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
big() { # big <文件数> <域名>  -> 数据包 JSON: 12 个固定名字 + ovr-pin-N / ovr-apppin-N / ovr-browserpin-N (N 从 1 起, 最多两位)
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
rm -rf "$W"/snap/rules/ovr-*-[0-9]*

echo "== T3d. 助手: 网站的域名列表 site-<id>.json —— 只有一条 domain / domain_suffix 规则、每个值都是合法的域名、只覆盖快照里已经有的文件"
seed_site() { mkdir -p "$W/snap/rules/site-$1"; printf '%s\n' '{"version":3,"rules":[{"domain":["enana-placeholder.invalid"]}]}' > "$W/snap/rules/site-$1/site-$1.json"; }   # 完整安装放进快照的文件
seed_site claude; seed_site ai-common
SI0=$(inode site-claude.json)
printf '%s' '{"site-claude.json":{"version":3,"rules":[{"domain_suffix":["claude.ai","anthropic.com"]}]},"ovr-pin.json":{"version":3,"rules":[{"domain":["keep.example"]}]}}' | H sync >"$W/out" 2>&1; rc=$?
eq "合法的域名列表 (和策略规则集在同一个数据包里): 退出码 0, 写了 2 个文件" "$rc:$(cat "$W/out")" "0:2 files synced"
eq "…内容写进去了, 原地覆盖 (inode 不变, 核心的文件监视继续有效)" "$(snap site-claude.json | grep -c anthropic.com):$(inode site-claude.json)" "1:$SI0"
LONG63=$(python3 -c 'print("a"*63)'); MAX253=$(python3 -c 'print(".".join(["a"*63]*3 + ["b"*61]))')
printf '{"site-ai-common.json":{"version":3,"rules":[{"domain_suffix":[".sub.example","cn","xn--fiqs8s.example","%s.example","%s","a-b.c-d.example"]}]}}' "$LONG63" "$MAX253" | H sync >"$W/out" 2>&1; rc=$?
eq "合法的名字: 以点开头的后缀 (只匹配子域名) / 单段 (cn) / punycode / 63 位的标签 / 正好 253 位 / 中间的连字符: 允许" "$rc:$(cat "$W/out")" "0:1 files synced"
printf '%s' '{"site-ai-common.json":{"version":3,"rules":[{"domain":["enana-placeholder.invalid"]}]}}' | H sync >/dev/null 2>&1; rc=$?
eq "域名删光了 (占位规则: domain enana-placeholder.invalid): 允许" "$rc:$(snap site-ai-common.json | grep -c enana-placeholder.invalid)" "0:1"
SBASE=$(snap site-claude.json); OBASE=$(snap ovr-pin.json)
srej() { # <描述> <数据包 JSON>  拒绝; 快照里的 site-claude / ovr-pin 一个字节都不变, 同一个包里的合法文件 (site-ai-common) 也不写
  local d=$1 body=$2 out rc
  body=$(python3 -c 'import json,sys; good={"site-ai-common.json":{"version":3,"rules":[{"domain":["must-not-appear.example"]}]}}; bad=json.loads(sys.argv[1]); good.update(bad); print(json.dumps(good))' "$body")
  printf '%s' "$body" | H sync >"$W/out" 2>&1; rc=$?
  if [ "$rc" != 0 ] && ! snap site-ai-common.json | grep -q must-not-appear && [ "$(snap site-claude.json)" = "$SBASE" ] && [ "$(snap ovr-pin.json)" = "$OBASE" ]; then tpass "$d"; else tfail "$d" "rc=$rc out=$(cat "$W/out")"; fi
}
SR() { printf '{"site-claude.json":{"version":3,"rules":%s}}' "$1"; }      # SR <rules 数组>: site-claude.json 的数据包
SV() { SR "$(python3 -c 'import json,sys; print(json.dumps([{sys.argv[1]: sys.argv[2:]}]))' "$@")"; }      # SV <匹配键> <值…>
srej "文件名: 大写 (site-Claude.json)"                     "{\"site-Claude.json\":$(R '[{"domain":["a.example"]}]')}"
srej "文件名: id 以连字符开头 (site--x.json)"              "{\"site--x.json\":$(R '[{"domain":["a.example"]}]')}"
srej "文件名: 空 id (site-.json)"                          "{\"site-.json\":$(R '[{"domain":["a.example"]}]')}"
srej "文件名: 路径穿越 (site-../../x.json)"                "{\"site-../../x.json\":$(R '[{"domain":["a.example"]}]')}"
srej "文件名: 带斜杠 (site-a/site-a.json)"                 "{\"site-a/site-a.json\":$(R '[{"domain":["a.example"]}]')}"
srej "文件名: 下划线 (site-a_b.json)"                      "{\"site-a_b.json\":$(R '[{"domain":["a.example"]}]')}"
srej "文件名: id 超过 63 位"                               "{\"site-${LONG63}a.json\":$(R '[{"domain":["a.example"]}]')}"
srej "文件名: 多余后缀 (site-claude.json.bak)"             "{\"site-claude.json.bak\":$(R '[{"domain":["a.example"]}]')}"
srej "文件名: 结尾带换行 (site-claude.json\\n)"            "{\"site-claude.json\\n\":$(R '[{"domain":["a.example"]}]')}"
srej "快照里没有的网站 (site-new: 目录和文件都不在): 拒绝" "{\"site-new.json\":$(R '[{"domain":["a.example"]}]')}"
eq "…而且没有新建目录 (助手不为网站的域名列表建任何东西)" "$([ -e "$W/snap/rules/site-new" ] && echo created || echo untouched)" "untouched"
mkdir -p "$W/snap/rules/site-half"
srej "目录在、文件不在 (site-half.json): 拒绝, 不新建文件" "{\"site-half.json\":$(R '[{"domain":["a.example"]}]')}"
eq "…site-half 目录里还是空的" "$(ls -A "$W/snap/rules/site-half" | wc -l | tr -d ' ')" "0"
rmdir "$W/snap/rules/site-half"
srej "匹配键: process_name (网站的列表里不能有应用)"        "$(SV process_name curl)"
srej "匹配键: process_path_regex (不能有正则)"             "$(SV process_path_regex '(?i)/x\.app/')"
srej "匹配键: domain_keyword"                              "$(SV domain_keyword claude)"
srej "匹配键: domain_regex"                                "$(SV domain_regex '.*')"
srej "匹配键: ip_cidr"                                     "$(SV ip_cidr 0.0.0.0/0)"
srej "两条规则 (网站的列表只有一条)"                         "$(SR '[{"domain":["a.example"]},{"domain_suffix":["b.example"]}]')"
srej "一条规则里有两个匹配键"                               "$(SR '[{"domain":["a.example"],"domain_suffix":["b.example"]}]')"
srej "规则集里多了别的键 (path)"                            '{"site-claude.json":{"version":3,"rules":[{"domain":["a.example"]}],"path":"/etc/hosts"}}'
srej "版本不是 3"                                          '{"site-claude.json":{"version":2,"rules":[{"domain":["a.example"]}]}}'
srej "值: 带协议和路径 (https://a.example/x)"               "$(SV domain_suffix https://a.example/x)"
srej "值: 路径 (/etc/passwd)"                              "$(SV domain_suffix /etc/passwd)"
srej "值: 带空格"                                          "$(SV domain_suffix 'a example.com')"
srej "值: 大写字母"                                        "$(SV domain_suffix A.example)"
srej "值: 通配符 (*.a.example)"                            "$(SV domain_suffix '*.a.example')"
srej "值: 下划线"                                          "$(SV domain_suffix a_b.example)"
srej "值: 标签以连字符开头 (-a.example)"                    "$(SV domain_suffix -a.example)"
srej "值: 标签以连字符结尾 (a-.example)"                    "$(SV domain_suffix a-.example)"
srej "值: 空标签 (a..example)"                             "$(SV domain_suffix a..example)"
srej "值: 结尾带点 (a.example.)"                           "$(SV domain_suffix a.example.)"
srej "值: 两个点开头 (..a.example)"                        "$(SV domain_suffix ..a.example)"
srej "值: 只有一个点"                                      "$(SV domain_suffix .)"
srej "值: domain (完整域名) 不能以点开头"                    "$(SV domain .a.example)"
srej "值: 标签超过 63 位"                                  "$(SV domain_suffix "${LONG63}a.example")"
srej "值: 总长超过 253"                                    "$(SV domain_suffix "${MAX253}b")"
srej "值: 中文 (要用 punycode)"                            "$(SV domain_suffix 中文.example)"
srej "值: 控制字符"                                        "$(SR '[{"domain":["a\u0001.example"]}]')"
srej "值: 数字"                                            "$(SR '[{"domain":[1]}]')"
srej "值: 空字符串"                                        "$(SR '[{"domain":[""]}]')"
srej "值: 同一条规则超过 5000 个"                           "$(python3 -c 'import json; print(json.dumps({"site-claude.json":{"version":3,"rules":[{"domain_suffix":["d%d.example"%i for i in range(5001)]}]}}))')"
python3 -c 'import json; v=["%s.d%d.example" % (".".join(["a"*55]*4), i) for i in range(5000)]; print(json.dumps({"site-ai-common.json":{"version":3,"rules":[{"domain_suffix":v}]},"site-claude.json":{"version":3,"rules":[{"domain_suffix":v}]}}))' 2>/dev/null | H sync >/dev/null 2>&1; rc=$?
eq "数据包超过 2 MB (两个网站各 5000 个合法的长域名): 整个拒绝, 一个字节都没写" "$([ "$rc" != 0 ] && echo rejected):$([ "$(snap site-claude.json)" = "$SBASE" ] && echo same):$(snap site-ai-common.json | grep -c d4999.example)" "rejected:same:0"
printf 'TOP-SECRET' > "$W/secret.txt"; rm -f "$W/snap/rules/site-claude/site-claude.json"; ln -s "$W/secret.txt" "$W/snap/rules/site-claude/site-claude.json"
printf '%s' '{"site-claude.json":{"version":3,"rules":[{"domain":["a.example"]}]}}' | H sync >/dev/null 2>&1; rc=$?
eq "site-claude.json 是符号链接: 拒绝, 链接指向的文件没被改" "$([ $rc != 0 ] && echo rejected || echo accepted):$(cat "$W/secret.txt")" "rejected:TOP-SECRET"
rm -f "$W/snap/rules/site-claude/site-claude.json"; printf '%s\n' "$SBASE" > "$W/snap/rules/site-claude/site-claude.json"
mkdir -p "$W/evil"; mv "$W/snap/rules/site-claude" "$W/snap/rules/site-claude.real"; ln -s "$W/evil" "$W/snap/rules/site-claude"
printf '%s' '{"site-claude.json":{"version":3,"rules":[{"domain":["a.example"]}]}}' | H sync >/dev/null 2>&1; rc=$?
eq "目录 rules/site-claude 是符号链接 (指向快照外): 拒绝, 链接另一端什么都没写" "$([ $rc != 0 ] && echo rejected || echo accepted):$(ls -A "$W/evil" | wc -l | tr -d ' ')" "rejected:0"
rm -f "$W/snap/rules/site-claude"; : > "$W/snap/rules/site-claude"
printf '%s' '{"site-claude.json":{"version":3,"rules":[{"domain":["a.example"]}]}}' | H sync >/dev/null 2>&1; rc=$?
eq "rules/site-claude 是普通文件: 拒绝" "$([ $rc != 0 ] && echo rejected || echo accepted)" "rejected"
rm -f "$W/snap/rules/site-claude"; mv "$W/snap/rules/site-claude.real" "$W/snap/rules/site-claude"; rm -rf "$W/evil"
sites() { # sites <个数> <域名> [策略文件个数]  -> 数据包: site-s1 … site-sN (+ 前 M 个固定名字 / 序号的 ovr 文件)
  python3 -c '
import json, sys
n, dom, m = int(sys.argv[1]), sys.argv[2], int(sys.argv[3])
d = {"site-s%d.json" % i: {"version": 3, "rules": [{"domain_suffix": [dom]}]} for i in range(1, n + 1)}
names = ["ovr-" + b + ".json" for b in "direct appdirect browserdirect browserauto browserpin browserpinauto pin pinauto apppin apppinauto appauto auto".split()]
i = 1
while len(names) < m:
    for p in ("pin", "apppin", "browserpin"): names.append("ovr-%s-%d.json" % (p, i))
    i += 1
for x in names[:m]: d[x] = {"version": 3, "rules": [{"domain": [dom]}]}
print(json.dumps(d))' "$1" "$2" "${3:-0}"
}
for i in $(seq 1 401); do seed_site "s$i"; done
sites 400 a.example 160 | H sync >"$W/out" 2>&1; rc=$?
eq "400 个网站的域名列表 + 160 个策略文件 (两个上限分开算): 一次同步完" "$rc:$(cat "$W/out")" "0:560 files synced"
sites 401 b.example | H sync >"$W/out" 2>&1; rc=$?
eq "401 个网站的域名列表: 整个数据包被拒, 一个字节都没变" "$([ "$rc" != 0 ] && echo rejected):$(snap site-s1.json | grep -c a.example):$(snap site-s1.json | grep -c b.example)" "rejected:1:0"
rm -rf "$W"/snap/rules/site-* "$W"/snap/rules/ovr-*-[0-9]*

echo "== T4. apply_config 的决策: 免密同步 还是 完整安装 (要管理员授权)"
export HOME=$W/home ENANA_HOME=$W/h LC_ALL=C ENANA_LANG=zh ENANA_PLATFORM=darwin PORT=37970 UI_PORT=37971 API_PORT=37972 SPEED_PORT=37973 ENANA_NO_DIAG=1
export ENANA_TEST=1 FAKE_STATE=$W/state ENANA_ROOT_PREFIX=$W/root FAKE_SUDOERS_DIR=$W/root/etc/sudoers.d ENANA_TUN_ROOT=$W/snap
mkdir -p "$HOME" "$ENANA_HOME" "$FAKE_STATE" "$ENANA_ROOT_PREFIX"
export PATH="$HERE/fakebin:$PATH"
. "$REPO/lib/common.sh"; init_paths "$REPO/install.sh"; LIB=$REPO/lib; DATA=$REPO/data
for _f in i18n jobs servers fetch os-darwin enhanced auth device session cloud dns logs health update config ops; do . "$LIB/$_f.sh"; done
load_settings; QUIET=1; mkdir -p "$H/rules" "$LOGS"
[ "$H" = "$W/h" ] || { echo "REFUSING: 数据目录不是临时目录 ($H)"; exit 1; }
printf 'NETWORK_MODE=tun\n' > "$H/settings.env"
printf '#!/bin/sh\nexit 0\n' > "$H/sing-box"; chmod +x "$H/sing-box"; SB=$H/sing-box
# 把 apply_config 依赖的东西换成假的: 配置固定不变, 只统计「核心被重启了几次」
# 配置和真的一样引用它的规则集文件 (route.rule_set 的本地路径): 指纹只算配置引用到的规则文件 (lib/enhanced.sh 的 enhanced_data_hashes)
RESTARTS=0
RS='"route":{"rule_set":[{"type":"local","tag":"geosite-cn","format":"binary","path":"'"$H"'/rules/geosite-cn/geosite-cn.srs"}]}'
gen_config() { printf '{"fixed":"config",%s}' "$RS" > "$H/config.json.new"; }
ovr_sync() { :; }; _apply_step() { :; }
os_service_restart() { RESTARTS=$((RESTARTS + 1)); return 0; }
os_service_loaded() { return 0; }; os_service_pid() { echo 1; }; wait_port() { return 0; }; proxy_sync_mode() { :; }
enhanced_ready() { return 0; }; enhanced_loaded() { return 0; }
# 助手: 用测试副本安装到沙箱的「/Library/PrivilegedHelperTools/com.enana.proxy」, sudoers 规则写进沙箱的「/etc/sudoers.d」
# 助手 = enana 自己渲染出来的字节 (enhanced_helper_render, 和 root 安装时用的是同一段函数); 测试不是 root, 所以只把 uid 换成当前用户
helper_bytes() { enhanced_helper_render "$W/snap" "$LBL" "$W/bin/mock-launchctl" < "$REPO/lib/tunrules-helper.pl" | sed "s/^my \$ROOT_UID = 0;/my \$ROOT_UID = $ME;/"; }
install_helper() {
  local h; h=$(enhanced_helper_path); mkdir -p "$(dirname "$h")" "$FAKE_SUDOERS_DIR"
  helper_bytes > "$h"
  chmod 755 "$h"
  printf '%s ALL=(root) NOPASSWD: %s\n' "$(id -un)" "$h" > "$FAKE_SUDOERS_DIR/enana-tunrules-$ME"
  enhanced_helper_expected() { helper_bytes | shasum -a 256 | awk '{print $1}'; }      # 测试的期望值 = 此刻渲染出来的字节 (和生产一样不看装上的文件: 换成旧版本的助手就对不上)
}
state() { # 把「现状」记成基线: 配置, 再让真实的 enhanced_record_install 记下完整安装之后留下的东西 (核心指纹 / 策略指纹 / 模式)
  cp "$H/config.json.new" "$H/config.json" 2>/dev/null || printf '{"fixed":"config"}' > "$H/config.json"
  enhanced_record_install
}
ovr() { mkdir -p "$H/rules/ovr-pin"; printf '{"version":3,"rules":[{"domain_suffix":["%s"]}]}\n' "$1" > "$H/rules/ovr-pin/ovr-pin.json"; }
reset() { rm -rf "$H/rules" "$W/snap/rules" "$W/root" "$LOGS"; mkdir -p "$H/rules/geosite-cn" "$W/snap/rules/ovr-pin" "$LOGS"; : > "$W/snap/rules/ovr-pin/ovr-pin.json"; RESTARTS=0; ovr base.example; printf 'x' > "$H/rules/geosite-cn/geosite-cn.srs"; gen_config; state; }
ops() { cat "$LOGS"/ops-*.log 2>/dev/null; }

reset; install_helper
apply_config; rc=$?
eq "什么都没变: 返回 0, 没有重启, 没有同步" "$rc:$RESTARTS:$(ops | grep -c 同步策略规则)" "0:0:0"
reset; install_helper; ovr changed.example
apply_config; rc=$?
eq "应用 / 网站策略变了 + 助手可用: 返回 0, 核心没有重启 (= 不弹管理员密码)" "$rc:$RESTARTS" "0:0"
eq "…新规则已经写进 root 快照 (核心热加载这个文件)" "$(grep -c changed.example "$W/snap/rules/ovr-pin/ovr-pin.json")" "1"
eq "…策略指纹已更新, 再来一次什么都不做" "$(enhanced_ovr_fingerprint)" "$(cat "$H/.enhanced-ovr-fingerprint")"
hs "…操作记录里写明是免密同步、没有重启" "同步策略规则	mode=tun via=helper restart=no	ok" "$(ops)"
RESTARTS=0; apply_config; eq "…第二次 apply: 无事可做" "$RESTARTS" "0"
reset; ovr changed.example
apply_config; rc=$?
eq "策略变了但助手还没装 (旧版本升级后的第一次): 走完整安装 (重启一次, 要管理员授权)" "$rc:$RESTARTS" "0:1"
hs "…操作记录写明原因 no-helper" "同步策略规则	mode=tun via=helper restart=yes err=no-helper" "$(ops)"
reset; install_helper; mkdir -p "$H/rules/ovr-pin"; printf '{"version":2,"rules":[{"domain":["a"]}]}\n' > "$H/rules/ovr-pin/ovr-pin.json"
apply_config; rc=$?
eq "助手拒绝了这份数据 (版本不对): 退回完整安装, 不会假装成功" "$rc:$RESTARTS" "0:1"
hs "…操作记录写明 rejected" "restart=yes err=rejected" "$(ops)"
reset; install_helper; printf 'changed' > "$H/rules/geosite-cn/geosite-cn.srs"
apply_config
eq "规则库 (geosite) 变了 (不是策略): 必须完整安装" "$RESTARTS" "1"
reset; mkdir -p "$H/rules/geosite-left"; printf 'L' > "$H/rules/geosite-left/geosite-left.srs"
apply_config; rc=$?
eq "取消了授权的规则集开关留下了下载 (rules/<x>/<x>.srs, 配置没有引用它): 之后的 TUN 应用不重启 (= 不再每次都要管理员密码)" "$rc:$RESTARTS" "0:0"
reset; install_helper; printf '{"fixed":"config","new":1}' > "$H/config.json.new"; gen_config() { printf '{"fixed":"config","new":1}' > "$H/config.json.new"; }
apply_config
eq "核心配置变了: 必须完整安装" "$RESTARTS" "1"
gen_config() { printf '{"fixed":"config",%s}' "$RS" > "$H/config.json.new"; }
reset; install_helper; chmod 775 "$(enhanced_helper_path)"; ovr changed.example
apply_config
eq "助手文件别人可写 (不可信): 不使用, 完整安装" "$RESTARTS" "1"
reset; install_helper; rm -f "$FAKE_SUDOERS_DIR"/*; ovr changed.example
apply_config
eq "sudoers 规则不在了 (sudo -n 要密码): 完整安装" "$RESTARTS" "1"
reset; install_helper; NETWORK_MODE=system; printf 'NETWORK_MODE=system\n' > "$H/settings.env"; ovr changed.example
enhanced_loaded() { return 1; }                                   # 系统代理模式: 根守护进程没有加载 (正常的状态)
apply_config; rc=$?
eq "系统代理模式: 完全不涉及助手 (规则本来就是热加载的)" "$rc:$RESTARTS:$(ops | grep -c 同步策略规则)" "0:0:0"
enhanced_loaded() { return 0; }                                   # 切回系统代理没有完成: 设置是系统代理, 根守护进程却还加载着
apply_config; rc=$?
eq "系统代理模式、配置没变, 但根守护进程还加载着: 不能直接返回 (它还在接管流量), 重启一次 (停掉它、启动用户核心); 不走助手同步" "$rc:$RESTARTS:$(ops | grep -c 同步策略规则)" "0:1:0"
printf 'NETWORK_MODE=tun\n' > "$H/settings.env"

echo "== T5. 指纹: 策略规则文件不再计入「核心」指纹"
reset; F0=$(enhanced_fingerprint); O0=$(enhanced_ovr_fingerprint)
ovr other.example
eq "改 ovr-*.json: 核心指纹不变, 策略指纹变" "$([ "$(enhanced_fingerprint)" = "$F0" ] && echo core-same):$([ "$(enhanced_ovr_fingerprint)" != "$O0" ] && echo ovr-changed)" "core-same:ovr-changed"
reset; F0=$(enhanced_fingerprint); O0=$(enhanced_ovr_fingerprint)
printf 'y' > "$H/rules/geosite-cn/geosite-cn.srs"
eq "改 geosite-cn.srs: 核心指纹变, 策略指纹不变" "$([ "$(enhanced_fingerprint)" != "$F0" ] && echo core-changed):$([ "$(enhanced_ovr_fingerprint)" != "$O0" ] && echo ovr-changed || echo ovr-same)" "core-changed:ovr-same"

echo "== T5b. 指纹: 只有真的会让 root 快照不同的东西才计入 (记账文件 / 开关模式不算)"
fp_same() { [ "$(enhanced_fingerprint)" = "$1" ] && echo same || echo changed; }
reset; printf '1\n' > "$H/rules/.updated"; F0=$(enhanced_fingerprint)
printf '2\n' > "$H/rules/.updated"
eq "rules/.updated 被改写 (每次 enana update / 每日维护都写, 即使没有任何规则变化): 指纹不变" "$(fp_same "$F0")" "same"
printf 'x' > "$H/rules/geosite-cn/geosite-cn.srs.new"; mkdir -p "$H/rules/ovr-pin"; printf 'x' > "$H/rules/ovr-pin/ovr-pin.json.tmp"; printf 'x' > "$H/rules/.DS_Store"; mkdir -p "$H/certs"; printf 'x' > "$H/certs/.DS_Store"
eq "下载 / 写入过程中的 *.new *.tmp 和 .DS_Store: 指纹不变" "$(fp_same "$F0")" "same"
printf 'y' > "$H/rules/geosite-cn/geosite-cn.srs"
eq "…但 .srs 的内容变了: 指纹变 (必须完整安装)" "$(fp_same "$F0")" "changed"
reset; F0=$(enhanced_fingerprint); mkdir -p "$H/rules/geosite-new"; printf 'n' > "$H/rules/geosite-new/geosite-new.srs"
eq "新增一个配置没有引用的 .srs (比如取消了授权的规则集开关留下的下载): 指纹不变 (root 的核心不读它)" "$(fp_same "$F0")" "same"
printf 'm' > "$H/rules/geosite-new/geosite-new.srs"
eq "…它的内容又变了: 指纹仍不变" "$(fp_same "$F0")" "same"
printf '{"fixed":"config","route":{"rule_set":[{"type":"local","tag":"geosite-cn","format":"binary","path":"%s/rules/geosite-cn/geosite-cn.srs"},{"type":"local","tag":"geosite-new","format":"binary","path":"%s/rules/geosite-new/geosite-new.srs"}]}}' "$H" "$H" > "$H/config.json"
eq "新增一个 .srs 并且配置引用了它 (启用了这个规则集): 指纹变" "$(fp_same "$F0")" "changed"
F1=$(enhanced_fingerprint); printf 'o' > "$H/rules/geosite-new/geosite-new.srs"
eq "…被引用的 .srs 内容变了: 指纹变 (必须完整安装)" "$(fp_same "$F1")" "changed"
printf 'not json' > "$H/config.json"; F1=$(enhanced_fingerprint); mkdir -p "$H/rules/geosite-other"; printf 'p' > "$H/rules/geosite-other/geosite-other.srs"
eq "配置读不懂 (root 那边反正会拒绝): 退回全部规则文件都算, 新增的 .srs 照样让指纹变" "$(fp_same "$F1")" "changed"
reset; F0=$(enhanced_fingerprint); mkdir -p "$H/certs"; printf 'cert' > "$H/certs/a.crt"
eq "新增 / 改动证书: 指纹变" "$(fp_same "$F0")" "changed"
reset; printf '{"a":1,"clash_api":{"default_mode":"Direct"}}' > "$H/config.json"; F0=$(enhanced_fingerprint)
printf '{"a":1,"clash_api":{"default_mode":"Global"}}' > "$H/config.json"
eq "config.json 只有 default_mode 变了 (总开关 / 模式切换会改写它): 指纹不变" "$(fp_same "$F0")" "same"
printf '{"a":2,"clash_api":{"default_mode":"Global"}}' > "$H/config.json"
eq "config.json 别的内容变了: 指纹变" "$(fp_same "$F0")" "changed"
printf '{"a":1,"clash_api":{"default_mode":"Global"}}' > "$H/config.json"; F1=$(enhanced_fingerprint); AUTOSTART=0
eq "开机自启设置变了: 指纹变 (守护进程的 plist 不同)" "$(fp_same "$F1")" "changed"; AUTOSTART=1
reset; F0=$(enhanced_fingerprint)
printf 'x' > "$H/rules/geosite-old.srs"; printf 'x' > "$H/rules/ovr-old.json"
eq "升级前平铺在 rules/ 下的 .srs / ovr-*.json 新增: 指纹不变 (升级复制到子目录后会删掉它们, 不能触发完整安装)" "$(fp_same "$F0")" "same"
printf 'y' > "$H/rules/geosite-old.srs"; rm -f "$H/rules/ovr-old.json"
eq "…平铺文件内容改了 / 删掉了: 指纹仍不变" "$(fp_same "$F0")" "same"
rm -f "$H/rules/geosite-old.srs"
eq "…平铺文件全部删掉: 指纹仍不变" "$(fp_same "$F0")" "same"
# Windows 的指纹 (没有免密助手, 策略规则集仍然计入): 同样不受 .updated / default_mode 影响, 真正的变化仍然计入
(
  eval "$(sed -n '/^enhanced_fingerprint()/,/^}/p' "$LIB/enhanced-windows.sh")"
  command -v sha256sum >/dev/null 2>&1 || { printf '#!/bin/sh\nexec shasum -a 256 "$@"\n' > "$W/bin/sha256sum"; chmod +x "$W/bin/sha256sum"; PATH="$W/bin:$PATH"; }
  mkdir -p "$H/windows"; printf 'a' > "$H/windows/tun.ps1"; printf 'b' > "$H/windows/common.ps1"; reset
  printf '{"a":1,"clash_api":{"default_mode":"Direct"}}' > "$H/config.json"; printf '1\n' > "$H/rules/.updated"; F0=$(enhanced_fingerprint)
  printf '2\n' > "$H/rules/.updated"; printf '{"a":1,"clash_api":{"default_mode":"Rule"}}' > "$H/config.json"; printf 'x' > "$H/rules/geosite-cn/geosite-cn.srs.new"
  eq "Windows 指纹: .updated / default_mode / *.new 变了, 指纹不变" "$(fp_same "$F0")" "same"
  printf 'y' > "$H/rules/geosite-cn/geosite-cn.srs"
  eq "Windows 指纹: .srs 变了, 指纹变" "$(fp_same "$F0")" "changed"
  reset; printf '{"a":1}' > "$H/config.json"; F0=$(enhanced_fingerprint); ovr other.example
  eq "Windows 指纹: 策略规则集 (ovr-*.json) 变了, 指纹变 (Windows 没有免密助手, 仍需要完整安装)" "$(fp_same "$F0")" "changed"
  reset; printf '{"a":1}' > "$H/config.json"; F0=$(enhanced_fingerprint)
  printf 'x' > "$H/rules/geosite-old.srs"; printf 'x' > "$H/rules/ovr-old.json"
  eq "Windows 指纹: 升级前平铺的 .srs / ovr-*.json 新增, 指纹不变 (升级会把它们删掉)" "$(fp_same "$F0")" "same"
  rm -f "$H/rules/geosite-old.srs" "$H/rules/ovr-old.json"
  eq "Windows 指纹: 平铺文件删掉后仍不变" "$(fp_same "$F0")" "same"
)

echo "== T5c. 指纹: 网站的域名列表 (rules/site-<id>/site-<id>.json) 只算进策略指纹, 而且只算配置引用到的; 别处的同名文件不算网站的域名列表"
site_cfg() { # 配置引用 geosite-cn 和给出的 rules/<目录>/<文件>
  local extra='' rel
  for rel in "$@"; do extra="$extra,{\"type\":\"local\",\"tag\":\"x-${rel##*/}\",\"format\":\"source\",\"path\":\"$H/$rel\"}"; done
  printf '{"fixed":"config","route":{"rule_set":[{"type":"local","tag":"geosite-cn","format":"binary","path":"%s/rules/geosite-cn/geosite-cn.srs"}%s]}}' "$H" "$extra" > "$H/config.json"
}
site_file() { mkdir -p "$H/rules/${1%/*}"; printf '{"version":3,"rules":[{"domain_suffix":["%s"]}]}\n' "$2" > "$H/rules/$1"; }      # site_file <目录/文件> <域名>
reset; site_file site-claude/site-claude.json claude.ai; site_file site-gone/site-gone.json gone.example
site_cfg rules/site-claude/site-claude.json; F0=$(enhanced_fingerprint); O0=$(enhanced_ovr_fingerprint)
eq "要同步的网站域名列表 (enhanced_site_files): 只有配置引用到的 site-claude, 没有不被引用的 site-gone" "$(enhanced_site_files | paste -sd, -)" "rules/site-claude/site-claude.json"
eq "…数据包里有 site-claude.json 和策略规则集, 没有 site-gone.json" "$(enhanced_ovr_bundle | python3 -c 'import json,sys; print(",".join(sorted(json.load(sys.stdin))))')" "ovr-pin.json,site-claude.json"
site_file site-claude/site-claude.json changed.example
eq "改了被引用的域名列表: 核心指纹不变 (不重装), 策略指纹变 (助手同步)" "$([ "$(enhanced_fingerprint)" = "$F0" ] && echo core-same):$([ "$(enhanced_ovr_fingerprint)" != "$O0" ] && echo ovr-changed)" "core-same:ovr-changed"
O1=$(enhanced_ovr_fingerprint); site_file site-gone/site-gone.json other.example
eq "改了没被引用的 site-gone.json (目录里删掉的网站留下的): 两个指纹都不变" "$([ "$(enhanced_fingerprint)" = "$F0" ] && echo core-same):$([ "$(enhanced_ovr_fingerprint)" = "$O1" ] && echo ovr-same)" "core-same:ovr-same"
reset; site_file odd/site-odd.json odd.example; site_file site-Up/site-Up.json up.example
site_cfg rules/odd/site-odd.json rules/site-Up/site-Up.json; F0=$(enhanced_fingerprint); O0=$(enhanced_ovr_fingerprint)
site_file odd/site-odd.json odd2.example; site_file site-Up/site-Up.json up2.example
eq "位置或名字不对的 site-*.json (rules/odd/site-odd.json、大写的 site-Up) 被引用时: 不当作网站的域名列表, 改动算进核心指纹 (完整安装), 也不进数据包" "$([ "$(enhanced_fingerprint)" != "$F0" ] && echo core-changed):$([ "$(enhanced_ovr_fingerprint)" = "$O0" ] && echo ovr-same):$(enhanced_site_files | wc -l | tr -d ' ')" "core-changed:ovr-same:0"
reset

echo "== T4b. 只是记账内容 / 总开关模式变了: 不重启核心 (= 不弹管理员密码框); 真的变了才重启"
(
  gen_config() { printf '{"fixed":"config",%s,"clash_api":{"default_mode":"%s"}}' "$RS" "$(proxy_clash_mode)" > "$H/config.json.new"; }
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
  gen_config() { printf '{"fixed":"config","servers":2,%s,"clash_api":{"default_mode":"%s"}}' "$RS" "$(proxy_clash_mode)" > "$H/config.json.new"; }
  _proxy_set PROXY_ENABLED 1; RESTARTS=0
  apply_config
  eq "default_mode 和别的内容一起变了: 必须完整安装" "$RESTARTS" "1"
  reset; state; printf 'z' > "$H/rules/geosite-cn/geosite-cn.srs"; printf '3\n' > "$H/rules/.updated"; RESTARTS=0
  apply_config
  eq ".updated 和 .srs 一起变了 (每日更新真的下载到新规则): 必须完整安装" "$RESTARTS" "1"
)

echo "== T6. 重启核心 (os_service_restart): 指纹没变 + 助手可信 → 用助手重启, 不弹管理员密码框; 其它情形走完整安装"
(
  eval "$(sed -n '/^os_service_restart()/,/^}/p' "$LIB/os-darwin.sh")"        # 前面把它换成了只计数的假函数; 这里要跑真实的那个
  FULL=0; SYS=0
  os_service_start() { FULL=$((FULL + 1)); return 0; }
  os_system_service_restart() { SYS=$((SYS + 1)); return 0; }
  gen_config() { printf '{"fixed":"config","inbounds":[{"type":"tun"}],%s}' "$RS" > "$H/config.json.new"; }
  lc() { cat "$W/lc.calls" 2>/dev/null; }
  fresh() { reset; install_helper; : > "$W/lc.calls"; rm -f "$W/lc-fail"; FULL=0; SYS=0; }
  fresh
  os_service_restart; rc=$?
  eq "TUN 已安装 + 配置 / 规则没变 + 助手可信: 返回 0, 完整安装一次都没走" "$rc:$FULL" "0:0"
  eq "…助手只做了一件事: kickstart -k 这个用户自己的守护进程" "$(lc)" "kickstart -k system/$LBL"
  hs "…操作记录写明是助手重启" "重启核心方式	mode=tun via=helper	ok" "$(ops)"
  hs "…sudo 调用的是助手本身 (写死的 root 路径, 新位置), 带 restart 参数, 而且是 -n (不等密码)" "^sudo -n /Library/PrivilegedHelperTools/com\.enana\.proxy/tunrules-$ME restart" "$(cat "$FAKE_STATE/calls.log" 2>/dev/null)"
  fresh; ovr changed.example
  os_service_restart
  eq "还有没同步的应用 / 网站策略: 先同步进 root 快照, 再用助手重启 (仍然不走完整安装)" "$FULL:$(grep -c changed.example "$W/snap/rules/ovr-pin/ovr-pin.json"):$(lc)" "0:1:kickstart -k system/$LBL"
  reset; : > "$W/lc.calls"; FULL=0
  os_service_restart
  eq "助手还没装 (旧版本升级后的第一次): 走完整安装, 不调用助手" "$FULL:$(lc)" "1:"
  hs "…操作记录写明原因 no-helper" "重启核心方式	mode=tun via=admin why=no-helper	ok" "$(ops)"
  fresh; mkhelper "$W/helper-v1.pl" 1; cp "$W/helper-v1.pl" "$(enhanced_helper_path)"
  os_service_restart
  eq "助手是旧版本 (版本 1, 没有 restart): 视为不可用, 走完整安装 (装上新版本)" "$FULL:$(lc)" "1:"
  fresh; printf 'changed' > "$H/rules/geosite-cn/geosite-cn.srs"
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
  enhanced_loaded() { return 0; }; eval "$(sed -n '/^enhanced_configured()/p' "$LIB/enhanced.sh")"      # 换回 TUN 已安装、正在运行 (上面最后一个用例把它们换掉了)
  gen_config() { printf '{"fixed":"config","inbounds":[{"type":"tun"}]}' > "$H/config.json.new"; }
  # 2.3.23 及更早版本装在 /usr/local/libexec/enana 的助手 (升级上来、还没完整安装过): 通过同样严格的检查就照常用, sudo -n 调用旧位置的路径 (免密规则写的就是它)
  LEGACY=$W/root/usr/local/libexec/enana/tunrules-$ME
  install_legacy() { mkdir -p "${LEGACY%/*}" "$FAKE_SUDOERS_DIR"; chmod 755 "$W/root/usr" "$W/root/usr/local" "$W/root/usr/local/libexec" "${LEGACY%/*}"; helper_bytes > "$LEGACY"; chmod 755 "$LEGACY"; printf '%s ALL=(root) NOPASSWD: %s\n' "$(id -un)" "$LEGACY" > "$FAKE_SUDOERS_DIR/enana-tunrules-$ME"; }
  reset; install_legacy; : > "$W/lc.calls"; rm -f "$W/lc-fail"; FULL=0; SYS=0; : > "$FAKE_STATE/calls.log"
  eq "(准备) 只有旧位置有助手, 它可信: enhanced_helper_root 给出旧位置的写死路径" "$(enhanced_helper_root)" "/usr/local/libexec/enana/tunrules-$ME"
  os_service_restart; rc=$?
  eq "只有旧位置的助手: 照样用它重启, 不走完整安装 (不弹管理员密码框)" "$rc:$FULL:$(lc)" "0:0:kickstart -k system/$LBL"
  hs "…sudo -n 调用的是旧位置的写死路径" "^sudo -n /usr/local/libexec/enana/tunrules-$ME restart" "$(cat "$FAKE_STATE/calls.log" 2>/dev/null)"
  reset; install_legacy; ovr legacy.example; : > "$W/lc.calls"; FULL=0
  os_service_restart
  eq "…还有没同步的策略: 也用旧位置的助手先同步, 再重启" "$FULL:$(grep -c legacy.example "$W/snap/rules/ovr-pin/ovr-pin.json"):$(lc)" "0:1:kickstart -k system/$LBL"
  reset; install_legacy; chmod 775 "$W/root/usr/local"; : > "$W/lc.calls"; FULL=0
  os_service_restart
  eq "旧位置的目录链不合格 (/usr/local 组可写, 老的 Homebrew 会这样): 不用它, 走完整安装 (那次授权把助手装到新位置)" "$FULL:$(lc)" "1:"
  chmod 755 "$W/root/usr/local"
)

echo "== T7. 停止已经停掉的守护进程不要管理员授权 (stop 之后 plist 还在; 更完整的覆盖在 tests/enhanced.sh)"
(
  eval "$(sed -n -e '/^enhanced_idle()/,/^}/p' -e '/^enhanced_stop()/,/^}/p' "$LIB/enhanced.sh")"        # 真实的函数 (前面没有换成假的, 这里只换掉特权调用和 launchd)
  ADMIN=0; enhanced_admin() { ADMIN=$((ADMIN + 1)); LOADED=0; return 0; }       # 和真的 root stop 一样: 停掉之后守护进程就不在 launchd 里了
  enhanced_paths() { TUN_UID=501; TUN_LABEL=com.enana.proxy.tun.501; TUN_ROOT="$W/stop-root"; TUN_PLIST="$W/stop.plist"; }; : > "$W/stop.plist"
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
) || tfail "T7 没有跑完 (子 shell 中途退出: 后面的断言都没有运行)"

echo "== T8. 内容没变的订阅刷新不改动 servers.jsonl (否则文件顺序变 → 配置变 → 核心重启, TUN 下还要管理员授权)"
(
  SF="$H/servers.jsonl"
  m() { printf '{"role":"auto","outbound":{"type":"trojan","tag":"%s","server":"%s.example","server_port":443,"password":"pw"}}\n' "$1" "$1"; }
  s() { printf '{"role":"auto","sub":"%s","outbound":{"type":"trojan","tag":"%s","server":"%s.example","server_port":443,"password":"pw"}}\n' "$1" "$2" "$2"; }
  tags() { sed -n 's/.*"tag":"\([^"]*\)".*/\1/p' "$SF" | paste -sd, -; }
  { m M1; s A A1; s A A2; s B B1; m M2; s B B2; } > "$SF"; cp "$SF" "$W/before"
  r1=$({ s A A1; s A A2; } | srv_import A replace); r2=$({ s B B1; s B B2; } | srv_import B replace)
  eq "两个订阅和手动服务器交错, 内容相同的刷新: servers.jsonl 一个字节没变 (计数: 0 新增 · 2 保留 · 0 移除 · 0 有变化 · 2 未变)" "$(cmp -s "$SF" "$W/before" && echo same || echo changed):$r1:$r2" "same:0 2 0 0 2:0 2 0 0 2"
  { s A A1; s A A3; } | srv_import A replace >/dev/null
  eq "订阅 A 换了一个节点: A2 消失, A3 追加到末尾, 其它每个节点的位置不变" "$(tags)" "M1,A1,B1,M2,B2,A3"
)

echo "== T9. 残留 TUN 路由清理 (cleanup): 只删网关是 enana 的 TUN 地址、接口是没有 IPv4 的 utun 的路由; 守护进程或核心在运行时什么都不删"
(
  CW=$W/cleanup; rm -rf "$CW"; mkdir -p "$CW/bin"
  cat > "$CW/bin/netstat" <<NS
#!/bin/sh
case "\$3" in inet) cat "$CW/netstat.inet" ;; inet6) cat "$CW/netstat.inet6" ;; esac
NS
  cat > "$CW/bin/ifconfig" <<IF
#!/bin/sh
cat "$CW/ifconfig.\$1" 2>/dev/null
IF
  cat > "$CW/bin/route" <<RT
#!/bin/sh
echo "\$*" >> "$CW/route.calls"
grep -qxF -- "\$*" "$CW/route.fail" 2>/dev/null && exit 1
exit 0
RT
  cat > "$CW/bin/ps" <<PS
#!/bin/sh
cat "$CW/ps.out" 2>/dev/null
PS
  cat > "$CW/bin/launchctl-mock" <<LC
#!/bin/sh
if [ "\$1" = print ] && [ -f "$CW/daemon.running" ]; then printf '\tpid = 123\n'; fi
exit 0
LC
  chmod +x "$CW"/bin/*
  mkhelper "$CW/raw.pl" "" "" "$CW/bin/launchctl-mock"
  sed -e "s|/usr/sbin/netstat|$CW/bin/netstat|g" -e "s|'/sbin/ifconfig'|'$CW/bin/ifconfig'|g" -e "s|'/sbin/route'|'$CW/bin/route'|g" -e "s|'/bin/ps'|'$CW/bin/ps'|g" "$CW/raw.pl" > "$CW/helper.pl"
  eq "测试副本里的系统命令都已换成假的 (没有残留的真命令路径)" "$(grep -cF -e '/usr/sbin/netstat' -e "'/sbin/ifconfig'" -e "'/sbin/route'" -e "'/bin/ps'" "$CW/helper.pl")" "0"
  cc() { # 运行助手的一个子命令 → 退出码|输出|route 调用
    local rc=0 out
    : > "$CW/route.calls"
    out=$(perl "$CW/helper.pl" "$@" 2>&1) || rc=$?
    printf '%s|%s|%s\n' "$([ "$rc" = 0 ] && echo 0 || echo fail)" "$out" "$(paste -sd';' "$CW/route.calls")"
  }
  scene() { # 夹具: enana 的残留路由 (0/1 重复一行, utun9 没有 IPv4) · 默认路由 (en0) · 别的 VPN (utun2 经 10.8.0.1)
    rm -f "$CW/route.fail" "$CW/daemon.running" "$CW/ps.out"
    cat > "$CW/netstat.inet" <<'T'
Destination        Gateway            Flags        Netif Expire
default            192.168.1.1        UGScg          en0
0/1                172.19.0.1         UGSc         utun9
0/1                172.19.0.1         UGSc         utun9
128.0.0.0/1        172.19.0.1         UGSc         utun9
10.0.0.0/8         10.8.0.1           UGSc         utun2
T
    cat > "$CW/netstat.inet6" <<'T'
Destination                             Gateway                        Flags        Netif Expire
::/1                                    fdfe:dcba:9876::1              UGSc         utun9
8000::/1                                fdfe:dcba:9876::1              UGSc         utun9
T
    cat > "$CW/ifconfig.utun9" <<'T'
utun9: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1380
  inet6 fe80::1234:5678:9abc:def0%utun9 prefixlen 64 scopeid 0x12
T
    cat > "$CW/ifconfig.utun2" <<'T'
utun2: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1380
  inet 10.8.0.2 --> 10.8.0.1 netmask 0xff000000
T
  }
  four="-n delete -net 0.0.0.0/1 172.19.0.1;-n delete -net 128.0.0.0/1 172.19.0.1;-n delete -inet6 ::/1 fdfe:dcba:9876::1;-n delete -inet6 8000::/1 fdfe:dcba:9876::1"
  scene; eq "残留的 enana 路由 (IPv4 的 0/1 与 128/1, IPv6 的 ::/1 与 8000::/1; 重复行只删一次) 全部删掉; 默认路由 (en0) 和别的 VPN (utun2, 经 10.8.0.1) 不动" "$(cc cleanup)" "0|removed 4, kept 0, failed 0|$four"
  scene; printf '  inet 172.19.0.1 --> 172.19.0.2 netmask 0xfffffffc\n' >> "$CW/ifconfig.utun9"
  eq "同一个 utun 上还有 IPv4 地址 (说明仍在使用): 一条都不删" "$(cc cleanup)" "0|removed 0, kept 4, failed 0|"
  scene; touch "$CW/daemon.running"
  eq "守护进程还在运行: 拒绝, 什么都不删" "$(cc cleanup)" "fail|daemon running|"
  scene; printf '%s/sing-box run -c %s/config.json\n' "$W/snap" "$W/snap" > "$CW/ps.out"
  eq "enana 自己的核心 (根快照里的 sing-box) 在运行: 拒绝, 什么都不删" "$(cc cleanup)" "fail|core running|"
  scene; printf '/Applications/enana.app/Contents/Resources/sing-box run -c /Users/x/config.json\n' > "$CW/ps.out"
  eq "用户另外装的 sing-box (不在 enana 的根快照里) 不影响清理" "$(cc cleanup)" "0|removed 4, kept 0, failed 0|$four"
  scene; printf -- '-n delete -net 128.0.0.0/1 172.19.0.1\n' > "$CW/route.fail"
  eq "某条路由删除失败: 其余照常删, 退出码非零 (报告失败, 不静默)" "$(cc cleanup)" "fail|removed 3, kept 0, failed 1|$four"
  scene; printf 'Destination Gateway Flags Netif Expire\ndefault 192.168.1.1 UGScg en0\n' > "$CW/netstat.inet"; : > "$CW/netstat.inet6"
  eq "没有任何残留路由 (正常断开后的状态): 什么也不做, 成功" "$(cc cleanup)" "0|removed 0, kept 0, failed 0|"
  scene; eq "多余的参数: 拒绝 (用法提示), 不删任何路由" "$(cc cleanup extra)" "fail|usage: tunrules sync|restart|cleanup|version|"
  eq "未知的子命令 (cleanupx): 拒绝, 不删任何路由" "$(cc cleanupx)" "fail|usage: tunrules sync|restart|cleanup|version|"
)

echo "== T10. 真实生成的配置 (TUN): 改网站域名 / 添加、删除自己的网站 / 改线路 / 恢复网站默认 → 配置一个字节不变, 只经助手免密同步 (不重装 = 不弹管理员框); 服务器变了 → 完整安装"
(
  . "$LIB/config.sh"; . "$LIB/apps.sh"; . "$LIB/autosites.sh"; . "$LIB/sites.sh"        # 真实的 gen_config / apply_config / ovr_sync / sites_edit (前面的用例把其中几个换成了假的)
  eval "$(sed -n '/^os_service_restart()/,/^}/p' "$LIB/os-darwin.sh")"
  core_version() { echo 1.14.2; }
  _apply_step() { :; }; wait_port() { return 0; }; proxy_sync_mode() { :; }; clash() { return 0; }; sysproxy_off_if_core_down() { :; }
  os_service_loaded() { return 0; }; os_service_pid() { echo 1; }; enhanced_ready() { return 0; }; enhanced_loaded() { return 0; }
  SYS=0; os_system_service_restart() { SYS=$((SYS + 1)); return 0; }
  snap_install() { # 和 root 的完整安装一样 (lib/enhanced-root.sh 的 c 步): 快照的 rules 整个换成 enana 这边 rules/<目录>/<文件> 的副本
    local rel; rm -rf "$W/snap/rules"; mkdir -p "$W/snap/rules"
    ( cd "$H" && find rules -mindepth 2 -maxdepth 2 -type f ) | while IFS= read -r rel; do mkdir -p "$W/snap/${rel%/*}"; cp "$H/$rel" "$W/snap/$rel"; done
  }
  FULL=0; os_service_start() { FULL=$((FULL + 1)); snap_install; install_helper; enhanced_record_install; return 0; }   # 完整安装 (要管理员授权) 的替身: 换上快照和新助手, 记下指纹
  fresh_log() { rm -f "$LOGS"/ops-*.log; : > "$FAKE_STATE/calls.log"; }
  cfg_sum() { shasum -a 256 < "$H/config.json" | awk '{print $1}'; }
  in_snap() { local f="$W/snap/rules/${1%.json}/$1"; [ -f "$f" ] || { echo missing; return; }; grep -c "\"$2\"" "$f"; }      # in_snap <文件> <域名>: 根快照里这个文件有没有这个值
  syncs() { ops | grep -c '同步策略规则	mode=tun via=helper restart=no	ok'; }
  restarts() { ops | grep -c '重启核心'; }                                                     # 每一次重启核心都会先记一笔「重启核心」(core_restart_note)
  admin() { grep -cE 'enana-root|osascript|/bin/sh -c' "$FAKE_STATE/calls.log"; }               # 管理员命令 (完整安装 / 停止都走这里) 一次都没有出现
  helper_syncs() { grep -c "^sudo -n /Library/PrivilegedHelperTools/com.enana.proxy/tunrules-$ME sync$" "$FAKE_STATE/calls.log"; }
  txn() { op_txn "$@" >/dev/null 2>&1; }
  rm -rf "$H/rules" "$W/snap/rules" "$LOGS" "$H/cloud" "$H/backups"; rm -f "$H/config.json" "$H/config.json.bak" "$H/overrides.tsv" "$H/site-domains.tsv" "$H/autosites.tsv" "$H/autosites.dismissed"
  mkdir -p "$H/rules" "$LOGS" "$H/cloud/content"
  # 云端下发的目录: 自带的基线 + 一个和这次反馈里一样的条目 (ai-common, 删 intercom.io / auth0.com 那次要了管理员密码); 它还带了要被整理掉的写法 (大写 / 不合法的名字)
  { cat "$REPO/data/services.conf"; printf 'ai-common|AI 通用|ai|pin|intercom.io,auth0.com,.cdn.example,Bad_Name.example,OpenAI.Example|||测试条目\n'; } > "$H/cloud/content/services.conf"
  NSITES=$(awk '!/^[ \t]*(#|$)/' "$H/cloud/content/services.conf" | wc -l | tr -d ' ')
  printf '%s\n' '{"role":"pin","outbound":{"type":"socks","tag":"Pin-A","server":"127.0.0.1","server_port":1}}' > "$H/servers.jsonl"
  printf 'NETWORK_MODE=tun\n' > "$H/settings.env"; load_settings; fresh_log
  apply_config; rc=$?
  eq "(准备) 第一次应用 = 一次完整安装 (要管理员授权): 快照里有每个网站的域名列表 ($NSITES 个)" "$rc:$FULL:$(ls -d "$W"/snap/rules/site-* | wc -l | tr -d ' ')" "0:1:$NSITES"
  eq "…配置里没有任何网站的域名, 每个网站一条 rule_set site-<id> → svc-<id>" "$(grep -cE 'claude\.ai|intercom\.io' "$H/config.json"):$(grep -o '"rule_set":\["site-[a-z0-9-]*"\],"action":"route","outbound":"svc-' "$H/config.json" | wc -l | tr -d ' ')" "0:$NSITES"
  eq "…ai-common 的域名列表: 小写, 只留合法的名字 (.cdn.example 只匹配子域名, Bad_Name.example 去掉)" "$(python3 -c 'import json,sys; print(",".join(json.load(open(sys.argv[1]))["rules"][0]["domain_suffix"]))' "$W/snap/rules/site-ai-common/site-ai-common.json")" "intercom.io,auth0.com,.cdn.example,openai.example"
  C0=$(cfg_sum); FULL=0; fresh_log
  txn "修改网站域名" txn_site_domain ai-common remove intercom.io; rc=$?
  eq "改网站域名 (ai-common 删掉 intercom.io): 成功, 没有完整安装, 也没有重启核心" "$rc:$FULL:$(restarts)" "0:0:0"
  eq "…配置一个字节没变" "$(cfg_sum)" "$C0"
  eq "…root 快照里的列表已经去掉 intercom.io (核心热加载), auth0.com 还在" "$(in_snap site-ai-common.json intercom.io):$(in_snap site-ai-common.json auth0.com)" "0:1"
  eq "…经助手免密同步 (sudo -n 助手 sync 一次), 没有任何管理员命令" "$(syncs):$(helper_syncs):$(admin)" "1:1:0"
  fresh_log; txn "修改网站域名" txn_site_domain ai-common remove auth0.com; txn "修改网站域名" txn_site_domain claude add new-claude.example
  eq "再删 auth0.com、给 Claude 添加 new-claude.example: 两次都只经助手同步, 配置不变" "$FULL:$(syncs):$(admin):$(in_snap site-ai-common.json auth0.com):$(in_snap site-claude.json new-claude.example):$([ "$(cfg_sum)" = "$C0" ] && echo same)" "0:2:0:0:1:same"
  fresh_log; txn "修改网站域名" txn_site_domain claude update new-claude.example renamed-claude.example
  eq "修改域名 (new-claude.example → renamed-claude.example): 只经助手同步" "$FULL:$(syncs):$(in_snap site-claude.json new-claude.example):$(in_snap site-claude.json renamed-claude.example)" "0:1:0:1"
  fresh_log; txn "重置网站域名" txn_site_reset ai-common
  eq "重置一个网站的域名: 回到系统默认, 只经助手同步" "$FULL:$(syncs):$(in_snap site-ai-common.json intercom.io):$(in_snap site-ai-common.json auth0.com)" "0:1:1:1"
  fresh_log; txn "修改应用/网站策略" txn_override site my-site.example pin ''
  eq "添加自己的网站 (走固定出口): 只经助手同步, 配置不变" "$FULL:$(syncs):$(admin):$(in_snap ovr-pin.json my-site.example):$([ "$(cfg_sum)" = "$C0" ] && echo same)" "0:1:0:1:same"
  fresh_log; txn "修改应用/网站策略" txn_override site my-site.example direct ''
  eq "改线路 (固定出口 → 直连): 只经助手同步" "$FULL:$(syncs):$(in_snap ovr-direct.json my-site.example):$(in_snap ovr-pin.json my-site.example)" "0:1:1:0"
  fresh_log; txn "修改应用/网站策略" txn_override site my-site.example auto ''
  eq "改线路 (直连 → 自动线路): 只经助手同步" "$FULL:$(syncs):$(in_snap ovr-auto.json my-site.example):$(in_snap ovr-direct.json my-site.example)" "0:1:1:0"
  fresh_log; txn "修改应用/网站策略" txn_override site my-site.example follow ''
  eq "删除自己的网站: 只经助手同步, 快照里哪个规则集都没有它了" "$FULL:$(syncs):$(cat "$W"/snap/rules/ovr-*/ovr-*.json | grep -c my-site.example)" "0:1:0"
  txn "修改网站域名" txn_site_domain claude add before-reset.example; txn "修改应用/网站策略" txn_override site reset-me.example direct ''
  reset_selector_diff() { :; }; fresh_log; txn "恢复网站默认" txn_sites_reset
  eq "恢复网站默认 (清掉域名改动和自己的网站): 只经助手同步, 配置不变" "$FULL:$(syncs):$(admin):$(in_snap site-claude.json before-reset.example):$(in_snap ovr-direct.json reset-me.example):$([ "$(cfg_sum)" = "$C0" ] && echo same)" "0:1:0:0:0:same"
  fresh_log; APPS_BG_JOB=1 OP_WHO=auto txn "修改网站域名" txn_site_domain claude add bg.example; rc=$?
  eq "后台任务 (APPS_BG_JOB=1, 从不弹管理员框) 改域名: 照常生效, 不会被撤销" "$rc:$FULL:$(syncs):$(in_snap site-claude.json bg.example)" "0:0:1:1"
  printf '%s\n' '{"role":"auto","outbound":{"type":"socks","tag":"Auto-B","server":"127.0.0.1","server_port":2}}' >> "$H/servers.jsonl"
  fresh_log; APPS_BG_JOB=1 apply_config; rc=$?
  eq "服务器列表变了, 后台任务: 返回 5 (要管理员授权, 不弹框), 什么都没装, 配置不变" "$rc:$FULL:$([ "$(cfg_sum)" = "$C0" ] && echo same)" "5:0:same"
  fresh_log; apply_config; rc=$?
  eq "服务器列表变了 (用户操作): 完整安装一次 (要管理员授权)" "$rc:$FULL:$(syncs)" "0:1:0"
  hs "…操作记录写明走的是授权安装, 原因 changed" "重启核心方式	mode=tun via=admin why=changed" "$(ops)"
  C0=$(cfg_sum); FULL=0; fresh_log; txn "修改网站域名" txn_site_domain claude add after-servers.example
  eq "…之后改域名又是免密的" "$FULL:$(syncs):$(in_snap site-claude.json after-servers.example)" "0:1:1"
  rm -f "$FAKE_SUDOERS_DIR"/*; fresh_log; txn "修改网站域名" txn_site_domain claude add no-helper.example; rc=$?
  eq "助手不可用 (免密规则不在了): 退回完整安装 (授权一次), 改动照样生效" "$rc:$FULL:$(in_snap site-claude.json no-helper.example)" "0:1:1"
  hs "…操作记录写明 no-helper" "同步策略规则	mode=tun via=helper restart=yes err=no-helper" "$(ops)"
  rm -f "$W/snap/rules/site-claude/site-claude.json"; FULL=0; fresh_log; txn "修改网站域名" txn_site_domain claude add refused.example; rc=$?
  eq "助手拒绝 (root 快照里没有 site-claude.json): 退回完整安装, 不会假装成功" "$rc:$FULL:$(in_snap site-claude.json refused.example)" "0:1:1"
  hs "…操作记录写明 rejected" "同步策略规则	mode=tun via=helper restart=yes err=rejected" "$(ops)"
  # 2.3.25 的 TUN 快照: 域名直接写在配置里 (没有 site-* 规则集), 根助手是第 4 版 (字节和现在渲染出来的不同: 不可信)
  python3 - "$H/config.json" "$H" <<'PY'
import json, sys
cfg, home = sys.argv[1:]
c = json.load(open(cfg)); r = c["route"]; sites = {}
for d in r["rule_set"]:
    if d["tag"].startswith("site-"): sites[d["tag"]] = json.load(open(d["path"]))["rules"][0]
r["rule_set"] = [d for d in r["rule_set"] if not d["tag"].startswith("site-")]
out = []
for x in r["rules"]:
    t = (x.get("rule_set") or [""])[0]
    if t in sites:
        if "domain_suffix" in sites[t]: out.append({"domain_suffix": sites[t]["domain_suffix"], "action": "route", "outbound": x["outbound"]})
    else: out.append(x)
r["rules"] = out
open(cfg, "w").write(json.dumps(c, separators=(",", ":")) + "\n")
PY
  rm -rf "$H"/rules/site-*; snap_install; mkhelper "$(enhanced_helper_path)" 4; enhanced_record_install
  eq "(准备) 2.3.25 的快照: 配置里写着域名, 没有 site-* 规则集, 快照里也没有" "$(grep -c '"claude.ai"' "$H/config.json"):$(grep -c 'site-claude' "$H/config.json"):$(ls -d "$W"/snap/rules/site-* 2>/dev/null | wc -l | tr -d ' ')" "1:0:0"
  FULL=0; fresh_log; txn "修改网站域名" txn_site_domain claude add first-after-upgrade.example; rc=$?
  # 新配置: 恰好一条 site-claude 规则集定义和一条引用它的路由规则 (配置是一行一项, 定义和引用在不同的行, 所以不按行数数), 域名不再写在配置里
  eq "升级后第一次需要新配置的应用: 完整安装一次 (授权一次), 装上新的配置、域名列表和新助手" "$rc:$FULL:$(grep -o '"tag":"site-claude","format":"source"' "$H/config.json" | wc -l | tr -d ' '):$(grep -o '"rule_set":\["site-claude"\],"action":"route","outbound":"svc-claude"' "$H/config.json" | wc -l | tr -d ' '):$(grep -c '"claude.ai"' "$H/config.json"):$(in_snap site-claude.json first-after-upgrade.example)" "0:1:1:1:0:1"
  fresh_log; txn "修改网站域名" txn_site_domain claude add second-after-upgrade.example
  eq "…之后再改域名: 免密 (只经新助手同步, 没有再安装)" "$FULL:$(syncs):$(admin):$(in_snap site-claude.json second-after-upgrade.example)" "1:1:0:1"
  # 系统代理模式: 用户自己的核心直接读同一个文件 (热加载), 不涉及助手, 也不重启
  printf 'NETWORK_MODE=system\n' > "$H/settings.env"; load_settings; enhanced_loaded() { return 1; }
  apply_config >/dev/null 2>&1; SYS=0; FULL=0; C0=$(cfg_sum); fresh_log
  txn "修改网站域名" txn_site_domain claude add system-proxy.example; rc=$?
  eq "系统代理模式改域名: 成功, 配置不变, 核心没有重启, 没有助手同步 / 完整安装" "$rc:$([ "$(cfg_sum)" = "$C0" ] && echo same):$SYS:$FULL:$(restarts):$(helper_syncs)" "0:same:0:0:0:0"
  eq "…用户核心读的规则文件已经更新 (核心监视文件变化自己热加载)" "$(grep -c '"system-proxy.example"' "$H/rules/site-claude/site-claude.json")" "1"
  printf 'NETWORK_MODE=tun\n' > "$H/settings.env"
) || tfail "T10 没有跑完 (子 shell 中途退出: 后面的断言都没有运行)"

P=$(wc -l < "$W/.pass" | tr -d ' '); F=$(wc -l < "$W/.fail" | tr -d ' ')
echo; echo "tunrules.sh: $P passed, $F failed"; [ "$F" = 0 ]
