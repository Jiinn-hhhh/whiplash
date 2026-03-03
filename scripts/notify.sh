#!/bin/bash
# notify.sh -- tmux 직접 전달 방식의 에이전트 간 알림
#
# 수신자의 tmux 윈도우에 직접 전달한다.
# tmux load-buffer + paste-buffer로 안정적인 멀티라인 전달.
#
# Usage:
#   notify.sh {project} {from} {to} {kind} {priority} {subject} {content}
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
  echo "Usage: notify.sh {project} {from} {to} {kind} {priority} {subject} {content}" >&2
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
  task_complete|status_update|need_input|escalation|agent_ready|reboot_notice|consensus_request) ;;
  *) echo "Error: 잘못된 kind: $kind" >&2
     echo "허용: task_complete, status_update, need_input, escalation, agent_ready, reboot_notice, consensus_request" >&2
     exit 1 ;;
esac

# priority 검증
case "$priority" in
  normal|urgent) ;;
  *) echo "Error: 잘못된 priority: $priority (허용: normal, urgent)" >&2
     exit 1 ;;
esac

repo_root="$(git rev-parse --show-toplevel)"
TOOLS_DIR="$repo_root/scripts"
session="whiplash-${project}"
tmux_target="${session}:${to}"

# 알림 형식 구성
prefix="[notify] ${from} → ${to} | ${kind}"
if [ "$priority" = "urgent" ]; then
  prefix="[URGENT] ${from} → ${to} | ${kind}"
fi
notification="${prefix}
제목: ${subject}
내용: ${content}"

# tmux 직접 전달 (fire-and-forget)
if tmux has-session -t "$session" 2>/dev/null; then
  if tmux list-windows -t "$session" -F '#{window_name}' | grep -q "^${to}$"; then
    # claude 프로세스 생존 확인
    pane_pid=$(tmux list-panes -t "$tmux_target" -F '#{pane_pid}' 2>/dev/null | head -1)
    if [ -n "$pane_pid" ] && ! pgrep -P "$pane_pid" claude >/dev/null 2>&1; then
      echo "Warning: ${to} 윈도우에 claude 프로세스 없음. 전달 건너뜀." >&2
      python3 "$TOOLS_DIR/log.py" message "$project" "$from" "$to" "$kind" "$priority" "$subject" skipped --reason "no claude process" || true
      exit 0
    fi

    tmpfile=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$tmpfile'" EXIT
    printf '%s' "$notification" > "$tmpfile"
    # 고유 버퍼 이름으로 동시 실행 시 경합 방지
    buf_name="notify-$$-${RANDOM}"
    if ! tmux load-buffer -b "$buf_name" "$tmpfile" 2>/dev/null; then
      echo "Warning: tmux load-buffer 실패. 전달 건너뜀." >&2
      rm -f "$tmpfile"
      trap - EXIT
      exit 1
    fi
    if ! tmux paste-buffer -b "$buf_name" -t "$tmux_target" -d 2>/dev/null; then
      echo "Warning: tmux paste-buffer 실패. 전달 건너뜀." >&2
      tmux delete-buffer -b "$buf_name" 2>/dev/null || true
      rm -f "$tmpfile"
      trap - EXIT
      exit 1
    fi
    if ! tmux send-keys -t "$tmux_target" Enter 2>/dev/null; then
      echo "Warning: tmux send-keys 실패." >&2
    fi
    rm -f "$tmpfile"
    trap - EXIT
    python3 "$TOOLS_DIR/log.py" message "$project" "$from" "$to" "$kind" "$priority" "$subject" delivered || true
  else
    echo "Warning: ${to} 윈도우가 없다. 알림 전달 건너뜀." >&2
    python3 "$TOOLS_DIR/log.py" message "$project" "$from" "$to" "$kind" "$priority" "$subject" skipped --reason "no window" || true
  fi
else
  echo "Warning: tmux 세션 '${session}'이 없다. 알림 전달 건너뜀." >&2
  python3 "$TOOLS_DIR/log.py" message "$project" "$from" "$to" "$kind" "$priority" "$subject" skipped --reason "no session" || true
fi

echo "전달 완료: ${from} → ${to} | ${kind}"
