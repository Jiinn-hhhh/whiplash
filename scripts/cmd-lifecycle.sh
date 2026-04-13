# cmd-lifecycle.sh -- 라이프사이클 관리 함수 (reboot, refresh, shutdown, status, merge-worktree, monitor-check, execution-config)
#
# cmd.sh에서 source된다. 단독 실행하지 않는다.
# 의존: cmd-utils.sh, cmd-boot.sh, cmd-dispatch.sh (먼저 source 필요)

# ──────────────────────────────────────────────
# reboot 서브커맨드
# ──────────────────────────────────────────────

cmd_reboot() {
  local target="$1"
  local project="$2"
  validate_project_name "$project"
  local sess
  sess="$(session_name "$project")"

  # target에서 role과 backend 분리
  # "researcher-claude" → role=researcher, backend=claude, window=researcher-claude
  # "researcher-codex"  → role=researcher, backend=codex, window=researcher-codex
  # "researcher"        → role=researcher, backend=claude, window=researcher (solo 호환)
  local role backend window_name resolved_target
  resolved_target="$(resolve_reboot_or_refresh_target "$target" "$project")"
  role="${resolved_target%%|*}"
  resolved_target="${resolved_target#*|}"
  backend="${resolved_target%%|*}"
  window_name="${resolved_target#*|}"

  echo "=== ${window_name} 에이전트 리부팅 ==="

  if [ "$backend" = "claude" ] && ! guard_claude_recovery "reboot" "$project" "$sess" "$window_name"; then
    runtime_clear_reboot_lock_ts "$project" "$window_name" || true
    return 1
  fi

  # reboot lock 획득 (경합 방지)
  ensure_manager_runtime_layout "$project"
  if ! runtime_try_claim_reboot_lock "$project" "$window_name" 60; then
    local lock_ts lock_age
    lock_ts="$(runtime_get_reboot_lock_ts "$project" "$window_name" 2>/dev/null || true)"
    if [[ "${lock_ts:-}" =~ ^[0-9]+$ ]]; then
      lock_age=$(( $(date +%s) - lock_ts ))
      echo "Info: ${window_name} 리부팅 진행 중 (${lock_age}초 전 시작). 건너뜀." >&2
    else
      echo "Info: ${window_name} 리부팅 lock 획득 실패. 건너뜀." >&2
    fi
    return 0
  fi

  # tmux 세션 존재 확인
  if ! tmux has-session -t "$sess" 2>/dev/null; then
    echo "Error: tmux 세션 '$sess'가 없다. boot를 먼저 실행하라." >&2
    runtime_clear_reboot_lock_ts "$project" "$window_name"
    exit 1
  fi

  # 1. 기존 윈도우 있으면 kill
  if window_indices_by_name "$sess" "$window_name" | grep -q .; then
    echo "기존 ${window_name} 윈도우 종료 중..."
    kill_windows_by_name "$sess" "$window_name" "1"
  fi

  # 2. sessions.md에서 이전 행을 crashed로 표시
  mark_window_status "$project" "$window_name" "active" "crashed"

  # 3. 중단된 태스크 조회
  local pending_task
  pending_task="$(resume_pending_task_for_window "$project" "$role" "$window_name")" || pending_task=""

  # 4. backend에 따라 적절한 부팅 함수 호출
  boot_agent_with_backend "$role" "$project" "$window_name" "$backend" "" "$pending_task" || {
    echo "Error: ${window_name} 리부팅 실패." >&2
    runtime_clear_reboot_lock_ts "$project" "$window_name"
    exit 1
  }

  # reboot lock 해제
  runtime_clear_reboot_lock_ts "$project" "$window_name"

  python3 "$TOOLS_DIR/log.py" system "$project" orchestrator agent_reboot "$window_name" || true
  echo "=== ${window_name} 리부팅 완료 ==="
}

# ──────────────────────────────────────────────
# refresh 서브커맨드
# ──────────────────────────────────────────────

cmd_refresh() {
  local target="$1"
  local project="$2"
  validate_project_name "$project"
  local sess
  sess="$(session_name "$project")"
  local handoff_wait="${WHIPLASH_REFRESH_HANDOFF_WAIT_SECONDS:-120}"
  local skip_handoff_request="${WHIPLASH_REFRESH_SKIP_HANDOFF_REQUEST:-0}"

  # target에서 role과 backend 분리 (reboot과 동일한 파싱)
  local role backend window_name resolved_target
  resolved_target="$(resolve_reboot_or_refresh_target "$target" "$project")"
  role="${resolved_target%%|*}"
  resolved_target="${resolved_target#*|}"
  backend="${resolved_target%%|*}"
  window_name="${resolved_target#*|}"

  echo "=== ${window_name} 에이전트 리프레시 ==="

  # tmux 세션 존재 확인
  if ! tmux has-session -t "$sess" 2>/dev/null; then
    echo "Error: tmux 세션 '$sess'가 없다. boot를 먼저 실행하라." >&2
    exit 1
  fi

  # 윈도우 존재 확인
  if ! tmux list-windows -t "$sess" -F '#{window_name}' 2>/dev/null | grep -q "^${window_name}$"; then
    echo "Error: ${window_name} 윈도우가 없다." >&2
    exit 1
  fi

  if [ "$backend" = "claude" ] && ! guard_claude_recovery "refresh" "$project" "$sess" "$window_name"; then
    return 1
  fi

  # handoff 파일 경로는 role 기준 (backend별로 분리하지 않음)
  local handoff_file="$(project_dir "$project")/memory/${role}/handoff.md"

  # 1. 에이전트에게 handoff.md 작성 지시
  if [ "$skip_handoff_request" != "1" ]; then
    echo "handoff.md 작성 지시 전송..."
    tmux send-keys -t "${sess}:${window_name}" \
      "지금까지의 작업 맥락을 memory/${role}/handoff.md에 정리해라. 현재 진행 상황, 다음 할 일, 중요 결정사항을 포함해라." Enter
  fi
  python3 "$TOOLS_DIR/log.py" system "$project" orchestrator agent_refresh_start "$window_name" || true

  # 2. 최대 handoff_wait초 대기 (handoff.md 파일 생성 감시)
  local waited=0
  if [ "$handoff_wait" -gt 0 ] 2>/dev/null; then
    echo "handoff.md 생성 대기 (최대 ${handoff_wait}초)..."
    while [ "$waited" -lt "$handoff_wait" ]; do
      if [ -f "$handoff_file" ]; then
        echo "handoff.md 생성 확인 (${waited}초 경과)"
        break
      fi
      sleep 5
      waited=$((waited + 5))
    done
  fi

  if [ ! -f "$handoff_file" ] && [ "$handoff_wait" -gt 0 ] 2>/dev/null; then
    echo "Warning: ${handoff_wait}초 내에 handoff.md가 생성되지 않았다. 그래도 리프레시를 진행한다." >&2
  fi

  # 3. 기존 세션 종료
  echo "기존 ${window_name} 세션 종료 중..."
  tmux send-keys -t "${sess}:${window_name}" "/exit" Enter 2>/dev/null || true
  sleep 3
  tmux kill-window -t "${sess}:${window_name}" 2>/dev/null || true

  # 4. sessions.md에서 이전 행을 refreshed로 표시
  mark_window_status "$project" "$window_name" "active" "refreshed"

  # 5. active 태스크 조회 + 새 세션 부팅 (온보딩 + handoff.md 읽기 지시 추가)
  local pending_task=""
  pending_task="$(resume_pending_task_for_window "$project" "$role" "$window_name")" || pending_task=""
  local extra_msg=""
  if [ -f "$handoff_file" ]; then
    extra_msg="10. memory/${role}/handoff.md를 읽어라. 이전 세션에서 인수인계한 맥락이다."
  fi

  boot_agent_with_backend "$role" "$project" "$window_name" "$backend" "$extra_msg" "$pending_task" || {
    echo "Error: ${window_name} 리프레시 후 부팅 실패." >&2
    exit 1
  }

  python3 "$TOOLS_DIR/log.py" system "$project" orchestrator agent_refresh_end "$window_name" || true
  echo "=== ${window_name} 리프레시 완료 ==="
}

# ──────────────────────────────────────────────
# monitor-check 서브커맨드
# ──────────────────────────────────────────────

cmd_monitor_check() {
  local project="$1"
  validate_project_name "$project"
  ensure_manager_runtime_layout "$project"
  local now pid lock_pid active_pid hb_time
  now=$(date +%s)

  pid="$(runtime_get_manager_state "$project" "monitor_pid" "" 2>/dev/null || true)"
  lock_pid="$(runtime_get_manager_state "$project" "monitor_lock_pid" "" 2>/dev/null || true)"

  if [[ "${lock_pid:-}" =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" 2>/dev/null; then
    active_pid="$lock_pid"
  elif [[ "${pid:-}" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    active_pid="$pid"
  else
    active_pid=""
  fi

  # PID 파일 확인
  if [ -z "$pid" ] && [ -z "$active_pid" ]; then
    echo "[monitor-check] PID 파일 없음. monitor.sh 재시작 중..."
    restart_monitor "$project"
    return
  fi

  # PID가 숫자인지 확인
  if [ -n "$pid" ] && ! [[ "$pid" =~ ^[0-9]+$ ]]; then
    echo "[monitor-check] PID 파일에 잘못된 값: '$pid'. monitor.sh 재시작 중..." >&2
    restart_monitor "$project"
    return
  fi

  # 프로세스 생존 확인
  if [ -z "$active_pid" ]; then
    echo "[monitor-check] monitor.sh 프로세스 죽음 (PID: $pid). 재시작 중..."
    restart_monitor "$project"
    return
  fi

  # heartbeat 신선도 확인 (90초 이상이면 좀비)
  hb_time="$(runtime_get_manager_state "$project" "monitor_heartbeat" "" 2>/dev/null || true)"
  if [ -n "$hb_time" ]; then
    if ! [[ "$hb_time" =~ ^[0-9]+$ ]]; then
      echo "[monitor-check] heartbeat 파일에 잘못된 값. 프로세스 확인 필요."
        return
    fi
    local hb_age=$((now - hb_time))
    if [ "$hb_age" -gt 90 ]; then
      echo "[monitor-check] heartbeat ${hb_age}초 전 (좀비). 강제 종료 후 재시작..."
      python3 "$TOOLS_DIR/log.py" system "$project" orchestrator monitor_zombie monitor --detail heartbeat_age="${hb_age}s" || true
      if [[ "${lock_pid:-}" =~ ^[0-9]+$ ]]; then
        kill "$lock_pid" 2>/dev/null || true
      fi
      if [[ "${pid:-}" =~ ^[0-9]+$ ]] && [ "${pid:-}" != "${lock_pid:-}" ]; then
        kill "$pid" 2>/dev/null || true
      fi
      sleep 1
      restart_monitor "$project"
        return
    fi
    echo "[monitor-check] monitor.sh 정상 (PID: $active_pid, heartbeat: ${hb_age}초 전)"
  else
    echo "[monitor-check] heartbeat 파일 없음. 프로세스 확인 필요."
  fi
}

restart_monitor() {
  local project="$1"
  local log_dir="$(project_dir "$project")/logs"
  mkdir -p "$log_dir"
  nohup bash -c "
    while true; do
      bash \"$TOOLS_DIR/monitor.sh\" \"$project\"
      echo \"\$(date '+%Y-%m-%d %H:%M:%S') monitor.sh 종료 감지. 10초 후 재시작...\" >&2
      sleep 10
    done
  " >>"$log_dir/monitor-wrapper.log" 2>&1 &
  local new_pid=$!
  runtime_set_manager_state "$project" "monitor_pid" "$new_pid"
  python3 "$TOOLS_DIR/log.py" system "$project" orchestrator monitor_restart monitor --detail pid="$new_pid" || true
  echo "[monitor-check] monitor.sh 재시작 완료 (PID: $new_pid, 자동 재시작 wrapper)"
}

# ──────────────────────────────────────────────
# shutdown 서브커맨드
# ──────────────────────────────────────────────

cmd_shutdown() {
  local project="$1"
  validate_project_name "$project"
  local sess
  sess="$(session_name "$project")"

  echo "=== ${project} 프로젝트 종료 ==="
  python3 "$TOOLS_DIR/log.py" system "$project" orchestrator project_shutdown "$project" || true

  # 1. 각 에이전트 윈도우에 /exit 전송
  if tmux has-session -t "$sess" 2>/dev/null; then
    local windows
    windows=$(tmux list-windows -t "$sess" -F '#{window_index}:#{window_name}')
    while IFS=: read -r win_idx win_name; do
      [ -z "$win_idx" ] && continue
      echo "${win_name}에 /exit 전송"
      tmux send-keys -t "${sess}:${win_idx}" "/exit" Enter 2>/dev/null || true
    done <<< "$windows"

    # 2. 5초 대기
    echo "에이전트 종료 대기 (5초)..."
    sleep 5

    # 3. tmux 세션 종료
    tmux kill-session -t "$sess" 2>/dev/null || true
    echo "tmux 세션 '$sess' 종료됨"
  else
    echo "tmux 세션 '$sess'가 없다. 이미 종료된 듯."
  fi

  # 4. monitor.sh 프로세스 종료 (wrapper + 자식 + 좀비 방지)
  ensure_manager_runtime_layout "$project"
  local pid
  pid="$(runtime_get_manager_state "$project" "monitor_pid" "" 2>/dev/null || true)"
  if [[ "${pid:-}" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    # wrapper와 자식 monitor.sh 모두 종료
    pkill -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
    echo "monitor.sh 종료됨 (PID: $pid)"
  fi
  # 좀비 방지: 이 프로젝트의 monitor.sh 프로세스를 모두 kill
  # (이전 세션에서 대기 모드로 살아남은 프로세스 포함)
  pkill -f "monitor\\.sh[[:space:]]+${project}$" 2>/dev/null || true
  runtime_clear_manager_state "$project" "monitor_pid" || true
  runtime_clear_manager_state "$project" "monitor_heartbeat" || true
  runtime_clear_manager_state "$project" "monitor_nudge_ts" || true
  clear_project_stage "$project" || true
  runtime_release_manager_lock "$project" || true

  # 5. sessions.md 업데이트
  close_all_sessions "$project"

  # 6. persistent ralph worktree 정리
  remove_ralph_worktree "$project" "developer" || true
  remove_ralph_worktree "$project" "systems-engineer" || true

  # 7. 런타임 파일 정리 (reboot 카운터, heartbeat, reboot lock)
  rm -f "$(runtime_reboot_state_file "$project")"
  rm -f "$(runtime_idle_state_file "$project")"
  cleanup_manager_runtime_transients "$project"

  echo "=== 종료 완료 ==="
}

# ──────────────────────────────────────────────
# status 서브커맨드
# ──────────────────────────────────────────────

cmd_status() {
  local project="$1"
  validate_project_name "$project"
  local sess
  sess="$(session_name "$project")"
  local now
  now=$(date +%s)
  local stage
  stage="$(get_project_stage "$project")"

  echo "=== ${project} 프로젝트 상태 ==="
  echo "[stage] ${stage}"

  # tmux 세션 확인 (idle 시간 포함)
  if tmux has-session -t "$sess" 2>/dev/null; then
    echo "[tmux] 세션 활성"
    while IFS= read -r line; do
      local win_name win_activity idle_sec
      win_name=$(echo "$line" | cut -d'|' -f1)
      win_activity=$(echo "$line" | cut -d'|' -f2)
      if [ -n "$win_activity" ] && [ "$win_activity" != "0" ]; then
        idle_sec=$((now - win_activity))
        local idle_min=$((idle_sec / 60))
        local idle_rem=$((idle_sec % 60))
        echo "  ${win_name} (idle: ${idle_min}분 ${idle_rem}초)"
      else
        echo "  ${win_name} (idle: 알 수 없음)"
      fi
    done < <(tmux list-windows -t "$sess" -F '#{window_name}|#{window_activity}')
    print_agent_health_status "$project" "$sess"
  else
    echo "[tmux] 세션 없음"
  fi

  # monitor.sh 확인 (PID + heartbeat 신선도)
  ensure_manager_runtime_layout "$project"
  local pid lock_pid active_pid hb_time
  pid="$(runtime_get_manager_state "$project" "monitor_pid" "" 2>/dev/null || true)"
  lock_pid="$(runtime_get_manager_state "$project" "monitor_lock_pid" "" 2>/dev/null || true)"

  if [[ "${lock_pid:-}" =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" 2>/dev/null; then
    active_pid="$lock_pid"
  elif [[ "${pid:-}" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    active_pid="$pid"
  else
    active_pid=""
  fi

  if [ -n "$pid" ] && ! [[ "$pid" =~ ^[0-9]+$ ]]; then
    echo "[monitor] PID 상태값이 잘못됨: '$pid'"
  elif [ -n "$active_pid" ]; then
    hb_time="$(runtime_get_manager_state "$project" "monitor_heartbeat" "" 2>/dev/null || true)"
    if [ -n "$hb_time" ]; then
      if [[ "$hb_time" =~ ^[0-9]+$ ]]; then
        local hb_age=$((now - hb_time))
        if [ "$hb_age" -gt 90 ]; then
          echo "[monitor] 실행 중 (PID: $active_pid) -- WARNING: heartbeat ${hb_age}초 전 (좀비 가능성)"
        else
          echo "[monitor] 실행 중 (PID: $active_pid, heartbeat: ${hb_age}초 전)"
        fi
      else
        echo "[monitor] 실행 중 (PID: $active_pid, heartbeat 상태값이 잘못됨)"
      fi
    else
      echo "[monitor] 실행 중 (PID: $active_pid, heartbeat 없음)"
    fi
  elif [ -n "$pid" ]; then
    echo "[monitor] 프로세스 죽음 (PID: $pid)"
  else
    echo "[monitor] 미시작"
  fi

  # sessions.md 출력
  local sf
  sf="$(sessions_file "$project")"
  if [ -f "$sf" ]; then
    echo ""
    cat "$sf"
  fi

  if ! tmux has-session -t "$sess" 2>/dev/null; then
    echo ""
    print_agent_health_status "$project" "$sess"
  fi
}

# ──────────────────────────────────────────────
# merge-worktree 서브커맨드
# ──────────────────────────────────────────────

cmd_merge_worktree() {
  local role="$1"
  local winner="$2"   # "claude" | "codex"
  local project="$3"
  validate_project_name "$project"

  if [ "$winner" != "claude" ] && [ "$winner" != "codex" ]; then
    echo "Error: winner는 'claude' 또는 'codex'만 가능하다. 입력값: '$winner'" >&2
    exit 1
  fi

  local code_repo
  code_repo="$(get_code_repo "$project")"
  if [ -z "$code_repo" ] || [ ! -d "$code_repo" ]; then
    echo "Error: 프로젝트 폴더가 설정되지 않았거나 존재하지 않음." >&2
    exit 1
  fi

  local winner_branch="dual/${role}-${winner}"
  local wt_dir="${code_repo}/.worktrees"

  echo "=== merge-worktree: ${role} (winner: ${winner}) ==="

  # 1. winner 브랜치를 main에 merge
  local current_branch
  current_branch=$(git -C "$code_repo" rev-parse --abbrev-ref HEAD)

  # main 브랜치로 전환 (현재 브랜치가 main이 아닌 경우)
  if [ "$current_branch" != "main" ]; then
    git -C "$code_repo" checkout main || {
      echo "Error: main 브랜치 checkout 실패." >&2
      exit 1
    }
  fi

  git -C "$code_repo" merge "$winner_branch" -m "Merge dual/${role}-${winner} (dual mode consensus winner)" || {
    echo "Error: merge 실패. 충돌을 수동으로 해결하라." >&2
    exit 1
  }

  echo "merge 완료: ${winner_branch} → main"

  # 2. 양쪽 worktree + 브랜치 정리
  remove_worktrees "$project" "$role"

  python3 "$TOOLS_DIR/log.py" system "$project" orchestrator merge_worktree "$role" \
    --detail winner="$winner" branch="$winner_branch" || true
  echo "=== merge-worktree 완료 ==="
}

# ──────────────────────────────────────────────
# execution-config 서브커맨드
# ──────────────────────────────────────────────

cmd_execution_config() {
  local project="$1"
  shift
  # execution-config.sh에서 제공하는 함수들을 사용하여 설정 변경
  # 현재는 직접 execution_config_set_preset 등을 호출
  local scope=""
  if [ "${1:-}" = "--scope" ]; then
    scope="$2"
    shift 2
  fi

  if [ $# -eq 0 ]; then
    # 현재 설정 표시
    execution_config_show_json "$project"
    return 0
  fi

  local first_arg="$1"
  case "$first_arg" in
    default|dual|"claude only"|"codex only")
      execution_config_set_preset "$project" "$first_arg"
      echo "execution-config: preset → ${first_arg}"
      ;;
    *)
      # role override: "developer claude" 등
      local role_name="$1"
      local backend_or_model="${2:-}"
      if [ -n "$backend_or_model" ]; then
        case "$backend_or_model" in
          claude|codex)
            execution_config_set_role_backend "$project" "$role_name" "$backend_or_model"
            echo "execution-config: ${role_name} backend → ${backend_or_model}"
            ;;
          *)
            execution_config_set_role_model "$project" "$role_name" "claude" "$backend_or_model"
            echo "execution-config: ${role_name} model → ${backend_or_model}"
            ;;
        esac
      else
        execution_config_reset_role "$project" "$role_name"
        echo "execution-config: ${role_name} → reset to preset default"
      fi
      ;;
  esac
}
