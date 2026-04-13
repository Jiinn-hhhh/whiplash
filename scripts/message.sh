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

# project 이름 검증 (경로 트래버설, 쉘/정규식 메타문자 방지)
if [ -z "$project" ] || [[ "$project" =~ [^a-zA-Z0-9_-] ]]; then
  echo "Error: 잘못된 project 이름: $project (영문/숫자/하이픈/밑줄만 허용)" >&2
  exit 1
fi

# from 검증 (빈값, 경로 트래버설, 쉘 메타문자 방지)
if [ -z "$from" ]; then
  echo "Error: from이 비어 있다." >&2
  exit 1
fi
if [[ "$from" == */* ]] || [[ "$from" == *..* ]] || [[ "$from" =~ [^a-zA-Z0-9_-] ]]; then
  echo "Error: 잘못된 from: $from (영문/숫자/하이픈/밑줄만 허용)" >&2
  exit 1
fi

# to 검증
if [ -z "$to" ]; then
  echo "Error: to가 비어 있다." >&2
  exit 1
fi
if [[ "$to" == */* ]] || [[ "$to" == *..* ]] || [[ "$to" =~ [^a-zA-Z0-9_-] ]]; then
  echo "Error: 잘못된 to: $to (영문/숫자/하이픈/밑줄만 허용)" >&2
  exit 1
fi

# subject 검증 (빈값 방지)
if [ -z "$subject" ]; then
  echo "Error: subject가 비어 있다." >&2
  exit 1
fi

# kind 검증
case "$kind" in
  task_complete|status_update|need_input|escalation|agent_ready|reboot_notice|consensus_request|consensus_response|alert_resolve|task_assign|user_notice) ;;
  *)
    echo "Error: 잘못된 kind: $kind" >&2
    echo "허용: task_complete, status_update, need_input, escalation, agent_ready, reboot_notice, consensus_request, consensus_response, alert_resolve, task_assign, user_notice" >&2
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
REPO_ROOT="$repo_root"
export REPO_ROOT
TOOLS_DIR="$SCRIPT_DIR"
session="whiplash-${project}"

# shellcheck source=/dev/null
source "$TOOLS_DIR/tmux-env.sh"
# shellcheck source=/dev/null
source "$TOOLS_DIR/tmux-submit.sh"
# shellcheck source=/dev/null
source "$TOOLS_DIR/runtime-paths.sh"
# shellcheck source=/dev/null
source "$TOOLS_DIR/assignment-state.sh"
# shellcheck source=/dev/null
source "$TOOLS_DIR/agent-health.sh"
# shellcheck source=/dev/null
source "$TOOLS_DIR/notify-format.sh"
# shellcheck source=/dev/null
source "$TOOLS_DIR/execution-config.sh"

whiplash_activate_tmux_project "$project"

lock_held=0
lock_target=""

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
  assignments_file_for_project "$project"
}

project_md_path() {
  echo "$repo_root/projects/$project/project.md"
}

get_loop_mode() {
  local project_md mode
  project_md="$(project_md_path)"
  mode=$({ grep -i "작업 루프" "$project_md" 2>/dev/null || true; } \
    | head -1 \
    | sed 's/.*: *//' \
    | sed 's/ *(.*)//' \
    | tr -d '[:space:]' \
    | tr -d '*|' \
    | tr '[:upper:]' '[:lower:]')
  if [ "$mode" = "ralph" ]; then
    echo "ralph"
  else
    echo "guided"
  fi
}

normalize_task_ref() {
  normalize_assignment_task_ref "$project" "$1"
}

# assignment-state.sh의 잠금+awk 기반 함수를 사용하는 래퍼
get_active_task_ref() {
  get_active_task_ref_for_project "$project" "$1"
}

record_assignment() {
  record_assignment_for_project "$project" "$1" "$2"
}

complete_assignment() {
  complete_assignment_for_project "$project" "$1"
}

is_execution_lead_task_assign_target() {
  case "$1" in
    developer|developer-claude|developer-codex|researcher|researcher-claude|researcher-codex|systems-engineer)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

discussion_handoff_file() {
  printf '%s/projects/%s/memory/discussion/handoff.md\n' "$repo_root" "$project"
}

section_has_body() {
  local file="$1"
  local heading="$2"
  awk -v heading="$heading" '
    $0 == heading { in_section = 1; next }
    in_section && /^## / { exit found ? 0 : 1 }
    in_section && $0 !~ /^[[:space:]]*$/ { found = 1 }
    END {
      if (!in_section) exit 1
      exit found ? 0 : 1
    }
  ' "$file"
}

is_discussion_handoff_notification() {
  [ "$from" = "discussion" ] || return 1
  [ "$to" = "manager" ] || return 1
  [ "$kind" = "status_update" ] || return 1
  [[ "$content" == *"memory/discussion/handoff.md"* ]]
}

validate_discussion_handoff_contract() {
  if ! is_discussion_handoff_notification; then
    return 0
  fi

  local handoff_file handoff_rel
  handoff_file="$(discussion_handoff_file)"
  handoff_rel="$(runtime_project_relative_path "$project" "$handoff_file")"

  if [ ! -f "$handoff_file" ]; then
    echo "Error: discussion handoff 알림 전 handoff 문서가 필요하다: ${handoff_rel}" >&2
    exit 1
  fi

  if ! grep -Eiq 'User approved.*yes' "$handoff_file"; then
    echo "Error: discussion handoff는 'User approved: yes'가 필요하다: ${handoff_rel}" >&2
    exit 1
  fi

  if ! section_has_body "$handoff_file" "## Manager next action"; then
    echo "Error: discussion handoff에 '## Manager next action' 본문이 필요하다: ${handoff_rel}" >&2
    exit 1
  fi

  if grep -q "작성 필요" "$handoff_file" 2>/dev/null; then
    echo "Error: discussion handoff에 미완성 placeholder가 남아 있다: ${handoff_rel}" >&2
    exit 1
  fi
}

augment_content_with_report_context() {
  if [ "$kind" = "task_assign" ] && is_execution_lead_task_assign_target "$to"; then
    content="${content} [kickoff reminder] 비사소한 작업이면 specialist 최소 1개, 복잡한 작업이면 2-way 이상 병렬 fan-out을 기본값으로 잡아라. specialist별 기본 모델/effort tier도 설정돼 있으니 난이도에 맞게 override를 고려해라. 어떤 specialist를 부를지는 네가 판단해라."
  fi
}

resolve_backend() {
  local window_name="$1"
  case "$window_name" in
    *-codex|*-codex-*)
      echo "codex"
      return
      ;;
    *-claude|*-claude-*)
      echo "claude"
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

  case "$window_name" in
    onboarding|manager|discussion|developer|researcher|systems-engineer|monitoring)
      local backend
      backend="$(execution_config_role_backend "$project" "$window_name" 2>/dev/null || true)"
      if [ "$backend" = "claude" ] || [ "$backend" = "codex" ]; then
        echo "$backend"
        return
      fi
      ;;
  esac

  echo "claude"
}

target_window_exists() {
  tmux has-session -t "$session" 2>/dev/null \
    && tmux list-windows -t "$session" -F '#{window_name}' 2>/dev/null | grep -q "^${1}$"
}

process_or_child_named() {
  local pid="$1"
  local process_name="$2"
  [ -n "$pid" ] || return 1

  local comm=""
  comm="$(ps -p "$pid" -o comm= 2>/dev/null | awk '{print $1}' | sed 's!.*/!!' | head -1 || true)"
  if [ "$comm" = "$process_name" ]; then
    return 0
  fi

  pgrep -P "$pid" "$process_name" >/dev/null 2>&1
}

target_has_live_agent() {
  local window_name="$1"
  target_window_exists "$window_name" || return 1

  local backend
  backend="$(resolve_backend "$window_name")"
  agent_window_has_live_backend "$session" "$window_name" "$backend"
}

target_delivery_state() {
  local window_name="$1"
  local backend
  backend="$(resolve_backend "$window_name")"
  agent_delivery_state "$project" "$session" "$window_name" "$backend"
}

# build_notification은 notify-format.sh에서 제공 (source는 파일 상단에서)

validate_routing() {
  if [ "$kind" = "task_assign" ] && [ "$from" != "manager" ]; then
    echo "Error: task_assign는 manager만 보낼 수 있다." >&2
    exit 1
  fi

  if [ "$kind" = "user_notice" ] && { [ "$from" != "manager" ] || [ "$to" != "user" ]; }; then
    echo "Error: user_notice는 manager → user 전송만 허용된다." >&2
    exit 1
  fi

  if [ "$kind" = "task_complete" ] && [ "$to" != "manager" ]; then
    echo "Error: task_complete는 manager에게만 보낼 수 있다." >&2
    exit 1
  fi

  if [ "$kind" = "agent_ready" ] && [ "$to" != "manager" ] && [ "$to" != "user" ] && [ "$to" != "onboarding" ]; then
    echo "Error: agent_ready는 manager, onboarding 또는 user에게만 보낼 수 있다." >&2
    exit 1
  fi

  if [ "$kind" = "reboot_notice" ] && [ "$to" != "manager" ]; then
    echo "Error: reboot_notice는 manager에게만 보낼 수 있다." >&2
    exit 1
  fi

  if [ "$to" != "manager" ] && [ "$to" != "user" ]; then
    case "$kind" in
      task_assign|status_update|need_input|escalation|consensus_request|consensus_response) ;;
      agent_ready)
        if [ "$to" != "onboarding" ]; then
          echo "Error: agent_ready의 peer direct 대상은 onboarding만 허용된다." >&2
          exit 1
        fi
        ;;
      *)
        echo "Error: ${kind}는 peer/worker 대상 직접 전송을 지원하지 않는다." >&2
        exit 1
        ;;
    esac
  fi

  if [ "$(get_loop_mode)" = "ralph" ] && [ "$from" = "manager" ] && [ "$to" = "user" ]; then
    case "$kind" in
      need_input|escalation)
        echo "Error: ralph loop에서는 manager → user need_input/escalation을 보낼 수 없다. user_notice를 사용해라." >&2
        exit 1
        ;;
    esac
  fi
}

log_delivery_failure() {
  local reason="$1"
  python3 "$TOOLS_DIR/log.py" message "$project" "$from" "$to" "$kind" "$priority" "$subject" skipped --reason "$reason" || true
  echo "전달 실패: ${from} → ${to} | ${kind} (${reason})" >&2
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
  local attempt delivery_state

  for attempt in 1 2; do
    if tmux_submit_pasted_payload "$tmux_target" "$notification" "notify"; then
      runtime_clear_message_refresh_ts "$project" "$target" || true
      return 0
    fi
    sleep 1
  done

  delivery_state="$(target_delivery_state "$target")"
  if [ "${delivery_state%%|*}" = "healthy" ] && maybe_refresh_target "$target"; then
    delivery_state="$(target_delivery_state "$target")"
    if [ "${delivery_state%%|*}" != "healthy" ]; then
      return 1
    fi
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

  local project_stage
  project_stage="$(runtime_get_manager_state "$project" "project_stage" "active" 2>/dev/null || echo "active")"
  if [ "$project_stage" = "onboarding" ]; then
    return 0
  fi

  local mirror_content
  mirror_content="[peer mirror] 원수신자: ${to} | ${content}"
  WHIPLASH_MESSAGE_SKIP_MIRROR=1 \
  WHIPLASH_MESSAGE_SKIP_BOOKKEEPING=1 \
  bash "$TOOLS_DIR/message.sh" "$project" "$from" manager "$kind" "$priority" "$subject" "$mirror_content" >/dev/null 2>&1 || true
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
validate_discussion_handoff_contract
augment_content_with_report_context

if [ "$kind" = "user_notice" ] || { [ "$kind" = "status_update" ] && { [ "$to" = "manager" ] || [ "$to" = "user" ]; }; }; then
  subject="$(whiplash_notification_subject "$kind" "$subject")"
  content="$(whiplash_notification_body "$kind" "$subject" "$content")"
fi

if [[ "$to" == "user" ]]; then
  apply_bookkeeping
  python3 "$TOOLS_DIR/log.py" message "$project" "$from" "$to" "$kind" "$priority" "$subject" delivered --reason "user-alert" || true
  echo "전달 완료: ${from} → ${to} | ${kind}"
  exit 0
fi

if ! runtime_claim_message_target_lock "$project" "$to"; then
  log_delivery_failure "lock-held"
  exit 1
fi
lock_held=1
lock_target="$to"

notification="$(build_notification "$from" "$to" "$kind" "$priority" "$subject" "$content")"

delivery_state="$(target_delivery_state "$to")"
case "${delivery_state%%|*}" in
  healthy)
    ;;
  *)
    log_delivery_failure "unhealthy-${delivery_state%%|*}"
    exit 1
    ;;
esac

if ! target_has_live_agent "$to"; then
  log_delivery_failure "no-live-agent"
  exit 1
fi

if submit_notification "$to" "$notification"; then
  apply_bookkeeping
  python3 "$TOOLS_DIR/log.py" message "$project" "$from" "$to" "$kind" "$priority" "$subject" delivered --reason "interactive" || true
  mirror_peer_message_to_manager
  echo "전달 완료: ${from} → ${to} | ${kind}"
  exit 0
fi

log_delivery_failure "tmux-submit-failed"
exit 1
