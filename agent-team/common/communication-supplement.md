# 소통 규칙 보충 (Agent Team 모드)

이 문서는 `agents/common/communication.md`를 **보충**한다. Agent Team 모드에서 mailbox.sh 대신 SendMessage를 사용하는 규칙을 정의한다.

기존 소통 원칙(Append-only, Citation enforcement, 근거 제시 의무)은 그대로 유지한다.

---

## 1. 매핑 테이블

| 기존 (mailbox.sh) | Agent Team (SendMessage) |
|-------------------|-------------------------|
| `mailbox.sh {project} {from} {to} task_complete ...` | `SendMessage(type: "message", recipient: "{to}", content: "...")` |
| `mailbox.sh {project} {from} {to} status_update ...` | `SendMessage(type: "message", recipient: "{to}", content: "...")` |
| `mailbox.sh {project} {from} {to} need_input ...` | `SendMessage(type: "message", recipient: "{to}", content: "...")` |
| `mailbox.sh {project} {from} {to} escalation ...` | `SendMessage(type: "message", recipient: "{to}", content: "...")` |
| `mailbox.sh {project} {from} {to} agent_ready ...` | `SendMessage(type: "message", recipient: "manager", content: "온보딩 완료, 준비됨")` |
| monitor.sh 전체 브로드캐스트 | `SendMessage(type: "broadcast", content: "...")` |

---

## 2. SendMessage 사용 규칙

### 짧게 쓴다
- 메시지는 **5줄 이내**. 상세 내용은 파일에 작성하고 경로만 참조한다.
- 예: "TASK-001 리서치 완료. 결과: workspace/teams/research/task-001-result.md"

### 1:1 우선
- 기본적으로 `type: "message"`로 특정 수신자에게 보낸다.
- `type: "broadcast"`는 **긴급 상황에만** 사용한다 (전체 작업 중단, 치명적 오류 등).
- broadcast는 모든 팀원에게 개별 전송되므로 비용이 팀원 수에 비례한다.

### summary 필수
- 모든 SendMessage에 `summary` 필드를 포함한다 (5-10 단어).
- UI 미리보기에 표시되어 수신자가 빠르게 판단할 수 있다.

---

## 3. 구조화된 문서는 파일 기반 유지

SendMessage는 **실시간 알림** 채널이다. 아래 구조화된 소통은 기존대로 파일 기반으로 진행한다:

| 소통 유형 | 방식 | 위치 |
|-----------|------|------|
| 토론 | 파일 기반 (Append-only) | `workspace/shared/discussions/` |
| 회의 | 파일 기반 (3라운드) | `workspace/shared/meetings/` |
| 공지 | 파일 기반 | `workspace/shared/announcements/` |
| 실시간 알림 | SendMessage | (네이티브) |

토론/회의를 시작하거나 완료했을 때 SendMessage로 관련자에게 **알림**을 보내되, 토론/회의 자체는 파일에서 진행한다.

---

## 4. 팀원 간 직접 소통

Agent Team 모드에서는 팀원 간 직접 SendMessage가 가능하다.

- Manager를 거칠 필요 없다 (기존 communication.md §4 "팀 간 소통" 원칙 유지).
- 예: Researcher가 Developer에게 직접 API 스펙을 알림.
- Manager는 peer DM의 요약을 idle 알림에서 볼 수 있으므로 가시성이 유지된다.

---

## 5. 하면 안 되는 것

- SendMessage로 긴 문서를 보내지 않는다 (파일에 작성하고 경로 참조).
- broadcast를 일상적 소통에 사용하지 않는다 (비용 + 불필요한 중단).
- mailbox.sh를 사용하지 않는다 (agent-team 모드에서는 SendMessage만 사용).
- 기존 소통 원칙(Append-only, Citation, 근거 제시)을 무시하지 않는다.
