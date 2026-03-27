# Discussion Handoff 작성법

`memory/discussion/handoff.md`는 Discussion이 Manager에게 넘기는 실행 변경 문서다. 목적은 긴 유저 대화를 "바로 실행 가능한 짧은 변경 계약"으로 압축하는 것이다.

---

## 1. 언제 handoff를 만든다

아래 조건일 때만 만든다.

- 유저와 방향 합의가 끝났다.
- Manager가 계획, 우선순위, 태스크 분배 중 하나 이상을 바꿔야 한다.
- 변경 이유와 영향 범위를 짧게 설명할 수 있다.

아래 경우에는 만들지 않는다.

- 아직 장단점 비교 중이다.
- 유저가 보류했다.
- 단순한 아이디어 메모다.
- 현재 상태 질문만 오갔다.

---

## 2. 작성 원칙

- 길게 쓰지 않는다. Manager가 바로 읽고 실행에 반영할 수 있어야 한다.
- `유저 합의 완료`와 `추가 확인 필요`를 섞지 않는다.
- 실행 변경을 중심으로 담되, 배경 합의사항도 Notes 섹션에 간략히 기록한다.
- 애매한 표현 대신 바뀌는 항목을 명시한다.
- Whiplash는 handoff 알림 시 아래 최소 계약을 검사한다. 형식이 맞지 않으면 Manager에게 handoff 준비 알림이 전달되지 않는다.

좋은 예:
- "Developer 우선순위를 A에서 B로 변경"
- "Systems Engineer 투입을 이번 스프린트에서는 보류"
- "Dual 모드는 유지하되 Discussion은 solo로 고정"

나쁜 예:
- "전체적으로 방향을 좀 바꿔보자"
- "대충 더 좋은 구조로 정리"

---

## 3. 템플릿

```markdown
# Discussion Handoff

- **Date**: YYYY-MM-DD HH:MM
- **Author**: discussion
- **User approved**: yes

## Why this change
- 왜 실행 변경이 필요한지 2-4줄
- 유저가 무엇에 동의했는지

## Scope impact
- 영향을 받는 역할 / 태스크 / 우선순위
- 지금 바로 바뀌는 것과 보류하는 것

## Manager next action
- Manager가 바로 해야 할 다음 행동 1-3개
- 필요하면 중단/추가/재분배할 태스크

## Notes
- 선택. 추가 맥락이나 열린 질문
- 없으면 생략 가능
```

---

## 4. Manager 통지

handoff 작성 후 아래 형식으로 Manager에게 알린다.

```bash
bash scripts/message.sh {project} discussion manager status_update normal \
  "discussion handoff 준비" \
  "memory/discussion/handoff.md를 읽고 실행 계획에 반영해라"
```

핵심은 알림 자체보다 문서다. Manager는 대화 로그가 아니라 `handoff.md`를 source로 삼아야 한다.

---

## 5. Manager가 기대하는 품질

Manager가 handoff를 읽고 아래 질문에 바로 답할 수 있어야 한다.

- 무엇이 바뀌었나?
- 왜 바뀌었나?
- 누가 영향을 받나?
- 지금 바로 어떤 실행 변경을 해야 하나?

이 네 가지가 보이지 않으면 handoff 품질이 부족한 것이다.
