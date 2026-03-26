#!/bin/bash

whiplash_tmux_socket_name() {
  local project="${1:-}"
  if [ -z "$project" ]; then
    printf '\n'
    return 0
  fi

  project="$(printf '%s' "$project" | tr '[:space:]' '-' | tr -cd '[:alnum:]_.-')"
  if [ -z "$project" ]; then
    project="whiplash"
  fi

  printf '%s\n' "$project"
}

whiplash_activate_tmux_project() {
  local project="${1:-}"
  if [ -z "$project" ]; then
    unset WHIPLASH_TMUX_PROJECT
    unset WHIPLASH_TMUX_SOCKET_NAME
    return 0
  fi

  export WHIPLASH_TMUX_PROJECT="$project"
  export WHIPLASH_TMUX_SOCKET_NAME
  WHIPLASH_TMUX_SOCKET_NAME="$(whiplash_tmux_socket_name "$project")"
  unset TMUX
}

whiplash_tmux_maybe_activate_from_env() {
  if [ -z "${WHIPLASH_TMUX_SOCKET_NAME:-}" ] && [ -n "${WHIPLASH_TMUX_PROJECT:-}" ]; then
    whiplash_activate_tmux_project "$WHIPLASH_TMUX_PROJECT"
  fi
}

whiplash_tmux_attach_command() {
  local session_name="$1"
  printf 'tmux attach -t %s\n' "$session_name"
}

# 이하 3개 함수: 864de78에서 소켓 격리 제거 후 모두 `command tmux "$@"` 동일.
# integration-test.sh 등에서 호출하므로 시그니처 유지. 첫 파라미터는 하위 호환용(무시).

whiplash_tmux_run_on_socket() {
  shift  # socket_name (legacy, 무시)
  command tmux "$@"
}

whiplash_tmux_run_default() {
  command tmux "$@"
}

whiplash_tmux_run_for_project() {
  shift  # project (legacy, 무시)
  command tmux "$@"
}

tmux() {
  command tmux "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  subcommand="${1:-}"
  case "$subcommand" in
    socket-name)
      whiplash_tmux_socket_name "${2:-}"
      ;;
    attach-command)
      whiplash_tmux_attach_command "${2:-}" "${3:-}"
      ;;
    *)
      echo "Usage: tmux-env.sh {socket-name <project>|attach-command <session> [socket]}" >&2
      exit 1
      ;;
  esac
fi
