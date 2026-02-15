# Whiplash

> AI들을 채찍질해서 훌륭한 결과를 낸다.

AI 에이전트들이 팀으로 협업하는 환경을 정의하는 프레임워크.

코드가 아니라 **마크다운 문서**로 구성되어 있다. 역할 정의, 업무 절차, 소통 규칙, 지식 관리 방식을 구조화된 문서로 만들어두면, AI 에이전트가 이를 읽고 따르며 자율적으로 일한다.

---

## 시작하기

### 사전 준비

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) 설치 (`npm install -g @anthropic-ai/claude-code`)
- [tmux](https://github.com/tmux/tmux) 설치 (`brew install tmux` / `apt install tmux`)
- [jq](https://jqlang.github.io/jq/) 설치 (`brew install jq` / `apt install jq`)

### 최초 실행 (3단계)

#### 1. 레포 클론

```bash
git clone https://github.com/Jiinn-hhhh/whiplash.git
cd whiplash
```

#### 2. 온보딩 시작

Claude Code를 이 폴더에서 실행하고 한마디면 된다:

```
너는 Onboarding 에이전트다. agents/onboarding/profile.md를 읽고 새 프로젝트 온보딩을 시작해라.
```

온보딩 에이전트가 유저와 대화하면서 프로젝트를 설계한다 — 목표, 제약사항, 성공 기준, 운영 방식, 팀 구성 등을 `project.md`로 정리한다.

#### 3. 자동 부팅 → tmux 접속

온보딩이 끝나면 **전부 자동**이다:

1. `orchestrator.sh boot-manager` 실행 → Manager가 tmux 세션에 부팅됨
2. Manager가 **자동으로** `orchestrator.sh boot` 실행 → Researcher, Developer, Monitoring 부팅
3. 모든 에이전트의 `agent_ready` 확인 후 → Manager가 project.md 목표를 분석하고 첫 태스크 분배
4. 유저에게 tmux 접속 안내가 뜬다

```bash
# tmux 세션에 접속해서 에이전트들이 일하는 걸 관찰
tmux attach -t whiplash-{project-name}
# Ctrl-b + n/p/숫자 로 에이전트 윈도우 전환
```

**유저가 할 일은 온보딩 대화뿐이다.** 그 후 Manager가 팀을 꾸리고, 태스크를 분배하고, 결과를 조율한다. 유저는 tmux에서 관찰하다가 중요한 결정만 내리면 된다.

Manager 윈도우(`Ctrl-b` + `0`)에서 직접 대화할 수도 있다 — 방향 수정, 추가 지시, 진행 상황 질문 등. Manager는 `claude --resume`으로 실행되는 인터랙티브 세션이므로 일반 Claude Code처럼 대화하면 된다.

---

## 핵심 아이디어

- 에이전트를 잘 쓰는 것은 **프롬프트 엔지니어링이 아니라 환경 엔지니어링**이다.
- 같은 모델이라도 harness(구조) 설계에 따라 결과가 2배 이상 차이난다.
- "더 잘 해"가 아니라 **"이 구조 안에서 해"**라고 제약을 주는 것이 핵심.

---

## 조직 구조

```
유저 — 가끔 개입. 진짜 중요한 것만.
 ↕
Onboarding — 새 프로젝트 시작 시 유저와 대화하며 설계. Manager보다 먼저 작동.
 ↕
Manager — 유저 ↔ 팀 허브. 에이전트 인스턴스 생성, 지시 분배, 조율, 보고.
 ├── Researcher (리서치팀장) ── 서브에이전트들
 ├── Developer (개발팀장) ── 서브에이전트들
 └── Monitoring (독립 관찰자) ── 인프라/환경 점검
```

| 에이전트 | 역할 | 모델 |
|---------|------|------|
| **Onboarding** | 유저와 대화하며 프로젝트를 설계. project.md + 디렉토리 생성 후 Manager에게 인계 | - |
| **Manager** | 유저 ↔ 팀 허브. 에이전트 생성·관리, 태스크 분배, 결과 조율, 유저 보고 | sonnet |
| **Researcher** | 자료 수집·분석, 실험(프로토타입 수준), 방향 제안. Manager에게 보고 | opus |
| **Developer** | 프로덕션 코드 구현, 아키텍처 설계, 인프라 구축. Manager에게 보고 | sonnet |
| **Monitoring** | 독립 관찰자. 인프라·환경 상태 점검 (GPU, 디스크, 프로세스 등) | haiku |

---

## 실행 구조

### 전체 부팅 흐름

```
유저: "온보딩 시작해라"
  │
  ▼
Onboarding 에이전트 (일반 Claude Code 세션)
  │  유저와 대화 → project.md 생성
  │
  ├─ orchestrator.sh boot-manager {project}
  │   ├─ claude -p → Manager 온보딩 + "팀 부팅해라" 지시 포함
  │   ├─ tmux new-session whiplash-{project} → manager 윈도우
  │   ├─ claude --resume → Manager 투입
  │   └─ sessions.md + mailbox 초기화
  │
  └─ 유저에게 "tmux attach" 안내 후 종료
       │
       ▼
Manager (tmux 안, 자동 실행)                      ← 유저 개입 불필요
  │
  ├─ 온보딩 8단계 수행
  ├─ orchestrator.sh boot {project}
  │   ├─ 기존 tmux 세션 재사용
  │   ├─ Researcher, Developer, Monitoring 각각 부팅
  │   │   (claude -p → session_id → tmux new-window → claude --resume)
  │   └─ monitor.sh 백그라운드 실행
  ├─ agent_ready 메시지 대기
  ├─ project.md 목표 분석 → 첫 태스크 분배
  │
  └─ 팀 운영 시작
       ├─ 태스크 지시서 작성 → dispatch로 전달
       ├─ mailbox로 결과 수집
       └─ 유저에게 보고
```

### tmux 기반 오케스트레이션

모든 에이전트는 하나의 tmux 세션(`whiplash-{project}`) 안에 각자의 윈도우로 실행된다:

```
tmux 세션: whiplash-{project}
  ├─ [0] manager      ← Manager (claude --resume)
  ├─ [1] researcher   ← Researcher (claude --resume)
  ├─ [2] developer    ← Developer (claude --resume)
  └─ [3] monitoring   ← Monitoring (claude --resume)
```

- 유저는 `tmux attach -t whiplash-{project}`로 접속
- `Ctrl-b` + `n`/`p`/`숫자`로 에이전트 윈도우 전환
- 각 에이전트가 뭘 하고 있는지 실시간 관찰 가능

### 에이전트 부팅 과정 (각 에이전트마다)

1. **`claude -p`**: 온보딩 메시지(역할, 프로젝트, 도메인 정보)를 넘기고 `--output-format json`으로 session_id를 획득
2. **tmux 윈도우 생성**: `tmux new-window -n {role}`
3. **`claude --resume`**: 획득한 session_id로 인터랙티브 세션 시작. 에이전트가 온보딩을 마치고 대기 상태로 들어감
4. **sessions.md에 기록**: 역할, session_id, tmux target, 모델, 상태를 추적

### mailbox 통신

에이전트 간 비동기 소통은 파일 기반 mailbox(Maildir 패턴)로 이루어진다:

```
workspace/shared/mailbox/
  {role}/
    tmp/     # 작성 중 (원자적 전달용)
    new/     # 도착한 메시지 (미읽음)
    cur/     # 처리된 메시지
```

- 에이전트가 `mailbox.sh`로 메시지 전송 → 수신자의 `new/`에 파일 생성
- `monitor.sh`가 30초마다 폴링 → 새 메시지를 수신자 tmux 윈도우에 알림 전달
- 메시지 종류: `task_complete`, `status_update`, `need_input`, `escalation`, `agent_ready`, `reboot_notice`, `consensus_request`

### 자동 복구

- **크래시 감지**: monitor.sh가 에이전트 윈도우 소멸을 감지하면 자동 reboot (최대 3회)
- **행(hung) 감지**: 10분 비활성 시 Manager에게 알림 (자동 kill은 안 함 — 긴 작업 중일 수 있으므로)
- **리프레시**: 맥락이 너무 길어지면 Manager가 `refresh` 명령으로 세션 교체 (handoff.md로 인수인계)

### CLI 명령어

```bash
# Manager 부팅 (온보딩 에이전트가 호출)
bash agents/manager/tools/orchestrator.sh boot-manager {project}

# 나머지 에이전트 부팅 (Manager가 호출)
bash agents/manager/tools/orchestrator.sh boot {project}

# 에이전트에게 태스크 전달
bash agents/manager/tools/orchestrator.sh dispatch {role} {task-file} {project}

# 이중 실행 태스크 전달 (dual 모드)
bash agents/manager/tools/orchestrator.sh dual-dispatch {role} {task-file} {project}

# 상태 확인
bash agents/manager/tools/orchestrator.sh status {project}

# 에이전트 재시작
bash agents/manager/tools/orchestrator.sh reboot {target} {project}

# 에이전트 맥락 리프레시
bash agents/manager/tools/orchestrator.sh refresh {target} {project}

# 전체 종료
bash agents/manager/tools/orchestrator.sh shutdown {project}
```

### 실행 모드

| 모드 | 설명 | 부팅 |
|------|------|------|
| **단독 (solo)** | 역할별 에이전트 1개씩 | 윈도우: `researcher`, `developer`, `monitoring` |
| **멀티 (dual)** | 같은 태스크를 Claude Code + Codex CLI 양쪽에서 이중 실행 → Manager가 합의 도출 | 윈도우: `researcher-claude`, `researcher-codex`, ... |

실행 모드는 프로젝트 온보딩 시 유저가 선택하고, `project.md`에 기록된다.

---

## 프로젝트 구조 — 3-Folder 분리

```
whiplash/
├── agents/                      # 프레임워크 정의 (immutable, git tracked)
│   ├── common/                  #   공통 규칙 + 프로젝트 컨벤션
│   ├── onboarding/              #   Onboarding 에이전트
│   ├── manager/                 #   Manager 에이전트
│   │   ├── profile.md           #     역할 정의
│   │   ├── techniques/          #     업무 방법론
│   │   └── tools/               #     orchestrator.sh, monitor.sh, mailbox.sh
│   ├── researcher/              #   Researcher 에이전트
│   ├── developer/               #   Developer 에이전트
│   └── monitoring/              #   Monitoring 에이전트
│
├── domains/                     # 도메인 특화 정의 (immutable, git tracked)
│   └── deep-learning/           #   예시 도메인
│       ├── context.md           #     도메인 배경, 용어, 원칙
│       └── researcher.md        #     Researcher 추가 지침
│
└── projects/                    # 프로젝트별 런타임 (mutable, gitignored)
    └── {project-name}/
        ├── project.md           #   프로젝트 정의 (이름, 목표, 도메인, 실행 모드)
        ├── team/                #   프로젝트 레벨 에이전트 커스터마이징 (선택)
        │   └── {role}.md        #     역할별 프로젝트 특화 지침
        ├── workspace/           #   진행 중인 작업
        │   ├── shared/          #     팀 간 토론, 회의, 공지
        │   │   └── mailbox/     #     에이전트 간 실시간 알림 (Maildir 패턴)
        │   └── teams/           #     팀별 내부 작업 공간
        ├── memory/              #   축적된 상태
        │   ├── {role}/          #     에이전트 개인 메모
        │   └── knowledge/       #     공유 지식 (교훈, 문서, 아카이브)
        └── reports/             #   사용자 열람용 문서
```

### 분리 근거

| 폴더 | 성격 | Git |
|------|------|-----|
| `agents/` | 프레임워크 정의 (불변) | tracked |
| `domains/` | 도메인 특화 정의 (불변) | tracked |
| `projects/` | 프로젝트별 모든 런타임 데이터 (가변) | ignored |

**Git clone하면 `agents/` + `domains/`만 온다.** 프로젝트 데이터는 에이전트가 실행하면서 생성한다.

---

## 세 레이어 분리

각 에이전트 폴더는 세 레이어로 분리된다. 상위가 안정적일수록 하위를 독립적으로 개선할 수 있다.

| 레이어 | 내용 | 변경 빈도 |
|--------|------|-----------|
| `profile.md` | 정의 — 역할, 규칙 (무엇을/왜) | 안정적 |
| `techniques/` | 방법론 — 자연어 절차 (어떻게) | 자유롭게 개선 |
| `tools/` | 자동화 — 미리 짜둔 코드/스크립트 (실행) | 필요 시 추가 |

---

## 멀티 프로젝트

하나의 프레임워크로 여러 프로젝트를 동시에 운영한다. 각 프로젝트는 `projects/{name}/` 안에 workspace, memory, reports를 독립적으로 갖는다.

- 에이전트 문서의 `workspace/`, `memory/`, `reports/` 경로는 현재 프로젝트 기준 상대 경로로 해석된다.
- 프로젝트마다 별도의 tmux 세션(`whiplash-{project}`)이 생성된다.
- 크로스 프로젝트 참조는 명시적 전체 경로로 한다.

상세: `agents/common/project-context.md`

---

## 도메인 특화

프로젝트에 도메인을 지정하면 에이전트가 해당 분야의 추가 컨텍스트를 읽고 작업한다.

- `domains/{domain}/context.md` — 모든 에이전트가 읽는 도메인 배경
- `domains/{domain}/{role}.md` — 특정 에이전트의 도메인 특화 지침 (선택)
- 도메인은 기본 규칙을 **보충**한다. 교체하지 않는다.
- 프로젝트에 도메인이 없으면 `general`로 동작 (추가 파일 불필요)

상세: `domains/README.md`

---

## 현재 구현 현황

| 에이전트 | 역할 | profile.md | techniques/ |
|---------|------|:----------:|:-----------:|
| Onboarding | 새 프로젝트 설계, 유저와 대화하며 project.md 생성 | O | 1개 |
| Manager | 유저 ↔ 팀 허브, 에이전트 오케스트레이션, 작업 분배, 조율 | O | 5개 |
| Researcher | 연구, 분석, 실험, 방향 제안 | O | 6개 |
| Developer | 프로덕션 구현, 인프라, 품질 관리 | O | 5개 |
| Monitoring | 독립 관찰자, 인프라/환경 점검 | O | 1개 |

| 도메인 | 설명 |
|--------|------|
| deep-learning | 딥러닝 프로젝트 (context.md + researcher.md) |

---

## 설계 근거

| 원칙 | 내용 |
|------|------|
| Environment Engineering | 프롬프트보다 레포 구조, 파일 컨벤션이 더 큰 레버리지 |
| 3-Folder 분리 | Immutable(agents/ + domains/)과 mutable(projects/)를 폴더 레벨에서 분리 |
| 프로젝트별 격리 | 여러 프로젝트의 workspace/memory/reports가 뒤섞이지 않음 |
| 도메인 보충 | 기본 규칙은 유지하면서 분야별 추가 컨텍스트 제공 |
| 컨텍스트 최소화 | 지도를 줘라, 백과사전을 주지 마라. index ~100줄, 교훈 30개 상한 |
| 피드백 루프 | 일회성 지시보다 자동 검증 + 교훈 축적 루프가 더 강력 |
| Citation Enforcement | 교훈 인용 강제로 근거 추적 가능 |
| Harness = 경쟁력 | 모델을 바꾸는 것보다 구조를 바꾸는 것이 더 큰 성능 향상 |
| Fail-safe | 에이전트 실패 시 사람이 대신하지 않고 환경을 개선 |

---

## For Agents

에이전트라면 아래 파일들을 순서대로 읽어라:

1. `agents/common/README.md` — 공통 규칙, 온보딩 절차
2. `agents/common/project-context.md` — 프로젝트 컨벤션
3. 자기 에이전트 폴더의 `profile.md` — 역할 정의
4. `projects/{name}/project.md` — 현재 프로젝트 확인
5. `domains/{domain}/context.md` — 도메인 배경
6. (해당 시) `domains/{domain}/{role}.md` — 도메인 특화 지침
7. (해당 시) `team/{role}.md` — 프로젝트 특화 지침
8. `memory/knowledge/index.md` — 프로젝트 지식 지도

상세 절차는 `techniques/`, 자동화 코드는 `tools/`에 있다.
