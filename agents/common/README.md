# agents/common — 에이전트 공통 규칙

에이전트 팀 프레임워크에서 **모든 에이전트가 따르는 공통 규칙**을 정의한다.
개별 에이전트(manager, researcher, developer 등)는 이 common을 기반으로 자기만의 특화 규칙을 추가한다.

---

## 공통 규칙 파일

| 파일 | 내용 |
|------|------|
| [project-context.md](project-context.md) | 프로젝트 컨텍스트 컨벤션 (경로 해석, 프로젝트 시작/전환 절차) |
| [communication.md](communication.md) | 소통 원칙, 공유 공간 구조, 토론/회의 진행 방식 |
| [memory.md](memory.md) | 배경 지식 관리, 교훈(Lesson) 축적/순환, 아카이브 규칙 |
| [formats.md](formats.md) | 교훈, 토론, 회의록, 보고서 등 문서 양식 템플릿 |
| [agent-spec.md](agent-spec.md) | 새 에이전트 정의 시 따르는 profile.md 양식 |

---

## 프로젝트 구조

```
whiplash/
  agents/                    # 프레임워크 정의 (불변, git tracked)
  domains/                   # 도메인 특화 정의 (불변, git tracked)
  projects/                  # 프로젝트별 런타임 데이터 (가변, gitignored)
    {project-name}/
      project.md             #   프로젝트 정의 (이름, 목표, 도메인)
      workspace/             #   진행 중인 작업
        shared/              #     진행 중인 토론, 회의, 공지
        teams/{team-name}/   #     팀별 내부 작업 공간
      memory/                #   축적된 상태
        {role}/              #     에이전트 개인 메모
        knowledge/           #     공유 지식
          lessons/           #       활성 교훈 (최대 30개)
          docs/              #       레퍼런스 문서
          discussions/       #       종료된 토론 원본
          meetings/          #       종료된 회의록 원본
          archives/          #       순환된 비활성 교훈
          index.md           #       지식 지도 (~100줄)
      reports/               #   사용자 열람용 문서
```

- Git tracked = `agents/` + `domains/`. 나머지 전부 = `projects/`.
- 에이전트 문서의 workspace/, memory/, reports/ 경로는 **현재 프로젝트 기준 상대 경로**로 해석한다.
- 상세: [project-context.md](project-context.md), [communication.md](communication.md) §1

---

## 기본 행동 원칙

### 근거 제시 의무
모든 결정과 산출물에는 이유를 명시한다.

### 교훈 인용 강제
교훈을 참고했다면 반드시 `Cite LESSON-NNN` 형식으로 인용한다.

### Append-only 소통
다른 에이전트가 쓴 내용을 수정/삭제하지 않는다. 자기 섹션만 추가한다.

### 세 레이어 분리
| 레이어 | 내용 | 변경 빈도 |
|--------|------|-----------|
| `profile.md` | **정의** — 역할, 규칙, 원칙 (무엇을/왜) | 안정적 |
| `techniques/` | **방법론** — 자연어 절차 (어떻게) | 자유롭게 개선 |
| `tools/` | **자동화** — 미리 짜둔 코드, 스크립트, 설정 (실행) | 필요 시 추가 |

- 상위 레이어가 변하지 않아도 하위 레이어는 독립적으로 개선할 수 있다.

### 안티패턴 명시
에이전트 정의 시 "하면 안 되는 것"을 구체적으로 기술한다.

### 컨텍스트 최소화
- `knowledge/index.md`는 ~100줄 이내의 지도로 유지한다.
- 활성 교훈은 최대 30개. 초과 시 순환한다.
- 상세 내용은 필요할 때 원본을 찾아 읽는다.

---

## 에이전트 온보딩

### 새 프로젝트 시작
새 프로젝트를 시작할 때는 **온보딩 에이전트**(`agents/onboarding/`)가 유저와 대화하며 project.md를 설계한다. project.md가 생성되어야 다른 에이전트가 온보딩 가능하다.

### 기존 프로젝트 투입
에이전트가 기존 프로젝트에서 작업을 시작할 때:
1. 이 파일(`common/README.md`)을 읽는다 — 공통 규칙.
2. `common/project-context.md`를 읽는다 — 프로젝트 컨벤션.
3. 자기 에이전트 폴더의 `profile.md`를 읽는다 — 역할 정의.
4. `projects/{name}/project.md`를 읽는다 — 현재 프로젝트 확인.
5. `domains/{domain}/context.md`를 읽는다 — 도메인 배경.
6. (해당 시) `domains/{domain}/{role}.md`를 읽는다 — 도메인 특화 지침.
7. `memory/knowledge/index.md`를 읽는다 — 프로젝트 지식 지도.

새 에이전트를 정의할 때:
1. [agent-spec.md](agent-spec.md)의 양식에 따라 `agents/{role}/profile.md`를 작성한다.
2. `agents/{role}/techniques/`에 방법론을 자연어 절차로 작성한다.
3. 필요 시 `agents/{role}/tools/`에 코드/스크립트/설정을 추가한다.

---

## 설계 근거

| 원칙 | 출처 | 적용 |
|------|------|------|
| 지도를 줘라, 백과사전을 주지 마라 | OpenAI | README.md와 index.md를 ~100줄 지도로 유지 |
| 컨텍스트는 줄일수록 좋다 | OpenAI, MARS | 배경 지식 요약 형태, 깊이 참고는 on-demand |
| 3-folder 분리 | 프레임워크 설계 | agents/(불변) + domains/(불변) + projects/(가변) |
| 프로젝트별 격리 | 프레임워크 설계 | 각 프로젝트의 workspace/memory/reports가 독립 |
| 도메인 보충 원칙 | 프레임워크 설계 | 도메인 파일은 기본 규칙을 보충, 교체 아님 |
| 교훈 K_m=30개 제한 + 중복 제거 | MARS | 활성 교훈 상한 + 중복 제거 규칙 |
| Citation Enforcement | MARS | 교훈 인용 시 `Cite LESSON-NNN` 강제 |
| Append-only 소통 | 프레임워크 설계 | 다른 에이전트의 글 수정 금지 |
| 안티패턴 명시적 금지 | MARS | 하면 안 되는 것을 명확히 기술 |
| 근거 제시 의무 | MARS, 6원칙 | 모든 결정/산출물에 이유 명시 |
| 세 레이어 분리 | 프레임워크 설계 | profile.md(정의) → techniques/(방법론) → tools/(자동화) |
