# 网站规则的域名编辑: 用户可以查看 / 添加 / 修改 / 删除某个服务条目的域名, 并一键重置为系统默认。依赖 common.sh config.sh(catalog_list)。
#
# 用户的改动保存在 $H/site-domains.tsv:  条目id|+|域名 (用户添加)  /  条目id|-|域名 (用户从系统列表里删掉)。
# 生效的域名 = (系统域名 − 已删除) ∪ 已添加。云端内容更新只换系统列表, 用户的改动单独保存、不会被覆盖; 重置 = 删除该条目的全部改动。

SITE_EDITS=${SITE_EDITS:-$H/site-domains.tsv}

site_entry() { catalog_list | awk -F'|' -v id="$1" '$1==id {print; exit}'; }          # 条目的原始行 (没有则空)

site_domain_norm() { # 规范化用户输入: 小写、去首尾空白、去结尾的点
  printf '%s' "$1" | tr 'A-Z' 'a-z' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/\.$//'
}
site_domain_valid() { # 0 = 合法 (不含通配符/协议/路径/空格; 每段 ≤ 63, 总长 ≤ 253; 中文域名请用 punycode xn--…)
  local d=$1
  case $d in *$'\n'*|*$'\r'*) return 1 ;; esac
  [ ${#d} -le 253 ] && printf '%s' "$d" | LC_ALL=C grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' || return 1
  printf '%s' "$d" | awk -F. '{ for (i = 1; i <= NF; i++) if (length($i) > 63) exit 1 }'
}

# 当前生效的域名, 每行: 域名<TAB>来源(system|added)
site_effective() { # <id>
  local line; line=$(site_entry "$1"); [ -n "$line" ] || return 1
  printf '%s\n' "$line" | awk -F'|' -v id="$1" -v ed="$SITE_EDITS" '
    BEGIN { while ((getline l < ed) > 0) { split(l, e, "|"); if (e[1] != id) continue; if (e[2] == "-") del[e[3]] = 1; else if (e[2] == "+") { add[++na] = e[3] } } }
    { n = split($5, s, ","); for (i = 1; i <= n; i++) if (s[i] != "" && !(s[i] in del)) { seen[s[i]] = 1; print s[i] "\tsystem" }
      for (i = 1; i <= na; i++) if (!(add[i] in seen)) { seen[add[i]] = 1; print add[i] "\tadded" } }'
}

# GET /api/sites/domains 的主体 (不含最外层 ok)
sites_domains_json() { # <id>
  local line name rs cidrs pol removed system dom
  line=$(site_entry "$1"); [ -n "$line" ] || return 1
  name=$(printf '%s' "$line" | cut -d'|' -f2); pol=$(printf '%s' "$line" | cut -d'|' -f4); rs=$(printf '%s' "$line" | cut -d'|' -f6)
  cidrs=$(printf '%s' "$line" | cut -d'|' -f7 | awk -F, '{ c = 0; for (i = 1; i <= NF; i++) if ($i != "") c++; print c }')
  system=$(printf '%s' "$line" | cut -d'|' -f5 | tr ',' '\n' | awk 'NF { printf "%s\"%s\"", (n++ ? "," : ""), $0 }')
  local ed=$SITE_EDITS; [ -f "$ed" ] || ed=/dev/null           # 还没有任何改动时文件不存在
  removed=$(awk -F'|' -v id="$1" '$1==id && $2=="-" { printf "%s\"%s\"", (n++ ? "," : ""), $3 }' "$ed")
  dom=$(site_effective "$1" | awk -F'\t' '{ printf "%s{\"domain\":\"%s\",\"source\":\"%s\"}", (n++ ? "," : ""), $1, $2 }')
  printf '"id":"%s","name":"%s","modified":%s,"system":[%s],"domains":[%s],"removed":[%s],"rulesets":[%s],"cidrs":%s,"policy":"%s"' \
    "$1" "$(jesc "$name")" "$(awk -F'|' -v id="$1" '$1==id {f=1} END{print f ? "true" : "false"}' "$ed")" "$system" "$dom" "$removed" \
    "$(printf '%s' "$rs" | tr ',' '\n' | awk 'NF { printf "%s\"%s\"", (n++ ? "," : ""), $0 }')" "${cidrs:-0}" "$pol"
}

# sites_edit <id> <add|remove|update|restore> <域名> [新域名]  -> 0 成功; 失败时 SITES_ERR 是原因 (中文原文)
sites_edit() {
  local id=$1 act=$2 d new='' sys has_sys=0 has_add=0 total
  SITES_ERR=''
  [ -n "$(site_entry "$id")" ] || { SITES_ERR="找不到这个网站条目"; return 1; }
  d=$(site_domain_norm "$3"); new=$(site_domain_norm "${4:-}")
  site_domain_valid "$d" || { SITES_ERR="域名格式不正确: 只能是小写字母/数字/连字符和点, 不含 http://、路径、空格和通配符 (中文域名请填 xn-- 开头的写法)"; return 1; }
  touch "$SITE_EDITS"
  total=$(wc -l < "$SITE_EDITS" | tr -d ' '); [ "$total" -lt 2000 ] || { SITES_ERR="自定义的域名太多了 (最多 2000 条)"; return 1; }
  site_entry "$id" | cut -d'|' -f5 | tr ',' '\n' | grep -Fxq -- "$d" && has_sys=1
  awk -F'|' -v id="$id" -v d="$d" '$1==id && $2=="+" && $3==d {f=1} END{exit f?0:1}' "$SITE_EDITS" && has_add=1
  case $act in
    add)
      if site_effective "$id" | cut -f1 | grep -Fxq -- "$d"; then SITES_ERR="已经有这个域名了"; return 1; fi
      if [ "$has_sys" = 1 ]; then _sites_row_del "$id" '-' "$d"; else
        [ "$(awk -F'|' -v id="$id" '$1==id && $2=="+" {n++} END{print n+0}' "$SITE_EDITS")" -lt 300 ] || { SITES_ERR="这个条目自定义的域名太多了 (最多 300 条)"; return 1; }
        printf '%s|+|%s\n' "$id" "$d" >> "$SITE_EDITS"; fi ;;
    remove)
      if [ "$has_add" = 1 ]; then _sites_row_del "$id" '+' "$d"
      elif [ "$has_sys" = 1 ]; then site_effective "$id" | cut -f1 | grep -Fxq -- "$d" || { SITES_ERR="这个域名已经删除了"; return 1; }; printf '%s|-|%s\n' "$id" "$d" >> "$SITE_EDITS"
      else SITES_ERR="没有这个域名"; return 1; fi ;;
    restore)
      awk -F'|' -v id="$id" -v d="$d" '$1==id && $2=="-" && $3==d {f=1} END{exit f?0:1}' "$SITE_EDITS" || { SITES_ERR="这个域名没有被删除过"; return 1; }
      _sites_row_del "$id" '-' "$d" ;;
    update)
      site_domain_valid "$new" || { SITES_ERR="新的域名格式不正确"; return 1; }
      [ "$new" != "$d" ] || { SITES_ERR="新旧域名一样, 没有修改"; return 1; }
      sites_edit "$id" remove "$d" || return 1
      sites_edit "$id" add "$new" || { _sites_row_del "$id" '+' "$d"; sites_edit "$id" add "$d" >/dev/null 2>&1; return 1; } ;;
    *) SITES_ERR="操作无效"; return 1 ;;
  esac
  return 0
}
_sites_row_del() { awk -F'|' -v id="$1" -v k="$2" -v d="$3" '!($1==id && $2==k && $3==d)' "$SITE_EDITS" > "$SITE_EDITS.new" && mv "$SITE_EDITS.new" "$SITE_EDITS"; }
sites_reset() { # <id>  删除该条目的全部改动
  [ -n "$(site_entry "$1")" ] || { SITES_ERR="找不到这个网站条目"; return 1; }
  [ -f "$SITE_EDITS" ] && awk -F'|' -v id="$1" '$1!=id' "$SITE_EDITS" > "$SITE_EDITS.new" && mv "$SITE_EDITS.new" "$SITE_EDITS"
  return 0
}
