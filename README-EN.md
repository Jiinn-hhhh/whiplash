# Whiplash

> Whip the AIs into producing great results.

A framework where AI agents collaborate as a team. Define roles, procedures, and communication rules with **Markdown documents** — agents read and follow them autonomously.

[Korean (한국어)](README.md)

---

## Getting Started

Open Claude Code in the whiplash directory and start talking.

```
"Start a new project"
"Continue midi-render"
```

The Onboarding agent designs the project, Manager assembles the team and distributes tasks.

<details>
<summary>Prerequisites</summary>

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (`npm install -g @anthropic-ai/claude-code`)
- [tmux](https://github.com/tmux/tmux) (`brew install tmux` / `apt install tmux`)
- [jq](https://jqlang.github.io/jq/) (`brew install jq` / `apt install jq`)

```bash
git clone https://github.com/Jiinn-hhhh/whiplash.git
cd whiplash
```

</details>

<details>
<summary>Execution modes</summary>

| Mode | Description | Cost |
|------|-------------|------|
| **solo** | Manager runs one agent per role (tmux-based) | 1x |
| **dual** (experimental) | Same task on Claude Code + Codex, consensus-based | 2x |

</details>

<details>
<summary>Observing agents</summary>

```bash
tmux attach -t whiplash-{project-name}
# Ctrl-b + n/p/number to switch agent windows
```

</details>

---

## Onboarding Process

When a user starts a new project, the Onboarding agent designs it through conversation. Not a survey — it identifies gaps in the user's answers and digs in naturally.

<details>
<summary>Phase 0–7 details</summary>

| Phase | Description | Output |
|-------|-------------|--------|
| Pre-question | Execution mode selection (solo / dual) | project.md draft, directory structure |
| 0. Existing work | Thoroughly analyze existing code/repos if any | — |
| 1. Big picture | Project type, goal, motivation | project.md name & goal |
| 2. Existing resources | Code, data, reference materials | project.md resources section |
| 3. Constraints | Environment, time, budget, tech limitations | project.md constraints section |
| 4. Success criteria | Quantitative/qualitative goals | project.md success criteria |
| 5. Operations | Reporting frequency/channel, autonomy scope, notification verification | project.md operations section |
| 6. Team customization | Per-agent focus adjustment (if needed) | team/{role}.md |
| 7. Review & finalize | Full review → hand off to Manager | Manager tmux boot |

**Progressive recording**: Each Phase writes to project.md immediately — nothing is deferred to the end.

</details>

<details>
<summary>Phase 5: Notification channel selection + verification</summary>

In Phase 5, the user is asked to choose a reporting channel. When an external channel is selected, a test notification is sent to verify actual delivery.

Options:
- `reports/` files (default, no verification needed)
- Slack webhook → send test message, confirm receipt
- Email → send test email, confirm receipt

If delivery fails, fix the configuration immediately. **The process does not proceed without verification.**

Technical prerequisites (webhook URL, email service integration, etc.) are recorded in project.md and prioritized for Developer to set up after Manager handoff.

</details>

---

## Core Philosophy

- Using agents well is **environment engineering, not prompt engineering**.
- Same model, different harness design → 2x+ difference in results.
- Not "do better" but **"work within this structure"** — constraints drive quality.

---

## Organization

```
User — occasional intervention. Critical decisions only.
 ↕
Onboarding — designs projects through conversation with user.
 ↕
Manager — user ↔ team hub. Creates agents, distributes tasks, coordinates, reports.
 ├── Researcher (research team lead)
 ├── Developer (development team lead)
 └── Monitoring (independent observer)
```

<details>
<summary>Agent details</summary>

| Agent | Role | Model | Allowed Tools |
|-------|------|-------|---------------|
| **Onboarding** | Designs projects via user conversation. Creates project.md, hands off to Manager | opus | Read,Glob,Grep,Write,Edit,Bash |
| **Manager** | User ↔ team hub. Agent lifecycle, task distribution, coordination, reporting | opus | Read,Glob,Grep,Bash,WebSearch,WebFetch |
| **Researcher** | Source collection/analysis, experiments (prototype-level), direction proposals | opus | Read,Glob,Grep,Bash,WebSearch,WebFetch |
| **Developer** | Production code, architecture design, infrastructure | opus | All |
| **Monitoring** | Independent observer. Infra/environment health checks | haiku | Read,Glob,Grep,Bash |

</details>

---

## Execution

Manager runs the team inside a tmux session. Each agent runs independently in its own tmux window.

```
tmux session: whiplash-{project}
  ├─ [0] manager
  ├─ [1] researcher
  ├─ [2] developer
  ├─ [3] monitoring
  └─ [4] researcher-2          ← dynamically spawned (on demand)
```

**Boot** — When the user starts onboarding, the Onboarding agent designs the project (project.md) and boots Manager. Manager then boots team agents (Researcher, Developer, Monitoring) and distributes the first tasks.

**Communication** — Combines real-time notifications (instant delivery for task completion, status updates, etc.) with structured documents (discussions, meetings, announcements recorded as markdown).

**Tasks** — Manager writes a directive and delivers it to an agent. The agent reports back upon completion. In dual mode, the same task runs on both backends and Manager drives consensus.

**Dynamic spawn** — When an agent is busy with a long task, an additional instance of the same role is deployed. Each agent works in an isolated git worktree; squash merge on termination.

**Failure recovery** — Health check every 30 seconds. Auto-recovery on crash (max 3 attempts), alert to Manager on 10-minute inactivity. Heartbeat monitors the monitor itself for zombie detection.

<details>
<summary>Boot technical details</summary>

Onboarding runs `cmd.sh boot-manager` to boot Manager. Manager runs `cmd.sh boot` to boot the team.

Per-agent boot process:
1. Parse model and allowed tools from `profile.md`'s `<!-- agent-meta -->` block
2. `claude -p "{boot_message}" --model {model} --allowedTools {tools} --output-format json` → session_id
3. `tmux new-window -n {role}` → window created
4. `claude --resume {session_id} --allowedTools {tools}` → interactive session starts (`--resume` doesn't inherit flags, so re-passed)
5. Recorded in `sessions.md`

</details>

<details>
<summary>Communication technical details</summary>

| Channel | Implementation |
|---------|---------------|
| Real-time notifications | `message.sh` → tmux `load-buffer` + `paste-buffer` to recipient's window |
| Discussions | `workspace/shared/discussions/DISC-NNN.md` (append-only) |
| Meetings | `workspace/shared/meetings/MEET-NNN.md` (3 rounds: position → response → synthesis) |
| Announcements | `workspace/shared/announcements/` |

Notification types: task_complete, status_update, need_input, escalation, agent_ready, reboot_notice, consensus_request

</details>

<details>
<summary>Task & spawn technical details</summary>

Task delivery:
```bash
cmd.sh dispatch {role} {task-file} {project}       # single backend
cmd.sh dual-dispatch {role} {task-file} {project}   # dual backend
```
Delivered via `tmux send-keys`. Agent reports `task_complete` via `message.sh`.

Dynamic spawn:
```bash
cmd.sh spawn {role} {window-name} {project}     # spawn
cmd.sh kill-agent {window-name} {project}        # terminate
```
Each agent works in an isolated git worktree. Squash merge on termination. `monitor.sh` auto-watches spawned agents.

</details>

<details>
<summary>Failure recovery technical details</summary>

`monitor.sh` is a nohup background daemon:

- **Crash detection**: parses active roles from `sessions.md` → detects tmux window disappearance → `cmd.sh reboot` (max 3 attempts)
- **Hung detection**: 10-minute inactivity → `message.sh` alert to Manager (no auto-kill). Auto-clears when activity resumes
- **Heartbeat**: writes timestamp to `monitor.heartbeat` every 30s. Manager calls `cmd.sh monitor-check` → 90s+ stale = zombie → restart
- **Session refresh**: when context grows too large, `cmd.sh refresh` → handoff to new session

</details>

<details>
<summary>Full CLI commands (Manager-internal)</summary>

These are run internally by the Manager agent. Users do not run them directly.

```bash
# Boot/Shutdown
cmd.sh boot-manager   {project}
cmd.sh boot           {project}
cmd.sh shutdown       {project}

# Tasks
cmd.sh dispatch       {role} {task-file} {project}
cmd.sh dual-dispatch  {role} {task-file} {project}

# Dynamic Spawn
cmd.sh spawn          {role} {window-name} {project}
cmd.sh kill-agent     {window-name} {project}

# Recovery/Management
cmd.sh reboot         {target} {project}
cmd.sh refresh        {target} {project}
cmd.sh status         {project}
cmd.sh monitor-check  {project}
```

</details>

---

## Logging

Infrastructure events (agent boot, shutdown, crash, task dispatch, etc.) are automatically recorded in `system.log`. Notification delivery and failures between agents are recorded in `message.log`. Agents themselves are unaware of logging.

<details>
<summary>Log format + examples</summary>

**system.log** — infrastructure events:
```
2026-03-03 18:44:35 [info] researcher 부팅 session=abc-123
2026-03-03 18:44:35 [warn] developer 크래시 감지 count=0/3
2026-03-03 18:44:35 [error] developer 리부팅 한도 초과 count=3/3
2026-03-03 18:44:35 [info] test-project 프로젝트 종료
```

**message.log** — message delivery history:
```
2026-03-03 18:44:35 [delivered] researcher → manager "TASK-001 completed"
2026-03-03 18:44:35 [skipped] manager → researcher "Direction choice needed" reason="no claude process"
```

Written by: `cmd.sh` and `monitor.sh` call `log.py system`; `message.sh` calls `log.py message`.

</details>

<details>
<summary>Filtering with grep</summary>

```bash
grep "\[error\]" logs/system.log           # errors only
grep -E "크래시|리부팅" logs/system.log     # crash/reboot history
grep "skipped" logs/message.log            # failed messages
grep "researcher" logs/system.log          # specific agent
```

</details>

<details>
<summary>Log level + rotation</summary>

Level is auto-determined by event type:

| Level | Events |
|-------|--------|
| **error** | Boot failure, reboot failure, reboot limit, monitor exit, monitor zombie |
| **warn** | Crash detected, hung detected, agent kill, monitor restart, session absent, notify delivery failure |
| **info** | Everything else (boot, dispatch, shutdown — normal operations) |

Rotation: 10MB rolling with max 3 generations (`.1` → `.2` → `.3`).
Concurrent write protection: `fcntl.flock()`.

</details>

---

## Project Structure

```
whiplash/
├── agents/                      # Agent definitions (immutable, git tracked)
├── domains/                     # Domain-specific definitions (git tracked)
├── scripts/                     # Infrastructure scripts (cmd, monitor, message, log)
├── feedback/                    # Framework improvement insights
└── projects/                    # Per-project runtime (mutable, gitignored)
    └── {project-name}/
        ├── project.md           #   Project definition
        ├── team/                #   Agent customization (optional)
        ├── workspace/           #   Active work in progress
        ├── memory/              #   Accumulated state
        │   └── knowledge/       #     Shared knowledge (lessons, docs, archives)
        ├── logs/                #   Infrastructure logs (system.log, message.log)
        └── reports/             #   User-facing documents
```

<details>
<summary>Separation rationale</summary>

| Folder | Nature | Git |
|--------|--------|-----|
| `agents/` | Framework definitions (immutable) | tracked |
| `domains/` | Domain-specific definitions (immutable) | tracked |
| `scripts/` | Infrastructure scripts | tracked |
| `feedback/` | Framework improvement (independent) | tracked |
| `projects/` | Per-project runtime data (mutable) | ignored |

**Git clone gives you `agents/` + `domains/` + `scripts/` + `feedback/`.** Project data is created at runtime by agents.

</details>

<details>
<summary>Agent layer separation</summary>

| Layer | Content | Change frequency |
|-------|---------|-----------------|
| `profile.md` | Definition — role, rules (what/why) | Stable |
| `techniques/` | Methods — natural language procedures (how) | Freely improvable |

</details>

<details>
<summary>Agent folder structure</summary>

```
agents/
├── common/                  # Shared rules + project conventions
├── onboarding/              # Onboarding agent
├── manager/                 # Manager agent
│   ├── profile.md           #   Role definition
│   └── techniques/ (6)      #   Procedures
├── researcher/              # Researcher agent
│   ├── profile.md
│   └── techniques/ (6)
├── developer/               # Developer agent
│   ├── profile.md
│   └── techniques/ (5)
└── monitoring/              # Monitoring agent
    ├── profile.md
    └── techniques/ (2)
```

</details>

---

## Multi-Project

One framework runs multiple projects simultaneously. Each project gets isolated workspace, memory, logs, and reports.

<details>
<summary>Details</summary>

- Paths like `workspace/`, `memory/`, `reports/` in agent docs resolve relative to the current project
- Each project gets its own tmux session (`whiplash-{project}`)
- Cross-project references use explicit full paths

Details: `agents/common/project-context.md`

</details>

---

## Domain Specialization

Assign a domain to a project and agents get additional field-specific context. Domains **supplement** base rules. They never replace them.

<details>
<summary>Details</summary>

- `domains/{domain}/context.md` — domain background read by all agents
- `domains/{domain}/{role}.md` — role-specific domain guidelines (optional)
- Projects without a domain default to `general` (no extra files needed)

Details: `domains/README.md`

</details>

---

## Design Principles

| Principle | Description |
|-----------|-------------|
| Environment Engineering | Repo structure and file conventions have more leverage than prompts |
| 3-Folder Separation | Immutable (agents/ + domains/) and mutable (projects/) separated at folder level |
| Context Minimization | Give a map, not an encyclopedia. Index ~100 lines, lessons capped at 30 |
| Progressive Disclosure | Documents split into 3 layers (required/on-task/on-demand) to save context window |
| Git Worktree Isolation | Each agent works in an independent worktree. Squash merge on termination |
| Backpressure Gate | Self-verification required before task_complete. No unverified completion reports |
| Semantic Compaction | Inactive lessons move to archive/ with 1-line summary reference. Originals preserved |
| Role-based Tool Restriction | Allowed tools defined in profile.md metadata, enforced by cmd.sh via --allowedTools |
| Harness = Competitive Edge | Changing structure yields more than changing models |
| Fail-safe | When agents fail, improve the environment instead of having humans take over |

---

## For Agents

If you are an agent, use **Progressive Disclosure** — read only what you need, when you need it:

**Layer 1 — Required (immediately on onboarding)**
1. `agents/common/README.md` — common rules, onboarding procedure
2. Your agent's `profile.md` — role definition
3. `projects/{name}/project.md` — current project

**Layer 2 — On task start**
4. `memory/knowledge/index.md` — knowledge map (reference only, not full read)
5. Relevant `techniques/*.md` for the task at hand
6. (If exists) `domains/{domain}/context.md` — domain background

**Layer 3 — On demand**
7. `agents/common/project-context.md` — path resolution conventions, when needed
8. (If exists) `domains/{domain}/{role}.md` — domain-specific guidelines
9. (If exists) `team/{role}.md` — project-specific guidelines

If you find inefficiencies in the framework itself, read `feedback/guide.md` and record them in `feedback/insights.md`.
