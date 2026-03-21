# Native Subagent Starter Pack

## 목적

Whiplash의 top-level 역할이 native subagent를 `권장` 수준이 아니라 `기본 실행 전략`으로 쓰게 만든다. 목표는 토큰을 아끼는 것이 아니라, 비사소한 작업에서 더 넓게 병렬 탐색하고 더 빠르게 수렴하는 것이다.

---

## 현재 구현 상태

이 레포는 아래 두 pack을 repo root에 제공한다.

- Claude Code: `.claude/agents/*.md`
- Codex CLI: `.codex/agents/*.toml`

또한 Codex는 `.codex/config.toml`에서 wide, shallow fan-out을 기본값으로 둔다.

런타임 계약:

- `manager`, `discussion`, `developer`, `researcher`, `systems-engineer` profile은 `Agent` 도구를 허용한다.
- top-level Codex 역할은 repo-local `.codex/config.toml`의 `model = "gpt-5.4"`를 기본값으로 사용한다.
- Claude 세션은 repo root에서 시작해야 `.claude/agents/`를 세션 시작 시점에 안정적으로 로드할 수 있다.
- agent env script는 `WHIPLASH_REPO_ROOT`, `WHIPLASH_NATIVE_CLAUDE_AGENTS`, `WHIPLASH_NATIVE_CODEX_AGENTS`를 export한다.
- starter pack은 기본적으로 read-heavy다. 실제 write 권한은 `debugger`, `refactoring-specialist`, `test-automator`처럼 코드베이스에 최소 수정이 필요한 역할에만 제한적으로 열어 둔다. `deployment-engineer` 같은 운영 보조는 backend별 런타임 제약에 맞춰 더 보수적으로 열 수 있다.

---

## 스타터 팩 구성

| 이름 | 주 용도 | 기본 성격 |
|------|---------|-----------|
| `task-distributor` | 목표 분해, 병렬 태스크 초안 | manager aide |
| `consensus-reviewer` | 옵션/결과 비교, 차이점 정리 | manager/discussion aide |
| `report-synthesizer` | 긴 증거/보고 압축 | shared aide |
| `code-mapper` | 파일/인터페이스/테스트/영향 범위 맵핑 | engineering aide |
| `docs-researcher` | 공식 문서/API/버전 사실 검증 | shared aide |
| `reviewer` | correctness/regression/security/missing tests 점검 | engineering aide |
| `debugger` | 재현/가설분리/좁은 probe | developer aide |
| `search-specialist` | 넓은 자료 수집, 비교 조사 | researcher aide |
| `runtime-auditor` | runtime/deploy/drift 감사 | systems aide |
| `architect-reviewer` | 설계 경계, layering, 장기 유지보수 리스크 검토 | discussion/developer aide |
| `refactoring-specialist` | 구조 정리, 책임 분리, safe cleanup 계획 | developer aide |
| `test-automator` | 테스트 전략 보강, 회귀 방지용 테스트 추가 | developer aide |
| `security-auditor` | trust boundary, auth, secret, validation, exploit risk 점검 | shared security aide |
| `performance-engineer` | 병목 분석, hot path 점검, 성능 회귀 탐지 | developer/systems aide |
| `deployment-engineer` | 배포 절차, rollout, rollback, release safety 검토 | systems aide |

---

## 역할별 기본 매핑

### Manager

- 기본: `task-distributor`
- dual 충돌/다중안 비교: `consensus-reviewer`
- 긴 결과 요약: `report-synthesizer`

### Discussion

- 코드 방향 논의: `code-mapper`
- 외부 사실/버전 확인: `docs-researcher`
- 옵션 비교: `consensus-reviewer`
- 아키텍처 선택지 검증: `architect-reviewer`
- 장문 압축: `report-synthesizer`

### Developer

- 기능/리팩터: `code-mapper + docs-researcher`
- 버그: `debugger + code-mapper`
- 마무리: `reviewer`
- 구조 정리 비중이 크면: `+ refactoring-specialist`
- 테스트 보강이 핵심이면: `+ test-automator`
- auth/권한/입력검증/secret이 걸리면: `+ security-auditor`
- 성능 민감 hot path면: `+ performance-engineer`
- 설계 경계가 흔들리면: `+ architect-reviewer`

### Researcher

- 조사 시작: `search-specialist + docs-researcher`
- codebase 연동: `+ code-mapper`
- 증거량 많음: `report-synthesizer`

### Systems Engineer

- 감사 시작: `runtime-auditor`
- repo/runtime 접점: `+ code-mapper`
- risky change plan: `+ reviewer`
- 공급자 문서 확인: `+ docs-researcher`
- rollout/rollback 설계: `+ deployment-engineer`
- exposed surface/hardening 검토: `+ security-auditor`
- 성능/용량 병목: `+ performance-engineer`

---

## 운영 규칙

1. 비사소한 작업은 subagent kickoff를 기본값으로 한다.
2. 복잡한 작업은 2-way 이상 병렬 fan-out을 기본값으로 한다.
3. `manager`는 outcome, 제약, 우선순위를 주고, `developer` / `researcher` / `systems-engineer` 같은 execution lead가 내부 specialist 조합을 스스로 결정한다.
4. top-level 역할이 최종 권한과 공식 산출물 책임을 가진다.
5. subagent 결과를 그대로 최종 보고로 내지 않는다.
6. trivial 예외가 아닌데 subagent를 생략했다면 이유를 설명할 수 있어야 한다.

---

## 아직 남은 일

- 실제 사용 흔적/성과를 대시보드에 노출할지 결정
- role별 starter pack을 더 세분화할지 결정
- 필요하면 Claude/Codex 생성 스크립트 도입
