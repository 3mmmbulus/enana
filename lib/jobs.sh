# 后台任务与进度: 仪表盘用 GET /api/job?id= 轮询 $H/jobs/<id>.json 来画进度条。
# 任务由主脚本的 `_job <name> <id>` 子命令在后台运行 (见 install.sh), 这里只负责状态文件。

# 排队序号: 改配置的任务按「请求到达的顺序」依次执行 (否则连续点两下时, 后启动的进程可能先拿到锁, 最终状态与用户的操作顺序相反)
job_ticket() { # 打印下一个序号 (全局单调递增; 用目录锁保护计数文件)
  local f="$H/.ticket" n=0 i=0
  while ! mkdir "$H/.ticket.lock" 2>/dev/null; do i=$((i+1)); [ "$i" -gt 100 ] && break; sleep 0.05; done
  [ -f "$f" ] && IFS= read -r n < "$f"; n=$((${n:-0}+1)); printf '%s\n' "$n" > "$f"
  rmdir "$H/.ticket.lock" 2>/dev/null || true
  printf '%s\n' "$n"
}

job_new() { # job_new 名称 "步骤1|步骤2|…"  -> 打印 id
  local name=$1 steps=$2 id
  mkdir -p "$H/jobs"
  find "$H/jobs" -type f -mtime +1 -exec rm -f {} + 2>/dev/null || true
  id="$name-$(now)-$RANDOM"
  printf '%s' "$steps" > "$H/jobs/$id.steps"
  case $name in net-info|speedtest|self-update|core-upgrade|maintain|dns-bench|sync-push|sync-login|vps-probe|vps-provision|vps-redetect|sysproxy) ;; *) job_ticket > "$H/jobs/$id.ticket" ;; esac   # 长时间的只读/独立任务不排队
  JOB_NAME=$name; job_write "$id" "$name" running 0 0 "准备中" '{}'
  printf '%s\n' "$id"
}

job_write() { # id name state(running|done|error) 当前步骤序号 pct msg result_json
  local id=$1 name=$2 state=$3 idx=$4 pct=$5 msg=$6 res=${7:-'{}'} f="$H/jobs/$1.json" label i=0 st arr=''
  local steps; steps=$(cat "$H/jobs/$id.steps" 2>/dev/null || true)
  local oldifs=$IFS; IFS='|'
  for label in $steps; do
    if [ "$state" = done ]; then st=done
    elif [ "$i" -lt "$idx" ]; then st=done
    elif [ "$i" -eq "$idx" ]; then [ "$state" = error ] && st=error || st=run
    else st=todo; fi
    arr="$arr${arr:+,}{\"label\":\"$(jesc "$(_t "$label")")\",\"state\":\"$st\"}"
    i=$((i+1))
  done
  IFS=$oldifs
  msg=$(jesc "$(_t "$msg")")
  printf '{"ok":true,"id":"%s","name":"%s","state":"%s","pct":%s,"msg":"%s","steps":[%s],"result":%s}\n' \
    "$id" "$name" "$state" "$pct" "$msg" "$arr" "$res" > "$f.tmp" && mv "$f.tmp" "$f"
}

# 在任务进程里使用 (环境变量 JOB_ID/JOB_NAME 由 _job 设置); 非任务模式下是空操作
job_step() { [ -n "${JOB_ID:-}" ] || return 0; job_write "$JOB_ID" "$JOB_NAME" running "$1" "$2" "$3" '{}'; }
job_ok()   { [ -n "${JOB_ID:-}" ] || return 0; local r=${2:-}; [ -n "$r" ] || r='{}'; job_write "$JOB_ID" "$JOB_NAME" done 99 100 "${1:-完成}" "$r"; }
job_fail() { [ -n "${JOB_ID:-}" ] || return 0; job_write "$JOB_ID" "$JOB_NAME" error "${2:-0}" 100 "$1" '{}'; }

job_get() { # id -> JSON (找不到时返回错误 JSON)
  local id=$1
  case $id in *[!A-Za-z0-9_-]*|'') printf '{"ok":false,"code":"E_INVALID","error":"%s"}\n' "$(_t "任务编号无效")"; return ;; esac
  if [ -f "$H/jobs/$id.json" ]; then cat "$H/jobs/$id.json"; else printf '{"ok":false,"code":"E_NOT_FOUND","error":"%s"}\n' "$(_t "找不到该任务")"; fi
}

job_launch() { # job_launch 名称 id [参数…]  在后台启动 `<主脚本> _job 名称 id 参数…`
  local name=$1 id=$2; shift 2
  if [ ! -x "$H/enana" ]; then
    job_write "$id" "$name" error 0 100 "后台任务启动失败: enana 没有执行权限, 请重新安装" '{"code":"E_JOB_LAUNCH"}'
    rm -f "$H/jobs/$id.cred"
    return 1
  fi
  ( ENANA_LANG="${I18N_LANG:-${LANG_UI:-}}" OP_WHO="${OP_WHO:-}" nohup "$H/enana" _job "$name" "$id" "$@" >>"$H/api.log" 2>&1 & ) >/dev/null 2>&1
}
job_spawn() { # job_spawn 名称 "步骤…" [参数…]  创建并启动, 打印 id
  local name=$1 steps=$2 id; shift 2
  id=$(job_new "$name" "$steps")
  job_launch "$name" "$id" "$@"
  printf '%s\n' "$id"
}
