# Ralph Loop

## 목적

Whiplash에 `ralph` 작업 루프를 추가한다. 이 루프의 핵심은 `user 승인 대기 없이 팀이 계속 움직인다`는 것이다.

---

## 설계 요약

- backend 실행 모드(`solo | dual`)와 별도로 작업 루프(`guided | ralph`)를 둔다.
- `ralph`는 onboarding에서 선택한다.
- `ralph`를 고르면 user가 직접:
  - `랄프 완료 기준`
  - `랄프 종료 방식`
  를 정한다.

## 종료 방식

### stop-on-criteria

- user가 적은 완료 기준을 만족하면 종료한다.

### continue-until-no-improvement

- 완료 기준을 만족한 뒤에도 개선을 계속한다.
- `3회 연속 no-gain pass`가 쌓였을 때만 종료를 검토한다.

## user 개입

- user는 언제든 `manager`, `discussion`에 개입할 수 있다.
- 이 입력은 global pause 신호가 아니다.
- manager가 async update로 흡수하고, 필요한 태스크만 재계획한다.

## user 알림

다음은 알리되 멈추지 않는다.

- blocker
- scope 축소
- 최종 완료

자동 알림은 `scripts/user-notify.sh`를 사용한다.
