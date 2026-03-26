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

# awk 기반 상태 전환 (sed injection 방지 — H-01 수정)
_assignment_state_transition() {
  local af="$1" agent="$2" old_status="$3" new_status="$4"
  [ -f "$af" ] || return 0
  local tmp="${af}.tmp.$$"
  awk -v agent="$agent" -v old_status="$old_status" -v new_status="$new_status" '
    BEGIN { FS="|"; OFS="|" }
    {
      if (NF >= 5) {
        a = $2; gsub(/^[ \t]+|[ \t]+$/, "", a)
        s = $5; gsub(/^[ \t]+|[ \t]+$/, "", s)
        if (a == agent && s == old_status) {
          $5 = " " new_status " "
        }
      }
      print
    }
  ' "$af" > "$tmp" && mv "$tmp" "$af"
}

record_assignment_for_project() {
  local project="$1" agent="$2" task_ref="$3" af
  af="$(assignments_file_for_project "$project")"
  mkdir -p "$(dirname "$af")"

  # 파일 잠금 (C-03 수정: read-modify-append 경합 방지)
  runtime_acquire_path_lock "$af" || return 1

  if [ ! -f "$af" ]; then
    cat > "$af" << 'HEADER'
# 태스크 할당 현황
| 에이전트 | 태스크 파일 | 할당 시각 | 상태 |
|----------|-----------|----------|------|
HEADER
  fi

  _assignment_state_transition "$af" "$agent" "active" "superseded"

  task_ref="$(normalize_assignment_task_ref "$project" "$task_ref")"
  echo "| ${agent} | ${task_ref} | $(date '+%Y-%m-%d %H:%M') | active |" >> "$af"

  runtime_release_path_lock "$af"
}

complete_assignment_for_project() {
  local project="$1" agent="$2" af
  af="$(assignments_file_for_project "$project")"
  [ -f "$af" ] || return 0

  runtime_acquire_path_lock "$af" || return 1
  _assignment_state_transition "$af" "$agent" "active" "completed"
  runtime_release_path_lock "$af"
}

get_active_task_ref_for_project() {
  local project="$1" agent="$2" af
  af="$(assignments_file_for_project "$project")"
  [ -f "$af" ] || return 0
  awk -F'|' -v agent="$agent" '
    {
      a = $2; gsub(/^[ \t]+|[ \t]+$/, "", a)
      s = $5; gsub(/^[ \t]+|[ \t]+$/, "", s)
      if (a == agent && s == "active") { task = $3 }
    }
    END {
      gsub(/^[ \t]+|[ \t]+$/, "", task)
      if (task != "") print task
    }
  ' "$af" || true
}
