# 런타임 감사

- **대상 행동**: "live 시스템의 실제 구조와 동작 경로를 검증" (#1), "서버/클라우드/네트워크/프로세스 문제 분석" (#3)

---

## 1. 기본 원칙

- repo보다 **현재 실행 중인 시스템**을 먼저 확인한다.
- 설명은 추정이 아니라 증거 기반으로 작성한다.
- `prod`, `staging`, `dev`, `legacy`를 섞어 말하지 않는다.
- 검증한 운영 사실은 머릿속에만 두지 말고 `memory/systems-engineer/`의 표준 문서 세트에 남긴다.
- 문서에는 `마지막 검증 시각`, `검증 환경`, `검증 방식`을 남긴다.
- secret 값은 저장하지 않고 이름, 경로, 역할, 구조만 기록한다.

---

## 2. 점검 순서

1. 진입점 확인
   - 도메인, DNS, CDN/LB, 인증서, ingress를 확인한다.
2. 컴퓨트 확인
   - EC2, container, systemd, process manager, Lambda, queue consumer를 확인한다.
3. 애플리케이션 확인
   - 실제 프로세스, 포트, 엔트리포인트, 환경 파일, 응답 경로를 확인한다.
4. 저장소/의존성 확인
   - DB, cache, object storage, queue, secret source를 확인한다.
5. live 코드 상태를 확인한다.
   - 배포 경로, 서버 파일 경로, 현재 revision/hash, repo 대응 관계를 확인한다.
6. 관찰 결과를 topology와 data flow로 정리한다.
7. 표준 live 문서 세트를 갱신한다.

---

## 3. 확인 항목

| 계층 | 확인 예시 |
|------|-----------|
| DNS / TLS | Route53, CloudFront, ALB, 인증서, 도메인 라우팅 |
| Compute | EC2, ECS, Lambda, systemd, docker, k8s |
| Runtime | 실행 파일, 프로세스, 포트, health check, 로그 |
| Data | S3, queue, cache, DB, 외부 API |
| Safety | single point of failure, broken target, stale DNS, drift |

---

## 4. 문서화 규칙

### 작성 위치
- 조사 중 메모와 초안은 `workspace/teams/systems-engineer/`에 작성한다.
- 검증이 끝난 운영 사실은 `memory/systems-engineer/`의 고정 파일명으로 승격한다.

### 표준 파일명
- `live-topology.md`
- `deployment-map.md`
- `runtime-inventory.md`
- `live-code-state.md`
- `drift-report.md`
- `runbook.md`
- `change-authority.md`

### 파일별 역할
- `live-topology.md`: 사용자 요청이 실제로 어디로 들어가 어떤 계층을 타는지 설명
- `deployment-map.md`: repo/branch/workflow/artifact/deploy target 연결
- `runtime-inventory.md`: 인스턴스, 서비스 매니저, 프로세스, 포트, 로그, 주요 경로
- `live-code-state.md`: 서버에 실제 올라간 코드의 위치, 현재 revision/hash, repo와의 직접 대응
- `drift-report.md`: aligned/drifted/legacy/broken 판정과 정리 필요 항목
- `runbook.md`: 반복 점검 절차, 재시작 전 확인, 롤백 포인트, 로그 확인 경로
- `change-authority.md`: 실제 수정 가능한 시스템 표면, 허용/금지 범위, 검증 근거

### 기록 규칙
- 각 문서 상단에 최소 아래를 남긴다.
  - 마지막 검증 시각
  - 검증 환경 (`prod`, `staging`, `dev`, `legacy`)
  - 검증 근거 종류 (`AWS API`, `SSH`, `systemd`, `curl`, `config file` 등)
- 서버 코드가 repo와 다르면 전체 복사보다 `경로`, `revision/hash`, `차이 요약`을 남긴다.
- secret, token, `.env` 값은 문서에 저장하지 않는다.

## 5. 최소 산출물

보고서나 문서 세트에는 최소 아래를 포함한다:

- 현재 live 경로: 사용자 → 진입점 → 컴퓨트 → 데이터 계층
- 실제로 살아 있는 것
- 깨져 있거나 잔존한 것
- 아직 검증 못 한 것
- live 코드 경로와 repo 대응 관계
- 변경 시 위험 경계
