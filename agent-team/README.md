# Agent Team 모드

Claude Code의 네이티브 Agent Team 기능(TeamCreate, TaskCreate, SendMessage 등)을 활용한 에이전트 오케스트레이션 모듈.

기존 tmux + mailbox.sh + monitor.sh 인프라 없이 동일한 팀 거버넌스를 구현한다.

---

## 전제조건

- Claude Code에서 Agent Teams 기능이 활성화되어 있어야 한다
  ```bash
  export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
  ```
- `boot.sh`가 이 환경변수를 자동 설정한다

---

## Quick Start

### 새 프로젝트

```bash
bash agent-team/boot.sh
```

Claude Code 세션이 열린다. "새 프로젝트 시작할래" → 온보딩 대화 → project.md 생성 → Manager 전환 → 팀 스폰 → 대시보드 자동 시작

### 기존 프로젝트 재개

```bash
bash agent-team/boot.sh {project-name}
```

대시보드가 즉시 열리고(`http://localhost:8420`), Claude Code 세션이 시작된다. "프로젝트 X 재개해" → Manager가 팀 스폰 → 작업 재개

---

## 기존 모드와의 차이

| 항목 | solo/dual (tmux 모드) | agent-team 모드 |
|------|----------------------|----------------|
| 인프라 | tmux + mailbox.sh + monitor.sh | Claude Code Agent Teams |
| 세션 관리 | orchestrator.sh | TeamCreate + Task(spawn) |
| 메시징 | mailbox.sh (파일 기반) | SendMessage (네이티브) |
| 크래시 감지 | monitor.sh (자동) | Manager가 TaskList + SendMessage로 수동 |
| 태스크 관리 | 지시서 파일 + dispatch | TaskCreate + TaskUpdate |
| 유저 관찰 | `tmux attach` | 대화 내 자동 표시 |
| 비용 | 1x (solo) / 2x (dual) | 4-7x (Manager + 팀원 동시 실행) |

---

## 비용 경고

Agent Team 모드는 Manager와 팀원(Developer, Researcher, Monitoring)이 동시에 실행된다. solo 모드 대비 **4-7배**의 API 비용이 발생할 수 있다. 비용에 민감한 경우 solo 모드를 권장한다.

---

## 제한사항

- **세션 재개 불가**: 팀 세션은 저장/재개되지 않는다. 종료 후 새로 부팅해야 한다.
- **팀당 하나의 리드**: Manager가 유일한 팀 리드 역할을 겸한다.
- **모델 직접 지정 불가**: Agent Teams에서 팀원의 모델을 직접 지정할 수 없다. subagent_type으로 간접 조율한다.
- **broadcast 비용**: broadcast는 모든 팀원에게 개별 전송되므로 비용이 팀원 수에 비례한다.

---

## 파일 구조

```
agent-team/
├── README.md                          # 이 파일
├── boot.sh                            # 진입점 스크립트
├── manager/
│   ├── profile-supplement.md          # Manager-as-lead 보충 지침
│   ├── techniques/
│   │   ├── orchestration.md           # Agent Team 오케스트레이션
│   │   ├── task-distribution.md       # TaskCreate/TaskUpdate 기반 작업 분배
│   │   └── crash-recovery.md          # 팀원 장애 복구
│   └── tools/
│       └── spawn-prompts/
│           ├── developer.md           # Developer 스폰 프롬프트
│           ├── researcher.md          # Researcher 스폰 프롬프트
│           └── monitoring.md          # Monitoring 스폰 프롬프트
└── common/
    ├── communication-supplement.md    # SendMessage 소통 규칙
    └── file-ownership.md              # 파일 소유권 분할 규칙
```

---

## 기존 모드에 미치는 영향

이 모듈은 독립적이다. 기존 `agents/` 파일에 최소한의 참조만 추가하며, solo/dual 모드의 동작을 변경하지 않는다.

- `agents/common/project-context.md`: `실행 모드` 유효값에 `agent-team` 추가
- `agents/manager/profile.md`: agent-team 시 보충 파일 참조 안내 1줄
- `agents/onboarding/techniques/project-design.md`: 3모드 질문 확장 + 자동 전환
