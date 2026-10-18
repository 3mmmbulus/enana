# 云端内容: 由 enana 云端下发的精选数据 (服务目录 / 分组 / 规则库 / 应用推荐 / 英文译文 / 服务器部署脚本)。依赖 common.sh auth.sh session.sh config.sh fetch.sh ops.sh。
#
# 为什么: 公开仓库里只放「瘦客户端」+ 最小基线; 持续维护的精选内容留在云端下发 (见 docs/ARCHITECTURE.md)。
# 不需要账号: 有云端会话 (登录了) 就带上会话 (session_call, 和以前一样); 没有 (没登录 / 离线登录) 就匿名下载同样的路径 —— 不带 Authorization / X-Enana-Session。
# 两种方式的校验一模一样: 内容可信靠的是签名 (以及防回滚 / 校验和 / 文件名白名单), 不是账号。
# 流程: 拉取 manifest (签名) → 验签 (内置公钥 data/cloud-pub.pem, ECDSA P-256 / SHA-256) → 防回滚 (seq 不能变小) → 下载内容包 →
#       校验 sha256 / 大小 / 文件名白名单 / 每个文件的格式 → 原子替换 $H/cloud/content (符号链接) → 重新生成配置 (失败自动回滚)。
# 验签失败 / 格式不对 / 网络不通: 保留旧内容 (或基线), 不影响代理; 内容只在本机缓存, 没有任何用户数据上传。
# 匿名下载被云端拒绝 (401 / 403: 云端还要求登录): 保留本机现有的内容, CLOUD_ERR 是一句平和的说明 (返回 2), 状态里记下 anon_refused;
# 每日维护据此先用一个很小的匿名请求问一下 (cloud_anon_refused), 还被拒绝就不开事务 —— 操作记录里不会每天多一条错误, 云端开放之后自动恢复。
#
#   $H/cloud/content -> content-<seq>/   当前生效的内容 (services.conf groups.conf rulesets.conf apps.conf SEQ VERSION i18n/en-data.tsv, 以及 vps/ 下的服务器部署脚本)
#   $H/cloud/state                       checked=<时间> error=<上次错误> [anon_refused=<匿名下载最近一次被拒绝的时间>]

CLOUD_PUBKEY=${ENANA_CLOUD_PUBKEY:-$DATA/cloud-pub.pem}
CLOUD_FILES_OK='^(services\.conf|groups\.conf|rulesets\.conf|apps\.conf|SEQ|VERSION|i18n/[a-z]{2}-data\.tsv|vps/(lib|probe|provision|redetect)\.sh)$'
CLOUD_ANON_MSG='云端内容暂时需要登录 enana 账号才能下载, 已保留本机现有的内容'      # 匿名下载被云端拒绝时的说明 (不是故障: 内容和代理都照常)
CLOUD_ANON=0                                                                   # 这一次下载是不是匿名的 (没有云端会话): cloud_content_install 设置, cloud_get 读取

cloud_seq() { local s=0; [ -f "$H/cloud/content/SEQ" ] && IFS= read -r s < "$H/cloud/content/SEQ"; printf '%s' "${s:-0}"; }
cloud_version() { local s=''; [ -f "$H/cloud/content/VERSION" ] && IFS= read -r s < "$H/cloud/content/VERSION"; printf '%s' "${s:-}"; }
cloud_state_set() { # <错误 (空 = 成功)> [anon: 这次是匿名下载被云端拒绝, 记下时间 (每日维护据此先问一下再开事务)]
  mkdir -p "$H/cloud"
  { printf 'checked=%s\nerror=%s\n' "$(now)" "$1"; [ "${2:-}" != anon ] || printf 'anon_refused=%s\n' "$(now)"; } > "$H/cloud/state"
}
cloud_has_session() { [ -n "$(session_token)" ] && [ -n "$(session_id)" ]; }
cloud_get() { # <输出文件> <路径>  -> HTTP 状态码 (000 = 没连上): 登录了带会话 (session_call), 匿名时只带 Content-Type / Accept (_cloud_req, 没有任何凭据)
  if [ "${CLOUD_ANON:-0}" = 1 ]; then _cloud_req GET "$2" '' "$1"; else session_call "$1" GET "$2"; fi
}
cloud_refused() { case $1 in 401|403) return 0 ;; esac; return 1; }          # 云端要求登录 (旧的云端: /v1/ 只对有会话的请求开放)
_cloud_anon_stop() { [ "${CLOUD_ANON:-0}" = 1 ] && cloud_refused "$1" && CLOUD_ERR=$CLOUD_ANON_MSG; }   # <状态码>  匿名下载被要求登录: 设置 CLOUD_ERR, 返回 0 (调用方随即返回 2)

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

# cloud_content_install [force]  下载 + 验证 + 安装 (只换符号链接, 不重新生成配置)。有云端会话就带会话下载, 没有就匿名下载 (CLOUD_ANON=1), 校验完全相同
#   0 = 已安装新内容 (CLOUD_CHANGED=1) 或已是最新 (CLOUD_CHANGED=0)   1 = 失败 (CLOUD_ERR 里有原因, 保留旧内容)
#   2 = 匿名下载被云端拒绝 (云端还要求登录; 保留现有内容, CLOUD_ERR 是平和的说明, 不算云端故障)
cloud_content_install() {
  local force=${1:-} T man sig seq url sha size minc code got stage cur
  CLOUD_CHANGED=0; CLOUD_ERR=''; CLOUD_ANON=0
  cloud_has_session || CLOUD_ANON=1                     # 没登录 (或离线登录, 没有云端会话): 匿名下载同样的路径
  T=$(mktemp -d); man="$T/manifest.json"; sig="$T/manifest.sig"
  code=$(cloud_get "$man" /v1/manifest.json)
  _cloud_anon_stop "$code" && { rm -rf "$T"; return 2; }
  [ "$code" = 200 ] || { CLOUD_ERR="连不上云端内容服务 (HTTP $code)"; rm -rf "$T"; return 1; }
  code=$(cloud_get "$sig" /v1/manifest.sig)
  _cloud_anon_stop "$code" && { rm -rf "$T"; return 2; }
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
  code=$(cloud_get "$T/pkg.tgz" "$url")
  _cloud_anon_stop "$code" && { rm -rf "$T"; return 2; }
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
  if [ "$rc" != 0 ]; then TXN_ERR=$CLOUD_ERR; if [ "$rc" = 2 ]; then cloud_state_set "$CLOUD_ERR" anon; else cloud_state_set "$CLOUD_ERR"; fi; return 1; fi
  [ "$CLOUD_CHANGED" = 1 ] && { job_step 1 30 "下载规则集"; rules_update >/dev/null 2>&1 || true; apps_rerecommend; ovr_sync; }      # 新的应用推荐: 首次扫描时没拿到推荐的应用在这里补上
  return 0
}

# 每日维护 (没登录时) 开事务之前问一下: 上一次匿名下载被云端拒绝过 (状态里有 anon_refused) → 用一个很小的匿名请求 (清单) 再试。
#   0 = 还是被拒绝: 这次不开事务, 只刷新状态 (仪表盘能看到原因), 不写操作记录    1 = 没被拒绝过 / 已经开放 / 连不上 / 有云端会话: 照常开事务, 结果照常记
cloud_anon_refused() {
  local code out
  grep -q '^anon_refused=[0-9]' "$H/cloud/state" 2>/dev/null || return 1
  cloud_has_session && return 1
  out=$(mktemp); code=$(CLOUD_MAXTIME=10 _cloud_req GET /v1/manifest.json '' "$out"); rm -f "$out"
  cloud_refused "$code" || return 1
  cloud_state_set "$CLOUD_ANON_MSG" anon; return 0
}

# 本机还没有任何云端内容 (全新安装, 不登录也一样) 时, 仪表盘拿令牌 (POST /api/auth/local) 那一刻在后台补一次下载: 不用等到凌晨的每日维护,
# 一键部署要的脚本马上就有。cloud_first_mark 记下这次尝试的时间, 6 小时之内 (几个标签页同时打开、下载失败、匿名被拒绝) 不再重复。0 = 该试了
cloud_first_due() {
  local t
  [ -s "$H/cloud/content/SEQ" ] && return 1
  [ -s "$H/cloud/.first-try" ] && IFS= read -r t < "$H/cloud/.first-try"
  case ${t:-} in ''|*[!0-9]*) return 0 ;; esac
  [ $(( $(now) - t )) -ge 21600 ] || [ "$t" -gt "$(now)" ]
}
cloud_first_mark() { mkdir -p "$H/cloud" && now > "$H/cloud/.first-try"; }

cloud_status_json() { # GET /api/content 的主体
  local checked=0 err='' src=baseline
  [ -f "$H/cloud/state" ] && { checked=$(sed -n 's/^checked=//p' "$H/cloud/state" | head -1); err=$(sed -n 's/^error=//p' "$H/cloud/state" | head -1); }
  [ -s "$H/cloud/content/SEQ" ] && src=cloud
  printf '"source":"%s","seq":%s,"version":"%s","checked":%s,"error":"%s"' "$src" "$(cloud_seq)" "$(jesc "$(cloud_version)")" "${checked:-0}" "$(jesc "$(_t "$err")")"
}
