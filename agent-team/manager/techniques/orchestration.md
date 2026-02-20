# Agent Team 오케스트레이션

**대상 행동**: "Claude Code Agent Team 기능으로 에이전트 팀을 생성·관리하고, 비동기적으로 팀을 운영한다"

이 문서는 `agents/manager/techniques/orchestration.md`의 agent-team 모드 대응 문서다. tmux/mailbox/monitor 대신 TeamCreate, Task, SendMessage 등 네이티브 도구를 사용한다.

---

## 1. 실행 모드

| 모드 | 설명 |
|------|------|
| agent-team | Manager가 Claude Code 팀 리드 역할을 겸하여 네이티브 Agent Team 도구로 팀 운영 |

- project.md `운영 방식`에 `실행 모드: agent-team` 기록
- tmux, orchestrator.sh, mailbox.sh, monitor.sh를 사용하지 않는다

---

## 2. 생명주기

```
TeamCreate → Task(spawn) × N → 준비 대기 → 대시보드 시작 → 태스크 분배 → 결과 수집 → 반복 또는 대시보드 종료 → TeamDelete
```

### 2.1 팀 생성

```
TeamCreate(team_name: "whiplash-{project}")
```

- 프로젝트당 하나의 팀
- 자동으로 `~/.claude/teams/whiplash-{project}/config.json` 생성

### 2.2 팀원 스폰

각 역할에 대해 `Task` 도구로 스폰한다:

```
Task(
  team_name: "whiplash-{project}",
  name: "{role}",
  subagent_type: "general-purpose",
  prompt: "{spawn-prompts/{role}.md의 프롬프트, 변수 치환 완료}",
  mode: "bypassPermissions"
)
```

스폰 순서: Researcher → Developer → Monitoring (의존성 없으므로 병렬 가능)

스폰 프롬프트는 `agent-team/manager/tools/spawn-prompts/{role}.md`에 정의되어 있다. Manager가 아래 변수를 치환한다:
- `{REPO_ROOT}`: 레포 루트 절대 경로
- `{PROJECT}`: 현재 프로젝트 이름
- `{DOMAIN}`: project.md에 기록된 도메인

**{REPO_ROOT} 결정**: Manager가 스폰 전에 레포 루트를 확인한다.
- Bash 도구로 `git rev-parse --show-toplevel` 실행하여 절대 경로 획득
- 이 값을 spawn-prompts의 `{REPO_ROOT}`에 치환

### 2.3 준비 대기

각 팀원이 온보딩을 완료하면 SendMessage로 "준비 완료"를 보고한다. Manager는 모든 팀원의 준비 완료 메시지를 수신한 후 태스크 분배를 시작한다.

### 2.4 태스크 분배

`agent-team/manager/techniques/task-distribution.md` 참조.

### 2.5 종료

```
1. 모든 진행 중인 태스크 완료 확인
2. 각 팀원에게 SendMessage(type: "shutdown_request") 전송
3. 팀원들의 shutdown_response 수신 확인
4. TeamDelete — 팀 리소스 정리
```

---

## 3. 모델 선택

Agent Teams에서 팀원의 모델을 직접 지정할 수 없다. `subagent_type`으로 간접 조율한다:

| 역할 | subagent_type | 비고 |
|------|--------------|------|
| Researcher | general-purpose | 복잡한 분석 수행 |
| Developer | general-purpose | 코드 작성 |
| Monitoring | general-purpose | 점검 수행 |

---

## 4. 비용 관리

- **broadcast 최소화**: broadcast는 모든 팀원에게 개별 전송된다. 1:1 SendMessage를 기본으로 사용한다.
- **상세 내용은 파일로**: SendMessage에 긴 내용을 담지 않는다. 파일에 작성하고 경로만 공유한다.
- **불필요한 폴링 자제**: TaskList를 지나치게 자주 호출하지 않는다. 팀원의 SendMessage 보고를 기본 신호로 사용한다.

---

## 5. 세션 추적

tmux 모드의 `memory/manager/sessions.md` 대신, Agent Team은 자동으로 팀 정보를 관리한다:

- `~/.claude/teams/whiplash-{project}/config.json` — 팀원 목록 자동 관리
- 팀원 이름으로 SendMessage 가능 (agentId 불필요)

Manager는 팀 운영 상태를 `memory/manager/`에 메모할 수 있다 (선택).

---

## 6. tmux 모드 도구 사용 금지

agent-team 모드에서는 다음 도구를 사용하지 않는다:

| 금지 도구 | 대체 |
|-----------|------|
| `orchestrator.sh` | TeamCreate, Task, SendMessage |
| `mailbox.sh` | SendMessage |
| `monitor.sh` | Manager가 TaskList + SendMessage로 직접 관리 |
| `tmux` 명령어 | 불필요 |

---

## 7. 안전장치

### 팀원 장애

`agent-team/manager/techniques/crash-recovery.md` 참조.

### 파일 충돌 방지

`agent-team/common/file-ownership.md` 참조.

---

## 8. 대시보드 연동

### 시작

모든 팀원의 "준비 완료"를 수신한 후, 첫 태스크 분배 전에:

1. 초기 상태 JSON을 `memory/manager/agent-team-status.json`에 작성
2. 대시보드 서버를 백그라운드로 시작:
   ```bash
   python3 dashboard/server.py --project {project} &
   ```
   - 서버가 시작되면 브라우저가 자동으로 `http://localhost:8420`을 연다 (`--no-open` 미사용)
   - 서버 PID를 `memory/manager/dashboard.pid`에 저장

### 상태 업데이트

Manager는 다음 이벤트 발생 시 `agent-team-status.json`을 갱신한다:
- 팀원 스폰 완료 (state: "working")
- 태스크 할당 (state: "working", current_task: 태스크 요약)
- 태스크 완료 보고 수신, 다음 태스크 미정 (state: "idle", current_task: null)
- 태스크 완료 후 즉시 새 태스크 할당 (state: "working", current_task: 새 태스크 요약)
- 장애 감지 (state: "crashed")
- 재스폰 (state: "rebooting" → "working")
- 유저에게 질문 시 (자신의 state: "waiting_for_user", current_task에 질문 요약)
- 유저 응답 수신 후 (state: "working"으로 복원)

대시보드 상태-행동 매핑:

| state | 대시보드 위치 | 시각 효과 |
|-------|-------------|----------|
| working | 책상 | 작업중 애니메이션 |
| idle | 휴게실 | 서있기 + "대기중..." |
| sleeping | 휴게실 소파 | 누워서 zzZ |
| crashed | 책상 | 스파크 + ERROR! |
| waiting_for_user | 책상 | 주황 버블 + 상단 배너 |

### 종료

shutdown_request 전송 전에:

1. `dashboard.pid` 파일에서 PID를 읽어 서버 프로세스 종료:
   ```bash
   kill $(cat memory/manager/dashboard.pid) 2>/dev/null
   rm -f memory/manager/dashboard.pid
   ```
2. `agent-team-status.json` 정리 (선택)

### agent-team-status.json 양식

기존 `status-collector.sh` 출력과 동일한 구조:

```json
{
  "project": "{project}",
  "timestamp": {unix_seconds},
  "monitor": {
    "alive": false,
    "heartbeat_age_sec": -1
  },
  "agents": {
    "manager": {
      "role": "manager",
      "model": "sonnet",
      "session_status": "active",
      "idle_seconds": 0,
      "state": "working",
      "reboot_count": 0,
      "is_hung": false,
      "mailbox_new": 0,
      "current_task": "팀 조율 중"
    },
    "researcher": { "..." : "..." },
    "developer": { "..." : "..." },
    "monitoring": { "..." : "..." }
  }
}
```

`monitor` 필드는 agent-team에서 사용하지 않으므로 기본값(`alive: false`)으로 둔다.
