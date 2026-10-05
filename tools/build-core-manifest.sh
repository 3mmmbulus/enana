#!/bin/bash
# 生成并签名 sing-box 兼容清单: 输出 core-manifest.conf + core-manifest.sig, 上传到下载目录的 core/ (https://install.enana.cc/dl/core/)。
#   用法: tools/build-core-manifest.sh <输入清单> <输出目录> <ECDSA P-256 私钥 PEM> [seq] [已下载的核心目录]
#   输入清单每行   版本|名称|SHA-256|最低 enana|最高 enana (空 = 不限)    # 开头是注释
#   例:  1.14.3|darwin-arm64|<sha256>|2.3.9|
# 私钥和云端内容签名是同一把, 只在你手里; 本脚本只在本地读它, 不保存、不上传任何东西。
# 签完立刻用随程序发布的公钥 data/cloud-pub.pem (可用 ENANA_CLOUD_PUBKEY 换成测试公钥) 验一遍: 钥匙不对 (客户端会拒绝这份清单) 在这里就会失败。
# 给了第 5 个参数 (目录里按 <版本>/sing-box-<版本>-<名称>.tar.gz 放着要发布的核心), 还会逐个核对 SHA-256, 防止清单和文件对不上。
set -eu
in=${1:?输入清单}; out=${2:?输出目录}; key=${3:?私钥}; seq=${4:-$(date +%Y%m%d%H%M)}; files=${5:-}
repo=$(cd "$(dirname "$0")/.." && pwd -P)
[ -s "$in" ] && [ -s "$key" ] || { echo "输入清单或私钥不存在" >&2; exit 1; }
[[ $seq =~ ^[0-9]+$ ]] || { echo "seq 必须是数字" >&2; exit 1; }
mkdir -p "$out"; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

rows=0
{
  printf '# enana sing-box 兼容清单 (已签名: core-manifest.sig). 行格式: 版本|名称|SHA-256|最低 enana|最高 enana (空 = 不限)\n'
  printf 'seq|%s\n' "$seq"
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in ''|'#'*) continue ;; esac
    IFS='|' read -r ver name sha min max extra <<EOF
$line
EOF
    [ -z "${extra:-}" ] || { echo "多余的列: $line" >&2; exit 1; }
    [[ $ver =~ ^[0-9]+(\.[0-9]+)+$ ]] || { echo "版本号无效: $line" >&2; exit 1; }
    [[ $name =~ ^[A-Za-z0-9._-]+$ ]] || { echo "名称无效: $line" >&2; exit 1; }
    [[ $sha =~ ^[0-9a-f]{64}$ ]] || { echo "SHA-256 必须是 64 位小写十六进制: $line" >&2; exit 1; }
    [ -z "${min:-}" ] || [[ $min =~ ^[0-9]+(\.[0-9]+)+$ ]] || { echo "最低 enana 版本无效: $line" >&2; exit 1; }
    [ -z "${max:-}" ] || [[ $max =~ ^[0-9]+(\.[0-9]+)+$ ]] || { echo "最高 enana 版本无效: $line" >&2; exit 1; }
    if [ -n "$files" ]; then
      f="$files/$ver/sing-box-$ver-$name.tar.gz"
      [ -f "$f" ] || { echo "找不到核心文件: $f" >&2; exit 1; }
      [ "$(shasum -a 256 "$f" | awk '{print $1}')" = "$sha" ] || { echo "SHA-256 和文件不一致: $f" >&2; exit 1; }
    fi
    printf '%s|%s|%s|%s|%s\n' "$ver" "$name" "$sha" "${min:-}" "${max:-}"
    rows=$((rows + 1))
  done < "$in"
} > "$tmp/core-manifest.conf"
[ "$rows" -gt 0 ] || { echo "清单里没有任何版本行" >&2; exit 1; }

/usr/bin/openssl dgst -sha256 -sign "$key" -out "$tmp/core-manifest.sig" "$tmp/core-manifest.conf"

# 用随程序发布的公钥验签 (文件里可以有多把公钥, 任意一把验过即可, 和客户端 cloud_verify 一致)
pub=${ENANA_CLOUD_PUBKEY:-$repo/data/cloud-pub.pem}
awk -v d="$tmp" '/BEGIN PUBLIC KEY/ { n++ } n { print > (d "/k" n ".pem") }' "$pub"
ok=1
for k in "$tmp"/k*.pem; do [ -f "$k" ] || continue
  if /usr/bin/openssl dgst -sha256 -verify "$k" -signature "$tmp/core-manifest.sig" "$tmp/core-manifest.conf" >/dev/null 2>&1; then ok=0; break; fi
done
[ "$ok" = 0 ] || { echo "签名无法用 data/cloud-pub.pem 验证: 这不是云端内容使用的那把私钥, 客户端会拒绝这份清单, 未输出任何文件" >&2; exit 1; }

cp "$tmp/core-manifest.conf" "$tmp/core-manifest.sig" "$out/"
chmod 644 "$out/core-manifest.conf" "$out/core-manifest.sig"
echo "已生成 $out/core-manifest.conf ($rows 行, seq=$seq) 和 core-manifest.sig, 签名已用 data/cloud-pub.pem 验证通过"
