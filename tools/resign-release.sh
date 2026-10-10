#!/bin/bash
# 重签已发布的下载清单, 安装包本身不变: 版本 / sha256 / 大小 / 地址 / commit 保持原样, 只更新 seq (现在的时间) 和 expires (seq + EXPIRY_DAYS 天) 和 released。
#   tools/resign-release.sh OUT_DIR PRIVATE_KEY_PEM [BASE_URL]
#   EXPIRY_DAYS=30 (默认, 1 ~ 90)   PUB_KEY=data/release-pub.pem (默认)
# 只有下面三件事都成立才会签名: 两份清单都能用公钥验证; 线上安装包的大小和 sha256 与清单一致; 安装包里的 VERSION 与清单版本一致。
# 私钥只交给 openssl, 本脚本不读取也不打印它。
set -euo pipefail
out=${1:?Usage: resign-release.sh OUT_DIR PRIVATE_KEY_PEM [BASE_URL]}
key=${2:?private key path}
base=${3:-https://install.enana.cc/dl}
repo=$(cd "$(dirname "$0")/.." && pwd -P)
pub=${PUB_KEY:-$repo/data/release-pub.pem}
days=${EXPIRY_DAYS:-30}
[[ $days =~ ^[0-9]+$ ]] && [ "$days" -ge 1 ] && [ "$days" -le 90 ] || { echo 'EXPIRY_DAYS must be a whole number from 1 to 90' >&2; exit 2; }
[ -f "$key" ] && [ -f "$pub" ] || { echo 'private key and public key must exist' >&2; exit 2; }
mkdir -p "$out"; out=$(cd "$out" && pwd -P)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

for name in manifest.json manifest.json.sig windows-manifest.json windows-manifest.json.sig; do
  curl -fsS --retry 3 --max-time 300 -o "$tmp/$name" "$base/$name" || { echo "cannot fetch $name" >&2; exit 1; }
done
openssl dgst -sha256 -verify "$pub" -signature "$tmp/manifest.json.sig" "$tmp/manifest.json" >/dev/null || { echo 'manifest.json does not verify; refusing to re-sign' >&2; exit 1; }
openssl dgst -sha256 -verify "$pub" -signature "$tmp/windows-manifest.json.sig" "$tmp/windows-manifest.json" >/dev/null || { echo 'windows-manifest.json does not verify; refusing to re-sign' >&2; exit 1; }
for m in manifest.json windows-manifest.json; do
  arc=$(python3 -c 'import json,sys,os;print(os.path.basename(json.load(open(sys.argv[1]))["url"]))' "$tmp/$m")
  curl -fsS --retry 3 --max-time 900 -o "$tmp/$arc" "$base/$arc" || { echo "cannot fetch $arc" >&2; exit 1; }
done

python3 - "$tmp" "$out" "$days" <<'PY'
import datetime, hashlib, json, os, pathlib, sys, tarfile, time, zipfile
tmp, out, days = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), int(sys.argv[3])
now = int(time.time())
for name in ("manifest.json", "windows-manifest.json"):
    m = json.loads((tmp / name).read_text())
    arc = tmp / os.path.basename(m["url"])
    data = arc.read_bytes()
    if len(data) != m["size"]:
        sys.exit(f"{name}: package size {len(data)} does not match the manifest ({m['size']}); refusing to re-sign")
    if hashlib.sha256(data).hexdigest() != m["sha256"]:
        sys.exit(f"{name}: package sha256 does not match the manifest; refusing to re-sign")
    member = f"enana-{m['version']}/VERSION"
    if arc.suffix == ".zip":
        with zipfile.ZipFile(arc) as z:
            version = z.read(member).decode().strip()
    else:
        with tarfile.open(arc) as t:
            version = t.extractfile(member).read().decode().strip()
    if version != m["version"]:
        sys.exit(f"{name}: VERSION in the package is {version!r}, the manifest says {m['version']!r}; refusing to re-sign")
    old_seq = int(m.get("seq", 0))
    seq = max(now, old_seq + 1)                      # 序号必须比已发布的大, 旧客户端才会接受
    m["seq"] = seq
    m["expires"] = seq + days * 86400
    m["released"] = datetime.datetime.fromtimestamp(seq, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    (out / name).write_text(json.dumps(m, separators=(",", ":"), ensure_ascii=False) + "\n")
    print(f"{name}: version {m['version']}, seq {old_seq} -> {seq}, expires in {days} days")
PY
cp "$pub" "$out/release-pubkey.pem"
for name in manifest.json windows-manifest.json; do
  openssl dgst -sha256 -sign "$key" -out "$out/$name.sig" "$out/$name"
  openssl dgst -sha256 -verify "$out/release-pubkey.pem" -signature "$out/$name.sig" "$out/$name" >/dev/null || { echo "$name: new signature does not verify" >&2; exit 1; }
  echo "signed and verified $name"
done
echo "re-signed release written to $out"
