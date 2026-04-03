# 프레임워크 개선 인사이트

| # | 날짜 | 발견자 | 카테고리 | 상태 | 요약 |
|---|------|--------|---------|------|------|
| 1 | 2026-03-23 | manager | 양식 | resolved | `agents/manager/techniques/orchestration.md`는 자동 reboot 한도를 3회로 적지만 실제 `scripts/monitor.sh`는 5회 기준으로 동작한다 — Cycle 1에서 monitor.sh MAX_REBOOT=3으로 통일 |
| 2 | 2026-03-23 | manager | 소통 | resolved | 오케스트레이터가 developer-claude와 systems-engineer가 재부팅 실패 상태인데도 `팀 부팅 완료`를 전송했다 — Cycle 1에서 부팅 완료 검증 강화 |
