# 지식 관리

- **대상 행동**: "교훈 추출/기록", "index.md 큐레이션", "교훈 순환 관리"

---

## 1. 교훈 추출

### 시점
- 토론이 resolved로 종료될 때
- 회의가 종료될 때 (Round 3 완료)
- 주요 작업 완료 후 회고 시

### 절차
1. 토론/회의 내용을 검토한다.
2. 일반화할 수 있는 교훈이 있는지 판단한다.
3. 기존 교훈과 의미적 중복 여부를 확인한다.
   - 중복이면: 기존 교훈을 보강한다.
   - 새로운 것이면: `common/formats.md`의 교훈(Lesson) 양식으로 새 파일을 작성한다.
4. `memory/knowledge/lessons/LESSON-NNN.md`로 저장한다.

---

## 2. index.md 큐레이션

### 원칙
- `memory/knowledge/index.md`를 ~100줄 이내로 유지한다.
- 항목당 1-2줄 설명.
- 활성 교훈 + 주요 문서만 포함한다.
- 끝난 토론/회의록은 index에 올리지 않는다.

### 업데이트 시점
- 새 교훈 추가 시
- 교훈 아카이브 시
- 주요 문서 추가/변경 시
- Systems Engineer가 `live-topology.md`, `deployment-map.md`, `runtime-inventory.md`, `live-code-state.md`, `drift-report.md`, `runbook.md`를 갱신했을 때

### 운영 문서 큐레이션
- `memory/knowledge/docs/`의 live 시스템 canonical 문서는 index에 1줄씩 유지한다.
- 한 줄에는 아래만 남긴다.
  - 문서명
  - 무엇을 설명하는지
  - 마지막 검증 시각 또는 검증 범위
- 세부 점검 로그까지 index에 올리지 않는다. canonical 문서만 올린다.

---

## 3. 교훈 순환 관리 (Semantic Compaction)

### 상한
- 활성 교훈: 최대 30개 (`memory/knowledge/lessons/`)

### 트리거
- 새 교훈 추가 후 활성 교훈이 30개를 초과할 때 실행한다.

### 순환 절차 (30개 초과 시)

**1단계: 인용 횟수 카운트**
```bash
# 각 교훈의 인용 횟수를 grep으로 집계
for lesson in memory/knowledge/lessons/LESSON-*.md; do
  id=$(basename "$lesson" .md)
  count=$(grep -r "Cite ${id}" memory/ workspace/ reports/ 2>/dev/null | wc -l)
  echo "${count} ${id}"
done | sort -n
```

**2단계: 아카이브 대상 선별**
- 인용 횟수가 가장 적은 교훈을 선택한다.
- 인용 횟수가 같으면 가장 오래된 교훈(낮은 번호)을 선택한다.
- 30개 이하가 될 때까지 반복한다.

**3단계: 아카이브 실행**
- 선택된 교훈을 `memory/knowledge/archives/`로 이동한다.
- `memory/knowledge/index.md`에서 해당 항목을 **1줄 요약 + archive 참조 링크**로 교체한다.
  - 예: `- ~~LESSON-005~~: [요약] (→ archives/LESSON-005.md)`
- 원본은 archives/에 그대로 보존한다. 삭제하지 않는다.

**4단계: 검증**
- `lessons/` 폴더의 파일 수가 30개 이하인지 확인한다.
- `index.md`에서 아카이브 참조가 올바르게 남아있는지 확인한다.

---

## 4. 종료 문서 이동

| 문서 유형 | 종료 후 이동 위치 |
|-----------|-------------------|
| 토론 (resolved) | `memory/knowledge/discussions/` |
| 회의록 (종료) | `memory/knowledge/meetings/` |

- `workspace/shared/`에는 진행 중인 것만 남긴다.
