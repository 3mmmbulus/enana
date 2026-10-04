#!/bin/bash
# 恢复官方默认规则 (lib/ops.sh 的 txn_reset_official / txn_reset_undo / reset_preview_json): 几秒钟, 不需要 sing-box / 真实云端 / 管理员权限, macOS 和 Linux 都能跑。
#   · 自己改过的规则全部清掉 (应用 / 网站策略、自动识别、规则集开关、自定义规则集 / 软件 / 域名 / 解析、DNS), 服务器 / 订阅 / 设置 / 偏好不动
#   · 云端官方内容强制重新下载 (签名校验): 就算序号没变, 本机缓存被改坏的内容也会换回官方的; 离线 / 没登录用本机已验证的内容, 一份都没有用随程序自带的基线
#   · 应用重新识别 (推荐值来自官方内容, 标记 def), 不会弹出一堆「新应用」
#   · 重置前备份 (最近 3 份), 可以撤销; 重置失败时整体回滚, 也不留下「可撤销」的假备份
# 云端用 _cloud_req 的函数替身 + 本机签名的内容包代替 (签名私钥是临时生成的, 公钥通过 ENANA_CLOUD_PUBKEY 交给客户端)。
set -u
HERE=$(cd "$(dirname "$0")" && pwd -P); REPO=$(dirname "$HERE")
W=$(mktemp -d /tmp/enana-reset.XXXXXX); W=$(cd "$W" && pwd -P)
trap 'rm -rf "$W"' EXIT; : > "$W/.pass"; : > "$W/.fail"
tpass() { echo p >> "$W/.pass"; echo "  ✓ $1"; }
tfail() { echo f >> "$W/.fail"; echo "  ✗ $1"; [ -n "${2:-}" ] && printf '      ↳ %s\n' "$(printf '%s' "$2" | head -c 700)"; return 0; }
eq()    { if [ "$2" = "$3" ]; then tpass "$1"; else tfail "$1" "期望 [$3] 实际 [$2]"; fi; }
has()   { if printf '%s\n' "$3" | grep -Eq -- "$2"; then tpass "$1"; else tfail "$1" "没有找到 /$2/ 于: $3"; fi; }
hasnt() { if ! printf '%s\n' "$3" | grep -Eq -- "$2"; then tpass "$1"; else tfail "$1" "不应出现 /$2/: $3"; fi; }
gone()  { if [ ! -e "$H/$2" ]; then tpass "$1"; else tfail "$1" "$2 还在"; fi; }
kept()  { if [ -s "$H/$2" ]; then tpass "$1"; else tfail "$1" "$2 没了"; fi; }

command -v perl >/dev/null && command -v python3 >/dev/null && [ -x /usr/bin/openssl ] || { echo "跳过: 需要 perl / python3 / openssl"; exit 77; }
export HOME=$W/home ENANA_HOME=$W/h LC_ALL=C ENANA_LANG=zh PORT=37890 UI_PORT=37891 API_PORT=37892 SPEED_PORT=37893 ENANA_PLATFORM=darwin ENANA_CLOUD_PUBKEY=$W/cpub.pem
mkdir -p "$HOME" "$ENANA_HOME"
. "$REPO/lib/common.sh"; init_paths "$REPO/install.sh"
LIB=$REPO/lib; DATA=$REPO/data
for _f in i18n jobs servers apps autosites sites fetch os-darwin enhanced auth device session cloud dns logs health update config ops speed stats prefs snapshot plan sync; do . "$LIB/$_f.sh"; done
load_settings; QUIET=1
[ "$H" = "$W/h" ] || { echo "REFUSING: 数据目录不是临时目录 ($H)"; exit 1; }

# ---- 替身: 不碰真实系统 / 网络
APPLY_RC=0; APPLIES=0; RS_UPDATES=0; ONLINE=1
apply_config() { APPLIES=$((APPLIES + 1)); APPLY_CHANGED=1; return "$APPLY_RC"; }
rules_update() { RS_UPDATES=$((RS_UPDATES + 1)); return 0; }
apps_installed() { printf 'Claude\t/Applications/Claude.app\nRandom Tool\t/Applications/Random Tool.app\nSafari\t/Applications/Safari.app\nWindsurf\t/Applications/Windsurf.app\n'; }
app_is_browser() { case $1 in *Safari*) return 0 ;; esac; return 1; }
os_birth_time() { echo 0; }
_cloud_req() { # <方法> <路径> <body> <输出文件> <头…>  -> 打印 HTTP 状态码; 路径 /v1/xxx 取本机 $W/v1/xxx
  [ "$ONLINE" = 1 ] || { printf '000'; return 0; }
  local f="$W/v1/${2#/v1/}"
  if [ -f "$f" ]; then cp "$f" "$4"; printf '200'; else printf '404'; fi
}

SEL=$W/sel.now
clash() { # 核心的 Clash API 替身: GET /proxies · PUT /proxies/<标签> {"name":"…"}; 开关当前的选择存在 $SEL (每行 标签=选择)
  case $1 in
    GET) awk -F= 'BEGIN { printf "{\"proxies\":{" } { printf "%s\"%s\":{\"now\":\"%s\"}", (NR > 1 ? "," : ""), $1, $2 } END { printf "}}" }' "$SEL" ;;
    PUT) local tag=${2#/proxies/} name; name=$(printf '%s' "$3" | sed 's/.*"name":"\([^"]*\)".*/\1/'); { grep -v "^$tag=" "$SEL" || true; echo "$tag=$name"; } > "$SEL.n"; mv "$SEL.n" "$SEL" ;;
  esac
}

/usr/bin/openssl ecparam -genkey -name prime256v1 -noout -out "$W/ckey.pem" 2>/dev/null; /usr/bin/openssl ec -in "$W/ckey.pem" -pubout -out "$W/cpub.pem" 2>/dev/null
mkdir -p "$W/v1"; bash "$REPO/tools/build-content-bundle.sh" "$HERE/fixtures/content" "$W/v1" "$W/ckey.pem" 100 >/dev/null
auth_logged_in() { [ -s "$H/cloud.token" ] && [ -s "$H/session" ]; }
login() { printf 'tok\n' > "$H/cloud.token"; printf 'sid\n' > "$H/session"; }
logout() { rm -f "$H/cloud.token" "$H/session"; }
JOB_ID=''; unset JOB_ID

# 一份「用户自己改过很多规则」的本机状态
customize() {
  printf 'app|Claude|direct|ack|\napp|Safari|direct|ack|\napp|Random Tool|pin|ack|PinNode\nsite|mine.example|pin|ack|PinNode\nsite|auto.example|pin|ack|PinNode\n' > "$H/overrides.tsv"
  printf 'auto.example|1700000000|timeout|2|Claude\n' > "$H/autosites.tsv"; printf 'dismissed.example\n' > "$H/autosites.dismissed"
  printf 'geosite-ai=0\ngeosite-ads=1\n' > "$H/rules.state"
  printf 'mylist|MyList|pin|1700000000|https://example.invalid/mylist.srs\n' > "$H/custom-rulesets.tsv"; mkdir -p "$H/rules"; printf 'SRS' > "$H/rules/custom-mylist.srs"
  printf 'My Tool|bin|/usr/local/bin/mytool||1700000000\n' > "$H/custom-apps.tsv"
  printf 'claude|+|extra.example\n' > "$H/site-domains.tsv"
  printf 'router.home|192.168.1.1\n' > "$H/hosts.tsv"
  printf 'CN=dnspod\nADS=1\n' > "$H/dns.conf"
  printf '1\n' > "$H/apps.seen"
  # 网站 / 服务的出口开关: 核心自己记住选择 (cache.db), 默认值在 config.json 里。chatgpt / spotify 被改过, ok 没改, PIN (节点选择) 不属于规则
  printf '{"outbounds":[{"type":"selector","tag":"PIN","outbounds":["A","B"],"default":"A"},{"type":"selector","tag":"svc-chatgpt","outbounds":["PIN","Global","direct"],"default":"Global"},{"type":"selector","tag":"svc-spotify","outbounds":["PIN","Global","direct"],"default":"direct"},{"type":"selector","tag":"svc-ok","outbounds":["PIN","Global","direct"],"default":"PIN"},{"type":"selector","tag":"Final","outbounds":["Global","PIN","direct"],"default":"Global"}]}' > "$H/config.json"
  printf 'PIN=B\nsvc-chatgpt=direct\nsvc-spotify=PIN\nsvc-ok=PIN\nFinal=Global\n' > "$SEL"
  settings_set AUTO_SITES 1; settings_set LOG_HOURS 48; load_settings
}
# 不属于「规则」的东西: 重置不能动
keepers() {
  printf '{"role":"pin","outbound":{"type":"socks","tag":"PinNode","server":"203.0.113.9","server_port":1080}}\n' > "$H/servers.jsonl"
  printf 'MySub|https://example.invalid/sub|12|0|0|0\n' > "$H/subs.tsv"
  printf 'cf|https://example.invalid/x\n' > "$H/speedtest-custom.tsv"; printf '{"ui.density":"compact"}\n' > "$H/prefs.json"
}

echo "== R1. 先装上云端内容 (序号 100), 再把本机缓存的官方内容改坏 + 造一堆自己的规则"
login; keepers; customize
op_txn "更新云端内容" txn_content >/dev/null 2>&1
eq "云端内容已安装 (序号 100)" "$(cloud_seq)" "100"
cp "$H/cloud/content/apps.conf" "$W/apps.conf.official"
printf 'Claude|direct|被改坏的推荐\nEvilApp|direct|X\n' > "$H/cloud/content/apps.conf"
has "本机缓存里的 apps.conf 确实被改坏了" "EvilApp" "$(cat "$H/cloud/content/apps.conf")"
customize        # txn_content 里的 apps 扫描会改动 overrides, 这里重新造一遍确定的状态

echo "== R2. 预览: 数量对得上 (确认框用)"
c=$(reset_counts)
eq "reset_counts (出口开关: 只数和默认不一样的 2 个, PIN 不算)" "$c" "apps=3 sites=1 auto_sites=1 services=2 rulesets=1 toggles=2 custom_apps=1 domains=1 hosts=1 dns=1 auto_on=1"
j=$(reset_preview_json); printf '{%s}' "$j" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["total"]==14 and d["logged_in"] is True and d["backup"] is None and d["services"]==2 and d["content"]["seq"]==100 and d["content"]["source"]=="cloud" and d["sync"]["enabled"] is False and d["auto_on"]==1' && tpass "reset_preview_json: 合法 JSON, 合计 14 项, 内容序号 100, 还没有备份" || tfail "reset_preview_json" "$j"

echo "== R3. 重置 (在线): 规则全清, 官方内容换回干净的, 应用按官方推荐重新识别"
APPLIES=0; RS_UPDATES=0; OP_WHO=dashboard
op_rules_reset >/dev/null 2>&1; rc=$?
eq "任务成功" "$rc" "0"
for f in autosites.tsv autosites.dismissed rules.state custom-rulesets.tsv custom-apps.tsv site-domains.tsv hosts.tsv dns.conf; do gone "已清除: $f" "$f"; done
eq "不再有自己改过的应用 / 网站策略 (没有 ack, 也没有 site)" "$(grep -Ec '[|]ack[|]|^site[|]' "$H/overrides.tsv")" "0"
eq "已安装的应用重新识别, 全部标记为 def (不弹「新应用」)" "$(awk -F'|' '$1=="app" && $4=="def" {n++} END{print n+0}' "$H/overrides.tsv")" "4"
eq "Claude 回到官方推荐 (pin)" "$(awk -F'|' '$1=="app" && $2=="Claude" {print $3}' "$H/overrides.tsv")" "pin"
eq "浏览器 Safari 回到默认 (follow)" "$(awk -F'|' '$1=="app" && $2=="Safari" {print $3}' "$H/overrides.tsv")" "follow"
eq "官方推荐的 Windsurf = follow" "$(awk -F'|' '$1=="app" && $2=="Windsurf" {print $3}' "$H/overrides.tsv")" "follow"
eq "没有推荐的应用 = direct" "$(awk -F'|' '$1=="app" && $2=="Random Tool" {print $3}' "$H/overrides.tsv")" "direct"
eq "网站 / 服务的出口开关切回默认 (chatgpt → Global, spotify → direct)" "$(grep -E '^(svc-chatgpt|svc-spotify)=' "$SEL" | sort | paste -sd' ' -)" "svc-chatgpt=Global svc-spotify=direct"
eq "没改过的开关不动; 节点选择 (PIN) 不属于规则, 也不动" "$(grep -E '^(svc-ok|PIN)=' "$SEL" | sort | paste -sd' ' -)" "PIN=B svc-ok=PIN"
eq "自动识别开关回到默认 (关)" "$(sed -n 's/^AUTO_SITES=//p' "$H/settings.env")" "0"
eq "官方内容被强制换回 (坏的 EvilApp 没了, 序号不变)" "$(grep -c EvilApp "$H/cloud/content/apps.conf"):$(cloud_seq)" "0:100"
eq "官方的 apps.conf 和云端的一字不差" "$(shasum -a 256 < "$H/cloud/content/apps.conf")" "$(shasum -a 256 < "$W/apps.conf.official")"
eq "重置后重新生成并应用了配置, 并补下了默认启用的规则集" "$APPLIES:$RS_UPDATES" "1:1"
has "任务结果: 内容来自云端" '"content":"cloud"' "$TXN_RESULT"
kept "服务器没动" servers.jsonl; kept "订阅没动" subs.tsv; kept "测速自定义目标没动" speedtest-custom.tsv; kept "界面偏好没动" prefs.json
eq "日志保留时长设置没动" "$(sed -n 's/^LOG_HOURS=//p' "$H/settings.env")" "48"
eq "成功后清理自定义规则集的文件 (登记已经没了)" "$(ls "$H"/rules/custom-*.srs 2>/dev/null | wc -l | tr -d ' ')" "0"

echo "== R4. 备份 + 撤销"
b=$(reset_latest_backup)
eq "备份文件存在" "$([ -f "$b" ] && echo y)" "y"
tl=$(tar -tzf "$b" | sed 's#^\./##' | sort | tr '\n' ' ')
for f in overrides.tsv hosts.tsv dns.conf custom-apps.tsv custom-rulesets.tsv site-domains.tsv rules.state autosites.tsv .reset.meta .reset.sel; do has "备份里有: $f" "$f" "$tl"; done
hasnt "备份里没有服务器 / 订阅 / 设置 (不碰敏感内容)" "servers.jsonl|subs.tsv|settings.env" "$tl"
eq "备份文件权限 600" "$(perl -e 'printf "%o", (stat shift)[2] & 0777' "$b")" "600"
j=$(reset_preview_json); printf '{%s}' "$j" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["backup"]["time"]>1700000000 and d["backup"]["name"].startswith("reset-")' && tpass "预览里能看到备份的时间 (可撤销)" || tfail "预览里的备份信息" "$j"
op_txn "撤销恢复默认" txn_reset_undo >/dev/null 2>&1; rc=$?
eq "撤销成功" "$rc" "0"
eq "自己改过的规则回来了 (Claude 又是 direct, 有 ack)" "$(awk -F'|' '$1=="app" && $2=="Claude" {print $3 ":" $4}' "$H/overrides.tsv")" "direct:ack"
eq "自己加的网站策略回来了" "$(grep -c '^site|mine.example|pin' "$H/overrides.tsv")" "1"
for f in autosites.tsv autosites.dismissed rules.state custom-rulesets.tsv custom-apps.tsv site-domains.tsv hosts.tsv dns.conf; do kept "撤销后恢复: $f" "$f"; done
eq "出口开关也切回重置前的选择 (chatgpt → direct, spotify → PIN)" "$(grep -E '^(svc-chatgpt|svc-spotify)=' "$SEL" | sort | paste -sd' ' -)" "svc-chatgpt=direct svc-spotify=PIN"
eq "自动识别开关也恢复成重置前的 (开)" "$(sed -n 's/^AUTO_SITES=//p' "$H/settings.env")" "1"
eq "服务器 / 设置仍然没动" "$(sed -n 's/^LOG_HOURS=//p' "$H/settings.env"):$(grep -c PinNode "$H/servers.jsonl")" "48:1"
eq "备份用掉就删 (不能重复撤销)" "$(reset_latest_backup)" ""
op_txn "撤销恢复默认" txn_reset_undo >/dev/null 2>&1; rc=$?
eq "没有备份时撤销被拒绝" "$rc" "1"
has "并说明原因" "没有可以撤销" "$TXN_ERR"

echo "== R5. 离线 / 没登录: 本地照样重置, 用本机已验证的官方内容; 说明原因"
customize; ONLINE=0
op_txn "恢复官方默认规则" txn_reset_official >/dev/null 2>&1; rc=$?
eq "离线时重置仍然成功" "$rc" "0"
has "任务结果: 内容用的是本机缓存" '"content":"cached"' "$TXN_RESULT"; has "带上原因 (连不上云端)" '"error":"连不上' "$TXN_RESULT"
eq "规则已清空 / 应用已重新识别" "$(grep -c '[|]ack[|]' "$H/overrides.tsv"):$(grep -c '[|]def[|]' "$H/overrides.tsv")" "0:4"
has "云端内容状态里记下了这次的错误 (设置页能看到)" "连不上" "$(sed -n 's/^error=//p' "$H/cloud/state")"
ONLINE=1; customize; logout; st_before=$(cat "$H/cloud/state")
op_txn "恢复官方默认规则" txn_reset_official >/dev/null 2>&1; rc=$?
eq "没登录也能重置" "$rc" "0"
has "任务结果: 本机缓存" '"content":"cached"' "$TXN_RESULT"
eq "没登录不算云端故障: 不改动云端内容状态" "$(cat "$H/cloud/state")" "$st_before"
rm -rf "$H/cloud"; customize
op_txn "恢复官方默认规则" txn_reset_official >/dev/null 2>&1; rc=$?
eq "从没有过云端内容 (全新安装 / 没登录过): 回到随程序自带的基线" "$rc:$(cloud_seq)" "0:0"
has "任务结果: 基线" '"content":"baseline"' "$TXN_RESULT"
eq "基线内容的路径" "$(content_file apps.conf)" "$DATA/apps.conf"

echo "== R6. 失败时整体回滚: 配置没通过校验 → 所有自己的规则原样还在, 也没有留下假的备份"
login; customize; rm -f "$H"/backups/reset-*.tgz; printf 'SRS' > "$H/rules/custom-mylist.srs"
before=$(cat "$H/overrides.tsv" "$H/hosts.tsv" "$H/dns.conf" "$H/rules.state" "$H/custom-rulesets.tsv" "$H/apps.seen" "$SEL" | sort | shasum -a 256)
APPLY_RC=1; op_rules_reset >/dev/null 2>&1; rc=$?; APPLY_RC=0
eq "配置没通过校验: 重置失败" "$rc" "1"
eq "自己的规则 (应用策略 / 网站 / DNS / 解析 / 规则集开关 / 自定义规则集 / 出口开关) 原样恢复" "$(cat "$H/overrides.tsv" "$H/hosts.tsv" "$H/dns.conf" "$H/rules.state" "$H/custom-rulesets.tsv" "$H/apps.seen" "$SEL" | sort | shasum -a 256)" "$before"
eq "没有留下临时的开关记录" "$([ -e "$H/.reset.sel" ] && echo left)" ""
eq "自定义规则集的文件还在 (没有因为失败被删掉)" "$(cat "$H/rules/custom-mylist.srs")" "SRS"
eq "失败的重置不留下备份 (不会让人误以为可以撤销)" "$(reset_latest_backup)" ""
eq "自动识别开关恢复成原来的 (开)" "$(sed -n 's/^AUTO_SITES=//p' "$H/settings.env")" "1"

echo "== R7. 备份只留最近 $RESET_KEEP 份; 没有任何自定义内容时不建备份"
rm -f "$H"/backups/reset-*.tgz; mkdir -p "$H/backups"
for n in 1700000001 1700000002 1700000003 1700000004 1700000005; do : > "$H/backups/reset-$n.tgz"; done
customize; reset_backup
eq "旧备份被清理, 只剩最新的 3 份" "$(ls "$H"/backups/reset-*.tgz | wc -l | tr -d ' ')" "3"
eq "最新一份是刚建的 (不是占位文件)" "$([ -s "$(reset_latest_backup)" ] && echo y)" "y"
rm -rf "$H/backups"; for f in $RESET_FILES; do rm -f "$H/$f"; done; settings_set AUTO_SITES 0; load_settings
printf 'PIN=B\nsvc-chatgpt=Global\nsvc-spotify=direct\nsvc-ok=PIN\nFinal=Global\n' > "$SEL"; reset_backup
eq "本来就是默认状态: 不建备份" "$(ls "$H"/backups 2>/dev/null | wc -l | tr -d ' ')" "0"
eq "默认状态的预览: 合计 0 项" "$(printf '{%s}' "$(reset_preview_json)" | python3 -c 'import json,sys; print(json.load(sys.stdin)["total"])')" "0"

echo "== R8. 操作记录: 记下重置前各类规则的数量 (没有任何密码 / 令牌)"
customize; OP_WHO=dashboard; op_txn "恢复官方默认规则" txn_reset_official >/dev/null 2>&1
ol=$(cat "$LOGS"/ops-*.log 2>/dev/null)
has "操作记录里有这次重置 + 数量" "恢复官方默认规则.*apps=3 sites=1 auto_sites=1 services=2 rulesets=1" "$ol"
hasnt "操作记录里没有主机 / 令牌" "203[.]0[.]113|tok" "$ol"

p=$(wc -l < "$W/.pass" | tr -d ' '); f=$(wc -l < "$W/.fail" | tr -d ' ')
echo; echo "reset.sh: $p passed, $f failed"; [ "$f" = 0 ]
