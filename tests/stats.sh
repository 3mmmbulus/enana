#!/bin/bash
# 流量统计 (lib/stats.pl): 采样分钟数 (区分「没有流量」和「没有采集到」) · 并发采样不丢数据 · 旧版本数据兼容 · 诊断摘要。几秒钟, macOS / Linux 都能跑, 只需要 perl。
set -u
HERE=$(cd "$(dirname "$0")" && pwd -P); REPO=$(dirname "$HERE")
W=$(mktemp -d /tmp/enana-stats.XXXXXX); W=$(cd "$W" && pwd -P); trap 'rm -rf "$W"' EXIT; : > "$W/.pass"; : > "$W/.fail"
tpass() { echo p >> "$W/.pass"; echo "  ✓ $1"; }
tfail() { echo f >> "$W/.fail"; echo "  ✗ $1"; [ -n "${2:-}" ] && printf '      ↳ %s\n' "$(printf '%s' "$2" | head -c 600)"; return 0; }
eq()    { if [ "$2" = "$3" ]; then tpass "$1"; else tfail "$1" "期望 [$3] 实际 [$2]"; fi; }
command -v perl >/dev/null || { echo "跳过: 需要 perl"; exit 77; }
export TZ=Asia/Shanghai LC_ALL=C
S=$W/stats; P="$REPO/lib/stats.pl"
epoch() { perl -MPOSIX -e 'print POSIX::mktime(0, $ARGV[4], $ARGV[3], $ARGV[2], $ARGV[1] - 1, $ARGV[0] - 1900)' "$1" "$2" "$3" "$4" "${5:-0}"; }   # 年 月 日 时 [分] -> epoch (本地时间)
sample() { # <epoch> <累计上传> <累计下载>   采一次样 (没有连接, 只有核心的累计计数)
  printf '{"uploadTotal":%s,"downloadTotal":%s,"connections":[]}' "$2" "$3" | ENANA_NOW=$1 perl "$P" collect "$S" /dev/null auto
}
jf() { python3 -c 'import sys,json; d=json.load(sys.stdin); '"$1"; }
report() { ENANA_NOW=$1 perl "$P" report "$S" "$2"; }

echo "== T1. 第一次只建基线; 之后每分钟采到样就记一分钟, 有没有流量都记"
T=$(epoch 2026 10 4 10 0)
sample "$T" 1000 5000
eq "第一次采样: 只建立基线, 不产生任何一天的记录" "$(ls "$S" | grep -c '^daily.tsv$')" "0"
sample $((T + 60)) 1500 9000
eq "第二次: 有流量 → 今天一行, 采样 1 分钟, up=500 down=4000" "$(awk -F'\t' '{print $1 ":" $2 ":" $3 ":" $10}' "$S/daily.tsv")" "2026-10-04:500:4000:1"
sample $((T + 120)) 1500 9000
eq "第三次: 没有流量也算采到样 (samples=2), 总量不变" "$(awk -F'\t' '{print $2 ":" $3 ":" $10}' "$S/daily.tsv")" "500:4000:2"
eq "最后一次采样时间已记录" "$(cat "$S/last")" "$((T + 120))"

echo "== T2. 区分「没有流量」和「根本没有采集到」"
# 10 月 3 日一次都没有采到样 (电脑休眠 / 核心没运行 / 定时任务没运行): 第 4 天之后的日子才有行
rm -rf "$S"
D1=$(epoch 2026 10 2 12 0); D2=$(epoch 2026 10 4 12 0)
sample "$D1" 100 100; sample $((D1 + 60)) 200 300; sample $((D1 + 120)) 200 300       # 10-02: 2 分钟采样, 其中 1 分钟有流量
sample "$D2" 0 0; sample $((D2 + 60)) 50 70                                              # 10-04: 核心重启过 (计数清零), 1 分钟采样
R=$(report "$D2" 3d)
eq "3 天范围: 10-02 / 10-03 / 10-04 的 samples = 2 / 0 / 2 (10-03 明确是「没采到」而不是「零流量」; 核心重启、计数清零的那一次也是有效采样)" "$(printf '%s' "$R" | jf 'print(",".join(str(s["samples"]) for s in d["series"]))')" "2,0,2"
eq "10-03 的流量为 0, 但带 samples=0 (界面据此画成「未采集」)" "$(printf '%s' "$R" | jf 'print(d["series"][1]["t"], d["series"][1]["down"], d["series"][1]["samples"])')" "2026-10-03 0 0"
eq "sample_since = 有采样列的最早一天" "$(printf '%s' "$R" | jf 'print(d["sample_since"])')" "2026-10-02"

echo "== T3. 旧版本留下的数据 (没有采样列): 不知道就说不知道 (null), 不冤枉成「没采到」"
rm -rf "$S"; mkdir -p "$S"
printf '2026-09-30\t10\t20\t0\t0\t10\t20\t0\t0\n2026-10-02\t30\t40\t0\t0\t30\t40\t0\t0\n' > "$S/daily.tsv"
R=$(report "$(epoch 2026 10 3 12 0)" 7d)
eq "旧数据的日子 samples=null; 没有行的旧日子也是 null (没有任何一天有采样列, 无法判断)" "$(printf '%s' "$R" | jf 'print(",".join(str(s["samples"]) for s in d["series"]))')" "None,None,None,None,None,None,None"
sample "$(epoch 2026 10 3 12 0)" 10 10; sample "$(epoch 2026 10 3 12 1)" 20 30
R=$(report "$(epoch 2026 10 4 12 0)" 7d)
eq "升级后有了采样列: 10-02 (旧版本留下的行) 仍是 null, 10-03 samples=1, 10-04 (还没采样) = 0" "$(printf '%s' "$R" | jf 'print(",".join(str(s["samples"]) for s in d["series"][-3:]))')" "None,1,0"
eq "旧数据的流量总量原样保留" "$(printf '%s' "$R" | jf 'print(d["series"][-5]["down"] if d["series"][-5]["t"]=="2026-09-30" else "-")')" "20"

echo "== T4. 并发采样 (每分钟的 tick 与每天的维护可能碰在一起): 不丢采样, 文件不损坏"
rm -rf "$S"
T=$(epoch 2026 10 4 10 0)
sample "$T" 0 0
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do ( sample "$T" $((i * 100)) $((i * 1000)) ) & done; wait
eq "12 个进程同时采样: 采样分钟数正好 12 (没有互相覆盖)" "$(awk -F'\t' '{print $10}' "$S/daily.tsv")" "12"
eq "daily.tsv 只有一行, 每行 10 列 (没有被交错写坏)" "$(awk -F'\t' 'END { print NR ":" NF }' "$S/daily.tsv")" "1:10"
eq "没有残留的临时文件" "$(ls "$S" | grep -c '\.new')" "0"

echo "== T5. 诊断摘要 (env 分区): 最近 7 天每天采了多少分钟"
rm -rf "$S"
D=$(epoch 2026 10 4 12 0)
sample "$((D - 86400 * 2))" 0 0; sample "$((D - 86400 * 2 + 60))" 10 20; sample "$D" 0 0; sample "$((D + 60))" 5 5
M=$(ENANA_NOW=$D perl "$P" summary "$S")
eq "last_sample 是本地时间" "$(printf '%s\n' "$M" | sed -n 's/^stats.last_sample=//p')" "2026-10-04 12:01:00"
eq "10-02: samples=1 up=10 down=20" "$(printf '%s\n' "$M" | sed -n 's/^stats.day.2026-10-02=//p')" "samples=1 up=10 down=20"
eq "10-03: no-row (一次都没采到)" "$(printf '%s\n' "$M" | sed -n 's/^stats.day.2026-10-03=//p')" "no-row"
eq "10-04: samples=2 up=5 down=5 (两次采样, 第二次起有流量)" "$(printf '%s\n' "$M" | sed -n 's/^stats.day.2026-10-04=//p')" "samples=2 up=5 down=5"

echo "== T6. 按应用统计 (应用页的「今日流量」): 浏览器辅助进程归到浏览器, 没归类的部分按比例分摊"
rm -rf "$S"
T=$(epoch 2026 10 4 10 0)
conn() { # <id> <processPath> <up> <down>
  printf '{"id":"%s","metadata":{"processPath":"%s"},"chains":["direct"],"upload":%s,"download":%s}' "$1" "$2" "$3" "$4"
}
sample_c() { # <epoch> <累计上传> <累计下载> <连接 JSON…>
  local e=$1 u=$2 d=$3 cs; shift 3; cs=$(IFS=,; printf '%s' "$*")
  printf '{"uploadTotal":%s,"downloadTotal":%s,"connections":[%s]}' "$u" "$d" "$cs" | ENANA_NOW=$e perl "$P" collect "$S" /dev/null auto
}
CH='/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper'
GP='/Applications/ChatGPT.app/Contents/MacOS/ChatGPT'
sample_c "$T" 0 0
sample_c $((T + 60)) 600 7000 "$(conn c1 "$CH" 100 3000)" "$(conn c2 "$GP" 100 1000)"
R=$(ENANA_NOW=$((T + 60)) perl "$P" apps "$S" today)
eq "Chrome 的 Helper 进程归到 Google Chrome (取最外层 .app), 不是 Google Chrome Helper" "$(printf '%s' "$R" | jf 'print(",".join(a["name"] for a in d["apps"]))')" "Google Chrome,ChatGPT"
# 总量 600/7000, 已归类 200/4000: 剩下的 400/3000 按 3100:1100 的比例分摊给两个应用
eq "两个应用加起来等于总量 600 / 7000 (没归类的部分没有凭空丢失; 整数截断最多差几个字节)" "$(printf '%s' "$R" | jf 'print(abs(sum(a["up"] for a in d["apps"]) - 600) <= 2 and abs(sum(a["down"] for a in d["apps"]) - 7000) <= 2)')" "True"
eq "Chrome 分到的更多 (它本来就占 3/4)" "$(printf '%s' "$R" | jf 'a=d["apps"]; print(a[0]["down"] > a[1]["down"] * 2)')" "True"
sample_c $((T + 120)) 700 7500 "$(conn c1 "$CH" 150 3200)" "$(conn c2 "$GP" 100 1000)" "$(conn c3 /usr/bin/curl 10 20)"
R=$(ENANA_NOW=$((T + 120)) perl "$P" apps "$S" today)
eq "第二分钟只算增量: curl 出现了 (命令行程序取文件名)" "$(printf '%s' "$R" | jf 'print("curl" in [a["name"] for a in d["apps"]])')" "True"
eq "apps 范围 3d 包含今天" "$(ENANA_NOW=$((T + 120)) perl "$P" apps "$S" 3d | jf 'print(len(d["apps"]))')" "3"
eq "没有进程信息的连接不归任何应用 (也不报错)" "$(sample_c $((T + 180)) 800 7600 '{"id":"c9","metadata":{},"chains":["direct"],"upload":1,"download":1}'; echo done)" "done"

echo "== T7. 2.3.7 及更早版本的缺陷: 从第二天起 daily.tsv 每分钟追加一条只含增量的新行, 每天只剩最后一分钟的流量 —— 升级后自动还原, 之后跨天采样每天的合计都对"
rm -rf "$S"; mkdir -p "$S"
# 这份文件就是旧版采集器在 3 天里 (每天 3 次采样, 每次 +1000 字节) 写出来的 (见提交说明里的复现): 日期重复、行与行之间有空行
printf '2026-10-02\t200\t2000\t0\t0\t0\t0\t200\t2000\n\n2026-10-03\t100\t1000\t0\t0\t0\t0\t100\t1000\n\n2026-10-03\t100\t1000\t0\t0\t0\t0\t100\t1000\n\n2026-10-03\t100\t1000\t0\t0\t0\t0\t100\t1000\n\n2026-10-04\t100\t1000\t0\t0\t0\t0\t100\t1000\n\n2026-10-04\t100\t1000\t0\t0\t0\t0\t100\t1000\n\n2026-10-04\t100\t1000\t0\t0\t0\t0\t100\t1000\n' > "$S/daily.tsv"
R=$(report "$(epoch 2026 10 4 13 0)" 7d)
eq "读取时合并重复行: 10-02 / 10-03 / 10-04 各自的下载合计 = 2000 / 3000 / 3000 (以前只显示最后一分钟的 1000)" "$(printf '%s' "$R" | jf 'print([s["down"] for s in d["series"][-3:]])')" "[2000, 3000, 3000]"
eq "总量 = 三天之和 8000" "$(printf '%s' "$R" | jf 'print(d["total"]["down"])')" "8000"
sample "$(epoch 2026 10 4 13 0)" 0 0; sample "$(epoch 2026 10 4 13 1)" 100 1000
eq "下一次采样把文件整理好: 每天只有一行 (没有重复日期, 没有空行)" "$(cut -f1 "$S/daily.tsv" | sort | uniq -c | awk '{print $1}' | paste -sd, -):$(grep -c '^$' "$S/daily.tsv")" "1,1,1:0"
eq "整理后 10-04 的合计是 3000 + 新增的 1000" "$(awk -F'\t' '$1=="2026-10-04" {print $3}' "$S/daily.tsv")" "4000"
printf '2026-10-04\t10\t100\t1000\t0\t1000\t0\n\n2026-10-04\t10\t100\t1000\t0\t1000\t0\n\n2026-10-04\t11\t50\t500\t500\t0\t0\n' > "$S/hourly.tsv"
R=$(report "$(epoch 2026 10 4 13 0)" today)
eq "今日按小时的图表同样合并重复行: 10 点 = 2000, 11 点 = 500 (以前只剩最后一条)" "$(printf '%s' "$R" | jf 'print(d["series"][10]["down"], d["series"][11]["down"])')" "2000 500"
rm -rf "$S"
# 新版采集器连续跑 3 天, 每天 3 次采样、每次 +1000 字节: 每天的合计都应该是 3000 (第一次采样只建基线), 不会出现重复行
d=0
for day in 2 3 4; do
  T=$(epoch 2026 10 $day 12 0)
  for m in 0 1 2; do d=$((d + 1000)); sample $((T + m * 60)) $((d / 10)) "$d"; done
done
R=$(report "$(epoch 2026 10 4 13 0)" 7d)
eq "连续 3 天: 10-02 = 2000 (第一次采样只建基线), 10-03 = 3000, 10-04 = 3000" "$(printf '%s' "$R" | jf 'print([s["down"] for s in d["series"][-3:]])')" "[2000, 3000, 3000]"
eq "daily.tsv 每天一行" "$(cut -f1 "$S/daily.tsv" | sort | uniq -d | wc -l | tr -d ' ')" "0"
eq "每天的采样分钟数: 2 / 3 / 3" "$(awk -F'\t' '{print $10}' "$S/daily.tsv" | paste -sd, -)" "2,3,3"

P_=$(grep -c . "$W/.pass"); F_=$(grep -c . "$W/.fail")
echo; echo "流量统计测试: $P_ 通过, $F_ 失败"
[ "$F_" = 0 ]
