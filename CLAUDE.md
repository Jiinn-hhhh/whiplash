# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repository Is

**Whiplash** — a multi-agent team governance framework (in Korean) that defines how three specialized AI agent roles — Manager, Developer, Researcher — collaborate. This is a documentation-first project: no build system, no package manager, no traditional code. All rules, procedures, and communication happen through structured Markdown files.

## Architecture

### Agent Hierarchy

```
User
  ↓
Manager (hub, no team — coordinates everything)
  ├→ Developer (개발팀 team lead — builds production systems)
  └→ Researcher (리서치팀 team lead — researches and proposes)
```

- **Manager**: Decomposes user goals into team tasks, coordinates across teams, escalates strategic decisions to user. Never does hands-on work.
- **Developer**: Implements production code, designs architecture, builds infra for Researcher experiments. Reports to Manager.
- **Researcher**: Collects/analyzes sources, runs experiments (prototype-level only), proposes directions. Reports to Manager.

### 4-Folder Separation

| Folder | Nature | Who reads it | Git |
|--------|--------|--------------|-----|
| `agents/` | Framework definitions (immutable) | Agents + designers | tracked |
| `workspace/` | Active work in progress (volatile) | Agents | ignored |
| `memory/` | Accumulated knowledge + memory (persistent) | Agents | ignored |
| `reports/` | User-facing documents (output) | User | ignored |

Git clone gives you only `agents/`. The rest is created at runtime.

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
│   │   ├── agent-spec.md        #     New agent definition template
│   │   ├── communication.md     #     Communication rules, shared space structure
│   │   ├── formats.md           #     Document templates (Lesson, Discussion, Meeting, Report)
│   │   └── memory.md            #     Knowledge management, lesson lifecycle
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
├── workspace/                   # Runtime work area (gitignored)
│   ├── shared/                  #   Cross-team discussions, meetings, announcements
│   │   ├── discussions/
│   │   ├── meetings/
│   │   └── announcements/
│   └── teams/                   #   Team-internal workspaces
│       ├── research/
│       └── developer/
│
├── memory/                      # Accumulated state (gitignored)
│   ├── manager/                 #   Agent personal notes
│   ├── researcher/
│   ├── developer/
│   └── knowledge/               #   Shared knowledge
│       ├── lessons/             #     Active lessons (max 30, LESSON-NNN.md)
│       ├── docs/                #     Reference documents
│       ├── discussions/         #     Closed discussion originals
│       ├── meetings/            #     Closed meeting originals
│       ├── archives/            #     Cycled-out lessons
│       └── index.md             #     Knowledge map (~100 lines)
│
└── reports/                     # User-facing documents (gitignored)
```

## Key Conventions

- **Language**: All framework documents are written in Korean.
- **Append-only**: Never edit another agent's text. Corrections go in new sections.
- **Citation enforcement**: Reference prior lessons as `Cite LESSON-NNN`. Never use lesson content without citation.
- **Reasoning obligation**: Every decision and artifact must include explicit rationale.
- **Context minimization**: `memory/knowledge/index.md` stays under ~100 lines. Active lessons capped at 30. Deep reads are on-demand.
- **No prototype-to-production shortcuts**: Researcher prototypes must be re-architected by Developer before production.
- **Document IDs**: `LESSON-NNN`, `DISC-NNN`, `MEET-NNN`, `ADR-NNN` (3-digit sequential).

## Agent Onboarding Sequence

1. Read `agents/common/README.md`
2. Read `memory/knowledge/index.md`
3. Read your agent's `profile.md`
4. Start working

## Adding a New Agent

1. Follow `agents/common/agent-spec.md` template
2. Create `agents/{role}/profile.md`
3. Add procedures in `agents/{role}/techniques/*.md`
4. Add automation code in `agents/{role}/tools/` as needed
5. Agent's personal memory goes in `memory/{role}/` (created at runtime)
