# 멀티 에이전트 오케스트레이션

**대상 행동**: "에이전트 인스턴스를 생성·관리하고, 멀티 모드에서 이중 실행 결과를 중재하여 합의를 도출한다"

---

## 1. 실행 모드

| 모드 | 설명 | 결정 시점 |
|------|------|-----------|
| 단독 (solo) | Manager가 역할별 에이전트 1개씩 실행 | 온보딩 시 유저 선택 |
| 멀티 (dual) | 같은 태스크를 두 백엔드로 이중 실행 → 합의 | 온보딩 시 유저 선택 |

- project.md `운영 방식`에 `실행 모드: solo | dual` 기록
- 멀티 모드에서도 Manager가 단순 태스크(정기 점검, 단순 조회 등)는 단독으로 판단 가능

---

## 2. 에이전트 세션 생명주기

```
부팅(Boot) → 태스크 디스패치(Dispatch) → 결과 수집(Collect) → [합의(Consensus)] → 반복 또는 종료
```

- **부팅**: 첫 호출로 에이전트에게 역할과 프로젝트를 알려주는 온보딩 메시지 전달. session_id 획득.
- **디스패치**: `--resume {session_id}`로 후속 태스크 전달. 이전 대화 맥락 유지됨.
- **수집**: 에이전트의 텍스트 응답 + 파일 시스템 산출물 확인.
- **합의** (멀티 모드): Manager가 양쪽 결과를 교차 전달하여 토론 중재.
- **종료**: 프로젝트 끝나거나 역할 불필요 시 세션 사용 중단.

---

## 3. 부팅 절차

### Claude Code 에이전트 부팅

첫 호출 시 메시지 구조:

```
너는 {Role} 에이전트다.
레포 루트: {repo_root}
현재 프로젝트: projects/{name}/

아래 온보딩 절차를 순서대로 따라라:
1. agents/common/README.md 읽기
2. agents/common/project-context.md 읽기
3. agents/{role}/profile.md 읽기
4. projects/{name}/project.md 읽기
5. domains/{domain}/context.md 읽기
6. (해당 시) domains/{domain}/{role}.md 읽기
7. (해당 시) projects/{name}/team/{role}.md 읽기
8. memory/knowledge/index.md 읽기

온보딩이 끝나면 준비 완료를 보고해라.
```

CLI:

```bash
session_id=$(claude -p "{부팅 메시지}" \
  --output-format json \
  --allowedTools "Read,Glob,Grep,Write,Edit,Bash,WebSearch,WebFetch" \
  --max-turns 20 \
  | jq -r '.session_id')
```

### Codex 에이전트 부팅

Codex는 AGENTS.md를 자동으로 읽으므로, 태스크 지시에 역할과 프로젝트 정보를 포함:

```bash
codex -p "{역할 + 온보딩 메시지 + 태스크}" --output-format json
```

(Codex CLI 구체 플래그는 실제 사용 시 확인 후 보정)

### CLI 플래그 요약

- `--output-format json`: session_id 캡처용
- `--allowedTools`: 무인 실행을 위한 도구 자동 승인
- `--max-turns`: 폭주 방지

---

## 4. 세션 추적

`memory/manager/sessions.md`에 활성 세션 기록:

```markdown
# 활성 에이전트 세션

| 역할 | 백엔드 | Session ID | 상태 | 시작일 | 모델 | 비고 |
|------|--------|-----------|------|--------|------|------|
| researcher | claude | abc-123 | active | 2026-02-13 | opus | |
| researcher | codex | def-456 | active | 2026-02-13 | - | dual pair |
| developer | claude | ghi-789 | active | 2026-02-13 | sonnet | |
| developer | codex | jkl-012 | active | 2026-02-13 | - | dual pair |
| monitoring | claude | mno-345 | active | 2026-02-13 | haiku | solo |
```

- 멀티 모드: 같은 역할에 두 행 (claude + codex)
- Manager가 세션 생성/종료 시 업데이트
- 세션이 오래되거나 맥락이 너무 길어지면 새 세션으로 교체 가능

---

## 5. 단독 모드: 태스크 디스패치

### 순차 실행 (의존성 있는 태스크)

```bash
result=$(claude -p "태스크 지시" --resume $researcher_id --output-format json)
# 결과 확인 후 다음 에이전트에게 지시
claude -p "이전 결과 기반 태스크" --resume $developer_id --output-format json
```

### 병렬 실행 (독립 태스크)

```bash
claude -p "리서치 태스크" --resume $researcher_id --output-format json > /tmp/r.json &
claude -p "인프라 태스크" --resume $developer_id --output-format json > /tmp/d.json &
wait
```

---

## 6. 멀티 모드: 이중 실행 + 합의 프로토콜

### 핵심 흐름

```
Step 1: 같은 태스크를 양쪽에 동시 디스패치
Step 2: 양쪽 결과 수집
Step 3: 결과 교차 전달 → 토론 라운드
Step 4: 합의 판정 → 최종 산출물
```

### Step 1 — 이중 디스패치

```bash
# 같은 태스크를 Claude Code와 Codex에 동시 실행
claude -p "태스크 T" --resume $researcher_claude --output-format json > /tmp/result_a.json &
codex -p "태스크 T" --resume $researcher_codex --output-format json > /tmp/result_b.json &
wait
```

### Step 2 — 결과 수집

두 결과를 파일에서 읽고 비교.

### Step 3 — 토론 라운드 (Manager 중재)

```bash
# Agent A에게 B의 결과를 보여주고 검토 요청
claude -p "다른 에이전트가 같은 태스크에 대해 아래 결과를 냈다:
{결과 B 요약}

너의 결과와 비교하여:
1. 동의하는 부분
2. 다른 부분과 그 이유
3. 최종 합의안 제안
을 정리해라." --resume $researcher_claude --output-format json > /tmp/review_a.json

# Agent B에게도 마찬가지
codex -p "{같은 구조, 결과 A를 보여줌}" --resume $researcher_codex --output-format json > /tmp/review_b.json
```

### Step 4 — 합의 판정

| 상황 | Manager 행동 |
|------|-------------|
| 양쪽 동의 | 합의된 결과를 최종 산출물로 채택 |
| 부분 차이 | Manager가 양쪽 논거를 보고 더 나은 쪽 채택, 이유 기록 |
| 근본적 차이 | 추가 토론 라운드 (최대 2회). 그래도 미합의 시 Manager가 판정하거나 유저 에스컬레이션 |

토론은 **최대 2라운드**. 무한 토론 방지.

### 합의 기록

합의 결과는 `workspace/shared/discussions/`에 기록:

```markdown
# 합의 기록 — {태스크 제목}

- **Date**: YYYY-MM-DD
- **태스크**: ...
- **Agent A** (Claude Code): {핵심 결론}
- **Agent B** (Codex): {핵심 결론}
- **합의**: {최종 결론}
- **차이점**: {있었다면 기록}
- **판정 근거**: {Manager가 개입했다면 이유}
```

---

## 7. 모델 선택 가이드

| 역할 | Claude Code 모델 | 이유 |
|------|-----------------|------|
| Researcher | opus | 복잡한 분석, 논문 해석 |
| Developer | sonnet | 빠른 코드 작성 |
| Monitoring | haiku | 단순 점검, 비용 절감 |

모델은 부팅 시 `--model` 플래그로 지정. Codex는 자체 모델을 사용.

---

## 8. 안전장치

- **타임아웃**: `--max-turns`으로 에이전트 턴 수 제한
- **비용 제한**: `--max-budget-usd`로 세션 당 비용 상한 설정
- **토론 라운드 상한**: 최대 2라운드. 미합의 시 Manager 판정 또는 유저 에스컬레이션.
- **에러 처리**: exit code ≠ 0 → Manager가 재시도 또는 다른 접근
- **파일 충돌 방지**: 이중 실행 시 양쪽 에이전트가 같은 파일에 쓰지 않도록 각각 별도 경로 사용

---

## 9. 병렬 실행 시 파일 소유권

| 안전 | 위험 |
|------|------|
| 각 에이전트가 자기 하위 디렉토리에 쓰기 | 같은 파일 동시 수정 |
| workspace/shared/에 새 파일 추가 | workspace/shared/의 기존 파일 수정 |
| memory/{role}/에 쓰기 | memory/knowledge/index.md 동시 수정 |

원칙:

- `memory/knowledge/index.md`와 `workspace/shared/`의 기존 파일은 **Manager만** 수정
- 이중 실행 시 같은 역할의 두 에이전트는 **별도 작업 디렉토리** 사용
- 합의 후 Manager가 최종 결과를 정식 위치에 배치
