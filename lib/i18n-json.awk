# 翻译一段 JSON 文本里指定键的字符串值 (目录 / 规则库等静态数据的多语言版本)。
#   awk -v tbl=<en.tsv> -v keys='name|desc|ai|account' -f i18n-lib.awk -f i18n-json.awk  文件
# 整个文件当作一条记录读入; 只改 "键":"值" 里值的内容 (值里不含引号/反斜杠, 由生成方保证)。
BEGIN { RS = "\001"; nk = split(keys, ka, "|"); for (i = 1; i <= nk; i++) K[ka[i]] = 1 }
{
  s = $0; out = ""
  while (match(s, /"[A-Za-z_0-9-]+":"[^"]*"/)) {
    pre = substr(s, 1, RSTART - 1); tok = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
    c = index(tok, "\":\""); key = substr(tok, 2, c - 2); val = substr(tok, c + 3, length(tok) - c - 3)
    if (key in K) { nv = T(val); if (nv != val) { gsub(/\\/, "\\\\", nv); gsub(/"/, "\\\"", nv); val = nv } }     # 译文里的 \ 和 " 要转义, 否则 JSON 会被破坏
    out = out pre "\"" key "\":\"" val "\""
  }
  printf "%s%s", out, s
}
