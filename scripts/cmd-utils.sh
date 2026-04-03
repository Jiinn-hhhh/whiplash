# cmd-utils.sh -- 공통 유틸리티 함수
#
# cmd.sh에서 source된다. 단독 실행하지 않는다.
# 의존: SCRIPT_DIR, REPO_ROOT, TOOLS_DIR (cmd.sh에서 설정)
# 의존: tmux-submit.sh, runtime-paths.sh, agent-health.sh, assignment-state.sh, execution-config.sh (cmd.sh에서 source)

# ──────────────────────────────────────────────
# tmux wrapper
# ──────────────────────────────────────────────

tmux() {
  command tmux "$@"
}

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
  # M-01: sed 메타문자 방지 — project 이름 재검증
  if [[ "$1" =~ [^a-zA-Z0-9_-] ]]; then
    echo "Error: session_name에 잘못된 project 이름: '$1'" >&2
    return 1
  fi
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

project_se_memory_dir() {
  echo "$(project_dir "$1")/memory/systems-engineer"
}

project_se_team_md_path() {
  echo "$(project_dir "$1")/team/systems-engineer.md"
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

is_canonical_role() {
  local role="$1"
  case "$role" in
    onboarding|manager|discussion|developer|researcher|systems-engineer|monitoring) return 0 ;;
    *) return 1 ;;
  esac
}

is_worker_role() {
  local role="$1"
  case "$role" in
    developer|researcher|systems-engineer|monitoring) return 0 ;;
    *) return 1 ;;
  esac
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

  # WHIPLASH_AUTH_RESTART_BYPASS=1이면 monitor의 자동 재시작 시도를 허용
  if [ "${WHIPLASH_AUTH_RESTART_BYPASS:-0}" = "1" ]; then
    return 0
  fi

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

canonical_role_from_window_name() {
  local window_name="$1"
  case "$window_name" in
    onboarding|manager|discussion|developer|researcher|systems-engineer|monitoring)
      printf '%s\n' "$window_name"
      return 0
      ;;
    *-claude)
      local role="${window_name%-claude}"
      if is_canonical_role "$role"; then
        printf '%s\n' "$role"
        return 0
      fi
      ;;
    *-codex)
      local role="${window_name%-codex}"
      if is_canonical_role "$role"; then
        printf '%s\n' "$role"
        return 0
      fi
      ;;
  esac
  return 1
}

session_role_for_window() {
  local project="$1" window_name="$2"
  local sf sess target
  sf="$(sessions_file "$project")"
  [ -f "$sf" ] || return 1
  sess="$(session_name "$project")"
  target="${sess}:${window_name}"
  awk -F'|' -v target="$target" '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    trim($5) == target && trim($6) == "active" { role = trim($2) }
    END {
      if (role != "") {
        print role
      }
    }
  ' "$sf"
}

session_backend_for_window() {
  local project="$1" window_name="$2"
  local sf sess target
  sf="$(sessions_file "$project")"
  [ -f "$sf" ] || return 1
  sess="$(session_name "$project")"
  target="${sess}:${window_name}"
  awk -F'|' -v target="$target" '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    trim($5) == target && trim($6) == "active" { backend = trim($3) }
    END {
      if (backend != "") {
        print backend
      }
    }
  ' "$sf"
}

get_current_preset() {
  local project="$1"
  local preset
  preset="$(execution_config_current_preset "$project" 2>/dev/null || true)"
  if [ -n "$preset" ]; then
    printf '%s\n' "$preset"
    return 0
  fi

  if [ "$(get_exec_mode "$project")" = "dual" ]; then
    printf 'dual\n'
  else
    printf 'default\n'
  fi
}

resolve_role_backend() {
  local project="$1" role="$2"
  local backend

  if [ "$role" = "manager" ] && [ -n "${WHIPLASH_MANAGER_BACKEND:-}" ]; then
    case "${WHIPLASH_MANAGER_BACKEND}" in
      claude|codex)
        printf '%s\n' "$WHIPLASH_MANAGER_BACKEND"
        return 0
        ;;
    esac
  fi

  backend="$(execution_config_role_backend "$project" "$role" 2>/dev/null || true)"
  case "$backend" in
    claude|codex)
      printf '%s\n' "$backend"
      return 0
      ;;
  esac

  case "$role" in
    onboarding|manager|discussion) printf 'codex\n' ;;
    *) printf 'claude\n' ;;
  esac
}

resolve_role_model() {
  local project="$1" role="$2" backend="$3"
  local model=""

  if [ "$backend" = "codex" ] && [ -n "${WHIPLASH_CODEX_MODEL:-}" ]; then
    printf '%s\n' "$WHIPLASH_CODEX_MODEL"
    return 0
  fi

  model="$(execution_config_role_model "$project" "$role" "$backend" 2>/dev/null || true)"
  if [ -n "$model" ]; then
    printf '%s\n' "$model"
    return 0
  fi

  if [ "$backend" = "codex" ]; then
    get_codex_model
  else
    get_model "$role"
  fi
}

role_runs_dual_now() {
  local project="$1" role="$2"
  local dual_flag
  dual_flag="$(execution_config_role_runs_dual "$project" "$role" 2>/dev/null || true)"
  if [ "$dual_flag" = "true" ]; then
    return 0
  fi
  return 1
}

role_window_plan_lines() {
  local project="$1" role="$2"
  local lines
  lines="$(execution_config_role_window_lines "$project" "$role" 2>/dev/null || true)"
  if [ -n "$lines" ]; then
    printf '%s\n' "$lines"
    return 0
  fi

  if role_supports_dual "$role" && [ "$(get_exec_mode "$project")" = "dual" ]; then
    printf '%s\n' "${role}-claude|claude|$(get_model "$role")"
    printf '%s\n' "${role}-codex|codex|$(get_codex_model)"
    return 0
  fi

  local backend
  backend="$(resolve_role_backend "$project" "$role")"
  printf '%s|%s|%s\n' "$role" "$backend" "$(resolve_role_model "$project" "$role" "$backend")"
}

resolve_window_backend() {
  local project="$1" window_name="$2" role_hint="${3:-}"
  local backend role

  case "$window_name" in
    *-codex|*-codex-*)
      printf 'codex\n'
      return 0
      ;;
    *-claude|*-claude-*)
      printf 'claude\n'
      return 0
      ;;
  esac

  backend="$(session_backend_for_window "$project" "$window_name" 2>/dev/null || true)"
  case "$backend" in
    claude|codex)
      printf '%s\n' "$backend"
      return 0
      ;;
  esac

  role="$role_hint"
  if [ -z "$role" ]; then
    role="$(session_role_for_window "$project" "$window_name" 2>/dev/null || true)"
  fi
  if [ -z "$role" ]; then
    role="$(canonical_role_from_window_name "$window_name" 2>/dev/null || true)"
  fi
  if [ -n "$role" ] && is_canonical_role "$role"; then
    resolve_role_backend "$project" "$role"
    return 0
  fi

  printf 'claude\n'
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

  # agent_id 검증을 경로 계산 전에 수행 (defense-in-depth — H-02 수정)
  if [[ "$agent_id" =~ [^a-zA-Z0-9_-] ]]; then
    echo "Error: 잘못된 agent_id: '$agent_id' (영문/숫자/하이픈/밑줄만 허용)" >&2
    return 1
  fi

  local script_path base_path tmux_socket_name
  script_path="$(agent_env_script_path "$project" "$agent_id")"
  base_path="$PATH"

  local env_dir
  env_dir="$(dirname "$script_path")"
  mkdir -p "$env_dir"
  chmod 700 "$env_dir"

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
  if [ -z "$project" ]; then
    project="${WHIPLASH_TMUX_PROJECT:-}"
  fi
  if [ -n "$project" ]; then
    resolve_role_backend "$project" "manager"
    return 0
  fi
  printf 'codex\n'
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
  local mode
  mode="$(execution_config_exec_mode "$project" 2>/dev/null || true)"
  if [ "$mode" = "dual" ]; then
    printf 'dual\n'
  else
    printf 'solo\n'
  fi
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

# sessions.md에서 active가 아닌 행(closed, crashed, stale, refreshed 등)을 제거
# boot 시 호출하여 이전 세션 잔재를 정리한다
prune_inactive_sessions() {
  local project="$1"
  local sf tmp
  sf="$(sessions_file "$project")"
  [ -f "$sf" ] || return 0
  tmp="${sf}.tmp"

  awk '
    BEGIN { FS=OFS="|" }
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    {
      status = trim($6)
      # 헤더, 구분선, 빈 줄, active 행은 유지
      if (NR <= 4 || status == "active") {
        print
      }
    }
  ' "$sf" > "$tmp" && mv "$tmp" "$sf"
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
    tmux set-option -t "$sess" window-status-current-style "bg=red,fg=white,bold"
    tmux set-option -t "$sess" window-status-current-format " #I:#W "
    tmux set-option -t "$sess" window-status-format " #I:#W "
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
  tmux set-option -t "$sess" window-status-current-style "bg=red,fg=white,bold"
  tmux set-option -t "$sess" window-status-current-format " #I:#W "
  tmux set-option -t "$sess" window-status-format " #I:#W "
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
    if is_canonical_role "$target"; then
      resolved_role="$target"
      if role_runs_dual_now "$project" "$resolved_role"; then
        resolved_backend="codex"
        resolved_window="${resolved_role}-codex"
      else
        resolved_window="$target"
        resolved_backend="$(resolve_role_backend "$project" "$resolved_role")"
      fi
    else
      resolved_window="$target"
      resolved_role="$(session_role_for_window "$project" "$target" 2>/dev/null || true)"
      if [ -z "$resolved_role" ]; then
        resolved_role="$(canonical_role_from_window_name "$target" 2>/dev/null || true)"
      fi
      if [ -z "$resolved_role" ]; then
        resolved_role="$target"
      fi
      resolved_backend="$(resolve_window_backend "$project" "$target" "$resolved_role")"
    fi
  fi

  printf '%s|%s|%s\n' "$resolved_role" "$resolved_backend" "$resolved_window"
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
