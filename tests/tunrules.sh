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
mkdir -p "$W/snap/rules"
# 助手的临时副本: 快照目录 / 目录归属 uid / 版本写成测试值 (生产里由 root 安装脚本写成真实路径和 0)
sed -e "s|@ROOT@|$W/snap|g" -e "s|@ROOTUID@|$ME|g" -e "s|@VERSION@|1|g" "$REPO/lib/tunrules-helper.pl" > "$W/helper.pl"
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
eq "version 输出版本号" "$(H version)" "1"
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
sed -e "s|@ROOT@|$W/snap|g" -e "s|@ROOTUID@|$((ME + 1))|g" -e "s|@VERSION@|1|g" "$REPO/lib/tunrules-helper.pl" > "$W/helper-other.pl"
printf '%s' '{"ovr-pin.json":{"version":3,"rules":[{"domain":["a"]}]}}' | perl "$W/helper-other.pl" sync >/dev/null 2>&1
eq "目录不归预期的 uid (生产里是 root): 拒绝" "$([ $? != 0 ] && echo rejected || echo accepted)" "rejected"
printf '%s' '{}' | H sync extra >/dev/null 2>&1; eq "多余参数: 拒绝" "$([ $? != 0 ] && echo rejected || echo accepted)" "rejected"
H bogus </dev/null >/dev/null 2>&1; eq "不认识的命令: 拒绝" "$([ $? != 0 ] && echo rejected || echo accepted)" "rejected"
H </dev/null >/dev/null 2>&1; eq "没有命令: 拒绝" "$([ $? != 0 ] && echo rejected || echo accepted)" "rejected"
sed -e "s|@ROOT@|$W/nonexistent|g" -e "s|@ROOTUID@|$ME|g" -e "s|@VERSION@|1|g" "$REPO/lib/tunrules-helper.pl" > "$W/helper-nodir.pl"
printf '%s' '{"ovr-pin.json":{"version":3,"rules":[{"domain":["a"]}]}}' | perl "$W/helper-nodir.pl" sync >/dev/null 2>&1
eq "快照里还没有规则集目录 (TUN 没装过): 拒绝, 不会凭空创建" "$([ $? != 0 ] && echo rejected || echo accepted):$([ -e "$W/nonexistent" ] && echo created || echo untouched)" "rejected:untouched"

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
state() { # 把「现状」记成基线: 配置 / 核心指纹 / 策略指纹
  cp "$H/config.json.new" "$H/config.json" 2>/dev/null || printf '{"fixed":"config"}' > "$H/config.json"
  enhanced_fingerprint > "$H/.enhanced-fingerprint"; enhanced_ovr_fingerprint > "$H/.enhanced-ovr-fingerprint"
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

P=$(wc -l < "$W/.pass" | tr -d ' '); F=$(wc -l < "$W/.fail" | tr -d ' ')
echo; echo "tunrules.sh: $P passed, $F failed"; [ "$F" = 0 ]
