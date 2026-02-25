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
| **solo** | Manager runs one agent per role (tmux-based) | Lowest cost, stable | No concurrency | 1x |
| **dual** (experimental) | Same task runs on two backends (Claude Code + Codex) | Diverse perspectives, consensus-based | Complex infra, not E2E tested | 2x |

#### 3. Start

Open Claude Code (or Codex CLI) in the whiplash directory:

```
"Start a new project"
```

The Onboarding agent discusses the project with you, then automatically boots Manager into a tmux session → boots team agents → distributes tasks. Fully automated.

To continue an existing project:

```
"Continue midi-render"
```

All you do is talk. After that, Manager assembles the team, distributes tasks, and coordinates results.

To observe agents working in a separate terminal:
```bash
tmux attach -t whiplash-{project-name}
# Ctrl-b + n/p/number to switch agent windows
```

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

| Agent | Role | Model |
|-------|------|-------|
| **Onboarding** | Designs projects via user conversation. Creates project.md, hands off to Manager | - |
| **Manager** | User ↔ team hub. Agent lifecycle, task distribution, coordination, reporting | sonnet |
| **Researcher** | Source collection/analysis, experiments (prototype-level), direction proposals | opus |
| **Developer** | Production code, architecture design, infrastructure | sonnet |
| **Monitoring** | Independent observer. Infra/environment health checks | haiku |

---

## Execution

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
  ├─ [3] monitoring
  └─ [4] researcher-2          ← dynamically spawned (on demand)
```

- Agent communication: `notify.sh` — direct tmux delivery (fire-and-forget)
- Task management: Task files + `dispatch` / `dual-dispatch`
- Crash detection: `monitor.sh` health check every 30s, auto-reboot (max 3x)
- Dynamic spawn: when an agent is busy, `spawn` adds another instance of the same role; `kill-agent` terminates it after work
- Details: `agents/manager/techniques/orchestration.md`

### CLI Commands (Manager-internal)

These commands are run internally by the Manager agent. Users do not run them directly.

```bash
# Boot/Shutdown
orchestrator.sh boot-manager   {project}                          # Boot Manager + create tmux session
orchestrator.sh boot           {project}                          # Boot agents + start monitor
orchestrator.sh shutdown       {project}                          # Shutdown all + cleanup

# Tasks
orchestrator.sh dispatch       {role} {task-file} {project}       # Send task to agent
orchestrator.sh dual-dispatch  {role} {task-file} {project}       # Send task to both backends (dual mode)

# Dynamic Spawn
orchestrator.sh spawn          {role} {window-name} {project}     # Spawn extra agent
orchestrator.sh kill-agent     {window-name} {project}            # Kill spawned agent

# Recovery/Management
orchestrator.sh reboot         {target} {project}                 # Restart agent (crash recovery)
orchestrator.sh refresh        {target} {project}                 # Context refresh (handoff → new session)
orchestrator.sh status         {project}                          # Check session status
orchestrator.sh monitor-check  {project}                          # Check monitor.sh + auto-restart
```

---

## How It Works (Technical Details)

### 1. Onboarding

- CLAUDE.md → Onboarding agent auto-activates
- Checks `projects/` → resume existing project or start new one
- New project: Phase 0~7 dialogue → `project.md` + directory creation
- Execution mode selection (solo / dual)

### 2. Manager Boot

- `orchestrator.sh boot-manager {project}`
  - Creates tmux session `whiplash-{project}`
  - `claude -p "{boot_message}" --model sonnet --output-format json` → session_id
  - `tmux new-window -n manager` + `claude --resume {session_id}`
  - Records in `sessions.md`
- Onboarding session terminates, user gets "tmux attach" instructions

### 3. Team Boot

- Manager runs `orchestrator.sh boot {project}`
  - Parses active agent list + execution mode from `project.md`
  - Each agent: `claude -p` (get session_id) → create tmux window → `claude --resume`
  - Dual mode: creates `{role}-claude` + `{role}-codex` windows per role (monitoring excluded)
  - Per-role models: researcher=opus, developer=sonnet, monitoring=haiku
  - Per-role tool restrictions: monitoring gets Read/Glob/Grep/Bash only
  - Per-role turn limits: monitoring=10, manager=20, researcher=30, developer=40
  - `monitor.sh` runs as nohup background process

### 4. Communication

- **Notifications (real-time)** — `notify.sh` (direct tmux delivery):
  - Agent A → `notify.sh` → delivers directly to Agent B's tmux window
  - Uses `tmux load-buffer` + `paste-buffer` for reliable multiline delivery
  - Fire-and-forget: if the tmux session/window is absent, logs a warning and continues
  - Types: task_complete, status_update, need_input, escalation, agent_ready, reboot_notice, consensus_request
  - Audit log: `memory/manager/logs/notify-audit.log`
- **Discussions** (`workspace/shared/discussions/DISC-NNN.md`): structured documents, append-only
- **Meetings** (`workspace/shared/meetings/MEET-NNN.md`): 3 rounds (position → response → synthesis)
- **Announcements** (`workspace/shared/announcements/`): task directives

### 5. Task Execution

- Manager writes directive → `orchestrator.sh dispatch {role} {task-file}`
- Delivered to agent via tmux send-keys
- Agent completes → sends task_complete via notify.sh
- Dual mode: `dual-dispatch` to both backends → Manager drives consensus

### 6. Dynamic Spawn

- When an agent is busy with a long task, spawn an additional instance of the same role
- `orchestrator.sh spawn {role} {window-name} {project}` → boots agent in new tmux window
- Shares the same project memory/workspace. Only restriction: no concurrent edits to the same file
- After work is done: `orchestrator.sh kill-agent {window-name} {project}`
- monitor.sh automatically watches spawned agents (including crash reboot)

### 7. Failure Recovery

`monitor.sh` is a dedicated health-check daemon. Checks agent status every 30 seconds and reports anomalies to Manager via `notify.sh`.

- **Crash detection**: Parses active roles from `sessions.md` → detects tmux window disappearance → auto-reboots via `orchestrator.sh reboot` (max 3 attempts)
- **Hung detection**: 10-minute inactivity → one-time alert to Manager (no auto-kill). Auto-clears when activity resumes
- **Heartbeat**: Every 30 seconds writes timestamp to `monitor.heartbeat`. Manager calls `monitor-check` — if over 90 seconds stale, zombie verdict → restart
- **Session refresh**: When context grows too large, `orchestrator.sh refresh` performs handoff → boots new session

### 8. Shutdown

- Manager runs `orchestrator.sh shutdown {project}`
- All agent sessions terminated (including dynamic spawns), tmux session killed, monitor.sh PID killed

---

## Project Structure

```
whiplash/
├── agents/                      # Framework definitions (immutable, git tracked)
│   ├── common/                  #   Shared rules + project conventions
│   ├── onboarding/              #   Onboarding agent
│   ├── manager/                 #   Manager agent
│   │   ├── profile.md           #     Role definition
│   │   ├── techniques/ (6)      #     Procedures
│   │   └── tools/               #     orchestrator.sh, monitor.sh, notify.sh
│   ├── researcher/              #   Researcher agent
│   │   ├── profile.md
│   │   └── techniques/ (6)
│   ├── developer/               #   Developer agent
│   │   ├── profile.md
│   │   └── techniques/ (5)
│   └── monitoring/              #   Monitoring agent
│       ├── profile.md
│       └── techniques/ (2)
│
├── domains/                     # Domain-specific definitions (git tracked)
│   └── deep-learning/           #   Example domain
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
| `domains/` | Domain-specific definitions (immutable) | tracked |
| `feedback/` | Framework improvement (independent) | tracked |
| `projects/` | Per-project runtime data (mutable) | ignored |

**Git clone gives you `agents/` + `domains/` + `feedback/`.** Project data is created at runtime by agents.

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
- Each project gets its own tmux session (`whiplash-{project}`)
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
| Manager | O | 6 |
| Researcher | O | 6 |
| Developer | O | 5 |
| Monitoring | O | 2 |

| Domain | Description |
|--------|-------------|
| deep-learning | Deep learning projects (context.md + researcher.md + developer.md + monitoring.md) |

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
