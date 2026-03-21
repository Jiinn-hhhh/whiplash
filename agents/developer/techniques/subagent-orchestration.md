# Developer Subagent Orchestration

- **대상 행동**: "비사소한 구현", "버그 수정", "리팩터", "검증 강화"

---

## 기본 원칙

- trivial single-file 기계적 수정이 아니면, 직접 구현 전에 먼저 specialist fan-out을 한다.
- 기본 모델은 `map -> verify/debug -> implement -> review -> top-level synthesize`다.
- 공식 코드 변경, 테스트 해석, 최종 보고 책임은 항상 Developer에게 있다.

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
