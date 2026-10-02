#!/bin/bash
# 构建「云端内容包」+ 签名清单 (格式见 docs/CLOUD_API.md): 把一个内容目录打成 content-<seq>.tar.gz, 写 manifest.json 并用私钥签名 manifest.sig。
#   用法: tools/build-content-bundle.sh <内容目录> <输出目录> <ECDSA P-256 私钥 PEM> [seq] [min_client]
# 内容目录里需要: services.conf groups.conf rulesets.conf apps.conf  (可选 i18n/<语言>-data.tsv 和 vps/{lib,probe,provision,redetect}.sh)。公开仓库只包含这个通用构建脚本和测试用的合成数据;
# 真正的精选内容和签名私钥在私有的云端工作区里, 不在本仓库。
set -eu
src=${1:?内容目录}; out=${2:?输出目录}; key=${3:?私钥}; seq=${4:-$(date +%Y%m%d%H%M)}; minc=${5:-2.1.0}
for f in services.conf groups.conf rulesets.conf apps.conf; do [ -s "$src/$f" ] || { echo "缺少 $src/$f" >&2; exit 1; }; done
ver="$(date +%Y.%m.%d).${seq: -2}"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/pkg/i18n" "$out"
cp "$src/services.conf" "$src/groups.conf" "$src/rulesets.conf" "$src/apps.conf" "$tmp/pkg/"
[ -d "$src/i18n" ] && cp "$src"/i18n/*-data.tsv "$tmp/pkg/i18n/" 2>/dev/null || true
rmdir "$tmp/pkg/i18n" 2>/dev/null || true
if [ -d "$src/vps" ]; then mkdir -p "$tmp/pkg/vps"; cp "$src"/vps/*.sh "$tmp/pkg/vps/"; fi        # 服务器部署脚本 (SSH 一键部署用; 只在云端内容里, 不在公开仓库)
printf '%s\n' "$seq" > "$tmp/pkg/SEQ"; printf '%s\n' "$ver" > "$tmp/pkg/VERSION"
(cd "$tmp/pkg" && COPYFILE_DISABLE=1 tar -czf "$out/content-$seq.tar.gz" --no-xattrs . 2>/dev/null || COPYFILE_DISABLE=1 tar -czf "$out/content-$seq.tar.gz" .)
sha=$(shasum -a 256 "$out/content-$seq.tar.gz" | cut -d' ' -f1); size=$(wc -c < "$out/content-$seq.tar.gz" | tr -d ' ')
printf '{"channel":"stable","bundles":{"content":{"seq":%s,"version":"%s","url":"/v1/content-%s.tar.gz","sha256":"%s","size":%s,"min_client":"%s"}}}' "$seq" "$ver" "$seq" "$sha" "$size" "$minc" > "$out/manifest.json"
/usr/bin/openssl dgst -sha256 -sign "$key" -out "$out/manifest.sig" "$out/manifest.json"
echo "content-$seq.tar.gz  sha256=$sha  size=$size  version=$ver"
