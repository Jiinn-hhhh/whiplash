# Subagent 로드맵

## 목적

이 문서는 Whiplash에 backend-native subagent를 어떻게 확장할지에 대한 다음 단계 설계 메모다. v1 starter pack은 이미 구현되었고, 이 문서는 그 이후 확장 전략과 운영 원칙을 정리한다.

현재 상태:
- v1 starter pack은 이미 구현되었고, 현재 운영 계약은 `docs/native-subagents.md`를 기준으로 본다.
- 이 문서는 그 이후 확장 단계(중립 스펙, 생성기, 더 깊은 계층화)를 다룬다.

핵심 전제:

- Codex와 Claude Code는 모두 subagent를 지원한다.
- 그러나 포맷과 런타임 계약이 다르다.
  - Codex: `.codex/agents/*.toml`
  - Claude Code: `.claude/agents/*.md` + YAML frontmatter
- 따라서 `똑같은 파일`이 아니라 `같은 책임, 다른 backend adapter`가 맞다.

---

## 왜 바로 구현하지 않았나

현재 Whiplash의 더 큰 병목은 `manager`가 긴 토론과 실행 통제를 동시에 들고 있다는 점이었다. 이 문제를 풀지 않은 채 subagent를 붙이면 다음 문제가 생긴다.

1. control-plane 경계가 불분명해진다.
2. 누가 최종 책임자인지 흐려진다.
3. 유저 토론, 실행 계획, specialist fan-out이 한꺼번에 섞인다.

그래서 순서는 다음이 맞다.

1. `discussion` 분리
2. control-plane 안정화
3. role별 subagent 도입

---

## 목표 구조

Whiplash의 장기 구조는 아래를 목표로 한다.

```text
User
├─ Discussion
└─ Manager
   ├─ Developer
   │  ├─ specialist subagents
   ├─ Researcher
   │  ├─ specialist subagents
   └─ Systems Engineer
      ├─ specialist subagents
```

핵심은:

- top-level role은 계속 최종 책임자다.
- subagent는 좁은 specialist 역할만 맡는다.
- 최종 산출물은 top-level role이 직접 통합해서 Whiplash 형식으로 보고한다.

---

## top-level 역할 재해석

subagent 도입 이후 top-level 역할은 단순 worker가 아니라 `lead`가 된다.

### Developer

- 지금: 코딩 주체
- 이후: 개발 리드 + 내부 specialist 조율자

예상 specialist:

- `code-mapper`
- `reviewer`
- `debugger`
- `docs-researcher`
- 스택별 specialist

### Researcher

- 지금: 리서치 주체
- 이후: 리서치 리드 + 내부 분석/검색 specialist 조율자

예상 specialist:

- `docs-researcher`
- `search-specialist`
- `research-analyst`

### Systems Engineer

- 지금: 운영/배포/런타임 리드
- 이후: 운영 리드 + 내부 검증 specialist 조율자

예상 specialist:

- `deployment-engineer`
- `security-engineer`
- `cloud-architect`

### Manager

Manager도 subagent를 둘 수는 있다. 하지만 성격은 worker가 아니라 `참모`여야 한다.

예상 staff aide:

- `task-distributor`
- `consensus-reviewer`
- `report-synthesizer`

금지 방향:

- Manager가 `debugger`, `code-mapper`, `docs-researcher` 같은 실무 specialist를 직접 굴리는 구조

---

## 운영 원칙

### 1. 무조건 fan-out 하지 않는다

`필요한 subagent를 다 부르면 더 잘할 것`이라는 가정은 대체로 틀리다.

문제:

- 컨텍스트 수집 중복
- 비용 증가
- 응답 지연
- 책임 경계 붕괴
- 최종 통합 품질 저하

정답:

- `좁고 반복적인 일`에만 subagent를 쓴다.

### 2. depth는 1로 시작한다

초기 운영 원칙:

- top-level role -> specialist subagent
- specialist의 재귀 fan-out 금지

이유:

- 디버깅과 운영 복잡도를 제어하기 쉽다.
- 누가 어떤 결론을 냈는지 추적이 쉽다.

### 3. 역할당 기본 2~4개만 둔다

초기 curated set은 작아야 한다.

추천:

- Developer: 3~4개
- Researcher: 2~3개
- Systems Engineer: 2~3개
- Manager aide: 1~2개

135개 같은 대형 카탈로그 전체를 바로 들여오지 않는다.

### 4. 한 번에 2~3개까지만 병렬 호출한다

초기 운영에서는 fan-out 폭도 제한한다.

이유:

- 통합 비용이 급증하는 지점을 늦추기 위해서
- manager/lead 역할이 실제로 결과를 읽고 통합할 수 있게 하기 위해서

### 5. subagent는 shared 문서를 직접 만지지 않는다

중요 규칙:

- `workspace/shared/`
- `reports/tasks/`
- 공식 handoff 문서

위 영역은 top-level role만 최종 반영한다.

subagent는 내부 임시 산출물이나 응답만 반환하고, 공식 결과는 lead가 정리한다.

---

## backend 전략

### 원칙: 같은 책임, 다른 구현

Codex와 Claude Code에서 내부 호출 로직까지 완전히 맞출 필요는 없다.

맞춰야 하는 것:

- 역할 이름
- 책임 범위
- 출력 기대치
- top-level role의 최종 보고 형식

맞추지 않아도 되는 것:

- 파일 포맷
- exact prompt wording
- exact delegation syntax
- exact auto/manual spawn 방식

---

## config 전략

장기적으로는 `중립 스펙 -> backend별 생성`이 좋다.

### 추천 방향

중립 정의 예시:

```yaml
name: reviewer
purpose: correctness, security, missing tests review
inputs:
  - diff
  - related docs
constraints:
  - no direct code changes
outputs:
  - findings-first review
```

이 중립 정의에서 아래를 생성한다.

- Codex용 TOML
- Claude Code용 Markdown + YAML

### 이유

- 역할 의도를 한 곳에서 관리할 수 있다.
- backend 포맷 차이를 생성 단계에서 흡수할 수 있다.
- dual mode 비교가 쉬워진다.
- 손복붙으로 인한 drift를 줄인다.

---

## Manager와 Discussion의 위치

`discussion`은 subagent가 아니다. control-plane 상위 역할이다.

이 구분이 중요하다.

- `discussion`은 유저와의 전략 토론 창구
- `manager`는 실행 통제 허브
- specialist subagent는 top-level role 아래의 내부 도구

즉 순서는:

1. 유저가 `discussion`에서 전략을 정한다.
2. `discussion`이 handoff를 Manager에게 넘긴다.
3. Manager가 top-level role에게 일을 분배한다.
4. top-level role이 필요하면 내부 specialist를 호출한다.

---

## v1 도입 후보

처음 도입할 공통 specialist 후보는 아래 네 개 정도가 적당하다.

- `reviewer`
- `docs-researcher`
- `code-mapper`
- `debugger`

이유:

- Codex/Claude 양쪽에 모두 자연스럽게 대응된다.
- 역할 경계가 좁다.
- top-level role의 통합 가치가 높다.

---

## 보류된 설계 질문

다음 작업에서 풀어야 할 질문:

1. subagent 결과를 top-level role 내부에서 어떤 형식으로 보관할 것인가?
2. role별 기본 curated set을 어디에 정의할 것인가?
3. 중립 스펙 파일을 어느 디렉토리에 둘 것인가?
4. Codex/Claude 생성기를 실제 스크립트로 둘 것인가?
5. dual mode에서 backend별 subagent 차이를 Manager가 얼마나 알아야 하는가?

---

## 다음 작업 재개 포인트

이 문서를 기준으로 다음 단계에서는 아래 순서로 이어간다.

1. 역할별 curated subagent 후보 4~8개 선정
2. 중립 스펙 포맷 초안 작성
3. Codex/Claude 출력 디렉토리 구조 설계
4. top-level role별 호출 규칙 문서화
5. 실제 starter pack을 최소 세트만 구현

중요:

- `discussion` 안정화가 먼저다.
- subagent는 control-plane을 대체하는 것이 아니라, top-level lead의 내부 specialist layer다.
