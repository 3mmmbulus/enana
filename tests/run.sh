#!/bin/bash
# 冒烟测试 (macOS, bash 3.2): 在隔离的临时目录里完整跑一遍
#   安装 → 账号登录/绑定/离线/限流/解除 → 辅助服务接口 → 热生效 → 回滚 → 设置/日志/规则库/DNS/更新 → 测速 → 国际化 → 重复运行/升级 → 维护清理 → 卸载 → 旧版迁移
# - 需要一个 sing-box 二进制:  SINGBOX=/路径/sing-box bash tests/run.sh   (没有则跳过, 退出码 77); 需要 python3
# - 系统相关命令 (launchctl / networksetup / sudo / open) 全部用 tests/fakebin 里的假命令, 并有硬性保护: 解析到真命令就拒绝运行
# - 只用占位数据; 「互联网」「enana.cc 账号服务」都是本机的模拟服务 (tests/mock-*.py), 不产生任何外部流量
set -u
HERE=$(cd "$(dirname "$0")" && pwd -P); REPO=$(dirname "$HERE")
SB=${SINGBOX:-$(command -v sing-box || true)}
[ -x "$SB" ] || { echo "跳过: 需要 sing-box 二进制 (SINGBOX=/路径/sing-box)"; exit 77; }
command -v python3 >/dev/null || { echo "跳过: 需要 python3"; exit 77; }

W=$(mktemp -d /tmp/enana-test.XXXXXX); W=$(cd "$W" && pwd -P); FAILS=0; PASSES=0
BASE=$((20000 + RANDOM % 20000))
HOP_PORT=$((BASE+4)); A_PORT=$((BASE+5)); N_PORT=$((BASE+6)); DOH_PORT=$((BASE+7)); SSHD_PORT=$((BASE+8))
VER=$(cat "$REPO/VERSION" 2>/dev/null || echo 2.1.0)
export FAKE_STATE=$W/state TESTS_DIR=$HERE HOME=$W/home ENANA_HOME=$W/h ENANA_SHORTCUT_DIR=$W/shortcut ENANA_PLIST_DIR=$W/home/Library/LaunchAgents
export FAKE_PORT=$BASE PORT=$BASE UI_PORT=$((BASE+1)) API_PORT=$((BASE+2)) SPEED_PORT=$((BASE+3)) ENANA_YES=1 ENANA_SKIP_PROBE=1
export ENANA_TUN_ROOT="$W/tun-root" ENANA_TUN_PLIST_DIR="$W/tun-plists"
export ENANA_ACCOUNT_URL=http://127.0.0.1:$A_PORT ENANA_SPEEDTEST_CONF=$W/speedtest.conf ENANA_IPLOOKUP_URL=http://127.0.0.1:$N_PORT/ip ENANA_IPLOOKUP_URL2=http://127.0.0.1:$N_PORT/trace
export ENANA_CLOUD_PUBKEY=$W/cpub.pem ENANA_UPDATE_BASE=http://127.0.0.1:$N_PORT/dl ENANA_CORE_LATEST=99.0.0 ENANA_LANG=zh ENANA_RULE_SOURCE=http://127.0.0.1:$N_PORT/rules/{file} ENANA_DNS_PRESETS=$W/dns-presets.conf
export ENANA_MOCK_CTL=$W/vpsctl ENANA_VERIFY_IP_URL=http://127.0.0.1:$N_PORT/ipraw ENANA_SSH=$HERE/fakebin/fakessh FAKE_SSH_PW='sshpw-Test-123'
mkdir -p "$W"/{state,home/Library/LaunchAgents,shortcut,h/rules,h/lib}
export ENANA_NO_MDFIND=1 ENANA_APPS_ROOTS="$W/home/Applications"            # 应用扫描只看测试夹具里的目录 (不碰这台电脑上真实的应用)
export PATH="$HERE/fakebin:$PATH"
for c in launchctl networksetup sudo open osascript; do
  case "$(command -v $c)" in "$HERE"/fakebin/*) ;; *) echo "REFUSING: 真实的 $c 出现在 PATH 中, 为防止改动系统已中止"; exit 1 ;; esac
done
cleanup() { for f in "$FAKE_STATE"/pid-* "$W"/pid-*; do [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null; done; sleep 0.3; pkill -f "$W/" 2>/dev/null; if [ -n "${KEEP_W:-}" ]; then echo "(保留测试目录 $W)"; else rm -rf "$W"; fi; }
trap cleanup EXIT

tpass() { echo p >> "$W/.pass"; echo "  ✓ $1"; }      # 计数写文件: chk 常在管道的子 shell 里运行, 变量计数会丢
tfail() { echo f >> "$W/.fail"; echo "  ✗ $1"; }
expect() { local d=$1; shift; if "$@" >/dev/null 2>&1; then tpass "$d"; else tfail "$d"; fi; }
jp() { python3 -c 'import sys,json; d=json.load(sys.stdin); '"$1"; }
chk() { local d=$1 code=$2 in; in=$(cat); if printf '%s' "$in" | jp "$code" >/dev/null 2>&1; then tpass "$d"; else tfail "$d"; printf '      ↳ %s\n' "$(printf '%s' "$in" | head -c 700)"; fi; }     # 从 stdin 读 JSON 并断言 (失败时把收到的内容打印出来)
A=http://127.0.0.1:$API_PORT; U=http://127.0.0.1:$UI_PORT; X='X-Enana: 1'; TOKEN=''
sudo_pw() { case "$(cut -d' ' -f1 "$W/h/loggedin" 2>/dev/null)" in user2@*) echo 'Another-Pass1' ;; *) echo 'New-Passw0rd2' ;; esac; }
sudo_tok() { curl -s --noproxy '*' -H "$X" -H "X-Enana-Token: $TOKEN" --data-urlencode "password=$(sudo_pw)" "$A/api/auth/verify" | jp 'print(d.get("sudo",""))'; }
api()  { # 带令牌; 敏感接口 (需要再次验证密码) 自动先换一个 sudo 令牌 (设 NO_AUTO_SUDO=1 可关掉, 用来测「没有令牌被拒」)
  local h=()
  case "$*" in *"/api/servers/delete"*|*"/api/sub/delete"*|*"/api/logs/clear"*|*"/api/devices/kick"*|*"/api/servers/secret"*|*"/api/sub/url"*|*"/api/export"*|*"/api/sync/clear"*) [ -n "${NO_AUTO_SUDO:-}" ] || h=(-H "X-Enana-Sudo: $(sudo_tok)") ;; esac
  curl -s --noproxy '*' -H "$X" -H "X-Enana-Token: $TOKEN" ${h[@]+"${h[@]}"} "$@"
}
apin() { curl -s --noproxy '*' -H "$X" "$@"; }                                       # 不带令牌
cl()   { curl -s --noproxy '*' -H "Authorization: Bearer $TOKEN" "$@"; }             # Clash API
login() { apin -X POST --data-urlencode "user=$1" --data-urlencode "password=$2" "$A/api/login"; }
job_wait() { local i s; for i in $(seq 1 90); do sleep 0.4; s=$(api "$A/api/job?id=$1" | jp 'print(d["state"])' 2>/dev/null); [ "$s" != running ] && break; done; echo "$s"; }
logconn() { : > "$W/h/sing-box.log"; curl -s -m 4 -x "socks5h://127.0.0.1:$PORT" "http://$1/" -o /dev/null 2>/dev/null; sleep 1.2; sed 's/\x1b\[[0-9;]*m//g' "$W/h/sing-box.log"; }
wait_clash_401() { local i; for i in $(seq 1 40); do [ "$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' -H "Authorization: Bearer $1" $U/proxies)" = 401 ] && return 0; sleep 0.5; done; return 1; }
mkapp() { # mkapp <目录> <名称> [可执行文件来源]: 造一个最小的、带 ad-hoc 签名的 .app
  local app="$1/$2.app" src=${3:-/usr/bin/true}; mkdir -p "$app/Contents/MacOS"; cp "$src" "$app/Contents/MacOS/${2// /-}"
  printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>test.%s</string><key>CFBundleShortVersionString</key><string>1.2.3</string><key>CFBundleExecutable</key><string>%s</string></dict></plist>' "${2// /.}" "${2// /-}" > "$app/Contents/Info.plist"
  codesign --force -s - "$app" >/dev/null 2>&1; echo "$app"
}
waitport() { local i; for i in $(seq 1 40); do nc -z 127.0.0.1 "$1" 2>/dev/null && return 0; sleep 0.25; done; return 1; }

echo "== 准备夹具 (占位数据 + 本机模拟服务)"
cp "$SB" "$W/h/sing-box"; chmod +x "$W/h/sing-box"
mk() { printf '%s' "$2" > "$W/h/rules/$1.json"; "$W/h/sing-box" rule-set compile --output "$W/h/rules/$1.srs" "$W/h/rules/$1.json" >/dev/null 2>&1; rm -f "$W/h/rules/$1.json"; }
mk geosite-cn '{"version":3,"rules":[{"domain_suffix":["cn.example"]}]}'; mk geosite-notcn '{"version":3,"rules":[{"domain_suffix":["example.org"]}]}'
mk geoip-cn '{"version":3,"rules":[{"ip_cidr":["114.114.114.114/32"]}]}'; mk geosite-ai '{"version":3,"rules":[{"domain_suffix":["newai.example"]}]}'
mk _default '{"version":3,"rules":[{"domain_suffix":["nothing.enana.invalid"]}]}'
# 本机模拟的规则集下载源: 四个固定规则集用上面的夹具, 其它规则集都返回一个不会命中任何东西的占位规则集
mkdir -p "$W/rules-src"; cp "$W/h/rules/_default.srs" "$W/rules-src/_default.srs"; rm -f "$W/h/rules/_default.srs"
cp "$W/h/rules/geosite-cn.srs" "$W/rules-src/geosite-cn.srs"; cp "$W/h/rules/geosite-notcn.srs" "$W/rules-src/geosite-geolocation-!cn.srs"
cp "$W/h/rules/geoip-cn.srs" "$W/rules-src/geoip-cn.srs"; cp "$W/h/rules/geosite-ai.srs" "$W/rules-src/geosite-category-ai-!cn.srs"
date +%s > "$W/h/rules/.updated"
cat > "$W/h/servers.jsonl" <<EOF
{"role":"pin","outbound":{"type":"socks","tag":"Fix-Pin","server":"127.0.0.1","server_port":1,"version":"5","username":"u","password":"p"}}
{"role":"auto","sub":"demo","outbound":{"type":"http","tag":"Fix Auto 1","server":"127.0.0.1","server_port":2,"username":"u","password":"p"}}
{"role":"auto","outbound":{"type":"hysteria2","tag":"🇯🇵 Fix-HY2","server":"127.0.0.1","server_port":4,"password":"pw","tls":{"enabled":true,"insecure":true,"alpn":["h3"]}}}
{"role":"auto","outbound":{"type":"socks","tag":"Local-Hop","server":"127.0.0.1","server_port":$HOP_PORT,"version":"5"}}
EOF
chmod 600 "$W/h/servers.jsonl"
mkdir -p "$HOME/Applications/Existing App.app"   # 首次扫描前就存在的应用
# 云端内容包: 用一把测试私钥签名 (公钥通过 ENANA_CLOUD_PUBKEY 交给客户端); 另一把钥匙用来做「伪造签名」的负面测试
/usr/bin/openssl ecparam -genkey -name prime256v1 -noout -out "$W/ckey.pem" 2>/dev/null; /usr/bin/openssl ec -in "$W/ckey.pem" -pubout -out "$W/cpub.pem" 2>/dev/null
/usr/bin/openssl ecparam -genkey -name prime256v1 -noout -out "$W/evil.pem" 2>/dev/null
mkdir -p "$W/v1"; bash "$REPO/tools/build-content-bundle.sh" "$HERE/fixtures/content" "$W/v1" "$W/ckey.pem" 100 >/dev/null
python3 "$HERE/mock-account.py" $A_PORT "$W/v1" & echo $! > "$W/pid-acct"
/usr/bin/openssl ecparam -genkey -name prime256v1 -noout -out "$W/doh.key" 2>/dev/null; /usr/bin/openssl req -new -x509 -key "$W/doh.key" -out "$W/doh.crt" -days 2 -subj /CN=127.0.0.1 2>/dev/null
cat > "$W/dns-presets.conf" <<EOF
# 测试用预设表: 名称 / id 和正式的一致, 但地址全部指向本机的模拟 DNS (不产生外部流量)
cn|system|系统默认|使用系统设置里的 DNS,不额外加密|system
cn|alidns|阿里 DNS (DoH)|223.5.5.5,国内最常用,稳定、延迟低|https://127.0.0.1:$DOH_PORT/dns-query
cn|alidns-dot|阿里 DNS (DoT)|223.5.5.5,加密的 TLS 直连,和 DoH 速度相近|tls://127.0.0.1:$DOH_PORT
cn|dnspod|腾讯 DNSPod (DoH)|1.12.12.12,腾讯公共 DNS|https://127.0.0.1:$DOH_PORT/dns-query
cn|114|114DNS (UDP)|传统 UDP,无加密,兼容性最好|udp://127.0.0.1:$N_PORT
cn|deaddns|Dead DNS (UDP)|Unreachable server|udp://127.0.0.1:1
cn|custom|自定义||
global|cloudflare|Cloudflare (DoH)|1.1.1.1,速度快,隐私友好|https://127.0.0.1:$DOH_PORT/dns-query
global|google|Google (DoH)|8.8.8.8|https://127.0.0.1:$DOH_PORT/dns-query
global|quad9|Quad9 (DoH)|9.9.9.9,自带恶意域名拦截|https://127.0.0.1:1/dns-query
global|custom|自定义||
EOF
python3 "$HERE/mock-net.py" $N_PORT "$W/rules-src" $DOH_PORT "$W/doh.crt" "$W/doh.key" & echo $! > "$W/pid-net"
printf '{"log":{"level":"warn"},"inbounds":[{"type":"socks","listen":"127.0.0.1","listen_port":%s}],"outbounds":[{"type":"direct","tag":"direct"}]}' "$HOP_PORT" > "$W/hop.json"
"$SB" run -c "$W/hop.json" >/dev/null 2>&1 & echo $! > "$W/pid-hop"
cat > "$W/speedtest.conf" <<EOF
target|t_ok|global|正常站|OK site|http://127.0.0.1:$N_PORT/204|204|search
target|t_slow|cn|慢站|Slow site|http://127.0.0.1:$N_PORT/slow|200|mail
target|t_lim|global|受限站|Limited site|http://127.0.0.1:$N_PORT/limited|200|cloud
target|t_dead|carrier|不通的站|Dead site|http://127.0.0.1:1/x|200|signal
file|f_global|global|本机全局|http://127.0.0.1:$N_PORT/file|
file|f_cn|cn|本机国内|http://127.0.0.1:$N_PORT/file|0-2999999
EOF
# 本机的 sshd (非 root, 只开密钥登录) 当作「自己的服务器」: 远程命令在本机执行云端部署脚本的测试替身 (tests/fixtures/content/vps/); ssh 走真的, 密码登录走 tests/fakebin/fakessh
printf 'hop=%s\n' "$HOP_PORT" > "$W/vpsctl"
if [ -x /usr/sbin/sshd ]; then
  mkdir -p "$W/sshd"; chmod 700 "$W/sshd"
  for k in hostkey client other; do ssh-keygen -q -t ed25519 -N '' -f "$W/sshd/$k" >/dev/null 2>&1; done
  cp "$W/sshd/client.pub" "$W/sshd/authorized_keys"
  cat > "$W/sshd/sshd_config" <<EOF
Port $SSHD_PORT
ListenAddress 127.0.0.1
HostKey $W/sshd/hostkey
PidFile $W/sshd/sshd.pid
AuthorizedKeysFile $W/sshd/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM no
StrictModes no
LogLevel ERROR
PerSourcePenalties no
MaxStartups 100:30:200
LoginGraceTime 30
SetEnv ENANA_MOCK_CTL=$W/vpsctl FAKE_STATE=$W/state PATH=$HERE/fakebin:/usr/bin:/bin:/usr/sbin:/sbin
EOF
  /usr/sbin/sshd -D -f "$W/sshd/sshd_config" -E "$W/sshd/sshd.log" & echo $! > "$W/pid-sshd"
fi
waitport $HOP_PORT && waitport $A_PORT && waitport $N_PORT && tpass "模拟服务已就绪" || tfail "模拟服务已就绪"

echo "== 1. 首次安装 (非交互)"
OUT=$(bash "$REPO/install.sh" --yes 2>&1 | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g'); echo "$OUT" | grep -E '^\[|✗' | sed 's/^/    /'
echo "$OUT" | grep -q '环境安装完成' && tpass "安装流程跑完" || tfail "安装流程跑完"
echo "$OUT" | grep -q 'enana.cc' && tpass "安装结尾提示用 enana.cc 账号登录" || tfail "安装结尾提示用 enana.cc 账号登录"
echo "$OUT" | grep -qiE '密码[:：] *[A-Za-z0-9]{8,}' && tfail "安装过程没有生成/打印任何密码" || tpass "安装过程没有生成/打印任何密码"
expect "代理端口在监听" nc -z 127.0.0.1 "$PORT"
expect "测速专用入站在监听" nc -z 127.0.0.1 "$SPEED_PORT"
D=$A/enana/admin; AH() { curl -s --noproxy '*' "$@"; }
expect "后台 /enana/admin/ 由本地辅助服务直接提供 (200, text/html, nosniff, 禁止嵌入)" sh -c "H=\$(curl -sI --noproxy '*' $D/ | tr -d '\r'); echo \"\$H\" | head -1 | grep -q ' 200 ' && echo \"\$H\" | grep -qi '^content-type: text/html' && echo \"\$H\" | grep -qi '^x-content-type-options: nosniff' && echo \"\$H\" | grep -qi '^x-frame-options: DENY'"
expect "不带斜杠的 /enana/admin 跳转到 /enana/admin/" sh -c "H=\$(curl -sI --noproxy '*' $A/enana/admin | tr -d '\r'); echo \"\$H\" | head -1 | grep -q ' 302 ' && echo \"\$H\" | grep -qi '^location: /enana/admin/\$'"
expect "根路径 / 也跳转到后台" sh -c "curl -sI --noproxy '*' $A/ | tr -d '\r' | grep -qi '^location: /enana/admin/\$'"
expect "页面路由 /enana/admin/apps 直接给 index.html (和 #apps 旧写法并存)" sh -c "curl -s --noproxy '*' $D/apps | grep -q 'id=\"v-apps\"'"
expect "页面路由带斜杠 /enana/admin/apps/ 跳到不带斜杠 (相对地址要靠它)" sh -c "curl -sI --noproxy '*' $D/apps/ | tr -d '\r' | grep -qi '^location: /enana/admin/apps\$'"
expect "后台能取到 style.css / app.js / i18n 词典 / env.json (扩展名白名单内的文件)" sh -c "for f in style.css app.js i18n/zh.js env.json catalog.json; do test \"\$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' $D/\$f)\" = 200 || exit 1; done"
expect "/favicon.ico 给出标签页图标 (200, image/png): 浏览器总会请求它, 以前是 403, 控制台里一条红色报错" sh -c "H=\$(curl -sI --noproxy '*' $A/favicon.ico | tr -d '\r'); echo \"\$H\" | head -1 | grep -q ' 200 ' && echo \"\$H\" | grep -qi '^content-type: image/png'"
expect "页面里声明了图标 (rel=icon), favicon.svg / favicon.png 都能取到" sh -c "curl -s --noproxy '*' $D/ | grep -q 'rel=\"icon\"' && test \"\$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' $D/favicon.svg)\" = 200 && test \"\$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' $D/favicon.png)\" = 200"
AH $D/env.json | chk "env.json: apiBase 为空 (仪表盘与辅助服务同源), clashBase 指向核心控制端口" 'assert d["apiBase"]=="" and d["clashBase"]=="http://127.0.0.1:'"$UI_PORT"'" and d["apiPort"]=='"$API_PORT"' and d["uiPort"]=='"$UI_PORT"
expect "目录穿越被拒 (../ 与 %2e%2e)" sh -c "test \"\$(curl -s --path-as-is -o /dev/null -w '%{http_code}' --noproxy '*' $D/../../../etc/hosts)\" != 200 && test \"\$(curl -s --path-as-is -o /dev/null -w '%{http_code}' --noproxy '*' $D/%2e%2e/%2e%2e/etc/hosts)\" = 404"
expect "隐藏文件 / 不在白名单里的扩展名 (appicons/index.tsv) 一律 404" sh -c "test \"\$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' $D/.x.js)\" = 404 && test \"\$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' $D/appicons/index.tsv)\" = 404 && test \"\$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' $D/nonexistent.js)\" = 404"
expect "静态文件只接受 GET / HEAD (POST → 405)" test "$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' -X POST $D/)" = 405
expect "别的网站的页面不能把后台文件当子资源加载 (Sec-Fetch-Site: cross-site 且不是导航 → 403; 自己打开 / 同源 / 导航照常 200)" sh -c "test \"\$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' -H 'Sec-Fetch-Site: cross-site' -H 'Sec-Fetch-Mode: no-cors' $D/style.css)\" = 403 && test \"\$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' -H 'Sec-Fetch-Site: same-origin' -H 'Sec-Fetch-Mode: no-cors' $D/style.css)\" = 200 && test \"\$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' -H 'Sec-Fetch-Site: cross-site' -H 'Sec-Fetch-Mode: navigate' $D/)\" = 200"
expect "Host 头不对 (DNS 重绑定) → 403, 静态文件也一样" test "$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' -H 'Host: evil.example:80' $D/)" = 403
expect "核心 (Clash API) 端口不再提供 /ui/ (页面已改由辅助服务提供)" test "$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' $U/ui/)" != 200
expect "核心只对后台的来源开放 CORS (别的来源没有 Access-Control-Allow-Origin)" sh -c "curl -sI --noproxy '*' -H 'Origin: http://127.0.0.1:$API_PORT' -H 'Access-Control-Request-Method: GET' -X OPTIONS $U/version | tr -d '\r' | grep -qi '^access-control-allow-origin: http://127.0.0.1:$API_PORT\$' && ! curl -sI --noproxy '*' -H 'Origin: http://evil.example' -H 'Access-Control-Request-Method: GET' -X OPTIONS $U/version | grep -qi '^access-control-allow-origin'"
expect "catalog.json 与 env.json 已生成" test -s "$W/h/ui/catalog.json" -a -s "$W/h/ui/env.json"
expect "令牌文件已生成 (权限 600) 且没有 auth.conf / 本地密码" sh -c "test -s '$W/h/secret' && test \"\$(stat -f %Lp '$W/h/secret')\" = 600 && test ! -e '$W/h/auth.conf'"
expect "快捷命令可从符号链接运行" test "$("$W/shortcut/enana" version)" = "enana $VER"
expect "系统代理已(假)开启" test -f "$FAKE_STATE/sysproxy-on"
expect "每日维护任务已注册" test -f "$ENANA_PLIST_DIR/com.enana.proxy.update.plist"
expect "核心 Clash API 没有令牌时拒绝访问" test "$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' $U/proxies)" = 401

echo "== 2. 账号: 登录 / 注册 / 离线 / 限流 / 退出账号 · 代理总开关 (账号服务是本机模拟的 enana.cc)"
apin "$A/api/auth/status" | chk "未登录可读 auth/status: 无缓存账号; 没有找回密码入口, 也没有指向网站账号页的链接 (官网只有首页)" 'assert d["ok"] and d["required"] and d["account_hint"]=="" and not d["offline_ok"] and "forgot_url" not in d and "register_url" not in d and "manage_url" not in d and "bound" not in d'
expect "未带令牌访问 /api/state → 401" test "$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' -H "$X" $A/api/state)" = 401
expect "错误令牌 → 401" test "$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' -H "$X" -H 'X-Enana-Token: nope' $A/api/state)" = 401
expect "未登录时不能开启代理: /api/proxy → 401" test "$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' -X POST -H "$X" $A/api/proxy -d on=1)" = 401
login user1@example.test 'wrong-pass' | chk "错误密码 → E_BAD_CREDENTIALS" 'assert not d["ok"] and d["code"]=="E_BAD_CREDENTIALS"'
login 'not-an-email' 'x' | chk "邮箱格式不对 → E_INVALID" 'assert not d["ok"] and d["code"]=="E_INVALID"'
reg() { apin -X POST --data-urlencode "user=$1" --data-urlencode "password=$2" "$A/api/register"; }
reg 'bad-email' 'LongEnough1' | chk "注册: 邮箱格式不对 → E_INVALID" 'assert d["code"]=="E_INVALID"'
reg 'new1@example.test' 'short' | chk "注册: 密码少于 8 位 → E_WEAK_PASSWORD (本机直接拦)" 'assert d["code"]=="E_WEAK_PASSWORD"'
reg 'user1@example.test' 'LongEnough1' | chk "注册: 邮箱已存在 → E_EMAIL_TAKEN" 'assert d["code"]=="E_EMAIL_TAKEN"'
curl -s -X POST "http://127.0.0.1:$A_PORT/_test/mode?m=down" >/dev/null
reg 'new1@example.test' 'LongEnough1' | chk "注册: 连不上 enana.cc → E_ACCOUNT_UNREACHABLE" 'assert d["code"]=="E_ACCOUNT_UNREACHABLE"'
curl -s -X POST "http://127.0.0.1:$A_PORT/_test/mode?m=ok" >/dev/null
R=$(reg 'New1@Example.Test' 'LongEnough1')
echo "$R" | chk "注册成功 (邮箱大小写不敏感) → 自动登录并返回令牌" 'assert d["ok"] and d["registered"] and d["via"]=="online" and d["account"]=="new1@example.test" and len(d["token"])==32'
TOKEN=$(echo "$R" | jp 'print(d["token"])')
api "$A/api/state" | chk "state: 当前账号 = 刚注册的邮箱; 刚登录时代理默认是关闭的" 'assert d["account"]["email"]=="new1@example.test" and d["proxy"]["enabled"] is False'
cl "$U/configs" | chk "核心处于「全部直连」模式 (Direct): 代理默认关闭, 不会断网" 'assert d["mode"]=="Direct"'
api -X POST "$A/api/logout" | chk "退出账号 → ok" 'assert d["ok"]'
wait_clash_401 "$TOKEN"
expect "退出后旧令牌立刻失效: 辅助服务 401" test "$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' -H "$X" -H "X-Enana-Token: $TOKEN" $A/api/state)" = 401
expect "退出后旧令牌失效: Clash API 401 (核心已换上新令牌)" test "$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' -H "Authorization: Bearer $TOKEN" $U/proxies)" = 401
expect "退出后已不处于登录状态" test ! -e "$W/h/loggedin"
R=$(login USER1@Example.Test 'Passw0rd!')
echo "$R" | chk "任何有效账号都能登录 (大小写不敏感): 在线校验" 'assert d["ok"] and d["via"]=="online" and d["account"]=="user1@example.test" and len(d["token"])==32 and "bound_now" not in d'
TOKEN=$(echo "$R" | jp 'print(d["token"])')
expect "令牌与 secret 文件一致" test "$TOKEN" = "$(cat "$W/h/secret")"
expect "离线缓存文件权限 600, 不含明文密码" sh -c "test \"\$(stat -f %Lp '$W/h/account.conf')\" = 600 && ! grep -q 'Passw0rd' '$W/h/account.conf' && grep -q '^hash=' '$W/h/account.conf'"
apin "$A/api/auth/status" | chk "auth/status: 缓存账号掩码 + offline_ok" 'assert d["offline_ok"] and d["account_hint"].startswith("u***@e***")'
api "$A/api/state" | chk "带令牌可读 /api/state (含 update/lang/proxy/account/speed 端口)" 'assert d["ok"] and d["lang"]=="zh" and "update" in d and d["ports"]["speed"]>0 and d["proxy"]["enabled"] is False and d["account"]["email"]=="user1@example.test"'
expect "Clash API 带令牌可访问" test "$(cl -o /dev/null -w '%{http_code}' $U/proxies)" = 200
api -X POST "$A/api/proxy" -d 'on=maybe' | chk "代理开关: 参数无效 → 被拒" 'assert not d["ok"]'
api -X POST "$A/api/proxy" -d 'on=1' | chk "手动开启代理 → enabled" 'assert d["ok"] and d["enabled"] is True'
cl "$U/configs" | chk "开启后核心切到规则分流 (Rule)" 'assert d["mode"]=="Rule"'
api "$A/api/state" | chk "state.proxy.enabled = true" 'assert d["proxy"]["enabled"] is True'
api -X POST "$A/api/proxy" -d 'on=1' | chk "总开关开启时系统代理已经指向 enana: 不再改动它 (sysproxy.state=on)" 'assert d["ok"] and d["sysproxy"]["state"]=="on"'
rm -f "$FAKE_STATE/sysproxy-on"; : > "$FAKE_STATE/calls.log"
SPJ=$(api -X POST "$A/api/proxy" -d 'on=1' | tee "$W/sp.json" | jp 'print(d["sysproxy"].get("job",""))')
chk "总开关开启时系统代理没有指向 enana: 自动在后台任务里开启 (state=pending + job), 不再必须去终端输入 enana on" 'assert d["ok"] and d["sysproxy"]["state"]=="pending" and d["sysproxy"]["job"]' < "$W/sp.json"
[ "$(job_wait "$SPJ")" = done ] && tpass "系统代理后台任务完成" || tfail "系统代理后台任务完成"
expect "系统代理已被后台任务重新指向 enana (不需要终端 / 管理员密码输入)" test -f "$FAKE_STATE/sysproxy-on"
expect "这一步没有向标准输出污染 HTTP 响应, 也没有 sudo -v (仪表盘里没有终端可输入密码)" test "$(grep -c '^sudo -v' "$FAKE_STATE/calls.log")" = 0
expect "操作记录里有「开启系统代理」(方式 direct, 结果 ok)" sh -c "grep -h '开启系统代理' '$W'/h/logs/ops-*.log | grep -q 'method=direct.*ok$'"
SPJ=$(api -X POST "$A/api/sysproxy" -d 'on=0' | jp 'print(d["job"])'); [ "$(job_wait "$SPJ")" = done ] && tpass "POST /api/sysproxy on=0 → 后台任务完成" || tfail "POST /api/sysproxy on=0 → 后台任务完成"
expect "单独关闭系统代理后不再指向 enana" test ! -f "$FAKE_STATE/sysproxy-on"
api -X POST "$A/api/sysproxy" -d 'on=maybe' | chk "POST /api/sysproxy 参数无效 → 被拒" 'assert not d["ok"]'
SPJ=$(api -X POST "$A/api/sysproxy" -d 'on=1' | jp 'print(d["job"])'); [ "$(job_wait "$SPJ")" = done ] && tpass "POST /api/sysproxy on=1 → 后台任务完成" || tfail "POST /api/sysproxy on=1 → 后台任务完成"
expect "单独开启系统代理后指向 enana" test -f "$FAKE_STATE/sysproxy-on"
api "$A/api/state" | chk "state.env.sysproxy 反映最新状态 (清掉 20 秒缓存)" 'assert d["env"]["sysproxy"] is True'
expect "开关已写进设置与磁盘配置 (重启后保持)" sh -c "grep -q '^PROXY_ENABLED=1' '$W/h/settings.env' && grep -q '\"default_mode\":\"Rule\"' '$W/h/config.json'"
login user2@example.test 'Another-Pass1' | chk "换另一个账号登录也可以 (没有绑定限制)" 'assert d["ok"] and d["account"]=="user2@example.test"'
login user1@example.test 'Passw0rd!' >/dev/null
api -X POST "$A/api/password" | chk "改密码接口: 什么都没填 → 被拒 (本机提交给云端, 不再指向网站账号页)" 'assert not d["ok"] and d["code"]!="E_CENTRAL" and "url" not in d'
apin -X POST "$A/api/password" -d 'x=1' | chk "无令牌不能调用 password (401)" 'assert d.get("code")=="E_AUTH"'
curl -s -X POST "http://127.0.0.1:$A_PORT/_test/mode?m=down" >/dev/null
login user1@example.test 'Passw0rd!' | chk "账号服务不可用时: 上一次登录的账号离线登录成功" 'assert d["ok"] and d["via"]=="offline"'
login user1@example.test 'Passw0rd?' | chk "离线时密码错误仍被拒" 'assert not d["ok"] and d["code"]=="E_BAD_CREDENTIALS"'
login new1@example.test 'LongEnough1' | chk "离线时其它账号 (没有缓存) 不能登录 → E_ACCOUNT_UNREACHABLE" 'assert d["code"]=="E_ACCOUNT_UNREACHABLE"'
curl -s -X POST "http://127.0.0.1:$A_PORT/_test/mode?m=ratelimit" >/dev/null
login user1@example.test 'Passw0rd!' | chk "账号服务限流 (429) → E_LOCKED + wait" 'assert d["code"]=="E_LOCKED" and d["wait"]>0'
curl -s -X POST "http://127.0.0.1:$A_PORT/_test/mode?m=ok" >/dev/null
curl -s -X POST "http://127.0.0.1:$A_PORT/_test/passwd?email=user1@example.test&pw=New-Passw0rd2" >/dev/null
login user1@example.test 'Passw0rd!' | chk "在网站上改密码后: 旧密码立刻失效 (在线校验优先于离线缓存)" 'assert d["code"]=="E_BAD_CREDENTIALS"'
login user1@example.test 'New-Passw0rd2' | chk "新密码可登录, 并刷新本机离线校验值" 'assert d["ok"] and d["via"]=="online"'
curl -s -X POST "http://127.0.0.1:$A_PORT/_test/mode?m=down" >/dev/null
login user1@example.test 'New-Passw0rd2' | chk "离线时用新密码登录成功" 'assert d["ok"] and d["via"]=="offline"'
curl -s -X POST "http://127.0.0.1:$A_PORT/_test/mode?m=ok" >/dev/null
for i in 1 2 3 4 5; do login user1@example.test "bad$i" >/dev/null; done
login user1@example.test 'New-Passw0rd2' | chk "连续失败 5 次后锁定: E_LOCKED + 等待秒数 (正确密码也被拦)" 'assert d["code"]=="E_LOCKED" and 0<d["wait"]<=300'
apin "$A/api/auth/status" | chk "锁定期间 auth/status 带 wait" 'assert d["wait"]>0'
rm -f "$W/h/auth.fail"
for i in 1 2 3 4 5 6 7 8; do reg "x$i@example.test" 'LongEnough1' >/dev/null; done
reg 'x9@example.test' 'LongEnough1' | chk "注册过于频繁 → E_LOCKED (本机限流)" 'assert d["code"]=="E_LOCKED"'
rm -f "$W/h/reg.log"
TOKEN=$(login user1@example.test 'New-Passw0rd2' | jp 'print(d["token"])')
expect "日志与记录里没有密码" sh -c "! grep -rq -e 'New-Passw0rd2' -e 'LongEnough1' -e 'Passw0rd!' '$W/h/api.log' '$W/h/logs' 2>/dev/null"
expect "账号服务只收到登录/注册请求" test "$(curl -s "http://127.0.0.1:$A_PORT/_test/hits" | jp 'print(d["hits"])')" -gt 5

echo "== 2b. 设备数量限制 (同账号同平台最多 2 台) · 下线其它设备 · 被下线后本机自动退出 · 心跳"
seed() { curl -s -G -X POST "http://127.0.0.1:$A_PORT/_test/seed" --data-urlencode "email=$1" --data-urlencode "uid=$2" --data-urlencode "platform=$3" --data-urlencode "name=$4" >/dev/null; }
seed user2@example.test dev-aaaa-1111 macos "办公室 MacBook"; seed user2@example.test dev-bbbb-2222 macos "家里 iMac"; seed user2@example.test dev-cccc-3333 windows "公司 Windows"
R=$(login user2@example.test 'Another-Pass1')
echo "$R" | chk "本平台已有 2 台设备在线 → E_DEVICE_LIMIT, 返回设备列表 (不含 Windows 那台)" 'assert d["code"]=="E_DEVICE_LIMIT" and d["platform"]=="macos" and d["limit"]==2 and sorted(x["uid"] for x in d["devices"])==["dev-aaaa-1111","dev-bbbb-2222"] and all(x["online"] for x in d["devices"]) and not d["ok"]'
expect "设备已满时没有登录 (令牌文件保持不变, 不处于 user2 登录状态)" test "$(cat "$W/h/loggedin" | cut -d' ' -f1)" = user1@example.test
R=$(apin -X POST --data-urlencode "user=user2@example.test" --data-urlencode "password=Another-Pass1" --data-urlencode "kick=dev-aaaa-1111" "$A/api/login")
echo "$R" | chk "下线其中一台 (kick) → 自动完成登录" 'assert d["ok"] and d["account"]=="user2@example.test" and len(d["token"])==32'
TOKEN=$(echo "$R" | jp 'print(d["token"])')
curl -s "http://127.0.0.1:$A_PORT/_test/sessions" | chk "被下线的设备会话在云端已撤销 (kicked); 另一台与本机仍在线" 's={x["uid"]:x for x in d["sessions"] if x["user"]=="rec2def45"}; assert s["dev-aaaa-1111"]["revoked"]=="kicked" and s["dev-bbbb-2222"]["active"]'
apin -X POST --data-urlencode "user=user2@example.test" --data-urlencode "password=Another-Pass1" --data-urlencode "kick=bad uid!" "$A/api/login" | chk "kick 参数非法 → 被拒" 'assert not d["ok"]'
api "$A/api/devices" | chk "我的设备: 列出本账号全部设备, 本机标记 current, 含在线状态" 'ds={x["uid"]:x for x in d["devices"]}; assert d["limit"]==2 and d["platform"]=="macos" and len(ds)==4 and sum(1 for x in ds.values() if x["current"])==1 and ds["dev-bbbb-2222"]["online"] and not ds["dev-aaaa-1111"]["online"] and ds["dev-cccc-3333"]["platform"]=="windows"'
api -X POST "$A/api/devices/kick" -d "uid=dev-bbbb-2222" | chk "在「我的设备」里下线另一台设备" 'assert d["ok"]'
curl -s "http://127.0.0.1:$A_PORT/_test/sessions" | chk "该设备会话已撤销" 's={x["uid"]:x for x in d["sessions"] if x["user"]=="rec2def45"}; assert s["dev-bbbb-2222"]["revoked"]=="kicked"'
api -X POST "$A/api/devices/kick" -d "uid=$(cat "$W/h/device.id")" | chk "不能下线自己" 'assert not d["ok"]'
api -X POST "$A/api/devices/kick" -d "uid=bad%20uid" | chk "设备编号非法 → 被拒" 'assert not d["ok"]'
rm -f "$W/h/.hb.last"; "$W/shortcut/enana" tick --quiet >/dev/null 2>&1
expect "心跳成功: 仍处于登录状态, 没有联网失败记录" sh -c "test -f '$W/h/loggedin' && test ! -f '$W/h/hb.fail'"
curl -s -X POST "http://127.0.0.1:$A_PORT/_test/revoke?uid=$(cat "$W/h/device.id")&reason=kicked" >/dev/null
api -X POST "$A/api/proxy" -d 'on=1' >/dev/null
rm -f "$W/h/.hb.last"; "$W/shortcut/enana" tick --quiet >/dev/null 2>&1; wait_clash_401 "$TOKEN"
expect "被其它设备下线后: 本机自动退出登录 (loggedin / 云端会话 / 离线缓存都被清除)" test ! -e "$W/h/loggedin" -a ! -e "$W/h/session" -a ! -e "$W/h/account.conf"
expect "被其它设备下线后: 代理自动关闭" grep -q '^PROXY_ENABLED=0' "$W/h/settings.env"
expect "被其它设备下线后: 旧令牌失效" test "$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' -H "$X" -H "X-Enana-Token: $TOKEN" $A/api/state)" = 401
apin "$A/api/auth/status" | chk "登录框会提示原因: notice = kicked" 'assert d["notice"]=="kicked"'
TOKEN=$(login user1@example.test 'New-Passw0rd2' | jp 'print(d["token"])'); [ -z "$TOKEN" ] && TOKEN=$(login user1@example.test 'Passw0rd!' | jp 'print(d["token"])')
apin "$A/api/auth/status" | chk "重新登录后 notice 清空" 'assert d["notice"]==""'
curl -s -X POST "http://127.0.0.1:$A_PORT/_test/mode?m=down" >/dev/null
rm -f "$W/h/.hb.last"; "$W/shortcut/enana" tick --quiet >/dev/null 2>&1
expect "云端连不上: 记录首次失败时间, 仍在宽限期内保持登录" sh -c "test -f '$W/h/hb.fail' && test -f '$W/h/loggedin'"
printf '%s\n' $(( $(date +%s) - 8*86400 )) > "$W/h/hb.fail"; rm -f "$W/h/.hb.last"; "$W/shortcut/enana" tick --quiet >/dev/null 2>&1
expect "离线超过 7 天: 本机自动退出登录并提示 offline_expired" sh -c "test ! -e '$W/h/loggedin' && grep -q offline_expired '$W/h/notice'"
curl -s -X POST "http://127.0.0.1:$A_PORT/_test/mode?m=ok" >/dev/null
TOKEN=$(login user1@example.test 'New-Passw0rd2' | jp 'print(d["token"])'); [ -n "$TOKEN" ] || TOKEN=$(login user1@example.test 'Passw0rd!' | jp 'print(d["token"])')
expect "测试夹具: 已重新登录" test -n "$TOKEN"

echo "== 2c. 云端内容 (登录后下发的精选数据: 验签 / 防篡改 / 防回滚 / 文件白名单 / 事务回滚)"
for i in $(seq 1 40); do sleep 0.5; [ "$(api "$A/api/content" | jp 'print(d["source"])' 2>/dev/null)" = cloud ] && break; done
api "$A/api/content" | chk "登录后自动拉取云端内容: 来源 = cloud, 序号 100, 无错误" 'assert d["source"]=="cloud" and d["seq"]==100 and d["error"]=="" and d["version"]'
expect "内容已缓存到本机 (符号链接 cloud/content -> content-100)" test "$(readlink "$W/h/cloud/content")" = content-100
api "$A/api/rules" | chk "规则库来自云端内容 (有 geosite-ai / geosite-ads)" 'n={x["tag"] for x in d["sets"]}; assert {"geosite-ai","geosite-ads","geosite-cn"} <= n'
cat "$W/h/ui/catalog.json" | chk "服务目录来自云端内容 (含 testsvc 和分组 search), 并生成了对应的策略开关" 'assert any(e["id"]=="testsvc" for e in d["entries"]) and "search" in d["groups"]'
cl "$U/proxies" | chk "核心里有 svc-testsvc 策略开关" 'assert "svc-testsvc" in d["proxies"]'
cat "$W/h/ui/catalog.en.json" | chk "英文目录用到了内容包自带的译文 (Test service)" 'assert any(e["name"]=="Test service" or e["desc"]=="This is a test service" for e in d["entries"])'
BUNDLE() { rm -rf "$W/v1.new"; mkdir -p "$W/v1.new"; bash "$REPO/tools/build-content-bundle.sh" "$1" "$W/v1.new" "$2" "$3" >/dev/null && rm -rf "$W/v1"/* && cp "$W/v1.new"/* "$W/v1/"; }
cp -R "$HERE/fixtures/content" "$W/content2"; printf 'testsvc2|第二个测试服务|search|auto|testsvc2.example|||新增的服务\n' >> "$W/content2/services.conf"
BUNDLE "$W/content2" "$W/evil.pem" 101
"$W/shortcut/enana" content --force > "$W/content.out" 2>&1; expect "伪造签名 (别的私钥) 的内容清单被拒绝, 保留旧内容 (序号仍是 100)" sh -c "grep -q '签名校验失败' '$W/content.out' && test \"\$(cat '$W/h/cloud/content/SEQ')\" = 100"
api "$A/api/content" | chk "接口里能看到错误原因, 内容来源仍是 cloud 100" 'assert d["seq"]==100 and "签名" in d["error"]'
BUNDLE "$W/content2" "$W/ckey.pem" 99
"$W/shortcut/enana" content --force > "$W/content.out" 2>&1; expect "更旧的序号 (99 < 100) 被拒绝 (防回滚)" sh -c "grep -q '防回滚' '$W/content.out' && test \"\$(cat '$W/h/cloud/content/SEQ')\" = 100"
# 被篡改的内容包: 清单有效但包内容与 sha256 不一致
BUNDLE "$HERE/fixtures/content" "$W/ckey.pem" 102; printf 'x' >> "$W/v1/content-102.tar.gz"
"$W/shortcut/enana" content --force > "$W/content.out" 2>&1; expect "内容包被篡改 (sha256 不符) 被拒绝" sh -c "grep -qE '校验和|大小不对' '$W/content.out' && test \"\$(cat '$W/h/cloud/content/SEQ')\" = 100"
# 包里带了不在白名单里的文件
rm -rf "$W/content3"; cp -R "$W/content2" "$W/content3"; printf '#!/bin/sh\necho pwned\n' > "$W/content3/evil.sh"
mkdir -p "$W/v1.x"; rm -rf "$W/v1.x"/*; bash "$REPO/tools/build-content-bundle.sh" "$W/content2" "$W/v1.x" "$W/ckey.pem" 103 >/dev/null
(mkdir -p "$W/v1.y" && cd "$W/v1.y" && rm -rf ./* && tar -xzf "$W/v1.x/content-103.tar.gz" && printf 'x\n' > evil.sh && COPYFILE_DISABLE=1 tar -czf "$W/v1.x/content-103.tar.gz" .)
sha=$(shasum -a 256 "$W/v1.x/content-103.tar.gz" | cut -d' ' -f1); size=$(wc -c < "$W/v1.x/content-103.tar.gz" | tr -d ' ')
printf '{"channel":"stable","bundles":{"content":{"seq":103,"version":"x","url":"/v1/content-103.tar.gz","sha256":"%s","size":%s,"min_client":"2.1.0"}}}' "$sha" "$size" > "$W/v1.x/manifest.json"; /usr/bin/openssl dgst -sha256 -sign "$W/ckey.pem" -out "$W/v1.x/manifest.sig" "$W/v1.x/manifest.json"
rm -rf "$W/v1"/*; cp "$W/v1.x"/* "$W/v1/"
"$W/shortcut/enana" content --force > "$W/content.out" 2>&1; expect "包里有白名单之外的文件 (evil.sh) 被拒绝" sh -c "grep -q '不允许的文件' '$W/content.out' && test ! -e '$W/h/cloud/content/evil.sh' && test \"\$(cat '$W/h/cloud/content/SEQ')\" = 100"
# 正常升级: 签名正确、序号更大
BUNDLE "$W/content2" "$W/ckey.pem" 110
"$W/shortcut/enana" content > "$W/content.out" 2>&1
api "$A/api/content" | chk "合法的新内容 (序号 110) 被安装并生效" 'assert d["seq"]==110 and d["error"]==""'
cat "$W/h/ui/catalog.json" | chk "新内容里新增的 testsvc2 出现在目录里" 'assert any(e["id"]=="testsvc2" for e in d["entries"])'
expect "只保留当前 + 上一份内容包" test "$(ls -d "$W/h"/cloud/content-* | wc -l | tr -d ' ')" -le 2
# 未登录 (没有云端会话) 时不拉取
BUNDLE "$HERE/fixtures/content" "$W/ckey.pem" 120
echo y | "$W/shortcut/enana" logout >/dev/null 2>&1; sleep 3
"$W/shortcut/enana" content > "$W/content.out" 2>&1; expect "没登录时不能拉取云端内容, 已缓存的内容保持不变 (序号 110)" sh -c "grep -q '还没有登录' '$W/content.out' && test \"\$(cat '$W/h/cloud/content/SEQ')\" = 110"
rm -f "$W/h/.hb.last"
TOKEN=$(login user1@example.test 'New-Passw0rd2' | jp 'print(d["token"])'); [ -n "$TOKEN" ] || TOKEN=$(login user1@example.test 'Passw0rd!' | jp 'print(d["token"])')
for i in $(seq 1 40); do sleep 0.5; [ "$(api "$A/api/content" | jp 'print(d["seq"])' 2>/dev/null)" = 120 ] && break; done
api "$A/api/content" | chk "重新登录后自动拿到更新的内容 (序号 120)" 'assert d["seq"]==120'

echo "== 2d. 网站域名编辑 (弹窗里一行一个域名: 添加 / 修改 / 删除 / 恢复 / 一键重置; 用户改动不被云端内容更新覆盖)"
sd() { api "$A/api/sites/domains?id=claude"; }
sd | chk "查看: 系统域名 + 生效域名 (来源 system), 未修改" 'assert d["id"]=="claude" and not d["modified"] and "claude.ai" in d["system"] and all(x["source"]=="system" for x in d["domains"]) and d["policy"]=="pin" and d["removed"]==[]'
api "$A/api/sites/domains?id=nope" | chk "不存在的条目 → E_NOT_FOUND" 'assert d["code"]=="E_NOT_FOUND"'
api "$A/api/sites/domains?id=Bad_ID" | chk "条目编号非法 → 被拒" 'assert not d["ok"]'
sdp() { api -X POST "$A/api/sites/domains" --data-urlencode "id=claude" --data-urlencode "action=$1" --data-urlencode "domain=$2" ${3:+--data-urlencode "new=$3"}; }
sdp add "http://bad.example/x" | chk "添加: 带协议/路径的域名 → 立刻被拒 (含原因)" 'assert not d["ok"] and d["code"]=="E_INVALID" and "格式" in d["error"]'
sdp add "*.wild.example" | chk "添加: 通配符 → 被拒" 'assert not d["ok"]'
sdp add "中文.example" | chk "添加: 中文域名 → 被拒并提示用 punycode" 'assert not d["ok"] and "xn--" in d["error"]'
sdp add "claude.ai" | chk "添加: 已经有的域名 → 被拒" 'assert not d["ok"] and "已经有" in d["error"]'
J=$(sdp add "New-Claude.Example." | jp 'print(d["job"])'); [ "$(job_wait "$J")" = done ] && tpass "添加域名 (规范化为小写、去掉结尾的点; 任务完成)" || tfail "添加域名"
sd | chk "添加后: 生效列表多了 new-claude.example (source=added), modified=true" 'm={x["domain"]:x["source"] for x in d["domains"]}; assert d["modified"] and m["new-claude.example"]=="added" and m["claude.ai"]=="system"'
cat "$W/h/ui/catalog.json" | chk "catalog.json 里该条目的 domains 是生效后的列表 + modified=true" 'e={x["id"]:x for x in d["entries"]}["claude"]; assert "new-claude.example" in e["domains"] and e["modified"]'
grep -q 'new-claude.example' "$W/h/config.json" && tpass "新域名已写进核心配置 (热生效)" || tfail "新域名已写进核心配置"
J=$(sdp remove "claude.com" | jp 'print(d["job"])'); job_wait "$J" >/dev/null
sd | chk "删除系统域名 (claude.com): 从生效列表消失, 记在 removed 里" 'assert "claude.com" not in [x["domain"] for x in d["domains"]] and d["removed"]==["claude.com"]'
grep -q '"claude.com"' "$W/h/config.json" && tfail "删除的系统域名不再出现在核心配置里" || tpass "删除的系统域名不再出现在核心配置里"
sdp remove "claude.com" | chk "重复删除同一个域名 → 被拒" 'assert not d["ok"]'
J=$(sdp restore "claude.com" | jp 'print(d["job"])'); job_wait "$J" >/dev/null
sd | chk "恢复被删除的系统域名" 'assert "claude.com" in [x["domain"] for x in d["domains"]] and d["removed"]==[]'
J=$(sdp update "new-claude.example" "renamed.example" | jp 'print(d["job"])'); job_wait "$J" >/dev/null
sd | chk "修改域名 (new-claude.example → renamed.example)" 'ds=[x["domain"] for x in d["domains"]]; assert "renamed.example" in ds and "new-claude.example" not in ds'
sdp update "claude.ai" "claude.ai" | chk "修改成同一个域名 → 被拒" 'assert not d["ok"]'
J=$(sdp update "claude.ai" "claude-new.example" | jp 'print(d["job"])'); job_wait "$J" >/dev/null
sd | chk "修改系统域名 = 删除旧的 + 添加新的" 'ds=[x["domain"] for x in d["domains"]]; assert "claude-new.example" in ds and "claude.ai" not in ds and "claude.ai" in d["removed"]'
BUNDLE "$W/content2" "$W/ckey.pem" 105 2>/dev/null || true
J=$(api -X POST "$A/api/sites/domains/reset" -d 'id=claude' | jp 'print(d["job"])'); [ "$(job_wait "$J")" = done ] && tpass "一键重置 (任务完成)" || tfail "一键重置"
sd | chk "重置后: 回到系统默认, modified=false" 'assert not d["modified"] and all(x["source"]=="system" for x in d["domains"]) and "claude.ai" in [x["domain"] for x in d["domains"]] and d["removed"]==[]'
api -X POST "$A/api/sites/domains/reset" -d 'id=nope' | chk "重置不存在的条目 → E_NOT_FOUND" 'assert d["code"]=="E_NOT_FOUND"'
J=$(sdp add "keep.example" | jp 'print(d["job"])'); job_wait "$J" >/dev/null

echo "== 3. 应用识别: 新装应用默认关闭, 已知应用有推荐"
api -X POST "$A/api/apps/scan" >/dev/null                      # 首次扫描: 之后才安装的应用才算「新装」
mkdir -p "$HOME/Applications/Zeta Notes.app" "$HOME/Applications/Windsurf.app"
R=$(api -X POST "$A/api/apps/scan")
echo "$R" | chk "新装的未知应用: 标记 new, 默认关(直连)" 'n={a["name"]:a for a in d["apps"]}; assert d["new_count"]==2; assert n["Zeta Notes"]["flag"]=="new" and n["Zeta Notes"]["state"]=="direct"'
echo "$R" | chk "新装的已知应用(Windsurf): 默认关, 但显示推荐 follow" 'n={a["name"]:a for a in d["apps"]}; t=n["Windsurf"]; assert t["flag"]=="new" and t["state"]=="direct" and t["rec"]=="follow" and t["known"]'
api -X POST "$A/api/apps/adopt" >/dev/null
api "$A/api/apps" | chk "采纳推荐: 已知→推荐值, 未知保持关" 'n={a["name"]:a for a in d["apps"]}; assert n["Windsurf"]["state"]=="follow" and n["Zeta Notes"]["state"]=="direct" and d["new_count"]==1'
api -X POST "$A/api/apps/ack?all=1" >/dev/null
api "$A/api/apps" | chk "全部确认后不再提示新应用" 'assert d["new_count"]==0'
api -X POST "$A/api/apps/scan" | chk "再次扫描不会重复标记" 'assert d["new_count"]==0'

echo "   (应用图标 / 自定义软件: 校验 + 两步添加)"
for i in $(seq 1 30); do sleep 0.5; [ "$(api "$A/api/apps" | jp 'print(sum(1 for a in d["apps"] if a["icon"]))' 2>/dev/null)" -ge 1 ] 2>/dev/null && break; done
api "$A/api/apps" | chk "应用图标: 后台提取了真实图标, 条目带 icon 路径 (没有的是空串, 前端用字母头像)" 'ic=[a["icon"] for a in d["apps"] if a["icon"]]; assert ic and all(i.startswith("appicons/") and i.endswith(".png") for i in ic)'
ICON=$(api "$A/api/apps" | jp 'print([a["icon"] for a in d["apps"] if a["icon"]][0])'); expect "图标文件是 PNG 且由后台 (辅助服务) 提供, Content-Type 为 image/png" sh -c "file '$W/h/ui/$ICON' | grep -q 'PNG image' && test \"\$(curl -s -o /dev/null -w '%{http_code} %{content_type}' --noproxy '*' $A/enana/admin/$ICON)\" = '200 image/png'"
CA=$(mkapp "$W/Custom" "Foo Tool"); mkapp "$HOME/Applications" "Searchable Tool" >/dev/null; mkdir -p "$W/bin" "$W/Custom/Broken.app"; cp /usr/bin/true "$W/bin/mytool"; codesign --force -s - "$W/bin/mytool" >/dev/null 2>&1
insp() { api -X POST --data-urlencode "input=$1" "$A/api/apps/inspect"; }
insp "relative/path" | chk "自定义软件校验: 相对路径 → 无效 + 原因" 'c=d["candidates"][0]; assert not c["valid"] and "绝对路径" in c["reason"]'
insp "/no/such/place.app" | chk "校验: 路径不存在 → 无效" 'c=d["candidates"][0]; assert not c["valid"] and "不存在" in c["reason"]'
insp "$W/Custom/Broken.app" | chk "校验: 目录名像 .app 但没有 Info.plist → 无效" 'assert not d["candidates"][0]["valid"]'
insp "/tmp/x\"; rm -rf ~" | chk "校验: 含引号/分号的恶意路径 → 无效 (不会被执行)" 'assert not d["candidates"][0]["valid"]'
insp "$W/Custom/Foo Tool.app" | chk "校验: 有效的 .app → 返回名称 / BundleID / 版本 / 路径 / 签名 / 图标, 且不重复" 'c=d["candidates"][0]; assert c["valid"] and c["kind"]=="app" and c["name"]=="Foo Tool" and c["bundle_id"]=="test.Foo.Tool" and c["version"]=="1.2.3" and c["signed"] and c["path"].endswith("/Foo Tool.app") and not c["exists"] and c["icon"].startswith("appicons/")'
insp "Searchable" | chk "校验: 按名称搜索 → 在 ~/Applications 里找到候选" 'cs=d["candidates"]; assert len(cs)==1 and cs[0]["valid"] and cs[0]["name"]=="Searchable Tool"'
insp "no*glob" | chk "校验: 名称里有通配符 → 被拒" 'assert not d["candidates"][0]["valid"]'
insp "$W/bin/mytool" | chk "校验: 命令行工具 → kind=bin" 'c=d["candidates"][0]; assert c["valid"] and c["kind"]=="bin" and c["name"]=="mytool"'
insp "$W/h/servers.jsonl" | chk "校验: 普通文件 (不可执行) → 无效" 'assert not d["candidates"][0]["valid"]'
api -X POST "$A/api/apps/custom" --data-urlencode "path=/no/such.app" -d 'state=pin' | chk "添加自定义软件: 路径无效 → 立即被拒 (不进任务)" 'assert not d["ok"] and d["code"]=="E_INVALID"'
api -X POST "$A/api/apps/custom" --data-urlencode "path=$CA" -d 'state=bogus' | chk "添加: 状态无效 → 被拒" 'assert not d["ok"]'
J=$(api -X POST "$A/api/apps/custom" --data-urlencode "path=$CA" -d 'state=pin' | jp 'print(d["job"])'); [ "$(job_wait "$J")" = done ] && tpass "添加自定义软件 (任务完成)" || tfail "添加自定义软件 (任务完成)"
api "$A/api/apps" | chk "应用列表里出现自定义软件: custom=true, state=pin, 带路径" 'a={x["name"]:x for x in d["apps"]}["Foo Tool"]; assert a["custom"] and a["state"]=="pin" and a["kind"]=="app" and a["path"].endswith("/Foo Tool.app")'
insp "$W/Custom/Foo Tool.app" | chk "再次校验同一个软件: exists=true (前端据此提示, 不允许重复添加)" 'assert d["candidates"][0]["exists"]'
api -X POST "$A/api/apps/custom" --data-urlencode "path=$CA" -d 'state=pin' | chk "重复添加 → 被拒" 'assert not d["ok"]'
grep -q 'Foo Tool' "$W/h/rules/ovr-pin.json" && tpass "自定义 .app 写入了「固定出口」规则集 (按路径匹配)" || tfail "自定义 .app 写入了「固定出口」规则集"
J=$(api -X POST "$A/api/apps/custom" --data-urlencode "path=$W/bin/mytool" -d 'state=direct' | jp 'print(d["job"])'); [ "$(job_wait "$J")" = done ] && tpass "添加命令行工具 (任务完成)" || tfail "添加命令行工具 (任务完成)"
grep -q '"process_name":\["mytool"\]' "$W/h/rules/ovr-appdirect.json" && tpass "命令行工具按可执行文件名匹配 (process_name)" || tfail "命令行工具按可执行文件名匹配 (process_name)"
api -X POST "$A/api/apps/custom/delete" -d 'name=mytool' | chk "删除自定义软件 → 任务" 'assert d["ok"] and d["job"]'
sleep 3; api "$A/api/apps" | chk "删除后不再出现, 规则集也清掉了" 'assert not any(x["name"]=="mytool" for x in d["apps"])'
api -X POST "$A/api/apps/custom/delete" -d 'name=Nope' | chk "删除不存在的自定义软件 → E_NOT_FOUND" 'assert d["code"]=="E_NOT_FOUND"'

echo "== 4. 覆盖层热生效 (不重启核心; 先在仪表盘接口里开启代理总开关)"
api -X POST "$A/api/proxy" -d 'on=1' >/dev/null
ENANA_LOG_LEVEL=debug bash "$REPO/install.sh" apply >/dev/null 2>&1; sleep 2
PID=$(cat "$FAKE_STATE/pid-com.enana.proxy")
logconn hot.example.org | grep -q 'geosite-notcn => route(Final)' && tpass "覆盖前: 命中社区规则集 → Final" || tfail "覆盖前: 命中社区规则集 → Final"
api -X POST "$A/api/override?kind=site&value=example.org&state=direct" >/dev/null; sleep 1.5
logconn hot.example.org | grep -q 'ovr-direct => route(direct-site)' && tpass "站点覆盖 → 直连 (热生效, 出口名 direct-site 说明是你设的)" || tfail "站点覆盖 → 直连 (热生效)"
api -X POST "$A/api/override?kind=site&value=example.org&state=pin" >/dev/null; sleep 1.5
logconn hot.example.org | grep -q 'ovr-pin => route(PIN)' && tpass "站点覆盖 → 固定出口 (热生效)" || tfail "站点覆盖 → 固定出口 (热生效)"
api -X POST "$A/api/override?kind=site&value=example.org&state=follow" >/dev/null
mkdir -p "$W/Foo.app/Contents/MacOS"; cp /usr/bin/curl "$W/Foo.app/Contents/MacOS/foo-net"; codesign --force -s - "$W/Foo.app/Contents/MacOS/foo-net" 2>/dev/null
api -X POST "$A/api/override?kind=app&value=Foo&state=pin" >/dev/null; sleep 1.5; : > "$W/h/sing-box.log"
"$W/Foo.app/Contents/MacOS/foo-net" -s -m 4 -x "socks5h://127.0.0.1:$PORT" http://plain.test/ -o /dev/null 2>/dev/null; sleep 1.2
sed 's/\x1b\[[0-9;]*m//g' "$W/h/sing-box.log" | grep -q 'ovr-apppin => route(PIN)' && tpass "按应用覆盖: Foo.app → 固定出口 (识别到进程路径)" || tfail "按应用覆盖 (进程路径识别)"
api -X POST "$A/api/proxy" -d 'mode=sideways' | chk "代理模式无效 → 被拒" 'assert not d["ok"]'
api -X POST "$A/api/proxy" -d 'mode=global' | chk "切到「全局代理」模式" 'assert d["ok"] and d["mode"]=="global" and d["enabled"] is True'
cl "$U/configs" | chk "核心模式 = Global" 'assert d["mode"]=="Global"'
api "$A/api/state" | chk "state.proxy = {enabled, mode=global}" 'assert d["proxy"]["enabled"] is True and d["proxy"]["mode"]=="global"'
logconn plain-global.example | grep -q 'clash_mode=Global => route(Global)' && tpass "全局代理: 普通网站全部走代理 (Global)" || tfail "全局代理: 普通网站全部走代理 (Global)"
logconn cn.example | grep -q 'clash_mode=Global => route(Global)' && tpass "全局代理: 国内域名也走代理 (忽略国内直连规则)" || tfail "全局代理: 国内域名也走代理 (忽略国内直连规则)"
logconn claude.ai | grep -q 'route(svc-claude)' && tpass "全局代理: 固定出口类服务 (Claude) 仍走固定出口" || tfail "全局代理: 固定出口类服务仍走固定出口"
api -X POST "$A/api/override?kind=site&value=example.org&state=direct" >/dev/null; sleep 1.5
logconn hot.example.org | grep -q 'ovr-direct => route(direct-site)' && tpass "全局代理: 用户手动设置的网站 (直连) 仍然生效" || tfail "全局代理: 用户手动设置的网站仍然生效"
api -X POST "$A/api/override?kind=site&value=example.org&state=follow" >/dev/null
expect "模式写进设置与磁盘配置" sh -c "grep -q '^PROXY_MODE=global' '$W/h/settings.env' && grep -q '\"default_mode\":\"Global\"' '$W/h/config.json'"
api -X POST "$A/api/proxy" -d 'mode=auto' | chk "切回「自动模式」" 'assert d["ok"] and d["mode"]=="auto"'
cl "$U/configs" | chk "核心模式 = Rule" 'assert d["mode"]=="Rule"'
logconn hot.example.org | grep -q 'geosite-notcn => route(Final)' && tpass "自动模式: 又按规则分流了" || tfail "自动模式: 又按规则分流了"
expect "整个过程核心没有重启 (PID 不变)" test "$PID" = "$(cat "$FAKE_STATE/pid-com.enana.proxy")"
CB=$(mkapp "$W/Custom" "Bar Tool" /usr/bin/curl); J=$(api -X POST "$A/api/apps/custom" --data-urlencode "path=$CB" -d 'state=pin' | jp 'print(d["job"])'); job_wait "$J" >/dev/null
ENANA_LOG_LEVEL=debug bash "$REPO/install.sh" apply >/dev/null 2>&1; sleep 2.5; : > "$W/h/sing-box.log"       # (任务重新生成配置时日志级别回到默认, 这里再切回 debug 才看得到路由日志)
"$CB/Contents/MacOS/Bar-Tool" -s -m 4 -x "socks5h://127.0.0.1:$PORT" http://plain2.test/ -o /dev/null 2>/dev/null; sleep 1.2
sed 's/\x1b\[[0-9;]*m//g' "$W/h/sing-box.log" | grep -q 'ovr-apppin => route(PIN)' && tpass "自定义软件 (Bar Tool.app) 的流量按设置走固定出口" || tfail "自定义软件的流量按设置走固定出口"
api -X POST "$A/api/apps/custom/delete" -d 'name=Bar Tool' >/dev/null; sleep 3
api -X POST "$A/api/override?kind=site&value=a%20b&state=direct" | chk "非法站点名被拒" 'assert not d["ok"]'

echo "== 4b. 固定出口 ≥ 2 个: 应用 / 网站可以指定走哪一个固定出口 (或在固定出口里自动选一个) · 直连原因出口名 · 访问记录 (用核心真实日志)"
api -X POST "$A/api/override?kind=site&value=target.example&state=pin&target=Fix-Pin" | chk "只有 1 个固定出口时不能指定出口 → 被拒" 'assert not d["ok"]'
cp "$W/h/servers.jsonl" "$W/servers.before-pin2"
printf '%s\n' '{"role":"pin","outbound":{"type":"socks","tag":"Fix-Pin2","server":"127.0.0.1","server_port":3,"version":"5","username":"u","password":"p"}}' >> "$W/h/servers.jsonl"
ENANA_LOG_LEVEL=debug bash "$REPO/install.sh" apply >/dev/null 2>&1; sleep 2.5
api -X POST "$A/api/override?kind=site&value=target.example&state=pin&target=Nope" | chk "指定的出口不存在 → 被拒" 'assert not d["ok"]'
api -X POST "$A/api/override?kind=site&value=target.example&state=direct&target=Fix-Pin2" | chk "只有「固定出口」状态才带出口 (其它状态下 target 被忽略)" 'assert d["ok"]'
api -X POST "$A/api/override?kind=site&value=target.example&state=pin&target=Fix-Pin2" | chk "2 个固定出口: 网站指定走 Fix-Pin2 → 成功" 'assert d["ok"]'
api "$A/api/state" | chk "状态里带出口: target=Fix-Pin2, target_ok=true, 来源 user" 'o={x["value"]:x for x in d["overrides"]}["target.example"]; assert o["state"]=="pin" and o["target"]=="Fix-Pin2" and o["target_ok"] and o["src"]=="user"'
sleep 1.5; logconn target.example | grep -q 'ovr-pin-2 => route(Fix-Pin2)' && tpass "指定出口 (热生效): 走的就是 Fix-Pin2 (规则集 ovr-pin-2)" || tfail "指定出口 (热生效)"
api "$A/api/logs?type=access&q=target.example" | chk "访问记录 (核心真实日志): 走了固定出口 Fix-Pin2, 连不上 → route=pin, 记下失败类型" 'r=d["rows"][0]; assert r["host"]=="target.example" and r["route"]=="pin" and r["node"]=="Fix-Pin2" and r["err"] in ("refused","reset","eof","other","timeout") and d["summary"]["error"]>=1'
api -X POST "$A/api/override?kind=site&value=target.example&state=pin&target=PINAUTO" >/dev/null; sleep 1.5
logconn target.example | grep -q 'ovr-pinauto => route(PINAUTO)' && tpass "「在固定出口里自动选」→ PINAUTO (urltest)" || tfail "自动选固定出口 (PINAUTO)"
api -X POST "$A/api/override?kind=site&value=target.example&state=pin" >/dev/null; sleep 1.5
logconn target.example | grep -q 'ovr-pin => route(PIN)' && tpass "不指定 → 默认固定出口 PIN" || tfail "默认固定出口 PIN"
api "$A/api/logs?type=ops&q=target.example" | chk "操作记录: 修改应用/网站策略 —— 谁 / 什么 / 从什么改成什么 / 原来的出口 (target_from)" 'r=[x for x in d["rows"] if x["action"]=="修改应用/网站策略"]; assert len(r)>=3 and "name=target.example" in r[0]["detail"] and "to=pin" in r[0]["detail"] and "target_from=PINAUTO" in r[0]["detail"] and r[0]["who"]=="dashboard"'
api -X POST "$A/api/override?kind=app&value=Foo&state=pin&target=Fix-Pin2" >/dev/null; sleep 1.5; : > "$W/h/sing-box.log"
"$W/Foo.app/Contents/MacOS/foo-net" -s -m 4 -x "socks5h://127.0.0.1:$PORT" http://plain3.test/ -o /dev/null 2>/dev/null; sleep 1.2
sed 's/\x1b\[[0-9;]*m//g' "$W/h/sing-box.log" | grep -q 'ovr-apppin-2 => route(Fix-Pin2)' && tpass "按应用指定出口: Foo.app → Fix-Pin2" || tfail "按应用指定出口"
cl "$U/proxies" | chk "每个服务的选择器 (svc-claude) 可选项里多了「在固定出口里自动选」和各固定出口" 'a=d["proxies"]["svc-claude"]["all"]; assert "PINAUTO" in a and "Fix-Pin" in a and "Fix-Pin2" in a and "PIN" in a'
api -X POST "$A/api/policy" -d 'tag=svc-claude&name=Fix-Pin2' | chk "网站页切换 svc-claude → Fix-Pin2 (经辅助服务)" 'assert d["ok"] and d["to"]=="Fix-Pin2"'
cl "$U/proxies" | chk "核心里的选择器确实切换了" 'assert d["proxies"]["svc-claude"]["now"]=="Fix-Pin2"'
api "$A/api/logs?type=ops&q=svc-claude" | chk "操作记录: 切换策略 (选择器 / 网站名 / 从什么改成什么)" 'r=d["rows"][0]; assert r["action"]=="切换策略" and "tag=svc-claude" in r["detail"] and "to=Fix-Pin2" in r["detail"] and "from=" in r["detail"]'
api -X POST "$A/api/policy" -d 'tag=svc-claude&name=NoSuch' | chk "切换到不存在的选项 → 被拒" 'assert not d["ok"]'
api -X POST "$A/api/policy" -d 'tag=bad tag&name=PIN' | chk "选择器名称不合法 → 被拒" 'assert not d["ok"]'
api -X POST "$A/api/policy" -d 'tag=svc-claude&name=PIN' >/dev/null
# 直连原因: 出口名区分
api -X POST "$A/api/override?kind=site&value=example.org&state=direct" >/dev/null; sleep 1.5; logconn hot.example.org >/dev/null
api "$A/api/logs?type=access&q=hot.example.org" | chk "访问记录: 你把网站设为直连 → route=direct, reason=site (direct-site)" 'r=d["rows"][0]; assert r["route"]=="direct" and r["reason"]=="site" and r["node"]=="direct-site"'
api -X POST "$A/api/override?kind=site&value=example.org&state=follow" >/dev/null
api -X POST "$A/api/override?kind=app&value=Foo&state=direct" >/dev/null; sleep 1.5; : > "$W/h/sing-box.log"
"$W/Foo.app/Contents/MacOS/foo-net" -s -m 4 -x "socks5h://127.0.0.1:$PORT" http://plain4.test/ -o /dev/null 2>/dev/null; sleep 1.2
api "$A/api/logs?type=access&q=plain4.test" | chk "访问记录: 你把应用设为关 → reason=app (direct-app), 能看到是哪个应用" 'r=d["rows"][0]; assert r["route"]=="direct" and r["reason"]=="app" and r["node"]=="direct-app" and r["app"]=="Foo"'
logconn cn.example >/dev/null; api "$A/api/logs?type=access&q=cn.example" | chk "访问记录: 国内规则 → reason=cn (direct-cn)" 'r=d["rows"][0]; assert r["route"]=="direct" and r["reason"]=="cn"'
logconn 192.168.77.7 >/dev/null; api "$A/api/logs?type=access&q=192.168.77.7" | chk "访问记录: 局域网地址 → reason=lan (direct-lan)" 'r=d["rows"][0]; assert r["route"]=="direct" and r["reason"]=="lan"'
api -X POST "$A/api/proxy" -d 'on=0' >/dev/null; sleep 1; logconn hot.example.org >/dev/null
api "$A/api/logs?type=access&q=hot.example.org" | chk "访问记录 (代理总开关关闭时也有记录): 全部直连, reason=mode (direct-mode)" 'r=d["rows"][0]; assert r["route"]=="direct" and r["reason"]=="mode" and r["node"]=="direct-mode"'
api -X POST "$A/api/proxy" -d 'on=1' >/dev/null; sleep 1
# 指定的固定出口被删除: 设置不丢, 退回默认固定出口, 标记失效
api -X POST "$A/api/override?kind=site&value=target.example&state=pin&target=Fix-Pin2" >/dev/null
cp "$W/servers.before-pin2" "$W/h/servers.jsonl"; ENANA_LOG_LEVEL=debug bash "$REPO/install.sh" apply >/dev/null 2>&1; sleep 2.5
api "$A/api/state" | chk "固定出口被删除后: 网站设置的出口标记为失效 (target_ok=false), 设置还在" 'o={x["value"]:x for x in d["overrides"]}["target.example"]; assert o["state"]=="pin" and o["target"]=="Fix-Pin2" and not o["target_ok"]'
logconn target.example | grep -q 'ovr-pin => route(PIN)' && tpass "出口失效 → 退回默认固定出口 (不会断网)" || tfail "出口失效 → 退回默认固定出口"
api -X POST "$A/api/override?kind=site&value=target.example&state=follow" | chk "网站设置恢复跟随 (删除覆盖)" 'assert d["ok"]'
api -X POST "$A/api/override?kind=app&value=Foo&state=pin" >/dev/null; sleep 1

echo "== 4bb. Browser fallback and rejected Enhanced authorization"
FB=$(mkapp "$W/Custom" "Fixture Browser" /usr/bin/curl)
python3 - "$FB/Contents/Info.plist" <<'BROWSER'
import sys,plistlib
p=sys.argv[1]; d=plistlib.load(open(p,'rb')); d['CFBundleURLTypes']=[{'CFBundleURLSchemes':['http','https']}]; plistlib.dump(d,open(p,'wb'))
BROWSER
codesign --force -s - "$FB" >/dev/null 2>&1
J=$(api -X POST "$A/api/apps/custom" --data-urlencode "path=$FB" -d 'state=follow' | jp 'print(d["job"])'); job_wait "$J" >/dev/null
ENANA_LOG_LEVEL=debug bash "$REPO/install.sh" apply >/dev/null 2>&1; sleep 2
cl -X PUT "$U/proxies/svc-claude" -d '{"name":"PIN"}' >/dev/null
for policy in direct auto; do
  api -G -X POST --data-urlencode 'kind=app' --data-urlencode 'value=Fixture Browser' --data-urlencode "state=$policy" "$A/api/override" | chk "Browser $policy policy API accepts query parameters" 'assert d["ok"]'; sleep 1.5
  expect "Browser $policy rule set contains the actual process" grep -q "Fixture Browser" "$W/h/rules/ovr-browser$policy.json"
  : > "$W/h/sing-box.log"
  "$FB/Contents/MacOS/Fixture-Browser" -s -m 3 -x "socks5h://127.0.0.1:$PORT" http://claude.com/ -o /dev/null 2>/dev/null; sleep 1
  expect "Browser $policy does not override website PIN (real process path)" grep -q 'route(svc-claude)' "$W/h/sing-box.log"
done
# Websites outrank browser PIN; native app PIN still controls that app's traffic.
printf '%s\n' '{"role":"pin","outbound":{"type":"socks","tag":"Browser-Other-PIN","server":"127.0.0.1","server_port":3,"version":"5"}}' >> "$W/h/servers.jsonl"
ENANA_LOG_LEVEL=debug bash "$REPO/install.sh" apply >/dev/null 2>&1; sleep 2
api -G -X POST --data-urlencode 'kind=site' -d 'value=claude.com&state=pin&target=Browser-Other-PIN' "$A/api/override" >/dev/null
api -G -X POST --data-urlencode 'kind=app' --data-urlencode 'value=Fixture Browser' -d 'state=pin' "$A/api/override" >/dev/null; sleep 1.5
: > "$W/h/sing-box.log"
"$FB/Contents/MacOS/Fixture-Browser" -s -m 3 -x "socks5h://127.0.0.1:$PORT" http://claude.com/ -o /dev/null 2>/dev/null; sleep 1
expect "Website-specific PIN outranks browser default PIN" grep -q 'ovr-pin-2 => route(Browser-Other-PIN)' "$W/h/sing-box.log"
: > "$W/h/sing-box.log"; "$FB/Contents/MacOS/Fixture-Browser" -s -m 3 -x "socks5h://127.0.0.1:$PORT" http://browser-fallback.example/ -o /dev/null 2>/dev/null || true; sleep 1
expect "Browser PIN remains the fallback for unconfigured websites" grep -q 'ovr-browserpin => route(PIN)' "$W/h/sing-box.log"
api -G -X POST --data-urlencode 'kind=app' --data-urlencode 'value=Foo' -d 'state=pin' "$A/api/override" >/dev/null; sleep 1.5
: > "$W/h/sing-box.log"; "$W/Foo.app/Contents/MacOS/foo-net" -s -m 3 -x "socks5h://127.0.0.1:$PORT" http://claude.com/ -o /dev/null 2>/dev/null || true; sleep 1
expect "Native app PIN outranks website-specific alternate PIN" grep -q 'ovr-apppin => route(PIN)' "$W/h/sing-box.log"
api -G -X POST --data-urlencode 'kind=app' --data-urlencode 'value=Foo' -d 'state=direct' "$A/api/override" >/dev/null
api -G -X POST -d 'kind=site&value=claude.com&state=follow' "$A/api/override" >/dev/null
python3 - "$W/h/servers.jsonl" <<'RESTORE'
import sys,json
p=sys.argv[1]; rows=[l for l in open(p) if json.loads(l)['outbound']['tag']!='Browser-Other-PIN'];open(p,'w').writelines(rows)
RESTORE
api -G -X POST --data-urlencode 'kind=app' --data-urlencode 'value=Fixture Browser' -d 'state=follow' "$A/api/override" >/dev/null
bash "$REPO/install.sh" apply >/dev/null 2>&1; sleep 1.5 # leave debug instrumentation before cancellation check
NM_PID=$(cat "$FAKE_STATE/pid-com.enana.proxy")
J=$(api -X POST "$A/api/network-mode" -d 'mode=tun' | jp 'print(d["job"])')
expect "TUN authorization cancellation reports a failed job" test "$(job_wait "$J")" = error
api "$A/api/state" | chk "Cancelled Enhanced selection keeps System mode and live service" 'assert d["proxy"]["network_mode"]=="system" and d["env"]["service"]'
expect "Cancelled Enhanced selection leaves original core PID untouched" test "$NM_PID" = "$(cat "$FAKE_STATE/pid-com.enana.proxy")"
api -X POST "$A/api/network-mode" -d 'mode=invalid' | chk "Capture mode validates its input" 'assert not d["ok"]'

echo "== 4c. 流量统计 (每分钟采样 → 本机按小时 / 天 / 节点累加; 只保留 3 个月)"
ST=$W/st; mkdir -p "$ST"; printf 'Fix-Pin\tpin\nLocal-Hop\tauto\n' > "$ST/roles"
NOW0=$(date -j -f '%Y-%m-%d %H:%M:%S' "$(date +%F) 10:30:00" +%s)
col() { printf '%s' "$1" | ENANA_NOW=$2 perl "$REPO/lib/stats.pl" collect "$ST" "$ST/roles" auto; }
col '{"downloadTotal":1000,"uploadTotal":100,"connections":[]}' $NOW0
expect "第一次采样只建立基线, 不记录任何流量 (不把核心启动以来的累计算进来)" test ! -s "$ST/daily.tsv"
col '{"downloadTotal":6000,"uploadTotal":600,"connections":[{"id":"a","upload":300,"download":4000,"chains":["Fix-Pin","PIN","svc-claude"]},{"id":"b","upload":50,"download":500,"chains":["direct"]}]}' $((NOW0+60))
perl "$REPO/lib/stats.pl" report "$ST" today | chk "今日 (按小时 24 格): 总量准确 = 累计计数的增量 (下载 5000 / 上传 500)" 'assert d["granularity"]=="hour" and len(d["series"])==24 and d["total"]["down"]==5000 and d["total"]["up"]==500 and d["series"][10]["down"]==5000 and sum(x["down"] for x in d["series"])==5000'
perl "$REPO/lib/stats.pl" report "$ST" today | chk "分类: 固定出口约 4443 / 直连约 556 (已结束连接的差额按比例分摊, 总和 = 总量)" 'r=d["routes"]; assert abs(r["pin"]["down"]-4443)<=3 and abs(r["direct"]["down"]-556)<=3 and r["auto"]["down"]==0 and r["pin"]["down"]+r["direct"]["down"]+r["auto"]["down"]>=4995'
perl "$REPO/lib/stats.pl" report "$ST" today | chk "按节点: Fix-Pin 有流量, 直连不算节点" 'n={x["tag"]:x for x in d["nodes"]}; assert n["Fix-Pin"]["down"]>=4000 and "direct" not in n'
col '{"downloadTotal":300,"uploadTotal":30,"connections":[]}' $((NOW0+120))
perl "$REPO/lib/stats.pl" report "$ST" today | chk "核心重启 (累计计数变小) 被识别, 从新计数开始累加 (+300/+30)" 'assert d["total"]["down"]==5300 and d["total"]["up"]==530'
for r in 3d:3 7d:7 30d:30 90d:90; do nd=${r##*:}; perl "$REPO/lib/stats.pl" report "$ST" "${r%%:*}" | chk "范围 ${r%%:*}: $nd 天的日序列, 今天有数据, 范围外为 0" "assert d['granularity']=='day' and len(d['series'])==$nd and d['series'][-1]['down']==5300 and sum(x['down'] for x in d['series'])==5300 and d['since']!=''"
done
OLD100=$(date -v-100d +%F); OLD50=$(date -v-50d +%F)
printf '%s\t10\t20\t0\t0\t0\t0\t10\t20\n%s\t1\t2\t0\t0\t0\t0\t1\t2\n' "$OLD100" "$OLD50" | cat - "$ST/daily.tsv" > "$ST/daily.new" && mv "$ST/daily.new" "$ST/daily.tsv"
perl "$REPO/lib/stats.pl" purge "$ST"
expect "超过 3 个月 (100 天前) 的本地数据被自动清除, 50 天前的保留" sh -c "! grep -q '$OLD100' '$ST/daily.tsv' && grep -q '$OLD50' '$ST/daily.tsv'"
perl "$REPO/lib/stats.pl" report "$ST" 90d | chk "90 天范围包含 50 天前的数据" 'assert d["total"]["down"]==5302 and d["retention_days"]==92'
printf '%s\n' "$(date -v-4d +%F)	04	1	2	0	0	3" > "$ST/hourly.tsv"; perl "$REPO/lib/stats.pl" purge "$ST"
expect "超过 72 小时的按小时数据被清除" test ! -s "$ST/hourly.tsv"
api "$A/api/stats?range=bad" | chk "统计范围无效 → 被拒" 'assert not d["ok"]'
rm -rf "$W/h/stats"; "$W/shortcut/enana" tick --quiet >/dev/null 2>&1
expect "定时任务 enana tick 能真实采样核心 (建立了采样基线)" test -s "$W/h/stats/state.json"
api "$A/api/stats?range=today" | chk "接口: today 返回 24 个小时格, 总量 ≥ 0 (核心不统计发往私有地址/本机的流量, 所以这里没有数据)" 'assert d["ok"] and d["range"]=="today" and len(d["series"])==24 and d["total"]["down"]>=0'
api "$A/api/stats?range=30d" | chk "接口: 30d 返回 30 天" 'assert d["ok"] and len(d["series"])==30'

echo "== 5. 策略开关跨重启保留"
cl -X PUT -d '{"name":"direct"}' "$U/proxies/svc-claude" -o /dev/null
J=$(api -X POST "$A/api/restart" | jp 'print(d["job"])'); [ "$(job_wait "$J")" = done ] && tpass "重启任务完成 (进度可轮询)" || tfail "重启任务完成"
sleep 1; cl "$U/proxies" | chk "svc-claude 的选择重启后仍保留" 'assert d["proxies"]["svc-claude"]["now"]=="direct"'
cl -X PUT -d '{"name":"PIN"}' "$U/proxies/svc-claude" -o /dev/null

echo "== 6. 服务器事务: 坏配置回滚 + 连续操作不互相覆盖"
BEFORE=$(md5 -q "$W/h/servers.jsonl"); cp "$W/h/servers.jsonl" "$W/servers.before"
echo '{"role":"auto","outbound":{"type":"trojan","tag":"Bad-Node","server":"127.0.0.1","server_port":8,"password":"pw","bogus_field":1}}' > "$W/bad.jsonl"
J1=$(api -X POST --data-binary @"$W/bad.jsonl" "$A/api/servers/import?mode=merge" | jp 'print(d["job"])')
J2=$(api -X POST "$A/api/servers/role?tag=Fix%20Auto%201&role=off" | jp 'print(d["job"])')
J3=$(api -X POST "$A/api/servers/role?tag=Fix%20Auto%201&role=auto" | jp 'print(d["job"])')
[ "$(job_wait $J1)" = error ] && tpass "坏配置的导入任务以 error 结束" || tfail "坏配置的导入任务以 error 结束"
[ "$(job_wait $J2)" = done ] && [ "$(job_wait $J3)" = done ] && tpass "紧接着的两个操作正常完成" || tfail "紧接着的两个操作正常完成"
if [ "$(md5 -q "$W/h/servers.jsonl")" = "$BEFORE" ]; then tpass "服务器文件与起点完全一致 (坏节点没有残留)"; else tfail "服务器文件与起点完全一致 (坏节点没有残留)"; diff "$W/servers.before" "$W/h/servers.jsonl" | head -6; fi
expect "核心仍在运行" nc -z 127.0.0.1 "$PORT"
echo '{"role":"auto","outbound":{"type":"trojan","tag":"Good-Node","server":"127.0.0.1","server_port":9,"password":"pw","tls":{"enabled":true,"insecure":true}}}' > "$W/good.jsonl"
J=$(api -X POST --data-binary @"$W/good.jsonl" "$A/api/servers/import?mode=merge" | jp 'print(d["job"])'); [ "$(job_wait $J)" = done ] && tpass "正常导入成功" || tfail "正常导入成功"
cl "$U/proxies" | chk "新节点出现在自动线路池里" 'assert "Good-Node" in d["proxies"]["AUTO"]["all"]'
cl "$U/proxies" | chk "测速选择器 SPEEDTEST 含全部节点 + direct/PIN/Global" 'a=d["proxies"]["SPEEDTEST"]["all"]; assert all(x in a for x in ["direct","PIN","Global","Good-Node","Local-Hop","Fix-Pin"])'

echo "== 7. 证书与订阅校验"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$W/k.pem" -out "$W/c.pem" -days 2 -subj '/CN=t.local' 2>/dev/null
api -X POST --data-binary @"$W/c.pem" "$A/api/cert?name=My-Server" | grep -q '@CERTS@/My-Server.crt' && tpass "证书上传返回引用路径" || tfail "证书上传返回引用路径"
echo hello | api -X POST --data-binary @- "$A/api/cert?name=x" | grep -q '"ok":false' && tpass "非证书内容被拒" || tfail "非证书内容被拒"
echo 'http://127.0.0.1/x' | api -X POST --data-binary @- "$A/api/sub/save?name=t1" | grep -q '"ok":false' && tpass "指向本机的订阅链接被拒" || tfail "指向本机的订阅链接被拒"
echo 'https://sub.example.com/s/SECRETTOKEN' | api -X POST --data-binary @- "$A/api/sub/save?name=demo" >/dev/null
api "$A/api/state" | grep -q SECRETTOKEN && tfail "订阅令牌没有泄露给仪表盘" || tpass "订阅令牌没有泄露给仪表盘"

echo "== 7b. 敏感操作要再次输入密码 (step-up) · 查看凭据 · 导出备份 · 修改密码 · 偏好设置 · 套餐"
for ep in "POST servers/delete" "POST sub/delete" "POST logs/clear" "POST devices/kick" "POST sync/clear" "GET servers/secret?tag=x" "GET sub/url?name=x" "GET export"; do
  set -- $ep
  CODE=$(curl -s -o "$W/gate.json" -w '%{http_code}' --noproxy '*' -X "$1" -H "$X" -H "X-Enana-Token: $TOKEN" "$A/api/$2")
  if [ "$CODE" = 403 ] && grep -q '"code":"E_SUDO_REQUIRED"' "$W/gate.json"; then tpass "没有 sudo 令牌: $1 /api/${2%%\?*} → 403 E_SUDO_REQUIRED"; else tfail "没有 sudo 令牌: $1 /api/${2%%\?*} → 403 E_SUDO_REQUIRED (得到 $CODE)"; fi
done
CODE=$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' -X POST -H "$X" -H "X-Enana-Token: $TOKEN" -H "X-Enana-Sudo: 00000000000000000000000000000000" "$A/api/logs/clear"); [ "$CODE" = 403 ] && tpass "随便编一个 sudo 令牌 → 403" || tfail "随便编一个 sudo 令牌 → 403 (得到 $CODE)"
CODE=$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' -X POST -H "$X" -H "X-Enana-Token: $TOKEN" -H "X-Enana-Sudo: ../../etc/passwd" "$A/api/logs/clear"); [ "$CODE" = 403 ] && tpass "sudo 令牌含非法字符 → 403" || tfail "sudo 令牌含非法字符 → 403 (得到 $CODE)"
verify() { curl -s --noproxy '*' -H "$X" -H "X-Enana-Token: $TOKEN" --data-urlencode "password=$1" "$A/api/auth/verify"; }
verify 'wrong-pw' | chk "二次验证: 密码错误 → E_BAD_CREDENTIALS" 'assert not d["ok"] and d["code"]=="E_BAD_CREDENTIALS"'
verify '' | chk "二次验证: 没填密码 → E_INVALID" 'assert not d["ok"] and d["code"]=="E_INVALID"'
CODE=$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' -H "$X" --data-urlencode "password=x" "$A/api/auth/verify"); [ "$CODE" = 401 ] && tpass "二次验证接口本身需要登录令牌 (401)" || tfail "二次验证接口本身需要登录令牌 (得到 $CODE)"
S=$(verify 'New-Passw0rd2'); echo "$S" | chk "二次验证成功: 32 位 sudo 令牌, 有效期 300 秒" 'assert d["ok"] and len(d["sudo"])==32 and d["ttl"]==300'
SUDO1=$(echo "$S" | jp 'print(d["sudo"])')
expect "sudo 令牌文件权限 600, 里面只有哈希 (没有令牌明文)" sh -c "test \"\$(stat -f %Lp '$W/h/sudo.tokens')\" = 600 && ! grep -q '$SUDO1' '$W/h/sudo.tokens'"
sdo() { curl -s --noproxy '*' -H "$X" -H "X-Enana-Token: $TOKEN" -H "X-Enana-Sudo: $SUDO1" "$@"; }
sdo "$A/api/servers/secret?tag=Good-Node" | chk "查看节点凭据 (需 sudo): 只返回凭据类字段" 'assert d["ok"] and d["tag"]=="Good-Node" and d["fields"]==[{"name":"password","value":"pw"}]'
sdo "$A/api/servers/secret?tag=No-Such" | chk "不存在的节点 → E_NOT_FOUND" 'assert d["code"]=="E_NOT_FOUND"'
sdo "$A/api/sub/url?name=demo" | chk "查看订阅链接 (需 sudo)" 'assert d["ok"] and d["url"]=="https://sub.example.com/s/SECRETTOKEN"'
sdo "$A/api/sub/url?name=nope" | chk "不存在的订阅 → E_NOT_FOUND" 'assert d["code"]=="E_NOT_FOUND"'
sdo "$A/api/export" -D "$W/exp.hdr" -o "$W/exp.json"
grep -qi 'content-disposition: attachment; filename="enana-backup-[0-9]*\.json"' "$W/exp.hdr" && tpass "导出备份: 以文件下载的方式返回" || tfail "导出备份: 以文件下载的方式返回"
cat "$W/exp.json" | chk "导出的备份: 格式 1, 含服务器 / 订阅 / 设置" 'f=d["files"]; assert d["format"]==1 and d["app"]=="enana" and "Good-Node" in f["servers.jsonl"] and "SECRETTOKEN" in f["subs.tsv"] and isinstance(d["settings"],dict) and set(d["settings"]) <= {"LANG_UI","LOG_DAYS","ACCESS_LOG","AUTO_UPDATE"} and "My-Server.crt" in d["certs"]'
expect "导出的备份里没有令牌 / 云端令牌 / 设备编号 / 端口 / 代理总开关" sh -c "! grep -q \"$(cat "$W/h/secret")\" '$W/exp.json' && ! grep -q \"$(cat "$W/h/device.id")\" '$W/exp.json' && ! grep -q \"$(cat "$W/h/cloud.token")\" '$W/exp.json' && ! grep -q -e PROXY_ENABLED -e 'PORT=' '$W/exp.json'"
api "$A/api/logs?type=ops" | chk "操作记录里有「查看服务器凭据」, 但不含凭据本身" 't=json.dumps(d["rows"],ensure_ascii=False); assert any(r["action"]=="查看服务器凭据" for r in d["rows"]) and "SECRETTOKEN" not in t'
sed -i '' 's/ [0-9]*$/ 1/' "$W/h/sudo.tokens"
sdo "$A/api/servers/secret?tag=Good-Node" | chk "sudo 令牌过期后 → E_SUDO_REQUIRED" 'assert d["code"]=="E_SUDO_REQUIRED"'
for i in 1 2 3 4 5; do date +%s >> "$W/h/auth.fail"; done
verify 'New-Passw0rd2' | chk "连续失败 5 次后二次验证被锁定 (E_LOCKED + wait), 正确密码也被拦" 'assert d["code"]=="E_LOCKED" and 0<d["wait"]<=300'
rm -f "$W/h/auth.fail"

echo "-- 修改密码 (本机提交给云端; 当前设备保持登录, 其它设备全部下线)"
seed user1@example.test dev-zzzz-9999 macos "另一台 Mac"
pw() { api -X POST "$A/api/password" "$@"; }
pw --data-urlencode 'old=wrong-old' --data-urlencode 'new=Third-Passw0rd3' | chk "改密码: 旧密码不对 → E_BAD_CREDENTIALS" 'assert d["code"]=="E_BAD_CREDENTIALS"'
pw --data-urlencode 'old=New-Passw0rd2' --data-urlencode 'new=short' | chk "新密码太短 → E_WEAK_PASSWORD (不用问云端)" 'assert d["code"]=="E_WEAK_PASSWORD"'
pw --data-urlencode 'old=New-Passw0rd2' --data-urlencode 'new=New-Passw0rd2' | chk "新旧密码相同 → E_WEAK_PASSWORD" 'assert d["code"]=="E_WEAK_PASSWORD"'
curl -s -X POST "http://127.0.0.1:$A_PORT/_test/mode?m=down" >/dev/null
pw --data-urlencode 'old=New-Passw0rd2' --data-urlencode 'new=Third-Passw0rd3' | chk "连不上 enana.cc → E_ACCOUNT_UNREACHABLE (改密码必须在线)" 'assert d["code"]=="E_ACCOUNT_UNREACHABLE"'
curl -s -X POST "http://127.0.0.1:$A_PORT/_test/mode?m=ok" >/dev/null
CODE=$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' -X POST -H "$X" --data-urlencode 'old=a' --data-urlencode 'new=bbbbbbbbb' "$A/api/password"); [ "$CODE" = 401 ] && tpass "改密码需要登录令牌 (401)" || tfail "改密码需要登录令牌 (得到 $CODE)"
SESS_BEFORE=$(cat "$W/h/session")
pw --data-urlencode 'old=New-Passw0rd2' --data-urlencode 'new=Third-Passw0rd3' | chk "改密码成功" 'assert d["ok"]'
expect "当前设备仍处于登录状态, 会话没变" sh -c "test -f '$W/h/loggedin' && test \"\$(cat '$W/h/session')\" = '$SESS_BEFORE'"
curl -s "http://127.0.0.1:$A_PORT/_test/sessions" | chk "账号下其它设备的会话全部被云端撤销 (password_changed), 本机的仍然有效" 's={x["uid"]:x for x in d["sessions"] if x["user"]=="rec1abc23"}; assert s["dev-zzzz-9999"]["revoked"]=="password_changed" and any(x["active"] for x in s.values())'
verify 'New-Passw0rd2' | chk "改完后本机校验值已刷新: 旧密码不再通过" 'assert d["code"]=="E_BAD_CREDENTIALS"'
verify 'Third-Passw0rd3' | chk "改完后新密码通过二次验证" 'assert d["ok"]'
"$W/shortcut/enana" tick --quiet >/dev/null 2>&1; rm -f "$W/h/.hb.last"; "$W/shortcut/enana" tick --quiet >/dev/null 2>&1
expect "改密码后心跳仍然正常 (没有被当成会话失效)" sh -c "test -f '$W/h/loggedin' && test ! -f '$W/h/hb.fail'"
pw --data-urlencode 'old=Third-Passw0rd3' --data-urlencode 'new=New-Passw0rd2' | chk "改回原来的密码 (后面的测试沿用)" 'assert d["ok"]'
verify 'New-Passw0rd2' | chk "改回后的二次验证通过 (同时清掉失败计数)" 'assert d["ok"]'
rm -f "$W/h/auth.fail"

echo "-- 偏好设置 (prefs): 界面习惯存在本机, 可同步"
api "$A/api/prefs" | chk "初始: 空对象, version=0" 'assert d["ok"] and d["prefs"]=={} and d["version"]==0'
pp() { api -X POST --data-binary "$1" "$A/api/prefs"; }
pp 'not json' | chk "不是 JSON → 被拒" 'assert not d["ok"] and d["code"]=="E_INVALID"'
pp '[1,2,3]' | chk "JSON 数组 (不是对象) → 被拒" 'assert not d["ok"]'
python3 -c 'print("{\"a\":\"" + "x"*33000 + "\"}")' > "$W/big.json"; api -X POST --data-binary @"$W/big.json" "$A/api/prefs" | chk "超过 32 KB → 被拒" 'assert not d["ok"] and "32" in d["error"]'
pp '{"ui.sidebar.collapsed":true,"table.sites.pageSize":20,"名称":"中文值"}' | chk "保存偏好设置 → version=1" 'assert d["ok"] and d["version"]==1'
api "$A/api/prefs" | chk "读回: 内容一致 (含中文), 有更新时间" 'assert d["prefs"]["table.sites.pageSize"]==20 and d["prefs"]["ui.sidebar.collapsed"] is True and d["prefs"]["名称"]=="中文值" and d["version"]==1 and d["updated"]>0'
api "$A/api/state" | chk "state.prefs_version 随之变化" 'assert d["prefs_version"]==1'
pp '{"table.sites.pageSize":50}' | chk "再次保存 → version=2 (整体替换)" 'assert d["version"]==2'
api "$A/api/prefs" | chk "整体替换: 旧键没有了" 'assert d["prefs"]=={"table.sites.pageSize":50}'
expect "prefs.json 权限 600" test "$(stat -f %Lp "$W/h/prefs.json")" = 600

echo "-- 套餐 / 权益 (会员预留; 云端是唯一真相, 本机只缓存)"
rm -f "$W/h/plan.json" "$W/h/plan.checked"
api "$A/api/plan" | chk "免费版 + 权益清单 (官方线路是「即将推出」, 未启用)" 'assert d["plan"]["code"]=="free" and d["plan"]["title"]=="免费版" and d["features"]["official_proxy"]["coming_soon"] and not d["features"]["official_proxy"]["enabled"] and d["features"]["sync"]["enabled"] and d["limits"]["devices_per_platform"]==2 and d["checked"]>0 and d["official"]["available"] is False and d["expires_at"] is None'
api -H 'X-Enana-Lang: en' "$A/api/plan" | chk "英文请求: 套餐名是 Free" 'assert d["plan"]["title"]=="Free"'
curl -s -X POST "http://127.0.0.1:$A_PORT/_test/plan?code=pro" >/dev/null; rm -f "$W/h/plan.checked"
api "$A/api/plan" | chk "云端套餐变了 (升级): 重新取到专业版, 官方线路已启用, 有到期时间" 'assert d["plan"]["code"]=="pro" and d["plan"]["title"]=="专业版" and d["features"]["official_proxy"]["enabled"] and d["expires_at"]==1790000000 and d["official"]["available"]'
curl -s -X POST "http://127.0.0.1:$A_PORT/_test/mode?m=down" >/dev/null; echo 1 > "$W/h/plan.checked"
api "$A/api/plan" | chk "云端连不上 + 缓存过期: 先用缓存的 (不报错)" 'assert d["ok"] and d["plan"]["code"]=="pro"'
curl -s -X POST "http://127.0.0.1:$A_PORT/_test/mode?m=ok" >/dev/null; curl -s -X POST "http://127.0.0.1:$A_PORT/_test/plan?code=free" >/dev/null; rm -f "$W/h/plan.json" "$W/h/plan.checked"

echo "== 7c. 配置快照 (备份 / 同步的数据格式) · 云端同步 (端到端加密)"
SP_=/usr/bin/perl; SNAPPL="$REPO/lib/snapshot.pl"; SYNCPL="$REPO/lib/sync.pl"
SD="$W/snaps"; mkdir -p "$SD/a/certs" "$SD/b" "$SD/c"
printf '%s\n' '{"role":"auto","outbound":{"type":"trojan","tag":"Snap-A","server":"127.0.0.1","server_port":1,"password":"pa"}}' '{"role":"pin","outbound":{"type":"trojan","tag":"Snap-B","server":"127.0.0.1","server_port":2,"password":"pb"}}' > "$SD/a/servers.jsonl"
printf 'sub1|https://sub.example.com/a|1|2|12|0|0|0\n' > "$SD/a/subs.tsv"; printf 'hosts-snap.example|127.0.0.1\n' > "$SD/a/hosts.tsv"; printf 'Snap-A\nSnap-B\n' > "$SD/a/servers.sync"; printf 'sub1\n' > "$SD/a/subs.sync"
printf 'LANG_UI=zh\nPORT=9999\nLOG_DAYS=45\nPROXY_ENABLED=1\nACCOUNT_URL=https://evil.example\n' > "$SD/a/settings.env"; cp "$W/c.pem" "$SD/a/certs/snap.crt"
$SP_ "$SNAPPL" build "$SD/a" 2.1.0 "Mac A" > "$SD/a.json"
cat "$SD/a.json" | chk "快照: 格式 1, 含白名单里的文件 / 证书 / 设置; 不含端口 / 代理总开关 / 账号地址" 'f=d["files"]; assert d["format"]==1 and d["device"]=="Mac A" and set(f)=={"servers.jsonl","subs.tsv","hosts.tsv"} and d["settings"]=={"LANG_UI":"zh","LOG_DAYS":"45"} and "snap.crt" in d["certs"]'
$SP_ "$SNAPPL" build "$SD/a" 2.1.0 "办公室的 Mac" | $SP_ "$SNAPPL" info /dev/stdin | chk "设备名里有中文: 摘要里原样返回 (没有被二次编码成乱码)" 'assert d["device"]=="办公室的 Mac"'
$SP_ "$SNAPPL" info "$SD/a.json" | chk "快照摘要: 2 个服务器 / 1 个订阅 / 1 条解析 / 1 个证书" 'assert d["servers"]==2 and d["subs"]==1 and d["hosts"]==1 and d["certs"]==1 and d["device"]=="Mac A" and d["version"]=="2.1.0"'
[ "$($SP_ "$SNAPPL" hash "$SD/a")" = "$($SP_ "$SNAPPL" hashfile "$SD/a.json")" ] && tpass "hash (目录) 与 hashfile (快照文件) 算法一致" || tfail "hash (目录) 与 hashfile (快照文件) 算法一致"
$SP_ "$SNAPPL" apply "$SD/b" "$SD/a.json" replace | chk "应用 (replace) 到空目录: 写入全部文件 + 设置" 'assert set(d["changed"])=={"servers.jsonl","subs.tsv","hosts.tsv","settings.env"} and d["servers"]==2'
expect "replace 之后服务器文件一致, 设置只写入白名单里的键, 文件权限 600" sh -c "cmp -s '$SD/a/servers.jsonl' '$SD/b/servers.jsonl' && grep -qx 'LOG_DAYS=45' '$SD/b/settings.env' && ! grep -q -e PORT -e PROXY -e evil '$SD/b/settings.env' && test \"\$(stat -f %Lp '$SD/b/servers.jsonl')\" = 600"
[ "$($SP_ "$SNAPPL" hash "$SD/b")" = "$($SP_ "$SNAPPL" hash "$SD/a")" ] && tpass "应用之后两边内容哈希相同" || tfail "应用之后两边内容哈希相同"
mkdir -p "$SD/m"; printf '%s\n' '{"role":"auto","outbound":{"type":"trojan","tag":"Snap-A","server":"10.9.9.9","server_port":9,"password":"LOCAL-PW"}}' '{"role":"auto","outbound":{"type":"trojan","tag":"Local-X","server":"127.0.0.1","server_port":3,"password":"px"}}' > "$SD/m/servers.jsonl"; printf 'sub1|https://local.example/keep|1|2|12|0|0|0\nsub9|https://local.example/nine|1|2|12|0|0|0\n' > "$SD/m/subs.tsv"
$SP_ "$SNAPPL" apply "$SD/m" "$SD/a.json" merge >/dev/null
expect "merge: 同名节点保留本机的 (密码没被覆盖), 本机独有的保留, 云端独有的加进来" sh -c "grep -q LOCAL-PW '$SD/m/servers.jsonl' && grep -q Local-X '$SD/m/servers.jsonl' && grep -q Snap-B '$SD/m/servers.jsonl' && [ \$(grep -c . '$SD/m/servers.jsonl') = 3 ]"
expect "merge: 订阅按名称合并 (本机的 sub1 保留, sub9 保留)" sh -c "grep -q 'local.example/keep' '$SD/m/subs.tsv' && grep -q sub9 '$SD/m/subs.tsv' && [ \$(grep -c . '$SD/m/subs.tsv') = 2 ]"
python3 - "$SD" <<'PY2'
import json, sys
sd = sys.argv[1]
d = {"format": 1, "app": "enana", "version": "9", "created": 1, "device": "Evil",
     "files": {"servers.jsonl": 'garbage\nnot json\n{"role":"auto","outbound":{"type":"trojan","tag":"direct","server":"x","server_port":1}}\n{"role":"nope","outbound":{"type":"trojan","tag":"BadRole","server":"x","server_port":1}}\n',
               "../evil.txt": "x", "secret": "x", "hosts.tsv": "evil.example|127.0.0.1\n", "prefs.json": {"not": "a string"}},
     "certs": {"../x.crt": "x", "ok.crt": "-----BEGIN CERTIFICATE-----\n", "a b.crt": "x"},
     "settings": {"PORT": "1", "LOG_DAYS": "9999", "LANG_UI": "zh", "ACCOUNT_URL": "https://evil.example"}}
json.dump(d, open(sd + "/hostile.json", "w"))
PY2
$SP_ "$SNAPPL" apply "$SD/c" "$SD/hostile.json" replace | chk "恶意快照 (但格式合法): 只写白名单文件, 坏节点行 / 保留名 / 非法角色被丢弃" 'assert set(d["changed"])=={"hosts.tsv","settings.env"} and d["servers"]==0'
expect "恶意快照: 没有写出目录之外的文件, 没有 secret, 证书只留下合法文件名, 设置只留合法值" sh -c "! ls '$SD/evil.txt' '$SD/c/secret' '$SD/x.crt' '$SD/c/certs/a b.crt' 2>/dev/null | grep -q . && test -f '$SD/c/certs/ok.crt' && test ! -e '$SD/c/servers.jsonl' && [ \"\$(cat '$SD/c/settings.env')\" = 'LANG_UI=zh' ]"
echo 'not json' > "$SD/bad.json"; $SP_ "$SNAPPL" info "$SD/bad.json" >/dev/null 2>&1; [ $? = 2 ] && tpass "不是快照 → 退出码 2" || tfail "不是快照 → 退出码 2"
echo '{"format":2,"files":{}}' > "$SD/bad2.json"; $SP_ "$SNAPPL" apply "$SD/c" "$SD/bad2.json" replace >/dev/null 2>&1; [ $? = 2 ] && tpass "未知的快照格式版本 → 被拒" || tfail "未知的快照格式版本 → 被拒"

echo "-- 同步密钥 / 加密载荷"
printf 'pw-for-kdf' | $SP_ "$SYNCPL" kdf acct123 1000 > "$SD/k1"; printf 'pw-for-kdf' | $SP_ "$SYNCPL" kdf acct123 1000 > "$SD/k1b"; printf 'pw-for-kdf' | $SP_ "$SYNCPL" kdf acct999 1000 > "$SD/k2"; printf 'other' | $SP_ "$SYNCPL" kdf acct123 1000 > "$SD/k3"
cmp -s "$SD/k1" "$SD/k1b" && ! cmp -s "$SD/k1" "$SD/k2" && ! cmp -s "$SD/k1" "$SD/k3" && [ "$(wc -l < "$SD/k1" | tr -d ' ')" = 2 ] && grep -Eq '^[0-9a-f]{64}$' "$SD/k1" && tpass "密钥派生: 同密码同账号 → 同密钥 (多台电脑一致); 换账号 / 换密码 → 不同" || tfail "密钥派生: 同密码同账号 → 同密钥; 换账号 / 换密码 → 不同"
$SP_ "$SYNCPL" seal "$SD/k1" "$SD/a.json" "$SD/a.b64" && $SP_ "$SYNCPL" seal "$SD/k1" "$SD/a.json" "$SD/a2.b64"
! cmp -s "$SD/a.b64" "$SD/a2.b64" && tpass "同一份内容每次加密的结果不同 (随机盐)" || tfail "同一份内容每次加密的结果不同 (随机盐)"
python3 -c "
import base64,sys
raw=base64.b64decode(open('$SD/a.b64').read()); sys.exit(0 if raw.startswith(b'ENSYNC1') and b'Snap-A' not in raw and b'trojan' not in raw and b'servers.jsonl' not in raw else 1)" && tpass "载荷以 ENSYNC1 开头, 里面没有任何明文" || tfail "载荷以 ENSYNC1 开头, 里面没有任何明文"
$SP_ "$SYNCPL" open "$SD/k1" "$SD/a.b64" "$SD/a.dec" && cmp -s "$SD/a.dec" "$SD/a.json" && tpass "用同一把密钥解密: 与原文一致" || tfail "用同一把密钥解密: 与原文一致"
$SP_ "$SYNCPL" open "$SD/k3" "$SD/a.b64" "$SD/x.dec" 2>/dev/null; [ $? = 3 ] && [ ! -e "$SD/x.dec" ] && tpass "密钥不对 → 退出码 3, 不输出任何内容" || tfail "密钥不对 → 退出码 3, 不输出任何内容"
python3 -c "
import base64
raw=bytearray(base64.b64decode(open('$SD/a.b64').read())); raw[40]^=1
open('$SD/tamper.b64','w').write(base64.b64encode(bytes(raw)).decode())"
$SP_ "$SYNCPL" open "$SD/k1" "$SD/tamper.b64" "$SD/x.dec" 2>/dev/null; [ $? = 3 ] && tpass "被改动过一个字节 → MAC 校验失败 (退出码 3)" || tfail "被改动过一个字节 → MAC 校验失败 (退出码 3)"
echo "AAAA" > "$SD/junk.b64"; $SP_ "$SYNCPL" open "$SD/k1" "$SD/junk.b64" "$SD/x.dec" 2>/dev/null; [ $? = 2 ] && tpass "不是载荷格式 → 退出码 2" || tfail "不是载荷格式 → 退出码 2"

echo "-- 同步接口 (本机模拟的 enana.cc 只存密文)"
sy() { api -X POST "$A/api/sync/$1" "${@:2}"; }
put_remote() { # <base64 文件> <base_version>   模拟「另一台电脑」上传
  python3 - "$1" "$2" "$(cat "$W/h/cloud.token")" "$(cat "$W/h/session")" "$A_PORT" <<'PY2'
import json, sys, urllib.request
f, base, tok, sid, port = sys.argv[1:6]
p = open(f).read().strip()
req = urllib.request.Request('http://127.0.0.1:%s/api/enana/v1/sync/snapshot' % port, data=json.dumps({'base_version': int(base), 'payload': p, 'size': len(p)}).encode(), method='PUT',
                             headers={'Authorization': 'Bearer ' + tok, 'X-Enana-Session': sid, 'Content-Type': 'application/json'})
try:
    print(urllib.request.urlopen(req).read().decode())
except urllib.error.HTTPError as e:
    print(e.read().decode())
PY2
  rm -f "$W/h/sync.remote"          # 云端信息缓存 20 秒; 外部改了云端之后让它失效 (相当于等了一会儿)
}
remote_v() { rm -f "$W/h/sync.remote"; api "$A/api/sync" | jp 'print(d["remote"]["version"])'; }
api "$A/api/sync" | chk "初始: 没开启; 云端没有数据; 本机有同步密钥 (登录时由密码派生); 本机有数据所以「有未上传的改动」" 'assert d["ok"] and not d["enabled"] and not d["auto"] and d["has_key"] and d["remote"]=={"exists":False} and d["local"]["version"]==0 and d["local"]["dirty"] and d["online"] and not d["conflict"] and d["account"]=="user1@example.test"'
expect "同步密钥文件权限 600" test "$(stat -f %Lp "$W/h/sync.key")" = 600
sy push | chk "没开启时上传 → 被拒" 'assert not d["ok"] and d["code"]=="E_INVALID"'
sy pull | chk "没开启时拉取 → 被拒" 'assert not d["ok"] and d["code"]=="E_INVALID"'
sy settings -d 'enabled=2' | chk "参数无效 → 被拒" 'assert not d["ok"]'
sy settings | chk "什么都没给 → 被拒" 'assert not d["ok"]'
sy settings -d 'enabled=1&auto=0' | chk "开启同步 (已有密钥, 不用再输入密码)" 'assert d["ok"]'
sy pull | chk "云端还没有数据时拉取 → E_NOT_FOUND" 'assert d["code"]=="E_NOT_FOUND"'
sy preview | chk "云端还没有数据时预览 → E_NOT_FOUND" 'assert d["code"]=="E_NOT_FOUND"'
J=$(sy push | jp 'print(d["job"])'); [ "$(job_wait "$J")" = done ] && tpass "第一次上传 (加密 → 上传) 完成" || tfail "第一次上传 (加密 → 上传) 完成"
api "$A/api/sync" | chk "上传后: 云端 v1 (来源是本机), 本机基于 v1, 没有未上传的改动" 'assert d["remote"]["exists"] and d["remote"]["version"]==1 and d["remote"]["size"]>100 and d["local"]["version"]==1 and not d["local"]["dirty"] and d["last_push"]>0'
curl -s -X POST "http://127.0.0.1:$A_PORT/_test/snap" | chk "云端存的是密文: 里面没有服务器名 / 订阅链接 / 密码 / 协议名" 'import base64; p=list(d["snaps"].values())[0]["payload"]; raw=base64.b64decode(p); assert raw.startswith(b"ENSYNC1") and not any(w in raw or w.decode() in p for w in (b"Good-Node", b"SECRETTOKEN", b"sub.example.com", b"trojan", b"hysteria"))'
J=$(api -X POST "$A/api/dns/hosts" -d 'action=add&domain=sync-test.example&ip=127.0.0.9' | jp 'print(d["job"])'); job_wait "$J" >/dev/null
api "$A/api/sync" | chk "本机改了配置 → 有未上传的改动" 'assert d["local"]["dirty"]'
J=$(sy push | jp 'print(d["job"])'); [ "$(job_wait "$J")" = done ] && tpass "再次上传完成" || tfail "再次上传完成"
api "$A/api/sync" | chk "再次上传后: 云端 v2, 没有未上传的改动" 'assert d["remote"]["version"]==2 and d["local"]["version"]==2 and not d["local"]["dirty"]'
$SP_ "$SYNCPL" seal "$W/h/sync.key" "$SD/a.json" "$SD/cloud-a.b64"
put_remote "$SD/cloud-a.b64" 2 | chk "(模拟另一台电脑上传 A 配置) 云端 → v3" 'assert d["version"]==3'
sy push | chk "云端比本机新 → 立刻 E_SYNC_CONFLICT (带云端版本 / 设备), 不进任务" 'assert d["code"]=="E_SYNC_CONFLICT" and d["remote"]["version"]==3 and d["remote"]["device"]'
api "$A/api/sync" | chk "状态里能看到云端 v3 > 本机 v2" 'assert d["remote"]["version"]==3 and d["local"]["version"]==2'
J=$(sy push -d 'force=1' | jp 'print(d["job"])'); [ "$(job_wait "$J")" = done ] && tpass "「用本机覆盖云端」(force) 完成" || tfail "「用本机覆盖云端」(force) 完成"
api "$A/api/sync" | chk "force 之后: 云端 v4 = 本机 v4" 'assert d["remote"]["version"]==4 and d["local"]["version"]==4 and not d["local"]["dirty"]'
echo "-- 拉取: 先备份完整状态, 最后再恢复"
J=$(api -X POST "$A/api/dns/hosts" -d 'action=remove&domain=sync-test.example' | jp 'print(d["job"])'); job_wait "$J" >/dev/null     # 备份里不要带本节临时加的解析记录
api "$A/api/export" -o "$SD/backup.json"
$SP_ "$SYNCPL" seal "$W/h/sync.key" "$SD/a.json" "$SD/cloud-a.b64"; put_remote "$SD/cloud-a.b64" 4 | chk "(另一台电脑) 云端 → v5" 'assert d["version"]==5'
MD5_BEFORE=$(md5 -q "$W/h/servers.jsonl")
sy preview | chk "预览: 只返回摘要 (2 个服务器 / 1 个订阅 / 设备名), 不改动本机" 'assert d["ok"] and d["summary"]["servers"]==2 and d["summary"]["subs"]==1 and d["summary"]["device"]=="Mac A" and d["remote"]["version"]==5'
[ "$MD5_BEFORE" = "$(md5 -q "$W/h/servers.jsonl")" ] && [ ! -e "$W/h/sync-incoming.json" ] && tpass "预览没有改动本机, 也没有留下解密后的临时文件" || tfail "预览没有改动本机, 也没有留下解密后的临时文件"
sy pull -d 'mode=sideways' | chk "拉取模式无效 → 被拒" 'assert not d["ok"]'
J=$(sy pull -d 'mode=merge' | jp 'print(d["job"])'); [ "$(job_wait "$J")" = done ] && tpass "拉取 (合并) 完成" || tfail "拉取 (合并) 完成"
api "$A/api/state" | chk "合并: 云端的 Snap-A / Snap-B 加进来了, 本机原有的服务器都还在" 'ts={s["tag"] for s in d["servers"]}; assert {"Snap-A","Snap-B","Local-Hop","Fix-Pin","Good-Node"} <= ts'
expect "合并: 非服务器类的配置以云端为准 (解析记录变成云端的)" sh -c "grep -q hosts-snap.example '$W/h/hosts.tsv' && ! grep -q sync-test.example '$W/h/hosts.tsv'"
expect "合并之后: 云端的设置 (保留天数 45) 已应用, 没有写出端口 / 账号地址之类" sh -c "grep -qx 'LOG_DAYS=45' '$W/h/settings.env' && ! grep -q 'evil' '$W/h/settings.env' && grep -q '^PORT=$PORT' '$W/h/settings.env'"
expect "核心仍在运行 (拉取的配置通过校验并已应用)" nc -z 127.0.0.1 "$PORT"
api "$A/api/sync" | chk "合并之后: 本机基于 v5; 本机有云端没有的东西, 所以「有未上传的改动」" 'assert d["local"]["version"]==5 and d["local"]["dirty"]'
expect "拉取后没有留下解密后的临时文件" test ! -e "$W/h/sync-incoming.json" -a ! -e "$W/h/sync-incoming.b64"
J=$(sy pull -d 'mode=replace' | jp 'print(d["job"])'); [ "$(job_wait "$J")" = done ] && tpass "拉取 (替换) 完成" || tfail "拉取 (替换) 完成"
api "$A/api/state" | chk "替换: 本机服务器 = 云端的 2 个" 'assert sorted(s["tag"] for s in d["servers"])==["Snap-A","Snap-B"]'
api "$A/api/sync" | chk "替换之后: 没有未上传的改动" 'assert d["local"]["version"]==5 and not d["local"]["dirty"]'
echo "-- 密钥对不上 (密码在别处改过) / 被篡改 / 内容损坏"
printf 'Other-Pass9' | $SP_ "$SYNCPL" kdf "$(sed -n 's/^id=//p' "$W/h/account.conf")" 200000 > "$SD/oldkey"
$SP_ "$SYNCPL" seal "$SD/oldkey" "$SD/a.json" "$SD/cloud-old.b64"; put_remote "$SD/cloud-old.b64" 5 | chk "(云端的快照是用另一把密钥加密的) → v6" 'assert d["version"]==6'
sy pull | chk "密钥对不上 → 立刻 E_SYNC_KEY (让前端要旧密码)" 'assert d["code"]=="E_SYNC_KEY" and "旧密码" in d["error"]'
sy pull -d 'old_password=Wrong-Old-1' | chk "旧密码也不对 → E_SYNC_KEY" 'assert d["code"]=="E_SYNC_KEY"'
expect "失败的拉取没有留下临时文件 / 旧密钥文件" test ! -e "$W/h/sync-incoming.json" -a ! -e "$W/h/sync.key.old" -a ! -e "$W/h/sync-incoming.b64"
J=$(sy pull --data-urlencode 'old_password=Other-Pass9' -d 'mode=merge' | jp 'print(d["job"])'); [ "$(job_wait "$J")" = done ] && tpass "输入旧密码 → 解开并应用" || tfail "输入旧密码 → 解开并应用"
sleep 1; api "$A/api/sync" | chk "用旧密码解开之后, 已用现在的密钥重新加密上传 (云端版本增加, 本机同步)" 'assert d["remote"]["version"]>=7 and d["local"]["version"]==d["remote"]["version"]'
J=$(sy pull -d 'mode=merge' | jp 'print(d["job"])'); [ "$(job_wait "$J")" = done ] && tpass "之后不再需要旧密码" || tfail "之后不再需要旧密码"
V=$(remote_v)
python3 -c "
import base64
raw=bytearray(base64.b64decode(open('$SD/cloud-a.b64').read())); raw[60]^=1
open('$SD/cloud-tamper.b64','w').write(base64.b64encode(bytes(raw)).decode())"
put_remote "$SD/cloud-tamper.b64" "$V" >/dev/null; sy pull | chk "云端内容被改动过 → 校验失败 (E_SYNC_KEY), 不会应用" 'assert d["code"]=="E_SYNC_KEY"'
V=$(remote_v); echo 'QUJD' > "$SD/cloud-junk.b64"; put_remote "$SD/cloud-junk.b64" "$V" >/dev/null
sy pull | chk "云端内容不是载荷格式 → E_INVALID (云端的配置无法读取)" 'assert d["code"]=="E_INVALID"'
echo "-- 恶意快照 (密钥正确、格式合法, 但内容有问题): 只应用白名单里的合法内容"
python3 - "$SD" <<'PY2'
import json, sys
d = json.load(open(sys.argv[1] + "/hostile.json")); d["files"].pop("prefs.json", None); d["settings"] = {"LOG_DAYS": "45", "PORT": "1"}
json.dump(d, open(sys.argv[1] + "/hostile2.json", "w"))
PY2
$SP_ "$SYNCPL" seal "$W/h/sync.key" "$SD/hostile2.json" "$SD/cloud-hostile.b64"; V=$(remote_v); put_remote "$SD/cloud-hostile.b64" "$V" >/dev/null
MD5_S=$(md5 -q "$W/h/servers.jsonl")
J=$(sy pull -d 'mode=merge' | jp 'print(d["job"])'); [ "$(job_wait "$J")" = done ] && tpass "拉取恶意快照 (合并) 没有崩" || tfail "拉取恶意快照 (合并) 没有崩"
expect "恶意快照: 服务器没被破坏 (坏行 / 保留名 / 非法角色都被丢弃), 没有写出 secret 或目录之外的文件, 端口没变" sh -c "[ '$MD5_S' = \"\$(md5 -q '$W/h/servers.jsonl')\" ] && ! ls '$W/h/secret.new' '$W/evil.txt' '$W/h/../evil.txt' 2>/dev/null | grep -q evil && grep -q '^PORT=$PORT' '$W/h/settings.env' && test -f '$W/h/certs/ok.crt' && ! test -e '$W/h/certs/a b.crt'"
rm -f "$W/h/certs/ok.crt"
echo "-- 自动同步 (打开后: 本机有改动 → 自动上传; 云端有新版本且本机没改动 → 自动拉取; 两边都变了 → 标记冲突)"
J=$(sy push -d 'force=1' | jp 'print(d["job"])'); job_wait "$J" >/dev/null
sy settings -d 'auto=1' | chk "打开自动同步" 'assert d["ok"]'
J=$(api -X POST "$A/api/dns/hosts" -d 'action=add&domain=auto-up.example&ip=127.0.0.6' | jp 'print(d["job"])'); job_wait "$J" >/dev/null
sed -i '' '/^CHECKED=/d' "$W/h/sync.conf"; "$W/shortcut/enana" tick --quiet >/dev/null 2>&1; sleep 1
api "$A/api/sync" | chk "tick 之后: 本机的改动已经自动上传 (云端版本 = 本机版本, 没有未上传的改动)" 'assert not d["local"]["dirty"] and d["remote"]["version"]==d["local"]["version"]'
python3 - "$SD" <<'PY2'
import json, sys
sd = sys.argv[1]
d = json.load(open(sd + "/backup.json"))
d["files"]["hosts.tsv"] = "auto-down.example|127.0.0.5\n"
json.dump(d, open(sd + "/auto-down.json", "w"))
PY2
$SP_ "$SYNCPL" seal "$W/h/sync.key" "$SD/auto-down.json" "$SD/cloud-auto.b64"; V=$(remote_v); put_remote "$SD/cloud-auto.b64" "$V" >/dev/null
sed -i '' '/^CHECKED=/d' "$W/h/sync.conf"; "$W/shortcut/enana" tick --quiet >/dev/null 2>&1; sleep 2
expect "tick 之后: 云端的新版本已经自动拉取 (解析记录变成云端的)" sh -c "grep -q auto-down.example '$W/h/hosts.tsv' && ! grep -q auto-up.example '$W/h/hosts.tsv'"
J=$(api -X POST "$A/api/dns/hosts" -d 'action=add&domain=local-only.example&ip=127.0.0.4' | jp 'print(d["job"])'); job_wait "$J" >/dev/null
$SP_ "$SYNCPL" seal "$W/h/sync.key" "$SD/a.json" "$SD/cloud-c.b64"; V=$(remote_v); put_remote "$SD/cloud-c.b64" "$V" >/dev/null
sed -i '' '/^CHECKED=/d' "$W/h/sync.conf"; "$W/shortcut/enana" tick --quiet >/dev/null 2>&1; sleep 1
api "$A/api/sync" | chk "两边都变了: 不自动覆盖, 标记冲突 (conflict=true)" 'assert d["conflict"] and d["local"]["dirty"]'
expect "冲突时本机的改动没有丢" grep -q local-only.example "$W/h/hosts.tsv"
J=$(sy push -d 'force=1' | jp 'print(d["job"])'); [ "$(job_wait "$J")" = done ] && tpass "用本机覆盖云端: 冲突解除" || tfail "用本机覆盖云端: 冲突解除"
api "$A/api/sync" | chk "冲突标记已清除" 'assert not d["conflict"] and not d["local"]["dirty"]'
echo "-- 清除云端数据 (需要再次验证密码) / 恢复测试前的状态"
CODE=$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' -X POST -H "$X" -H "X-Enana-Token: $TOKEN" "$A/api/sync/clear"); [ "$CODE" = 403 ] && tpass "清除云端数据需要 sudo 令牌 (403)" || tfail "清除云端数据需要 sudo 令牌 (得到 $CODE)"
api -X POST "$A/api/sync/clear" | chk "清除云端数据" 'assert d["ok"]'
api "$A/api/sync" | chk "清除后: 云端没有数据, 本机版本归零" 'assert d["remote"]=={"exists":False} and d["local"]["version"]==0'
$SP_ "$SYNCPL" seal "$W/h/sync.key" "$SD/backup.json" "$SD/cloud-bk.b64"; put_remote "$SD/cloud-bk.b64" 0 | chk "(把测试前的完整备份放回云端)" 'assert d["version"]==1'
J=$(sy pull -d 'mode=replace' | jp 'print(d["job"])'); [ "$(job_wait "$J")" = done ] && tpass "从备份恢复 (替换) 完成" || tfail "从备份恢复 (替换) 完成"
J=$(api -X POST "$A/api/dns/hosts/reset" | jp 'print(d["job"])'); job_wait "$J" >/dev/null
api "$A/api/state" | chk "恢复之后: 原来的服务器都回来了" 'ts={s["tag"] for s in d["servers"]}; assert {"Local-Hop","Fix-Pin","Good-Node"} <= ts and "Snap-A" not in ts'
sy settings -d 'enabled=0' | chk "关闭同步 (自动同步一起关)" 'assert d["ok"]'
api "$A/api/sync" | chk "已关闭" 'assert not d["enabled"] and not d["auto"]'
api -X POST "$A/api/settings" -d 'log_hours=720' >/dev/null
sy push | chk "关闭后不能上传" 'assert not d["ok"]'

echo "-- 添加服务器的「保存到云端」: 只有勾选的进入云端同步 · 导出备份带全部 · 登录后自动取回 · 明确关闭过的不动"
SO="$SD/o"; mkdir -p "$SO"
printf '%s\n' '{"role":"auto","outbound":{"type":"trojan","tag":"O-Synced","server":"127.0.0.1","server_port":1,"password":"p"}}' '{"role":"auto","outbound":{"type":"trojan","tag":"O-Local","server":"127.0.0.1","server_port":2,"password":"p"}}' '{"role":"auto","sub":"os","outbound":{"type":"trojan","tag":"O-FromSub","server":"127.0.0.1","server_port":3,"password":"p"}}' > "$SO/servers.jsonl"
printf 'os|https://sub.example.com/o|1|1|12|0|0|0\nol|https://sub.example.com/l|1|0|12|0|0|0\n' > "$SO/subs.tsv"
printf 'O-Synced\n' > "$SO/servers.sync"; printf 'os\n' > "$SO/subs.sync"
$SP_ "$SNAPPL" build "$SO" 2.1.0 X | chk "快照只带「保存到云端」的服务器 (O-Synced, 以及已保存订阅 os 的 O-FromSub) 和订阅 os; 只在本机的 O-Local / ol 不在里面" 'f=d["files"]; s=f["servers.jsonl"]; assert "O-Synced" in s and "O-FromSub" in s and "O-Local" not in s and f["subs.tsv"].startswith("os|") and "ol|" not in f["subs.tsv"]'
$SP_ "$SNAPPL" build "$SO" 2.1.0 X all | chk "导出备份 (build … all) 带全部服务器和订阅" 'f=d["files"]; assert "O-Local" in f["servers.jsonl"] and "ol|" in f["subs.tsv"] and "O-Synced" in f["servers.jsonl"]'
H1=$($SP_ "$SNAPPL" hash "$SO"); printf '%s\n' '{"role":"auto","outbound":{"type":"trojan","tag":"O-Local2","server":"127.0.0.1","server_port":4,"password":"p"}}' >> "$SO/servers.jsonl"
[ "$H1" = "$($SP_ "$SNAPPL" hash "$SO")" ] && tpass "只在本机的服务器变化不影响「有没有未上传的改动」(哈希不变)" || tfail "只在本机的服务器变化不影响「有没有未上传的改动」(哈希不变)"
$SP_ "$SNAPPL" apply "$SO" "$SD/a.json" replace >/dev/null
expect "替换 (replace): 云端的 Snap-A / Snap-B / sub1 进来, 之前同步过但云端没有的 O-Synced / O-FromSub / os 被替换掉, 只在本机的 O-Local / O-Local2 / ol 保留" sh -c "grep -q Snap-A '$SO/servers.jsonl' && grep -q Snap-B '$SO/servers.jsonl' && ! grep -q O-Synced '$SO/servers.jsonl' && ! grep -q O-FromSub '$SO/servers.jsonl' && grep -q O-Local '$SO/servers.jsonl' && grep -q O-Local2 '$SO/servers.jsonl' && grep -q '^sub1|' '$SO/subs.tsv' && grep -q '^ol|' '$SO/subs.tsv' && ! grep -q '^os|' '$SO/subs.tsv'"
expect "取回来的 Snap-A / Snap-B / sub1 记入本机的同步清单 (之后继续同步)" sh -c "grep -qx Snap-A '$SO/servers.sync' && grep -qx Snap-B '$SO/servers.sync' && grep -qx sub1 '$SO/subs.sync'"
SG="$SD/m2"; mkdir -p "$SG"; printf '%s\n' '{"role":"auto","outbound":{"type":"trojan","tag":"G-Local","server":"127.0.0.1","server_port":5,"password":"p"}}' > "$SG/servers.jsonl"
$SP_ "$SNAPPL" apply "$SG" "$SD/a.json" merge >/dev/null
expect "合并 (merge): 本机原有的 G-Local 保留 (仍然只在本机), 云端的 Snap-A / Snap-B 加进来并记入同步清单" sh -c "grep -q G-Local '$SG/servers.jsonl' && grep -q Snap-A '$SG/servers.jsonl' && ! grep -qx G-Local '$SG/servers.sync' && grep -qx Snap-A '$SG/servers.sync'"

echo "-- 接口: save=1 / save=0 · 第一次勾选自动打开同步 · 老服务器不会被连带上传 · 登录后自动取回"
sy settings -d 'enabled=0' >/dev/null; rm -f "$W/h/servers.sync" "$W/h/subs.sync" "$W/h/.sync-pending"; sed -i '' -e '/^ENABLED=/d' -e '/^AUTO=/d' "$W/h/sync.conf"
api "$A/api/sync" | chk "还没做过选择: decided=false, enabled=false" 'assert d["decided"] is False and d["enabled"] is False'
LY='{"role":"auto","outbound":{"type":"socks","tag":"Save-Yes","server":"127.0.0.1","server_port":'$HOP_PORT',"version":"5"}}'
LN='{"role":"auto","outbound":{"type":"socks","tag":"Save-No","server":"127.0.0.1","server_port":'$HOP_PORT',"version":"5"}}'
api -X POST "$A/api/servers/import?mode=merge&save=2" --data-binary "$LY" | chk "save 参数只接受 0 / 1" 'assert not d["ok"]'
J=$(api -X POST "$A/api/servers/import?mode=merge&save=1" --data-binary "$LY" | jp 'print(d["job"])'); [ "$(job_wait "$J")" = done ] && tpass "导入 (save=1) 完成" || tfail "导入 (save=1) 完成"
expect "save=1: 节点进入同步清单; 第一次勾选自动打开云端同步 (enabled + auto) 并标记「马上上传」" sh -c "grep -qx 'Save-Yes' '$W/h/servers.sync' && grep -qx 'ENABLED=1' '$W/h/sync.conf' && grep -qx 'AUTO=1' '$W/h/sync.conf' && test -e '$W/h/.sync-pending'"
expect "老服务器 (没有记录, 例如 Fix-Pin) 不会被连带同步: 只有这次勾选的进了清单" sh -c "! grep -qx 'Fix-Pin' '$W/h/servers.sync' && [ \$(grep -c . '$W/h/servers.sync') = 1 ]"
J=$(api -X POST "$A/api/servers/import?mode=merge&save=0" --data-binary "$LN" | jp 'print(d["job"])'); [ "$(job_wait "$J")" = done ] && tpass "导入 (save=0) 完成" || tfail "导入 (save=0) 完成"
expect "save=0: 服务器已添加但只留在本机 (不进同步清单)" sh -c "grep -q Save-No '$W/h/servers.jsonl' && ! grep -qx 'Save-No' '$W/h/servers.sync'"
api "$A/api/export" -o "$SD/export-all.json"
cat "$SD/export-all.json" | jp 'import json; f=d["files"]["servers.jsonl"]; assert "Save-No" in f and "Save-Yes" in f and "Fix-Pin" in f' && tpass "导出备份带全部服务器 (包括只在本机的)" || tfail "导出备份带全部服务器 (包括只在本机的)"
J=$(api -X POST "$A/api/servers/delete?tag=Save-Yes" | jp 'print(d.get("job",""))'); [ -z "$J" ] || job_wait "$J" >/dev/null
expect "删除服务器时从同步清单里去掉" sh -c "! grep -qx 'Save-Yes' '$W/h/servers.sync'"
J=$(api -X POST "$A/api/servers/delete?tag=Save-No" | jp 'print(d.get("job",""))'); [ -z "$J" ] || job_wait "$J" >/dev/null
# 登录后自动取回: 云端有「另一台电脑」保存的服务器 Cloud-New → 退出再登录, 它自动出现 (合并, 本机已有的都在)
python3 - "$SD" <<'PY2'
import json, sys
sd = sys.argv[1]
d = json.load(open(sd + "/export-all.json"))
d["files"]["servers.jsonl"] = d["files"]["servers.jsonl"].rstrip("\n") + '\n{"role":"auto","outbound":{"type":"socks","tag":"Cloud-New","server":"127.0.0.1","server_port":1,"version":"5"}}\n'
json.dump(d, open(sd + "/cloud-login.json", "w"))
PY2
$SP_ "$SYNCPL" seal "$W/h/sync.key" "$SD/cloud-login.json" "$SD/cloud-login.b64"; V=$(remote_v); put_remote "$SD/cloud-login.b64" "$V" >/dev/null
sed -i '' -e '/^ENABLED=/d' -e '/^AUTO=/d' -e '/^BASE_VERSION=/d' -e '/^SYNCED_HASH=/d' "$W/h/sync.conf"
ACC_=$(cut -d' ' -f1 "$W/h/loggedin"); PW_=$(sudo_pw)
api -X POST "$A/api/logout" >/dev/null; wait_clash_401 "$TOKEN"
R=$(login "$ACC_" "$PW_"); TOKEN=$(echo "$R" | jp 'print(d["token"])')
for i in $(seq 1 40); do api "$A/api/state" | jp 'import sys; sys.exit(0 if "Cloud-New" in {s["tag"] for s in d["servers"]} else 1)' >/dev/null 2>&1 && break; sleep 0.5; done
api "$A/api/state" | chk "登录后自动取回云端保存的服务器: Cloud-New 出现, 本机原有的服务器都在 (合并, 不覆盖)" 'ts={s["tag"] for s in d["servers"]}; assert "Cloud-New" in ts and {"Fix-Pin","Local-Hop"} <= ts'
expect "取回来的服务器记入同步清单, 同步自动打开 (之前没做过选择)" sh -c "grep -qx 'Cloud-New' '$W/h/servers.sync' && grep -qx 'ENABLED=1' '$W/h/sync.conf'"
expect "云端快照里带来的全部服务器 (包括 Fix-Pin) 都记入同步清单, 之后继续同步" sh -c "grep -qx 'Fix-Pin' '$W/h/servers.sync' && grep -qx 'Local-Hop' '$W/h/servers.sync'"
# 在设置里明确关闭过同步 → 登录后不自动取回
J=$(api -X POST "$A/api/servers/delete?tag=Cloud-New" | jp 'print(d.get("job",""))'); [ -z "$J" ] || job_wait "$J" >/dev/null
sy settings -d 'enabled=0' >/dev/null; sed -i '' -e '/^BASE_VERSION=/d' -e '/^SYNCED_HASH=/d' "$W/h/sync.conf"; V=$(remote_v)
api -X POST "$A/api/logout" >/dev/null; wait_clash_401 "$TOKEN"
R=$(login "$ACC_" "$PW_"); TOKEN=$(echo "$R" | jp 'print(d["token"])'); sleep 4
api "$A/api/state" | chk "明确关闭过同步 → 登录后不会自动取回 (Cloud-New 没有出现), ENABLED 仍是 0" 'assert "Cloud-New" not in {s["tag"] for s in d["servers"]}'
expect "ENABLED=0 没有被登录流程改回去" grep -qx 'ENABLED=0' "$W/h/sync.conf"
rm -f "$W/h/servers.sync" "$W/h/subs.sync" "$W/h/.sync-pending"
api -X POST "$A/api/proxy" -d 'on=1' >/dev/null           # 上面退出再登录会关掉代理 (这是设计): 后面的章节要在「代理已开启」的状态下继续

echo "== 7d. 添加自己的服务器 (SSH 一键部署): 探测 / 主机指纹 / 部署 / 重新识别出口 IP / 凭据不落盘"
if ! waitport "$SSHD_PORT"; then tfail "本机测试用的 sshd 没有起来 (跳过 SSH 部署测试)"; else
FP=$(ssh-keygen -lf "$W/sshd/hostkey.pub" -E sha256 | awk '{print $2}'); ME=$(id -un)
KEYLINE=$(sed -n '2p' "$W/sshd/client")
vp() { local ep=$1; shift; api -X POST "$A/api/vps/$ep" --data-urlencode "host=${VH:-127.0.0.1}" --data-urlencode "port=${VP:-$SSHD_PORT}" --data-urlencode "user=${VU:-$ME}" "$@"; }       # VH / VP / VU 可以临时覆盖
KEYARGS=(--data-urlencode "mode=key" --data-urlencode "key@$W/sshd/client")
vjob() { local j=$1; job_wait "$j" >/dev/null; api "$A/api/job?id=$j"; }          # 等任务结束, 返回它的 JSON
vres() { vp "$@" | jp 'print(d["job"])'; }                                          # 启动任务, 打印任务编号
printf 'hop=%s\nips=2\n' "$HOP_PORT" > "$W/vpsctl"
api "$A/api/vps" | chk "初始: 还没有自己的服务器记录" 'assert d["ok"] and d["vps"]==[]'
echo "-- 参数校验 (立刻返回原因, 不启动任务)"
api -X POST "$A/api/vps/probe" --data-urlencode "host=bad host" --data-urlencode mode=password --data-urlencode password=x | chk "服务器地址不合法 → E_INVALID" 'assert not d["ok"] and d["code"]=="E_INVALID" and "地址" in d["error"]'
VP=70000 vp probe --data-urlencode mode=password --data-urlencode password=x | chk "SSH 端口超范围 → 被拒" 'assert not d["ok"] and "端口" in d["error"]'
VU=-oProxyCommand=evil vp probe --data-urlencode mode=password --data-urlencode password=x | chk "用户名里有选项注入 (以 - 开头) → 被拒" 'assert not d["ok"] and "用户名" in d["error"]'
VH=-oProxyCommand=evil vp probe --data-urlencode mode=password --data-urlencode password=x | chk "地址以 - 开头 (选项注入) → 被拒" 'assert not d["ok"]'
vp probe --data-urlencode mode=key --data-urlencode "key=not a key" | chk "私钥格式不对 → 被拒" 'assert not d["ok"] and "私钥" in d["error"]'
vp probe --data-urlencode mode=sideways | chk "登录方式无效 → 被拒" 'assert not d["ok"]'
vp probe --data-urlencode mode=password | chk "没填密码 → 被拒" 'assert not d["ok"] and "密码" in d["error"]'
vp probe --data-urlencode mode=password --data-urlencode "password=line1
line2" | chk "密码里有换行 → 被拒 (不能破坏凭据文件)" 'assert not d["ok"]'
vp probe "${KEYARGS[@]}" --data-urlencode "hostkey=SHA256:tooshort" | chk "主机指纹格式不对 → 被拒" 'assert not d["ok"] and "指纹" in d["error"]'
vp provision "${KEYARGS[@]}" | chk "部署必须带主机指纹 (先探测并确认) → E_SSH_HOSTKEY" 'assert d["code"]=="E_SSH_HOSTKEY"'
vp provision "${KEYARGS[@]}" --data-urlencode "hostkey=$FP" --data-urlencode "role=bogus" | chk "角色无效 → 被拒" 'assert not d["ok"]'
vp provision "${KEYARGS[@]}" --data-urlencode "hostkey=$FP" --data-urlencode "name=bad name!" | chk "服务器名称不合法 → 被拒" 'assert not d["ok"]'
vp redetect "${KEYARGS[@]}" --data-urlencode "id=nope" | chk "服务器编号无效 → 被拒" 'assert not d["ok"]'
vp redetect "${KEYARGS[@]}" --data-urlencode "id=v-abcdef" | chk "找不到的服务器记录 → E_NOT_FOUND" 'assert d["code"]=="E_NOT_FOUND"'
CONT=$(readlink "$W/h/cloud/content"); mv "$W/h/cloud/$CONT/vps" "$W/h/cloud/$CONT/vps.off"
vp probe "${KEYARGS[@]}" | chk "云端还没有下发部署脚本 (没登录 / 没同步) → E_VPS_NO_PLAYBOOK" 'assert d["code"]=="E_VPS_NO_PLAYBOOK"'
mv "$W/h/cloud/$CONT/vps.off" "$W/h/cloud/$CONT/vps"
echo "-- 主机指纹: 先给用户确认, 之后固定校验"
J=$(vres probe "${KEYARGS[@]}" --data-urlencode "confirm_hostkey=1"); vjob "$J" | chk "先只取指纹 (confirm_hostkey=1): 还没有用私钥登录, 返回的指纹与服务器的一致" 'r=d["result"]; assert d["state"]=="done" and r["need_confirm"] and r["hostkey"]=="'"$FP"'" and "os" not in r'
J=$(vres probe "${KEYARGS[@]}" --data-urlencode "hostkey=$FP"); vjob "$J" > "$W/probe.json"
cat "$W/probe.json" | chk "探测 (固定了指纹): 系统 / 架构 / 权限 / 依赖 / 防火墙 / 监听端口 / 出口 IP / 将要执行的操作" 'r=d["result"]; assert d["state"]=="done" and r["hostkey"]=="'"$FP"'" and not r["hostkey_changed"] and r["os"]["id"]=="debian" and r["os"]["version"]=="12" and r["os"]["codename"]=="bookworm" and r["arch"]=="amd64" and r["supported"] and r["support"]=="full" and r["privilege"]=="root" and r["init"]=="systemd" and len(r["deps"])==5 and all(x["installed"] for x in r["deps"]) and r["missing"]==[] and not r["all_missing"] and r["firewall"]=="ufw_inactive" and r["listening"]==[22,80] and [i["public"] for i in r["ips"]]==["203.0.113.9","203.0.113.10"] and r["ipv6"]==["2001:db8::5"] and [a["id"] for a in r["actions"]]==["core","config","service"] and "SHA-256" in r["actions"][0]["text"]'
J=$(vp probe -H 'X-Enana-Lang: en' "${KEYARGS[@]}" --data-urlencode "hostkey=$FP" | jp 'print(d["job"])'); job_wait "$J" >/dev/null; curl -s --noproxy '*' -H "$X" -H "X-Enana-Token: $TOKEN" -H 'X-Enana-Lang: en' "$A/api/job?id=$J" | chk "英文请求: 说明文字是英文" 'r=d["result"]; assert "Download and install" in r["actions"][0]["text"] and "fully supported" in r["support_note"]'
vp probe "${KEYARGS[@]}" > "$W/tofu.json"; J=$(jp 'print(d["job"])' < "$W/tofu.json"); vjob "$J" | chk "没带指纹也能探测 (首次信任): 返回看到的指纹, 供之后固定" 'assert d["state"]=="done" and d["result"]["hostkey"]=="'"$FP"'"'
J=$(vres probe "${KEYARGS[@]}" --data-urlencode "hostkey=SHA256:$(printf 'A%.0s' $(seq 1 43))"); vjob "$J" | chk "指纹与服务器的不一致 → 任务失败 E_SSH_HOSTKEY, 没有发送私钥" 'assert d["state"]=="error" and d["result"]["code"]=="E_SSH_HOSTKEY"'
echo "-- 连接失败的各种原因都能分清"
J=$(vres probe --data-urlencode mode=key --data-urlencode "key@$W/sshd/other" --data-urlencode "hostkey=$FP"); vjob "$J" | chk "私钥不对 (服务器没有它的公钥) → E_SSH_AUTH" 'assert d["state"]=="error" and d["result"]["code"]=="E_SSH_AUTH"'
J=$(vres probe --data-urlencode mode=key --data-urlencode "key=-----BEGIN OPENSSH PRIVATE KEY-----
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
-----END OPENSSH PRIVATE KEY-----" --data-urlencode "hostkey=$FP"); vjob "$J" | chk "私钥内容损坏 → E_SSH_KEY" 'assert d["state"]=="error" and d["result"]["code"]=="E_SSH_KEY"'
J=$(VP=$((SSHD_PORT+1)) vres probe "${KEYARGS[@]}"); vjob "$J" | chk "端口上没有 SSH 服务 → E_SSH_UNREACHABLE" 'assert d["state"]=="error" and d["result"]["code"]=="E_SSH_UNREACHABLE"'
printf 'hop=%s\nips=2\nos=centos\n' "$HOP_PORT" > "$W/vpsctl"
J=$(vres probe "${KEYARGS[@]}" --data-urlencode "hostkey=$FP"); vjob "$J" | chk "不支持的系统 (CentOS): 探测成功但 supported=false, 说明原因 (没有操作清单)" 'r=d["result"]; assert d["state"]=="done" and not r["supported"] and r["support"]=="no" and "Debian" in r["support_note"] and r["actions"]==[]'
J=$(vres provision "${KEYARGS[@]}" --data-urlencode "hostkey=$FP" --data-urlencode "install_deps=1"); vjob "$J" | chk "对不支持的系统部署 → E_VPS_UNSUPPORTED (不改动服务器)" 'assert d["state"]=="error" and d["result"]["code"]=="E_VPS_UNSUPPORTED" and "Debian" in d["msg"]'
printf 'hop=%s\nips=2\nos=ubuntu2404\n' "$HOP_PORT" > "$W/vpsctl"
J=$(vres probe "${KEYARGS[@]}" --data-urlencode "hostkey=$FP"); vjob "$J" | chk "Ubuntu 24.04 完整支持" 'r=d["result"]; assert r["os"]["id"]=="ubuntu" and r["support"]=="full"'
printf 'hop=%s\nips=2\nos=debian10\n' "$HOP_PORT" > "$W/vpsctl"
J=$(vres probe "${KEYARGS[@]}" --data-urlencode "hostkey=$FP"); vjob "$J" | chk "Debian 10 (已停止维护): 尽力支持, 给出提示" 'r=d["result"]; assert r["supported"] and r["support"]=="best_effort" and "停止维护" in r["support_note"]'
echo "-- 依赖缺失: 先问用户, 没同意就不装"
printf 'hop=%s\nips=2\nmissing=1\n' "$HOP_PORT" > "$W/vpsctl"
J=$(vres probe "${KEYARGS[@]}" --data-urlencode "hostkey=$FP"); vjob "$J" | chk "探测出缺少 ca-certificates, 操作清单里有「安装依赖」" 'r=d["result"]; assert r["missing"]==["ca-certificates"] and [x["name"] for x in r["deps"] if not x["installed"]]==["ca-certificates"] and r["actions"][0]["id"]=="deps"'
J=$(vres provision "${KEYARGS[@]}" --data-urlencode "hostkey=$FP" --data-urlencode "install_deps=0"); vjob "$J" | chk "没同意安装依赖 → E_VPS_DEPS (服务器没动)" 'assert d["state"]=="error" and d["result"]["code"]=="E_VPS_DEPS"'
expect "失败的部署没有往本机服务器列表里加任何东西" sh -c "! grep -q '203.0.113' '$W/h/servers.jsonl'"
echo "-- 部署 (同意安装依赖): 节点加进本机, 每个出口 IP 一个"
J=$(vres provision "${KEYARGS[@]}" --data-urlencode "hostkey=$FP" --data-urlencode "install_deps=1" --data-urlencode "name=My-VPS" --data-urlencode "role=pin"); vjob "$J" > "$W/prov.json"
cat "$W/prov.json" | chk "部署成功: 9 个步骤全部完成, 每个出口 IP 一个节点, 出口 IP 已验证 (从节点出去看到的 IP)" 'r=d["result"]; assert d["state"]=="done" and len(d["steps"])==9 and all(s["state"]=="done" for s in d["steps"]) and [n["tag"] for n in r["nodes"]]==["My-VPS-203.0.113.9","My-VPS-203.0.113.10"] and all(n["egress"]=="203.0.113.9" for n in r["nodes"]) and r["ips"]==["127.0.0.1","127.0.0.1"] and r["vps"].startswith("v-")'
VID=$(jp 'print(d["result"]["vps"])' < "$W/prov.json")
api "$A/api/state" | chk "两个节点已经在本机服务器列表里 (固定出口)" 's={x["tag"]:x for x in d["servers"]}; assert s["My-VPS-203.0.113.9"]["role"]=="pin" and s["My-VPS-203.0.113.10"]["role"]=="pin"'
expect "核心仍在运行, 配置里有新节点" sh -c "nc -z 127.0.0.1 $PORT && grep -q 'My-VPS-203.0.113.9' '$W/h/config.json'"
api "$A/api/vps" | chk "记录: 地址 / 端口 / 用户 / 系统 / 指纹 / 出口 IP / 节点 (没有任何密码或私钥)" 'v=d["vps"][0]; assert len(d["vps"])==1 and v["id"]=="'"$VID"'" and v["name"]=="My-VPS" and v["host"]=="127.0.0.1" and v["ssh_port"]=='"$SSHD_PORT"' and v["user"]=="'"$ME"'" and "Debian" in v["os"] and v["hostkey"]=="'"$FP"'" and v["nodes"]==["My-VPS-203.0.113.9","My-VPS-203.0.113.10"] and "password" not in json.dumps(v) and "key" not in [k for k in v]'
expect "记录文件权限 600, 里面没有私钥" sh -c "test \"\$(stat -f %Lp '$W/h/vps.jsonl')\" = 600 && ! grep -q 'PRIVATE KEY' '$W/h/vps.jsonl'"
echo "-- 凭据不落盘: 任务结束后临时文件都已删除, 私钥 / 口令没有出现在日志 / 任务文件 / 记录里"
sleep 1
expect "没有留下凭据临时文件 (jobs/*.cred 与 enana-vps.* 目录)" sh -c "! ls '$W/h/jobs'/*.cred 2>/dev/null | grep -q . && ! ls -d \"\${TMPDIR:-/tmp}\"/enana-vps.* 2>/dev/null | grep -q ."
expect "私钥内容没有出现在本机数据目录的任何文件里 (日志 / 任务 / 记录 / 同步密钥 …)" sh -c "! grep -rqF '$KEYLINE' '$W/h' 2>/dev/null"
api "$A/api/logs?type=ops" | chk "操作记录里有「添加自己的服务器」, 不含私钥" 't=json.dumps(d["rows"],ensure_ascii=False); assert any(r["action"]=="添加自己的服务器" for r in d["rows"]) and "PRIVATE KEY" not in t'
echo "-- 再部署一次同一台 = 更新记录 (不重复)"
J=$(vres provision "${KEYARGS[@]}" --data-urlencode "hostkey=$FP" --data-urlencode "install_deps=1" --data-urlencode "name=My-VPS" --data-urlencode "role=pin"); [ "$(job_wait "$J")" = done ] && tpass "再次部署同一台服务器完成" || tfail "再次部署同一台服务器完成"
api "$A/api/vps" | chk "仍然只有一条记录, 编号不变" 'assert len(d["vps"])==1 and d["vps"][0]["id"]=="'"$VID"'"'
echo "-- 重新识别出口 IP: 服务器多了一个 IP → 补上新节点; 没变化就不动配置"
J=$(vres redetect "${KEYARGS[@]}" --data-urlencode "id=$VID"); vjob "$J" | chk "没有新 IP: added=0, 不改动核心配置" 'r=d["result"]; assert d["state"]=="done" and r["added"]==0 and r["nodes"]==[] and len(r["ips"])==2'
printf 'hop=%s\nips=3\n' "$HOP_PORT" > "$W/vpsctl"
J=$(vres redetect "${KEYARGS[@]}" --data-urlencode "id=$VID"); vjob "$J" | chk "多了一个 IP: 补充 1 个新节点 (沿用已有节点的角色), 总共 3 个出口 IP" 'r=d["result"]; assert d["state"]=="done" and r["added"]==1 and [n["tag"] for n in r["nodes"]]==["My-VPS-203.0.113.11"] and len(r["ips"])==3'
api "$A/api/state" | chk "本机服务器列表里有 3 个 My-VPS 节点, 新节点角色 = pin" 's={x["tag"]:x for x in d["servers"] if x["tag"].startswith("My-VPS-")}; assert sorted(s)==["My-VPS-203.0.113.10","My-VPS-203.0.113.11","My-VPS-203.0.113.9"] and s["My-VPS-203.0.113.11"]["role"]=="pin"'
api "$A/api/vps" | chk "记录里的出口 IP / 节点更新为 3 个" 'v=d["vps"][0]; assert len(v["ips"])==3 and len(v["nodes"])==3'
echo "-- 记录里的指纹是固定的: 服务器指纹变了 (被中间人 / 重装) → 拒绝连接"
cp "$W/h/vps.jsonl" "$W/vps.jsonl.bak"; sed -i '' "s#\"hostkey\":\"$FP\"#\"hostkey\":\"SHA256:$(printf 'B%.0s' $(seq 1 43))\"#" "$W/h/vps.jsonl"
J=$(vres redetect "${KEYARGS[@]}" --data-urlencode "id=$VID"); vjob "$J" | chk "重新识别时用的是记录里固定的指纹: 与服务器不一致 → E_SSH_HOSTKEY" 'assert d["state"]=="error" and d["result"]["code"]=="E_SSH_HOSTKEY"'
J=$(vres probe "${KEYARGS[@]}"); vjob "$J" | chk "没带指纹的探测会提示「这台服务器的指纹和上次保存的不一样」 (hostkey_changed)" 'assert d["result"]["hostkey_changed"]'
cp "$W/vps.jsonl.bak" "$W/h/vps.jsonl"
echo "-- 提权: root / sudo 免密 / sudo 要密码 / 没有 sudo"
printf 'hop=%s\nips=2\npriv=sudo_nopass\n' "$HOP_PORT" > "$W/vpsctl"; : > "$FAKE_STATE/calls.log"
J=$(vres provision "${KEYARGS[@]}" --data-urlencode "hostkey=$FP" --data-urlencode "install_deps=1" --data-urlencode "name=Sudo-VPS"); vjob "$J" | chk "sudo 免密的用户: 部署成功" 'assert d["state"]=="done"'
expect "部署脚本是通过 sudo -n 执行的 (探测只读, 不用 sudo)" sh -c "grep -q '^sudo -n bash -c' '$FAKE_STATE/calls.log'"
printf 'hop=%s\nips=2\npriv=sudo_password\nsudopw=Sudo-Pw-1\n' "$HOP_PORT" > "$W/vpsctl"; : > "$FAKE_STATE/calls.log"
J=$(vres provision "${KEYARGS[@]}" --data-urlencode "hostkey=$FP" --data-urlencode "install_deps=1" --data-urlencode "name=Sudo-VPS" --data-urlencode "sudo_password=Sudo-Pw-1"); vjob "$J" | chk "sudo 要密码: 提供了正确的 sudo 密码 → 成功" 'assert d["state"]=="done"'
expect "sudo 密码只通过标准输入传递: 没有出现在 sudo 的命令行里" sh -c "grep -q '^sudo -S -p' '$FAKE_STATE/calls.log' && ! grep -q 'Sudo-Pw-1' '$FAKE_STATE/calls.log' '$FAKE_STATE/ssh.log'"
J=$(vres provision "${KEYARGS[@]}" --data-urlencode "hostkey=$FP" --data-urlencode "install_deps=1" --data-urlencode "name=Sudo-VPS" --data-urlencode "sudo_password=wrong"); vjob "$J" | chk "sudo 密码不对 → E_VPS_PRIVILEGE" 'assert d["state"]=="error" and d["result"]["code"]=="E_VPS_PRIVILEGE"'
printf 'hop=%s\nips=2\npriv=none\n' "$HOP_PORT" > "$W/vpsctl"
J=$(vres provision "${KEYARGS[@]}" --data-urlencode "hostkey=$FP" --data-urlencode "install_deps=1" --data-urlencode "name=Sudo-VPS"); vjob "$J" | chk "既不是 root 也没有 sudo → E_VPS_PRIVILEGE" 'assert d["state"]=="error" and d["result"]["code"]=="E_VPS_PRIVILEGE"'
printf 'hop=%s\nips=2\nfail=E_VPS_VERIFY\n' "$HOP_PORT" > "$W/vpsctl"
J=$(vres provision "${KEYARGS[@]}" --data-urlencode "hostkey=$FP" --data-urlencode "install_deps=1" --data-urlencode "name=Fail-VPS"); vjob "$J" | chk "服务端启动失败 (脚本报 E_VPS_VERIFY) → 任务失败, 带原因" 'assert d["state"]=="error" and d["result"]["code"]=="E_VPS_VERIFY" and d["msg"]'
printf 'hop=%s\nips=2\n' "$HOP_PORT" > "$W/vpsctl"
echo "-- 密码登录 (SSH_ASKPASS: 密码从 600 权限的临时文件交给 ssh, 不进命令行 / 环境变量)"
: > "$FAKE_STATE/ssh.log"
J=$(vres probe --data-urlencode mode=password --data-urlencode "password=sshpw-Test-123" --data-urlencode "hostkey=$FP"); vjob "$J" | chk "密码登录: 探测成功" 'assert d["state"]=="done" and d["result"]["os"]["id"]=="debian"'
J=$(vres probe --data-urlencode mode=password --data-urlencode "password=sshpw-WRONG" --data-urlencode "hostkey=$FP"); vjob "$J" | chk "密码不对 → E_SSH_AUTH" 'assert d["state"]=="error" and d["result"]["code"]=="E_SSH_AUTH"'
expect "密码没有出现在 ssh 的命令行里, 用的是 askpass (SSH_ASKPASS_REQUIRE=force)" sh -c "! grep -q -e 'sshpw-Test-123' -e 'sshpw-WRONG' '$FAKE_STATE/ssh.log' && grep -q 'ASKPASS_REQUIRE=force askpass=askpass' '$FAKE_STATE/ssh.log'"
expect "密码没有出现在本机数据目录的任何文件里 (日志 / 任务 / 记录)" sh -c "! grep -rqF -e 'sshpw-Test-123' -e 'sshpw-WRONG' -e 'Sudo-Pw-1' '$W/h' 2>/dev/null"
sleep 1; expect "没有留下凭据临时文件" sh -c "! ls '$W/h/jobs'/*.cred 2>/dev/null | grep -q . && ! ls -d \"\${TMPDIR:-/tmp}\"/enana-vps.* 2>/dev/null | grep -q ."
echo "-- 忘记记录 (只删记录, 不删节点)"
vp forget -d 'id=bad' | chk "编号无效 → 被拒" 'assert not d["ok"]'
vp forget -d 'id=v-ffffff' | chk "找不到的记录 → E_NOT_FOUND" 'assert d["code"]=="E_NOT_FOUND"'
api -X POST "$A/api/vps/forget" -d "id=$VID" | chk "忘记这台服务器的记录" 'assert d["ok"]'
api "$A/api/vps" | chk "记录已删除" 'assert d["vps"]==[] or all(v["id"]!="'"$VID"'" for v in d["vps"])'
api "$A/api/state" | chk "节点还在 (只删了记录)" 'assert "My-VPS-203.0.113.9" in {x["tag"] for x in d["servers"]}'
echo "-- 云端内容包里的部署脚本: 只认白名单里的四个文件名"
rm -rf "$W/content4"; cp -R "$HERE/fixtures/content" "$W/content4"; printf '#!/bin/sh\necho pwned\n' > "$W/content4/vps/evil.sh"
BUNDLE "$W/content4" "$W/ckey.pem" 130
"$W/shortcut/enana" content --force > "$W/content.out" 2>&1; expect "包里的 vps/evil.sh (白名单之外) 被拒绝, 仍用原来的内容" sh -c "grep -q '不允许的文件' '$W/content.out' && test ! -e '$W/h/cloud/content/vps/evil.sh'"
BUNDLE "$HERE/fixtures/content" "$W/ckey.pem" 140
"$W/shortcut/enana" content --force > "$W/content.out" 2>&1; expect "正常的内容包 (含四个部署脚本) 照常安装" sh -c "test \"\$(cat '$W/h/cloud/content/SEQ')\" = 140 && test -s '$W/h/cloud/content/vps/provision.sh'"
for n in Sudo-VPS My-VPS; do for ip in 9 10 11; do J=$(api -X POST "$A/api/servers/delete?tag=$n-203.0.113.$ip" | jp 'print(d.get("job",""))'); [ -z "$J" ] || job_wait "$J" >/dev/null; done; done
fi

echo "== 8. 设置 / 操作记录 / 日志"
api "$A/api/settings" | chk "读取设置: 日志保留 720 小时 (12 小时 – 30 天) + 三个日志开关 + 自动识别 + 占用 + 账号" 'st=d["settings"]; assert st["log_hours"]==720 and st["log_hours_min"]==12 and st["log_hours_max"]==720 and st["access_log"] and st["log_ops"] and st["log_core"] and st["auto_sites"] is False and "usage" in d and d["account"]["email"]=="user1@example.test" and "proxy" in d'
api -X POST "$A/api/settings" -d 'log_hours=721' | chk "保留 721 小时 (超过 30 天) → 被拒" 'assert not d["ok"]'
api -X POST "$A/api/settings" -d 'log_hours=11' | chk "保留 11 小时 (不到 12 小时) → 被拒" 'assert not d["ok"]'
api -X POST "$A/api/settings" -d 'log_hours=abc' | chk "保留时长非数字 → 被拒" 'assert not d["ok"]'
api -X POST "$A/api/settings" -d 'lang=fr' | chk "不支持的语言 → 被拒" 'assert not d["ok"]'
api -X POST "$A/api/settings" -d 'log_hours=168' | chk "保留时长改为 168 小时 (7 天) → 成功" 'assert d["ok"]'
api "$A/api/settings" | chk "设置已保存" 'assert d["settings"]["log_hours"]==168'
api -X POST "$A/api/settings" -d 'log_days=2' | chk "旧版仪表盘按天提交 (log_days=2) 仍然接受, 换算成 48 小时" 'assert d["ok"]'
api "$A/api/settings" | chk "log_days=2 → 48 小时" 'assert d["settings"]["log_hours"]==48'
api -X POST "$A/api/settings" -d 'log_hours=720' >/dev/null
api "$A/api/logs?type=ops" | chk "操作记录里有此前的操作 (登录 / 覆盖 / 服务器 …), 不含密码或令牌" 'rows=d["rows"]; assert d["ok"] and len(rows)>=5; t=json.dumps(rows); assert "Passw0rd" not in t and "New-Passw0rd2" not in t and "'"$TOKEN"'" not in t; assert any(r["action"]=="登录" for r in rows)'
api "$A/api/logs?type=ops&q=%E7%99%BB%E5%BD%95" | chk "操作记录支持关键字搜索" 'assert d["total"]>=1 and all("登录" in (r["action"]+r["detail"]) for r in d["rows"])'
api -H 'X-Enana-Lang: en' "$A/api/logs?type=ops" | chk "操作记录按请求语言翻译 (英文: Sign in)" 'assert any(r["action"]=="Sign in" for r in d["rows"]) and not any("登录" in r["action"] for r in d["rows"])'
api "$A/api/logs?type=proxy&limit=5" | chk "代理日志可读" 'assert d["ok"] and len(d["rows"])<=5'
api "$A/api/logs?type=access" | chk "网站访问记录可读" 'assert d["ok"]'
api "$A/api/logs?type=bogus" | chk "日志类型无效 → 被拒" 'assert not d["ok"]'
api "$A/api/logs?type=ops&day=2026-1-1" | chk "日期格式无效 → 被拒" 'assert not d["ok"]'
api "$A/api/logs/export?type=ops" | grep -q '登录' && tpass "导出操作记录 (纯文本)" || tfail "导出操作记录 (纯文本)"
api -X POST "$A/api/logs/clear" -d 'type=ops' | chk "清除操作记录" 'assert d["ok"] and d["freed"]>=0'
api "$A/api/logs?type=ops" | chk "清除后只剩「清除日志」这一条" 'assert d["total"]<=1'
api -X POST "$A/api/logs/clear" -d 'type=nope' | chk "清除: 类型无效 → 被拒" 'assert not d["ok"]'
api -X POST "$A/api/settings" -d 'access_log=0' | chk "关闭「记录网站访问」→ 需要重新生成配置 (返回任务)" 'assert d["ok"] and d["job"]'
sleep 0.5; J=$(api "$A/api/settings" >/dev/null; ls "$W/h/jobs" | grep '^settings-apply.*json$' | head -1 | sed 's/\.json$//'); [ "$(job_wait "$J")" = done ] && tpass "配置已重新生成并应用 (日志级别 warn)" || tfail "配置已重新生成并应用"
grep -q '"level":"warn"' "$W/h/config.json" && tpass "config.json 日志级别 = warn" || tfail "config.json 日志级别 = warn"
api -X POST "$A/api/settings" -d 'access_log=1' >/dev/null; sleep 4

echo "== 8b. 日志系统: 概览 / 筛选 / 搜索 (合成日志) · 诊断导出 · 三个独立开关 · 关闭代理时也记录访问"
D8=$(date -v-1d +%F); mkdir -p "$W/h/logs"
{
  for r in "1|10:00:01|chatgpt.com|Google Chrome|direct-app|" "2|10:00:02|www.example.org|Google Chrome|Fix-Pin|" "3|10:00:03|slow.example|curl|direct|timeout"; do
    IFS='|' read -r id tm h ap tg er <<< "$r"
    printf '+0800 %s %s INFO [%s 0ms] inbound/mixed[in]: inbound connection to %s:443\n' "$D8" "$tm" "$id" "$h"
    printf '+0800 %s %s INFO [%s 0ms] router: found process path: /Applications/%s.app/Contents/MacOS/x, user: u\n' "$D8" "$tm" "$id" "$ap"
    printf '+0800 %s %s INFO [%s 1ms] outbound/%s[%s]: outbound connection to %s:443\n' "$D8" "$tm" "$id" "$([ "${tg#direct}" != "$tg" ] && echo direct || echo socks)" "$tg" "$h"
    [ -n "$er" ] && printf '+0800 %s %s ERROR [%s 9s] connection: open connection to %s:443 using outbound/direct[direct]: dial tcp 9.9.9.9:443: i/o timeout\n' "$D8" "$tm" "$id" "$h"
  done
} > "$W/h/logs/proxy-$D8.log"
api "$A/api/logs?type=access&day=$D8&limit=10" | chk "访问记录: 3 条连接 + 概览 (全部 3 / 直连 2 / 代理 1 / 失败 1, 原因 app:1 policy:1) + 有记录的日期列表" 's=d["summary"]; assert d["total"]==3 and (s["all"],s["direct"],s["proxy"],s["error"])==(3,2,1,1) and s["reasons"]=={"app":1,"policy":1} and "'"$D8"'" in d["days"]'
api "$A/api/logs?type=access&day=$D8&f=direct" | chk "筛选 f=direct → 2 条 (概览数字不变)" 'assert d["total"]==2 and d["summary"]["all"]==3'
api "$A/api/logs?type=access&day=$D8&f=error" | chk "筛选 f=error → 1 条 (slow.example, 失败类型 timeout)" 'assert d["total"]==1 and d["rows"][0]["host"]=="slow.example" and d["rows"][0]["err"]=="timeout"'
api "$A/api/logs?type=access&day=$D8&q=chrome&limit=1&offset=1" | chk "搜索 + 分页: q=chrome (2 条), limit=1 offset=1 → 返回较早的那条" 'assert d["total"]==2 and len(d["rows"])==1 and d["rows"][0]["host"]=="chatgpt.com"'
api "$A/api/logs?type=access&day=$D8&f=bogus" | chk "筛选值无效 → 忽略 (返回全部), 不报错" 'assert d["ok"] and d["total"]==3'
api "$A/api/logs?type=ops&f=dashboard" | chk "操作记录筛选 f=dashboard: 只有来自仪表盘的" 'assert d["rows"] and all(r["who"]=="dashboard" for r in d["rows"])'
api "$A/api/logs?type=proxy&day=$D8&f=error" | chk "代理日志筛选 f=error: 只有 ERROR 行, 概览带 warn / error 数" 'assert d["total"]==1 and d["rows"][0]["level"]=="ERROR" and d["summary"]["error"]==1'
# 诊断导出
api "$A/api/logs/bundle?hours=48&sections=ops,access,proxy,snapshot" -D "$W/bundle.hdr" -o "$W/bundle.txt"
grep -qi 'content-disposition: attachment; filename="enana-diagnostics-' "$W/bundle.hdr" && tpass "诊断导出: 下载文件名 enana-diagnostics-<时间>.txt" || tfail "诊断导出: 下载文件名"
head -1 "$W/bundle.txt" | grep -q '^#ENANA-DIAGNOSTICS format=1' && tpass "诊断导出: 第一行格式标记" || tfail "诊断导出: 第一行格式标记"
python3 - "$W/bundle.txt" "$TOKEN" <<'PY' && tpass "诊断导出: 11 个分区齐全, 行数自洽, 不含令牌 / 服务器密码" || tfail "诊断导出: 分区 / 行数 / 脱敏"
import sys, re
txt = open(sys.argv[1], encoding='utf-8').read(); lines = txt.split('\n')
secs, cur = {}, None
for l in lines:
    m = re.match(r'@@SECTION (\S+) format=(\S+) rows=(\d+)$', l)
    if m: cur = m.group(1); secs[cur] = [int(m.group(3)), 0]; continue
    if l == '@@END': cur = None; continue
    if cur and l != '': secs[cur][1] += 1
need = ['meta','env','config','policy','servers','apps','probes','live','ops','access','proxy']
assert all(k in secs for k in need), [k for k in need if k not in secs]
assert all(abs(v[0] - v[1]) <= 1 for v in secs.values()), secs
assert sys.argv[2] not in txt and 'sshpw-Test-123' not in txt and '"password":"p"' not in txt
assert 'chatgpt.com' in txt and 'config.check=ok' in txt and 'proxy.enabled=1' in txt, 'content'
PY
api "$A/api/logs/bundle?hours=24&sections=ops" | grep -c '^@@SECTION' | { read -r n; [ "$n" = 2 ] && tpass "诊断导出: 只勾选操作记录 → meta + ops 两个分区" || tfail "诊断导出: 只勾选操作记录 (得到 $n 个分区)"; }
api "$A/api/logs/bundle?hours=24&sections=ops,bogus" | chk "诊断导出: 分区名无效 → 被拒" 'assert not d["ok"]'
api "$A/api/logs/bundle?hours=abc&sections=ops" | chk "诊断导出: 时间范围无效 → 被拒" 'assert not d["ok"]'
api "$A/api/logs?type=ops&q=%E5%AF%BC%E5%87%BA%E8%AF%8A%E6%96%AD" | chk "每次导出都留下一条操作记录 (时间范围 / 勾选的内容 / 大小)" 'r=[x for x in d["rows"] if "hours=48 sections=ops,access,proxy,snapshot" in x["detail"]]; assert d["total"]>=2 and r and "bytes=" in r[0]["detail"] and r[0]["action"]=="导出诊断日志" and r[0]["who"]=="dashboard"'
python3 "$REPO/tools/diag-summary.py" "$W/bundle.txt" 2>&1 | grep -q '== 自动判断' && tpass "tools/diag-summary.py 能解读这份导出文件" || tfail "tools/diag-summary.py 解读导出文件"
"$W/shortcut/enana" diag 6 2>/dev/null | head -1 | grep -q '^#ENANA-DIAGNOSTICS format=1$' && tpass "终端 enana diag (接管道): 直接输出诊断文件" || tfail "终端 enana diag (接管道)"
"$W/shortcut/enana" diag abc >/dev/null 2>&1 && tfail "enana diag 时间范围无效 → 应报错退出" || tpass "enana diag 时间范围无效 → 报错退出"
mkdir -p "$HOME/Downloads"; script -q /dev/null "$W/shortcut/enana" diag 1 >/dev/null 2>&1
DG=$(ls "$HOME/Downloads"/enana-diagnostics-*.txt 2>/dev/null | head -1)
[ -n "$DG" ] && head -1 "$DG" | grep -q '^#ENANA-DIAGNOSTICS format=1$' && grep -q '^@@SECTION access ' "$DG" && tpass "终端 enana diag (在终端里): 存成 ~/Downloads/enana-diagnostics-<时间>.txt" || tfail "终端 enana diag (在终端里) 保存文件"
api "$A/api/logs?type=ops&f=terminal" | chk "终端导出也留下操作记录 (来源 terminal)" 'assert any(r["action"]=="导出诊断日志" and r["who"]=="terminal" for r in d["rows"])'
# 三个独立开关: 操作记录 / 网站访问 / 代理核心日志
api -X POST "$A/api/settings" -d 'log_ops=0' | chk "关闭「操作记录」" 'assert d["ok"]'
api -X POST "$A/api/override?kind=site&value=nolog.example&state=direct" >/dev/null
api "$A/api/logs?type=ops&q=nolog.example" | chk "操作记录关闭后: 新的操作不再记录" 'assert d["total"]==0'
api "$A/api/logs?type=ops&q=log_ops" | chk "但「关闭操作记录」这个动作本身留痕 (先写再关)" 'assert any("setting=log_ops" in r["detail"] and "to=0" in r["detail"] for r in d["rows"])'
api -X POST "$A/api/settings" -d 'log_ops=1' >/dev/null
api -X POST "$A/api/override?kind=site&value=nolog.example&state=follow" >/dev/null
api "$A/api/logs?type=ops&q=nolog.example" | chk "重新开启后又开始记录 (只有开启之后的那一次, 关闭期间的没有)" 'assert d["total"]==1 and "to=follow" in d["rows"][0]["detail"]'
api "$A/api/logs?type=ops&q=log_ops" | chk "「开启操作记录」本身也留痕" 'assert any("to=1" in r["detail"] for r in d["rows"])'
api "$A/api/settings" | chk "三个开关各自独立: log_ops / access_log / log_core 都能读到" 'st=d["settings"]; assert st["log_ops"] is True and st["access_log"] is True and st["log_core"] is True'
J=$(api -X POST "$A/api/settings" -d 'log_core=0' | jp 'print(d["job"])'); [ "$(job_wait "$J")" = done ] && tpass "只关「代理核心日志」(网站访问仍开) → 重新生成配置" || tfail "只关代理核心日志"
grep -q '"level":"info"' "$W/h/config.json" && tpass "网站访问还开着 → 核心仍是 info 级别 (连接记录要用)" || tfail "网站访问开着时核心级别应保持 info"
J=$(api -X POST "$A/api/settings" -d 'access_log=0' | jp 'print(d["job"])'); [ "$(job_wait "$J")" = done ] && tpass "再关「网站访问」→ 重新生成配置" || tfail "再关网站访问"
grep -q '"disabled":true' "$W/h/config.json" && tpass "网站访问和核心日志都关闭 → 核心完全不写日志 (log.disabled)" || tfail "两个都关闭 → log.disabled"
J=$(api -X POST "$A/api/settings" -d 'access_log=1&log_core=1' | jp 'print(d["job"])'); [ "$(job_wait "$J")" = done ] && tpass "两个都重新打开" || tfail "重新打开日志"
grep -q '"level":"info"' "$W/h/config.json" && ! grep -q '"disabled":true' "$W/h/config.json" && tpass "配置恢复: info 级别, 没有 disabled" || tfail "配置恢复"
api -X POST "$A/api/settings" -d 'log_ops=2' | chk "开关值无效 → 被拒" 'assert not d["ok"]'
sleep 3

echo "== 8c. 自动识别打不开的网站 (设置里打开才工作): enana tick 读核心日志 → 候选 → 经过代理验证 → 加入 / 放弃 · 撤销 · 审计"
fakefail() { # fakefail <域名> <次数> [出口名]: 往核心日志里追加「走直连却超时」的连接 (出口 direct-cn / direct 才会被自动识别参考)
  local h=$1 n=$2 tg=${3:-direct-cn} i id ts; ts=$(date '+%F %T')
  for i in $(seq 1 "$n"); do
    id=$((RANDOM * 100 + i))
    { printf '+0800 %s INFO [%s 0ms] router: found process path: /Applications/Safari.app/Contents/MacOS/Safari, user: u\n' "$ts" "$id"
      printf '+0800 %s INFO [%s 1ms] outbound/direct[%s]: outbound connection to %s:443\n' "$ts" "$id" "$tg" "$h"
      printf '+0800 %s ERROR [%s 9s] connection: open connection to %s:443 using outbound/direct[%s]: dial tcp 9.9.9.9:443: i/o timeout\n' "$ts" "$id" "$h" "$tg"; } >> "$W/h/sing-box.log"
  done
}
fakeok() { # fakeok <次数>: 往核心日志里追加「走直连、成功了」的连接 (没有这些, 窗口里全是失败, 会被当成断网而不添加任何网站 —— 这是故意的保护)
  local n=$1 i id ts; ts=$(date '+%F %T')
  for i in $(seq 1 "$n"); do id=$((RANDOM * 100 + i + 50)); printf '+0800 %s INFO [%s 1ms] outbound/direct[direct]: outbound connection to www.fine-site.com:443\n' "$ts" "$id" >> "$W/h/sing-box.log"; done
}
atick() { ENANA_AUTOSITE_VERIFY_URL=${1:-http://127.0.0.1:$N_PORT/ip} "$W/shortcut/enana" tick --quiet >/dev/null 2>&1; }
api -X POST "$A/api/proxy" -d 'on=1&mode=auto' >/dev/null
api -X POST "$A/api/settings" -d 'auto_sites=1' | chk "打开「自动识别」(默认关闭; 有服务器才允许)" 'assert d["ok"]'
api "$A/api/settings" | chk "设置里 auto_sites = true" 'assert d["settings"]["auto_sites"] is True'
atick; sleep 1                                                               # 第一次只记下日志位置 (不翻历史)
fakefail cdn.stuck-site.io 4 direct-cn; fakefail mine-site.io 4 direct-site; fakefail viaok-site.io 1 direct; fakeok 30
atick; sleep 3
expect "同一网站 4 次直连超时 → 自动加入代理 (取最后两段: stuck-site.io, 有自动线路用自动线路)" grep -q '^site|stuck-site.io|auto|' "$W/h/overrides.tsv"
expect "你明确设为直连的 (出口 direct-site) 不参与, 失败太少的 (1 次) 也不加" sh -c "! grep -q 'mine-site.io' '$W/h/overrides.tsv' && ! grep -q 'viaok-site.io' '$W/h/overrides.tsv'"
api "$A/api/state" | chk "状态里: src=auto, 带 添加时间 / 失败类型 / 失败次数 / 触发的应用" 'o={x["value"]:x for x in d["overrides"]}["stuck-site.io"]; assert o["src"]=="auto" and o["state"]=="auto" and o["why"]=="timeout" and o["fails"]==4 and o["app"]=="Safari" and o["at"]>0'
api "$A/api/logs?type=ops&f=auto" | chk "操作记录 (来源 auto): 添加网站到代理 —— 域名 / 失败次数 / 失败类型 / 应用 / 原来的出口 / 验证结果" 'r=[x for x in d["rows"] if x["action"]=="自动识别: 添加网站到代理"]; assert r and "domain=stuck-site.io" in r[0]["detail"] and "fails=4" in r[0]["detail"] and "err=timeout" in r[0]["detail"] and "app=Safari" in r[0]["detail"] and "was=direct-cn" in r[0]["detail"] and "verify=\"http=200" in r[0]["detail"] and r[0]["who"]=="auto"'
fakefail cdn.stuck-site.io 4 direct-cn; atick; sleep 1
expect "已经加过的不会重复添加" test "$(grep -c '^site|stuck-site.io|' "$W/h/overrides.tsv")" = 1
# 验证没通过 (经过代理也连不上) → 撤销, 24 小时内不再试
fakefail dead-site.io 4 direct; atick "https://127.0.0.1:1/"; sleep 3
expect "经过代理验证不通 → 撤销 (不留下覆盖), 记入冷却" sh -c "! grep -q 'dead-site.io|' '$W/h/overrides.tsv' && grep -q '^dead-site.io ' '$W/h/.autosite.cool'"
api "$A/api/logs?type=ops&f=auto" | chk "操作记录: 放弃网站 (结果 error, 说明为什么)" 'r=[x for x in d["rows"] if x["action"]=="自动识别: 放弃网站"]; assert r and "domain=dead-site.io" in r[0]["detail"] and r[0]["result"]=="error"'
# 你从自动识别里删掉 (网站页「恢复跟随」) → 以后不再自动添加
api -X POST "$A/api/override?kind=site&value=stuck-site.io&state=follow" | chk "网站页把自动识别的网站恢复跟随 → 成功" 'assert d["ok"]'
expect "从自动识别记录里去掉, 并记入「不再自动添加」" sh -c "! grep -q '^stuck-site.io|' '$W/h/autosites.tsv' && grep -qx 'stuck-site.io' '$W/h/autosites.dismissed'"
fakefail cdn.stuck-site.io 4 direct-cn; atick; sleep 1
expect "删除过的网站不会再被自动添加" sh -c "! grep -q 'stuck-site.io' '$W/h/overrides.tsv'"
# 全部撤销
fakefail second-stuck.io 4 direct-cn; atick; sleep 3
expect "又自动添加了一个 (second-stuck.io)" grep -q '^site|second-stuck.io|auto|' "$W/h/overrides.tsv"
api -X POST "$A/api/sites/auto/clear" | chk "全部撤销 → removed = 1" 'assert d["ok"] and d["removed"]==1'
expect "撤销后覆盖和记录都没了, 并且不会再被自动添加" sh -c "! grep -q 'second-stuck.io' '$W/h/overrides.tsv' && test ! -s '$W/h/autosites.tsv' && grep -qx 'second-stuck.io' '$W/h/autosites.dismissed'"
api "$A/api/logs?type=ops&f=dashboard&q=%E5%85%A8%E9%83%A8%E6%92%A4%E9%94%80" | chk "操作记录: 自动识别: 全部撤销" 'assert d["total"]>=1 and "count=1" in d["rows"][0]["detail"]'
# 关闭后不工作
api -X POST "$A/api/settings" -d 'auto_sites=0' | chk "关闭「自动识别」" 'assert d["ok"]'
fakefail third-stuck.io 4 direct-cn; atick; sleep 1
expect "关闭后即使日志里有失败也不添加" sh -c "! grep -q 'third-stuck.io' '$W/h/overrides.tsv'"
api -X POST "$A/api/settings" -d 'auto_sites=maybe' | chk "开关值无效 → 被拒" 'assert not d["ok"]'
# 审计: 仪表盘直接对核心做的操作 (断开连接) 事后补一条操作记录
api -X POST "$A/api/audit" -d 'ev=kill&scope=host&n=3&host=a.example' | chk "审计: 断开连接 (按网站) → 成功" 'assert d["ok"]'
api "$A/api/logs?type=ops&q=%E6%96%AD%E5%BC%80%E8%BF%9E%E6%8E%A5" | chk "操作记录: 断开连接 —— 范围 / 数量 / 网站" 'r=d["rows"][0]; assert "scope=host" in r["detail"] and "count=3" in r["detail"] and "host=a.example" in r["detail"] and r["who"]=="dashboard"'
api -X POST "$A/api/audit" -d 'ev=bogus' | chk "审计: 不认识的事件 → 被拒" 'assert not d["ok"]'
api -X POST "$A/api/audit" -d 'ev=kill&scope=host&n=1&host=bad%20host;rm' | chk "审计: 网站名里有奇怪字符 → 不写进记录" 'assert d["ok"]'
expect "奇怪字符的网站名没有被写进操作记录" sh -c "! cat '$W/h/logs/'ops-*.log | grep -qF 'host=bad'"

echo "== 9. 规则库 / DNS"
api "$A/api/rules" | chk "规则库列表: 必选项不可停用, 含自定义标记" 'n={s["tag"]:s for s in d["sets"]}; assert n["geosite-cn"]["essential"] and n["geosite-cn"]["present"] and len(d["sets"])>=5'
api -X POST "$A/api/rules/toggle" -d 'tag=geosite-cn&on=0' | chk "停用必选规则集 → 被拒" 'assert not d["ok"]'
api -X POST "$A/api/rules/toggle" -d 'tag=nope&on=0' | chk "停用不存在的规则集 → E_NOT_FOUND" 'assert d["code"]=="E_NOT_FOUND"'
api -X POST "$A/api/rules/toggle" -d 'tag=geosite-ai&on=0' | chk "停用 AI 规则集 → 任务" 'assert d["ok"] and d["job"]'
sleep 3; api "$A/api/rules" | chk "geosite-ai 已停用" 'n={s["tag"]:s for s in d["sets"]}; assert not n["geosite-ai"]["enabled"]'
api -X POST "$A/api/rules/toggle" -d 'tag=geosite-ai&on=1' >/dev/null; sleep 3
api "$A/api/rules" | chk "geosite-ai 已重新启用" 'n={s["tag"]:s for s in d["sets"]}; assert n["geosite-ai"]["enabled"]'
api -X POST "$A/api/rules/custom/add" -d 'name=bad name&url=http://127.0.0.1/x.srs&policy=pin' | chk "自定义规则集: 非法名称/本机链接 → 被拒" 'assert not d["ok"]'
api "$A/api/dns" | chk "DNS 页数据: 预设 + 当前设置 + 解析流程" 'assert d["settings"]["cn"]=="alidns" and d["settings"]["leak_guard"] and len(d["presets"]["cn"])>=4 and len(d["pipeline"])>=2'
api -X POST "$A/api/dns" -d 'cn=nope' | chk "未知的 DNS 预设 → 立刻返回原因 (不进任务)" 'assert not d["ok"] and "预设" in d["error"]'
api -X POST "$A/api/dns" -d 'cn=custom&cn_custom=ftp://x' | chk "非法自定义 DNS 地址 → 被拒" 'assert not d["ok"]'
api -X POST "$A/api/dns" -d 'cn=dnspod&global=google&ads_block=true&strategy=ipv4_only' | chk "修改 DNS → 任务" 'assert d["ok"] and d["job"]'
sleep 4; api "$A/api/dns" | chk "DNS 设置已保存 (DNSPod / Google / 屏蔽广告 / 仅 IPv4)" 'assert d["settings"]["cn"]=="dnspod" and d["settings"]["global"]=="google" and d["settings"]["ads_block"] and d["settings"]["strategy"]=="ipv4_only"'
expect "核心仍在运行 (DNS 配置通过校验并已应用)" nc -z 127.0.0.1 "$PORT"
api -X POST "$A/api/dns/test" -d 'name=not%20a%20domain' | chk "DNS 测试: 非法域名 → 被拒" 'assert not d["ok"]'
api -X POST "$A/api/dns" -d 'cn=alidns&global=cloudflare&ads_block=false&strategy=prefer_ipv4' >/dev/null; sleep 4
api "$A/api/dns" | chk "DNS 页: 预设更多 (含 DoT / UDP), 带 hosts 数组, 解析流程含「直连用国内 DNS」「经代理由代理解析」" 'ids=[p["id"] for p in d["presets"]["cn"]]; assert "alidns-dot" in ids and "114" in ids and d["hosts"]==[] and {"direct","cn","proxy","global"} <= {r["id"] for r in d["pipeline"]}'
grep -q '"reverse_mapping": *true' "$W/h/config.json" && tpass "核心配置里开启了反向映射 (reverse_mapping)" || tfail "核心配置里开启了反向映射 (reverse_mapping)"
grep -q 'independent_cache' "$W/h/config.json" && tfail "没有使用已弃用的 independent_cache" || tpass "没有使用已弃用的 independent_cache"
grep -q '"default_domain_resolver": *"dns-cn"' "$W/h/config.json" && tpass "直连的域名用国内 DNS 解析 (default_domain_resolver = dns-cn)" || tfail "直连的域名用国内 DNS 解析 (default_domain_resolver = dns-cn)"
dh() { api -X POST "$A/api/dns/hosts" "$@"; }
dh -d 'action=add&domain=hosts-test.example&ip=999.1.1.1' | chk "自定义解析: IP 不合法 → 被拒" 'assert not d["ok"] and d["code"]=="E_INVALID" and "IP" in d["error"]'
dh -d 'action=add&domain=hosts-test.example&ip=01.2.3.4' | chk "自定义解析: IPv4 带前导零 → 被拒" 'assert not d["ok"]'
dh -d 'action=add&domain=hosts-test.example&ip=2001:::1' | chk "自定义解析: IPv6 写错 → 被拒" 'assert not d["ok"]'
dh -d 'action=add&domain=http://bad.example/x&ip=1.2.3.4' | chk "自定义解析: 域名带协议 / 路径 → 被拒" 'assert not d["ok"] and "域名" in d["error"]'
dh --data-urlencode 'action=add' --data-urlencode 'domain=a.example' --data-urlencode "ip=1.2.3.4
b.example|5.6.7.8" | chk "自定义解析: IP 里夹带换行 → 被拒 (不能写坏文件)" 'assert not d["ok"]'
dh -d 'action=nope&domain=a.example&ip=1.2.3.4' | chk "自定义解析: 操作无效 → 被拒" 'assert not d["ok"]'
dh -d 'action=remove&domain=never.example' | chk "自定义解析: 删除不存在的记录 → 被拒" 'assert not d["ok"]'
J=$(dh -d "action=add&domain=Hosts-Test.Example.&ip=127.0.0.1" | jp 'print(d["job"])'); [ "$(job_wait "$J")" = done ] && tpass "添加解析记录 (域名规范化为小写, 任务完成)" || tfail "添加解析记录"
api "$A/api/dns" | chk "记录出现在 hosts 里, 解析流程多出「自定义解析」一行" 'assert d["hosts"]==[{"domain":"hosts-test.example","ip":"127.0.0.1"}] and d["pipeline"][0]["id"]=="hosts" and "1" in d["pipeline"][0]["match"]'
grep -q '"type": *"hosts"' "$W/h/config.json" && grep -q 'override_address' "$W/h/config.json" && tpass "核心配置里有 hosts 服务器和 override_address 路由规则" || tfail "核心配置里有 hosts 服务器和 override_address 路由规则"
expect "加了解析记录后核心仍在运行" nc -z 127.0.0.1 "$PORT"
R=$(curl -s -m 6 -x "socks5h://127.0.0.1:$PORT" "http://hosts-test.example:$N_PORT/ok"); [ "$R" = ok ] && tpass "域名没有真实解析, 但经解析记录连到了 127.0.0.1 (经代理入站访问成功)" || tfail "域名没有真实解析, 但经解析记录连到了 127.0.0.1 (得到: $R)"
api -X POST "$A/api/dns/test" -d 'name=hosts-test.example' | chk "「测试解析」返回你填的 IP" 'assert d["ok"] and d["answers"]==["127.0.0.1"]'
dh -d "action=add&domain=hosts-test.example&ip=127.0.0.2" | chk "重复添加同一个域名 → 被拒" 'assert not d["ok"]'
J=$(dh -d "action=add&domain=v6.hosts-test.example&ip=2001:DB8::1" | jp 'print(d["job"])'); job_wait "$J" >/dev/null
api "$A/api/dns" | chk "IPv6 记录 (规范化为小写)" 'assert {"domain":"v6.hosts-test.example","ip":"2001:db8::1"} in d["hosts"] and len(d["hosts"])==2'
J=$(dh -d "action=update&domain=hosts-test.example&new_domain=hosts-two.example&ip=127.0.0.1" | jp 'print(d["job"])'); job_wait "$J" >/dev/null
api "$A/api/dns" | chk "修改记录 (改域名)" 'ds=[h["domain"] for h in d["hosts"]]; assert "hosts-two.example" in ds and "hosts-test.example" not in ds'
dh -d "action=update&domain=hosts-two.example&new_domain=v6.hosts-test.example&ip=127.0.0.1" | chk "改成已有的域名 → 被拒" 'assert not d["ok"]'
J=$(dh -d "action=update&domain=hosts-two.example&ip=127.0.0.3" | jp 'print(d["job"])'); job_wait "$J" >/dev/null
api "$A/api/dns" | chk "只改 IP (域名不变)" 'assert {"domain":"hosts-two.example","ip":"127.0.0.3"} in d["hosts"]'
J=$(dh -d "action=remove&domain=v6.hosts-test.example" | jp 'print(d["job"])'); job_wait "$J" >/dev/null
api "$A/api/dns" | chk "删除记录" 'assert [h["domain"] for h in d["hosts"]]==["hosts-two.example"]'
J=$(api -X POST "$A/api/dns/hosts/reset" | jp 'print(d["job"])'); [ "$(job_wait "$J")" = done ] && tpass "清空自定义解析 (任务完成)" || tfail "清空自定义解析"
api "$A/api/dns" | chk "清空后 hosts 为空, 解析流程回到原样" 'assert d["hosts"]==[] and d["pipeline"][0]["id"]!="hosts"'
grep -q 'override_address' "$W/h/config.json" && tfail "清空后核心配置里没有 override_address" || tpass "清空后核心配置里没有 override_address"
echo "-- DNS 服务器测速 (本机模拟的 DNS: UDP + DoH + DoT)"
# AUTO's public connectivity URL is intentionally unreachable in the isolated
# fixture. Select its known-working local hop instead of relying on incidental
# URLTest history from prior sections; still exercise the real Global detour.
dns_bench_global_before=$(cl "$U/proxies/Global" | jp 'print(d["now"])')
cl -X PUT "$U/proxies/Global" -d '{"name":"Local-Hop"}' >/dev/null
J=$(api -X POST "$A/api/dns/bench" | jp 'print(d["job"])'); [ "$(job_wait "$J")" = done ] && tpass "DNS 测速任务完成" || tfail "DNS 测速任务完成"
api "$A/api/job?id=$J" | chk "测速结果: 能通的有毫秒数, 不通的是 null, 没有 system / custom" 'r=d["result"]; c={x["id"]:x["ms"] for x in r["cn"]}; g={x["id"]:x["ms"] for x in r["global"]}; assert isinstance(c["alidns"],int) and isinstance(c["alidns-dot"],int) and isinstance(c["114"],int) and c["deaddns"] is None and isinstance(g["cloudflare"],int) and g["quad9"] is None and "system" not in c and "custom" not in c and r["via"]'
cl -X PUT "$U/proxies/Global" -d "{\"name\":\"$dns_bench_global_before\"}" >/dev/null

echo "== 10. 检查更新 (本机模拟的版本源)"
rm -f "$W/h/update.json"
api "$A/api/update/check?force=1" | chk "发现新版本 9.9.9 + 中文更新说明 + 核心也有新版" 'assert d["available"] and d["latest"]=="9.9.9" and "测试更新说明" in d["notes"] and d["core"]["available"] and d["core"]["latest"]=="99.0.0" and d["error"]==""'
api -H 'X-Enana-Lang: en' "$A/api/update/check" | chk "英文请求拿到英文更新说明" 'assert "Test release notes" in d["notes"]'
api "$A/api/state" | chk "state 里带更新摘要" 'assert d["update"]["available"] and d["update"]["latest"]=="9.9.9"'
api -X POST "$A/api/update/apply?what=nope" | chk "update/apply 参数无效 → 被拒" 'assert not d["ok"]'
curl -s -X POST "http://127.0.0.1:$A_PORT/_test/mode?m=ok" >/dev/null
ENANA_UPDATE_BASE=http://127.0.0.1:1 api "$A/api/update/check?force=1" >/dev/null   # (环境变量只对 curl 无效, 这里只是确保不崩)

echo "== 11. 本机 IP + 多线路测速 (本机模拟的互联网; 节点 = 本机第二个 sing-box 的 socks)"
api "$A/api/net/info" | chk "还没查过: checked=0" 'assert d["ok"] and d["checked"]==0'
J=$(api -X POST "$A/api/net/refresh" | jp 'print(d["job"])'); [ "$(job_wait "$J")" = done ] && tpass "IP 查询任务完成" || tfail "IP 查询任务完成"
api "$A/api/net/info" | chk "本机直连 IP 查到 + 两条线路 (固定出口不通 → ok:false + reason) + 状态" 'assert d["checked"]>0 and d["direct"]["ok"] and d["direct"]["ip"]=="203.0.113.9" and d["direct"]["country"]=="TL" and len(d["routes"])==2 and d["state"] in ("normal","limited","blocked") and d["lan"]["ip"]!=None'
api "$A/api/speedtest/plan" | chk "测速计划: 目标 + 节点 + 默认选择 + 估算" 'assert d["node_available"] and len(d["targets"])==4 and any(n["tag"]=="Local-Hop" for n in d["nodes"]) and "Fix-Pin" in d["defaults"]["nodes"] and d["est"]["seconds"]>10'
api -X POST "$A/api/speedtest/start" -d 'mode=node&nodes=No-Such-Node&speed=0' | chk "节点不存在 → E_NO_SERVERS" 'assert d["code"]=="E_NO_SERVERS"'
api -X POST "$A/api/speedtest/start" -d 'mode=sideways' | chk "模式无效 → 被拒" 'assert not d["ok"]'
api -X POST "$A/api/speedtest/start" -d 'targets=a;b' | chk "目标含非法字符 → 被拒" 'assert not d["ok"]'
R=$(api -X POST "$A/api/speedtest/start" -d 'mode=both&speed=1&nodes=Local-Hop')
echo "$R" | chk "开始测速 → 返回任务 id" 'assert d["ok"] and d["id"].startswith("st-")'
ST=$(echo "$R" | jp 'print(d["id"])')
api -X POST "$A/api/speedtest/start" -d 'mode=direct&speed=0' | chk "已有测速在运行 → E_RUNNING" 'assert d["code"]=="E_RUNNING"'
for i in $(seq 1 120); do sleep 0.5; S=$(api "$A/api/speedtest/status?id=$ST" | jp 'print(d["state"])'); [ "$S" != running ] && break; done
[ "$S" = done ] && tpass "测速在时限内完成" || tfail "测速在时限内完成 (状态 $S)"
api "$A/api/speedtest/status?id=$ST" > "$W/st.json"
cat "$W/st.json" | chk "列 = 本地直连 + Local-Hop; 行 = 4 个目标; 单元格齐全" 'assert [r["id"] for r in d["routes"]]==["direct","Local-Hop"] and len(d["targets"])==4 and len(d["cells"])==8 and not [c for c in d["cells"] if c["st"]=="pending"]'
cat "$W/st.json" | chk "直连: 正常站 ok · 慢站 slow · 受限站 limited · 不通的站 fail(refused)" 'c={(x["t"],x["r"]):x for x in d["cells"]}; assert c[("t_ok","direct")]["st"]=="ok" and c[("t_slow","direct")]["st"]=="slow" and c[("t_slow","direct")]["ms"]>=800 and c[("t_lim","direct")]["st"]=="limited" and c[("t_lim","direct")]["http"]==403 and c[("t_dead","direct")]["st"]=="fail" and c[("t_dead","direct")]["err"]=="refused"'
cat "$W/st.json" | chk "经节点 (Local-Hop): 同样的结果 — 说明流量确实走了被测节点的入站" 'c={(x["t"],x["r"]):x for x in d["cells"]}; assert c[("t_ok","Local-Hop")]["st"]=="ok" and c[("t_lim","Local-Hop")]["st"]=="limited" and c[("t_dead","Local-Hop")]["st"]=="fail"'
cat "$W/st.json" | chk "下载速度: 直连 cn+global, 节点 global; 都 > 0" 's={(x["r"],x["kind"]):x["kbps"] for x in d["speeds"]}; assert s[("direct","cn")]>0 and s[("direct","global")]>0 and s[("Local-Hop","global")]>0'
cat "$W/st.json" | chk "汇总: best / 平均延迟 / 成功数" 'sm=d["summary"]; assert sm["best"]=="Local-Hop" and sm["ok"]["direct"]==2 and sm["total"]["direct"]==4 and sm["limited"]["direct"]==1 and sm["avg_ms"]["direct"]>0'
cat "$W/st.json" | chk "IP 状态: limited (受限站 + 不通) 且带说明" 'assert d["ip"]["state"] in ("limited","blocked") and d["ip"]["direct"]["ok"]'
cat "$W/st.json" | chk "进度 100% · 有耗时" 'assert d["pct"]==100 and d["elapsed"]>=1'
api "$A/api/speedtest/last" | chk "last 返回最近一次结果 (同一个 id)" 'assert d["id"]=="'"$ST"'" and d["state"]=="done"'
cl "$U/proxies/SPEEDTEST" | chk "测速结束后 SPEEDTEST 选择器已还原为 direct" 'assert d["now"]=="direct"'
R=$(api -X POST "$A/api/speedtest/start" -d 'mode=direct&speed=0'); ST2=$(echo "$R" | jp 'print(d["id"])')
api -X POST "$A/api/speedtest/stop?id=$ST2" | chk "停止测速" 'assert d["ok"]'
sleep 2; api "$A/api/speedtest/status?id=$ST2" | chk "停止后状态为 stopped" 'assert d["state"] in ("stopped","done")'
api "$A/api/speedtest/status?id=bogus" | chk "任务编号无效 → E_NOT_FOUND" 'assert d["code"]=="E_NOT_FOUND"'

echo "== 6b. 测速目标管理 (内置可隐藏 / 修改 / 恢复; 自己添加的可改可删; 一键还原)"
stg() { api "$A/api/speedtest/targets"; }
stp() { api -X POST "$A/api/speedtest/targets" "$@"; }
stg | chk "目标列表: 内置目标带 builtin / default / modified / hidden 标记, 分组正确" 'by={x["id"]:x for x in d["targets"]}; assert len(d["targets"])==4 and by["t_ok"]["builtin"] and by["t_ok"]["default"] and not by["t_ok"]["modified"] and not by["t_ok"]["hidden"] and d["groups"]==["global","cn","carrier","dev","media"] and d["hidden"]==0 and d["custom"]==0 and by["t_ok"]["expect"]=="204"'
stp --data-urlencode "name=坏地址" --data-urlencode "group=global" --data-urlencode "url=ftp://x.example/a" | chk "添加: 不是 http(s) 的网址 → 被拒并说明原因" 'assert not d["ok"] and d["code"]=="E_INVALID" and "网址" in d["error"]'
stp --data-urlencode "name=带空格" --data-urlencode "group=global" --data-urlencode "url=http://x.example/a b" | chk "添加: 网址里有空格 → 被拒" 'assert not d["ok"]'
stp --data-urlencode "name=带换行" --data-urlencode "group=global" --data-urlencode "url=http://x.example/a
b|evil" | chk "添加: 网址里有换行 / 竖线 → 被拒 (不能写坏配置文件)" 'assert not d["ok"]'
stp --data-urlencode "name=$(printf 'x%.0s' $(seq 1 41))" --data-urlencode "group=global" --data-urlencode "url=http://x.example/" | chk "添加: 名称超过 40 个字符 → 被拒" 'assert not d["ok"] and "40" in d["error"]'
stp --data-urlencode "name=$(printf '测%.0s' $(seq 1 40))" --data-urlencode "group=global" --data-urlencode "url=http://x.example/" | chk "添加: 名称正好 40 个汉字 → 允许 (按字符数不按字节数)" 'assert d["ok"]'
stp --data-urlencode "name=a|b" --data-urlencode "group=global" --data-urlencode "url=http://x.example/" | chk "添加: 名称里有 | → 被拒" 'assert not d["ok"]'
stp --data-urlencode "name=分组错" --data-urlencode "group=nope" --data-urlencode "url=http://x.example/" | chk "添加: 分组无效 → 被拒" 'assert not d["ok"] and "分组" in d["error"]'
stp --data-urlencode "name=码错" --data-urlencode "group=cn" --data-urlencode "url=http://x.example/" --data-urlencode "expect=abc" | chk "添加: 状态码格式不对 → 被拒" 'assert not d["ok"] and "状态码" in d["error"]'
R=$(stp --data-urlencode "name=我的站点" --data-urlencode "group=cn" --data-urlencode "url=http://127.0.0.1:$N_PORT/204" --data-urlencode "expect=204" --data-urlencode "icon=globe"); UID1=$(echo "$R" | jp 'print(d["id"])')
echo "$R" | chk "添加自己的目标: 返回 u- 开头的编号" 'assert d["ok"] and d["id"].startswith("u-")'
stg | chk "目标列表里出现它: builtin=false, default=true" 'by={x["id"]:x for x in d["targets"]}; x=by["'"$UID1"'"]; assert not x["builtin"] and x["default"] and x["name"]=="我的站点" and x["group"]=="cn" and x["expect"]=="204"'
api "$A/api/speedtest/plan" | chk "测速计划里也有它, 并带 default" 'by={x["id"]:x for x in d["targets"]}; assert by["'"$UID1"'"]["default"] is True and len(d["targets"])==6'
stp --data-urlencode "id=$UID1" --data-urlencode "name=我的站点 (改)" --data-urlencode "group=dev" --data-urlencode "url=http://127.0.0.1:$N_PORT/204" --data-urlencode "expect=204,200" | chk "修改自己的目标" 'assert d["ok"] and d["id"]=="'"$UID1"'"'
stg | chk "修改生效: 名称 / 分组 / 状态码都变了" 'by={x["id"]:x for x in d["targets"]}; x=by["'"$UID1"'"]; assert x["name"]=="我的站点 (改)" and x["group"]=="dev" and x["expect"]=="204,200"'
stp --data-urlencode "id=nope-1" --data-urlencode "name=x" --data-urlencode "group=cn" --data-urlencode "url=http://x.example/" | chk "修改不存在的目标 → 被拒" 'assert not d["ok"]'
stp --data-urlencode "id=Bad_ID" --data-urlencode "name=x" --data-urlencode "group=cn" --data-urlencode "url=http://x.example/" | chk "目标编号含非法字符 → 被拒" 'assert not d["ok"]'
stp --data-urlencode "id=t_ok" --data-urlencode "name=改过的正常站" --data-urlencode "group=global" --data-urlencode "url=http://127.0.0.1:$N_PORT/204" --data-urlencode "expect=204" | chk "修改内置目标 = 保存一份覆盖 (id 不变)" 'assert d["ok"] and d["id"]=="t_ok"'
stg | chk "内置目标显示 modified=true, 仍然 builtin" 'by={x["id"]:x for x in d["targets"]}; x=by["t_ok"]; assert x["modified"] and x["builtin"] and x["name"]=="改过的正常站"'
api -X POST "$A/api/speedtest/targets/delete" -d 'id=t_dead' | chk "删除内置目标 = 隐藏" 'assert d["ok"]'
stg | chk "已隐藏的内置目标仍在列表里 (hidden=true), 计数 hidden=1 custom=2" 'by={x["id"]:x for x in d["targets"]}; assert by["t_dead"]["hidden"] and d["hidden"]==1 and d["custom"]==2'
api "$A/api/speedtest/plan" | chk "测速计划不含已隐藏的目标" 'assert "t_dead" not in [x["id"] for x in d["targets"]]'
R=$(api -X POST "$A/api/speedtest/start" -d 'mode=direct&speed=0'); ST3=$(echo "$R" | jp 'print(d["id"])')
for i in $(seq 1 120); do sleep 0.5; S=$(api "$A/api/speedtest/status?id=$ST3" | jp 'print(d["state"])'); [ "$S" != running ] && break; done
api "$A/api/speedtest/status?id=$ST3" | chk "不指定目标时只测未隐藏的 (含自己添加的, 不含 t_dead), 自己添加的目标测通" 'ids=[t["id"] for t in d["targets"]]; c={x["t"]:x["st"] for x in d["cells"] if x["r"]=="direct"}; assert "t_dead" not in ids and "'"$UID1"'" in ids and "t_ok" in ids and c["'"$UID1"'"]=="ok"'
api -X POST "$A/api/speedtest/targets/restore" -d 'id=t_dead' | chk "恢复被隐藏的内置目标" 'assert d["ok"]'
api -X POST "$A/api/speedtest/targets/restore" -d 'id=t_ok' | chk "恢复被修改的内置目标 (撤销修改)" 'assert d["ok"]'
stg | chk "恢复后: 不再隐藏 / 不再是已修改, 名称回到内置" 'by={x["id"]:x for x in d["targets"]}; assert not by["t_dead"]["hidden"] and not by["t_ok"]["modified"] and by["t_ok"]["name"]=="正常站" and d["hidden"]==0'
api -X POST "$A/api/speedtest/targets/restore" -d "id=$UID1" | chk "恢复接口不接受自己添加的目标 → 被拒" 'assert not d["ok"]'
api -X POST "$A/api/speedtest/targets/delete" -d "id=$UID1" | chk "删除自己添加的目标 = 直接删除" 'assert d["ok"]'
stg | chk "已删除的目标不再出现" 'assert "'"$UID1"'" not in [x["id"] for x in d["targets"]] and d["custom"]==1'
api -X POST "$A/api/speedtest/targets/delete" -d "id=$UID1" | chk "再次删除 → 找不到" 'assert not d["ok"] and d["code"]=="E_NOT_FOUND"'
stat -f %Lp "$W/h/speedtest-custom.tsv" 2>/dev/null | grep -qx 600 && tpass "自定义目标文件权限 600" || tfail "自定义目标文件权限 600"
api -X POST "$A/api/speedtest/targets/reset" | chk "一键还原" 'assert d["ok"]'
stg | chk "还原后: 只剩 4 个内置目标, 没有任何覆盖 / 隐藏 / 自定义" 'assert len(d["targets"])==4 and d["hidden"]==0 and d["custom"]==0 and not any(x["modified"] or x["hidden"] or not x["builtin"] for x in d["targets"])'
expect "还原后自定义文件已删除" test ! -e "$W/h/speedtest-custom.tsv"
api -H 'X-Enana-Lang: en' "$A/api/speedtest/targets" | chk "英文界面: 内置目标显示英文名" 'by={x["id"]:x for x in d["targets"]}; assert by["t_ok"]["name"]=="OK site"'
cl "$U/proxies/SPEEDTEST" | chk "停止后选择器仍还原" 'assert d["now"]=="direct"'

echo "== 12. 国际化 (终端 + 接口 + 静态目录)"
cat "$W/h/ui/catalog.en.json" | chk "英文目录 catalog.en.json: 名称 / 说明 / 分组名都已翻译, 没有残留中文" 'import re; t=open("'"$W"'/h/ui/catalog.en.json",encoding="utf-8").read(); assert not re.search(r"[\u4e00-\u9fff]", t) and "Fixed exit" in t and d["schema"]==3'
cat "$W/h/ui/catalog.json" | chk "中文目录 catalog.json 保持中文" 'import re; t=open("'"$W"'/h/ui/catalog.json",encoding="utf-8").read(); assert re.search(r"[\u4e00-\u9fff]", t)'
api -H 'X-Enana-Lang: en' "$A/api/rules" | chk "规则库接口按语言翻译名称 / 说明 (英文无中文残留)" 'import re; t=json.dumps(d,ensure_ascii=False); assert not re.search(r"[\u4e00-\u9fff]", t), re.findall(r"[^\"]*[\u4e00-\u9fff][^\"]*", t)[:3]'
api -H 'X-Enana-Lang: en' "$A/api/dns" | chk "DNS 接口按语言翻译 (预设名称 / 解析流程说明)" 'import re; t=json.dumps(d,ensure_ascii=False); assert not re.search(r"[\u4e00-\u9fff]", t), re.findall(r"[^\"]*[\u4e00-\u9fff][^\"]*", t)[:3]'
ENANA_LANG=en "$W/shortcut/enana" status > "$W/status.en" 2>&1
expect "终端 status 英文输出没有中文" python3 -c "import re,sys; sys.exit(1 if re.search(r'[\u4e00-\u9fff]', open('$W/status.en',encoding='utf-8').read()) else 0)"
ENANA_LANG=en "$W/shortcut/enana" doctor > "$W/doctor.en" 2>&1; expect "终端 doctor 英文输出里没有残留的中文提示" python3 -c "import re,sys; t=open('$W/doctor.en',encoding='utf-8').read(); sys.exit(1 if re.search(r'[\u4e00-\u9fff]', t) else 0)"
api -H 'X-Enana-Lang: en' "$A/api/override?kind=site&value=a%20b&state=direct" -X POST | chk "接口错误按语言头翻译成英文" 'assert not d["ok"] and "Invalid" in d["error"] or "invalid" in d["error"].lower() or "format" in d["error"].lower()'
ENANA_LANG=en "$W/shortcut/enana" help | grep -q 'Restart\|restart' && tpass "终端帮助可显示英文" || tfail "终端帮助可显示英文"
ENANA_LANG=zh "$W/shortcut/enana" help | grep -q '重启' && tpass "终端帮助可显示中文" || tfail "终端帮助可显示中文"
J=$(api -H 'X-Enana-Lang: en' -X POST "$A/api/restart" | jp 'print(d["job"])'); job_wait "$J" >/dev/null
api "$A/api/job?id=$J" | chk "任务进度按语言头翻译 (英文步骤名)" 'assert d["steps"][0]["label"]=="Restarting the service" or d["steps"][0]["label"]!="重启服务"'
api -X POST "$A/api/settings" -d 'lang=en' >/dev/null; grep -q '^LANG_UI=en' "$W/h/settings.env" && tpass "语言选择已保存到 settings.env (终端与仪表盘共用)" || tfail "语言选择已保存"
api -X POST "$A/api/settings" -d 'lang=zh' >/dev/null

echo "== 13. 退出账号 = 关闭代理 (仪表盘 + 终端) · 终端没登录时不能开启代理"
OLD=$TOKEN
api "$A/api/state" | chk "退出前: 代理已开启 (按规则分流)" 'assert d["proxy"]["enabled"] is True'
sudo_tok >/dev/null; expect "退出前有 sudo 令牌文件" test -s "$W/h/sudo.tokens"
api -X POST "$A/api/logout" | chk "仪表盘退出账号" 'assert d["ok"]'
wait_clash_401 "$OLD"
expect "退出后: sudo 令牌全部清除" test ! -e "$W/h/sudo.tokens"
expect "退出后: 旧令牌失效 (辅助服务 401)" test "$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' -H "$X" -H "X-Enana-Token: $OLD" $A/api/state)" = 401
expect "退出后: 旧令牌失效 (Clash API 401)" test "$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' -H "Authorization: Bearer $OLD" $U/proxies)" = 401
expect "退出后: 设置里代理总开关 = 0, 磁盘配置 default_mode = Direct" sh -c "grep -q '^PROXY_ENABLED=0' '$W/h/settings.env' && grep -q '\"default_mode\":\"Direct\"' '$W/h/config.json'"
expect "退出后: 核心仍在监听 (系统代理指向它也不会断网)" nc -z 127.0.0.1 "$PORT"
R=$(login user1@example.test 'New-Passw0rd2'); TOKEN=$(echo "$R" | jp 'print(d["token"])'); [ "$TOKEN" != "$OLD" ] && tpass "重新登录拿到新令牌" || tfail "重新登录拿到新令牌"
cl "$U/configs" | chk "重新登录后代理仍是关闭的 (必须手动在仪表盘里开启)" 'assert d["mode"]=="Direct"'
api "$A/api/state" | chk "state.proxy.enabled 仍为 false" 'assert d["proxy"]["enabled"] is False'
if "$W/shortcut/enana" status 2>&1 | grep -q '已登录'; then tpass "终端 status 显示已登录"; else tfail "终端 status 显示已登录"; fi
api -X POST "$A/api/proxy" -d 'on=1' >/dev/null
echo y | "$W/shortcut/enana" logout >/dev/null 2>&1; sleep 3
expect "终端 enana logout: 登录状态与离线缓存都被清除" test ! -e "$W/h/loggedin" -a ! -e "$W/h/account.conf"
expect "终端 enana logout: 代理被关闭" grep -q '^PROXY_ENABLED=0' "$W/h/settings.env"
"$W/shortcut/enana" on >"$W/on.out" 2>&1; expect "没登录时终端 enana on 被拒绝并提示先登录" grep -q '还没有登录' "$W/on.out"
expect "被拒绝的 enana on 没有改变代理状态" grep -q '^PROXY_ENABLED=0' "$W/h/settings.env"
curl -s -X POST "http://127.0.0.1:$A_PORT/_test/mode?m=down" >/dev/null
login user1@example.test 'New-Passw0rd2' | chk "清除缓存后又连不上 enana.cc: 不能登录 (E_ACCOUNT_UNREACHABLE)" 'assert d["code"]=="E_ACCOUNT_UNREACHABLE"'
curl -s -X POST "http://127.0.0.1:$A_PORT/_test/mode?m=ok" >/dev/null
TOKEN=$(login user1@example.test 'New-Passw0rd2' | jp 'print(d["token"])'); [ -n "$TOKEN" ] && tpass "在线后可再次登录" || tfail "在线后可再次登录"
"$W/shortcut/enana" on >"$W/on.out" 2>&1; expect "登录之后终端 enana on 可以开启代理" grep -q '^PROXY_ENABLED=1' "$W/h/settings.env"
api -X POST "$A/api/proxy" -d 'on=0' >/dev/null

echo "== 14. 重复运行安装器 / 升级模式: 不重装 / 不重启 / 不要密码 / 不动系统代理"
bash "$REPO/install.sh" apply >/dev/null 2>&1; sleep 1.5      # 回到默认日志级别 (前面为了看路由日志用了 debug)
: > "$FAKE_STATE/calls.log"; PID=$(cat "$FAKE_STATE/pid-com.enana.proxy")
cp "$W/h/config.json" "$W/reinstall-before.json"
cp -R "$ENANA_PLIST_DIR" "$W/reinstall-plists-before"
bash "$REPO/install.sh" --yes > "$W/reinstall.out" 2>&1
cp "$W/h/config.json" "$W/reinstall-after.json"
cp "$FAKE_STATE/calls.log" "$W/reinstall-calls.log"
cp -R "$ENANA_PLIST_DIR" "$W/reinstall-plists-after"
expect "核心没有被重启" test "$PID" = "$(cat "$FAKE_STATE/pid-com.enana.proxy")"
expect "没有调用 sudo (不再要密码)" test "$(grep -c '^sudo' "$FAKE_STATE/calls.log")" = 0
expect "没有改动系统代理" test "$(grep -c 'networksetup -set' "$FAKE_STATE/calls.log")" = 0
expect "账号绑定与令牌在重装后保留" test "$TOKEN" = "$(cat "$W/h/secret")"
rm -f "$FAKE_STATE/sysproxy-on"; : > "$FAKE_STATE/calls.log"
OUT=$(ENANA_PROGRESS=1 bash "$REPO/install.sh" --upgrade 2>&1 | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g')
echo "$OUT" | grep -q '已升级到 enana' && tpass "升级模式: 不弹菜单, 直接完成" || tfail "升级模式: 不弹菜单, 直接完成"
echo "$OUT" | grep -q '^##job 2 ' && tpass "升级模式输出任务进度标记 (供仪表盘更新进度条)" || tfail "升级模式输出任务进度标记"
expect "升级不会重新打开用户关掉的系统代理" test "$(grep -c 'networksetup -set' "$FAKE_STATE/calls.log")" = 0
touch "$FAKE_STATE/sysproxy-on"

echo "== 15. 每日维护: 日志切分 / 压缩 / 按保留期清理"
mkdir -p "$W/h/logs"; OLDD=$(date -v-100d +%F); MID=$(date -v-10d +%F)
printf '%s 00:00:00\tdashboard\t旧记录\t.\tok\n' "$OLDD" > "$W/h/logs/ops-$OLDD.log"; printf '%s 00:00:00\tdashboard\t较新记录\t.\tok\n' "$MID" > "$W/h/logs/ops-$MID.log"
printf '+0800 %s 01:02:03 INFO [1 0ms] inbound/mixed[in]: inbound connection to a.example:443\n' "$OLDD" > "$W/h/logs/proxy-$OLDD.log"
api -X POST "$A/api/settings" -d 'log_hours=720' >/dev/null
"$W/shortcut/enana" maintain --quiet >/dev/null 2>&1
expect "超过保留期 (100 天前) 的日志被清理" test ! -e "$W/h/logs/ops-$OLDD.log" -a ! -e "$W/h/logs/proxy-$OLDD.log"
expect "保留期内 (10 天前) 的日志被压缩保留" test -e "$W/h/logs/ops-$MID.log.gz"
api "$A/api/logs?type=ops&day=$MID" | chk "压缩过的日志仍可在仪表盘查询" 'assert d["total"]==1 and d["rows"][0]["action"]=="较新记录"'
api -X POST "$A/api/settings" -d 'log_hours=720' >/dev/null; printf '%s 00:00:00\tdashboard\t二十天前\t.\tok\n' "$(date -v-20d +%F)" > "$W/h/logs/ops-$(date -v-20d +%F).log"; printf '%s 00:00:00\tdashboard\t四十天前\t.\tok\n' "$(date -v-40d +%F)" > "$W/h/logs/ops-$(date -v-40d +%F).log"; "$W/shortcut/enana" maintain --quiet >/dev/null 2>&1
expect "保留期 30 天 (720 小时): 20 天前的日志被保留, 40 天前的被清理" sh -c "{ test -e '$W/h/logs/ops-$(date -v-20d +%F).log.gz' -o -e '$W/h/logs/ops-$(date -v-20d +%F).log'; } && test ! -e '$W/h/logs/ops-$(date -v-40d +%F).log' -a ! -e '$W/h/logs/ops-$(date -v-40d +%F).log.gz'"

echo "== 16. 卸载"
cp -R "$W/h/rules" "$W/rules-keep"
mkdir -p "$W/h/user-fixture" "$W/h/backups/old" "$W/h/certs" "$W/h/logs"
printf 'placeholder user data\n' > "$W/h/user-fixture/private"
printf 'keep this unrelated setting\n# enana 快捷命令\nexport PATH="$HOME/.local/bin:$PATH"\n' > "$HOME/.zshrc"
"$W/shortcut/enana" uninstall --yes >/dev/null 2>&1; sleep 3.5
expect "快捷命令已移除" test ! -e "$W/shortcut/enana"
expect "系统代理已(假)关闭" test ! -f "$FAKE_STATE/sysproxy-on"
expect "安装目录已删除" test ! -d "$W/h"
expect "本机账号、节点、设置、备份与证书目录全部随安装目录删除" test ! -e "$W/h/user-fixture" -a ! -e "$W/h/backups" -a ! -e "$W/h/certs" -a ! -e "$W/h/settings.env"
expect "shell 配置只清除 enana 标记, 保留其它设置" sh -c "grep -q 'unrelated setting' '$HOME/.zshrc' && ! grep -q 'enana 快捷命令' '$HOME/.zshrc'"
expect "全部用户 launchd plist 已移除" test ! -e "$ENANA_PLIST_DIR/com.enana.proxy.plist" -a ! -e "$ENANA_PLIST_DIR/com.enana.proxy.api.plist" -a ! -e "$ENANA_PLIST_DIR/com.enana.proxy.update.plist" -a ! -e "$ENANA_PLIST_DIR/com.enana.proxy.tick.plist"

echo "== 17. 旧版迁移 (~/.tokyo-proxy + launchd 标签 local.tokyo-proxy*) → ~/.enana"
mkdir -p "$HOME/.tokyo-proxy/certs" "$HOME/.local/bin"
printf '{"role":"auto","outbound":{"type":"socks","tag":"Legacy-Node","server":"127.0.0.1","server_port":3,"version":"5"}}\n' > "$HOME/.tokyo-proxy/servers.jsonl"; chmod 600 "$HOME/.tokyo-proxy/servers.jsonl"
printf 'PORT=%s\nUI_PORT=%s\nAPI_PORT=%s\n' "$PORT" "$UI_PORT" "$API_PORT" > "$HOME/.tokyo-proxy/settings.env"
touch "$HOME/.tokyo-proxy/tproxy" "$FAKE_STATE/loaded-local.tokyo-proxy" "$ENANA_PLIST_DIR/local.tokyo-proxy.plist"; ln -sf "$HOME/.tokyo-proxy/tproxy" "$HOME/.local/bin/tproxy"
printf '\n# tproxy 快捷命令\nexport PATH="$HOME/.local/bin:$PATH"\n' > "$HOME/.zshrc"
cp "$SB" "$HOME/.tokyo-proxy/sing-box"; cp -R "$W/rules-keep" "$HOME/.tokyo-proxy/rules"
bash "$REPO/install.sh" --yes >/dev/null 2>&1
expect "旧数据目录已迁移 (servers.jsonl 原样保留)" sh -c "grep -q Legacy-Node '$W/h/servers.jsonl' && test ! -d '$HOME/.tokyo-proxy'"
expect "旧 launchd 任务与 plist 已清理" test ! -e "$FAKE_STATE/loaded-local.tokyo-proxy" -a ! -e "$ENANA_PLIST_DIR/local.tokyo-proxy.plist"
expect "旧快捷命令 tproxy 与 shell 配置标记行已清理" sh -c "test ! -e '$HOME/.local/bin/tproxy' && ! grep -q 'tproxy 快捷命令' '$HOME/.zshrc'"
expect "迁移后的安装可用 (代理在监听, 迁移来的节点已进入配置)" sh -c "nc -z 127.0.0.1 $PORT && grep -q Legacy-Node '$W/h/config.json'"
"$W/shortcut/enana" uninstall --yes >/dev/null 2>&1; sleep 3.5

echo "== 18. 单元测试 (tests/units.sh: 日志解析 / 自动识别 / 保留期 / 应用扫描 / 规则集拆分 / 诊断导出)"
bash "$HERE/units.sh" > "$W/units.out" 2>&1
grep -E '^==|^  ✗|^      ↳' "$W/units.out"
UP=$(grep -c '^  ✓' "$W/units.out"); UF=$(grep -c '^  ✗' "$W/units.out")
echo "  (单元测试 $UP 项通过, $UF 项失败)"
[ "${UP:-0}" -ge 80 ] || { echo "  ✗ 单元测试通过数异常 ($UP), 见 $W/units.out"; echo f >> "$W/.fail"; }
_i=0; while [ "$_i" -lt "${UP:-0}" ]; do echo p >> "$W/.pass"; _i=$((_i+1)); done; _i=0; while [ "$_i" -lt "${UF:-0}" ]; do echo f >> "$W/.fail"; _i=$((_i+1)); done      # (BSD 的 seq 1 0 会倒数, 所以不用 seq)

echo "== 19. Enhanced/TUN isolated regressions"
if SINGBOX="$SB" bash "$HERE/enhanced.sh" > "$W/enhanced.out" 2>&1; then tpass "System/TUN schema, exclusions, PIN priority and socket evidence"; else tfail "Enhanced config regression"; cat "$W/enhanced.out"; fi
if bash "$HERE/tun-service.sh" > "$W/tun-service.out" 2>&1; then tpass "Root snapshot rollback and route ownership"; else tfail "TUN service regression"; cat "$W/tun-service.out"; fi
if bash "$HERE/vps-probe.sh" > "$W/vps-probe.out" 2>&1; then tpass "Read-only SSH retries, cancellation and launch failure"; else tfail "SSH detection lifecycle regression"; cat "$W/vps-probe.out"; fi
if command -v node >/dev/null; then
  if node "$HERE/ui-busy.test.js" > "$W/ui-busy.out" 2>&1; then tpass "Async UI buttons and modal duplicate submissions"; else tfail "UI busy regression"; cat "$W/ui-busy.out"; fi
  if node "$HERE/network-mode-ui.test.js" > "$W/network-mode-ui.out" 2>&1; then tpass "App capture onboarding, cancellation and readiness"; else tfail "Capture onboarding regression"; cat "$W/network-mode-ui.out"; fi
  if node "$HERE/vps-ui.test.js" > "$W/vps-ui.out" 2>&1; then tpass "SSH wizard cancellation and failed-cancel races"; else tfail "SSH wizard lifecycle regression"; cat "$W/vps-ui.out"; fi
  if node "$HERE/app-refresh-ui.test.js" > "$W/app-refresh-ui.out" 2>&1; then tpass "Quiet app discovery and visibility/reload cadence"; else tfail "App refresh lifecycle regression"; cat "$W/app-refresh-ui.out"; fi
fi

PASSES=$(cat "$W/.pass" 2>/dev/null | wc -l | tr -d ' '); FAILS=$(cat "$W/.fail" 2>/dev/null | wc -l | tr -d ' ')
echo; echo "结果: $PASSES 通过, $FAILS 失败"; [ "$FAILS" = 0 ]
