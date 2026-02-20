# 작업 분배 (Agent Team 모드)

**대상 행동**: "TaskCreate/TaskUpdate 기반으로 작업을 분배하고 진행을 추적한다"

이 문서는 `agents/manager/techniques/task-distribution.md`의 agent-team 모드 대응 문서다. 지시서 파일 + orchestrator dispatch 대신 네이티브 Task 도구를 사용한다.

---

## 1. 작업 생성

### TaskCreate 사용법

```
TaskCreate(
  subject: "[작업 제목] — 명령형으로 간결하게",
  description: "## 목표\n...\n## 배경\n...\n## 산출물\n...\n## 참조\n...",
  activeForm: "[진행형 표현] — 예: Researching API options"
)
```

#### 필드 규칙

| 필드 | 형식 | 예시 |
|------|------|------|
| subject | 명령형, 간결 (한글 가능) | "API 스펙 조사", "인증 모듈 구현" |
| description | 구조화된 마크다운 | 목표, 배경, 산출물, 참조 파일 경로 |
| activeForm | 현재 진행형 (영문) | "Researching API spec", "Implementing auth module" |

#### description 구조

```markdown
## 목표
이 작업이 달성해야 하는 것 (1-2문장)

## 배경
왜 이 작업이 필요한지, 유저의 원래 요청이 무엇인지

## 할 일
- 구체적 작업 항목 1
- 구체적 작업 항목 2

## 산출물
- 예상 산출물과 위치 (예: workspace/teams/research/api-analysis.md)

## 참조
- 관련 파일 경로
- Cite LESSON-NNN (해당 시)
```

---

## 2. 작업 할당

### TaskUpdate로 owner 할당 + SendMessage로 알림

```
1. TaskUpdate(taskId: "{id}", owner: "{role}", status: "in_progress")
2. SendMessage(
     type: "message",
     recipient: "{role}",
     content: "새 태스크 할당됨. TaskGet(taskId: '{id}')으로 상세 확인.",
     summary: "새 태스크 할당: {subject 요약}"
   )
```

- TaskUpdate만으로는 팀원이 알 수 없다. 반드시 SendMessage로 알림을 보낸다.
- 팀원은 TaskGet으로 상세 description을 확인한다.

---

## 3. 의존성 관리

### 순차 실행 (의존성 있는 태스크)

```
TaskCreate(subject: "TASK-A: API 스펙 조사", ...)      → id: "1"
TaskCreate(subject: "TASK-B: API 구현", ...)             → id: "2"
TaskUpdate(taskId: "2", addBlockedBy: ["1"])
```

- TASK-A 완료 후 TASK-B가 진행 가능해진다.
- Manager가 TASK-A 완료 확인 후 TASK-B를 할당한다.

### 병렬 실행 (독립 태스크)

```
TaskCreate(subject: "TASK-A: 프론트엔드 리서치", ...)    → owner: "researcher"
TaskCreate(subject: "TASK-B: 백엔드 구현", ...)          → owner: "developer"
```

- 독립 태스크는 동시에 할당 가능.

---

## 4. 진행 추적

### 피드백 루프

Manager는 주기적으로 TaskList를 호출하여 전체 진행 상황을 확인한다.

```
1. TaskList — 전체 태스크 상태 확인
2. 정체된 태스크 발견 시 → 해당 팀원에게 SendMessage로 상태 확인
3. 완료된 태스크 → 결과물 확인 → 후속 태스크 생성 또는 의존 태스크 해제
```

### 팀원의 보고

팀원은 태스크 완료 시:

```
1. TaskUpdate(taskId: "{id}", status: "completed")
2. SendMessage(
     type: "message",
     recipient: "manager",
     content: "TASK-{id} 완료. 결과: {파일 경로}",
     summary: "태스크 완료: {subject 요약}"
   )
```

### 블로커 보고

팀원이 작업 중 블로커를 만나면:

```
SendMessage(
  type: "message",
  recipient: "manager",
  content: "TASK-{id} 블로커: {블로커 설명}. 결정/입력 필요.",
  summary: "블로커 발생: {요약}"
)
```

---

## 5. 기존 작업 지시서와의 관계

| 기존 (tmux 모드) | Agent Team 모드 |
|------------------|----------------|
| `workspace/shared/announcements/TASK-NNN.md` | TaskCreate의 description |
| `orchestrator.sh dispatch` | TaskUpdate(owner) + SendMessage |
| mailbox task_complete | TaskUpdate(completed) + SendMessage |

기존 작업 지시서 구조(목표, 배경, 팀별 할당, 의존성, 마감)를 TaskCreate의 description 안에 동일하게 작성한다.

---

## 6. 모니터링 운영

기존 `agents/manager/techniques/task-distribution.md`의 모니터링 운영 섹션을 그대로 따른다. 차이점:

- 지시 방법: dispatch 대신 TaskCreate + SendMessage
- 보고 수신: mailbox 대신 SendMessage
- 이상 징후 대응 흐름은 동일
