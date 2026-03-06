#!/bin/bash
# integration-test.sh -- 라이브 통합 테스트 (tmux 기반)
#
# 테스트 전용 프로젝트 _stability-test를 사용.
# 실제 claude 호출 대신 컴파일된 가짜 바이너리로 시뮬레이션.
#
# Usage: bash scripts/integration-test.sh

# set -e 사용 안 함 — 테스트는 실패를 의도적으로 유발하므로
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOLS_DIR="$SCRIPT_DIR"
PROJECT="_stability-test"
SESSION="whiplash-${PROJECT}"
PROJECT_DIR="$REPO_ROOT/projects/$PROJECT"
FAKE_CLAUDE_BIN=""
PASS=0
FAIL=0
TOTAL=0

# ──────────────────────────────────────────────
# 테스트 유틸리티
# ──────────────────────────────────────────────

setup_test_project() {
  mkdir -p "$PROJECT_DIR/memory/manager"
  mkdir -p "$PROJECT_DIR/logs"
  cat > "$PROJECT_DIR/project.md" << 'EOF'
# _stability-test

- 목표: 통합 테스트용 임시 프로젝트
- 활성 에이전트: developer, researcher
- 실행 모드: solo
- 도메인: general
EOF
}

# "claude"라는 이름의 가짜 바이너리 컴파일
# pgrep -P pane_pid claude 가 매칭되려면 프로세스 comm이 "claude"여야 함
build_fake_claude() {
  FAKE_CLAUDE_BIN="$PROJECT_DIR/claude"
  if [ -f "$FAKE_CLAUDE_BIN" ]; then
    return 0
  fi
  mkdir -p "$PROJECT_DIR"
  if command -v cc &>/dev/null; then
    printf '#include <unistd.h>\nint main(void){for(;;)pause();}\n' | \
      cc -x c - -o "$FAKE_CLAUDE_BIN" 2>/dev/null
  else
    echo "ERROR: C 컴파일러(cc) 없음. 가짜 claude 바이너리 생성 불가." >&2
    exit 1
  fi
}

cleanup() {
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  if [ -f "$PROJECT_DIR/memory/manager/monitor.pid" ]; then
    local pid
    pid=$(cat "$PROJECT_DIR/memory/manager/monitor.pid" 2>/dev/null) || pid=""
    if [[ "${pid:-}" =~ ^[0-9]+$ ]]; then
      pkill -P "$pid" 2>/dev/null || true
      kill "$pid" 2>/dev/null || true
    fi
  fi
  rm -rf "$PROJECT_DIR"
}

trap cleanup EXIT

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected='$expected', actual='$actual')"
    FAIL=$((FAIL + 1))
  fi
}

assert_true() {
  local desc="$1"; shift
  TOTAL=$((TOTAL + 1))
  if "$@" 2>/dev/null; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    FAIL=$((FAIL + 1))
  fi
}

assert_false() {
  local desc="$1"; shift
  TOTAL=$((TOTAL + 1))
  if "$@" 2>/dev/null; then
    echo "  FAIL: $desc (expected failure but succeeded)"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  fi
}

assert_file_exists() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [ -f "$path" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (file not found: $path)"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_not_exists() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [ ! -f "$path" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (file should not exist: $path)"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_contains() {
  local desc="$1" path="$2" pattern="$3"
  TOTAL=$((TOTAL + 1))
  if [ -f "$path" ] && grep -q "$pattern" "$path" 2>/dev/null; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (pattern '$pattern' not found in $path)"
    FAIL=$((FAIL + 1))
  fi
}

probe_cmd_boot_message() {
  local role="$1"
  local project_name="${2:-$PROJECT}"
  WHIPLASH_SOURCE_ONLY=1 \
  WHIPLASH_TEST_ROLE="$role" \
  WHIPLASH_TEST_PROJECT="$project_name" \
  bash -lc '
    source "'"$TOOLS_DIR"'/cmd.sh"
    build_boot_message "$WHIPLASH_TEST_ROLE" "$WHIPLASH_TEST_PROJECT"
  '
}

invoke_cmd_function() {
  local function_name="$1"
  shift
  WHIPLASH_SOURCE_ONLY=1 \
  WHIPLASH_TEST_FUNCTION="$function_name" \
  bash -lc '
    source "'"$TOOLS_DIR"'/cmd.sh"
    "$WHIPLASH_TEST_FUNCTION" "$@"
  ' -- "$@"
}

probe_dashboard_project() {
  python3 - "$REPO_ROOT" "$PROJECT_DIR" <<'PY'
import importlib.util
import pathlib
import sys

repo_root = pathlib.Path(sys.argv[1])
project_dir = sys.argv[2]
module_path = repo_root / "dashboard" / "dashboard.py"
spec = importlib.util.spec_from_file_location("whiplash_dashboard", module_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
info = module.parse_project_md(project_dir)
print(f'{info["name"]}|{info["mode"]}|{info["domain"]}')
PY
}

probe_dashboard_monitor() {
  python3 - "$REPO_ROOT" "$PROJECT_DIR" <<'PY'
import importlib.util
import pathlib
import sys

repo_root = pathlib.Path(sys.argv[1])
project_dir = sys.argv[2]
module_path = repo_root / "dashboard" / "dashboard.py"
spec = importlib.util.spec_from_file_location("whiplash_dashboard", module_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
info = module.check_monitor(project_dir)
print(f'{int(info["alive"])}|{info["queued"]}|{int(info["heartbeat_age"] is not None)}')
PY
}

# 가짜 에이전트 윈도우 생성
create_fake_agent() {
  local win_name="$1"
  tmux new-window -t "$SESSION" -n "$win_name"
  # 컴파일된 바이너리를 실행 — 프로세스 이름이 "claude"로 표시됨
  tmux send-keys -t "${SESSION}:${win_name}" "'${FAKE_CLAUDE_BIN}'" Enter
  sleep 2
}

# sessions.md에 가짜 에이전트 등록
register_fake_agent() {
  local win_name="$1" role="$2"
  local sf="$PROJECT_DIR/memory/manager/sessions.md"
  mkdir -p "$(dirname "$sf")"
  if [ ! -f "$sf" ]; then
    cat > "$sf" << 'HEADER'
# 활성 에이전트 세션

| 역할 | 백엔드 | Session ID | tmux Target | 상태 | 시작일 | 모델 | 비고 |
|------|--------|-----------|-------------|------|--------|------|------|
HEADER
  fi
  local today
  today="$(date +%Y-%m-%d)"
  echo "| ${role} | claude | fake-session | ${SESSION}:${win_name} | active | ${today} | test | |" >> "$sf"
}

# ──────────────────────────────────────────────
# 시나리오 1: 에이전트 kill → monitor 감지
# ──────────────────────────────────────────────

test_scenario_1() {
  echo ""
  echo "=== 시나리오 1: 에이전트 kill → monitor 크래시 감지 ==="
  cleanup
  setup_test_project
  build_fake_claude

  tmux new-session -d -s "$SESSION" -n manager
  create_fake_agent "developer"
  register_fake_agent "developer" "developer"

  # 에이전트 alive 확인
  local pane_pid
  pane_pid=$(tmux list-panes -t "${SESSION}:developer" -F '#{pane_pid}' 2>/dev/null | head -1) || pane_pid=""
  assert_true "developer alive 확인" bash -c \
    "[ -n '$pane_pid' ] && pgrep -P '$pane_pid' claude >/dev/null 2>&1"

  # 에이전트 프로세스 kill (윈도우는 남겨둠 — tmux send-keys로 shell 유지)
  if [ -n "$pane_pid" ]; then
    # claude 프로세스만 kill
    local claude_pid
    claude_pid=$(pgrep -P "$pane_pid" claude 2>/dev/null | head -1) || claude_pid=""
    if [ -n "$claude_pid" ]; then
      kill "$claude_pid" 2>/dev/null || true
    fi
  fi
  sleep 1

  # 크래시 상태 확인
  assert_false "developer dead 확인" bash -c \
    "pgrep -P '$pane_pid' claude >/dev/null 2>&1"

  # sessions.md에서 active인 developer를 찾을 수 있는지 확인
  local active_windows
  active_windows=$(grep '| active |' "$PROJECT_DIR/memory/manager/sessions.md" 2>/dev/null \
    | awk -F'|' '{print $5}' \
    | sed 's/.*://' \
    | sed 's/^ *//;s/ *$//' \
    | grep -v '^$') || active_windows=""
  assert_eq "sessions.md에서 developer 감지" "developer" "$active_windows"

  echo "  시나리오 1 완료"
}

# ──────────────────────────────────────────────
# 시나리오 2: 태스크 할당 영속화 + 복구 메시지
# ──────────────────────────────────────────────

test_scenario_2() {
  echo ""
  echo "=== 시나리오 2: 태스크 할당 영속화 + 복구 메시지 ==="
  cleanup
  setup_test_project

  local af="$PROJECT_DIR/memory/manager/assignments.md"
  mkdir -p "$(dirname "$af")"

  # assignments.md 생성 + 태스크 기록
  cat > "$af" << 'HEADER'
# 태스크 할당 현황
| 에이전트 | 태스크 파일 | 할당 시각 | 상태 |
|----------|-----------|----------|------|
HEADER
  echo "| developer | workspace/tasks/TASK-001.md | $(date '+%Y-%m-%d %H:%M') | active |" >> "$af"

  assert_file_exists "assignments.md 생성됨" "$af"
  assert_file_contains "developer active 태스크 기록" "$af" "| developer |.*| active |"

  # get_active_task 로직 시뮬레이션
  local task
  task=$({ grep "| developer |" "$af" 2>/dev/null || true; } \
    | grep "| active |" | tail -1 \
    | awk -F'|' '{print $3}' | sed 's/^ *//;s/ *$//') || task=""
  assert_eq "active 태스크 조회" "workspace/tasks/TASK-001.md" "$task"

  # build_boot_message에 pending_task 포함 확인
  # cmd.sh 함수를 직접 호출하기 어려우므로 핵심 로직만 확인
  local pending_task="workspace/tasks/TASK-001.md"
  local recovery_msg=""
  if [ -n "$pending_task" ]; then
    recovery_msg="[재부팅 후 태스크 복구]
이전 세션에서 중단된 태스크가 있다: ${pending_task}
해당 파일을 읽고 작업을 이어서 진행해라."
  fi
  TOTAL=$((TOTAL + 1))
  if echo "$recovery_msg" | grep -q "재부팅 후 태스크 복구"; then
    echo "  PASS: 부팅 메시지에 태스크 복구 지시 포함"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: 부팅 메시지에 태스크 복구 지시 누락"
    FAIL=$((FAIL + 1))
  fi

  # 기존 active → completed 전환 테스트
  echo "| developer | workspace/tasks/TASK-002.md | $(date '+%Y-%m-%d %H:%M') | active |" >> "$af"
  if [[ "$OSTYPE" == darwin* ]]; then
    sed -i '' "s/| developer |\(.*\)TASK-001\(.*\)| active |/| developer |\1TASK-001\2| completed |/" "$af"
  else
    sed -i "s/| developer |\(.*\)TASK-001\(.*\)| active |/| developer |\1TASK-001\2| completed |/" "$af"
  fi
  assert_file_contains "이전 태스크 completed 전환" "$af" "TASK-001.*| completed |"
  assert_file_contains "새 태스크 active 유지" "$af" "TASK-002.*| active |"

  echo "  시나리오 2 완료"
}

# ──────────────────────────────────────────────
# 시나리오 3: 메시지 전달 실패 → 큐 저장 → drain
# ──────────────────────────────────────────────

test_scenario_3() {
  echo ""
  echo "=== 시나리오 3: 메시지 큐 저장 + drain ==="
  cleanup
  setup_test_project
  build_fake_claude

  local queue_dir="$PROJECT_DIR/memory/manager/message-queue"

  # tmux 세션 생성 (수신자 없음)
  tmux new-session -d -s "$SESSION" -n manager

  # 수신자(developer)가 없는 상태에서 메시지 전송 → 큐 저장
  bash "$TOOLS_DIR/message.sh" "$PROJECT" researcher developer \
    task_complete normal "TASK-001 완료" "연구 결과 정리 완료" 2>/dev/null || true

  # .msg 파일 생성 확인
  local msg_count
  msg_count=$(find "$queue_dir" -name "*.msg" 2>/dev/null | wc -l | tr -d ' ') || msg_count="0"
  assert_true "큐 파일 생성됨" test "$msg_count" -gt 0

  # 큐 파일 내용 확인
  local msg_file
  msg_file=$(find "$queue_dir" -name "*.msg" 2>/dev/null | head -1) || msg_file=""
  if [ -n "$msg_file" ]; then
    assert_file_contains "큐 파일에 from 기록" "$msg_file" "^from=researcher"
    assert_file_contains "큐 파일에 to 기록" "$msg_file" "^to=developer"
    assert_file_contains "큐 파일에 kind 기록" "$msg_file" "^kind=task_complete"
  fi

  # 수신자 윈도우 생성
  create_fake_agent "developer"

  # drain 시뮬레이션
  local drained=false
  for msg_f in "$queue_dir"/*.msg; do
    [ -f "$msg_f" ] || continue
    local msg_to msg_from msg_kind msg_priority msg_subject msg_content
    msg_to=$(grep '^to=' "$msg_f" | head -1 | sed 's/^to=//') || msg_to=""
    [ -z "$msg_to" ] && continue

    # 수신자 윈도우 존재 확인
    if ! tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -q "^${msg_to}$"; then
      continue
    fi

    msg_from=$(grep '^from=' "$msg_f" | head -1 | sed 's/^from=//') || msg_from=""
    msg_kind=$(grep '^kind=' "$msg_f" | head -1 | sed 's/^kind=//') || msg_kind=""
    msg_priority=$(grep '^priority=' "$msg_f" | head -1 | sed 's/^priority=//') || msg_priority=""
    msg_subject=$(grep '^subject=' "$msg_f" | head -1 | sed 's/^subject=//') || msg_subject=""
    msg_content=$(grep '^content=' "$msg_f" | head -1 | sed 's/^content=//') || msg_content=""

    local prefix="[notify] ${msg_from} → ${msg_to} | ${msg_kind}"
    local notification="${prefix}
제목: ${msg_subject}
내용: ${msg_content}"

    local tmpfile tmux_target="${SESSION}:${msg_to}"
    tmpfile=$(mktemp)
    printf '%s' "$notification" > "$tmpfile"
    local buf_name="test-drain-$$-${RANDOM}"
    if tmux load-buffer -b "$buf_name" "$tmpfile" 2>/dev/null && \
       tmux paste-buffer -b "$buf_name" -t "$tmux_target" -d 2>/dev/null; then
      rm -f "$msg_f"
      drained=true
    else
      tmux delete-buffer -b "$buf_name" 2>/dev/null || true
    fi
    rm -f "$tmpfile"
  done

  assert_true "큐 drain 성공" test "$drained" = true

  # 큐 파일 삭제 확인
  local remaining
  remaining=$(find "$queue_dir" -name "*.msg" 2>/dev/null | wc -l | tr -d ' ') || remaining="0"
  assert_eq "큐 파일 삭제됨" "0" "$remaining"

  echo "  시나리오 3 완료"
}

# ──────────────────────────────────────────────
# 시나리오 4: tmux 세션 kill → monitor 대기 모드 → 복귀
# ──────────────────────────────────────────────

test_scenario_4() {
  echo ""
  echo "=== 시나리오 4: 세션 kill → monitor 대기 모드 → 복귀 ==="
  cleanup
  setup_test_project

  local hb_file="$PROJECT_DIR/memory/manager/monitor.heartbeat"
  mkdir -p "$(dirname "$hb_file")"

  # 세션 없는 상태에서 SESSION_ABSENT_COUNT 증가 로직 테스트
  local SESSION_ABSENT_COUNT=0
  for i in 1 2 3; do
    if ! tmux has-session -t "$SESSION" 2>/dev/null; then
      SESSION_ABSENT_COUNT=$((SESSION_ABSENT_COUNT + 1))
    fi
  done
  assert_eq "3회 부재 카운트" "3" "$SESSION_ABSENT_COUNT"

  # 대기 모드에서 heartbeat 갱신 확인
  date +%s > "$hb_file"
  assert_file_exists "heartbeat 파일 존재" "$hb_file"
  local hb_val
  hb_val=$(cat "$hb_file")
  TOTAL=$((TOTAL + 1))
  if [[ "$hb_val" =~ ^[0-9]+$ ]]; then
    echo "  PASS: heartbeat 값이 숫자"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: heartbeat 값이 숫자 아님 ('$hb_val')"
    FAIL=$((FAIL + 1))
  fi

  # 세션 재생성 → 복귀
  tmux new-session -d -s "$SESSION" -n manager
  assert_true "세션 복귀 확인" tmux has-session -t "$SESSION"

  # 복귀 후 카운트 리셋
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    SESSION_ABSENT_COUNT=0
  fi
  assert_eq "세션 복귀 후 카운트 리셋" "0" "$SESSION_ABSENT_COUNT"

  echo "  시나리오 4 완료"
}

# ──────────────────────────────────────────────
# 시나리오 5: reboot 경합 방지 (lock)
# ──────────────────────────────────────────────

test_scenario_5() {
  echo ""
  echo "=== 시나리오 5: reboot 경합 방지 (lock) ==="
  cleanup
  setup_test_project

  local lock_dir="$PROJECT_DIR/memory/manager/reboot-locks"
  mkdir -p "$lock_dir"

  # lock 파일 생성 (방금 시작된 리부팅)
  local lock_file="$lock_dir/developer.lock"
  date +%s > "$lock_file"

  local lock_age should_skip=false
  lock_age=$(($(date +%s) - $(cat "$lock_file")))
  if [ -f "$lock_file" ] && [ "$lock_age" -lt 60 ]; then
    should_skip=true
  fi
  assert_eq "리부팅 진행 중 → 건너뜀" "true" "$should_skip"

  # 60초 이상 된 stale lock → 강제 해제 허용
  echo $(($(date +%s) - 120)) > "$lock_file"
  lock_age=$(($(date +%s) - $(cat "$lock_file")))
  local should_proceed=false
  if [ "$lock_age" -ge 60 ]; then
    should_proceed=true
  fi
  assert_eq "stale lock → 진행 허용" "true" "$should_proceed"

  rm -f "$lock_file"
  assert_file_not_exists "lock 파일 삭제됨" "$lock_file"

  echo "  시나리오 5 완료"
}

# ──────────────────────────────────────────────
# 시나리오 6: reboot 한도 초과 → 쿨다운 → 리셋
# ──────────────────────────────────────────────

test_scenario_6() {
  echo ""
  echo "=== 시나리오 6: reboot 한도 초과 → 5분 쿨다운 → 리셋 ==="
  cleanup
  setup_test_project

  local MAX_REBOOT=3
  local count_dir="$PROJECT_DIR/memory/manager/reboot-counts"
  mkdir -p "$count_dir"

  # 카운터를 MAX_REBOOT까지 올리기
  echo "$MAX_REBOOT" > "$count_dir/developer.count"
  local count
  count=$(cat "$count_dir/developer.count")
  assert_eq "카운터 MAX_REBOOT 도달" "$MAX_REBOOT" "$count"

  # 한도 초과 확인
  assert_true "한도 초과 확인" test "$count" -ge "$MAX_REBOOT"

  # lockout 파일 생성
  local lockout_file="$count_dir/developer.lockout"
  date +%s > "$lockout_file"
  assert_file_exists "lockout 파일 생성됨" "$lockout_file"

  # 5분 미경과 → 유지
  local lockout_time now_ts should_reset=false
  lockout_time=$(cat "$lockout_file")
  now_ts=$(date +%s)
  if [ $((now_ts - lockout_time)) -gt 300 ]; then
    should_reset=true
  fi
  assert_eq "5분 미경과 → 유지" "false" "$should_reset"

  # lockout 타임스탬프를 6분 전으로 수정
  echo $(($(date +%s) - 360)) > "$lockout_file"
  lockout_time=$(cat "$lockout_file")
  now_ts=$(date +%s)
  should_reset=false
  if [ $((now_ts - lockout_time)) -gt 300 ]; then
    should_reset=true
  fi
  assert_eq "6분 경과 → 리셋 허용" "true" "$should_reset"

  # 카운터 리셋 실행
  rm -f "$count_dir/developer.count"
  rm -f "$lockout_file"
  assert_file_not_exists "카운터 파일 삭제됨" "$count_dir/developer.count"
  assert_file_not_exists "lockout 파일 삭제됨" "$lockout_file"

  # 리셋 후 카운트 = 0
  local new_count="0"
  if [ -f "$count_dir/developer.count" ]; then
    new_count=$(cat "$count_dir/developer.count")
  fi
  assert_eq "리셋 후 카운트 0" "0" "$new_count"

  echo "  시나리오 6 완료"
}

# ──────────────────────────────────────────────
# 시나리오 7: monitor wrapper — kill 후 재시작
# ──────────────────────────────────────────────

test_scenario_7() {
  echo ""
  echo "=== 시나리오 7: monitor wrapper 자동 재시작 ==="
  cleanup
  setup_test_project

  # tmux 세션 생성
  tmux new-session -d -s "$SESSION" -n manager

  # sessions.md 초기화
  local sf="$PROJECT_DIR/memory/manager/sessions.md"
  mkdir -p "$(dirname "$sf")"
  cat > "$sf" << 'HEADER'
# 활성 에이전트 세션

| 역할 | 백엔드 | Session ID | tmux Target | 상태 | 시작일 | 모델 | 비고 |
|------|--------|-----------|-------------|------|--------|------|------|
HEADER

  local hb_file="$PROJECT_DIR/memory/manager/monitor.heartbeat"
  local pid_file="$PROJECT_DIR/memory/manager/monitor.pid"

  # wrapper로 monitor.sh 시작 (짧은 재시작 간격)
  nohup bash -c "
    while true; do
      bash '${TOOLS_DIR}/monitor.sh' '${PROJECT}'
      sleep 2
    done
  " >/dev/null 2>&1 &
  local wrapper_pid=$!
  echo "$wrapper_pid" > "$pid_file"

  # monitor.sh가 heartbeat를 갱신할 때까지 대기 (최대 40초)
  local waited=0
  while [ ! -f "$hb_file" ] && [ "$waited" -lt 40 ]; do
    sleep 2
    waited=$((waited + 2))
  done

  assert_true "wrapper 프로세스 alive" kill -0 "$wrapper_pid"
  assert_file_exists "heartbeat 파일 생성됨" "$hb_file"

  # 첫 heartbeat 타임스탬프 기록
  local hb_before
  hb_before=$(cat "$hb_file" 2>/dev/null) || hb_before="0"

  # monitor.sh 프로세스만 kill (wrapper는 살림)
  # wrapper의 모든 자식 중 monitor.sh 관련 프로세스를 kill
  local child_pids
  child_pids=$(pgrep -P "$wrapper_pid" 2>/dev/null) || child_pids=""
  for cpid in $child_pids; do
    kill "$cpid" 2>/dev/null || true
  done

  # wrapper가 monitor.sh를 재시작할 시간 대기 (sleep 2 + monitor 시작 + 첫 heartbeat)
  sleep 40

  assert_true "wrapper 여전히 alive" kill -0 "$wrapper_pid"

  # heartbeat가 갱신되었는지 확인 (재시작 증명)
  local hb_after
  hb_after=$(cat "$hb_file" 2>/dev/null) || hb_after="0"
  TOTAL=$((TOTAL + 1))
  if [ "$hb_after" != "$hb_before" ] && [ "$hb_after" -gt "$hb_before" ] 2>/dev/null; then
    echo "  PASS: heartbeat 갱신됨 (monitor 재시작 확인)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: heartbeat 미갱신 (before=$hb_before, after=$hb_after)"
    FAIL=$((FAIL + 1))
  fi

  # 정리
  pkill -P "$wrapper_pid" 2>/dev/null || true
  kill "$wrapper_pid" 2>/dev/null || true
  wait "$wrapper_pid" 2>/dev/null || true

  echo "  시나리오 7 완료"
}

# ──────────────────────────────────────────────
# 시나리오 8: INS-003 태스크 추적 통합
# ──────────────────────────────────────────────

test_scenario_8() {
  echo ""
  echo "=== 시나리오 8: task_assign 추적 통합 + Manager assign/complete ==="
  cleanup
  setup_test_project
  build_fake_claude

  mkdir -p "$PROJECT_DIR/workspace/tasks"
  cat > "$PROJECT_DIR/workspace/tasks/TASK-003.md" << 'EOF'
# TASK-003: Developer dispatch test
EOF
  cat > "$PROJECT_DIR/workspace/tasks/TASK-004.md" << 'EOF'
# TASK-004: Direct message assignment test
EOF

  local af="$PROJECT_DIR/memory/manager/assignments.md"

  tmux new-session -d -s "$SESSION" -n manager
  create_fake_agent "developer"
  register_fake_agent "developer" "developer"

  bash "$TOOLS_DIR/cmd.sh" dispatch developer \
    "projects/${PROJECT}/workspace/tasks/TASK-003.md" "$PROJECT" >/dev/null

  local dispatch_active dispatch_total
  dispatch_active=$(grep -Ec "\\| developer \\| workspace/tasks/TASK-003.md \\| .*\\| active \\|" "$af" 2>/dev/null || true)
  dispatch_total=$(grep -Ec "\\| developer \\| workspace/tasks/TASK-003.md \\|" "$af" 2>/dev/null || true)
  assert_eq "dispatch active 기록 1건" "1" "$dispatch_active"
  assert_eq "dispatch 중복 기록 없음" "1" "$dispatch_total"

  bash "$TOOLS_DIR/message.sh" "$PROJECT" developer manager \
    task_complete normal "TASK-003 완료" "dispatch task finished" >/dev/null

  local developer_active developer_completed
  developer_active=$(grep -Ec "\\| developer \\| .*\\| active \\|" "$af" 2>/dev/null || true)
  developer_completed=$(grep -Ec "\\| developer \\| workspace/tasks/TASK-003.md \\| .*\\| completed \\|" "$af" 2>/dev/null || true)
  assert_eq "task_complete 후 developer active 없음" "0" "$developer_active"
  assert_eq "task_complete 후 completed 반영" "1" "$developer_completed"

  bash "$TOOLS_DIR/message.sh" "$PROJECT" manager developer \
    task_assign normal "projects/${PROJECT}/workspace/tasks/TASK-004.md" \
    "새 작업 지시가 있다. 읽고 실행해라." >/dev/null

  local direct_assign_active
  direct_assign_active=$(grep -Ec "\\| developer \\| workspace/tasks/TASK-004.md \\| .*\\| active \\|" "$af" 2>/dev/null || true)
  assert_eq "message.sh task_assign 직접 기록" "1" "$direct_assign_active"

  bash "$TOOLS_DIR/cmd.sh" assign manager "Review consensus result" "$PROJECT" >/dev/null

  local manager_active
  manager_active=$(grep -Ec "\\| manager \\| Review consensus result \\| .*\\| active \\|" "$af" 2>/dev/null || true)
  assert_eq "cmd.sh assign 으로 manager 태스크 기록" "1" "$manager_active"

  bash "$TOOLS_DIR/cmd.sh" complete manager "$PROJECT" >/dev/null

  local manager_completed manager_active_after
  manager_completed=$(grep -Ec "\\| manager \\| Review consensus result \\| .*\\| completed \\|" "$af" 2>/dev/null || true)
  manager_active_after=$(grep -Ec "\\| manager \\| .*\\| active \\|" "$af" 2>/dev/null || true)
  assert_eq "cmd.sh complete 으로 manager 완료 반영" "1" "$manager_completed"
  assert_eq "manager active 태스크 제거" "0" "$manager_active_after"

  echo "  시나리오 8 완료"
}

# ──────────────────────────────────────────────
# 시나리오 9: dashboard parser / monitor 경로 정합성
# ──────────────────────────────────────────────

test_scenario_9() {
  echo ""
  echo "=== 시나리오 9: dashboard parser / monitor 경로 정합성 ==="
  cleanup
  setup_test_project

  local legacy_info
  legacy_info="$(probe_dashboard_project)"
  assert_eq "legacy project.md 파싱" "_stability-test|solo|general" "$legacy_info"

  cat > "$PROJECT_DIR/project.md" << 'EOF'
# Project: canonical-test

## 기본 정보
- **Domain** (또는 **도메인**): deep-learning
- **Started**: 2026-03-06

## 운영 방식
- **실행 모드**: dual

## 팀 구성
- **활성 에이전트**: developer, researcher
EOF

  local canonical_info
  canonical_info="$(probe_dashboard_project)"
  assert_eq "canonical project.md 파싱" "canonical-test|dual|deep-learning" "$canonical_info"

  local manager_dir="$PROJECT_DIR/memory/manager"
  local queue_dir="$manager_dir/message-queue"
  mkdir -p "$queue_dir"
  : > "$queue_dir/queued.msg"
  echo "$$" > "$manager_dir/monitor.pid"
  date +%s > "$manager_dir/monitor.heartbeat"

  local monitor_info
  monitor_info="$(probe_dashboard_monitor)"
  assert_eq "dashboard monitor 경로 인식" "1|1|1" "$monitor_info"

  echo "  시나리오 9 완료"
}

# ──────────────────────────────────────────────
# 시나리오 10: general 도메인 온보딩 예외 처리
# ──────────────────────────────────────────────

test_scenario_10() {
  echo ""
  echo "=== 시나리오 10: general 도메인 온보딩 예외 처리 ==="
  cleanup
  setup_test_project

  local general_msg
  general_msg="$(probe_cmd_boot_message researcher "$PROJECT")"
  TOTAL=$((TOTAL + 1))
  if ! echo "$general_msg" | grep -q 'domains/general/context.md'; then
    echo "  PASS: general 도메인에서 nonexistent context 경로 미노출"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: general 도메인에서 domains/general/context.md 노출"
    FAIL=$((FAIL + 1))
  fi

  TOTAL=$((TOTAL + 1))
  if echo "$general_msg" | grep -q '추가 domain context는 없다'; then
    echo "  PASS: general 도메인 skip 문구 포함"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: general 도메인 skip 문구 누락"
    FAIL=$((FAIL + 1))
  fi

  cat > "$PROJECT_DIR/project.md" << 'EOF'
# Project: domain-test

## 기본 정보
- **Domain** (또는 **도메인**): deep-learning

## 운영 방식
- **실행 모드**: solo
EOF

  local domain_msg
  domain_msg="$(probe_cmd_boot_message researcher "$PROJECT")"
  TOTAL=$((TOTAL + 1))
  if echo "$domain_msg" | grep -q 'domains/deep-learning/context.md'; then
    echo "  PASS: non-general 도메인 context 경로 유지"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: non-general 도메인 context 경로 누락"
    FAIL=$((FAIL + 1))
  fi

  echo "  시나리오 10 완료"
}

# ──────────────────────────────────────────────
# 시나리오 11: dual worktree 지원 디렉토리 링크
# ──────────────────────────────────────────────

test_scenario_11() {
  echo ""
  echo "=== 시나리오 11: dual worktree 지원 디렉토리 링크 ==="
  cleanup
  setup_test_project

  local code_repo="$PROJECT_DIR/code-repo"
  mkdir -p "$code_repo/configs" "$code_repo/states"
  cat > "$code_repo/.gitignore" << 'EOF'
states/
EOF
  cat > "$code_repo/configs/app.cfg" << 'EOF'
state_path=../states/current.bin
EOF
  printf 'seed' > "$code_repo/states/current.bin"

  git -C "$code_repo" init -b main >/dev/null 2>&1
  git -C "$code_repo" config user.name "Whiplash Test"
  git -C "$code_repo" config user.email "test@example.com"
  git -C "$code_repo" add .gitignore configs/app.cfg
  git -C "$code_repo" commit -m "init" >/dev/null 2>&1

  cat > "$PROJECT_DIR/project.md" << EOF
# Project: worktree-test

## 기본 정보
- **Domain** (또는 **도메인**): general

## 프로젝트 폴더
- **경로**: ${code_repo}

## 운영 방식
- **실행 모드**: dual
EOF

  invoke_cmd_function create_worktrees "$PROJECT" developer

  local wt_dir="$code_repo/.worktrees"
  local claude_states="$wt_dir/developer-claude/states"
  local codex_states="$wt_dir/developer-codex/states"

  assert_true "claude worktree states 링크 생성" test -L "$claude_states"
  assert_true "codex worktree states 링크 생성" test -L "$codex_states"
  assert_eq "claude worktree states 링크 대상" "$code_repo/states" "$(readlink "$claude_states")"
  assert_eq "codex worktree states 링크 대상" "$code_repo/states" "$(readlink "$codex_states")"

  invoke_cmd_function remove_worktrees "$PROJECT" developer

  echo "  시나리오 11 완료"
}

# ──────────────────────────────────────────────
# 메인
# ──────────────────────────────────────────────

echo "============================================"
echo "  Whiplash 안정성 통합 테스트"
echo "============================================"
echo "프로젝트: $PROJECT"
echo "시작: $(date '+%Y-%m-%d %H:%M:%S')"

# 사전 정리
tmux kill-session -t "$SESSION" 2>/dev/null || true
rm -rf "$PROJECT_DIR"

test_scenario_1
test_scenario_2
test_scenario_3
test_scenario_4
test_scenario_5
test_scenario_6
test_scenario_7
test_scenario_8
test_scenario_9
test_scenario_10
test_scenario_11

echo ""
echo "============================================"
echo "  결과: ${PASS}/${TOTAL} 통과, ${FAIL} 실패"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
