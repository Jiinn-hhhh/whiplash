# 프로젝트 컨텍스트 컨벤션

이 프레임워크는 여러 프로젝트를 동시에 운영한다. 각 프로젝트는 `projects/{name}/` 안에 workspace, memory, runtime, reports를 갖는다.

---

## 1. 경로 해석 규칙

에이전트 문서(profile.md, techniques/, tools/)에서 사용하는 경로는 **현재 프로젝트 기준 상대 경로**다.

| 문서에 적힌 경로 | 실제 물리 경로 |
|------------------|----------------|
| `workspace/shared/` | `projects/{name}/workspace/shared/` |
| `workspace/teams/` | `projects/{name}/workspace/teams/` |
| `memory/knowledge/` | `projects/{name}/memory/knowledge/` |
| `memory/discussion/` | `projects/{name}/memory/discussion/` |
| `memory/{role}/` | `projects/{name}/memory/{role}/` |
| `runtime/manager-state.tsv` | `projects/{name}/runtime/manager-state.tsv` |
| `runtime/reboot-state.tsv` | `projects/{name}/runtime/reboot-state.tsv` |
| `runtime/idle-state.tsv` | `projects/{name}/runtime/idle-state.tsv` |
| `runtime/message-queue/` | `projects/{name}/runtime/message-queue/` |
| `runtime/message-locks/` | `projects/{name}/runtime/message-locks/` |
| `reports/` | `projects/{name}/reports/` |

에이전트 정의 파일(`agents/`)과 도메인 파일(`domains/`)의 경로는 레포 루트 기준이다.

**프로젝트 폴더**: project.md에 `프로젝트 폴더` 경로가 지정되어 있으면, 모든 코드 작업(파일 생성, 수정, 빌드, 테스트 등)은 해당 경로에서 수행한다. 프레임워크 산출물(workspace/, memory/, reports/)과 코드 작업 경로는 별개다.
기본 규칙상 이 경로의 수정 권한은 Developer와 Systems Engineer에만 있다. 단, 외부 반영은 별도 approval gate를 따른다.

---

## 2. 프로젝트 구조

```
projects/{name}/
  project.md               # 프로젝트 정의 (이름, 목표, 도메인)
  team/                    # 프로젝트 레벨 에이전트 커스터마이징 (선택)
    {role}.md              #   역할별 프로젝트 특화 지침
  workspace/               # 진행 중인 작업
    shared/
      discussions/
      meetings/
      announcements/
    teams/
      research/
      developer/
      systems-engineer/
  memory/                  # 축적된 상태
    discussion/
      decision-notes.md    #   전략 토론 메모 (선택)
      handoff.md           #   manager에게 넘길 실행 변경 handoff (선택)
    manager/
      sessions.md          #   활성 세션 추적
    researcher/
    developer/
    systems-engineer/
    monitoring/
    knowledge/
      lessons/
      docs/
        change-authority.md #   systems-engineer 시스템 수정 가능 표면 / 정책 근거
      discussions/
      meetings/
      archives/
      index.md
  runtime/                 # 시스템 운용용 런타임 상태
    manager-state.tsv      #   monitor pid/heartbeat/lock/nudge key-value 상태
    reboot-state.tsv       #   role -> reboot count / reboot lock / lockout 시각
    idle-state.tsv         #   role -> idle 감지 시각
    message-queue/         #   전달 실패 메시지 보관
    message-locks/         #   target별 직렬화 lock
    manager/               #   runtime 보조 파일
  logs/                    # system.log, message.log
  reports/                 # 사용자 열람 전용 (에이전트는 쓰기만, 읽기 참조 금지)
```

---

## 3. 프로젝트 시작 절차

새 프로젝트를 시작할 때:

1. **온보딩 에이전트**(`agents/onboarding/`)가 유저와 대화하며 프로젝트를 설계한다.
2. 온보딩 에이전트가 `projects/{name}/` 폴더, project.md, 디렉토리 구조를 생성한다.
3. `memory/knowledge/index.md`를 빈 지식 지도로 초기화한다.
4. 설계 확정 후 Manager에게 인계한다.

온보딩 에이전트 없이 수동으로 시작할 수도 있다. 이 경우 아래 양식을 직접 작성한다.

### project.md 양식

```markdown
# Project: {이름}

## 기본 정보
- **Domain** (또는 **도메인**): {도메인 이름} (예: deep-learning, game-dev, general)
- **Started**: YYYY-MM-DD

## 목표
프로젝트가 달성하려는 것. 1-3문장.

## 배경
왜 이걸 하는지, 어떤 맥락에서 시작됐는지. 2-3문장.

## 프로젝트 폴더
- **경로**: {절대 경로 또는 "없음"}
  - 코드 작업이 있는 프로젝트: Developer와 Systems Engineer가 이 경로에서 코드/자동화 작업 수행
  - "없음": 코드 작업 없는 프로젝트 (연구, 문서 등)

## 기존 자원
- **코드**: {레포 경로 또는 "없음"}
- **데이터**: {사용 가능한 데이터, 접근 방식 또는 "없음"}
- **참고 자료**: {논문, 문서, 기존 연구 또는 "없음"}
- **진행 상태**: {이미 된 것 또는 "새로 시작"}

## 제약사항
- **컴퓨팅**: {GPU, 서버, 클라우드 예산 등 또는 "제한 없음"}
- **시간**: {마감, 예상 기간 또는 "제한 없음"}
- **데이터**: {데이터 제한, 라이선스 또는 "제한 없음"}
- **기술**: {언어, 프레임워크, 호환성 또는 "제한 없음"}
- **기타**: {예산, 규제, 기타 또는 "없음"}

## 성공 기준
구체적 조건. 가능하면 정량적으로.

## 운영 방식
- **실행 모드**: {solo | dual}
- **control-plane 백엔드**: {codex | claude}
- **작업 루프**: {guided | ralph}
- **랄프 완료 기준**: {유저가 적은 완료 기준 또는 "해당 없음"}
- **랄프 종료 방식**: {stop-on-criteria | continue-until-no-improvement 또는 "해당 없음"}
- **보고 빈도**: {매일 / 마일스톤마다 / 요청 시 등}
- **보고 채널**: {reports/ 파일 / Slack / 이메일 / 대화 내 등}
- Slack을 쓰는 프로젝트면 `bash scripts/slack.sh {project} "제목" "내용" [level]`로 webhook 전송 가능
- **자율 범위**: {팀이 알아서 진행할 수 있는 범위 / 유저 확인이 필요한 것}
- **긴급 알림**: {블로커 발생 시 즉시 / 모아서 보고}
- **프레임워크 디버깅**: {on | off} (에이전트가 프레임워크 비효율을 feedback/insights.md에 기록할지 여부)
- **기술적 전제조건**: {운영 방식 실현에 필요한 인프라, 설정 등 또는 "없음"}
- **시스템 변경 권한**: {기본 금지 / systems-engineer 비활성 / team/systems-engineer.md + memory/knowledge/docs/change-authority.md 참조}
- `작업 루프 = ralph`면 manager는 user 승인 입력을 기다리며 멈추지 않는다. 대신 blocker / scope 축소 / 최종 완료를 알림 채널에 남기고 계속 진행한다.
- `랄프 종료 방식 = continue-until-no-improvement`이면 완료 기준 충족 후에도 개선 loop를 이어가며, 팀이 보수적으로 "더 이상 의미 있는 개선이 어렵다"고 판단할 때만 종료한다.
- 기본값은 `codex`다. onboarding이 유저와 합의해 `claude`로 바꿀 수 있다.

## 팀 구성
- **활성 에이전트**: {이 프로젝트에 참여하는 에이전트 목록}
  - `manager`, `discussion`은 control-plane 역할이라 명시하지 않아도 부팅 흐름에서 자동 포함된다.
  - `systems-engineer` 포함 여부는 온보딩 중 유저 확인을 거쳐 결정
  - 확인 질문 예시: "이 프로젝트에서 서버, 클라우드, 배포, runtime 작업이 얼마나 중요한가? 거의 없음 / 일부 있음 / 핵심임"
  - 기본 기준: `핵심임`이면 포함 권장, `일부 있음`이면 포함 추천, `거의 없음`이면 제외 가능
  - `systems-engineer`를 포함하면 `team/systems-engineer.md`와 `memory/knowledge/docs/change-authority.md`를 함께 초안 작성
- **커스터마이징**: {있으면 team/{role}.md 참조, 없으면 "기본"}

## 현재 상태
(에이전트가 업데이트)
```

---

## 4. 프로젝트 전환

에이전트가 다른 프로젝트로 전환할 때:

1. `projects/{name}/project.md`를 읽는다.
2. 도메인이 `general`이 아니고 파일이 있으면 `domains/{domain}/context.md`를 읽는다.
3. 해당 도메인이 `general`이 아니고 자기 역할 파일이 있으면 (`domains/{domain}/{role}.md`) 읽는다.
4. 해당 프로젝트에 자기 역할 파일이 있으면 (`projects/{name}/team/{role}.md`) 읽는다.
5. `systems-engineer`라면 `projects/{name}/memory/knowledge/docs/change-authority.md`를 읽는다. 원격 시스템 변경 전에는 다시 확인한다.
6. `projects/{name}/memory/knowledge/index.md`를 읽는다.
7. 이후 workspace/, memory/, reports/ 경로는 해당 프로젝트 기준으로 해석한다.

---

## 5. 크로스 프로젝트 참조

다른 프로젝트의 지식을 참조할 때:

- 명시적 전체 경로를 사용한다: `projects/{other-project}/memory/knowledge/lessons/LESSON-NNN.md`
- 크로스 프로젝트 인용 시 프로젝트명을 함께 표기한다: `Cite LESSON-NNN (project: {name})`
- 다른 프로젝트의 workspace/는 참조하지 않는다 (진행 중인 작업은 해당 프로젝트에 종속).

---

## 6. 도메인 연동

프로젝트의 도메인이 `general`이 아닌 경우:

1. `domains/{domain}/context.md` — 모든 에이전트가 읽는 도메인 배경
2. `domains/{domain}/{role}.md` — 해당 역할 에이전트만 읽는 추가 지침 (있는 경우)

도메인 파일은 기본 규칙을 **보충**한다. 교체하지 않는다.

---

## 7. 프로젝트 레벨 팀 커스터마이징

같은 도메인이라도 프로젝트마다 에이전트에게 다른 초점/우선순위를 줄 수 있다.

### 3-Layer 보충 체인

```
agents/{role}/profile.md          ← 기본 (프레임워크, 불변)
  ↓ 보충
domains/{domain}/{role}.md        ← 도메인 특화 (프레임워크, 불변)
  ↓ 보충
projects/{name}/team/{role}.md    ← 프로젝트 특화 (프로젝트, 가변)
```

- 각 레이어는 이전 레이어를 **보충**한다. 교체하지 않는다.
- 프로젝트 레벨 파일은 선택. 없으면 기본 + 도메인만으로 작동한다.

### team/{role}.md 양식

```markdown
# {프로젝트명} — {역할} 프로젝트 지침

이 파일은 `agents/{role}/profile.md`와 `domains/{domain}/{role}.md`를 **보충**한다.

## 이 프로젝트에서의 초점
(이 프로젝트에서 특별히 강조할 것)

## 이 프로젝트에서의 제한
(이 프로젝트에서 특별히 피할 것)
```

`role`이 `systems-engineer`인 경우에는 아래 섹션을 추가한다.

```markdown
## 시스템 변경 권한
- 기본값: 명시되지 않은 원격 시스템 write는 금지
- 판단 순서:
  1. 이 표의 환경별 정책 확인
  2. `memory/knowledge/docs/change-authority.md`의 실제 표면/근거 확인
  3. 두 문서가 모두 허용할 때만 실행

| 환경 | read | config-change | deploy | service-restart | data-change |
|------|------|---------------|--------|-----------------|-------------|
| prod | {허용/금지} | {허용/금지} | {허용/금지} | {허용/금지} | {허용/금지} |
| staging | {허용/금지} | {허용/금지} | {허용/금지} | {허용/금지} | {허용/금지} |
| dev | {허용/금지} | {허용/금지} | {허용/금지} | {허용/금지} | {허용/금지} |
```

### change-authority.md 양식

```markdown
# 시스템 변경 권한 근거

- **마지막 검증 시각**: YYYY-MM-DD HH:MM TZ
- **검증 환경**: prod | staging | dev
- **검증 근거 종류**: AWS API | SSH | systemd | config file | ...

## 목적
- 실제로 수정 가능한 시스템 표면과 근거를 기록한다.
- 문서에 없는 원격 시스템 write는 금지다.

## 표면 목록
| 환경 | 표면 | 허용 행동 | 금지 행동 | 근거 | 마지막 확인 |
|------|------|-----------|-----------|------|-------------|
```

### 작성 규칙

- **온보딩 에이전트가 생성**한다. 유저와의 대화에서 프로젝트별 에이전트 커스터마이징을 도출한 결과물이다.
- **Manager가 수정 가능**하다. 프로젝트 진행 중 필요 시 유저 합의 하에 업데이트한다.
- 기본 profile.md나 도메인 파일의 규칙을 **무효화하지 않는다**. 초점과 우선순위를 조정할 뿐이다.
- project.md의 `팀 구성` 섹션에 개요를 기록하고, 상세는 `team/{role}.md`에 둔다.
- `systems-engineer`가 활성인 프로젝트라면 `team/systems-engineer.md`와 `memory/knowledge/docs/change-authority.md`를 함께 관리한다.
