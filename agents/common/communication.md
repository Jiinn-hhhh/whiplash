# 소통 규칙

에이전트 간 소통의 모든 규칙을 정의한다.

---

## 1. 공유 공간 구조

각 프로젝트 안에 다음 구조가 존재한다. 아래 경로는 현재 프로젝트 기준 상대 경로다 (상세: [project-context.md](project-context.md)).

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

reports/                     # 사용자 열람 전용 (에이전트는 쓰기만, 읽기 참조 금지)
```

- 물리 경로: `projects/{project-name}/workspace/`, `projects/{project-name}/memory/`, `projects/{project-name}/reports/`
- `workspace/shared/` — 진행 중인 토론, 회의, 공지만 둔다. 종료된 것은 `memory/knowledge/`로 이동.
- `workspace/teams/{team-name}/` — 팀 내부 작업과 토론 공간.
- `memory/knowledge/` — 축적된 모든 지식. 상세 관리는 [memory.md](memory.md) 참조.
- `reports/` — 에이전트가 작성하고, 사람만 읽는 단방향 산출물. 에이전트 간 정보 공유용이 아니다.

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

---

## 6. 실시간 알림 (notify)

기존 소통(토론, 회의, 공지)은 구조화된 문서 기반. 실시간 알림은 이를 보완하는 즉시 전달 채널이다.

### 소통 채널 분리

| 채널 | 목적 | 내용 | 수명 |
|------|------|------|------|
| announcements/ | 작업 지시 | 구조화된 지시서 | 영구 |
| discussions/ | 토론 | 구조화된 토론 문서 | memory/로 이동 |
| meetings/ | 회의 | 구조화된 회의록 | memory/로 이동 |
| notify | 실시간 알림 | 짧은 상태 메시지 | tmux 직접 전달 |

### 전송 방법

```bash
bash scripts/message.sh {project} {from} {to} {kind} {priority} "{subject}" "{content}"
```

- kind: `task_complete` | `status_update` | `need_input` | `escalation` | `agent_ready` | `reboot_notice` | `consensus_request`
- 추가 kind: `consensus_response`, `task_assign`, `alert_resolve`
- priority: `normal` | `urgent`
- Interactive 세션에는 한 줄 알림을 직접 입력한다. rich TUI(Claude/Codex)는 `send-keys -l`, 그 외 셸/REPL은 기존 paste 기반 전달을 사용한다.

### 사용 규칙

- **짧은 알림용**. 상세 내용은 별도 문서에 두고 참조만 포함한다.
- 기존 소통(토론, 회의, 공지) 규칙을 **대체하지 않는다**. 보충한다.
- `task_assign`는 Manager만 보낼 수 있다.
- `task_complete`, `agent_ready`, `reboot_notice`의 정식 수신자는 Manager만 된다.
- peer direct는 `status_update`, `need_input`, `escalation`, `consensus_request`, `consensus_response`만 허용한다.
- peer direct 메시지는 Manager에도 자동 미러링된다.
- 메시지 로그(`logs/message.log`)가 이력을 기록한다.
- 알림 프로토콜 상세는 `agents/manager/techniques/orchestration.md` §11 참조.

### 완료 보고 규칙 (백프레셔 게이트)

- `task_complete` 전에 **자체 검증을 완료**해야 한다. 각 에이전트의 profile.md에 정의된 검증 체크리스트를 따른다.
- `task_complete` 메시지의 content에 **검증 결과를 포함**한다 (어떤 검증을 했는지, 결과가 무엇인지).
- 검증 없이 완료 보고하는 것은 금지한다.
