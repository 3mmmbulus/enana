# 固定出口分配 (Exit assignment): 哪些应用 / 网站 / 服务走哪一个固定出口 · 默认固定出口是哪一个 · 批量移动 / 冻结 · 删除或改角色之前的影响检查。
# 依赖 common servers apps config(clash) logs ops(op_txn)。bash 3.2 兼容 (没有关联数组 / mapfile)。设计和接口见 docs/ARCHITECTURE.md 的「固定出口分配」与 docs/API.md 的 /api/exits。
#
# 概念
#   固定出口 = role=pin 的服务器。overrides.tsv 里状态是 pin 的应用 / 网站, 出口 (第 5 列) 有四种归属:
#     bound   指定走某一个固定出口 (出口 = 服务器名)
#     follow  跟随默认固定出口 (出口为空): 默认固定出口换了, 它们的出口 IP 也跟着换 —— 所以「换默认」必须先让用户看到谁会受影响 (见 exits_impact_json)
#     auto    在固定出口里自动选 (出口 = PINAUTO)
#     orphan  指定的出口已经不是固定出口 (被删除 / 改了角色 / 超过 OVR_PIN_MAX): 规则集里暂时退回默认固定出口 (lib/apps.sh 的 key()), 这里把它们单独标出来
#   服务 (svc-<id> 选择器) 的归属在核心里 (cache.db): 当前选 PIN = 跟随默认, 选某个固定出口 = 指定, 选 PINAUTO = 自动选; 只有核心在运行时才读得到 (读不到时 services_known=false)。
#   默认固定出口 = 选择器 PIN 当前选中的服务器。除了核心自己记住 (cache.db) 之外, 另存一份在 $H/pin-default (一行服务器名), 作用是:
#     ① 核心没运行时也知道默认是谁 (界面 / 诊断) ② 核心重启后选择被重置 (缓存丢了 / 重装) 时校正回来 (exits_sync_default, 由 proxy_sync_mode 调用) ③ 不再靠「文件里的第一个固定出口」这种会随导入顺序变化的东西。
#   老安装没有这个文件: 默认 = 核心里正在用的 (它本来就是这样记住的); 第一次读到时 (exits_adopt) 把它记下来 —— 只信核心里读到的值, 绝不拿「第一个固定出口」去覆盖用户的选择。
#   文件放在 TXN_FILES 里, 随事务一起备份 / 回滚。
#
# 路由语义没有改变: 指定的出口不存在时规则集仍退回默认固定出口 (不会断网)。新增的是: 先检查 (删除 / 改角色 / 换默认之前列出受影响的项目, 必须明确选择去向), 事后看得见 (界面标记 + 健康记录 exit_orphans)。

EXITS_ERR=''; EXITS_CODE=E_INVALID
EXITS_DEF=''; EXITS_SRC=none; EXITS_LIVE=''; EXITS_STORED=''
EXITS_SVC_MOVED=0; EXITS_SVC_FAILED=0; EXITS_SVC_KNOWN=0

exits_pins_all() { srv_list 2>/dev/null | awk -F'\t' '$5=="pin" { print $1 }'; }                  # 全部固定出口 (不受 OVR_PIN_MAX 限制)
exits_has_pin() { [ -n "$1" ] && exits_pins_all | grep -qxF -- "$1"; }

# ---------- 默认固定出口 ----------
exits_stored() { # 持久化的默认固定出口 (它必须还是固定出口, 否则当作没有)
  local t=''
  [ -s "$H/pin-default" ] && IFS= read -r t < "$H/pin-default"
  if [ -n "$t" ] && exits_has_pin "$t"; then printf '%s' "$t"; fi
  return 0
}
exits_live() { # 核心里选择器 PIN 当前选中的服务器 (核心没运行 / 选的不是固定出口: 空)
  local now
  [ -z "${ENANA_EXITS_NO_LIVE:-}" ] || return 0
  now=$(clash GET /proxies/PIN 2>/dev/null | sed -n 's/.*"now": *"\([^"]*\)".*/\1/p' | head -1)
  if [ -n "$now" ] && exits_has_pin "$now"; then printf '%s' "$now"; fi
  return 0
}
exits_resolve() { # 设置 EXITS_DEF (有效的默认固定出口) · EXITS_SRC (live|stored|first|none) · EXITS_LIVE · EXITS_STORED
  local first
  EXITS_LIVE=$(exits_live); EXITS_STORED=$(exits_stored); first=$(exits_pins_all | head -1)
  if [ -n "$EXITS_LIVE" ]; then EXITS_DEF=$EXITS_LIVE; EXITS_SRC=live
  elif [ -n "$EXITS_STORED" ]; then EXITS_DEF=$EXITS_STORED; EXITS_SRC=stored
  elif [ -n "$first" ]; then EXITS_DEF=$first; EXITS_SRC=first
  else EXITS_DEF=''; EXITS_SRC=none; fi
}
exits_default_save() { # <服务器名>: 记下默认固定出口 (原子写; 必须是现有的固定出口)
  exits_has_pin "$1" || return 1
  printf '%s\n' "$1" > "$H/pin-default.new" && mv "$H/pin-default.new" "$H/pin-default"
}
exits_adopt() { # 持久化的值跟上核心里正在用的 (老安装第一次 / 在别处切换过); 只信核心里读到的值
  exits_resolve
  [ "$EXITS_SRC" = live ] || return 0
  [ "$EXITS_LIVE" != "$EXITS_STORED" ] || return 0
  exits_default_save "$EXITS_LIVE"
}
exits_set_live() { # <服务器名>: 热切换选择器 PIN (和 POST /api/policy 一样: 不重启核心)
  [ -z "$(clash PUT /proxies/PIN "{\"name\":\"$(jesc "$1")\"}" 2>/dev/null)" ]
}
exits_sync_default() { # 核心(重新)启动后: 持久化的默认固定出口还在, 但核心里选的不是它 (缓存丢了 / 重装) → 切回去; 不然所有「跟随默认」的应用 / 网站 / 服务会悄悄换了出口 IP
  local want live='' i=0
  want=$(exits_stored); [ -n "$want" ] || return 0
  while [ "$i" -lt 6 ]; do
    live=$(clash GET /proxies/PIN 2>/dev/null | sed -n 's/.*"now": *"\([^"]*\)".*/\1/p' | head -1)
    [ -z "$live" ] || break
    i=$((i + 1)); sleep 0.5
  done
  [ -n "$live" ] && [ "$live" != "$want" ] || return 0
  exits_set_live "$want" || return 0
  oplog "${OP_WHO:-auto}" "恢复默认固定出口" "$(kv from "$live" to "$want" why "core restarted with a different selection")" ok
}

# ---------- 服务 (核心里的 svc-* 选择器) ----------
exits_services_scan() { # 每行: 选择器名<TAB>当前选择; 核心没运行 / 读不到 → 返回 1
  local px
  px=$(clash GET /proxies 2>/dev/null) || return 1
  [ -n "$px" ] || return 1
  printf '%s' "$px" | perl -MJSON::PP -e '
    local $/; my $j = eval { JSON::PP->new->decode(<STDIN>) } or exit 3; my $p = $j->{proxies} or exit 3;
    for my $t (sort keys %$p) { next unless $t =~ /^svc-/ && ($p->{$t}{type} // "") =~ /^selector$/i; print "$t\t", ($p->{$t}{now} // ""), "\n"; }'
}
exits_services_move() { # <from> <to> [记录文件]: from = DEFAULT (选的是 PIN) | PINAUTO | 服务器名; to = DEFAULT (改选 PIN) | PINAUTO | 服务器名。设置 EXITS_SVC_MOVED / _FAILED / _KNOWN; 记录文件里写 选择器<TAB>原来<TAB>现在 (失败回滚用)
  local f=$1 t=$2 log=${3:-} want name tmp tag now
  EXITS_SVC_MOVED=0; EXITS_SVC_FAILED=0; EXITS_SVC_KNOWN=0
  case $f in DEFAULT) want=PIN ;; *) want=$f ;; esac
  case $t in DEFAULT) name=PIN ;; *) name=$t ;; esac
  [ "$want" != "$name" ] || { EXITS_SVC_KNOWN=1; return 0; }
  tmp=$(mktemp)
  if ! exits_services_scan > "$tmp"; then rm -f "$tmp"; return 1; fi
  EXITS_SVC_KNOWN=1
  while IFS=$'\t' read -r tag now; do
    [ -n "$tag" ] && [ "$now" = "$want" ] || continue
    if [ -z "$(clash PUT "/proxies/$tag" "{\"name\":\"$(jesc "$name")\"}" 2>/dev/null)" ]; then
      EXITS_SVC_MOVED=$((EXITS_SVC_MOVED + 1)); [ -z "$log" ] || printf '%s\t%s\t%s\n' "$tag" "$want" "$name" >> "$log"
    else EXITS_SVC_FAILED=$((EXITS_SVC_FAILED + 1)); fi
  done < "$tmp"
  rm -f "$tmp"
  return 0
}
exits_services_restore() { # <记录文件>: 把 exits_services_move 改过的选择器切回去 (任务失败回滚时用)
  local tag old new
  [ -s "${1:-}" ] || return 0
  while IFS=$'\t' read -r tag old new; do
    [ -n "$tag" ] && [ -n "$old" ] || continue
    clash PUT "/proxies/$tag" "{\"name\":\"$(jesc "$old")\"}" >/dev/null 2>&1 || true
  done < "$1"
}

# ---------- 归属表 ----------
exits_items() { # 每行: 种类<TAB>名称<TAB>归属<TAB>出口<TAB>原因。种类 app|site|svc; 归属 follow|auto|bound|orphan; 原因只有 orphan 有 (deleted 已删除 | role 不再是固定出口 | cap 超出上限)。$1 = 服务选择文件 (选择器<TAB>当前选择, 可省略)
  local pf cf rf sf=${1:-} ov="$H/overrides.tsv"
  [ -f "$ov" ] || ov=/dev/null
  pf=$(mktemp); cf=$(mktemp); rf=$(mktemp)
  exits_pins_all > "$pf"; ovr_pins > "$cf"; srv_list 2>/dev/null | awk -F'\t' '{ print $1 "\t" $5 }' > "$rf"
  LC_ALL=C awk -F'|' -v pf="$pf" -v cf="$cf" -v rf="$rf" -v sf="$sf" '
    BEGIN {
      OFS = "\t"
      while ((getline l < pf) > 0) if (l != "") P[l] = 1
      while ((getline l < cf) > 0) if (l != "") C[l] = 1
      while ((getline l < rf) > 0) { split(l, a, "\t"); R[a[1]] = a[2] }
      if (sf != "") while ((getline l < sf) > 0) {
        split(l, a, "\t")
        if (a[2] == "PIN") print "svc", a[1], "follow", "", ""
        else if (a[2] == "PINAUTO") print "svc", a[1], "auto", "PINAUTO", ""
        else if (a[2] in C) print "svc", a[1], "bound", a[2], ""
      }
    }
    ($1 == "app" || $1 == "site") && $3 == "pin" {
      t = $5; why = ""
      if (t == "") cls = "follow"
      else if (t == "PINAUTO") cls = "auto"
      else if (t in C) cls = "bound"
      else { cls = "orphan"; why = (t in P) ? "cap" : ((t in R) ? "role" : "deleted") }
      print $1, $2, cls, t, why
    }' "$ov"
  rm -f "$pf" "$cf" "$rf"
}
exits_items_full() { # <输出文件>: 归属表 (含服务); 返回 0 = 服务也读到了, 1 = 核心没运行 (只有应用 / 网站)
  local svc rc=0; svc=$(mktemp)
  if ! exits_services_scan > "$svc" 2>/dev/null; then : > "$svc"; rc=1; fi
  exits_items "$svc" > "$1"; rm -f "$svc"
  return $rc
}
exits_orphan_count() { exits_items | awk -F'\t' '$3 == "orphan" { n++ } END { print n + 0 }'; }
exits_orphan_names() { # 最多 6 个: 名称->出口(原因), 逗号分隔 (健康记录 / 终端提示用)
  exits_items | awk -F'\t' '$3 == "orphan" && n < 6 { printf "%s%s->%s(%s)", (n++ ? "," : ""), $2, $4, $5 }'
}

exits_json() { # GET /api/exits 的主体 (不含花括号)
  local items pf cf dns=false known=false
  exits_resolve
  items=$(mktemp); pf=$(mktemp); cf=$(mktemp)
  if exits_items_full "$items"; then known=true; fi
  if type dns_load >/dev/null 2>&1; then dns_load; [ "${DNS_LEAK:-1}" = 1 ] && [ "${DNS_VIA:-}" = PIN ] && dns=true; fi
  exits_pins_all > "$pf"; ovr_pins > "$cf"
  LC_ALL=C awk -F'\t' -v items="$items" -v pf="$pf" -v cf="$cf" -v def="$EXITS_DEF" -v src="$EXITS_SRC" -v live="$EXITS_LIVE" -v stored="$EXITS_STORED" -v max="${OVR_PIN_MAX:-32}" -v dns="$dns" -v known="$known" '
    function js(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
    function add(k, s) { L[k] = L[k] (L[k] == "" ? "" : ",") "\"" js(s) "\"" }
    function lst(g, t) { return "\"apps\":[" L[g SEP t SEP "app"] "],\"sites\":[" L[g SEP t SEP "site"] "],\"services\":[" L[g SEP t SEP "svc"] "]" }
    BEGIN {
      SEP = "\001"
      while ((getline l < pf) > 0) if (l != "") P[++np] = l
      while ((getline l < cf) > 0) if (l != "") C[l] = 1
      while ((getline l < items) > 0) {
        n = split(l, a, "\t"); kind = a[1]; name = a[2]; cls = a[3]; tg = a[4]; why = a[5]
        if (cls == "bound") add("bound" SEP tg SEP kind, name)
        else if (cls == "follow") add("follow" SEP SEP kind, name)
        else if (cls == "auto") add("auto" SEP SEP kind, name)
        else if (cls == "orphan") { no++; O = O (O == "" ? "" : ",") "{\"kind\":\"" kind "\",\"name\":\"" js(name) "\",\"target\":\"" js(tg) "\",\"reason\":\"" why "\"}" }
      }
      printf "\"default\":{\"tag\":\"%s\",\"source\":\"%s\",\"live\":\"%s\",\"stored\":\"%s\"},\"max\":%d,\"count\":%d,\"pins\":[", js(def), src, js(live), js(stored), max, np
      for (i = 1; i <= np; i++) {
        t = P[i]
        printf "%s{\"tag\":\"%s\",\"targetable\":%s,\"default\":%s,%s}", (i > 1 ? "," : ""), js(t), ((t in C) ? "true" : "false"), ((t == def) ? "true" : "false"), lst("bound", t)
      }
      printf "],\"follow\":{%s,\"dns\":%s},\"auto\":{%s},\"orphans\":[%s],\"orphan_count\":%d,\"services_known\":%s", lst("follow", ""), dns, lst("auto", ""), O, no + 0, known
    }' /dev/null
  rm -f "$items" "$pf" "$cf"
}

# ---------- 影响检查 (删除 / 改角色 / 换默认之前) ----------
# exits_impact_calc <remove|default> <服务器名>: 设置 EXITS_ISPIN (remove 时它现在是固定出口吗) · EXITS_DEF_CHANGES (默认固定出口会因此改变吗) · EXITS_REMAIN (其余固定出口个数)
#   · EXITS_AFFECTED (会换出口的项目总数: 指定了它的 + (默认会变时) 跟随默认的 + DNS) · EXITS_IMPACT_JSON (界面用的明细, 不含花括号)
exits_impact_calc() {
  local op=$1 x=$2 items pf cf out known=false dns=false cnt
  EXITS_ISPIN=0; EXITS_DEF_CHANGES=0; EXITS_REMAIN=0; EXITS_AFFECTED=0; EXITS_IMPACT_JSON=''
  exits_resolve
  items=$(mktemp); pf=$(mktemp); cf=$(mktemp)
  if exits_items_full "$items"; then known=true; fi
  if type dns_load >/dev/null 2>&1; then dns_load; [ "${DNS_LEAK:-1}" = 1 ] && [ "${DNS_VIA:-}" = PIN ] && dns=true; fi
  exits_pins_all > "$pf"; ovr_pins > "$cf"
  out=$(LC_ALL=C awk -F'\t' -v op="$op" -v x="$x" -v items="$items" -v pf="$pf" -v cf="$cf" -v def="$EXITS_DEF" -v dns="$dns" -v known="$known" '
    function js(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
    function add(k, s) { L[k] = L[k] (L[k] == "" ? "" : ",") "\"" js(s) "\""; N[k]++ }
    BEGIN {
      while ((getline l < pf) > 0) if (l != "") { P[++np] = l; if (l == x) ispin = 1 }
      while ((getline l < cf) > 0) if (l != "") C[l] = 1
      if (op == "remove") { change = (ispin && x == def) ? 1 : 0 } else { change = (x != def && x != "") ? 1 : 0 }
      while ((getline l < items) > 0) {
        n = split(l, a, "\t"); kind = a[1]; name = a[2]; cls = a[3]; tg = a[4]
        if (cls == "bound" && tg == x && op == "remove" && ispin) add("b" kind, name)
        else if (cls == "follow" && change) add("f" kind, name)
      }
      remain = 0; cand = ""
      for (i = 1; i <= np; i++) if (P[i] != x) { remain++; cand = cand (cand == "" ? "" : ",") "{\"tag\":\"" js(P[i]) "\",\"targetable\":" ((P[i] in C) ? "true" : "false") "}" }
      dd = (change && dns == "true") ? 1 : 0
      aff = N["bapp"] + N["bsite"] + N["bsvc"] + N["fapp"] + N["fsite"] + N["fsvc"] + dd
      printf "%d %d %d %d\n", ispin + 0, change, remain, aff
      printf "\"op\":\"%s\",\"tag\":\"%s\",\"is_pin\":%s,\"default\":\"%s\",\"default_changes\":%s,", op, js(x), (ispin ? "true" : "false"), js(def), (change ? "true" : "false")
      printf "\"bound\":{\"apps\":[%s],\"sites\":[%s],\"services\":[%s]},", L["bapp"], L["bsite"], L["bsvc"]
      printf "\"follow\":{\"apps\":[%s],\"sites\":[%s],\"services\":[%s],\"dns\":%s},", L["fapp"], L["fsite"], L["fsvc"], ((change && dns == "true") ? "true" : "false")
      printf "\"affected\":%d,\"remaining\":%d,\"candidates\":[%s],\"services_known\":%s", aff, remain, cand, known
    }' /dev/null)
  rm -f "$items" "$pf" "$cf"
  cnt=${out%%$'\n'*}; EXITS_IMPACT_JSON=${out#*$'\n'}
  set -- $cnt
  EXITS_ISPIN=${1:-0}; EXITS_DEF_CHANGES=${2:-0}; EXITS_REMAIN=${3:-0}; EXITS_AFFECTED=${4:-0}
}
exits_impact_json() { exits_impact_calc "$1" "$2"; printf '%s' "$EXITS_IMPACT_JSON"; }

exits_reassign_valid() { # <被移除的> <去向>: 去向 = 另一个固定出口 | PINAUTO (其余固定出口 ≥ 2 个, 且被移除的不是默认固定出口) | DEFAULT (被移除的不是默认固定出口)。要先调用过 exits_impact_calc remove
  EXITS_CODE=E_INVALID
  case $2 in
    "$1") EXITS_ERR="新的出口不能是正要移除的这一个"; return 1 ;;
    DEFAULT) if [ "$EXITS_DEF" = "$1" ]; then EXITS_ERR="它自己就是默认固定出口, 请选另一个固定出口作为新的去向"; return 1; fi ;;
    PINAUTO)
      if [ "$EXITS_DEF" = "$1" ]; then EXITS_ERR="它自己就是默认固定出口, 请选另一个固定出口作为新的去向"; return 1; fi
      if [ "$EXITS_REMAIN" -lt 2 ]; then EXITS_ERR="剩下的固定出口不到 2 个, 不能选「在固定出口里自动选」"; return 1; fi ;;
    *) if ! ovr_pins | grep -qxF -- "$2"; then EXITS_ERR="指定的固定出口不存在 (固定出口至少要有 2 个才能单独指定)"; return 1; fi ;;
  esac
  return 0
}
exits_guard_check() { # <服务器名> <去向 (可空)> <接受后果 0|1>: 0 = 放行; 1 = 拒绝, 原因在 EXITS_ERR / EXITS_CODE, 明细在 EXITS_IMPACT_JSON
  local x=$1 y=${2:-} ac=${3:-0}
  EXITS_ERR=''; EXITS_CODE=E_INVALID
  exits_impact_calc remove "$x"
  [ "$EXITS_ISPIN" = 1 ] || return 0                                  # 它现在不是固定出口: 没有什么要保护的
  if [ -n "$y" ]; then exits_reassign_valid "$x" "$y"; return $?; fi
  [ "$EXITS_AFFECTED" -gt 0 ] || return 0
  [ "$ac" = 1 ] && return 0
  EXITS_CODE=E_EXIT_IN_USE
  EXITS_ERR="有应用 / 网站 / 服务正在使用这个固定出口 (或跟随它作默认出口): 先选择让它们改走哪一个出口, 或者明确接受后果再继续"
  return 1
}
exits_runtime_reassign() { # <被移除的> <去向> <冻结 0|1>: 在核心里热切换 (移除之前, 去向还在): 默认固定出口 → 去向; 指定了被移除出口的服务 → 去向; 冻结时跟随默认的服务也钉在去向上。失败不致命 (EXITS_SVC_FAILED)
  local x=$1 y=$2 fz=${3:-0} failed=0 moved=0
  exits_resolve
  if [ "$EXITS_DEF" = "$x" ] && [ "$y" != DEFAULT ] && [ "$y" != PINAUTO ]; then exits_set_live "$y" || failed=$((failed + 1)); fi
  exits_services_move "$x" "$y"; moved=$((moved + EXITS_SVC_MOVED)); failed=$((failed + EXITS_SVC_FAILED))
  if [ "$fz" = 1 ] && [ "$EXITS_DEF" = "$x" ]; then exits_services_move DEFAULT "$y"; moved=$((moved + EXITS_SVC_MOVED)); failed=$((failed + EXITS_SVC_FAILED)); fi
  EXITS_SVC_MOVED=$moved; EXITS_SVC_FAILED=$failed
  return 0
}
exits_remove_prep() { # <服务器名> <去向> <冻结> <接受后果>: txn_delete / txn_role 在真正改服务器之前调用 (持锁, 在事务里); 不放行 → TXN_ERR
  local x=$1 y=${2:-} fz=${3:-0} ac=${4:-0}
  exits_guard_check "$x" "$y" "$ac" || { TXN_ERR=$EXITS_ERR; return 1; }
  [ "$EXITS_ISPIN" = 1 ] || return 0
  if [ -n "$y" ]; then
    exits_move_rows "$x" "$y" "" >/dev/null                           # 指定了它的应用 / 网站 → 去向
    if [ "$EXITS_DEF_CHANGES" = 1 ]; then
      exits_default_save "$y" || true                                 # 默认固定出口也换成去向 (跟随默认的随它走); 去向是 DEFAULT / PINAUTO 时不记 (保持原样)
      if [ "$fz" = 1 ]; then exits_move_rows DEFAULT "$y" "" >/dev/null; fi          # 冻结: 跟随默认的也钉在去向上, 之后默认再换也不动它们
    fi
    oplog "${OP_WHO:-terminal}" "固定出口移除前改派" "$(kv tag "$x" to "$y" freeze "$([ "$fz" = 1 ] && echo 1)" affected "$EXITS_AFFECTED")" ok
  elif [ "$EXITS_AFFECTED" -gt 0 ]; then
    oplog "${OP_WHO:-terminal}" "固定出口移除时没有改派" "$(kv tag "$x" affected "$EXITS_AFFECTED" default_changes "$([ "$EXITS_DEF_CHANGES" = 1 ] && echo 1)" why accept_orphans)" ok
  fi
  return 0
}

# 删除订阅 = 一次删掉它导入的全部服务器 (其中可能有固定出口)。没有逐个改派的界面, 只有「明确接受后果」: 受影响的项目退回默认固定出口 (或没有固定出口时直连)
exits_sub_check() { # <订阅名> <接受后果 0|1>: 0 = 放行; 1 = 拒绝: EXITS_ERR / EXITS_CODE / EXITS_IMPACT_JSON (servers + affected)
  local sub=$1 ac=${2:-0} pf items n servers
  EXITS_ERR=''; EXITS_CODE=E_INVALID; EXITS_AFFECTED=0; EXITS_IMPACT_JSON=''
  pf=$(mktemp); items=$(mktemp)
  srv_list 2>/dev/null | awk -F'\t' -v s="$sub" '$5 == "pin" && $6 == s { print $1 }' > "$pf"
  if [ ! -s "$pf" ]; then rm -f "$pf" "$items"; return 0; fi
  exits_resolve; exits_items_full "$items" || true
  n=$(LC_ALL=C awk -F'\t' -v pf="$pf" -v items="$items" -v def="$EXITS_DEF" '
    BEGIN { while ((getline l < pf) > 0) if (l != "") { S[l] = 1; if (l == def) dh = 1 }
            while ((getline l < items) > 0) { split(l, a, "\t"); if (a[3] == "bound" && (a[4] in S)) n++; else if (a[3] == "follow" && dh) n++ }
            print n + 0 }' /dev/null)
  servers=$(LC_ALL=C awk '{ gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); printf "%s\"%s\"", (n++ ? "," : ""), $0 }' "$pf")
  rm -f "$pf" "$items"
  EXITS_AFFECTED=$n; EXITS_IMPACT_JSON="\"servers\":[$servers],\"affected\":$n"
  [ "$n" -gt 0 ] || return 0
  [ "$ac" = 1 ] && return 0
  EXITS_CODE=E_EXIT_IN_USE
  EXITS_ERR="有应用 / 网站 / 服务正在使用这个订阅里的固定出口 (或跟随其中的默认固定出口): 删除订阅后它们会退回默认固定出口 (没有固定出口时直连)。请明确接受后果再继续"
  return 1
}
exits_sub_prep() { # <订阅名> <接受后果>: txn_subdel 在真正删除之前调用 (在事务里); 不放行 → TXN_ERR
  exits_sub_check "$1" "${2:-0}" || { TXN_ERR=$EXITS_ERR; return 1; }
  if [ "${EXITS_AFFECTED:-0}" -gt 0 ]; then oplog "${OP_WHO:-terminal}" "删除订阅时没有改派固定出口" "$(kv sub "$1" affected "$EXITS_AFFECTED")" ok; fi
  return 0
}

# ---------- 批量移动 / 冻结 ----------
exits_move_check() { # <from> <to> <kind>: from = DEFAULT | PINAUTO | ORPHAN (全部孤儿) | 服务器名; to = DEFAULT | PINAUTO | 固定出口名; kind = 空 | app | site | service
  local from=$1 to=$2 kind=${3:-}
  EXITS_ERR=''; EXITS_CODE=E_INVALID
  case $kind in ''|app|site|service) ;; *) EXITS_ERR="参数无效"; return 1 ;; esac
  case $from in ''|*[\|\"\\]*) EXITS_ERR="参数无效"; return 1 ;; esac
  [ "${#from}" -le 80 ] || { EXITS_ERR="参数无效"; return 1; }
  case $to in
    DEFAULT) ;;
    '') EXITS_ERR="参数无效"; return 1 ;;
    *) ovr_target_valid "$to" || { EXITS_ERR="指定的固定出口不存在 (固定出口至少要有 2 个才能单独指定)"; return 1; } ;;
  esac
  return 0
}
exits_move_rows() { # <from> <to> [app|site]: 一次 awk + 原子替换 overrides.tsv (只动状态是 pin 的行, 标记设为 ack); 不调用 ovr_sync (调用方负责)。stdout: "应用数 网站数"
  local from=$1 to=$2 kind=${3:-} tgt=$2 cf cnt
  [ "$kind" != service ] || { echo "0 0"; return 0; }
  [ "$to" != DEFAULT ] || tgt=''
  [ -f "$H/overrides.tsv" ] || { echo "0 0"; return 0; }
  cf=$(mktemp); cnt=$(mktemp); ovr_pins > "$cf"
  LC_ALL=C awk -F'|' -v OFS='|' -v from="$from" -v tgt="$tgt" -v kind="$kind" -v cf="$cf" -v cnt="$cnt" '
    BEGIN { while ((getline l < cf) > 0) if (l != "") C[l] = 1 }
    ($1 == "app" || $1 == "site") && $3 == "pin" && (kind == "" || kind == $1) {
      t = $5; hit = 0
      if (from == "DEFAULT") hit = (t == "")
      else if (from == "PINAUTO") hit = (t == "PINAUTO")
      else if (from == "ORPHAN") hit = (t != "" && t != "PINAUTO" && !(t in C))
      else hit = (t == from)
      if (hit && t != tgt) { $5 = tgt; $4 = "ack"; if ($1 == "app") na++; else ns++ }
    } { print }
    END { printf "%d %d\n", na + 0, ns + 0 > cnt }' "$H/overrides.tsv" > "$H/overrides.tsv.new" && mv "$H/overrides.tsv.new" "$H/overrides.tsv"
  cat "$cnt"; rm -f "$cf" "$cnt"
}
exits_move_run() { # <from> <to> <kind>: 非 TUN 模式的同步路径 (和 ep_override 一样不经过 apply_config: 规则集文件热加载, 核心不重启)。调用方持有 lock_take。设置 EXITS_M_APPS / _SITES / _SVC / _SVCFAIL / EXITS_SVC_KNOWN
  local r
  r=$(exits_move_rows "$1" "$2" "${3:-}"); EXITS_M_APPS=${r%% *}; EXITS_M_SITES=${r##* }
  ovr_sync
  EXITS_M_SVC=0; EXITS_M_SVCFAIL=0; EXITS_SVC_KNOWN=0
  case ${3:-} in
    app|site) ;;
    *) exits_services_move "$1" "$2" || true; EXITS_M_SVC=$EXITS_SVC_MOVED; EXITS_M_SVCFAIL=$EXITS_SVC_FAILED ;;
  esac
  oplog "${OP_WHO:-dashboard}" "移动固定出口" "$(kv from "$1" to "$2" kind "${3:-}" apps "$EXITS_M_APPS" sites "$EXITS_M_SITES" services "$EXITS_M_SVC")" ok
}
txn_exit_move() { # <from> <to> [kind]: op_txn 的变更函数 (TUN 模式: 之后 apply_config 把规则同步给 root 的核心, 没有助手时才需要管理员授权)
  exits_move_check "$1" "$2" "${3:-}" || { TXN_ERR=$EXITS_ERR; return 1; }
  exits_move_rows "$1" "$2" "${3:-}" >/dev/null
}
op_exit_move() { # <from> <to> [kind]: 后台任务 exits-move。服务的选择在核心里 (不在事务的备份范围内): 事务失败时切回去
  local from=$1 to=$2 kind=${3:-} log
  exits_move_check "$from" "$to" "$kind" || { _txn_end fail "$EXITS_ERR" 0; return 1; }
  log=$(mktemp)
  case $kind in app|site) ;; *) exits_services_move "$from" "$to" "$log" || true ;; esac
  if op_txn "移动固定出口" txn_exit_move "$from" "$to" "$kind"; then rm -f "$log"; return 0; fi
  exits_services_restore "$log"; rm -f "$log"
  return 1
}
