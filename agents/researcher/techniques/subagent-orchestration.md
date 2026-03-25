# Researcher Subagent Orchestration

- **대상 행동**: "자료 조사", "증거 수집", "비교 분석", "연구 synthesis"

---

## 기본 원칙

- 비사소한 조사에서는 `수집`과 `검증`을 분리한다.
- 기본 모델은 `search/docs gather -> analyze -> synthesize`다.
- 최종 연구 판단과 공식 제안 책임은 항상 Researcher에게 있다.

---

## 모델 선택 가이드

| specialist tier | 기본 모델 강도 | 대상 |
|------|------|------|
| 탐색/수집 | 빠른/가벼운 기본값 | `search-specialist`, `code-mapper`, `report-synthesizer` |
| 분석/검증 | 기본 연구 모델 강도 | `docs-researcher`, `consensus-reviewer`, `task-distributor` |
| 판단/리뷰 | 더 강한 기본값 | `reviewer`, `architect-reviewer`, `security-auditor` |

- 기본 tier를 먼저 쓰고, evidence가 얕거나 깊이에 비해 과하면 그때 override를 검토한다.
- Codex 같은 effort-aware backend에서는 tier에 맞는 기본 effort도 함께 따라간다. 탐색/수집은 low, 분석/검증은 medium, user-facing 결론이나 위험 판정은 high를 기본으로 둔다.
- 공식 문서 검증이 단순 사실 확인을 넘어서 version contract 비교가 되면 더 강한 모델을 고려한다.
- synthesis나 recommendation이 user-facing 결론에 가까우면 판단/리뷰 tier를 먼저 붙인다.

---

## 기본 fan-out 패턴

### 1. 일반 조사 / 비교 분석

기본적으로 아래 둘을 먼저 병렬 호출한다.

- `search-specialist`
- `docs-researcher`

목적:
- 넓은 자료 수집
- 공식 문서/버전 민감 사실 확인

### 2. 저장소와 연결된 조사

기본적으로 `code-mapper`를 추가한다.

목적:
- 조사 결과가 실제 코드베이스의 어디에 연결되는지 파악

### 3. 증거량이 많을 때

`report-synthesizer`를 사용해 중간 증거 묶음을 압축한다.

주의:
- 압축은 요약 보조일 뿐이며, 최종 연구 해석은 Researcher가 직접 한다.

---

## 금지 패턴

- broad search 없이 바로 결론으로 점프
- 공식 문서 검증 없이 커뮤니티 글만으로 판단
- evidence bundle이 큰데 synthesis 없이 장문 출력만 늘리기
- subagent 메모를 그대로 최종 연구 결론처럼 쓰기

---

## 최소 운영 규칙

- 조사 시작: `search-specialist + docs-researcher`
- codebase 연동 시: `+ code-mapper`
- 증거가 많으면: `report-synthesizer`
