#!/bin/bash

execution_config_repo_root() {
  local root="${REPO_ROOT:-${repo_root:-}}"
  if [ -n "$root" ]; then
    printf '%s\n' "$root"
    return 0
  fi
  printf '%s\n' "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
}

execution_config_tool() {
  local root
  root="$(execution_config_repo_root)"
  python3 "$root/scripts/execution_config.py" --repo-root "$root" "$@"
}

execution_config_show_json() {
  execution_config_tool show --project "$1" "${@:2}"
}

execution_config_current_preset() {
  execution_config_show_json "$1" | jq -r '.current_preset'
}

execution_config_exec_mode() {
  execution_config_show_json "$1" | jq -r '.exec_mode'
}

execution_config_role_plan_json() {
  local project="$1" role="$2"
  execution_config_show_json "$project" | jq -c --arg role "$role" '.roles[$role]'
}

execution_config_role_window_lines() {
  local project="$1" role="$2"
  execution_config_role_plan_json "$project" "$role" | jq -r '
    .windows[] | "\(.window_name)|\(.backend)|\(.model)"
  '
}

execution_config_role_backend() {
  local project="$1" role="$2"
  execution_config_role_plan_json "$project" "$role" | jq -r '
    if .effective_mode == "dual" then "dual" else .windows[0].backend end
  '
}

execution_config_baseline_role_backend() {
  local project="$1" role="$2"
  execution_config_show_json "$project" | jq -r --arg role "$role" '
    .baseline[$role].solo_backend // empty
  '
}

execution_config_role_model() {
  local project="$1" role="$2" backend="$3"
  execution_config_role_plan_json "$project" "$role" | jq -r --arg backend "$backend" '
    .models[$backend] // empty
  '
}

execution_config_role_runs_dual() {
  local project="$1" role="$2"
  execution_config_role_plan_json "$project" "$role" | jq -r '.effective_mode == "dual"'
}

execution_config_required_backends() {
  execution_config_show_json "$1" "${@:2}" | jq -r '.required_backends[]'
}

execution_config_set_preset() {
  local project="$1" preset="$2"
  execution_config_tool set-preset --project "$project" --preset "$preset"
}

execution_config_set_role_backend() {
  local project="$1" role="$2" backend="$3" scope="${4:-current}"
  execution_config_tool set-role-backend --project "$project" --role "$role" --backend "$backend" --scope "$scope"
}

execution_config_set_role_model() {
  local project="$1" role="$2" backend="$3" model="$4" scope="${5:-current}"
  execution_config_tool set-role-model --project "$project" --role "$role" --backend "$backend" --model "$model" --scope "$scope"
}

execution_config_reset_role() {
  local project="$1" role="$2" scope="${3:-current}"
  execution_config_tool reset-role --project "$project" --role "$role" --scope "$scope"
}
