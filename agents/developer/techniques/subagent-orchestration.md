# Developer Subagent Orchestration

- **대상 행동**: "비사소한 구현", "버그 수정", "리팩터", "검증 강화"

---

## 기본 원칙

- trivial single-file 기계적 수정이 아니면, 직접 구현 전에 먼저 specialist fan-out을 한다.
- 기본 모델은 `map -> verify/debug -> implement -> review -> top-level synthesize`다.
- 공식 코드 변경, 테스트 해석, 최종 보고 책임은 항상 Developer에게 있다.

---

## Task Triage

| 작업 성격 | 기본 선택 | 권장 모델 강도 |
|------|------|------|
| 작고 명확함 | direct 예외 가능. 그래도 불확실하면 scout 1개(`code-mapper` 또는 `debugger`)부터 | 빠른/가벼운 모델 우선 |
| 비사소하지만 bounded | 직접 구현 전에 2-way fan-out 기본. 기능/리팩터는 `code-mapper + docs-researcher`, 버그는 `debugger + code-mapper` | 기본 코딩 모델 + 빠른 specialist 조합 |
| 복잡/애매/고위험 | direct-only 금지. `map + verify/review`를 먼저 깔고, 필요하면 `architect-reviewer`, `security-auditor`, `performance-engineer`까지 붙인다 | 더 강한 모델을 구조 경계, 애매한 설계, 최종 위험 판정에 우선 배치 |

- 빠른/가벼운 모델은 mapping, evidence 수집, 좁은 verify에 먼저 쓴다.
- 더 강한 모델은 merge-risk, 설계 경계 흔들림, cross-file refactor, ambiguous bug, release gate 판정에 우선 쓴다.
- execution lead는 이 triage를 기본값으로 삼되, 실제 fan-out 조합과 최종 모델 선택은 task 맥락을 보고 자율적으로 결정한다.

---

## 모델 선택 가이드

| specialist tier | 기본 모델 강도 | 대상 |
|------|------|------|
| 탐색/수집 | 빠른/가벼운 기본값 | `code-mapper`, `search-specialist`, `report-synthesizer` |
| 분석/구현 | 기본 코딩 모델 강도 | `debugger`, `test-automator`, `refactoring-specialist`, `docs-researcher`, `performance-engineer`, `runtime-auditor`, `deployment-engineer`, `consensus-reviewer`, `task-distributor` |
| 판단/리뷰 | 더 강한 기본값 | `reviewer`, `architect-reviewer`, `security-auditor` |

- 기본 tier로 시작하고, task가 unusually simple하거나 복잡할 때만 override를 검토한다.
- 넓은 매핑이나 자료 수집이 unexpectedly deep하면 한 단계 올린다.
- review/release gate가 사실 확인 위주로 좁으면 한 단계 내릴 수 있지만, 최종 위험 판정은 더 강한 모델을 유지한다.

---

## 기본 fan-out 패턴

### 1. 기능 구현 / 리팩터

기본적으로 아래 둘을 먼저 병렬 호출한다.

- `code-mapper`
- `docs-researcher`

목적:
- 영향 파일, 인터페이스, 테스트 범위 파악
- 버전/API/문서 사실 확인

### 2. 버그 수정 / flaky / 재현 어려운 실패

기본적으로 아래 둘을 먼저 병렬 호출한다.

- `debugger`
- `code-mapper`

필요하면 `docs-researcher`를 추가한다.

### 3. 마무리 직전

기본적으로 `reviewer`를 호출한다.

목적:
- correctness
- regression risk
- missing tests
- security smell

### 4. 구조 정리가 큰 변경

기본적으로 `refactoring-specialist`를 추가한다.

목적:
- 책임 분리 검토
- 중복 제거
- 단계적 리팩터 순서 제안

### 5. 테스트 보강이 핵심인 변경

기본적으로 `test-automator`를 추가한다.

목적:
- 회귀 방지용 테스트 위치 제안
- 누락된 단위/통합 테스트 식별
- flaky 없이 검증 가능한 최소 테스트 세트 구성

### 6. 보안 민감 변경

`security-auditor`를 추가한다.

대상 예시:
- auth/authz
- secret/token 처리
- 입력 검증
- 파일 업로드
- 외부 호출 trust boundary

### 7. 성능 민감 변경

`performance-engineer`를 추가한다.

대상 예시:
- hot path
- 대량 데이터 처리
- N+1 / query fan-out
- cache / concurrency / latency 문제

### 8. 설계 경계가 흔들릴 때

`architect-reviewer`를 추가한다.

목적:
- layering 위반 감지
- 장기 유지보수 비용이 큰 coupling 식별
- 대체 설계 선택지 비교

---

## `debugger` 사용 규칙

- `debugger`는 좁은 범위의 재현, 로그 보강, 임시 probe, 테스트 추가를 할 수 있다.
- 하지만 최종 패치 정리, 불필요한 probe 제거, 테스트 해석, release-ready 판정은 Developer가 직접 한다.

---

## 금지 패턴

- 비사소한 구현을 아무 mapping 없이 바로 시작
- 문서/API 사실 확인 없이 추정 구현
- `reviewer` 없이 끝내고 release-ready라고 주장
- subagent 출력을 그대로 최종 보고로 내보내기

## trivial 예외 기준

- 변경 파일 1개
- 대략 20줄 안팎의 기계적 수정
- 사이드이펙트가 좁고 다른 파일 인터페이스에 영향 없음
- 위 조건 중 하나라도 애매하면 direct-only 대신 scout 1개 이상 먼저 호출

---

## 최소 운영 규칙

- 기능/리팩터: `code-mapper + docs-researcher`
- 버그: `debugger + code-mapper`
- 마무리: `reviewer`
- 구조 정리 비중 큼: `+ refactoring-specialist`
- 테스트 보강 핵심: `+ test-automator`
- 보안 민감: `+ security-auditor`
- 성능 민감: `+ performance-engineer`
- 설계 경계 흔들림: `+ architect-reviewer`
- direct-only 경로는 trivial 예외일 때만
