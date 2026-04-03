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
#   execution-config {project} [--scope current|baseline] {preset|role override} -- 실행 backend/model 설정

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOLS_DIR="$SCRIPT_DIR"
TASK_EXEC_PATTERN=""
TASK_EXEC_MANAGER_STUB=""
TASK_EXEC_TARGETS=()
TASK_EXEC_ROLES=()

# ──────────────────────────────────────────────
# 외부 의존 source (순서 중요)
# ──────────────────────────────────────────────

# shellcheck source=/dev/null
source "$TOOLS_DIR/tmux-submit.sh"
# shellcheck source=/dev/null
source "$TOOLS_DIR/runtime-paths.sh"
# shellcheck source=/dev/null
source "$TOOLS_DIR/agent-health.sh"
# shellcheck source=/dev/null
source "$TOOLS_DIR/assignment-state.sh"
# shellcheck source=/dev/null
source "$TOOLS_DIR/execution-config.sh"

# ──────────────────────────────────────────────
# 모듈 source (순서 중요: utils → boot → dispatch → lifecycle)
# ──────────────────────────────────────────────

# shellcheck source=/dev/null
source "$TOOLS_DIR/cmd-utils.sh"
# shellcheck source=/dev/null
source "$TOOLS_DIR/cmd-boot.sh"
# shellcheck source=/dev/null
source "$TOOLS_DIR/cmd-dispatch.sh"
# shellcheck source=/dev/null
source "$TOOLS_DIR/cmd-lifecycle.sh"

# ──────────────────────────────────────────────
# 메인 (WHIPLASH_SOURCE_ONLY=1 이면 source만 하고 종료)
# ──────────────────────────────────────────────

if [ "${WHIPLASH_SOURCE_ONLY:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

if [ $# -lt 2 ]; then
  echo "Usage:" >&2
  echo "  cmd.sh boot-onboarding {project}" >&2
  echo "  cmd.sh boot-manager   {project}" >&2
  echo "  cmd.sh boot           {project}" >&2
  echo "  cmd.sh dispatch       {role} {task-file} {project} [pattern]" >&2
  echo "  cmd.sh dual-dispatch  {role} {task-file} {project}" >&2
  echo "  cmd.sh spawn          {role} {window-name} {project} [extra-msg]" >&2
  echo "  cmd.sh kill-agent     {window-name} {project}" >&2
  echo "  cmd.sh shutdown       {project}" >&2
  echo "  cmd.sh status         {project}" >&2
  echo "  cmd.sh reboot         {target} {project}" >&2
  echo "  cmd.sh refresh        {target} {project}" >&2
  echo "  cmd.sh merge-worktree {role} {winner} {project}" >&2
  echo "  cmd.sh monitor-check  {project}" >&2
  echo "  cmd.sh execution-config {project} [--scope current|baseline] {default|claude only|codex only|dual|<role> ...}" >&2
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
  execution-config)
    [ $# -lt 2 ] && { echo "Usage: cmd.sh execution-config {project} [--scope current|baseline] {default|claude only|codex only|dual|<role> ...}" >&2; exit 1; }
    activate_project_tmux_context "$1"
    project_name="$1"
    shift
    cmd_execution_config "$project_name" "$@"
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
    echo "Available: boot-onboarding, boot-manager, boot, dispatch, dual-dispatch, assign, spawn, kill-agent, shutdown, status, reboot, refresh, merge-worktree, monitor-check, execution-config, complete, expire-stale" >&2
    exit 1
    ;;
esac
