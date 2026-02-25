#!/bin/bash
# monitor.sh -- 크래시 복구 + 행 감지 데몬
#
# 헬스 체크(크래시/hung/heartbeat): 30초 주기 포그라운드 루프.
# 에이전트 크래시 감지 시 자동 reboot (최대 3회).
# 10분 비활성 에이전트 감지 시 Manager에게 알림.
#
# Usage:
#   nohup bash monitor.sh {project} >> {log_file} 2>&1 &
#
# 종료:
#   orchestrator.sh shutdown이 PID를 kill하거나, 직접 kill.

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
REPO_ROOT="$(git rev-parse --show-toplevel)"
TOOLS_DIR="$REPO_ROOT/agents/manager/tools"
SESSION="whiplash-${PROJECT}"
HEALTH_CHECK_INTERVAL=30
MAX_REBOOT=3
HUNG_THRESHOLD=600  # 10분 (초)
REBOOT_COUNT_DIR="$REPO_ROOT/projects/$PROJECT/memory/manager/reboot-counts"
HEARTBEAT_FILE="$REPO_ROOT/projects/$PROJECT/memory/manager/monitor.heartbeat"
SESSION_ABSENT_COUNT=0

# ──────────────────────────────────────────────
# 크래시 알림 헬퍼
# ──────────────────────────────────────────────

send_crash_alert() {
  local role="$1" message="$2"
  if [ "$role" = "manager" ]; then
    echo "[monitor] MANAGER CRASH: $message" >&2
  else
    bash "$TOOLS_DIR/notify.sh" "$PROJECT" monitor manager \
      reboot_notice urgent "${role} 크래시" "$message" || \
      echo "[monitor] Warning: 크래시 알림 전달 실패 (role=${role})" >&2
  fi
}

# ──────────────────────────────────────────────
# sessions.md에서 active 윈도우 이름 파싱
# ──────────────────────────────────────────────

get_active_roles() {
  local sessions_file="$REPO_ROOT/projects/$PROJECT/memory/manager/sessions.md"
  if [ ! -f "$sessions_file" ]; then
    return
  fi
  grep '| active |' "$sessions_file" 2>/dev/null \
    | awk -F'|' '{print $5}' \
    | sed 's/.*://' \
    | sed 's/^ *//;s/ *$//' \
    | grep -v '^$'
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

# ──────────────────────────────────────────────
# 크래시 감지 + 자동 reboot
# ──────────────────────────────────────────────

check_agent_windows() {
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    SESSION_ABSENT_COUNT=$((SESSION_ABSENT_COUNT + 1))
    if [ "$SESSION_ABSENT_COUNT" -ge 3 ]; then
      echo "[monitor] tmux 세션 '$SESSION' 3회 연속 부재. 종료." >&2
      exit 1
    fi
    echo "[monitor] tmux 세션 '$SESSION' 부재 (${SESSION_ABSENT_COUNT}/3). 재시도 대기." >&2
    return
  fi
  SESSION_ABSENT_COUNT=0

  local active_windows
  active_windows=$(tmux list-windows -t "$SESSION" -F '#{window_name}')

  local active_window_names
  active_window_names=$(get_active_roles)

  for window_name in $active_window_names; do
    if echo "$active_windows" | grep -q "^${window_name}$"; then
      reset_reboot_count "$window_name"
    else
      local count
      count=$(get_reboot_count "$window_name")

      if [ "$count" -lt "$MAX_REBOOT" ]; then
        echo "[monitor] ${window_name} 윈도우 없음. 자동 reboot 시도 (${count}/${MAX_REBOOT})"
        increment_reboot_count "$window_name"

        if bash "$TOOLS_DIR/orchestrator.sh" reboot "$window_name" "$PROJECT" 2>&1; then
          echo "[monitor] ${window_name} reboot 성공"
          send_crash_alert "$window_name" \
            "${window_name} 에이전트 크래시 감지. 자동 reboot 성공 ($((count + 1))/${MAX_REBOOT}회)."
        else
          echo "[monitor] ${window_name} reboot 실패"
          send_crash_alert "$window_name" \
            "${window_name} 에이전트 크래시 감지. 자동 reboot 실패 ($((count + 1))/${MAX_REBOOT}회). 수동 개입 필요."
        fi
      else
        echo "[monitor] ${window_name} reboot 한도 초과 (${count}/${MAX_REBOOT}). 수동 개입 필요."
        send_crash_alert "$window_name" \
          "${window_name} 에이전트 reboot ${MAX_REBOOT}회 시도 후 실패. 수동 개입이 필요하다. orchestrator.sh reboot ${window_name} ${PROJECT} 로 수동 복구하라."
        echo $((MAX_REBOOT + 1)) > "$REBOOT_COUNT_DIR/${window_name}.count"
      fi
    fi
  done
}

# ──────────────────────────────────────────────
# 행(hung) 감지
# ──────────────────────────────────────────────

check_agent_health() {
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    return
  fi

  local now
  now=$(date +%s)
  local hung_flag_dir="$REPO_ROOT/projects/$PROJECT/memory/manager/hung-flags"

  while IFS='|' read -r win_name win_activity; do
    if [ "$win_name" = "manager" ]; then
      continue
    fi

    local hung_flag="$hung_flag_dir/${win_name}.hung"

    if [ -n "$win_activity" ] && [ "$win_activity" != "0" ] && [[ "$win_activity" =~ ^[0-9]+$ ]]; then
      local idle_sec=$((now - win_activity))

      if [ "$idle_sec" -gt "$HUNG_THRESHOLD" ]; then
        if [ ! -f "$hung_flag" ]; then
          mkdir -p "$hung_flag_dir"
          echo "$now" > "$hung_flag"
          local idle_min=$((idle_sec / 60))
          echo "[monitor] ${win_name} ${idle_min}분 비활성. Manager에 알림."
          bash "$TOOLS_DIR/notify.sh" "$PROJECT" monitor manager \
            escalation normal "${win_name} 비활성 경고" \
            "${win_name} 에이전트가 ${idle_min}분간 비활성 상태다. 긴 작업 중일 수도 있으니 확인 바란다." || \
            echo "[monitor] Warning: 비활성 알림 전달 실패 (${win_name})" >&2
        fi
      else
        if [ -f "$hung_flag" ]; then
          rm -f "$hung_flag"
          echo "[monitor] ${win_name} 활동 재개. hung flag 클리어."
        fi
      fi
    fi
  done < <(tmux list-windows -t "$SESSION" -F '#{window_name}|#{window_activity}')
}

# ──────────────────────────────────────────────
# 메인: 헬스 체크 루프
# ──────────────────────────────────────────────

echo "[monitor] 시작: project=${PROJECT}, session=${SESSION}, health_check=${HEALTH_CHECK_INTERVAL}s"

mkdir -p "$(dirname "$HEARTBEAT_FILE")"

while true; do
  check_agent_windows
  check_agent_health
  date +%s > "$HEARTBEAT_FILE"
  sleep "$HEALTH_CHECK_INTERVAL"
done
