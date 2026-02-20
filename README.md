# Whiplash

> AI들을 채찍질해서 훌륭한 결과를 낸다.

AI 에이전트들이 팀으로 협업하는 환경을 정의하는 프레임워크.

코드가 아니라 **마크다운 문서**로 구성되어 있다. 역할 정의, 업무 절차, 소통 규칙, 지식 관리 방식을 구조화된 문서로 만들어두면, AI 에이전트가 이를 읽고 따르며 자율적으로 일한다.

[English](README-EN.md)

---

## 시작하기

### 사전 준비

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) 설치 (`npm install -g @anthropic-ai/claude-code`)
- [tmux](https://github.com/tmux/tmux) 설치 — solo/dual 모드에 필요 (`brew install tmux` / `apt install tmux`)
- [jq](https://jqlang.github.io/jq/) 설치 — solo/dual 모드에 필요 (`brew install jq` / `apt install jq`)

### 최초 실행

#### 1. 레포 클론

```bash
git clone https://github.com/Jiinn-hhhh/whiplash.git
cd whiplash
```

#### 2. 실행 모드 선택

| 모드 | 설명 | 장점 | 단점 | 비용 |
|------|------|------|------|------|
| **solo** | Manager가 역할별 에이전트를 하나씩 순차 실행 (tmux 기반) | 비용 최소, 안정적 | 동시 실행 불가 | 1x |
| **agent-team** | Claude Code Agent Team으로 팀원 동시 실행 | 편의성, 병렬 작업 | 비용 높음 | 4-7x |
| **dual** | 같은 태스크를 두 백엔드(Claude Code + Codex)에서 이중 실행 | 다양한 관점, 합의 기반 | 인프라 복잡 | 2x |

#### 3-A. agent-team 모드 (권장)

```bash
bash agent-team/boot.sh
```

Agent Teams 환경변수가 설정된 Claude Code 세션이 열린다. 이후:

```
"새 프로젝트 시작할래"
```

온보딩 에이전트가 유저와 대화하며 프로젝트를 설계하고, 완료되면 같은 세션에서 Manager로 자동 전환 → 팀 생성 → 팀원 스폰 → 대시보드 자동 오픈 → 태스크 분배까지 전부 자동이다.

#### 3-B. solo/dual 모드

Claude Code를 이 폴더에서 실행하고:

```
너는 Onboarding 에이전트다. agents/onboarding/profile.md를 읽고 새 프로젝트 온보딩을 시작해라.
```

온보딩이 끝나면:

1. `orchestrator.sh boot-manager` → Manager가 tmux 세션에 부팅
2. Manager가 자동으로 나머지 에이전트 부팅
3. 유저에게 tmux 접속 안내

```bash
tmux attach -t whiplash-{project-name}
# Ctrl-b + n/p/숫자 로 에이전트 윈도우 전환
```

**유저가 할 일은 온보딩 대화뿐이다.** 그 후 Manager가 팀을 꾸리고, 태스크를 분배하고, 결과를 조율한다.

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
 ├── Researcher (리서치팀장)
 ├── Developer (개발팀장)
 └── Monitoring (독립 관찰자)
```

| 에이전트 | 역할 | 모델 (solo/dual) |
|---------|------|-----------------|
| **Onboarding** | 유저와 대화하며 프로젝트를 설계. project.md + 디렉토리 생성 후 Manager에게 인계 | - |
| **Manager** | 유저 ↔ 팀 허브. 에이전트 생성·관리, 태스크 분배, 결과 조율, 유저 보고 | sonnet |
| **Researcher** | 자료 수집·분석, 실험(프로토타입 수준), 방향 제안 | opus |
| **Developer** | 프로덕션 코드 구현, 아키텍처 설계, 인프라 구축 | sonnet |
| **Monitoring** | 독립 관찰자. 인프라·환경 상태 점검 | haiku |

---

## 실행 구조

### agent-team 모드

```
유저: "새 프로젝트 시작할래"
  │
  ▼
Onboarding (boot.sh → Claude Code 세션)
  │  유저와 대화 → project.md 생성
  │  Phase 7에서 Manager로 자동 전환
  │
  ▼
Manager (같은 세션)
  │
  ├─ TeamCreate("whiplash-{project}")
  ├─ Task(spawn) × 3 — Researcher, Developer, Monitoring 병렬 스폰
  ├─ "준비 완료" × 3 수신 대기
  ├─ 대시보드 서버 시작 (브라우저 자동 오픈)
  ├─ project.md 목표 분석 → 첫 태스크 분배
  └─ 팀 운영 시작
       ├─ SendMessage로 태스크 지시
       ├─ 팀원 보고 수신 → 다음 태스크 분배
       ├─ agent-team-status.json 갱신 → 대시보드 실시간 반영
       └─ 유저에게 보고
```

- 팀원 간 소통: `SendMessage` (네이티브)
- 태스크 관리: `TaskCreate` + `TaskUpdate`
- 장애 감지: Manager가 10분/5분/5분 단계적 확인 → 재스폰
- 상세: `agent-team/manager/techniques/orchestration.md`

### solo/dual 모드

```
유저: "온보딩 시작해라"
  │
  ▼
Onboarding → project.md 생성
  │
  ├─ orchestrator.sh boot-manager → tmux 세션 생성
  └─ 유저에게 "tmux attach" 안내
       │
       ▼
Manager (tmux 안, 자동 실행)
  │
  ├─ orchestrator.sh boot → Researcher, Developer, Monitoring 부팅
  ├─ monitor.sh 백그라운드 실행
  ├─ agent_ready 수신 → 첫 태스크 분배
  └─ 팀 운영 시작
```

```
tmux 세션: whiplash-{project}
  ├─ [0] manager
  ├─ [1] researcher
  ├─ [2] developer
  └─ [3] monitoring
```

- 팀원 간 소통: `mailbox.sh` (Maildir 패턴)
- 태스크 관리: 지시서 파일 + `dispatch`
- 장애 감지: `monitor.sh` 30초 폴링, 자동 reboot (최대 3회)
- 상세: `agents/manager/techniques/orchestration.md`

### CLI 명령어 (solo/dual)

```bash
bash agents/manager/tools/orchestrator.sh boot-manager {project}  # Manager 부팅
bash agents/manager/tools/orchestrator.sh boot {project}          # 팀원 부팅
bash agents/manager/tools/orchestrator.sh dispatch {role} {task} {project}  # 태스크 전달
bash agents/manager/tools/orchestrator.sh status {project}        # 상태 확인
bash agents/manager/tools/orchestrator.sh shutdown {project}      # 전체 종료
```

---

## 대시보드

픽셀 아트 오피스 대시보드로 에이전트 상태를 시각적으로 모니터링한다.

```bash
python3 dashboard/server.py --project {project-name}
# → http://localhost:8420 에서 브라우저 자동 오픈
```

- 3초 폴링으로 에이전트 상태 실시간 표시
- 에이전트 상태별 위치: 작업중 → 책상, 대기 → 휴게실, 수면 → 소파
- Manager가 유저 입력 대기 시 주황색 배너 + 브라우저 알림
- solo/dual 모드: tmux + sessions.md 기반 수집
- agent-team 모드: Manager가 작성하는 `agent-team-status.json` 기반 수집
- 더블 버퍼링으로 깜빡임 없는 렌더링

---

## 프로젝트 구조

```
whiplash/
├── agents/                      # 프레임워크 정의 (immutable, git tracked)
│   ├── common/                  #   공통 규칙 + 프로젝트 컨벤션
│   ├── onboarding/              #   Onboarding 에이전트
│   ├── manager/                 #   Manager 에이전트
│   │   ├── profile.md           #     역할 정의
│   │   ├── techniques/ (5)      #     업무 방법론
│   │   └── tools/               #     orchestrator.sh, monitor.sh, mailbox.sh
│   ├── researcher/              #   Researcher 에이전트
│   │   ├── profile.md
│   │   └── techniques/ (6)
│   ├── developer/               #   Developer 에이전트
│   │   ├── profile.md
│   │   └── techniques/ (5)
│   └── monitoring/              #   Monitoring 에이전트
│       └── techniques/ (2)
│
├── agent-team/                  # Agent Team 모드 모듈 (git tracked)
│   ├── boot.sh                  #   진입점 스크립트
│   ├── manager/                 #   Manager 보충 지침
│   │   ├── profile-supplement.md
│   │   ├── techniques/ (3)      #     orchestration, task-distribution, crash-recovery
│   │   └── tools/spawn-prompts/ #     팀원 스폰 프롬프트
│   └── common/                  #   공통 보충 규칙
│       ├── communication-supplement.md
│       └── file-ownership.md
│
├── domains/                     # 도메인 특화 정의 (git tracked)
│   └── deep-learning/           #   예시 도메인
│
├── dashboard/                   # 시각 오피스 대시보드 (독립 모듈)
│   ├── server.py                #   HTTP 서버 (Python stdlib only)
│   ├── status-collector.sh      #   데이터 수집 → JSON (모드별 분기)
│   ├── index.html               #   Canvas + 폴링
│   ├── sprites.js               #   픽셀 아트 스프라이트 정의
│   └── office.js                #   오피스 레이아웃 + 렌더링 엔진
│
├── feedback/                    # 프레임워크 개선 인사이트 (독립 모듈)
│   ├── guide.md                 #   기록 규칙
│   └── insights.md              #   축적된 인사이트
│
└── projects/                    # 프로젝트별 런타임 (mutable, gitignored)
    └── {project-name}/
        ├── project.md           #   프로젝트 정의
        ├── team/                #   에이전트 커스터마이징 (선택)
        ├── workspace/           #   진행 중인 작업
        ├── memory/              #   축적된 상태
        │   └── knowledge/       #     공유 지식 (교훈, 문서, 아카이브)
        └── reports/             #   사용자 열람용 문서
```

### 분리 근거

| 폴더 | 성격 | Git |
|------|------|-----|
| `agents/` | 프레임워크 정의 (불변) | tracked |
| `agent-team/` | Agent Team 모드 보충 (불변) | tracked |
| `domains/` | 도메인 특화 정의 (불변) | tracked |
| `dashboard/` | 시각 대시보드 (독립) | tracked |
| `feedback/` | 프레임워크 개선 (독립) | tracked |
| `projects/` | 프로젝트별 런타임 데이터 (가변) | ignored |

**Git clone하면 `agents/` + `agent-team/` + `domains/` + `dashboard/` + `feedback/`가 온다.** 프로젝트 데이터는 에이전트가 실행하면서 생성한다.

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

- 에이전트 문서의 `workspace/`, `memory/`, `reports/` 경로는 현재 프로젝트 기준 상대 경로
- 프로젝트마다 별도의 tmux 세션(`whiplash-{project}`) 또는 Agent Team(`whiplash-{project}`)
- 크로스 프로젝트 참조는 명시적 전체 경로

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

| 에이전트 | profile.md | techniques |
|---------|:----------:|:----------:|
| Onboarding | O | 1개 |
| Manager | O | 5개 (+agent-team 3개) |
| Researcher | O | 6개 |
| Developer | O | 5개 |
| Monitoring | - | 2개 |

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

프레임워크 자체의 비효율을 발견하면 `feedback/guide.md`를 읽고 `feedback/insights.md`에 기록해라.
