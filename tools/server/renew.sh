#!/bin/bash
# 续期下载清单 (由 systemd 定时器以 root 运行; 服务器上位于 /opt/enana-release/renew.sh)。
# 签名由 enana-release 用户完成 (私钥只有它能读), 发布由 root 完成 (deploy-resign.sh)。
# RENEW_FORCE=1 可以强制续期一次 (测试用)。
set -euo pipefail
ROOT=/opt/enana-release
WORK=/var/lib/enana-release/work
KEY=/var/lib/enana-release/release-signing-key.pem
BEFORE=${RESIGN_BEFORE_DAYS:-14}
LOG=/var/log/enana-release-renew.log
exec >>"$LOG" 2>&1
echo "$(date '+%F %T') check"
exp=$(python3 -c 'import json;print(json.load(open("/var/www/enana-dl/manifest.json"))["expires"])')
left=$(( (exp - $(date +%s)) / 86400 ))
echo "published manifest: ${left} days left"
if [ "$left" -ge "$BEFORE" ] && [ "${RENEW_FORCE:-0}" != 1 ]; then echo "no action (threshold ${BEFORE} days)"; exit 0; fi
rm -rf "$WORK/out"; install -d -m 0750 -o enana-release -g enana-release "$WORK/out"
sudo -u enana-release env PUB_KEY="$ROOT/data/release-pub.pem" EXPIRY_DAYS="${EXPIRY_DAYS:-30}" \
  bash "$ROOT/tools/resign-release.sh" "$WORK/out" "$KEY" https://install.enana.cc/dl
bash "$ROOT/tools/deploy-resign.sh" "$WORK/out"
echo "$(date '+%F %T') renewed"
