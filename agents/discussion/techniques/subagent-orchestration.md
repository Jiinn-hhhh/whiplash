# Discussion Subagent Orchestration

- **대상 행동**: "코드/사실이 걸린 전략 토론", "설계 비교", "추천안 강화"

---

## 기본 원칙

- Discussion의 subagent는 `read-heavy strategist aide`다.
- 기본 모델은 `fact/context gather -> compare -> recommend -> handoff(optional)`다.
- 빠른/가벼운 모델과 낮은 effort는 사실 수집과 비교 초안에, 더 강한 모델과 높은 effort는 추천안 비교와 handoff 직전 판단에 우선 쓴다.
- 최종 추천안과 handoff 승격 책임은 Discussion에게 있다.

---

## 기본 fan-out 패턴

### 1. 코드 방향이 걸린 전략 토론

기본적으로 `code-mapper`를 먼저 호출한다.

목적:
- 영향 파일
- 현재 구조
- 바뀌는 경계

### 2. 외부 사실 / API / 버전 / 문서가 걸린 토론

기본적으로 `docs-researcher`를 호출한다.

### 3. 선택지가 여러 개인 설계 토론

기본적으로 `consensus-reviewer`를 호출한다.

목적:
- 옵션별 차이점
- 리스크/비용/장점 비교 초안

### 3-1. 아키텍처 경계가 핵심인 토론

`architect-reviewer`를 추가한다.

목적:
- layering / ownership 경계 점검
- 장기 유지보수 비용이 큰 결합 식별
- architecture-level anti-pattern 경고

### 4. 노트와 증거가 길어질 때

`report-synthesizer`를 호출한다.

목적:
- 긴 맥락 압축
- 유저에게 설명할 핵심 포인트 정리

---

## 금지 패턴

- 코드 영향이 큰데 repo 확인 없이 방향 결정
- 버전/문서 사실이 중요한데 검증 없이 주장
- 긴 비교 토론을 압축 없이 손으로만 끌기
- aide 결과를 검토 없이 handoff로 승격

---

## 최소 운영 규칙

- 코드 논의: `code-mapper`
- 외부 사실 논의: `docs-researcher`
- 옵션 비교: `consensus-reviewer`
- 아키텍처 경계 검토: `architect-reviewer`
- 장문 압축: `report-synthesizer`
