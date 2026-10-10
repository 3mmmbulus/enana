#!/bin/bash
# 每天检查一次线上清单的剩余有效期。剩余不到 RESIGN_BEFORE_DAYS 天 (默认 14) 时: 用同一份安装包重签 →
# 上传到下载服务器并用 deploy-resign.sh 上线 → 同步到 GitHub Release 的清单资源。
# 失败时写日志并弹出系统通知。RESIGN_DRY_RUN=1 只检查、不做任何改动。
set -uo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd -P)
key=${RELEASE_KEY:-$HOME/.enana-release-keys/release-signing-key.pem}
before=${RESIGN_BEFORE_DAYS:-14}
host=${RESIGN_HOST:-goco-shili.asia-east1-b.cloudsuo}
log="$HOME/Library/Logs/enana-resign.log"
mkdir -p "$(dirname "$log")"
say()  { echo "$(date '+%F %T') $*" | tee -a "$log"; }
fail() { say "FAILED: $*"; osascript -e "display notification \"$*\" with title \"enana 清单重签失败\"" >/dev/null 2>&1 || true; exit 1; }

expires=$(curl -fsS --noproxy '*' --max-time 60 https://install.enana.cc/dl/manifest.json | python3 -c 'import json,sys;print(json.load(sys.stdin)["expires"])') || fail "无法读取线上清单"
version=$(curl -fsS --noproxy '*' --max-time 60 https://install.enana.cc/dl/manifest.json | python3 -c 'import json,sys;print(json.load(sys.stdin)["version"])') || fail "无法读取线上版本"
left=$(( (expires - $(date +%s)) / 86400 ))
say "线上清单 v${version} 剩余 ${left} 天"
[ "$left" -lt "$before" ] || { say "无需重签 (阈值 ${before} 天)"; exit 0; }
if [ "${RESIGN_DRY_RUN:-0}" = 1 ]; then say "DRY RUN: 会重签 v${version} 并上线"; exit 0; fi

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
bash "$repo/tools/resign-release.sh" "$work/release" "$key" || fail "重签失败 (见上面的输出)"
ssh -o BatchMode=yes "$host" 'rm -rf /home/fa/enana-stage/resign && mkdir -p /home/fa/enana-stage/resign' || fail "无法连接下载服务器"
scp -q -o BatchMode=yes "$work"/release/* "$host:/home/fa/enana-stage/resign/" || fail "上传失败"
ssh -o BatchMode=yes "$host" 'sudo bash /home/fa/enana-stage/tools/deploy-resign.sh /home/fa/enana-stage/resign' || fail "上线失败 (服务器没有替换清单)"
gh release upload "v${version}" "$work/release/manifest.json" "$work/release/manifest.json.sig" "$work/release/windows-manifest.json" "$work/release/windows-manifest.json.sig" --clobber --repo 3mmmbulus/enana >/dev/null 2>&1 || say "注意: GitHub Release v${version} 的清单没有更新 (下载服务器已上线)"
new=$(curl -fsS --noproxy '*' --max-time 60 https://install.enana.cc/dl/manifest.json | python3 -c 'import json,sys;m=json.load(sys.stdin);print(m["expires"])')
say "重签完成: v${version} 新的过期时间 $(date -r "$new" '+%F %T')"
