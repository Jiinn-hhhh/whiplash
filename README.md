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

## 온보딩 과정

유저가 새 프로젝트를 시작하면 Onboarding 에이전트가 대화를 통해 프로젝트를 설계한다. 설문이 아니라 토론 — 유저 답변에서 빠진 것을 파악하고 자연스럽게 파고든다.

<details>
<summary>Phase 0–7 상세</summary>

| Phase | 내용 | 산출물 |
|-------|------|--------|
| 사전 질문 | 실행 모드 선택 (solo / dual) | project.md 초안, 디렉토리 구조 |
| 0. 기존 작업물 | 기존 코드/레포가 있으면 철저 분석 | — |
| 1. 큰 그림 | 프로젝트 유형, 목표, 동기 | project.md 이름·목표 |
| 2. 기존 자원 | 코드, 데이터, 참고 자료 확인 | project.md 자원 섹션 |
| 3. 제약사항 | 환경, 시간, 예산, 기술 제한 | project.md 제약 섹션 |
| 4. 성공 기준 | 정량/정성 목표 구체화 | project.md 성공 기준 |
| 5. 운영 방식 | 보고 빈도/채널, 자율 범위, 알림 채널 검증 | project.md 운영 방식 |
| 6. 팀 커스터마이징 | 에이전트별 초점 조정 (필요 시) | team/{role}.md |
| 7. 리뷰 및 확정 | 전체 리뷰 → Manager 인계 | Manager tmux 부팅 |

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

| 에이전트 | 역할 | 모델 | 허용 도구 |
|---------|------|------|-----------|
| **Onboarding** | 유저와 대화하며 프로젝트를 설계. project.md 생성 후 Manager에게 인계 | opus | Read,Glob,Grep,Write,Edit,Bash |
| **Manager** | 유저 ↔ 팀 허브. 에이전트 생성·관리, 태스크 분배, 결과 조율, 유저 보고 | opus | Read,Glob,Grep,Bash,WebSearch,WebFetch |
| **Researcher** | 자료 수집·분석, 실험(프로토타입 수준), 방향 제안 | opus | Read,Glob,Grep,Bash,WebSearch,WebFetch |
| **Developer** | 프로덕션 코드 구현, 아키텍처 설계, 인프라 구축 | opus | 전체 |
| **Monitoring** | 독립 관찰자. 인프라·환경 상태 점검 | haiku | Read,Glob,Grep,Bash |

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

**부팅** — 유저가 온보딩을 시작하면 Onboarding이 프로젝트를 설계(project.md)하고 Manager를 부팅한다. Manager는 팀 에이전트(Researcher, Developer, Monitoring)를 부팅한 뒤 첫 태스크를 분배한다.

**소통** — 실시간 알림(태스크 완료, 상태 업데이트 등을 즉시 전달)과 구조화 문서(토론·회의·공지를 마크다운으로 기록)를 병행한다.

**태스크** — Manager가 지시서를 작성해 에이전트에게 전달한다. 에이전트는 완료 후 Manager에게 보고. Dual 모드에서는 같은 태스크를 양쪽 백엔드에서 실행하고 합의를 도출한다.

**동적 스폰** — 에이전트가 긴 태스크 중일 때 같은 역할의 추가 인스턴스를 투입한다. 각 에이전트는 별도 git worktree에서 격리 작업하며, 종료 시 squash merge된다.

**장애 대응** — 30초마다 헬스체크. 크래시 시 자동 복구(최대 3회), 10분 비활성 시 Manager에게 알림. heartbeat로 모니터 자체의 좀비 여부도 감시한다.

<details>
<summary>부팅 기술 상세</summary>

Onboarding은 `cmd.sh boot-manager`로 Manager를 부팅하고, Manager는 `cmd.sh boot`로 팀을 부팅한다.

각 에이전트 부팅 과정:
1. `profile.md`의 `<!-- agent-meta -->` 블록에서 모델과 허용 도구 파싱
2. `claude -p "{부팅메시지}" --model {model} --allowedTools {tools} --output-format json` → session_id 획득
3. `tmux new-window -n {role}` → 윈도우 생성
4. `claude --resume {session_id} --allowedTools {tools}` → 인터랙티브 세션 시작 (`--resume`이 플래그를 계승하지 않으므로 재전달)
5. `sessions.md`에 기록

</details>

<details>
<summary>소통 기술 상세</summary>

| 채널 | 구현 |
|------|------|
| 실시간 알림 | `message.sh` → tmux `load-buffer` + `paste-buffer`로 수신자 윈도우에 직접 전달 |
| 토론 | `workspace/shared/discussions/DISC-NNN.md` (append-only) |
| 회의 | `workspace/shared/meetings/MEET-NNN.md` (3라운드: 입장→응답→종합) |
| 공지 | `workspace/shared/announcements/` |

알림 종류: task_complete, status_update, need_input, escalation, agent_ready, reboot_notice, consensus_request

</details>

<details>
<summary>태스크·스폰 기술 상세</summary>

태스크 전달:
```bash
cmd.sh dispatch {role} {task-file} {project}       # 단일 백엔드
cmd.sh dual-dispatch {role} {task-file} {project}   # 이중 백엔드
```
`tmux send-keys`로 에이전트에게 전달, 완료 시 `message.sh`로 `task_complete` 보고.

동적 스폰:
```bash
cmd.sh spawn {role} {window-name} {project}     # 추가 투입
cmd.sh kill-agent {window-name} {project}        # 종료
```
각 에이전트는 별도 git worktree에서 격리 작업. 종료 시 squash merge. `monitor.sh`가 스폰된 에이전트도 자동 감시.

</details>

<details>
<summary>장애 대응 기술 상세</summary>

`monitor.sh`는 nohup 백그라운드 데몬:

- **크래시 감지**: `sessions.md`에서 활성 역할 파싱 → tmux 윈도우 소멸 감지 → `cmd.sh reboot` (최대 3회)
- **행(hung) 감지**: 10분 비활성 → `message.sh`로 Manager에게 1회 알림 (자동 kill 안 함). 활동 재개 시 자동 해제
- **heartbeat**: 매 30초 `monitor.heartbeat`에 timestamp 기록. Manager가 `cmd.sh monitor-check` 호출 → 90초 이상이면 좀비 → 재시작
- **세션 리프레시**: 맥락 과다 시 `cmd.sh refresh`로 handoff → 새 세션

</details>

<details>
<summary>CLI 명령어 전체 (Manager 내부용)</summary>

Manager 에이전트가 내부적으로 실행한다. 유저가 직접 실행하지 않는다.

```bash
# 부팅/종료
cmd.sh boot-manager   {project}
cmd.sh boot           {project}
cmd.sh shutdown       {project}

# 태스크
cmd.sh dispatch       {role} {task-file} {project}
cmd.sh dual-dispatch  {role} {task-file} {project}

# 동적 스폰
cmd.sh spawn          {role} {window-name} {project}
cmd.sh kill-agent     {window-name} {project}

# 복구/관리
cmd.sh reboot         {target} {project}
cmd.sh refresh        {target} {project}
cmd.sh status         {project}
cmd.sh monitor-check  {project}
```

</details>

---

## 로깅

에이전트 부팅·종료·크래시·태스크 분배 등 인프라 이벤트가 발생하면 `system.log`에 자동 기록된다. 에이전트 간 알림이 전달되거나 실패하면 `message.log`에 자동 기록된다. 에이전트 자신은 로깅을 의식하지 않는다.

<details>
<summary>로그 형식 + 예시</summary>

**system.log** — 인프라 이벤트:
```
2026-03-03 18:44:35 [info] researcher 부팅 session=abc-123
2026-03-03 18:44:35 [warn] developer 크래시 감지 count=0/3
2026-03-03 18:44:35 [error] developer 리부팅 한도 초과 count=3/3
2026-03-03 18:44:35 [info] test-project 프로젝트 종료
```

**message.log** — 메시지 전달 이력:
```
2026-03-03 18:44:35 [delivered] researcher → manager "TASK-001 완료"
2026-03-03 18:44:35 [skipped] manager → researcher "방향 선택 필요" reason="no claude process"
```

기록 주체: `cmd.sh`와 `monitor.sh`가 `log.py system`을, `message.sh`가 `log.py message`를 호출한다.

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
├── scripts/                     # 인프라 스크립트 (cmd, monitor, message, log)
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
| Progressive Disclosure | 문서를 3단계(필수/작업시/필요시)로 나눠 컨텍스트 윈도우 절약 |
| Git Worktree 격리 | 에이전트별 독립 worktree로 파일 충돌 원천 방지. 종료 시 squash merge |
| 백프레셔 게이트 | task_complete 전 자체 검증 필수. 검증 없이 완료 보고 금지 |
| Semantic Compaction | 비활성 교훈을 archive/로 이동 + 1줄 요약 참조 유지. 원본 보존 |
| 역할별 도구 제한 | profile.md 메타데이터로 허용 도구 정의, cmd.sh가 --allowedTools로 강제 적용 |
| Harness = 경쟁력 | 모델을 바꾸는 것보다 구조를 바꾸는 것이 더 큰 성능 향상 |
| Fail-safe | 에이전트 실패 시 사람이 대신하지 않고 환경을 개선 |

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
