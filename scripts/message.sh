#!/bin/bash
# message.sh -- tmux 직접 전달 방식의 에이전트 간 알림
#
# 모든 메시지는 같은 interactive 전달 엔진을 쓴다.
# 차이는 라우팅과 후처리(assignments/log/mirror)뿐이다.

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
  task_complete|status_update|need_input|escalation|agent_ready|reboot_notice|consensus_request|consensus_response|alert_resolve|task_assign) ;;
  *)
    echo "Error: 잘못된 kind: $kind" >&2
    echo "허용: task_complete, status_update, need_input, escalation, agent_ready, reboot_notice, consensus_request, consensus_response, alert_resolve, task_assign" >&2
    exit 1
    ;;
esac

# priority 검증
case "$priority" in
  normal|urgent) ;;
  *)
    echo "Error: 잘못된 priority: $priority (허용: normal, urgent)" >&2
    exit 1
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOLS_DIR="$SCRIPT_DIR"
session="whiplash-${project}"

# shellcheck source=/dev/null
source "$TOOLS_DIR/tmux-submit.sh"
# shellcheck source=/dev/null
source "$TOOLS_DIR/runtime-paths.sh"

lock_held=0
lock_target=""
task_assign_report_rel=""
task_complete_report_rel=""

release_target_lock() {
  if [ "$lock_held" -eq 1 ] && [ -n "$lock_target" ]; then
    runtime_release_message_target_lock "$project" "$lock_target" || true
    lock_held=0
  fi
}

cleanup_on_exit() {
  release_target_lock
}

trap cleanup_on_exit EXIT

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

get_active_task_ref() {
  local agent="$1"
  local af
  af="$(assignments_file)"
  [ -f "$af" ] || return 0
  { grep "| ${agent} |" "$af" 2>/dev/null || true; } \
    | grep "| active |" \
    | tail -1 \
    | awk -F'|' '{print $3}' \
    | sed 's/^ *//;s/ *$//' || true
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

prepare_task_assign_report_stub() {
  if [ "$kind" != "task_assign" ]; then
    return 0
  fi
  local normalized_task
  normalized_task="$(normalize_task_ref "$subject")"
  task_assign_report_rel="$(runtime_write_task_report_stub "$project" "$normalized_task" "$to" "manager")"
}

validate_task_complete_report() {
  if [ "$kind" != "task_complete" ] || [ "$to" != "manager" ] || [ "$from" = "manager" ]; then
    return 0
  fi

  local active_task report_path
  active_task="$(get_active_task_ref "$from")"
  if [ -z "$active_task" ]; then
    echo "Error: task_complete 전에 active assignment를 찾을 수 없다: ${from}" >&2
    exit 1
  fi

  report_path="$(runtime_task_report_path "$project" "$active_task" "$from")"
  task_complete_report_rel="$(runtime_project_relative_path "$project" "$report_path")"

  if [ ! -f "$report_path" ]; then
    echo "Error: task_complete 전에 결과 보고서가 필요하다: ${task_complete_report_rel}" >&2
    exit 1
  fi

  if ! grep -Eq '^- \*\*Status\*\*: final([[:space:]]*)$' "$report_path"; then
    echo "Error: 결과 보고서 Status가 final이어야 한다: ${task_complete_report_rel}" >&2
    exit 1
  fi

  if grep -q "작성 필요" "$report_path" 2>/dev/null; then
    echo "Error: 결과 보고서에 미완성 placeholder가 남아 있다: ${task_complete_report_rel}" >&2
    exit 1
  fi
}

augment_content_with_report_context() {
  if [ "$kind" = "task_assign" ] && [ -n "$task_assign_report_rel" ] && [[ "$content" != *"$task_assign_report_rel"* ]]; then
    content="${content} 결과 보고서는 ${task_assign_report_rel}에 작성하고 완료 전 Status를 final로 바꿔라."
  fi

  if [ "$kind" = "task_complete" ] && [ -n "$task_complete_report_rel" ] && [[ "$content" != *"$task_complete_report_rel"* ]]; then
    content="${content} | 보고서: ${task_complete_report_rel}"
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

target_window_exists() {
  tmux has-session -t "$session" 2>/dev/null \
    && tmux list-windows -t "$session" -F '#{window_name}' 2>/dev/null | grep -q "^${1}$"
}

target_has_live_agent() {
  local window_name="$1"
  local tmux_target="${session}:${window_name}"
  target_window_exists "$window_name" || return 1

  local pane_pid backend
  pane_pid=$(tmux list-panes -t "$tmux_target" -F '#{pane_pid}' 2>/dev/null | head -1)
  [ -n "$pane_pid" ] || return 1
  backend="$(resolve_backend "$window_name")"
  if [ "$backend" = "codex" ]; then
    pgrep -P "$pane_pid" codex >/dev/null 2>&1
  else
    pgrep -P "$pane_pid" claude >/dev/null 2>&1
  fi
}

build_notification() {
  local msg_from="$1"
  local msg_to="$2"
  local msg_kind="$3"
  local msg_priority="$4"
  local msg_subject="$5"
  local msg_content="$6"
  local flat_subject flat_content
  local prefix="[notify] ${msg_from} → ${msg_to} | ${msg_kind}"
  if [ "$msg_priority" = "urgent" ]; then
    prefix="[URGENT] ${msg_from} → ${msg_to} | ${msg_kind}"
  fi
  flat_subject="$(printf '%s' "$msg_subject" | tr '\r\n' '  ')"
  flat_content="$(printf '%s' "$msg_content" | tr '\r\n' '  ')"
  printf '%s' "${prefix} | 제목: ${flat_subject} | 내용: ${flat_content}"
}

validate_routing() {
  if [ "$kind" = "task_assign" ] && [ "$from" != "manager" ]; then
    echo "Error: task_assign는 manager만 보낼 수 있다." >&2
    exit 1
  fi

  if [ "$kind" = "task_complete" ] && [ "$to" != "manager" ]; then
    echo "Error: task_complete는 manager에게만 보낼 수 있다." >&2
    exit 1
  fi

  if [ "$kind" = "agent_ready" ] && [ "$to" != "manager" ]; then
    echo "Error: agent_ready는 manager에게만 보낼 수 있다." >&2
    exit 1
  fi

  if [ "$kind" = "reboot_notice" ] && [ "$to" != "manager" ]; then
    echo "Error: reboot_notice는 manager에게만 보낼 수 있다." >&2
    exit 1
  fi

  if [ "$to" != "manager" ] && [ "$to" != "user" ]; then
    case "$kind" in
      task_assign|status_update|need_input|escalation|consensus_request|consensus_response) ;;
      *)
        echo "Error: ${kind}는 peer/worker 대상 직접 전송을 지원하지 않는다." >&2
        exit 1
        ;;
    esac
  fi
}

queue_message() {
  ensure_manager_runtime_layout "$project"
  local queue_dir
  queue_dir="$(runtime_message_queue_dir "$project")"
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
  ensure_manager_runtime_layout "$project"
  local now last=0
  now=$(date +%s)

  last="$(runtime_get_manager_state "$project" "monitor_nudge_ts" "0" 2>/dev/null || echo "0")"
  if ! [[ "${last:-0}" =~ ^[0-9]+$ ]]; then
    last=0
  fi

  if [ $((now - last)) -lt 15 ]; then
    return 0
  fi

  runtime_set_manager_state "$project" "monitor_nudge_ts" "$now" || true
  (
    bash "$TOOLS_DIR/cmd.sh" monitor-check "$project" >/dev/null 2>&1 || true
  ) &
}

target_has_pending_queue() {
  local target="$1"
  local queue_dir msg_file
  queue_dir="$(runtime_message_queue_dir "$project")"
  [ -d "$queue_dir" ] || return 1
  for msg_file in "$queue_dir"/*.msg; do
    [ -f "$msg_file" ] || continue
    if grep -q "^to=${target}$" "$msg_file" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

maybe_refresh_target() {
  local target="$1"
  if [ "$target" = "manager" ] || [ "$target" = "user" ]; then
    return 1
  fi

  ensure_manager_runtime_layout "$project"
  local now last_refresh
  now=$(date +%s)
  last_refresh="$(runtime_get_message_refresh_ts "$project" "$target" "" 2>/dev/null || true)"
  if [[ "${last_refresh:-}" =~ ^[0-9]+$ ]] && [ $((now - last_refresh)) -lt 60 ]; then
    return 1
  fi

  runtime_set_message_refresh_ts "$project" "$target" "$now" || true
  WHIPLASH_REFRESH_HANDOFF_WAIT_SECONDS=0 \
  WHIPLASH_REFRESH_SKIP_HANDOFF_REQUEST=1 \
  bash "$TOOLS_DIR/cmd.sh" refresh "$target" "$project" >/dev/null 2>&1 || return 1
  sleep 5
}

submit_notification() {
  local target="$1"
  local notification="$2"
  local tmux_target="${session}:${target}"
  local attempt

  for attempt in 1 2; do
    if tmux_submit_pasted_payload "$tmux_target" "$notification" "notify"; then
      runtime_clear_message_refresh_ts "$project" "$target" || true
      return 0
    fi
    sleep 1
  done

  if maybe_refresh_target "$target" && target_has_live_agent "$target"; then
    if tmux_submit_pasted_payload "$tmux_target" "$notification" "notify-refresh"; then
      runtime_clear_message_refresh_ts "$project" "$target" || true
      return 0
    fi
  fi

  return 1
}

mirror_peer_message_to_manager() {
  if [ "${WHIPLASH_MESSAGE_SKIP_MIRROR:-0}" = "1" ]; then
    return 0
  fi

  if [ "$to" = "manager" ] || [ "$to" = "user" ]; then
    return 0
  fi

  if [ "$from" = "manager" ]; then
    return 0
  fi

  local mirror_content
  mirror_content="[peer mirror] 원수신자: ${to} | ${content}"
  WHIPLASH_MESSAGE_SKIP_MIRROR=1 \
  WHIPLASH_MESSAGE_SKIP_BOOKKEEPING=1 \
  bash "$TOOLS_DIR/message.sh" "$project" "$from" manager "$kind" "$priority" "$subject" "$mirror_content" >/dev/null 2>&1 || true
}

queue_with_optional_mirror() {
  queue_message
  mirror_peer_message_to_manager
  echo "전달 보류: ${from} → ${to} | ${kind} (queued)"
}

apply_bookkeeping() {
  if [ "${WHIPLASH_MESSAGE_SKIP_BOOKKEEPING:-0}" = "1" ]; then
    return 0
  fi

  case "$kind" in
    task_assign)
      record_assignment "$to" "$subject"
      ;;
    task_complete)
      if [ "$to" = "manager" ]; then
        complete_assignment "$from"
      fi
      ;;
  esac
}

validate_routing
prepare_task_assign_report_stub
validate_task_complete_report
apply_bookkeeping
augment_content_with_report_context

if [[ "$to" == "user" ]]; then
  python3 "$TOOLS_DIR/log.py" message "$project" "$from" "$to" "$kind" "$priority" "$subject" delivered --reason "user-alert" || true
  echo "전달 완료: ${from} → ${to} | ${kind}"
  exit 0
fi

if target_has_pending_queue "$to"; then
  queue_with_optional_mirror
  exit 0
fi

if ! runtime_claim_message_target_lock "$project" "$to"; then
  queue_with_optional_mirror
  exit 0
fi
lock_held=1
lock_target="$to"

notification="$(build_notification "$from" "$to" "$kind" "$priority" "$subject" "$content")"

if ! target_has_live_agent "$to"; then
  queue_with_optional_mirror
  exit 0
fi

if submit_notification "$to" "$notification"; then
  python3 "$TOOLS_DIR/log.py" message "$project" "$from" "$to" "$kind" "$priority" "$subject" delivered --reason "interactive" || true
  mirror_peer_message_to_manager
  echo "전달 완료: ${from} → ${to} | ${kind}"
  exit 0
fi

queue_with_optional_mirror
