#!/bin/bash
# monitor.sh -- 크래시 복구 + 행 감지 데몬
#
# 헬스 체크(크래시/idle/heartbeat): 30초 주기 포그라운드 루프.
# 에이전트 크래시 감지 시 자동 reboot (최대 3회).
# 10분 비활성 에이전트 감지 시 Manager에게 알림.
#
# Usage:
#   nohup bash monitor.sh {project} >/dev/null 2>&1 &
#
# 종료:
#   cmd.sh shutdown이 PID를 kill하거나, 직접 kill.

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: monitor.sh {project}" >&2
  exit 1
fi

PROJECT="$1"
# project 이름 검증 (경로 트래버설 방지)
if [[ "$PROJECT" == */* ]] || [[ "$PROJECT" == *..* ]] || [ -z "$PROJECT" ]; then
  echo "Error: 잘못된 project 이름: $PROJECT" >&2
  exit 1
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOLS_DIR="$SCRIPT_DIR"
SESSION="whiplash-${PROJECT}"
MONITOR_ONCE="${WHIPLASH_MONITOR_ONCE:-0}"
# shellcheck source=/dev/null
source "$TOOLS_DIR/tmux-env.sh"
# shellcheck source=/dev/null
source "$TOOLS_DIR/tmux-submit.sh"
# shellcheck source=/dev/null
source "$TOOLS_DIR/runtime-paths.sh"
# shellcheck source=/dev/null
source "$TOOLS_DIR/agent-health.sh"
# shellcheck source=/dev/null
source "$TOOLS_DIR/assignment-state.sh"
# shellcheck source=/dev/null
source "$TOOLS_DIR/message-queue.sh"
# shellcheck source=/dev/null
source "$TOOLS_DIR/notify-format.sh"
# shellcheck source=/dev/null
source "$TOOLS_DIR/execution-config.sh"
whiplash_activate_tmux_project "$PROJECT"
HEALTH_CHECK_INTERVAL=30
MAX_REBOOT=3
HUNG_THRESHOLD=600  # 10분 (초)
QUEUE_TTL=86400  # 24시간
ensure_manager_runtime_layout "$PROJECT"
SESSION_ABSENT_COUNT=0
REHYDRATION_GRACE_SECONDS="${WHIPLASH_REHYDRATION_GRACE_SECONDS:-180}"
REBOOTED_THIS_CYCLE=""  # H-03: check_agent_windows에서 reboot한 윈도우 추적

# ──────────────────────────────────────────────
# PID lock — 동일 프로젝트에 대한 중복 monitor 방지
# ──────────────────────────────────────────────
if [ "$MONITOR_ONCE" != "1" ]; then
  if ! runtime_claim_manager_lock "$PROJECT" "$$"; then
    OLD_PID="$(runtime_get_manager_state "$PROJECT" "monitor_lock_pid" "" 2>/dev/null || true)"
    echo "Error: monitor.sh가 이미 실행 중 (PID: ${OLD_PID:-unknown}). 중복 실행 방지." >&2
    exit 1
  fi
  cleanup_monitor() {
    runtime_release_manager_lock "$PROJECT" "$$"
  }
  trap cleanup_monitor EXIT INT TERM HUP
fi

# ──────────────────────────────────────────────
# 크래시 알림 헬퍼
# ──────────────────────────────────────────────

send_crash_alert() {
  local role="$1" message="$2"
  if [ "$role" = "manager" ]; then
    python3 "$TOOLS_DIR/log.py" system "$PROJECT" monitor manager_crash_alert "$role" --detail message="$message" || true
  else
    bash "$TOOLS_DIR/message.sh" "$PROJECT" monitor manager \
      reboot_notice urgent "${role} 크래시" "$message" || \
      python3 "$TOOLS_DIR/log.py" system "$PROJECT" monitor notify_delivery_fail "$role" || true
  fi
}

# ──────────────────────────────────────────────
# sessions.md에서 active 윈도우 이름 파싱
# ──────────────────────────────────────────────

get_active_roles() {
  local sessions_file="$REPO_ROOT/projects/$PROJECT/memory/manager/sessions.md"
  if [ ! -f "$sessions_file" ]; then
    return 0
  fi
  # || true: active 행이 없을 때 set -e에서 exit 방지
  grep '| active |' "$sessions_file" 2>/dev/null \
    | awk -F'|' '{print $5}' \
    | sed 's/.*://' \
    | sed 's/^ *//;s/ *$//' \
    | grep -v '^$' \
    || true
}

get_active_session_entries() {
  local sessions_file="$REPO_ROOT/projects/$PROJECT/memory/manager/sessions.md"
  if [ ! -f "$sessions_file" ]; then
    return 0
  fi

  awk -F'|' '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    /\| active \|/ {
      role = trim($2)
      backend = trim($3)
      session_id = trim($4)
      tmux_target = trim($5)
      status = trim($6)
      if (status != "active") {
        next
      }
      count = split(tmux_target, parts, ":")
      win_name = parts[count]
      if (win_name != "") {
        print win_name "|" backend "|" session_id "|" role
      }
    }
  ' "$sessions_file"
}

window_indices_by_name() {
  local win_name="$1"
  tmux list-windows -t "$SESSION" -F '#I|#{window_name}' 2>/dev/null \
    | awk -F'|' -v target="$win_name" '$2 == target { print $1 }'
}

# ──────────────────────────────────────────────
# reboot 카운터 관리
# ──────────────────────────────────────────────

get_reboot_count() {
  local role="$1"
  local val
  val="$(runtime_get_reboot_count "$PROJECT" "$role" 2>/dev/null || echo "0")"
  if [[ "$val" =~ ^[0-9]+$ ]]; then
    echo "$val"
  else
    echo "0"
  fi
}

increment_reboot_count() {
  local role="$1"
  runtime_increment_reboot_count "$PROJECT" "$role"
}

reset_reboot_count() {
  local role="$1"
  runtime_reset_reboot_count "$PROJECT" "$role"
}

get_window_backend() {
  local win_name="$1"
  case "$win_name" in
    *-codex|*-codex-*)
      echo "codex"
      return
      ;;
    *-claude|*-claude-*)
      echo "claude"
      return
      ;;
  esac

  local sessions_file="$REPO_ROOT/projects/$PROJECT/memory/manager/sessions.md"
  if [ -f "$sessions_file" ]; then
    local backend
    backend=$(
      awk -F'|' -v target="${SESSION}:${win_name}" '
        function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
        trim($5) == target && trim($6) == "active" { backend = trim($3) }
        END { print backend }
      ' "$sessions_file"
    )
    if [ -n "$backend" ]; then
      echo "$backend"
      return
    fi
  fi

  case "$win_name" in
    onboarding|manager|discussion|developer|researcher|systems-engineer|monitoring)
      local backend
      backend="$(execution_config_role_backend "$PROJECT" "$win_name" 2>/dev/null || true)"
      if [ "$backend" = "claude" ] || [ "$backend" = "codex" ]; then
        echo "$backend"
        return
      fi
      ;;
  esac

  echo "claude"
}

heuristic_agent_role() {
  local win_name="$1"
  printf '%s\n' "$win_name" | sed -E 's/-(claude|codex)(-.+)?$//'
}

resolve_agent_role() {
  local win_name="$1"
  local sessions_file="$REPO_ROOT/projects/$PROJECT/memory/manager/sessions.md"
  if [ -f "$sessions_file" ]; then
    local role
    role=$(
      awk -F'|' -v target="${SESSION}:${win_name}" '
        function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
        trim($5) == target && trim($6) == "active" { role = trim($2) }
        END { print role }
      ' "$sessions_file"
    )
    if [ -n "$role" ]; then
      echo "$role"
      return
    fi
  fi

  heuristic_agent_role "$win_name"
}

# build_notification은 notify-format.sh에서 제공 (source는 파일 상단에서)

mark_active_session_rows_stale() {
  local sessions_file
  sessions_file="$REPO_ROOT/projects/$PROJECT/memory/manager/sessions.md"
  [ -f "$sessions_file" ] || return 0
  grep -q '| active |' "$sessions_file" 2>/dev/null || return 0

  awk '
    BEGIN { FS = OFS = "|" }
    function trim(s) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
      return s
    }
    NR <= 2 { print; next }
    {
      if (trim($6) == "active") {
        $6 = " stale "
      }
      print
    }
  ' "$sessions_file" > "${sessions_file}.tmp" && mv "${sessions_file}.tmp" "$sessions_file"
}

maybe_refresh_target() {
  local target="$1"
  if [ "$target" = "manager" ] || [ "$target" = "user" ]; then
    return 1
  fi

  local now last_refresh
  now=$(date +%s)
  last_refresh="$(runtime_get_message_refresh_ts "$PROJECT" "$target" "" 2>/dev/null || true)"
  if [[ "${last_refresh:-}" =~ ^[0-9]+$ ]] && [ $((now - last_refresh)) -lt 60 ]; then
    return 1
  fi

  runtime_set_message_refresh_ts "$PROJECT" "$target" "$now" || true
  WHIPLASH_REFRESH_HANDOFF_WAIT_SECONDS=0 \
  WHIPLASH_REFRESH_SKIP_HANDOFF_REQUEST=1 \
  bash "$TOOLS_DIR/cmd.sh" refresh "$target" "$PROJECT" >/dev/null 2>&1 || return 1
  sleep 5
}

submit_notification() {
  local target="$1"
  local notification="$2"
  local tmux_target="${SESSION}:${target}"
  local attempt backend delivery_state

  for attempt in 1 2; do
    if tmux_submit_pasted_payload "$tmux_target" "$notification" "drain"; then
      runtime_clear_message_refresh_ts "$PROJECT" "$target" || true
      return 0
    fi
    sleep 1
  done

  backend="$(get_window_backend "$target")"
  delivery_state="$(agent_delivery_state "$PROJECT" "$SESSION" "$target" "$backend")"
  if [ "${delivery_state%%|*}" = "healthy" ] && maybe_refresh_target "$target"; then
    delivery_state="$(agent_delivery_state "$PROJECT" "$SESSION" "$target" "$backend")"
    if [ "${delivery_state%%|*}" != "healthy" ]; then
      return 1
    fi
    if tmux_submit_pasted_payload "$tmux_target" "$notification" "drain-refresh"; then
      runtime_clear_message_refresh_ts "$PROJECT" "$target" || true
      return 0
    fi
  fi

  return 1
}

is_agent_alive() {
  local win_name="$1"
  local backend
  backend="$(get_window_backend "$win_name")"
  agent_window_has_live_backend "$SESSION" "$win_name" "$backend"
}

session_epoch_marker() {
  tmux display-message -p -t "$SESSION" '#{session_name}|#{session_created}' 2>/dev/null || true
}

begin_rehydration_grace() {
  local reason="$1"
  local epoch="$2"
  local now_ts grace_until existing_until

  now_ts=$(date +%s)
  grace_until=$((now_ts + REHYDRATION_GRACE_SECONDS))
  existing_until="$(runtime_get_manager_state "$PROJECT" "rehydration_grace_until" "" 2>/dev/null || true)"
  if [[ "${existing_until:-}" =~ ^[0-9]+$ ]] && [ "$existing_until" -gt "$grace_until" ]; then
    grace_until="$existing_until"
  fi

  runtime_set_manager_state "$PROJECT" "rehydration_grace_until" "$grace_until"
  [ -n "$epoch" ] && runtime_set_manager_state "$PROJECT" "session_recovery_epoch" "$epoch"
  [ -n "$epoch" ] && runtime_set_manager_state "$PROJECT" "session_epoch" "$epoch"
  python3 "$TOOLS_DIR/log.py" system "$PROJECT" monitor session_rehydration_grace "$SESSION" \
    --detail reason="$reason" epoch="${epoch:-unknown}" until="$grace_until" || true
}

rehydration_grace_active() {
  local grace_until now_ts
  grace_until="$(runtime_get_manager_state "$PROJECT" "rehydration_grace_until" "" 2>/dev/null || true)"
  if ! [[ "${grace_until:-}" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  now_ts=$(date +%s)
  if [ "$now_ts" -ge "$grace_until" ]; then
    local booting_ts
    booting_ts="$(runtime_get_manager_state "$PROJECT" "project_booting" "" 2>/dev/null || true)"
    # project_booting 설정 후 5분 이내면 grace 연장 (부팅 중 보호)
    # 5분 초과면 stale로 간주하고 정리
    if [[ "${booting_ts:-}" =~ ^[0-9]+$ ]] && [ $((now_ts - booting_ts)) -lt 300 ]; then
      return 0
    elif [ -n "$booting_ts" ]; then
      runtime_clear_manager_state "$PROJECT" "project_booting" || true
    fi
    runtime_clear_manager_state "$PROJECT" "rehydration_grace_until" || true
    return 1
  fi

  return 0
}

handle_session_epoch_transition() {
  local current_epoch="$1"
  local previous_epoch

  [ -n "$current_epoch" ] || return 0
  previous_epoch="$(runtime_get_manager_state "$PROJECT" "session_epoch" "" 2>/dev/null || true)"
  if [ -z "$previous_epoch" ]; then
    runtime_set_manager_state "$PROJECT" "session_epoch" "$current_epoch"
    return 0
  fi

  if [[ "$previous_epoch" == \$* ]] && [[ "$current_epoch" != \$* ]]; then
    runtime_set_manager_state "$PROJECT" "session_epoch" "$current_epoch"
    python3 "$TOOLS_DIR/log.py" system "$PROJECT" monitor session_epoch_format_migrated "$SESSION" \
      --detail previous="$previous_epoch" current="$current_epoch" || true
    return 0
  fi

  if [ "$previous_epoch" != "$current_epoch" ]; then
    python3 "$TOOLS_DIR/log.py" system "$PROJECT" monitor session_epoch_changed "$SESSION" \
      --detail previous="$previous_epoch" current="$current_epoch" || true
    mark_active_session_rows_stale
    begin_rehydration_grace "session-epoch-changed" "$current_epoch"
  fi
}

plan_mode_state_key() {
  printf 'plan_mode_%s\n' "$1"
}

has_plan_mode_state() {
  local win_name="$1"
  [ -n "$(runtime_get_manager_state "$PROJECT" "$(plan_mode_state_key "$win_name")" "" 2>/dev/null || true)" ]
}

pane_is_in_plan_mode() {
  local win_name="$1"
  local tmux_target="${SESSION}:${win_name}"
  local pane_dump
  pane_dump="$(tmux capture-pane -pJ -t "$tmux_target" -S -40 2>/dev/null \
    | sed '/^[[:space:]]*$/d' \
    | tail -n 8 || true)"
  [ -n "$pane_dump" ] || return 1
  printf '%s\n' "$pane_dump" | grep -Eiq 'plan mode on|entered plan mode|plan mode 진입'
}

check_claude_plan_mode() {
  if ! session_exists; then
    return
  fi

  while IFS='|' read -r win_name backend session_id role; do
    [ -n "$win_name" ] || continue
    if [ "$win_name" = "manager" ] || [ "$win_name" = "dashboard" ]; then
      continue
    fi

    local state_key
    state_key="$(plan_mode_state_key "$win_name")"

    if [ "$backend" != "claude" ] || ! is_agent_alive "$win_name"; then
      if has_plan_mode_state "$win_name"; then
        runtime_clear_manager_state "$PROJECT" "$state_key" || true
      fi
      continue
    fi

    if pane_is_in_plan_mode "$win_name"; then
      if ! has_plan_mode_state "$win_name"; then
        runtime_set_manager_state "$PROJECT" "$state_key" "$(date +%s)" || true
        python3 "$TOOLS_DIR/log.py" system "$PROJECT" monitor plan_mode_detected "$win_name" \
          --detail backend="$backend" role="$role" session="$session_id" || true
        bash "$TOOLS_DIR/message.sh" "$PROJECT" monitor manager \
          need_input normal "${win_name} plan mode 판단 필요" \
          "${SESSION}:${win_name} pane 최근 출력과 현재 태스크 맥락을 확인해 승인 대기인지 단순 설계 단계인지 판단하고, 필요 시 해당 에이전트에 다음 행동을 지시해라." || true
      fi
    else
      if has_plan_mode_state "$win_name"; then
        runtime_clear_manager_state "$PROJECT" "$state_key" || true
        python3 "$TOOLS_DIR/log.py" system "$PROJECT" monitor plan_mode_cleared "$win_name" \
          --detail backend="$backend" role="$role" session="$session_id" || true
      fi
    fi
  done < <(get_active_session_entries)
}

check_claude_auth_blocked() {
  if ! session_exists; then
    return
  fi

  while IFS='|' read -r win_name backend session_id role; do
    [ -n "$win_name" ] || continue
    if [ "$win_name" = "manager" ] || [ "$win_name" = "dashboard" ]; then
      continue
    fi

    local previous_state previous_alert classification current_state detail
    previous_state="$(runtime_get_agent_health_state "$PROJECT" "$win_name" "" 2>/dev/null || true)"
    previous_alert="$(runtime_get_agent_health_alert_ts "$PROJECT" "$win_name" "" 2>/dev/null || true)"
    classification="$(agent_classify_window_health "$PROJECT" "$SESSION" "$win_name" "$backend")"
    current_state="${classification%%|*}"
    detail="${classification#*|}"

    if [ "$current_state" = "AUTH_BLOCKED" ]; then
      if [ "$previous_state" != "AUTH_BLOCKED" ]; then
        python3 "$TOOLS_DIR/log.py" system "$PROJECT" monitor auth_blocked_detected "$win_name" \
          --detail backend="$backend" role="$role" session="$session_id" reason="${detail:-pane-login-required}" || true
      fi

      # 자동 세션 재시작 1회 시도 (별도 플래그로 재시도 방지)
      # env var는 cmd.sh 프로세스에만 적용됨 (command-scoped, export 아님)
      local restart_flag="auth_restart_attempted_${win_name}"
      local already_attempted
      already_attempted="$(runtime_get_manager_state "$PROJECT" "$restart_flag" "" 2>/dev/null || true)"
      if [ -z "$already_attempted" ]; then
        runtime_set_manager_state "$PROJECT" "$restart_flag" "$(date +%s)" || true
        python3 "$TOOLS_DIR/log.py" system "$PROJECT" monitor auth_restart_attempt "$win_name" \
          --detail backend="$backend" role="$role" || true
        if WHIPLASH_AUTH_RESTART_BYPASS=1 bash "$TOOLS_DIR/cmd.sh" reboot "$win_name" "$PROJECT" 2>&1; then
          # 재시작 후 auth 상태 재확인 (2초 간격, 최대 20초 폴링)
          # healthy만 성공으로 인정. offline은 아직 부팅 중일 수 있으므로 대기.
          local poll_ok=0
          for _poll_i in 1 2 3 4 5 6 7 8 9 10; do
            sleep 2
            local recheck
            recheck="$(agent_classify_window_health "$PROJECT" "$SESSION" "$win_name" "$backend")"
            local recheck_state="${recheck%%|*}"
            if [ "$recheck_state" = "healthy" ]; then
              poll_ok=1
              break
            elif [ "$recheck_state" = "AUTH_BLOCKED" ]; then
              break
            fi
            # offline 등 → 아직 부팅 중, 계속 대기
          done
          if [ "$poll_ok" -eq 1 ]; then
            python3 "$TOOLS_DIR/log.py" system "$PROJECT" monitor auth_restart_success "$win_name" \
              --detail backend="$backend" role="$role" || true
            runtime_clear_agent_health_state "$PROJECT" "$win_name" || true
            runtime_clear_agent_health_alert_ts "$PROJECT" "$win_name" || true
            runtime_clear_manager_state "$PROJECT" "$restart_flag" || true
            continue
          fi
        fi
        python3 "$TOOLS_DIR/log.py" system "$PROJECT" monitor auth_restart_failed "$win_name" \
          --detail backend="$backend" role="$role" || true
      fi
      if ! [[ "${previous_alert:-}" =~ ^[0-9]+$ ]]; then
        runtime_set_agent_health_alert_ts "$PROJECT" "$win_name" "$(date +%s)" || true
        bash "$TOOLS_DIR/message.sh" "$PROJECT" monitor manager \
          need_input normal "${win_name} Claude auth blocked" \
          "${SESSION}:${win_name} pane이 로그인 필요 상태다. 자동 재시작을 시도했으나 실패했다. Claude 인증 복구 후 다시 진행해라." || true
      fi
      continue
    fi

    if [ "$previous_state" = "AUTH_BLOCKED" ]; then
      python3 "$TOOLS_DIR/log.py" system "$PROJECT" monitor auth_blocked_cleared "$win_name" \
        --detail backend="$backend" role="$role" session="$session_id" || true
      runtime_clear_manager_state "$PROJECT" "auth_restart_attempted_${win_name}" || true
    fi
    if [[ "${previous_alert:-}" =~ ^[0-9]+$ ]]; then
      runtime_clear_agent_health_alert_ts "$PROJECT" "$win_name" || true
    fi
  done < <(get_active_session_entries)
}

# ──────────────────────────────────────────────
# 크래시 감지 + 자동 reboot
# ──────────────────────────────────────────────

session_exists() {
  # 1차: has-session (빠름)
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    return 0
  fi
  # 2차: list-sessions fallback (has-session 일시 실패 대비)
  if tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -qx "$SESSION"; then
    return 0
  fi
  return 1
}

check_agent_windows() {
  local active_window_names window_name
  if ! session_exists; then
    SESSION_ABSENT_COUNT=$((SESSION_ABSENT_COUNT + 1))
    if [ "$SESSION_ABSENT_COUNT" -ge 3 ]; then
      python3 "$TOOLS_DIR/log.py" system "$PROJECT" monitor session_absent_confirmed "$SESSION" --detail reason="3회 연속 세션 부재, 대기 모드 진입" || true
      # 대기 모드: 60초 간격으로 세션 복귀 대기 (exit 대신)
      while ! session_exists; do
        sleep 60
        runtime_set_manager_state "$PROJECT" "monitor_heartbeat" "$(date +%s)" || true  # 좀비 오판 방지
      done
      # 세션 복귀 감지
      local recovered_epoch
      recovered_epoch="$(session_epoch_marker)"
      python3 "$TOOLS_DIR/log.py" system "$PROJECT" monitor session_recovered "$SESSION" --detail epoch="${recovered_epoch:-unknown}" || true
      mark_active_session_rows_stale
      begin_rehydration_grace "session-recovered" "$recovered_epoch"
      SESSION_ABSENT_COUNT=0
      return
    fi
    python3 "$TOOLS_DIR/log.py" system "$PROJECT" monitor session_absent "$SESSION" --detail count="${SESSION_ABSENT_COUNT}/3" || true
    return
  fi
  SESSION_ABSENT_COUNT=0

  active_window_names=$(get_active_roles)
  handle_session_epoch_transition "$(session_epoch_marker)"

  if rehydration_grace_active; then
    for window_name in $active_window_names; do
      if is_agent_alive "$window_name"; then
        reset_reboot_count "$window_name"
      else
        # 2-F: grace 중에도 crash 감지 + 로그. reboot은 grace 만료까지 유예.
        python3 "$TOOLS_DIR/log.py" system "$PROJECT" monitor crash_detected_during_grace "$window_name" \
          --detail reason="rehydration-grace-active, reboot-deferred" || true
      fi
    done
    return
  fi

  for window_name in $active_window_names; do
    if is_agent_alive "$window_name"; then
      reset_reboot_count "$window_name"
    else
      local count
      count=$(get_reboot_count "$window_name")

      if [ "$count" -lt "$MAX_REBOOT" ]; then
        # reboot lock 확인 (경합 방지)
        local lock_ts
        lock_ts="$(runtime_get_reboot_lock_ts "$PROJECT" "$window_name" 2>/dev/null || true)"
        if [[ "${lock_ts:-}" =~ ^[0-9]+$ ]]; then
          local lock_age=$(( $(date +%s) - lock_ts ))
          if [ "$lock_age" -lt 60 ]; then
            continue  # 리부팅 진행 중, 건너뜀
          fi
        fi

        python3 "$TOOLS_DIR/log.py" system "$PROJECT" monitor crash_detected "$window_name" --detail count="${count}/${MAX_REBOOT}" || true
        increment_reboot_count "$window_name"
        REBOOTED_THIS_CYCLE="${REBOOTED_THIS_CYCLE} ${window_name}"

        if bash "$TOOLS_DIR/cmd.sh" reboot "$window_name" "$PROJECT" 2>&1; then
          python3 "$TOOLS_DIR/log.py" system "$PROJECT" monitor reboot_success "$window_name" --detail count="$((count + 1))/${MAX_REBOOT}" || true
          send_crash_alert "$window_name" \
            "${window_name} 에이전트 크래시 감지. 자동 reboot 성공 ($((count + 1))/${MAX_REBOOT}회)."
        else
          python3 "$TOOLS_DIR/log.py" system "$PROJECT" monitor reboot_failed "$window_name" --detail count="$((count + 1))/${MAX_REBOOT}" || true
          send_crash_alert "$window_name" \
            "${window_name} 에이전트 크래시 감지. 자동 reboot 실패 ($((count + 1))/${MAX_REBOOT}회). 수동 개입 필요."
        fi
      else
        # 리부팅 한도 초과 — 쿨다운 (5분 후 카운터 리셋)
        local lockout_time
        lockout_time="$(runtime_get_reboot_lockout_ts "$PROJECT" "$window_name" 2>/dev/null || true)"
        if ! [[ "${lockout_time:-}" =~ ^[0-9]+$ ]]; then
          # 첫 lockout: 알림 + 타임스탬프 기록
          python3 "$TOOLS_DIR/log.py" system "$PROJECT" monitor reboot_limit "$window_name" --detail count="${count}/${MAX_REBOOT}" || true
          send_crash_alert "$window_name" \
            "${window_name} 에이전트 reboot ${MAX_REBOOT}회 시도 후 실패. 5분 후 카운터 리셋하여 재시도한다."
          runtime_set_reboot_lockout_ts "$PROJECT" "$window_name" "$(date +%s)"
        else
          # 5분 경과 확인
          local now_ts
          now_ts=$(date +%s)
          if [[ "$lockout_time" =~ ^[0-9]+$ ]] && [ $((now_ts - lockout_time)) -gt 300 ]; then
            reset_reboot_count "$window_name"
            runtime_clear_reboot_lockout_ts "$PROJECT" "$window_name"
            python3 "$TOOLS_DIR/log.py" system "$PROJECT" monitor reboot_count_reset "$window_name" || true
          fi
        fi
      fi
    fi
  done
}

# ──────────────────────────────────────────────
# 비활성 감지 — 10분 output 없으면 프로세스 생존 확인
# alive → 작업중 (정상), 10분 후 다시 확인
# dead → 매니저에게 보고 (크래시 감지와 별개로 이중 안전망)
# ──────────────────────────────────────────────

check_agent_health() {
  if ! session_exists; then
    return
  fi

  local now
  now=$(date +%s)

  while IFS='|' read -r win_name win_activity; do
    if [ "$win_name" = "manager" ] || [ "$win_name" = "dashboard" ]; then
      continue
    fi

    # H-03: 이번 사이클에서 이미 reboot된 window는 중복 escalation 방지
    if [[ " $REBOOTED_THIS_CYCLE " == *" $win_name "* ]]; then
      continue
    fi

    local idle_check_ts
    idle_check_ts="$(runtime_get_idle_check_ts "$PROJECT" "$win_name" 2>/dev/null || true)"

    if [ -n "$win_activity" ] && [ "$win_activity" != "0" ] && [[ "$win_activity" =~ ^[0-9]+$ ]]; then
      local idle_sec=$((now - win_activity))

      if [ "$idle_sec" -gt "$HUNG_THRESHOLD" ]; then
        # 10분간 output 없음 — 프로세스 확인
        if is_agent_alive "$win_name"; then
          local health_state
          health_state="$(runtime_get_agent_health_state "$PROJECT" "$win_name" "" 2>/dev/null || true)"
          # 살아있음 → 작업중. 체크 파일만 기록 (dashboard용)
          if ! [[ "${idle_check_ts:-}" =~ ^[0-9]+$ ]]; then
            runtime_set_idle_check_ts "$PROJECT" "$win_name" "$now"
            local idle_min=$((idle_sec / 60))
            local idle_status="alive"
            if [ "$health_state" = "AUTH_BLOCKED" ]; then
              idle_status="auth-blocked"
            fi
            python3 "$TOOLS_DIR/log.py" system "$PROJECT" monitor idle_detected "$win_name" --detail idle_min="$idle_min" status="$idle_status" || true
          fi
          # 10분 후 다시 확인됨 (30초 루프 + HUNG_THRESHOLD 조건)
        else
          # 죽었음 — 이미 보고했으면 중복 escalation 방지
          if [[ "${idle_check_ts:-}" =~ ^[0-9]+$ ]]; then
            # 이미 감지·보고 완료된 상태. 반복 escalation 안 함.
            :
          else
            local idle_min=$((idle_sec / 60))
            runtime_set_idle_check_ts "$PROJECT" "$win_name" "$now"

            # 태스크 할당 여부 확인: 할당 없으면 로그만, 있으면 escalation
            local _role_for_task="${win_name}"
            # dual 모드 window 이름에서 role 추출 (예: developer-claude → developer)
            _role_for_task="${_role_for_task%-claude}"
            _role_for_task="${_role_for_task%-codex}"
            local _active_task
            _active_task="$(get_active_task_ref_for_project "$PROJECT" "$_role_for_task" 2>/dev/null || true)"

            python3 "$TOOLS_DIR/log.py" system "$PROJECT" monitor idle_dead "$win_name" --detail idle_min="$idle_min" has_task="${_active_task:+yes}" || true

            if [ -n "$_active_task" ]; then
              bash "$TOOLS_DIR/message.sh" "$PROJECT" monitor manager \
                escalation urgent "${win_name} 프로세스 종료 감지" \
                "${win_name} 에이전트가 ${idle_min}분간 비활성 + 프로세스 종료 상태다. 활성 태스크: ${_active_task}. 리부팅이 필요하다." || \
                echo "[monitor] Warning: 종료 알림 전달 실패 (${win_name})" >&2
            fi
          fi
        fi
      else
        # 활동 재개 — 체크 파일 제거
        if [[ "${idle_check_ts:-}" =~ ^[0-9]+$ ]]; then
          runtime_clear_idle_check_ts "$PROJECT" "$win_name"
          python3 "$TOOLS_DIR/log.py" system "$PROJECT" monitor idle_cleared "$win_name" || true
        fi
      fi
    fi
  done < <(tmux list-windows -t "$SESSION" -F '#{window_name}|#{window_activity}')
}

# ──────────────────────────────────────────────
# 메시지 큐 drain
# ──────────────────────────────────────────────

drain_message_queue() {
  local queue_dir
  queue_dir="$(runtime_message_queue_dir "$PROJECT")"
  [ -d "$queue_dir" ] || return 0

  local now
  now=$(date +%s)

  for msg_file in "$queue_dir"/*.msg; do
    [ -f "$msg_file" ] || continue

    # TTL 확인 (파일명의 첫 필드가 타임스탬프)
    local msg_ts
    msg_ts=$(basename "$msg_file" | cut -d'-' -f1)
    if [[ "$msg_ts" =~ ^[0-9]+$ ]] && [ $((now - msg_ts)) -gt "$QUEUE_TTL" ]; then
      python3 "$TOOLS_DIR/log.py" message "$PROJECT" queue system queue_expire normal "$(basename "$msg_file")" skipped --reason "queue-ttl-expired" || true
      rm -f "$msg_file"
      continue
    fi

    # 메시지 파싱
    local msg_from msg_to msg_kind msg_priority msg_subject msg_content
    msg_from="$(whiplash_queue_read_field "$msg_file" "from")"
    msg_to="$(whiplash_queue_read_field "$msg_file" "to")"
    msg_kind="$(whiplash_queue_read_field "$msg_file" "kind")"
    msg_priority="$(whiplash_queue_read_field "$msg_file" "priority")"
    msg_subject="$(whiplash_queue_read_field "$msg_file" "subject")"
    msg_content="$(whiplash_queue_read_content "$msg_file")"

    [ -z "$msg_to" ] && { rm -f "$msg_file"; continue; }

    if [ "$msg_kind" = "user_notice" ] || { [ "$msg_kind" = "status_update" ] && { [ "$msg_to" = "manager" ] || [ "$msg_to" = "user" ]; }; }; then
      msg_subject="$(whiplash_notification_subject "$msg_kind" "$msg_subject")"
      msg_content="$(whiplash_notification_body "$msg_kind" "$msg_subject" "$msg_content")"
    fi

    if [ "$msg_to" = "user" ]; then
      rm -f "$msg_file"
      python3 "$TOOLS_DIR/log.py" message "$PROJECT" "$msg_from" "$msg_to" "$msg_kind" "$msg_priority" "$msg_subject" delivered --reason "queued-user-alert" || true
      continue
    fi

    if ! runtime_claim_message_target_lock "$PROJECT" "$msg_to"; then
      continue
    fi

    local notification
    notification="$(build_notification "$msg_from" "$msg_to" "$msg_kind" "$msg_priority" "$msg_subject" "$msg_content")"

    local backend delivery_state
    backend="$(get_window_backend "$msg_to")"
    delivery_state="$(agent_delivery_state "$PROJECT" "$SESSION" "$msg_to" "$backend")"
    if [ "${delivery_state%%|*}" != "healthy" ]; then
      runtime_release_message_target_lock "$PROJECT" "$msg_to" || true
      continue  # 아직 죽어 있으면 다음 주기에 재시도
    fi

    if submit_notification "$msg_to" "$notification"; then
      rm -f "$msg_file"
      # bookkeeping: 전달 성공 후에만 assignments.md 갱신 (C-02 수정)
      case "$msg_kind" in
        task_assign)
          runtime_clear_waiting_report "$PROJECT" "$msg_to" 2>/dev/null || true
          record_assignment_for_project "$PROJECT" "$msg_to" "$msg_subject" 2>/dev/null || true
          ;;
        task_complete)
          if [ "$msg_to" = "manager" ]; then
            # record_waiting_report: active task를 조회한 뒤 complete 처리
            local _drain_task_ref _drain_report_path _drain_report_rel
            _drain_task_ref="$(get_active_task_ref_for_project "$PROJECT" "$msg_from" 2>/dev/null || true)"
            if [ -n "$_drain_task_ref" ]; then
              _drain_report_path="$(runtime_task_report_path "$PROJECT" "$_drain_task_ref" "$msg_from" 2>/dev/null || true)"
              _drain_report_rel="$(runtime_project_relative_path "$PROJECT" "$_drain_report_path" 2>/dev/null || true)"
              runtime_set_waiting_report "$PROJECT" "$msg_from" "$(date +%s)" "$msg_subject" "$_drain_task_ref" "$_drain_report_rel" 2>/dev/null || true
            fi
            complete_assignment_for_project "$PROJECT" "$msg_from" 2>/dev/null || true
          fi
          ;;
      esac
      python3 "$TOOLS_DIR/log.py" message "$PROJECT" "$msg_from" "$msg_to" "$msg_kind" "$msg_priority" "$msg_subject" delivered --reason "queued-drain" || true
    fi
    runtime_release_message_target_lock "$PROJECT" "$msg_to" || true
  done
}

# ──────────────────────────────────────────────
# 메인: 헬스 체크 루프
# ──────────────────────────────────────────────

if [ "$MONITOR_ONCE" = "1" ]; then
  check_agent_windows
  check_agent_health
  check_claude_plan_mode
  check_claude_auth_blocked
  drain_message_queue
  cleanup_manager_runtime_transients "$PROJECT"
  runtime_set_manager_state "$PROJECT" "monitor_heartbeat" "$(date +%s)" || true
  exit 0
fi

python3 "$TOOLS_DIR/log.py" system "$PROJECT" monitor monitor_started "$SESSION" --detail interval="${HEALTH_CHECK_INTERVAL}s" || true

# 초기 sweep: monitor 시작 전에 쌓인 상태를 즉시 처리
# (메인 루프 첫 반복까지 최대 HEALTH_CHECK_INTERVAL초 지연 방지)
REBOOTED_THIS_CYCLE=""
check_agent_windows
drain_message_queue

MONITOR_PARENT_PID="$$"

while true; do
  # C-01 대응: wrapper 사망 시 orphan 자가 감지 → 깔끔한 exit
  # (wrapper가 죽으면 PPID가 1/init이 됨. 정상 exit 후 monitor-check이 재시작)
  local_ppid="$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ' || echo "1")"
  if [ "$local_ppid" = "1" ]; then
    python3 "$TOOLS_DIR/log.py" system "$PROJECT" monitor monitor_orphaned "$SESSION" \
      --detail reason="wrapper-dead, PPID=1" || true
    exit 1
  fi

  REBOOTED_THIS_CYCLE=""
  check_agent_windows
  check_agent_health
  check_claude_plan_mode
  check_claude_auth_blocked
  drain_message_queue
  cleanup_manager_runtime_transients "$PROJECT"
  runtime_set_manager_state "$PROJECT" "monitor_heartbeat" "$(date +%s)" || true
  sleep "$HEALTH_CHECK_INTERVAL"
done
