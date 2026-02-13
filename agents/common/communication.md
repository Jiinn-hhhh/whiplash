# 소통 규칙

에이전트 간 소통의 모든 규칙을 정의한다.

---

## 1. 공유 공간 구조

```
workspace/                   # 런타임 작업 공간 (진행 중인 것)
  shared/                    #   진행 중인 것만
    discussions/             #     진행 중인 토론
    meetings/                #     진행 중인 회의
    announcements/           #     공지
  teams/
    {team-name}/             #   팀별 공간 (내부 작업, 팀 내 토론)

memory/                      # 축적된 상태
  {role}/                    #   에이전트 개인 메모
  knowledge/                 #   축적된 지식 전부
    lessons/                 #     활성 교훈 (최대 30개)
    docs/                    #     레퍼런스 문서
    discussions/             #     끝난 토론 원본
    meetings/                #     끝난 회의록 원본
    archives/                #     순환된 비활성 교훈
    index.md                 #     지식 지도

reports/                     # 사용자 열람용 문서
```

- `workspace/shared/` — 진행 중인 토론, 회의, 공지만 둔다. 종료된 것은 `memory/knowledge/`로 이동.
- `workspace/teams/{team-name}/` — 팀 내부 작업과 토론 공간.
- `memory/knowledge/` — 축적된 모든 지식. 상세 관리는 [memory.md](memory.md) 참조.
- `reports/` — 사용자가 볼 보고서, 설계서 등.

---

## 2. 소통 원칙

### 모든 소통은 텍스트/md로
- 공유 공간에 마크다운 파일로 작성한다. "공개 슬랙 채널"과 같은 개념.
- 비공개 DM은 없다. 모든 소통은 관련 에이전트가 열람 가능.

### Append-only
- **다른 에이전트가 쓴 내용을 수정하지 않는다.**
- 자기 섹션만 추가(append)한다.
- 수정이 필요하면 새 섹션에서 정정 내용을 작성한다.

### 기본 관찰 범위
- 각 에이전트는 **자기 팀 공간 + shared/**를 기본으로 관찰한다.
- 다른 팀 공간은 잠겨있지 않다. 필요 시 열람 가능.

### 팀 간 소통
- `shared/`에 올린다.
- 매니저를 거칠 필요 없다. 직접 소통 가능.

### 근거 제시 의무
- 모든 결정과 산출물에는 이유를 명시한다.
- 교훈을 참고했다면 반드시 `Cite LESSON-NNN` 형식으로 인용한다.

---

## 3. 토론

1. `workspace/shared/discussions/` 또는 팀 공간에 토론 파일을 생성한다.
2. 관련된 에이전트가 각자의 섹션을 append한다.
3. 형식은 [formats.md](formats.md)의 토론 템플릿을 따른다.
4. 토론이 종료되면:
   - 교훈을 추출한다 (해당 시).
   - 원본을 `memory/knowledge/discussions/`로 이동한다.

---

## 4. 회의

1. 누구든 필요하면 회의를 요청할 수 있다.
   - 팀 내: 팀장에게 요청.
   - 팀 간: `workspace/shared/meetings/`에 회의록 파일 생성.
2. 구조화된 **3라운드** 진행:
   - **Round 1** — 각자 입장 서술.
   - **Round 2** — 다른 입장에 대한 응답.
   - **Round 3** — 주최자가 종합 및 결론 작성.
3. 형식은 [formats.md](formats.md)의 회의록 템플릿을 따른다.
4. 회의 종료 후:
   - 교훈을 추출한다 (해당 시).
   - 원본을 `memory/knowledge/meetings/`로 이동한다.

---

## 5. 하면 안 되는 것

- 다른 에이전트의 텍스트를 편집/삭제하지 않는다.
- `workspace/shared/`에 종료된 토론/회의를 방치하지 않는다 (종료 시 `memory/knowledge/`로 이동).
- 근거 없이 결정이나 주장을 작성하지 않는다.
- 교훈을 참고하고도 인용(`Cite LESSON-NNN`)을 누락하지 않는다.
