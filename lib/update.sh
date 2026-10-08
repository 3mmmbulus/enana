# 检查更新 (enana 本体 + sing-box 核心)。依赖 common.sh fetch.sh。
#
# 本体: 读仓库根目录的 VERSION (GitHub raw → jsDelivr 镜像 → …, 走下载链, 国内也能查)。更新说明来自 CHANGELOG.md:
#       "## 2.1.2 (日期)" 下面的 "### 中文" / "### English" 两段。
# 核心: GitHub releases/latest 的跳转地址得到最新版本号。
# 结果缓存在 $H/update.json (6 小时内不重复请求, force 可强制), 每天由 `enana maintain` 刷新一次。
# 更新本体: `enana self-update` (= 重新运行 get.sh 的升级流程, 安装器重复运行安全)。

UPDATE_REPO=3mmmbulus/enana
UPDATE_BRANCH=main
UPDATE_TTL=21600
UPDATE_MIRROR=https://enana.cc/dl     # 项目自己的下载镜像 (GitHub / jsDelivr 访问不了时兜底)

version_gt() { # version_gt A B  -> 0 当且仅当 A > B (点分数字, 忽略后缀)
  awk -v a="$1" -v b="$2" 'BEGIN { na = split(a, x, "."); nb = split(b, y, "."); n = (na > nb ? na : nb)
    for (i = 1; i <= n; i++) { xi = x[i] + 0; yi = y[i] + 0; if (xi > yi) exit 0; if (xi < yi) exit 1 } exit 1 }'
}
valid_version_file() { grep -Eq '^[0-9]+(\.[0-9]+){1,3}[[:space:]]*$' "$1"; }
valid_text_file() { [ -s "$1" ] && ! LC_ALL=C grep -q '<html' "$1"; }

_update_urls() { # 文件名 -> 每行一个 URL
  if [ -n "${ENANA_UPDATE_BASE:-}" ]; then printf '%s/%s\n' "$ENANA_UPDATE_BASE" "$1"; return 0; fi     # 测试用
  if [ "${ENANA_PLATFORM:-darwin}" = windows ] && [ "$1" = windows-manifest.json ]; then
    printf '%s\n' "${UPDATE_MIRROR:-https://enana.cc/dl}/windows-manifest.json" "https://github.com/$UPDATE_REPO/releases/latest/download/windows-manifest.json"; return 0
  fi
  if [ "${ENANA_PLATFORM:-darwin}" = windows ] && [ "$1" = CHANGELOG.md ]; then
    printf '%s\n' "${UPDATE_MIRROR:-https://enana.cc/dl}/windows-CHANGELOG.md" "https://raw.githubusercontent.com/$UPDATE_REPO/$UPDATE_BRANCH/CHANGELOG.md"; return 0
  fi
  printf '%s\n' "${UPDATE_MIRROR:-https://enana.cc/dl}/$1" \
                "https://raw.githubusercontent.com/$UPDATE_REPO/$UPDATE_BRANCH/$1" \
                "https://fastly.jsdelivr.net/gh/$UPDATE_REPO@$UPDATE_BRANCH/$1" \
                "https://cdn.jsdelivr.net/gh/$UPDATE_REPO@$UPDATE_BRANCH/$1"
}
_update_get() { # 文件名 校验函数 输出文件
  local f=$1 v=$2 o=$3 u
  set --; while IFS= read -r u; do set -- "$@" "$u"; done < <(_update_urls "$f")
  QUIET=1 fetch_any "$o" "$v" "$@" >/dev/null 2>&1
}
valid_windows_manifest() {
  perl -MJSON::PP -e 'local $/; my $j=eval {decode_json(<>)} or exit 1; exit (($j->{platform}//"") eq "windows" && ($j->{version}//"") =~ /^\d+\.\d+\.\d+$/ && ($j->{sha256}//"") =~ /^[0-9a-f]{64}$/ && ($j->{size}//0)>0 && $j->{size}<=104857600 && ($j->{url}//"") eq "/dl/enana-$j->{version}-windows.zip" ? 0 : 1)' "$1"
}

# 从 CHANGELOG.md 里取某个版本的说明: 输出两个变量 NOTES_ZH NOTES_EN (最多 20 行)
update_notes() { # 版本 changelog 文件
  local ver=$1 f=$2
  NOTES_ZH=$(awk -v v="$ver" '/^## /{ on = (index($0, "## " v) == 1); lang = ""; next } on && /^### /{ lang = ($0 ~ /中文/) ? "zh" : (($0 ~ /English/) ? "en" : ""); next } on && lang == "zh" && NF { print }' "$f" | head -20)
  NOTES_EN=$(awk -v v="$ver" '/^## /{ on = (index($0, "## " v) == 1); lang = ""; next } on && /^### /{ lang = ($0 ~ /中文/) ? "zh" : (($0 ~ /English/) ? "en" : ""); next } on && lang == "en" && NF { print }' "$f" | head -20)
}

# update_check [force]: 刷新 $H/update.json (成功返回 0)
update_check() {
  local force=${1:-} f="$H/update.json" ts=0 tmp latest='' core_latest='' now_ cl
  now_=$(now)
  if [ -f "$f" ] && [ -z "$force" ]; then ts=$(sed -n 's/.*"checked":\([0-9]*\).*/\1/p' "$f" | head -1); [ $((now_ - ${ts:-0})) -lt $UPDATE_TTL ] && return 0; fi
  tmp=$(mktemp)
  if [ "${ENANA_PLATFORM:-darwin}" = windows ]; then
    if _update_get windows-manifest.json valid_windows_manifest "$tmp"; then latest=$(perl -MJSON::PP -e 'local $/; print decode_json(<>)->{version}' "$tmp"); fi
    # SYSTEM snapshots accept only the core reviewed and pinned in this client.
    core_latest=$(perl -MJSON::PP -e 'local $/; print decode_json(<>)->{core}->{version}' "$H/windows/runtime-pins.json" 2>/dev/null || true)
  else
    if _update_get VERSION valid_version_file "$tmp"; then latest=$(tr -d '[:space:]' < "$tmp"); fi
    # 核心只提示「和当前 enana 兼容」的版本: 来自项目签名的兼容清单, 不再直接取 GitHub 的 latest (没测试过的新版本可能和我们的配置不兼容)。
    core_manifest_refresh >/dev/null 2>&1 || true
    core_latest=$(core_latest_compat 2>/dev/null || true)
  fi
  NOTES_ZH=''; NOTES_EN=''
  if [ -n "$latest" ] && version_gt "$latest" "$VERSION" && _update_get CHANGELOG.md valid_text_file "$tmp"; then update_notes "$latest" "$tmp"; fi
  rm -f "$tmp"
  if [ -z "$latest" ] && [ -z "$core_latest" ]; then   # 完全查不到: 保留旧结果, 只记录失败
    [ -f "$f" ] && sed_inplace 's/"error":[a-z]*/"error":true/' "$f" 2>/dev/null; return 1
  fi
  printf '{"checked":%s,"latest":"%s","core_latest":"%s","notes_zh":"%s","notes_en":"%s","error":false}\n' "$now_" "$latest" "$core_latest" \
    "$(printf '%s' "$NOTES_ZH" | awk '{ gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/[\001-\037]/, " "); printf "%s%s", (NR > 1 ? "\\n" : ""), $0 }')" \
    "$(printf '%s' "$NOTES_EN" | awk '{ gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/[\001-\037]/, " "); printf "%s%s", (NR > 1 ? "\\n" : ""), $0 }')" > "$f.new" && mv "$f.new" "$f"
}

# update_json: GET /api/update/check 的主体 (不含最外层 ok); 语言 zh|en 决定 notes
update_json() {
  local f="$H/update.json" checked=0 latest='' core_latest='' nz='' ne='' err='' code='' core_cur avail=false cavail=false notes
  if [ -f "$f" ]; then
    checked=$(sed -n 's/.*"checked":\([0-9]*\).*/\1/p' "$f" | head -1); latest=$(sed -n 's/.*"latest":"\([^"]*\)".*/\1/p' "$f" | head -1)
    core_latest=$(sed -n 's/.*"core_latest":"\([^"]*\)".*/\1/p' "$f" | head -1)
    nz=$(sed -n 's/.*"notes_zh":"\(.*\)","notes_en".*/\1/p' "$f" | head -1); ne=$(sed -n 's/.*"notes_en":"\(.*\)","error".*/\1/p' "$f" | head -1)
    case "$(sed -n 's/.*"error":\([a-z]*\).*/\1/p' "$f" | head -1)" in true) err=$(_t "没有查到最新版本 (网络不可用?)"); code=E_NETWORK ;; esac
  fi
  core_cur=$(core_version 2>/dev/null || true)
  [ -n "$latest" ] && version_gt "$latest" "$VERSION" && avail=true
  [ -n "$core_latest" ] && [ -n "$core_cur" ] && version_gt "$core_latest" "$core_cur" && cavail=true
  notes=$ne; [ "${I18N_LANG:-${LANG_UI:-zh}}" = zh ] && notes=$nz
  printf '"current":"%s","latest":"%s","available":%s,"checked":%s,"notes":"%s","notes_zh":"%s","notes_en":"%s","url":"https://github.com/%s/releases","error":"%s","code":"%s","core":{"current":"%s","latest":"%s","available":%s}' \
    "$VERSION" "${latest:-$VERSION}" "$avail" "${checked:-0}" "$notes" "$nz" "$ne" "$UPDATE_REPO" "$(jesc "$err")" "$code" "$core_cur" "${core_latest:-$core_cur}" "$cavail"
}
update_available() { # 简短摘要 (供 /api/state 使用): {"available":bool,"latest":"x","checked":n}
  local f="$H/update.json" latest='' checked=0 av=false
  if [ -f "$f" ]; then latest=$(sed -n 's/.*"latest":"\([^"]*\)".*/\1/p' "$f" | head -1); checked=$(sed -n 's/.*"checked":\([0-9]*\).*/\1/p' "$f" | head -1); fi
  [ -n "$latest" ] && version_gt "$latest" "$VERSION" && av=true
  printf '{"available":%s,"latest":"%s","checked":%s}' "$av" "${latest:-$VERSION}" "${checked:-0}"
}
update_has_new() { # 缓存里的最新版本是否比当前新 (不联网)
  local latest; latest=$(sed -n 's/.*"latest":"\([^"]*\)".*/\1/p' "$H/update.json" 2>/dev/null | head -1)
  [ -n "$latest" ] && version_gt "$latest" "$VERSION"
}
