# Whiplash

> AI들을 채찍질해서 훌륭한 결과를 낸다.

AI 에이전트들이 팀으로 협업하는 프레임워크. 코드가 아니라 **마크다운 문서**로 역할, 절차, 소통 규칙을 정의하면 에이전트가 읽고 따른다.

[English](README-EN.md)

---

## 시작하기

whiplash 디렉토리에서 Claude Code를 열고 대화하면 된다.

```
"새 프로젝트 시작할래"
"midi-render 이어하자"
```

온보딩 에이전트가 프로젝트를 설계하고, Manager가 팀을 꾸리고, 태스크를 분배한다.

<details>
<summary>사전 준비</summary>

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) 설치 (`npm install -g @anthropic-ai/claude-code`)
- [tmux](https://github.com/tmux/tmux) 설치 (`brew install tmux` / `apt install tmux`)
- [jq](https://jqlang.github.io/jq/) 설치 (`brew install jq` / `apt install jq`)

```bash
git clone https://github.com/Jiinn-hhhh/whiplash.git
cd whiplash
```

</details>

<details>
<summary>실행 모드 선택</summary>

| 모드 | 설명 | 비용 |
|------|------|------|
| **solo** | Manager가 역할별 에이전트를 하나씩 실행 (tmux 기반) | 1x |
| **dual** (실험적) | 같은 태스크를 Claude Code + Codex 이중 실행, 합의 도출 | 2x |

</details>

<details>
<summary>에이전트 관찰하기</summary>

```bash
tmux attach -t whiplash-{project-name}
# Ctrl-b + n/p/숫자 로 에이전트 윈도우 전환
```

</details>

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
Onboarding — 새 프로젝트 시작 시 유저와 대화하며 설계.
 ↕
Manager — 유저 ↔ 팀 허브. 에이전트 생성, 지시 분배, 조율, 보고.
 ├── Researcher (리서치팀장)
 ├── Developer (개발팀장)
 └── Monitoring (독립 관찰자)
```

<details>
<summary>에이전트 상세</summary>

| 에이전트 | 역할 | 모델 |
|---------|------|------|
| **Onboarding** | 유저와 대화하며 프로젝트를 설계. project.md 생성 후 Manager에게 인계 | - |
| **Manager** | 유저 ↔ 팀 허브. 에이전트 생성·관리, 태스크 분배, 결과 조율, 유저 보고 | sonnet |
| **Researcher** | 자료 수집·분석, 실험(프로토타입 수준), 방향 제안 | opus |
| **Developer** | 프로덕션 코드 구현, 아키텍처 설계, 인프라 구축 | sonnet |
| **Monitoring** | 독립 관찰자. 인프라·환경 상태 점검 | haiku |

</details>

---

## 실행 구조

Manager가 tmux 세션 안에서 팀을 운영한다. 각 에이전트는 자기 tmux 윈도우에서 독립 실행.

```
tmux 세션: whiplash-{project}
  ├─ [0] manager
  ├─ [1] researcher
  ├─ [2] developer
  ├─ [3] monitoring
  └─ [4] researcher-2          ← 동적 스폰 (필요 시)
```

<details>
<summary>부팅 흐름</summary>

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

각 에이전트 부팅 과정:
1. `claude -p "{부팅메시지}" --output-format json` → session_id 획득
2. `tmux new-window -n {role}` → 윈도우 생성
3. `claude --resume {session_id}` → 인터랙티브 세션 시작
4. `sessions.md`에 기록

</details>

<details>
<summary>소통 체계</summary>

| 채널 | 목적 | 방식 |
|------|------|------|
| **알림** (notify.sh) | 실시간 상태 전달 | tmux 직접 전달 (fire-and-forget) |
| **토론** (DISC-NNN.md) | 구조화된 논의 | 마크다운 append-only |
| **회의** (MEET-NNN.md) | 3라운드 토론 | 입장→응답→종합 |
| **공지** (announcements/) | 태스크 지시서 | 마크다운 파일 |

알림 종류: task_complete, status_update, need_input, escalation, agent_ready, reboot_notice, consensus_request

</details>

<details>
<summary>태스크 실행</summary>

1. Manager가 지시서 작성 → `orchestrator.sh dispatch {role} {task-file}`
2. tmux send-keys로 에이전트에게 전달
3. 에이전트 완료 → notify.sh로 task_complete 보고
4. dual 모드: `dual-dispatch`로 양쪽 실행 → Manager가 합의 도출

</details>

<details>
<summary>동적 스폰</summary>

에이전트가 긴 태스크 중일 때 같은 역할의 추가 인스턴스를 투입:

```bash
orchestrator.sh spawn researcher researcher-2 myproject     # 추가
orchestrator.sh kill-agent researcher-2 myproject            # 종료
```

- 동일 프로젝트 메모리/workspace 공유. 같은 파일 동시 수정만 금지
- monitor.sh가 자동 감시 (크래시 시 reboot 포함)

</details>

<details>
<summary>장애 대응</summary>

`monitor.sh`는 30초 주기 헬스체크 데몬:

- **크래시 감지**: tmux 윈도우 소멸 → `orchestrator.sh reboot`으로 자동 복구 (최대 3회)
- **행(hung) 감지**: 10분 비활성 → Manager에게 1회 알림 (자동 kill 안 함)
- **heartbeat**: 매 30초 timestamp 기록. 90초 이상이면 좀비 판정 → 재시작
- **세션 리프레시**: 맥락 과다 시 `orchestrator.sh refresh`로 handoff → 새 세션

</details>

<details>
<summary>CLI 명령어 (Manager 내부용)</summary>

Manager 에이전트가 내부적으로 실행한다. 유저가 직접 실행하지 않는다.

```bash
# 부팅/종료
orchestrator.sh boot-manager   {project}
orchestrator.sh boot           {project}
orchestrator.sh shutdown       {project}

# 태스크
orchestrator.sh dispatch       {role} {task-file} {project}
orchestrator.sh dual-dispatch  {role} {task-file} {project}

# 동적 스폰
orchestrator.sh spawn          {role} {window-name} {project}
orchestrator.sh kill-agent     {window-name} {project}

# 복구/관리
orchestrator.sh reboot         {target} {project}
orchestrator.sh refresh        {target} {project}
orchestrator.sh status         {project}
orchestrator.sh monitor-check  {project}
```

</details>

---

## 로깅

인프라 스크립트가 `logs/`에 자동 기록한다. 에이전트는 로깅을 의식하지 않는다.

| 파일 | 내용 |
|------|------|
| `logs/system.log` | 인프라 이벤트 (부팅/종료/크래시/디스패치 등) |
| `logs/message.log` | 에이전트 간 메시지 전달 이력 |

<details>
<summary>system.log 예시</summary>

```
2026-03-03 18:44:35 [info] test-project 프로젝트 부팅 시작 mode=solo
2026-03-03 18:44:35 [info] researcher 부팅 session=abc-123
2026-03-03 18:44:35 [info] developer 부팅 session=def-456
2026-03-03 18:44:35 [error] monitoring 부팅 실패 reason=claude -p 실행 실패
2026-03-03 18:44:35 [info] 모니터 시작 pid=12345
2026-03-03 18:44:35 [info] researcher 태스크 전달 task=TASK-001.md
2026-03-03 18:44:35 [warn] developer 크래시 감지 count=0/3
2026-03-03 18:44:35 [info] developer 리부팅 성공 count=1/3
2026-03-03 18:44:35 [error] developer 리부팅 실패 count=2/3
2026-03-03 18:44:35 [error] developer 리부팅 한도 초과 count=3/3
2026-03-03 18:44:35 [warn] researcher 비활성 감지 idle_min=12
2026-03-03 18:44:35 [info] researcher 활동 재개
2026-03-03 18:44:35 [info] test-project 프로젝트 종료
```

</details>

<details>
<summary>message.log 예시</summary>

```
2026-03-03 18:44:35 [delivered] researcher → manager "TASK-001 완료"
2026-03-03 18:44:35 [delivered] developer → manager "TASK-002 구현 완료"
2026-03-03 18:44:35 [skipped] manager → researcher "방향 선택 필요" reason="no claude process"
2026-03-03 18:44:35 [skipped] monitor → manager "developer 크래시" reason="no window"
```

</details>

<details>
<summary>grep으로 필터링</summary>

```bash
grep "\[error\]" logs/system.log           # error만
grep -E "크래시|리부팅" logs/system.log     # 크래시/리부팅 이력
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

## 프로젝트 구조

```
whiplash/
├── agents/                      # 에이전트 정의 (immutable, git tracked)
├── domains/                     # 도메인 특화 정의 (git tracked)
├── scripts/                     # 인프라 스크립트 (orchestrator, monitor, notify, log)
├── feedback/                    # 프레임워크 개선 인사이트
└── projects/                    # 프로젝트별 런타임 (mutable, gitignored)
    └── {project-name}/
        ├── project.md           #   프로젝트 정의
        ├── team/                #   에이전트 커스터마이징 (선택)
        ├── workspace/           #   진행 중인 작업
        ├── memory/              #   축적된 상태
        │   └── knowledge/       #     공유 지식 (교훈, 문서, 아카이브)
        ├── logs/                #   인프라 로그 (system.log, message.log)
        └── reports/             #   사용자 열람용 문서
```

<details>
<summary>폴더 분리 근거</summary>

| 폴더 | 성격 | Git |
|------|------|-----|
| `agents/` | 프레임워크 정의 (불변) | tracked |
| `domains/` | 도메인 특화 정의 (불변) | tracked |
| `scripts/` | 인프라 스크립트 | tracked |
| `feedback/` | 프레임워크 개선 (독립) | tracked |
| `projects/` | 프로젝트별 런타임 데이터 (가변) | ignored |

**Git clone하면 `agents/` + `domains/` + `scripts/` + `feedback/`가 온다.** 프로젝트 데이터는 에이전트가 실행하면서 생성한다.

</details>

<details>
<summary>에이전트 레이어 분리</summary>

| 레이어 | 내용 | 변경 빈도 |
|--------|------|-----------|
| `profile.md` | 정의 — 역할, 규칙 (무엇을/왜) | 안정적 |
| `techniques/` | 방법론 — 자연어 절차 (어떻게) | 자유롭게 개선 |

</details>

<details>
<summary>에이전트 상세 구조</summary>

```
agents/
├── common/                  # 공통 규칙 + 프로젝트 컨벤션
├── onboarding/              # Onboarding 에이전트
├── manager/                 # Manager 에이전트
│   ├── profile.md           #   역할 정의
│   └── techniques/ (6)      #   업무 방법론
├── researcher/              # Researcher 에이전트
│   ├── profile.md
│   └── techniques/ (6)
├── developer/               # Developer 에이전트
│   ├── profile.md
│   └── techniques/ (5)
└── monitoring/              # Monitoring 에이전트
    ├── profile.md
    └── techniques/ (2)
```

</details>

---

## 멀티 프로젝트

하나의 프레임워크로 여러 프로젝트를 동시에 운영한다. 각 프로젝트는 독립된 workspace, memory, logs, reports를 갖는다.

<details>
<summary>상세</summary>

- 에이전트 문서의 `workspace/`, `memory/`, `reports/` 경로는 현재 프로젝트 기준 상대 경로
- 프로젝트마다 별도의 tmux 세션 (`whiplash-{project}`)
- 크로스 프로젝트 참조는 명시적 전체 경로

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

상세: `domains/README.md`

</details>

---

## 설계 근거

| 원칙 | 내용 |
|------|------|
| Environment Engineering | 프롬프트보다 레포 구조, 파일 컨벤션이 더 큰 레버리지 |
| 3-Folder 분리 | Immutable(agents/ + domains/)과 mutable(projects/)를 폴더 레벨에서 분리 |
| 컨텍스트 최소화 | 지도를 줘라, 백과사전을 주지 마라. index ~100줄, 교훈 30개 상한 |
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
