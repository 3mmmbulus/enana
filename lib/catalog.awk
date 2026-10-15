# 目录生成 (由 config.sh 调用): 读 services.conf, 产出 sing-box 的策略开关 / 路由规则 / 仪表盘用的 catalog 条目。
#   -v have=<文件>  已就绪且启用的规则集 tag (每行一个)      -v sel= -v r1= -v r2= -v catf=   输出文件
#   -v domf=<文件>  把所有服务的生效域名 (每行一个) 写到这里, 供「自动识别无法访问的网站」排除目录里已有的服务
#   -v pinx=<JSON 片段>  固定出口有 2 个以上时, 追加到每个开关选项里的 "PINAUTO","节点名",… (没有就留空)
#   -v sited=<目录> -v sitel=<文件>  每个服务的生效域名写成一个本地规则集 sited/<id>.json, id 按目录顺序记进 sitel (lib/sites.sh 的 sites_rules_write 放进 rules/site-<id>/);
#                    路由规则只引用固定的 tag site-<id>, 所以改域名只改这个文件, 不改核心配置 (TUN 下由规则同步助手免密同步, 见 lib/enhanced.sh)。
#                    域名一律小写, 只留合法的名字 (和 lib/tunrules-helper.pl 的 site 检查一样); 一个都不剩时写占位 (不会匹配任何域名)。id 不合规 (理论上不会) 时照旧直接写进配置
# 输入格式: id|名称|分组|默认策略|基线域名|社区规则集|IP段|说明
function jl(csv,   a, n, i, s) { n = split(csv, a, ","); s = ""; for (i = 1; i <= n; i++) if (a[i] != "") s = s (s == "" ? "" : ",") "\"" a[i] "\""; return s }
function cnt(csv,   a, n, i, c) { n = split(csv, a, ","); c = 0; for (i = 1; i <= n; i++) if (a[i] != "") c++; return c }
function eff(id, csv,   a, n, i, out, k, e) {   # 生效的域名 = (系统域名 − 用户删除的) ∪ 用户添加的 (见 lib/sites.sh)
  n = split(csv, a, ","); out = ""
  for (i = 1; i <= n; i++) if (a[i] != "" && !((id SUBSEP a[i]) in del)) { out = out (out == "" ? "" : ",") a[i]; have_d[id SUBSEP a[i]] = 1 }
  for (k = 1; k <= na[id]; k++) { e = addl[id, k]; if (!((id SUBSEP e) in have_d)) { have_d[id SUBSEP e] = 1; out = out (out == "" ? "" : ",") e } }
  return out
}
function okname(d, sfx,   a, n, i) {   # 合法的域名 (domain_suffix 可以以一个点开头: 只匹配子域名); 和 lib/tunrules-helper.pl 的 name_ok 一致
  if (sfx && substr(d, 1, 1) == ".") d = substr(d, 2)
  if (d == "" || length(d) > 253) return 0
  n = split(d, a, ".")
  for (i = 1; i <= n; i++) if (length(a[i]) > 63 || a[i] !~ /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/) return 0
  return 1
}
function sitejson(csv,   a, n, i, d, s, seen) {   # 生效域名 -> 规则集文件的内容 (一条 domain_suffix 规则; 没有合法的域名 = 占位)
  n = split(csv, a, ","); s = ""
  for (i = 1; i <= n; i++) { d = tolower(a[i]); if (okname(d, 1) && !(d in seen)) { seen[d] = 1; s = s (s == "" ? "" : ",") "\"" d "\"" } }
  return "{\"version\":3,\"rules\":[" (s == "" ? "{\"domain\":[\"enana-placeholder.invalid\"]}" : "{\"domain_suffix\":[" s "]}") "]}"
}
BEGIN {
  FS = "|"; while ((getline l < have) > 0) hv[l] = 1; close(have)
  if (edits != "") {
    while ((getline l < edits) > 0) { split(l, e, "|"); if (e[1] == "" || e[3] == "") continue; mod[e[1]] = 1
      if (e[2] == "-") del[e[1] SUBSEP e[3]] = 1; else if (e[2] == "+") { na[e[1]]++; addl[e[1], na[e[1]]] = e[3] } }
    close(edits)
  }
}
/^[ \t]*(#|$)/ { next }
{
  id = $1; name = $2; group = $3; pol = $4; domains = $5; rulesets = $6; cidrs = $7; desc = $8
  gsub(/[^a-z0-9-]/, "", id); if (id == "") next
  gsub(/["\\]/, "", name); gsub(/["\\]/, "", desc); gsub(/[^a-z]/, "", group)
  gsub(/[^A-Za-z0-9._,-]/, "", domains); domains = eff(id, domains); gsub(/[^A-Za-z0-9._,-]/, "", rulesets)
  if (domf != "") { nd = split(domains, dd, ","); for (i = 1; i <= nd; i++) if (dd[i] != "") print dd[i] >> domf }; gsub(/[^0-9A-Fa-f:.\/,]/, "", cidrs)
  deftag = (pol == "pin") ? "PIN" : ((pol == "auto") ? "Global" : "direct")
  print "{\"type\":\"selector\",\"tag\":\"svc-" id "\",\"outbounds\":[\"PIN\",\"Global\",\"direct\"" pinx "],\"default\":\"" deftag "\",\"interrupt_exist_connections\":true}" >> sel
  out = (group == "ai" || group == "account" || group == "exchange" || group == "tools") ? r1 : r2
  if (sited != "" && id ~ /^[a-z0-9][a-z0-9-]*$/ && length(id) <= 63 && !(id in site)) {
    site[id] = 1; f = sited "/" id ".json"; print sitejson(domains) > f; close(f); print id >> sitel
    print "{\"rule_set\":[\"site-" id "\"],\"action\":\"route\",\"outbound\":\"svc-" id "\"}" >> out
  } else if (domains != "") print "{\"domain_suffix\":[" jl(domains) "],\"action\":\"route\",\"outbound\":\"svc-" id "\"}" >> out
  n = split(rulesets, rs, ","); present = ""
  for (i = 1; i <= n; i++) if (rs[i] != "" && (rs[i] in hv)) present = present (present == "" ? "" : ",") rs[i]
  if (present != "") print "{\"rule_set\":[" jl(present) "],\"action\":\"route\",\"outbound\":\"svc-" id "\"}" >> out
  if (cidrs != "") print "{\"ip_cidr\":[" jl(cidrs) "],\"action\":\"route\",\"outbound\":\"svc-" id "\"}" >> out
  printf "%s{\"id\":\"%s\",\"tag\":\"svc-%s\",\"name\":\"%s\",\"group\":\"%s\",\"default\":\"%s\",\"desc\":\"%s\",\"domains\":[%s],\"rulesets\":[%s],\"cidrs\":%d,\"modified\":%s}", (nc++ ? "," : ""), id, id, name, group, pol, desc, jl(domains), jl(rulesets), cnt(cidrs), ((id in mod) ? "true" : "false") >> catf
}
