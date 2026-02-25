#!/bin/bash
# orchestrator.sh -- tmux 기반 멀티 에이전트 오케스트레이션
#
# 서브커맨드:
#   boot-manager   {project}                   -- Manager 부팅 + tmux 세션 생성
#   boot           {project}                   -- tmux 세션 생성 + 에이전트 부팅 + monitor 시작
#   dispatch       {role} {task-file} {project} -- 에이전트에게 태스크 전달
#   dual-dispatch  {role} {task-file} {project} -- 양쪽 백엔드에 동일 태스크 전달 (dual 모드)
#   spawn          {role} {window-name} {project} [extra-msg] -- 동적 에이전트 추가 스폰
#   kill-agent     {window-name} {project}     -- 동적 에이전트 종료
#   shutdown       {project}                   -- 세션 종료 + 정리
#   status         {project}                   -- 세션 상태 확인
#   reboot         {target} {project}          -- 에이전트 세션 재시작 (target: role 또는 role-backend)
#   refresh        {target} {project}          -- 에이전트 맥락 리프레시 (target: role 또는 role-backend)
#   monitor-check  {project}                   -- monitor.sh 상태 확인 + 자동 재시작

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
TOOLS_DIR="$REPO_ROOT/agents/manager/tools"

# ──────────────────────────────────────────────
# 유틸리티 함수
# ──────────────────────────────────────────────

validate_project_name() {
  local name="$1"
  if [ -z "$name" ] || [[ "$name" == */* ]] || [[ "$name" == *..* ]]; then
    echo "Error: 잘못된 project 이름: '$name'" >&2
    exit 1
  fi
}

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

# 역할별 allowedTools
get_allowed_tools() {
  local role="$1"
  case "$role" in
    monitoring) echo "Read,Glob,Grep,Bash" ;;
    *)          echo "Read,Glob,Grep,Write,Edit,Bash,WebSearch,WebFetch" ;;
  esac
}

# 역할별 max-turns
get_max_turns() {
  local role="$1"
  case "$role" in
    monitoring) echo "10" ;;
    manager)    echo "20" ;;
    researcher) echo "30" ;;
    developer)  echo "40" ;;
    *)          echo "20" ;;
  esac
}

# 역할별 도메인 파일 경로 (있으면 반환)
get_domain() {
  local project="$1"
  local project_md="$(project_dir "$project")/project.md"
  { grep -i "domain" "$project_md" 2>/dev/null || true; } \
    | head -1 \
    | sed 's/.*: *//' \
    | sed 's/ *(.*//' \
    | tr -d '[:space:]' \
    | tr -d '*'
}

# project.md에서 실행 모드 추출 (solo | dual, 기본값 solo)
get_exec_mode() {
  local project="$1"
  local project_md="$(project_dir "$project")/project.md"
  local mode
  mode=$({ grep -i "실행 모드" "$project_md" 2>/dev/null || true; } \
    | head -1 \
    | sed 's/.*: *//' \
    | tr -d '[:space:]' \
    | tr -d '*|' \
    | tr '[:upper:]' '[:lower:]')
  if [ "$mode" = "dual" ]; then echo "dual"; else echo "solo"; fi
}

# 부팅 메시지 생성
build_boot_message() {
  local role="$1"
  local project="$2"
  local extra="${3:-}"
  local agent_id="${4:-$role}"
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
5. (해당 시) domains/${domain}/context.md 읽기
6. (해당 시) domains/${domain}/${role}.md 읽기
7. (해당 시) projects/${project}/team/${role}.md 읽기
8. memory/knowledge/index.md 읽기
9. 알림 보내기 (상황별 예시):
   태스크 완료:
     bash agents/manager/tools/notify.sh ${project} ${agent_id} manager task_complete normal "TASK-XXX 완료" "결과 요약"
   도움 필요:
     bash agents/manager/tools/notify.sh ${project} ${agent_id} manager need_input normal "방향 선택 필요" "상세 내용"
   긴급 블로커:
     bash agents/manager/tools/notify.sh ${project} ${agent_id} manager escalation urgent "블로커 발생" "상세 내용"
   다른 에이전트에게:
     bash agents/manager/tools/notify.sh ${project} ${agent_id} {대상} status_update normal "제목" "내용"

10. 알림 받기 — 작업 중 아래 형식의 알림이 올 수 있다:
    [notify] {보낸이} → {나} | {종류}
    제목: {제목}
    내용: {내용}

    종류별 행동:
    - task_complete: 태스크 결과 확인 후 다음 단계
    - status_update: 참고
    - need_input: 응답 필요
    - escalation: 긴급 처리
    - agent_ready: 에이전트 준비 확인
    - reboot_notice: 에이전트 복구 상태 확인
${extra}
온보딩이 끝나면 준비 완료를 알림으로 보고해라:
bash agents/manager/tools/notify.sh ${project} ${agent_id} manager agent_ready normal "온보딩 완료" "${agent_id} 에이전트 준비 완료"
BOOTMSG
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

# sessions.md에 행 추가
add_session_row() {
  local project="$1" role="$2" session_id="$3" tmux_target="$4" model="$5" backend="${6:-claude}"
  local sf
  sf="$(sessions_file "$project")"

  # 중복 등록 방지: 이미 같은 tmux_target이 active면 건너뜀
  if grep -q "| ${tmux_target} | active |" "$sf" 2>/dev/null; then
    echo "Warning: ${tmux_target}가 이미 active 상태. 중복 등록 건너뜀." >&2
    return 0
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
      sed -i '' "s/| ${role} | ${backend} \(.*\)| ${old_status} |/| ${role} | ${backend} \1| ${new_status} |/g" "$sf"
    else
      sed -i '' "s/| ${role} \(.*\)| ${old_status} |/| ${role} \1| ${new_status} |/g" "$sf"
    fi
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
  local window_name="${4:-$role}"
  local sess
  sess="$(session_name "$project")"
  local model
  model="$(get_model "$role")"
  local allowed_tools
  allowed_tools="$(get_allowed_tools "$role")"
  local max_turns
  max_turns="$(get_max_turns "$role")"
  local agent_id="$window_name"
  local boot_msg
  boot_msg="$(build_boot_message "$role" "$project" "$extra_boot_msg" "$agent_id")"
  local tmux_target="${sess}:${window_name}"

  echo "--- ${window_name} (${model}) 부팅 중 ---"

  # claude -p로 초기 세션 생성하여 session_id 획득
  # env -u CLAUDECODE: Manager가 Claude Code 안에서 호출할 때 중첩 세션 에러 방지
  local result
  result=$(env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT claude -p "$boot_msg" \
    --model "$model" \
    --output-format json \
    --allowedTools "$allowed_tools" \
    --max-turns "$max_turns" \
    --dangerously-skip-permissions) || {
    echo "Warning: ${window_name} claude -p 실행 실패." >&2
    return 1
  }

  local session_id
  session_id=$(echo "$result" | jq -r '.session_id' 2>/dev/null) || session_id=""

  if [ -z "$session_id" ] || [ "$session_id" = "null" ]; then
    echo "Warning: ${window_name} session_id 획득 실패." >&2
    return 1
  fi

  # tmux 윈도우 생성 후 claude --resume으로 인터랙티브 세션 시작
  # env -u CLAUDECODE: Manager가 Claude Code 안에서 호출할 때 중첩 세션 에러 방지
  tmux new-window -t "$sess" -n "$window_name"
  tmux send-keys -t "$tmux_target" "env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT claude --resume $session_id --dangerously-skip-permissions" Enter

  # sessions.md에 기록
  add_session_row "$project" "$role" "$session_id" "$tmux_target" "$model" "claude"

  echo "${window_name} 부팅 완료: session=${session_id}, tmux=${tmux_target}"
  return 0
}

# Codex CLI 에이전트 부팅
boot_codex_agent() {
  local role="$1"
  local project="$2"
  local window_name="$3"
  local extra_boot_msg="${4:-}"
  local sess
  sess="$(session_name "$project")"
  local agent_id="$window_name"
  local tmux_target="${sess}:${window_name}"

  # codex CLI 설치 확인
  if ! command -v codex &>/dev/null; then
    echo "Warning: codex CLI가 설치되어 있지 않다. ${window_name} 부팅 건너뜀." >&2
    return 1
  fi

  echo "--- ${window_name} (codex) 부팅 중 ---"

  # 부팅 메시지를 파일에 저장 (send-keys 길이 제한 회피)
  local boot_msg
  boot_msg="$(build_boot_message "$role" "$project" "$extra_boot_msg" "$agent_id")"
  local boot_file="$(project_dir "$project")/memory/${role}/codex-boot-msg.md"
  mkdir -p "$(dirname "$boot_file")"
  echo "$boot_msg" > "$boot_file"

  # tmux 윈도우 생성
  tmux new-window -t "$sess" -n "$window_name"

  # codex 인터랙티브 시작
  tmux send-keys -t "$tmux_target" "codex" Enter
  sleep 2

  # 부팅 메시지 파일 읽기 지시
  tmux send-keys -t "$tmux_target" \
    "${boot_file} 파일을 읽고 그 안의 온보딩 절차를 따라라." Enter

  # sessions.md에 기록
  add_session_row "$project" "$role" "codex-interactive" "$tmux_target" "codex" "codex"

  echo "${window_name} 부팅 완료: tmux=${tmux_target}"
  return 0
}

# ──────────────────────────────────────────────
# spawn 서브커맨드 — 동적 에이전트 추가 스폰
# ──────────────────────────────────────────────

cmd_spawn() {
  local role="$1"        # researcher, developer 등
  local window_name="$2" # researcher-2, dev-hotfix 등
  local project="$3"
  local extra_msg="${4:-}"
  validate_project_name "$project"
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

  # 부팅 (동일한 프로젝트 맥락, 메모리 공유)
  local spawn_note="
참고: 너는 동적으로 스폰된 추가 에이전트다 (${window_name}).
다른 에이전트가 현재 수정 중인 파일은 건드리지 마라.
${extra_msg}"
  boot_single_agent "$role" "$project" "$spawn_note" "$window_name" || {
    echo "Error: ${window_name} 스폰 실패." >&2
    exit 1
  }
  echo "=== ${window_name} 스폰 완료 ==="
}

# ──────────────────────────────────────────────
# kill-agent 서브커맨드 — 동적 에이전트 종료
# ──────────────────────────────────────────────

cmd_kill_agent() {
  local window_name="$1"
  local project="$2"
  validate_project_name "$project"
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

  # sessions.md 업데이트
  local sf
  sf="$(sessions_file "$project")"
  if [ -f "$sf" ]; then
    sed -i '' "s/| ${sess}:${window_name} | active |/| ${sess}:${window_name} | closed |/g" "$sf"
  fi
  echo "=== ${window_name} 종료 완료 ==="
}

# ──────────────────────────────────────────────
# boot-manager 서브커맨드
# ──────────────────────────────────────────────

cmd_boot_manager() {
  local project="$1"
  validate_project_name "$project"
  local sess
  sess="$(session_name "$project")"

  echo "=== Manager 부팅 ==="

  # 이미 세션이 있으면 중단
  if tmux has-session -t "$sess" 2>/dev/null; then
    echo "Error: tmux 세션 '$sess'가 이미 존재한다. 먼저 shutdown하라." >&2
    exit 1
  fi

  # 1. sessions.md 초기화
  init_sessions_file "$project"

  # 2. Manager 부팅 (claude -p → session_id)
  local model
  model="$(get_model "manager")"
  local allowed_tools
  allowed_tools="$(get_allowed_tools "manager")"
  local max_turns
  max_turns="$(get_max_turns "manager")"
  local extra_boot_instructions
  extra_boot_instructions=$(cat << EXTRA
10. 온보딩 완료 후, 아래 명령으로 팀 에이전트를 부팅해라:
    bash agents/manager/tools/orchestrator.sh boot ${project}
11. 모든 에이전트의 agent_ready 메시지를 기다려라.
12. 팀이 준비되면 project.md의 목표를 분석하고 첫 태스크를 분배해라.
    techniques/task-distribution.md 절차를 따른다.
EXTRA
)
  local boot_msg
  boot_msg="$(build_boot_message "manager" "$project" "$extra_boot_instructions")"

  # env -u CLAUDECODE: Claude Code 안에서 호출할 때 중첩 세션 에러 방지
  local result
  result=$(env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT claude -p "$boot_msg" \
    --model "$model" \
    --output-format json \
    --allowedTools "$allowed_tools" \
    --max-turns "$max_turns" \
    --dangerously-skip-permissions) || {
    echo "Error: Manager claude -p 실행 실패." >&2
    exit 1
  }

  local session_id
  session_id=$(echo "$result" | jq -r '.session_id' 2>/dev/null) || session_id=""

  if [ -z "$session_id" ] || [ "$session_id" = "null" ]; then
    echo "Error: Manager session_id 획득 실패." >&2
    exit 1
  fi

  # 3. tmux 세션 생성 + Manager 투입
  tmux new-session -d -s "$sess" -n manager
  local tmux_target="${sess}:manager"
  tmux send-keys -t "$tmux_target" "env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT claude --resume $session_id --dangerously-skip-permissions" Enter

  # 4. sessions.md에 기록
  add_session_row "$project" "manager" "$session_id" "$tmux_target" "$model"

  echo "=== Manager 부팅 완료 ==="
  echo "session_id: $session_id"
  echo "tmux attach -t $sess 로 접속하라."
  echo "Manager가 orchestrator.sh boot ${project} 로 나머지 에이전트를 부팅한다."
}

# ──────────────────────────────────────────────
# boot 서브커맨드
# ──────────────────────────────────────────────

cmd_boot() {
  local project="$1"
  validate_project_name "$project"
  local sess
  sess="$(session_name "$project")"
  local exec_mode
  exec_mode="$(get_exec_mode "$project")"

  echo "=== ${project} 프로젝트 부팅 (mode: ${exec_mode}) ==="

  # dual 모드 시 codex 설치 확인
  if [ "$exec_mode" = "dual" ] && ! command -v codex &>/dev/null; then
    echo "Error: dual 모드이지만 codex CLI가 설치되어 있지 않다." >&2
    exit 1
  fi

  # 1. sessions.md 초기화 (멱등 — boot-manager에서 이미 생성했으면 건너뜀)
  init_sessions_file "$project"

  # 2. tmux 세션 생성 또는 기존 재사용
  if tmux has-session -t "$sess" 2>/dev/null; then
    echo "기존 tmux 세션 '$sess' 재사용 (boot-manager로 생성됨)"
  else
    tmux new-session -d -s "$sess" -n manager
    echo "tmux 세션 '$sess' 생성됨"
  fi

  # 3. 각 에이전트 부팅
  local agents
  agents="$(get_active_agents "$project")"

  if [ -z "$agents" ]; then
    echo "Error: project.md에서 활성 에이전트를 찾을 수 없다." >&2
    exit 1
  fi

  for role in $agents; do
    # manager는 이미 유저가 사용 중이므로 건너뛴다
    if [ "$role" = "manager" ]; then
      continue
    fi

    if [ "$exec_mode" = "dual" ] && [ "$role" != "monitoring" ]; then
      # dual 모드: claude + codex 양쪽 부팅 (monitoring은 solo)
      boot_single_agent "$role" "$project" "" "${role}-claude" || {
        echo "Warning: ${role}-claude 부팅 실패. 건너뜀." >&2
      }
      boot_codex_agent "$role" "$project" "${role}-codex" || {
        echo "Warning: ${role}-codex 부팅 실패. 건너뜀." >&2
      }
    else
      # solo 모드 (기존 동작)
      boot_single_agent "$role" "$project" || {
        echo "Warning: ${role} 부팅 실패. 건너뜀." >&2
        continue
      }
    fi
  done

  # 4. monitor.sh 백그라운드 실행 (에러 로깅)
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
  validate_project_name "$project"
  local sess
  sess="$(session_name "$project")"
  local tmux_target="${sess}:${role}"

  # tmux 윈도우 존재 확인
  if ! tmux list-windows -t "$sess" -F '#{window_name}' 2>/dev/null | grep -q "^${role}$"; then
    echo "Error: ${role} 윈도우가 없다. 에이전트가 부팅되지 않았다." >&2
    exit 1
  fi

  # 태스크 지시 전송
  tmux send-keys -t "$tmux_target" \
    "${task_file} 파일에 새 작업 지시가 있다. 읽고 실행해라." Enter

  echo "dispatch 완료: ${role} ← ${task_file}"
}

# ──────────────────────────────────────────────
# dual-dispatch 서브커맨드
# ──────────────────────────────────────────────

cmd_dual_dispatch() {
  local role="$1"
  local task_file="$2"
  local project="$3"
  validate_project_name "$project"
  local sess
  sess="$(session_name "$project")"

  local claude_win="${role}-claude"
  local codex_win="${role}-codex"

  # 양쪽 윈도우 존재 확인
  local windows
  windows=$(tmux list-windows -t "$sess" -F '#{window_name}' 2>/dev/null)

  local ok=true
  if ! echo "$windows" | grep -q "^${claude_win}$"; then
    echo "Error: ${claude_win} 윈도우가 없다." >&2
    ok=false
  fi
  if ! echo "$windows" | grep -q "^${codex_win}$"; then
    echo "Error: ${codex_win} 윈도우가 없다." >&2
    ok=false
  fi
  if [ "$ok" = false ]; then
    exit 1
  fi

  # 양쪽에 동일 태스크 전달
  tmux send-keys -t "${sess}:${claude_win}" \
    "${task_file} 파일에 새 작업 지시가 있다. 읽고 실행해라." Enter
  tmux send-keys -t "${sess}:${codex_win}" \
    "${task_file} 파일에 새 작업 지시가 있다. 읽고 실행해라." Enter

  echo "dual-dispatch 완료: ${role} (claude + codex) ← ${task_file}"
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
  local role backend window_name
  if [[ "$target" == *-claude ]]; then
    role="${target%-claude}"
    backend="claude"
    window_name="$target"
  elif [[ "$target" == *-codex ]]; then
    role="${target%-codex}"
    backend="codex"
    window_name="$target"
  else
    role="$target"
    backend="claude"
    window_name="$target"
  fi

  echo "=== ${window_name} 에이전트 리부팅 ==="

  # tmux 세션 존재 확인
  if ! tmux has-session -t "$sess" 2>/dev/null; then
    echo "Error: tmux 세션 '$sess'가 없다. boot를 먼저 실행하라." >&2
    exit 1
  fi

  # 1. 기존 윈도우 있으면 kill
  if tmux list-windows -t "$sess" -F '#{window_name}' 2>/dev/null | grep -q "^${window_name}$"; then
    echo "기존 ${window_name} 윈도우 종료 중..."
    tmux send-keys -t "${sess}:${window_name}" "/exit" Enter 2>/dev/null || true
    sleep 2
    tmux kill-window -t "${sess}:${window_name}" 2>/dev/null || true
  fi

  # 2. sessions.md에서 이전 행을 crashed로 표시
  mark_session_status "$project" "$role" "active" "crashed" "$backend"

  # 3. backend에 따라 적절한 부팅 함수 호출
  if [ "$backend" = "codex" ]; then
    boot_codex_agent "$role" "$project" "$window_name" || {
      echo "Error: ${window_name} 리부팅 실패." >&2
      exit 1
    }
  else
    boot_single_agent "$role" "$project" "" "$window_name" || {
      echo "Error: ${window_name} 리부팅 실패." >&2
      exit 1
    }
  fi

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

  # target에서 role과 backend 분리 (reboot과 동일한 파싱)
  local role backend window_name
  if [[ "$target" == *-claude ]]; then
    role="${target%-claude}"
    backend="claude"
    window_name="$target"
  elif [[ "$target" == *-codex ]]; then
    role="${target%-codex}"
    backend="codex"
    window_name="$target"
  else
    role="$target"
    backend="claude"
    window_name="$target"
  fi

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

  # handoff 파일 경로는 role 기준 (backend별로 분리하지 않음)
  local handoff_file="$(project_dir "$project")/memory/${role}/handoff.md"

  # 1. 에이전트에게 handoff.md 작성 지시
  echo "handoff.md 작성 지시 전송..."
  tmux send-keys -t "${sess}:${window_name}" \
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
  echo "기존 ${window_name} 세션 종료 중..."
  tmux send-keys -t "${sess}:${window_name}" "/exit" Enter 2>/dev/null || true
  sleep 3
  tmux kill-window -t "${sess}:${window_name}" 2>/dev/null || true

  # 4. sessions.md에서 이전 행을 refreshed로 표시
  mark_session_status "$project" "$role" "active" "refreshed" "$backend"

  # 5. 새 세션 부팅 (온보딩 + handoff.md 읽기 지시 추가)
  local extra_msg=""
  if [ -f "$handoff_file" ]; then
    extra_msg="10. memory/${role}/handoff.md를 읽어라. 이전 세션에서 인수인계한 맥락이다."
  fi

  if [ "$backend" = "codex" ]; then
    boot_codex_agent "$role" "$project" "$window_name" "$extra_msg" || {
      echo "Error: ${window_name} 리프레시 후 부팅 실패." >&2
      exit 1
    }
  else
    boot_single_agent "$role" "$project" "$extra_msg" "$window_name" || {
      echo "Error: ${window_name} 리프레시 후 부팅 실패." >&2
      exit 1
    }
  fi

  echo "=== ${window_name} 리프레시 완료 ==="
}

# ──────────────────────────────────────────────
# monitor-check 서브커맨드
# ──────────────────────────────────────────────

cmd_monitor_check() {
  local project="$1"
  validate_project_name "$project"
  local pid_file="$(project_dir "$project")/memory/manager/monitor.pid"
  local hb_file="$(project_dir "$project")/memory/manager/monitor.heartbeat"
  local now
  now=$(date +%s)

  # PID 파일 확인
  if [ ! -f "$pid_file" ]; then
    echo "[monitor-check] PID 파일 없음. monitor.sh 재시작 중..."
    restart_monitor "$project"
    return
  fi

  local pid
  pid=$(cat "$pid_file")

  # PID가 숫자인지 확인
  if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
    echo "[monitor-check] PID 파일에 잘못된 값: '$pid'. monitor.sh 재시작 중..." >&2
    restart_monitor "$project"
    return
  fi

  # 프로세스 생존 확인
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "[monitor-check] monitor.sh 프로세스 죽음 (PID: $pid). 재시작 중..."
    restart_monitor "$project"
    return
  fi

  # heartbeat 신선도 확인 (90초 이상이면 좀비)
  if [ -f "$hb_file" ]; then
    local hb_time
    hb_time=$(cat "$hb_file")
    if ! [[ "$hb_time" =~ ^[0-9]+$ ]]; then
      echo "[monitor-check] heartbeat 파일에 잘못된 값. 프로세스 확인 필요."
      return
    fi
    local hb_age=$((now - hb_time))
    if [ "$hb_age" -gt 90 ]; then
      echo "[monitor-check] heartbeat ${hb_age}초 전 (좀비). 강제 종료 후 재시작..."
      kill "$pid" 2>/dev/null || true
      sleep 1
      restart_monitor "$project"
      return
    fi
    echo "[monitor-check] monitor.sh 정상 (PID: $pid, heartbeat: ${hb_age}초 전)"
  else
    echo "[monitor-check] heartbeat 파일 없음. 프로세스 확인 필요."
  fi
}

restart_monitor() {
  local project="$1"
  local log_dir="$(project_dir "$project")/memory/manager/logs"
  mkdir -p "$log_dir"
  local log_file="$log_dir/monitor-$(date +%Y%m%d-%H%M%S).log"
  nohup bash "$TOOLS_DIR/monitor.sh" "$project" >> "$log_file" 2>&1 &
  local new_pid=$!
  echo "$new_pid" > "$(project_dir "$project")/memory/manager/monitor.pid"
  echo "[monitor-check] monitor.sh 재시작 완료 (PID: $new_pid, log: $log_file)"
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
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
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
  validate_project_name "$project"
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
        local idle_rem=$((idle_sec % 60))
        echo "  ${win_name} (idle: ${idle_min}분 ${idle_rem}초)"
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
    if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
      echo "[monitor] PID 파일에 잘못된 값: '$pid'"
    elif kill -0 "$pid" 2>/dev/null; then
      local hb_file="$(project_dir "$project")/memory/manager/monitor.heartbeat"
      if [ -f "$hb_file" ]; then
        local hb_time
        hb_time=$(cat "$hb_file")
        if [[ "$hb_time" =~ ^[0-9]+$ ]]; then
          local hb_age=$((now - hb_time))
          if [ "$hb_age" -gt 90 ]; then
            echo "[monitor] 실행 중 (PID: $pid) -- WARNING: heartbeat ${hb_age}초 전 (좀비 가능성)"
          else
            echo "[monitor] 실행 중 (PID: $pid, heartbeat: ${hb_age}초 전)"
          fi
        else
          echo "[monitor] 실행 중 (PID: $pid, heartbeat 파일에 잘못된 값)"
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
  echo "  orchestrator.sh boot-manager   {project}" >&2
  echo "  orchestrator.sh boot           {project}" >&2
  echo "  orchestrator.sh dispatch       {role} {task-file} {project}" >&2
  echo "  orchestrator.sh dual-dispatch  {role} {task-file} {project}" >&2
  echo "  orchestrator.sh spawn          {role} {window-name} {project} [extra-msg]" >&2
  echo "  orchestrator.sh kill-agent     {window-name} {project}" >&2
  echo "  orchestrator.sh shutdown       {project}" >&2
  echo "  orchestrator.sh status         {project}" >&2
  echo "  orchestrator.sh reboot         {target} {project}" >&2
  echo "  orchestrator.sh refresh        {target} {project}" >&2
  echo "  orchestrator.sh monitor-check  {project}" >&2
  exit 1
fi

command="$1"
shift

case "$command" in
  boot-manager)
    [ $# -lt 1 ] && { echo "Usage: orchestrator.sh boot-manager {project}" >&2; exit 1; }
    cmd_boot_manager "$1"
    ;;
  boot)
    [ $# -lt 1 ] && { echo "Usage: orchestrator.sh boot {project}" >&2; exit 1; }
    cmd_boot "$1"
    ;;
  dispatch)
    [ $# -lt 3 ] && { echo "Usage: orchestrator.sh dispatch {role} {task-file} {project}" >&2; exit 1; }
    cmd_dispatch "$1" "$2" "$3"
    ;;
  dual-dispatch)
    [ $# -lt 3 ] && { echo "Usage: orchestrator.sh dual-dispatch {role} {task-file} {project}" >&2; exit 1; }
    cmd_dual_dispatch "$1" "$2" "$3"
    ;;
  spawn)
    [ $# -lt 3 ] && { echo "Usage: orchestrator.sh spawn {role} {window-name} {project} [extra-msg]" >&2; exit 1; }
    cmd_spawn "$1" "$2" "$3" "${4:-}"
    ;;
  kill-agent)
    [ $# -lt 2 ] && { echo "Usage: orchestrator.sh kill-agent {window-name} {project}" >&2; exit 1; }
    cmd_kill_agent "$1" "$2"
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
    [ $# -lt 2 ] && { echo "Usage: orchestrator.sh reboot {target} {project}" >&2; exit 1; }
    cmd_reboot "$1" "$2"
    ;;
  refresh)
    [ $# -lt 2 ] && { echo "Usage: orchestrator.sh refresh {target} {project}" >&2; exit 1; }
    cmd_refresh "$1" "$2"
    ;;
  monitor-check)
    [ $# -lt 1 ] && { echo "Usage: orchestrator.sh monitor-check {project}" >&2; exit 1; }
    cmd_monitor_check "$1"
    ;;
  *)
    echo "Unknown command: $command" >&2
    echo "Available: boot-manager, boot, dispatch, dual-dispatch, spawn, kill-agent, shutdown, status, reboot, refresh, monitor-check" >&2
    exit 1
    ;;
esac
