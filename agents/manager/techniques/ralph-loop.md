# Ralph Loop

- **대상 행동**: "ralph 프로젝트 운영", "승인 대기 없는 재계획", "끝날 때까지 계속 굴리기"

---

## 핵심 규칙

- project.md의 `작업 루프`, `랄프 완료 기준`, `랄프 종료 방식`을 먼저 확인한다.
- `ralph`에서는 user 승인 대기 때문에 루프를 멈추지 않는다.
- blocker, scope 축소, 최종 완료는 `bash scripts/user-notify.sh {project} ...` 로 알린다.
- user나 discussion이 새 방향을 주면 전체를 pause하지 말고 해당 레인만 재계획한다.
- active task를 새 태스크로 갈아끼울 때는 기존 태스크를 completed로 보지 않고 `superseded`로 취급한다.

## 종료 규칙

### stop-on-criteria

- project.md의 `랄프 완료 기준`을 만족했다고 판단하면 종료한다.

### continue-until-no-improvement

- 먼저 `랄프 완료 기준`을 만족해야 한다.
- 그 뒤에도 개선 loop를 계속 돌린다.
- `3회 연속 no-gain pass`가 쌓일 때만 종료를 검토한다.

no-gain pass 기준:
- 개선 아이디어를 명시했다.
- 실제 변경 또는 검증을 수행했다.
- 결과가 material gain으로 채택되지 않았다.
- 회귀 또는 유의미한 개선 부재가 근거와 함께 남았다.

## 알림 시점

- 치명 블로커를 만나서 우회/축소가 필요할 때
- scope를 줄여 live target을 바꿀 때
- 최종 결과를 확정할 때
