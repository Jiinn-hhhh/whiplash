# 파일 소유권 규칙 (Agent Team 모드)

Agent Team 모드에서는 여러 에이전트가 동시에 파일을 읽고 쓸 수 있다. 두 에이전트가 같은 파일을 편집하면 한쪽이 덮어쓰므로, 엄격한 파티셔닝으로 충돌을 방지한다.

이 문서는 `agents/manager/techniques/orchestration.md` §9의 파일 소유권 원칙을 Agent Team 환경에 맞게 **보충**한다.

---

## 1. 전용 공간

각 에이전트는 자기 전용 공간에서만 파일을 생성/수정한다.

| 에이전트 | 전용 작업 공간 | 전용 메모리 |
|----------|---------------|------------|
| Manager | (팀 전체 조율, 공유 공간 관리) | `memory/manager/` |
| Developer | `workspace/teams/developer/` | `memory/developer/` |
| Researcher | `workspace/teams/research/` | `memory/researcher/` |
| Monitoring | (점검 결과 보고) | `memory/monitoring/` |

각 에이전트는 자기 전용 메모리에 `status.json`을 작성하여 현재 상태를 보고한다. Manager만 `memory/manager/overrides/` 디렉토리에 다른 에이전트의 상태 오버라이드를 작성할 수 있다.

---

## 2. 공유 공간 규칙

### `workspace/shared/`

| 행위 | 허용 |
|------|------|
| 새 파일 추가 | 모든 에이전트 가능 |
| 기존 파일 수정 | **Manager만** |
| 파일 이동/삭제 | **Manager만** |

- 토론/회의 파일: 참여자가 자기 섹션을 **append** (기존 Append-only 원칙 유지)
- 공지(announcements/): Manager가 작성

### `memory/knowledge/`

| 파일/폴더 | 소유자 |
|-----------|--------|
| `index.md` | **Manager 전용** |
| `lessons/LESSON-NNN.md` | Manager가 생성, 다른 에이전트는 읽기만 |
| `docs/` | 누구나 추가 가능, 수정은 작성자만 |
| `discussions/`, `meetings/` | Manager가 종료된 문서를 이동 |
| `archives/` | Manager가 순환 시 이동 |

### `reports/`

| 행위 | 허용 |
|------|------|
| 새 보고서 작성 | 모든 에이전트 가능 |
| 기존 보고서 수정 | 작성자만 |

---

## 3. 외부 코드베이스

프로젝트의 외부 코드(`projects/{name}/project.md`에 기록된 레포)에 대한 소유권:

| 에이전트 | 권한 |
|----------|------|
| Developer | **주 소유자** — 프로덕션 코드 직접 수정 |
| Researcher | 별도 디렉토리 또는 브랜치에서 프로토타입 작업. 프로덕션 코드 직접 수정 금지 |
| Monitoring | 읽기 전용 |
| Manager | 직접 수정 금지 |

---

## 4. 충돌 방지 원칙

1. **의심스러우면 쓰지 마라**: 다른 에이전트가 작업 중일 수 있는 파일은 건드리지 않는다.
2. **새 파일 > 기존 파일 수정**: 공유 공간에서는 기존 파일 수정보다 새 파일 추가를 선호한다.
3. **Manager가 중재**: 파일 소유권에 대한 불확실성은 Manager에게 SendMessage로 확인한다.
4. **중간 결과 보존**: 긴 작업은 중간 결과를 자기 전용 공간에 저장한다. 크래시 시 복구 가능.

---

## 5. tmux 모드와의 차이

tmux 모드에서는 monitor.sh가 파일 접근을 간접적으로 조율했다. Agent Team 모드에서는 이 규칙이 유일한 파티셔닝 메커니즘이므로 **엄격히 준수**해야 한다.
