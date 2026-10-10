#!/bin/bash
# 重签 (tools/resign-release.sh): 续期后的清单内容不变、序号增大、有效期 = 序号 + EXPIRY_DAYS 天;
# 安装包被篡改 / 有效期超过 90 天 → 拒绝。只用临时目录和测试密钥, 不碰线上。
set -eu
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
openssl ecparam -name prime256v1 -genkey -noout -out "$W/key.pem"
openssl ec -in "$W/key.pem" -pubout -out "$W/pub.pem" 2>/dev/null
bash "$REPO/tools/build-release.sh" "$W/dist" >/dev/null
bash "$REPO/tools/sign-release.sh" "$W/dist" "$W/key.pem" "$W/pub.pem" >/dev/null
export PUB_KEY="$W/pub.pem"
fail=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; fail=1; }

sleep 1
if EXPIRY_DAYS=30 bash "$REPO/tools/resign-release.sh" "$W/out" "$W/key.pem" "file://$W/dist" >/dev/null 2>&1; then ok "正常的发布目录可以重签"; else bad "重签正常的发布目录失败"; fi
python3 - "$W/dist" "$W/out" <<'PY' && ok "内容不变: 版本 / sha256 / 大小 / 地址 / commit 都一样; 序号增大; 有效期 = 序号 + 30 天" || { echo "  FAIL 清单字段检查"; exit 1; }
import json, pathlib, sys
old, new = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
for name in ("manifest.json", "windows-manifest.json"):
    a, b = json.loads((old / name).read_text()), json.loads((new / name).read_text())
    for k in ("version", "sha256", "size", "url", "commit", "platform", "channel"):
        if k in a: assert a[k] == b[k], (name, k)
    assert b["seq"] > a["seq"], (name, "seq")
    assert b["expires"] == b["seq"] + 30 * 86400, (name, "expires")
PY
for name in manifest.json windows-manifest.json; do
  if openssl dgst -sha256 -verify "$W/pub.pem" -signature "$W/out/$name.sig" "$W/out/$name" >/dev/null 2>&1; then ok "$name 的新签名可以验证"; else bad "$name 的新签名不能验证"; fi
done

cp -R "$W/dist" "$W/tampered"; printf 'x' >> "$W/tampered/enana-"*.tar.gz
if EXPIRY_DAYS=30 bash "$REPO/tools/resign-release.sh" "$W/out2" "$W/key.pem" "file://$W/tampered" >/dev/null 2>&1; then bad "安装包被篡改时仍然重签了"; else ok "安装包被篡改 → 拒绝重签"; fi
[ ! -e "$W/out2/manifest.json" ] && ok "拒绝时没有生成新清单" || bad "拒绝时仍然生成了清单"

if EXPIRY_DAYS=1000 bash "$REPO/tools/resign-release.sh" "$W/out3" "$W/key.pem" "file://$W/dist" >/dev/null 2>&1; then bad "超过 90 天的有效期被接受"; else ok "有效期超过 90 天 → 拒绝"; fi
[ "$fail" = 0 ] && echo "ok resign-release" || { echo "resign-release: 有失败"; exit 1; }
