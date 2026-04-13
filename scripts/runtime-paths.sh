#!/bin/bash
# runtime-paths.sh -- 프로젝트별 런타임 상태 파일 경로/상태 헬퍼

runtime_paths_repo_root() {
  if [ -n "${REPO_ROOT:-}" ]; then
    printf '%s\n' "$REPO_ROOT"
    return
  fi
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s\n' "$(cd "$script_dir/.." && pwd)"
}

runtime_project_dir() {
  printf '%s/projects/%s\n' "$(runtime_paths_repo_root)" "$1"
}

runtime_root_dir() {
  printf '%s/runtime\n' "$(runtime_project_dir "$1")"
}

runtime_reports_dir() {
  printf '%s/reports\n' "$(runtime_project_dir "$1")"
}

runtime_task_reports_dir() {
  printf '%s/tasks\n' "$(runtime_reports_dir "$1")"
}

runtime_project_relative_path() {
  local project="$1"
  local path="$2"
  local project_dir
  project_dir="$(runtime_project_dir "$project")"
  if [[ "$path" == "$project_dir/"* ]]; then
    printf '%s\n' "${path#"$project_dir"/}"
  else
    printf '%s\n' "$path"
  fi
}

runtime_task_report_key() {
  local task_ref="$1"
  local base hash
  base="${task_ref##*/}"
  base="${base%.*}"
  base="$(printf '%s' "$base" | tr '[:space:]' '-' | tr -cd '[:alnum:]._-')"
  if [ -z "$base" ]; then
    hash="$(printf '%s' "$task_ref" | cksum | awk '{print $1}')"
    base="task-${hash}"
  fi
  if [ "${#base}" -gt 80 ]; then
    hash="$(printf '%s' "$task_ref" | cksum | awk '{print $1}')"
    base="${base:0:40}-${hash}"
  fi
  printf '%s\n' "$base"
}

runtime_report_author_key() {
  local author="$1"
  author="$(printf '%s' "$author" | tr '[:space:]' '-' | tr -cd '[:alnum:]._-')"
  if [ -z "$author" ]; then
    author="agent"
  fi
  printf '%s\n' "$author"
}

runtime_task_report_path() {
  local project="$1"
  local task_ref="$2"
  local author="$3"
  printf '%s/%s-%s.md\n' \
    "$(runtime_task_reports_dir "$project")" \
    "$(runtime_task_report_key "$task_ref")" \
    "$(runtime_report_author_key "$author")"
}

runtime_manager_state_file() {
  printf '%s/manager-state.tsv\n' "$(runtime_root_dir "$1")"
}

runtime_reboot_state_file() {
  printf '%s/reboot-state.tsv\n' "$(runtime_root_dir "$1")"
}

runtime_idle_state_file() {
  printf '%s/idle-state.tsv\n' "$(runtime_root_dir "$1")"
}

runtime_waiting_state_file() {
  printf '%s/waiting-state.tsv\n' "$(runtime_root_dir "$1")"
}

runtime_message_lock_dir() {
  printf '%s/message-locks\n' "$(runtime_root_dir "$1")"
}

runtime_message_target_lock_path() {
  printf '%s/%s\n' "$(runtime_message_lock_dir "$1")" "$2"
}

runtime_manager_dir() {
  printf '%s/manager\n' "$(runtime_root_dir "$1")"
}

legacy_manager_memory_dir() {
  printf '%s/memory/manager\n' "$(runtime_project_dir "$1")"
}

runtime_lock_dir() {
  printf '%s.lockdir\n' "$1"
}

runtime_acquire_path_lock() {
  local target_path="$1"
  local lock_dir holder_file holder_pid holder_ts start_ts now_ts
  lock_dir="$(runtime_lock_dir "$target_path")"
  holder_file="${lock_dir}/meta"
  mkdir -p "$(dirname "$lock_dir")"
  start_ts=$(date +%s)

  while ! mkdir "$lock_dir" 2>/dev/null; do
    now_ts=$(date +%s)
    if [ -f "$holder_file" ]; then
      holder_pid=$(sed -n '1p' "$holder_file" 2>/dev/null || true)
      holder_ts=$(sed -n '2p' "$holder_file" 2>/dev/null || true)
      if ! [[ "${holder_pid:-}" =~ ^[0-9]+$ ]] || ! kill -0 "$holder_pid" 2>/dev/null; then
        # M-07: stale lock 제거 후 즉시 재시도 (TOCTOU 창 최소화)
        rm -rf "$lock_dir" 2>/dev/null || true
        if mkdir "$lock_dir" 2>/dev/null; then break; fi
        continue
      fi
      if [[ "${holder_ts:-}" =~ ^[0-9]+$ ]] && [ $((now_ts - holder_ts)) -gt 15 ]; then
        rm -rf "$lock_dir" 2>/dev/null || true
        if mkdir "$lock_dir" 2>/dev/null; then break; fi
        continue
      fi
    fi
    if [ $((now_ts - start_ts)) -ge 10 ]; then
      return 1
    fi
    sleep 0.05
  done

  printf '%s\n%s\n' "$$" "$start_ts" > "$holder_file"
}

runtime_release_path_lock() {
  rm -rf "$(runtime_lock_dir "$1")"
}

_runtime_kv_get_nolock() {
  local file="$1"
  local key="$2"
  [ -f "$file" ] || return 1
  awk -F'\t' -v key="$key" '
    $1 == key { print $2; found = 1; exit }
    END { exit(found ? 0 : 1) }
  ' "$file"
}

_runtime_kv_set_nolock() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp_file
  mkdir -p "$(dirname "$file")"
  tmp_file="${file}.tmp.$$"

  if [ -f "$file" ]; then
    awk -F'\t' -v key="$key" -v value="$value" '
      BEGIN { OFS = "\t"; updated = 0 }
      $1 == key {
        if (!updated) {
          print key, value
          updated = 1
        }
        next
      }
      { print }
      END {
        if (!updated) {
          print key, value
        }
      }
    ' "$file" > "$tmp_file"
  else
    printf '%s\t%s\n' "$key" "$value" > "$tmp_file"
  fi

  mv "$tmp_file" "$file"
}

_runtime_kv_clear_nolock() {
  local file="$1"
  local key="$2"
  local tmp_file
  [ -f "$file" ] || return 0
  tmp_file="${file}.tmp.$$"
  awk -F'\t' -v key="$key" 'BEGIN { OFS = "\t" } $1 != key { print }' "$file" > "$tmp_file"
  if [ -s "$tmp_file" ]; then
    mv "$tmp_file" "$file"
  else
    rm -f "$file" "$tmp_file"
  fi
}

runtime_kv_get() {
  local file="$1"
  local key="$2"
  local default_value="${3-__runtime_no_default__}"
  if _runtime_kv_get_nolock "$file" "$key"; then
    return 0
  fi
  if [ "$default_value" != "__runtime_no_default__" ]; then
    printf '%s\n' "$default_value"
    return 0
  fi
  return 1
}

runtime_kv_set() {
  local file="$1"
  local key="$2"
  local value="$3"
  runtime_acquire_path_lock "$file" || return 1
  _runtime_kv_set_nolock "$file" "$key" "$value"
  runtime_release_path_lock "$file"
}

runtime_kv_clear() {
  local file="$1"
  local key="$2"
  runtime_acquire_path_lock "$file" || return 1
  _runtime_kv_clear_nolock "$file" "$key"
  runtime_release_path_lock "$file"
}

_runtime_row_get_nolock() {
  local file="$1"
  local row_key="$2"
  local column_index="$3"
  [ -f "$file" ] || return 1
  awk -F'\t' -v row_key="$row_key" -v column_index="$column_index" '
    $1 == row_key {
      if (column_index <= NF) {
        print $column_index
      }
      found = 1
      exit
    }
    END { exit(found ? 0 : 1) }
  ' "$file"
}

_runtime_row_set_nolock() {
  local file="$1"
  local row_key="$2"
  shift 2
  local tmp_file line field
  mkdir -p "$(dirname "$file")"
  tmp_file="${file}.tmp.$$"
  line="$row_key"
  for field in "$@"; do
    line="${line}"$'\t'"${field}"
  done

  if [ -f "$file" ]; then
    awk -F'\t' -v row_key="$row_key" -v line="$line" '
      BEGIN { updated = 0 }
      $1 == row_key {
        if (!updated) {
          print line
          updated = 1
        }
        next
      }
      { print }
      END {
        if (!updated) {
          print line
        }
      }
    ' "$file" > "$tmp_file"
  else
    printf '%s\n' "$line" > "$tmp_file"
  fi

  mv "$tmp_file" "$file"
}

_runtime_row_clear_nolock() {
  local file="$1"
  local row_key="$2"
  local tmp_file
  [ -f "$file" ] || return 0
  tmp_file="${file}.tmp.$$"
  awk -F'\t' -v row_key="$row_key" '$1 != row_key { print }' "$file" > "$tmp_file"
  if [ -s "$tmp_file" ]; then
    mv "$tmp_file" "$file"
  else
    rm -f "$file" "$tmp_file"
  fi
}

runtime_row_get() {
  local file="$1"
  local row_key="$2"
  local column_index="$3"
  local default_value="${4-__runtime_no_default__}"
  if _runtime_row_get_nolock "$file" "$row_key" "$column_index"; then
    return 0
  fi
  if [ "$default_value" != "__runtime_no_default__" ]; then
    printf '%s\n' "$default_value"
    return 0
  fi
  return 1
}

runtime_row_set() {
  local file="$1"
  shift
  runtime_acquire_path_lock "$file" || return 1
  _runtime_row_set_nolock "$file" "$@"
  runtime_release_path_lock "$file"
}

runtime_row_clear() {
  local file="$1"
  local row_key="$2"
  runtime_acquire_path_lock "$file" || return 1
  _runtime_row_clear_nolock "$file" "$row_key"
  runtime_release_path_lock "$file"
}

runtime_migrate_file() {
  local new_path="$1"
  local old_path="$2"
  mkdir -p "$(dirname "$new_path")"
  if [ ! -e "$new_path" ] && [ -e "$old_path" ]; then
    mv "$old_path" "$new_path"
  fi
}

runtime_prune_empty_dir_chain() {
  local path="$1"
  local stop_dir="${2:-}"
  while [ -n "$path" ] && [ "$path" != "/" ]; do
    if [ -n "$stop_dir" ] && [ "$path" = "$stop_dir" ]; then
      rmdir "$path" 2>/dev/null || true
      break
    fi
    rmdir "$path" 2>/dev/null || break
    path="$(dirname "$path")"
  done
}

runtime_get_manager_state() {
  runtime_kv_get "$(runtime_manager_state_file "$1")" "$2" "${3-__runtime_no_default__}"
}

runtime_set_manager_state() {
  runtime_kv_set "$(runtime_manager_state_file "$1")" "$2" "$3"
}

runtime_clear_manager_state() {
  runtime_kv_clear "$(runtime_manager_state_file "$1")" "$2"
}

runtime_claim_manager_lock() {
  local project="$1"
  local pid="$2"
  local state_file current_pid
  state_file="$(runtime_manager_state_file "$project")"
  mkdir -p "$(dirname "$state_file")"
  runtime_acquire_path_lock "$state_file" || return 1
  current_pid="$(_runtime_kv_get_nolock "$state_file" "monitor_lock_pid" || true)"
  if [[ "${current_pid:-}" =~ ^[0-9]+$ ]] && [ "$current_pid" != "$pid" ] && kill -0 "$current_pid" 2>/dev/null; then
    runtime_release_path_lock "$state_file"
    return 1
  fi
  _runtime_kv_set_nolock "$state_file" "monitor_lock_pid" "$pid"
  runtime_release_path_lock "$state_file"
}

runtime_release_manager_lock() {
  local project="$1"
  local pid="${2:-}"
  local state_file current_pid
  state_file="$(runtime_manager_state_file "$project")"
  [ -f "$state_file" ] || return 0
  runtime_acquire_path_lock "$state_file" || return 1
  current_pid="$(_runtime_kv_get_nolock "$state_file" "monitor_lock_pid" || true)"
  if [ -z "$pid" ] || [ -z "$current_pid" ] || [ "$current_pid" = "$pid" ]; then
    _runtime_kv_clear_nolock "$state_file" "monitor_lock_pid"
  fi
  runtime_release_path_lock "$state_file"
}

_runtime_reboot_state_write_nolock() {
  local state_file="$1"
  local row_key="$2"
  local count="$3"
  local lock_ts="$4"
  local lockout_ts="$5"
  if [ "${count:-0}" = "0" ] && [ -z "$lock_ts" ] && [ -z "$lockout_ts" ]; then
    _runtime_row_clear_nolock "$state_file" "$row_key"
  else
    _runtime_row_set_nolock "$state_file" "$row_key" "$count" "$lock_ts" "$lockout_ts"
  fi
}

runtime_get_reboot_count() {
  runtime_row_get "$(runtime_reboot_state_file "$1")" "$2" 2 "0"
}

runtime_get_reboot_lock_ts() {
  runtime_row_get "$(runtime_reboot_state_file "$1")" "$2" 3 ""
}

runtime_get_reboot_lockout_ts() {
  runtime_row_get "$(runtime_reboot_state_file "$1")" "$2" 4 ""
}

runtime_set_reboot_count() {
  local project="$1"
  local row_key="$2"
  local count="$3"
  local state_file lock_ts lockout_ts
  state_file="$(runtime_reboot_state_file "$project")"
  runtime_acquire_path_lock "$state_file" || return 1
  lock_ts="$(_runtime_row_get_nolock "$state_file" "$row_key" 3 || true)"
  lockout_ts="$(_runtime_row_get_nolock "$state_file" "$row_key" 4 || true)"
  _runtime_reboot_state_write_nolock "$state_file" "$row_key" "$count" "$lock_ts" "$lockout_ts"
  runtime_release_path_lock "$state_file"
}

runtime_increment_reboot_count() {
  local project="$1"
  local row_key="$2"
  local state_file current_count lock_ts lockout_ts
  state_file="$(runtime_reboot_state_file "$project")"
  runtime_acquire_path_lock "$state_file" || return 1
  current_count="$(_runtime_row_get_nolock "$state_file" "$row_key" 2 || true)"
  lock_ts="$(_runtime_row_get_nolock "$state_file" "$row_key" 3 || true)"
  lockout_ts="$(_runtime_row_get_nolock "$state_file" "$row_key" 4 || true)"
  [[ "${current_count:-}" =~ ^[0-9]+$ ]] || current_count=0
  _runtime_reboot_state_write_nolock "$state_file" "$row_key" "$((current_count + 1))" "$lock_ts" "$lockout_ts"
  runtime_release_path_lock "$state_file"
}

runtime_reset_reboot_count() {
  runtime_set_reboot_count "$1" "$2" "0"
}

runtime_set_reboot_lock_ts() {
  local project="$1"
  local row_key="$2"
  local lock_ts="$3"
  local state_file current_count lockout_ts
  state_file="$(runtime_reboot_state_file "$project")"
  runtime_acquire_path_lock "$state_file" || return 1
  current_count="$(_runtime_row_get_nolock "$state_file" "$row_key" 2 || true)"
  lockout_ts="$(_runtime_row_get_nolock "$state_file" "$row_key" 4 || true)"
  [[ "${current_count:-}" =~ ^[0-9]+$ ]] || current_count=0
  _runtime_reboot_state_write_nolock "$state_file" "$row_key" "$current_count" "$lock_ts" "$lockout_ts"
  runtime_release_path_lock "$state_file"
}

runtime_clear_reboot_lock_ts() {
  runtime_set_reboot_lock_ts "$1" "$2" ""
}

runtime_try_claim_reboot_lock() {
  local project="$1"
  local row_key="$2"
  local stale_after="$3"
  local now_ts current_count lock_ts lockout_ts state_file
  now_ts=$(date +%s)
  state_file="$(runtime_reboot_state_file "$project")"
  runtime_acquire_path_lock "$state_file" || return 1
  current_count="$(_runtime_row_get_nolock "$state_file" "$row_key" 2 || true)"
  lock_ts="$(_runtime_row_get_nolock "$state_file" "$row_key" 3 || true)"
  lockout_ts="$(_runtime_row_get_nolock "$state_file" "$row_key" 4 || true)"
  [[ "${current_count:-}" =~ ^[0-9]+$ ]] || current_count=0
  if [[ "${lock_ts:-}" =~ ^[0-9]+$ ]] && [ $((now_ts - lock_ts)) -lt "$stale_after" ]; then
    runtime_release_path_lock "$state_file"
    return 1
  fi
  _runtime_reboot_state_write_nolock "$state_file" "$row_key" "$current_count" "$now_ts" "$lockout_ts"
  runtime_release_path_lock "$state_file"
}

runtime_set_reboot_lockout_ts() {
  local project="$1"
  local row_key="$2"
  local lockout_ts="$3"
  local state_file current_count lock_ts
  state_file="$(runtime_reboot_state_file "$project")"
  runtime_acquire_path_lock "$state_file" || return 1
  current_count="$(_runtime_row_get_nolock "$state_file" "$row_key" 2 || true)"
  lock_ts="$(_runtime_row_get_nolock "$state_file" "$row_key" 3 || true)"
  [[ "${current_count:-}" =~ ^[0-9]+$ ]] || current_count=0
  _runtime_reboot_state_write_nolock "$state_file" "$row_key" "$current_count" "$lock_ts" "$lockout_ts"
  runtime_release_path_lock "$state_file"
}

runtime_clear_reboot_lockout_ts() {
  runtime_set_reboot_lockout_ts "$1" "$2" ""
}

runtime_get_idle_check_ts() {
  runtime_row_get "$(runtime_idle_state_file "$1")" "$2" 2 ""
}

runtime_set_idle_check_ts() {
  runtime_row_set "$(runtime_idle_state_file "$1")" "$2" "$3"
}

runtime_clear_idle_check_ts() {
  runtime_row_clear "$(runtime_idle_state_file "$1")" "$2"
}

runtime_set_waiting_report() {
  local project="$1"
  local row_key="$2"
  local report_ts="$3"
  local subject="$4"
  local task_ref="$5"
  local report_path="${6:-}"
  runtime_row_set "$(runtime_waiting_state_file "$project")" \
    "$row_key" "$report_ts" "$subject" "$task_ref" "$report_path"
}

runtime_clear_waiting_report() {
  runtime_row_clear "$(runtime_waiting_state_file "$1")" "$2"
}

runtime_claim_message_target_lock() {
  local project="$1"
  local target="$2"
  local lock_path
  lock_path="$(runtime_message_target_lock_path "$project" "$target")"
  mkdir -p "$(dirname "$lock_path")"
  runtime_acquire_path_lock "$lock_path"
}

runtime_release_message_target_lock() {
  local project="$1"
  local target="$2"
  local lock_path lock_dir
  lock_path="$(runtime_message_target_lock_path "$project" "$target")"
  lock_dir="$(dirname "$lock_path")"
  runtime_release_path_lock "$lock_path"
  rmdir "$lock_dir" 2>/dev/null || true
}

runtime_get_message_refresh_ts() {
  runtime_get_manager_state "$1" "message_refresh_$2" ""
}

runtime_set_message_refresh_ts() {
  runtime_set_manager_state "$1" "message_refresh_$2" "$3"
}

runtime_clear_message_refresh_ts() {
  runtime_clear_manager_state "$1" "message_refresh_$2"
}

runtime_migrate_manager_state_value() {
  local project="$1"
  local source_file="$2"
  local state_key="$3"
  if [ -f "$source_file" ]; then
    runtime_set_manager_state "$project" "$state_key" "$(cat "$source_file")"
    rm -f "$source_file"
  fi
}

runtime_migrate_reboot_dir() {
  local project="$1"
  local source_dir="$2"
  local entry role_name state_value

  [ -d "$source_dir" ] || return 0

  for entry in "$source_dir"/*.count; do
    [ -f "$entry" ] || continue
    role_name="$(basename "$entry" .count)"
    state_value="$(cat "$entry" 2>/dev/null || true)"
    [[ "$state_value" =~ ^[0-9]+$ ]] || state_value=0
    runtime_set_reboot_count "$project" "$role_name" "$state_value"
    rm -f "$entry"
  done

  for entry in "$source_dir"/*.lockout; do
    [ -f "$entry" ] || continue
    role_name="$(basename "$entry" .lockout)"
    state_value="$(cat "$entry" 2>/dev/null || true)"
    if [[ "$state_value" =~ ^[0-9]+$ ]]; then
      runtime_set_reboot_lockout_ts "$project" "$role_name" "$state_value"
    fi
    rm -f "$entry"
  done

  rmdir "$source_dir" 2>/dev/null || true
}

runtime_migrate_reboot_locks_dir() {
  local project="$1"
  local source_dir="$2"
  local entry role_name state_value

  [ -d "$source_dir" ] || return 0

  for entry in "$source_dir"/*.lock; do
    [ -f "$entry" ] || continue
    role_name="$(basename "$entry" .lock)"
    state_value="$(cat "$entry" 2>/dev/null || true)"
    if [[ "$state_value" =~ ^[0-9]+$ ]]; then
      runtime_set_reboot_lock_ts "$project" "$role_name" "$state_value"
    fi
    rm -f "$entry"
  done

  rmdir "$source_dir" 2>/dev/null || true
}

runtime_migrate_idle_checks_dir() {
  local project="$1"
  local source_dir="$2"
  local entry role_name state_value

  [ -d "$source_dir" ] || return 0

  for entry in "$source_dir"/*.check; do
    [ -f "$entry" ] || continue
    role_name="$(basename "$entry" .check)"
    state_value="$(cat "$entry" 2>/dev/null || true)"
    if [[ "$state_value" =~ ^[0-9]+$ ]]; then
      runtime_set_idle_check_ts "$project" "$role_name" "$state_value"
    fi
    rm -f "$entry"
  done

  rmdir "$source_dir" 2>/dev/null || true
}

ensure_manager_runtime_layout() {
  local project="$1"
  local runtime_root manager_role_dir legacy_dir source_dir
  runtime_root="$(runtime_root_dir "$project")"
  manager_role_dir="$(runtime_manager_dir "$project")"
  legacy_dir="$(legacy_manager_memory_dir "$project")"
  mkdir -p "$runtime_root"

  for source_dir in "$manager_role_dir" "$legacy_dir"; do
    [ -d "$source_dir" ] || continue
    runtime_migrate_manager_state_value "$project" "$source_dir/monitor.pid" "monitor_pid"
    runtime_migrate_manager_state_value "$project" "$source_dir/monitor.heartbeat" "monitor_heartbeat"
    runtime_migrate_manager_state_value "$project" "$source_dir/monitor.lock" "monitor_lock_pid"
    runtime_migrate_manager_state_value "$project" "$source_dir/monitor.nudge" "monitor_nudge_ts"
    runtime_migrate_reboot_dir "$project" "$source_dir/reboot-counts"
    runtime_migrate_reboot_locks_dir "$project" "$source_dir/reboot-locks"
    runtime_migrate_idle_checks_dir "$project" "$source_dir/idle-checks"
    rm -rf "$source_dir/message-queue"
    rm -rf "$source_dir/hung-flags"
    runtime_prune_empty_dir_chain "$source_dir" "$runtime_root"
  done
}

cleanup_manager_runtime_transients() {
  local project="$1"
  local runtime_root lock_dir manager_state reboot_state idle_state waiting_state
  runtime_root="$(runtime_root_dir "$project")"
  lock_dir="$(runtime_message_lock_dir "$project")"
  manager_state="$(runtime_manager_state_file "$project")"
  reboot_state="$(runtime_reboot_state_file "$project")"
  idle_state="$(runtime_idle_state_file "$project")"
  waiting_state="$(runtime_waiting_state_file "$project")"

  rm -rf "$(legacy_manager_memory_dir "$project")/hung-flags"
  rm -rf "$(runtime_manager_dir "$project")/hung-flags"

  if [ -d "$lock_dir" ] && ! find "$lock_dir" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
    rmdir "$lock_dir" 2>/dev/null || true
  fi

  for state_file in "$reboot_state" "$idle_state" "$waiting_state"; do
    if [ -f "$state_file" ] && ! grep -q '[^[:space:]]' "$state_file" 2>/dev/null; then
      rm -f "$state_file"
    fi
  done

  if [ -f "$manager_state" ] && ! grep -q '[^[:space:]]' "$manager_state" 2>/dev/null; then
    rm -f "$manager_state"
  fi

  runtime_prune_empty_dir_chain "$(runtime_manager_dir "$project")" "$runtime_root"
  runtime_prune_empty_dir_chain "$runtime_root" "$(runtime_project_dir "$project")"
}
