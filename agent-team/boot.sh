#!/usr/bin/env bash
# agent-team/boot.sh — Agent Team 모드 진입점
# Usage: bash agent-team/boot.sh [project-name]
#   인자 없이: 새 프로젝트 (온보딩 시작)
#   인자 있으면: 기존 프로젝트 재개 (대시보드 자동 시작)
set -euo pipefail

export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ -n "${1:-}" ]]; then
  PROJECT="$1"
  PROJECT_DIR="$REPO_ROOT/projects/$PROJECT"
  if [[ ! -d "$PROJECT_DIR" ]]; then
    echo "Error: 프로젝트 '$PROJECT'가 없습니다 (projects/$PROJECT/)" >&2
    exit 1
  fi
  # 대시보드 서버 시작 (코드 보장)
  python3 "$REPO_ROOT/dashboard/server.py" --project "$PROJECT" &
  DASH_PID=$!
  mkdir -p "$PROJECT_DIR/memory/manager"
  echo "$DASH_PID" > "$PROJECT_DIR/memory/manager/dashboard.pid"
  echo "Dashboard started (PID: $DASH_PID) — http://localhost:8420"
fi

exec claude
