# Whiplash

AI 에이전트들이 팀으로 협업하는 환경을 정의하는 프레임워크.

코드가 아니라 **마크다운 문서**로 구성되어 있다. 역할 정의, 업무 절차, 소통 규칙, 지식 관리 방식을 구조화된 문서로 만들어두면, AI 에이전트가 이를 읽고 따르며 자율적으로 일한다.

---

## 핵심 아이디어

- 에이전트를 잘 쓰는 것은 **프롬프트 엔지니어링이 아니라 환경 엔지니어링**이다.
- 같은 모델이라도 harness(구조) 설계에 따라 결과가 2배 이상 차이난다.
- "더 잘 해"가 아니라 **"이 구조 안에서 해"**라고 제약을 주는 것이 핵심.

---

## 조직 구조

```
유저 — 가끔 개입. 진짜 중요한 것만.
 ↕
Manager — 유저 ↔ 팀 허브. 지시 분배, 조율, 보고.
 ├── Researcher (리서치팀장) ── 서브에이전트들
 ├── Developer (개발팀장) ── 서브에이전트들
 └── (필요 시 확장)
```

---

## 프로젝트 구조 — 4-Folder 분리

```
whiplash/
├── agents/                      # 프레임워크 정의 (immutable, git tracked)
│   ├── common/                  #   공통 규칙
│   ├── manager/                 #   Manager 에이전트
│   │   ├── profile.md           #     역할 정의
│   │   ├── techniques/          #     업무 방법론
│   │   └── tools/               #     자동화 코드
│   ├── researcher/              #   Researcher 에이전트
│   │   ├── profile.md
│   │   ├── techniques/
│   │   └── tools/
│   └── developer/               #   Developer 에이전트
│       ├── profile.md
│       ├── techniques/
│       └── tools/
│
├── workspace/                   # 런타임 작업 공간 (mutable, gitignored)
│   ├── shared/                  #   팀 간 토론, 회의, 공지
│   └── teams/                   #   팀별 내부 작업 공간
│
├── memory/                      # 축적된 상태 (mutable, gitignored)
│   ├── {role}/                  #   에이전트 개인 메모
│   └── knowledge/               #   공유 지식
│       ├── lessons/             #     활성 교훈 (최대 30개)
│       ├── docs/                #     레퍼런스 문서
│       ├── archives/            #     순환된 교훈
│       └── index.md             #     지식 지도
│
└── reports/                     # 사용자 열람용 문서 (mutable, gitignored)
```

### 분리 근거

| 폴더 | 성격 | 누가 보는가 | Git |
|------|------|-------------|-----|
| `agents/` | 프레임워크 정의 (불변) | 에이전트 + 설계자 | tracked |
| `workspace/` | 진행 중인 작업 (휘발) | 에이전트끼리 | ignored |
| `memory/` | 축적된 지식 + 기억 (누적) | 에이전트 | ignored |
| `reports/` | 사용자용 문서 (출력) | 사용자 | ignored |

**Git clone하면 `agents/`만 온다.** 나머지는 에이전트가 실행하면서 생성한다.

---

## 세 레이어 분리

각 에이전트는 세 레이어로 분리된다. 상위가 안정적일수록 하위를 독립적으로 개선할 수 있다.

| 레이어 | 내용 | 변경 빈도 |
|--------|------|-----------|
| `profile.md` | 정의 — 역할, 규칙 (무엇을/왜) | 안정적 |
| `techniques/` | 방법론 — 자연어 절차 (어떻게) | 자유롭게 개선 |
| `tools/` | 자동화 — 미리 짜둔 코드/스크립트 (실행) | 필요 시 추가 |

---

## 현재 구현 현황

| 에이전트 | 역할 | profile.md | techniques/ |
|---------|------|:----------:|:-----------:|
| Manager | 유저 ↔ 팀 허브, 작업 분배, 조율 | O | 4개 |
| Researcher | 연구, 분석, 실험, 방향 제안 | O | 6개 |
| Developer | 프로덕션 구현, 인프라, 품질 관리 | O | 5개 |
| 공통 규칙 (common/) | 모든 에이전트가 따르는 규칙 | - | - |

---

## 설계 근거

| 원칙 | 내용 |
|------|------|
| Environment Engineering | 프롬프트보다 레포 구조, 파일 컨벤션이 더 큰 레버리지 |
| 4-Folder 분리 | Immutable(정의)과 mutable(런타임)을 폴더 레벨에서 완전히 분리 |
| 컨텍스트 최소화 | 지도를 줘라, 백과사전을 주지 마라. index ~100줄, 교훈 30개 상한 |
| 피드백 루프 | 일회성 지시보다 자동 검증 + 교훈 축적 루프가 더 강력 |
| Citation Enforcement | 교훈 인용 강제로 근거 추적 가능 |
| Harness = 경쟁력 | 모델을 바꾸는 것보다 구조를 바꾸는 것이 더 큰 성능 향상 |
| Fail-safe | 에이전트 실패 시 사람이 대신하지 않고 환경을 개선 |

---

## For Agents

에이전트라면 아래 파일들을 읽어라:

1. `agents/common/README.md` — 공통 규칙, 온보딩 절차
2. `memory/knowledge/index.md` — 지식 지도
3. 자기 에이전트 폴더의 `profile.md` — 역할 정의

상세 절차는 `techniques/`, 자동화 코드는 `tools/`에 있다.
