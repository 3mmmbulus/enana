# 应用识别 + 用户覆盖层。
# 覆盖层 = 用户对「某个应用 / 某个网站」的显式设置, 保存在 $H/overrides.tsv:  类型|名称|状态|标记
#   类型 app|site;  状态 follow(跟随规则=开) direct(直连=关) pin(全走固定出口) auto(全走自动线路);  标记 new|ack
# 三种非 follow 状态分别写成三个 sing-box 本地规则集 (rules/ovr-direct|pin|auto.json), sing-box 监视文件变化,
# 因此切换应用/网站无需重启、不会断开现有连接。
#
# 应用规则: 新装应用默认「关」(direct, 标记 new)。首次识别时, 已知应用(data/apps.conf)采用推荐设置。

ovr_file() { printf '%s\n' "$H/overrides.tsv"; }

ovr_valid() { # kind value
  local k=$1 v=$2
  [ -n "$v" ] && [ ${#v} -le 80 ] || return 1
  case $k in
    app)  printf '%s' "$v" | LC_ALL=C grep -q '[|"\\/[:cntrl:]]' && return 1; return 0 ;;
    site) printf '%s' "$v" | LC_ALL=C grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' ;;
    *) return 1 ;;
  esac
}

ovr_set() { # kind value state [flag]  (upsert, 原子写)
  local k=$1 v=$2 s=$3 f=${4:-ack}
  touch "$H/overrides.tsv"
  LC_ALL=C awk -F'|' -v OFS='|' -v k="$k" -v v="$v" -v s="$s" -v f="$f" '
    $1==k && $2==v { $3=s; $4=f; found=1 } { print } END { if (!found) print k, v, s, f }' "$H/overrides.tsv" > "$H/overrides.tsv.new" \
    && mv "$H/overrides.tsv.new" "$H/overrides.tsv"
}
ovr_delete() { # kind value
  [ -f "$H/overrides.tsv" ] || return 0
  LC_ALL=C awk -F'|' -v k="$1" -v v="$2" '!($1==k && $2==v)' "$H/overrides.tsv" > "$H/overrides.tsv.new" && mv "$H/overrides.tsv.new" "$H/overrides.tsv"
}
ovr_get() { awk -F'|' -v k="$1" -v v="$2" '$1==k && $2==v {print $3; exit}' "$H/overrides.tsv" 2>/dev/null; }

json_list() { # stdin 每行一个字符串 -> "a","b"  (调用方保证内容不含引号/反斜杠)
  sed 's/.*/"&"/' | paste -sd, -
}
app_regex_json() { # 应用名 -> JSON 字符串内容: (?i)/名称\\.app/  (点号等已转义)
  local n=$1
  n=$(printf '%s' "$n" | sed -e 's/[][\.*^$+?(){}|]/\\&/g')
  printf '(?i)/%s\\.app/' "$n" | sed 's/\\/\\\\/g'
}

ovr_sync() { # 由 overrides.tsv 生成三个规则集文件 (原地覆盖写, 让 sing-box 的文件监视生效)
  local st sites apps bins rules body f bset
  mkdir -p "$H/rules"
  bset="|$(awk -F'|' '$2=="bin" {printf "%s|", $1}' "$H/custom-apps.tsv" 2>/dev/null)"        # 自定义的命令行工具 (按可执行文件名匹配, 不是 .app 路径)
  for st in direct pin auto; do
    sites=$(awk -F'|' -v s="$st" '$1=="site" && $3==s {print $2}' "$H/overrides.tsv" 2>/dev/null | json_list)
    apps=''; bins=''
    while IFS= read -r a; do
      [ -n "$a" ] || continue
      case $bset in *"|$a|"*) bins="$bins${bins:+,}\"$a\"" ;; *) apps="$apps${apps:+,}\"$(app_regex_json "$a")\"" ;; esac
    done < <(awk -F'|' -v s="$st" '$1=="app" && $3==s {print $2}' "$H/overrides.tsv" 2>/dev/null)
    rules=''
    [ -n "$sites" ] && rules="{\"domain_suffix\":[$sites]}"
    [ -n "$apps" ] && rules="$rules${rules:+,}{\"process_path_regex\":[$apps]}"
    [ -n "$bins" ] && rules="$rules${rules:+,}{\"process_name\":[$bins]}"
    [ -n "$rules" ] || rules='{"domain":["enana-placeholder.invalid"]}'   # 空规则集占位 (不会匹配任何域名)
    body="{\"version\":3,\"rules\":[$rules]}"
    f="$H/rules/ovr-$st.json"
    if [ ! -f "$f" ] || [ "$(cat "$f")" != "$body" ]; then printf '%s\n' "$body" > "$f.tmp" && cat "$f.tmp" > "$f" && rm -f "$f.tmp"; fi
  done
}

# ---------- 应用扫描 ----------
apps_installed() { # 每行: 名称<TAB>路径  (自动识别的 + 用户手动添加的自定义软件)
  {
    { find /Applications "$HOME/Applications" -maxdepth 2 -name '*.app' -prune 2>/dev/null || true; } \
      | LC_ALL=C awk -F/ '{ n = $NF; sub(/\.app$/, "", n); if (n != "" && substr(n,1,1) != ".") print n "\t" $0 }'
    [ -s "$H/custom-apps.tsv" ] && awk -F'|' '{ print $1 "\t" $3 }' "$H/custom-apps.tsv"
  } | LC_ALL=C sort -u -t"$(printf '\t')" -k1,1
}

apps_scan() { # 新应用写入 overrides.tsv: 首次扫描=已知用推荐/其余直连(标记 ack); 之后=一律直连(标记 new). 打印新增数量
  local first=0 before after
  [ -f "$H/apps.seen" ] || first=1
  touch "$H/overrides.tsv"
  apps_installed > "$H/.apps.now"
  before=$(wc -l < "$H/overrides.tsv" | tr -d ' ')
  LC_ALL=C awk -F'\t' -v first="$first" -v conf="$(content_file apps.conf)" -v ovr="$H/overrides.tsv" '
    BEGIN {
      while ((getline line < conf) > 0) { if (line ~ /^[ \t]*(#|$)/) continue; split(line, a, "|"); pat[++np] = tolower(a[1]); rec[np] = a[2] }
      while ((getline line < ovr) > 0) { split(line, b, "|"); if (b[1] == "app") known[b[2]] = 1 }
    }
    {
      name = $1
      if (name in known || name ~ /[|"\\\/]/ || length(name) > 80) next
      ln = tolower(name); r = ""
      for (i = 1; i <= np; i++) {
        p = pat[i]
        if (substr(p, length(p), 1) == "*") { pre = substr(p, 1, length(p) - 1); if (substr(ln, 1, length(pre)) == pre) { r = rec[i]; break } }
        else if (ln == p) { r = rec[i]; break }
      }
      if (first) print "app|" name "|" (r == "" ? "direct" : r) "|ack"
      else print "app|" name "|direct|new"
    }' "$H/.apps.now" >> "$H/overrides.tsv"
  after=$(wc -l < "$H/overrides.tsv" | tr -d ' ')
  : > "$H/apps.seen"
  ovr_sync
  echo $((after - before))
}

apps_json() { # 已安装应用 + 当前状态 + 推荐 (JSON 数组)
  [ -s "$H/.apps.now" ] || apps_installed > "$H/.apps.now"
  LC_ALL=C awk -F'\t' -v conf="$(content_file apps.conf)" -v ovr="$H/overrides.tsv" -v cust="$H/custom-apps.tsv" -v icx="$H/ui/appicons/index.tsv" '
    BEGIN {
      while ((getline line < conf) > 0) { if (line ~ /^[ \t]*(#|$)/) continue; split(line, a, "|"); pat[++np] = tolower(a[1]); rec[np] = a[2]; grp[np] = a[3] }
      while ((getline line < ovr) > 0) { split(line, b, "|"); if (b[1] == "app") { st[b[2]] = b[3]; fl[b[2]] = b[4] } }
      while ((getline line < cust) > 0) { split(line, c, "|"); cu[c[1]] = c[2] }
      while ((getline line < icx) > 0) { split(line, d, "\t"); ic[d[1]] = d[2] }
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
      s = (name in st) ? st[name] : "direct"; f = (name in fl) ? fl[name] : "ack"
      if (name in cu) g = (g == "其他" ? "自定义" : g)
      printf "%s{\"name\":\"%s\",\"state\":\"%s\",\"flag\":\"%s\",\"known\":%s,\"rec\":\"%s\",\"group\":\"%s\",\"path\":\"%s\",\"custom\":%s,\"kind\":\"%s\",\"icon\":\"%s\"}", (n++ ? "," : ""), name, s, f, (r == "" ? "false" : "true"), r, g, path, ((name in cu) ? "true" : "false"), ((name in cu) ? cu[name] : "app"), ((name in ic) ? ic[name] : "")
    }
    END { printf "]" }' "$H/.apps.now"
}

apps_new_count() { awk -F'|' '$1=="app" && $4=="new" {n++} END{print n+0}' "$H/overrides.tsv" 2>/dev/null; }

apps_adopt() { # 把所有 flag=new 且有推荐值的应用设为推荐状态
  [ -s "$H/overrides.tsv" ] || return 0
  LC_ALL=C awk -F'|' -v OFS='|' -v conf="$(content_file apps.conf)" '
    BEGIN { while ((getline line < conf) > 0) { if (line ~ /^[ \t]*(#|$)/) continue; split(line, a, "|"); pat[++np] = tolower(a[1]); rec[np] = a[2] } }
    $1 == "app" && $4 == "new" {
      ln = tolower($2); r = ""
      for (i = 1; i <= np; i++) { p = pat[i]
        if (substr(p, length(p), 1) == "*") { pre = substr(p, 1, length(p) - 1); if (substr(ln, 1, length(pre)) == pre) { r = rec[i]; break } }
        else if (ln == p) { r = rec[i]; break } }
      if (r != "") { $3 = r; $4 = "ack" }
    } { print }' "$H/overrides.tsv" > "$H/overrides.tsv.new" && mv "$H/overrides.tsv.new" "$H/overrides.tsv"
  ovr_sync
}
apps_ack() { # 名称 | all
  [ -s "$H/overrides.tsv" ] || return 0
  LC_ALL=C awk -F'|' -v OFS='|' -v n="$1" '$1=="app" && $4=="new" && (n=="all" || $2==n) { $4="ack" } { print }' "$H/overrides.tsv" > "$H/overrides.tsv.new" && mv "$H/overrides.tsv.new" "$H/overrides.tsv"
}

overrides_json() { # 仅网站覆盖 (应用走 apps_json)
  [ -s "$H/overrides.tsv" ] || { printf '[]'; return 0; }
  awk -F'|' 'BEGIN{printf "["} $1=="site" {printf "%s{\"kind\":\"site\",\"value\":\"%s\",\"state\":\"%s\"}", (n++?",":""), $2, $3} END{printf "]"}' "$H/overrides.tsv"
}

# ---------- 应用图标 (后台提取, 前端 <img> 直接引用 appicons/<名>.png; 取不到时前端用字母头像) ----------
app_icon_slug() { local s; s=$(printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_' | cut -c1-40); printf '%s-%s' "$s" "$(printf '%s' "$1" | cksum | cut -d' ' -f1)"; }
apps_icons() { # 为还没有图标的应用提取图标并重建索引 (一次只跑一个; 失败/没有的就跳过)
  local d="$H/ui/appicons" lst name path slug
  mkdir -p "$d"
  if ! mkdir "$H/.icons.lock" 2>/dev/null; then [ -n "$(find "$H/.icons.lock" -maxdepth 0 -mmin +3 2>/dev/null)" ] && rmdir "$H/.icons.lock" 2>/dev/null; return 0; fi
  lst=$(mktemp)
  while IFS=$'\t' read -r name path; do
    [ -n "$name" ] && [ -d "$path" ] || continue
    slug=$(app_icon_slug "$name"); [ -s "$d/$slug.png" ] || printf '%s\t%s\n' "$slug" "$path" >> "$lst"
  done < <([ -s "$H/.apps.now" ] && cat "$H/.apps.now" || apps_installed)
  [ -s "$lst" ] && { osascript -l JavaScript "$LIB/appicon.js" "$d" "$lst" >/dev/null 2>&1 || true; }
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
  local d="$H/ui/appicons" slug lst; slug=$(app_icon_slug "$1"); mkdir -p "$d"
  [ -s "$d/$slug.png" ] && return 0
  lst=$(mktemp); printf '%s\t%s\n' "$slug" "$2" > "$lst"; osascript -l JavaScript "$LIB/appicon.js" "$d" "$lst" >/dev/null 2>&1; rm -f "$lst"
  [ -s "$d/$slug.png" ]
}
apps_inspect() { # <输入: 绝对路径 或 软件名称> -> 候选数组 JSON 的内容 (不含方括号); 名称最多 8 个候选
  local in=$1 f out='' n=0 p
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
  done < <( { find /Applications "$HOME/Applications" /System/Applications /Applications/Utilities -maxdepth 2 -iname "*$in*.app" -prune 2>/dev/null
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
