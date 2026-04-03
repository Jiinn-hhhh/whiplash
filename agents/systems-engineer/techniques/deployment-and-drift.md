# 배포 경로 및 드리프트 분석

- **대상 행동**: "배포 경로, 아티팩트, 런타임 드리프트 추적" (#2), "운영 사실 공유" (#6)

---

## 1. 드리프트 정의

아래 셋이 서로 다르면 드리프트로 본다.

- repo 상태
- 배포 아티팩트/CI 산출물
- live runtime 상태

---

## 2. 분석 절차

1. 현재 배포 진입 경로를 찾는다.
   - CI/CD, artifact store, deploy script, remote bootstrap 순으로 추적한다.
2. live runtime의 실제 파일/프로세스/설정을 확인한다.
3. 로컬 repo와 파일 내용, 브랜치, 커밋, 빌드 결과를 비교한다.
4. 차이를 아래 네 가지로 분류한다.

| 분류 | 의미 |
|------|------|
| aligned | repo / artifact / runtime이 일치 |
| drifted | runtime만 달라짐 |
| legacy | 더 이상 활성은 아니지만 남아 있음 |
| broken | 구성은 남아 있으나 실제 서비스 불가 |

---

## 3. 중요 포인트

- Git HEAD만 보고 live 여부를 판단하지 않는다.
- 환경변수, dotfile, 설치 패키지, 이미지 태그, 원격 스크립트는 별도로 본다.
- staging이 prod와 같은 대상을 보는지 항상 번들/설정으로 검증한다.

---

## 4. 보고 방식

보고서는 다음 순서로 쓴다:

1. 실제 배포 방식
2. live인 것
3. live가 아닌 잔존물
4. repo와 runtime의 직접 대응 관계
5. 위험한 드리프트와 정리 필요 항목

표준 문서 반영:

- `memory/systems-engineer/deployment-map.md`에 실제 배포 경로를 유지한다.
- `memory/systems-engineer/live-code-state.md`에 서버 코드 경로와 revision/hash를 유지한다.
- `memory/systems-engineer/drift-report.md`에 aligned/drifted/legacy/broken 판정을 유지한다.

문서화할 때는 아래를 같이 남긴다:

- 마지막 검증 시각
- 어떤 환경(`prod`, `staging`, `dev`, `legacy`)을 본 것인지
- repo/artifact/runtime 중 어디까지 직접 확인했고 어디가 추정인지
