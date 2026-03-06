#!/bin/bash
# message.sh -- tmux 직접 전달 방식의 에이전트 간 알림
#
# 수신자의 tmux 윈도우에 직접 전달한다.
# tmux load-buffer + paste-buffer로 안정적인 멀티라인 전달.
#
# Usage:
#   message.sh {project} {from} {to} {kind} {priority} {subject} {content}
#
# Arguments:
#   project   -- 프로젝트 이름
#   from      -- 발신자 역할 (manager, researcher, developer, monitoring)
#   to        -- 수신자 역할
#   kind      -- 메시지 종류: task_complete | status_update | need_input | escalation | agent_ready | reboot_notice | consensus_request
#   priority  -- normal | urgent
#   subject   -- 제목 (한 줄)
#   content   -- 본문 (짧게. 상세 내용은 별도 문서에 두고 참조)

set -euo pipefail

if [ $# -lt 7 ]; then
  echo "Usage: message.sh {project} {from} {to} {kind} {priority} {subject} {content}" >&2
  exit 1
fi

project="$1"
from="$2"
to="$3"
kind="$4"
priority="$5"
subject="$6"
content="$7"

# project 이름 검증 (경로 트래버설 방지)
if [[ "$project" == */* ]] || [[ "$project" == *..* ]] || [ -z "$project" ]; then
  echo "Error: 잘못된 project 이름: $project" >&2
  exit 1
fi

# kind 검증
case "$kind" in
  task_complete|status_update|need_input|escalation|agent_ready|reboot_notice|consensus_request|alert_resolve|task_assign) ;;
  *) echo "Error: 잘못된 kind: $kind" >&2
     echo "허용: task_complete, status_update, need_input, escalation, agent_ready, reboot_notice, consensus_request, alert_resolve, task_assign" >&2
     exit 1 ;;
esac

# priority 검증
case "$priority" in
  normal|urgent) ;;
  *) echo "Error: 잘못된 priority: $priority (허용: normal, urgent)" >&2
     exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOLS_DIR="$SCRIPT_DIR"
session="whiplash-${project}"
tmux_target="${session}:${to}"
# shellcheck source=/dev/null
source "$TOOLS_DIR/tmux-submit.sh"

sed_inplace() {
  if [[ "$OSTYPE" == darwin* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

assignments_file() {
  echo "$repo_root/projects/$project/memory/manager/assignments.md"
}

normalize_task_ref() {
  local task_ref="$1"
  local project_root="$repo_root/projects/$project"
  if [[ "$task_ref" == "$project_root"/* ]]; then
    task_ref="${task_ref#"$project_root"/}"
  elif [[ "$task_ref" == "projects/$project/"* ]]; then
    task_ref="${task_ref#"projects/$project/"}"
  fi
  echo "$task_ref"
}

record_assignment() {
  local agent="$1"
  local task_ref="$2"
  local af
  af="$(assignments_file)"
  mkdir -p "$(dirname "$af")"

  if [ ! -f "$af" ]; then
    cat > "$af" << 'HEADER'
# 태스크 할당 현황
| 에이전트 | 태스크 파일 | 할당 시각 | 상태 |
|----------|-----------|----------|------|
HEADER
  fi

  if grep -q "| ${agent} |.*| active |" "$af" 2>/dev/null; then
    sed_inplace "s/| ${agent} |\(.*\)| active |/| ${agent} |\1| completed |/" "$af"
  fi

  task_ref="$(normalize_task_ref "$task_ref")"
  echo "| ${agent} | ${task_ref} | $(date '+%Y-%m-%d %H:%M') | active |" >> "$af"
}

complete_assignment() {
  local agent="$1"
  local af
  af="$(assignments_file)"
  [ -f "$af" ] || return 0
  if grep -q "| ${agent} |.*| active |" "$af" 2>/dev/null; then
    sed_inplace "s/| ${agent} |\(.*\)| active |/| ${agent} |\1| completed |/" "$af"
  fi
}

resolve_backend() {
  local window_name="$1"
  case "$window_name" in
    *-codex|*-codex-*)
    echo "codex"
    return
    ;;
  esac

  local sf="$repo_root/projects/$project/memory/manager/sessions.md"
  if [ -f "$sf" ]; then
    local backend
    backend=$(
      awk -F'|' -v target="${session}:${window_name}" '
        function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
        trim($5) == target && trim($6) == "active" { backend = trim($3) }
        END { print backend }
      ' "$sf"
    )
    if [ -n "$backend" ]; then
      echo "$backend"
      return
    fi
  fi

  echo "claude"
}

heuristic_agent_role() {
  local window_name="$1"
  printf '%s\n' "$window_name" | sed -E 's/-(claude|codex)(-.+)?$//'
}

resolve_agent_role() {
  local window_name="$1"
  local sf="$repo_root/projects/$project/memory/manager/sessions.md"
  if [ -f "$sf" ]; then
    local role
    role=$(
      awk -F'|' -v target="${session}:${window_name}" '
        function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
        trim($5) == target && trim($6) == "active" { role = trim($2) }
        END { print role }
      ' "$sf"
    )
    if [ -n "$role" ]; then
      echo "$role"
      return
    fi
  fi

  heuristic_agent_role "$window_name"
}

resolve_codex_mode() {
  local window_name="$1"
  local sf="$repo_root/projects/$project/memory/manager/sessions.md"
  if [ ! -f "$sf" ]; then
    echo "unknown"
    return
  fi

  local session_id
  session_id=$(
    awk -F'|' -v target="${session}:${window_name}" '
      function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
      trim($5) == target && trim($6) == "active" { sid = trim($4) }
      END { print sid }
    ' "$sf"
  )

  case "$session_id" in
    codex-interactive) echo "interactive" ;;
    codex-exec)        echo "exec" ;;
    *)                 echo "unknown" ;;
  esac
}

deliver_codex_tui_message() {
  local pane_pid
  pane_pid=$(tmux list-panes -t "$tmux_target" -F '#{pane_pid}' 2>/dev/null | head -1)
  if [ -z "$pane_pid" ] || ! pgrep -P "$pane_pid" "codex" >/dev/null 2>&1; then
    return 1
  fi

  tmux_submit_pasted_payload "$tmux_target" "$notification" "notify-codex"
}

deliver_codex_inbox_message() {
  local window_name="$1"
  local message_body="$2"
  local sender="${3:-$from}"
  local codex_role
  codex_role="$(resolve_agent_role "$window_name")"
  [ -n "$codex_role" ] || return 1

  local inbox_dir="$repo_root/projects/$project/memory/${codex_role}/codex-inbox"
  mkdir -p "$inbox_dir"

  local ts suffix tmp_file notify_file
  ts=$(date +%s)
  suffix="${sender}-${window_name}-${RANDOM}"
  tmp_file="${inbox_dir}/.${ts}-${suffix}.notify.tmp"
  notify_file="${inbox_dir}/${ts}-${suffix}.notify"
  printf '%s' "$message_body" > "$tmp_file"
  mv "$tmp_file" "$notify_file"
}

# task_assign / task_complete 시 assignments.md 자동 동기화 (INS-003)
if [[ "$kind" == "task_assign" ]]; then
  record_assignment "$to" "$subject"
elif [[ "$kind" == "task_complete" ]]; then
  complete_assignment "$from"
fi

# 전달 실패 시 큐에 저장
queue_message() {
  local queue_dir="$repo_root/projects/$project/memory/manager/message-queue"
  mkdir -p "$queue_dir"
  local ts suffix tmp_file queue_file
  ts=$(date +%s)
  suffix="${from}-${to}-${RANDOM}"
  tmp_file="${queue_dir}/.${ts}-${suffix}.msg.tmp"
  queue_file="${queue_dir}/${ts}-${suffix}.msg"
  cat > "${tmp_file}" << MSGEOF
from=${from}
to=${to}
kind=${kind}
priority=${priority}
subject=${subject}
content=${content}
MSGEOF
  mv "$tmp_file" "$queue_file"
  python3 "$TOOLS_DIR/log.py" message "$project" "$from" "$to" "$kind" "$priority" "$subject" skipped --reason "queued" || true
  nudge_monitor_for_queue
  echo "메시지 큐 저장: ${queue_file}" >&2
}

nudge_monitor_for_queue() {
  local nudge_file="$repo_root/projects/$project/memory/manager/monitor.nudge"
  local now last=0
  now=$(date +%s)

  if [ -f "$nudge_file" ]; then
    last=$(cat "$nudge_file" 2>/dev/null || echo "0")
  fi
  if ! [[ "${last:-0}" =~ ^[0-9]+$ ]]; then
    last=0
  fi

  mkdir -p "$(dirname "$nudge_file")"
  if [ $((now - last)) -lt 15 ]; then
    return 0
  fi

  printf '%s\n' "$now" > "$nudge_file"
  (
    bash "$TOOLS_DIR/cmd.sh" monitor-check "$project" >/dev/null 2>&1 || true
  ) &
}

# 알림 형식 구성
prefix="[notify] ${from} → ${to} | ${kind}"
if [ "$priority" = "urgent" ]; then
  prefix="[URGENT] ${from} → ${to} | ${kind}"
fi
notification="${prefix}
제목: ${subject}
내용: ${content}"

# 유저 대상 알림: 로그만 기록하고 종료 (tmux 윈도우 없음)
if [[ "$to" == "user" ]]; then
  python3 "$TOOLS_DIR/log.py" message "$project" "$from" "$to" "$kind" "$priority" "$subject" delivered --reason "user-alert" || true
  echo "전달 완료: ${from} → ${to} | ${kind}"
  exit 0
fi

to_backend="$(resolve_backend "$to")"
to_codex_mode="unknown"
if [[ "$to_backend" == "codex" ]]; then
  to_codex_mode="$(resolve_codex_mode "$to")"
fi

# Codex 에이전트:
# - interactive: tmux에서 입력 반영 여부를 확인하면서 제출될 때까지 Enter 반복
# - exec: inbox 파일로 fallback
if [[ "$to_backend" == "codex" ]]; then
  if tmux has-session -t "$session" 2>/dev/null \
    && tmux list-windows -t "$session" -F '#{window_name}' | grep -q "^${to}$" \
    && deliver_codex_tui_message; then
    python3 "$TOOLS_DIR/log.py" message "$project" "$from" "$to" "$kind" "$priority" "$subject" delivered --reason "codex-tui" || true
  elif [[ "$to_codex_mode" == "exec" ]]; then
    # exec 모드는 codex-agent.sh inbox로 전달한다.
    if ! deliver_codex_inbox_message "$to" "$notification" "$from"; then
      echo "Warning: ${to} codex inbox 전달 실패. 큐에 저장." >&2
      queue_message
      echo "전달 보류: ${from} → ${to} | ${kind} (queued)"
      exit 0
    fi
    python3 "$TOOLS_DIR/log.py" message "$project" "$from" "$to" "$kind" "$priority" "$subject" delivered --reason "codex-inbox" || true
  else
    echo "Warning: ${to} codex interactive 직접 전달 실패. 큐에 저장." >&2
    queue_message
    echo "전달 보류: ${from} → ${to} | ${kind} (queued)"
    exit 0
  fi

# Claude Code 에이전트: tmux 직접 전달 (기존 방식)
elif tmux has-session -t "$session" 2>/dev/null; then
  if tmux list-windows -t "$session" -F '#{window_name}' | grep -q "^${to}$"; then
    # 에이전트 프로세스 생존 확인
    pane_pid=$(tmux list-panes -t "$tmux_target" -F '#{pane_pid}' 2>/dev/null | head -1)
    if [ -n "$pane_pid" ] && ! pgrep -P "$pane_pid" "claude" >/dev/null 2>&1 && ! pgrep -P "$pane_pid" "codex" >/dev/null 2>&1; then
      echo "Warning: ${to} 윈도우에 에이전트 프로세스 없음. 큐에 저장." >&2
      queue_message
      echo "전달 보류: ${from} → ${to} | ${kind} (queued)"
      exit 0
    fi

    if tmux_submit_pasted_payload "$tmux_target" "$notification" "notify"; then
      python3 "$TOOLS_DIR/log.py" message "$project" "$from" "$to" "$kind" "$priority" "$subject" delivered || true
    else
      echo "Warning: ${to} tmux target 제출 경로 확보 실패. 큐에 저장." >&2
      queue_message
      echo "전달 보류: ${from} → ${to} | ${kind} (queued)"
      exit 0
    fi
  else
    echo "Warning: ${to} 윈도우가 없다. 큐에 저장." >&2
    queue_message
    echo "전달 보류: ${from} → ${to} | ${kind} (queued)"
    exit 0
  fi
else
  echo "Warning: tmux 세션 '${session}'이 없다. 큐에 저장." >&2
  queue_message
  echo "전달 보류: ${from} → ${to} | ${kind} (queued)"
  exit 0
fi

echo "전달 완료: ${from} → ${to} | ${kind}"
