# 멀티 에이전트 오케스트레이션

**대상 행동**: "에이전트 인스턴스를 생성·관리하고, tmux 기반 비동기 오케스트레이션으로 팀을 운영한다"

> **참고**: 이 문서의 모든 `orchestrator.sh`, `notify.sh`, `monitor.sh` 명령은 Manager 에이전트가 내부적으로 실행한다. 유저가 직접 실행하지 않는다.

---

## 1. 실행 모드

| 모드 | 설명 | 결정 시점 |
|------|------|-----------|
| 단독 (solo) | Manager가 역할별 에이전트 1개씩 실행 | 온보딩 시 유저 선택 |
| 멀티 (dual, 실험적) | 같은 태스크를 두 백엔드(Claude Code + Codex CLI)로 이중 실행 → Manager가 합의 도출. **E2E 미검증** — Codex CLI 호환성 미확인 | 온보딩 시 유저 선택 |

- project.md `운영 방식`에 `실행 모드: solo | dual` 기록
- Solo와 Dual 모드를 모두 지원한다. `orchestrator.sh boot` 시 project.md에서 실행 모드를 파싱하여 자동 분기한다.

---

## 2. 에이전트 세션 생명주기

```
준비(Setup) → 부팅(Boot) → 대기(Ready) → 디스패치(Dispatch) → 결과 수집(Collect) → 반복 또는 종료
                                              ↑
                크래시 → 자동 리부팅 (최대 3회) ──┘
                행(hung) → Manager 판단 ────────┘
                맥락 과다 → 리프레시 ────────────┘
                부하 초과 → 동적 스폰 ────────────┘
```

- **준비**: `orchestrator.sh boot`로 tmux 세션 생성.
- **부팅**: 각 에이전트에게 `claude -p`로 온보딩 메시지 전달, session_id 획득 후 tmux 윈도우에 `claude --resume`으로 인터랙티브 세션 시작.
- **대기**: 에이전트가 자기 tmux 윈도우에서 입력 대기 중. 유저도 `tmux attach`로 직접 관찰 가능.
- **디스패치**: `orchestrator.sh dispatch`로 tmux send-keys를 통해 태스크 전달.
- **수집**: 에이전트가 notify.sh로 완료/상태를 Manager에게 직접 전달.
- **크래시**: monitor.sh가 감지하여 자동 reboot 시도 (최대 3회). 실패 시 Manager에게 에스컬레이션.
- **행(hung)**: 10분 비활성 감지 시 Manager에게 알림. 자동 kill 안 함 (긴 bash 명령 가능성).
- **리프레시**: 맥락이 과도해졌을 때 Manager가 수동으로 `orchestrator.sh refresh` 실행. handoff 후 새 세션 부팅.
- **동적 스폰**: Manager가 `spawn`으로 같은 역할의 추가 인스턴스를 투입. 작업 후 `kill-agent`로 종료.
- **종료**: `orchestrator.sh shutdown`으로 세션 정리.

---

## 3. 부팅 절차

### Manager 부팅 (orchestrator.sh boot-manager)

```bash
bash agents/manager/tools/orchestrator.sh boot-manager {project-name}
```

orchestrator.sh가 수행하는 것:

1. sessions.md 초기화
2. `claude -p "{부팅 메시지}" --model sonnet --output-format json` → session_id 획득
3. tmux 세션 `whiplash-{project}` 생성 (manager 윈도우)
4. `tmux send-keys "claude --resume {session_id}" Enter`
5. sessions.md에 Manager 행 기록

Manager가 tmux 안에서 `orchestrator.sh boot`을 호출하면 나머지 에이전트가 부팅된다.

### Manager 시작 절차 (부팅 후 자동 실행)

Manager는 부팅 메시지에 포함된 지시에 따라 아래를 자동 실행한다:

1. 온보딩 8단계 완료
2. `orchestrator.sh boot {project}` 실행 → 팀 에이전트 부팅
3. 모든 에이전트의 `agent_ready` 알림 대기
4. project.md의 목표를 분석하고 첫 태스크 분배 (task-distribution.md 절차)
5. 팀 운영 시작

### 전체 부팅 (orchestrator.sh boot)

```bash
bash agents/manager/tools/orchestrator.sh boot {project-name}
```

orchestrator.sh가 자동으로 수행하는 것:

1. tmux 세션 `whiplash-{project}` 생성 (없으면 생성, boot-manager로 이미 생성되었으면 재사용)
2. project.md에서 활성 에이전트 목록 추출
3. 각 에이전트에 대해 (Manager는 건너뜀):
   - `claude -p "{부팅 메시지}" --model {model} --output-format json` → session_id 획득
   - tmux 윈도우 생성 (`tmux new-window -n {role}`)
   - `tmux send-keys "claude --resume {session_id}" Enter`
   - sessions.md에 기록
5. monitor.sh 백그라운드 실행 (에러 로깅 + 로그 로테이션)

### 부팅 메시지

기존 온보딩 8단계 + 알림 안내(9단계):

```
너는 {Role} 에이전트다.
레포 루트: {repo_root}
현재 프로젝트: projects/{name}/

아래 온보딩 절차를 순서대로 따라라:
1. agents/common/README.md 읽기
2. agents/common/project-context.md 읽기
3. agents/{role}/profile.md 읽기
4. projects/{name}/project.md 읽기
5. (해당 시) domains/{domain}/context.md 읽기
6. (해당 시) domains/{domain}/{role}.md 읽기
7. (해당 시) projects/{name}/team/{role}.md 읽기
8. memory/knowledge/index.md 읽기
9. 태스크 완료 또는 블로커 발생 시:
   bash agents/manager/tools/notify.sh {project} {role} manager {kind} {priority} "{subject}" "{content}"
   kind: task_complete | status_update | need_input | escalation | agent_ready | reboot_notice | consensus_request

온보딩이 끝나면 준비 완료를 알림으로 보고해라.
```

### CLI 플래그 요약

- `--output-format json`: session_id 캡처용
- `--allowedTools`: 무인 실행을 위한 도구 자동 승인
- `--max-turns`: 폭주 방지
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
#    Researcher가 notify.sh로 완료 알림을 Manager에게 직접 전달

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
# 4. 양쪽 알림 도착 후 결과 확인
```

### 직접 관찰

유저가 언제든 에이전트의 작업을 직접 관찰할 수 있다:

```bash
tmux attach -t whiplash-{project}
# Ctrl-b + 숫자 또는 n/p로 윈도우 전환
```

---

## 6. 멀티 모드: 이중 실행 + 합의 프로토콜

### 6.1 개요

Dual 모드는 같은 태스크를 **Claude Code**와 **Codex CLI** 두 백엔드에서 병렬 실행하고, Manager가 결과를 비교하여 합의를 도출하는 방식이다.

- 합의는 **반자동** — orchestrator.sh에 도구(`dual-dispatch` 등)만 제공하고, Manager가 문서화된 절차를 따라 직접 판정한다.
- Monitoring 에이전트는 dual에서도 **solo로 부팅**한다 (이중 실행 불필요).

### 6.2 이중 부팅

`orchestrator.sh boot`가 project.md의 `실행 모드: dual`을 감지하면 자동으로 이중 부팅한다:

- 각 역할(monitoring 제외)에 대해 두 윈도우 생성:
  - `{role}-claude`: Claude Code (`claude -p` → `claude --resume`)
  - `{role}-codex`: Codex CLI (`codex` 인터랙티브)
- sessions.md에 백엔드별 행이 기록된다:

```markdown
| researcher | claude | abc-123 | whiplash-proj:researcher-claude | active | 2026-02-15 | opus | |
| researcher | codex | codex-interactive | whiplash-proj:researcher-codex | active | 2026-02-15 | codex | |
```

- codex CLI가 설치되어 있지 않으면 boot 시 에러로 중단한다.

### 6.3 이중 디스패치

```bash
bash agents/manager/tools/orchestrator.sh dual-dispatch {role} {task-file} {project}
```

양쪽 윈도우(`{role}-claude`, `{role}-codex`)에 동일한 태스크를 전달한다. 단독 dispatch도 여전히 사용 가능 — 특정 백엔드 윈도우에만 전달하고 싶을 때.

### 6.4 합의 절차

Manager가 다음 6단계를 수동으로 수행한다:

1. **결과 수집**: 양쪽 에이전트의 `task_complete` 메시지를 대기. 한쪽이 먼저 완료해도 다른 쪽을 기다린다 (타임아웃은 Manager 판단).
2. **합의 문서 생성**: 양쪽 결과를 비교하여 `workspace/shared/discussions/DISC-NNN.md`에 합의 문서를 작성한다. 형식은 `formats.md` 토론 템플릿을 따른다.
3. **교차 전달**: notify.sh로 양쪽 에이전트에 `consensus_request`를 보낸다.
   ```bash
   bash agents/manager/tools/notify.sh {project} manager {role}-claude \
     consensus_request normal "합의 요청" "workspace/shared/discussions/DISC-NNN.md를 읽고 의견을 추가하라."
   bash agents/manager/tools/notify.sh {project} manager {role}-codex \
     consensus_request normal "합의 요청" "workspace/shared/discussions/DISC-NNN.md를 읽고 의견을 추가하라."
   ```
4. **판정**: 양쪽 응답 확인 후 Manager가 판정한다.
   - **동의**: 합의 결과를 채택하고 문서에 결론을 기록한다.
   - **대립**: 2차 라운드를 진행한다.
5. **2차 라운드** (최대 1회 추가): 대립 지점을 명확히 하여 양쪽에 재질의한다. 2차에서도 미합의 시 Manager가 직접 판정하거나 유저에게 에스컬레이션한다.
6. **결과 확정**: 합의 문서를 `memory/knowledge/discussions/`로 이동하고, 최종 결과를 정식 위치에 배치한다.

### 6.5 작업 영역 분리

Dual 모드에서는 양쪽 에이전트가 파일 충돌을 피하기 위해 별도 작업 경로를 사용한다:

- Claude: `workspace/teams/{team}/{role}-claude/`
- Codex: `workspace/teams/{team}/{role}-codex/`

합의 후 Manager가 최종 결과를 정식 위치에 배치한다.

### 6.6 에이전트 식별

Dual 모드에서는 notify.sh의 from 인자에 `{role}-{backend}`를 사용한다:

- `researcher-claude`, `researcher-codex` 등
- Manager가 어느 백엔드의 보고인지 구별할 수 있다.
- 부팅 메시지에서 agent_id로 자동 설정된다.

### 6.7 한쪽 장애 시

- 한쪽 백엔드만 크래시되면 monitor.sh가 해당 윈도우만 독립적으로 reboot한다.
  - 예: `researcher-codex` 크래시 → `orchestrator.sh reboot researcher-codex {project}`
- 한쪽만 결과를 낸 경우 Manager가 해당 결과만으로 채택 가능 (합의 불필요 판정).

---

## 7. 모델 선택 가이드

| 역할 | Claude Code 모델 | 이유 |
|------|-----------------|------|
| Researcher | opus | 복잡한 분석, 논문 해석 |
| Developer | sonnet | 빠른 코드 작성 |
| Monitoring | haiku | 단순 점검, 비용 절감 |

모델은 부팅 시 orchestrator.sh가 역할에 따라 자동 선택. 필요 시 project.md에서 오버라이드 가능.

### 역할별 도구 제한 (allowedTools)

| 역할 | allowedTools | 근거 |
|------|-------------|------|
| manager | 전체 (Read,Glob,Grep,Write,Edit,Bash,WebSearch,WebFetch) | 지시서 작성, 지식 관리 |
| researcher | 전체 | 논문 검색, 실험 노트 |
| developer | 전체 | 코드 구현, 테스트 |
| monitoring | Read,Glob,Grep,Bash | profile에 "코드 수정 금지" 명시 |

### 역할별 턴 제한 (max-turns)

| 역할 | max-turns | 근거 |
|------|----------|------|
| monitoring | 10 | 짧은 점검 사이클 |
| manager | 20 | 조율 |
| researcher | 30 | 다중 소스 검색 |
| developer | 40 | 구현+테스트 반복 |

---

## 8. 안전장치

### 자동 리부팅

- monitor.sh가 에이전트 윈도우 소멸 감지 시 `orchestrator.sh reboot` 자동 호출
- **최대 3회**까지 시도. 매 시도마다 Manager에게 notify.sh로 보고.
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

- 매 헬스 체크 사이클(30초)마다 `memory/manager/monitor.heartbeat`에 Unix epoch 기록.
- `orchestrator.sh status`에서 heartbeat 신선도 확인. 90초 이상이면 좀비 경고 표시.

### 알림 감사 로그

- notify.sh가 모든 알림 전달을 `memory/manager/logs/notify-audit.log`에 기록.
- 형식: `{ISO timestamp} | {from} → {to} | {kind} | {priority} | {subject}`
- grep으로 알림 이력 검색 가능.

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

## 10. 알림 프로토콜

### 전달 방식

notify.sh가 수신자의 tmux 윈도우에 `load-buffer` + `paste-buffer`로 직접 전달한다. 파일 중개 없음.

### 알림 형식

```
[notify] {from} → {to} | {kind}
제목: {subject}
내용: {content}

[URGENT] {from} → {to} | {kind}
제목: {subject}
내용: {content}
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
| consensus_request | 합의 요청 (dual 모드) | "DISC-001 합의 문서를 읽고 의견 추가" |

### 사용법

```bash
# 에이전트가 Manager에게 완료 보고
bash agents/manager/tools/notify.sh {project} researcher manager \
  task_complete normal "TASK-001 완료" "리서치 결과를 workspace/teams/research/에 작성함"

# 에이전트가 다른 에이전트에게 직접 알림
bash agents/manager/tools/notify.sh {project} researcher developer \
  status_update normal "API 스펙 확정" "workspace/teams/research/api-spec.md 참조"
```

### 규칙

- 알림은 **짧은 알림** 전용. 상세 내용은 별도 문서에 두고 참조만.
- 기존 소통(토론, 회의, 공지) 규칙을 **대체하지 않는다**. 실시간 알림으로 보충할 뿐.
- priority: urgent는 `[URGENT]` 접두어로 표시된다.
- 감사 로그(`memory/manager/logs/notify-audit.log`)가 이력을 기록한다.

---

## 11. Monitor 연동

### monitor.sh 역할

- **헬스 체크**: 30초 주기 포그라운드 루프
  - 에이전트 윈도우 소멸 시 자동 reboot (최대 3회)
  - 10분 비활성 에이전트 감지 시 Manager에게 notify.sh로 알림
- 자가 heartbeat 기록 (좀비 감지용)

### Manager가 알림 받았을 때

| 알림 kind | Manager 행동 |
|-----------|-------------|
| agent_ready | 에이전트 준비 확인, 대기 중인 태스크가 있으면 디스패치 |
| task_complete | 결과물 확인, 다음 단계 진행. dual 모드에서는 양쪽 완료 후 합의 절차(§6.4) 시작 |
| status_update | 참고. 필요 시 추가 지시 |
| need_input | 결정이 Manager 범위면 응답, 아니면 유저 에스컬레이션 |
| escalation | 유저에게 보고 |
| reboot_notice | 에이전트 복구 상태 확인, 필요 시 수동 개입 |
| consensus_request | (dual 모드) 에이전트에게 합의 문서 검토 요청. 응답 대기 후 판정(§6.4) |

### monitor.sh 관리

```bash
# 상태 확인
bash agents/manager/tools/orchestrator.sh status {project}

# monitor.sh 상태 확인 + 자동 재시작
bash agents/manager/tools/orchestrator.sh monitor-check {project}

# monitor.sh는 orchestrator.sh boot 시 자동 시작, shutdown 시 자동 종료
# PID는 memory/manager/monitor.pid에 저장
# 로그는 memory/manager/logs/monitor-{timestamp}.log에 기록
```

Manager가 주기적으로 `monitor-check`를 호출하여 monitor.sh의 생존을 확인한다:
- PID + heartbeat 확인
- 프로세스 죽었으면 자동 재시작
- heartbeat 90초 이상이면 좀비로 판정 → 강제 종료 후 재시작

### Manager 감시

monitor.sh는 Manager 윈도우도 감시 대상에 포함한다. Manager 크래시 시:
- 자동 reboot 시도 (최대 3회)
- Manager에게 알림 전달은 불가하므로 (수신자가 크래시 상태) 로그에만 기록

---

## 12. 크래시 복구

### 자동 복구 (monitor.sh → reboot)

1. monitor.sh가 30초 헬스 체크 주기로 에이전트 윈도우 존재 확인
2. sessions.md에서 active 역할을 파싱 (하드코딩 아님)
3. 윈도우 소멸 감지 시:
   - `memory/manager/reboot-counts/{role}.count`에서 카운터 확인
   - 3회 미만이면 `orchestrator.sh reboot {role} {project}` 자동 호출
   - 성공/실패 모두 카운터 증가 + Manager에게 notify.sh로 보고
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

---

## 13. 동적 에이전트 스폰

에이전트가 오래 걸리는 작업 중일 때 같은 역할의 추가 인스턴스를 스폰해서 다른 태스크를 병렬 수행한다. 작업이 끝나면 종료한다.

### 사용 시점

- 에이전트가 긴 태스크 실행 중이고, 같은 역할에 새 태스크를 병렬로 줘야 할 때
- 긴급 핫픽스가 필요한데 해당 역할 에이전트가 바쁠 때

### 스폰

```bash
bash agents/manager/tools/orchestrator.sh spawn {role} {window-name} {project} [extra-msg]
# 예시: researcher가 바쁠 때 researcher-2 추가
bash agents/manager/tools/orchestrator.sh spawn researcher researcher-2 myproject
# 예시: 핫픽스 전용 developer
bash agents/manager/tools/orchestrator.sh spawn developer dev-hotfix myproject "긴급 버그 수정 전용"
```

### 종료

```bash
bash agents/manager/tools/orchestrator.sh kill-agent {window-name} {project}
# 예시
bash agents/manager/tools/orchestrator.sh kill-agent researcher-2 myproject
```

### 공유 범위

- 동일 프로젝트의 메모리, workspace를 **공유**한다
- 같은 파일 동시 수정만 **금지** — 스폰 시 부팅 메시지에 주의사항이 자동 포함된다
- notify.sh로 `researcher-2` 등 window_name으로 알림 송수신 가능

### 자동 감시

- monitor.sh가 sessions.md의 tmux target을 파싱하므로 동적 에이전트도 자동 감시 대상
- 크래시 시 자동 reboot 동작 (기존과 동일)

### 주의사항

- 스폰된 에이전트는 `shutdown` 시 다른 에이전트와 함께 일괄 종료된다
- window_name 중복은 자동으로 거절된다

---

## 14. Claude Code vs Codex CLI 호환성 매트릭스

| 기능 | Claude Code | Codex CLI |
|------|-----------|---------|
| --allowedTools | O | X |
| --max-turns | O | X |
| --resume (세션 재개) | O | X |
| Hooks (.claude/) | O | X |
| notify.sh (Bash) | O | O |
| tmux send-keys | O | O |

Dual 모드에서 Codex CLI 측은 CLI 플래그 기반 제어가 불가하므로, 부팅 메시지와 알림 프로토콜에만 의존한다.
