# 멀티 에이전트 오케스트레이션

**대상 행동**: "에이전트 인스턴스를 생성·관리하고, tmux + mailbox 기반 비동기 오케스트레이션으로 팀을 운영한다"

---

## 1. 실행 모드

| 모드 | 설명 | 결정 시점 |
|------|------|-----------|
| 단독 (solo) | Manager가 역할별 에이전트 1개씩 실행 | 온보딩 시 유저 선택 |
| 멀티 (dual) | 같은 태스크를 두 백엔드로 이중 실행 → 합의 | 온보딩 시 유저 선택 |

- project.md `운영 방식`에 `실행 모드: solo | dual` 기록
- **현재 Solo 모드만 구현**. Dual 모드는 Phase 3에서 추가 예정.

---

## 2. 에이전트 세션 생명주기

```
준비(Setup) → 부팅(Boot) → 대기(Ready) → 디스패치(Dispatch) → 결과 수집(Collect) → 반복 또는 종료
                                              ↑
                크래시 → 자동 리부팅 (최대 3회) ──┘
                행(hung) → Manager 판단 ────────┘
                맥락 과다 → 리프레시 ────────────┘
```

- **준비**: `orchestrator.sh boot`로 tmux 세션 생성 + mailbox 초기화.
- **부팅**: 각 에이전트에게 `claude -p`로 온보딩 메시지 전달, session_id 획득 후 tmux 윈도우에 `claude --resume`으로 인터랙티브 세션 시작.
- **대기**: 에이전트가 자기 tmux 윈도우에서 입력 대기 중. 유저도 `tmux attach`로 직접 관찰 가능.
- **디스패치**: `orchestrator.sh dispatch`로 tmux send-keys를 통해 태스크 전달.
- **수집**: 에이전트가 mailbox로 완료/상태를 보고. monitor.sh가 Manager에게 알림 전달.
- **크래시**: monitor.sh가 감지하여 자동 reboot 시도 (최대 3회). 실패 시 Manager에게 에스컬레이션.
- **행(hung)**: 10분 비활성 감지 시 Manager에게 알림. 자동 kill 안 함 (긴 bash 명령 가능성).
- **리프레시**: 맥락이 과도해졌을 때 Manager가 수동으로 `orchestrator.sh refresh` 실행. handoff 후 새 세션 부팅.
- **종료**: `orchestrator.sh shutdown`으로 세션 정리.

---

## 3. 부팅 절차

### 전체 부팅 (orchestrator.sh)

```bash
bash agents/manager/tools/orchestrator.sh boot {project-name}
```

orchestrator.sh가 자동으로 수행하는 것:

1. tmux 세션 `whiplash-{project}` 생성 (manager 윈도우 포함)
2. project.md에서 활성 에이전트 목록 추출
3. project.md에서 비용 상한 추출 (없으면 기본값 $5)
4. 각 에이전트에 대해:
   - `claude -p "{부팅 메시지}" --model {model} --output-format json --max-budget-usd {budget}` → session_id 획득
   - tmux 윈도우 생성 (`tmux new-window -n {role}`)
   - `tmux send-keys "claude --resume {session_id}" Enter`
   - sessions.md에 기록
5. mailbox 디렉토리 생성 (각 role별 tmp/new/cur)
6. monitor.sh 백그라운드 실행 (에러 로깅 + 로그 로테이션)

### 부팅 메시지

기존 온보딩 8단계 + mailbox 안내(9단계):

```
너는 {Role} 에이전트다.
레포 루트: {repo_root}
현재 프로젝트: projects/{name}/

아래 온보딩 절차를 순서대로 따라라:
1. agents/common/README.md 읽기
2. agents/common/project-context.md 읽기
3. agents/{role}/profile.md 읽기
4. projects/{name}/project.md 읽기
5. domains/{domain}/context.md 읽기
6. (해당 시) domains/{domain}/{role}.md 읽기
7. (해당 시) projects/{name}/team/{role}.md 읽기
8. memory/knowledge/index.md 읽기
9. 태스크 완료 또는 블로커 발생 시:
   bash agents/manager/tools/mailbox.sh {project} {role} manager {kind} {priority} "{subject}" "{content}"
   kind: task_complete | status_update | need_input | escalation | agent_ready

온보딩이 끝나면 준비 완료를 mailbox로 보고해라.
```

### CLI 플래그 요약

- `--output-format json`: session_id 캡처용
- `--allowedTools`: 무인 실행을 위한 도구 자동 승인
- `--max-turns`: 폭주 방지
- `--max-budget-usd`: 세션 당 비용 상한 (project.md에서 추출, 기본 $5)
- `--model`: 역할별 모델 선택 (§7 참조)

---

## 4. 세션 추적

`memory/manager/sessions.md`에 활성 세션 기록:

```markdown
# 활성 에이전트 세션

| 역할 | 백엔드 | Session ID | tmux Target | 상태 | 시작일 | 모델 | 비고 |
|------|--------|-----------|-------------|------|--------|------|------|
| researcher | claude | abc-123 | whiplash-myproj:researcher | active | 2026-02-14 | opus | |
| developer | claude | def-456 | whiplash-myproj:developer | active | 2026-02-14 | sonnet | |
| monitoring | claude | ghi-789 | whiplash-myproj:monitoring | active | 2026-02-14 | haiku | |
```

- Manager가 세션 생성/종료 시 업데이트
- orchestrator.sh가 boot/shutdown/reboot/refresh 시 자동 관리
- 상태값: `active` | `closed` | `crashed` | `refreshed`
- 세션이 오래되거나 맥락이 너무 길어지면 `refresh`로 교체

---

## 5. 단독 모드: 태스크 디스패치

### 순차 실행 (의존성 있는 태스크)

```bash
# 1. 태스크 지시서 작성
#    workspace/shared/announcements/TASK-001.md

# 2. Researcher에게 디스패치
bash agents/manager/tools/orchestrator.sh dispatch researcher \
  workspace/shared/announcements/TASK-001.md {project}

# 3. (비동기 — Manager는 다른 작업 가능)
#    monitor.sh가 Researcher의 완료 알림을 Manager에게 전달

# 4. 결과 확인 후 다음 에이전트에게 디스패치
bash agents/manager/tools/orchestrator.sh dispatch developer \
  workspace/shared/announcements/TASK-002.md {project}
```

### 병렬 실행 (독립 태스크)

```bash
# 1. 독립 태스크 지시서 작성
#    TASK-A.md, TASK-B.md

# 2. 동시 디스패치
bash agents/manager/tools/orchestrator.sh dispatch researcher \
  workspace/shared/announcements/TASK-A.md {project}
bash agents/manager/tools/orchestrator.sh dispatch developer \
  workspace/shared/announcements/TASK-B.md {project}

# 3. (동시 진행 — 유저도 tmux에서 각 창 관찰 가능)
# 4. 양쪽 mailbox 알림 도착 후 결과 확인
```

### 직접 관찰

유저가 언제든 에이전트의 작업을 직접 관찰할 수 있다:

```bash
tmux attach -t whiplash-{project}
# Ctrl-b + 숫자 또는 n/p로 윈도우 전환
```

---

## 6. 멀티 모드: 이중 실행 + 합의 프로토콜

> **Phase 3에서 추가 예정.** 현재는 단독 모드만 지원한다.
>
> 기존 설계: 같은 태스크를 Claude Code + Codex 양쪽에 디스패치 → 결과 교차 전달 → 토론 라운드 → 합의 판정.
> tmux 기반으로 전환 시 각 백엔드를 별도 윈도우로 운영하고, 결과 비교를 mailbox 메시지로 수행하는 방식으로 확장할 예정.

---

## 7. 모델 선택 가이드

| 역할 | Claude Code 모델 | 이유 |
|------|-----------------|------|
| Researcher | opus | 복잡한 분석, 논문 해석 |
| Developer | sonnet | 빠른 코드 작성 |
| Monitoring | haiku | 단순 점검, 비용 절감 |

모델은 부팅 시 orchestrator.sh가 역할에 따라 자동 선택. 필요 시 project.md에서 오버라이드 가능.

---

## 8. 안전장치

### 비용 제한

- `--max-budget-usd`: 세션 당 비용 상한. project.md에서 추출, 기본값 $5.
- 부팅 시 `claude -p` 호출과 인터랙티브 세션 모두에 적용.

### 자동 리부팅

- monitor.sh가 에이전트 윈도우 소멸 감지 시 `orchestrator.sh reboot` 자동 호출
- **최대 3회**까지 시도. 매 시도마다 Manager에게 mailbox로 보고.
- 3회 초과 시 reboot 포기, 수동 개입 요청 에스컬레이션.
- 윈도우가 정상 확인되면 카운터 자동 리셋.

### 행(hung) 감지

- tmux `window_activity` (마지막 활동 Unix epoch) 기반.
- **10분(600초)** 이상 비활성 시 Manager에게 1회 알림 (중복 방지 flag).
- **알림만, 자동 kill 안 함** — 긴 bash 명령 실행 중일 수 있으므로 Manager 판단에 위임.
- 활동 재개 시 flag 자동 클리어.

### 에러 로깅

- monitor.sh 출력을 `memory/manager/logs/monitor-{timestamp}.log`에 기록.
- 로그 로테이션: 부팅 시 최근 5개만 유지, 나머지 자동 삭제.

### monitor 자가 heartbeat

- 매 폴링 사이클마다 `memory/manager/monitor.heartbeat`에 Unix epoch 기록.
- `orchestrator.sh status`에서 heartbeat 신선도 확인. 90초 이상이면 좀비 경고 표시.

### 메시지 감사 로그

- mailbox.sh가 모든 메시지 전달을 `memory/manager/logs/mailbox-audit.log`에 기록.
- 형식: `{ISO timestamp} | {MSG ID} | {from} → {to} | {kind} | {priority} | {subject}`
- grep으로 메시지 이력 검색 가능.

### 기타

- **타임아웃**: `--max-turns`으로 에이전트 턴 수 제한
- **tmux 세션 관리**: orchestrator.sh shutdown으로 깔끔한 정리 (런타임 파일 포함)
- **파일 충돌 방지**: 병렬 실행 시 양쪽 에이전트가 같은 파일에 쓰지 않도록 각각 별도 경로 사용

---

## 9. 병렬 실행 시 파일 소유권

| 안전 | 위험 |
|------|------|
| 각 에이전트가 자기 하위 디렉토리에 쓰기 | 같은 파일 동시 수정 |
| workspace/shared/에 새 파일 추가 | workspace/shared/의 기존 파일 수정 |
| memory/{role}/에 쓰기 | memory/knowledge/index.md 동시 수정 |

원칙:

- `memory/knowledge/index.md`와 `workspace/shared/`의 기존 파일은 **Manager만** 수정
- 병렬 실행 시 같은 역할의 에이전트는 **별도 작업 디렉토리** 사용
- 합의 후 Manager가 최종 결과를 정식 위치에 배치

---

## 10. Mailbox 프로토콜

### 구조

```
workspace/shared/mailbox/
  {role}/
    tmp/     # 작성 중 (원자적 전달용)
    new/     # 도착한 메시지 (미읽음)
    cur/     # 처리된 메시지
```

### 메시지 형식

```markdown
---
id: MSG-{epoch}-{from}-{pid}-{random}
from: {발신자 역할}
to: {수신자 역할}
kind: {종류}
priority: {우선도}
timestamp: {ISO 8601}
subject: {제목}
---

{본문}
```

### 메시지 종류 (kind)

| kind | 의미 | 예시 |
|------|------|------|
| task_complete | 태스크 완료 보고 | "TASK-001 리서치 완료" |
| status_update | 진행 상황 업데이트 | "논문 3편 분석 중, 2편 완료" |
| need_input | 입력/결정 필요 | "방향 A와 B 중 선택 필요" |
| escalation | 유저 에스컬레이션 필요 | "리소스 부족, 유저 확인 필요" |
| agent_ready | 에이전트 준비 완료 | "온보딩 완료, 대기 중" |
| reboot_notice | 에이전트 자동 리부팅 알림 | "researcher 크래시 후 자동 reboot" |

### 사용법

```bash
# 에이전트가 Manager에게 완료 보고
bash agents/manager/tools/mailbox.sh {project} researcher manager \
  task_complete normal "TASK-001 완료" "리서치 결과를 workspace/teams/research/에 작성함"

# 에이전트가 다른 에이전트에게 직접 알림
bash agents/manager/tools/mailbox.sh {project} researcher developer \
  status_update normal "API 스펙 확정" "workspace/teams/research/api-spec.md 참조"
```

### 규칙

- mailbox는 **짧은 알림** 전용. 상세 내용은 별도 문서에 두고 참조만.
- 기존 소통(토론, 회의, 공지) 규칙을 **대체하지 않는다**. 실시간 알림으로 보충할 뿐.
- priority: urgent는 monitor.sh가 `[URGENT]` 접두어로 표시한다.
- new/ → cur/ 이동은 monitor.sh가 자동 처리.
- MSG ID: `MSG-{epoch}-{from}-{pid}-{random}` 형식으로 충돌 방지.

---

## 11. Monitor 연동

### monitor.sh 역할

- 30초 간격으로 모든 에이전트의 mailbox/new/ 폴링
- 새 메시지 발견 시 수신자의 tmux 윈도우에 알림 전달
- 에이전트 윈도우 소멸 시 자동 reboot (최대 3회)
- 10분 비활성 에이전트 감지 시 Manager에게 알림
- 자가 heartbeat 기록 (좀비 감지용)

### 알림 형식

monitor.sh가 tmux send-keys로 전달하는 알림:

```
mailbox {from}: {subject} ({kind})
URGENT mailbox {from}: {subject} ({kind})
```

### Manager가 알림 받았을 때

| 알림 kind | Manager 행동 |
|-----------|-------------|
| agent_ready | 에이전트 준비 확인, 대기 중인 태스크가 있으면 디스패치 |
| task_complete | 결과물 확인, 다음 단계 진행 |
| status_update | 참고. 필요 시 추가 지시 |
| need_input | 결정이 Manager 범위면 응답, 아니면 유저 에스컬레이션 |
| escalation | 유저에게 보고 |
| reboot_notice | 에이전트 복구 상태 확인, 필요 시 수동 개입 |

### monitor.sh 관리

```bash
# 상태 확인
bash agents/manager/tools/orchestrator.sh status {project}

# monitor.sh는 orchestrator.sh boot 시 자동 시작, shutdown 시 자동 종료
# PID는 memory/manager/monitor.pid에 저장
# 로그는 memory/manager/logs/monitor-{timestamp}.log에 기록
```

---

## 12. 크래시 복구

### 자동 복구 (monitor.sh → reboot)

1. monitor.sh가 30초 간격으로 에이전트 윈도우 존재 확인
2. sessions.md에서 active 역할을 파싱 (하드코딩 아님)
3. 윈도우 소멸 감지 시:
   - `memory/manager/reboot-counts/{role}.count`에서 카운터 확인
   - 3회 미만이면 `orchestrator.sh reboot {role} {project}` 자동 호출
   - 성공/실패 모두 카운터 증가 + Manager에게 mailbox 보고
   - 3회 초과 시 reboot 포기, 수동 개입 요청 에스컬레이션
4. 윈도우가 정상 확인되면 카운터 자동 리셋

### 수동 복구 (orchestrator.sh reboot)

```bash
bash agents/manager/tools/orchestrator.sh reboot {role} {project}
```

동작:
1. 기존 윈도우 있으면 `/exit` 전송 후 kill
2. sessions.md에서 해당 역할의 이전 행을 `crashed`로 표시
3. `claude -p`로 새 세션 생성 (build_boot_message 재사용)
4. tmux 윈도우 생성 + `claude --resume`
5. sessions.md에 새 행 추가

### 세션 리프레시 (orchestrator.sh refresh)

맥락이 과도하게 길어졌을 때 Manager가 수동 호출:

```bash
bash agents/manager/tools/orchestrator.sh refresh {role} {project}
```

동작:
1. 에이전트에게 `memory/{role}/handoff.md` 작성 지시 (tmux send-keys)
2. 최대 2분 대기 (handoff.md 파일 생성 감시)
3. 기존 세션 종료 (/exit → kill-window)
4. sessions.md에서 이전 행을 `refreshed`로 표시
5. 새 세션 부팅 (온보딩 + "10. handoff.md를 읽어라" 추가)

자동 트리거는 하지 않음 — Manager 판단에 위임.
