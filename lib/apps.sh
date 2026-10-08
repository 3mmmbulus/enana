# 应用识别 + 用户覆盖层。
# 覆盖层 = 用户对「某个应用 / 某个网站」的显式设置, 保存在 $H/overrides.tsv:  类型|名称|状态|标记|出口
#   类型 app|site;  状态 follow(跟随规则=开) direct(直连=关) pin(进入核心的流量走固定出口) auto(全走自动线路);
#   标记 new(扫描新发现, 还没处理) ack(用户设置过 / 已知晓) def(首次扫描按推荐设置的默认值, 云端推荐更新后可以刷新);
#   出口 只对 pin 有意义: 空 = 跟随默认固定出口 · PINAUTO = 在固定出口里自动选一个 · 其它 = 指定走这一个固定出口 (固定出口有 2 个以上时才能选)
#        「跟随默认」的应用 / 网站会随默认固定出口一起换出口 IP; 要钉住就指定一个 (批量移动 / 冻结 / 删除服务器前的影响检查见 lib/exits.sh)。指定的出口已不是固定出口 (被删除 / 改了角色 / 超过上限) =「孤儿」,
#        规则集里暂时退回默认固定出口 (见下面 ovr_sync 的 key()), 同时会在界面和健康记录里标出来。
# 设置分别写成 sing-box 本地规则集 (rules/ovr-<名字>.json): direct(网站直连) appdirect(应用直连) pin(默认固定出口) pinauto(固定出口里自动选) pin-<序号>(指定的固定出口) auto(自动线路),
# sing-box 监视文件变化, 因此切换应用/网站无需重启、不会断开现有连接。
#
# 应用规则: 新装应用默认「关」(direct, 标记 new), 但浏览器例外 (默认跟随规则: 否则新装的浏览器会让所有网站都打不开)。首次识别时, 已知应用 (data/apps.conf) 采用推荐设置。
# 自动识别无法访问的网站 (设置里打开) 添加的网站另外记在 $H/autosites.tsv:  域名|添加时间|原因|失败次数|应用   (网站页据此标出「自动识别」)

APPS_SCAN_V=2                         # 扫描范围的版本: 升级后范围变大时, 新发现的老应用不算「新应用」(不弹提示)

ovr_file() { printf '%s\n' "$H/overrides.tsv"; }

ovr_valid() { # kind value
  local k=$1 v=$2
  [ -n "$v" ] && [ ${#v} -le 80 ] || return 1
  case $k in
    app)  case $v in *'|'*|*'"'*|*'\'*|*/*|*[[:cntrl:]]*) return 1 ;; esac; return 0 ;;   # 整串检查 (不按行): 换行 / 控制字符也挡住
    site) [[ $v =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] ;;
    *) return 1 ;;
  esac
}

OVR_PIN_MAX=32      # 可以单独指定的固定出口个数上限: 每个固定出口 3 个规则集 (网站 / 应用 / 浏览器), 32 个 = 96 + 12 个文件。要和 lib/config.sh、ui/data.js (TP.PIN_MAX)、lib/tunrules-helper.pl (一次最多同步的文件数) 保持一致
ovr_pins() { srv_list 2>/dev/null | awk -F'\t' -v max="$OVR_PIN_MAX" '$5=="pin" && n < max { print $1; n++ }'; }      # 可以单独指定的固定出口 (按配置里的顺序, 最多 OVR_PIN_MAX 个; 和 config.sh 里的规则集序号一致)
ovr_target_valid() { # 出口: 空 / PINAUTO / 现有的某个固定出口 (固定出口不到 2 个时只能是空)
  local t=$1
  [ -z "$t" ] && return 0
  [ "$(ovr_pins | wc -l | tr -d ' ')" -ge 2 ] || return 1
  [ "$t" = PINAUTO ] || ovr_pins | grep -qxF -- "$t"
}

ovr_set() { # kind value state [flag] [target]  (upsert, 原子写)
  local k=$1 v=$2 s=$3 f=${4:-ack} t=${5:-}
  [ "$s" = pin ] || t=''
  touch "$H/overrides.tsv"
  LC_ALL=C awk -F'|' -v OFS='|' -v k="$k" -v v="$v" -v s="$s" -v f="$f" -v t="$t" '
    $1==k && $2==v { $3=s; $4=f; $5=t; found=1 } { print } END { if (!found) print k, v, s, f, t }' "$H/overrides.tsv" > "$H/overrides.tsv.new" \
    && mv "$H/overrides.tsv.new" "$H/overrides.tsv"
}
ovr_delete() { # kind value
  [ -f "$H/overrides.tsv" ] || return 0
  LC_ALL=C awk -F'|' -v k="$1" -v v="$2" '!($1==k && $2==v)' "$H/overrides.tsv" > "$H/overrides.tsv.new" && mv "$H/overrides.tsv.new" "$H/overrides.tsv"
}
ovr_get() { awk -F'|' -v k="$1" -v v="$2" '$1==k && $2==v {print $3; exit}' "$H/overrides.tsv" 2>/dev/null; }
ovr_target() { awk -F'|' -v k="$1" -v v="$2" '$1==k && $2==v {print $5; exit}' "$H/overrides.tsv" 2>/dev/null; }

json_list() { # stdin 每行一个字符串 -> "a","b"  (调用方保证内容不含引号/反斜杠)
  sed 's/.*/"&"/' | paste -sd, -
}
app_regex_json() { # 应用名 -> JSON 字符串内容: (?i)/名称\\.app/  (点号等已转义)
  local n=$1
  n=$(printf '%s' "$n" | sed -e 's/[][\.*^$+?(){}|]/\\&/g')
  printf '(?i)/%s\\.app/' "$n" | sed 's/\\/\\\\/g'
}

# 由 overrides.tsv 生成各个规则集文件 (原地覆盖写, 让 sing-box 的文件监视生效; 内容没变就不写)
ovr_sync() {
  local T bset f body name path
  mkdir -p "$H/rules"; T=$(mktemp -d); touch "$H/overrides.tsv"
  bset="|$(awk -F'|' '$2=="bin" {printf "%s|", $1}' "$H/custom-apps.tsv" 2>/dev/null)"        # 自定义的命令行工具 (按可执行文件名匹配, 不是 .app 路径)
  [ "${ENANA_PLATFORM:-darwin}" != windows ] || bset='|'
  if [ "${ENANA_PLATFORM:-darwin}" = windows ]; then windows_node regex-map "$H" > "$T/regexes" || { rm -rf "$T"; return 1; }; fi
  ovr_pins > "$T.pins"
  : > "$T.browsers"
  while IFS=$'\t' read -r name path; do
    if app_is_browser "$path" || awk -F'|' -v n="$name" '$1==n && $3=="浏览器" {found=1} END {exit !found}' "$(content_file apps.conf)"; then
      printf '%s\n' "$name" >> "$T.browsers"
    fi
  done < "$H/.apps.now" 2>/dev/null
  LC_ALL=C awk -F'|' -v dir="$T" -v bset="$bset" -v bf="$T.browsers" -v pf="$T.pins" -v rf="$T/regexes" '
    function js(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
    function rx(n,   t) { t = n; gsub(/[][\\.*^$+?(){}|\/]/, "\\\\&", t); return "(?i)/" t "\\.app/" }          # 应用名里的正则符号转义, 再整体当 JSON 字符串写
    function key(st, kind, tg, name) {
      if (kind == "app" && (name in browsers)) {
        if (st == "direct") return "browserdirect"
        if (st == "auto") return "browserauto"
        if (st == "pin") {
          if (np >= 2 && tg == "PINAUTO") return "browserpinauto"
          if (np >= 2 && tg in pidx) return "browserpin-" pidx[tg]
          return "browserpin"
        }
      }
      if (st == "direct") return (kind == "site") ? "direct" : "appdirect"
      if (st == "auto") return (kind == "site") ? "auto" : "appauto"     # 应用自动单独成集 (N1): 排在网站规则之后
      if (np < 2) return "pin"
      if (tg == "PINAUTO") return "pinauto"
      if (tg in pidx) return "pin-" pidx[tg]
      return "pin"                                                                                           # 指定的出口已经不存在: 退回默认固定出口
    }
    function appjson(n) { return (n in winrx) ? winrx[n] : "\"" js(rx(n)) "\"" }
    BEGIN { while ((getline l < rf) > 0) { split(l, wr, "\t"); winrx[wr[1]]=wr[2] }
            while ((getline l < bf) > 0) browsers[l] = 1; np = 0; while ((getline l < pf) > 0) if (l != "") { P[++np] = l; pidx[l] = np }
            nk = split("direct appdirect browserdirect browserauto browserpin browserpinauto pin pinauto apppin apppinauto appauto auto", K, " "); for (i = 1; i <= np; i++) { K[++nk] = "pin-" i; K[++nk] = "apppin-" i; K[++nk] = "browserpin-" i }
            for (i = 1; i <= nk; i++) known[K[i]] = 1 }
    ($1 == "site" || $1 == "app") && $3 != "follow" && $3 != "" {
      k = key($3, $1, $5, $2)
      if ($1 == "site") S[k] = S[k] (S[k] == "" ? "" : ",") "\"" js($2) "\""
      else if (index(bset, "|" $2 "|") > 0) B[k] = B[k] (B[k] == "" ? "" : ",") "\"" js($2) "\""
      else A[k] = A[k] (A[k] == "" ? "" : ",") appjson($2)
      # App PIN must precede EVERY website PIN, including a site-specific node.
      # Keep combined files for compatibility and add app-only precedence files.
      if ($1 == "app" && $3 == "pin" && !($2 in browsers)) {
        ak = "app" k
        if (index(bset, "|" $2 "|") > 0) B[ak] = B[ak] (B[ak] == "" ? "" : ",") "\"" js($2) "\""
        else A[ak] = A[ak] (A[ak] == "" ? "" : ",") appjson($2)
      }
    }
    END {
      for (i = 1; i <= nk; i++) {
        k = K[i]; r = ""
        if (S[k] != "") r = "{\"domain_suffix\":[" S[k] "]}"
        if (A[k] != "") r = r (r == "" ? "" : ",") "{\"process_path_regex\":[" A[k] "]}"
        if (B[k] != "") r = r (r == "" ? "" : ",") "{\"process_name\":[" B[k] "]}"
        if (r == "") r = "{\"domain\":[\"enana-placeholder.invalid\"]}"                                      # 空规则集占位 (不会匹配任何域名)
        print "{\"version\":3,\"rules\":[" r "]}" > (dir "/" k ".json")
      }
    }' "$H/overrides.tsv" 2>/dev/null
  # 没有 overrides.tsv 时 awk 不会产出文件: 补齐占位, 保证每个规则集文件都存在
  for name in direct appdirect browserdirect browserauto browserpin browserpinauto pin pinauto apppin apppinauto appauto auto; do [ -f "$T/$name.json" ] || printf '%s\n' '{"version":3,"rules":[{"domain":["enana-placeholder.invalid"]}]}' > "$T/$name.json"; done
  for f in "$T"/*.json; do
    name=$(basename "$f"); body=$(cat "$f")
    if [ ! -f "$H/rules/ovr-$name" ] || [ "$(cat "$H/rules/ovr-$name")" != "$body" ]; then printf '%s\n' "$body" > "$H/rules/ovr-$name.tmp" && cat "$H/rules/ovr-$name.tmp" > "$H/rules/ovr-$name" && rm -f "$H/rules/ovr-$name.tmp"; fi
  done
  rm -rf "$T" "$T.pins" "$T.browsers"
}

# ---------- 应用扫描 ----------
APPS_ROOTS_PRIO="/Applications /System/Applications /System/Cryptexes/App/System/Applications /System/Library/CoreServices/Applications"          # 重名时靠前的优先
_apps_find() { # 每行: 名称<TAB>路径 (按目录优先级); 不进入 .app 里面, 所以应用内嵌的辅助程序 (Helper.app 等) 不会出现。ENANA_APPS_ROOTS (空格分隔) 可替换扫描目录 (测试用)
  if [ "${ENANA_PLATFORM:-darwin}" = windows ]; then win_bridge apps; return; fi
  local r
  for r in ${ENANA_APPS_ROOTS:-$APPS_ROOTS_PRIO "$HOME/Applications"}; do
    [ -d "$r" ] || continue
    find "$r" -maxdepth 4 -name '*.app' -prune 2>/dev/null || true
  done | LC_ALL=C awk -F/ '{ n = $NF; sub(/\.app$/, "", n); if (n != "" && substr(n,1,1) != ".") print n "\t" $0 }'
}
_apps_mdfind() { # Spotlight 能找到、但不在上面这些目录里的应用 (装在别处的); 结果缓存 10 分钟, 最多等 10 秒 (Spotlight 在重建索引时可能很慢)
  [ "${ENANA_PLATFORM:-darwin}" != windows ] || return 0
  local c="$H/.apps.md" t p i=0
  [ "${ENANA_NO_MDFIND:-}" = 1 ] && return 0
  if [ ! -s "$c" ] || [ -n "$(find "$c" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
    t=$(mktemp); mdfind "kMDItemContentTypeTree == 'com.apple.application-bundle'" > "$t" 2>/dev/null & p=$!
    while kill -0 "$p" 2>/dev/null && [ "$i" -lt 40 ]; do sleep 0.25; i=$((i + 1)); done
    kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true
    LC_ALL=C grep -E '\.app$' "$t" | LC_ALL=C grep -Ev '\.app/|/DerivedData/|/Library/Developer/|/Library/Caches/|/node_modules/|/\.Trash/' \
      | LC_ALL=C grep -E "^(/Applications/|/System/Applications/|/System/Cryptexes/App/System/Applications/|/opt/homebrew/|/usr/local/|$HOME/Applications/)" > "$c.new"; mv "$c.new" "$c"; rm -f "$t"
  fi
  LC_ALL=C awk -F/ '{ n = $NF; sub(/\.app$/, "", n); if (n != "" && substr(n,1,1) != ".") print n "\t" $0 }' "$c"
}
apps_installed() { # 每行: 名称<TAB>路径  (自动识别的 + 用户手动添加的自定义软件)
  {
    { _apps_find; _apps_mdfind; } | LC_ALL=C awk -F'\t' '!seen[$1]++'                                    # 先 find (有优先级顺序), 再 Spotlight 补充; 同名只留第一个
    [ -s "$H/custom-apps.tsv" ] && awk -F'|' '{ print $1 "\t" $3 }' "$H/custom-apps.tsv"
  } | LC_ALL=C sort -u -t"$(printf '\t')" -k1,1
}

app_is_browser() { # <.app 路径>  声明自己能打开 http / https 链接的应用 = 浏览器
  if [ "${ENANA_PLATFORM:-darwin}" = windows ]; then
    # Native scanning already returned EXE paths; avoid starting PowerShell for
    # each application just to compare a known browser executable filename.
    local exe=${1##*/}; exe=${exe##*\\}; exe=$(printf '%s' "$exe" | tr '[:upper:]' '[:lower:]')
    case $exe in chrome.exe|msedge.exe|firefox.exe|brave.exe|opera.exe|vivaldi.exe|arc.exe) return 0 ;; *) return 1 ;; esac
  fi
  local plist="$1/Contents/Info.plist" name group
  name=$(basename "$1" .app)
  # Known native apps can register http/https for OAuth or deep links too.
  # Their catalog category takes precedence over that URL-handler heuristic.
  group=$(LC_ALL=C awk -F'|' -v n="$name" '
    !/^[ \t]*(#|$)/ {p=tolower($1); x=tolower(n); if (substr(p,length(p))=="*") {if (index(x,substr(p,1,length(p)-1))!=1) next} else if (x!=p) next; print $3; exit}
  ' "$(content_file apps.conf)" 2>/dev/null)
  if [ -n "$group" ]; then [ "$group" = 浏览器 ]; return; fi
  [ -f "$plist" ] && plutil -extract CFBundleURLTypes json -o - "$plist" 2>/dev/null | LC_ALL=C grep -Eq '"https?"'
}

apps_conf_rec() { # <应用名>  -> 推荐状态 (没有就空); 规则见 apps.conf: 不分大小写, 支持结尾 *
  LC_ALL=C awk -v n="$1" -v conf="$(content_file apps.conf)" 'BEGIN {
    ln = tolower(n)
    while ((getline line < conf) > 0) { if (line ~ /^[ \t]*(#|$)/) continue; split(line, a, "|"); p = tolower(a[1])
      if (substr(p, length(p), 1) == "*") { pre = substr(p, 1, length(p) - 1); if (substr(ln, 1, length(pre)) == pre) { print a[2]; exit } }
      else if (ln == p) { print a[2]; exit } } }'
}

_apps_fix_browsers() { # 2.1.0 把「新装的浏览器」默认设成了直连 (标记 new = 你还没处理过), 浏览器里的网站因此全都不走代理: 这样的浏览器改回跟随规则 (标记不变, 仍会提示你)。你自己设置过的 (标记 ack) 不动
  local names name path n=0 list=''
  names=$(awk -F'|' '$1 == "app" && $3 == "direct" && $4 == "new" {print $2}' "$H/overrides.tsv")
  [ -n "$names" ] || return 0
  while IFS= read -r name; do
    path=$(awk -F'\t' -v n="$name" '$1 == n {print $2; exit}' "$H/.apps.now")
    [ -n "$path" ] && app_is_browser "$path" || continue
    ovr_set app "$name" follow new ''; n=$((n + 1)); list="$list${list:+,}$name"
  done <<< "$names"
  [ "$n" = 0 ] || oplog "${OP_WHO:-auto}" "修复浏览器的默认设置" "$(kv count "$n" names "$list" from direct to follow why "browser defaulted to off by 2.1.0")" ok
}

apps_scan() { # 新应用写入 overrides.tsv: 首次扫描 (或扫描范围扩大后的第一次) = 已知用推荐 / 浏览器跟随 / 其余直连 (标记 def, 不弹「新应用」); 之后 = 浏览器跟随 / 其余直连 (标记 new). 打印新增数量
  local first=0 seen_v=0 before after path name flag state rec
  [ -f "$H/apps.seen" ] || first=1
  [ "$first" = 1 ] || { IFS= read -r seen_v < "$H/apps.seen" || true; case $seen_v in ''|*[!0-9]*) seen_v=1 ;; esac; [ "$seen_v" -ge "$APPS_SCAN_V" ] || first=1; }
  touch "$H/overrides.tsv"
  apps_installed > "$H/.apps.now"
  apps_times_update
  _apps_fix_browsers
  before=$(wc -l < "$H/overrides.tsv" | tr -d ' ')
  # 只有还没有记录的应用才处理; 浏览器要读 Info.plist, 所以逐个判断 (新应用不多)
  : > "$H/.apps.add"
  while IFS=$'\t' read -r name path; do
    [ -n "$name" ] || continue
    case $name in *[\|\"\\/]*) continue ;; esac; [ ${#name} -le 80 ] || continue
    awk -F'|' -v n="$name" '$1=="app" && $2==n {f=1} END{exit f?0:1}' "$H/overrides.tsv" && continue
    rec=$(apps_conf_rec "$name"); state=direct
    if [ -n "$rec" ]; then [ "$first" = 1 ] && state=$rec || state=direct
    elif app_is_browser "$path"; then state=follow; fi
    if [ "$first" = 1 ]; then flag=def; else flag=new; fi
    printf 'app|%s|%s|%s|\n' "$name" "$state" "$flag" >> "$H/.apps.add"
  done < "$H/.apps.now"
  cat "$H/.apps.add" >> "$H/overrides.tsv"
  after=$(wc -l < "$H/overrides.tsv" | tr -d ' ')
  printf '%s\n' "$APPS_SCAN_V" > "$H/apps.seen"
  apps_rerecommend
  ovr_sync
  if [ "$first" = 0 ] && [ $((after - before)) -gt 0 ]; then
    oplog "${OP_WHO:-auto}" "发现新应用" "$(kv count $((after - before)) names "$(awk -F'|' '$4=="new" {print $2}' "$H/.apps.add" | head -8 | paste -sd, -)" default "$(awk -F'|' '$4=="new" {print $3}' "$H/.apps.add" | sort | uniq -c | awk '{printf "%s%s×%s", (n++ ? "," : ""), $2, $1}')")" ok
  elif [ "$first" = 1 ] && [ $((after - before)) -gt 0 ]; then
    oplog "${OP_WHO:-auto}" "识别已安装的应用" "$(kv count $((after - before)) scan_v "$APPS_SCAN_V" browsers "$(awk -F'|' '$3=="follow" && $4=="def" {n++} END{print n+0}' "$H/.apps.add")")" ok
  fi
  rm -f "$H/.apps.add"
  echo $((after - before))
}

apps_rerecommend() { # 云端下发了新的应用推荐 (或首次扫描时还没拿到): 把「首次扫描给的默认值 (def) 且仍是直连」的应用刷新成推荐值
  [ -s "$H/overrides.tsv" ] || return 0
  LC_ALL=C awk -F'|' -v OFS='|' -v conf="$(content_file apps.conf)" '
    BEGIN { while ((getline line < conf) > 0) { if (line ~ /^[ \t]*(#|$)/) continue; split(line, a, "|"); pat[++np] = tolower(a[1]); rec[np] = a[2] } }
    $1 == "app" && $4 == "def" && $3 == "direct" {
      ln = tolower($2); r = ""
      for (i = 1; i <= np; i++) { p = pat[i]
        if (substr(p, length(p), 1) == "*") { pre = substr(p, 1, length(p) - 1); if (substr(ln, 1, length(pre)) == pre) { r = rec[i]; break } }
        else if (ln == p) { r = rec[i]; break } }
      if (r != "" && r != "direct") $3 = r
    } { print }' "$H/overrides.tsv" > "$H/overrides.tsv.new" && mv "$H/overrides.tsv.new" "$H/overrides.tsv"
}

# 每个应用的「识别时间」(第一次被扫描到, 之后不变) 和「安装时间」(应用目录的创建时间; 应用更新后会变): $H/apps.times  名称<TAB>识别<TAB>安装 (epoch 秒; 0 = 不知道)
apps_times_update() {
  local f="$H/apps.times" b name path
  [ -s "$H/.apps.now" ] || return 0
  touch "$f"; b=$(mktemp)
  while IFS=$'\t' read -r name path; do [ -n "$name" ] && printf '%s\t%s\n' "$name" "$(os_birth_time "$path")"; done < "$H/.apps.now" > "$b"
  # 旧文件在 BEGIN 里读: 不能用 `NR == FNR` 两个文件的写法 —— 旧文件是空的 (第一次扫描 / 以前被这个写法清空过) 时 FNR 永远追上 NR, 新数据整个被当成「旧文件」吞掉, 文件永远是空的
  LC_ALL=C awk -F'\t' -v now="$(now)" -v old="$f" '
    BEGIN { while ((getline line < old) > 0) { split(line, a, "\t"); if (a[1] != "" && a[2] ~ /^[0-9]+$/ && a[2] + 0 > 0) s[a[1]] = a[2] } close(old) }
    { i = $2; if (i !~ /^[0-9]+$/) i = 0; printf "%s\t%s\t%s\n", $1, ($1 in s ? s[$1] : now), i }' "$b" > "$f.new" && mv "$f.new" "$f"
  rm -f "$b" "$f.new"
}

apps_json() { # 已安装应用 + 当前状态 + 推荐 (JSON 数组)
  [ -s "$H/.apps.now" ] || apps_installed > "$H/.apps.now"
  LC_ALL=C awk -F'\t' -v conf="$(content_file apps.conf)" -v ovr="$H/overrides.tsv" -v cust="$H/custom-apps.tsv" -v icx="$H/ui/appicons/index.tsv" -v tms="$H/apps.times" -v pins="$(ovr_pins | paste -sd'|' -)" '
    BEGIN {
      while ((getline line < conf) > 0) { if (line ~ /^[ \t]*(#|$)/) continue; split(line, a, "|"); pat[++np] = tolower(a[1]); rec[np] = a[2]; grp[np] = a[3] }
      while ((getline line < ovr) > 0) { split(line, b, "|"); if (b[1] == "app") { st[b[2]] = b[3]; fl[b[2]] = b[4]; tg[b[2]] = b[5] } }
      while ((getline line < cust) > 0) { split(line, c, "|"); cu[c[1]] = c[2] }
      while ((getline line < icx) > 0) { split(line, d, "\t"); ic[d[1]] = d[2] }
      while ((getline line < tms) > 0) { split(line, e, "\t"); sn[e[1]] = e[2] + 0; ins[e[1]] = e[3] + 0 }
      n_p = split(pins, PP, "|"); for (i = 1; i <= n_p; i++) pv[PP[i]] = 1
      printf "["
    }
    {
      name = $1; path = $2
      if (name ~ /["\\]/ || path ~ /["\\]/) next
      ln = tolower(name); r = ""; g = "其他"
      for (i = 1; i <= np; i++) {
        p = pat[i]
        if (substr(p, length(p), 1) == "*") { pre = substr(p, 1, length(p) - 1); if (substr(ln, 1, length(pre)) == pre) { r = rec[i]; g = grp[i]; break } }
        else if (ln == p) { r = rec[i]; g = grp[i]; break }
      }
      s = (name in st) ? st[name] : "direct"; f = (name in fl) ? fl[name] : "ack"; t = (name in tg) ? tg[name] : ""
      if (name in cu) g = (g == "其他" ? "自定义" : g)
      tv = (t == "" || t == "PINAUTO" || (t in pv)) ? "true" : "false"
      printf "%s{\"name\":\"%s\",\"state\":\"%s\",\"flag\":\"%s\",\"target\":\"%s\",\"target_ok\":%s,\"known\":%s,\"rec\":\"%s\",\"group\":\"%s\",\"path\":\"%s\",\"custom\":%s,\"kind\":\"%s\",\"icon\":\"%s\",\"installed\":%d,\"seen\":%d}", (n++ ? "," : ""), name, s, f, t, tv, (r == "" ? "false" : "true"), r, g, path, ((name in cu) ? "true" : "false"), ((name in cu) ? cu[name] : "app"), ((name in ic) ? ic[name] : ""), ((name in ins) ? ins[name] : 0), ((name in sn) ? sn[name] : 0)
    }
    END { printf "]" }' "$H/.apps.now"
}

apps_new_count() { awk -F'|' '$1=="app" && $4=="new" {n++} END{print n+0}' "$H/overrides.tsv" 2>/dev/null; }

apps_adopt() { # [名称文件]  把 flag=new 的应用 (或只把名称文件里 (每行一个) 的应用) 设为推荐状态; 没有推荐值的不动
  [ -s "$H/overrides.tsv" ] || return 0
  LC_ALL=C awk -F'|' -v OFS='|' -v conf="$(content_file apps.conf)" -v nf="${1:-}" '
    BEGIN { while ((getline line < conf) > 0) { if (line ~ /^[ \t]*(#|$)/) continue; split(line, a, "|"); pat[++np] = tolower(a[1]); rec[np] = a[2] }
            if (nf != "") { sel = 1; while ((getline line < nf) > 0) if (line != "") want[line] = 1 } }
    $1 == "app" && ((!sel && $4 == "new") || ($2 in want)) {
      ln = tolower($2); r = ""
      for (i = 1; i <= np; i++) { p = pat[i]
        if (substr(p, length(p), 1) == "*") { pre = substr(p, 1, length(p) - 1); if (substr(ln, 1, length(pre)) == pre) { r = rec[i]; break } }
        else if (ln == p) { r = rec[i]; break } }
      if (r != "") { $3 = r; $4 = "ack"; $5 = "" }
    } { print }' "$H/overrides.tsv" > "$H/overrides.tsv.new" && mv "$H/overrides.tsv.new" "$H/overrides.tsv"
  ovr_sync
}
apps_ack() { # 名称 | all
  [ -s "$H/overrides.tsv" ] || return 0
  LC_ALL=C awk -F'|' -v OFS='|' -v n="$1" '$1=="app" && $4=="new" && (n=="all" || $2==n) { $4="ack" } { print }' "$H/overrides.tsv" > "$H/overrides.tsv.new" && mv "$H/overrides.tsv.new" "$H/overrides.tsv"
}

overrides_json() { # 仅网站覆盖 (应用走 apps_json); 带出口 (target, target_ok = 指定的固定出口还在) 和来源 (src: user 你添加的 / auto 自动识别添加的)
  [ -s "$H/overrides.tsv" ] || { printf '[]'; return 0; }
  awk -F'|' -v auto="$H/autosites.tsv" -v pins="$(ovr_pins | paste -sd'|' -)" '
    BEGIN { while ((getline line < auto) > 0) { split(line, a, "|"); at[a[1]] = a[2]; why[a[1]] = a[3]; fails[a[1]] = a[4]; app[a[1]] = a[5] }
            n_p = split(pins, PP, "|"); for (i = 1; i <= n_p; i++) pv[PP[i]] = 1; printf "[" }
    $1=="site" { src = ($2 in at) ? "auto" : "user"; tv = ($5 == "" || $5 == "PINAUTO" || ($5 in pv)) ? "true" : "false"
      printf "%s{\"kind\":\"site\",\"value\":\"%s\",\"state\":\"%s\",\"target\":\"%s\",\"target_ok\":%s,\"src\":\"%s\",\"at\":%d,\"why\":\"%s\",\"fails\":%d,\"app\":\"%s\"}", (n++?",":""), $2, $3, $5, tv, src, at[$2] + 0, why[$2], fails[$2] + 0, app[$2] }
    END { printf "]" }' "$H/overrides.tsv"
}

# ---------- 应用图标 (后台提取, 前端 <img> 直接引用 appicons/<名>.png; 取不到时前端用字母头像) ----------
app_icon_slug() { local s; s=$(printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_' | cut -c1-40); printf '%s-%s' "$s" "$(printf '%s' "$1" | cksum | cut -d' ' -f1)"; }
apps_icons() { # 为还没有图标的应用提取图标并重建索引 (一次只跑一个; 失败/没有的就跳过)
  local d="$H/ui/appicons" lst name path slug
  mkdir -p "$d"
  if ! mkdir "$H/.icons.lock" 2>/dev/null; then [ -n "$(find "$H/.icons.lock" -maxdepth 0 -mmin +3 2>/dev/null)" ] && rmdir "$H/.icons.lock" 2>/dev/null; return 0; fi
  lst=$(mktemp)
  while IFS=$'\t' read -r name path; do
    [ -n "$name" ] && { [ -d "$path" ] || { [ "${ENANA_PLATFORM:-darwin}" = windows ] && [ -f "$path" ]; }; } || continue
    slug=$(app_icon_slug "$name"); [ -s "$d/$slug.png" ] || printf '%s\t%s\n' "$slug" "$path" >> "$lst"
  done < <([ -s "$H/.apps.now" ] && cat "$H/.apps.now" || apps_installed)
  if [ -s "$lst" ]; then
    if [ "${ENANA_PLATFORM:-darwin}" = windows ]; then win_bridge icons "$(cygpath -w "$lst")" >/dev/null 2>&1 || true
    else osascript -l JavaScript "$LIB/appicon.js" "$d" "$lst" >/dev/null 2>&1 || true; fi
  fi
  : > "$d/index.tsv.new"
  while IFS=$'\t' read -r name path; do
    [ -n "$name" ] || continue
    slug=$(app_icon_slug "$name"); [ -s "$d/$slug.png" ] && printf '%s\tappicons/%s.png\n' "$name" "$slug" >> "$d/index.tsv.new"
  done < <([ -s "$H/.apps.now" ] && cat "$H/.apps.now" || apps_installed)
  mv "$d/index.tsv.new" "$d/index.tsv"; rm -f "$lst"; rmdir "$H/.icons.lock" 2>/dev/null || true
}

# ---------- 自定义软件: 校验 + 添加 / 删除 ----------
# 自定义软件保存在 $H/custom-apps.tsv:  名称|类型(app|bin)|路径|BundleID|添加时间。不会执行这些程序, 只读它们的信息。
_ja() { printf '%s' "$1" | tr -d '"\\' | tr '\000-\037' ' ' | cut -c1-200; }            # JSON 字符串 (去掉引号/反斜杠/控制字符)
app_exists_name() { # 这个名称是否已在应用列表里 (自动识别的 + 自定义的 + 已有覆盖)
  { apps_installed | cut -f1; awk -F'|' '$1=="app" {print $2}' "$H/overrides.tsv" 2>/dev/null; } | grep -Fxq -- "$1"
}
apps_inspect_path() { # 绝对路径 -> 打印一个候选对象 (JSON); 路径只读, 绝不执行
  if [ "${ENANA_PLATFORM:-darwin}" = windows ]; then win_bridge app-inspect "$1"; return; fi
  local p=$1 dir real name='' bid='' ver='' exe='' kind='' signed=false auth='' team='' reason='' sig plist icon='' ex=false
  case $p in /*) ;; *) printf '{"valid":false,"path":"%s","reason":"%s"}' "$(_ja "$p")" "$(_ja "$(_t "请输入绝对路径 (以 / 开头), 或者输入软件名称")")"; return ;; esac
  printf '%s' "$p" | LC_ALL=C grep -q '[|"\\[:cntrl:]]' && { printf '{"valid":false,"path":"%s","reason":"%s"}' "$(_ja "$p")" "$(_ja "$(_t "路径里有不支持的字符")")"; return; }
  p=${p%/}
  if [ ! -e "$p" ]; then printf '{"valid":false,"path":"%s","reason":"%s"}' "$(_ja "$p")" "$(_ja "$(_t "路径不存在")")"; return; fi
  dir=$(cd "$(dirname "$p")" 2>/dev/null && pwd -P) || { printf '{"valid":false,"path":"%s","reason":"%s"}' "$(_ja "$p")" "$(_ja "$(_t "没有读取权限")")"; return; }
  real="$dir/$(basename "$p")"
  case $real in
    *.app)
      plist="$real/Contents/Info.plist"
      [ -d "$real" ] && [ -f "$plist" ] || { printf '{"valid":false,"path":"%s","reason":"%s"}' "$(_ja "$real")" "$(_ja "$(_t "这不是有效的应用 (缺少 Info.plist)")")"; return; }
      kind=app; name=$(basename "$real" .app)
      bid=$(plutil -extract CFBundleIdentifier raw -o - "$plist" 2>/dev/null || true); ver=$(plutil -extract CFBundleShortVersionString raw -o - "$plist" 2>/dev/null || true)
      exe=$(plutil -extract CFBundleExecutable raw -o - "$plist" 2>/dev/null || true)
      [ -n "$exe" ] && [ -x "$real/Contents/MacOS/$exe" ] || { printf '{"valid":false,"path":"%s","reason":"%s"}' "$(_ja "$real")" "$(_ja "$(_t "应用里找不到可执行文件, 可能已损坏")")"; return; } ;;
    *)
      [ -f "$real" ] && [ -x "$real" ] || { printf '{"valid":false,"path":"%s","reason":"%s"}' "$(_ja "$real")" "$(_ja "$(_t "不是应用 (.app) 或可执行文件")")"; return; }
      case "$(file -b "$real" 2>/dev/null)" in *Mach-O*|*script*) ;; *) printf '{"valid":false,"path":"%s","reason":"%s"}' "$(_ja "$real")" "$(_ja "$(_t "不是应用 (.app) 或可执行文件")")"; return ;; esac
      kind=bin; name=$(basename "$real"); exe=$name ;;
  esac
  printf '%s' "$name" | LC_ALL=C grep -q '[|"\\[:cntrl:]]' && { printf '{"valid":false,"path":"%s","reason":"%s"}' "$(_ja "$real")" "$(_ja "$(_t "名称里有不支持的字符")")"; return; }
  sig=$(codesign -dv --verbose=2 "$real" 2>&1 || true)
  case $sig in *"not signed at all"*|'') ;; *) signed=true; auth=$(printf '%s\n' "$sig" | sed -n 's/^Authority=//p' | head -1); team=$(printf '%s\n' "$sig" | sed -n 's/^TeamIdentifier=//p' | head -1); [ "$team" = "not set" ] && team='' ;; esac
  app_exists_name "$name" && ex=true
  if [ "$kind" = app ]; then   # 预览用的图标 (已有就直接用)
    apps_icon_one "$name" "$real" && icon="appicons/$(app_icon_slug "$name").png"
  fi
  printf '{"valid":true,"kind":"%s","name":"%s","bundle_id":"%s","version":"%s","path":"%s","exec":"%s","signed":%s,"authority":"%s","team":"%s","icon":"%s","exists":%s,"matches_running":%s}' \
    "$kind" "$(_ja "$name")" "$(_ja "$bid")" "$(_ja "$ver")" "$(_ja "$real")" "$(_ja "$exe")" "$signed" "$(_ja "$auth")" "$(_ja "$team")" "$icon" "$ex" "$(pgrep -f -- "$real" >/dev/null 2>&1 && echo true || echo false)"
}
apps_icon_one() { # <名称> <路径>  提取单个图标 (0 = 成功/已有)
  [ "${ENANA_PLATFORM:-darwin}" != windows ] || return 1
  local d="$H/ui/appicons" slug lst; slug=$(app_icon_slug "$1"); mkdir -p "$d"
  [ -s "$d/$slug.png" ] && return 0
  lst=$(mktemp); printf '%s\t%s\n' "$slug" "$2" > "$lst"; osascript -l JavaScript "$LIB/appicon.js" "$d" "$lst" >/dev/null 2>&1; rm -f "$lst"
  [ -s "$d/$slug.png" ]
}
apps_inspect() { # <输入: 绝对路径 或 软件名称> -> 候选数组 JSON 的内容 (不含方括号); 名称最多 8 个候选
  local in=$1 f out='' n=0 p
  if [ "${ENANA_PLATFORM:-darwin}" = windows ]; then
    case $1 in [A-Za-z]:*|\\\\*) apps_inspect_path "$1"; return ;; esac
    local candidate; candidate=$(apps_installed | awk -F'\t' -v n="$1" 'tolower($1)==tolower(n){print $2;exit}')
    apps_inspect_path "${candidate:-$1}"; return
  fi
  in=$(printf '%s' "$in" | tr -d '\r\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^["'"'"']//; s/["'"'"']$//'); [ ${#in} -le 300 ] || in=${in:0:300}
  case $in in
    '') printf '{"valid":false,"path":"","reason":"%s"}' "$(_ja "$(_t "请输入软件的路径或名称")")"; return ;;
    /*) apps_inspect_path "$in"; return ;;
  esac
  case $in in */*) printf '{"valid":false,"path":"","reason":"%s"}' "$(_ja "$(_t "请输入绝对路径 (以 / 开头), 或者输入软件名称")")"; return ;; esac
  case $in in */*) printf '{"valid":false,"path":"","reason":"%s"}' "$(_ja "$(_t "请输入绝对路径 (以 / 开头), 或者输入软件名称")")"; return ;; esac      # 带斜杠但不是绝对路径
  printf '%s' "$in" | LC_ALL=C grep -q '[][*?|"\\[:cntrl:]/]' && { printf '{"valid":false,"path":"","reason":"%s"}' "$(_ja "$(_t "名称里有不支持的字符")")"; return; }
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    f=$(apps_inspect_path "$p"); out="$out${out:+,}$f"; n=$((n+1)); [ "$n" -ge 8 ] && break
  done < <( { find ${ENANA_APPS_ROOTS:-$APPS_ROOTS_PRIO "$HOME/Applications"} -maxdepth 4 -iname "*$in*.app" -prune 2>/dev/null
              find /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" -maxdepth 1 -iname "$in" 2>/dev/null; } | head -n 8 )
  [ -n "$out" ] || { printf '{"valid":false,"path":"","reason":"%s"}' "$(_ja "$(_t "没有找到这个软件: 请检查名称, 或者直接输入它的完整路径")")"; return; }
  printf '%s' "$out"
}
apps_custom_add() { # <路径> <状态> -> 0 成功; 失败时 APPS_ERR 里有原因
  local p=$1 st=$2 j name kind bid
  APPS_ERR=''
  case $st in follow|direct|pin|auto) ;; *) APPS_ERR="状态无效"; return 1 ;; esac
  j=$(apps_inspect_path "$p")
  case $j in *'"valid":true'*) ;; *) APPS_ERR=$(printf '%s' "$j" | sed -n 's/.*"reason":"\([^"]*\)".*/\1/p'); [ -n "$APPS_ERR" ] || APPS_ERR="软件校验失败"; return 1 ;; esac
  case $j in *'"exists":true'*) APPS_ERR="这个软件已经在列表里了"; return 1 ;; esac
  name=$(printf '%s' "$j" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p'); kind=$(printf '%s' "$j" | sed -n 's/.*"kind":"\([a-z]*\)".*/\1/p'); bid=$(printf '%s' "$j" | sed -n 's/.*"bundle_id":"\([^"]*\)".*/\1/p')
  p=$(printf '%s' "$j" | sed -n 's/.*"path":"\([^"]*\)".*/\1/p')
  ovr_valid app "$name" || { APPS_ERR="名称里有不支持的字符"; return 1; }
  touch "$H/custom-apps.tsv"; chmod 600 "$H/custom-apps.tsv"
  printf '%s|%s|%s|%s|%s\n' "$name" "$kind" "$p" "$bid" "$(now)" >> "$H/custom-apps.tsv"
  ovr_set app "$name" "$st" ack
  apps_installed > "$H/.apps.now"
  return 0
}
apps_custom_delete() { # <名称>
  [ -s "$H/custom-apps.tsv" ] && awk -F'|' -v n="$1" '$1==n {f=1} END{exit f?0:1}' "$H/custom-apps.tsv" || { APPS_ERR="找不到这个自定义软件"; return 1; }
  awk -F'|' -v n="$1" '$1!=n' "$H/custom-apps.tsv" > "$H/custom-apps.tsv.new" && mv "$H/custom-apps.tsv.new" "$H/custom-apps.tsv"
  ovr_delete app "$1"; apps_installed > "$H/.apps.now"
}
