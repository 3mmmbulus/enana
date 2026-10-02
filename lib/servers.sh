# 服务器与订阅存储。仓库里不含任何服务器信息: 全部由用户在仪表盘里填写, 保存在 $H/servers.jsonl (权限 600)。
#
# servers.jsonl 每行一个 JSON:  {"role":"auto"[,"sub":"订阅名"],"outbound":{"type":"trojan","tag":"名称",...}}
#   role: pin=固定出口(AI/账号类走它, 无自动故障转移)  auto=自动选线池  dl=仅用于下载环境  off=停用
#   outbound 是 sing-box 出站; 键顺序约定为 type, tag 在最前 (由仪表盘的 importer.js 生成, 下面的 awk 依赖它)
#   自签证书的引用写成 "certificate_path":"@CERTS@/xxx.crt", 生成配置时替换成 $H/certs
#
# 订阅保存在 $H/subs.tsv:  名称|链接|更新时间|节点数|刷新间隔(小时)|已用|总量|到期   (链接含令牌, 权限 600, 不会返回给仪表盘)

RESERVED_TAGS="direct AUTO PIN Global Final SPEEDTEST"

srv_file() { printf '%s\n' "$H/servers.jsonl"; }

srv_list() { # TSV: tag<TAB>type<TAB>server<TAB>port<TAB>role<TAB>sub
  [ -s "$H/servers.jsonl" ] || return 0
  LC_ALL=C awk '
    function str(s, key,   k, p) { k = "\"" key "\":\""; p = index(s, k); if (!p) return ""; s = substr(s, p + length(k)); return substr(s, 1, index(s, "\"") - 1) }
    function num(s, key,   k, p) { k = "\"" key "\":"; p = index(s, k); if (!p) return ""; s = substr(s, p + length(k)); match(s, /^[0-9]+/); return substr(s, 1, RLENGTH) }
    {
      i = index($0, ",\"outbound\":{\"type\":\""); if (!i) next
      head = substr($0, 1, i); ob = substr($0, i + 12)
      role = str(head, "role"); sub_ = str(head, "sub")
      rest = substr($0, i + 21); t = substr(rest, 1, index(rest, "\"") - 1)
      r2 = substr(rest, length(t) + 2); tag = ""
      if (substr(r2, 1, 8) == ",\"tag\":\"") { r3 = substr(r2, 9); tag = substr(r3, 1, index(r3, "\"") - 1) }
      printf "%s\t%s\t%s\t%s\t%s\t%s\n", tag, t, str(ob, "server"), num(ob, "server_port"), role, sub_
    }' "$H/servers.jsonl"
}

srv_emit() { # TSV: role<TAB>tag<TAB>outbound_json (已替换 @CERTS@); 供配置生成器使用
  [ -s "$H/servers.jsonl" ] || return 0
  LC_ALL=C awk -v certs="$H/certs" '
    {
      i = index($0, ",\"outbound\":{\"type\":\""); if (!i) next
      head = substr($0, 1, i); ob = substr($0, i + 12, length($0) - (i + 12))
      k = "\"role\":\""; j = index(head, k); role = substr(head, j + length(k)); role = substr(role, 1, index(role, "\"") - 1)
      rest = substr($0, i + 21); r2 = substr(rest, index(rest, "\"") + 1); tag = ""
      if (substr(r2, 1, 8) == ",\"tag\":\"") { r3 = substr(r2, 9); tag = substr(r3, 1, index(r3, "\"") - 1) }
      gsub(/@CERTS@/, certs, ob)
      printf "%s\t%s\t%s\n", role, tag, ob
    }' "$H/servers.jsonl"
}

srv_secret_fields() { # <tag> -> 打印 JSON 数组 [{name,value}] (只含凭据类字段); 0 = 找到  1 = 没有这个服务器  3 = 官方线路 (永远不显示)
  /usr/bin/perl -MJSON::PP -e '
    my ($tag, $file) = @ARGV; my $j = JSON::PP->new->utf8; open my $fh, "<", $file or exit 1;
    while (my $l = <$fh>) {
      my $d = eval { $j->decode($l) }; next unless ref $d eq "HASH" && ref $d->{outbound} eq "HASH"; my $o = $d->{outbound};
      next unless defined $o->{tag} && $o->{tag} eq $tag; exit 3 if $d->{official};
      my @f; for my $k (qw(username password uuid auth_str private_key pre_shared_key)) { push @f, { name => $k, value => $o->{$k} } if defined $o->{$k} && !ref $o->{$k} && length $o->{$k} }
      push @f, { name => "obfs_password", value => $o->{obfs}{password} } if ref $o->{obfs} eq "HASH" && defined $o->{obfs}{password} && length $o->{obfs}{password};
      print $j->encode(\@f); exit 0 }
    exit 1' "$1" "$H/servers.jsonl"
}
srv_has_tag() { srv_list | awk -F'\t' -v t="$1" '$1==t {f=1} END{exit f?0:1}'; }
srv_count() { srv_list | wc -l | tr -d ' '; }

# ---------- 写入 (带锁与备份) ----------
lock_take() { # 简单目录锁, 最多等 10 秒; 超过 60 秒的旧锁视为残留
  local i=0
  while ! mkdir "$H/.lock" 2>/dev/null; do
    if [ -d "$H/.lock" ] && [ -n "$(find "$H/.lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then rmdir "$H/.lock" 2>/dev/null || true; continue; fi
    i=$((i+1)); [ "$i" -gt 50 ] && return 1; sleep 0.2
  done
  return 0
}
lock_drop() { rmdir "$H/.lock" 2>/dev/null || true; }

srv_backup() { [ -f "$H/servers.jsonl" ] && cp -p "$H/servers.jsonl" "$H/servers.jsonl.prev" || : > "$H/servers.jsonl.prev"; }
srv_restore() { [ -f "$H/servers.jsonl.prev" ] && cp -p "$H/servers.jsonl.prev" "$H/servers.jsonl" || true; }

srv_check_line() { # 仪表盘提交的一行是否合法 (正则闸门; 真正的有效性由 sing-box check 兜底)
  local l=$1 tag
  printf '%s\n' "$l" | LC_ALL=C grep -Eq '^\{"role":"(pin|auto|dl|off)"(,"sub":"[A-Za-z0-9._ -]{1,40}")?,"outbound":\{"type":"(trojan|http|socks|tuic|hysteria2|vless|vmess|shadowsocks|anytls)","tag":"[^"\\[:cntrl:]]{1,64}",.+\}\}$' || return 1
  case $l in *'"detour"'*) return 1 ;; esac
  tag=$(printf '%s\n' "$l" | LC_ALL=C sed -n 's/^.*,"outbound":{"type":"[a-z0-9]*","tag":"\([^"]*\)".*/\1/p')
  case " $RESERVED_TAGS " in *" $tag "*) return 1 ;; esac
  case $tag in svc-*|'') return 1 ;; esac
  return 0
}

srv_import() { # srv_import [订阅名] [merge|replace] < JSONL  -> 打印 "added replaced removed", 逐行错误写 stderr
  # 目标文件默认 $H/servers.jsonl; 设置 SRV_FILE 可对副本做「干跑」(仪表盘预览数量用)
  local sub=${1:-} mode=${2:-merge} line n=0 added=0 replaced=0 removed=0 tag f=${SRV_FILE:-$H/servers.jsonl}
  local tmp="$f.new"
  : > "$tmp"
  [ -f "$f" ] && cp "$f" "$tmp"
  if [ "$mode" = replace ] && [ -n "$sub" ]; then
    removed=$(LC_ALL=C grep -c "^{\"role\":\"[a-z]*\",\"sub\":\"$sub\"," "$tmp" || true)
    LC_ALL=C grep -v "^{\"role\":\"[a-z]*\",\"sub\":\"$sub\"," "$tmp" > "$tmp.2" || true; mv "$tmp.2" "$tmp"
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n+1)); [ -n "$line" ] || continue
    if ! srv_check_line "$line"; then printf '第 %s 行格式不符合要求, 已忽略\n' "$n" >&2; continue; fi
    if [ -n "$sub" ]; then # 以参数为准, 重写 sub 字段
      line=$(printf '%s\n' "$line" | sed -e 's/^{"role":"\([a-z]*\)","sub":"[^"]*",/{"role":"\1",/' -e "s/^{\"role\":\"\([a-z]*\)\",\"outbound\"/{\"role\":\"\1\",\"sub\":\"$sub\",\"outbound\"/")
    fi
    tag=$(printf '%s\n' "$line" | LC_ALL=C sed -n 's/^.*,"outbound":{"type":"[a-z0-9]*","tag":"\([^"]*\)".*/\1/p')
    if LC_ALL=C grep -qF ",\"tag\":\"$tag\"" "$tmp" 2>/dev/null; then
      LC_ALL=C awk -v needle=",\"tag\":\"$tag\"" 'index($0, needle) == 0' "$tmp" > "$tmp.2"; mv "$tmp.2" "$tmp"; replaced=$((replaced+1))
    else added=$((added+1)); fi
    printf '%s\n' "$line" >> "$tmp"
  done
  mv "$tmp" "$f"; chmod 600 "$f"
  printf '%s %s %s\n' "$added" "$replaced" "$removed"
}

srv_delete() { # tag
  [ -f "$H/servers.jsonl" ] || return 0
  LC_ALL=C awk -v needle=",\"tag\":\"$1\"" 'index($0, needle) == 0' "$H/servers.jsonl" > "$H/servers.jsonl.new" && mv "$H/servers.jsonl.new" "$H/servers.jsonl"
  chmod 600 "$H/servers.jsonl"
}

srv_set_role() { # tag role
  [ -f "$H/servers.jsonl" ] || return 1
  LC_ALL=C awk -v needle=",\"tag\":\"$1\"" -v r="$2" '
    index($0, needle) { sub(/^\{"role":"[a-z]+"/, "{\"role\":\"" r "\"") } { print }' "$H/servers.jsonl" > "$H/servers.jsonl.new" && mv "$H/servers.jsonl.new" "$H/servers.jsonl"
  chmod 600 "$H/servers.jsonl"
}

srv_delete_sub() { # 订阅名: 删除该订阅导入的全部服务器
  [ -f "$H/servers.jsonl" ] || return 0
  LC_ALL=C grep -v "^{\"role\":\"[a-z]*\",\"sub\":\"$1\"," "$H/servers.jsonl" > "$H/servers.jsonl.new" || true
  mv "$H/servers.jsonl.new" "$H/servers.jsonl"; chmod 600 "$H/servers.jsonl"
}

# ---------- 下载线路: 用户配置的 http/socks 服务器 (curl 能直接使用的类型) ----------
srv_curl_routes() { # label|proxyurl|user:pass  (最多 6 条; role=dl 优先)
  [ -s "$H/servers.jsonl" ] || return 0
  LC_ALL=C awk '
    function str(s, key,   k, i) { k = "\"" key "\":\""; i = index(s, k); if (!i) return ""; s = substr(s, i + length(k)); return substr(s, 1, index(s, "\"") - 1) }
    function num(s, key,   k, i) { k = "\"" key "\":"; i = index(s, k); if (!i) return ""; s = substr(s, i + length(k)); match(s, /^[0-9]+/); return substr(s, 1, RLENGTH) }
    {
      i = index($0, ",\"outbound\":{\"type\":\""); if (!i) next
      role = str(substr($0, 1, i), "role"); ob = substr($0, i + 12)
      if (role == "off") next
      rest = substr($0, i + 21); t = substr(rest, 1, index(rest, "\"") - 1)
      if (t != "http" && t != "socks") next
      r2 = substr(rest, length(t) + 2); r3 = substr(r2, 9); tag = substr(r3, 1, index(r3, "\"") - 1)
      scheme = (t == "socks") ? "socks5h" : (index(ob, "\"tls\":{\"enabled\":true") ? "https" : "http")
      u = str(ob, "username"); p = str(ob, "password")
      line = sprintf("备用线路 %s|%s://%s:%s|%s%s%s", tag, scheme, str(ob, "server"), num(ob, "server_port"), u, (u != "" || p != "") ? ":" : "", p)
      if (role == "dl") a[++na] = line; else b[++nb] = line
    }
    END { for (k = 1; k <= na; k++) print a[k]; for (k = 1; k <= nb && na + k <= 6; k++) print b[k] }' "$H/servers.jsonl"
}

# ---------- 订阅 ----------
subs_file() { printf '%s\n' "$H/subs.tsv"; }
sub_valid_name() { case $1 in ''|*[!A-Za-z0-9._\ -]*) return 1 ;; esac; [ ${#1} -le 40 ]; }
sub_url_ok() { # 只允许 http(s), 且不允许指向本机/内网
  local u=$1 host
  case $u in http://*|https://*) ;; *) return 1 ;; esac
  host=${u#*://}; host=${host%%/*}; host=${host%%\?*}; host=${host##*@}; host=${host%%:*}
  case $host in ''|localhost|*.local|127.*|10.*|192.168.*|169.254.*|0.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|\[*) return 1 ;; esac
  return 0
}
sub_get_url() { awk -F'|' -v n="$1" '$1==n {print $2; exit}' "$H/subs.tsv" 2>/dev/null; }
sub_save() { # name url
  sub_valid_name "$1" && sub_url_ok "$2" || return 1
  touch "$H/subs.tsv"; chmod 600 "$H/subs.tsv"
  local keep; keep=$(awk -F'|' -v n="$1" '$1==n {print}' "$H/subs.tsv")
  awk -F'|' -v n="$1" '$1!=n' "$H/subs.tsv" > "$H/subs.tsv.new"
  if [ -n "$keep" ]; then printf '%s\n' "$keep" | awk -F'|' -v u="$2" 'BEGIN{OFS="|"} {$2=u; print}' >> "$H/subs.tsv.new"
  else printf '%s|%s|0|0|12|0|0|0\n' "$1" "$2" >> "$H/subs.tsv.new"; fi
  mv "$H/subs.tsv.new" "$H/subs.tsv"; chmod 600 "$H/subs.tsv"
}
sub_touch() { # name count interval used total expire  (拉取并导入成功后记录)
  [ -f "$H/subs.tsv" ] || return 0
  awk -F'|' -v n="$1" -v t="$(now)" -v c="${2:-0}" -v iv="${3:-12}" -v us="${4:-0}" -v to="${5:-0}" -v ex="${6:-0}" 'BEGIN{OFS="|"} $1==n {$3=t; $4=c; $5=iv; $6=us; $7=to; $8=ex} {print}' "$H/subs.tsv" > "$H/subs.tsv.new" && mv "$H/subs.tsv.new" "$H/subs.tsv"; chmod 600 "$H/subs.tsv"
}
sub_delete() { [ -f "$H/subs.tsv" ] && { awk -F'|' -v n="$1" '$1!=n' "$H/subs.tsv" > "$H/subs.tsv.new"; mv "$H/subs.tsv.new" "$H/subs.tsv"; chmod 600 "$H/subs.tsv"; }; srv_delete_sub "$1"; }
subs_json() { # 不含链接/令牌, 只给主机名
  [ -s "$H/subs.tsv" ] || { printf '[]'; return; }
  awk -F'|' 'BEGIN{printf "["} {
    h = $2; sub(/^[a-z]+:\/\//, "", h); sub(/[\/?:].*$/, "", h)
    printf "%s{\"name\":\"%s\",\"host\":\"%s\",\"updated\":%s,\"count\":%s,\"interval\":%s,\"usage\":", (NR>1?",":""), $1, h, $3+0, $4+0, $5+0
    if ($7+0 > 0) printf "{\"used\":%s,\"total\":%s,\"expire\":%s}", $6+0, $7+0, $8+0; else printf "null"
    printf "}"
  } END{printf "]"}' "$H/subs.tsv"
}

# ---------- 从 v1 升级: 把旧的 config.env 迁移成服务器条目 (无需重新输入) ----------
srv_migrate_v1() {
  [ -f "$H/config.env" ] && [ ! -f "$H/servers.jsonl" ] || return 1
  ( . "$H/config.env" 2>/dev/null
    [ -n "${SERVER:-}" ] && [ -n "${TROJAN_PASS:-}" ] || exit 0
    case "$SERVER$TROJAN_PASS${SNI:-}${SOCKS_USER:-}${SOCKS_PASS:-}" in *\"*|*\\*) exit 0 ;; esac
    mkdir -p "$H/certs"; [ -f "$H/tokyo-server.crt" ] && cp "$H/tokyo-server.crt" "$H/certs/Tokyo.crt"
    tls="{\"enabled\":true,\"server_name\":\"${SNI:-$SERVER}\""
    [ -f "$H/certs/Tokyo.crt" ] && tls="$tls,\"certificate_path\":\"@CERTS@/Tokyo.crt\""
    tls="$tls}"
    printf '{"role":"pin","outbound":{"type":"trojan","tag":"Tokyo","server":"%s","server_port":443,"password":"%s","tls":%s}}\n' "$SERVER" "$TROJAN_PASS" "$tls" > "$H/servers.jsonl"
    if [ -n "${SOCKS_USER:-}" ] && [ -n "${SOCKS_PASS:-}" ]; then
      printf '{"role":"dl","outbound":{"type":"socks","tag":"Tokyo-SOCKS5","server":"%s","server_port":%s,"version":"5","username":"%s","password":"%s"}}\n' "$SERVER" "${SOCKS_PORT:-1080}" "$SOCKS_USER" "$SOCKS_PASS" >> "$H/servers.jsonl"
    fi
    chmod 600 "$H/servers.jsonl" )
  if [ -f "$H/servers.jsonl" ]; then mv "$H/config.env" "$H/config.env.v1.bak"; chmod 600 "$H/config.env.v1.bak"; return 0; fi
  return 1
}
