# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repository Is

**Whiplash** — a multi-agent team governance framework (in Korean) that defines how three specialized AI agent roles — Manager, Developer, Researcher — collaborate across multiple projects with domain specialization. This is a documentation-first project: no build system, no package manager, no traditional code. All rules, procedures, and communication happen through structured Markdown files.

## Architecture

### Agent Hierarchy

```
User
  ↓
Onboarding (project designer — runs before Manager, designs new projects)
  ↓
Manager (hub — orchestrates agent instances via claude -p)
  ├→ Developer (개발팀 team lead — builds production systems)
  ├→ Researcher (리서치팀 team lead — researches and proposes)
  └→ Monitoring (독립 관찰자 — infra/environment health)
```

- **Onboarding**: Discusses with user to design new projects. Creates project.md and directory structure. Hands off to Manager when done.
- **Manager**: Decomposes user goals into team tasks, coordinates across teams, escalates strategic decisions to user. Never does hands-on work.
- **Developer**: Implements production code, designs architecture, builds infra for Researcher experiments. Reports to Manager.
- **Researcher**: Collects/analyzes sources, runs experiments (prototype-level only), proposes directions. Reports to Manager.

### 3-Folder Separation

| Folder | Nature | Git |
|--------|--------|-----|
| `agents/` | Framework definitions (immutable) | tracked |
| `domains/` | Domain-specific definitions (immutable) | tracked |
| `projects/` | Per-project runtime data (mutable) | ignored |

Git clone gives you `agents/` + `domains/`. Project data is created at runtime.

### Three-Layer Separation (per agent)

Each agent folder (`manager/`, `developer/`, `researcher/`) follows:

| Layer | Purpose | Change frequency |
|-------|---------|-----------------|
| `profile.md` | **What/Why** — role definition, rules, constraints | Stable |
| `techniques/` | **How** — natural language procedures | Freely improvable |
| `tools/` | **Execution** — pre-built automation code, scripts, configs | Added as needed |

Upper layers remain stable while lower layers evolve independently.

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
│   │   ├── techniques/ (4)
│   │   └── tools/
│   ├── researcher/
│   │   ├── profile.md
│   │   ├── techniques/ (6)
│   │   └── tools/
│   └── developer/
│       ├── profile.md
│       ├── techniques/ (5)
│       └── tools/
│
├── domains/                     # Domain-specific definitions (git tracked)
│   ├── README.md                #   Domain system explanation
│   └── deep-learning/           #   Example domain
│       ├── context.md           #     Domain background, terminology, principles
│       └── researcher.md        #     Researcher domain-specific guidelines
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

Manager runs agents via tmux + mailbox for async orchestration:
- Each agent runs in its own tmux window within session `whiplash-{project}`
- Agents communicate status via mailbox (Maildir pattern: tmp/ → new/ → cur/)
- monitor.sh polls mailboxes and delivers notifications via tmux send-keys
- Users can observe any agent live via `tmux attach -t whiplash-{project}`

Modes (configured per-project in project.md):
- **Solo**: One agent instance per role (MVP — currently implemented)
- **Dual**: Same task runs on two backends (Claude Code + Codex CLI) → Manager mediates consensus

Key tools: `orchestrator.sh` (boot/dispatch/shutdown), `monitor.sh` (polling), `mailbox.sh` (messaging).
See `agents/manager/techniques/orchestration.md` for details.

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

## Spawning Agents (Manager Use)

Boot Manager into tmux session:

```bash
bash agents/manager/tools/orchestrator.sh boot-manager {project-name}
```

Boot all other agents (run by Manager inside tmux):

```bash
bash agents/manager/tools/orchestrator.sh boot {project-name}
```

Dispatch a task to an agent:

```bash
bash agents/manager/tools/orchestrator.sh dispatch {role} {task-file} {project-name}
```

Shutdown all agents:

```bash
bash agents/manager/tools/orchestrator.sh shutdown {project-name}
```

Check status:

```bash
bash agents/manager/tools/orchestrator.sh status {project-name}
```

Model selection is automatic: `opus` (Researcher), `sonnet` (Developer), `haiku` (Monitoring).

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
