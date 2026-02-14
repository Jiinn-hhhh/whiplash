#!/bin/bash
# orchestrator.sh -- tmux 기반 멀티 에이전트 오케스트레이션
#
# 서브커맨드:
#   boot     {project}                   -- tmux 세션 생성 + 에이전트 부팅 + monitor 시작
#   dispatch {role} {task-file} {project} -- 에이전트에게 태스크 전달
#   shutdown {project}                   -- 세션 종료 + 정리
#   status   {project}                   -- 세션 상태 확인
#   reboot   {role} {project}            -- 에이전트 세션 재시작
#   refresh  {role} {project}            -- 에이전트 맥락 리프레시 (handoff 후 새 세션)

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
TOOLS_DIR="$REPO_ROOT/agents/manager/tools"

# ──────────────────────────────────────────────
# 유틸리티 함수
# ──────────────────────────────────────────────

session_name() {
  echo "whiplash-$1"
}

project_dir() {
  echo "$REPO_ROOT/projects/$1"
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

# 역할별 모델 선택
get_model() {
  local role="$1"
  case "$role" in
    researcher) echo "opus" ;;
    developer)  echo "sonnet" ;;
    monitoring) echo "haiku" ;;
    *)          echo "sonnet" ;;
  esac
}

# 역할별 도메인 파일 경로 (있으면 반환)
get_domain() {
  local project="$1"
  local project_md="$(project_dir "$project")/project.md"
  grep -i "domain" "$project_md" \
    | head -1 \
    | sed 's/.*: *//' \
    | sed 's/ *(.*//' \
    | tr -d '[:space:]'
}

# project.md에서 비용 상한 추출 (없으면 빈 문자열 → 기본값 5)
get_budget() {
  local project="$1"
  local project_md="$(project_dir "$project")/project.md"
  grep -oE 'max.*budget.*[0-9]+|비용.*상한.*[0-9]+' "$project_md" 2>/dev/null \
    | grep -oE '[0-9]+(\.[0-9]+)?' | head -1
  # 매치 없으면 빈 문자열 → 호출부에서 기본값 5 사용
}

# 부팅 메시지 생성
build_boot_message() {
  local role="$1"
  local project="$2"
  local extra="${3:-}"
  local domain
  domain="$(get_domain "$project")"

  cat << BOOTMSG
너는 ${role} 에이전트다.
레포 루트: ${REPO_ROOT}
현재 프로젝트: projects/${project}/

아래 온보딩 절차를 순서대로 따라라:
1. agents/common/README.md 읽기
2. agents/common/project-context.md 읽기
3. agents/${role}/profile.md 읽기
4. projects/${project}/project.md 읽기
5. domains/${domain}/context.md 읽기
6. (해당 시) domains/${domain}/${role}.md 읽기
7. (해당 시) projects/${project}/team/${role}.md 읽기
8. memory/knowledge/index.md 읽기
9. 태스크 완료 또는 블로커 발생 시 아래 명령으로 Manager에게 알려라:
   bash agents/manager/tools/mailbox.sh ${project} ${role} manager {kind} {priority} "{subject}" "{content}"
   kind: task_complete | status_update | need_input | escalation | agent_ready
   priority: normal | urgent
   다른 에이전트에게 직접 알릴 때도 같은 방식 (to를 해당 역할로 변경).
${extra}
온보딩이 끝나면 준비 완료를 mailbox로 보고해라:
bash agents/manager/tools/mailbox.sh ${project} ${role} manager agent_ready normal "온보딩 완료" "${role} 에이전트 준비 완료"
BOOTMSG
}

# mailbox 디렉토리 생성
init_mailbox() {
  local project="$1"
  local shared_dir="$(project_dir "$project")/workspace/shared/mailbox"

  for role in manager researcher developer monitoring; do
    mkdir -p "$shared_dir/$role"/{tmp,new,cur}
  done
  echo "mailbox 디렉토리 초기화 완료"
}

# sessions.md 초기화 또는 갱신
init_sessions_file() {
  local project="$1"
  local sf
  sf="$(sessions_file "$project")"
  mkdir -p "$(dirname "$sf")"

  cat > "$sf" << 'HEADER'
# 활성 에이전트 세션

| 역할 | 백엔드 | Session ID | tmux Target | 상태 | 시작일 | 모델 | 비고 |
|------|--------|-----------|-------------|------|--------|------|------|
HEADER
}

# sessions.md에 행 추가
add_session_row() {
  local project="$1" role="$2" session_id="$3" tmux_target="$4" model="$5"
  local sf
  sf="$(sessions_file "$project")"
  local today
  today="$(date +%Y-%m-%d)"
  echo "| ${role} | claude | ${session_id} | ${tmux_target} | active | ${today} | ${model} | |" >> "$sf"
}

# sessions.md에서 특정 역할의 상태를 변경
mark_session_status() {
  local project="$1" role="$2" old_status="$3" new_status="$4"
  local sf
  sf="$(sessions_file "$project")"
  if [ -f "$sf" ]; then
    sed -i '' "s/| ${role} \(.*\)| ${old_status} |/| ${role} \1| ${new_status} |/g" "$sf"
  fi
}

# sessions.md 전체를 closed로 갱신
close_all_sessions() {
  local project="$1"
  local sf
  sf="$(sessions_file "$project")"
  if [ -f "$sf" ]; then
    sed -i '' 's/| active |/| closed |/g' "$sf"
  fi
}

# 단일 에이전트 부팅 (reboot/refresh에서 재사용)
boot_single_agent() {
  local role="$1"
  local project="$2"
  local extra_boot_msg="${3:-}"
  local sess
  sess="$(session_name "$project")"
  local model
  model="$(get_model "$role")"
  local budget
  budget="$(get_budget "$project")"
  local boot_msg
  boot_msg="$(build_boot_message "$role" "$project" "$extra_boot_msg")"
  local tmux_target="${sess}:${role}"

  echo "--- ${role} (${model}) 부팅 중 ---"

  # claude -p로 초기 세션 생성하여 session_id 획득
  local result
  result=$(claude -p "$boot_msg" \
    --model "$model" \
    --output-format json \
    --allowedTools "Read,Glob,Grep,Write,Edit,Bash,WebSearch,WebFetch" \
    --max-turns 20 \
    --max-budget-usd "${budget:-5}")

  local session_id
  session_id=$(echo "$result" | jq -r '.session_id')

  if [ -z "$session_id" ] || [ "$session_id" = "null" ]; then
    echo "Warning: ${role} session_id 획득 실패." >&2
    return 1
  fi

  # tmux 윈도우 생성 후 claude --resume으로 인터랙티브 세션 시작
  tmux new-window -t "$sess" -n "$role"
  tmux send-keys -t "$tmux_target" "claude --resume $session_id" Enter

  # sessions.md에 기록
  add_session_row "$project" "$role" "$session_id" "$tmux_target" "$model"

  echo "${role} 부팅 완료: session=${session_id}, tmux=${tmux_target}"
  return 0
}

# ──────────────────────────────────────────────
# boot 서브커맨드
# ──────────────────────────────────────────────

cmd_boot() {
  local project="$1"
  local sess
  sess="$(session_name "$project")"

  echo "=== ${project} 프로젝트 부팅 ==="

  # 이미 세션이 있으면 중단
  if tmux has-session -t "$sess" 2>/dev/null; then
    echo "Error: tmux 세션 '$sess'가 이미 존재한다. 먼저 shutdown하라." >&2
    exit 1
  fi

  # 1. mailbox 디렉토리 생성
  init_mailbox "$project"

  # 2. sessions.md 초기화
  init_sessions_file "$project"

  # 3. tmux 세션 생성 (manager 윈도우)
  tmux new-session -d -s "$sess" -n manager
  echo "tmux 세션 '$sess' 생성됨"

  # 4. 각 에이전트 부팅
  local agents
  agents="$(get_active_agents "$project")"

  for role in $agents; do
    # manager는 이미 유저가 사용 중이므로 건너뛴다
    if [ "$role" = "manager" ]; then
      continue
    fi

    boot_single_agent "$role" "$project" || {
      echo "Warning: ${role} 부팅 실패. 건너뜀." >&2
      continue
    }
  done

  # 5. monitor.sh 백그라운드 실행 (에러 로깅)
  local log_dir="$(project_dir "$project")/memory/manager/logs"
  mkdir -p "$log_dir"
  # 로그 로테이션: 최근 5개만 유지
  ls -t "$log_dir"/monitor-*.log 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true
  local log_file="$log_dir/monitor-$(date +%Y%m%d-%H%M%S).log"
  nohup bash "$TOOLS_DIR/monitor.sh" "$project" >> "$log_file" 2>&1 &
  local monitor_pid=$!
  echo "$monitor_pid" > "$(project_dir "$project")/memory/manager/monitor.pid"
  echo "monitor.sh 시작됨 (PID: $monitor_pid, log: $log_file)"

  echo "=== 부팅 완료 ==="
  echo "tmux attach -t $sess 로 세션에 접속하라."
}

# ──────────────────────────────────────────────
# dispatch 서브커맨드
# ──────────────────────────────────────────────

cmd_dispatch() {
  local role="$1"
  local task_file="$2"
  local project="$3"
  local sess
  sess="$(session_name "$project")"
  local tmux_target="${sess}:${role}"

  # tmux 윈도우 존재 확인
  if ! tmux list-windows -t "$sess" 2>/dev/null | grep -q "$role"; then
    echo "Error: ${role} 윈도우가 없다. 에이전트가 부팅되지 않았다." >&2
    exit 1
  fi

  # 태스크 지시 전송
  tmux send-keys -t "$tmux_target" \
    "${task_file} 파일에 새 작업 지시가 있다. 읽고 실행해라." Enter

  echo "dispatch 완료: ${role} ← ${task_file}"
}

# ──────────────────────────────────────────────
# reboot 서브커맨드
# ──────────────────────────────────────────────

cmd_reboot() {
  local role="$1"
  local project="$2"
  local sess
  sess="$(session_name "$project")"

  echo "=== ${role} 에이전트 리부팅 ==="

  # tmux 세션 존재 확인
  if ! tmux has-session -t "$sess" 2>/dev/null; then
    echo "Error: tmux 세션 '$sess'가 없다. boot를 먼저 실행하라." >&2
    exit 1
  fi

  # 1. 기존 윈도우 있으면 kill
  if tmux list-windows -t "$sess" -F '#{window_name}' 2>/dev/null | grep -q "^${role}$"; then
    echo "기존 ${role} 윈도우 종료 중..."
    tmux send-keys -t "${sess}:${role}" "/exit" Enter 2>/dev/null || true
    sleep 2
    tmux kill-window -t "${sess}:${role}" 2>/dev/null || true
  fi

  # 2. sessions.md에서 이전 행을 crashed로 표시
  mark_session_status "$project" "$role" "active" "crashed"

  # 3. 새 세션으로 부팅
  boot_single_agent "$role" "$project" || {
    echo "Error: ${role} 리부팅 실패." >&2
    exit 1
  }

  echo "=== ${role} 리부팅 완료 ==="
}

# ──────────────────────────────────────────────
# refresh 서브커맨드
# ──────────────────────────────────────────────

cmd_refresh() {
  local role="$1"
  local project="$2"
  local sess
  sess="$(session_name "$project")"

  echo "=== ${role} 에이전트 리프레시 ==="

  # tmux 세션 존재 확인
  if ! tmux has-session -t "$sess" 2>/dev/null; then
    echo "Error: tmux 세션 '$sess'가 없다. boot를 먼저 실행하라." >&2
    exit 1
  fi

  # 윈도우 존재 확인
  if ! tmux list-windows -t "$sess" -F '#{window_name}' 2>/dev/null | grep -q "^${role}$"; then
    echo "Error: ${role} 윈도우가 없다." >&2
    exit 1
  fi

  local handoff_file="$(project_dir "$project")/memory/${role}/handoff.md"

  # 1. 에이전트에게 handoff.md 작성 지시
  echo "handoff.md 작성 지시 전송..."
  tmux send-keys -t "${sess}:${role}" \
    "지금까지의 작업 맥락을 memory/${role}/handoff.md에 정리해라. 현재 진행 상황, 다음 할 일, 중요 결정사항을 포함해라." Enter

  # 2. 최대 2분 대기 (handoff.md 파일 생성 감시)
  echo "handoff.md 생성 대기 (최대 120초)..."
  local waited=0
  while [ $waited -lt 120 ]; do
    if [ -f "$handoff_file" ]; then
      echo "handoff.md 생성 확인 (${waited}초 경과)"
      break
    fi
    sleep 5
    waited=$((waited + 5))
  done

  if [ ! -f "$handoff_file" ]; then
    echo "Warning: 120초 내에 handoff.md가 생성되지 않았다. 그래도 리프레시를 진행한다." >&2
  fi

  # 3. 기존 세션 종료
  echo "기존 ${role} 세션 종료 중..."
  tmux send-keys -t "${sess}:${role}" "/exit" Enter 2>/dev/null || true
  sleep 3
  tmux kill-window -t "${sess}:${role}" 2>/dev/null || true

  # 4. sessions.md에서 이전 행을 refreshed로 표시
  mark_session_status "$project" "$role" "active" "refreshed"

  # 5. 새 세션 부팅 (온보딩 + handoff.md 읽기 지시 추가)
  local extra_msg=""
  if [ -f "$handoff_file" ]; then
    extra_msg="10. memory/${role}/handoff.md를 읽어라. 이전 세션에서 인수인계한 맥락이다."
  fi

  boot_single_agent "$role" "$project" "$extra_msg" || {
    echo "Error: ${role} 리프레시 후 부팅 실패." >&2
    exit 1
  }

  echo "=== ${role} 리프레시 완료 ==="
}

# ──────────────────────────────────────────────
# shutdown 서브커맨드
# ──────────────────────────────────────────────

cmd_shutdown() {
  local project="$1"
  local sess
  sess="$(session_name "$project")"

  echo "=== ${project} 프로젝트 종료 ==="

  # 1. 각 에이전트 윈도우에 /exit 전송
  if tmux has-session -t "$sess" 2>/dev/null; then
    local windows
    windows=$(tmux list-windows -t "$sess" -F '#{window_name}')
    for win in $windows; do
      echo "${win}에 /exit 전송"
      tmux send-keys -t "${sess}:${win}" "/exit" Enter
    done

    # 2. 5초 대기
    echo "에이전트 종료 대기 (5초)..."
    sleep 5

    # 3. tmux 세션 종료
    tmux kill-session -t "$sess"
    echo "tmux 세션 '$sess' 종료됨"
  else
    echo "tmux 세션 '$sess'가 없다. 이미 종료된 듯."
  fi

  # 4. monitor.sh 프로세스 종료
  local pid_file="$(project_dir "$project")/memory/manager/monitor.pid"
  if [ -f "$pid_file" ]; then
    local pid
    pid=$(cat "$pid_file")
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid"
      echo "monitor.sh 종료됨 (PID: $pid)"
    fi
    rm -f "$pid_file"
  fi

  # 5. sessions.md 업데이트
  close_all_sessions "$project"

  # 6. 런타임 파일 정리 (reboot 카운터, heartbeat)
  rm -rf "$(project_dir "$project")/memory/manager/reboot-counts"
  rm -f "$(project_dir "$project")/memory/manager/monitor.heartbeat"

  echo "=== 종료 완료 ==="
}

# ──────────────────────────────────────────────
# status 서브커맨드
# ──────────────────────────────────────────────

cmd_status() {
  local project="$1"
  local sess
  sess="$(session_name "$project")"
  local now
  now=$(date +%s)

  echo "=== ${project} 프로젝트 상태 ==="

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
        echo "  ${win_name} (idle: ${idle_min}분 ${idle_sec}초)"
      else
        echo "  ${win_name} (idle: 알 수 없음)"
      fi
    done < <(tmux list-windows -t "$sess" -F '#{window_name}|#{window_activity}')
  else
    echo "[tmux] 세션 없음"
  fi

  # monitor.sh 확인 (PID + heartbeat 신선도)
  local pid_file="$(project_dir "$project")/memory/manager/monitor.pid"
  if [ -f "$pid_file" ]; then
    local pid
    pid=$(cat "$pid_file")
    if kill -0 "$pid" 2>/dev/null; then
      local hb_file="$(project_dir "$project")/memory/manager/monitor.heartbeat"
      if [ -f "$hb_file" ]; then
        local hb_time
        hb_time=$(cat "$hb_file")
        local hb_age=$((now - hb_time))
        if [ "$hb_age" -gt 90 ]; then
          echo "[monitor] 실행 중 (PID: $pid) -- WARNING: heartbeat ${hb_age}초 전 (좀비 가능성)"
        else
          echo "[monitor] 실행 중 (PID: $pid, heartbeat: ${hb_age}초 전)"
        fi
      else
        echo "[monitor] 실행 중 (PID: $pid, heartbeat 파일 없음)"
      fi
    else
      echo "[monitor] 프로세스 죽음 (PID: $pid)"
    fi
  else
    echo "[monitor] 미시작"
  fi

  # mailbox 상태
  local mailbox_dir="$(project_dir "$project")/workspace/shared/mailbox"
  if [ -d "$mailbox_dir" ]; then
    echo "[mailbox]"
    for role_dir in "$mailbox_dir"/*/; do
      local role
      role=$(basename "$role_dir")
      local new_count
      new_count=$(find "$role_dir/new" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
      local cur_count
      cur_count=$(find "$role_dir/cur" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
      echo "  ${role}: new=${new_count}, cur=${cur_count}"
    done
  fi

  # sessions.md 출력
  local sf
  sf="$(sessions_file "$project")"
  if [ -f "$sf" ]; then
    echo ""
    cat "$sf"
  fi
}

# ──────────────────────────────────────────────
# 메인
# ──────────────────────────────────────────────

if [ $# -lt 2 ]; then
  echo "Usage:" >&2
  echo "  orchestrator.sh boot     {project}" >&2
  echo "  orchestrator.sh dispatch {role} {task-file} {project}" >&2
  echo "  orchestrator.sh shutdown {project}" >&2
  echo "  orchestrator.sh status   {project}" >&2
  echo "  orchestrator.sh reboot   {role} {project}" >&2
  echo "  orchestrator.sh refresh  {role} {project}" >&2
  exit 1
fi

command="$1"
shift

case "$command" in
  boot)
    [ $# -lt 1 ] && { echo "Usage: orchestrator.sh boot {project}" >&2; exit 1; }
    cmd_boot "$1"
    ;;
  dispatch)
    [ $# -lt 3 ] && { echo "Usage: orchestrator.sh dispatch {role} {task-file} {project}" >&2; exit 1; }
    cmd_dispatch "$1" "$2" "$3"
    ;;
  shutdown)
    [ $# -lt 1 ] && { echo "Usage: orchestrator.sh shutdown {project}" >&2; exit 1; }
    cmd_shutdown "$1"
    ;;
  status)
    [ $# -lt 1 ] && { echo "Usage: orchestrator.sh status {project}" >&2; exit 1; }
    cmd_status "$1"
    ;;
  reboot)
    [ $# -lt 2 ] && { echo "Usage: orchestrator.sh reboot {role} {project}" >&2; exit 1; }
    cmd_reboot "$1" "$2"
    ;;
  refresh)
    [ $# -lt 2 ] && { echo "Usage: orchestrator.sh refresh {role} {project}" >&2; exit 1; }
    cmd_refresh "$1" "$2"
    ;;
  *)
    echo "Unknown command: $command" >&2
    echo "Available: boot, dispatch, shutdown, status, reboot, refresh" >&2
    exit 1
    ;;
esac
