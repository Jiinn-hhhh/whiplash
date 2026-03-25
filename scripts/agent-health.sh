#!/bin/bash

AGENT_HEALTH_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$AGENT_HEALTH_SCRIPT_DIR/tmux-env.sh"
whiplash_tmux_maybe_activate_from_env

agent_health_state_key() {
  printf 'agent_health_%s\n' "$1"
}

agent_health_detail_key() {
  printf 'agent_health_detail_%s\n' "$1"
}

agent_health_alert_key() {
  printf 'agent_health_alert_%s\n' "$1"
}

runtime_get_agent_health_state() {
  runtime_get_manager_state "$1" "$(agent_health_state_key "$2")" "${3-}"
}

runtime_get_agent_health_detail() {
  runtime_get_manager_state "$1" "$(agent_health_detail_key "$2")" "${3-}"
}

runtime_set_agent_health_state() {
  local project="$1"
  local window_name="$2"
  local state="$3"
  local detail="${4:-}"

  runtime_set_manager_state "$project" "$(agent_health_state_key "$window_name")" "$state"
  if [ -n "$detail" ]; then
    runtime_set_manager_state "$project" "$(agent_health_detail_key "$window_name")" "$detail"
  else
    runtime_clear_manager_state "$project" "$(agent_health_detail_key "$window_name")" || true
  fi
}

runtime_clear_agent_health_state() {
  local project="$1"
  local window_name="$2"
  runtime_clear_manager_state "$project" "$(agent_health_state_key "$window_name")" || true
  runtime_clear_manager_state "$project" "$(agent_health_detail_key "$window_name")" || true
}

runtime_get_agent_health_alert_ts() {
  runtime_get_manager_state "$1" "$(agent_health_alert_key "$2")" "${3-}"
}

runtime_set_agent_health_alert_ts() {
  runtime_set_manager_state "$1" "$(agent_health_alert_key "$2")" "$3"
}

runtime_clear_agent_health_alert_ts() {
  runtime_clear_manager_state "$1" "$(agent_health_alert_key "$2")" || true
}

agent_trim_command_name() {
  printf '%s' "$1" | sed 's#.*/##;s/^[[:space:]]*//;s/[[:space:]]*$//'
}

agent_backend_command_matches() {
  local backend="$1"
  local command_name
  command_name="$(agent_trim_command_name "${2:-}")"
  [ -n "$command_name" ] || return 1

  if [ "$backend" = "codex" ]; then
    [[ "$command_name" == codex* ]]
  else
    [[ "$command_name" == claude* ]]
  fi
}

agent_window_pane_info() {
  local session_name="$1"
  local window_ref="$2"
  tmux list-panes -t "${session_name}:${window_ref}" -F '#{pane_pid}|#{pane_current_command}' 2>/dev/null | head -1
}

agent_window_indices_by_name() {
  local session_name="$1"
  local window_name="$2"
  tmux list-windows -t "$session_name" -F '#I|#{window_name}' 2>/dev/null \
    | awk -F'|' -v target="$window_name" '$2 == target { print $1 }'
}

agent_pane_has_backend_child() {
  local pane_pid="$1"
  local backend="$2"
  local child_pid child_cmd
  [ -n "$pane_pid" ] || return 1

  while IFS= read -r child_pid; do
    [ -n "$child_pid" ] || continue
    child_cmd="$(ps -o comm= -p "$child_pid" 2>/dev/null || true)"
    if agent_backend_command_matches "$backend" "$child_cmd"; then
      return 0
    fi
  done < <(pgrep -P "$pane_pid" 2>/dev/null || true)

  return 1
}

agent_window_has_live_backend() {
  local session_name="$1"
  local window_name="$2"
  local backend="$3"
  local pane_info pane_pid pane_cmd pane_ps_cmd window_idx

  if ! agent_window_indices_by_name "$session_name" "$window_name" | grep -q .; then
    return 1
  fi

  while IFS= read -r window_idx; do
    [ -n "$window_idx" ] || continue
    pane_info="$(agent_window_pane_info "$session_name" "$window_idx")"
    pane_pid="${pane_info%%|*}"
    pane_cmd="${pane_info#*|}"
    [ -n "$pane_pid" ] || continue

    if agent_backend_command_matches "$backend" "$pane_cmd"; then
      return 0
    fi

    pane_ps_cmd="$(ps -o comm= -p "$pane_pid" 2>/dev/null || true)"
    if agent_backend_command_matches "$backend" "$pane_ps_cmd"; then
      return 0
    fi

    if agent_pane_has_backend_child "$pane_pid" "$backend"; then
      return 0
    fi
  done < <(agent_window_indices_by_name "$session_name" "$window_name")

  return 1
}

agent_capture_pane_tail() {
  local session_name="$1"
  local window_name="$2"
  local lines="${3:-60}"
  local window_idx
  window_idx="$(agent_window_indices_by_name "$session_name" "$window_name" | tail -1)"
  [ -n "$window_idx" ] || return 0
  tmux capture-pane -pJ -t "${session_name}:${window_idx}" -S "-${lines}" 2>/dev/null \
    | sed '/^[[:space:]]*$/d' \
    || true
}

agent_pane_requires_claude_login() {
  grep -Eiq 'not logged in|please run /login|run /login|claude auth login|security unlock-keychain'
}

agent_classify_live_window_health() {
  local session_name="$1"
  local window_name="$2"
  local backend="$3"
  local pane_dump

  if [ "$backend" != "claude" ]; then
    printf 'healthy|\n'
    return 0
  fi

  pane_dump="$(agent_capture_pane_tail "$session_name" "$window_name" 60 | tail -n 12 || true)"
  if [ -n "$pane_dump" ] && printf '%s\n' "$pane_dump" | agent_pane_requires_claude_login; then
    printf 'AUTH_BLOCKED|pane-login-required\n'
    return 0
  fi

  printf 'healthy|\n'
}

agent_classify_window_health() {
  local project="$1"
  local session_name="$2"
  local window_name="$3"
  local backend="$4"
  local result state detail

  if ! agent_window_has_live_backend "$session_name" "$window_name" "$backend"; then
    runtime_clear_agent_health_state "$project" "$window_name"
    printf 'offline|backend-offline\n'
    return 0
  fi

  result="$(agent_classify_live_window_health "$session_name" "$window_name" "$backend")"
  state="${result%%|*}"
  detail="${result#*|}"

  if [ "$state" = "AUTH_BLOCKED" ]; then
    runtime_set_agent_health_state "$project" "$window_name" "$state" "$detail"
  else
    runtime_clear_agent_health_state "$project" "$window_name"
  fi

  printf '%s|%s\n' "$state" "$detail"
}

agent_delivery_state() {
  local project="$1"
  local session_name="$2"
  local window_name="$3"
  local backend="$4"
  local result state detail

  result="$(agent_classify_window_health "$project" "$session_name" "$window_name" "$backend")"
  state="${result%%|*}"
  detail="${result#*|}"

  case "$state" in
    healthy)
      printf 'healthy|%s\n' "$detail"
      ;;
    AUTH_BLOCKED)
      printf 'auth-blocked|%s\n' "$detail"
      ;;
    *)
      printf 'offline|%s\n' "$detail"
      ;;
  esac
  return 0
}

claude_cli_auth_state() {
  local auth_json logged_in

  if ! command -v claude >/dev/null 2>&1; then
    printf 'unknown\n'
    return 1
  fi

  auth_json="$(env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT claude auth status 2>/dev/null || true)"
  logged_in="$(printf '%s' "$auth_json" | jq -r '.loggedIn // ""' 2>/dev/null || true)"

  case "$logged_in" in
    true)
      printf 'ok\n'
      ;;
    false)
      printf 'blocked\n'
      ;;
    *)
      printf 'unknown\n'
      ;;
  esac
}

claude_recovery_blocked() {
  local project="$1"
  local session_name="$2"
  local window_name="$3"
  local result state auth_state

  result="$(agent_classify_window_health "$project" "$session_name" "$window_name" "claude")"
  state="${result%%|*}"
  if [ "$state" = "AUTH_BLOCKED" ]; then
    return 0
  fi

  auth_state="$(claude_cli_auth_state)"
  if [ "$auth_state" = "blocked" ]; then
    runtime_set_agent_health_state "$project" "$window_name" "AUTH_BLOCKED" "claude-auth-status"
    return 0
  fi

  return 1
}
