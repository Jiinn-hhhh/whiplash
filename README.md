# Whiplash

> AI들을 채찍질해서 훌륭한 결과를 낸다.

AI 에이전트들이 팀으로 협업하는 프레임워크. 코드가 아니라 **마크다운 문서**로 역할, 절차, 소통 규칙을 정의하면 에이전트가 읽고 따른다.

[English](README-EN.md)

---

## 빠른 시작

### 1. 설치

```bash
# 필수
npm install -g @anthropic-ai/claude-code
brew install tmux jq        # 또는 apt install tmux jq
pip install rich             # 대시보드용

# 선택 (dual 모드)
# Codex CLI: https://github.com/openai/codex

git clone https://github.com/Jiinn-hhhh/whiplash.git
cd whiplash
```

### 2. 실행

whiplash 디렉토리에서 Claude Code를 열고 대화한다.

```
"새 프로젝트 시작할래"
"midi-render 이어하자"
```

### 3. 이후 흐름

```
유저 대화 → Onboarding이 프로젝트 설계 → Manager + Discussion이 control plane 구성 → 에이전트들이 작업
```

에이전트가 돌아가는 모습은 tmux로 관찰한다:
```bash
tmux attach -t whiplash-{project-name}
# Ctrl-b + n/p/숫자 로 윈도우 전환
# 0번 윈도우가 실시간 대시보드
```

**여기까지만 알면 사용할 수 있다.** 아래는 프레임워크의 동작 원리와 설계 상세.

---
---

## 핵심 아이디어

- 에이전트를 잘 쓰는 것은 **프롬프트 엔지니어링이 아니라 환경 엔지니어링**이다.
- 같은 모델이라도 harness(구조) 설계에 따라 결과가 2배 이상 차이난다.
- "더 잘 해"가 아니라 **"이 구조 안에서 해"**라고 제약을 주는 것이 핵심.

---

## 조직 구조

```
유저 — 가끔 개입. 진짜 중요한 것만.
 ├── Onboarding — 새 프로젝트 시작 시 1회성 설계 담당
 ├── Discussion — 장문 전략/설계/우선순위 토론 담당
 └── Manager — 실행 허브. 상태/블로커/태스크 분배/보고
      ├── Researcher (리서치팀장)
      ├── Developer (개발팀장)
      ├── Systems Engineer (플랫폼팀장, 선택)
      └── Monitoring (독립 관찰자)
```

<details>
<summary>에이전트 상세</summary>

| 에이전트 | 역할 | 모델 | 허용 도구 |
|---------|------|------|-----------|
| **Onboarding** | 유저와 대화하며 프로젝트를 설계. project.md 생성 후 Manager에게 인계 | opus | Read,Glob,Grep,Write,Edit,Bash |
| **Discussion** | 유저와 장문 전략/설계/우선순위 토론. 결정이 실행 변경으로 이어질 때 manager handoff 작성 | opus | Read,Glob,Grep,Write,Edit,Bash,WebSearch,WebFetch,Agent |
| **Manager** | 유저 ↔ 팀 허브. 에이전트 생성·관리, 태스크 분배, 결과 조율, 유저 보고 | opus | Read,Glob,Grep,Bash,WebSearch,WebFetch,Agent |
| **Researcher** | 자료 수집·분석, 실험(프로토타입 수준), 방향 제안 | opus | Read,Glob,Grep,Bash,WebSearch,WebFetch,Agent |
| **Developer** | 프로덕션 애플리케이션 코드 구현, 테스트, 아키텍처 설계 | opus | 전체 |
| **Systems Engineer** | live 시스템, 배포 경로, 런타임, 클라우드, 드리프트 분석 | opus | 전체 + Agent |
| **Monitoring** | 독립 관찰자. 인프라·환경 상태 점검 | haiku | Read,Glob,Grep,Bash |

- 모델과 허용 도구는 각 에이전트의 `profile.md` 내 `<!-- agent-meta -->` 블록에 정의
- `cmd.sh`가 부팅 시 자동 파싱하여 `--model`과 `--allowedTools` 플래그로 적용
- Developer와 Systems Engineer가 code/runtime 변경 권한의 중심이고, Discussion은 decision note/handoff 문서 작성을 위해 제한적으로 Write/Edit를 가진다
- prod/staging 외부 반영은 프로젝트 문서와 사용자 지시 기준으로 판단한다

</details>

---

## 실행 모드

| 모드 | 설명 | tmux 윈도우 구성 | 비용 |
|------|------|-----------------|------|
| **solo** | Manager가 역할별 에이전트를 하나씩 실행 (tmux 기반) | `manager`, `discussion`, `developer`, `researcher`, `monitoring`, 필요 시 `systems-engineer` | 1x |
| **dual** (실험적) | 같은 태스크를 Claude Code + Codex CLI 이중 실행, Manager가 합의 도출 | `manager`, `discussion`, `developer-claude`, `developer-codex`, `researcher-claude`, `researcher-codex`, `monitoring`, 필요 시 `systems-engineer`(solo) | 2x |

- Dual 모드에서 Monitoring은 항상 solo로 실행 (이중 실행 불필요)
- Discussion은 항상 solo로 실행 (전략 토론 역할, backend 복제 불필요)
- Systems Engineer는 dual 모드에서도 기본적으로 solo로 실행
- 실행 모드는 온보딩 시 유저가 선택, `project.md`에 기록

## 작업 루프

| 루프 | 설명 |
|------|------|
| **guided** | 현재 기본값. 필요 시 user 확인/승인을 거친다 |
| **ralph** | user 승인 대기 없이 팀이 계속 진행한다. blocker, scope 축소, 최종 완료만 user에게 notify 한다 |

- `실행 모드(solo/dual)`와 `작업 루프(guided/ralph)`는 별도 축이다.
- `ralph`를 선택하면 onboarding에서 user가 직접 `랄프 완료 기준`과 `랄프 종료 방식`을 정한다.
- `랄프 종료 방식`
  - `stop-on-criteria`: 완료 기준 충족 시 종료
  - `continue-until-no-improvement`: 완료 기준 충족 후에도 개선을 계속하고, 팀이 보수적으로 더 이상 의미 있는 개선이 어렵다고 판단할 때만 종료

## 대화 라우팅

- 전략, 설계, 요구사항, 우선순위, 코드 방향 토론은 `discussion`과 한다.
- 현재 진행 상황, 누가 작업 중인지, blocker, idle 상태, runtime health는 `manager`에게 묻는다.
- `discussion`이 실행 변경이 필요한 결론을 내리면 `memory/discussion/handoff.md`로 정리하고 `manager`가 이를 실행 계획에 반영한다.

## Native Subagents

- 이 레포는 repo-local native subagent pack을 함께 제공한다.
  - Claude Code: `.claude/agents/`
  - Codex CLI: `.codex/agents/`
- `manager`, `discussion`, `developer`, `researcher`, `systems-engineer`는 비사소한 작업에서 이 pack을 **기본적으로** 사용한다.
- `manager`는 목표와 제약을 설정하고, `developer` / `researcher` / `systems-engineer`는 어떤 specialist subagent를 내부적으로 호출할지 스스로 결정한다.
- 기본 규칙은 역할별 `techniques/subagent-orchestration.md`에 있고, 현재 pack 구성은 [`docs/native-subagents.md`](docs/native-subagents.md)에 정리했다.

---

## 온보딩 과정

유저가 새 프로젝트를 시작하면 Onboarding 에이전트가 대화를 통해 프로젝트를 설계한다. 설문이 아니라 토론 — 유저 답변에서 빠진 것을 파악하고 자연스럽게 파고든다.

- 기본 흐름은 `boot-onboarding`으로 onboarding 세션을 먼저 띄우고, 설계가 확정되면 onboarding이 내부적으로 `boot-manager`를 실행해 Manager에게 넘기는 것이다.
- 새 프로젝트에서 `project.md`가 아직 없으면 `boot-onboarding`이 bootstrap 초안과 기본 디렉토리를 자동 생성한다. 이 초안의 `실행 모드`, `작업 루프`, `활성 에이전트`는 온보딩 과정에서 확정한다.
- onboarding 단계에서는 필요 시 `researcher`, `systems-engineer` 보조 에이전트를 제한적으로 띄울 수 있다. `developer`, `monitoring`, `manager` spawn은 금지다.

<details>
<summary>Phase 0–7 상세</summary>

| Phase | 내용 | 산출물 |
|-------|------|--------|
| 사전 질문 | 실행 모드(solo / dual) + 작업 루프(guided / ralph) 선택 | project.md 초안, 디렉토리 구조 |
| 0. 기존 작업물 | 기존 코드/레포가 있으면 철저 분석 | — |
| 1. 큰 그림 | 프로젝트 유형, 목표, 동기 | project.md 이름·목표 |
| 2. 기존 자원 | 코드, 데이터, 참고 자료 확인 | project.md 자원 섹션 |
| 3. 제약사항 | 환경, 시간, 예산, 기술 제한 | project.md 제약 섹션 |
| 4. 성공 기준 | 정량/정성 목표 구체화 | project.md 성공 기준 |
| 5. 운영 방식 | 보고 빈도/채널, 자율 범위, 알림 채널 검증 | project.md 운영 방식 |
| 6. 팀 커스터마이징 | 에이전트별 초점 조정 + `systems-engineer` 필요 여부 확인 | team/{role}.md |
| 7. 리뷰 및 확정 | 전체 리뷰 → onboarding이 Manager 인계 | Manager tmux 부팅 |

**점진적 기록**: 마지막에 한꺼번에 쓰지 않는다. 각 Phase가 끝날 때마다 project.md에 즉시 기록한다.

</details>

<details>
<summary>Phase 5: 알림 채널 선택 + 검증</summary>

Phase 5에서 유저에게 보고 채널을 물어보고, 외부 채널 선택 시 테스트 알림으로 실제 수신을 확인한다.

선택지 예시:
- `reports/` 파일 (기본, 검증 불필요)
- Slack webhook → 테스트 메시지 전송 후 수신 확인
- 이메일 → 테스트 메일 전송 후 수신 확인

수신 실패 시 설정을 즉시 수정한다. **검증 없이 넘어가지 않는다.**

기술적 전제조건(webhook URL, 이메일 서비스 연동 등)은 project.md에 기록하고, Manager 인계 시 Developer가 우선 처리한다.

</details>

<details>
<summary>Onboarding 세션</summary>

`cmd.sh boot-onboarding {project}`는 onboarding과 dashboard가 있는 tmux 세션을 만든다. 프로젝트가 아직 없다면 bootstrap 초안 `project.md`, `team/systems-engineer.md`, `memory/knowledge/docs/change-authority.md`와 기본 디렉토리를 먼저 만든 뒤 onboarding을 띄운다. 이 단계에서 Onboarding은 기존 코드/레포 분석, project.md 초안 보강, 팀 구성 제안, `systems-engineer` 필요 여부 확인까지 진행하고, 설계가 확정되면 내부적으로 `cmd.sh boot-manager {project}`를 실행한다.

분석이 큰 경우에는 onboarding이 아래 보조 에이전트를 직접 spawn할 수 있다.
- `researcher`
- `systems-engineer`

제약:
- 윈도우 이름은 `onboarding-` 접두어가 필요하다.
- 분석/토론/문서화까지만 허용된다.
- `task_assign`, `task_complete`, 실제 구현/배포/서비스 변경은 금지다.
- 보조 에이전트의 공식 보고 대상은 Manager가 아니라 `onboarding`이다.

</details>

---

## 실행 구조

Manager가 tmux 세션 안에서 팀을 운영한다. 각 에이전트는 자기 tmux 윈도우에서 독립 실행.

```text
onboarding
tmux 세션: whiplash-{project}
  ├─ [0] dashboard
  ├─ [1] onboarding
  ├─ [2] onboarding-research   ← 선택
  └─ [3] onboarding-systems    ← 선택

manager 부팅 후 full team
tmux 세션: whiplash-{project}
  ├─ [0] dashboard             ← 실시간 TUI 대시보드 (Rich)
  ├─ [1] manager
  ├─ [2] discussion            ← 항상 solo
  ├─ [3] developer(-claude)
  ├─ [4] developer-codex       ← dual 모드만
  ├─ [5] researcher(-claude)
  ├─ [6] researcher-codex      ← dual 모드만
  ├─ [7] systems-engineer      ← 프로젝트에 따라 활성
  ├─ [8] monitoring
  └─ [9] researcher-2          ← 동적 스폰 (필요 시)
```

<details>
<summary>부팅 흐름</summary>

```text
온보딩 흐름
유저 ──→ cmd.sh boot-onboarding ──→ onboarding tmux 세션
                                         │
                                         ├─ onboarding
                                         ├─ onboarding-research (선택)
                                         └─ onboarding-systems  (선택)
                                         │
                         onboarding 내부 실행: cmd.sh boot-manager
                                         │
                                         ├─ manager 부팅
                                         └─ cmd.sh boot {project}
                                                │
                    ┌───────────┬────────────┬───────────┬───────────┐
                    ↓           ↓            ↓           ↓           ↓
                dashboard   discussion   developer   researcher   systems-engineer   monitoring
                                         (-claude)   (-claude)
                                         (-codex)    (-codex)     ← dual 모드
```

1. `boot-onboarding`이 onboarding 세션과 dashboard를 만든다.
2. Onboarding이 기존 작업물 분석, project.md 초안, 팀 제안을 진행한다.
3. 필요 시 onboarding이 `researcher`/`systems-engineer` 보조 분석 에이전트를 spawn한다.
4. 유저와 최종 리뷰가 끝나면 onboarding이 내부적으로 `cmd.sh boot-manager {project}`를 실행한다.
5. Manager가 준비되면 `cmd.sh boot {project}`가 `discussion`과 정식 팀을 부팅한다.
6. 모든 정식 에이전트가 `agent_ready` 알림을 보내면 Manager가 첫 태스크를 분배한다.

</details>

<details>
<summary>부팅 기술 상세</summary>

온보딩 흐름에서는 `cmd.sh boot-onboarding`이 onboarding을 먼저 띄우고, 온보딩이 끝나면 내부적으로 `cmd.sh boot-manager`가 실행된다. 직접 시작이 필요한 경우에는 기존처럼 `cmd.sh boot-manager`로 바로 Manager를 올릴 수도 있다.

각 에이전트 부팅 과정:
1. `profile.md`의 `<!-- agent-meta -->` 블록에서 모델과 허용 도구 파싱
2. `claude -p "{부팅메시지}" --model {model} --allowedTools {tools} --output-format json` → session_id 획득
3. `tmux new-window -d -n {role}` → 윈도우 생성 (백그라운드, 현재 윈도우 유지)
4. `claude --resume {session_id} --allowedTools {tools}` → 인터랙티브 세션 시작 (`--resume`이 플래그를 계승하지 않으므로 재전달)
5. `sessions.md`에 기록
6. `--dangerously-skip-permissions` 플래그로 무인 실행 (도구 승인 바이패스)

부팅 메시지에 Progressive Disclosure 3단계 온보딩 절차와 알림 프로토콜이 자동 포함된다.

</details>

### 소통

실시간 알림과 구조화 문서를 병행한다.

| 채널 | 구현 | 용도 |
|------|------|------|
| 실시간 알림 | `message.sh` → interactive 세션 직접 입력 | 태스크 완료, 상태, 긴급 에스컬레이션 |
| 토론 | `workspace/shared/discussions/DISC-NNN.md` (append-only) | 기술 의사결정 |
| 회의 | `workspace/shared/meetings/MEET-NNN.md` (3라운드) | 입장→응답→종합 |
| 공지 | `workspace/shared/announcements/` | 태스크 지시서 (TASK-NNN.md) |

알림 종류: `task_complete`, `status_update`, `need_input`, `escalation`, `agent_ready`, `reboot_notice`, `consensus_request`, `consensus_response`, `task_assign`, `alert_resolve`

- `task_assign`는 Manager만 발행한다.
- `task_complete`, `agent_ready`, `reboot_notice`의 정식 수신자는 Manager다.
- peer direct는 `status_update`, `need_input`, `escalation`, `consensus_request`, `consensus_response`만 허용한다.
- peer direct는 Manager에도 자동 미러링된다.

### 태스크 분배

```bash
# solo 모드: 단일 에이전트에 태스크 전달
cmd.sh dispatch {role} {task-file} {project}

# dual 모드: 양쪽 백엔드에 동일 태스크 전달
cmd.sh dual-dispatch {role} {task-file} {project}
```

Manager가 `workspace/shared/announcements/TASK-NNN.md`에 지시서를 작성하고, `dispatch`/`dual-dispatch`로 전달. 에이전트는 완료 후 `message.sh`로 `task_complete` 보고.

- 각 top-level task는 완료 전에 `reports/tasks/{task-id}-{agent}.md` 결과 보고서를 남긴다.
- `dispatch`/`task_assign` 시 보고서 stub가 자동 생성된다.
- `task_complete`는 보고서의 `Status`가 `final`이고 placeholder가 제거된 뒤에만 허용된다.

### 동적 스폰

에이전트가 긴 태스크 중일 때 같은 역할의 추가 인스턴스를 투입한다.

```bash
cmd.sh spawn {role} {window-name} {project}     # 추가 투입
cmd.sh kill-agent {window-name} {project}        # 종료
```

동일 프로젝트의 메모리·workspace를 공유하되, 같은 파일 동시 수정은 금지. `monitor.sh`가 스폰된 에이전트도 자동 감시.

<details>
<summary>Dual 모드 합의 절차</summary>

1. **결과 수집**: 양쪽(`{role}-claude`, `{role}-codex`)의 `task_complete` 메시지 대기
2. **합의 문서 생성**: 양쪽 결과 비교 → `DISC-NNN.md`에 합의 문서 작성
3. **교차 전달**: 양쪽 에이전트에 `consensus_request` 전송, 의견 추가 요청
4. **판정**: 동의하면 채택, 대립하면 2차 라운드 (최대 1회 추가)
5. **2차 미합의**: Manager가 직접 판정하거나 유저에게 에스컬레이션
6. **확정**: 합의 문서를 `memory/knowledge/`로 이동, 결과를 정식 배치

작업 영역 분리:
- Claude: `workspace/teams/{team}/{role}-claude/`
- Codex: `workspace/teams/{team}/{role}-codex/`
- 합의 후 Manager가 최종 결과를 정식 위치에 배치

</details>

---

## 장애 대응

`monitor.sh`는 nohup 백그라운드 데몬으로 30초마다 헬스체크를 수행한다.

| 감지 | 동작 | 상세 |
|------|------|------|
| **크래시** (윈도우 소멸) | `cmd.sh reboot` 자동 호출 (최대 3회) | 매 시도마다 Manager에게 보고. 3회 초과 시 수동 개입 에스컬레이션 |
| **행(hung)** (10분 비활성) | Manager에게 1회 알림 | 자동 kill 안 함 (긴 bash 가능성). 활동 재개 시 자동 해제 |
| **monitor 좀비** (heartbeat 90초+) | `cmd.sh monitor-check`로 감지 → 강제 재시작 | Manager가 주기적 호출 |
| **맥락 과다** | `cmd.sh refresh` → handoff → 새 세션 | Manager 판단으로 수동 호출 |

<details>
<summary>크래시 복구 상세</summary>

1. `monitor.sh`가 `sessions.md`에서 active 역할 파싱 (하드코딩 아님)
2. tmux 윈도우 소멸 감지 시 `reboot-counts/{role}.count`에서 카운터 확인
3. 3회 미만이면 `cmd.sh reboot` 호출:
   - 기존 윈도우 kill → sessions.md crashed 표시
   - 중단된 태스크 조회 (`assignments.md`)
   - 새 세션 부팅 (pending task 자동 복구 지시 포함)
4. 3회 초과 시 reboot 포기 → 에스컬레이션
5. 윈도우 정상 확인되면 카운터 자동 리셋

Dual 모드에서는 각 백엔드(`{role}-claude`, `{role}-codex`)가 독립적으로 관리된다.

</details>

<details>
<summary>세션 리프레시 상세</summary>

맥락이 과도하게 길어졌을 때 Manager가 수동 호출:

```bash
cmd.sh refresh {role} {project}
```

1. 에이전트에게 `memory/{role}/handoff.md` 작성 지시
2. 최대 2분 대기 (handoff.md 파일 생성 감시)
3. 기존 세션 종료 → sessions.md `refreshed` 표시
4. 새 세션 부팅 + "handoff.md를 읽어라" 지시 추가

</details>

---

## 대시보드

`dashboard.py`가 tmux 세션의 0번 윈도우에서 실시간 TUI를 제공한다. Rich 라이브러리 기반.

표시 정보:
- 에이전트별 상태 (실제 child process 기준 alive/crashed/absent)
- 진행 중인 태스크의 간단 요약 (`ACTIVE TASKS`)
- 현재 태스크 경과 시간 + task report 상태 (`DRAFT`/`FINAL`/`MISS`)
- 가장 최근에 완료됐고 다음 태스크를 기다리는 작업 알림 (`NEXT TASK WAITING`)
- Claude 에이전트의 `plan mode` 진입 감지 이벤트
- 최근 시스템 이벤트 (부팅, 크래시, 리부팅)
- 최근 메시지 전달 이력
- Monitor heartbeat + queued message 상태

```bash
# 자동: cmd.sh boot 시 dashboard 윈도우가 자동 생성됨
# 수동:
python3 dashboard/dashboard.py {project} --interval 3
```

---

## Preflight 검증

`cmd.sh boot-manager`와 `cmd.sh boot` 시 `preflight.sh`가 자동 실행된다.

검증 항목:
- **패키지**: tmux, jq, python3, pgrep — 없으면 자동 설치 시도 (brew/apt)
- **Claude CLI**: `claude` 명령어 존재 확인
- **Codex CLI**: dual 모드에서만 확인. `--dangerously-bypass-approvals-and-sandbox` 지원 여부
- **프로젝트 구조**: `project.md` 존재, 활성 에이전트의 `profile.md` 존재

최초 통과 시 `.preflight-ok` 마커를 생성하여 이후 패키지 검사를 건너뛴다. Claude/Codex 인증은 매번 실행하고, 프로젝트 구조 검증도 기본적으로 매번 실행한다. 단, `boot-onboarding`이 새 프로젝트 bootstrap 초안을 만드는 단계에서는 내부적으로 `--skip-project-check`를 사용해 이 검사를 잠시 건너뛴다.

---

## 로깅

에이전트 부팅·종료·크래시·태스크 분배 등 인프라 이벤트가 발생하면 `system.log`에 자동 기록된다. 에이전트 간 알림이 전달되거나 실패하면 `message.log`에 자동 기록된다. 에이전트 자신은 로깅을 의식하지 않는다.

<details>
<summary>로그 형식 + 예시</summary>

**system.log** — 인프라 이벤트:
```
2026-03-03 18:44:35 [info] orchestrator agent_boot researcher session=abc-123
2026-03-03 18:44:35 [warn] monitor crash_detected developer count=0/3
2026-03-03 18:44:35 [error] monitor reboot_limit developer count=3/3
2026-03-03 18:44:35 [info] orchestrator project_shutdown test-project
```

**message.log** — 메시지 전달 이력:
```
2026-03-03 18:44:35 [delivered] researcher → manager task_complete normal "TASK-001 완료"
2026-03-03 18:44:35 [skipped] manager → researcher need_input normal "방향 선택 필요" reason="no claude process"
```

기록 주체: `cmd.sh`와 `monitor.sh`가 `log.py system`을, `message.sh`가 `log.py message`를 호출한다.

</details>

<details>
<summary>grep으로 필터링</summary>

```bash
grep "\[error\]" logs/system.log           # error만
grep -E "crash|reboot" logs/system.log     # 크래시/리부팅 이력
grep "skipped" logs/message.log            # 실패한 메시지
grep "researcher" logs/system.log          # 특정 에이전트
```

</details>

<details>
<summary>로그 레벨 + 로테이션</summary>

레벨은 이벤트 종류에 따라 자동 결정:

| 레벨 | 이벤트 |
|------|--------|
| **error** | 부팅 실패, 리부팅 실패/한도 초과, 모니터 종료/좀비 |
| **warn** | 크래시 감지, 비활성 감지, 세션 부재, 알림 전달 실패 |
| **info** | 나머지 정상 동작 |

로테이션: 10MB 초과 시 `.1` → `.2` → `.3` 롤링 (최대 3세대).
동시 쓰기 보호: `fcntl.flock()`.

</details>

---

## 스크립트 참조

Manager 에이전트가 내부적으로 실행한다. 유저는 `boot-onboarding`, `boot-manager`, `shutdown`만 직접 사용한다.

```bash
# 유저 실행
cmd.sh boot-onboarding {project}                  # onboarding 세션 부팅
cmd.sh boot-manager    {project}                  # Manager 직접 부팅 (빠른 진입점)
cmd.sh shutdown       {project}                   # 전체 종료

# Manager 내부용
cmd.sh boot           {project}                   # 팀 에이전트 부팅
cmd.sh dispatch       {role} {task-file} {project} # 태스크 전달
cmd.sh dual-dispatch  {role} {task-file} {project} # 이중 태스크 전달
cmd.sh spawn          {role} {window} {project}    # 동적 에이전트 추가
cmd.sh kill-agent     {window} {project}           # 동적 에이전트 종료
cmd.sh reboot         {target} {project}           # 에이전트 재시작
cmd.sh refresh        {target} {project}           # 맥락 리프레시
cmd.sh status         {project}                   # 상태 확인
cmd.sh monitor-check  {project}                   # monitor.sh 점검

# 알림 (에이전트가 호출)
message.sh {project} {from} {to} {kind} {priority} {subject} {content}
```

---

## 프로젝트 구조

```
whiplash/
├── agents/                      # 에이전트 정의 (immutable, git tracked)
│   ├── common/                  #   공통 규칙 + 프로젝트 컨벤션
│   ├── onboarding/              #   Onboarding 에이전트
│   ├── discussion/              #   Discussion 에이전트
│   ├── manager/                 #   Manager 에이전트
│   │   ├── profile.md           #     역할 정의 + agent-meta
│   │   └── techniques/ (6)      #     업무 방법론
│   ├── researcher/              #   Researcher 에이전트
│   │   ├── profile.md
│   │   └── techniques/ (6)
│   ├── developer/               #   Developer 에이전트
│   │   ├── profile.md
│   │   └── techniques/ (5)
│   ├── systems-engineer/        #   Systems Engineer 에이전트
│   │   ├── profile.md
│   │   └── techniques/ (4)
│   └── monitoring/              #   Monitoring 에이전트
│       ├── profile.md
│       └── techniques/ (2)
├── domains/                     # 도메인 특화 정의 (git tracked)
├── scripts/                     # 인프라 스크립트
│   ├── cmd.sh                   #   오케스트레이션 (boot, dispatch, reboot 등)
│   ├── integration-test.sh      #   tmux 기반 통합 테스트
│   ├── message.sh               #   에이전트 간 실시간 알림 (tmux 직접 전달)
│   ├── monitor.sh               #   헬스체크 데몬 (크래시/행 감지)
│   ├── log.py                   #   구조화 로거 (fcntl 잠금, 로테이션)
│   └── preflight.sh             #   부팅 전 환경 검증 + 자동 설치
├── dashboard/                   # 실시간 TUI 대시보드
│   ├── dashboard.py             #   Rich Live 기반 상태 모니터링
│   └── requirements.txt         #   대시보드 의존성
├── docs/                        # 프레임워크 설계/로드맵 문서
├── feedback/                    # 프레임워크 개선 인사이트
└── projects/                    # 프로젝트별 런타임 (mutable, gitignored)
    └── {project-name}/
        ├── project.md           #   프로젝트 정의 (목표, 제약, 운영 방식)
        ├── team/                #   에이전트 커스터마이징 (선택)
        │   └── {role}.md        #     프로젝트 특화 지침 (systems-engineer 권한 표 포함 가능)
        ├── workspace/           #   진행 중인 작업
        │   ├── shared/          #     공유 (토론, 회의, 공지, 태스크 지시서)
        │   └── teams/           #     역할별 작업 디렉토리
        ├── memory/              #   축적된 상태
        │   ├── discussion/      #     전략 토론 메모, manager handoff
        │   ├── knowledge/       #     공유 지식 (index, 교훈, 아카이브, change-authority)
        │   ├── manager/         #     sessions.md, assignments.md
        │   └── {role}/          #     역할별 개인 메모리
        ├── runtime/             #   런타임 상태 파일 (manager-state.tsv, reboot-state.tsv, queue/lock)
        ├── logs/                #   인프라 로그 (system.log, message.log)
        └── reports/             #   사용자 열람용 문서
            └── tasks/           #     top-level task 결과 보고서
```

<details>
<summary>폴더 분리 근거</summary>

| 폴더 | 성격 | Git |
|------|------|-----|
| `agents/` | 프레임워크 정의 (불변) | tracked |
| `domains/` | 도메인 특화 정의 (불변) | tracked |
| `scripts/` | 인프라 스크립트 | tracked |
| `dashboard/` | 실시간 모니터링 TUI | tracked |
| `feedback/` | 프레임워크 개선 (독립) | tracked |
| `projects/` | 프로젝트별 런타임 데이터 (가변) | ignored |

**프레임워크 핵심 경로는 `agents/` + `domains/` + `scripts/` + `dashboard/` + `feedback/` + `projects/`다.** 프로젝트 데이터는 에이전트가 실행하면서 생성한다.
로컬에 `pixel-agents/`, `system_develop/` 같은 실험/보조 폴더가 함께 있어도 프레임워크 본체는 위 경로 기준으로 본다.

</details>

<details>
<summary>에이전트 레이어 분리</summary>

에이전트 지침은 3계층 보충 체계를 따른다:

| 레이어 | 위치 | 내용 | 변경 빈도 |
|--------|------|------|-----------|
| 1. 기본 | `agents/{role}/profile.md` | 역할 정의, 규칙 (무엇을/왜) | 안정적 |
| 2. 도메인 | `domains/{domain}/{role}.md` | 도메인 특화 보충 (선택) | 도메인별 |
| 3. 프로젝트 | `projects/{name}/team/{role}.md` | 프로젝트 특화 보충 (선택) | 프로젝트별 |

각 레이어는 이전 레이어를 **보충**한다. 교체하지 않는다.

방법론은 별도 분리:
| 파일 | 내용 |
|------|------|
| `techniques/*.md` | 자연어 절차 (어떻게) — 자유롭게 개선 가능 |

</details>

---

## 멀티 프로젝트

하나의 프레임워크로 여러 프로젝트를 동시에 운영한다. 각 프로젝트는 독립된 workspace, memory, logs, reports를 갖는다.

<details>
<summary>상세</summary>

- 에이전트 문서의 `workspace/`, `memory/`, `reports/` 경로는 현재 프로젝트 기준 상대 경로
- 프로젝트마다 별도의 tmux 세션 (`whiplash-{project}`)
- 크로스 프로젝트 참조는 명시적 전체 경로: `projects/{other}/memory/knowledge/...`

상세: `agents/common/project-context.md`

</details>

---

## 도메인 특화

프로젝트에 도메인을 지정하면 에이전트가 해당 분야의 추가 컨텍스트를 읽고 작업한다. 도메인은 기본 규칙을 **보충**한다. 교체하지 않는다.

<details>
<summary>상세</summary>

- `domains/{domain}/context.md` — 모든 에이전트가 읽는 도메인 배경
- `domains/{domain}/{role}.md` — 특정 에이전트의 도메인 특화 지침 (선택)
- 프로젝트에 도메인이 없으면 `general`로 동작 (추가 파일 불필요)

새 도메인 추가:
1. `domains/{domain-name}/` 폴더 생성
2. `context.md` — 도메인 배경, 개념, 용어, 품질 기준
3. (선택) `{role}.md` — 역할별 도메인 특화 지침
4. `project.md`에 도메인 설정

상세: `domains/README.md`

</details>

---

## 설계 근거

| 원칙 | 내용 |
|------|------|
| Environment Engineering | 프롬프트보다 레포 구조, 파일 컨벤션이 더 큰 레버리지 |
| 3-Folder 분리 | Immutable(agents/ + domains/)과 mutable(projects/)를 폴더 레벨에서 분리 |
| 컨텍스트 최소화 | 지도를 줘라, 백과사전을 주지 마라. index ~100줄, 교훈 30개 상한 |
| Progressive Disclosure | 문서를 3단계(필수/작업시/필요시)로 나눠 컨텍스트 윈도우 절약 |
| 백엔드 네이티브 팀 활용 | Claude Code와 Codex CLI의 subagent / agent team / 병렬 기능을 적극 활용하고, 가능하면 수동 분해보다 우선 검토 |
| 역할 기반 파일 접근 | 프로젝트 코드는 Developer와 Systems Engineer만 수정. 원격 시스템 변경은 별도 문서 정책을 따른다 |
| 시스템 변경 정책 | `systems-engineer`는 프로젝트 문서(`team/systems-engineer.md`, `change-authority.md`) 기준으로 원격 시스템 변경을 판단 |
| 백프레셔 게이트 | task_complete 전 자체 검증 필수. 검증 없이 완료 보고 금지 |
| Semantic Compaction | 비활성 교훈을 archive/로 이동 + 1줄 요약 참조 유지. 원본 보존 |
| 역할별 도구 제한 | profile.md 메타데이터로 허용 도구 정의, cmd.sh가 --allowedTools로 강제 적용 |
| Harness = 경쟁력 | 모델을 바꾸는 것보다 구조를 바꾸는 것이 더 큰 성능 향상 |
| Fail-safe | 에이전트 실패 시 사람이 대신하지 않고 환경을 개선 |

문서 전반에서 `서브에이전트`는 특별한 예외가 없는 한 Claude Code와 Codex CLI의 네이티브 subagent / agent team을 함께 가리킨다.

---

## For Agents

에이전트라면 **Progressive Disclosure** 방식으로 필요한 시점에 필요한 문서만 읽어라:

**Layer 1 — 필수 (온보딩 즉시)**
1. `agents/common/README.md` — 공통 규칙, 온보딩 절차
2. 자기 에이전트 폴더의 `profile.md` — 역할 정의
3. `projects/{name}/project.md` — 현재 프로젝트 확인

**Layer 2 — 작업 시작 시**
4. `memory/knowledge/index.md` — 지식 지도 (참조용, 전체 읽기 아님)
5. 해당 작업에 필요한 `techniques/*.md`
6. (해당 시) `domains/{domain}/context.md` — 도메인 배경

**Layer 3 — 필요 시 (on-demand)**
7. `agents/common/project-context.md` — 경로 해석 등 필요 시
8. (해당 시) `domains/{domain}/{role}.md` — 도메인 특화 지침
9. (해당 시) `team/{role}.md` — 프로젝트 특화 지침

프레임워크 자체의 비효율을 발견하면 `feedback/guide.md`를 읽고 `feedback/insights.md`에 기록해라.
