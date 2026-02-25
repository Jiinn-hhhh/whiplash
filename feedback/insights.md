# 프레임워크 개선 인사이트

| # | 날짜 | 발견자 | 카테고리 | 상태 | 요약 |
|---|------|--------|---------|------|------|
| 1 | 2026-02-25 | E2E 테스트 | 도구 | implemented | `--resume` 세션이 `--allowedTools` 미계승 → `--dangerously-skip-permissions`로 우회 |
| 2 | 2026-02-25 | E2E 테스트 | 도구 | implemented | `claude -p` 중첩 실행이 Bash tool 내에서 불안정 → tmux 내부 실행으로 우회 |
| 3 | 2026-02-25 | E2E 테스트 | 절차 | validated | Manager `--resume` 세션에서 자율 루프(알림 수신→태스크 디스패치) 동작 안 함 |
| 4 | 2026-02-25 | E2E 테스트 | 절차 | validated | Dual 모드가 실제 E2E 검증된 적 없음. Codex CLI 호환성 미확인 |
| 5 | 2026-02-25 | E2E 테스트 | 도구 | validated | Monitoring(haiku) 10턴 제한 + 매 Bash 명령 권한 승인 = 실효성 저하 |
| 6 | 2026-02-25 | E2E 테스트 | 도구 | implemented | tmux send-keys 긴 텍스트 후 별도 Enter 추가 필요 |

## INS-001: `--resume` 세션의 CLI 플래그 미계승

- **발견 상황**: E2E 테스트에서 모든 에이전트의 `--resume` 세션이 `--allowedTools` 설정을 무시하여 매번 권한 승인 필요
- **현재 동작**: `claude --resume {id}`는 초기 `claude -p`에서 설정한 `--allowedTools`, `--max-turns` 등을 계승하지 않음
- **조치**: `--dangerously-skip-permissions` 플래그 추가로 우회 (implemented)
- **영향 범위**: orchestrator.sh `boot_single_agent()`, `cmd_boot_manager()`

## INS-002: `claude -p` 중첩 실행 불안정

- **발견 상황**: Claude Code 세션 안에서 `orchestrator.sh boot-manager` 실행 시 내부 `claude -p` 실패
- **현재 동작**: `env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT` 우회를 사용해도 Bash tool 내에서 불안정
- **조치**: tmux 세션을 먼저 생성 후 tmux 내부에서 `claude -p` 실행으로 우회
- **영향 범위**: orchestrator.sh 전체 부팅 흐름

## INS-003: Manager 자율 루프 부재

- **발견 상황**: Manager의 `--resume` 인터랙티브 세션은 수동 입력을 대기할 뿐, 알림을 수신하여 자동으로 다음 태스크를 디스패치하지 못함
- **현재 동작**: notify.sh가 tmux에 알림을 전달하면 텍스트로 표시되지만, Manager가 이를 트리거로 인식하여 행동하지 않음
- **제안**: Manager 부팅 메시지에 "주기적으로 알림을 확인하라"는 지시 추가, 또는 `-p` 모드에서 전체 작업을 완료하도록 `--max-turns`을 충분히 높임
- **영향 범위**: Manager 운영 전반

## INS-004: Dual 모드 미검증

- **발견 상황**: Dual 모드(Claude Code + Codex CLI) 코드가 orchestrator.sh에 존재하지만 실제 E2E 테스트된 적 없음
- **현재 동작**: `--allowedTools`, `--resume` 등 Codex CLI가 지원하지 않는 기능에 의존
- **조치**: orchestration.md, README, project-design.md에 "(실험적)" 표기 추가 (implemented)
- **영향 범위**: Dual 모드 전체 (orchestration.md §6, §14)

## INS-005: Monitoring 에이전트 실효성

- **발견 상황**: Monitoring(haiku)의 10턴 제한과 매 Bash 명령 권한 승인이 결합되면 거의 작업 불가
- **현재 동작**: `--dangerously-skip-permissions` 추가로 권한 문제는 해소되었지만, haiku의 10턴으로 복잡한 시스템 점검은 여전히 제약
- **제안**: Monitoring max-turns 상향 검토 (15~20턴), 또는 점검 스크립트를 tools/에 사전 작성
- **영향 범위**: agents/monitoring/, orchestrator.sh `get_max_turns()`
