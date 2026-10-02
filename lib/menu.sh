# 键盘选择菜单 (bash 3.2 兼容, 纯终端控制序列, 无依赖)。
#
# 用法: 先 menu_reset, 用 menu_add 逐项添加, 再 menu_run, 最后用 menu_val <id> 取值
#   menu_add id 名称 类型(toggle|choice) 当前值(=推荐值) [选项 "键:显示|键:显示"] [推荐理由] [锁定 1/0]
# 键位: ↑/↓ 或 k/j 移动 · 空格/←/→ 切换 · r 恢复推荐 · Enter 确认 · q 退出
# 非交互 (无终端 / ENANA_YES=1) 时直接采用当前值 (即推荐值)。ENANA_MENU_FORCE=1 可在测试里强制走交互并从 stdin 读键。

M_N=0
menu_reset() { M_N=0; }
menu_add() {
  local i=$M_N
  eval "M_ID_$i=\$1; M_LABEL_$i=\$2; M_KIND_$i=\$3; M_VAL_$i=\$4; M_REC_$i=\$4; M_OPTS_$i=\${5:-}; M_WHY_$i=\${6:-}; M_LOCK_$i=\${7:-0}"
  M_N=$((M_N + 1))
}
_mn_get() { eval "printf '%s' \"\${M_$1_$2:-}\""; }          # _mn_get 字段 序号
_mn_set() { eval "M_$1_$2=\$3"; }                             # _mn_set 字段 序号 值
menu_val() { local i; for ((i = 0; i < M_N; i++)); do [ "$(_mn_get ID "$i")" = "$1" ] && { _mn_get VAL "$i"; printf '\n'; return; }; done; }

_menu_opt_label() { # 序号 键 -> 显示名
  local o rest; rest=$(_mn_get OPTS "$1")
  while [ -n "$rest" ]; do
    o=${rest%%|*}; if [ "$rest" = "$o" ]; then rest=''; else rest=${rest#*|}; fi
    [ "${o%%:*}" = "$2" ] && { _t "${o#*:}"; return; }
  done
  printf '%s' "$2"
}
_menu_opt_next() { # 序号 当前键 -> 下一个选项键 (循环)
  local o rest first='' k found=0; rest=$(_mn_get OPTS "$1")
  while [ -n "$rest" ]; do
    o=${rest%%|*}; if [ "$rest" = "$o" ]; then rest=''; else rest=${rest#*|}; fi
    k=${o%%:*}; [ -z "$first" ] && first=$k
    [ "$found" = 1 ] && { printf '%s' "$k"; return; }
    [ "$k" = "$2" ] && found=1
  done
  printf '%s' "$first"
}
_menu_flip() {
  local i=$1 v
  [ "$(_mn_get LOCK "$i")" = 1 ] && return 0
  v=$(_mn_get VAL "$i")
  if [ "$(_mn_get KIND "$i")" = toggle ]; then if [ "$v" = 1 ]; then _mn_set VAL "$i" 0; else _mn_set VAL "$i" 1; fi
  else _mn_set VAL "$i" "$(_menu_opt_next "$i" "$v")"; fi
  [ "$(_mn_get ID "$i")" = lang ] && { I18N_LANG=$(_mn_get VAL "$i"); LANG_UI=$I18N_LANG; }    # 切换语言: 菜单马上换成新语言重画
  return 0
}
_menu_draw() { # 恰好输出 M_N+2 行
  local cur=$1 i mark box star v
  for ((i = 0; i < M_N; i++)); do
    if [ "$i" -eq "$cur" ]; then mark="${C}❯${N}"; else mark=' '; fi
    v=$(_mn_get VAL "$i")
    if [ "$(_mn_get KIND "$i")" = toggle ]; then
      if [ "$v" = 1 ]; then box="${G}[✓]${N}"; else box="[ ]"; fi
    else box="${C}‹$(_menu_opt_label "$i" "$v")›${N}"; fi
    star=''; [ "$v" = "$(_mn_get REC "$i")" ] && star="${DIM}$(_t 推荐)${N}"
    if [ "$(_mn_get LOCK "$i")" = 1 ]; then box="${DIM}[✓]${N}"; star="${DIM}$(_t '(必装/已就绪)')${N}"; fi
    printf '\033[2K\r %s %s %s  %s\n' "$mark" "$box" "$(_t "$(_mn_get LABEL "$i")")" "$star"
  done
  printf '\033[2K\r   %s%s%s\n' "$DIM" "$(_t "$(_mn_get WHY "$cur")")" "$N"
  printf '\033[2K\r   %s%s%s\n' "$DIM" "$(_t '↑↓ 移动 · 空格/←→ 切换 · r 恢复推荐 · Enter 开始安装 · q 退出')" "$N"
}

menu_interactive() { [ -z "${ENANA_YES:-}" ] && { { [ -t 0 ] && [ -t 1 ]; } || [ -n "${ENANA_MENU_FORCE:-}" ]; }; }

menu_run() { # 返回 1 = 用户按 q 退出
  local cur=0 key rest first=1 i
  [ "$M_N" -gt 0 ] || return 0
  menu_interactive || return 0
  printf '\033[?25l'
  while :; do
    [ "$first" = 1 ] || printf '\033[%dA' $((M_N + 2))
    first=0
    _menu_draw "$cur"
    IFS= read -rsn1 key || break
    case $key in
      $'\033')
        rest=''; read -rsn2 -t 1 rest || true
        case $rest in
          '[A') cur=$(( (cur + M_N - 1) % M_N )) ;;
          '[B') cur=$(( (cur + 1) % M_N )) ;;
          '[C'|'[D') _menu_flip "$cur" ;;
        esac ;;
      k) cur=$(( (cur + M_N - 1) % M_N )) ;;
      j) cur=$(( (cur + 1) % M_N )) ;;
      ' ') _menu_flip "$cur" ;;
      r|R) for ((i = 0; i < M_N; i++)); do [ "$(_mn_get LOCK "$i")" = 1 ] || _mn_set VAL "$i" "$(_mn_get REC "$i")"; done ;;
      q|Q) printf '\033[?25h\n'; return 1 ;;
      '') break ;;
    esac
  done
  printf '\033[?25h'
  return 0
}
