# Whiplash

> Whip the AIs into producing great results.

A framework that defines how AI agents collaborate as a team.

Built entirely with **Markdown documents** — no build system, no package manager, no traditional code. Role definitions, procedures, communication rules, and knowledge management are all structured documents that AI agents read and follow autonomously.

[Korean (한국어)](README.md)

---

## Getting Started

### Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (`npm install -g @anthropic-ai/claude-code`)
- [tmux](https://github.com/tmux/tmux) — required for solo/dual mode (`brew install tmux` / `apt install tmux`)
- [jq](https://jqlang.github.io/jq/) — required for solo/dual mode (`brew install jq` / `apt install jq`)

### Quick Start

#### 1. Clone

```bash
git clone https://github.com/Jiinn-hhhh/whiplash.git
cd whiplash
```

#### 2. Choose Execution Mode

| Mode | Description | Pros | Cons | Cost |
|------|-------------|------|------|------|
| **solo** | Manager runs one agent per role sequentially (tmux-based) | Lowest cost, stable | No concurrency | 1x |
| **agent-team** | Claude Code Agent Teams for simultaneous execution | Convenient, parallel work | Higher cost | 4-7x |
| **dual** | Same task runs on two backends (Claude Code + Codex) | Diverse perspectives, consensus-based | Complex infra | 2x |

#### 3-A. Agent-Team Mode (Recommended)

```bash
bash agent-team/boot.sh
```

Opens a Claude Code session with Agent Teams enabled. Then:

```
"Start a new project"
```

The Onboarding agent discusses the project with you, then automatically transitions to Manager in the same session — creates team, spawns agents, opens dashboard, distributes tasks. Fully automated.

#### 3-B. Solo/Dual Mode

Run Claude Code in this folder:

```
You are the Onboarding agent. Read agents/onboarding/profile.md and start a new project onboarding.
```

After onboarding completes:

1. `orchestrator.sh boot-manager` boots Manager into a tmux session
2. Manager automatically boots remaining agents
3. You get a tmux attach command

```bash
tmux attach -t whiplash-{project-name}
# Ctrl-b + n/p/number to switch agent windows
```

**All you do is the onboarding conversation.** After that, Manager assembles the team, distributes tasks, and coordinates results.

---

## Core Philosophy

- Using agents well is **environment engineering, not prompt engineering**.
- Same model, different harness design → 2x+ difference in results.
- The key is not "do better" but **"work within this structure"** — constraints drive quality.

---

## Organization

```
User — occasional intervention. Only for critical decisions.
 ↕
Onboarding — designs projects through conversation with user. Runs before Manager.
 ↕
Manager — user ↔ team hub. Creates agents, distributes tasks, coordinates, reports.
 ├── Researcher (research team lead)
 ├── Developer (development team lead)
 └── Monitoring (independent observer)
```

| Agent | Role | Model (solo/dual) |
|-------|------|-------------------|
| **Onboarding** | Designs projects via user conversation. Creates project.md, hands off to Manager | - |
| **Manager** | User ↔ team hub. Agent lifecycle, task distribution, coordination, reporting | sonnet |
| **Researcher** | Source collection/analysis, experiments (prototype-level), direction proposals | opus |
| **Developer** | Production code, architecture design, infrastructure | sonnet |
| **Monitoring** | Independent observer. Infra/environment health checks | haiku |

---

## Execution

### Agent-Team Mode

```
User: "Start a new project"
  │
  ▼
Onboarding (boot.sh → Claude Code session)
  │  Conversation → project.md created
  │  Phase 7: auto-transition to Manager
  │
  ▼
Manager (same session)
  │
  ├─ TeamCreate("whiplash-{project}")
  ├─ Task(spawn) × 3 — Researcher, Developer, Monitoring (parallel)
  ├─ Wait for 3× "ready" messages
  ├─ Start dashboard server (browser auto-opens)
  ├─ Analyze project.md goals → distribute first tasks
  └─ Team operation begins
       ├─ SendMessage for task instructions
       ├─ Receive reports → distribute next tasks
       ├─ Update agent-team-status.json → dashboard reflects in real-time
       └─ Report to user
```

- Agent communication: `SendMessage` (native)
- Task management: `TaskCreate` + `TaskUpdate`
- Crash detection: Manager checks at 10min/5min/5min intervals → re-spawn
- Details: `agent-team/manager/techniques/orchestration.md`

### Solo/Dual Mode

```
User: "Start onboarding"
  │
  ▼
Onboarding → project.md created
  │
  ├─ orchestrator.sh boot-manager → tmux session created
  └─ User gets "tmux attach" instructions
       │
       ▼
Manager (inside tmux, automated)
  │
  ├─ orchestrator.sh boot → Researcher, Developer, Monitoring booted
  ├─ monitor.sh running in background
  ├─ agent_ready received → first task distribution
  └─ Team operation begins
```

```
tmux session: whiplash-{project}
  ├─ [0] manager
  ├─ [1] researcher
  ├─ [2] developer
  └─ [3] monitoring
```

- Agent communication: `mailbox.sh` (Maildir pattern)
- Task management: Task files + `dispatch`
- Crash detection: `monitor.sh` polls every 30s, auto-reboot (max 3x)
- Details: `agents/manager/techniques/orchestration.md`

### CLI Commands (solo/dual)

```bash
bash agents/manager/tools/orchestrator.sh boot-manager {project}  # Boot Manager
bash agents/manager/tools/orchestrator.sh boot {project}          # Boot agents
bash agents/manager/tools/orchestrator.sh dispatch {role} {task} {project}  # Send task
bash agents/manager/tools/orchestrator.sh status {project}        # Check status
bash agents/manager/tools/orchestrator.sh shutdown {project}      # Shutdown all
```

---

## Dashboard

A pixel-art office dashboard for visual agent monitoring.

```bash
python3 dashboard/server.py --project {project-name}
# → http://localhost:8420 auto-opens in browser
```

- 3-second polling for real-time agent status
- Agents move based on state: working → desk, idle → lounge, sleeping → sofa
- Orange flashing banner + browser notification when Manager awaits user input
- Solo/dual mode: collects from tmux + sessions.md
- Agent-team mode: reads `agent-team-status.json` written by Manager
- Double-buffered rendering for flicker-free display

---

## Project Structure

```
whiplash/
├── agents/                      # Framework definitions (immutable, git tracked)
│   ├── common/                  #   Shared rules + project conventions
│   ├── onboarding/              #   Onboarding agent
│   ├── manager/                 #   Manager agent
│   │   ├── profile.md           #     Role definition
│   │   ├── techniques/ (5)      #     Procedures
│   │   └── tools/               #     orchestrator.sh, monitor.sh, mailbox.sh
│   ├── researcher/              #   Researcher agent
│   │   ├── profile.md
│   │   └── techniques/ (6)
│   ├── developer/               #   Developer agent
│   │   ├── profile.md
│   │   └── techniques/ (5)
│   └── monitoring/              #   Monitoring agent
│       └── techniques/ (2)
│
├── agent-team/                  # Agent Team mode module (git tracked)
│   ├── boot.sh                  #   Entry point script
│   ├── manager/                 #   Manager supplement
│   │   ├── profile-supplement.md
│   │   ├── techniques/ (3)      #     orchestration, task-distribution, crash-recovery
│   │   └── tools/spawn-prompts/ #     Agent spawn prompts
│   └── common/                  #   Shared supplements
│       ├── communication-supplement.md
│       └── file-ownership.md
│
├── domains/                     # Domain-specific definitions (git tracked)
│   └── deep-learning/           #   Example domain
│
├── dashboard/                   # Visual office dashboard (independent module)
│   ├── server.py                #   HTTP server (Python stdlib only)
│   ├── status-collector.sh      #   Data collection → JSON (mode-aware)
│   ├── index.html               #   Canvas + polling
│   ├── sprites.js               #   Pixel art sprite definitions
│   └── office.js                #   Office layout + rendering engine
│
├── feedback/                    # Framework improvement insights (independent module)
│   ├── guide.md                 #   Recording rules
│   └── insights.md              #   Accumulated insights
│
└── projects/                    # Per-project runtime data (mutable, gitignored)
    └── {project-name}/
        ├── project.md           #   Project definition
        ├── team/                #   Agent customization (optional)
        ├── workspace/           #   Active work in progress
        ├── memory/              #   Accumulated state
        │   └── knowledge/       #     Shared knowledge (lessons, docs, archives)
        └── reports/             #   User-facing documents
```

### Separation Rationale

| Folder | Nature | Git |
|--------|--------|-----|
| `agents/` | Framework definitions (immutable) | tracked |
| `agent-team/` | Agent Team mode supplement (immutable) | tracked |
| `domains/` | Domain-specific definitions (immutable) | tracked |
| `dashboard/` | Visual dashboard (independent) | tracked |
| `feedback/` | Framework improvement (independent) | tracked |
| `projects/` | Per-project runtime data (mutable) | ignored |

**Git clone gives you `agents/` + `agent-team/` + `domains/` + `dashboard/` + `feedback/`.** Project data is created at runtime by agents.

---

## Three-Layer Separation

Each agent folder follows three layers. Stable upper layers allow lower layers to evolve independently.

| Layer | Content | Change frequency |
|-------|---------|-----------------|
| `profile.md` | Definition — role, rules (what/why) | Stable |
| `techniques/` | Methods — natural language procedures (how) | Freely improvable |
| `tools/` | Automation — pre-built scripts (execution) | Added as needed |

---

## Multi-Project

One framework runs multiple projects simultaneously. Each project has isolated workspace, memory, and reports under `projects/{name}/`.

- Paths like `workspace/`, `memory/`, `reports/` in agent docs resolve relative to the current project
- Each project gets its own tmux session (`whiplash-{project}`) or Agent Team (`whiplash-{project}`)
- Cross-project references use explicit full paths

Details: `agents/common/project-context.md`

---

## Domain Specialization

Assign a domain to a project and agents get additional context for that field.

- `domains/{domain}/context.md` — domain background read by all agents
- `domains/{domain}/{role}.md` — role-specific domain guidelines (optional)
- Domains **supplement** base rules. They never replace them.
- Projects without a domain default to `general` (no extra files needed)

Details: `domains/README.md`

---

## Current Implementation

| Agent | profile.md | techniques |
|-------|:----------:|:----------:|
| Onboarding | O | 1 |
| Manager | O | 5 (+3 agent-team) |
| Researcher | O | 6 |
| Developer | O | 5 |
| Monitoring | - | 2 |

| Domain | Description |
|--------|-------------|
| deep-learning | Deep learning projects (context.md + researcher.md) |

---

## Design Principles

| Principle | Description |
|-----------|-------------|
| Environment Engineering | Repo structure and file conventions have more leverage than prompts |
| 3-Folder Separation | Immutable (agents/ + domains/) and mutable (projects/) separated at folder level |
| Project Isolation | Multiple projects never mix workspace/memory/reports |
| Domain Supplementation | Base rules stay while domains add field-specific context |
| Context Minimization | Give a map, not an encyclopedia. Index ~100 lines, lessons capped at 30 |
| Feedback Loops | Auto-verification + lesson accumulation beats one-shot instructions |
| Citation Enforcement | Mandatory lesson citations enable reasoning traceability |
| Harness = Competitive Edge | Changing structure yields more than changing models |
| Fail-safe | When agents fail, improve the environment instead of having humans take over |

---

## For Agents

If you are an agent, read these files in order:

1. `agents/common/README.md` — common rules, onboarding procedure
2. `agents/common/project-context.md` — project conventions
3. Your agent's `profile.md` — role definition
4. `projects/{name}/project.md` — current project
5. `domains/{domain}/context.md` — domain background
6. (If exists) `domains/{domain}/{role}.md` — domain-specific guidelines
7. (If exists) `team/{role}.md` — project-specific guidelines
8. `memory/knowledge/index.md` — project knowledge map

If you find inefficiencies in the framework itself, read `feedback/guide.md` and record them in `feedback/insights.md`.
