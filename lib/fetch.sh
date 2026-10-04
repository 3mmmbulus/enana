# 下载链: 直连 -> 本地代理 -> 用户配置的 http/socks 服务器 -> (仅核心, 且有 SHA-256 校验时) 镜像。
# 任何一条线路超时/过慢/校验失败都会自动换下一条, 全部失败才报错。依赖 common.sh servers.sh jobs.sh。

CURL_BASE="-fL --connect-timeout 8 --speed-limit 10240 --speed-time 15 --max-time 900"

# DL_SPEED (字节/秒, 可选): 比 CURL_BASE 更严的最低速度, 连续 DL_SPEED_TIME 秒低于它就放弃当前源换下一个。
# 用在「还有备用源」的下载上: GitHub 在国内常常只有十几 KB/s, 高于 10 KB/s 的默认下限, 会白白等满 900 秒。
_dl() { # url out [代理URL] [user:pass]
  local url=$1 out=$2 px=${3:-} auth=${4:-} bar=-sS ms='' sp=''
  if [ -t 2 ] && [ -z "${QUIET:-}" ]; then bar=--progress-bar; fi
  [ -n "${DL_MAXSIZE:-}" ] && ms="--max-filesize $DL_MAXSIZE"
  [ -n "${DL_SPEED:-}" ] && sp="--speed-limit $DL_SPEED --speed-time ${DL_SPEED_TIME:-20}"
  if [ -n "$px" ]; then
    if [ -n "$auth" ]; then curl $CURL_BASE $sp $ms $bar -x "$px" --proxy-user "$auth" -o "$out" "$url"
    else curl $CURL_BASE $sp $ms $bar -x "$px" -o "$out" "$url"; fi
  else
    curl $CURL_BASE $sp $ms $bar --noproxy '*' -o "$out" "$url"
  fi
}

dl_routes() { # 每行: 标签|代理URL|user:pass
  printf '直连||\n'
  if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then printf '本地代理(自动选线)|http://127.0.0.1:%s|\n' "$PORT"; fi
  srv_curl_routes 2>/dev/null || true
}

# fetch_any 输出文件 校验函数 URL...   线路(外层) × URL(内层) 依次尝试; 成功设置 DL_VIA
fetch_any() {
  local out=$1 validator=$2 label px auth url tmp; shift 2
  tmp="$out.part"
  while IFS='|' read -r label px auth; do
    [ -n "$label" ] || continue
    for url in "$@"; do
      rm -f "$tmp"
      info "尝试 [$label] ${url%%\?*}"
      if _dl "$url" "$tmp" "$px" "$auth"; then
        if [ -s "$tmp" ] && "$validator" "$tmp"; then mv "$tmp" "$out"; DL_VIA=$label; return 0; fi
        warn "下载内容校验未通过 (可能是错误页面或被篡改), 已丢弃, 换下一条线路"
      fi
    done
  done < <(dl_routes)
  rm -f "$tmp"; return 1
}

valid_srs()    { [ "$(head -c 3 "$1" 2>/dev/null)" = SRS ]; }
valid_targz()  { tar -tzf "$1" >/dev/null 2>&1; }
valid_core()   { # 压缩包完整, 且 (若有预置哈希) SHA-256 一致
  valid_targz "$1" || return 1
  [ -z "${EXPECT_SHA:-}" ] && return 0
  [ "$(shasum -a 256 "$1" | awk '{print $1}')" = "$EXPECT_SHA" ]
}

# ---------- sing-box 核心 ----------
core_version() { # 带缓存: 只在二进制更新后才真正运行它 (每次运行 sing-box 在慢机器上要好几秒)
  local f="$H/.core-version" v
  [ -x "$SB" ] || return 1
  if [ -s "$f" ] && ! [ "$SB" -nt "$f" ]; then IFS= read -r v < "$f"; printf '%s\n' "$v"; return 0; fi
  v=$("$SB" version 2>/dev/null | head -1 | awk '{print $3}')
  [ -n "$v" ] && printf '%s\n' "$v" > "$f"
  printf '%s\n' "$v"
}
core_ok() { [ -x "$SB" ] && [ -n "$(core_version)" ]; }

# ---------- 核心备用下载源 + 签名的兼容清单 ----------
# CORE_BASE: 项目自己的核心下载目录, 官方 GitHub 下不动 (太慢 / 连不上) 时作为第二个源。只放有 SHA-256 钉死的版本, 客户端逐个校验, 所以这个目录不需要被信任。
# 兼容清单 core-manifest.conf: 项目测试过、和某段 enana 版本兼容的核心版本, 用云端内容同一把私钥签名 (core-manifest.sig, 内置公钥验签)。
#   后台只会提示清单里「和当前 enana 兼容」的核心更新, 不再直接跟着 GitHub 的 latest 走 (tools/build-core-manifest.sh 生成并签名)。
#   行格式  版本|名称|SHA-256|最低 enana|最高 enana (空 = 不限)    另有一行 seq|N: 只增不减, 防止被换回旧清单。
CORE_BASE=${ENANA_CORE_BASE:-https://install.enana.cc/dl/core}

core_names() { # 这台电脑要找的构建名称 (按优先顺序)。ARCH / MACOS_MAJOR 只在安装时由 os_detect 设置; 仪表盘接口 / 后台任务 / 每日维护进程里没有, 所以缺了就自己判断
  local arch=${ARCH:-} major=${MACOS_MAJOR:-} n
  if [ -z "$arch" ]; then arch=amd64; [ "$(uname -m)" = arm64 ] && arch=arm64; [ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" = 1 ] && arch=arm64; fi      # Rosetta 终端里也选原生版 (同 os_detect)
  if [ -z "$major" ]; then major=$(sw_vers -productVersion 2>/dev/null | cut -d. -f1); case $major in ''|*[!0-9]*) major=14 ;; esac; fi
  n="darwin-$arch"
  if [ "$arch" = amd64 ] && [ "$major" -lt 11 ]; then n="darwin-amd64-legacy-macos-10.13 darwin-amd64"; fi
  printf '%s' "$n"
}
valid_nonempty() { [ -s "$1" ]; }
valid_core_manifest() { [ -s "$1" ] && ! LC_ALL=C grep -q '<html' "$1" && grep -Eq '^seq\|[0-9]+$' "$1"; }
core_manifest_seq() { sed -n 's/^seq|\([0-9][0-9]*\)$/\1/p' "$1" 2>/dev/null | head -1; }
core_manifest_rows() { # 本机保存的、验签通过的清单里的版本行 (没有清单 / 验签失败 = 什么都不输出)
  local f="$H/core-manifest.conf" s="$H/core-manifest.sig"
  [ -s "$f" ] && [ -s "$s" ] && cloud_verify "$f" "$s" || return 0
  grep -E '^[0-9]+(\.[0-9]+)+\|[A-Za-z0-9._-]+\|[0-9a-f]{64}\|' "$f" || true
}
core_manifest_refresh() { # 下载 + 验签 + 防回滚; 拿到了有效且不比本机旧的清单就返回 0
  local t new old
  t=$(mktemp -d)
  if ! { QUIET=1 fetch_any "$t/c" valid_core_manifest "$CORE_BASE/core-manifest.conf" \
      && QUIET=1 fetch_any "$t/s" valid_nonempty "$CORE_BASE/core-manifest.sig"; } >/dev/null 2>&1; then rm -rf "$t"; return 1; fi
  cloud_verify "$t/c" "$t/s" || { rm -rf "$t"; return 1; }
  new=$(core_manifest_seq "$t/c"); old=$(core_manifest_seq "$H/core-manifest.conf")
  if [ -n "$old" ] && [ "${new:-0}" -lt "$old" ]; then rm -rf "$t"; return 1; fi
  mkdir -p "$H"
  cp "$t/c" "$H/core-manifest.conf.new" && cp "$t/s" "$H/core-manifest.sig.new" \
    && mv "$H/core-manifest.sig.new" "$H/core-manifest.sig" && mv "$H/core-manifest.conf.new" "$H/core-manifest.conf"
  local rc=$?; rm -rf "$t"; return $rc
}
core_latest_compat() { # 清单里「适用于这台电脑、且和当前 enana 版本兼容」的最新核心版本 (没有清单 = 空)
  local names best='' v nm min max
  names=$(core_names)
  while IFS='|' read -r v nm _ min max; do
    case " $names " in *" $nm "*) ;; *) continue ;; esac
    if [ -n "$min" ] && version_gt "$min" "$VERSION"; then continue; fi
    if [ -n "$max" ] && version_gt "$VERSION" "$max"; then continue; fi
    if [ -z "$best" ] || version_gt "$v" "$best"; then best=$v; fi
  done < <(core_manifest_rows)
  printf '%s\n' "$best"
}
core_pin_sha() { # <版本> <名称> -> SHA-256: 先查随程序发布的 core-pins.conf (清单不能覆盖它), 再查本机验过签的兼容清单
  local s
  s=$(awk -F'|' -v v="$1" -v s="$2" '$1==v && $2==s {print $3; exit}' "$DATA/core-pins.conf" 2>/dev/null)
  [ -n "$s" ] || s=$(core_manifest_rows | awk -F'|' -v v="$1" -v s="$2" '$1==v && $2==s {print $3; exit}')
  printf '%s\n' "$s"
}
core_latest_version() { # 用 /releases/latest 的跳转拿版本号 (不走 API, 没有限流)
  local r px auth label u
  [ -n "${ENANA_CORE_LATEST:-}" ] && { printf '%s\n' "$ENANA_CORE_LATEST"; return 0; }      # 测试用
  r=$(curl -fsSL -m 12 --noproxy '*' -o /dev/null -w '%{url_effective}' https://github.com/SagerNet/sing-box/releases/latest 2>/dev/null || true)
  if [ -z "$r" ]; then
    while IFS='|' read -r label px auth; do
      [ -n "$px" ] || continue
      if [ -n "$auth" ]; then r=$(curl -fsSL -m 15 -x "$px" --proxy-user "$auth" -o /dev/null -w '%{url_effective}' https://github.com/SagerNet/sing-box/releases/latest 2>/dev/null || true)
      else r=$(curl -fsSL -m 15 -x "$px" -o /dev/null -w '%{url_effective}' https://github.com/SagerNet/sing-box/releases/latest 2>/dev/null || true); fi
      [ -n "$r" ] && break
    done < <(dl_routes)
  fi
  printf '%s\n' "$r" | sed -n 's#.*/tag/v\([0-9][0-9.]*\)$#\1#p'
}

core_urls() { # 名称 版本 有无 SHA-256 钉死(1/0) [fast|all]: 每行一个 URL, 顺序 = 官方发布页 → 项目自己的下载目录 → 第三方 GitHub 镜像
  # 项目自己的目录和第三方镜像都不是官方源: 只在有 SHA-256 钉死时才用, 所以换不成别的文件。fast = 只要前两类 (第一轮快速切换用)。
  local name=$1 ver=$2 pinned=$3 mode=${4:-all} tpl gh m
  while IFS= read -r tpl; do
    case $tpl in ''|'#'*) continue ;; esac
    gh=${tpl//\{ver\}/$ver}; gh=${gh//\{name\}/$name}
    printf '%s\n' "$gh"
  done < "$DATA/core-sources.conf"
  [ "$pinned" = 1 ] || return 0
  printf '%s/%s/sing-box-%s-%s.tar.gz\n' "$CORE_BASE" "$ver" "$ver" "$name"
  [ "$mode" = fast ] && return 0
  while IFS= read -r tpl; do
    case $tpl in ''|'#'*) continue ;; esac
    gh=${tpl//\{ver\}/$ver}; gh=${gh//\{name\}/$name}
    while IFS= read -r m; do
      case $m in ''|'#'*) continue ;; esac
      printf '%s%s\n' "$m" "$gh"
    done < "$DATA/mirrors.conf"
  done < "$DATA/core-sources.conf"
}

_core_try() { # <临时目录> <版本> <名称> <SHA-256|空> <fast|all>  -> 0 = 下载并解出了 $H/sing-box.new
  local tmp=$1 ver=$2 nm=$3 expect=$4 mode=$5 u
  set --; while IFS= read -r u; do set -- "$@" "$u"; done < <(core_urls "$nm" "$ver" "$([ -n "$expect" ] && echo 1 || echo 0)" "$mode")
  if [ "$mode" = fast ]; then
    DL_SPEED=${ENANA_DL_FAST_SPEED:-204800} DL_SPEED_TIME=${ENANA_DL_FAST_TIME:-20} EXPECT_SHA=$expect fetch_any "$tmp/sb.tgz" valid_core "$@" || return 1
  else
    EXPECT_SHA=$expect fetch_any "$tmp/sb.tgz" valid_core "$@" || return 1
  fi
  ok "下载完成 (线路: $DL_VIA)${expect:+, SHA-256 校验通过}"
  tar -xzf "$tmp/sb.tgz" -C "$tmp" || return 1
  cp "$tmp"/sing-box-*/sing-box "$H/sing-box.new" && chmod +x "$H/sing-box.new"
}

core_from_chain() { # -> $H/sing-box.new
  local ver=${SINGBOX_VERSION:-$CORE_PIN} nm expect tmp
  if [ "$ver" = latest ]; then
    ver=$(core_latest_version); [ -n "$ver" ] || { warn "查不到最新版本, 使用已测试版本 $CORE_PIN"; ver=$CORE_PIN; }
  fi
  tmp=$(mktemp -d)
  for nm in $(core_names); do
    expect=$(core_pin_sha "$ver" "$nm")
    info "下载 sing-box $ver ($nm)${expect:+, 将校验 SHA-256}"
    # 有 SHA-256 钉死才有备用源可换。第一轮只试「官方 + 项目自己的目录」, 速度太低 (GitHub 在国内常常只有十几 KB/s) 就立刻换下一个源;
    # 都不行再放宽速度要求, 把全部源 (含第三方镜像) 按慢速也试一遍。
    if { [ -n "$expect" ] && _core_try "$tmp" "$ver" "$nm" "$expect" fast; } || _core_try "$tmp" "$ver" "$nm" "$expect" all; then
      rm -rf "$tmp"; return 0
    fi
  done
  rm -rf "$tmp"; return 1
}

core_from_brew() {
  command -v brew >/dev/null 2>&1 || return 1
  info "通过 Homebrew 安装 sing-box…"
  brew install sing-box >&2 || return 1
  local p; p="$(brew --prefix)/bin/sing-box"
  [ -x "$p" ] && cp "$p" "$H/sing-box.new" && chmod +x "$H/sing-box.new"
}

core_from_local() { # SINGBOX_TGZ 指定, 或在源码目录/下载目录里找
  local f=${SINGBOX_TGZ:-} tmp
  if [ -z "$f" ]; then f=$(ls -1t "$SRC"/sing-box-*darwin*.tar.gz "$HOME"/Downloads/sing-box-*darwin*.tar.gz 2>/dev/null | head -1 || true); fi
  [ -n "$f" ] && [ -f "$f" ] || return 1
  valid_targz "$f" || return 1
  tmp=$(mktemp -d); tar -xzf "$f" -C "$tmp" && cp "$tmp"/sing-box-*/sing-box "$H/sing-box.new" && chmod +x "$H/sing-box.new"
  rm -rf "$tmp"; info "使用本地安装包 $f"
}

core_install() { # core_install chain|brew|local  -> 安装/替换 $H/sing-box
  if [ "${ENANA_PLATFORM:-darwin}" = windows ]; then win_bridge core-upgrade "${SINGBOX_VERSION:-$CORE_PIN}"; return; fi
  local src=${1:-chain}
  rm -f "$H/sing-box.new"
  case $src in
    chain) core_from_chain || { warn "GitHub 下载链全部失败"; command -v brew >/dev/null 2>&1 && core_from_brew; } ;;
    brew)  core_from_brew ;;
    local) core_from_local ;;
  esac || true
  [ -x "$H/sing-box.new" ] || return 1
  xattr -d com.apple.quarantine "$H/sing-box.new" 2>/dev/null || true
  "$H/sing-box.new" version >/dev/null 2>&1 || { rm -f "$H/sing-box.new"; return 2; }
  mv "$H/sing-box.new" "$SB"
}

# ---------- 规则库 (社区规则集) ----------
# rulesets.conf: tag|仓库|分支|远程文件名|名称|说明|essential|默认启用     $H/rules.state: tag=0|1 (用户的启停选择)
# 自定义规则集: $H/custom-rulesets.tsv  tag|名称|策略|时间|链接  (文件 rules/custom-<tag>.srs)
rules_list() { local l; [ -f "$(content_file rulesets.conf)" ] || return 0; while IFS= read -r l; do case $l in ''|'#'*|[[:space:]]*) ;; *) printf '%s\n' "$l" ;; esac; done < "$(content_file rulesets.conf)"; }
rules_wanted() { # 输出「启用」的规则集 (完整行). essential 恒启用; 其余按 rules.state, 没有就用默认
  awk -F'|' -v st="$H/rules.state" 'BEGIN { while ((getline l < st) > 0) { split(l, a, "="); s[a[1]] = a[2] } }
    /^[ \t]*(#|$)/ { next }
    { en = ($8 == "") ? 1 : $8; if ($1 in s) en = s[$1]; if ($7 == 1) en = 1; if (en == 1) print }' "$(content_file rulesets.conf)" 2>/dev/null
}
rules_missing() { local tag _r; while IFS='|' read -r tag _r; do [ -s "$H/rules/$tag.srs" ] || printf '%s\n' "$tag"; done < <(rules_wanted); }
rules_updated_at() { local v; [ -f "$H/rules/.updated" ] && IFS= read -r v < "$H/rules/.updated"; echo "${v:-0}"; }
rules_set_enabled() { # tag 0|1  (essential 不可停用)
  local tag=$1 v=$2 line
  case $v in 0|1) ;; *) return 1 ;; esac
  line=$(rules_list | awk -F'|' -v t="$tag" '$1==t {print; exit}'); [ -n "$line" ] || return 2
  [ "$(printf '%s' "$line" | cut -d'|' -f7)" = 1 ] && [ "$v" = 0 ] && return 3
  touch "$H/rules.state"
  { grep -v "^$tag=" "$H/rules.state" || true; printf '%s=%s\n' "$tag" "$v"; } > "$H/rules.state.new" && mv "$H/rules.state.new" "$H/rules.state"
}

_rules_urls() { # repo branch file -> 每行一个 URL (来源模板见 rule-sources.conf)
  local tpl u
  if [ -n "${ENANA_RULE_SOURCE:-}" ]; then printf '%s\n' "${ENANA_RULE_SOURCE//\{file\}/$3}"; return 0; fi     # 测试用: 指向本机模拟源
  while IFS= read -r tpl; do
    case $tpl in ''|'#'*) continue ;; esac
    u=${tpl//\{repo\}/$1}; u=${u//\{branch\}/$2}; u=${u//\{file\}/$3}; printf '%s\n' "$u"
  done < "$DATA/rule-sources.conf"
}
_rules_fetch_one() { # tag repo branch file outdir  (在后台子进程里运行)
  local tag=$1 repo=$2 branch=$3 file=$4 od=$5 u
  set --; while IFS= read -r u; do set -- "$@" "$u"; done < <(_rules_urls "$repo" "$branch" "$file")
  if fetch_any "$H/rules/$tag.srs.new" valid_srs "$@" > "$od/$tag.log" 2>&1; then printf '%s' "$DL_VIA" > "$od/$tag.via"; echo 0 > "$od/$tag.rc"; else echo 1 > "$od/$tag.rc"; fi
}
_rules_finish_batch() { # outdir tag…  逐个收尾: 校验已通过的文件原子替换, 统计结果, 打印一行
  local od=$1 tag rc; shift
  for tag in "$@"; do
    IFS= read -r rc < "$od/$tag.rc" 2>/dev/null || rc=1
    if [ "$rc" = 0 ]; then
      if [ -f "$H/rules/$tag.srs" ] && cmp -s "$H/rules/$tag.srs.new" "$H/rules/$tag.srs"; then rm -f "$H/rules/$tag.srs.new"; ok "$tag 已是最新"
      else mv "$H/rules/$tag.srs.new" "$H/rules/$tag.srs"; RULES_CHANGED=$((RULES_CHANGED+1)); ok "$tag 已更新 (线路: $(cat "$od/$tag.via" 2>/dev/null))"; fi
      RULES_OK=$((RULES_OK+1))
    else
      RULES_FAILED=$((RULES_FAILED+1)); rm -f "$H/rules/$tag.srs.new"
      if [ -s "$H/rules/$tag.srs" ]; then warn "$tag 下载失败, 继续使用旧版本"; else warn "$tag 下载失败 (暂时不使用该规则集)"; fi
    fi
  done
}

# rules_update [tag…]: 下载/更新「启用」的规则集 (6 个并行; 不带参数 = 全部启用的, 再顺带刷新自定义规则集)
# 设置 RULES_CHANGED / RULES_FAILED / RULES_OK; 返回 0 = 没有全部失败
rules_update() {
  local only=" $* " tag repo branch file name desc ess en total=0 done_=0 n=0 batch='' od lines
  mkdir -p "$H/rules"; RULES_CHANGED=0; RULES_FAILED=0; RULES_OK=0
  od=$(mktemp -d); lines=$(rules_wanted)
  while IFS='|' read -r tag _; do [ -n "$tag" ] || continue; case "$only" in "  ") total=$((total+1)) ;; *" $tag "*) total=$((total+1)) ;; esac; done <<EOF
$lines
EOF
  while IFS='|' read -r tag repo branch file name desc ess en; do
    [ -n "$tag" ] || continue
    case "$only" in "  ") ;; *" $tag "*) ;; *) continue ;; esac
    ( _rules_fetch_one "$tag" "$repo" "$branch" "$file" "$od" ) &
    batch="$batch $tag"; n=$((n+1))
    if [ "$n" -ge 6 ]; then
      wait; done_=$((done_+n)); job_step 1 $(( done_ * 90 / (total == 0 ? 1 : total) )) "下载规则集 $done_/$total"
      _rules_finish_batch "$od" $batch; batch=''; n=0
    fi
  done <<EOF
$lines
EOF
  if [ "$n" -gt 0 ]; then wait; done_=$((done_+n)); job_step 1 90 "下载规则集 $done_/$total"; _rules_finish_batch "$od" $batch; fi
  [ "$only" = "  " ] && custom_rs_refresh_all
  rm -rf "$od"
  date +%s > "$H/rules/.updated"
  [ "$total" -eq 0 ] || [ "$RULES_OK" -gt 0 ] || [ "$RULES_FAILED" -lt "$total" ]
}

custom_rs_valid_name() { printf '%s' "$1" | LC_ALL=C grep -Eq '^[A-Za-z0-9._-]{1,30}$'; }
custom_rs_add() { # name url policy  -> 下载 (≤20MB) 校验为 .srs 后登记; 返回 0 成功, 2 名称/链接/策略不合法, 3 已存在, 4 下载失败
  local name=$1 url=$2 pol=$3 tag
  custom_rs_valid_name "$name" || return 2
  sub_url_ok "$url" || return 2
  case $pol in pin|auto|direct) ;; *) return 2 ;; esac
  tag=$(printf '%s' "$name" | tr 'A-Z' 'a-z')
  grep -q "^$tag|" "$H/custom-rulesets.tsv" 2>/dev/null && return 3
  grep -q "^geosite-$tag|\|^geoip-$tag|" "$(content_file rulesets.conf)" 2>/dev/null && return 3
  mkdir -p "$H/rules"
  DL_MAXSIZE=20971520 fetch_any "$H/rules/custom-$tag.srs.new" valid_srs "$url" || return 4
  mv "$H/rules/custom-$tag.srs.new" "$H/rules/custom-$tag.srs"
  touch "$H/custom-rulesets.tsv"; chmod 600 "$H/custom-rulesets.tsv"
  printf '%s|%s|%s|%s|%s\n' "$tag" "$name" "$pol" "$(now)" "$url" >> "$H/custom-rulesets.tsv"
}
custom_rs_delete() { # tag
  [ -f "$H/custom-rulesets.tsv" ] || return 1
  grep -q "^$1|" "$H/custom-rulesets.tsv" || return 1
  grep -v "^$1|" "$H/custom-rulesets.tsv" > "$H/custom-rulesets.tsv.new"; mv "$H/custom-rulesets.tsv.new" "$H/custom-rulesets.tsv"
  rm -f "$H/rules/custom-$1.srs"
}
custom_rs_refresh_all() {
  local tag name pol ts url
  [ -s "$H/custom-rulesets.tsv" ] || return 0
  while IFS='|' read -r tag name pol ts url; do
    [ -n "$url" ] || continue
    DL_MAXSIZE=20971520 fetch_any "$H/rules/custom-$tag.srs.new" valid_srs "$url" >/dev/null 2>&1 && mv "$H/rules/custom-$tag.srs.new" "$H/rules/custom-$tag.srs" || rm -f "$H/rules/custom-$tag.srs.new"
  done < "$H/custom-rulesets.tsv"
}

rules_json() { # GET /api/rules 的 sets 数组
  local st="$H/.rules.stat"
  { stat -f '%N|%z|%m' "$H"/rules/*.srs 2>/dev/null || true; } > "$st"
  awk -F'|' -v st="$st" -v state="$H/rules.state" -v cust="$H/custom-rulesets.tsv" -v rd="$H/rules/" '
    function esc(x) { gsub(/["\\]/, "", x); return x }
    BEGIN {
      while ((getline l < st) > 0) { split(l, a, "|"); f = a[1]; sub(rd, "", f); sub(/\.srs$/, "", f); sz[f] = a[2]; mt[f] = a[3] }
      while ((getline l < state) > 0) { split(l, a, "="); s[a[1]] = a[2] }
      printf "["
    }
    /^[ \t]*(#|$)/ { next }
    FILENAME != cust {
      en = ($8 == "") ? 1 : $8; if ($1 in s) en = s[$1]; if ($7 == 1) en = 1
      printf "%s{\"tag\":\"%s\",\"name\":\"%s\",\"desc\":\"%s\",\"repo\":\"%s\",\"present\":%s,\"bytes\":%d,\"updated\":%d,\"enabled\":%s,\"essential\":%s,\"custom\":false}", (n++ ? "," : ""), $1, esc($5), esc($6), $2, ($1 in sz ? "true" : "false"), sz[$1] + 0, mt[$1] + 0, (en == 1 ? "true" : "false"), ($7 == 1 ? "true" : "false")
    }
    END {
      while ((getline l < cust) > 0) { split(l, a, "|"); t = "custom-" a[1]
        printf "%s{\"tag\":\"%s\",\"name\":\"%s\",\"desc\":\"自定义规则集\",\"repo\":\"自定义链接\",\"present\":%s,\"bytes\":%d,\"updated\":%d,\"enabled\":true,\"essential\":false,\"custom\":true,\"policy\":\"%s\"}", (n++ ? "," : ""), a[1], esc(a[2]), (t in sz ? "true" : "false"), sz[t] + 0, mt[t] + 0, a[3] }
      printf "]"
    }' "$(content_file rulesets.conf)" 2>/dev/null
}

# ---------- 订阅拉取 (仅由本地辅助服务 / 命令行使用; 订阅链接含令牌, 绝不打印) ----------
sub_ua() { case ${1:-auto} in clash) echo "clash-verge/v2.0.0" ;; v2ray) echo "v2rayN/6.45" ;; *) echo "sing-box/1.12.0" ;; esac; }

sub_fetch() { # sub_fetch URL UA类型 输出文件 响应头文件  -> 0 成功
  local url=$1 ua out=$3 hdr=$4 label px auth code
  ua=$(sub_ua "$2")
  sub_url_ok "$url" || return 2
  while IFS='|' read -r label px auth; do
    [ -n "$label" ] || continue
    if [ -n "$px" ]; then
      if [ -n "$auth" ]; then code=$(curl -sS -m 25 --max-filesize 3145728 -A "$ua" -x "$px" --proxy-user "$auth" -D "$hdr" -o "$out" -w '%{http_code}' "$url" 2>/dev/null || true)
      else code=$(curl -sS -m 25 --max-filesize 3145728 -A "$ua" -x "$px" -D "$hdr" -o "$out" -w '%{http_code}' "$url" 2>/dev/null || true); fi
    else code=$(curl -sS -m 25 --max-filesize 3145728 -A "$ua" --noproxy '*' -D "$hdr" -o "$out" -w '%{http_code}' "$url" 2>/dev/null || true); fi
    [ "$code" = 200 ] && [ -s "$out" ] && return 0
  done < <(dl_routes)
  return 1
}
