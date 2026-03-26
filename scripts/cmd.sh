#!/bin/bash
# cmd.sh -- tmux 기반 멀티 에이전트 오케스트레이션
#
# 서브커맨드:
#   boot-onboarding {project}                  -- Onboarding 세션 부팅 (완료 시 Manager 자동 인계)
#   handoff        {project}                   -- Legacy: 기존 Onboarding 세션을 Manager/팀 세션으로 인계
#   boot-manager   {project}                   -- Manager 부팅 + tmux 세션 생성
#   boot           {project}                   -- tmux 세션 생성 + 에이전트 부팅 + monitor 시작
#   dispatch       {role} {task} {project}      -- 에이전트에게 태스크 전달 (파일 경로 OR 인라인 텍스트)
#   dual-dispatch  {role} {task} {project}      -- 양쪽 백엔드에 동일 태스크 전달 (dual 모드)
#   assign         {agent} {task} {project}      -- 태스크 추적만 기록 (전달 없이, Manager 자기 태스크 등)
#   complete       {agent} {project}            -- 에이전트의 active 태스크를 completed로 변경
#   expire-stale   {project} [max-hours]        -- stale 태스크 자동 만료 (기본 4시간)
#   spawn          {role} {window-name} {project} [extra-msg] -- 동적 에이전트 추가 스폰
#   kill-agent     {window-name} {project}     -- 동적 에이전트 종료
#   shutdown       {project}                   -- 세션 종료 + 정리
#   status         {project}                   -- 세션 상태 확인
#   reboot         {target} {project}          -- 에이전트 세션 재시작 (target: role 또는 role-backend)
#   refresh        {target} {project}          -- 에이전트 맥락 리프레시 (target: role 또는 role-backend)
#   merge-worktree {role} {winner} {project}     -- 듀얼 모드 합의 후 winner를 main에 merge + worktree 정리
#   monitor-check  {project}                   -- monitor.sh 상태 확인 + 자동 재시작

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOLS_DIR="$SCRIPT_DIR"
TASK_EXEC_PATTERN=""
TASK_EXEC_MANAGER_STUB=""
TASK_EXEC_TARGETS=()
TASK_EXEC_ROLES=()

tmux() {
  command tmux "$@"
}

# shellcheck source=/dev/null
source "$TOOLS_DIR/tmux-submit.sh"
# shellcheck source=/dev/null
source "$TOOLS_DIR/runtime-paths.sh"
# shellcheck source=/dev/null
source "$TOOLS_DIR/agent-health.sh"
# shellcheck source=/dev/null
source "$TOOLS_DIR/assignment-state.sh"

# ──────────────────────────────────────────────
# 유틸리티 함수
# ──────────────────────────────────────────────

validate_project_name() {
  local name="$1"
  if [ -z "$name" ] || [[ "$name" =~ [^a-zA-Z0-9_-] ]]; then
    echo "Error: 잘못된 project 이름: '$name' (영문/숫자/하이픈/밑줄만 허용)" >&2
    exit 1
  fi
}

sed_inplace() {
  if [[ "$OSTYPE" == darwin* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

validate_window_name() {
  local name="$1"
  if [ -z "$name" ] || [[ "$name" =~ [^a-zA-Z0-9_-] ]]; then
    echo "Error: 잘못된 window 이름: '$name' (영문, 숫자, -, _ 만 허용)" >&2
    exit 1
  fi
}

activate_project_tmux_context() {
  local project="$1"
  local sess
  sess="$(session_name "$project")"
  export WHIPLASH_TMUX_PROJECT="$project"
  export WHIPLASH_TMUX_SOCKET_NAME="$sess"
  unset TMUX
}

session_name() {
  echo "whiplash-$1"
}

project_dir() {
  echo "$REPO_ROOT/projects/$1"
}

project_team_dir() {
  echo "$(project_dir "$1")/team"
}

project_team_role_doc_path() {
  local project="$1" role="$2"
  echo "$(project_team_dir "$project")/${role}.md"
}

project_knowledge_docs_dir() {
  echo "$(project_dir "$1")/memory/knowledge/docs"
}

project_change_authority_doc_path() {
  echo "$(project_knowledge_docs_dir "$1")/change-authority.md"
}

ensure_onboarding_project_layout() {
  local project="$1"
  local base
  base="$(project_dir "$project")"

  mkdir -p \
    "$base/team" \
    "$base/workspace/shared/discussions" \
    "$base/workspace/shared/meetings" \
    "$base/workspace/shared/announcements" \
    "$base/workspace/teams/research" \
    "$base/workspace/teams/developer" \
    "$base/workspace/teams/systems-engineer" \
    "$base/memory/discussion" \
    "$base/memory/manager" \
    "$base/memory/researcher" \
    "$base/memory/developer" \
    "$base/memory/systems-engineer" \
    "$base/memory/monitoring" \
    "$base/memory/onboarding" \
    "$base/memory/knowledge/lessons" \
    "$base/memory/knowledge/docs" \
    "$base/memory/knowledge/discussions" \
    "$base/memory/knowledge/meetings" \
    "$base/memory/knowledge/archives" \
    "$base/runtime/message-queue" \
    "$base/runtime/message-locks" \
    "$base/runtime/manager" \
    "$base/logs" \
    "$base/reports/tasks"
}

write_onboarding_systems_engineer_team_md() {
  local project="$1"
  local team_md
  team_md="$(project_team_role_doc_path "$project" "systems-engineer")"

  cat > "$team_md" <<EOF
# ${project} — Systems Engineer 프로젝트 지침

이 파일은 \`agents/systems-engineer/profile.md\`를 보충한다.

## 이 프로젝트에서의 초점
- 시스템 변경 전마다 \`memory/knowledge/docs/change-authority.md\`를 확인하고, 실제 표면과 근거를 최신 상태로 유지한다.

## 이 프로젝트에서의 제한
- 문서에 없는 원격 시스템 write는 금지다.
- 정책이 애매하거나 새로운 변경이 필요하면 Manager를 통해 사용자 합의를 받고, 이 문서와 \`change-authority.md\`를 먼저 갱신한다.

## 시스템 변경 권한
- 기본값: 명시되지 않은 원격 시스템 \`write/apply/restart/deploy/data change\`는 금지
- Ralph 자율 실행: 미정 (온보딩 시 프로젝트별로 확정)
- 판단 순서:
  1. 이 표의 환경별 정책 확인
  2. \`memory/knowledge/docs/change-authority.md\`의 실제 표면/근거 확인
  3. 두 문서가 모두 허용할 때만 실행
- \`read\` 성격의 조사/진단 명령은 허용. 단, secret 값은 저장하지 않는다.

| 환경 | read | config-change | deploy | service-restart | data-change |
|------|------|---------------|--------|-----------------|-------------|
| prod | 허용 | 금지 | 금지 | 금지 | 금지 |
| staging | 허용 | 금지 | 금지 | 금지 | 금지 |
| dev | 허용 | 금지 | 금지 | 금지 | 금지 |
EOF
}

write_onboarding_change_authority_md() {
  local project="$1"
  local authority_md
  authority_md="$(project_change_authority_doc_path "$project")"

  cat > "$authority_md" <<'EOF'
# 시스템 변경 권한 근거

- **마지막 검증 시각**: 미정
- **검증 환경**: 미정
- **검증 근거 종류**: 미정
- **Ralph 자율 권한**: 미정

## 목적
- Systems Engineer가 실제로 수정 가능한 시스템 표면과 근거를 기록한다.
- 이 문서에 없는 원격 시스템 write는 금지다.
- 애매하거나 새 변경이 필요하면 Manager가 사용자 합의를 받아 이 문서를 갱신한다.

## 표면 목록
| 환경 | 표면 | 허용 행동 | Ralph 자율 | 금지 행동 | 근거 | 마지막 확인 |
|------|------|-----------|------------|-----------|------|-------------|
| prod | 미정 | 없음 | 미정 | 모든 write | 온보딩 전 | 미정 |
| staging | 미정 | 없음 | 미정 | 모든 write | 온보딩 전 | 미정 |
| dev | 미정 | 없음 | 미정 | 모든 write | 온보딩 전 | 미정 |
EOF
}

write_onboarding_bootstrap_project_md() {
  local project="$1"
  local project_md
  project_md="$(project_dir "$project")/project.md"

  cat > "$project_md" <<EOF
# Project: ${project}

## 기본 정보
- **Domain**: general
- **Started**: $(date +%Y-%m-%d)

## 목표
온보딩 전. 유저와 대화하며 구체화할 예정.

## 배경
새 프로젝트 bootstrap 초안 상태. onboarding이 기존 작업물 확인과 대화를 통해 내용을 채운다.

## 프로젝트 폴더
- **경로**: 미정

## 기존 자원
- **코드**: 미정
- **데이터**: 미정
- **참고 자료**: 미정
- **진행 상태**: 온보딩 전

## 제약사항
- **컴퓨팅**: 미정
- **시간**: 미정
- **데이터**: 미정
- **기술**: 미정
- **기타**: 미정

## 성공 기준
온보딩 전. 유저와 합의 후 작성.

## 운영 방식
- **실행 모드**: pending
- **control-plane 백엔드**: pending
- **작업 루프**: pending
- **랄프 완료 기준**: 미정
- **랄프 종료 방식**: 미정
- **보고 빈도**: 미정
- **보고 채널**: 미정
- **자율 범위**: 미정
- **긴급 알림**: 미정
- **프레임워크 디버깅**: off
- **기술적 전제조건**: 미정
- **시스템 변경 권한**: 기본 금지. 상세는 team/systems-engineer.md 와 memory/knowledge/docs/change-authority.md 참고

## 팀 구성
- **활성 에이전트**: 미정
  - `manager`, `discussion`은 control-plane 역할이라 bootstrap 이후 자동 부팅된다.
- **커스터마이징**: 기본

## 현재 상태
Onboarding 시작 전 bootstrap 초안. boot-onboarding이 생성했으며, onboarding 과정에서 갱신된다.
EOF
}

ensure_onboarding_project_bootstrap() {
  local project="$1"
  local base project_md knowledge_index team_systems_md change_authority_md
  base="$(project_dir "$project")"
  project_md="${base}/project.md"
  knowledge_index="${base}/memory/knowledge/index.md"
  team_systems_md="$(project_team_role_doc_path "$project" "systems-engineer")"
  change_authority_md="$(project_change_authority_doc_path "$project")"

  ensure_onboarding_project_layout "$project"

  if [ ! -f "$project_md" ]; then
    write_onboarding_bootstrap_project_md "$project"
  fi

  if [ ! -f "$knowledge_index" ]; then
    cat > "$knowledge_index" <<'EOF'
# 지식 지도

- 초기 bootstrap 상태. onboarding과 이후 에이전트가 핵심 문서 링크를 정리한다.
EOF
  fi

  if [ ! -f "$team_systems_md" ]; then
    write_onboarding_systems_engineer_team_md "$project"
  fi

  if [ ! -f "$change_authority_md" ]; then
    write_onboarding_change_authority_md "$project"
  fi
}

sessions_file() {
  echo "$(project_dir "$1")/memory/manager/sessions.md"
}

# project.md에서 활성 에이전트 목록 추출
# "활성 에이전트" 줄에서 역할 이름을 파싱한다
get_active_agents() {
  local project="$1"
  local project_md="$(project_dir "$project")/project.md"
  if [ ! -f "$project_md" ]; then
    echo "Error: project.md가 없다: $project_md" >&2
    exit 1
  fi
  # "활성 에이전트" 줄에서 역할 이름 추출 (소문자)
  grep -i "활성 에이전트" "$project_md" \
    | sed 's/.*: *//' \
    | tr ',' '\n' \
    | sed 's/^ *//;s/ *$//' \
    | tr '[:upper:]' '[:lower:]' \
    | grep -v '^$'
}

# profile.md의 <!-- agent-meta --> 블록에서 키 값 추출
parse_agent_meta() {
  local role="$1"
  local key="$2"
  local profile="$REPO_ROOT/agents/${role}/profile.md"
  if [ ! -f "$profile" ]; then
    return 0
  fi
  sed -n '/<!-- agent-meta/,/-->/p' "$profile" \
    | grep "^${key}:" \
    | sed "s/^${key}: *//"
}

# 역할별 모델 선택 (profile.md 메타데이터 → fallback 하드코딩)
get_model() {
  local role="$1"
  local meta_model
  meta_model=$(parse_agent_meta "$role" "model")
  if [ -n "$meta_model" ]; then
    echo "$meta_model"
    return
  fi
  # fallback: 메타데이터 없을 때
  case "$role" in
    monitoring) echo "haiku" ;;
    *)          echo "opus" ;;
  esac
}

# 역할별 reasoning effort 선택 (profile.md 메타데이터 → fallback 하드코딩)
get_reasoning_effort() {
  local role="$1"
  local meta_effort
  meta_effort=$(parse_agent_meta "$role" "reasoning-effort")
  if [ -n "$meta_effort" ]; then
    echo "$meta_effort"
    return
  fi
  case "$role" in
    manager|discussion|developer|researcher|systems-engineer|onboarding)
      echo "high"
      ;;
    monitoring)
      echo "low"
      ;;
    *)
      echo "medium"
      ;;
  esac
}

# 역할별 허용 도구 (profile.md 메타데이터)
get_allowed_tools() {
  local role="$1"
  parse_agent_meta "$role" "allowed-tools"
}

role_supports_dual() {
  local role="$1"
  case "$role" in
    developer|researcher) return 0 ;;
    *) return 1 ;;
  esac
}

role_uses_dual_worktree() {
  local role="$1"
  case "$role" in
    developer|researcher|systems-engineer) return 0 ;;
    *) return 1 ;;
  esac
}

get_active_session_entries() {
  local project="$1"
  local sessions_path
  sessions_path="$(sessions_file "$project")"
  [ -f "$sessions_path" ] || return 0

  awk -F'|' '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    /\| active \|/ {
      role = trim($2)
      backend = trim($3)
      tmux_target = trim($5)
      status = trim($6)
      if (status != "active") {
        next
      }
      count = split(tmux_target, parts, ":")
      win_name = parts[count]
      if (win_name != "") {
        print win_name "|" backend "|" role
      }
    }
  ' "$sessions_path"
}

guard_claude_recovery() {
  local action="$1"
  local project="$2"
  local sess="$3"
  local window_name="$4"

  if ! claude_recovery_blocked "$project" "$sess" "$window_name"; then
    return 0
  fi

  python3 "$TOOLS_DIR/log.py" system "$project" orchestrator auth_blocked_recovery_skip "$window_name" \
    --detail action="$action" reason="$(runtime_get_agent_health_detail "$project" "$window_name" "auth-blocked" 2>/dev/null || echo "auth-blocked")" || true
  echo "Warning: ${window_name} Claude auth blocked. ${action} 중단; 기존 pane/task/report 가시성 유지." >&2
  return 1
}

print_agent_health_status() {
  local project="$1"
  local sess="$2"
  local emitted=0

  while IFS='|' read -r win_name backend role; do
    [ -n "$win_name" ] || continue
    local health_state health_detail
    health_state="$(agent_classify_window_health "$project" "$sess" "$win_name" "$backend" 2>/dev/null || true)"
    health_detail="${health_state#*|}"
    health_state="${health_state%%|*}"
    if [ "$health_state" = "AUTH_BLOCKED" ]; then
      if [ "$emitted" -eq 0 ]; then
        echo "[agent-health]"
        emitted=1
      fi
      echo "  ${win_name} (${role}/${backend}): AUTH_BLOCKED ${health_detail:+(${health_detail})}"
    fi
  done < <(get_active_session_entries "$project")

  if [ "$emitted" -eq 0 ]; then
    echo "[agent-health] 이상 없음"
  fi
}

role_uses_ralph_worktree() {
  local role="$1"
  case "$role" in
    developer|systems-engineer) return 0 ;;
    *) return 1 ;;
  esac
}

role_supports_native_subagents() {
  local role="$1"
  case "$role" in
    manager|discussion|developer|researcher|systems-engineer) return 0 ;;
    *) return 1 ;;
  esac
}

native_subagent_runtime_triage_lines() {
  local role="$1"
  case "$role" in
    researcher)
      cat <<'EOF'
    - task triage를 먼저 해라: 작고 명확한 조사는 search-specialist 또는 code-mapper 1개부터, 비사소하지만 bounded면 search-specialist + docs-researcher 또는 docs-researcher + consensus-reviewer를 기본으로 잡아라.
    - 더 빠른/가벼운 모델과 낮은 effort는 검색, evidence 수집, 비교 초안에 먼저 쓰고, 더 강한 모델과 높은 effort는 recommendation, contract 비교, 최종 위험 판정에 우선 배치해라.
EOF
      ;;
    systems-engineer)
      cat <<'EOF'
    - task triage를 먼저 해라: 작고 명확한 감사/확인은 runtime-auditor 1개부터, 비사소하지만 bounded면 runtime-auditor + code-mapper를 기본으로 잡아라.
    - 더 빠른/가벼운 모델과 낮은 effort는 runtime 사실 확인과 구조 맵핑에 먼저 쓰고, 더 강한 모델과 높은 effort는 ambiguous drift, rollback gate, cross-system risk 판정에 우선 배치해라.
EOF
      ;;
    *)
      cat <<'EOF'
    - task triage를 먼저 해라: 작고 명확하면 scout 1개 또는 direct 예외, 비사소하지만 bounded면 2-way map/debug 기본, 복잡/애매/merge-risk면 stronger model + reviewer/architect 계열을 우선 고려해라.
    - 더 빠른/가벼운 모델과 낮은 effort는 mapping, evidence 수집, 좁은 verify에 먼저 쓰고, 더 강한 모델과 높은 effort는 구조 경계, 모호한 설계, 고위험 최종 판정에 우선 배치해라.
EOF
      ;;
  esac
}

agent_env_script_path() {
  local project="$1" agent_id="$2"
  printf '%s/runtime/agent-env/%s.sh\n' "$(project_dir "$project")" "$agent_id"
}

write_agent_env_script() {
  local project="$1" role="$2" agent_id="$3"
  local script_path base_path tmux_socket_name
  script_path="$(agent_env_script_path "$project" "$agent_id")"
  base_path="$PATH"

  local env_dir
  env_dir="$(dirname "$script_path")"
  mkdir -p "$env_dir"
  chmod 700 "$env_dir"

  # agent_id 검증 (쉘 인젝션 방지 — H-02 수정)
  if [[ "$agent_id" =~ [^a-zA-Z0-9_-] ]]; then
    echo "Error: 잘못된 agent_id: '$agent_id' (영문/숫자/하이픈/밑줄만 허용)" >&2
    return 1
  fi

  {
    printf 'export PATH=%q\n' "$base_path"
    printf 'export WHIPLASH_REPO_ROOT=%q\n' "$REPO_ROOT"
    printf 'export WHIPLASH_TMUX_PROJECT=%q\n' "$project"
    printf 'export WHIPLASH_NATIVE_CLAUDE_AGENTS=%q\n' "${REPO_ROOT}/.claude/agents"
    printf 'export WHIPLASH_NATIVE_CODEX_AGENTS=%q\n' "${REPO_ROOT}/.codex/agents"
    env | awk -F= '
      /^(WHIPLASH_FAKE_CLAUDE_|WHIPLASH_FAKE_CODEX_)/ {
        key=$1
        sub(/^[^=]+=*/, "", $0)
        value=$0
        gsub(/\047/, "\047\\\047\047", value)
        printf("export %s=\047%s\047\n", key, value)
      }
    '
  } > "$script_path"
  chmod 600 "$script_path"

  printf '%s\n' "$script_path"
}

run_with_agent_env() {
  local project="$1" role="$2" agent_id="$3"
  shift 3
  local script_path
  script_path="$(agent_env_script_path "$project" "$agent_id")"
  (
    if [ -f "$script_path" ]; then
      # shellcheck source=/dev/null
      . "$script_path"
    fi
    cd "$REPO_ROOT"
    "$@"
  )
}

build_claude_session_bootstrap_prompt() {
  cat <<'BOOTSTRAP'
너는 Whiplash bootstrap 단계다.
지금은 session_id만 만들기 위한 초기 호출이다.
도구를 사용하지 말고, 파일도 읽지 말고, 명령도 실행하지 말고, 한 줄로 READY만 답해라.
BOOTSTRAP
}

process_or_child_named() {
  local pid="$1"
  local process_name="$2"
  [ -n "$pid" ] || return 1

  local comm child_pid child_cmd
  comm="$(ps -p "$pid" -o comm= 2>/dev/null | head -1 || true)"
  if agent_backend_command_matches "$process_name" "$comm"; then
    return 0
  fi

  while IFS= read -r child_pid; do
    [ -n "$child_pid" ] || continue
    child_cmd="$(ps -o comm= -p "$child_pid" 2>/dev/null | head -1 || true)"
    if agent_backend_command_matches "$process_name" "$child_cmd"; then
      return 0
    fi
  done < <(pgrep -P "$pid" 2>/dev/null || true)

  return 1
}

window_indices_by_name() {
  local sess="$1"
  local window_name="$2"
  tmux list-windows -t "$sess" -F '#I|#{window_name}' 2>/dev/null \
    | awk -F'|' -v target="$window_name" '$2 == target { print $1 }'
}

kill_windows_by_name() {
  local sess="$1"
  local window_name="$2"
  local send_exit="${3:-0}"
  local indices
  indices="$(window_indices_by_name "$sess" "$window_name" | sort -rn)"
  [ -n "$indices" ] || return 0

  local idx
  if [ "$send_exit" = "1" ]; then
    while IFS= read -r idx; do
      [ -n "$idx" ] || continue
      tmux send-keys -t "${sess}:${idx}" "/exit" Enter 2>/dev/null || true
    done <<< "$indices"
    sleep 2
  fi

  while IFS= read -r idx; do
    [ -n "$idx" ] || continue
    tmux kill-window -t "${sess}:${idx}" 2>/dev/null || true
  done <<< "$indices"
}

get_manager_backend() {
  local project="${1:-}"
  local backend="${WHIPLASH_MANAGER_BACKEND:-}"

  if [ -n "$backend" ]; then
    case "$backend" in
      claude|codex)
        echo "$backend"
        return
        ;;
    esac
  fi

  if [ -n "$project" ]; then
    local project_md parsed
    project_md="$(project_dir "$project")/project.md"
    parsed=$({ grep -i "control-plane backend\|control-plane 백엔드" "$project_md" 2>/dev/null || true; } \
      | head -1 \
      | sed 's/.*: *//' \
      | sed 's/ *(.*)//' \
      | tr -d '[:space:]' \
      | tr -d '*|' \
      | tr '[:upper:]' '[:lower:]')
    case "$parsed" in
      claude|codex)
        echo "$parsed"
        return
        ;;
    esac
  fi

  echo "codex"
}

get_codex_model() {
  if [ -n "${WHIPLASH_CODEX_MODEL:-}" ]; then
    echo "$WHIPLASH_CODEX_MODEL"
    return
  fi

  local cfg
  for cfg in "${REPO_ROOT}/.codex/config.toml" "${HOME}/.codex/config.toml"; do
    if [ ! -f "$cfg" ]; then
      continue
    fi
    local model
    model=$(sed -n 's/^model = "\(.*\)"/\1/p' "$cfg" | head -1)
    if [ -n "$model" ]; then
      echo "$model"
      return
    fi
  done

  echo "codex"
}

get_codex_frontend_mode() {
  echo "interactive"
}

prepare_codex_bootstrap_file() {
  local project="$1"
  local agent_id="$2"
  local boot_msg="$3"
  local bootstrap_dir bootstrap_path
  bootstrap_dir="$(runtime_root_dir "$project")/bootstrap"
  bootstrap_path="${bootstrap_dir}/${agent_id}.md"
  mkdir -p "$bootstrap_dir"
  printf '%s\n' "$boot_msg" > "$bootstrap_path"
  printf '%s\n' "$bootstrap_path"
}

build_codex_bootstrap_prompt() {
  local bootstrap_path="$1"
  printf '%s' "Read ${bootstrap_path} and follow it exactly. Start with Layer 1, continue through onboarding, run the required readiness command from that file, and then wait for the next instruction. Do not paste the file contents back."
}

build_codex_env_prefix() {
  local model_override="${1:-${WHIPLASH_CODEX_MODEL:-}}"
  local reasoning_effort_override="${2:-${WHIPLASH_CODEX_REASONING_EFFORT:-}}"
  local service_tier_override="${3:-${WHIPLASH_CODEX_SERVICE_TIER:-}}"
  local env_prefix="env"
  if [ -n "$model_override" ]; then
    env_prefix+=" WHIPLASH_CODEX_MODEL=$(printf '%q' "$model_override")"
  fi
  if [ -n "$reasoning_effort_override" ]; then
    env_prefix+=" WHIPLASH_CODEX_REASONING_EFFORT=$(printf '%q' "$reasoning_effort_override")"
  fi
  if [ -n "$service_tier_override" ]; then
    env_prefix+=" WHIPLASH_CODEX_SERVICE_TIER=$(printf '%q' "$service_tier_override")"
  fi
  echo "$env_prefix"
}

send_codex_prompt_tmux() {
  local tmux_target="$1"
  local prompt="$2"
  tmux_submit_pasted_payload "$tmux_target" "$prompt" "codex-prompt"
}


# 역할별 도메인 파일 경로 (있으면 반환)
get_domain() {
  local project="$1"
  local project_md="$(project_dir "$project")/project.md"
  if [ ! -f "$project_md" ]; then
    return 0
  fi
  awk '
    function clean(line) {
      gsub(/\*\*/, "", line)
      gsub(/`/, "", line)
      gsub(/\|/, "", line)
      sub(/[[:space:]]*\(.*/, "", line)
      gsub(/[[:space:]]+$/, "", line)
      gsub(/^[[:space:]]+/, "", line)
      return line
    }
    /^[[:space:]]*[-*][[:space:]]*/ && /(Domain|도메인)/ && /[:：]/ {
      line = $0
      sub(/^[^:：]*[:：][[:space:]]*/, "", line)
      print clean(line)
      exit
    }
  ' "$project_md"
}

# project.md에서 실행 모드 추출 (solo | dual, 기본값 solo)
get_exec_mode() {
  local project="$1"
  local project_md="$(project_dir "$project")/project.md"
  local mode
  mode=$({ grep -i "실행 모드" "$project_md" 2>/dev/null || true; } \
    | head -1 \
    | sed 's/.*: *//' \
    | sed 's/ *(.*)//' \
    | tr -d '[:space:]' \
    | tr -d '*|' \
    | tr '[:upper:]' '[:lower:]')
  if [ "$mode" = "dual" ]; then echo "dual"; else echo "solo"; fi
}

# project.md에서 작업 루프 추출 (guided | ralph, 기본값 guided)
get_loop_mode() {
  local project="$1"
  local project_md="$(project_dir "$project")/project.md"
  local mode
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

get_ralph_completion_mode() {
  local project="$1"
  local project_md="$(project_dir "$project")/project.md"
  local mode
  mode=$({ grep -i "랄프 종료 방식" "$project_md" 2>/dev/null || true; } \
    | head -1 \
    | sed 's/.*: *//' \
    | sed 's/ *(.*)//' \
    | tr -d '[:space:]' \
    | tr -d '*|' \
    | tr '[:upper:]' '[:lower:]')
  case "$mode" in
    continue-until-no-improvement|continue_until_no_improvement|open-ended|open_ended)
      echo "continue-until-no-improvement"
      ;;
    *)
      echo "stop-on-criteria"
      ;;
  esac
}

get_project_stage() {
  local project="$1"
  ensure_manager_runtime_layout "$project"
  runtime_get_manager_state "$project" "project_stage" "active" 2>/dev/null || printf 'active\n'
}

set_project_stage() {
  local project="$1"
  local stage="$2"
  ensure_manager_runtime_layout "$project"
  runtime_set_manager_state "$project" "project_stage" "$stage"
}

clear_project_stage() {
  local project="$1"
  ensure_manager_runtime_layout "$project"
  runtime_clear_manager_state "$project" "project_stage" || true
}

onboarding_helper_role_allowed() {
  local role="$1"
  case "$role" in
    researcher|systems-engineer) return 0 ;;
    *) return 1 ;;
  esac
}

validate_onboarding_helper_window_name() {
  local window_name="$1"
  if [[ "$window_name" != onboarding-* ]]; then
    echo "Error: onboarding 분석 단계 보조 에이전트 윈도우 이름은 'onboarding-' 접두어가 필요하다: '$window_name'" >&2
    return 1
  fi
  return 0
}

validate_spawn_for_project_stage() {
  local project="$1"
  local role="$2"
  local window_name="$3"
  local stage
  stage="$(get_project_stage "$project")"

  if [ "$stage" != "onboarding" ]; then
    return 0
  fi

  if ! onboarding_helper_role_allowed "$role"; then
    echo "Error: onboarding 분석 단계에서는 researcher 또는 systems-engineer만 spawn할 수 있다. 입력 role: '$role'" >&2
    return 1
  fi

  validate_onboarding_helper_window_name "$window_name" || return 1
  return 0
}

# project.md에서 프로젝트 폴더 (코드 레포) 경로 추출
get_code_repo() {
  local project="$1"
  local project_md="$(project_dir "$project")/project.md"
  if [ ! -f "$project_md" ]; then
    return 0
  fi

  local section_path
  section_path=$(
    awk '
      function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
      /^##[[:space:]]+프로젝트[[:space:]]+폴더/ { in_section = 1; next }
      /^##[[:space:]]+/ && in_section { in_section = 0 }
      in_section && /경로/ {
        line = $0
        sub(/.*: */, "", line)
        gsub(/`/, "", line)
        gsub(/\*\*/, "", line)
        gsub(/\|/, "", line)
        line = trim(line)
        sub(/ *\(.*/, "", line)
        sub(/\/+$/, "", line)
        print line
        exit
      }
    ' "$project_md"
  )
  if [ -n "$section_path" ]; then
    printf '%s\n' "$section_path"
    return
  fi

  { grep -i "프로젝트 폴더" "$project_md" 2>/dev/null || true; } \
    | head -1 \
    | sed 's/.*: *//' \
    | sed 's/ *(.*//' \
    | sed 's#/*$##' \
    | tr -d '[:space:]' \
    | tr -d '*|'
}

# 듀얼 모드 worktree에서 메인 레포의 top-level ignored 지원 디렉토리를 재사용한다.
# 예: states/, node_modules/, .venv/ 등. tracked 파일의 상대 참조가 worktree에서 깨지는 것을 막는다.
sync_worktree_support_paths() {
  local code_repo="$1"
  local wt_path="$2"
  [ -d "$code_repo" ] || return 0
  [ -d "$wt_path" ] || return 0

  local ignored_dirs
  ignored_dirs=$(
    git -C "$code_repo" ls-files --others --ignored --exclude-standard --directory --no-empty-directory 2>/dev/null \
      | sed 's#/$##' \
      | awk -F'/' 'NF { print $1 }' \
      | sort -u
  ) || ignored_dirs=""

  [ -n "$ignored_dirs" ] || return 0

  while IFS= read -r dir_name; do
    [ -n "$dir_name" ] || continue
    case "$dir_name" in
      .git|.worktrees) continue ;;
    esac

    local src="${code_repo}/${dir_name}"
    local dst="${wt_path}/${dir_name}"
    [ -d "$src" ] || continue

    if [ -L "$dst" ]; then
      local current_target
      current_target=$(readlink "$dst" 2>/dev/null || true)
      if [ "$current_target" = "$src" ]; then
        continue
      fi
      rm -f "$dst"
    elif [ -e "$dst" ]; then
      continue
    fi

    if ! ln -s "$src" "$dst" 2>/dev/null; then
      echo "Warning: support 디렉토리 링크 실패: ${dst} -> ${src}" >&2
    fi
  done <<< "$ignored_dirs"
}

# 듀얼 모드용 git worktree 생성 (멱등)
create_worktrees() {
  local project="$1"
  local role="$2"
  local code_repo
  code_repo="$(get_code_repo "$project")"
  if [ -z "$code_repo" ] || [ ! -d "$code_repo" ]; then
    echo "Warning: 프로젝트 폴더가 설정되지 않았거나 존재하지 않음. worktree 생성 건너뜀." >&2
    return 0
  fi

  local wt_dir="${code_repo}/.worktrees"
  mkdir -p "$wt_dir"

  for backend in claude codex; do
    local wt_path="${wt_dir}/${role}-${backend}"
    local branch="dual/${role}-${backend}"
    if [ -d "$wt_path" ]; then
      echo "Info: worktree ${wt_path} 이미 존재. 건너뜀." >&2
      sync_worktree_support_paths "$code_repo" "$wt_path"
      continue
    fi

    if ! git -C "$code_repo" worktree add "$wt_path" -b "$branch" 2>&1; then
      echo "Warning: worktree 생성 실패: ${wt_path}" >&2
      continue
    fi

    sync_worktree_support_paths "$code_repo" "$wt_path"
  done
}

# 듀얼 모드용 git worktree + 브랜치 정리
remove_worktrees() {
  local project="$1"
  local role="$2"
  local code_repo
  code_repo="$(get_code_repo "$project")"
  if [ -z "$code_repo" ] || [ ! -d "$code_repo" ]; then
    return 0
  fi

  local wt_dir="${code_repo}/.worktrees"

  for backend in claude codex; do
    local wt_path="${wt_dir}/${role}-${backend}"
    local branch="dual/${role}-${backend}"
    if [ -d "$wt_path" ]; then
      git -C "$code_repo" worktree remove "$wt_path" --force 2>/dev/null || true
    fi
    git -C "$code_repo" branch -D "$branch" 2>/dev/null || true
  done

  # .worktrees 디렉토리가 비었으면 삭제
  if [ -d "$wt_dir" ] && [ -z "$(ls -A "$wt_dir" 2>/dev/null)" ]; then
    rmdir "$wt_dir" 2>/dev/null || true
  fi
}

create_agent_worktree() {
  local project="$1"
  local agent_id="$2"
  local code_repo
  code_repo="$(get_code_repo "$project")"
  if [ -z "$code_repo" ] || [ ! -d "$code_repo" ]; then
    return 0
  fi

  local wt_dir="${code_repo}/.worktrees"
  local wt_path="${wt_dir}/${agent_id}"
  local branch="dual/${agent_id}"
  mkdir -p "$wt_dir"

  if [ -d "$wt_path" ]; then
    sync_worktree_support_paths "$code_repo" "$wt_path"
    return 0
  fi

  if ! git -C "$code_repo" worktree add "$wt_path" -b "$branch" 2>&1; then
    echo "Warning: extra agent worktree 생성 실패: ${wt_path}" >&2
    return 1
  fi

  sync_worktree_support_paths "$code_repo" "$wt_path"
  return 0
}

remove_agent_worktree() {
  local project="$1"
  local agent_id="$2"
  local code_repo
  code_repo="$(get_code_repo "$project")"
  if [ -z "$code_repo" ] || [ ! -d "$code_repo" ]; then
    return 0
  fi

  local wt_dir="${code_repo}/.worktrees"
  local wt_path="${wt_dir}/${agent_id}"
  local branch="dual/${agent_id}"

  if [ -d "$wt_path" ]; then
    git -C "$code_repo" worktree remove "$wt_path" --force 2>/dev/null || true
  fi
  git -C "$code_repo" branch -D "$branch" 2>/dev/null || true
}

ralph_worktree_agent_id() {
  local agent_id="$1"
  if [[ "$agent_id" == *-ralph ]]; then
    echo "$agent_id"
  else
    echo "${agent_id}-ralph"
  fi
}

create_ralph_worktree() {
  local project="$1"
  local agent_id="$2"
  local code_repo
  code_repo="$(get_code_repo "$project")"
  if [ -z "$code_repo" ] || [ ! -d "$code_repo" ]; then
    return 0
  fi

  local wt_agent_id wt_dir wt_path branch
  wt_agent_id="$(ralph_worktree_agent_id "$agent_id")"
  wt_dir="${code_repo}/.worktrees"
  wt_path="${wt_dir}/${wt_agent_id}"
  branch="ralph/${wt_agent_id}"
  mkdir -p "$wt_dir"

  if [ -d "$wt_path" ]; then
    sync_worktree_support_paths "$code_repo" "$wt_path"
    return 0
  fi

  if ! git -C "$code_repo" worktree add "$wt_path" -b "$branch" 2>&1; then
    echo "Warning: ralph worktree 생성 실패: ${wt_path}" >&2
    return 1
  fi

  sync_worktree_support_paths "$code_repo" "$wt_path"
  return 0
}

remove_ralph_worktree() {
  local project="$1"
  local agent_id="$2"
  local code_repo
  code_repo="$(get_code_repo "$project")"
  if [ -z "$code_repo" ] || [ ! -d "$code_repo" ]; then
    return 0
  fi

  local wt_agent_id wt_dir wt_path branch
  wt_agent_id="$(ralph_worktree_agent_id "$agent_id")"
  wt_dir="${code_repo}/.worktrees"
  wt_path="${wt_dir}/${wt_agent_id}"
  branch="ralph/${wt_agent_id}"

  if [ -d "$wt_path" ]; then
    git -C "$code_repo" worktree remove "$wt_path" --force 2>/dev/null || true
  fi
  git -C "$code_repo" branch -D "$branch" 2>/dev/null || true
}

# 부팅 메시지 생성
build_boot_message() {
  local role="$1"
  local project="$2"
  local extra="${3:-}"
  local agent_id="${4:-$role}"
  local pending_task="${5:-}"
  local ready_target="${6:-}"
  local domain
  domain="$(get_domain "$project")"
  domain="${domain:-general}"
  local message_cmd="bash \"$TOOLS_DIR/message.sh\""
  local layer2_domain_line
  local layer3_domain_line
  local need_input_action
  local mutation_safety_note
  local native_subagent_note=""
  local loop_mode
  local ralph_completion_mode
  local loop_mode_note=""
  local user_notice_cmd="bash \"$TOOLS_DIR/user-notify.sh\""

  loop_mode="$(get_loop_mode "$project")"
  ralph_completion_mode="$(get_ralph_completion_mode "$project")"

  if [ -z "$ready_target" ] && { [ "$role" = "manager" ] || [ "$role" = "onboarding" ] || [ "$role" = "discussion" ]; }; then
    ready_target="user"
  elif [ -z "$ready_target" ]; then
    ready_target="manager"
  fi

  if [ "$domain" = "general" ]; then
    layer2_domain_line="6. 이 프로젝트 도메인은 general이다. 추가 domain context는 없다."
    layer3_domain_line="8. general 도메인이므로 role-specific domain 파일도 없다."
  else
    layer2_domain_line="6. (파일이 있으면) domains/${domain}/context.md 읽기"
    layer3_domain_line="8. (파일이 있으면) domains/${domain}/${role}.md"
  fi

  need_input_action="- need_input: 응답 필요"
  if [ "$role" = "manager" ]; then
    need_input_action="- need_input: 응답 필요. 특히 monitor의 \"plan mode 판단 필요\" 알림을 받으면 해당 agent pane 최근 출력과 task/report 맥락을 읽고, 승인 대기인지 단순 설계 단계인지 판단해 지시 또는 승인 여부를 결정"
  fi

  if role_supports_native_subagents "$role"; then
    native_subagent_note="$(cat <<BOOTRULES
13. 이 레포에는 repo-local native subagent pack이 있다:
    - Claude Code: ${REPO_ROOT}/.claude/agents/
    - Codex CLI: ${REPO_ROOT}/.codex/agents/
    - 비사소한 작업은 agents/${role}/techniques/subagent-orchestration.md 를 초기에 읽고, 기본적으로 최소 1개 이상 specialist를 먼저 호출해라.
    - 복잡한 작업은 2-way 이상 병렬 fan-out을 기본값으로 삼아라.
$(native_subagent_runtime_triage_lines "$role")
    - execution lead라면 어떤 specialist를 부를지 네가 판단한다. manager는 outcome/제약을 주고, 내부 fan-out 조합은 세세히 지시하지 않는다.
    - 최종 권한과 공식 산출물 책임은 항상 너에게 있다. subagent 결과를 그대로 최종본으로 내지 마라.
BOOTRULES
)"
  else
    native_subagent_note="$(cat <<BOOTRULES
13. Claude Code/Codex CLI가 제공하는 네이티브 subagent / agent team / parallel 기능은 필요 시 활용할 수 있다.
    단, 이 역할의 기본 책임과 권한 경계를 우선한다.
BOOTRULES
)"
  fi

  if [ "$role" = "manager" ] && [ "$loop_mode" = "ralph" ]; then
    loop_mode_note="$(cat <<BOOTRULES
[Ralph loop 규칙]
- 현재 프로젝트의 작업 루프는 ralph 다.
- user 승인/확인 입력을 기다리며 작업을 멈추지 마라.
- manager → user need_input / escalation은 금지다. 대신 ${user_notice_cmd} ${project} "제목" "내용" [level] 로 알리고 계속 진행해라.
- 블로커, scope 축소, 최종 완료는 user_notice로 남겨라.
- discussion 또는 user 개입이 와도 전체 루프를 pause 하지 말고 activity/handoff를 반영한 뒤 해당 레인만 재계획해라.
- 종료 방식: ${ralph_completion_mode}. stop-on-criteria면 project.md의 랄프 완료 기준을 만족할 때 끝내고, continue-until-no-improvement면 완료 기준 충족 후에도 개선 loop를 계속 돌려라.
BOOTRULES
)"
  elif [ "$loop_mode" = "ralph" ]; then
    loop_mode_note="$(cat <<BOOTRULES
[Ralph loop 규칙]
- 현재 프로젝트의 작업 루프는 ralph 다.
- user 확인을 기다리며 멈추지 마라. 필요한 판단은 manager에게 올리고, user-facing 알림은 manager가 user_notice로 처리한다.
- 블로커를 만나면 manager에게 이유와 fallback/options를 짧게 알리고, 가능한 대체 경로로 계속 진행해라.
- discussion이나 user의 새 방향 입력은 pause 신호가 아니라 async 업데이트다. manager의 새 지시가 오면 그 방향으로 흡수해라.
- 종료는 manager가 project.md의 랄프 정책을 만족했다고 판단할 때만 선언한다.
BOOTRULES
)"
  fi

  if [ "$role" = "discussion" ]; then
    local discussion_layer2_domain_line discussion_layer3_domain_line
    if [ "$domain" = "general" ]; then
      discussion_layer2_domain_line="8. 이 프로젝트 도메인은 general이다. 추가 domain context는 없다."
      discussion_layer3_domain_line="9. general 도메인이므로 role-specific domain 파일도 없다."
    else
      discussion_layer2_domain_line="8. (파일이 있으면) domains/${domain}/context.md 읽기"
      discussion_layer3_domain_line="9. (파일이 있으면) domains/${domain}/discussion.md"
    fi

    cat << BOOTMSG
너는 discussion 에이전트다.
레포 루트: ${REPO_ROOT}
현재 프로젝트: projects/${project}/
주의: worktree나 다른 디렉토리로 이동한 뒤에도 whiplash 문서/스크립트는 위 레포 루트 기준 절대경로로 다뤄라.

아래 온보딩 절차를 순서대로 따라라 (Progressive Disclosure — 필요한 것만 필요한 시점에):

[Layer 1 — 필수, 지금 즉시 읽기]
1. agents/common/README.md 읽기
2. agents/discussion/profile.md 읽기
3. projects/${project}/project.md 읽기

[Layer 2 — 전략 대화 시작 시 읽기]
4. memory/manager/activity.md 읽기 (있으면 최근 판단과 변경 이유 확인)
5. memory/onboarding/handoff.md 읽기 (있으면 초기 설계 맥락 확인)
6. memory/knowledge/index.md 읽기 (지도만, 전체 읽기 아님)
7. 해당 대화에 필요한 agents/discussion/techniques/*.md 읽기
${discussion_layer2_domain_line}

[Layer 3 — 필요할 때만 읽기]
8. agents/common/project-context.md (경로 해석 등 필요 시)
${discussion_layer3_domain_line}
10. (해당 시) projects/${project}/team/discussion.md
11. 필요하면 memory/manager/sessions.md, memory/manager/assignments.md, workspace/shared/announcements/ 를 읽어라.
    단, "지금 누가 뭘 하고 있는지"의 공식 source of truth는 manager다.

12. discussion의 기본 산출물:
    - ongoing decision note: memory/discussion/decision-notes.md
    - 실행 변경 handoff: memory/discussion/handoff.md
    - handoff는 유저와 합의되어 실행에 반영되어야 하는 경우에만 갱신한다.

13. 라우팅 규칙:
    - 전략, 설계, 요구사항, 우선순위, 코드 방향 토론은 네가 담당한다.
    - 현재 진행 상황, 누가 작업 중인지, blocker, idle 상태, runtime health는 manager가 담당한다.
    - 상태 질문을 받으면 manager에게 안내하고, 설계 질문을 받으면 스스로 끝까지 토론해라.

14. 권한과 금지:
    - 직접 task_assign, task_complete, reboot, refresh, spawn, merge-worktree, dispatch를 실행하지 마라.
    - developer, researcher, systems-engineer에게 직접 실행 지시하지 마라.
    - 코드 구현이나 리서치 실무를 직접 수행하지 마라.
    - 공식 실행 변경은 handoff 문서로 정리하고 manager에게 status_update로 알려라.

15. manager handoff 알림 예시:
    ${message_cmd} ${project} ${agent_id} manager status_update normal "discussion handoff 준비" "memory/discussion/handoff.md를 읽고 실행 계획에 반영해라"

16. handoff 작성 규칙:
    - 유저와 합의된 내용만 handoff로 승격해라.
    - handoff 알림이 전달되려면 User approved: yes, Why this change, Scope impact, Manager next action 필드가 모두 있어야 한다.
    - 목표, 변경 이유, 영향 범위, manager가 바로 실행에 옮겨야 할 다음 액션을 짧고 명확하게 적어라.
    - 실행 변경이 없으면 decision note만 갱신하고 handoff는 만들지 마라.

17. repo-local native subagent pack:
    - Claude Code: ${REPO_ROOT}/.claude/agents/
    - Codex CLI: ${REPO_ROOT}/.codex/agents/
    - 비사소한 전략 토론은 agents/discussion/techniques/subagent-orchestration.md 를 초기에 읽고, 관련 specialist를 먼저 호출해라.
    - discussion은 전략 토론에 필요한 aide를 스스로 고른다. manager가 discussion 내부 specialist 조합을 세세히 지정하지 않는다.
    - 최종 추천안과 handoff 책임은 항상 너에게 있다.

${loop_mode_note}
${extra}
온보딩이 끝나면 준비 완료를 알림으로 보고해라:
${message_cmd} ${project} ${agent_id} ${ready_target} agent_ready normal "온보딩 완료" "${agent_id} 에이전트 준비 완료"
BOOTMSG

    if [ -n "$pending_task" ]; then
      cat << TASKMSG

[재부팅 후 태스크 복구]
이전 세션에서 중단된 태스크가 있다: ${pending_task}
해당 파일을 읽고 작업을 이어서 진행해라.
TASKMSG
    fi
    return 0
  fi

  if [ "$role" = "systems-engineer" ]; then
    mutation_safety_note="$(cat <<BOOTRULES
15. 외부 반영 안전 규칙:
    - 로컬 파일 수정, 테스트, 빌드, 로컬 git commit은 가능하다.
    - 원격 시스템 변경 전에는 projects/${project}/team/systems-engineer.md 와 projects/${project}/memory/knowledge/docs/change-authority.md 를 다시 읽어라.
    - 문서에 없는 변경이거나 애매하면 manager에게 escalation하고, manager가 프로젝트의 현재 loop 정책에 맞게 판단하게 해라.
BOOTRULES
)"
  else
    mutation_safety_note="$(cat <<BOOTRULES
15. 외부 반영 안전 규칙:
    - 로컬 파일 수정, 테스트, 빌드, 로컬 git commit은 가능하다.
    - 외부 반영이 실제로 필요한 변경은 프로젝트 문서와 현재 지시를 먼저 확인해라.
    - 범위가 애매하면 manager에게 확인을 요청해라. user 직접 승인은 manager가 판단해 처리한다.
BOOTRULES
)"
  fi

  cat << BOOTMSG
너는 ${role} 에이전트다.
레포 루트: ${REPO_ROOT}
현재 프로젝트: projects/${project}/
주의: worktree나 다른 디렉토리로 이동한 뒤에도 whiplash 문서/스크립트는 위 레포 루트 기준 절대경로로 다뤄라.

아래 온보딩 절차를 순서대로 따라라 (Progressive Disclosure — 필요한 것만 필요한 시점에):

[Layer 1 — 필수, 지금 즉시 읽기]
1. agents/common/README.md 읽기
2. agents/${role}/profile.md 읽기
3. projects/${project}/project.md 읽기

[Layer 2 — 첫 태스크 수신 시 읽기]
4. memory/knowledge/index.md 읽기 (지도만, 전체 읽기 아님)
5. 해당 작업에 필요한 agents/${role}/techniques/*.md 읽기
${layer2_domain_line}

[Layer 3 — 필요할 때만 읽기]
7. agents/common/project-context.md (경로 해석 등 필요 시)
${layer3_domain_line}
9. (해당 시) projects/${project}/team/${role}.md

10. top-level task마다 결과 보고서를 작성해라.
    - 경로 규칙: reports/tasks/{task-id}-${agent_id}.md
    - manager가 task_assign를 보낼 때 해당 보고서 stub 경로를 같이 알려준다.
    - task_complete 전에 보고서를 채우고 Status를 final로 바꿔라.

11. 알림 보내기 (상황별 예시. worktree 안에서도 아래 절대경로 명령을 그대로 써라):
   태스크 완료:
     ${message_cmd} ${project} ${agent_id} manager task_complete normal "TASK-XXX 완료" "결과 요약"
   도움 필요:
     ${message_cmd} ${project} ${agent_id} manager need_input normal "방향 선택 필요" "상세 내용"
   긴급 블로커:
     ${message_cmd} ${project} ${agent_id} manager escalation urgent "블로커 발생" "상세 내용"
   다른 에이전트에게:
     ${message_cmd} ${project} ${agent_id} {대상} status_update normal "제목" "내용"
   듀얼 합의 응답:
     ${message_cmd} ${project} ${agent_id} manager consensus_response normal "합의 응답" "prefer_self | prefer_peer | synth 와 근거"

    중요 라우팅 규칙:
    - task_assign는 manager만 보낸다. manager가 아니면 보내지 마라.
    - task_complete, agent_ready, reboot_notice의 정식 수신자는 manager다.
    - peer direct는 status_update, need_input, escalation, consensus_request, consensus_response만 허용된다.
    - peer direct 메시지는 manager에도 자동 미러링된다. 별도 참조 전달을 다시 할 필요 없다.
    - 다른 에이전트에게 "완료했다"를 알릴 때는 task_complete가 아니라 status_update를 써라.

12. 알림 받기 — 작업 중 아래 형식의 한 줄 알림이 올 수 있다:
    [notify] {보낸이} → {나} | {종류} | 제목: {제목} | 내용: {내용}

    종류별 행동:
    - task_complete: 태스크 결과 확인 후 다음 단계
    - status_update: 참고
${need_input_action}
    - escalation: 긴급 처리
    - agent_ready: 에이전트 준비 확인
    - reboot_notice: 에이전트 복구 상태 확인
    - consensus_request: 비교 문서를 읽고 consensus_response로 답변

${native_subagent_note}
${loop_mode_note}

${mutation_safety_note}
${extra}
$(
  # 듀얼 모드 워크트리 경로 안내
  _exec_mode="$(get_exec_mode "$project")"
  _loop_mode="$(get_loop_mode "$project")"
  _code_repo="$(get_code_repo "$project")"
  if [ "$_exec_mode" = "dual" ] && [ -n "$_code_repo" ] && { [[ "$agent_id" == *-claude ]] || [[ "$agent_id" == *-codex ]]; }; then
    echo "작업 디렉토리: ${_code_repo}/.worktrees/${agent_id}/"
    echo "주의: 반드시 이 디렉토리 안에서만 코드를 수정하라. 메인 레포를 직접 수정하지 마라."
  elif [ "$_loop_mode" = "ralph" ] && [ -n "$_code_repo" ] && role_uses_ralph_worktree "$role"; then
    _ralph_agent_id="$(ralph_worktree_agent_id "$agent_id")"
    echo "작업 디렉토리: ${_code_repo}/.worktrees/${_ralph_agent_id}/"
    echo "주의: ralph 루프에서는 이 worktree 상태를 기준으로 이어서 작업한다. 메인 레포 대신 이 경로를 우선 사용해라."
  fi
)
온보딩이 끝나면 준비 완료를 알림으로 보고해라:
${message_cmd} ${project} ${agent_id} ${ready_target} agent_ready normal "온보딩 완료" "${agent_id} 에이전트 준비 완료"
BOOTMSG

  # 재부팅 태스크 복구 지시 (pending_task가 있으면 추가)
  if [ -n "$pending_task" ]; then
    cat << TASKMSG

[재부팅 후 태스크 복구]
이전 세션에서 중단된 태스크가 있다: ${pending_task}
해당 파일을 읽고 작업을 이어서 진행해라.
TASKMSG
  fi
}

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

write_pattern_manager_report_stub() {
  local project="$1" task_ref="$2" pattern="$3"
  shift 3
  local report_path report_rel task_key pattern_label tag joined_reports report_line
  report_path="$(runtime_task_report_path "$project" "$task_ref" "manager")"
  report_rel="$(runtime_project_relative_path "$project" "$report_path")"
  task_key="$(runtime_task_report_key "$task_ref")"
  mkdir -p "$(dirname "$report_path")"

  case "$pattern" in
    lead_verify)
      pattern_label="lead + verify"
      tag="lead-verify"
      ;;
    *)
      pattern_label="independent compare"
      tag="independent-compare"
      ;;
  esac

  joined_reports=""
  for report_line in "$@"; do
    if [ -n "$joined_reports" ]; then
      joined_reports="${joined_reports}; "
    fi
    joined_reports="${joined_reports}${report_line}"
  done

  if [ ! -f "$report_path" ]; then
    cat > "$report_path" <<EOF
# ${task_key} 패턴 조율 보고

- **Date**: $(date +%Y-%m-%d)
- **Author**: manager
- **For**: user
- **Status**: draft
- **Tags**: \`task-report\`, \`${task_key}\`, \`task-pattern\`, \`${tag}\`

## 요약
- **무엇**: ${task_ref}에 대한 ${pattern_label} 조율 보고
- **핵심 발견**: 작성 필요
- **시사점**: 작성 필요

## 내용
- 작업 지시: ${task_ref}
- 보고서 경로: ${report_rel}
- 실행 패턴: ${pattern_label}
- lane 결과: ${joined_reports}
- 최종 판정: 작성 필요
- 검증 결과: 작성 필요
- 남은 리스크: 작성 필요

## 참고한 교훈
- 해당 없으면 비워둘 수 있음

## 다음 단계
- 후속 작업이 있으면 작성
EOF
  fi

  printf '%s\n' "$report_rel"
}

# ──────────────────────────────────────────────
# task-pattern 메타데이터 파싱 및 실행 계획
# ──────────────────────────────────────────────

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

peer_lane_for_target() {
  local role="$1" target="$2"
  if [[ "$target" == *-claude ]]; then
    printf '%s\n' "${target%-claude}-codex"
    return 0
  fi
  if [[ "$target" == *-codex ]]; then
    printf '%s\n' "${target%-codex}-claude"
    return 0
  fi
  if [ "$target" = "$role" ]; then
    printf '%s-codex\n' "$role"
    return 0
  fi
  printf '%s-codex\n' "$role"
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
      append_unique_task_target "${owner_lane:-$(csv_first_value "$owner_lanes")}" "owner"
      if [ "${#TASK_EXEC_TARGETS[@]}" -eq 0 ]; then
        append_unique_task_target "$role" "owner"
      fi
      ;;
    lead_verify)
      lead_target="${owner_lane:-$(csv_first_value "$owner_lanes")}"
      [ -n "$lead_target" ] || lead_target="$role"
      append_unique_task_target "$lead_target" "lead"
      verify_target="$review_lane"
      if [ -z "$verify_target" ] || [[ "$verify_target" == manager* ]]; then
        verify_target="$(peer_lane_for_target "$role" "$lead_target")"
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
  local _tsm_subject_var="$2"
  local _tsm_message_var="$3"
  local project="${4:-}"
  local _tsm_subject _tsm_msg _tsm_resolved
  _tsm_resolved=""
  if [ -n "$project" ]; then
    _tsm_resolved="$(resolve_task_metadata_path "$project" "$task" 2>/dev/null || true)"
  fi
  if [ -n "$_tsm_resolved" ] || [ -f "$task" ]; then
    _tsm_subject="$task"
    if [ -n "$project" ]; then
      _tsm_msg="$(normalize_task_ref "$project" "$task") 파일에 새 작업 지시가 있다. 읽고 실행해라."
    else
      _tsm_msg="${task} 파일에 새 작업 지시가 있다. 읽고 실행해라."
    fi
  else
    _tsm_subject="$task"
    _tsm_msg="$task"
  fi
  printf -v "$_tsm_subject_var" '%s' "$_tsm_subject"
  printf -v "$_tsm_message_var" '%s' "$_tsm_msg"
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

write_pattern_manager_report_stub() {
  local project="$1" task_ref="$2" pattern="$3"
  shift 3
  local report_path report_rel task_key pattern_label tag joined_reports report_line
  report_path="$(runtime_task_report_path "$project" "$task_ref" "manager")"
  report_rel="$(runtime_project_relative_path "$project" "$report_path")"
  task_key="$(runtime_task_report_key "$task_ref")"
  mkdir -p "$(dirname "$report_path")"

  case "$pattern" in
    lead_verify)
      pattern_label="lead + verify"
      tag="lead-verify"
      ;;
    *)
      pattern_label="independent compare"
      tag="independent-compare"
      ;;
  esac

  joined_reports=""
  for report_line in "$@"; do
    if [ -n "$joined_reports" ]; then
      joined_reports="${joined_reports}; "
    fi
    joined_reports="${joined_reports}${report_line}"
  done

  if [ ! -f "$report_path" ]; then
    cat > "$report_path" <<EOF
# ${task_key} 패턴 조율 보고

- **Date**: $(date +%Y-%m-%d)
- **Author**: manager
- **For**: user
- **Status**: draft
- **Tags**: \`task-report\`, \`${task_key}\`, \`task-pattern\`, \`${tag}\`

## 요약
- **무엇**: ${task_ref}에 대한 ${pattern_label} 조율 보고
- **핵심 발견**: 작성 필요
- **시사점**: 작성 필요

## 내용
- 작업 지시: ${task_ref}
- 보고서 경로: ${report_rel}
- 실행 패턴: ${pattern_label}
- lane 결과: ${joined_reports}
- 최종 판정: 작성 필요
EOF
  fi

  printf '%s\n' "$report_rel"
}

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
  local active_task
  active_task="$(get_active_task "$project" "$agent")"
  if [ -n "$active_task" ]; then
    validate_task_report_ready "$project" "$agent" "$active_task"
  fi
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
  runtime_write_task_report_stub "$project" "$(normalize_task_ref "$project" "$task")" "$agent" "manager" >/dev/null
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

validate_task_report_ready() {
  local project="$1" agent="$2" task_ref="$3"
  local report_path report_rel
  report_path="$(runtime_task_report_path "$project" "$task_ref" "$agent")"
  report_rel="$(runtime_project_relative_path "$project" "$report_path")"

  if [ ! -f "$report_path" ]; then
    echo "Error: 완료 전에 결과 보고서가 필요하다: ${report_rel}" >&2
    return 1
  fi

  if ! grep -Eq '^- \*\*Status\*\*: final([[:space:]]*)$' "$report_path"; then
    echo "Error: 결과 보고서 Status가 final이어야 한다: ${report_rel}" >&2
    return 1
  fi

  if grep -q "작성 필요" "$report_path" 2>/dev/null; then
    echo "Error: 결과 보고서에 미완성 placeholder가 남아 있다: ${report_rel}" >&2
    return 1
  fi
}

# sessions.md 초기화 (멱등: 이미 존재하면 건너뜀)
init_sessions_file() {
  local project="$1"
  local sf
  sf="$(sessions_file "$project")"
  mkdir -p "$(dirname "$sf")"

  # 이미 존재하면 덮어쓰지 않음 (boot-manager에서 이미 생성했을 수 있음)
  if [ -f "$sf" ]; then
    return
  fi

  cat > "$sf" << 'HEADER'
# 활성 에이전트 세션

| 역할 | 백엔드 | Session ID | tmux Target | 상태 | 시작일 | 모델 | 비고 |
|------|--------|-----------|-------------|------|--------|------|------|
HEADER
}

# sessions.md에 행 추가 (role+backend 중복 방지)
add_session_row() {
  local project="$1" role="$2" session_id="$3" tmux_target="$4" model="$5" backend="${6:-claude}"
  local sf
  init_sessions_file "$project"
  sf="$(sessions_file "$project")"
  prune_active_session_rows "$project" "$role" "$backend" "$tmux_target"

  # prune 후에도 동일 role+backend active 행이 남아있으면 중복 append 방지
  if grep -q "| active |" "$sf" 2>/dev/null; then
    local dup
    dup="$(awk -F'|' -v role="$role" -v backend="$backend" '
      function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
      trim($6) == "active" && trim($2) == role && trim($3) == backend { found=1; exit }
      END { if (found) print "1" }
    ' "$sf")"
    if [ "$dup" = "1" ]; then
      python3 "$TOOLS_DIR/log.py" system "$project" cmd session_duplicate_skipped "$role" \
        --detail backend="$backend" target="$tmux_target" || true
      return 0
    fi
  fi

  local today
  today="$(date +%Y-%m-%d)"
  echo "| ${role} | ${backend} | ${session_id} | ${tmux_target} | active | ${today} | ${model} | |" >> "$sf"
}

# sessions.md에서 특정 역할의 상태를 변경
# backend가 지정되면 role+backend 매칭, 없으면 role만 매칭
mark_session_status() {
  local project="$1" role="$2" old_status="$3" new_status="$4" backend="${5:-}"
  local sf
  sf="$(sessions_file "$project")"
  if [ -f "$sf" ]; then
    if [ -n "$backend" ]; then
      awk -v role=" $role " -v backend=" $backend " -v old=" $old_status " -v new=" $new_status " \
        'BEGIN{FS=OFS="|"} $2==role && $3==backend && $6==old {$6=new} 1' \
        "$sf" > "${sf}.tmp" && mv "${sf}.tmp" "$sf"
    else
      awk -v role=" $role " -v old=" $old_status " -v new=" $new_status " \
        'BEGIN{FS=OFS="|"} $2==role && $6==old {$6=new} 1' \
        "$sf" > "${sf}.tmp" && mv "${sf}.tmp" "$sf"
    fi
  fi
}

mark_window_status() {
  local project="$1" window_name="$2" old_status="$3" new_status="$4"
  local sf sess target
  sf="$(sessions_file "$project")"
  sess="$(session_name "$project")"
  target="${sess}:${window_name}"
  if [ -f "$sf" ]; then
    awk -v target=" ${target} " -v old=" ${old_status} " -v new=" ${new_status} " \
      'BEGIN{FS=OFS="|"} $5==target && $6==old {$6=new} 1' \
      "$sf" > "${sf}.tmp" && mv "${sf}.tmp" "$sf"
  fi
}

# sessions.md 전체를 closed로 갱신
close_all_sessions() {
  local project="$1"
  local sf
  sf="$(sessions_file "$project")"
  if [ -f "$sf" ]; then
    sed_inplace 's/| active |/| closed |/g' "$sf"
  fi
}

prune_active_session_rows() {
  local project="$1" role="$2" backend="$3" tmux_target="$4"
  local sf tmp
  sf="$(sessions_file "$project")"
  [ -f "$sf" ] || return 0
  tmp="${sf}.tmp"

  awk -v role="$role" -v backend="$backend" -v target="$tmux_target" '
    BEGIN { FS=OFS="|" }
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    {
      drop = 0
      if (trim($6) == "active") {
        if (trim($5) == target) {
          drop = 1
        } else if (trim($2) == role && trim($3) == backend) {
          drop = 1
        }
      }
      if (!drop) {
        print
      }
    }
  ' "$sf" > "$tmp" && mv "$tmp" "$sf"
}

stale_missing_active_session_rows() {
  local project="$1" sess="$2"
  local sf tmp has_session=0
  sf="$(sessions_file "$project")"
  [ -f "$sf" ] || return 0
  tmux has-session -t "$sess" 2>/dev/null && has_session=1
  tmp="${sf}.tmp"

  awk -v sess="$sess" -v has_session="$has_session" '
    BEGIN { FS=OFS="|" }
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    {
      if (trim($6) == "active") {
        target = trim($5)
        if (index(target, sess ":") == 1) {
          if (has_session == 0) {
            $6 = " stale "
          } else {
            cmd = "tmux list-panes -t \"" target "\" >/dev/null 2>&1"
            if (system(cmd) != 0) {
              $6 = " stale "
            }
          }
        }
      }
      print
    }
  ' "$sf" > "$tmp" && mv "$tmp" "$sf"
}

clear_recovered_agent_runtime_state() {
  local project="$1" window_name="$2"
  runtime_clear_agent_health_state "$project" "$window_name"
  runtime_clear_agent_health_alert_ts "$project" "$window_name"
}

reset_stale_boot_runtime_state() {
  local project="$1"
  rm -f "$(runtime_reboot_state_file "$project")"
  rm -f "$(runtime_idle_state_file "$project")"
  rm -f "$(runtime_waiting_state_file "$project")"

  # tmux-debug 로그 정리: 이전 세션 잔재 삭제
  # server 로그는 현재 PID 보존, client 로그는 부팅 시점에 모두 이전 세션 잔재이므로 전부 삭제
  local debug_dir current_server_pid
  debug_dir="$(tmux_debug_log_dir "$project")"
  if [ -d "$debug_dir" ]; then
    current_server_pid="$(tmux display-message -p '#{pid}' 2>/dev/null || true)"
    local log_file base_name
    for log_file in "$debug_dir"/tmux-server-*.log; do
      [ -f "$log_file" ] || continue
      base_name="$(basename "$log_file")"
      if [ -n "$current_server_pid" ] && [[ "$base_name" == *"-${current_server_pid}.log" ]]; then
        continue
      fi
      rm -f "$log_file"
    done
    # client 로그는 client PID 기반이므로 server PID로 보존 판별 불가 — 전부 삭제
    rm -f "$debug_dir"/tmux-client-*.log
    rm -f "$debug_dir"/latest-*.meta
  fi
}

submit_tmux_prompt_when_ready() {
  local tmux_target="$1" prompt="$2" label="$3"
  local submit_attempts="${4:-12}" ready_attempts="${5:-30}" ready_delay="${6:-1}" attempt
  for attempt in $(seq 1 "$submit_attempts"); do
    if tmux_submit_wait_app_ready "$tmux_target" "$ready_attempts" "$ready_delay" 6 && \
       tmux_submit_pasted_payload "$tmux_target" "$prompt" "$label"; then
      return 0
    fi
    sleep 2
  done
  return 1
}

pane_recent_contains() {
  local tmux_target="$1" needle="$2" lines="${3:-220}" capture
  [ -n "$needle" ] || return 1
  capture="$(tmux capture-pane -pJ -t "$tmux_target" -S "-${lines}" 2>/dev/null || true)"
  [[ "$capture" == *"$needle"* ]]
}

wait_for_visible_task_prompt() {
  local tmux_target="$1" task_ref="$2" attempts="${3:-6}" delay="${4:-1}"
  local task_key attempt
  [ -n "$task_ref" ] || return 0
  task_key="${task_ref##*/}"
  for attempt in $(seq 1 "$attempts"); do
    if pane_recent_contains "$tmux_target" "$task_ref" 260 || pane_recent_contains "$tmux_target" "$task_key" 260; then
      return 0
    fi
    sleep "$delay"
  done
  return 1
}

send_task_visibility_reminder() {
  local tmux_target="$1" task_ref="$2" label="$3"
  [ -n "$task_ref" ] || return 0
  submit_tmux_prompt_when_ready "$tmux_target" "이전 태스크 재개: ${task_ref}" "$label" 3 10 1
}

configure_tmux_session_visuals() {
  local sess="$1"
  tmux set-option -t "$sess" activity-action none
  tmux set-option -t "$sess" visual-activity off
  tmux set-option -t "$sess" window-status-separator "  "
  tmux set-option -t "$sess" window-status-format " #I:#W "
  tmux set-option -t "$sess" window-status-current-format " [#I:#W] "
  tmux set-option -t "$sess" status-style "bg=black,fg=white"
  tmux set-option -t "$sess" window-status-current-style "bg=blue,fg=white,bold"
}

tmux_debug_enabled() {
  case "${WHIPLASH_TMUX_DEBUG:-0}" in
    0|false|FALSE|off|OFF|no|NO)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

tmux_debug_log_dir() {
  local project="$1"
  printf '%s/tmux-debug\n' "$(project_dir "$project")/logs"
}

tmux_write_debug_meta() {
  local project="$1"
  local sess="$2"
  local before_file="$3"
  local meta_file log_dir log_file found=0
  log_dir="$(tmux_debug_log_dir "$project")"
  meta_file="${log_dir}/latest-${sess}.meta"

  {
    printf 'timestamp=%s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf 'session=%s\n' "$sess"
    printf 'cwd=%s\n' "$log_dir"
    printf 'socket_hint=/private/tmp/tmux-%s/%s\n' "$(id -u)" "$sess"
    printf 'logs=\n'
    for log_file in "$log_dir"/tmux-*.log; do
      [ -f "$log_file" ] || continue
      if ! grep -Fqx "$(basename "$log_file")" "$before_file" 2>/dev/null; then
        printf '%s\n' "$log_file"
        found=1
      fi
    done
    if [ "$found" -eq 0 ]; then
      printf '(no-new-log-files-detected)\n'
    fi
  } > "$meta_file"
}

tmux_new_session_detached() {
  local project="$1"
  local sess="$2"
  local window_name="$3"

  if ! tmux_debug_enabled; then
    tmux new-session -d -s "$sess" -n "$window_name"
    return
  fi

  local log_dir before_file
  log_dir="$(tmux_debug_log_dir "$project")"
  mkdir -p "$log_dir"
  before_file="$(mktemp)"
  (
    cd "$log_dir"
    ls tmux-*.log 2>/dev/null | sort > "$before_file" || true
    command tmux -vv new-session -d -s "$sess" -n "$window_name"
  )
  tmux_write_debug_meta "$project" "$sess" "$before_file"
  rm -f "$before_file"
}

tmux_session_exists_on_socket() {
  local sess="$1"
  command tmux has-session -t "$sess" 2>/dev/null
}

tmux_window_exists_on_socket() {
  local sess="$1"
  local window_name="$2"
  command tmux list-windows -t "$sess" -F '#{window_name}' 2>/dev/null | grep -qx "$window_name"
}

ensure_dashboard_window() {
  local project="$1"
  local sess
  sess="$(session_name "$project")"

  if ! tmux list-windows -t "$sess" -F '#{window_name}' 2>/dev/null | grep -q '^dashboard$'; then
    tmux new-window -d -t "$sess" -n "dashboard"
  fi

  tmux send-keys -t "${sess}:dashboard" C-c 2>/dev/null || true
  tmux send-keys -t "${sess}:dashboard" \
    "env -u NO_COLOR FORCE_COLOR=1 CLICOLOR_FORCE=1 python3 \"$REPO_ROOT/dashboard/dashboard.py\" \"$project\" --interval 3" Enter
}

ensure_tmux_session_with_dashboard() {
  local project="$1"
  local sess
  sess="$(session_name "$project")"

  init_sessions_file "$project"

  if ! tmux_session_exists_on_socket "$sess"; then
    tmux_new_session_detached "$project" "$sess" "dashboard"
  fi

  configure_tmux_session_visuals "$sess"
  ensure_dashboard_window "$project"
}

build_onboarding_analysis_note() {
  local project="$1"
  cat <<EOF

[Onboarding]
- 지금은 프로젝트 설계 단계다. 기존 코드/레포 분석, project.md 작성/보강, 팀 구성 확정까지 진행해라.
- 필요하면 아래 명령으로 researcher 또는 systems-engineer 보조 에이전트를 띄울 수 있다:
  bash "$TOOLS_DIR/cmd.sh" spawn researcher onboarding-research ${project} "기존 레포/문서 분석 보조"
  bash "$TOOLS_DIR/cmd.sh" spawn systems-engineer onboarding-systems ${project} "서버/클라우드/runtime 분석 보조"
- onboarding 단계 보조 에이전트는 분석 전용이다. developer, monitoring, manager spawn은 금지다.
- 보조 에이전트와의 소통은 status_update, need_input, escalation, agent_ready만 사용해라. task_assign/task_complete는 쓰지 마라.
- 구현, 배포, 실제 서비스 변경은 금지다. 근거 수집, 구조 해석, 준비 문서 작성까지만 해라.
- 최종 리뷰가 끝나고 프로젝트 정의가 확정되면 아래 명령으로 Manager를 내부적으로 부팅해라:
  bash "$TOOLS_DIR/cmd.sh" boot-manager ${project}
- 별도 user handoff 명령을 기다리지 마라. Manager가 올라간 뒤에는 온보딩 맥락을 넘기고 종료해라.
EOF
}

build_onboarding_helper_spawn_note() {
  local project="$1"
  local agent_id="$2"
  cat <<EOF

[온보딩 분석 보조 모드]
- 지금은 온보딩 분석 단계다. 공식 보고 대상은 manager가 아니라 onboarding이다.
- 준비 완료와 진행 업데이트는 onboarding에게 보고해라:
  bash "$TOOLS_DIR/message.sh" ${project} ${agent_id} onboarding agent_ready normal "준비 완료" "분석 준비 완료"
  bash "$TOOLS_DIR/message.sh" ${project} ${agent_id} onboarding status_update normal "분석 업데이트" "핵심 발견"
- need_input, escalation도 onboarding에게 보낼 수 있다.
- task_assign/task_complete는 이 단계에서 사용하지 마라.
- 구현, 배포, 서비스 변경, 추가 에이전트 스폰은 금지다. 분석/문서화/준비까지만 수행해라.
EOF
}

close_window_if_present() {
  local sess="$1"
  local window_name="$2"
  if tmux list-windows -t "$sess" -F '#{window_name}' 2>/dev/null | grep -q "^${window_name}$"; then
    tmux send-keys -t "${sess}:${window_name}" "/exit" Enter 2>/dev/null || true
    sleep 1
    tmux kill-window -t "${sess}:${window_name}" 2>/dev/null || true
  fi
}

close_onboarding_analysis_windows() {
  local project="$1"
  local sess window_name
  sess="$(session_name "$project")"
  if ! tmux has-session -t "$sess" 2>/dev/null; then
    return 0
  fi

  while IFS= read -r window_name; do
    [ -n "$window_name" ] || continue
    case "$window_name" in
      onboarding|onboarding-*)
        close_window_if_present "$sess" "$window_name"
        mark_window_status "$project" "$window_name" "active" "closed"
        ;;
    esac
  done < <(tmux list-windows -t "$sess" -F '#{window_name}' 2>/dev/null || true)
}

resolve_reboot_or_refresh_target() {
  local target="$1"
  local project="$2"
  local resolved_role resolved_backend resolved_window

  if [[ "$target" == *-claude ]]; then
    resolved_role="${target%-claude}"
    resolved_backend="claude"
    resolved_window="$target"
  elif [[ "$target" == *-codex ]]; then
    resolved_role="${target%-codex}"
    resolved_backend="codex"
    resolved_window="$target"
  else
    resolved_role="$target"
    resolved_window="$target"
    case "$resolved_role" in
      onboarding|manager|discussion)
        resolved_backend="$(get_manager_backend "$project")"
        ;;
      *)
        resolved_backend="claude"
        ;;
    esac
  fi

  printf '%s|%s|%s\n' "$resolved_role" "$resolved_backend" "$resolved_window"
}

# 단일 에이전트 부팅 (reboot/refresh에서 재사용)
boot_single_agent() {
  local role="$1"
  local project="$2"
  local extra_boot_msg="${3:-}"
  local window_name="${4:-$role}"
  local pending_task="${5:-}"
  local ready_target_override="${6:-}"
  local sess
  sess="$(session_name "$project")"

  # 멱등성 가드: 윈도우 존재 + claude 프로세스 alive 확인
  local existing_idx existing_pane_pid existing_alive=0
  while IFS= read -r existing_idx; do
    [ -n "$existing_idx" ] || continue
    existing_pane_pid=$(tmux list-panes -t "${sess}:${existing_idx}" -F '#{pane_pid}' 2>/dev/null | head -1)
    if process_or_child_named "$existing_pane_pid" claude; then
      existing_alive=1
      break
    fi
  done < <(window_indices_by_name "$sess" "$window_name")

  if [ "$existing_alive" -eq 1 ]; then
    echo "Info: ${window_name} 윈도우 + claude 프로세스 활성. 부팅 건너뜀." >&2
    return 0
  fi

  if window_indices_by_name "$sess" "$window_name" | grep -q .; then
    # 실패한 부팅이 남긴 동명 창을 모두 정리한다.
    echo "Info: ${window_name} 동명 윈도우 존재하나 claude 프로세스 없음. 모두 제거 후 재부팅." >&2
    kill_windows_by_name "$sess" "$window_name"
  fi

  local model
  model="$(get_model "$role")"
  local tools
  tools="$(get_allowed_tools "$role")"
  local agent_id="$window_name"
  local boot_msg
  boot_msg="$(build_boot_message "$role" "$project" "$extra_boot_msg" "$agent_id" "$pending_task" "$ready_target_override")"
  local bootstrap_msg
  bootstrap_msg="$(build_claude_session_bootstrap_prompt)"
  local tmux_target="${sess}:${window_name}"
  local agent_env_script
  agent_env_script="$(write_agent_env_script "$project" "$role" "$agent_id")"

  echo "--- ${window_name} (${model}) 부팅 중 ---"

  # claude -p로 초기 세션 생성하여 session_id 획득
  # env -u CLAUDECODE: Manager가 Claude Code 안에서 호출할 때 중첩 세션 에러 방지
  local tools_flag=""
  [ -n "$tools" ] && tools_flag="--allowedTools $tools"
  local result
  result=$(run_with_agent_env "$project" "$role" "$agent_id" env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT claude -p "$bootstrap_msg" \
    --model "$model" \
    --output-format json \
    --dangerously-skip-permissions $tools_flag) || {
    echo "Warning: ${window_name} claude -p 실행 실패." >&2
    python3 "$TOOLS_DIR/log.py" system "$project" orchestrator agent_boot_fail "$window_name" --detail reason="claude -p 실행 실패" || true
    return 1
  }

  local session_id
  session_id=$(echo "$result" | jq -r '.session_id' 2>/dev/null) || session_id=""

  if [ -z "$session_id" ] || [ "$session_id" = "null" ]; then
    echo "Warning: ${window_name} session_id 획득 실패." >&2
    python3 "$TOOLS_DIR/log.py" system "$project" orchestrator agent_boot_fail "$window_name" --detail reason="session_id 획득 실패" || true
    return 1
  fi

  # tmux 윈도우 생성 후 claude --resume으로 인터랙티브 세션 시작
  # env -u CLAUDECODE: Manager가 Claude Code 안에서 호출할 때 중첩 세션 에러 방지
  tmux new-window -d -t "$sess" -n "$window_name"
  local resume_tools_flag=""
  [ -n "$tools" ] && resume_tools_flag=" --allowedTools $tools"
  tmux send-keys -t "$tmux_target" "cd $(printf '%q' "$REPO_ROOT") && . $(printf '%q' "$agent_env_script") && env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT claude --resume $session_id --dangerously-skip-permissions${resume_tools_flag}" Enter

  # 부팅 확인: claude 프로세스 시작 대기 (최대 10초)
  local boot_pane_pid
  boot_pane_pid=$(tmux list-panes -t "$tmux_target" -F '#{pane_pid}' 2>/dev/null | head -1)
  if [ -n "$boot_pane_pid" ]; then
    local i
    for i in $(seq 1 10); do
      process_or_child_named "$boot_pane_pid" claude && break
      sleep 1
    done
    if ! process_or_child_named "$boot_pane_pid" claude; then
      echo "Warning: ${window_name} claude 프로세스 10초 내 미시작." >&2
      python3 "$TOOLS_DIR/log.py" system "$project" orchestrator agent_boot_fail "$window_name" --detail reason="claude 프로세스 미시작" || true
      return 1
    fi
    sleep 1
  done
  if ! agent_window_has_live_backend "$sess" "$window_name" "claude"; then
    echo "Warning: ${window_name} claude 프로세스 10초 내 미시작." >&2
    python3 "$TOOLS_DIR/log.py" system "$project" orchestrator agent_boot_fail "$window_name" --detail reason="claude 프로세스 미시작" || true
    return 1
  fi

  # TUI 초기화 대기: 프로세스 감지 직후 paste를 보내면 바이너리가 아직
  # bracketed paste / raw mode를 설정하지 못해 전달 실패할 수 있다.
  sleep 2

  local prompt_ok=0
  for i in 1 2 3 4 5; do
    if tmux_submit_pasted_payload "$tmux_target" "$boot_msg" "${window_name}-boot"; then
      prompt_ok=1
      break
    fi
    sleep 2
  done
  if [ "$prompt_ok" -ne 1 ]; then
    echo "Warning: ${window_name} 온보딩 프롬프트 전달 실패." >&2
    python3 "$TOOLS_DIR/log.py" system "$project" orchestrator agent_boot_fail "$window_name" --detail reason="온보딩 프롬프트 전달 실패" || true
    tmux kill-window -t "$tmux_target" 2>/dev/null || true
    return 1
  fi

  # sessions.md에는 visible boot prompt 전달 이후에만 기록한다.
  add_session_row "$project" "$role" "$session_id" "$tmux_target" "$model" "claude"

  if ! submit_tmux_prompt_when_ready "$tmux_target" "$boot_msg" "${window_name}-boot"; then
    echo "Warning: ${window_name} 온보딩 프롬프트 전달 실패." >&2
    mark_window_status "$project" "$window_name" "active" "crashed"
    kill_windows_by_name "$sess" "$window_name"
    python3 "$TOOLS_DIR/log.py" system "$project" orchestrator agent_boot_fail "$window_name" --detail reason="온보딩 프롬프트 전달 실패" || true
    return 1
  fi
  if [ -n "$pending_task" ] && ! wait_for_visible_task_prompt "$tmux_target" "$pending_task" 4 1; then
    if ! submit_tmux_prompt_when_ready "$tmux_target" "$boot_msg" "${window_name}-boot-redeliver" 4 20 1; then
      echo "Warning: ${window_name} task prompt 재전달 실패." >&2
      mark_window_status "$project" "$window_name" "active" "crashed"
      kill_windows_by_name "$sess" "$window_name"
      python3 "$TOOLS_DIR/log.py" system "$project" orchestrator agent_boot_fail "$window_name" --detail reason="task prompt 재전달 실패" || true
      return 1
    fi
    send_task_visibility_reminder "$tmux_target" "$pending_task" "${window_name}-task-reminder" || true
  fi

  clear_recovered_agent_runtime_state "$project" "$window_name"
  python3 "$TOOLS_DIR/log.py" system "$project" orchestrator agent_boot "$window_name" --detail session="$session_id" || true
  echo "${window_name} 부팅 완료: session=${session_id}, tmux=${tmux_target}"
  return 0
}

# Codex CLI 에이전트 부팅 (interactive-only)
boot_codex_agent() {
  local role="$1"
  local project="$2"
  local window_name="$3"
  local extra_boot_msg="${4:-}"
  local pending_task="${5:-}"
  local ready_target_override="${6:-}"
  local sess
  sess="$(session_name "$project")"
  local agent_id="$window_name"
  local tmux_target="${sess}:${window_name}"
  local codex_model
  codex_model="$(get_codex_model)"
  local codex_effort
  codex_effort="$(get_reasoning_effort "$role")"
  local codex_env
  codex_env="$(build_codex_env_prefix "$codex_model" "$codex_effort")"
  local codex_env_args
  codex_env_args="${codex_env#env }"
  local agent_env_script
  agent_env_script="$(write_agent_env_script "$project" "$role" "$agent_id")"
  # codex CLI 설치 확인
  if ! command -v codex &>/dev/null; then
    echo "Warning: codex CLI가 설치되어 있지 않다. ${window_name} 부팅 건너뜀." >&2
    return 1
  fi

  local existing_idx pane_info pane_pid pane_cmd existing_alive=0
  while IFS= read -r existing_idx; do
    [ -n "$existing_idx" ] || continue
    pane_info=$(tmux list-panes -t "${sess}:${existing_idx}" -F '#{pane_pid}|#{pane_current_command}' 2>/dev/null | head -1)
    pane_pid="${pane_info%%|*}"
    pane_cmd="${pane_info#*|}"
    case "$pane_cmd" in
      codex|codex-*)
        existing_alive=1
        break
        ;;
    esac
    if process_or_child_named "$pane_pid" "codex"; then
      existing_alive=1
      break
    fi
  done < <(window_indices_by_name "$sess" "$window_name")

  if [ "$existing_alive" -eq 1 ]; then
    echo "Info: ${window_name} 윈도우 + codex 프로세스 활성. 부팅 건너뜀." >&2
    return 0
  fi

  if window_indices_by_name "$sess" "$window_name" | grep -q .; then
    echo "Info: ${window_name} 동명 윈도우 존재하나 codex 프로세스 없음. 모두 제거 후 재부팅." >&2
    kill_windows_by_name "$sess" "$window_name"
  fi

  echo "--- ${window_name} (codex interactive mode) 부팅 중 ---"

  local boot_msg bootstrap_path bootstrap_prompt
  boot_msg="$(build_boot_message "$role" "$project" "$extra_boot_msg" "$agent_id" "$pending_task" "$ready_target_override")"
  bootstrap_path="$(prepare_codex_bootstrap_file "$project" "$agent_id" "$boot_msg")"
  bootstrap_prompt="$(build_codex_bootstrap_prompt "$bootstrap_path")"

  tmux new-window -d -t "$sess" -n "$window_name"
  tmux send-keys -t "$tmux_target" \
    "cd $(printf '%q' "$REPO_ROOT") && . $(printf '%q' "$agent_env_script") &&${codex_env_args:+ ${codex_env_args}} codex --no-alt-screen" Enter
  sleep 4
  if ! submit_tmux_prompt_when_ready "$tmux_target" "$bootstrap_prompt" "codex-prompt" 5 20 1; then
    echo "Warning: ${window_name} codex TUI 온보딩 프롬프트 전달 실패." >&2
    tmux kill-window -t "$tmux_target" 2>/dev/null || true
    return 1
  fi
  add_session_row "$project" "$role" "codex-interactive" "$tmux_target" "$codex_model" "codex"
  clear_recovered_agent_runtime_state "$project" "$window_name"
  python3 "$TOOLS_DIR/log.py" system "$project" orchestrator codex_boot "$window_name" --detail tmux="$tmux_target" mode="codex-interactive" || true
  echo "${window_name} 부팅 완료: tmux=${tmux_target} (codex interactive mode)"
  return 0
}

boot_agent_with_backend() {
  local role="$1"
  local project="$2"
  local window_name="$3"
  local backend="$4"
  local extra_boot_msg="${5:-}"
  local pending_task="${6:-}"
  local ready_target_override="${7:-}"

  if [ "$backend" = "codex" ]; then
    boot_codex_agent "$role" "$project" "$window_name" "$extra_boot_msg" "$pending_task" "$ready_target_override"
  else
    boot_single_agent "$role" "$project" "$extra_boot_msg" "$window_name" "$pending_task" "$ready_target_override"
  fi
}

log_message_line_count() {
  local project="$1"
  local msg_log
  msg_log="$(project_dir "$project")/logs/message.log"
  if [ -f "$msg_log" ]; then
    wc -l < "$msg_log"
  else
    echo "0"
  fi
}

wait_for_delivered_message() {
  local project="$1"
  local start_lines="$2"
  local pattern="$3"
  local timeout_seconds="${4:-0}"
  local msg_log waited=0
  msg_log="$(project_dir "$project")/logs/message.log"

  while true; do
    if tail -n +"$((start_lines + 1))" "$msg_log" 2>/dev/null | grep -q "$pattern"; then
      return 0
    fi
    if [ "$timeout_seconds" -gt 0 ] 2>/dev/null && [ "$waited" -ge "$timeout_seconds" ]; then
      return 1
    fi
    sleep 2
    waited=$((waited + 2))
  done
}

boot_manager_window() {
  local project="$1"
  local extra_boot_msg="${2:-}"
  local manager_backend
  manager_backend="$(get_manager_backend "$project")"

  if [ "$manager_backend" = "codex" ]; then
    boot_agent_with_backend "manager" "$project" "manager" "codex" "$extra_boot_msg" "" "user" || {
      echo "Error: Manager codex 부팅 실패." >&2
      return 1
    }
  else
    local model
    model="$(get_model "manager")"
    local mgr_tools
    mgr_tools="$(get_allowed_tools "manager")"
    local manager_env_script
    manager_env_script="$(write_agent_env_script "$project" "manager" "manager")"
    local bootstrap_msg
    bootstrap_msg=$'너는 Whiplash manager 세션의 bootstrap 단계다.\n지금은 session_id만 만들기 위한 초기 호출이다.\n도구를 사용하지 말고, 파일도 읽지 말고, 명령도 실행하지 말고, 한 줄로 READY만 답해라.'
    local boot_msg
    boot_msg="$(build_boot_message "manager" "$project" "$extra_boot_msg" "manager" "" "user")"
    local model_flag result session_id tmux_target mgr_resume_flag boot_pane_pid attempt

    model_flag=""
    [ -n "$mgr_tools" ] && model_flag="--allowedTools $mgr_tools"
    result=$(run_with_agent_env "$project" "manager" "manager" env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT claude -p "$bootstrap_msg" \
      --model "$model" \
      --output-format json \
      --dangerously-skip-permissions $model_flag) || {
      echo "Error: Manager claude -p 실행 실패." >&2
      return 1
    }

    session_id=$(echo "$result" | jq -r '.session_id' 2>/dev/null) || session_id=""
    if [ -z "$session_id" ] || [ "$session_id" = "null" ]; then
      echo "Error: Manager session_id 획득 실패." >&2
      return 1
    fi

    tmux new-window -d -t "$(session_name "$project")" -n manager
    tmux_target="$(session_name "$project"):manager"
    mgr_resume_flag=""
    [ -n "$mgr_tools" ] && mgr_resume_flag=" --allowedTools $mgr_tools"
    tmux send-keys -t "$tmux_target" "cd $(printf '%q' "$REPO_ROOT") && . $(printf '%q' "$manager_env_script") && env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT claude --resume $session_id --dangerously-skip-permissions${mgr_resume_flag}" Enter

    boot_pane_pid=$(tmux list-panes -t "$tmux_target" -F '#{pane_pid}' 2>/dev/null | head -1)
    if [ -n "$boot_pane_pid" ]; then
      for attempt in $(seq 1 10); do
        process_or_child_named "$boot_pane_pid" claude && break
        sleep 1
      done
    fi
    if [ -z "$boot_pane_pid" ] || ! process_or_child_named "$boot_pane_pid" claude; then
      echo "Error: Manager claude --resume 프로세스 시작 실패." >&2
      return 1
    fi

    add_session_row "$project" "manager" "$session_id" "$tmux_target" "$model"
    python3 "$TOOLS_DIR/log.py" system "$project" orchestrator manager_boot manager --detail session="$session_id" || true

    if ! submit_tmux_prompt_when_ready "$tmux_target" "$boot_msg" "manager-boot"; then
      echo "Error: Manager 온보딩 프롬프트 전달 실패." >&2
      mark_window_status "$project" "manager" "active" "boot-failed"
      kill_windows_by_name "$(session_name "$project")" "manager"
      return 1
    fi
  fi

  return 0
}

boot_onboarding_window() {
  local project="$1"
  local extra_boot_msg="${2:-}"
  local backend
  backend="$(get_manager_backend "$project")"
  boot_agent_with_backend "onboarding" "$project" "onboarding" "$backend" "$extra_boot_msg" "" "user" || {
    echo "Error: Onboarding 부팅 실패." >&2
    return 1
  }
  return 0
}

# ──────────────────────────────────────────────
# spawn 서브커맨드 — 동적 에이전트 추가 스폰
# ──────────────────────────────────────────────

normalize_spawn_role() {
  local role="$1"
  case "$role" in
    researcher|researcher-claude|researcher-codex) echo "researcher" ;;
    developer|developer-claude|developer-codex) echo "developer" ;;
    systems-engineer|systems-engineer-claude|systems-engineer-codex) echo "systems-engineer" ;;
    monitoring|monitoring-claude|monitoring-codex) echo "monitoring" ;;
    manager|manager-claude|manager-codex) echo "manager" ;;
    *)
      echo "Error: 지원하지 않는 spawn role: '$role'" >&2
      exit 1
      ;;
  esac
}

resolve_spawn_backend() {
  local requested_role="$1"
  local window_name="$2"

  case "$requested_role" in
    *-codex) echo "codex"; return ;;
    *-claude) echo "claude"; return ;;
  esac

  case "$window_name" in
    *codex*) echo "codex"; return ;;
    *claude*) echo "claude"; return ;;
  esac

  echo "claude"
}

cmd_spawn() {
  local requested_role="$1" # researcher, researcher-codex 등
  local window_name="$2" # researcher-2, dev-hotfix 등
  local project="$3"
  local extra_msg="${4:-}"
  local role
  role="$(normalize_spawn_role "$requested_role")"
  local backend
  backend="$(resolve_spawn_backend "$requested_role" "$window_name")"
  validate_project_name "$project"
  validate_window_name "$window_name"
  local stage
  stage="$(get_project_stage "$project")"
  validate_spawn_for_project_stage "$project" "$role" "$window_name" || exit 1
  local sess
  sess="$(session_name "$project")"

  # 세션 확인
  if ! tmux has-session -t "$sess" 2>/dev/null; then
    echo "Error: tmux 세션 '$sess'가 없다." >&2
    exit 1
  fi

  # 윈도우 중복 확인
  if tmux list-windows -t "$sess" -F '#{window_name}' | grep -q "^${window_name}$"; then
    echo "Error: ${window_name} 윈도우가 이미 존재한다." >&2
    exit 1
  fi

  local exec_mode
  exec_mode="$(get_exec_mode "$project")"
  if [ "$stage" != "onboarding" ] && [ "$exec_mode" = "dual" ] && role_uses_dual_worktree "$role"; then
    create_agent_worktree "$project" "$window_name" || true
  fi

  # 부팅 (동일한 프로젝트 맥락, 메모리 공유)
  local spawn_note="
참고: 너는 동적으로 스폰된 추가 에이전트다 (${window_name}).
같은 프로젝트의 메모리와 workspace를 공유한다. 같은 파일 동시 수정은 금지.
${extra_msg}"
  local ready_target_override=""
  if [ "$stage" = "onboarding" ]; then
    spawn_note="${spawn_note}
$(build_onboarding_helper_spawn_note "$project" "$window_name")"
    ready_target_override="onboarding"
  fi
  if [ "$backend" = "codex" ]; then
    boot_codex_agent "$role" "$project" "$window_name" "$spawn_note" "$ready_target_override" || {
      echo "Error: ${window_name} 스폰 실패." >&2
      exit 1
    }
  else
    boot_single_agent "$role" "$project" "$spawn_note" "$window_name" "" "$ready_target_override" || {
      echo "Error: ${window_name} 스폰 실패." >&2
      exit 1
    }
  fi
  python3 "$TOOLS_DIR/log.py" system "$project" orchestrator agent_spawn "$window_name" --detail role="$role" backend="$backend" || true
  echo "=== ${window_name} 스폰 완료 ==="
}

# ──────────────────────────────────────────────
# kill-agent 서브커맨드 — 동적 에이전트 종료
# ──────────────────────────────────────────────

cmd_kill_agent() {
  local window_name="$1"
  local project="$2"
  validate_project_name "$project"
  validate_window_name "$window_name"
  local sess
  sess="$(session_name "$project")"

  # 세션 확인
  if ! tmux has-session -t "$sess" 2>/dev/null; then
    echo "Error: tmux 세션 '$sess'가 없다." >&2
    exit 1
  fi

  # 윈도우 확인
  if ! tmux list-windows -t "$sess" -F '#{window_name}' | grep -q "^${window_name}$"; then
    echo "Error: ${window_name} 윈도우가 없다." >&2
    exit 1
  fi

  # 종료
  tmux send-keys -t "${sess}:${window_name}" "/exit" Enter
  sleep 3
  tmux kill-window -t "${sess}:${window_name}" 2>/dev/null || true

  remove_agent_worktree "$project" "$window_name" || true

  # sessions.md 업데이트
  local sf
  sf="$(sessions_file "$project")"
  if [ -f "$sf" ]; then
    sed_inplace "s/| ${sess}:${window_name} | active |/| ${sess}:${window_name} | closed |/g" "$sf"
  fi
  python3 "$TOOLS_DIR/log.py" system "$project" orchestrator agent_kill "$window_name" || true
  echo "=== ${window_name} 종료 완료 ==="
}

# ──────────────────────────────────────────────
# boot-onboarding / handoff / boot-manager 서브커맨드
# ──────────────────────────────────────────────

cmd_boot_onboarding() {
  local project="$1"
  validate_project_name "$project"
  ensure_onboarding_project_bootstrap "$project"
  local exec_mode
  exec_mode="$(get_exec_mode "$project")"

  bash "$TOOLS_DIR/preflight.sh" "$project" --mode "$exec_mode" --skip-project-check || exit 1

  local sess
  sess="$(session_name "$project")"

  echo "=== Onboarding 부팅 ==="
  if tmux has-session -t "$sess" 2>/dev/null; then
    echo "Error: tmux 세션 '$sess'가 이미 존재한다. 먼저 shutdown하라." >&2
    exit 1
  fi

  ensure_tmux_session_with_dashboard "$project"
  set_project_stage "$project" "onboarding"

  echo ""
  echo "╔══════════════════════════════════════════════╗"
  echo "║  Onboarding 세션 준비 완료                  ║"
  echo "║  tmux attach -t $sess 로 분석 과정을 볼 수 있음 ║"
  echo "╚══════════════════════════════════════════════╝"
  echo ""

  boot_onboarding_window "$project" "$(build_onboarding_analysis_note "$project")" || exit 1

  echo "Onboarding 실행 확인"
  echo "=== Onboarding 부팅 완료 ==="
  echo "유저와 설계를 진행하고, 확정되면 onboarding이 내부적으로 Manager를 부팅한다."
}

cmd_handoff() {
  local project="$1"
  validate_project_name "$project"
  local exec_mode
  exec_mode="$(get_exec_mode "$project")"
  local stage
  stage="$(get_project_stage "$project")"
  local sess
  sess="$(session_name "$project")"

  if [ "$stage" != "onboarding" ]; then
    echo "Error: ${project}는 onboarding 단계가 아니다 (current stage: ${stage})." >&2
    exit 1
  fi

  if ! tmux has-session -t "$sess" 2>/dev/null; then
    echo "Error: tmux 세션 '$sess'가 없다. boot-onboarding 또는 boot-manager를 먼저 실행하라." >&2
    exit 1
  fi

  bash "$TOOLS_DIR/preflight.sh" "$project" --mode "$exec_mode" || exit 1

  echo "=== Onboarding -> Manager handoff ==="

  local onboarding_handoff_file
  onboarding_handoff_file="$(project_dir "$project")/memory/onboarding/handoff.md"
  local handoff_wait="${WHIPLASH_ONBOARDING_HANDOFF_WAIT_SECONDS:-30}"
  if tmux list-windows -t "$sess" -F '#{window_name}' 2>/dev/null | grep -q '^onboarding$'; then
    tmux send-keys -t "${sess}:onboarding" \
      "지금까지의 분석 맥락을 memory/onboarding/handoff.md에 정리해라. 현재 이해한 구조, 열린 질문, 추천 팀 구성, 다음 handoff 준비 상태를 포함해라." Enter
    if [ "$handoff_wait" -gt 0 ] 2>/dev/null; then
      local waited=0
      echo "onboarding handoff.md 대기 중 (최대 ${handoff_wait}초)..."
      while [ "$waited" -lt "$handoff_wait" ]; do
        if [ -f "$onboarding_handoff_file" ]; then
          echo "onboarding handoff.md 생성 확인 (${waited}초 경과)"
          break
        fi
        sleep 5
        waited=$((waited + 5))
      done
    fi
  fi

  set_project_stage "$project" "handoff"

  local manager_extra_msg=""
  if [ -f "$onboarding_handoff_file" ]; then
    manager_extra_msg="10. memory/onboarding/handoff.md를 읽어라. 온보딩 분석 인수인계 문서다."
  fi

  local start_lines
  start_lines="$(log_message_line_count "$project")"
  boot_manager_window "$project" "$manager_extra_msg" || exit 1

  echo "Manager 온보딩 대기 중..."
  wait_for_delivered_message "$project" "$start_lines" '\[delivered\] manager → user agent_ready normal "온보딩 완료"' || {
    echo "Error: Manager 준비 완료 알림을 확인하지 못했다." >&2
    exit 1
  }
  echo "Manager 온보딩 완료 확인"

  close_onboarding_analysis_windows "$project"

  bash "$TOOLS_DIR/cmd.sh" boot "$project"
  set_project_stage "$project" "active"

  local boot_failed
  boot_failed="$(runtime_get_manager_state "$project" "boot_failed_agents" "" 2>/dev/null || true)"
  local boot_subject="팀 부팅 완료"
  local boot_content="onboarding handoff가 완료되었다. 활성 에이전트 부팅이 끝났으니 project.md와 handoff 문서를 바탕으로 첫 태스크를 분배해라."
  if [ -n "$boot_failed" ]; then
    boot_subject="팀 부팅 완료 (일부 실패)"
    boot_content="활성 에이전트 부팅이 끝났으나 일부가 실패했다. 실패: ${boot_failed}. 성공한 에이전트로 태스크를 분배하고, 실패한 에이전트는 reboot를 검토해라."
  fi
  bash "$TOOLS_DIR/message.sh" "$project" orchestrator manager status_update normal \
    "$boot_subject" \
    "$boot_content" \
    2>/dev/null || true

  echo "=== handoff 완료 ==="
  echo "tmux attach -t $sess 로 접속하라."
}

cmd_boot_manager() {
  local project="$1"
  validate_project_name "$project"
  local exec_mode
  exec_mode="$(get_exec_mode "$project")"
  local sess
  sess="$(session_name "$project")"
  local stage
  stage="$(get_project_stage "$project")"
  local previous_stage="$stage"
  local created_session=0
  local reuse_partial_session=0

  if tmux_session_exists_on_socket "$sess"; then
    if [ "$stage" = "onboarding" ]; then
      echo "Info: onboarding 세션이 이미 존재한다. Manager 부팅으로 이어간다."
      cmd_handoff "$project"
      return 0
    fi
    if tmux_window_exists_on_socket "$sess" "dashboard" \
      && ! tmux_window_exists_on_socket "$sess" "manager"; then
      echo "Info: dashboard만 남은 기존 세션 '$sess'를 재사용해 Manager 부팅을 이어간다."
      reuse_partial_session=1
    else
      echo "Error: tmux 세션 '$sess'가 이미 존재한다. 먼저 shutdown하라." >&2
      exit 1
    fi
  fi

  bash "$TOOLS_DIR/preflight.sh" "$project" --mode "$exec_mode" || exit 1

  echo "=== Manager 부팅 ==="
  ensure_tmux_session_with_dashboard "$project"
  if [ "$reuse_partial_session" -eq 0 ] && tmux_session_exists_on_socket "$sess"; then
    created_session=1
  fi
  set_project_stage "$project" "handoff"

  echo ""
  echo "╔══════════════════════════════════════════════╗"
  echo "║  Dashboard 준비 완료                        ║"
  echo "║  tmux attach -t $sess 로 실시간 모니터링    ║"
  echo "╚══════════════════════════════════════════════╝"
  echo ""
  echo "Manager 세션 생성 중..."

  local start_lines
  start_lines="$(log_message_line_count "$project")"
  boot_manager_window "$project" || {
    set_project_stage "$project" "$previous_stage"
    # Manager 윈도우만 정리, 세션 전체를 죽이지 않음
    tmux kill-window -t "${sess}:manager" 2>/dev/null || true
    echo "Error: Manager 부팅 실패. 세션은 유지됨." >&2
    exit 1
  }

  echo "Manager 온보딩 대기 중..."
  wait_for_delivered_message "$project" "$start_lines" '\[delivered\] manager → user agent_ready normal "온보딩 완료"' || {
    echo "Error: Manager 준비 완료 알림을 확인하지 못했다." >&2
    exit 1
  }
  echo "Manager 온보딩 완료 확인"

  bash "$TOOLS_DIR/cmd.sh" boot "$project"
  set_project_stage "$project" "active"

  local boot_failed
  boot_failed="$(runtime_get_manager_state "$project" "boot_failed_agents" "" 2>/dev/null || true)"
  local boot_subject="팀 부팅 완료"
  local boot_content="모든 에이전트 부팅이 완료되었다. agent_ready 메시지를 확인하고, project.md의 목표를 분석하여 첫 태스크를 분배해라. techniques/task-distribution.md 절차를 따른다."
  if [ -n "$boot_failed" ]; then
    boot_subject="팀 부팅 완료 (일부 실패)"
    boot_content="에이전트 부팅이 끝났으나 일부가 실패했다. 실패: ${boot_failed}. agent_ready 메시지를 확인하고, 성공한 에이전트로 태스크를 분배해라. 실패한 에이전트는 reboot를 검토해라."
  fi
  bash "$TOOLS_DIR/message.sh" "$project" orchestrator manager status_update normal \
    "$boot_subject" \
    "$boot_content" \
    2>/dev/null || true

  echo "=== 전체 부팅 완료 ==="
  echo "tmux attach -t $sess 로 접속하라."
}

# ──────────────────────────────────────────────
# boot 서브커맨드
# ──────────────────────────────────────────────

cmd_boot() {
  local project="$1"
  validate_project_name "$project"
  local exec_mode
  exec_mode="$(get_exec_mode "$project")"
  local loop_mode
  loop_mode="$(get_loop_mode "$project")"
  local stage
  stage="$(get_project_stage "$project")"

  if [ "$stage" = "onboarding" ]; then
    echo "Error: ${project}는 onboarding 단계다. 팀 부팅 전에 boot-manager를 먼저 실행해라." >&2
    exit 1
  fi

  # Preflight 검증
  bash "$TOOLS_DIR/preflight.sh" "$project" --mode "$exec_mode" || exit 1

  local sess
  sess="$(session_name "$project")"

  echo "=== ${project} 프로젝트 부팅 (mode: ${exec_mode}, loop: ${loop_mode}) ==="
  python3 "$TOOLS_DIR/log.py" system "$project" orchestrator project_boot_start "$project" --detail mode="$exec_mode" loop="$loop_mode" || true

  # 1. sessions.md 초기화 (멱등 — boot-manager에서 이미 생성했으면 건너뜀)
  init_sessions_file "$project"
  stale_missing_active_session_rows "$project" "$sess"
  reset_stale_boot_runtime_state "$project"

  # 2. tmux 세션 생성 또는 기존 재사용
  if tmux has-session -t "$sess" 2>/dev/null; then
    echo "기존 tmux 세션 '$sess' 재사용 (boot-manager로 생성됨)"
  else
    ensure_tmux_session_with_dashboard "$project"
    if ! tmux list-windows -t "$sess" -F '#{window_name}' 2>/dev/null | grep -q '^manager$'; then
      tmux new-window -d -t "$sess" -n manager
    fi
    echo "tmux 세션 '$sess' 생성됨"
  fi

  # 3. 각 에이전트 부팅 (manager가 이 명령을 호출하므로 manager는 이미 준비됨)
  local agents
  agents="$(get_active_agents "$project")"

  if [ -z "$agents" ]; then
    echo "Error: project.md에서 활성 에이전트를 찾을 수 없다." >&2
    exit 1
  fi

  local discussion_backend
  discussion_backend="$(get_manager_backend "$project")"
  local failed_agents=""
  boot_agent_with_backend "discussion" "$project" "discussion" "$discussion_backend" "" "" "user" || {
    echo "Warning: discussion 부팅 실패. 건너뜀." >&2
    failed_agents="discussion"
  }

  for role in $agents; do
    # manager/discussion은 control-plane 역할로 별도 처리됨
    if [ "$role" = "manager" ] || [ "$role" = "discussion" ]; then
      continue
    fi

    if [ "$exec_mode" = "dual" ] && role_supports_dual "$role"; then
      local pending_task_claude=""
      local pending_task_codex=""
      # dual 모드: worktree 생성 + claude + codex 양쪽 부팅
      create_worktrees "$project" "$role"
      pending_task_claude="$(resume_pending_task_for_window "$project" "$role" "${role}-claude")" || pending_task_claude=""
      pending_task_codex="$(resume_pending_task_for_window "$project" "$role" "${role}-codex")" || pending_task_codex=""
      boot_single_agent "$role" "$project" "" "${role}-claude" "$pending_task_claude" || {
        echo "Warning: ${role}-claude 부팅 실패. 건너뜀." >&2
        failed_agents="${failed_agents:+${failed_agents},}${role}-claude"
      }
      boot_codex_agent "$role" "$project" "${role}-codex" "" "$pending_task_codex" || {
        echo "Warning: ${role}-codex 부팅 실패. 건너뜀." >&2
        failed_agents="${failed_agents:+${failed_agents},}${role}-codex"
      }
    else
      # solo 모드 (기존 동작)
      if [ "$loop_mode" = "ralph" ] && role_uses_ralph_worktree "$role"; then
        create_ralph_worktree "$project" "$role" || true
      fi
      boot_single_agent "$role" "$project" || {
        echo "Warning: ${role} 부팅 실패. 건너뜀." >&2
        failed_agents="${failed_agents:+${failed_agents},}${role}"
        continue
      }
    fi
  done

  # 부팅 실패 에이전트 목록을 런타임 상태에 기록 (호출자가 참조)
  if [ -n "$failed_agents" ]; then
    runtime_set_manager_state "$project" "boot_failed_agents" "$failed_agents"
  else
    runtime_clear_manager_state "$project" "boot_failed_agents"
  fi

  # 5. dashboard 윈도우 생성 (Rich Live TUI) — boot-manager에서 이미 만들었으면 건너뜀
  if ! tmux list-windows -t "$sess" -F '#{window_name}' 2>/dev/null | grep -q '^dashboard$'; then
    ensure_dashboard_window "$project"
    echo "dashboard 윈도우 생성됨"
  else
    ensure_dashboard_window "$project"
    echo "dashboard 윈도우 이미 존재 — 재시작"
  fi

  # 6. monitor.sh 백그라운드 실행 (자동 재시작 wrapper)
  # 기존 좀비 monitor 정리: wrapper PID kill → 자식 kill → broad sweep
  local old_monitor_pid
  old_monitor_pid="$(runtime_get_manager_state "$project" "monitor_pid" "" 2>/dev/null || true)"
  if [[ "${old_monitor_pid:-}" =~ ^[0-9]+$ ]] && kill -0 "$old_monitor_pid" 2>/dev/null; then
    kill "$old_monitor_pid" 2>/dev/null || true
    pkill -P "$old_monitor_pid" 2>/dev/null || true
  fi
  pkill -f "monitor\\.sh[[:space:]]+${project}" 2>/dev/null || true
  runtime_clear_manager_state "$project" "monitor_pid" || true
  runtime_clear_manager_state "$project" "monitor_heartbeat" || true
  runtime_release_manager_lock "$project" || true
  sleep 1  # lock 파일 해제 및 프로세스 종료 대기
  local log_dir="$(project_dir "$project")/logs"
  mkdir -p "$log_dir"
  ensure_manager_runtime_layout "$project"
  nohup bash -c "
    while true; do
      bash \"$TOOLS_DIR/monitor.sh\" \"$project\"
      echo \"\$(date '+%Y-%m-%d %H:%M:%S') monitor.sh 종료 감지. 10초 후 재시작...\" >&2
      sleep 10
    done
  " >/dev/null 2>&1 &
  local monitor_pid=$!
  runtime_set_manager_state "$project" "monitor_pid" "$monitor_pid"
  echo "monitor.sh 시작됨 (PID: $monitor_pid, 자동 재시작 wrapper)"
  python3 "$TOOLS_DIR/log.py" system "$project" orchestrator monitor_start monitor --detail pid="$monitor_pid" || true

  python3 "$TOOLS_DIR/log.py" system "$project" orchestrator project_boot_end "$project" || true
  set_project_stage "$project" "active"
  echo "=== 부팅 완료 ==="
  echo "tmux attach -t $sess 로 세션에 접속하라."
}

# ──────────────────────────────────────────────
# dispatch 서브커맨드
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
  local normalized_task target_report_rel claude_report_rel codex_report_rel
  local manager_report_rel="" target_csv="" role_csv="" report_refs=()
  task_subject_and_message "$task" subject base_msg "$project"
  normalized_task="$(normalize_task_ref "$project" "$subject")"

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
    target_report_rel="$(runtime_project_relative_path "$project" "$(runtime_task_report_path "$project" "$normalized_task" "$target")")"
    report_refs+=("${target}:${target_report_rel}")
    if [[ "$target" == *-claude ]]; then
      claude_report_rel="$target_report_rel"
    elif [[ "$target" == *-codex ]]; then
      codex_report_rel="$target_report_rel"
    fi
  done

  if [ "$TASK_EXEC_MANAGER_STUB" = "compare" ]; then
    if [ -n "${claude_report_rel:-}" ] && [ -n "${codex_report_rel:-}" ]; then
      runtime_write_dual_synthesis_report_stub "$project" "$normalized_task" "$claude_report_rel" "$codex_report_rel" >/dev/null
      manager_report_rel="$(runtime_project_relative_path "$project" "$(runtime_task_report_path "$project" "$normalized_task" "manager")")"
    else
      manager_report_rel="$(write_pattern_manager_report_stub "$project" "$normalized_task" "$TASK_EXEC_PATTERN" "${report_refs[@]}")"
    fi
  elif [ "$TASK_EXEC_MANAGER_STUB" = "verify" ]; then
    manager_report_rel="$(write_pattern_manager_report_stub "$project" "$normalized_task" "$TASK_EXEC_PATTERN" "${report_refs[@]}")"
  fi

  python3 "$TOOLS_DIR/log.py" system "$project" orchestrator task_dispatch "$role" \
    --detail task="$task" pattern="$TASK_EXEC_PATTERN" targets="$target_csv" roles="$role_csv" manager_report="${manager_report_rel:-}" || true
  echo "dispatch 완료: ${role} [${TASK_EXEC_PATTERN}] ← ${task} (${target_csv})"
}

# ──────────────────────────────────────────────
# dual-dispatch 서브커맨드
# ──────────────────────────────────────────────

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

# ──────────────────────────────────────────────
# reboot 서브커맨드
# ──────────────────────────────────────────────

cmd_reboot() {
  local target="$1"
  local project="$2"
  validate_project_name "$project"
  local sess
  sess="$(session_name "$project")"

  # target에서 role과 backend 분리
  # "researcher-claude" → role=researcher, backend=claude, window=researcher-claude
  # "researcher-codex"  → role=researcher, backend=codex, window=researcher-codex
  # "researcher"        → role=researcher, backend=claude, window=researcher (solo 호환)
  local role backend window_name resolved_target
  resolved_target="$(resolve_reboot_or_refresh_target "$target" "$project")"
  role="${resolved_target%%|*}"
  resolved_target="${resolved_target#*|}"
  backend="${resolved_target%%|*}"
  window_name="${resolved_target#*|}"

  echo "=== ${window_name} 에이전트 리부팅 ==="

  if [ "$backend" = "claude" ] && ! guard_claude_recovery "reboot" "$project" "$sess" "$window_name"; then
    runtime_clear_reboot_lock_ts "$project" "$window_name" || true
    return 1
  fi

  # reboot lock 획득 (경합 방지)
  ensure_manager_runtime_layout "$project"
  if ! runtime_try_claim_reboot_lock "$project" "$window_name" 60; then
    local lock_ts lock_age
    lock_ts="$(runtime_get_reboot_lock_ts "$project" "$window_name" 2>/dev/null || true)"
    if [[ "${lock_ts:-}" =~ ^[0-9]+$ ]]; then
      lock_age=$(( $(date +%s) - lock_ts ))
      echo "Info: ${window_name} 리부팅 진행 중 (${lock_age}초 전 시작). 건너뜀." >&2
    else
      echo "Info: ${window_name} 리부팅 lock 획득 실패. 건너뜀." >&2
    fi
    return 0
  fi

  # tmux 세션 존재 확인
  if ! tmux has-session -t "$sess" 2>/dev/null; then
    echo "Error: tmux 세션 '$sess'가 없다. boot를 먼저 실행하라." >&2
    runtime_clear_reboot_lock_ts "$project" "$window_name"
    exit 1
  fi

  # 1. 기존 윈도우 있으면 kill
  if window_indices_by_name "$sess" "$window_name" | grep -q .; then
    echo "기존 ${window_name} 윈도우 종료 중..."
    kill_windows_by_name "$sess" "$window_name" "1"
  fi

  # 2. sessions.md에서 이전 행을 crashed로 표시
  mark_window_status "$project" "$window_name" "active" "crashed"

  # 3. 중단된 태스크 조회
  local pending_task
  pending_task="$(resume_pending_task_for_window "$project" "$role" "$window_name")" || pending_task=""

  # 4. backend에 따라 적절한 부팅 함수 호출
  if [ "$backend" = "codex" ]; then
    boot_codex_agent "$role" "$project" "$window_name" "" "$pending_task" || {
      echo "Error: ${window_name} 리부팅 실패." >&2
      runtime_clear_reboot_lock_ts "$project" "$window_name"
      exit 1
    }
  else
    boot_single_agent "$role" "$project" "" "$window_name" "$pending_task" || {
      echo "Error: ${window_name} 리부팅 실패." >&2
      runtime_clear_reboot_lock_ts "$project" "$window_name"
      exit 1
    }
  fi

  # reboot lock 해제
  runtime_clear_reboot_lock_ts "$project" "$window_name"

  python3 "$TOOLS_DIR/log.py" system "$project" orchestrator agent_reboot "$window_name" || true
  echo "=== ${window_name} 리부팅 완료 ==="
}

# ──────────────────────────────────────────────
# refresh 서브커맨드
# ──────────────────────────────────────────────

cmd_refresh() {
  local target="$1"
  local project="$2"
  validate_project_name "$project"
  local sess
  sess="$(session_name "$project")"
  local handoff_wait="${WHIPLASH_REFRESH_HANDOFF_WAIT_SECONDS:-120}"
  local skip_handoff_request="${WHIPLASH_REFRESH_SKIP_HANDOFF_REQUEST:-0}"

  # target에서 role과 backend 분리 (reboot과 동일한 파싱)
  local role backend window_name resolved_target
  resolved_target="$(resolve_reboot_or_refresh_target "$target" "$project")"
  role="${resolved_target%%|*}"
  resolved_target="${resolved_target#*|}"
  backend="${resolved_target%%|*}"
  window_name="${resolved_target#*|}"

  echo "=== ${window_name} 에이전트 리프레시 ==="

  # tmux 세션 존재 확인
  if ! tmux has-session -t "$sess" 2>/dev/null; then
    echo "Error: tmux 세션 '$sess'가 없다. boot를 먼저 실행하라." >&2
    exit 1
  fi

  # 윈도우 존재 확인
  if ! tmux list-windows -t "$sess" -F '#{window_name}' 2>/dev/null | grep -q "^${window_name}$"; then
    echo "Error: ${window_name} 윈도우가 없다." >&2
    exit 1
  fi

  if [ "$backend" = "claude" ] && ! guard_claude_recovery "refresh" "$project" "$sess" "$window_name"; then
    return 1
  fi

  # handoff 파일 경로는 role 기준 (backend별로 분리하지 않음)
  local handoff_file="$(project_dir "$project")/memory/${role}/handoff.md"

  # 1. 에이전트에게 handoff.md 작성 지시
  if [ "$skip_handoff_request" != "1" ]; then
    echo "handoff.md 작성 지시 전송..."
    tmux send-keys -t "${sess}:${window_name}" \
      "지금까지의 작업 맥락을 memory/${role}/handoff.md에 정리해라. 현재 진행 상황, 다음 할 일, 중요 결정사항을 포함해라." Enter
  fi
  python3 "$TOOLS_DIR/log.py" system "$project" orchestrator agent_refresh_start "$window_name" || true

  # 2. 최대 handoff_wait초 대기 (handoff.md 파일 생성 감시)
  local waited=0
  if [ "$handoff_wait" -gt 0 ] 2>/dev/null; then
    echo "handoff.md 생성 대기 (최대 ${handoff_wait}초)..."
    while [ "$waited" -lt "$handoff_wait" ]; do
      if [ -f "$handoff_file" ]; then
        echo "handoff.md 생성 확인 (${waited}초 경과)"
        break
      fi
      sleep 5
      waited=$((waited + 5))
    done
  fi

  if [ ! -f "$handoff_file" ] && [ "$handoff_wait" -gt 0 ] 2>/dev/null; then
    echo "Warning: ${handoff_wait}초 내에 handoff.md가 생성되지 않았다. 그래도 리프레시를 진행한다." >&2
  fi

  # 3. 기존 세션 종료
  echo "기존 ${window_name} 세션 종료 중..."
  tmux send-keys -t "${sess}:${window_name}" "/exit" Enter 2>/dev/null || true
  sleep 3
  tmux kill-window -t "${sess}:${window_name}" 2>/dev/null || true

  # 4. sessions.md에서 이전 행을 refreshed로 표시
  mark_window_status "$project" "$window_name" "active" "refreshed"

  # 5. active 태스크 조회 + 새 세션 부팅 (온보딩 + handoff.md 읽기 지시 추가)
  local pending_task=""
  pending_task="$(resume_pending_task_for_window "$project" "$role" "$window_name")" || pending_task=""
  local extra_msg=""
  if [ -f "$handoff_file" ]; then
    extra_msg="10. memory/${role}/handoff.md를 읽어라. 이전 세션에서 인수인계한 맥락이다."
  fi

  if [ "$backend" = "codex" ]; then
    boot_codex_agent "$role" "$project" "$window_name" "$extra_msg" "$pending_task" || {
      echo "Error: ${window_name} 리프레시 후 부팅 실패." >&2
      exit 1
    }
  else
    boot_single_agent "$role" "$project" "$extra_msg" "$window_name" "$pending_task" || {
      echo "Error: ${window_name} 리프레시 후 부팅 실패." >&2
      exit 1
    }
  fi

  python3 "$TOOLS_DIR/log.py" system "$project" orchestrator agent_refresh_end "$window_name" || true
  echo "=== ${window_name} 리프레시 완료 ==="
}

# ──────────────────────────────────────────────
# monitor-check 서브커맨드
# ──────────────────────────────────────────────

cmd_monitor_check() {
  local project="$1"
  validate_project_name "$project"
  ensure_manager_runtime_layout "$project"
  local now pid lock_pid active_pid hb_time
  now=$(date +%s)

  pid="$(runtime_get_manager_state "$project" "monitor_pid" "" 2>/dev/null || true)"
  lock_pid="$(runtime_get_manager_state "$project" "monitor_lock_pid" "" 2>/dev/null || true)"

  if [[ "${lock_pid:-}" =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" 2>/dev/null; then
    active_pid="$lock_pid"
  elif [[ "${pid:-}" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    active_pid="$pid"
  else
    active_pid=""
  fi

  # PID 파일 확인
  if [ -z "$pid" ] && [ -z "$active_pid" ]; then
    echo "[monitor-check] PID 파일 없음. monitor.sh 재시작 중..."
    restart_monitor "$project"
    run_monitor_drain_once_if_queued "$project"
    return
  fi

  # PID가 숫자인지 확인
  if [ -n "$pid" ] && ! [[ "$pid" =~ ^[0-9]+$ ]]; then
    echo "[monitor-check] PID 파일에 잘못된 값: '$pid'. monitor.sh 재시작 중..." >&2
    restart_monitor "$project"
    run_monitor_drain_once_if_queued "$project"
    return
  fi

  # 프로세스 생존 확인
  if [ -z "$active_pid" ]; then
    echo "[monitor-check] monitor.sh 프로세스 죽음 (PID: $pid). 재시작 중..."
    restart_monitor "$project"
    run_monitor_drain_once_if_queued "$project"
    return
  fi

  # heartbeat 신선도 확인 (90초 이상이면 좀비)
  hb_time="$(runtime_get_manager_state "$project" "monitor_heartbeat" "" 2>/dev/null || true)"
  if [ -n "$hb_time" ]; then
    if ! [[ "$hb_time" =~ ^[0-9]+$ ]]; then
      echo "[monitor-check] heartbeat 파일에 잘못된 값. 프로세스 확인 필요."
      run_monitor_drain_once_if_queued "$project"
      return
    fi
    local hb_age=$((now - hb_time))
    if [ "$hb_age" -gt 90 ]; then
      echo "[monitor-check] heartbeat ${hb_age}초 전 (좀비). 강제 종료 후 재시작..."
      python3 "$TOOLS_DIR/log.py" system "$project" orchestrator monitor_zombie monitor --detail heartbeat_age="${hb_age}s" || true
      if [[ "${lock_pid:-}" =~ ^[0-9]+$ ]]; then
        kill "$lock_pid" 2>/dev/null || true
      fi
      if [[ "${pid:-}" =~ ^[0-9]+$ ]] && [ "${pid:-}" != "${lock_pid:-}" ]; then
        kill "$pid" 2>/dev/null || true
      fi
      sleep 1
      restart_monitor "$project"
      run_monitor_drain_once_if_queued "$project"
      return
    fi
    echo "[monitor-check] monitor.sh 정상 (PID: $active_pid, heartbeat: ${hb_age}초 전)"
    run_monitor_drain_once_if_queued "$project"
  else
    echo "[monitor-check] heartbeat 파일 없음. 프로세스 확인 필요."
    run_monitor_drain_once_if_queued "$project"
  fi
}

restart_monitor() {
  local project="$1"
  local log_dir="$(project_dir "$project")/logs"
  mkdir -p "$log_dir"
  nohup bash -c "
    while true; do
      bash \"$TOOLS_DIR/monitor.sh\" \"$project\"
      echo \"\$(date '+%Y-%m-%d %H:%M:%S') monitor.sh 종료 감지. 10초 후 재시작...\" >&2
      sleep 10
    done
  " >/dev/null 2>&1 &
  local new_pid=$!
  runtime_set_manager_state "$project" "monitor_pid" "$new_pid"
  python3 "$TOOLS_DIR/log.py" system "$project" orchestrator monitor_restart monitor --detail pid="$new_pid" || true
  echo "[monitor-check] monitor.sh 재시작 완료 (PID: $new_pid, 자동 재시작 wrapper)"
}

run_monitor_drain_once_if_queued() {
  local project="$1"
  local queue_dir
  queue_dir="$(runtime_message_queue_dir "$project")"
  if compgen -G "${queue_dir}/*.msg" >/dev/null 2>&1; then
    WHIPLASH_MONITOR_ONCE=1 bash "$TOOLS_DIR/monitor.sh" "$project" >/dev/null 2>&1 || true
  fi
}

# ──────────────────────────────────────────────
# shutdown 서브커맨드
# ──────────────────────────────────────────────

cmd_shutdown() {
  local project="$1"
  validate_project_name "$project"
  local sess
  sess="$(session_name "$project")"

  echo "=== ${project} 프로젝트 종료 ==="
  python3 "$TOOLS_DIR/log.py" system "$project" orchestrator project_shutdown "$project" || true

  # 1. 각 에이전트 윈도우에 /exit 전송
  if tmux has-session -t "$sess" 2>/dev/null; then
    local windows
    windows=$(tmux list-windows -t "$sess" -F '#{window_index}:#{window_name}')
    while IFS=: read -r win_idx win_name; do
      [ -z "$win_idx" ] && continue
      echo "${win_name}에 /exit 전송"
      tmux send-keys -t "${sess}:${win_idx}" "/exit" Enter 2>/dev/null || true
    done <<< "$windows"

    # 2. 5초 대기
    echo "에이전트 종료 대기 (5초)..."
    sleep 5

    # 3. tmux 세션 종료
    tmux kill-session -t "$sess" 2>/dev/null || true
    echo "tmux 세션 '$sess' 종료됨"
  else
    echo "tmux 세션 '$sess'가 없다. 이미 종료된 듯."
  fi

  # 4. monitor.sh 프로세스 종료 (wrapper + 자식 + 좀비 방지)
  ensure_manager_runtime_layout "$project"
  local pid
  pid="$(runtime_get_manager_state "$project" "monitor_pid" "" 2>/dev/null || true)"
  if [[ "${pid:-}" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    # wrapper와 자식 monitor.sh 모두 종료
    pkill -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
    echo "monitor.sh 종료됨 (PID: $pid)"
  fi
  # 좀비 방지: 이 프로젝트의 monitor.sh 프로세스를 모두 kill
  # (이전 세션에서 대기 모드로 살아남은 프로세스 포함)
  pkill -f "monitor\\.sh[[:space:]]+${project}$" 2>/dev/null || true
  runtime_clear_manager_state "$project" "monitor_pid" || true
  runtime_clear_manager_state "$project" "monitor_heartbeat" || true
  runtime_clear_manager_state "$project" "monitor_nudge_ts" || true
  clear_project_stage "$project" || true
  runtime_release_manager_lock "$project" || true

  # 5. sessions.md 업데이트
  close_all_sessions "$project"

  # 6. persistent ralph worktree 정리
  remove_ralph_worktree "$project" "developer" || true
  remove_ralph_worktree "$project" "systems-engineer" || true

  # 7. 런타임 파일 정리 (reboot 카운터, heartbeat, 메시지 큐, reboot lock)
  rm -rf "$(runtime_message_queue_dir "$project")"
  rm -f "$(runtime_reboot_state_file "$project")"
  rm -f "$(runtime_idle_state_file "$project")"
  cleanup_manager_runtime_transients "$project"

  echo "=== 종료 완료 ==="
}

# ──────────────────────────────────────────────
# status 서브커맨드
# ──────────────────────────────────────────────

cmd_status() {
  local project="$1"
  validate_project_name "$project"
  local sess
  sess="$(session_name "$project")"
  local now
  now=$(date +%s)
  local stage
  stage="$(get_project_stage "$project")"

  echo "=== ${project} 프로젝트 상태 ==="
  echo "[stage] ${stage}"

  # tmux 세션 확인 (idle 시간 포함)
  if tmux has-session -t "$sess" 2>/dev/null; then
    echo "[tmux] 세션 활성"
    while IFS= read -r line; do
      local win_name win_activity idle_sec
      win_name=$(echo "$line" | cut -d'|' -f1)
      win_activity=$(echo "$line" | cut -d'|' -f2)
      if [ -n "$win_activity" ] && [ "$win_activity" != "0" ]; then
        idle_sec=$((now - win_activity))
        local idle_min=$((idle_sec / 60))
        local idle_rem=$((idle_sec % 60))
        echo "  ${win_name} (idle: ${idle_min}분 ${idle_rem}초)"
      else
        echo "  ${win_name} (idle: 알 수 없음)"
      fi
    done < <(tmux list-windows -t "$sess" -F '#{window_name}|#{window_activity}')
    print_agent_health_status "$project" "$sess"
  else
    echo "[tmux] 세션 없음"
  fi

  # monitor.sh 확인 (PID + heartbeat 신선도)
  ensure_manager_runtime_layout "$project"
  local pid lock_pid active_pid hb_time
  pid="$(runtime_get_manager_state "$project" "monitor_pid" "" 2>/dev/null || true)"
  lock_pid="$(runtime_get_manager_state "$project" "monitor_lock_pid" "" 2>/dev/null || true)"

  if [[ "${lock_pid:-}" =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" 2>/dev/null; then
    active_pid="$lock_pid"
  elif [[ "${pid:-}" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    active_pid="$pid"
  else
    active_pid=""
  fi

  if [ -n "$pid" ] && ! [[ "$pid" =~ ^[0-9]+$ ]]; then
    echo "[monitor] PID 상태값이 잘못됨: '$pid'"
  elif [ -n "$active_pid" ]; then
    hb_time="$(runtime_get_manager_state "$project" "monitor_heartbeat" "" 2>/dev/null || true)"
    if [ -n "$hb_time" ]; then
      if [[ "$hb_time" =~ ^[0-9]+$ ]]; then
        local hb_age=$((now - hb_time))
        if [ "$hb_age" -gt 90 ]; then
          echo "[monitor] 실행 중 (PID: $active_pid) -- WARNING: heartbeat ${hb_age}초 전 (좀비 가능성)"
        else
          echo "[monitor] 실행 중 (PID: $active_pid, heartbeat: ${hb_age}초 전)"
        fi
      else
        echo "[monitor] 실행 중 (PID: $active_pid, heartbeat 상태값이 잘못됨)"
      fi
    else
      echo "[monitor] 실행 중 (PID: $active_pid, heartbeat 없음)"
    fi
  elif [ -n "$pid" ]; then
    echo "[monitor] 프로세스 죽음 (PID: $pid)"
  else
    echo "[monitor] 미시작"
  fi

  # sessions.md 출력
  local sf
  sf="$(sessions_file "$project")"
  if [ -f "$sf" ]; then
    echo ""
    cat "$sf"
  fi

  echo ""
  print_agent_health_status "$project" "$sess"
}

# ──────────────────────────────────────────────
# merge-worktree 서브커맨드
# ──────────────────────────────────────────────

cmd_merge_worktree() {
  local role="$1"
  local winner="$2"   # "claude" | "codex"
  local project="$3"
  validate_project_name "$project"

  if [ "$winner" != "claude" ] && [ "$winner" != "codex" ]; then
    echo "Error: winner는 'claude' 또는 'codex'만 가능하다. 입력값: '$winner'" >&2
    exit 1
  fi

  local code_repo
  code_repo="$(get_code_repo "$project")"
  if [ -z "$code_repo" ] || [ ! -d "$code_repo" ]; then
    echo "Error: 프로젝트 폴더가 설정되지 않았거나 존재하지 않음." >&2
    exit 1
  fi

  local winner_branch="dual/${role}-${winner}"
  local wt_dir="${code_repo}/.worktrees"

  echo "=== merge-worktree: ${role} (winner: ${winner}) ==="

  # 1. winner 브랜치를 main에 merge
  local current_branch
  current_branch=$(git -C "$code_repo" rev-parse --abbrev-ref HEAD)

  # main 브랜치로 전환 (현재 브랜치가 main이 아닌 경우)
  if [ "$current_branch" != "main" ]; then
    git -C "$code_repo" checkout main || {
      echo "Error: main 브랜치 checkout 실패." >&2
      exit 1
    }
  fi

  git -C "$code_repo" merge "$winner_branch" -m "Merge dual/${role}-${winner} (dual mode consensus winner)" || {
    echo "Error: merge 실패. 충돌을 수동으로 해결하라." >&2
    exit 1
  }

  echo "merge 완료: ${winner_branch} → main"

  # 2. 양쪽 worktree + 브랜치 정리
  remove_worktrees "$project" "$role"

  python3 "$TOOLS_DIR/log.py" system "$project" orchestrator merge_worktree "$role" \
    --detail winner="$winner" branch="$winner_branch" || true
  echo "=== merge-worktree 완료 ==="
}

# ──────────────────────────────────────────────
# 메인
# ──────────────────────────────────────────────

if [ "${WHIPLASH_SOURCE_ONLY:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

if [ $# -lt 2 ]; then
  echo "Usage:" >&2
  echo "  cmd.sh boot-onboarding {project}" >&2
  echo "  cmd.sh boot-manager   {project}" >&2
  echo "  cmd.sh boot           {project}" >&2
  echo "  cmd.sh dispatch       {role} {task-file} {project}" >&2
  echo "  cmd.sh dual-dispatch  {role} {task-file} {project}" >&2
  echo "  cmd.sh spawn          {role} {window-name} {project} [extra-msg]" >&2
  echo "  cmd.sh kill-agent     {window-name} {project}" >&2
  echo "  cmd.sh shutdown       {project}" >&2
  echo "  cmd.sh status         {project}" >&2
  echo "  cmd.sh reboot         {target} {project}" >&2
  echo "  cmd.sh refresh        {target} {project}" >&2
  echo "  cmd.sh merge-worktree {role} {winner} {project}" >&2
  echo "  cmd.sh monitor-check  {project}" >&2
  exit 1
fi

command="$1"
shift

case "$command" in
  boot-onboarding)
    [ $# -lt 1 ] && { echo "Usage: cmd.sh boot-onboarding {project}" >&2; exit 1; }
    activate_project_tmux_context "$1"
    cmd_boot_onboarding "$1"
    ;;
  handoff)
    [ $# -lt 1 ] && { echo "Usage: cmd.sh handoff {project}" >&2; exit 1; }
    activate_project_tmux_context "$1"
    cmd_handoff "$1"
    ;;
  boot-manager)
    [ $# -lt 1 ] && { echo "Usage: cmd.sh boot-manager {project}" >&2; exit 1; }
    activate_project_tmux_context "$1"
    cmd_boot_manager "$1"
    ;;
  boot)
    [ $# -lt 1 ] && { echo "Usage: cmd.sh boot {project}" >&2; exit 1; }
    activate_project_tmux_context "$1"
    cmd_boot "$1"
    ;;
  dispatch)
    [ $# -lt 3 ] && { echo "Usage: cmd.sh dispatch {role} {task-file} {project} [pattern]" >&2; exit 1; }
    cmd_dispatch "$1" "$2" "$3" "${4:-}"
    ;;
  dual-dispatch)
    [ $# -lt 3 ] && { echo "Usage: cmd.sh dual-dispatch {role} {task-file} {project}" >&2; exit 1; }
    activate_project_tmux_context "$3"
    cmd_dual_dispatch "$1" "$2" "$3"
    ;;
  spawn)
    [ $# -lt 3 ] && { echo "Usage: cmd.sh spawn {role} {window-name} {project} [extra-msg]" >&2; exit 1; }
    activate_project_tmux_context "$3"
    cmd_spawn "$1" "$2" "$3" "${4:-}"
    ;;
  kill-agent)
    [ $# -lt 2 ] && { echo "Usage: cmd.sh kill-agent {window-name} {project}" >&2; exit 1; }
    activate_project_tmux_context "$2"
    cmd_kill_agent "$1" "$2"
    ;;
  shutdown)
    [ $# -lt 1 ] && { echo "Usage: cmd.sh shutdown {project}" >&2; exit 1; }
    activate_project_tmux_context "$1"
    cmd_shutdown "$1"
    ;;
  status)
    [ $# -lt 1 ] && { echo "Usage: cmd.sh status {project}" >&2; exit 1; }
    activate_project_tmux_context "$1"
    cmd_status "$1"
    ;;
  reboot)
    [ $# -lt 2 ] && { echo "Usage: cmd.sh reboot {target} {project}" >&2; exit 1; }
    activate_project_tmux_context "$2"
    cmd_reboot "$1" "$2"
    ;;
  refresh)
    [ $# -lt 2 ] && { echo "Usage: cmd.sh refresh {target} {project}" >&2; exit 1; }
    activate_project_tmux_context "$2"
    cmd_refresh "$1" "$2"
    ;;
  merge-worktree)
    [ $# -lt 3 ] && { echo "Usage: cmd.sh merge-worktree {role} {winner} {project}" >&2; exit 1; }
    activate_project_tmux_context "$3"
    cmd_merge_worktree "$1" "$2" "$3"
    ;;
  monitor-check)
    [ $# -lt 1 ] && { echo "Usage: cmd.sh monitor-check {project}" >&2; exit 1; }
    activate_project_tmux_context "$1"
    cmd_monitor_check "$1"
    ;;
  complete)
    [ $# -lt 2 ] && { echo "Usage: cmd.sh complete {agent} {project}" >&2; exit 1; }
    activate_project_tmux_context "$2"
    cmd_complete "$1" "$2"
    ;;
  expire-stale)
    [ $# -lt 1 ] && { echo "Usage: cmd.sh expire-stale {project} [max-hours]" >&2; exit 1; }
    activate_project_tmux_context "$1"
    expire_stale_assignments "$1" "${2:-4}"
    ;;
  assign)
    [ $# -lt 3 ] && { echo "Usage: cmd.sh assign {agent} {task} {project}" >&2; exit 1; }
    activate_project_tmux_context "$3"
    cmd_assign "$1" "$2" "$3"
    ;;
  *)
    echo "Unknown command: $command" >&2
    echo "Available: boot-onboarding, boot-manager, boot, dispatch, dual-dispatch, assign, spawn, kill-agent, shutdown, status, reboot, refresh, merge-worktree, monitor-check, complete, expire-stale" >&2
    exit 1
    ;;
esac
