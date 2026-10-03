# 访问记录: 把代理核心的日志 (info 级别, 每条连接有一个编号 [id 耗时]) 按连接编号归并成「一条连接一行」。
# 供 lib/logs.sh 调用 (仪表盘「日志 → 网站访问」和诊断导出共用):
#   LC_ALL=C awk -f access.awk -v mode=json|tsv -v q=<搜索词, 小写> -v f=<筛选 direct|proxy|error|空> -v lim=<条数> -v off=<跳过条数> -v since="YYYY-MM-DD HH:MM:SS" -v mask=0|1
# 输入 (标准输入): 三段, 依次是  @@PINS (固定出口节点名, 每行一个)  @@AUTOS (自动线路节点名)  @@LOG (核心日志原文)
# 一条连接可能出现的行 (都带 [编号 耗时]):
#   inbound/mixed[in]: inbound connection to 域名:端口            (UDP 是 inbound packet connection to)
#   router: found process path: 进程路径, user: 用户
#   dns: lookup succeed for 域名: IP IP …                          (解析结果; 域名被污染时这里能看到)
#   outbound/<类型>[<节点名>]: outbound connection to 域名:端口    (实际选中的出口; 节点名里可以带方括号)
#   ERROR connection: open connection to 域名:端口 using outbound/<类型>[<节点名>]: 原因
# 出口名 direct-mode / direct-lan / direct-site / direct-app / direct-cn 都是「直连」, 后缀说明为什么直连 (见 lib/config.sh);
# 单独的 direct = 策略 (网站开关 / 默认出口) 选了直连。
# 输出 (json): {"total":N (筛选后的条数),"rows":[新→旧, 每行一条连接],"summary":{全部/直连/代理/失败的条数, 直连原因分布, 失败最多的网站}}   (tsv): 表头 + 每行一条连接 (旧→新)

function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/[\001-\037]/, " ", s); return s }
function tsvc(s) { gsub(/[\t\r\n]/, " ", s); return s }
function errclass(m,   l) {
  l = tolower(m)
  if (l ~ /i\/o timeout|timed out|deadline exceeded|timeout/) return "timeout"
  if (l ~ /connection refused/) return "refused"
  if (l ~ /connection reset|broken pipe/) return "reset"
  if (l ~ /no route to host|network is unreachable|host is unreachable/) return "unreachable"
  if (l ~ /no such host|nxdomain|lookup/) return "dns"
  if (l ~ /tls|certificate|handshake/) return "tls"
  if (l ~ /eof/) return "eof"
  if (l ~ /reject|blocked|forbidden|denied|not allowed/) return "rejected"
  return "other"
}
function reasonOf(tag) {
  if (tag == "direct") return "policy"
  if (tag == "direct-mode") return "mode"
  if (tag == "direct-lan") return "lan"
  if (tag == "direct-site") return "site"
  if (tag == "direct-app") return "app"
  if (tag == "direct-cn") return "cn"
  return ""
}
function hostport(hp,   h, p) {                      # "域名:端口" / "[IPv6]:端口" -> HOST, PORT
  PORT_ = ""; HOST_ = hp
  if (substr(hp, 1, 1) == "[" && (p = index(hp, "]:")) > 0) { HOST_ = substr(hp, 2, p - 2); PORT_ = substr(hp, p + 2); return }
  p = hp; sub(/.*:/, "", p); h = hp; sub(/:[^:]*$/, "", h)
  if (p ~ /^[0-9]+$/) { HOST_ = h; PORT_ = p } else { HOST_ = hp }
}
function appname(pp,   n, parts) {                   # /Applications/Google Chrome.app/Contents/... -> Google Chrome (取最外层 .app); 其它取文件名
  if (match(pp, /[^\/]+\.app\//)) return substr(pp, RSTART, RLENGTH - 5)
  n = split(pp, parts, "/"); return parts[n]
}
function mkid(id) { if (!(id in seen)) { seen[id] = 1; ord[++n] = id } }
function maskp(s) { gsub(/\/Users\/[^\/]+/, "/Users/<user>", s); return s }
function masku(u) { if (u == "" || u == "root" || substr(u, 1, 1) == "_") return u; return "<user>" }

/^@@PINS$/ { mode_ = 1; next }
/^@@AUTOS$/ { mode_ = 2; next }
/^@@LOG$/ { mode_ = 3; next }
mode_ == 1 { if ($0 != "") pin[$0] = 1; next }
mode_ == 2 { if ($0 != "") auto[$0] = 1; next }
mode_ == 3 {
  line = $0; gsub(/\033\[[0-9;]*m/, "", line)
  if (!match(line, /^[+-][0-9][0-9][0-9][0-9] [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9:]+ [A-Z]+ /)) next
  split(substr(line, 1, RLENGTH - 1), hd, " ")
  when = hd[2] " " hd[3]; level = hd[4]
  rest = substr(line, RLENGTH + 1)
  if (!match(rest, /^\[[0-9]+ [^]]*\] /)) next
  split(substr(rest, 2, RLENGTH - 3), idt, " "); id = idt[1]; dur = idt[2]
  msg = substr(rest, RLENGTH + 1)

  if ((p = index(msg, ": inbound connection to ")) > 0 || (p = index(msg, ": inbound packet connection to ")) > 0) {
    if (index(msg, "inbound/tun[") > 0) capture[id] = "tun"; else capture[id] = "mixed"
    mkid(id); isudp = (index(msg, "inbound packet connection to ") > 0)
    hp = msg; sub(/.*inbound (packet )?connection to /, "", hp); hostport(hp)
    ts[id] = when; host[id] = HOST_; port[id] = PORT_; net[id] = isudp ? "udp" : "tcp"
  } else if (index(msg, "router: found process path: ") == 1) {
    mkid(id); pp = substr(msg, 29); u = ""
    if (match(pp, /, user: [^,]*$/)) { u = substr(pp, RSTART + 8); pp = substr(pp, 1, RSTART - 1) }
    path[id] = pp; usr[id] = u; app[id] = appname(pp)
    if (!(id in ts)) ts[id] = when
  } else if (index(msg, "dns: lookup succeed for ") == 1) {
    mkid(id); r = substr(msg, 25); p2 = index(r, ": ")
    if (p2 > 0) { ips[id] = substr(r, p2 + 2); if (!(id in ts)) ts[id] = when }
  } else if (msg ~ /^dns: (lookup|exchange) failed/) {
    mkid(id); err[id] = "dns"; emsg[id] = substr(msg, 6, 160); edur[id] = dur; if (!(id in ts)) ts[id] = when
  } else if (msg ~ /^outbound\/[a-z0-9-]+\[/) {
    p = index(msg, "]: outbound connection to "); isu = 0
    if (!p) { p = index(msg, "]: outbound packet connection to "); isu = 1 }
    if (p > 0) {
      mkid(id); head = substr(msg, 1, p - 1); sub(/^outbound\//, "", head)
      q1 = index(head, "["); otype[id] = substr(head, 1, q1 - 1); tag[id] = substr(head, q1 + 1)
      if (!(id in ts)) ts[id] = when
      if (!(id in host)) { hp = substr(msg, p + (isu ? 33 : 26)); hostport(hp); host[id] = HOST_; port[id] = PORT_ }
    }
  } else if ((level == "ERROR" || level == "WARN") && index(msg, "connection: open ") == 1) {
    mkid(id); if (!(id in ts)) ts[id] = when
    up = index(msg, " using outbound/"); m = (up > 0) ? substr(msg, up + 16) : ""
    if (m != "") { p3 = index(m, "]: "); if (p3 > 0) { m = substr(m, p3 + 3) } }
    else { m = msg }
    emsg[id] = substr(m, 1, 160); err[id] = errclass(m); edur[id] = dur
    if (!(id in host)) { hp = msg; sub(/^connection: open (packet )?connection to /, "", hp); sub(/ using .*/, "", hp); hostport(hp); host[id] = HOST_; port[id] = PORT_ }
    if (!(id in ips) && match(m, /dial (tcp|udp) [^ :]+:[0-9]+/)) {                          # 解析不到 DNS 行时, 用拨号失败里的地址
      a = substr(m, RSTART, RLENGTH); sub(/^dial (tcp|udp) /, "", a); sub(/:[0-9]+$/, "", a); ips[id] = a
    }
  }
}
END {
  nm = 0
  for (i = 1; i <= n; i++) {
    id = ord[i]
    if (since != "" && ts[id] < since) continue
    hasout = (id in tag); t = tag[id]                  # 先判断有没有出口: 直接读 tag[id] 会让 awk 凭空建出这个元素
    rt = hasout ? ((t ~ /^direct(-[a-z]+)?$/) ? "direct" : ((t in pin) ? "pin" : ((t in auto) ? "auto" : "other"))) : "none"
    rs[id] = (rt == "direct") ? reasonOf(t) : ""; rtc[id] = rt
    if (q != "") {
      bl = tolower(host[id] " " app[id] " " t " " rs[id] " " ((id in err) ? err[id] : "") " " ips[id]); if (index(bl, q) == 0) continue       # (不能直接读 err[id]: 会让没有错误的连接也变成「失败」)
    }
    base[++nb] = id
  }
  # 汇总 (在搜索之后、筛选之前: 筛选按钮上显示的数字)
  for (i = 1; i <= nb; i++) {
    id = base[i]; c_all++
    if (rtc[id] == "direct") { c_direct++; if (rs[id] != "") c_reason[rs[id]]++ } else if (rtc[id] == "pin" || rtc[id] == "auto" || rtc[id] == "other") c_proxy++
    if (rtc[id] == "pin") c_pin++; if (rtc[id] == "auto") c_auto++
    if (id in err) { c_err++; fh = host[id]; if (!(fh in fcnt)) { fh_order[++nfh] = fh }; fcnt[fh]++; fcls[fh] = err[id]; fapp[fh] = app[id]; ftag[fh] = tag[id] }
  }
  for (i = 1; i <= nb; i++) {
    id = base[i]
    if (f == "direct" && rtc[id] != "direct") continue
    if (f == "proxy" && !(rtc[id] == "pin" || rtc[id] == "auto" || rtc[id] == "other")) continue
    if (f == "error" && !(id in err)) continue
    M[++nm] = id
  }
  if (mode == "tsv") {
    print "ts\tid\tnet\thost\tport\tapp\tuser\troute\tnode\treason\tresult\terr\tdur\tips\terrmsg\tpath\tcapture"
    for (i = 1; i <= nm; i++) {
      id = M[i]; pa = path[id]; us = usr[id]; if (mask) { pa = maskp(pa); us = masku(us) }
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", ts[id], id, net[id], tsvc(host[id]), port[id], tsvc(app[id]), tsvc(us), rtc[id], tsvc(tag[id]), rs[id], ((id in err) ? "error" : "ok"), err[id], edur[id], tsvc(ips[id]), tsvc(emsg[id]), tsvc(pa), capture[id]
    }
  } else {
    printf "{\"total\":%d,\"rows\":[", nm; c = 0
    for (i = nm - off; i >= 1 && c < lim; i--) {
      id = M[i]
      printf "%s{\"ts\":\"%s\",\"id\":\"%s\",\"net\":\"%s\",\"host\":\"%s\",\"port\":%d,\"app\":\"%s\",\"user\":\"%s\",\"path\":\"%s\",\"capture\":\"%s\",\"route\":\"%s\",\"node\":\"%s\",\"reason\":\"%s\",\"err\":\"%s\",\"errmsg\":\"%s\",\"dur\":\"%s\",\"ips\":\"%s\"}", (c++ ? "," : ""), esc(ts[id]), esc(id), net[id], esc(host[id]), port[id] + 0, esc(app[id]), esc(usr[id]), esc(path[id]), capture[id], rtc[id], esc(tag[id]), rs[id], err[id], esc(emsg[id]), esc(edur[id]), esc(ips[id])
    }
    printf "],\"summary\":{\"all\":%d,\"direct\":%d,\"proxy\":%d,\"pin\":%d,\"auto\":%d,\"error\":%d,\"reasons\":{", c_all + 0, c_direct + 0, c_proxy + 0, c_pin + 0, c_auto + 0, c_err + 0
    k = 0; for (r in c_reason) printf "%s\"%s\":%d", (k++ ? "," : ""), r, c_reason[r]
    printf "},\"top_fail\":["
    # 失败最多的 5 个网站 (简单选择排序)
    for (j = 1; j <= 5; j++) { best = ""; bn = 0; for (i = 1; i <= nfh; i++) { h2 = fh_order[i]; if (!(h2 in used) && fcnt[h2] > bn) { bn = fcnt[h2]; best = h2 } }
      if (best == "") break; used[best] = 1
      printf "%s{\"host\":\"%s\",\"n\":%d,\"err\":\"%s\",\"app\":\"%s\",\"node\":\"%s\"}", (j > 1 ? "," : ""), esc(best), bn, fcls[best], esc(fapp[best]), esc(ftag[best]) }
    printf "]}}"
  }
}
