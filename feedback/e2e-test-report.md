# Whiplash 프레임워크 E2E 테스트 보고서

- **Date**: 2026-02-25
- **프로젝트**: framework-audit
- **테스터**: Claude Code (Onboarding + User 역할 겸임)
- **실행 모드**: solo

---

## 1. 테스트 개요

프레임워크의 전체 파이프라인을 처음으로 실행하여 검증했다:
- 프로젝트 생성 → Manager 부팅 → 팀 부팅 → 태스크 디스패치 → 에이전트 작업 → 결과 수집 → 종료

### 테스트 태스크 설계

```
[병렬] TASK-001 (researcher): 프레임워크 문서 완전성 감사
[병렬] TASK-002 (developer): 프레임워크 도구 코드 리뷰
[순차] TASK-003 (researcher): TASK-001+002 결과를 종합한 감사 보고서
       + monitoring: 시스템 상태 점검
```

### 소요 시간

| Phase | 예상 | 실제 | 비고 |
|-------|------|------|------|
| Phase 0: --max-budget-usd 제거 | 5분 | 3분 | 단순 편집 |
| Phase 1: 프로젝트 생성 | 2분 | 2분 | 정상 |
| Phase 2: Manager 부팅 | 3분 | 8분 | claude -p 중첩 세션 문제로 우회 필요 |
| Phase 3: 팀 부팅 | 5분 | 자동 | Manager가 22턴 안에 자동 완료 |
| Phase 4: 태스크 실행 | 15분 | 25분 | 권한 프롬프트 수동 승인 필요 |
| Phase 5: 결과 수집 | 5분 | 3분 | |
| Phase 6: 정리 & 보고서 | 5분 | 5분 | |
| **합계** | **35-40분** | **~46분** | 권한 승인 병목 |

---

## 2. 각 Phase 결과

### Phase 0: 사전 정리 ✅

`--max-budget-usd` 관련 코드/문서를 제거했다:
- `orchestrator.sh`: `get_budget()` 함수, `boot_single_agent()`, `cmd_boot_manager()`에서 `--max-budget-usd` 제거
- `orchestration.md`: §3 CLI 플래그에서 항목 제거, §8 비용 제한 섹션 제거, §13 호환성 매트릭스에서 행 제거
- 기타 파일에는 비용 관련 언급 없음 확인

### Phase 1: 프로젝트 생성 ✅

`project-design.md`의 디렉토리 생성 목록대로 정상 생성:
- `projects/framework-audit/` 전체 구조 (workspace, memory, reports)
- `project.md` 작성
- `memory/knowledge/index.md` 초기화

### Phase 2: Manager 부팅 ⚠️ (우회 필요)

**문제**: Claude Code 세션 안에서 `orchestrator.sh boot-manager`를 실행하면, 내부의 `claude -p` 호출이 실패한다.

**원인**: 현재 Claude Code → Bash tool → `claude -p` 경로에서, `env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT`를 사용해도 출력이 비어있거나 내부 에러가 발생한다. Bash tool 내에서의 자식 프로세스가 리소스 충돌을 일으키는 것으로 추정.

**우회**: tmux 세션을 먼저 수동으로 생성하고, tmux send-keys로 `claude -p`를 tmux 내부에서 실행. 이 방식은 현재 Claude Code 프로세스와 분리된 셸에서 실행되므로 성공.

**결과**: Manager가 22턴 동안 자동으로 온보딩 → 팀 부팅 → 태스크 분배까지 완료.

### Phase 3: 팀 부팅 ✅ (단, 3중 부팅 버그)

4개 tmux 윈도우 정상 생성: manager, researcher, developer, monitoring

**버그**: sessions.md에 각 에이전트가 **3행씩 중복 등록**됨. Manager의 `-p` 세션에서 `orchestrator.sh boot`가 3번 호출된 것으로 추정.
- 근본 원인: `add_session_row()`에 기존 active 행 존재 확인이 없음 (Developer가 O-01로 보고)

### Phase 4: 태스크 실행 ⚠️ (수동 개입 필요)

**디스패치 문제 1**: monitor.sh의 fswatch 감시자는 시작 전에 이미 `new/`에 있던 메시지를 처리하지 않는다. 초기 스위프 로직이 없어서, Manager가 보낸 디스패치 메시지가 에이전트에게 전달되지 않았다.

**디스패치 문제 2**: `tmux send-keys`로 보낸 긴 텍스트가 Claude Code 프롬프트에 표시되었지만 즉시 처리를 시작하지 않았다. 별도의 빈 Enter를 보내야 활성화됐다.

**디스패치 문제 3**: Manager의 순차 태스크 관리가 동작하지 않았다. Manager의 `--resume` 인터랙티브 세션은 수동 입력 대기 상태이므로, mailbox 알림을 자동으로 처리하여 TASK-003을 디스패치하지 못했다.

**권한 문제**: `--resume`으로 시작한 인터랙티브 세션이 `--allowedTools` 설정을 계승하지 않는다. 모든 에이전트가 Bash 명령(mkdir, sysctl, top, ps)과 파일 쓰기에 대해 매번 권한 승인을 요구했다. 이것이 **가장 큰 블로커**였다.

**결과**: 수동 개입(Enter 전송, 권한 승인)을 통해 모든 태스크가 결국 완료됨:
- TASK-001: `audit-findings.md` (10.3KB) ✅
- TASK-002: `tools-audit.md` (16.6KB) ✅
- Monitoring: `system-health.md` (3.5KB) ✅
- TASK-003: `framework-audit-report.md` (10.4KB) ✅

### Phase 5: 결과 수집 ✅

모든 산출물이 의도한 위치에 생성됨. 에이전트별 mailbox 메시지도 정상 전송됨.

### Phase 6: 정리 ✅

`orchestrator.sh shutdown` 정상 동작. tmux 세션 종료, monitor.sh 종료, sessions.md 갱신 완료.

---

## 3. 발견된 버그 (E2E 관찰 기반)

### Critical

| # | 제목 | 심각도 | 재현 가능 |
|---|------|--------|-----------|
| E-01 | `--resume` 세션이 `--allowedTools` 계승 안 함 | Critical | 항상 |
| E-02 | sessions.md 3중 등록 | Critical | boot 재실행 시 |

### High

| # | 제목 | 심각도 | 재현 가능 |
|---|------|--------|-----------|
| E-03 | monitor.sh 초기 스위프 없음 — 기존 mailbox 메시지 미처리 | High | fswatch 시작 전 메시지 존재 시 |
| E-04 | Manager `--resume` 세션이 mailbox 알림을 자동 처리 못 함 | High | 항상 |
| E-05 | `claude -p`가 Claude Code 내부 Bash tool에서 실행 불가 | High | Claude Code 안에서 실행 시 |
| E-06 | tmux send-keys 긴 텍스트 → Claude Code에서 즉시 처리 안 됨 | High | 긴 텍스트 전송 시 |

### Medium

| # | 제목 | 심각도 |
|---|------|--------|
| E-07 | tmux send-keys 숫자 선택이 Claude Code 권한 프롬프트에서 안 됨 | Medium |
| E-08 | Manager가 mailbox kind를 잘못 사용 (task_complete로 dispatch 지시) | Medium |

---

## 4. 에이전트별 행동 분석

### Manager (sonnet)
- 22턴 안에 온보딩 → 팀 부팅 → 태스크 분배까지 자동 완료. **기대 이상**으로 동작.
- 태스크 지시서가 잘 구조화됨 (TASK-001-002-003.md).
- sessions.md 중복 등록 버그를 스스로 발견하고 TASK-002에 포함시킴.
- 약점: mailbox kind를 잘못 사용함 (dispatch에 task_complete 사용).

### Researcher (opus)
- 온보딩 8단계를 완벽히 수행.
- TASK-001: 31개 파일을 분석하여 16건의 문서 이슈 발견. 심각도 분류가 정확.
- TASK-003: TASK-001 + TASK-002 결과를 통합하여 41건의 종합 보고서 작성. 패턴 분석이 인상적.
- 약점: 권한 프롬프트에 막혀 작업 지연.

### Developer (sonnet)
- 1,341줄의 쉘 스크립트를 분석하여 22건의 코드 이슈 발견. 구체적 수정안 제시.
- Critical 1건, High 8건 발견. 재현 방법과 수정 코드까지 제공.
- 긍정적 평가도 포함하여 균형잡힌 감사.
- 약점: 동일하게 권한 프롬프트 이슈.

### Monitoring (haiku)
- 시스템 상태를 정확히 점검 (CPU, RAM, 디스크, 프로세스).
- mds_stores 이상과 iTerm2 메모리 과다 사용을 자발적으로 감지.
- 약점: Bash 명령마다 권한 승인 필요 — haiku의 10턴 제한과 결합하면 거의 작업 불가.

---

## 5. 핵심 개선 사항

### 즉시 수정 (이번 세션)

1. **`--resume` 시 `--dangerously-skip-permissions` 추가**: orchestrator.sh의 `boot_single_agent()`에서 `claude --resume` 호출 시 권한 스킵 플래그 추가. 이것 없이는 무인 실행 불가능.

2. **monitor.sh 초기 스위프 추가**: `start_mailbox_watcher()` 호출 전에 `process_all_mailboxes` 1회 실행하여 기존 메시지 처리.

3. **sessions.md 중복 방지**: `add_session_row()`에 기존 active 행 확인 로직 추가.

### 조기 수정 (설계 개선)

4. **Manager 자율 루프**: 현재 Manager의 `--resume` 세션은 수동 입력을 기다릴 뿐이다. Manager가 mailbox 수신 → 상태 갱신 → 다음 태스크 디스패치를 자동으로 수행하려면, Manager 부팅 메시지에 "주기적으로 mailbox를 확인하라"는 지시를 추가하거나, `--max-turns`을 충분히 높여서 `-p` 모드에서 전체 작업을 완료하게 해야 한다.

5. **`claude -p` 중첩 실행 안정화**: `env -u CLAUDECODE` 우회가 Bash tool 내에서 불안정하다. tmux 기반 우회를 orchestrator.sh에 내장하거나, 중첩 실행을 근본적으로 지원하는 방법 필요.

---

## 6. 결론

**E2E 파이프라인의 핵심 흐름은 동작한다.** 프로젝트 생성, Manager 부팅, 팀 부팅, 태스크 분배, 에이전트 작업, mailbox 소통, 산출물 생성, 세션 종료 — 모두 작동했다.

그러나 **무인 자율 실행은 아직 불가능하다.** `--resume` 세션의 권한 문제, monitor.sh의 초기 스위프 누락, Manager의 자율 루프 부재라는 3가지 핵심 블로커가 존재한다.

에이전트들의 작업 품질은 **기대 이상**이었다. 41건의 감사 항목 발견, 패턴 분석, 구체적 수정안 제시 — 프레임워크 구조가 에이전트의 행동을 효과적으로 가이드하고 있음을 확인했다.

### 다음 단계

1. 이번 보고서의 "즉시 수정" 3항목 적용
2. 에이전트가 발견한 41건 중 Critical + High 11건 수정
3. 수정 후 E2E 재실행하여 무인 실행 검증
