#!/bin/bash

assignment_state_repo_root() {
  local root="${REPO_ROOT:-${repo_root:-}}"
  if [ -z "$root" ]; then
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  fi
  printf '%s\n' "$root"
}

assignments_file_for_project() {
  local project="$1"
  printf '%s/projects/%s/memory/manager/assignments.md\n' "$(assignment_state_repo_root)" "$project"
}

normalize_assignment_task_ref() {
  local project="$1" task_ref="$2" project_root
  project_root="$(assignment_state_repo_root)/projects/$project"
  if [[ "$task_ref" == "$project_root"/* ]]; then
    task_ref="${task_ref#"$project_root"/}"
  elif [[ "$task_ref" == "projects/$project/"* ]]; then
    task_ref="${task_ref#"projects/$project/"}"
  fi
  printf '%s\n' "$task_ref"
}

assignment_state_sed_inplace() {
  if [[ "$OSTYPE" == darwin* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

record_assignment_for_project() {
  local project="$1" agent="$2" task_ref="$3" af
  af="$(assignments_file_for_project "$project")"
  mkdir -p "$(dirname "$af")"

  if [ ! -f "$af" ]; then
    cat > "$af" << 'HEADER'
# 태스크 할당 현황
| 에이전트 | 태스크 파일 | 할당 시각 | 상태 |
|----------|-----------|----------|------|
HEADER
  fi

  if grep -q "| ${agent} |.*| active |" "$af" 2>/dev/null; then
    assignment_state_sed_inplace "s/| ${agent} |\(.*\)| active |/| ${agent} |\1| superseded |/" "$af"
  fi

  task_ref="$(normalize_assignment_task_ref "$project" "$task_ref")"
  echo "| ${agent} | ${task_ref} | $(date '+%Y-%m-%d %H:%M') | active |" >> "$af"
}

complete_assignment_for_project() {
  local project="$1" agent="$2" af
  af="$(assignments_file_for_project "$project")"
  [ -f "$af" ] || return 0
  if grep -q "| ${agent} |.*| active |" "$af" 2>/dev/null; then
    assignment_state_sed_inplace "s/| ${agent} |\(.*\)| active |/| ${agent} |\1| completed |/" "$af"
  fi
}

get_active_task_ref_for_project() {
  local project="$1" agent="$2" af
  af="$(assignments_file_for_project "$project")"
  [ -f "$af" ] || return 0
  { grep "| ${agent} |" "$af" 2>/dev/null || true; } \
    | grep "| active |" \
    | tail -1 \
    | awk -F'|' '{print $3}' \
    | sed 's/^ *//;s/ *$//' || true
}
