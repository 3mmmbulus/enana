#!/bin/bash
# sing-box 核心: 备用下载源 + 签名的兼容清单 (lib/fetch.sh · lib/update.sh · tools/build-core-manifest.sh): 几秒钟, 不需要网络 / sing-box / 管理员权限。
#   · 下载源顺序 (官方 → 项目自己的目录 → 第三方镜像), 没有 SHA-256 钉死时只用官方
#   · 清单: 生成并签名 · 验签 · 防回滚 (seq 变小就拒绝) · 被篡改 / 用错钥匙签名都拒绝 · 本机文件被改也不再生效
#   · 兼容选择: 按 enana 版本范围和这台电脑的架构挑最新的核心; 清单不能覆盖随程序发布的 SHA-256
#   · 低速立即换源的参数传给了 curl · 官方源不可用时真的从项目自己的目录下载并逐个校验
#   · 检查更新里的 core_latest 只来自清单, 不再跟着 GitHub 的 latest
# 线上的 /dl/core/ 用本机 file:// 目录代替; 签名私钥是临时生成的, 公钥通过 ENANA_CLOUD_PUBKEY 交给客户端。
set -u
HERE=$(cd "$(dirname "$0")" && pwd -P); REPO=$(dirname "$HERE")
W=$(mktemp -d /tmp/enana-core.XXXXXX); W=$(cd "$W" && pwd -P)
trap 'rm -rf "$W"' EXIT; : > "$W/.pass"; : > "$W/.fail"
tpass() { echo p >> "$W/.pass"; echo "  ✓ $1"; }
tfail() { echo f >> "$W/.fail"; echo "  ✗ $1"; [ -n "${2:-}" ] && printf '      ↳ %s\n' "$(printf '%s' "$2" | head -c 700)"; return 0; }
eq()    { if [ "$2" = "$3" ]; then tpass "$1"; else tfail "$1" "期望 [$3] 实际 [$2]"; fi; }
has()   { if printf '%s\n' "$3" | grep -Eq -- "$2"; then tpass "$1"; else tfail "$1" "没有找到 /$2/ 于: $3"; fi; }
hasnt() { if ! printf '%s\n' "$3" | grep -Eq -- "$2"; then tpass "$1"; else tfail "$1" "不应出现 /$2/: $3"; fi; }
t_ok()  { if "${@:2}" >/dev/null 2>&1; then tpass "$1"; else tfail "$1" "命令失败: ${*:2}"; fi; }
t_no()  { if "${@:2}" >/dev/null 2>&1; then tfail "$1" "本应失败: ${*:2}"; else tpass "$1"; fi; }

command -v perl >/dev/null && [ -x /usr/bin/openssl ] || { echo "跳过: 需要 perl / openssl"; exit 77; }
export HOME=$W/home ENANA_HOME=$W/h LC_ALL=C ENANA_LANG=zh PORT=37990 UI_PORT=37991 API_PORT=37992 SPEED_PORT=37993 ENANA_PLATFORM=darwin ENANA_CLOUD_PUBKEY=$W/cpub.pem
mkdir -p "$HOME" "$ENANA_HOME"
. "$REPO/lib/common.sh"; init_paths "$REPO/install.sh"
LIB=$REPO/lib; DATA=$REPO/data
for _f in i18n jobs servers apps autosites sites fetch os-darwin enhanced auth device session cloud dns logs health update config ops; do . "$LIB/$_f.sh"; done
load_settings; QUIET=1
[ "$H" = "$W/h" ] || { echo "REFUSING: 数据目录不是临时目录 ($H)"; exit 1; }
mkdir -p "$H"

SHA_A=$(printf 'a' | shasum -a 256 | awk '{print $1}'); SHA_B=$(printf 'b' | shasum -a 256 | awk '{print $1}'); SHA_C=$(printf 'c' | shasum -a 256 | awk '{print $1}')
/usr/bin/openssl ecparam -genkey -name prime256v1 -noout -out "$W/ckey.pem" 2>/dev/null; /usr/bin/openssl ec -in "$W/ckey.pem" -pubout -out "$W/cpub.pem" 2>/dev/null
/usr/bin/openssl ecparam -genkey -name prime256v1 -noout -out "$W/other.pem" 2>/dev/null; /usr/bin/openssl ec -in "$W/other.pem" -pubout -out "$W/other-pub.pem" 2>/dev/null
CORE_BASE="file://$W/srv/core"
ARCH=arm64

echo "== C1. 下载源顺序: 官方 → 项目自己的目录 → 第三方镜像; 没有 SHA-256 钉死时只用官方"
all=$(core_urls darwin-arm64 1.14.2 1 all)
eq "钉死 + all: 第 1 行是官方 GitHub" "$(printf '%s\n' "$all" | sed -n 1p)" "https://github.com/SagerNet/sing-box/releases/download/v1.14.2/sing-box-1.14.2-darwin-arm64.tar.gz"
eq "钉死 + all: 第 2 行是项目自己的下载目录" "$(printf '%s\n' "$all" | sed -n 2p)" "$CORE_BASE/1.14.2/sing-box-1.14.2-darwin-arm64.tar.gz"
has "钉死 + all: 之后才是第三方镜像 (带官方地址)" '^https://ghfast\.top/https://github\.com/SagerNet/' "$(printf '%s\n' "$all" | sed -n 3p)"
eq "钉死 + all: 共 1 + 1 + 镜像数 行" "$(printf '%s\n' "$all" | wc -l | tr -d ' ')" "$((2 + $(grep -cvE '^(#|$)' "$DATA/mirrors.conf")))"
eq "钉死 + fast: 只有官方和项目自己的目录 (2 行)" "$(core_urls darwin-arm64 1.14.2 1 fast | wc -l | tr -d ' ')" "2"
eq "没有钉死: 只有官方 (1 行), 不会用项目目录或镜像" "$(core_urls darwin-arm64 9.9.9 0 all | wc -l | tr -d ' ')" "1"
hasnt "没有钉死: 不含项目自己的目录" "$W/srv/core" "$(core_urls darwin-arm64 9.9.9 0 all)"

echo "== C2. 兼容清单: 生成 + 签名 → 客户端验签保存"
mkdir -p "$W/in" "$W/srv/core" "$W/out1"
cat > "$W/in/m.txt" <<EOF
# 测试清单
1.14.2|darwin-arm64|$SHA_A|2.3.0|
1.14.3|darwin-arm64|$SHA_B|2.3.9|
1.15.0|darwin-arm64|$SHA_C|2.4.0|
1.14.4|darwin-arm64|$SHA_A|2.3.0|2.3.8
1.14.3|darwin-amd64|$SHA_B|2.3.9|
EOF
t_no "没有清单时 core_manifest_rows 什么都不输出" test -n "$(core_manifest_rows)"
eq "没有清单时 core_latest_compat 为空" "$(core_latest_compat)" ""
t_ok "tools/build-core-manifest.sh 生成并签名 (seq=100)" bash "$REPO/tools/build-core-manifest.sh" "$W/in/m.txt" "$W/out1" "$W/ckey.pem" 100
t_ok "输出了清单和签名文件" test -s "$W/out1/core-manifest.conf" -a -s "$W/out1/core-manifest.sig"
has "清单里有 seq 行" '^seq\|100$' "$(cat "$W/out1/core-manifest.conf")"
cp "$W/out1"/core-manifest.* "$W/srv/core/"
t_ok "客户端拉取 + 验签 + 保存" core_manifest_refresh
t_ok "本机保存了清单和签名" test -s "$H/core-manifest.conf" -a -s "$H/core-manifest.sig"
eq "验签通过后 core_manifest_rows 有 5 行" "$(core_manifest_rows | wc -l | tr -d ' ')" "5"

echo "== C3. 清单的安全性: 防回滚 · 篡改 · 错钥匙 · 本机文件被改"
mkdir -p "$W/out0"; bash "$REPO/tools/build-core-manifest.sh" "$W/in/m.txt" "$W/out0" "$W/ckey.pem" 99 >/dev/null 2>&1
cp "$W/out0"/core-manifest.* "$W/srv/core/"
t_no "seq 比本机的小 (99 < 100): 拒绝, 防止换回旧清单" core_manifest_refresh
eq "拒绝之后本机仍是 seq=100" "$(core_manifest_seq "$H/core-manifest.conf")" "100"
mkdir -p "$W/out2"; bash "$REPO/tools/build-core-manifest.sh" "$W/in/m.txt" "$W/out2" "$W/ckey.pem" 101 >/dev/null 2>&1
cp "$W/out2"/core-manifest.* "$W/srv/core/"
t_ok "seq 变大 (101): 接受" core_manifest_refresh
eq "更新之后本机是 seq=101" "$(core_manifest_seq "$H/core-manifest.conf")" "101"
mkdir -p "$W/out3"; bash "$REPO/tools/build-core-manifest.sh" "$W/in/m.txt" "$W/out3" "$W/ckey.pem" 102 >/dev/null 2>&1
cp "$W/out3"/core-manifest.* "$W/srv/core/"; printf '1.99.9|darwin-arm64|%s|2.0.0|\n' "$SHA_C" >> "$W/srv/core/core-manifest.conf"
t_no "清单被篡改 (多了一行, 签名对不上): 拒绝" core_manifest_refresh
eq "拒绝之后本机仍是 seq=101" "$(core_manifest_seq "$H/core-manifest.conf")" "101"
cp "$W/out3"/core-manifest.* "$W/srv/core/"; /usr/bin/openssl dgst -sha256 -sign "$W/other.pem" -out "$W/srv/core/core-manifest.sig" "$W/srv/core/core-manifest.conf"
t_no "用别的私钥签名: 拒绝" core_manifest_refresh
t_no "生成工具: 私钥和公钥对不上时不输出任何文件" env ENANA_CLOUD_PUBKEY="$W/other-pub.pem" bash "$REPO/tools/build-core-manifest.sh" "$W/in/m.txt" "$W/out4" "$W/ckey.pem" 7
eq "生成工具拒绝时没有留下输出文件" "$(ls "$W/out4" 2>/dev/null | wc -l | tr -d ' ')" "0"
printf '1.14.9|darwin-arm64|zzz|2.3.0|\n' > "$W/in/bad.txt"
bad=$(bash "$REPO/tools/build-core-manifest.sh" "$W/in/bad.txt" "$W/out5" "$W/ckey.pem" 8 2>&1); rc=$?
eq "生成工具: SHA-256 格式不对时拒绝" "$([ "$rc" != 0 ] && echo rejected || echo accepted)" "rejected"
has "生成工具: 报错说的是 SHA-256 的问题 (不是文件不存在)" 'SHA-256 必须是 64 位' "$bad"
mkdir -p "$W/relfiles/1.14.2"; printf 'fake-core' > "$W/relfiles/1.14.2/sing-box-1.14.2-darwin-arm64.tar.gz"
printf '1.14.2|darwin-arm64|%s|2.3.0|\n' "$SHA_A" > "$W/in/mismatch.txt"
mm=$(bash "$REPO/tools/build-core-manifest.sh" "$W/in/mismatch.txt" "$W/out6" "$W/ckey.pem" 9 "$W/relfiles" 2>&1); rc=$?
eq "生成工具: 清单里的 SHA-256 和要发布的文件对不上时拒绝" "$([ "$rc" != 0 ] && echo rejected || echo accepted)" "rejected"
has "生成工具: 报错指出 SHA-256 和文件不一致" '不一致' "$mm"
printf '1.14.2|darwin-arm64|%s|2.3.0|\n' "$(shasum -a 256 "$W/relfiles/1.14.2/sing-box-1.14.2-darwin-arm64.tar.gz" | awk '{print $1}')" > "$W/in/match.txt"
t_ok "生成工具: SHA-256 和文件一致时通过" bash "$REPO/tools/build-core-manifest.sh" "$W/in/match.txt" "$W/out7" "$W/ckey.pem" 10 "$W/relfiles"
cp "$H/core-manifest.conf" "$W/saved.conf"; printf '1.99.9|darwin-arm64|%s|2.0.0|\n' "$SHA_C" >> "$H/core-manifest.conf"
eq "本机清单文件被改过: 读取时重新验签, 不再生效" "$(core_manifest_rows | wc -l | tr -d ' ')" "0"
cp "$W/saved.conf" "$H/core-manifest.conf"
eq "改回去之后恢复生效" "$(core_manifest_rows | wc -l | tr -d ' ')" "5"

echo "== C4. 兼容选择: 按 enana 版本范围和架构挑最新的核心"
eq "enana 2.3.8 (arm64): 1.14.4 (最高到 2.3.8) 是最新兼容的" "$( VERSION=2.3.8; core_latest_compat )" "1.14.4"
eq "enana 2.3.9 (arm64): 1.14.4 已过了最高版本, 取 1.14.3" "$( VERSION=2.3.9; core_latest_compat )" "1.14.3"
eq "enana 2.4.0 (arm64): 取 1.15.0" "$( VERSION=2.4.0; core_latest_compat )" "1.15.0"
eq "enana 2.2.0: 低于所有最低要求, 没有兼容版本" "$( VERSION=2.2.0; core_latest_compat )" ""
eq "amd64 + enana 2.3.9: 只看 amd64 的行, 取 1.14.3" "$( VERSION=2.3.9; ARCH=amd64; core_latest_compat )" "1.14.3"
eq "amd64 + enana 2.3.8: amd64 没有兼容版本" "$( VERSION=2.3.8; ARCH=amd64; core_latest_compat )" ""
eq "core_pin_sha: 随程序发布的钉死值优先 (和 core-pins.conf 一致)" "$(core_pin_sha 1.14.2 darwin-arm64)" "$(awk -F'|' '$1=="1.14.2" && $2=="darwin-arm64" {print $3}' "$DATA/core-pins.conf")"
eq "core_pin_sha: 随程序发布的版本里没有时, 取清单里的" "$(core_pin_sha 1.15.0 darwin-arm64)" "$SHA_C"
eq "core_pin_sha: 清单也没有时为空 (不钉死, 只能用官方源)" "$(core_pin_sha 7.7.7 darwin-arm64)" ""

echo "== C4b. ARCH / MACOS_MAJOR 只在安装时设置: 仪表盘 / 后台任务进程里没有, core_names 要自己判断"
WANT=darwin-amd64; [ "$(uname -m)" = arm64 ] && WANT=darwin-arm64; [ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" = 1 ] && WANT=darwin-arm64
eq "ARCH 没设置: 按这台电脑判断 ($WANT)" "$( unset ARCH MACOS_MAJOR; core_names )" "$WANT"
eq "ARCH 设置了就用它 (amd64)" "$( ARCH=amd64 MACOS_MAJOR=14; core_names )" "darwin-amd64"
eq "旧 macOS (10.x) + amd64: 先找 legacy 构建, 再找普通构建" "$( ARCH=amd64 MACOS_MAJOR=10; core_names )" "darwin-amd64-legacy-macos-10.13 darwin-amd64"
eq "arm64 不受 macOS 版本影响" "$( ARCH=arm64 MACOS_MAJOR=10; core_names )" "darwin-arm64"
eq "没有设置 ARCH 时 core_latest_compat 也能工作 (这正是仪表盘进程里的情况)" "$( unset ARCH MACOS_MAJOR; VERSION=2.3.9; cp \"$W/out2/core-manifest.conf\" \"$H/core-manifest.conf\"; cp \"$W/out2/core-manifest.sig\" \"$H/core-manifest.sig\"; [ \"$(core_names)\" != darwin-amd64 ] && echo has-arm64-or-other; core_latest_compat )" "$([ "$WANT" = darwin-arm64 ] && printf 'has-arm64-or-other\n1.14.3' || printf '1.14.3')"

echo "== C5. 低速立即换源的参数真的传给了 curl"
curl() { printf '%s\n' "$*" > "$W/curl.args"; return 0; }
_dl "https://example.invalid/x" "$W/x.out" >/dev/null 2>&1
eq "默认: 最后生效的最低速度是 10240 B/s" "$(grep -o -- '--speed-limit [0-9]*' "$W/curl.args" | tail -1)" "--speed-limit 10240"
DL_SPEED=204800 DL_SPEED_TIME=20 _dl "https://example.invalid/x" "$W/x.out" >/dev/null 2>&1
eq "DL_SPEED: 最后生效的最低速度是 204800 B/s" "$(grep -o -- '--speed-limit [0-9]*' "$W/curl.args" | tail -1)" "--speed-limit 204800"
eq "DL_SPEED: 低速持续 20 秒就放弃" "$(grep -o -- '--speed-time [0-9]*' "$W/curl.args" | tail -1)" "--speed-time 20"
unset -f curl

echo "== C6. 官方源不可用时, 从项目自己的目录下载并校验 SHA-256"
mkdir -p "$W/data" "$W/pkg/sing-box-9.9.9-darwin-arm64" "$W/srv/core/9.9.9"
cp "$REPO"/data/* "$W/data/" 2>/dev/null
printf '#!/bin/sh\necho "sing-box version 9.9.9"\n' > "$W/pkg/sing-box-9.9.9-darwin-arm64/sing-box"; chmod +x "$W/pkg/sing-box-9.9.9-darwin-arm64/sing-box"
( cd "$W/pkg" && COPYFILE_DISABLE=1 tar -czf "$W/srv/core/9.9.9/sing-box-9.9.9-darwin-arm64.tar.gz" sing-box-9.9.9-darwin-arm64 )
SHA_T=$(shasum -a 256 "$W/srv/core/9.9.9/sing-box-9.9.9-darwin-arm64.tar.gz" | awk '{print $1}')
printf '# 官方源指向一个不存在的文件: 模拟 GitHub 连不上\nfile://%s/nowhere/sing-box-{ver}-{name}.tar.gz\n' "$W" > "$W/data/core-sources.conf"
: > "$W/data/mirrors.conf"
printf '9.9.9|darwin-arm64|%s\n' "$SHA_T" > "$W/data/core-pins.conf"
DATA_SAVE=$DATA; DATA=$W/data
rm -f "$H/sing-box.new"
SINGBOX_VERSION=9.9.9 core_from_chain >"$W/chain.out" 2>&1; rc=$?
eq "官方源失败后, 从项目自己的目录下载成功" "$rc" "0"
t_ok "解出了可执行的 sing-box.new" test -x "$H/sing-box.new"
has "输出里能看到用的是项目自己的目录" "$W/srv/core/9.9.9" "$(cat "$W/chain.out")"
printf '9.9.9|darwin-arm64|%s\n' "$SHA_A" > "$W/data/core-pins.conf"
rm -f "$H/sing-box.new"
SINGBOX_VERSION=9.9.9 core_from_chain >"$W/chain2.out" 2>&1; rc=$?
eq "SHA-256 和钉死值不一致: 下载失败, 不安装" "$([ "$rc" != 0 ] && echo failed || echo installed)" "failed"
t_ok "没有留下 sing-box.new" test ! -e "$H/sing-box.new"
printf '' > "$W/data/core-pins.conf"
SINGBOX_VERSION=9.9.9 core_from_chain >"$W/chain3.out" 2>&1; rc=$?
eq "没有钉死的版本: 只试官方, 不会去项目目录 (官方又失败, 所以整体失败)" "$([ "$rc" != 0 ] && echo failed || echo installed)" "failed"

echo "== C6b. 只要钉死的下载 (CORE_PINNED_ONLY=1, 升级时为 TUN 重新钉死核心): 记下 pinned 来源和摘要; 没有 SHA-256 / 下载失败时不回落到 Homebrew, 原来的核心不动"
SB=$H/sing-box
mkdir -p "$W/fakebrew/prefix/bin"
printf '#!/bin/sh\necho "sing-box version 0.0.1"\n' > "$W/fakebrew/prefix/bin/sing-box"
cat > "$W/fakebrew/brew" <<EOF
#!/bin/sh
# 假的 Homebrew (放在 PATH 最前面): 记下每次调用; install 假装成功, --prefix 指向放着假核心的目录 —— 真被调用了, 核心就会被换掉, 来源记成 unpinned
printf '%s\n' "\$*" >> "$W/brew.calls"
[ "\$1" = --prefix ] && echo "$W/fakebrew/prefix"
exit 0
EOF
chmod +x "$W/fakebrew/brew" "$W/fakebrew/prefix/bin/sing-box"
printf '#!/bin/sh\necho "sing-box version 1.14.2"\n# 原来的核心\n' > "$SB"; chmod +x "$SB"; cp -p "$SB" "$W/sb.before"
printf 'unpinned chain\n' > "$H/core-provenance"; shasum -a 256 "$SB" | awk '{print $1}' > "$H/core-binary.sha256"
cp -p "$H/core-provenance" "$W/prov.before"; cp -p "$H/core-binary.sha256" "$W/binsha.before"
core_before() { cp -p "$W/sb.before" "$SB"; cp -p "$W/prov.before" "$H/core-provenance"; cp -p "$W/binsha.before" "$H/core-binary.sha256"; rm -f "$H/sing-box.new"; : > "$W/brew.calls"; }
core_unchanged() { cmp -s "$SB" "$W/sb.before" && cmp -s "$H/core-provenance" "$W/prov.before" && cmp -s "$H/core-binary.sha256" "$W/binsha.before"; }
brew_calls() { wc -l < "$W/brew.calls" | tr -d ' '; }
core_before; printf '9.9.9|darwin-arm64|%s\n' "$SHA_T" > "$W/data/core-pins.conf"
PATH="$W/fakebrew:$PATH" SINGBOX_VERSION=9.9.9 CORE_PINNED_ONLY=1 core_install chain >"$W/pinned.out" 2>&1; rc=$?
eq "有钉死的 SHA-256: 下载并安装成功" "$rc" "0"
eq "…来源记成 pinned 9.9.9 <压缩包的 SHA-256>" "$(cat "$H/core-provenance")" "pinned 9.9.9 $SHA_T"
eq "…二进制的摘要记进 core-binary.sha256 (TUN 预检拿它核对核心有没有被改动)" "$(cat "$H/core-binary.sha256")" "$(shasum -a 256 "$W/pkg/sing-box-9.9.9-darwin-arm64/sing-box" | awk '{print $1}')"
t_ok "…核心换成了压缩包里的那一份" cmp -s "$SB" "$W/pkg/sing-box-9.9.9-darwin-arm64/sing-box"
t_ok "…TUN 预检会放行这个核心 (core_tun_ok)" core_tun_ok
eq "…没有调用 Homebrew" "$(brew_calls)" "0"
core_before; : > "$W/data/core-pins.conf"
PATH="$W/fakebrew:$PATH" SINGBOX_VERSION=9.9.9 CORE_PINNED_ONLY=1 core_install chain >"$W/nopin.out" 2>&1; rc=$?
eq "没有钉死的 SHA-256: 失败" "$([ "$rc" != 0 ] && echo failed || echo installed)" "failed"
hasnt "…一个构建都没有下载 (连官方源都不试)" '尝试 \[' "$(cat "$W/nopin.out")"
has "…说明了原因" '没有钉死的 SHA-256' "$(cat "$W/nopin.out")"
eq "…没有回落到 Homebrew" "$(brew_calls)" "0"
t_ok "…原来的核心、来源和摘要记录都没有改动" core_unchanged
t_ok "…没有留下 sing-box.new" test ! -e "$H/sing-box.new"
core_before; printf '9.9.9|darwin-arm64|%s\n' "$SHA_A" > "$W/data/core-pins.conf"
PATH="$W/fakebrew:$PATH" SINGBOX_VERSION=9.9.9 CORE_PINNED_ONLY=1 core_install chain >"$W/pinfail.out" 2>&1; rc=$?
eq "有钉死的 SHA-256, 但所有线路都下载失败 (这里: 内容和钉死值对不上): 失败" "$([ "$rc" != 0 ] && echo failed || echo installed)" "failed"
eq "…没有回落到 Homebrew" "$(brew_calls)" "0"
t_ok "…原来的核心、来源和摘要记录都没有改动" core_unchanged
t_ok "…没有留下 sing-box.new" test ! -e "$H/sing-box.new"
core_before
if [ "$(PATH="$W/fakebrew:$PATH"; command -v brew)" = "$W/fakebrew/brew" ]; then          # 对照会真的走 Homebrew 那条路: 只在找到的确实是假的 brew 时才跑
  PATH="$W/fakebrew:$PATH" SINGBOX_VERSION=9.9.9 core_install chain >"$W/brewfb.out" 2>&1; rc=$?
  eq "对照: 不要求钉死时, 同样的失败会回落到 (假的) Homebrew —— 上面的「没有调用」不是因为找不到 brew" "$rc:$(grep -c '^install sing-box$' "$W/brew.calls")" "0:1"
  eq "…这样装上的核心来源记成 unpinned (TUN 不会用它)" "$(cut -d' ' -f1 "$H/core-provenance")" "unpinned"
else tfail "假的 brew 没有排在 PATH 最前面: 跳过对照 (不能调用真的 Homebrew)"; fi
DATA=$DATA_SAVE

echo "== C7. 检查更新里的 core_latest 只来自清单, 不再跟着 GitHub 的 latest"
mkdir -p "$W/upd"; printf '9.9.9\n' > "$W/upd/VERSION"; printf '## 9.9.9 (2026-01-01)\n### 中文\n- 测试\n### English\n- test\n' > "$W/upd/CHANGELOG.md"
export ENANA_UPDATE_BASE="file://$W/upd" ENANA_CORE_LATEST=99.0.0
cp "$W/out2"/core-manifest.* "$W/srv/core/"; rm -f "$H/core-manifest.conf" "$H/core-manifest.sig" "$H/update.json"
VERSION=2.3.9 update_check force >/dev/null 2>&1
eq "有清单: core_latest 是清单里兼容的版本 (1.14.3), 不是 GitHub 的 99.0.0" "$(sed -n 's/.*"core_latest":"\([^"]*\)".*/\1/p' "$H/update.json")" "1.14.3"
rm -f "$H/core-manifest.conf" "$H/core-manifest.sig" "$H/update.json"; rm -f "$W/srv/core/core-manifest.conf" "$W/srv/core/core-manifest.sig"
VERSION=2.3.9 update_check force >/dev/null 2>&1
eq "没有清单: core_latest 为空 (不提示核心更新)" "$(sed -n 's/.*"core_latest":"\([^"]*\)".*/\1/p' "$H/update.json")" ""
unset ENANA_UPDATE_BASE ENANA_CORE_LATEST

P=$(grep -c p "$W/.pass" 2>/dev/null || true); F=$(grep -c f "$W/.fail" 2>/dev/null || true); P=${P:-0}; F=${F:-0}
echo; echo "core.sh: $P passed, $F failed"; [ "$F" = 0 ]
