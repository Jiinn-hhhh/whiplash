# agents/common — 에이전트 공통 규칙

## 공통 규칙 파일

| 파일 | 내용 |
|------|------|
| [project-context.md](project-context.md) | 프로젝트 컨텍스트 컨벤션 (경로 해석, 프로젝트 시작/전환 절차) |
| [communication.md](communication.md) | 소통 원칙, 공유 공간 구조, 토론 진행 방식 |
| [memory.md](memory.md) | 배경 지식 관리, 교훈(Lesson) 축적, 중복 제거 규칙 |
| [formats.md](formats.md) | 교훈, 토론, 보고서 등 문서 양식 템플릿 |
| [agent-spec.md](agent-spec.md) | 새 에이전트 정의 시 따르는 profile.md 양식 |

---

## 기본 행동 원칙

### 근거 제시 의무
모든 결정과 산출물에는 이유를 명시한다.

### Append-only 소통
다른 에이전트가 쓴 내용을 수정/삭제하지 않는다. 자기 섹션만 추가한다.

### 레이어 분리
- `profile.md` = 정의(역할, 규칙). `techniques/` = 방법론(절차). 인프라 스크립트는 `scripts/`.
- 상위 레이어가 변하지 않아도 하위 레이어는 독립적으로 개선 가능.

### 백엔드 네이티브 기능 활용
각 백엔드(Claude Code, Codex CLI)의 subagent/team 기능을 적극 활용한다. 프레임워크가 모든 것을 재발명하지 않는다.
- repo-local subagent pack: `.claude/agents/`, `.codex/agents/` (활용 가능한 옵션, 강제 아님)
- execution lead(developer, researcher, systems-engineer)는 서브에이전트 팀을 자율 구성한다.
- manager는 목표/제약/우선순위만 준다. 내부 fan-out은 execution lead 판단.
- 역할별 참고 패턴: `techniques/subagent-orchestration.md` (출발점, 구속 아님)

### 작업 루프 정책
- `guided`(기본): 중요한 방향 전환은 user 확인 가능.
- `ralph`: user 승인 없이 계속 진행. blocker/scope 축소/완료는 알림만.

### 역할별 도구 제한
`profile.md`의 `<!-- agent-meta -->`에 정의. cmd.sh가 `--allowedTools`로 자동 적용.

### 프로젝트 폴더 접근
코드/자동화 수정은 Developer와 Systems Engineer만 가능. 다른 에이전트는 읽기 전용.

### 시스템 변경 정책
- 로컬 파일 수정, 테스트, 빌드, 로컬 git commit은 허용.
- 원격 시스템 변경은 역할 문서와 프로젝트 문서 기준으로 판단.

### 프레임워크 개선 피드백
`프레임워크 디버깅: on` 시 비효율 발견하면 `feedback/guide.md` 읽고 `feedback/insights.md`에 기록.

### 문서 로딩 원칙 (Progressive Disclosure)
- **Layer 1 (필수)**: common/README.md, profile.md, project.md — 온보딩 즉시.
- **Layer 2 (작업 시작 시)**: memory/{role}/, 해당 techniques/*.md, domain context — 첫 태스크 수신 시.
- **Layer 3 (필요 시)**: project-context.md, domain/{role}.md, team/{role}.md — on-demand.

### 프로젝트 구조
- `agents/`, `domains/`, `scripts/`, `dashboard/`, `feedback/` = git tracked (불변)
- `projects/` = 런타임 (가변, gitignored)
- 에이전트 문서의 workspace/, memory/, reports/ 경로는 현재 프로젝트 기준 상대 경로
- `manager`, `onboarding` = control-plane (부팅 흐름에서 별도 관리)
- 상세: [project-context.md](project-context.md)
