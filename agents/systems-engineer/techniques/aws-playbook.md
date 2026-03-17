# AWS 우선 플레이북

- **대상 행동**: "클라우드/런타임 문제 분석" (#3), "운영 사실 공유" (#6)

---

## 1. 우선 확인 순서

1. Route53 / DNS
2. CloudFront / CDN
3. ALB / target group / health check
4. Compute
   - EC2
   - ECS / EKS
   - Lambda
5. Data plane
   - S3
   - SQS / SNS
   - cache
   - DB
6. 배포 흔적
   - GitHub Actions / artifact bucket / SSM / startup script

---

## 2. 대표 확인 질문

- 이 도메인은 실제로 어디를 가리키는가?
- CloudFront/ALB 뒤의 실제 target은 살아 있는가?
- systemd/docker/Lambda 중 실제 실행 주체는 무엇인가?
- 현재 live 코드와 로컬 repo는 같은가?
- staging은 prod와 같은 대상을 보는가?
- 남아 있는 DNS, ALB, bucket, queue 중 legacy/broken은 무엇인가?

---

## 3. 자주 드러나는 리스크

- target group health check path 오류
- DNS는 남았는데 뒤 리소스가 삭제됨
- artifact는 최신인데 runtime만 오래됨
- runtime은 최신인데 Git metadata가 오래됨
- staging frontend만 남고 backend는 사라짐
- GPU/Lambda 경로가 남았지만 target이 비어 있음

---

## 4. 보고서 기준

AWS 관련 보고서는 아래 형태를 우선한다.

- 실제 사용자 요청 흐름
- 실제 운영 리소스
- 깨진 경로 / 잔존 리소스
- 배포 방식
- 드리프트 / 리스크
