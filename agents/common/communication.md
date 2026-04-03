# 소통 규칙

에이전트 간 소통의 모든 규칙을 정의한다.

---

## 1. 공유 공간 구조

각 프로젝트 안에 다음 구조가 존재한다. 아래 경로는 현재 프로젝트 기준 상대 경로다 (상세: [project-context.md](project-context.md)).

```
workspace/                   # 런타임 작업 공간
  teams/
    {team-name}/             #   팀별 공간 (내부 작업, 팀 내 토론)

memory/                      # 축적된 상태
  manager/                   #   sessions.md, assignments.md, activity.md
  discussion/                #   handoff.md
  {role}/                    #   에이전트 개인 메모 (세션 간 맥락 보존)
```

- 물리 경로: `projects/{project-name}/workspace/`, `projects/{project-name}/memory/`
- `workspace/teams/{team-name}/` — 팀 내부 작업과 토론 공간.
- `memory/` — 축적된 상태. 상세 관리는 [memory.md](memory.md) 참조.

---

## 2. 소통 원칙

### Append-only
- **다른 에이전트가 쓴 내용을 수정하지 않는다.**
- 자기 섹션만 추가(append)한다.

### 근거 제시 의무
- 모든 결정과 산출물에는 이유를 명시한다.

### 팀 간 소통
- 매니저를 거칠 필요 없다. 직접 소통 가능.

---

## 3. 실시간 알림 (notify)

에이전트 간 주요 소통 채널.

### 전송 방법

```bash
bash scripts/message.sh {project} {from} {to} {kind} {priority} "{subject}" "{content}"
```

- kind: `task_complete` | `status_update` | `need_input` | `escalation` | `agent_ready` | `reboot_notice` | `consensus_request`
- 추가 kind: `consensus_response`, `task_assign`, `alert_resolve`, `user_notice`
- priority: `normal` | `urgent`

### 사용 규칙

- `task_assign`는 Manager만 보낼 수 있다.
- `task_complete`, `agent_ready`, `reboot_notice`의 정식 수신자는 Manager만 된다.
- `user_notice`는 Manager가 유저에게 남기는 비차단 알림이다.
- peer direct는 `status_update`, `need_input`, `escalation`, `consensus_request`, `consensus_response`만 허용한다.
- peer direct 메시지는 Manager에도 자동 미러링된다.
- 메시지 로그(`logs/message.log`)가 이력을 기록한다.
- 알림 프로토콜 상세는 `agents/manager/techniques/orchestration.md` §11 참조.

### 완료 보고 규칙

- `task_complete` 전에 **자체 검증을 완료**해야 한다.
- `task_complete` 메시지에 **검증 결과를 포함**한다.
- 검증 없이 완료 보고하는 것은 금지한다.

---

## 4. 하면 안 되는 것

- 다른 에이전트의 텍스트를 편집/삭제하지 않는다.
- 근거 없이 결정이나 주장을 작성하지 않는다.
