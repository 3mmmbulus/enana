# 翻译函数库 (给其它 awk 程序用): awk -v tbl=<en.tsv> -f i18n-lib.awk -f 你的程序.awk
# tbl 为空 (中文) 时 T() 原样返回。表格式同 i18n.awk: 中文模式<TAB>English, * 为通配 (按出现顺序回填)。
BEGIN {
  nf = split(tbl, tf, ",")                       # tbl 可以是逗号分隔的多个表 (程序自带的 + 云端内容包里的), 先出现的优先
  for (k = 1; k <= nf; k++) if (tf[k] != "") {
    while ((getline line < tf[k]) > 0) {
      if (line ~ /^#/ || line == "") continue
      tab = index(line, "\t"); if (!tab) continue
      zh = substr(line, 1, tab - 1); en = substr(line, tab + 1)
      if (index(zh, "*") == 0) { if (!(zh in tx_exact)) tx_exact[zh] = en }
      else { tx_np++; tx_pat[tx_np] = zh; tx_rep[tx_np] = en }
    }
    close(tf[k])
  }
}
function tx_apply(p, e, m,   nl, L, nE, E, k, rest, pos, cap, out) {
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
function T(m,   i, r) {
  if (tbl == "") return m
  if (m in tx_exact) return tx_exact[m]
  for (i = 1; i <= tx_np; i++) { r = tx_apply(tx_pat[i], tx_rep[i], m); if (r != "\001") return r }
  return m
}
