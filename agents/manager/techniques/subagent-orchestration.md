# Manager Subagent Orchestration

- **대상 행동**: "복잡한 목표 분해", "dual 결과 비교", "대형 보고 요약"

---

## 기본 원칙

- Manager의 native subagent는 `worker`가 아니라 `staff aide`다.
- `task-distributor`, `consensus-reviewer`, `report-synthesizer` 같은 보조 역할만 기본 사용한다.
- 빠른/가벼운 모델과 낮은 effort는 분해 초안과 장문 압축에, 더 강한 모델과 높은 effort는 결과 비교와 최종 판단 보조에 우선 쓴다.
- execution lead 아래 specialist 조합은 Manager가 아니라 해당 lead가 정한다.
- 최종 태스크 분배, 우선순위 결정, 유저 보고 책임은 항상 Manager에게 있다.

---

## 기본 fan-out 규칙

### 1. 멀티팀/복합 목표가 들어오면

기본적으로 먼저 `task-distributor`를 호출한다.

목적:
- 독립 작업 단위로 분해
- 병렬 가능 부분 식별
- 의존성 최소화

trivial 예외:
- 이미 TASK 파일이 있고 단순 재전달만 하면 되는 경우

### 2. dual 모드에서 결과가 갈리면

기본적으로 `consensus-reviewer`를 호출한다.

목적:
- 차이점 요약
- 누락/충돌 포인트 식별
- 추천안 초안 생성

Manager는 이 결과를 참고만 하고, 최종 합의 문서와 판정은 직접 한다.

### 3. 보고서/결과 묶음이 커지면

기본적으로 `report-synthesizer`를 호출한다.

목적:
- 긴 보고서 묶음을 압축
- 유저 보고용 핵심 신호 정리
- 누락 위험 줄이기

---

## 금지 패턴

- Manager가 `debugger`, `runtime-auditor`, `search-specialist` 같은 실무 specialist를 직접 굴리는 것
- Manager가 Developer/Researcher/Systems Engineer에게 특정 specialist 조합을 미시적으로 강제하는 것
- staff aide 결과를 그대로 유저에게 보내는 것
- subagent 없이 큰 멀티팀 작업을 바로 분배하는 것

---

## 최소 운영 규칙

- 비사소한 멀티팀 목표: `task-distributor` 먼저
- dual 충돌: `consensus-reviewer` 먼저
- 장문 결과 요약: `report-synthesizer` 먼저
- 최종 공식 문서/지시/보고: Manager 직접 작성
