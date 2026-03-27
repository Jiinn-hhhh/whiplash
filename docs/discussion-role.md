# Discussion 역할 설계

## 배경

Whiplash의 기존 구조에서는 `manager`가 유저와의 긴 전략 토론과 실제 실행 조율을 동시에 떠안았다. 이 구조는 두 문제가 있었다.

1. 유저와 장문 토론이 길어질수록 Manager의 실행 문맥이 오염된다.
2. 실행 허브가 설계 토론까지 오래 붙잡으면 "현재 상태 source of truth"와 "전략 토론 partner" 역할이 섞인다.

`discussion`은 이 문제를 분리하기 위한 상위 역할이다.

---

## 핵심 아이디어

- `discussion`은 Manager와 같은 수준의 프로젝트 이해를 유지한다.
- 하지만 실행 통제권은 가지지 않는다.
- 유저와 장문 전략/설계/우선순위 토론을 담당한다.
- 실행이 바뀌어야 할 때만 `manager`에게 handoff를 넘긴다.

한 줄 정의:

> `discussion = manager-grade understanding + no execution authority`

---

## 역할 경계

### Discussion이 맡는 것

- 목표, 요구사항, 제약, 우선순위, 아키텍처 방향 토론
- 코드 방향과 제품 방향의 트레이드오프 정리
- 유저 합의 사항과 열린 질문 구분
- 결정 노트 유지
- 실행 변경 handoff 작성

### Manager가 맡는 것

- 현재 실행 상태
- 누가 무엇을 하고 있는지
- blocker, idle, reboot, runtime health
- 실제 태스크 분배와 실행 계획 반영
- 최종 조율과 팀 운영

### 절대 섞지 않는 것

- Discussion이 worker에게 직접 지시하지 않는다.
- Manager가 긴 전략 토론을 오래 붙잡지 않는다.
- 둘 다 동시에 유저에게 다른 약속을 하지 않는다.

---

## 부팅 정책

- `discussion`은 top-level 역할이다.
- `cmd.sh boot` 시 자동 부팅된다.
- project.md `활성 에이전트`에 적지 않아도 된다.
- dual 모드에서도 `discussion`은 항상 `solo`다.
- backend는 현재 `manager`와 같은 backend를 사용한다.

이유:

- 전략 토론은 backend 간 경쟁보다 일관성이 중요하다.
- dual 비교는 Developer/Researcher 같은 생산 역할에 집중하는 편이 신호가 좋다.
- control-plane을 복제하면 합의 루프만 늘고 운영 비용이 커진다.

---

## 읽기/쓰기 표면

### 필수 읽기

- `projects/{name}/project.md`
- `projects/{name}/memory/manager/activity.md`
- `projects/{name}/memory/onboarding/handoff.md` (있으면)

### 필요 시 읽기

- `projects/{name}/memory/manager/sessions.md`
- `projects/{name}/memory/manager/assignments.md`
- `projects/{name}/workspace/shared/announcements/`
- `projects/{name}/memory/knowledge/index.md`

### 쓰기 표면

- `projects/{name}/memory/discussion/handoff.md` (전략 합의 + 실행 변경 통합)

주의:

- `discussion`은 `reports/tasks/`를 top-level task 결과 보고서처럼 사용하지 않는다.
- 코드 레포 수정, 태스크 파일 작성, worker dispatch는 하지 않는다.

---

## 라우팅 계약

### discussion으로 가야 하는 질문

- "이 기능 방향을 바꿀까?"
- "지금 이 요구사항을 줄일까 늘릴까?"
- "Codex/Claude 둘 다 고려하면 어떤 구조가 맞을까?"
- "이 프로젝트에서 dual 모드를 어디까지 쓰는 게 맞지?"

### manager로 가야 하는 질문

- "지금 누가 뭐 하고 있어?"
- "현재 blocker 뭐야?"
- "developer 멈췄어?"
- "runtime health 괜찮아?"

### 혼합형 질문 처리

혼합형 질문에서는 아래처럼 나눈다.

- 전략/의미/변경 방향 설명: `discussion`
- 현재 상태 사실 확인: `manager`

즉, Discussion은 status source가 아니라 strategy source다.

---

## 산출물 계약

### handoff.md (통합 산출물)

목적:

- 유저와의 전략 합의와 실행 변경을 하나의 문서에 기록한다.
- Manager가 즉시 반영할 수 있는 실행 변경 계약이자, 합의 이력 기록이다.

포함 내용:

- 왜 바뀌는지
- 무엇이 바뀌는지
- 어떤 역할이 영향을 받는지
- Manager가 지금 바로 해야 할 변경
- Notes: 열린 질문, 배경 합의사항 (선택)

---

## 권한 정책

Discussion은 아래를 하지 않는다.

- `task_assign`
- `task_complete`
- `dispatch`
- `spawn`
- `reboot`
- `refresh`
- `merge-worktree`

또한 아래도 하지 않는다.

- worker 직접 지휘
- 코드 구현
- 리서치 실무
- runtime/source of truth 판정

---

## Manager와의 계약

Manager는 `memory/discussion/handoff.md`를 받으면 이를 다음처럼 취급한다.

- 기본값: 유저 승인된 실행 의도
- 예외: 기존 안전 규칙, 시스템 권한 정책, 명시적 사용자 제한과 충돌할 때

즉 Manager는 handoff를 다시 토론하지 않고, 실행 계획에 반영하는 쪽이 기본 동작이다.

---

## 이번 단계의 구현 범위

이번 변경에서는 아래까지만 구현한다.

- `discussion` top-level 역할 추가
- 자동 부팅
- dual 모드에서도 solo 유지
- `memory/discussion/` 경로 공식화
- `handoff` 계약 문서화
- manager와의 라우팅/권한 규칙 문서화

이번 변경에서 의도적으로 미룬 것:

- specialist subagent 계층
- discussion 전용 동적 spawn
- discussion용 별도 backend 선택 옵션
- discussion/manager 자동 메시지 라우터

이 미룬 항목은 `docs/subagent-roadmap.md`에서 이어서 다룬다.
