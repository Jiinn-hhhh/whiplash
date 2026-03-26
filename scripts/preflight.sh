#!/bin/bash
# preflight.sh -- 부팅 전 환경 검증 + 자동 설치
#
# Usage: preflight.sh {project} [--mode solo|dual] [--skip-project-check]
# 종료 코드: 0=통과, 1=실패
#
# 동작 원칙:
#   - 설치 가능한 패키지 → 자동 설치 (macOS: brew, Linux: apt)
#   - 이미 설치됨 → 조용히 통과
#   - 자동 설치 불가 → 에러 메시지 + exit 1
#   - 최초 성공 후 .preflight-ok 마커 → 이후 패키지 검사 건너뜀
#   - claude 인증, codex(dual/control-plane), 프로젝트 구조 검증은 매번 실행

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MARKER="$REPO_ROOT/.preflight-ok"

# ── 인자 파싱 ──

if [ $# -lt 1 ]; then
  echo "Usage: preflight.sh {project} [--mode solo|dual] [--skip-project-check]" >&2
  exit 1
fi

PROJECT="$1"
shift

MODE="solo"
SKIP_PROJECT_CHECK="0"
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="${2:-solo}"; shift 2 ;;
    --skip-project-check) SKIP_PROJECT_CHECK="1"; shift ;;
    *)      shift ;;
  esac
done

# ── 유틸리티 ──

info()  { echo "[preflight] $*"; }
fail()  { echo "[preflight] ERROR: $*" >&2; exit 1; }
warn()  { echo "[preflight] WARNING: $*" >&2; }

detect_pkg_manager() {
  if [[ "$OSTYPE" == darwin* ]]; then
    echo "brew"
  elif command -v apt-get &>/dev/null; then
    echo "apt"
  else
    echo "unknown"
  fi
}

install_pkg() {
  local pkg="$1"
  local mgr
  mgr="$(detect_pkg_manager)"

  case "$mgr" in
    brew)
      info "${pkg} 설치 중 (brew install)..."
      brew install "$pkg"
      ;;
    apt)
      info "${pkg} 설치 중 (apt install)..."
      sudo apt-get update -qq && sudo apt-get install -y -qq "$pkg"
      ;;
    *)
      return 1
      ;;
  esac
}

# ── 1. 패키지 검증 (최초만) ──

ensure_packages() {
  if [ -f "$MARKER" ]; then
    info "패키지 검사 건너뜀 (.preflight-ok 존재)"
    return 0
  fi

  info "패키지 검증 시작..."
  local failed=false

  # tmux
  if ! command -v tmux &>/dev/null; then
    install_pkg tmux || { warn "tmux 자동 설치 실패. 수동 설치 필요."; failed=true; }
  fi

  # jq
  if ! command -v jq &>/dev/null; then
    install_pkg jq || { warn "jq 자동 설치 실패. 수동 설치 필요."; failed=true; }
  fi

  # python3
  if ! command -v python3 &>/dev/null; then
    warn "python3이 설치되어 있지 않다."
    warn "  macOS: brew install python3"
    warn "  Linux: sudo apt install python3"
    failed=true
  fi

  # pgrep
  if ! command -v pgrep &>/dev/null; then
    if [[ "$OSTYPE" == darwin* ]]; then
      warn "pgrep이 없다 (macOS에서는 기본 포함이어야 함). 시스템 확인 필요."
      failed=true
    else
      install_pkg procps || { warn "pgrep(procps) 자동 설치 실패. 수동 설치 필요."; failed=true; }
    fi
  fi

  if [ "$failed" = true ]; then
    fail "일부 패키지 설치에 실패했다. 위 안내를 참고하여 수동 설치 후 재시도."
  fi

  # 마커 생성
  date -u '+%Y-%m-%dT%H:%M:%SZ' > "$MARKER"
  info "패키지 검증 통과. 마커 생성됨."
}

# ── 2. Claude CLI 인증 검증 (매번) ──

check_claude_auth() {
  if ! command -v claude &>/dev/null; then
    fail "claude CLI가 설치되어 있지 않다. https://docs.anthropic.com 참고."
  fi

  info "Claude CLI 인증 상태 확인 중..."

  local auth_json logged_in auth_method
  auth_json="$(env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT claude auth status 2>/dev/null || true)"
  logged_in="$(printf '%s' "$auth_json" | jq -r '.loggedIn // false' 2>/dev/null || printf 'false')"
  auth_method="$(printf '%s' "$auth_json" | jq -r '.authMethod // "unknown"' 2>/dev/null || printf 'unknown')"

  if [ "$logged_in" != "true" ]; then
    fail "Claude CLI가 로그인되지 않았다. 'claude auth login' 또는 '/login' 후 재시도해라. (authMethod: ${auth_method})"
  fi

  info "Claude CLI 인증 확인 완료."
}

# ── 3. Codex CLI 검증 (dual 모드 또는 codex control-plane, 매번) ──

get_manager_backend() {
  local backend="${WHIPLASH_MANAGER_BACKEND:-}"

  if [ -n "$backend" ]; then
    case "$backend" in
      claude|codex)
        echo "$backend"
        return
        ;;
    esac
  fi

  local project_md="$REPO_ROOT/projects/$PROJECT/project.md"
  local parsed
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

  echo "claude"
}

check_codex() {
  local requires_codex=0
  if [ "$MODE" = "dual" ] || [ "$(get_manager_backend)" = "codex" ]; then
    requires_codex=1
  fi

  if [ "$requires_codex" -ne 1 ]; then
    return 0
  fi

  if [ "$MODE" = "dual" ]; then
    info "Codex CLI 확인 중 (dual 모드)..."
  else
    info "Codex CLI 확인 중 (codex control-plane 기본 backend)..."
  fi

  # 바이너리 존재 확인 (alias가 아닌 실제 실행파일)
  local codex_bin
  codex_bin=$(command -p which codex 2>/dev/null) || codex_bin=$(type -P codex 2>/dev/null) || codex_bin=""

  if [ -z "$codex_bin" ]; then
    if [ "$MODE" = "dual" ]; then
      fail "dual 모드이지만 codex CLI가 설치되어 있지 않다. codex CLI를 설치하거나 solo 모드로 전환해라."
    fi
    fail "manager/discussion/onboarding 기본 backend가 codex라 codex CLI가 필요하다. codex CLI를 설치하거나 WHIPLASH_MANAGER_BACKEND=claude 로 실행해라."
  fi

  # --dangerously-bypass-approvals-and-sandbox 플래그 지원 확인
  if ! "$codex_bin" --help 2>&1 | grep -q "dangerously-bypass"; then
    warn "codex CLI가 --dangerously-bypass-approvals-and-sandbox를 지원하지 않는다. 업데이트 필요: brew upgrade --cask codex"
    fail "codex CLI 버전이 너무 낮다."
  fi

  info "Codex CLI 확인 완료. ($codex_bin)"
}

check_native_subagents() {
  info "repo-local native subagent pack 확인 중..."

  local requires_codex_pack=0
  if [ "$MODE" = "dual" ] || [ "$(get_manager_backend)" = "codex" ]; then
    requires_codex_pack=1
  fi

  local required_agents=(
    task-distributor
    consensus-reviewer
    report-synthesizer
    code-mapper
    docs-researcher
    reviewer
    debugger
    search-specialist
    runtime-auditor
    architect-reviewer
    refactoring-specialist
    test-automator
    security-auditor
    performance-engineer
    deployment-engineer
  )
  local role_profiles=(
    manager
    discussion
    developer
    researcher
    systems-engineer
  )
  local agent_name
  for agent_name in "${required_agents[@]}"; do
    [ -f "$REPO_ROOT/.claude/agents/${agent_name}.md" ] || fail "Claude subagent pack 누락: .claude/agents/${agent_name}.md"
    if [ "$requires_codex_pack" -eq 1 ]; then
      [ -f "$REPO_ROOT/.codex/agents/${agent_name}.toml" ] || fail "Codex subagent pack 누락: .codex/agents/${agent_name}.toml"
    fi
  done

  if [ "$requires_codex_pack" -eq 1 ]; then
    [ -f "$REPO_ROOT/.codex/config.toml" ] || fail "Codex project config 누락: .codex/config.toml"
    grep -q '^model = "gpt-5.4"$' "$REPO_ROOT/.codex/config.toml" || fail ".codex/config.toml 에 top-level model = \"gpt-5.4\" 설정이 없다."
    grep -q '^\[agents\]' "$REPO_ROOT/.codex/config.toml" || fail ".codex/config.toml 에 [agents] 섹션이 없다."
    grep -q '^max_threads = ' "$REPO_ROOT/.codex/config.toml" || fail ".codex/config.toml 에 max_threads 설정이 없다."
    grep -q '^max_depth = ' "$REPO_ROOT/.codex/config.toml" || fail ".codex/config.toml 에 max_depth 설정이 없다."
  fi

  local role profile
  for role in "${role_profiles[@]}"; do
    profile="$REPO_ROOT/agents/${role}/profile.md"
    [ -f "$profile" ] || fail "role profile 누락: $profile"
    grep -q '^allowed-tools: .*Agent' "$profile" || fail "${role} profile 에 Agent tool 허용이 없다."
  done

  info "repo-local native subagent pack 확인 완료."
}

# ── 4. 프로젝트 구조 검증 (매번) ──

check_project() {
  info "프로젝트 구조 확인 중..."

  local project_dir="$REPO_ROOT/projects/$PROJECT"
  local project_md="$project_dir/project.md"

  # project.md 존재
  if [ ! -f "$project_md" ]; then
    fail "project.md가 없다: $project_md"
  fi

  # 활성 에이전트 파싱 + profile.md 존재 확인
  local agents
  agents=$(grep -i "활성 에이전트" "$project_md" \
    | sed 's/.*: *//' \
    | tr ',' '\n' \
    | sed 's/^ *//;s/ *$//' \
    | tr '[:upper:]' '[:lower:]' \
    | grep -v '^$') || true

  if [ -z "$agents" ]; then
    fail "project.md에서 활성 에이전트를 찾을 수 없다."
  fi

  local missing=false
  for role in $agents; do
    local profile="$REPO_ROOT/agents/${role}/profile.md"
    if [ ! -f "$profile" ]; then
      warn "에이전트 profile 없음: $profile"
      missing=true
    fi
  done

  if [ "$missing" = true ]; then
    fail "일부 에이전트의 profile.md가 존재하지 않는다."
  fi

  info "프로젝트 구조 확인 완료. (에이전트: $(echo $agents | tr '\n' ', '))"
}

# ── 메인 ──

info "=== Preflight 검증 시작 (project: $PROJECT, mode: $MODE) ==="

ensure_packages
check_claude_auth
check_codex
check_native_subagents
if [ "$SKIP_PROJECT_CHECK" = "1" ]; then
  info "프로젝트 구조 검사는 건너뜀 (--skip-project-check)"
else
  check_project
fi

info "=== Preflight 검증 통과 ==="
