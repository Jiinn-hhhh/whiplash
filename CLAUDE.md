# Whiplash Framework Guide

## 즉시 행동 지시 (Claude Code 세션 시작 시)

너는 Whiplash 프레임워크의 **Onboarding 에이전트**다.

### 첫 번째 행동
1. `projects/` 디렉토리를 확인한다.
2. 기존 프로젝트가 있으면 목록을 보여주며 물어본다:
   "기존 프로젝트를 이어할까, 새 프로젝트를 시작할까?"
3. 기존 프로젝트가 없으면 새 프로젝트 온보딩을 시작한다.

### 역할 활성화
- Onboarding 절차 상세: `agents/onboarding/techniques/project-design.md`
- 역할 정의: `agents/onboarding/profile.md`
- 유저가 명시적으로 다른 에이전트 역할을 지정하면: `agents/{role}/profile.md` 읽고 전환

## 프레임워크 개요

**Whiplash** — AI 에이전트 팀 거버넌스 프레임워크 (한국어). 마크다운 문서로 역할, 절차, 소통 규칙을 정의하면 에이전트가 자율 협업한다.

- **에이전트**: Onboarding → Manager → Developer, Researcher, Monitoring
- **구조**: `agents/`(정의, immutable) + `domains/`(도메인, immutable) + `projects/`(런타임, gitignored)
- **각 에이전트**: `profile.md`(역할) + `techniques/`(방법론) + `tools/`(자동화)
- **실행 모드**: solo(tmux 단일 백엔드) / dual(Claude Code + Codex 이중 실행)
- **소통**: mailbox(실시간 알림) + 토론/회의/공지(구조화 문서)

상세 아키텍처: `agents/common/README.md`

### Directory Structure

```
whiplash/
├── agents/                      # Framework definitions (git tracked)
│   ├── common/                  #   Shared rules
│   │   ├── README.md            #     Common rules + onboarding
│   │   ├── project-context.md   #     Project context convention (path resolution, project lifecycle)
│   │   ├── agent-spec.md        #     New agent definition template
│   │   ├── communication.md     #     Communication rules, shared space structure
│   │   ├── formats.md           #     Document templates (Lesson, Discussion, Meeting, Report)
│   │   └── memory.md            #     Knowledge management, lesson lifecycle
│   ├── onboarding/
│   │   ├── profile.md
│   │   └── techniques/ (1)
│   ├── manager/
│   │   ├── profile.md
│   │   ├── techniques/ (6)
│   │   └── tools/
│   ├── researcher/
│   │   ├── profile.md
│   │   ├── techniques/ (6)
│   │   └── tools/
│   ├── developer/
│   │   ├── profile.md
│   │   ├── techniques/ (5)
│   │   └── tools/
│   └── monitoring/
│       ├── profile.md
│       └── techniques/ (2)
│
├── domains/                     # Domain-specific definitions (git tracked)
│   ├── README.md                #   Domain system explanation
│   └── deep-learning/           #   Example domain
│       ├── context.md           #     Domain background, terminology, principles
│       ├── researcher.md        #     Researcher domain-specific guidelines
│       ├── developer.md         #     Developer domain-specific guidelines
│       └── monitoring.md        #     Monitoring domain-specific guidelines
│
├── feedback/                    # Framework improvement insights (independent module)
│   ├── guide.md                 #   Recording rules
│   └── insights.md              #   Accumulated insights
│
└── projects/                    # Per-project runtime data (gitignored)
    └── {project-name}/
        ├── project.md           #   Project definition (name, goal, domain)
        ├── team/                #   Project-level agent customization (optional)
        │   └── {role}.md        #     Role-specific project guidelines
        ├── workspace/           #   Active work in progress
        │   ├── shared/          #     Cross-team discussions, meetings, announcements
        │   │   └── mailbox/     #     Real-time agent notifications (Maildir pattern)
        │   └── teams/           #     Team-internal workspaces
        ├── memory/              #   Accumulated state
        │   ├── {role}/          #     Agent personal notes
        │   └── knowledge/       #     Shared knowledge
        │       ├── lessons/     #       Active lessons (max 30, LESSON-NNN.md)
        │       ├── docs/        #       Reference documents
        │       ├── discussions/ #       Closed discussion originals
        │       ├── meetings/    #       Closed meeting originals
        │       ├── archives/    #       Cycled-out lessons
        │       └── index.md     #       Knowledge map (~100 lines)
        └── reports/             #   User-facing documents
```

### Multi-Project Support

One framework runs multiple projects simultaneously. Each project gets isolated workspace, memory, and reports under `projects/{name}/`.

- Paths like `workspace/`, `memory/`, `reports/` in agent documents are **relative to the current project** (resolved to `projects/{name}/workspace/`, etc.)
- Each project has a `project.md` defining its name, goal, and domain
- Cross-project references use explicit full paths: `projects/{other}/memory/knowledge/...`
- See `agents/common/project-context.md` for full convention

### Domain Specialization

Projects can specify a domain for additional context:

- `domains/{domain}/context.md` — domain background read by all agents
- `domains/{domain}/{role}.md` — role-specific domain guidelines (optional)
- Domains **supplement** base rules. They never replace them.
- Projects without a domain default to `general` (no extra files needed)
- See `domains/README.md` for details

### Project-Level Team Customization

Even within the same domain, each project can give agents different focus/priorities:

- `projects/{name}/team/{role}.md` — project-specific agent guidelines (optional)
- 3-layer supplement chain: `agents/{role}/profile.md` → `domains/{domain}/{role}.md` → `team/{role}.md`
- Each layer **supplements** the previous. Never replaces.
- Created by Onboarding agent, updatable by Manager with user consent.
- See `agents/common/project-context.md` §7 for details

### Multi-Agent Orchestration

Two execution modes (configured per-project in project.md):

**Solo mode** (tmux-based):
- Each agent runs in its own tmux window within session `whiplash-{project}`
- Manager and all sub-agents use the same backend (Claude Code or Codex)
- Agents communicate via mailbox (Maildir pattern: tmp/ → new/ → deliver → delete)
- monitor.sh polls mailboxes and delivers notifications via tmux send-keys
- Key tools: `orchestrator.sh`, `monitor.sh`, `mailbox.sh`

**Dual mode** (tmux-based):
- Same task runs on two backends (Claude Code + Codex) simultaneously
- Manager coordinates consensus between both results
- Monitoring runs solo (no dual needed)
- Key tools: same as solo + `dual-dispatch`

See `agents/manager/techniques/orchestration.md`

**Note**: Claude Code agents can optionally use Agent Teams (TeamCreate, Task, SendMessage) internally within their tmux sessions.

## Key Conventions

- **Language**: All framework documents are written in Korean.
- **Append-only**: Never edit another agent's text. Corrections go in new sections.
- **Citation enforcement**: Reference prior lessons as `Cite LESSON-NNN`. Never use lesson content without citation.
- **Reasoning obligation**: Every decision and artifact must include explicit rationale.
- **Context minimization**: `memory/knowledge/index.md` stays under ~100 lines. Active lessons capped at 30. Deep reads are on-demand.
- **No prototype-to-production shortcuts**: Researcher prototypes must be re-architected by Developer before production.
- **Document IDs**: `LESSON-NNN`, `DISC-NNN`, `MEET-NNN`, `ADR-NNN` (3-digit sequential).
- **Project-relative paths**: `workspace/`, `memory/`, `reports/` in agent docs resolve to current project's directories.

## Agent Onboarding Sequence

1. Read `agents/common/README.md` — common rules
2. Read `agents/common/project-context.md` — project convention
3. Read your agent's `profile.md` — role definition
4. Read `projects/{name}/project.md` — current project
5. Read `domains/{domain}/context.md` — domain background
6. (If exists) Read `domains/{domain}/{role}.md` — domain-specific guidelines
7. (If exists) Read `team/{role}.md` — project-specific guidelines
8. Read `memory/knowledge/index.md` — project knowledge map

## Adding a New Agent

1. Follow `agents/common/agent-spec.md` template
2. Create `agents/{role}/profile.md`
3. Add procedures in `agents/{role}/techniques/*.md`
4. Add automation code in `agents/{role}/tools/` as needed
5. Agent's personal memory goes in `projects/{name}/memory/{role}/` (created at runtime)

## Adding a New Domain

1. Create `domains/{domain-name}/` folder
2. Write `context.md` — domain background, concepts, terminology, quality criteria
3. (Optional) Write `{role}.md` — role-specific domain guidelines
4. Set domain in project's `project.md`

## Validation Commands

No build/test pipeline. Use these checks:

```bash
rg --files agents domains       # list managed docs
git status --short              # confirm staged files
git log --oneline -n 10         # check commit style
```

## Style Conventions

- **Language**: Korean for all framework documents
- **Filenames**: kebab-case for techniques (e.g., `knowledge-management.md`)
- **Paths**: exact patterns — `agents/{role}/...`, `domains/{domain}/...`
- **Commits**: imperative verb start (`Add`, `Refactor`, `Update`), one logical change per commit
- **Pull Requests**: include a concise summary of changed paths and rationale, link related issues/tasks, note cross-file consistency updates (especially `agents/common/` impacts)
- **Security**: respect `.gitignore` (`projects/*` is runtime state), avoid embedding secrets or project-specific private data in framework docs
