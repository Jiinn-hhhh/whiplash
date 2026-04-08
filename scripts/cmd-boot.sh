# cmd-boot.sh -- 부팅 관련 함수 (온보딩 레이아웃, 프롬프트 생성, 에이전트 부팅, 부팅 커맨드)
#
# cmd.sh에서 source된다. 단독 실행하지 않는다.
# 의존: cmd-utils.sh (먼저 source 필요)

# ──────────────────────────────────────────────
# 온보딩 프로젝트 레이아웃 / bootstrap
# ──────────────────────────────────────────────

ensure_onboarding_project_layout() {
  local project="$1"
  local base
  base="$(project_dir "$project")"

  mkdir -p \
    "$base/team" \
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
    "$base/runtime/message-queue" \
    "$base/runtime/message-locks" \
    "$base/runtime/manager" \
    "$base/logs" \
    "$base/reports"
}

write_onboarding_systems_engineer_team_md() {
  local project="$1"
  local team_md
  team_md="$(project_team_role_doc_path "$project" "systems-engineer")"

  cat > "$team_md" <<EOF
# ${project} — Systems Engineer 프로젝트 지침

이 파일은 \`agents/systems-engineer/profile.md\`를 보충한다.

## 이 프로젝트에서의 초점
- 시스템 변경 전마다 \`team/systems-engineer.md\`를 확인하고, 실제 표면과 근거를 최신 상태로 유지한다.

## 이 프로젝트에서의 제한
- 문서에 없는 원격 시스템 write는 금지다.
- 정책이 애매하거나 새로운 변경이 필요하면 Manager를 통해 사용자 합의를 받고, 이 문서와 \`change-authority.md\`를 먼저 갱신한다.

## 시스템 변경 권한
- 기본값: 명시되지 않은 원격 시스템 \`write/apply/restart/deploy/data change\`는 금지
- Ralph 자율 실행: 미정 (온보딩 시 프로젝트별로 확정)
- 판단 순서:
  1. 이 표의 환경별 정책 확인
  2. \`team/systems-engineer.md\`의 실제 표면/근거 확인
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
  authority_md="$(project_se_team_md_path "$project")"

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
- **실행 프리셋**: pending
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
- **시스템 변경 권한**: 기본 금지. 상세는 team/systems-engineer.md 와 team/systems-engineer.md 참고

## 팀 구성
- **활성 에이전트**: 미정
  - \`manager\`는 control-plane 역할이라 bootstrap 이후 자동 부팅된다.
- **커스터마이징**: 기본

## 현재 상태
Onboarding 시작 전 bootstrap 초안. boot-onboarding이 생성했으며, onboarding 과정에서 갱신된다.
EOF
}

ensure_onboarding_project_bootstrap() {
  local project="$1"
  local base project_md team_systems_md change_authority_md
  base="$(project_dir "$project")"
  project_md="${base}/project.md"
  team_systems_md="$(project_team_role_doc_path "$project" "systems-engineer")"
  change_authority_md="$(project_se_team_md_path "$project")"

  ensure_onboarding_project_layout "$project"

  if [ ! -f "$project_md" ]; then
    write_onboarding_bootstrap_project_md "$project"
  fi

  if [ ! -f "$team_systems_md" ]; then
    write_onboarding_systems_engineer_team_md "$project"
  fi

  if [ ! -f "$change_authority_md" ]; then
    write_onboarding_change_authority_md "$project"
  fi
}

# ──────────────────────────────────────────────
# 부팅 메시지 생성
# ──────────────────────────────────────────────

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

  if [ -z "$ready_target" ] && { [ "$role" = "manager" ] || [ "$role" = "onboarding" ]; }; then
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
- user 개입이 와도 전체 루프를 pause 하지 말고 반영한 뒤 해당 레인만 재계획해라.
- 종료 방식: ${ralph_completion_mode}. stop-on-criteria면 project.md의 랄프 완료 기준을 만족할 때 끝내고, continue-until-no-improvement면 완료 기준 충족 후에도 개선 loop를 계속 돌려라.
BOOTRULES
)"
  elif [ "$loop_mode" = "ralph" ]; then
    loop_mode_note="$(cat <<BOOTRULES
[Ralph loop 규칙]
- 현재 프로젝트의 작업 루프는 ralph 다.
- user 확인을 기다리며 멈추지 마라. 필요한 판단은 manager에게 올리고, user-facing 알림은 manager가 user_notice로 처리한다.
- 블로커를 만나면 manager에게 이유와 fallback/options를 짧게 알리고, 가능한 대체 경로로 계속 진행해라.
- user의 새 방향 입력은 pause 신호가 아니라 async 업데이트다. manager의 새 지시가 오면 그 방향으로 흡수해라.
- 종료는 manager가 project.md의 랄프 정책을 만족했다고 판단할 때만 선언한다.
BOOTRULES
)"
  fi

  if [ "$role" = "systems-engineer" ]; then
    mutation_safety_note="$(cat <<BOOTRULES
15. 외부 반영 안전 규칙:
    - 로컬 파일 수정, 테스트, 빌드, 로컬 git commit은 가능하다.
    - 원격 시스템 변경 전에는 projects/${project}/team/systems-engineer.md 와 projects/${project}/team/systems-engineer.md 를 다시 읽어라.
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
4. memory/${role}/ 읽기 (이전 세션 메모 확인)
5. 해당 작업에 필요한 agents/${role}/techniques/*.md 읽기
${layer2_domain_line}

[Layer 3 — 필요할 때만 읽기]
7. agents/common/project-context.md (경로 해석 등 필요 시)
${layer3_domain_line}
9. (해당 시) projects/${project}/team/${role}.md

10. 태스크 완료 시 핵심 메모를 memory/${role}/에 남겨라 (어떤 파일을 왜 고쳤는지, 주의할 점, 다음에 이어할 때 알아야 할 것).

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

# ──────────────────────────────────────────────
# 에이전트 부팅 함수
# ──────────────────────────────────────────────

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
  model="$(resolve_role_model "$project" "$role" "claude")"
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
    --dangerously-skip-permissions $tools_flag </dev/null) || {
    echo "Warning: ${window_name} claude -p 실행 실패." >&2
    python3 "$TOOLS_DIR/log.py" system "$project" orchestrator agent_boot_fail "$window_name" --detail reason="claude -p 실행 실패" || true
    return 1
  }

  local session_id
  session_id=$(echo "$result" | jq -r '.session_id' 2>/dev/null) || session_id=""

  # 부팅 토큰 사용량 로깅
  local usage_input usage_output
  usage_input=$(echo "$result" | jq -r '.usage.input_tokens // 0' 2>/dev/null) || usage_input=0
  usage_output=$(echo "$result" | jq -r '.usage.output_tokens // 0' 2>/dev/null) || usage_output=0
  if [ "$usage_input" != "0" ] || [ "$usage_output" != "0" ]; then
    python3 "$TOOLS_DIR/log.py" system "$project" orchestrator agent_bootstrap_tokens \
      "$window_name" --detail input_tokens="$usage_input" output_tokens="$usage_output" model="$model" || true
  fi

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
  fi

  # TUI 초기화 대기: 프로세스 감지 직후 paste를 보내면 바이너리가 아직
  # bracketed paste / raw mode를 설정하지 못해 전달 실패할 수 있다.
  sleep 2

  # boot_msg 전송: paste → 실패 시 submit_tmux_prompt_when_ready fallback (이중 전송 방지)
  local prompt_ok=0
  for i in 1 2 3 4 5; do
    if tmux_submit_pasted_payload "$tmux_target" "$boot_msg" "${window_name}-boot"; then
      prompt_ok=1
      break
    fi
    sleep 2
  done
  if [ "$prompt_ok" -ne 1 ]; then
    # paste 실패 → submit_tmux_prompt_when_ready로 fallback
    if ! submit_tmux_prompt_when_ready "$tmux_target" "$boot_msg" "${window_name}-boot"; then
      echo "Warning: ${window_name} 온보딩 프롬프트 전달 실패." >&2
      kill_windows_by_name "$sess" "$window_name"
      python3 "$TOOLS_DIR/log.py" system "$project" orchestrator agent_boot_fail "$window_name" --detail reason="온보딩 프롬프트 전달 실패" || true
      return 1
    fi
  fi
  if [ -n "$pending_task" ] && ! wait_for_visible_task_prompt "$tmux_target" "$pending_task" 4 1; then
    if ! submit_tmux_prompt_when_ready "$tmux_target" "$boot_msg" "${window_name}-boot-redeliver" 4 20 1; then
      echo "Warning: ${window_name} task prompt 재전달 실패." >&2
      kill_windows_by_name "$sess" "$window_name"
      python3 "$TOOLS_DIR/log.py" system "$project" orchestrator agent_boot_fail "$window_name" --detail reason="task prompt 재전달 실패" || true
      return 1
    fi
    send_task_visibility_reminder "$tmux_target" "$pending_task" "${window_name}-task-reminder" || true
  fi

  # sessions.md는 boot prompt 전달 성공 후에만 기록 (2-A: phantom active 방지)
  add_session_row "$project" "$role" "$session_id" "$tmux_target" "$model" "claude"

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
  codex_model="$(resolve_role_model "$project" "$role" "codex")"
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
  # codex 프로세스 시작 대기 + 검증 (2-B)
  local codex_boot_pane_pid codex_boot_attempt
  codex_boot_pane_pid=$(tmux list-panes -t "$tmux_target" -F '#{pane_pid}' 2>/dev/null | head -1)
  if [ -n "$codex_boot_pane_pid" ]; then
    for codex_boot_attempt in $(seq 1 8); do
      process_or_child_named "$codex_boot_pane_pid" "codex" && break
      sleep 1
    done
    if ! process_or_child_named "$codex_boot_pane_pid" "codex"; then
      echo "Warning: ${window_name} codex 프로세스 8초 내 미시작." >&2
      python3 "$TOOLS_DIR/log.py" system "$project" orchestrator agent_boot_fail "$window_name" --detail reason="codex 프로세스 미시작" || true
      tmux kill-window -t "$tmux_target" 2>/dev/null || true
      return 1
    fi
  fi
  sleep 1
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

boot_manager_window() {
  local project="$1"
  local extra_boot_msg="${2:-}"
  local manager_backend
  manager_backend="$(resolve_role_backend "$project" "manager")"
  boot_agent_with_backend "manager" "$project" "manager" "$manager_backend" "$extra_boot_msg" "" "user" || {
    echo "Error: Manager 부팅 실패." >&2
    return 1
  }

  return 0
}

boot_onboarding_window() {
  local project="$1"
  local extra_boot_msg="${2:-}"
  local backend
  backend="$(resolve_role_backend "$project" "onboarding")"
  boot_agent_with_backend "onboarding" "$project" "onboarding" "$backend" "$extra_boot_msg" "" "user" || {
    echo "Error: Onboarding 부팅 실패." >&2
    return 1
  }
  return 0
}

build_onboarding_analysis_note() {
  local project="$1"
  cat <<EOF

[Onboarding — Entry Branch]
- 먼저 projects/ 디렉토리를 확인해라.
- 기존 프로젝트가 있으면 목록을 보여주며 유저에게 물어라: "기존 프로젝트를 이어할까, 새 프로젝트를 시작할까?"
- 유저가 기존 프로젝트를 선택하면 해당 project.md를 읽고 이어가라. 새 프로젝트를 선택하면 아래 설계 절차를 진행해라.

[Onboarding — 프로젝트 설계]
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

# ──────────────────────────────────────────────
# spawn / kill-agent 서브커맨드
# ──────────────────────────────────────────────

normalize_spawn_role() {
  local role="$1"
  case "$role" in
    researcher|researcher-claude|researcher-codex) echo "researcher" ;;
    developer|developer-claude|developer-codex) echo "developer" ;;
    systems-engineer|systems-engineer-claude|systems-engineer-codex) echo "systems-engineer" ;;
    monitoring|monitoring-claude|monitoring-codex) echo "monitoring" ;;
    manager|manager-claude|manager-codex) echo "manager" ;;
    discussion|discussion-claude|discussion-codex) echo "discussion" ;; # legacy, 더이상 부팅하지 않음
    *)
      echo "Error: 지원하지 않는 spawn role: '$role'" >&2
      exit 1
      ;;
  esac
}

resolve_spawn_backend() {
  local requested_role="$1"
  local window_name="$2"
  local project="${3:-}"
  local canonical_role="${4:-}"

  case "$requested_role" in
    *-codex) echo "codex"; return ;;
    *-claude) echo "claude"; return ;;
  esac

  case "$window_name" in
    *codex*) echo "codex"; return ;;
    *claude*) echo "claude"; return ;;
  esac

  if [ -n "$project" ] && [ -n "$canonical_role" ]; then
    resolve_role_backend "$project" "$canonical_role"
    return 0
  fi

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
  backend="$(resolve_spawn_backend "$requested_role" "$window_name" "$project" "$role")"
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
  boot_agent_with_backend "$role" "$project" "$window_name" "$backend" "$spawn_note" "" "$ready_target_override" || {
    echo "Error: ${window_name} 스폰 실패." >&2
    exit 1
  }
  python3 "$TOOLS_DIR/log.py" system "$project" orchestrator agent_spawn "$window_name" --detail role="$role" backend="$backend" || true
  echo "=== ${window_name} 스폰 완료 ==="
}

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
# boot-onboarding / handoff / boot-manager / boot 서브커맨드
# ──────────────────────────────────────────────

cmd_boot_onboarding() {
  local project="$1"
  validate_project_name "$project"
  ensure_onboarding_project_bootstrap "$project"
  local exec_mode
  exec_mode="$(get_exec_mode "$project")"

  WHIPLASH_PREFLIGHT_INCLUDE_ONBOARDING=1 \
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
  runtime_set_manager_state "$project" "project_booting" "$(date +%s)"
  python3 "$TOOLS_DIR/log.py" system "$project" orchestrator project_boot_start "$project" --detail mode="$exec_mode" loop="$loop_mode" || true

  # 1. sessions.md 초기화 + 이전 세션 잔재 정리
  init_sessions_file "$project"
  prune_inactive_sessions "$project"
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

  local failed_agents=""

  for role in $agents; do
    # manager는 control-plane 역할로 별도 처리됨
    if [ "$role" = "manager" ]; then
      continue
    fi

    if role_runs_dual_now "$project" "$role"; then
      create_worktrees "$project" "$role"
    elif [ "$loop_mode" = "ralph" ] && role_uses_ralph_worktree "$role"; then
      create_ralph_worktree "$project" "$role" || true
    fi

    while IFS='|' read -r window_name backend _model; do
      [ -n "$window_name" ] || continue
      local pending_task=""
      pending_task="$(resume_pending_task_for_window "$project" "$role" "$window_name")" || pending_task=""
      boot_agent_with_backend "$role" "$project" "$window_name" "$backend" "" "$pending_task" || {
        echo "Warning: ${window_name} 부팅 실패. 건너뜀." >&2
        failed_agents="${failed_agents:+${failed_agents},}${window_name}"
      }
    done < <(role_window_plan_lines "$project" "$role")
  done

  # 4. post-boot liveness gate (2-C): 부팅 직후 모든 에이전트 최종 생존 확인
  sleep 3
  local check_windows win_name win_backend
  check_windows="$(tmux list-windows -t "$sess" -F '#{window_name}' 2>/dev/null || true)"
  while IFS= read -r win_name; do
    [ -n "$win_name" ] || continue
    case "$win_name" in
      manager|dashboard) continue ;;
    esac
    win_backend="$(resolve_window_backend "$project" "$win_name")"
    if ! agent_window_has_live_backend "$sess" "$win_name" "$win_backend" 2>/dev/null; then
      echo "Warning: post-boot check — ${win_name} 프로세스 사망 감지." >&2
      python3 "$TOOLS_DIR/log.py" system "$project" orchestrator post_boot_dead "$win_name" || true
      if [ -n "$failed_agents" ]; then
        # 중복 방지
        case ",$failed_agents," in *",$win_name,"*) ;; *) failed_agents="${failed_agents},${win_name}" ;; esac
      else
        failed_agents="$win_name"
      fi
    fi
  done <<< "$check_windows"

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
  " >>"$log_dir/monitor-wrapper.log" 2>&1 &
  local monitor_pid=$!
  runtime_set_manager_state "$project" "monitor_pid" "$monitor_pid"
  echo "monitor.sh 시작됨 (PID: $monitor_pid, 자동 재시작 wrapper)"
  python3 "$TOOLS_DIR/log.py" system "$project" orchestrator monitor_start monitor --detail pid="$monitor_pid" || true

  runtime_clear_manager_state "$project" "project_booting" || true
  python3 "$TOOLS_DIR/log.py" system "$project" orchestrator project_boot_end "$project" || true
  set_project_stage "$project" "active"
  echo "=== 부팅 완료 ==="
  echo "tmux attach -t $sess 로 세션에 접속하라."
}
