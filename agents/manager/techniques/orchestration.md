# 멀티 에이전트 오케스트레이션

**대상 행동**: "에이전트 인스턴스를 생성·관리하고, tmux 기반 비동기 오케스트레이션으로 팀을 운영한다"

> **참고**: 이 문서의 모든 `cmd.sh`, `message.sh`, `monitor.sh` 명령은 Manager 에이전트가 내부적으로 실행한다. 유저가 직접 실행하지 않는다.

---

## 1. 실행 모드

| 모드 | 설명 | 결정 시점 |
|------|------|-----------|
| 단독 (solo) | Manager가 역할별 에이전트 1개씩 실행 | 온보딩 시 유저 선택 |
| 멀티 (dual, 실험적) | 같은 태스크를 두 백엔드(Claude Code + Codex CLI)로 이중 실행 → Manager가 합의 도출. **E2E 미검증** — Codex CLI 호환성 미확인 | 온보딩 시 유저 선택 |

- project.md `운영 방식`에 `실행 모드: solo | dual` 기록
- Solo와 Dual 모드를 모두 지원한다. `cmd.sh boot` 시 project.md에서 실행 모드를 파싱하여 자동 분기한다.

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

- **준비**: `cmd.sh boot`로 tmux 세션 생성.
- **부팅**: 각 에이전트에게 `claude -p`로 온보딩 메시지 전달, session_id 획득 후 tmux 윈도우에 `claude --resume`으로 인터랙티브 세션 시작.
- **대기**: 에이전트가 자기 tmux 윈도우에서 입력 대기 중. 유저도 `tmux attach`로 직접 관찰 가능.
- **디스패치**: `cmd.sh dispatch`로 tmux send-keys를 통해 태스크 전달.
- **수집**: 에이전트가 message.sh로 완료/상태를 Manager에게 직접 전달.
- **크래시**: monitor.sh가 감지하여 자동 reboot 시도 (최대 3회). 실패 시 Manager에게 에스컬레이션.
- **행(hung)**: 10분 비활성 감지 시 Manager에게 알림. 자동 kill 안 함 (긴 bash 명령 가능성).
- **리프레시**: 맥락이 과도해졌을 때 Manager가 수동으로 `cmd.sh refresh` 실행. handoff 후 새 세션 부팅.
- **동적 스폰**: Manager가 `spawn`으로 같은 역할의 추가 인스턴스를 투입. 작업 후 `kill-agent`로 종료.
- **종료**: `cmd.sh shutdown`으로 세션 정리.

---

## 3. 부팅 절차

### Manager 부팅 (cmd.sh boot-manager)

```bash
bash scripts/cmd.sh boot-manager {project-name}
```

cmd.sh가 수행하는 것:

1. sessions.md 초기화
2. `claude -p "{부팅 메시지}" --model {model} --allowedTools {tools} --output-format json` → session_id 획득
3. tmux 세션 `whiplash-{project}` 생성 (manager 윈도우)
4. `tmux send-keys "claude --resume {session_id}" Enter`
5. sessions.md에 Manager 행 기록

Manager가 tmux 안에서 `cmd.sh boot`을 호출하면 나머지 에이전트가 부팅된다.

### Manager 시작 절차 (부팅 후 자동 실행)

Manager는 부팅 메시지에 포함된 지시에 따라 아래를 자동 실행한다:

1. 온보딩 Layer 1 완료 (Layer 2, 3은 필요 시)
2. `cmd.sh boot {project}` 실행 → 팀 에이전트 부팅
3. 모든 에이전트의 `agent_ready` 알림 대기
4. project.md의 목표를 분석하고 첫 태스크 분배 (task-distribution.md 절차)
5. 팀 운영 시작

### 전체 부팅 (cmd.sh boot)

```bash
bash scripts/cmd.sh boot {project-name}
```

cmd.sh가 자동으로 수행하는 것:

1. tmux 세션 `whiplash-{project}` 생성 (없으면 생성, boot-manager로 이미 생성되었으면 재사용)
2. project.md에서 활성 에이전트 목록 추출
3. 각 에이전트에 대해 (Manager는 건너뜀):
   - `profile.md`에서 모델·허용 도구 파싱
   - `claude -p "{부팅 메시지}" --model {model} --allowedTools {tools} --output-format json` → session_id 획득
   - tmux 윈도우 생성 (`tmux new-window -n {role}`)
   - `tmux send-keys "claude --resume {session_id} --allowedTools {tools}" Enter`
   - sessions.md에 기록
5. monitor.sh 백그라운드 실행

### 부팅 메시지

Progressive Disclosure 3단계 온보딩 + 알림 안내:

```
너는 {Role} 에이전트다.
레포 루트: {repo_root}
현재 프로젝트: projects/{name}/

아래 온보딩 절차를 순서대로 따라라 (Progressive Disclosure — 필요한 것만 필요한 시점에):

[Layer 1 — 필수, 지금 즉시 읽기]
1. agents/common/README.md 읽기
2. agents/{role}/profile.md 읽기
3. projects/{name}/project.md 읽기

[Layer 2 — 첫 태스크 수신 시 읽기]
4. memory/knowledge/index.md 읽기 (지도만, 전체 읽기 아님)
5. 해당 작업에 필요한 agents/{role}/techniques/*.md 읽기
6. (도메인이 general이 아니고 파일이 있으면) domains/{domain}/context.md 읽기

[Layer 3 — 필요할 때만 읽기]
7. agents/common/project-context.md (경로 해석 등 필요 시)
8. (도메인이 general이 아니고 파일이 있으면) domains/{domain}/{role}.md
9. (해당 시) projects/{name}/team/{role}.md

10. 태스크 완료 또는 블로커 발생 시:
    bash scripts/message.sh {project} {role} manager {kind} {priority} "{subject}" "{content}"
    kind: task_complete | status_update | need_input | escalation | agent_ready | reboot_notice | consensus_request | alert_resolve

온보딩이 끝나면 준비 완료를 알림으로 보고해라.
```

### CLI 플래그 요약

- `--output-format json`: session_id 캡처용
- `--dangerously-skip-permissions`: 무인 실행 (도구 승인 바이패스)
- `--model`: 역할별 모델 선택 (§8 참조, profile.md 메타데이터에서 파싱)
- `--allowedTools`: 역할별 허용 도구 제한 (§8 참조, profile.md 메타데이터에서 파싱). `--resume` 시에도 재전달 필요

---

## 4. 세션 추적

`memory/manager/sessions.md`에 활성 세션 기록:

```markdown
# 활성 에이전트 세션

| 역할 | 백엔드 | Session ID | tmux Target | 상태 | 시작일 | 모델 | 비고 |
|------|--------|-----------|-------------|------|--------|------|------|
| researcher | claude | abc-123 | whiplash-myproj:researcher | active | 2026-02-14 | opus | |
| developer | claude | def-456 | whiplash-myproj:developer | active | 2026-02-14 | opus | |
| monitoring | claude | ghi-789 | whiplash-myproj:monitoring | active | 2026-02-14 | haiku | |
```

- Manager가 세션 생성/종료 시 업데이트
- cmd.sh가 boot/shutdown/reboot/refresh 시 자동 관리
- 상태값: `active` | `closed` | `crashed` | `refreshed`
- 세션이 오래되거나 맥락이 너무 길어지면 `refresh`로 교체

### Manager 활동 기록

Manager는 주요 운영 판단을 `memory/manager/activity.md`에 기록한다. 다른 에이전트가 점검 이력이나 실험 결과를 기록하는 것과 동일한 원칙.

기록 시점:
- 태스크 분배 결정 (왜 이 에이전트에게, 왜 이 순서로)
- 에이전트 보고(task_complete) 검토 후 판단
- 에스컬레이션 결정 (유저에게 올릴지 자체 해결할지)
- 계획 변경 (순서 조정, 추가 태스크 등)
- dual 모드 합의 판정

형식 (자유 형식, 시간순 append):

```markdown
### 2026-03-05 14:30 — TASK-001 결과 검토
- Researcher가 호환성 매트릭스 완료 보고
- Kontakt 8, BBC SO 동작 확인. SWAM 불가.
- → Developer에게 TASK-002 (코어 파이프라인) 분배. Kontakt 8로 먼저 시작.
```

---

## 5. 단독 모드: 태스크 디스패치

### 순차 실행 (의존성 있는 태스크)

```bash
# 1. 태스크 지시서 작성
#    workspace/shared/announcements/TASK-001.md

# 2. Researcher에게 디스패치
bash scripts/cmd.sh dispatch researcher \
  workspace/shared/announcements/TASK-001.md {project}

# 3. (비동기 — Manager는 다른 작업 가능)
#    Researcher가 message.sh로 완료 알림을 Manager에게 직접 전달

# 4. 결과 확인 후 다음 에이전트에게 디스패치
bash scripts/cmd.sh dispatch developer \
  workspace/shared/announcements/TASK-002.md {project}
```

- dispatch가 실행되면 `reports/tasks/{task-id}-{agent}.md` 보고서 stub도 함께 준비된다.
- 에이전트는 완료 전에 보고서를 채우고 `- **Status**: final`로 바꿔야 한다.
- `task_complete`는 이 보고서가 final 상태일 때만 허용된다.

### 병렬 실행 (독립 태스크)

```bash
# 1. 독립 태스크 지시서 작성
#    TASK-A.md, TASK-B.md

# 2. 동시 디스패치
bash scripts/cmd.sh dispatch researcher \
  workspace/shared/announcements/TASK-A.md {project}
bash scripts/cmd.sh dispatch developer \
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

- 합의는 **반자동** — cmd.sh에 도구(`dual-dispatch` 등)만 제공하고, Manager가 문서화된 절차를 따라 직접 판정한다.
- Monitoring 에이전트는 dual에서도 **solo로 부팅**한다 (이중 실행 불필요).

### 6.2 이중 부팅

`cmd.sh boot`가 project.md의 `실행 모드: dual`을 감지하면 자동으로 이중 부팅한다:

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
bash scripts/cmd.sh dual-dispatch {role} {task-file} {project}
```

양쪽 윈도우(`{role}-claude`, `{role}-codex`)에 동일한 태스크를 전달한다. 단독 dispatch도 여전히 사용 가능 — 특정 백엔드 윈도우에만 전달하고 싶을 때.
- dual-dispatch는 `reports/tasks/` 아래에 팀별 보고서 2개와 Manager 합의 보고서 stub 1개를 함께 만든다.

### 6.4 합의 절차

Manager가 다음 6단계를 수동으로 수행한다:

1. **결과 수집**: 양쪽 에이전트의 `task_complete` 메시지를 대기. 한쪽이 먼저 완료해도 다른 쪽을 기다린다 (타임아웃은 Manager 판단).
2. **합의 문서 생성**: 양쪽 결과를 비교하여 `workspace/shared/discussions/DISC-NNN.md`에 합의 문서를 작성한다. 형식은 `formats.md` 토론 템플릿을 따른다.
3. **교차 전달**: message.sh로 양쪽 에이전트에 `consensus_request`를 보낸다.
   ```bash
   bash scripts/message.sh {project} manager {role}-claude \
     consensus_request normal "합의 요청" "workspace/shared/discussions/DISC-NNN.md를 읽고 의견을 추가하라."
   bash scripts/message.sh {project} manager {role}-codex \
     consensus_request normal "합의 요청" "workspace/shared/discussions/DISC-NNN.md를 읽고 의견을 추가하라."
   ```
4. **판정**: 양쪽 응답 확인 후 Manager가 판정한다.
   - **동의**: 합의 결과를 채택하고 문서에 결론을 기록한다.
   - **대립**: 2차 라운드를 진행한다.
5. **2차 라운드** (최대 1회 추가): 대립 지점을 명확히 하여 양쪽에 재질의한다. 2차에서도 미합의 시 Manager가 직접 판정하거나 유저에게 에스컬레이션한다.
6. **결과 확정**: 합의 문서를 `memory/knowledge/discussions/`로 이동하고, 최종 결과를 정식 위치에 배치한다.

### 6.5 작업 영역 분리 (Git Worktree)

Dual 모드에서는 양쪽 에이전트가 코드 충돌을 피하기 위해 **git worktree**로 물리적 디렉토리를 분리한다.

**전제**: project.md에 `프로젝트 폴더` 필드가 설정되어 있어야 한다 (코드 레포 경로).

#### 생명주기

```
boot (dual)
  ├─ git worktree add .worktrees/{role}-claude -b dual/{role}-claude
  └─ git worktree add .worktrees/{role}-codex  -b dual/{role}-codex

dispatch → 각자 자기 워크트리에서 코드 수정

consensus → Manager가 winner 결정

merge-worktree {role} {winner} {project}
  ├─ git checkout main
  ├─ git merge dual/{role}-{winner}
  ├─ git worktree remove .worktrees/{role}-claude
  ├─ git worktree remove .worktrees/{role}-codex
  └─ git branch -D dual/{role}-claude dual/{role}-codex
```

- `cmd.sh boot`가 dual 모드에서 자동으로 `create_worktrees`를 호출한다.
- 부팅 메시지에 워크트리 경로가 포함되어, 에이전트는 자기 워크트리에서만 작업한다.
- 메인 레포 루트의 top-level ignored 지원 디렉토리(예: `states/`, `node_modules/`, `.venv/`)는 worktree에 심볼릭 링크로 재사용된다.
- 합의 후 Manager가 `cmd.sh merge-worktree {role} {winner} {project}`로 winner를 main에 merge하고 양쪽 worktree + 브랜치를 정리한다.
- `프로젝트 폴더`가 미설정이면 worktree 생성을 건너뛴다 (기존 동작 유지).

#### 프레임워크 산출물 분리

코드 레포의 worktree와 별개로, 프레임워크 산출물(토론 문서, 보고서 등)은 기존과 동일하게 `workspace/` 경로를 사용한다.

### 6.6 에이전트 식별

Dual 모드에서는 message.sh의 from 인자에 `{role}-{backend}`를 사용한다:

- `researcher-claude`, `researcher-codex` 등
- Manager가 어느 백엔드의 보고인지 구별할 수 있다.
- 부팅 메시지에서 agent_id로 자동 설정된다.

### 6.7 한쪽 장애 시

- 한쪽 백엔드만 크래시되면 monitor.sh가 해당 윈도우만 독립적으로 reboot한다.
  - 예: `researcher-codex` 크래시 → `cmd.sh reboot researcher-codex {project}`
- 한쪽만 결과를 낸 경우 Manager가 해당 결과만으로 채택 가능 (합의 불필요 판정).

---

## 7. 파일 접근 규칙

### 프로젝트 폴더 (코드)

- **Developer만 수정 가능**. 다른 에이전트는 읽기 전용.
- Researcher의 실험/프로토타입 코드는 `workspace/teams/research/`에 작성.
- 프로토타입을 프로덕션에 반영하려면 Developer가 재설계 (기존 규칙).

### 프레임워크 산출물

- `workspace/shared/`: 새 파일 생성만 가능 (append-only, 기존 규칙)
- `workspace/teams/{role}/`: 해당 역할만 쓰기
- `memory/{role}/`: 해당 역할만 쓰기
- `memory/knowledge/index.md`: Manager만 수정

### 도구 수준 제약 (이미 적용 중)

- Developer: Write, Edit 도구 사용 가능
- Researcher, Manager, Monitoring: Write, Edit 도구 없음 (profile.md agent-meta)

---

## 8. 모델 및 도구 정책

각 에이전트의 모델과 허용 도구는 `agents/{role}/profile.md`의 `<!-- agent-meta -->` 블록에 정의된다. cmd.sh가 부팅 시 자동 파싱하여 `--model`과 `--allowedTools` 플래그로 적용한다.

| 역할 | 모델 | 허용 도구 | 근거 |
|------|------|-----------|------|
| Manager | opus | Read,Glob,Grep,Bash,WebSearch,WebFetch | 오케스트레이션 전용. 코드 작성(Write/Edit) 불가 |
| Developer | opus | 전체 | 프로덕션 코드 담당 |
| Researcher | opus | Read,Glob,Grep,Bash,WebSearch,WebFetch | 코드 직접 수정 불가. 프로토타입은 Bash로 |
| Monitoring | haiku | Read,Glob,Grep,Bash | 읽기 + 상태 체크만 |

- `--dangerously-skip-permissions`는 유지 (도구 승인 바이패스). `--allowedTools`는 사용 가능한 도구 범위를 제한한다.
- `--resume`은 `--allowedTools`를 계승하지 않으므로, resume 시에도 명시적으로 전달한다.
- 메타데이터가 없는 에이전트는 fallback (opus, 전체 도구).

**턴 제한**: 없음. `--max-turns` 플래그를 사용하지 않는다.

---

## 9. 안전장치

### 자동 리부팅

- monitor.sh가 에이전트 윈도우 소멸 감지 시 `cmd.sh reboot` 자동 호출
- **최대 3회**까지 시도. 매 시도마다 Manager에게 message.sh로 보고.
- 3회 초과 시 reboot 포기, 수동 개입 요청 에스컬레이션.
- 윈도우가 정상 확인되면 카운터 자동 리셋.

### 행(hung) 감지

- tmux `window_activity` (마지막 활동 Unix epoch) 기반.
- **10분(600초)** 이상 비활성 시 Manager에게 1회 알림 (중복 방지 flag).
- **알림만, 자동 kill 안 함** — 긴 bash 명령 실행 중일 수 있으므로 Manager 판단에 위임.
- 활동 재개 시 flag 자동 클리어.

### 구조화 로깅

모든 이벤트를 2개의 텍스트 로그 파일로 기록한다 (`logs/`):

| 파일 | 내용 | 기록 주체 |
|------|------|-----------|
| `system.log` | 인프라 이벤트 (부팅/종료/크래시/디스패치 등) | cmd.sh, monitor.sh |
| `message.log` | 에이전트 간 메시지 전달 이력 | message.sh |

로거: `scripts/log.py` (Python 3, fcntl 잠금, 10MB 로테이션 3세대).

형식 예시:
```
2026-03-03 18:35:42 [info] orchestrator agent_boot researcher session=abc-123
2026-03-03 18:35:42 [warn] monitor crash_detected developer count=0/3
2026-03-03 18:35:42 [delivered] researcher → manager task_complete normal "TASK-001 완료"
2026-03-03 18:35:42 [skipped] manager → researcher need_input normal "방향 선택 필요" reason="no claude process"
```

사후 분석 예시:
```bash
# 특정 에이전트의 이벤트
grep "researcher" logs/system.log

# 크래시/리부트 이력
grep -E "crash|reboot" logs/system.log

# 실패한 메시지 전달
grep "skipped" logs/message.log
```

### monitor 자가 heartbeat

- 매 헬스 체크 사이클(30초)마다 `runtime/manager-state.tsv`의 `monitor_heartbeat`에 Unix epoch 기록.
- `cmd.sh status`에서 heartbeat 신선도 확인. 90초 이상이면 좀비 경고 표시.

### 기타

- **tmux 세션 관리**: cmd.sh shutdown으로 깔끔한 정리 (런타임 파일 포함)
- **파일 충돌 방지**: 병렬 실행 시 양쪽 에이전트가 같은 파일에 쓰지 않도록 각각 별도 경로 사용

---

## 10. 병렬 실행 시 파일 소유권

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

## 11. 알림 프로토콜

### 전달 방식

message.sh가 수신자의 interactive 세션에 직접 입력한다. rich TUI는 literal typing, 셸/REPL은 paste 기반 전달을 사용한다. 파일 중개 없음.

### 알림 형식

```
[notify] {from} → {to} | {kind} | 제목: {subject} | 내용: {content}
[URGENT] {from} → {to} | {kind} | 제목: {subject} | 내용: {content}
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
| consensus_response | 합의 응답 (dual 모드) | "synth: Codex 구조 + Claude 예외 처리 채택" |
| alert_resolve | 유저 알럿 해결 완료 | "블로커 해결됨" (subject가 원본 알럿과 동일해야 매칭) |

### 사용법

```bash
# 에이전트가 Manager에게 완료 보고
bash scripts/message.sh {project} researcher manager \
  task_complete normal "TASK-001 완료" "리서치 결과를 workspace/teams/research/에 작성함"

# 에이전트가 다른 에이전트에게 직접 알림
bash scripts/message.sh {project} researcher developer \
  status_update normal "API 스펙 확정" "workspace/teams/research/api-spec.md 참조"
```

### 규칙

- 알림은 **짧은 알림** 전용. 상세 내용은 별도 문서에 두고 참조만.
- 기존 소통(토론, 회의, 공지) 규칙을 **대체하지 않는다**. 실시간 알림으로 보충할 뿐.
- priority: urgent는 `[URGENT]` 접두어로 표시된다.
- `task_assign`는 Manager만 발행한다.
- `task_complete`, `agent_ready`, `reboot_notice`는 Manager만 정식 수신한다.
- peer direct는 `status_update`, `need_input`, `escalation`, `consensus_request`, `consensus_response`만 허용한다.
- peer direct 메시지는 Manager에도 자동 미러링된다.
- 메시지 로그(`logs/message.log`)가 이력을 기록한다.

---

## 12. Monitor 연동

### monitor.sh 역할

- **헬스 체크**: 30초 주기 포그라운드 루프
  - 에이전트 윈도우 소멸 시 자동 reboot (최대 3회)
  - 10분 비활성 에이전트 감지 시 Manager에게 message.sh로 알림
  - Claude pane의 `plan mode on` 상태 감지 시 Manager에게 `need_input` 알림
- 자가 heartbeat 기록 (좀비 감지용)

### Manager가 알림 받았을 때

| 알림 kind | Manager 행동 |
|-----------|-------------|
| agent_ready | 에이전트 준비 확인, 대기 중인 태스크가 있으면 디스패치 |
| task_complete | 결과물 확인, 다음 단계 진행. dual 모드에서는 양쪽 완료 후 합의 절차(§6.4) 시작 |
| status_update | 참고. 필요 시 추가 지시 |
| need_input | 결정이 Manager 범위면 응답, 아니면 유저 에스컬레이션. monitor의 `plan mode 판단 필요` 알림이면 해당 agent pane 최근 출력과 현재 task/report를 읽고 승인 대기인지 단순 설계 단계인지 판단 |
| escalation | 유저에게 보고 |
| reboot_notice | 에이전트 복구 상태 확인, 필요 시 수동 개입 |
| consensus_request | (dual 모드) 에이전트에게 합의 문서 검토 요청. 응답 대기 후 판정(§6.4) |

### monitor.sh 관리

```bash
# 상태 확인
bash scripts/cmd.sh status {project}

# monitor.sh 상태 확인 + 자동 재시작
bash scripts/cmd.sh monitor-check {project}

# monitor.sh는 cmd.sh boot 시 자동 시작, shutdown 시 자동 종료
# PID는 runtime/manager-state.tsv의 `monitor_pid`에 저장
# 로그는 logs/system.log에 기록
```

Manager가 주기적으로 `monitor-check`를 호출하여 monitor.sh의 생존을 확인한다:
- PID + heartbeat 확인
- 프로세스 죽었으면 자동 재시작
- heartbeat 90초 이상이면 좀비로 판정 → 강제 종료 후 재시작

### Manager 감시

monitor.sh는 Manager 윈도우도 감시 대상에 포함한다. Manager 크래시 시:
- 자동 reboot 시도 (최대 3회)
- Manager에게 알림 전달은 불가하므로 (수신자가 크래시 상태) 로그에만 기록

### 유저 알림 프로토콜

Manager가 유저에게 직접 보고할 때 `to=user`로 message.sh를 사용한다. 대시보드 USER ALERTS 패널에 자동 표시된다.

```bash
# 에스컬레이션 (긴급)
bash scripts/message.sh {project} manager user escalation urgent "블로커 발생" "researcher 3회 리부팅 실패, 수동 개입 필요"

# 입력 요청
bash scripts/message.sh {project} manager user need_input normal "방향 선택 필요" "A안과 B안 중 유저 결정 필요"

# 필요 시 Slack 병행 알림
bash scripts/slack.sh {project} "블로커 발생" "researcher 3회 리부팅 실패, 수동 개입 필요" urgent
```

- `to=user`일 때 tmux 전달 없이 message.log에만 기록 (유저는 tmux 윈도우가 없으므로)
- 대시보드가 message.log에서 `kind=escalation|need_input` + `receiver=user`를 필터하여 표시
- Slack webhook과 병행 사용 가능 (대시보드 + Slack 이중 채널)

---

## 13. 크래시 복구

### 자동 복구 (monitor.sh → reboot)

1. monitor.sh가 30초 헬스 체크 주기로 에이전트 윈도우 존재 확인
2. sessions.md에서 active 역할을 파싱 (하드코딩 아님)
3. 윈도우 소멸 감지 시:
   - `runtime/reboot-state.tsv`에서 role별 reboot 카운터 확인
   - 3회 미만이면 `cmd.sh reboot {role} {project}` 자동 호출
   - 성공/실패 모두 카운터 증가 + Manager에게 message.sh로 보고
   - 3회 초과 시 reboot 포기, 수동 개입 요청 에스컬레이션
4. 윈도우가 정상 확인되면 카운터 자동 리셋

### 수동 복구 (cmd.sh reboot)

```bash
bash scripts/cmd.sh reboot {role} {project}
```

동작:
1. 기존 윈도우 있으면 `/exit` 전송 후 kill
2. sessions.md에서 해당 역할의 이전 행을 `crashed`로 표시
3. `claude -p`로 새 세션 생성 (build_boot_message 재사용)
4. tmux 윈도우 생성 + `claude --resume`
5. sessions.md에 새 행 추가

### 세션 리프레시 (cmd.sh refresh)

맥락이 과도하게 길어졌을 때 Manager가 수동 호출:

```bash
bash scripts/cmd.sh refresh {role} {project}
```

동작:
1. 에이전트에게 `memory/{role}/handoff.md` 작성 지시 (tmux send-keys)
2. 최대 2분 대기 (handoff.md 파일 생성 감시)
3. 기존 세션 종료 (/exit → kill-window)
4. sessions.md에서 이전 행을 `refreshed`로 표시
5. 새 세션 부팅 (온보딩 + "10. handoff.md를 읽어라" 추가)

자동 트리거는 하지 않음 — Manager 판단에 위임.

---

## 14. 동적 에이전트 스폰

에이전트가 오래 걸리는 작업 중일 때 같은 역할의 추가 인스턴스를 스폰해서 다른 태스크를 병렬 수행한다. 작업이 끝나면 종료한다.

### 사용 시점

- 에이전트가 긴 태스크 실행 중이고, 같은 역할에 새 태스크를 병렬로 줘야 할 때
- 긴급 핫픽스가 필요한데 해당 역할 에이전트가 바쁠 때

### 스폰

```bash
bash scripts/cmd.sh spawn {role} {window-name} {project} [extra-msg]
# 예시: researcher가 바쁠 때 researcher-2 추가
bash scripts/cmd.sh spawn researcher researcher-2 myproject
# 예시: 핫픽스 전용 developer
bash scripts/cmd.sh spawn developer dev-hotfix myproject "긴급 버그 수정 전용"
```

### 종료

```bash
bash scripts/cmd.sh kill-agent {window-name} {project}
# 예시
bash scripts/cmd.sh kill-agent researcher-2 myproject
```

### 공유 범위

- 동일 프로젝트의 메모리, workspace를 **공유**한다
- 같은 파일 동시 수정만 **금지** — 스폰 시 부팅 메시지에 주의사항이 자동 포함된다
- message.sh로 `researcher-2` 등 window_name으로 알림 송수신 가능

### 자동 감시

- monitor.sh가 sessions.md의 tmux target을 파싱하므로 동적 에이전트도 자동 감시 대상
- 크래시 시 자동 reboot 동작 (기존과 동일)

### 주의사항

- 스폰된 에이전트는 `shutdown` 시 다른 에이전트와 함께 일괄 종료된다
- window_name 중복은 자동으로 거절된다

---

## 15. Claude Code vs Codex CLI 호환성 매트릭스

| 기능 | Claude Code | Codex CLI |
|------|-----------|---------|
| 무인 실행 | --dangerously-skip-permissions | --dangerously-bypass-approvals-and-sandbox |
| --resume (세션 재개) | O | X |
| Hooks (.claude/) | O | X |
| message.sh (Bash) | O | O |
| tmux send-keys | O | O |

양쪽 모두 바이패스 플래그로 무인 실행한다. Dual 모드에서 Codex CLI 측은 `--resume` 등 CLI 플래그 기반 세션 제어가 불가하므로, 부팅 메시지와 알림 프로토콜에만 의존한다.
