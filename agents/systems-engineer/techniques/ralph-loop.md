# Ralph Loop

- **대상 행동**: "승인 대기 없는 시스템 검증/개선 반복", "문서 권한 안에서 끝까지 밀기"

---

## 기본 사이클

`audit -> reproduce -> safe change -> verify -> rollback check -> improve`

- user 확인을 기다리며 멈추지 않는다.
- 원격 시스템 변경은 항상 `team/systems-engineer.md` 기준으로만 한다.
- 문서에 없는 변경이거나 애매하면 manager에게 escalation하고, 그 범위 안에서 가능한 read/local fallback으로 계속 진행한다.

## 종료

- manager가 현재 랄프 종료 정책을 만족했다고 판단할 때만 완료로 본다.
