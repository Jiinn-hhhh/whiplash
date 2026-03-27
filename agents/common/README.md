# agents/common — 에이전트 공통 규칙

에이전트 팀 프레임워크에서 **모든 에이전트가 따르는 공통 규칙**을 정의한다.
개별 에이전트(discussion, manager, researcher, developer, systems-engineer 등)는 이 common을 기반으로 자기만의 특화 규칙을 추가한다.

---

## 공통 규칙 파일

| 파일 | 내용 |
|------|------|
| [project-context.md](project-context.md) | 프로젝트 컨텍스트 컨벤션 (경로 해석, 프로젝트 시작/전환 절차) |
| [communication.md](communication.md) | 소통 원칙, 공유 공간 구조, 토론 진행 방식 |
| [memory.md](memory.md) | 배경 지식 관리, 교훈(Lesson) 축적, 중복 제거 규칙 |
| [formats.md](formats.md) | 교훈, 토론, 보고서 등 문서 양식 템플릿 |
| [agent-spec.md](agent-spec.md) | 새 에이전트 정의 시 따르는 profile.md 양식 |

---

## 프로젝트 구조

```
whiplash/
  agents/                    # 프레임워크 정의 (불변, git tracked)
  domains/                   # 도메인 특화 정의 (불변, git tracked)
  scripts/                   # 인프라 스크립트 (orchestrator, monitor, notify 등)
  dashboard/                 # 실시간 TUI 대시보드 (tracked)
  feedback/                  # 프레임워크 개선 인사이트 (tracked)
  projects/                  # 프로젝트별 런타임 데이터 (가변, gitignored)
    {project-name}/
      project.md             #   프로젝트 정의 (이름, 목표, 도메인)
      team/                  #   프로젝트 레벨 에이전트 커스터마이징 (선택)
        {role}.md            #     역할별 프로젝트 특화 지침
      workspace/             #   진행 중인 작업
        shared/              #     진행 중인 토론, 공지
        teams/{team-name}/   #     팀별 내부 작업 공간
      memory/                #   축적된 상태
        discussion/          #     전략 토론 메모, manager handoff
        manager/             #     sessions.md, assignments.md
        {role}/              #     에이전트 개인 메모
        knowledge/           #     공유 지식
          lessons/           #       교훈
          docs/              #       레퍼런스 문서
          index.md           #       지식 지도 (~100줄)
      runtime/               #   manager-state.tsv, reboot-state.tsv, message queue/locks
      logs/                  #   system.log, message.log
      reports/               #   사용자 열람 전용 (에이전트는 쓰기만, 읽기 참조 금지)
        tasks/               #     top-level task 결과 보고서
```

- Git tracked = `agents/` + `domains/` + `scripts/` + `dashboard/` + `feedback/`. 런타임 = `projects/`.
- `pixel-agents/`, `system_develop/` 같은 로컬 실험/보조 폴더가 보여도 프레임워크 핵심 경로는 위 구조가 기준이다.
- 에이전트 문서의 workspace/, memory/, reports/ 경로는 **현재 프로젝트 기준 상대 경로**로 해석한다.
- `discussion`, `manager`, `onboarding`은 control-plane 역할이다. 일반적으로 project.md `활성 에이전트`에는 worker/team 역할만 적고, control-plane 역할은 부팅 흐름에서 별도로 올라간다.
- 상세: [project-context.md](project-context.md), [communication.md](communication.md) §1

---

## 기본 행동 원칙

### 근거 제시 의무
모든 결정과 산출물에는 이유를 명시한다.

### Append-only 소통
다른 에이전트가 쓴 내용을 수정/삭제하지 않는다. 자기 섹션만 추가한다.

### 레이어 분리
| 레이어 | 내용 | 변경 빈도 |
|--------|------|-----------|
| `profile.md` | **정의** — 역할, 규칙, 원칙 (무엇을/왜) | 안정적 |
| `techniques/` | **방법론** — 자연어 절차 (어떻게) | 자유롭게 개선 |
- 상위 레이어가 변하지 않아도 하위 레이어는 독립적으로 개선할 수 있다.
- 프레임워크 인프라 스크립트(`cmd.sh`, `monitor.sh`, `message.sh`, `log.py`)는 `scripts/`에 위치한다.

### 백엔드 네이티브 기능 적극 활용
Claude Code의 subagent / TeamCreate / 병렬 태스크와 Codex CLI의 subagent / agent team / delegation / 병렬 태스크처럼 각 백엔드가 제공하는 네이티브 기능을 적극적으로 활용한다. 특정 백엔드에 팀 기능이 있으면 수동 분해보다 우선 검토한다. 프레임워크가 모든 것을 재발명하지 않는다 — 백엔드가 잘하는 것은 백엔드에 맡긴다.
이 문서들과 역할 문서에서 `서브에이전트`라고 쓰면, 특별한 예외가 없는 한 Claude Code와 Codex CLI의 네이티브 subagent / agent team을 모두 포함하는 표현으로 이해한다.
- 이 레포는 repo-local native subagent pack을 함께 제공한다:
  - Claude Code: `.claude/agents/`
  - Codex CLI: `.codex/agents/`
- 이 specialist pack은 **활용 가능한 옵션**이지, 반드시 따라야 하는 강제 사항이 아니다.
- `developer`, `researcher`, `systems-engineer` 같은 팀장급 execution lead는 서브에이전트 팀을 **자율적으로 구성**한다:
  - 기존 specialist가 작업에 맞으면 활용한다.
  - 파일별 병렬 코딩, 영역별 병렬 조사처럼 specialist 성격 부여 없이 범용 에이전트를 자유롭게 팀 구성하는 것도 허용한다.
  - 팀장이 판단하여 가장 효율적인 조합을 선택한다.
- `manager`는 목표, 제약, 우선순위를 준다. 내부 fan-out 조합과 에이전트 구성은 execution lead가 자율적으로 결정한다.
- "subagent를 하나도 쓰지 않는 경로"는 trivial 예외일 때만 허용한다. 그렇지 않으면 어떤 에이전트를 썼는지 또는 왜 생략했는지 설명할 수 있어야 한다.
- 역할별 참고 패턴은 각 역할의 `techniques/subagent-orchestration.md`에 정의한다. 이 패턴은 출발점이지 구속이 아니다.

### 작업 루프 정책
- backend 실행 모드(`solo | dual`)와 작업 루프(`guided | ralph`)는 별도 축이다.
- `guided`는 현재 기본 방식이다. 중요한 방향 전환은 user 확인을 거칠 수 있다.
- `ralph`는 기본적으로 user 승인 없이 계속 진행한다. 다만 user는 언제든 manager/discussion에 개입할 수 있고, 그 입력은 async 업데이트로 흡수된다.
- `ralph`에서는 blocker, scope 축소, 최종 완료를 user-facing 알림 채널에 남기되, 전체 루프를 멈추지 않는다.

### 안티패턴 명시
에이전트 정의 시 "하면 안 되는 것"을 구체적으로 기술한다.

### 역할별 도구 제한
각 에이전트의 허용 도구가 `profile.md`의 `<!-- agent-meta -->` 블록에 정의된다. cmd.sh가 부팅 시 `--allowedTools`로 자동 적용한다. 허용되지 않은 도구는 사용 불가.

### 프로젝트 폴더 접근 규칙
프로젝트 폴더(코드/자동화)는 **Developer와 Systems Engineer만 수정 가능**. 다른 에이전트는 읽기 전용. 상세: `agents/manager/techniques/orchestration.md` §7

### 시스템 변경 정책
- 로컬 파일 수정, 테스트, 빌드, 로컬 git commit은 허용한다.
- 원격 시스템 변경은 역할 문서와 프로젝트 문서 기준으로 판단한다.
- `systems-engineer`는 `team/systems-engineer.md` + `memory/knowledge/docs/change-authority.md`를 기준으로 원격 시스템 변경 여부를 결정한다.

### 태스크 결과 보고서
- 각 top-level task는 `reports/tasks/{task-id}-{agent}.md` 결과 보고서를 남긴다.
- `task_assign`를 받으면 보고서 stub가 자동 생성된다.
- `task_complete` 전에 보고서를 채우고 `- **Status**: final`로 바꿔야 한다.
- Dual 모드에서는 `{task-id}-{role}-claude.md`, `{task-id}-{role}-codex.md`, `{task-id}-manager.md`가 함께 사용될 수 있다.

### 컨텍스트 최소화
- `knowledge/index.md`는 ~100줄 이내의 지도로 유지한다.
- 상세 내용은 필요할 때 원본을 찾아 읽는다.

### 프레임워크 개선 피드백
project.md `운영 방식`에 `프레임워크 디버깅: on`이 설정된 경우, 작업 중 프레임워크 자체의 비효율(절차, 소통, 구조, 도구 등)을 발견하면 `feedback/guide.md`를 읽고 `feedback/insights.md`에 기록한다.

### 문서 로딩 원칙 (Progressive Disclosure)
필요한 문서만 필요한 시점에 읽는다. 컨텍스트 윈도우는 유한한 자원이다.
- **Layer 1 (필수)**: common/README.md, profile.md, project.md — 온보딩 즉시 읽는다.
- **Layer 2 (작업 시작 시)**: index.md(지도), 해당 techniques/*.md, domain context — 첫 태스크 수신 시 읽는다.
- **Layer 3 (필요 시)**: project-context.md, domain/{role}.md, team/{role}.md, 개별 교훈 — 해당 정보가 필요할 때만 읽는다.
- `index.md`는 **지도**다. 전체를 읽는 것이 아니라 필요한 참조를 찾아가는 용도다.

---

## 에이전트 온보딩

### 새 프로젝트 시작
새 프로젝트를 시작할 때는 **온보딩 에이전트**(`agents/onboarding/`)가 유저와 대화하며 project.md를 설계한다. project.md가 생성되어야 다른 에이전트가 온보딩 가능하다.

### 기존 프로젝트 투입 (Progressive Disclosure)
에이전트가 기존 프로젝트에서 작업을 시작할 때, 3단계로 나누어 읽는다:

**Layer 1 — 필수 (온보딩 즉시)**
1. 이 파일(`common/README.md`)을 읽는다 — 공통 규칙.
2. 자기 에이전트 폴더의 `profile.md`를 읽는다 — 역할 정의.
3. `projects/{name}/project.md`를 읽는다 — 현재 프로젝트 확인.

**Layer 2 — 작업 시작 시**
4. `memory/knowledge/index.md`를 읽는다 — 지식 지도 (참조용, 전체 읽기 아님).
5. 해당 작업에 필요한 `techniques/*.md`를 읽는다.
6. (도메인이 `general`이 아니고 파일이 있으면) `domains/{domain}/context.md`를 읽는다 — 도메인 배경.

**Layer 3 — 필요 시 (on-demand)**
7. `common/project-context.md` — 경로 해석 등 필요 시.
8. (도메인이 `general`이 아니고 파일이 있으면) `domains/{domain}/{role}.md` — 도메인 특화 지침.
9. (해당 시) `team/{role}.md` — 프로젝트 특화 지침.
10. 개별 교훈/문서 — `index.md`에서 참조를 찾아 필요한 것만.

새 에이전트를 정의할 때:
1. [agent-spec.md](agent-spec.md)의 양식에 따라 `agents/{role}/profile.md`를 작성한다.
2. `agents/{role}/techniques/`에 방법론을 자연어 절차로 작성한다.
3. 프레임워크 인프라 스크립트는 `scripts/`에 위치한다.

---

## 설계 근거

| 원칙 | 출처 | 적용 |
|------|------|------|
| 지도를 줘라, 백과사전을 주지 마라 | OpenAI | README.md와 index.md를 ~100줄 지도로 유지 |
| 컨텍스트는 줄일수록 좋다 | OpenAI, MARS | 배경 지식 요약 형태, 깊이 참고는 on-demand |
| 폴더 분리 | 프레임워크 설계 | agents/(불변) + domains/(불변) + scripts/(인프라) + projects/(가변) |
| 프로젝트별 격리 | 프레임워크 설계 | 각 프로젝트의 workspace/memory/reports가 독립 |
| 도메인 보충 원칙 | 프레임워크 설계 | 도메인 파일은 기본 규칙을 보충, 교체 아님 |
| 교훈 중복 제거 | 프레임워크 설계 | 중복 교훈 대신 기존 교훈 보강 |
| Append-only 소통 | 프레임워크 설계 | 다른 에이전트의 글 수정 금지 |
| 안티패턴 명시적 금지 | MARS | 하면 안 되는 것을 명확히 기술 |
| 근거 제시 의무 | MARS, 6원칙 | 모든 결정/산출물에 이유 명시 |
| 레이어 분리 | 프레임워크 설계 | profile.md(정의) → techniques/(방법론). 인프라 스크립트는 scripts/ |
