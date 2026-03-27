# 지식 관리

- **대상 행동**: "교훈 추출/기록", "index.md 큐레이션"

---

## 1. 교훈 추출

### 시점
- 토론이 resolved로 종료될 때
- 주요 작업 완료 후 회고 시

### 절차
1. 토론 내용을 검토한다.
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
- 끝난 토론은 index에 올리지 않는다.

### 업데이트 시점
- 새 교훈 추가 시
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

## 3. 종료 문서 정리

- 종료된 토론은 교훈 추출 후 정리한다. 이중 저장(workspace→memory 이동)은 하지 않는다.
