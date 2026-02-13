# 프로젝트 컨텍스트 컨벤션

이 프레임워크는 여러 프로젝트를 동시에 운영한다. 각 프로젝트는 `projects/{name}/` 안에 workspace, memory, reports를 갖는다.

---

## 1. 경로 해석 규칙

에이전트 문서(profile.md, techniques/, tools/)에서 사용하는 경로는 **현재 프로젝트 기준 상대 경로**다.

| 문서에 적힌 경로 | 실제 물리 경로 |
|------------------|----------------|
| `workspace/shared/` | `projects/{name}/workspace/shared/` |
| `workspace/teams/` | `projects/{name}/workspace/teams/` |
| `memory/knowledge/` | `projects/{name}/memory/knowledge/` |
| `memory/{role}/` | `projects/{name}/memory/{role}/` |
| `reports/` | `projects/{name}/reports/` |

에이전트 정의 파일(`agents/`)과 도메인 파일(`domains/`)의 경로는 레포 루트 기준이다.

---

## 2. 프로젝트 구조

```
projects/{name}/
  project.md               # 프로젝트 정의 (이름, 목표, 도메인)
  workspace/               # 진행 중인 작업
    shared/
      discussions/
      meetings/
      announcements/
    teams/
      research/
      developer/
  memory/                  # 축적된 상태
    manager/
    researcher/
    developer/
    knowledge/
      lessons/
      docs/
      discussions/
      meetings/
      archives/
      index.md
  reports/                 # 사용자용 산출물
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
- **Domain**: {도메인 이름} (예: deep-learning, game-dev, general)
- **Started**: YYYY-MM-DD

## 목표
프로젝트가 달성하려는 것. 1-3문장.

## 배경
왜 이걸 하는지, 어떤 맥락에서 시작됐는지. 2-3문장.

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

## 현재 상태
(에이전트가 업데이트)
```

---

## 4. 프로젝트 전환

에이전트가 다른 프로젝트로 전환할 때:

1. `projects/{name}/project.md`를 읽는다.
2. 도메인이 지정되어 있으면 `domains/{domain}/context.md`를 읽는다.
3. 해당 도메인에 자기 역할 파일이 있으면 (`domains/{domain}/{role}.md`) 읽는다.
4. `projects/{name}/memory/knowledge/index.md`를 읽는다.
5. 이후 workspace/, memory/, reports/ 경로는 해당 프로젝트 기준으로 해석한다.

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
