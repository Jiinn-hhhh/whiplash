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
# shellcheck source=/dev/null
source "$TOOLS_DIR/tmux-submit.sh"
HEALTH_CHECK_INTERVAL=30
MAX_REBOOT=5
HUNG_THRESHOLD=600  # 10분 (초)
REBOOT_COUNT_DIR="$REPO_ROOT/projects/$PROJECT/memory/manager/reboot-counts"
HEARTBEAT_FILE="$REPO_ROOT/projects/$PROJECT/memory/manager/monitor.heartbeat"
SESSION_ABSENT_COUNT=0

# ──────────────────────────────────────────────
# PID lock — 동일 프로젝트에 대한 중복 monitor 방지
# ──────────────────────────────────────────────
LOCK_FILE="$REPO_ROOT/projects/$PROJECT/memory/manager/monitor.lock"
mkdir -p "$(dirname "$LOCK_FILE")"
if [ -f "$LOCK_FILE" ]; then
  OLD_PID=$(cat "$LOCK_FILE" 2>/dev/null)
  if [[ "$OLD_PID" =~ ^[0-9]+$ ]] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "Error: monitor.sh가 이미 실행 중 (PID: $OLD_PID). 중복 실행 방지." >&2
    exit 1
  fi
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

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

# ──────────────────────────────────────────────
# reboot 카운터 관리
# ──────────────────────────────────────────────

get_reboot_count() {
  local role="$1"
  local count_file="$REBOOT_COUNT_DIR/${role}.count"
  if [ -f "$count_file" ]; then
    local val
    val=$(cat "$count_file")
    # 숫자가 아니면 0으로 리셋
    if [[ "$val" =~ ^[0-9]+$ ]]; then
      echo "$val"
    else
      echo "0"
    fi
  else
    echo "0"
  fi
}

increment_reboot_count() {
  local role="$1"
  mkdir -p "$REBOOT_COUNT_DIR"
  local count_file="$REBOOT_COUNT_DIR/${role}.count"
  local current
  current=$(get_reboot_count "$role")
  echo $((current + 1)) > "$count_file"
}

reset_reboot_count() {
  local role="$1"
  local count_file="$REBOOT_COUNT_DIR/${role}.count"
  rm -f "$count_file"
}

get_window_backend() {
  local win_name="$1"
  if [[ "$win_name" == *-codex ]]; then
    echo "codex"
    return
  fi

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

  echo "claude"
}

# ──────────────────────────────────────────────
# 프로세스 레벨 생존 체크
# ──────────────────────────────────────────────

is_agent_alive() {
  local win_name="$1"
  local tmux_target="${SESSION}:${win_name}"
  # 윈도우 존재 + 에이전트 프로세스 생존 둘 다 확인
  if ! tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -q "^${win_name}$"; then
    return 1
  fi
  local pane_pid
  pane_pid=$(tmux list-panes -t "$tmux_target" -F '#{pane_pid}' 2>/dev/null | head -1)
  local backend
  backend="$(get_window_backend "$win_name")"
  # 백엔드에 따라 프로세스 이름 분기
  # codex interactive 모드: codex 프로세스가 상시 실행
  # codex exec 모드: codex-agent.sh (bash)가 상시 실행, codex 프로세스는 태스크별 실행/종료
  if [ "$backend" = "codex" ]; then
    [ -n "$pane_pid" ] && {
      pgrep -P "$pane_pid" "codex" >/dev/null 2>&1 || \
      pgrep -P "$pane_pid" "bash" >/dev/null 2>&1
    }
  else
    [ -n "$pane_pid" ] && pgrep -P "$pane_pid" "claude" >/dev/null 2>&1
  fi
}

# ──────────────────────────────────────────────
# 크래시 감지 + 자동 reboot
# ──────────────────────────────────────────────

check_agent_windows() {
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    SESSION_ABSENT_COUNT=$((SESSION_ABSENT_COUNT + 1))
    if [ "$SESSION_ABSENT_COUNT" -ge 3 ]; then
      python3 "$TOOLS_DIR/log.py" system "$PROJECT" monitor session_absent_confirmed "$SESSION" --detail reason="3회 연속 세션 부재, 대기 모드 진입" || true
      # 대기 모드: 60초 간격으로 세션 복귀 대기 (exit 대신)
      while ! tmux has-session -t "$SESSION" 2>/dev/null; do
        sleep 60
        date +%s > "$HEARTBEAT_FILE"  # 좀비 오판 방지
      done
      # 세션 복귀 감지
      python3 "$TOOLS_DIR/log.py" system "$PROJECT" monitor session_recovered "$SESSION" || true
      SESSION_ABSENT_COUNT=0
      return
    fi
    python3 "$TOOLS_DIR/log.py" system "$PROJECT" monitor session_absent "$SESSION" --detail count="${SESSION_ABSENT_COUNT}/3" || true
    return
  fi
  SESSION_ABSENT_COUNT=0

  local active_windows
  active_windows=$(tmux list-windows -t "$SESSION" -F '#{window_name}')

  local active_window_names
  active_window_names=$(get_active_roles)

  for window_name in $active_window_names; do
    if is_agent_alive "$window_name"; then
      reset_reboot_count "$window_name"
    else
      local count
      count=$(get_reboot_count "$window_name")

      if [ "$count" -lt "$MAX_REBOOT" ]; then
        # reboot lock 확인 (경합 방지)
        local lock_file="$REPO_ROOT/projects/$PROJECT/memory/manager/reboot-locks/${window_name}.lock"
        if [ -f "$lock_file" ]; then
          local lock_age=$(($(date +%s) - $(cat "$lock_file")))
          if [ "$lock_age" -lt 60 ]; then
            continue  # 리부팅 진행 중, 건너뜀
          fi
        fi

        python3 "$TOOLS_DIR/log.py" system "$PROJECT" monitor crash_detected "$window_name" --detail count="${count}/${MAX_REBOOT}" || true
        increment_reboot_count "$window_name"

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
        local lockout_file="$REBOOT_COUNT_DIR/${window_name}.lockout"
        if [ ! -f "$lockout_file" ]; then
          # 첫 lockout: 알림 + 타임스탬프 기록
          python3 "$TOOLS_DIR/log.py" system "$PROJECT" monitor reboot_limit "$window_name" --detail count="${count}/${MAX_REBOOT}" || true
          send_crash_alert "$window_name" \
            "${window_name} 에이전트 reboot ${MAX_REBOOT}회 시도 후 실패. 5분 후 카운터 리셋하여 재시도한다."
          date +%s > "$lockout_file"
        else
          # 5분 경과 확인
          local lockout_time
          lockout_time=$(cat "$lockout_file")
          local now_ts
          now_ts=$(date +%s)
          if [[ "$lockout_time" =~ ^[0-9]+$ ]] && [ $((now_ts - lockout_time)) -gt 300 ]; then
            reset_reboot_count "$window_name"
            rm -f "$lockout_file"
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
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    return
  fi

  local now
  now=$(date +%s)
  local idle_check_dir="$REPO_ROOT/projects/$PROJECT/memory/manager/idle-checks"

  while IFS='|' read -r win_name win_activity; do
    if [ "$win_name" = "manager" ] || [ "$win_name" = "dashboard" ]; then
      continue
    fi

    local check_file="$idle_check_dir/${win_name}.check"

    if [ -n "$win_activity" ] && [ "$win_activity" != "0" ] && [[ "$win_activity" =~ ^[0-9]+$ ]]; then
      local idle_sec=$((now - win_activity))

      if [ "$idle_sec" -gt "$HUNG_THRESHOLD" ]; then
        # 10분간 output 없음 — 프로세스 확인
        if is_agent_alive "$win_name"; then
          # 살아있음 → 작업중. 체크 파일만 기록 (dashboard용)
          if [ ! -f "$check_file" ]; then
            mkdir -p "$idle_check_dir"
            echo "$now" > "$check_file"
            local idle_min=$((idle_sec / 60))
            python3 "$TOOLS_DIR/log.py" system "$PROJECT" monitor idle_detected "$win_name" --detail idle_min="$idle_min" status="alive" || true
          fi
          # 10분 후 다시 확인됨 (30초 루프 + HUNG_THRESHOLD 조건)
        else
          # 죽었음 → 매니저에게 보고
          local idle_min=$((idle_sec / 60))
          python3 "$TOOLS_DIR/log.py" system "$PROJECT" monitor idle_dead "$win_name" --detail idle_min="$idle_min" || true
          bash "$TOOLS_DIR/message.sh" "$PROJECT" monitor manager \
            escalation urgent "${win_name} 프로세스 종료 감지" \
            "${win_name} 에이전트가 ${idle_min}분간 비활성 + 프로세스 종료 상태다. 리부팅이 필요하다." || \
            echo "[monitor] Warning: 종료 알림 전달 실패 (${win_name})" >&2
          [ -f "$check_file" ] && rm -f "$check_file"
        fi
      else
        # 활동 재개 — 체크 파일 제거
        if [ -f "$check_file" ]; then
          rm -f "$check_file"
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
  local queue_dir="$REPO_ROOT/projects/$PROJECT/memory/manager/message-queue"
  [ -d "$queue_dir" ] || return 0

  local now
  now=$(date +%s)
  local ttl=1800  # 30분

  for msg_file in "$queue_dir"/*.msg; do
    [ -f "$msg_file" ] || continue

    # TTL 확인 (파일명의 첫 필드가 타임스탬프)
    local msg_ts
    msg_ts=$(basename "$msg_file" | cut -d'-' -f1)
    if [[ "$msg_ts" =~ ^[0-9]+$ ]] && [ $((now - msg_ts)) -gt $ttl ]; then
      rm -f "$msg_file"
      continue
    fi

    # 메시지 파싱
    local msg_from msg_to msg_kind msg_priority msg_subject msg_content
    msg_from=$(grep '^from=' "$msg_file" | head -1 | sed 's/^from=//')
    msg_to=$(grep '^to=' "$msg_file" | head -1 | sed 's/^to=//')
    msg_kind=$(grep '^kind=' "$msg_file" | head -1 | sed 's/^kind=//')
    msg_priority=$(grep '^priority=' "$msg_file" | head -1 | sed 's/^priority=//')
    msg_subject=$(grep '^subject=' "$msg_file" | head -1 | sed 's/^subject=//')
    msg_content=$(grep '^content=' "$msg_file" | head -1 | sed 's/^content=//')

    [ -z "$msg_to" ] && { rm -f "$msg_file"; continue; }

    # 수신자 프로세스 alive 확인
    if ! is_agent_alive "$msg_to"; then
      continue  # 아직 죽어 있으면 다음 주기에 재시도
    fi

    # 직접 tmux 전달 (message.sh 재호출 안 함 → 재큐 루프 방지)
    local tmux_target="${SESSION}:${msg_to}"
    local prefix="[notify] ${msg_from} → ${msg_to} | ${msg_kind}"
    if [ "$msg_priority" = "urgent" ]; then
      prefix="[URGENT] ${msg_from} → ${msg_to} | ${msg_kind}"
    fi
    local notification="${prefix}
제목: ${msg_subject}
내용: ${msg_content}"

    if tmux_submit_pasted_payload "$tmux_target" "$notification" "drain"; then
      rm -f "$msg_file"
      python3 "$TOOLS_DIR/log.py" message "$PROJECT" "$msg_from" "$msg_to" "$msg_kind" "$msg_priority" "$msg_subject" delivered || true
    else
      python3 "$TOOLS_DIR/log.py" message "$PROJECT" "$msg_from" "$msg_to" "$msg_kind" "$msg_priority" "$msg_subject" skipped --reason "tmux-target-unavailable" || true
    fi
  done
}

# ──────────────────────────────────────────────
# 메인: 헬스 체크 루프
# ──────────────────────────────────────────────

python3 "$TOOLS_DIR/log.py" system "$PROJECT" monitor monitor_started "$SESSION" --detail interval="${HEALTH_CHECK_INTERVAL}s" || true

mkdir -p "$(dirname "$HEARTBEAT_FILE")"

while true; do
  check_agent_windows
  check_agent_health
  drain_message_queue
  date +%s > "$HEARTBEAT_FILE"
  sleep "$HEALTH_CHECK_INTERVAL"
done
