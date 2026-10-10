#!/bin/bash
# 上线重签后的清单 (安装包不变)。在下载服务器上以 root 运行:
#   sudo bash deploy-resign.sh RELEASE_DIR
# 检查: 两份清单都能用 release-pubkey.pem 验证; 版本与线上当前的版本一致 (只允许续期, 不能换内容);
# 序号比线上的大 (不能回滚); 安装包的大小与 sha256 与新清单一致。替换前把旧文件备份。
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo 'Run as root on the download host.' >&2; exit 2; }
release=${1:?Usage: deploy-resign.sh RELEASE_DIR}
dl=/var/www/enana-dl
[ -d "$release" ] && [ ! -L "$release" ] && [ -d "$dl" ] && [ ! -L "$dl" ] || exit 2
mkdir -p /var/backups/enana/releases
exec 9>/var/backups/enana/resign-publish.lock
flock -n 9 || { echo 'Another re-sign is running.' >&2; exit 2; }
for n in manifest.json manifest.json.sig windows-manifest.json windows-manifest.json.sig release-pubkey.pem; do
  [ -f "$release/$n" ] || { echo "missing $n" >&2; exit 2; }
done
openssl dgst -sha256 -verify "$release/release-pubkey.pem" -signature "$release/manifest.json.sig" "$release/manifest.json" >/dev/null 2>&1 || { echo 'manifest.json does not verify; refusing.' >&2; exit 2; }
openssl dgst -sha256 -verify "$release/release-pubkey.pem" -signature "$release/windows-manifest.json.sig" "$release/windows-manifest.json" >/dev/null 2>&1 || { echo 'windows-manifest.json does not verify; refusing.' >&2; exit 2; }
python3 - "$release" "$dl" <<'PY'
import hashlib, json, pathlib, sys
rel, dl = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
for name in ("manifest.json", "windows-manifest.json"):
    new = json.loads((rel / name).read_text())
    cur = json.loads((dl / name).read_text())
    assert new["version"] == cur["version"], f"{name}: version changed ({cur['version']} -> {new['version']}); a re-sign must not change content"
    assert new["seq"] > cur["seq"], f"{name}: seq must increase ({cur['seq']} -> {new['seq']})"
    assert new["sha256"] == cur["sha256"] and new["size"] == cur["size"] and new["url"] == cur["url"], f"{name}: package changed"
    pkg = dl / new["url"].rsplit("/", 1)[1]
    data = pkg.read_bytes()
    assert len(data) == new["size"], f"{name}: package size mismatch"
    assert hashlib.sha256(data).hexdigest() == new["sha256"], f"{name}: package sha256 mismatch"
    print(f"ok {name}: {new['version']} seq {cur['seq']} -> {new['seq']}")
PY
backup="/var/backups/enana/releases/resign-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$backup"; chmod 700 "$backup"
for name in manifest.json manifest.json.sig windows-manifest.json windows-manifest.json.sig; do
  [ ! -e "$dl/$name" ] || cp -p "$dl/$name" "$backup/$name"
done
for name in manifest.json.sig manifest.json windows-manifest.json.sig windows-manifest.json; do   # 签名先于清单, 线上的清单和签名始终配套
  install -m 644 -o root -g root "$release/$name" "$dl/.enana-resign-$$"
  mv -f "$dl/.enana-resign-$$" "$dl/$name"
done
cp -p "$release/release-pubkey.pem" "$dl/release-pubkey.pem" 2>/dev/null || true
for name in manifest.json manifest.json.sig windows-manifest.json windows-manifest.json.sig; do cmp -s "$release/$name" "$dl/$name" || { echo "post-check failed: $name" >&2; exit 1; }; done
echo "Re-signed manifests published. Previous files kept in $backup"
