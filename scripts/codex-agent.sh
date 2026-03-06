#!/bin/bash
# codex-agent.sh -- codex exec 기반 지속 에이전트 래퍼
#
# 대화형 TUI 대신 codex exec (비대화형)을 사용한다.
# tmux + Kitty Keyboard Protocol 비호환 문제를 근본적으로 해결.
#
# 동작:
#   1. 부팅: codex exec로 온보딩 메시지 실행
#   2. 태스크 대기: inbox 디렉토리를 폴링하며 신규 태스크 파일 감시
#   3. 태스크 실행: codex exec resume로 이전 세션 이어서 실행
#   4. 알림 수신: notify 파일도 같이 처리
#
# Usage:
#   codex-agent.sh {project} {role} {window_name} {boot_file}

set -uo pipefail
# 주의: set -e 사용 안 함 — 폴링 루프에서 ls 글로브 실패가 스크립트를 죽임

if [ $# -lt 4 ]; then
  echo "Usage: codex-agent.sh {project} {role} {window_name} {boot_file}" >&2
  exit 1
fi

PROJECT="$1"
ROLE="$2"
WINDOW_NAME="$3"
BOOT_FILE="$4"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INBOX_DIR="$REPO_ROOT/projects/$PROJECT/memory/${ROLE}/codex-inbox"
SESSION_FILE="$REPO_ROOT/projects/$PROJECT/memory/${ROLE}/codex-session-id"
POLL_INTERVAL=5

CODEX_MODEL="${WHIPLASH_CODEX_MODEL:-}"
CODEX_REASONING_EFFORT="${WHIPLASH_CODEX_REASONING_EFFORT:-}"
CODEX_SERVICE_TIER="${WHIPLASH_CODEX_SERVICE_TIER:-}"

mkdir -p "$INBOX_DIR"

# ──────────────────────────────────────────────
# codex exec 실행 헬퍼
# ──────────────────────────────────────────────
run_codex() {
  local prompt="$1"
  local session_id=""
  local -a codex_args
  codex_args=(--dangerously-bypass-approvals-and-sandbox --json)

  if [ -n "$CODEX_MODEL" ]; then
    codex_args+=(--model "$CODEX_MODEL")
  fi
  if [ -n "$CODEX_REASONING_EFFORT" ]; then
    codex_args+=(-c "model_reasoning_effort=\"$CODEX_REASONING_EFFORT\"")
  fi
  if [ -n "$CODEX_SERVICE_TIER" ]; then
    codex_args+=(-c "service_tier=\"$CODEX_SERVICE_TIER\"")
  fi

  # 기존 세션이 있으면 resume
  if [ -f "$SESSION_FILE" ]; then
    session_id=$(cat "$SESSION_FILE")
  fi

  local result
  if [ -n "$session_id" ]; then
    echo "[codex-agent] resume session=$session_id"
    result=$(command codex exec resume "$session_id" \
      "${codex_args[@]}" \
      "$prompt" 2>&1) || true
  else
    echo "[codex-agent] new session"
    result=$(command codex exec \
      "${codex_args[@]}" \
      "$prompt" 2>&1) || true
  fi

  # thread_id 추출 및 저장 (codex exec JSON 출력에서)
  local new_id
  new_id=$(echo "$result" | grep -o '"thread_id":"[^"]*"' | head -1 | sed 's/.*"thread_id":"\([^"]*\)".*/\1/') || true
  if [ -n "$new_id" ] && [ "$new_id" != "null" ]; then
    echo "$new_id" > "$SESSION_FILE"
    echo "[codex-agent] thread_id=$new_id"
  fi

  # 결과 출력 (tmux pane에 보임)
  echo "$result" | head -100
  echo ""
}

# ──────────────────────────────────────────────
# 1. 부팅 (온보딩)
# ──────────────────────────────────────────────
echo "╔══════════════════════════════════════════╗"
echo "║  ${WINDOW_NAME} (codex exec mode)        "
echo "║  project: ${PROJECT}                      "
echo "╚══════════════════════════════════════════╝"
echo ""

boot_prompt="${BOOT_FILE} 파일을 읽고 그 안의 온보딩 절차를 따라라."
echo "[codex-agent] 온보딩 시작..."
run_codex "$boot_prompt"
echo "[codex-agent] 온보딩 완료"

# ──────────────────────────────────────────────
# 2. 태스크 폴링 루프
# ──────────────────────────────────────────────
echo "[codex-agent] 태스크 대기 중... (inbox: $INBOX_DIR)"

while true; do
  # inbox에서 가장 오래된 파일 처리
  task_file=$(ls -1t "$INBOX_DIR"/*.task 2>/dev/null | tail -1)

  if [ -n "$task_file" ] && [ -f "$task_file" ]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "[codex-agent] 태스크 수신: $(basename "$task_file")"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    task_prompt=$(cat "$task_file")
    rm -f "$task_file"

    run_codex "$task_prompt"

    echo "[codex-agent] 태스크 처리 완료"
  fi

  # notify 파일도 처리
  notify_file=$(ls -1t "$INBOX_DIR"/*.notify 2>/dev/null | tail -1)
  if [ -n "$notify_file" ] && [ -f "$notify_file" ]; then
    echo ""
    echo "[codex-agent] 알림 수신: $(basename "$notify_file")"
    notify_prompt=$(cat "$notify_file")
    rm -f "$notify_file"
    run_codex "$notify_prompt"
  fi

  sleep "$POLL_INTERVAL"
done
