# 终端文案翻译 (中文原文 -> English)。由 i18n.sh 调用:
#   printf '%s\n' "消息" | LC_ALL=C awk -v tbl=<en.tsv> -f i18n.awk
# 表格式: 中文模式<TAB>English   (# 开头为注释)。模式里的 * 是通配: 匹配任意内容, 并在译文里按顺序用 * 回填。
# 没有命中就原样输出。
BEGIN {
  nf = split(tbl, tf, ",")                       # tbl 可以是逗号分隔的多个表 (程序自带的 + 云端内容包里的), 先出现的优先
  for (k = 1; k <= nf; k++) {
    while ((getline line < tf[k]) > 0) {
      if (line ~ /^#/ || line == "") continue
      tab = index(line, "\t"); if (!tab) continue
      zh = substr(line, 1, tab - 1); en = substr(line, tab + 1)
      if (index(zh, "*") == 0) { if (!(zh in exact)) exact[zh] = en }
      else { np++; pat[np] = zh; rep[np] = en }
    }
    close(tf[k])
  }
}
function apply(p, e, m,   nl, L, nE, E, k, rest, pos, cap, out) {
  nl = split(p, L, "*")
  if (substr(m, 1, length(L[1])) != L[1]) return "\001"
  rest = substr(m, length(L[1]) + 1)
  for (k = 2; k < nl; k++) {
    pos = index(rest, L[k]); if (pos == 0) return "\001"
    cap[k - 1] = substr(rest, 1, pos - 1); rest = substr(rest, pos + length(L[k]))
  }
  if (L[nl] != "") {
    if (length(rest) < length(L[nl]) || substr(rest, length(rest) - length(L[nl]) + 1) != L[nl]) return "\001"
    cap[nl - 1] = substr(rest, 1, length(rest) - length(L[nl]))
  } else cap[nl - 1] = rest
  nE = split(e, E, "*"); if (nE != nl) return "\001"
  out = E[1]; for (k = 1; k < nl; k++) out = out cap[k] E[k + 1]
  return out
}
{
  m = $0
  if (m in exact) { print exact[m]; next }
  for (i = 1; i <= np; i++) { r = apply(pat[i], rep[i], m); if (r != "\001") { print r; next } }
  print m
}
