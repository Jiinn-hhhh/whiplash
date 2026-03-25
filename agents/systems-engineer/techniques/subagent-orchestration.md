# Systems Engineer Subagent Orchestration

- **대상 행동**: "runtime 감사", "deploy/drift 분석", "운영 위험 검토"

---

## 기본 원칙

- runtime 사실은 증거 기반이어야 한다.
- 기본 모델은 `audit -> map/verify -> conclude`다.
- 운영 결론, write authority 판단, 최종 runbook 반영 책임은 Systems Engineer에게 있다.

---

## Task Triage

| 작업 성격 | 기본 선택 | 권장 모델 강도 |
|------|------|------|
| 작고 명확한 감사/확인 | direct 예외 가능. 다만 runtime 사실이 헷갈리면 `runtime-auditor` 1개부터 | 빠른/가벼운 모델 우선 |
| 비사소하지만 bounded | `runtime-auditor + code-mapper` 2-way 기본. repo/runtime 접점을 먼저 맞춘다 | 기본 모델 + 빠른 specialist 조합 |
| 복잡/애매/고위험 운영 판단 | direct-only 금지. `audit + verify/review`를 먼저 깔고, rollout/security/perf 성격에 맞는 specialist를 더 붙인다 | 더 강한 모델을 drift 판정, rollback gate, cross-system risk 결론에 우선 배치 |

- 빠른/가벼운 모델과 낮은 effort는 evidence 수집, 구조 맵핑, 좁은 사실 확인에 먼저 쓴다.
- 더 강한 모델과 높은 effort는 ambiguous runtime diagnosis, 고위험 rollout 판단, trust boundary가 얽힌 결론에 우선 쓴다.
- execution lead는 이 triage를 기본값으로 삼되, 실제 fan-out 조합과 최종 모델 선택은 상황에 맞게 자율적으로 결정한다.

---

## 기본 fan-out 패턴

### 1. 런타임/배포/드리프트 조사

기본적으로 `runtime-auditor`를 먼저 호출한다.

목적:
- 현재 구조
- evidence path
- drift 지점
- 추가 검증 필요 영역

### 2. repo/runtime 접점이 있을 때

기본적으로 `code-mapper`를 병렬 호출한다.

목적:
- 코드 경로와 live 경로 연결
- 수정이 영향을 미칠 파일/스크립트 범위 파악

### 3. 변경 계획/리스크 검토

기본적으로 `reviewer`를 추가한다.

목적:
- risky script/config change 검토
- 누락된 rollback/test/safety check 확인

### 4. 공급자 문서/버전 사실이 중요할 때

`docs-researcher`를 추가한다.

### 5. rollout / rollback / release 절차가 중요할 때

`deployment-engineer`를 추가한다.

목적:
- 배포 단계 검토
- rollback 포인트 식별
- release safety checklist 보강

### 6. exposed surface / hardening / trust boundary가 중요할 때

`security-auditor`를 추가한다.

### 7. 성능 / 용량 / 병목이 중요할 때

`performance-engineer`를 추가한다.

---

## 금지 패턴

- audit 없이 구조 단정
- repo/runtime mapping 없이 변경 계획 작성
- reviewer 없이 위험한 변경 추천
- subagent 증거를 검토 없이 runbook에 반영

---

## 최소 운영 규칙

- 감사 시작: `runtime-auditor`
- code path 연동 필요: `+ code-mapper`
- risky change plan: `+ reviewer`
- rollout/rollback 설계: `+ deployment-engineer`
- hardening/security review: `+ security-auditor`
- 성능/용량 문제: `+ performance-engineer`
