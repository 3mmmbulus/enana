# 云端内容: 登录后由 enana 云端下发的精选数据 (服务目录 / 分组 / 规则库 / 应用推荐 / 英文译文)。依赖 common.sh auth.sh session.sh config.sh fetch.sh ops.sh。
#
# 为什么: 公开仓库里只放「瘦客户端」+ 最小基线; 持续维护的精选内容留在云端, 按账号下发 (见 docs/ARCHITECTURE.md)。
# 流程: 拉取 manifest (签名) → 验签 (内置公钥 data/cloud-pub.pem, ECDSA P-256 / SHA-256) → 防回滚 (seq 不能变小) → 下载内容包 →
#       校验 sha256 / 大小 / 文件名白名单 / 每个文件的格式 → 原子替换 $H/cloud/content (符号链接) → 重新生成配置 (失败自动回滚)。
# 验签失败 / 格式不对 / 网络不通: 保留旧内容 (或基线), 不影响代理; 内容只在本机缓存, 没有任何用户数据上传。
#
#   $H/cloud/content -> content-<seq>/   当前生效的内容 (services.conf groups.conf rulesets.conf apps.conf SEQ VERSION i18n/en-data.tsv, 以及 vps/ 下的服务器部署脚本)
#   $H/cloud/state                       checked=<时间> error=<上次错误>

CLOUD_PUBKEY=${ENANA_CLOUD_PUBKEY:-$DATA/cloud-pub.pem}
CLOUD_FILES_OK='^(services\.conf|groups\.conf|rulesets\.conf|apps\.conf|SEQ|VERSION|i18n/[a-z]{2}-data\.tsv|vps/(lib|probe|provision|redetect)\.sh)$'

cloud_seq() { local s=0; [ -f "$H/cloud/content/SEQ" ] && IFS= read -r s < "$H/cloud/content/SEQ"; printf '%s' "${s:-0}"; }
cloud_version() { local s=''; [ -f "$H/cloud/content/VERSION" ] && IFS= read -r s < "$H/cloud/content/VERSION"; printf '%s' "${s:-}"; }
cloud_state_set() { mkdir -p "$H/cloud"; printf 'checked=%s\nerror=%s\n' "$(now)" "$1" > "$H/cloud/state"; }

# cloud_verify <文件> <签名文件>  (公钥文件里可以有多把公钥: 依次尝试, 方便以后换密钥)
cloud_verify() {
  local f=$1 sig=$2 d k ok=1
  [ -s "$CLOUD_PUBKEY" ] && [ -s "$sig" ] || return 1
  d=$(mktemp -d)
  awk -v d="$d" '/BEGIN PUBLIC KEY/ { n++ } n { print > (d "/k" n ".pem") }' "$CLOUD_PUBKEY"
  for k in "$d"/k*.pem; do [ -f "$k" ] || continue; if /usr/bin/openssl dgst -sha256 -verify "$k" -signature "$sig" "$f" >/dev/null 2>&1; then ok=0; break; fi; done
  rm -rf "$d"; return $ok
}

# 内容包里每个文件的格式检查: 非注释行的列数必须对 (坏数据不能进入配置生成)
cloud_check_files() { # <目录>
  local d=$1 f
  for f in services.conf groups.conf rulesets.conf apps.conf SEQ; do [ -s "$d/$f" ] || { CLOUD_ERR="内容包缺少 $f"; return 1; }; done
  awk -F'|' '!/^[ \t]*(#|$)/ && NF != 8 { bad = 1 } END { exit bad }' "$d/services.conf" || { CLOUD_ERR="内容包里的 services.conf 格式不对"; return 1; }
  awk -F'|' '!/^[ \t]*(#|$)/ && NF != 2 { bad = 1 } END { exit bad }' "$d/groups.conf" || { CLOUD_ERR="内容包里的 groups.conf 格式不对"; return 1; }
  awk -F'|' '!/^[ \t]*(#|$)/ && NF != 8 { bad = 1 } END { exit bad }' "$d/rulesets.conf" || { CLOUD_ERR="内容包里的 rulesets.conf 格式不对"; return 1; }
  awk -F'|' '!/^[ \t]*(#|$)/ && NF != 3 { bad = 1 } END { exit bad }' "$d/apps.conf" || { CLOUD_ERR="内容包里的 apps.conf 格式不对"; return 1; }
  grep -Eq '^[0-9]+$' "$d/SEQ" || { CLOUD_ERR="内容包的版本序号不对"; return 1; }
  return 0
}

# cloud_content_install [force]  下载 + 验证 + 安装 (只换符号链接, 不重新生成配置)
#   0 = 已安装新内容 (CLOUD_CHANGED=1) 或已是最新 (CLOUD_CHANGED=0)   1 = 失败 (CLOUD_ERR 里有原因, 保留旧内容)   2 = 没有登录/没有云端会话
cloud_content_install() {
  local force=${1:-} T man sig seq url sha size minc code got stage cur
  CLOUD_CHANGED=0; CLOUD_ERR=''
  [ -n "$(session_token)" ] && [ -n "$(session_id)" ] || { CLOUD_ERR="还没有登录云端"; return 2; }
  T=$(mktemp -d); man="$T/manifest.json"; sig="$T/manifest.sig"
  code=$(session_call "$man" GET /v1/manifest.json)
  [ "$code" = 200 ] || { CLOUD_ERR="连不上云端内容服务 (HTTP $code)"; rm -rf "$T"; return 1; }
  code=$(session_call "$sig" GET /v1/manifest.sig)
  [ "$code" = 200 ] && cloud_verify "$man" "$sig" || { CLOUD_ERR="内容清单签名校验失败, 已忽略"; rm -rf "$T"; return 1; }
  local body; body=$(sed -n 's/.*"content":{\([^}]*\)}.*/\1/p' "$man" | head -1)
  seq=$(printf '%s' "$body" | sed -n 's/.*"seq":\([0-9]*\).*/\1/p'); url=$(printf '%s' "$body" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')
  sha=$(printf '%s' "$body" | sed -n 's/.*"sha256":"\([0-9a-f]*\)".*/\1/p'); size=$(printf '%s' "$body" | sed -n 's/.*"size":\([0-9]*\).*/\1/p')
  minc=$(printf '%s' "$body" | sed -n 's/.*"min_client":"\([0-9.]*\)".*/\1/p')
  { [ -n "$seq" ] && [ -n "$url" ] && [ ${#sha} -eq 64 ] && [ -n "$size" ]; } || { CLOUD_ERR="内容清单格式不对"; rm -rf "$T"; return 1; }
  case $url in /v1/content-[0-9]*.tar.gz) ;; *) CLOUD_ERR="内容清单里的下载地址不合法"; rm -rf "$T"; return 1 ;; esac
  [ -z "$minc" ] || ! version_gt "$minc" "$VERSION" || { CLOUD_ERR="这份内容需要 enana $minc 或更高版本, 请先更新 enana"; rm -rf "$T"; return 1; }
  cur=$(cloud_seq)
  if [ "$seq" -lt "$cur" ]; then CLOUD_ERR="云端内容序号 ($seq) 比本机已有的 ($cur) 旧, 已忽略 (防回滚)"; rm -rf "$T"; return 1; fi
  if [ "$seq" -eq "$cur" ] && [ -z "$force" ]; then rm -rf "$T"; cloud_state_set ''; return 0; fi
  code=$(session_call "$T/pkg.tgz" GET "$url")
  [ "$code" = 200 ] || { CLOUD_ERR="下载内容包失败 (HTTP $code)"; rm -rf "$T"; return 1; }
  got=$(wc -c < "$T/pkg.tgz" | tr -d ' '); [ "$got" = "$size" ] && [ "$size" -le 5242880 ] || { CLOUD_ERR="内容包大小不对"; rm -rf "$T"; return 1; }
  [ "$(shasum -a 256 "$T/pkg.tgz" | cut -d' ' -f1)" = "$sha" ] || { CLOUD_ERR="内容包校验和不对"; rm -rf "$T"; return 1; }
  # 解包前先检查文件名 (只允许白名单, 不能有绝对路径 / ..), 再解到临时目录
  tar -tzf "$T/pkg.tgz" 2>/dev/null | sed 's#^\./##' | grep -Ev '/$|^\.?$' | grep -Evq "$CLOUD_FILES_OK" && { CLOUD_ERR="内容包里有不允许的文件"; rm -rf "$T"; return 1; }
  stage="$T/stage"; mkdir -p "$stage"; tar -xzf "$T/pkg.tgz" -C "$stage" 2>/dev/null || { CLOUD_ERR="内容包解压失败"; rm -rf "$T"; return 1; }
  cloud_check_files "$stage" || { rm -rf "$T"; return 1; }
  [ "$(tr -d '[:space:]' < "$stage/SEQ")" = "$seq" ] || { CLOUD_ERR="内容包的序号与清单不一致"; rm -rf "$T"; return 1; }
  mkdir -p "$H/cloud"; chmod 700 "$H/cloud"
  rm -rf "$H/cloud/content-$seq"; mv "$stage" "$H/cloud/content-$seq" && ln -sfn "content-$seq" "$H/cloud/content" || { CLOUD_ERR="安装内容包失败"; rm -rf "$T"; return 1; }
  rm -rf "$T"; cloud_state_set ''; CLOUD_CHANGED=1
  # 只保留当前 + 上一份
  ls -1d "$H"/cloud/content-* 2>/dev/null | sort | awk '{ a[NR] = $0 } END { for (i = 1; i <= NR - 2; i++) print a[i] }' | while IFS= read -r d; do rm -rf "$d"; done
  return 0
}

# 事务里的变更函数: 安装内容 + 下载新启用的规则集 (失败时 op_txn 自动恢复到上一份内容)
txn_content() {
  cloud_content_install "${TXN_FORCE:-}"; local rc=$?
  if [ "$rc" != 0 ]; then TXN_ERR=$CLOUD_ERR; cloud_state_set "$CLOUD_ERR"; return 1; fi
  [ "$CLOUD_CHANGED" = 1 ] && { job_step 1 30 "下载规则集"; rules_update >/dev/null 2>&1 || true; apps_rerecommend; ovr_sync; }      # 新的应用推荐: 首次扫描时没拿到推荐的应用在这里补上
  return 0
}

cloud_status_json() { # GET /api/content 的主体
  local checked=0 err='' src=baseline
  [ -f "$H/cloud/state" ] && { checked=$(sed -n 's/^checked=//p' "$H/cloud/state" | head -1); err=$(sed -n 's/^error=//p' "$H/cloud/state" | head -1); }
  [ -s "$H/cloud/content/SEQ" ] && src=cloud
  printf '"source":"%s","seq":%s,"version":"%s","checked":%s,"error":"%s"' "$src" "$(cloud_seq)" "$(jesc "$(cloud_version)")" "${checked:-0}" "$(jesc "$(_t "$err")")"
}
