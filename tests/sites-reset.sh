#!/bin/bash
# 网站页「恢复网站默认」(lib/ops.sh 的 txn_sites_reset): 只清网站相关的改动, 先备份, 只保留最近 3 份备份, 不动应用设置。
# 核心 (clash) 不运行: 用桩函数代替开关的读写, 直接检查文件的结果。
set -eu
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
H="$W/h"; mkdir -p "$H"
# 只取出被测函数的源码 (避免加载整个 ops.sh 的依赖)
FN="$W/txn.sh"
awk '/^SITES_RESET_FILES=/{p=1} p{print} p && /^}/{exit}' "$REPO/lib/ops.sh" > "$FN"
[ -s "$FN" ] || { echo "FAIL: 找不到 txn_sites_reset"; exit 1; }
job_step() { :; }
settings_set() { echo "$1=$2" >> "$H/settings.log"; }
SELECTOR_APPLIED=0
reset_selector_diff() { printf 'svc-claude\tauto\tpin\n'; }
reset_selectors_apply() { SELECTOR_APPLIED=$(( SELECTOR_APPLIED + 1 )); }
. "$FN"
fail=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fail=1; }

printf 'claude|+|example.test\n' > "$H/site-domains.tsv"
printf 'auto.example\n' > "$H/autosites.tsv"; printf 'x\n' > "$H/autosites.dismissed"
printf 'site|claude|pin|ack|\nsite|chatgpt|direct|ack|\napp|TestCurl|pin|ack|\n' > "$H/overrides.tsv"
printf 'LOG_HOURS=48\n' > "$H/settings.env"
for i in 1 2 3 4; do
  printf 'site|gemini|auto|ack|\n' >> "$H/overrides.tsv"
  txn_sites_reset || { bad "txn 第 $i 次返回失败"; }
  sleep 1
done

[ ! -e "$H/site-domains.tsv" ] && ok "域名增删 (site-domains.tsv) 已清掉" || bad "site-domains.tsv 没有清掉"
[ ! -e "$H/autosites.tsv" ] && [ ! -e "$H/autosites.dismissed" ] && ok "自动识别的记录已清掉" || bad "自动识别记录没有清掉"
if grep -q '^site|' "$H/overrides.tsv"; then bad "overrides.tsv 里还有网站策略"; else ok "网站策略 (site|) 已清掉"; fi
grep -q '^app|TestCurl|' "$H/overrides.tsv" && ok "应用设置 (app|) 保留" || bad "应用设置被误删"
grep -q '^LOG_HOURS=48' "$H/settings.env" && ok "设置文件 settings.env 没有被动" || bad "settings.env 被改动"
grep -q '^AUTO_SITES=0' "$H/settings.log" && ok "自动识别开关 AUTO_SITES 设为 0" || bad "AUTO_SITES 没有设为 0"
[ "$SELECTOR_APPLIED" = 4 ] && ok "网站出口开关切回默认 (每次 1 个)" || bad "出口开关没有切回默认 (次数 $SELECTOR_APPLIED)"
n=$(ls -1 "$H"/backups/sites-*.tgz 2>/dev/null | wc -l | tr -d ' ')
[ "$n" = 3 ] && ok "备份只保留最近 3 份 (现有 $n 份)" || bad "备份份数不对: $n"
tar -xzf "$(ls -1 "$H"/backups/sites-*.tgz | tail -1)" -C "$W" overrides.tsv && grep -q '^site|gemini|' "$W/overrides.tsv" && ok "最近一次备份保存了清除前的网站策略" || bad "备份缺少清除前的网站策略"
[ "$fail" = 0 ] && echo "ok sites-reset" || { echo "sites-reset: 有失败"; exit 1; }
