#!/bin/bash
# monitor.sh -- 이벤트 드리븐 mailbox 감시 + tmux 알림 + 크래시 복구 + 행 감지 데몬
#
# mailbox/new/ 감시: fswatch(macOS) / inotifywait(Linux)로 즉시 감지.
# 둘 다 없으면 5초 폴링 fallback.
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
REPO_ROOT="$(git rev-parse --show-toplevel)"
TOOLS_DIR="$REPO_ROOT/agents/manager/tools"
MAILBOX_ROOT="$REPO_ROOT/projects/$PROJECT/workspace/shared/mailbox"
SESSION="whiplash-${PROJECT}"
HEALTH_CHECK_INTERVAL=30   # 헬스 체크 주기 (mailbox와 무관)
MAX_REBOOT=3
HUNG_THRESHOLD=600  # 10분 (초)
REBOOT_COUNT_DIR="$REPO_ROOT/projects/$PROJECT/memory/manager/reboot-counts"
HEARTBEAT_FILE="$REPO_ROOT/projects/$PROJECT/memory/manager/monitor.heartbeat"

# ──────────────────────────────────────────────
# 메시지 파싱 (frontmatter에서 필드 추출)
# ──────────────────────────────────────────────

parse_field() {
  local file="$1" field="$2"
  grep "^${field}:" "$file" | head -1 | sed "s/^${field}: *//"
}

# ──────────────────────────────────────────────
# 크래시 알림 헬퍼
# ──────────────────────────────────────────────

send_crash_alert() {
  local role="$1" message="$2"
  if [ "$role" = "manager" ]; then
    # Manager에게 mailbox를 보낼 수 없으므로 로그에만 기록
    echo "[monitor] MANAGER CRASH: $message" >&2
  else
    bash "$TOOLS_DIR/mailbox.sh" "$PROJECT" monitor manager \
      reboot_notice urgent "${role} 크래시" "$message"
  fi
}

# ──────────────────────────────────────────────
# sessions.md에서 active 윈도우 이름 파싱
# tmux target 컬럼에서 윈도우 이름을 추출한다.
# solo: "researcher" 반환. dual: "researcher-claude", "researcher-codex" 반환.
# ──────────────────────────────────────────────

get_active_roles() {
  local sessions_file="$REPO_ROOT/projects/$PROJECT/memory/manager/sessions.md"
  if [ ! -f "$sessions_file" ]; then
    return
  fi
  # tmux target 컬럼(5번째)에서 "session:window" 형식의 윈도우 이름 추출
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
    cat "$count_file"
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
# 모든 역할의 mailbox를 한 번에 처리
# ──────────────────────────────────────────────

process_all_mailboxes() {
  for role_dir in "$MAILBOX_ROOT"/*/; do
    [ -d "$role_dir" ] || continue
    local role
    role="$(basename "$role_dir")"
    process_mailbox "$role"
  done
}

# ──────────────────────────────────────────────
# 크로스플랫폼 파일 감시 — mailbox/*/new/ 디렉토리 감시
# ──────────────────────────────────────────────

start_mailbox_watcher() {
  if command -v fswatch &>/dev/null; then
    # macOS (FSEvents)
    fswatch -0 --event Created "$MAILBOX_ROOT"/*/new/ 2>/dev/null \
      | while read -d '' _event; do
          process_all_mailboxes
        done
  elif command -v inotifywait &>/dev/null; then
    # Linux (inotify)
    inotifywait -m -q -e create,moved_to \
      --format '%w' "$MAILBOX_ROOT"/*/new/ 2>/dev/null \
      | while read _dir; do
          process_all_mailboxes
        done
  else
    # Fallback: 빠른 폴링 (5초)
    echo "[monitor] fswatch/inotifywait 없음. 5초 폴링 fallback."
    while true; do
      process_all_mailboxes
      sleep 5
    done
  fi
}

# ──────────────────────────────────────────────
# 메시지 처리: new/ → tmux 알림(전체 내용 포함) → 즉시 삭제
# ──────────────────────────────────────────────

process_mailbox() {
  local role="$1"
  local new_dir="$MAILBOX_ROOT/$role/new"

  # new/ 디렉토리가 없거나 비어있으면 스킵
  [ -d "$new_dir" ] || return 0

  for msg_file in "$new_dir"/*.md; do
    # glob이 매치 안 되면 리터럴 문자열이 됨 — 존재 확인
    [ -f "$msg_file" ] || continue

    local from subject kind priority content
    from="$(parse_field "$msg_file" "from")"
    subject="$(parse_field "$msg_file" "subject")"
    kind="$(parse_field "$msg_file" "kind")"
    priority="$(parse_field "$msg_file" "priority")"
    # frontmatter(---...---) 이후의 본문을 추출
    content="$(sed -n '/^---$/,/^---$/d; /^$/d; p' "$msg_file" | head -20)"

    # tmux 알림 구성 (전체 내용 포함)
    local prefix="[mailbox]"
    if [ "$priority" = "urgent" ]; then
      prefix="[URGENT mailbox]"
    fi
    local notification="${prefix} ${from} → ${role} | ${kind}
제목: ${subject}
내용: ${content}"

    # 해당 에이전트의 tmux 윈도우에 전달
    local tmux_target="${SESSION}:${role}"
    if tmux has-session -t "$SESSION" 2>/dev/null; then
      # 윈도우 존재 확인
      if tmux list-windows -t "$SESSION" -F '#{window_name}' | grep -q "^${role}$"; then
        tmux send-keys -t "$tmux_target" "$notification" Enter
      fi
    fi

    # 전달 후 즉시 삭제
    rm -f "$msg_file"
  done
}

# ──────────────────────────────────────────────
# 크래시 감지 + 자동 reboot
# ──────────────────────────────────────────────

check_agent_windows() {
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "[monitor] tmux 세션 '$SESSION' 사라짐. 종료." >&2
    exit 1
  fi

  local active_windows
  active_windows=$(tmux list-windows -t "$SESSION" -F '#{window_name}')

  # sessions.md에서 active 윈도우 이름 파싱 (solo: role, dual: role-backend)
  local active_window_names
  active_window_names=$(get_active_roles)

  for window_name in $active_window_names; do
    if echo "$active_windows" | grep -q "^${window_name}$"; then
      # 윈도우 정상 — reboot 카운터 리셋
      reset_reboot_count "$window_name"
    else
      # 윈도우 없음 — 크래시 감지
      local count
      count=$(get_reboot_count "$window_name")

      if [ "$count" -lt "$MAX_REBOOT" ]; then
        echo "[monitor] ${window_name} 윈도우 없음. 자동 reboot 시도 (${count}/${MAX_REBOOT})"
        increment_reboot_count "$window_name"

        # orchestrator.sh reboot 호출 (window_name을 target으로 전달)
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
        # 3회 초과 — reboot 포기
        echo "[monitor] ${window_name} reboot 한도 초과 (${count}/${MAX_REBOOT}). 수동 개입 필요."
        send_crash_alert "$window_name" \
          "${window_name} 에이전트 reboot ${MAX_REBOOT}회 시도 후 실패. 수동 개입이 필요하다. orchestrator.sh reboot ${window_name} ${PROJECT} 로 수동 복구하라."
        # 알림 중복 방지: 카운터를 한도+1로 설정
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
    # manager는 유저 윈도우이므로 건너뛴다
    if [ "$win_name" = "manager" ]; then
      continue
    fi

    local hung_flag="$hung_flag_dir/${win_name}.hung"

    if [ -n "$win_activity" ] && [ "$win_activity" != "0" ]; then
      local idle_sec=$((now - win_activity))

      if [ "$idle_sec" -gt "$HUNG_THRESHOLD" ]; then
        # 10분 이상 비활성 — 중복 알림 방지 후 Manager에 1회 알림
        if [ ! -f "$hung_flag" ]; then
          mkdir -p "$hung_flag_dir"
          echo "$now" > "$hung_flag"
          local idle_min=$((idle_sec / 60))
          echo "[monitor] ${win_name} ${idle_min}분 비활성. Manager에 알림."
          bash "$TOOLS_DIR/mailbox.sh" "$PROJECT" monitor manager \
            escalation normal "${win_name} 비활성 경고" \
            "${win_name} 에이전트가 ${idle_min}분간 비활성 상태다. 긴 작업 중일 수도 있으니 확인 바란다."
        fi
      else
        # 활동 재개 — flag 클리어
        if [ -f "$hung_flag" ]; then
          rm -f "$hung_flag"
          echo "[monitor] ${win_name} 활동 재개. hung flag 클리어."
        fi
      fi
    fi
  done < <(tmux list-windows -t "$SESSION" -F '#{window_name}|#{window_activity}')
}

# ──────────────────────────────────────────────
# 메인: mailbox 이벤트 감시(백그라운드) + 헬스 체크(포그라운드)
# ──────────────────────────────────────────────

echo "[monitor] 시작: project=${PROJECT}, session=${SESSION}, health_check=${HEALTH_CHECK_INTERVAL}s"

# 1. Mailbox 감시 — 백그라운드 (이벤트 드리븐)
start_mailbox_watcher &
WATCHER_PID=$!

# 종료 시 watcher도 함께 정리
trap 'kill $WATCHER_PID 2>/dev/null; exit 0' INT TERM EXIT

echo "[monitor] mailbox watcher 시작 (PID: $WATCHER_PID)"

# 2. 헬스 체크 — 포그라운드 (주기적)
while true; do
  # 크래시 감지 + 자동 reboot (매 사이클)
  check_agent_windows

  # 행(hung) 감지 (매 사이클)
  check_agent_health

  # 자가 heartbeat
  date +%s > "$HEARTBEAT_FILE"

  sleep "$HEALTH_CHECK_INTERVAL"
done
