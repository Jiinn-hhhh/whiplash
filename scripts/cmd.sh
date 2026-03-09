#!/bin/bash
# cmd.sh -- tmux 기반 멀티 에이전트 오케스트레이션
#
# 서브커맨드:
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
# shellcheck source=/dev/null
source "$TOOLS_DIR/tmux-submit.sh"
# shellcheck source=/dev/null
source "$TOOLS_DIR/runtime-paths.sh"

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

# 역할별 허용 도구 (profile.md 메타데이터)
get_allowed_tools() {
  local role="$1"
  parse_agent_meta "$role" "allowed-tools"
}

get_manager_backend() {
  local backend="${WHIPLASH_MANAGER_BACKEND:-claude}"
  case "$backend" in
    claude|codex) echo "$backend" ;;
    *)            echo "claude" ;;
  esac
}

get_codex_model() {
  if [ -n "${WHIPLASH_CODEX_MODEL:-}" ]; then
    echo "$WHIPLASH_CODEX_MODEL"
    return
  fi

  local cfg="${HOME}/.codex/config.toml"
  if [ -f "$cfg" ]; then
    local model
    model=$(sed -n 's/^model = "\(.*\)"/\1/p' "$cfg" | head -1)
    if [ -n "$model" ]; then
      echo "$model"
      return
    fi
  fi

  echo "codex"
}

get_codex_frontend_mode() {
  echo "interactive"
}

build_codex_env_prefix() {
  local env_prefix="env"
  if [ -n "${WHIPLASH_CODEX_MODEL:-}" ]; then
    env_prefix+=" WHIPLASH_CODEX_MODEL=$(printf '%q' "$WHIPLASH_CODEX_MODEL")"
  fi
  if [ -n "${WHIPLASH_CODEX_REASONING_EFFORT:-}" ]; then
    env_prefix+=" WHIPLASH_CODEX_REASONING_EFFORT=$(printf '%q' "$WHIPLASH_CODEX_REASONING_EFFORT")"
  fi
  if [ -n "${WHIPLASH_CODEX_SERVICE_TIER:-}" ]; then
    env_prefix+=" WHIPLASH_CODEX_SERVICE_TIER=$(printf '%q' "$WHIPLASH_CODEX_SERVICE_TIER")"
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

# 부팅 메시지 생성
build_boot_message() {
  local role="$1"
  local project="$2"
  local extra="${3:-}"
  local agent_id="${4:-$role}"
  local pending_task="${5:-}"
  local domain
  domain="$(get_domain "$project")"
  domain="${domain:-general}"
  local message_cmd="bash \"$TOOLS_DIR/message.sh\""
  local layer2_domain_line
  local layer3_domain_line

  if [ "$domain" = "general" ]; then
    layer2_domain_line="6. 이 프로젝트 도메인은 general이다. 추가 domain context는 없다."
    layer3_domain_line="8. general 도메인이므로 role-specific domain 파일도 없다."
  else
    layer2_domain_line="6. (파일이 있으면) domains/${domain}/context.md 읽기"
    layer3_domain_line="8. (파일이 있으면) domains/${domain}/${role}.md"
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
    - need_input: 응답 필요
    - escalation: 긴급 처리
    - agent_ready: 에이전트 준비 확인
    - reboot_notice: 에이전트 복구 상태 확인
    - consensus_request: 비교 문서를 읽고 consensus_response로 답변

13. Claude/Codex가 제공하는 네이티브 subagent / team / parallel 기능을 적극 활용하라.
    단, 외부에 공유하는 공식 결과는 반드시 네가 직접 검토·정리한 뒤 보고해라.
${extra}
$(
  # 듀얼 모드 워크트리 경로 안내
  _exec_mode="$(get_exec_mode "$project")"
  _code_repo="$(get_code_repo "$project")"
  if [ "$_exec_mode" = "dual" ] && [ -n "$_code_repo" ] && { [[ "$agent_id" == *-claude ]] || [[ "$agent_id" == *-codex ]]; }; then
    echo "작업 디렉토리: ${_code_repo}/.worktrees/${agent_id}/"
    echo "주의: 반드시 이 디렉토리 안에서만 코드를 수정하라. 메인 레포를 직접 수정하지 마라."
  fi
)
온보딩이 끝나면 준비 완료를 알림으로 보고해라:
${message_cmd} ${project} ${agent_id} manager agent_ready normal "온보딩 완료" "${agent_id} 에이전트 준비 완료"
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
  local project="$1"
  local task_ref="$2"
  local pdir
  pdir="$(project_dir "$project")"
  if [[ "$task_ref" == "$pdir"/* ]]; then
    task_ref="${task_ref#"$pdir"/}"
  elif [[ "$task_ref" == "projects/$project/"* ]]; then
    task_ref="${task_ref#"projects/$project/"}"
  fi
  echo "$task_ref"
}

record_assignment() {
  local project="$1" agent="$2" task_file="$3"
  local pdir
  pdir="$(project_dir "$project")"
  local af="${pdir}/memory/manager/assignments.md"
  mkdir -p "$(dirname "$af")"

  # 절대경로 → 상대경로 정규화 (project_dir 기준)
  task_file="$(normalize_task_ref "$project" "$task_file")"

  if [ ! -f "$af" ]; then
    cat > "$af" << 'HEADER'
# 태스크 할당 현황
| 에이전트 | 태스크 파일 | 할당 시각 | 상태 |
|----------|-----------|----------|------|
HEADER
  fi
  # 기존 active → completed
  if grep -q "| ${agent} |.*| active |" "$af" 2>/dev/null; then
    sed_inplace "s/| ${agent} |\(.*\)| active |/| ${agent} |\1| completed |/" "$af"
  fi
  echo "| ${agent} | ${task_file} | $(date '+%Y-%m-%d %H:%M') | active |" >> "$af"
}

# assignments.md에서 에이전트의 active 태스크를 completed로 변경
complete_assignment() {
  local project="$1" agent="$2"
  local af="$(project_dir "$project")/memory/manager/assignments.md"
  [ -f "$af" ] || return 0
  if grep -q "| ${agent} |.*| active |" "$af" 2>/dev/null; then
    sed_inplace "s/| ${agent} |\(.*\)| active |/| ${agent} |\1| completed |/" "$af"
  fi
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
  local project="$1" agent="$2"
  local af="$(project_dir "$project")/memory/manager/assignments.md"
  [ -f "$af" ] || return 0
  { grep "| ${agent} |" "$af" 2>/dev/null || true; } | grep "| active |" | tail -1 | awk -F'|' '{print $3}' | sed 's/^ *//;s/ *$//' || true
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

# sessions.md 전체를 closed로 갱신
close_all_sessions() {
  local project="$1"
  local sf
  sf="$(sessions_file "$project")"
  if [ -f "$sf" ]; then
    sed_inplace 's/| active |/| closed |/g' "$sf"
  fi
}

# 단일 에이전트 부팅 (reboot/refresh에서 재사용)
boot_single_agent() {
  local role="$1"
  local project="$2"
  local extra_boot_msg="${3:-}"
  local window_name="${4:-$role}"
  local pending_task="${5:-}"
  local sess
  sess="$(session_name "$project")"

  # 멱등성 가드: 윈도우 존재 + claude 프로세스 alive 확인
  if tmux list-windows -t "${sess}" -F '#{window_name}' 2>/dev/null | grep -q "^${window_name}$"; then
    local existing_pane_pid
    existing_pane_pid=$(tmux list-panes -t "${sess}:${window_name}" -F '#{pane_pid}' 2>/dev/null | head -1)
    if [ -n "$existing_pane_pid" ] && pgrep -P "$existing_pane_pid" claude >/dev/null 2>&1; then
      echo "Info: ${window_name} 윈도우 + claude 프로세스 활성. 부팅 건너뜀." >&2
      return 0
    fi
    # 윈도우는 있지만 프로세스가 없음 → 윈도우 kill 후 재부팅 진행
    echo "Info: ${window_name} 윈도우 존재하나 claude 프로세스 없음. 윈도우 제거 후 재부팅." >&2
    tmux kill-window -t "${sess}:${window_name}" 2>/dev/null || true
  fi

  local model
  model="$(get_model "$role")"
  local tools
  tools="$(get_allowed_tools "$role")"
  local agent_id="$window_name"
  local boot_msg
  boot_msg="$(build_boot_message "$role" "$project" "$extra_boot_msg" "$agent_id" "$pending_task")"
  local tmux_target="${sess}:${window_name}"

  echo "--- ${window_name} (${model}) 부팅 중 ---"

  # claude -p로 초기 세션 생성하여 session_id 획득
  # env -u CLAUDECODE: Manager가 Claude Code 안에서 호출할 때 중첩 세션 에러 방지
  local tools_flag=""
  [ -n "$tools" ] && tools_flag="--allowedTools $tools"
  local result
  result=$(env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT claude -p "$boot_msg" \
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
  tmux send-keys -t "$tmux_target" "env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT claude --resume $session_id --dangerously-skip-permissions${resume_tools_flag}" Enter

  # 부팅 확인: claude 프로세스 시작 대기 (최대 10초)
  local boot_pane_pid
  boot_pane_pid=$(tmux list-panes -t "$tmux_target" -F '#{pane_pid}' 2>/dev/null | head -1)
  if [ -n "$boot_pane_pid" ]; then
    local i
    for i in $(seq 1 10); do
      pgrep -P "$boot_pane_pid" claude >/dev/null 2>&1 && break
      sleep 1
    done
    if ! pgrep -P "$boot_pane_pid" claude >/dev/null 2>&1; then
      echo "Warning: ${window_name} claude 프로세스 10초 내 미시작." >&2
      python3 "$TOOLS_DIR/log.py" system "$project" orchestrator agent_boot_fail "$window_name" --detail reason="claude 프로세스 미시작" || true
      return 1
    fi
  fi

  # sessions.md에 기록
  add_session_row "$project" "$role" "$session_id" "$tmux_target" "$model" "claude"

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
  local sess
  sess="$(session_name "$project")"
  local agent_id="$window_name"
  local tmux_target="${sess}:${window_name}"
  local codex_model
  codex_model="$(get_codex_model)"
  local codex_env
  codex_env="$(build_codex_env_prefix)"
  # codex CLI 설치 확인
  if ! command -v codex &>/dev/null; then
    echo "Warning: codex CLI가 설치되어 있지 않다. ${window_name} 부팅 건너뜀." >&2
    return 1
  fi

  echo "--- ${window_name} (codex interactive mode) 부팅 중 ---"

  local boot_msg
  boot_msg="$(build_boot_message "$role" "$project" "$extra_boot_msg" "$agent_id")"

  tmux new-window -d -t "$sess" -n "$window_name"
  tmux send-keys -t "$tmux_target" \
    "cd $(printf '%q' "$REPO_ROOT") && ${codex_env} codex --no-alt-screen --dangerously-bypass-approvals-and-sandbox" Enter
  sleep 4
  local prompt_ok=0
  local attempt
  for attempt in 1 2 3 4 5; do
    if send_codex_prompt_tmux "$tmux_target" "$boot_msg"; then
      prompt_ok=1
      break
    fi
    sleep 2
  done
  if [ "$prompt_ok" -ne 1 ]; then
    echo "Warning: ${window_name} codex TUI 온보딩 프롬프트 전달 실패." >&2
    tmux kill-window -t "$tmux_target" 2>/dev/null || true
    return 1
  fi
  add_session_row "$project" "$role" "codex-interactive" "$tmux_target" "$codex_model" "codex"
  python3 "$TOOLS_DIR/log.py" system "$project" orchestrator codex_boot "$window_name" --detail tmux="$tmux_target" mode="codex-interactive" || true
  echo "${window_name} 부팅 완료: tmux=${tmux_target} (codex interactive mode)"
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
  if [ "$exec_mode" = "dual" ] && { [ "$role" = "researcher" ] || [ "$role" = "developer" ]; }; then
    create_agent_worktree "$project" "$window_name" || true
  fi

  # 부팅 (동일한 프로젝트 맥락, 메모리 공유)
  local spawn_note="
참고: 너는 동적으로 스폰된 추가 에이전트다 (${window_name}).
같은 프로젝트의 메모리와 workspace를 공유한다. 같은 파일 동시 수정은 금지.
${extra_msg}"
  if [ "$backend" = "codex" ]; then
    boot_codex_agent "$role" "$project" "$window_name" "$spawn_note" || {
      echo "Error: ${window_name} 스폰 실패." >&2
      exit 1
    }
  else
    boot_single_agent "$role" "$project" "$spawn_note" "$window_name" || {
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
# boot-manager 서브커맨드
# ──────────────────────────────────────────────

cmd_boot_manager() {
  local project="$1"
  validate_project_name "$project"

  # Preflight 검증
  bash "$TOOLS_DIR/preflight.sh" "$project" || exit 1

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

  # 2. tmux 세션 + dashboard 먼저 생성 (부팅 과정을 실시간으로 볼 수 있도록)
  tmux new-session -d -s "$sess" -n "dashboard"
  # activity로 인한 자동 윈도우 전환 방지
  tmux set-option -t "$sess" activity-action none
  tmux set-option -t "$sess" visual-activity off
  # 상태바 시각적 구분: 윈도우 간 구분자 + 현재 윈도우 강조
  tmux set-option -t "$sess" window-status-separator "  "
  tmux set-option -t "$sess" window-status-format " #I:#W "
  tmux set-option -t "$sess" window-status-current-format " [#I:#W] "
  tmux set-option -t "$sess" status-style "bg=black,fg=white"
  tmux set-option -t "$sess" window-status-current-style "bg=blue,fg=white,bold"
  tmux send-keys -t "${sess}:dashboard" \
    "python3 \"$REPO_ROOT/dashboard/dashboard.py\" \"$project\" --interval 3" Enter

  echo ""
  echo "╔══════════════════════════════════════════════╗"
  echo "║  Dashboard 준비 완료                        ║"
  echo "║  tmux attach -t $sess 로 실시간 모니터링    ║"
  echo "╚══════════════════════════════════════════════╝"
  echo ""
  echo "Manager 세션 생성 중..."

  local msg_log="$(project_dir "$project")/logs/message.log"
  local start_lines=0
  if [ -f "$msg_log" ]; then
    start_lines=$(wc -l < "$msg_log")
  fi

  # 3. Manager 부팅
  local manager_backend
  manager_backend="$(get_manager_backend)"
  if [ "$manager_backend" = "codex" ]; then
    boot_codex_agent "manager" "$project" "manager" || {
      echo "Error: Manager codex 부팅 실패." >&2
      exit 1
    }
  else
    local model
    model="$(get_model "manager")"
    local mgr_tools
    mgr_tools="$(get_allowed_tools "manager")"
    local bootstrap_msg
    bootstrap_msg=$'너는 Whiplash manager 세션의 bootstrap 단계다.\n지금은 session_id만 만들기 위한 초기 호출이다.\n도구를 사용하지 말고, 파일도 읽지 말고, 명령도 실행하지 말고, 한 줄로 READY만 답해라.'
    local boot_msg
    boot_msg="$(build_boot_message "manager" "$project")"

    # env -u CLAUDECODE: Claude Code 안에서 호출할 때 중첩 세션 에러 방지
    local mgr_tools_flag=""
    [ -n "$mgr_tools" ] && mgr_tools_flag="--allowedTools $mgr_tools"
    local result
    result=$(env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT claude -p "$bootstrap_msg" \
      --model "$model" \
      --output-format json \
      --dangerously-skip-permissions $mgr_tools_flag) || {
      echo "Error: Manager claude -p 실행 실패." >&2
      exit 1
    }

    local session_id
    session_id=$(echo "$result" | jq -r '.session_id' 2>/dev/null) || session_id=""

    if [ -z "$session_id" ] || [ "$session_id" = "null" ]; then
      echo "Error: Manager session_id 획득 실패." >&2
      exit 1
    fi

    # 4. Manager tmux 윈도우 생성 + 투입
    tmux new-window -d -t "$sess" -n manager
    local tmux_target="${sess}:manager"
    local mgr_resume_flag=""
    [ -n "$mgr_tools" ] && mgr_resume_flag=" --allowedTools $mgr_tools"
    tmux send-keys -t "$tmux_target" "env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT claude --resume $session_id --dangerously-skip-permissions${mgr_resume_flag}" Enter

    local boot_pane_pid
    boot_pane_pid=$(tmux list-panes -t "$tmux_target" -F '#{pane_pid}' 2>/dev/null | head -1)
    if [ -n "$boot_pane_pid" ]; then
      local i
      for i in $(seq 1 10); do
        pgrep -P "$boot_pane_pid" claude >/dev/null 2>&1 && break
        sleep 1
      done
    fi
    if [ -z "$boot_pane_pid" ] || ! pgrep -P "$boot_pane_pid" claude >/dev/null 2>&1; then
      echo "Error: Manager claude --resume 프로세스 시작 실패." >&2
      exit 1
    fi

    # 5. sessions.md에 기록 (dashboard가 바로 반영)
    add_session_row "$project" "manager" "$session_id" "$tmux_target" "$model"
    python3 "$TOOLS_DIR/log.py" system "$project" orchestrator manager_boot manager --detail session="$session_id" || true

    local prompt_ok=0
    local attempt
    for attempt in 1 2 3 4 5; do
      if tmux_submit_pasted_payload "$tmux_target" "$boot_msg" "manager-boot"; then
        prompt_ok=1
        break
      fi
      sleep 2
    done
    if [ "$prompt_ok" -ne 1 ]; then
      echo "Error: Manager 온보딩 프롬프트 전달 실패." >&2
      exit 1
    fi
  fi

  # 6. 매니저 온보딩 완료 대기 후 에이전트 부팅
  echo "Manager 온보딩 대기 중..."
  while ! tail -n +"$((start_lines + 1))" "$msg_log" 2>/dev/null | grep -q '\[delivered\] manager → manager agent_ready normal "온보딩 완료"'; do
    sleep 2
  done
  echo "Manager 온보딩 완료 확인"

  # 7. 나머지 에이전트 부팅 (매니저 대신 orchestrator가 순서 보장)
  bash "$TOOLS_DIR/cmd.sh" boot "$project"

  # 8. 매니저에게 팀 준비 완료 알림 → 태스크 분배 시작 트리거
  bash "$TOOLS_DIR/message.sh" "$project" orchestrator manager status_update normal \
    "팀 부팅 완료" \
    "모든 에이전트 부팅이 완료되었다. agent_ready 메시지를 확인하고, project.md의 목표를 분석하여 첫 태스크를 분배해라. techniques/task-distribution.md 절차를 따른다." \
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

  # Preflight 검증
  bash "$TOOLS_DIR/preflight.sh" "$project" --mode "$exec_mode" || exit 1

  local sess
  sess="$(session_name "$project")"

  echo "=== ${project} 프로젝트 부팅 (mode: ${exec_mode}) ==="
  python3 "$TOOLS_DIR/log.py" system "$project" orchestrator project_boot_start "$project" --detail mode="$exec_mode" || true

  # 1. sessions.md 초기화 (멱등 — boot-manager에서 이미 생성했으면 건너뜀)
  init_sessions_file "$project"

  # 2. tmux 세션 생성 또는 기존 재사용
  if tmux has-session -t "$sess" 2>/dev/null; then
    echo "기존 tmux 세션 '$sess' 재사용 (boot-manager로 생성됨)"
  else
    tmux new-session -d -s "$sess" -n manager
    echo "tmux 세션 '$sess' 생성됨"
  fi

  # 3. 각 에이전트 부팅 (manager가 이 명령을 호출하므로 manager는 이미 준비됨)
  local agents
  agents="$(get_active_agents "$project")"

  if [ -z "$agents" ]; then
    echo "Error: project.md에서 활성 에이전트를 찾을 수 없다." >&2
    exit 1
  fi

  for role in $agents; do
    # manager는 이미 부팅됨
    if [ "$role" = "manager" ]; then
      continue
    fi

    if [ "$exec_mode" = "dual" ] && [ "$role" != "monitoring" ]; then
      # dual 모드: worktree 생성 + claude + codex 양쪽 부팅 (monitoring은 solo)
      create_worktrees "$project" "$role"
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

  # 5. dashboard 윈도우 생성 (Rich Live TUI) — boot-manager에서 이미 만들었으면 건너뜀
  if ! tmux list-windows -t "$sess" -F '#{window_name}' 2>/dev/null | grep -q '^dashboard$'; then
    tmux new-window -d -t "$sess" -n "dashboard"
    tmux send-keys -t "${sess}:dashboard" \
      "python3 \"$REPO_ROOT/dashboard/dashboard.py\" \"$project\" --interval 3" Enter
    echo "dashboard 윈도우 생성됨"
  else
    echo "dashboard 윈도우 이미 존재 — 건너뜀"
  fi

  # 6. monitor.sh 백그라운드 실행 (자동 재시작 wrapper)
  # 기존 좀비 monitor 정리
  pkill -f "monitor\\.sh[[:space:]]+${project}$" 2>/dev/null || true
  runtime_release_manager_lock "$project" || true
  sleep 1  # lock 파일 해제 대기
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
  validate_project_name "$project"

  # stale 정리
  expire_stale_assignments "$project"

  # 태스크 파일이면 기존 방식 메시지, 아니면 인라인
  local msg subject
  if [ -f "$task" ]; then
    subject="$task"
    msg="${task} 파일에 새 작업 지시가 있다. 읽고 실행해라."
  else
    subject="$task"
    msg="$task"
  fi

  # message.sh로 전달 (interactive submit, 큐잉, 프로세스 체크 전부 활용)
  # 태스크 할당 기록은 message.sh가 kind=task_assign 시 자동 처리 (INS-003)
  bash "$TOOLS_DIR/message.sh" "$project" "manager" "$role" "task_assign" "normal" "$subject" "$msg"

  python3 "$TOOLS_DIR/log.py" system "$project" orchestrator task_dispatch "$role" \
    --detail task="$task" || true
  echo "dispatch 완료: ${role} ← ${task}"
}

# ──────────────────────────────────────────────
# dual-dispatch 서브커맨드
# ──────────────────────────────────────────────

cmd_dual_dispatch() {
  local role="$1"
  local task="$2"       # 태스크 파일 경로 OR 인라인 텍스트
  local project="$3"
  validate_project_name "$project"

  # stale 정리
  expire_stale_assignments "$project"

  local claude_win="${role}-claude"
  local codex_win="${role}-codex"

  local msg subject
  if [ -f "$task" ]; then
    subject="$task"
    msg="${task} 파일에 새 작업 지시가 있다. 읽고 실행해라."
  else
    subject="$task"
    msg="$task"
  fi

  # 양쪽 전달 (message.sh가 interactive submit/큐잉 전부 처리)
  # 태스크 할당 기록은 message.sh가 kind=task_assign 시 자동 처리 (INS-003)
  bash "$TOOLS_DIR/message.sh" "$project" "manager" "$claude_win" "task_assign" "normal" "$subject" "$msg"
  bash "$TOOLS_DIR/message.sh" "$project" "manager" "$codex_win" "task_assign" "normal" "$subject" "$msg"

  local normalized_task claude_report_rel codex_report_rel
  normalized_task="$(normalize_task_ref "$project" "$subject")"
  claude_report_rel="$(runtime_project_relative_path "$project" "$(runtime_task_report_path "$project" "$normalized_task" "$claude_win")")"
  codex_report_rel="$(runtime_project_relative_path "$project" "$(runtime_task_report_path "$project" "$normalized_task" "$codex_win")")"
  runtime_write_dual_synthesis_report_stub "$project" "$normalized_task" "$claude_report_rel" "$codex_report_rel" >/dev/null

  python3 "$TOOLS_DIR/log.py" system "$project" orchestrator dual_dispatch "$role" \
    --detail task="$task" || true
  echo "dual-dispatch 완료: ${role} (claude + codex) ← ${task}"
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
  if tmux list-windows -t "$sess" -F '#{window_name}' 2>/dev/null | grep -q "^${window_name}$"; then
    echo "기존 ${window_name} 윈도우 종료 중..."
    tmux send-keys -t "${sess}:${window_name}" "/exit" Enter 2>/dev/null || true
    sleep 2
    tmux kill-window -t "${sess}:${window_name}" 2>/dev/null || true
  fi

  # 2. sessions.md에서 이전 행을 crashed로 표시
  mark_session_status "$project" "$role" "active" "crashed" "$backend"

  # 3. 중단된 태스크 조회
  local pending_task
  pending_task="$(get_active_task "$project" "$window_name")" || pending_task=""

  # 4. backend에 따라 적절한 부팅 함수 호출
  if [ "$backend" = "codex" ]; then
    boot_codex_agent "$role" "$project" "$window_name" || {
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
  local now pid hb_time
  now=$(date +%s)

  # PID 파일 확인
  pid="$(runtime_get_manager_state "$project" "monitor_pid" "" 2>/dev/null || true)"
  if [ -z "$pid" ]; then
    echo "[monitor-check] PID 파일 없음. monitor.sh 재시작 중..."
    restart_monitor "$project"
    return
  fi

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
      kill "$pid" 2>/dev/null || true
      sleep 1
      restart_monitor "$project"
      return
    fi
    echo "[monitor-check] monitor.sh 정상 (PID: $pid, heartbeat: ${hb_age}초 전)"
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
  runtime_release_manager_lock "$project" || true

  # 5. sessions.md 업데이트
  close_all_sessions "$project"

  # 6. 런타임 파일 정리 (reboot 카운터, heartbeat, 메시지 큐, reboot lock)
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
  ensure_manager_runtime_layout "$project"
  local pid hb_time
  pid="$(runtime_get_manager_state "$project" "monitor_pid" "" 2>/dev/null || true)"
  if [ -n "$pid" ]; then
    if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
      echo "[monitor] PID 상태값이 잘못됨: '$pid'"
    elif kill -0 "$pid" 2>/dev/null; then
      hb_time="$(runtime_get_manager_state "$project" "monitor_heartbeat" "" 2>/dev/null || true)"
      if [ -n "$hb_time" ]; then
        if [[ "$hb_time" =~ ^[0-9]+$ ]]; then
          local hb_age=$((now - hb_time))
          if [ "$hb_age" -gt 90 ]; then
            echo "[monitor] 실행 중 (PID: $pid) -- WARNING: heartbeat ${hb_age}초 전 (좀비 가능성)"
          else
            echo "[monitor] 실행 중 (PID: $pid, heartbeat: ${hb_age}초 전)"
          fi
        else
          echo "[monitor] 실행 중 (PID: $pid, heartbeat 상태값이 잘못됨)"
        fi
      else
        echo "[monitor] 실행 중 (PID: $pid, heartbeat 없음)"
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
  boot-manager)
    [ $# -lt 1 ] && { echo "Usage: cmd.sh boot-manager {project}" >&2; exit 1; }
    cmd_boot_manager "$1"
    ;;
  boot)
    [ $# -lt 1 ] && { echo "Usage: cmd.sh boot {project}" >&2; exit 1; }
    cmd_boot "$1"
    ;;
  dispatch)
    [ $# -lt 3 ] && { echo "Usage: cmd.sh dispatch {role} {task-file} {project}" >&2; exit 1; }
    cmd_dispatch "$1" "$2" "$3"
    ;;
  dual-dispatch)
    [ $# -lt 3 ] && { echo "Usage: cmd.sh dual-dispatch {role} {task-file} {project}" >&2; exit 1; }
    cmd_dual_dispatch "$1" "$2" "$3"
    ;;
  spawn)
    [ $# -lt 3 ] && { echo "Usage: cmd.sh spawn {role} {window-name} {project} [extra-msg]" >&2; exit 1; }
    cmd_spawn "$1" "$2" "$3" "${4:-}"
    ;;
  kill-agent)
    [ $# -lt 2 ] && { echo "Usage: cmd.sh kill-agent {window-name} {project}" >&2; exit 1; }
    cmd_kill_agent "$1" "$2"
    ;;
  shutdown)
    [ $# -lt 1 ] && { echo "Usage: cmd.sh shutdown {project}" >&2; exit 1; }
    cmd_shutdown "$1"
    ;;
  status)
    [ $# -lt 1 ] && { echo "Usage: cmd.sh status {project}" >&2; exit 1; }
    cmd_status "$1"
    ;;
  reboot)
    [ $# -lt 2 ] && { echo "Usage: cmd.sh reboot {target} {project}" >&2; exit 1; }
    cmd_reboot "$1" "$2"
    ;;
  refresh)
    [ $# -lt 2 ] && { echo "Usage: cmd.sh refresh {target} {project}" >&2; exit 1; }
    cmd_refresh "$1" "$2"
    ;;
  merge-worktree)
    [ $# -lt 3 ] && { echo "Usage: cmd.sh merge-worktree {role} {winner} {project}" >&2; exit 1; }
    cmd_merge_worktree "$1" "$2" "$3"
    ;;
  monitor-check)
    [ $# -lt 1 ] && { echo "Usage: cmd.sh monitor-check {project}" >&2; exit 1; }
    cmd_monitor_check "$1"
    ;;
  complete)
    [ $# -lt 2 ] && { echo "Usage: cmd.sh complete {agent} {project}" >&2; exit 1; }
    cmd_complete "$1" "$2"
    ;;
  expire-stale)
    [ $# -lt 1 ] && { echo "Usage: cmd.sh expire-stale {project} [max-hours]" >&2; exit 1; }
    expire_stale_assignments "$1" "${2:-4}"
    ;;
  assign)
    [ $# -lt 3 ] && { echo "Usage: cmd.sh assign {agent} {task} {project}" >&2; exit 1; }
    cmd_assign "$1" "$2" "$3"
    ;;
  *)
    echo "Unknown command: $command" >&2
    echo "Available: boot-manager, boot, dispatch, dual-dispatch, assign, spawn, kill-agent, shutdown, status, reboot, refresh, merge-worktree, monitor-check, complete, expire-stale" >&2
    exit 1
    ;;
esac
