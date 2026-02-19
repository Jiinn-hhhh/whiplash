# Whiplash Office Dashboard

도트 그래픽(픽셀 아트) 스타일 오피스 대시보드. 에이전트들의 상태를 한눈에 시각적으로 파악할 수 있다.

## 사전 준비

- Python 3 (macOS 기본 포함)
- jq (`brew install jq`)
- tmux (Whiplash 필수 의존성)

## 실행

```bash
python3 dashboard/server.py --project {project-name}
```

`http://localhost:8420`이 자동으로 열린다.

### 옵션

| 플래그 | 설명 | 기본값 |
|--------|------|--------|
| `--project` | 프로젝트 이름 (필수) | - |
| `--port` | 포트 번호 | 8420 |
| `--no-open` | 브라우저 자동 열기 비활성화 | false |

## 상태 표시

| 상태 | 캐릭터 | 말풍선 | 상태점 | 모니터 |
|------|--------|--------|--------|--------|
| working | 타이핑 애니메이션 | 태스크명 | 초록 | 화면 켜짐 |
| idle | 서있음 | "대기중..." | 노랑 | 화면 어둡게 |
| sleeping | 책상에 엎드림 | "zzZ" | 흰색 | 꺼짐 |
| crashed | 스파크 파티클 | "ERROR!" (빨간) | 빨강 | 연기 |
| hung | 서있음 + "?" | "응답없음..." | 주황 | 깜빡임 |
| rebooting | 타이핑 | "재부팅중..." | 파랑 점멸 | 로딩 바 |
| offline | 빈 자리 | 없음 | 없음 | 꺼짐 |

편지 아이콘: mailbox에 새 메시지가 있으면 캐릭터 옆에 표시.

## 에이전트 캐릭터

| 역할 | 색상 | 특징 |
|------|------|------|
| Manager | 빨간 넥타이 + 흰 셔츠 | 넥타이 |
| Researcher | 파란 코트 | 안경 |
| Developer | 초록 후디 | 헤드폰 |
| Monitoring | 노란 조끼 | - |

## API

```bash
# 상태 JSON 직접 조회
curl http://localhost:8420/api/status?project={project-name}
```

## 아키텍처

```
Browser (HTML5 Canvas, 640x480)
  │  3초마다 GET /api/status
  ▼
Python HTTP Server (stdlib만, 의존성 0)
  │  subprocess 호출
  ▼
status-collector.sh (bash + jq)
  │  읽기 전용
  ▼
Whiplash 런타임 데이터 (projects/{name}/...)
```

## 파일 구성

| 파일 | 역할 |
|------|------|
| `server.py` | HTTP 서버 (Python stdlib only) |
| `status-collector.sh` | 데이터 수집 → JSON |
| `index.html` | Canvas + 폴링 |
| `sprites.js` | 픽셀 아트 스프라이트 정의 |
| `office.js` | 오피스 레이아웃 + 렌더링 엔진 |

기존 `agents/` 파일 수정 없음. 완전 독립 모듈.
