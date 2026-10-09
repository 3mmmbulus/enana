#!/bin/bash
# get.sh (一行安装命令) 的流程测试 (macOS, bash 3.2): 一台本机「下载服务器」+ 隔离目录, 把安装 / 升级整条链路真的跑一遍
#   首次安装 → 校验失败被拦截 → 两条线路的清单不一致被拦截 → 主线路的坏包自动换线路 → 升级并保留用户数据 → 已是最新 → enana self-update
#
#   SINGBOX=/路径/sing-box bash tests/get-test.sh [PKG_DIR]
#   PKG_DIR (可选): 已经构建好的发布目录 (含 manifest.json / enana-<版本>.tar.gz / get.sh), 用来检查「真正要发布的那一份」;
#                   不给就从本仓库现场打一份同样布局的。
# 系统命令 (launchctl / networksetup / sudo / open) 用 tests/fakebin 里的假命令并有硬性保护; 「下载服务」「GitHub」「互联网」
# 都是本机的模拟服务, 不产生任何外部流量。
set -u
export LC_ALL=C # Byte-oriented shell/log checks also handle macOS Bash 3.2.
HERE=$(cd "$(dirname "$0")" && pwd -P); REPO=$(dirname "$HERE")
SB=${SINGBOX:-$(command -v sing-box || true)}
[ -x "$SB" ] || { echo "跳过: 需要 sing-box 二进制 (SINGBOX=/路径/sing-box)"; exit 77; }
command -v python3 >/dev/null || { echo "跳过: 需要 python3"; exit 77; }
PKG=${1:-}; [ -z "$PKG" ] || PKG=$(cd "$PKG" && pwd -P)

W=$(mktemp -d /tmp/enana-gettest.XXXXXX)
# 测试专用的签名密钥 (只在这份临时目录里, 不是发布密钥); get.sh 通过 ENANA_RELEASE_PUBKEY_FILE 用它的公钥校验清单
openssl ecparam -name prime256v1 -genkey -noout -out "$W/test-key.pem" && openssl ec -in "$W/test-key.pem" -pubout -out "$W/test-pub.pem" 2>/dev/null
# 用生成的测试公钥校验; 指定了发布目录 (真正要发布的那一份) 时不覆盖, 让 get.sh 用内置的正式公钥校验
[ -n "$PKG" ] || export ENANA_RELEASE_PUBKEY_FILE="$W/test-pub.pem"
sign_manifest() { openssl dgst -sha256 -sign "$W/test-key.pem" -out "$1.sig" "$1"; }   # 与 tools/sign-release.sh 一样的签名方式
BASE=$((20000 + RANDOM % 20000))
export PORT=$BASE UI_PORT=$((BASE+1)) API_PORT=$((BASE+2)) SPEED_PORT=$((BASE+3))
DL_PORT=$((BASE+4)); GH_PORT=$((BASE+5)); N_PORT=$((BASE+6))
export FAKE_STATE=$W/state TESTS_DIR=$HERE HOME=$W/home ENANA_HOME=$W/h ENANA_SHORTCUT_DIR=$W/shortcut ENANA_PLIST_DIR=$W/home/Library/LaunchAgents
# Keep a real Enhanced installation on the host outside this installer fixture.
export ENANA_TUN_ROOT="$W/tun-root" ENANA_TUN_PLIST_DIR="$W/tun-plists"
export ENANA_SKIP_PROBE=1 ENANA_LANG=zh ENANA_CORE_LATEST=99.0.0 ENANA_ACCOUNT_URL=http://127.0.0.1:1
export ENANA_RULE_SOURCE=http://127.0.0.1:$N_PORT/rules/{file} ENANA_IPLOOKUP_URL=http://127.0.0.1:$N_PORT/ip ENANA_IPLOOKUP_URL2=http://127.0.0.1:$N_PORT/trace
export ENANA_INSTALL_BASE=http://127.0.0.1:$DL_PORT ENANA_UPDATE_BASE=http://127.0.0.1:$DL_PORT/dl ENANA_GH_REPO=test/enana ENANA_GH_BASE=http://127.0.0.1:$GH_PORT
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY; export NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost
mkdir -p "$W"/{state,tmp,home/Library/LaunchAgents,shortcut,h/rules,www/dl,gh,rules-src}
export TMPDIR=$W/tmp          # get.sh / 安装器的临时目录都落在测试目录里, 方便检查有没有清理干净
export PATH="$HERE/fakebin:$PATH"
for c in launchctl networksetup sudo open; do
  case "$(command -v $c)" in "$HERE"/fakebin/*) ;; *) echo "REFUSING: 真实的 $c 出现在 PATH 中, 为防止改动系统已中止"; exit 1 ;; esac
done
cleanup() { for f in "$FAKE_STATE"/pid-* "$W"/pid-*; do [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null; done; sleep 0.3; pkill -f "$W/" 2>/dev/null; if [ -n "${KEEP_W:-}" ]; then echo "(保留测试目录 $W)"; else rm -rf "$W"; fi; }
trap cleanup EXIT

tpass() { echo p >> "$W/.pass"; echo "  ✓ $1"; }
tfail() { echo f >> "$W/.fail"; echo "  ✗ $1"; }
expect() { local d=$1; shift; if "$@" >/dev/null 2>&1; then tpass "$d"; else tfail "$d"; fi; }
plain() { sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g'; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
U=http://127.0.0.1:$UI_PORT; A=http://127.0.0.1:$API_PORT
waitport() { local i; for i in $(seq 1 40); do nc -z 127.0.0.1 "$1" 2>/dev/null && return 0; sleep 0.25; done; return 1; }
installed() { IFS= read -r v < "$W/h/VERSION" 2>/dev/null || v=''; printf '%s' "$v"; }

# 打一份发布目录 (布局与服务器上的 /var/www/enana-dl/ 一致): mkpkg <版本> <目录> [从哪个版本的 stage 复制]
mkpkg() {
  local v=$1 o=$2 s="$W/stage-$1/enana-$1" sum size
  rm -rf "$W/stage-$v"; mkdir -p "$s" "$o"
  ( cd "$REPO" && cp -R install.sh lib data ui CHANGELOG.md get.sh "$s/" ); printf '%s\n' "$v" > "$s/VERSION"
  tar -C "$W/stage-$v" -czf "$o/enana-$v.tar.gz" "enana-$v"
  sum=$(sha "$o/enana-$v.tar.gz"); size=$(wc -c < "$o/enana-$v.tar.gz" | tr -d ' ')
  printf '{"version":"%s","sha256":"%s","size":%s,"url":"/dl/enana-%s.tar.gz","released":"2026-01-01T00:00:00Z"}\n' "$v" "$sum" "$size" "$v" > "$o/manifest.json"
  sign_manifest "$o/manifest.json"
  printf '%s\n' "$v" > "$o/VERSION"; cp "$REPO/CHANGELOG.md" "$REPO/get.sh" "$o/"
}
# 把一个发布目录挂到「官网」(DL) 和「GitHub」(GH) 两条线路上
serve() { # serve <发布目录>
  local d=$1 v; v=$(sed -n 's/.*"version":"\([^"]*\)".*/\1/p' "$d/manifest.json")
  mkdir -p "$W/www/dl" "$W/gh/test/enana/releases/latest/download" "$W/gh/test/enana/releases/download/v$v"
  cp "$d"/* "$W/www/dl/"
  cp "$d/manifest.json" "$d/manifest.json.sig" "$W/gh/test/enana/releases/latest/download/"; cp "$d/enana-$v.tar.gz" "$W/gh/test/enana/releases/download/v$v/"
}

echo "== 准备夹具 (本机模拟的下载服务 / GitHub / 互联网)"
cp "$SB" "$W/h/sing-box"; chmod +x "$W/h/sing-box"
printf '{"version":3,"rules":[{"domain_suffix":["nothing.enana.invalid"]}]}' > "$W/rules-src/_default.json"
"$SB" rule-set compile --output "$W/rules-src/_default.srs" "$W/rules-src/_default.json" >/dev/null 2>&1; rm -f "$W/rules-src/_default.json"
python3 "$HERE/mock-net.py" $N_PORT "$W/rules-src" & echo $! > "$W/pid-net"
python3 -m http.server $DL_PORT --bind 127.0.0.1 -d "$W/www" >/dev/null 2>&1 & echo $! > "$W/pid-dl"
python3 -m http.server $GH_PORT --bind 127.0.0.1 -d "$W/gh" >/dev/null 2>&1 & echo $! > "$W/pid-gh"
if [ -n "$PKG" ]; then
  cp -R "$PKG" "$W/pkg"; VER=$(sed -n 's/.*"version":"\([^"]*\)".*/\1/p' "$W/pkg/manifest.json"); GET=$W/pkg/get.sh
  echo "  使用已构建的发布目录: $PKG (v$VER)"
else
  VER=$(tr -d ' \r\n' < "$REPO/VERSION"); mkpkg "$VER" "$W/pkg"; GET=$W/pkg/get.sh
fi
serve "$W/pkg"
waitport $N_PORT && waitport $DL_PORT && waitport $GH_PORT && tpass "模拟服务已就绪" || tfail "模拟服务已就绪"
expect "发布目录里的 manifest 与 tarball 对得上 (大小 / SHA-256)" test "$(sha "$W/pkg/enana-$VER.tar.gz")" = "$(sed -n 's/.*"sha256":"\([^"]*\)".*/\1/p' "$W/pkg/manifest.json")"
expect "tarball 里没有 tests / docs / tools / server / 私钥" sh -c "! tar -tzf '$W/pkg/enana-$VER.tar.gz' | grep -E '^enana-[^/]+/(tests|docs|tools|server|\\.git)(/|\$)' && ! tar -xzOf '$W/pkg/enana-$VER.tar.gz' | grep -aqE '^-----BEGIN [A-Z ]*PRIVATE KEY-----'"

echo "== 1. 首次安装: curl … | bash 等价流程 (get.sh --yes)"
OUT=$(bash "$GET" --yes --lang zh 2>&1); RC=$?; OUT=$(echo "$OUT" | plain); echo "$OUT" | grep -E '^ *(▸|✓|!|✗)' | sed 's/^/    /'
expect "get.sh 退出码 0" test "$RC" = 0
echo "$OUT" | grep -q "最新版本: v$VER" && tpass "查到最新版本" || tfail "查到最新版本"
echo "$OUT" | grep -q 'SHA-256 校验通过' && tpass "下载并通过 SHA-256 校验" || tfail "下载并通过 SHA-256 校验"
echo "$OUT" | grep -q '环境安装完成' && tpass "安装器跑完" || tfail "安装器跑完"
expect "安装的版本 = 发布的版本" test "$(installed)" = "$VER"
expect "get.sh 已复制到安装目录 (供 enana self-update 使用)" test -s "$W/h/get.sh"
expect "后台 /enana/admin/ 返回 200" test "$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' $A/enana/admin/)" = 200
expect "快捷命令可用" test "$("$W/shortcut/enana" version)" = "enana $VER"
expect "辅助服务在监听且要求自定义请求头" test "$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' $A/api/auth/status)" != 000
expect "没有生成任何本地密码文件" test ! -e "$W/h/auth.conf"
ls -d "$TMPDIR"/enana-get.* >/dev/null 2>&1 && tfail "get.sh 退出后清理了自己的临时目录" || tpass "get.sh 退出后清理了自己的临时目录"

echo "== 2. 安全: 包被篡改 / 清单不一致时必须拒绝, 且不改动已安装的版本"
cp "$W/www/dl/manifest.json" "$W/manifest.good"; cp "$W/gh/test/enana/releases/latest/download/manifest.json" "$W/manifest.gh.good"
sed -i '' 's/"sha256":"[0-9a-f]\{64\}"/"sha256":"0000000000000000000000000000000000000000000000000000000000000000"/' "$W/www/dl/manifest.json"
rm -f "$W/gh/test/enana/releases/latest/download/manifest.json" "$W/gh/test/enana/releases/latest/download/manifest.json.sig"
OUT=$(ENANA_GH_BASE=http://127.0.0.1:1 bash "$GET" --yes --lang zh 2>&1); RC=$?; OUT=$(echo "$OUT" | plain)
expect "清单里的哈希与包不符 → 失败 (退出码非 0)" test "$RC" != 0
if echo "$OUT" | grep -q '签名无效'; then tpass "提示「签名无效」(清单被改过, 签名对不上)"; else tfail "提示「签名无效」(清单被改过, 签名对不上)"; echo "$OUT" | head -6 | sed 's/^/      got: /'; fi
expect "已安装的版本没有被改动" test "$(installed)" = "$VER"
cp "$W/manifest.good" "$W/www/dl/manifest.json"                      # 官网清单恢复; GitHub 线路给一份「不一致」的清单
sed 's/"sha256":"[0-9a-f]\{64\}"/"sha256":"1111111111111111111111111111111111111111111111111111111111111111"/' "$W/manifest.gh.good" > "$W/gh/test/enana/releases/latest/download/manifest.json"; sign_manifest "$W/gh/test/enana/releases/latest/download/manifest.json"
OUT=$(bash "$GET" --yes --lang zh 2>&1); RC=$?; OUT=$(echo "$OUT" | plain)
expect "两条线路的清单不一致 → 失败" test "$RC" != 0
echo "$OUT" | grep -q '清单不一致' && tpass "提示「清单不一致」(可能被篡改)" || tfail "提示「清单不一致」(可能被篡改)"
cp "$W/manifest.gh.good" "$W/gh/test/enana/releases/latest/download/manifest.json"; sign_manifest "$W/gh/test/enana/releases/latest/download/manifest.json"
: > "$W/www/dl/enana-$VER.tar.gz"                                    # 官网线路的包坏了 (空文件), GitHub 线路是好的 → 自动换线路
OUT=$(bash "$GET" --yes --lang zh 2>&1); RC=$?; OUT=$(echo "$OUT" | plain)
expect "主线路的包损坏 → 自动换到下一条线路并成功" test "$RC" = 0
echo "$OUT" | grep -q '换下一条' && tpass "提示「换下一条」" || tfail "提示「换下一条」"
expect "换线路安装后版本正确" test "$(installed)" = "$VER"
cp "$W/pkg/enana-$VER.tar.gz" "$W/www/dl/enana-$VER.tar.gz"

echo "== 3. 升级: 保留用户数据; 已是最新时什么也不做"
printf '{"role":"auto","outbound":{"type":"socks","tag":"Keep-Me","server":"127.0.0.1","server_port":1,"version":"5"}}\n' > "$W/h/servers.jsonl"; chmod 600 "$W/h/servers.jsonl"
printf 'LOG_DAYS=45\n' >> "$W/h/settings.env"
before=$(sha "$W/h/servers.jsonl")
NEW=9.9.9; mkpkg "$NEW" "$W/pkg2"; serve "$W/pkg2"
OUT=$(bash "$GET" --upgrade --lang zh 2>&1); RC=$?; OUT=$(echo "$OUT" | plain); echo "$OUT" | grep -E '^ *(▸|✓|!|✗)' | sed 's/^/    /'
expect "get.sh --upgrade 退出码 0" test "$RC" = 0
echo "$OUT" | grep -q "已安装 v$VER" && tpass "识别出已安装的旧版本" || tfail "识别出已安装的旧版本"
expect "升级到新版本" test "$(installed)" = "$NEW"
expect "服务器列表原样保留" test "$(sha "$W/h/servers.jsonl")" = "$before"
expect "用户设置保留 (LOG_DAYS=45)" grep -q '^LOG_DAYS=45$' "$W/h/settings.env"
waitport "$API_PORT" && expect "升级后辅助服务可用" test "$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' $A/api/auth/status)" != 000
expect "升级后仪表盘仍可访问" test "$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' $A/enana/admin/)" = 200
OUT=$(bash "$GET" --upgrade --lang zh 2>&1); RC=$?; OUT=$(echo "$OUT" | plain)
expect "已是最新版本: 退出码 0" test "$RC" = 0
echo "$OUT" | grep -q '已经是最新版本' && tpass "提示「已经是最新版本」且不再下载" || tfail "提示「已经是最新版本」且不再下载"
echo "$OUT" | grep -q 'SHA-256' && tfail "已是最新版本时没有重复下载" || tpass "已是最新版本时没有重复下载"

echo "== 4. enana self-update (安装目录里的 get.sh)"
NEW2=9.9.10; mkpkg "$NEW2" "$W/pkg3"; serve "$W/pkg3"
OUT=$(ENANA_YES=1 "$W/shortcut/enana" self-update 2>&1); RC=$?; OUT=$(echo "$OUT" | plain)
expect "self-update 退出码 0" test "$RC" = 0
expect "self-update 升到更新的版本" test "$(installed)" = "$NEW2"
expect "self-update 后快捷命令版本一致" test "$("$W/shortcut/enana" version)" = "enana $NEW2"
OUT=$(ENANA_YES=1 "$W/shortcut/enana" self-update 2>&1 | plain); echo "$OUT" | grep -q '已经是最新版本' && tpass "再次 self-update: 已经是最新版本" || tfail "再次 self-update: 已经是最新版本"

echo "== 5. 没有 curl 的系统: 用 wget 下载 (ENANA_DL=wget + 本机的 wget 替身)"
mkdir -p "$W/wbin"; cat > "$W/wbin/wget" <<'EOF'
#!/bin/bash
# 测试用的 wget 替身: 支持 get.sh 用到的参数 (-q -O- -O 文件 -T 秒 --tries=N --show-progress), 实际用 curl 下载
out=''; url=''; while [ $# -gt 0 ]; do case $1 in -qO-) out=- ;; -q) ;; -O) out=$2; shift ;; -O-) out=- ;; -T) shift ;; --tries=*) ;; --show-progress) ;; *) url=$1 ;; esac; shift; done
echo "wget $url" >> "$WGET_LOG"
if [ "$out" = - ]; then exec curl -fsSL --max-time 20 "$url"; else exec curl -fsSL --max-time 60 -o "$out" "$url"; fi
EOF
chmod +x "$W/wbin/wget"; export WGET_LOG=$W/wget.log; : > "$WGET_LOG"
NEW3=9.9.11; mkpkg "$NEW3" "$W/pkg4"; serve "$W/pkg4"
OUT=$(PATH="$W/wbin:$PATH" ENANA_DL=wget bash "$GET" --upgrade --lang zh 2>&1); RC=$?; OUT=$(echo "$OUT" | plain)
expect "ENANA_DL=wget: 升级成功 (退出码 0)" test "$RC" = 0
expect "实际走的是 wget (清单和安装包都是通过它下载的)" sh -c "grep -q 'dl/manifest.json' '$WGET_LOG' && grep -q 'enana-$NEW3.tar.gz' '$WGET_LOG'"
expect "升级到新版本" test "$(installed)" = "$NEW3"
OUT=$(ENANA_DL=nothing PATH=/usr/bin:/bin bash "$GET" --upgrade --lang zh 2>&1); RC=$?; OUT=$(echo "$OUT" | plain)
echo "(指定一个不存在的下载工具) 退出码 $RC"; [ "$RC" != 0 ] && tpass "指定的下载工具用不了 → 失败, 而不是半路崩溃" || tfail "指定的下载工具用不了 → 失败"
OUT=$(sh "$GET" --help 2>&1 | head -3 | plain); echo "$OUT" | grep -q 'enana' && tpass "sh 运行 get.sh 也能切回 bash (--help)" || tfail "sh 运行 get.sh 也能切回 bash (--help)"
OUT=$(cat "$GET" | zsh -s -- --help 2>&1 | plain); echo "$OUT" | grep -q 'run the installer with bash' && tpass "管道给 zsh 运行 → 提示用 bash (不是一堆语法错误)" || tfail "管道给 zsh 运行 → 提示用 bash"

echo "== 6. 端口被占用 → 自动换一个随机的空闲端口; 安装完成后打印后台地址 (/enana/admin/)"
B1=$((BASE+10)); B2=$((BASE+11)); B3=$((BASE+12)); B4=$((BASE+13))
python3 -c "
import socket,sys,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(('127.0.0.1',$B1)); s.listen(5)
while True: time.sleep(1)" & echo $! > "$W/pid-busy"; sleep 0.5
mkdir -p "$W/s2/"{state,tmp,home/Library/LaunchAgents,shortcut,h/rules}; cp "$SB" "$W/s2/h/sing-box"; chmod +x "$W/s2/h/sing-box"
env2() { HOME=$W/s2/home ENANA_HOME=$W/s2/h FAKE_STATE=$W/s2/state ENANA_PLIST_DIR=$W/s2/home/Library/LaunchAgents ENANA_SHORTCUT_DIR=$W/s2/shortcut TMPDIR=$W/s2/tmp PORT=$B1 UI_PORT=$B2 API_PORT=$B3 SPEED_PORT=$B4 "$@"; }
OUT=$(env2 bash "$GET" --yes --lang zh 2>&1); RC=$?; OUT=$(echo "$OUT" | plain); echo "$OUT" | grep -E '已自动改用|后台地址' | sed 's/^/    /'
expect "端口被占用时安装仍然成功 (退出码 0)" test "$RC" = 0
NEWP=$(sed -n 's/^PORT=//p' "$W/s2/h/settings.env" | tail -1)
expect "代理端口已自动换成别的空闲端口 (写进了设置, 不是被占用的那个)" sh -c "[ -n '$NEWP' ] && [ '$NEWP' != '$B1' ] && [ '$NEWP' -ge 20000 ] && [ '$NEWP' -le 59999 ]"
echo "$OUT" | grep -q "本地端口 $B1 已被其它程序占用, 已自动改用 ${NEWP}" && tpass "输出里说明了「端口 $B1 被占用, 已自动改用 ${NEWP}」" || tfail "输出里说明了端口被占用并自动改用了哪个"
expect "新端口上代理在监听; 被占用的端口没有被动过 (占用它的程序还在)" sh -c "nc -z 127.0.0.1 '$NEWP' && kill -0 \$(cat '$W/pid-busy')"
echo "$OUT" | grep -q "后台地址.*http://127.0.0.1:$B3/enana/admin/" && tpass "安装完成后打印了后台地址 http://127.0.0.1:$B3/enana/admin/" || tfail "安装完成后打印了后台地址 http://127.0.0.1:$B3/enana/admin/"
expect "后台地址能打开 (由本地辅助服务提供)" test "$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' http://127.0.0.1:$B3/enana/admin/)" = 200
expect "核心配置里没有 external_ui, 并且只允许后台的来源跨域访问核心" sh -c "! grep -q external_ui '$W/s2/h/config.json' && grep -q 'http://127.0.0.1:$B3' '$W/s2/h/config.json'"
expect "env.json 里有 clashBase (核心控制端口) 且 apiBase 为空 (后台与辅助服务同源)" sh -c "grep -q '\"clashBase\":\"http://127.0.0.1:$B2\"' '$W/s2/h/ui/env.json' && grep -q '\"apiBase\":\"\"' '$W/s2/h/ui/env.json'"
OUT=$(env2 bash "$GET" --yes --lang zh 2>&1); RC=$?; OUT=$(echo "$OUT" | plain)
expect "再次运行 (升级): 退出码 0, 不再提示换端口, 端口保持不变" sh -c "[ '$RC' = 0 ] && ! echo '$OUT' | grep -q '已自动改用' && [ \"\$(sed -n 's/^PORT=//p' '$W/s2/h/settings.env' | tail -1)\" = '$NEWP' ]"
kill "$(cat "$W/pid-busy")" 2>/dev/null

echo "== 7. 快捷命令 enana: 装完马上能用 (放进 PATH 里已有的可写目录), 没有这样的目录才写 shell 配置"
SC() { # SC <SHELL> <PATH> <候选目录…>  在隔离环境里调用 shortcut_install, 打印 "SHORTCUT=… RC=…"
  local sh=$1 pth=$2; shift 2
  ( export HOME=$W/sc/home ENANA_HOME=$W/sc/h SHELL=$sh PATH=$pth ENANA_SHORTCUT_DIRS="$*"; unset ENANA_SHORTCUT_DIR ENANA_PLIST_DIR; rm -rf "$W/sc"; mkdir -p "$HOME" "$ENANA_HOME" "$W/binA" "$W/binB"; : > "$ENANA_HOME/enana"; chmod 755 "$ENANA_HOME/enana"
    . "$REPO/lib/common.sh"; init_paths "$REPO/install.sh"; . "$REPO/lib/i18n.sh"; . "$REPO/lib/os-darwin.sh"; load_settings
    shortcut_install; echo "SHORTCUT=$SHORTCUT RC=$SHORTCUT_RC" )
}
R=$(SC /bin/zsh "$W/binB:/usr/bin:/bin" "$W/binA" "$W/binB"); echo "$R" | grep -q "^SHORTCUT=$W/binB/enana RC=\$" && [ -L "$W/binB/enana" ] && [ ! -e "$W/binA/enana" ] && tpass "候选目录里「已经在 PATH 里」的 binB 被选中 (不在 PATH 里的 binA 跳过); 不需要重开终端" || tfail "候选目录里已经在 PATH 里的被选中 ($R)"
R=$(SC /bin/zsh "/usr/bin:/bin" "$W/binA"); echo "$R" | grep -q "^SHORTCUT=$W/sc/home/.local/bin/enana RC=$W/sc/home/.zshrc\$" && grep -q 'export PATH="$HOME/.local/bin:$PATH"' "$W/sc/home/.zshrc" && grep -q '# enana 快捷命令' "$W/sc/home/.zshrc" && tpass "没有 PATH 里的可写目录 → ~/.local/bin + 写进 ~/.zshrc (RC 非空: 提示重开终端)" || tfail "没有可用目录 → ~/.local/bin + ~/.zshrc ($R)"
R=$(SC /usr/local/bin/fish "/usr/bin:/bin" "$W/binA"); echo "$R" | grep -q "enana.fish\$" && grep -q 'set -gx PATH' "$W/sc/home/.config/fish/conf.d/enana.fish" && tpass "fish: 写 ~/.config/fish/conf.d/enana.fish" || tfail "fish 的 PATH 配置 ($R)"
R=$(SC /bin/bash "/usr/bin:/bin" "$W/binA"); echo "$R" | grep -q "RC=$W/sc/home/.bash_profile\$" && tpass "bash: 写 ~/.bash_profile" || tfail "bash 的 PATH 配置 ($R)"

P=$(grep -c p "$W/.pass" 2>/dev/null); F=$(grep -c f "$W/.fail" 2>/dev/null)
echo; echo "通过 ${P:-0} · 失败 ${F:-0}"
[ "${F:-0}" = 0 ]
