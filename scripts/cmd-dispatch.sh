# cmd-dispatch.sh -- 태스크 디스패치, 할당, 완료 함수
#
# cmd.sh에서 source된다. 단독 실행하지 않는다.
# 의존: cmd-utils.sh (먼저 source 필요)
# 의존: cmd-boot.sh (boot_agent_with_backend 등 — 동적 스폰 시 필요)

# ──────────────────────────────────────────────
# 태스크 참조 / 메타데이터 헬퍼
# ──────────────────────────────────────────────

# assignments.md에 태스크 할당 기록
normalize_task_ref() {
  normalize_assignment_task_ref "$1" "$2"
}

_task_trim() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

_task_line_backtick_value() {
  printf '%s\n' "$1" | sed -n 's/.*`\([^`][^`]*\)`.*/\1/p' | head -1
}

_task_line_backtick_csv() {
  printf '%s\n' "$1" | grep -o '`[^`][^`]*`' 2>/dev/null | tr -d '`' | paste -sd, - | sed 's/^ *//;s/ *$//'
}

resolve_task_metadata_path() {
  local project="$1" task="$2"
  local normalized_task pdir
  if [ -f "$task" ]; then
    printf '%s\n' "$task"
    return 0
  fi
  pdir="$(project_dir "$project")"
  normalized_task="$(normalize_task_ref "$project" "$task")"
  if [ -f "$pdir/$normalized_task" ]; then
    printf '%s\n' "$pdir/$normalized_task"
    return 0
  fi
  if [[ "$task" == "projects/$project/"* ]] && [ -f "$REPO_ROOT/$task" ]; then
    printf '%s\n' "$REPO_ROOT/$task"
    return 0
  fi
  return 1
}

_task_metadata_line() {
  local project="$1" task="$2" label="$3" task_path
  task_path="$(resolve_task_metadata_path "$project" "$task" 2>/dev/null || true)"
  [ -f "$task_path" ] || return 0
  grep -m1 "^- \\*\\*${label}\\*\\*:" "$task_path" 2>/dev/null || true
}

# ──────────────────────────────────────────────
# 태스크 실행 패턴 (task pattern) 함수
# ──────────────────────────────────────────────

canonicalize_task_pattern() {
  local raw lowered
  raw="$(_task_trim "${1:-}")"
  lowered="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  case "$lowered" in
    "single owner"|"single-owner"|"single_owner")
      printf 'single_owner\n'
      ;;
    "lead + verify"|"lead+verify"|"lead-verify"|"lead_verify"|"mirror + challenge"|"mirror+challenge"|"mirror-challenge"|"mirror + verify"|"split + cross-check"|"split+cross-check"|"split-cross-check")
      printf 'lead_verify\n'
      ;;
    "independent compare"|"independent-compare"|"independent_compare"|"mirror + consensus"|"mirror+consensus"|"mirror-consensus"|"mirror + synth"|"mirror+synth"|"mirror-synth")
      printf 'independent_compare\n'
      ;;
    *)
      printf 'single_owner\n'
      ;;
  esac
}

task_pattern_from_task() {
  local project="$1" task="$2" line value
  line="$(_task_metadata_line "$project" "$task" "Pattern")"
  value="$(_task_line_backtick_value "$line")"
  canonicalize_task_pattern "$value"
}

task_owner_lane_from_task() {
  local project="$1" task="$2" line value
  line="$(_task_metadata_line "$project" "$task" "Owner lane")"
  value="$(_task_line_backtick_value "$line")"
  [ "$value" = "none" ] && value=""
  printf '%s\n' "$value"
}

task_owner_lanes_from_task() {
  local project="$1" task="$2" line value
  line="$(_task_metadata_line "$project" "$task" "Owner lanes")"
  value="$(_task_line_backtick_csv "$line")"
  [ "$value" = "none" ] && value=""
  printf '%s\n' "$value"
}

task_review_lane_from_task() {
  local project="$1" task="$2" line value
  line="$(_task_metadata_line "$project" "$task" "Review lane")"
  value="$(_task_line_backtick_value "$line")"
  [ "$value" = "none" ] && value=""
  printf '%s\n' "$value"
}

csv_first_value() {
  local csv="${1:-}" first
  IFS=',' read -r first _ <<< "$csv"
  _task_trim "${first:-}"
}

append_unique_task_target() {
  local target="$1" role_label="$2" existing idx
  [ -n "$target" ] || return 0
  for idx in "${!TASK_EXEC_TARGETS[@]}"; do
    existing="${TASK_EXEC_TARGETS[$idx]}"
    if [ "$existing" = "$target" ]; then
      return 0
    fi
  done
  TASK_EXEC_TARGETS+=("$target")
  TASK_EXEC_ROLES+=("$role_label")
}

canonical_lane_target() {
  local role="$1" target="$2" project="$3" default_backend="${4:-codex}"
  [ -n "$target" ] || return 0

  if [[ "$target" == *-claude ]] || [[ "$target" == *-codex ]]; then
    printf '%s\n' "$target"
    return 0
  fi

  if [ "$target" = "$role" ] && role_supports_dual "$role" && [ "$(get_exec_mode "$project")" = "dual" ]; then
    printf '%s-%s\n' "$role" "$default_backend"
    return 0
  fi

  printf '%s\n' "$target"
}

peer_lane_for_target() {
  local role="$1" target="$2" project="${3:-}"
  if [[ "$target" == *-claude ]]; then
    printf '%s\n' "${target%-claude}-codex"
    return 0
  fi
  if [[ "$target" == *-codex ]]; then
    printf '%s\n' "${target%-codex}-claude"
    return 0
  fi
  if [ -n "$project" ] && [ "$(get_exec_mode "$project")" != "dual" ]; then
    printf '%s\n' "$target"
    return 0
  fi
  if ! role_supports_dual "$role"; then
    printf '%s\n' "$target"
    return 0
  fi
  if [ "$target" = "$role" ]; then
    printf '%s-claude\n' "$role"
    return 0
  fi
  printf '%s\n' "$target"
}

resolve_task_execution_plan() {
  local role="$1" task="$2" project="$3" forced_pattern="${4:-}"
  local pattern owner_lane owner_lanes review_lane lead_target verify_target compare_csv compare_target
  local IFS=','

  TASK_EXEC_TARGETS=()
  TASK_EXEC_ROLES=()
  TASK_EXEC_MANAGER_STUB=""

  if [ -n "${forced_pattern:-}" ]; then
    pattern="$(canonicalize_task_pattern "$forced_pattern")"
  else
    pattern="$(task_pattern_from_task "$project" "$task")"
  fi

  owner_lane="$(task_owner_lane_from_task "$project" "$task")"
  owner_lanes="$(task_owner_lanes_from_task "$project" "$task")"
  review_lane="$(task_review_lane_from_task "$project" "$task")"

  case "$pattern" in
    single_owner)
      append_unique_task_target "$(canonical_lane_target "$role" "${owner_lane:-$(csv_first_value "$owner_lanes")}" "$project" "codex")" "owner"
      if [ "${#TASK_EXEC_TARGETS[@]}" -eq 0 ]; then
        append_unique_task_target "$(canonical_lane_target "$role" "$role" "$project" "codex")" "owner"
      fi
      ;;
    lead_verify)
      lead_target="${owner_lane:-$(csv_first_value "$owner_lanes")}"
      [ -n "$lead_target" ] || lead_target="$role"
      lead_target="$(canonical_lane_target "$role" "$lead_target" "$project" "codex")"
      append_unique_task_target "$lead_target" "lead"
      verify_target="$review_lane"
      if [ -z "$verify_target" ] || [[ "$verify_target" == manager* ]]; then
        verify_target="$(peer_lane_for_target "$role" "$lead_target" "$project")"
      elif [ "$verify_target" = "$role" ]; then
        verify_target="$(peer_lane_for_target "$role" "$lead_target" "$project")"
      else
        verify_target="$(canonical_lane_target "$role" "$verify_target" "$project" "claude")"
      fi
      if [ -n "$verify_target" ] && [ "$verify_target" != "$lead_target" ]; then
        append_unique_task_target "$verify_target" "verify"
      fi
      TASK_EXEC_MANAGER_STUB="verify"
      ;;
    independent_compare)
      compare_csv="$owner_lanes"
      if [ -z "$compare_csv" ]; then
        compare_csv="${role}-claude,${role}-codex"
      fi
      for compare_target in $compare_csv; do
        compare_target="$(_task_trim "$compare_target")"
        append_unique_task_target "$compare_target" "compare"
      done
      TASK_EXEC_MANAGER_STUB="compare"
      ;;
  esac

  TASK_EXEC_PATTERN="$pattern"
}

task_subject_and_message() {
  local task="$1"
  local subject_var="$2"
  local message_var="$3"
  local project="${4:-}"
  local subject_value msg_value resolved_task
  resolved_task=""
  if [ -n "$project" ]; then
    resolved_task="$(resolve_task_metadata_path "$project" "$task" 2>/dev/null || true)"
  fi
  if [ -n "$resolved_task" ] || [ -f "$task" ]; then
    subject_value="$task"
    if [ -n "$project" ]; then
      msg_value="$(normalize_task_ref "$project" "$task") 파일에 새 작업 지시가 있다. 읽고 실행해라."
    else
      msg_value="${task} 파일에 새 작업 지시가 있다. 읽고 실행해라."
    fi
  else
    subject_value="$task"
    msg_value="$task"
  fi
  printf -v "$subject_var" '%s' "$subject_value"
  printf -v "$message_var" '%s' "$msg_value"
}

pattern_dispatch_message() {
  local task="$1" project="$2" pattern="$3" role_label="$4" lead_target="${5:-}"
  local subject base
  task_subject_and_message "$task" subject base "$project"
  case "$pattern:$role_label" in
    single_owner:owner)
      printf '%s\n' "$base"
      ;;
    lead_verify:lead)
      printf '[execution pattern: lead + verify]\n%s\nexecution lead로서 구현을 주도하고 결과 보고를 남겨라.\n' "$base"
      ;;
    lead_verify:verify)
      printf '[execution pattern: lead + verify]\n%s\nreview/verify lane으로서 %s 결과를 교차검토하고 challenge/confirm 메모를 남겨라.\n' "$base" "${lead_target:-lead lane}"
      ;;
    independent_compare:compare)
      printf '[execution pattern: independent compare]\n%s\npeer lane과 독립적으로 읽고 실행한 뒤 비교 가능한 보고를 남겨라.\n' "$base"
      ;;
    *)
      printf '%s\n' "$base"
      ;;
  esac
}

# ──────────────────────────────────────────────
# 할당 기록 / 완료 / 만료
# ──────────────────────────────────────────────

record_assignment() {
  record_assignment_for_project "$1" "$2" "$3"
}

# assignments.md에서 에이전트의 active 태스크를 completed로 변경
complete_assignment() {
  complete_assignment_for_project "$1" "$2"
}

# 명시적 complete 커맨드
cmd_complete() {
  local agent="$1" project="$2"
  validate_project_name "$project"
  validate_window_name "$agent"
  complete_assignment "$project" "$agent"
  python3 "$TOOLS_DIR/log.py" system "$project" orchestrator task_complete "$agent" || true
  echo "complete 완료: ${agent}"
}

# 명시적 assign 커맨드 (전달 없이 추적만 기록)
# Manager가 message.sh로 이미 전달한 태스크를 사후 등록하거나,
# 자기 자신의 조율 태스크를 기록할 때 사용
cmd_assign() {
  local agent="$1" task="$2" project="$3"
  validate_project_name "$project"
  validate_window_name "$agent"
  record_assignment "$project" "$agent" "$task"
  python3 "$TOOLS_DIR/log.py" system "$project" orchestrator task_assign "$agent" \
    --detail task="$task" || true
  echo "assign 완료: ${agent} ← ${task}"
}

# stale 태스크 자동 만료 (max_hours 이상 active 유지된 태스크를 stale로 표시)
expire_stale_assignments() {
  local project="$1" max_hours="${2:-4}"
  local af
  af="$(project_dir "$project")/memory/manager/assignments.md"
  [ -f "$af" ] || return 0

  # 파일 잠금 (NEW-04 수정: 다른 writers와 동일한 lock 패턴)
  runtime_acquire_path_lock "$af" || return 0

  local now_epoch
  now_epoch=$(date +%s)

  local tmp="${af}.tmp"
  while IFS= read -r line; do
    if echo "$line" | grep -q "| active |"; then
      local ts_str
      ts_str=$(echo "$line" | awk -F'|' '{print $4}' | sed 's/^ *//;s/ *$//')
      if [ -n "$ts_str" ]; then
        local ts_epoch=0
        if [[ "$OSTYPE" == darwin* ]]; then
          ts_epoch=$(date -j -f "%Y-%m-%d %H:%M" "$ts_str" +%s 2>/dev/null) || ts_epoch=0
        else
          ts_epoch=$(date -d "$ts_str" +%s 2>/dev/null) || ts_epoch=0
        fi
        local age_hours=$(( (now_epoch - ts_epoch) / 3600 ))
        if [ "$ts_epoch" -gt 0 ] && [ "$age_hours" -ge "$max_hours" ]; then
          line=$(echo "$line" | sed 's/| active |/| stale |/')
        fi
      fi
    fi
    echo "$line"
  done < "$af" > "$tmp"
  mv "$tmp" "$af"

  runtime_release_path_lock "$af"
}

# 에이전트의 현재 active 태스크 경로 반환
get_active_task() {
  get_active_task_ref_for_project "$1" "$2"
}

resume_pending_task_for_window() {
  local project="$1" role="$2" window_name="$3"
  local pending_task=""
  pending_task="$(get_active_task "$project" "$window_name")" || pending_task=""
  if [ -n "$pending_task" ]; then
    printf '%s\n' "$pending_task"
    return 0
  fi

  if [ -n "$role" ] && [ "$window_name" != "$role" ]; then
    pending_task="$(get_active_task "$project" "$role")" || pending_task=""
  fi

  printf '%s\n' "$pending_task"
}

# ──────────────────────────────────────────────
# dispatch / dual-dispatch 서브커맨드
# ──────────────────────────────────────────────

cmd_dispatch() {
  local role="$1"
  local task="$2"       # 태스크 파일 경로 OR 인라인 텍스트
  local project="$3"
  local forced_pattern="${4:-}"

  # 입력 검증
  if [ -z "$role" ]; then
    echo "Error: dispatch role이 비어 있다." >&2
    return 1
  fi
  if [[ "$role" =~ [^a-zA-Z0-9_-] ]]; then
    echo "Error: 잘못된 dispatch role: $role (영문/숫자/하이픈/밑줄만 허용)" >&2
    return 1
  fi
  if [ -z "$task" ]; then
    echo "Error: dispatch task가 비어 있다." >&2
    return 1
  fi
  validate_project_name "$project"

  # stale 정리
  expire_stale_assignments "$project"

  local subject base_msg lead_target target role_label target_msg idx
  local target_csv="" role_csv=""
  task_subject_and_message "$task" subject base_msg "$project"

  resolve_task_execution_plan "$role" "$task" "$project" "$forced_pattern"
  if [ "${#TASK_EXEC_TARGETS[@]}" -eq 0 ]; then
    echo "Error: dispatch 대상이 비어 있다." >&2
    return 1
  fi

  lead_target="${TASK_EXEC_TARGETS[0]}"
  for target in "${TASK_EXEC_TARGETS[@]}"; do
    [ -n "$target_csv" ] && target_csv="${target_csv},"
    target_csv="${target_csv}${target}"
  done
  for role_label in "${TASK_EXEC_ROLES[@]}"; do
    [ -n "$role_csv" ] && role_csv="${role_csv},"
    role_csv="${role_csv}${role_label}"
  done

  for idx in "${!TASK_EXEC_TARGETS[@]}"; do
    target="${TASK_EXEC_TARGETS[$idx]}"
    role_label="${TASK_EXEC_ROLES[$idx]}"
    target_msg="$(pattern_dispatch_message "$task" "$project" "$TASK_EXEC_PATTERN" "$role_label" "$lead_target")"
    bash "$TOOLS_DIR/message.sh" "$project" "manager" "$target" "task_assign" "normal" "$subject" "$target_msg"
  done

  python3 "$TOOLS_DIR/log.py" system "$project" orchestrator task_dispatch "$role" \
    --detail task="$task" pattern="$TASK_EXEC_PATTERN" targets="$target_csv" roles="$role_csv" || true
  echo "dispatch 완료: ${role} [${TASK_EXEC_PATTERN}] ← ${task} (${target_csv})"
}

cmd_dual_dispatch() {
  local role="$1"
  local task="$2"       # 태스크 파일 경로 OR 인라인 텍스트
  local project="$3"
  # 호환 래퍼: independent compare 패턴으로 dispatch
  cmd_dispatch "$role" "$task" "$project" "independent compare"
  python3 "$TOOLS_DIR/log.py" system "$project" orchestrator dual_dispatch "$role" \
    --detail task="$task" pattern="independent_compare" || true
  echo "dual-dispatch 완료: ${role} (compat → independent compare) ← ${task}"
}
