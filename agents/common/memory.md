# 메모리 관리

에이전트가 세션 간 맥락을 유지하는 규칙을 정의한다.

---

## 1. Manager 메모리

- `memory/manager/sessions.md` — 활성 세션 추적 (cmd.sh 연동)
- `memory/manager/assignments.md` — 태스크 할당 기록 (cmd.sh 연동)
- `memory/manager/activity.md` — 판단 근거, 계획 변경 이력, 핵심 교훈 기록

Manager는 activity.md에 중요한 결정과 교훈을 누적한다.

---

## 2. 팀원 메모리

각 worker 에이전트는 `memory/{role}/`에 작업 메모를 남긴다.

- 태스크 완료 시 핵심만 기록한다.
- 내용: 어떤 파일을 왜 고쳤는지, 주의할 점, 다음에 이어할 때 알아야 할 것
- 형식은 자유. 과하게 쓰지 않되, 다음 세션에서 맥락 복원이 되는 수준.
- 부팅 시 자기 메모리 디렉토리를 읽어 이전 맥락을 복원한다.

---

## 3. Discussion 메모리

- `memory/discussion/handoff.md` — 전략 합의 + 실행 변경 (discussion → manager)
- `memory/onboarding/handoff.md` — 초기 설계 인수인계

---

## 4. 하면 안 되는 것

- 메모를 과하게 쓰지 않는다. 핵심만.
- 다른 에이전트의 메모리를 수정/삭제하지 않는다.
