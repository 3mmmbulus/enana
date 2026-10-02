# 终端国际化 (中文 / English; 以后加语言: 在 data/i18n/ 放 <代码>.tsv, 并在 I18N_LANGS 里登记)。依赖 common.sh。
#
# 约定: 源码里的提示一律写中文 (相当于 gettext 的 msgid), 译文在 data/i18n/<语言>.tsv。
# 输出函数 ok/info/warn/die/step/confirm 会自动翻译; 带变量的句子在表里用 * 通配。工具 tools/i18n-verify.py 检查缺失的译文。
# 语言选择: ENANA_LANG > settings.env 的 LANG_UI > 系统语言 (中文系统=zh, 其它=en)。

I18N_LANGS="zh en"

i18n_detect() { # 按系统语言猜测
  local l
  l=$(defaults read -g AppleLanguages 2>/dev/null | awk 'NR==2 { gsub(/[ ",]/, ""); print; exit }')
  [ -n "$l" ] || l=${LANG:-}
  case $l in zh*|ZH*) echo zh ;; '') echo en ;; *) echo en ;; esac
}
i18n_init() {
  local l=${ENANA_LANG:-${LANG_UI:-}}
  case " $I18N_LANGS " in *" $l "*) ;; *) l=$(i18n_detect) ;; esac
  LANG_UI=$l
}
i18n_tbl() { # <语言> -> 译表路径 (逗号分隔): 程序自带的, 加上云端内容包里的 (如果有)
  local t="$DATA/i18n/$1.tsv"
  [ -f "$H/cloud/content/i18n/$1-data.tsv" ] && t="$t,$H/cloud/content/i18n/$1-data.tsv"
  printf '%s' "$t"
}
i18n_t() { # i18n_t "中文原文" -> 当前语言的译文 (zh 或没有译表时原样输出)
  local lang=${I18N_LANG:-${LANG_UI:-zh}} out
  if [ "$lang" = zh ] || [ ! -f "$DATA/i18n/$lang.tsv" ]; then printf '%s' "$1"; return 0; fi
  out=$(printf '%s\n' "$1" | LC_ALL=C awk -v tbl="$(i18n_tbl "$lang")" -f "$LIB/i18n.awk")
  printf '%s' "$out"
}
_t() { i18n_t "$1"; }
i18n_filter() { # stdin 每行一条中文 -> 当前语言 (批量翻译, 只起一个 awk)
  local lang=${I18N_LANG:-${LANG_UI:-zh}}
  if [ "$lang" = zh ] || [ ! -f "$DATA/i18n/$lang.tsv" ]; then cat; else LC_ALL=C awk -v tbl="$(i18n_tbl "$lang")" -f "$LIB/i18n.awk"; fi
}
i18n_json() { # i18n_json '键1|键2|…'  stdin 里的 JSON: 只翻译这些键对应的字符串值 (目录 / 规则库 / DNS 页等返回给仪表盘的数据)
  local lang=${I18N_LANG:-${LANG_UI:-zh}}
  if [ "$lang" = zh ] || [ ! -f "$DATA/i18n/$lang.tsv" ]; then cat; else LC_ALL=C awk -v tbl="$(i18n_tbl "$lang")" -v keys="$1" -f "$LIB/i18n-lib.awk" -f "$LIB/i18n-json.awk"; fi
}
