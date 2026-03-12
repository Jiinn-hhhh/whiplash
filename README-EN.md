# Whiplash

> Whip the AIs into producing great results.

A framework where AI agents collaborate as a team. Define roles, procedures, and communication rules with **Markdown documents** — agents read and follow them autonomously.

[Korean (한국어)](README.md)

---

## Quick Start

### 1. Install

```bash
# Required
npm install -g @anthropic-ai/claude-code
brew install tmux jq        # or apt install tmux jq
pip install rich             # for dashboard

# Optional (dual mode)
# Codex CLI: https://github.com/openai/codex

git clone https://github.com/Jiinn-hhhh/whiplash.git
cd whiplash
```

### 2. Run

Open Claude Code in the whiplash directory and start talking.

```
"Start a new project"
"Continue midi-render"
```

### 3. What Happens Next

```
User conversation → Onboarding designs project → Manager assembles team → Agents work
```

Watch agents via tmux:
```bash
tmux attach -t whiplash-{project-name}
# Ctrl-b + n/p/number to switch windows
# Window 0 is the real-time dashboard
```

**That's all you need to get started.** Everything below covers how the framework works under the hood.

---
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

- Models and allowed tools are defined in each agent's `profile.md` within `<!-- agent-meta -->` blocks
- `cmd.sh` auto-parses these at boot time and applies `--model` and `--allowedTools` flags
- Only Developer has Write/Edit tools, restricting production code modification to Developer

</details>

---

## Execution Modes

| Mode | Description | tmux window layout | Cost |
|------|-------------|-------------------|------|
| **solo** | Manager runs one agent per role (tmux-based) | `manager`, `developer`, `researcher`, `monitoring` | 1x |
| **dual** (experimental) | Same task on Claude Code + Codex CLI, Manager drives consensus | `manager`, `developer-claude`, `developer-codex`, `researcher-claude`, `researcher-codex`, `monitoring` | 2x |

- In dual mode, Monitoring always runs solo (no dual needed)
- Execution mode is chosen during onboarding and recorded in `project.md`

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

## Execution

Manager runs the team inside a tmux session. Each agent runs independently in its own tmux window.

```
tmux session: whiplash-{project}
  ├─ [0] dashboard             ← real-time TUI dashboard (Rich)
  ├─ [1] manager
  ├─ [2] developer(-claude)
  ├─ [3] developer-codex       ← dual mode only
  ├─ [4] researcher(-claude)
  ├─ [5] researcher-codex      ← dual mode only
  ├─ [6] monitoring
  └─ [7] researcher-2          ← dynamically spawned (on demand)
```

<details>
<summary>Boot flow</summary>

```
User ──→ Onboarding ──→ cmd.sh boot-manager ──→ Manager tmux session created
                                                    │
                            Manager auto-runs:  cmd.sh boot {project}
                                                    │
                            ┌───────────┬───────────┼───────────┐
                            ↓           ↓           ↓           ↓
                        dashboard   developer   researcher   monitoring
                                   (-claude)   (-claude)
                                   (-codex)    (-codex)     ← dual mode
```

1. Onboarding writes `project.md`, then `cmd.sh boot-manager` to boot Manager
2. Manager completes onboarding (reads Layer 1 docs), then `cmd.sh boot` to boot team
3. `preflight.sh` validates dependencies (tmux, jq, python3, codex, etc.)
4. Each agent: `claude -p` → session_id → tmux window → `claude --resume`
5. All agents send `agent_ready` → Manager distributes first tasks

</details>

<details>
<summary>Boot technical details</summary>

Onboarding runs `cmd.sh boot-manager` to boot Manager. Manager runs `cmd.sh boot` to boot the team.

Per-agent boot process:
1. Parse model and allowed tools from `profile.md`'s `<!-- agent-meta -->` block
2. `claude -p "{boot_message}" --model {model} --allowedTools {tools} --output-format json` → session_id
3. `tmux new-window -d -n {role}` → window created (background, keeps current window)
4. `claude --resume {session_id} --allowedTools {tools}` → interactive session starts (`--resume` doesn't inherit flags, so re-passed)
5. Recorded in `sessions.md`
6. `--dangerously-skip-permissions` flag for unattended execution (tool approval bypass)

Boot messages automatically include Progressive Disclosure 3-layer onboarding instructions and the notification protocol.

</details>

### Communication

Combines real-time notifications with structured documents.

| Channel | Implementation | Use |
|---------|---------------|-----|
| Real-time notifications | `message.sh` → tmux `load-buffer` + `paste-buffer` | Task completion, status, urgent escalation |
| Discussions | `workspace/shared/discussions/DISC-NNN.md` (append-only) | Technical decisions |
| Meetings | `workspace/shared/meetings/MEET-NNN.md` (3 rounds) | Position → response → synthesis |
| Announcements | `workspace/shared/announcements/` | Task directives (TASK-NNN.md) |

Notification types: `task_complete`, `status_update`, `need_input`, `escalation`, `agent_ready`, `reboot_notice`, `consensus_request`

### Task Distribution

```bash
# Solo mode: deliver task to single agent
cmd.sh dispatch {role} {task-file} {project}

# Dual mode: deliver same task to both backends
cmd.sh dual-dispatch {role} {task-file} {project}
```

Manager writes directives in `workspace/shared/announcements/TASK-NNN.md` and delivers via `dispatch`/`dual-dispatch`. Agents report `task_complete` via `message.sh`.

- Every top-level task must leave a result report in `reports/tasks/{task-id}-{agent}.md` before completion.
- `dispatch`/`task_assign` auto-creates the report stub.
- `task_complete` is allowed only after the report `Status` is `final` and placeholders are removed.

### Dynamic Spawn

When an agent is busy with a long task, deploy an additional instance of the same role.

```bash
cmd.sh spawn {role} {window-name} {project}     # spawn
cmd.sh kill-agent {window-name} {project}        # terminate
```

Spawned agents share the project's memory and workspace. Concurrent modification of the same file is prohibited. `monitor.sh` auto-watches spawned agents.

<details>
<summary>Dual mode consensus procedure</summary>

1. **Collect results**: Wait for `task_complete` from both `{role}-claude` and `{role}-codex`
2. **Create consensus doc**: Compare results → write `DISC-NNN.md`
3. **Cross-deliver**: Send `consensus_request` to both agents for review
4. **Judge**: If agreed → adopt. If disagreed → 2nd round (max 1 additional)
5. **2nd round deadlock**: Manager decides directly or escalates to user
6. **Finalize**: Move consensus doc to `memory/knowledge/`, place result in official location

Workspace separation:
- Claude: `workspace/teams/{team}/{role}-claude/`
- Codex: `workspace/teams/{team}/{role}-codex/`
- After consensus, Manager places final result in the official location

</details>

---

## Failure Recovery

`monitor.sh` runs as a nohup background daemon, health-checking every 30 seconds.

| Detection | Action | Details |
|-----------|--------|---------|
| **Crash** (window gone) | `cmd.sh reboot` auto-called (max 3 attempts) | Reports each attempt to Manager. Escalates after 3 failures |
| **Hung** (10min inactive) | Single alert to Manager | No auto-kill (might be a long bash command). Auto-clears on activity |
| **Monitor zombie** (heartbeat 90s+) | `cmd.sh monitor-check` detects → force restart | Manager calls periodically |
| **Context overload** | `cmd.sh refresh` → handoff → new session | Manual trigger by Manager |

<details>
<summary>Crash recovery details</summary>

1. `monitor.sh` parses active roles from `sessions.md` (not hardcoded)
2. On window disappearance, checks counter in `reboot-counts/{role}.count`
3. Under 3 attempts → `cmd.sh reboot`:
   - Kill existing window → mark `crashed` in sessions.md
   - Query pending task from `assignments.md`
   - Boot new session (includes auto-recovery instruction for pending task)
4. Over 3 attempts → give up → escalation
5. Counter auto-resets when window is confirmed healthy

In dual mode, each backend (`{role}-claude`, `{role}-codex`) is managed independently.

</details>

<details>
<summary>Session refresh details</summary>

When context grows too large, Manager manually triggers:

```bash
cmd.sh refresh {role} {project}
```

1. Instruct agent to write `memory/{role}/handoff.md`
2. Wait up to 2 minutes (watch for handoff.md creation)
3. Terminate existing session → mark `refreshed` in sessions.md
4. Boot new session + add "read handoff.md" instruction

</details>

---

## Dashboard

`dashboard.py` provides a real-time TUI in tmux window 0. Built on the Rich library.

Displays:
- Per-agent status (alive/crashed/absent based on the real child process)
- A compact summary of in-progress tasks (`ACTIVE TASKS`)
- Current task elapsed time + task report status (`DRAFT`/`FINAL`/`MISS`)
- The latest completed task that is still waiting for the next assignment (`NEXT TASK WAITING`)
- Claude agent `plan mode` detection events
- Recent system events (boot, crash, reboot)
- Recent message delivery history
- Monitor heartbeat + queued message state

```bash
# Automatic: dashboard window is created by cmd.sh boot
# Manual:
python3 dashboard/dashboard.py {project} --interval 3
```

---

## Preflight Validation

`preflight.sh` runs automatically on `cmd.sh boot-manager` and `cmd.sh boot`.

Checks:
- **Packages**: tmux, jq, python3, pgrep — auto-installs if possible (brew/apt)
- **Claude CLI**: verifies `claude` command exists
- **Codex CLI**: dual mode only. Checks `--dangerously-bypass-approvals-and-sandbox` support
- **Project structure**: `project.md` exists, all active agents have `profile.md`

Creates `.preflight-ok` marker on first pass to skip package checks on subsequent boots. Claude/Codex auth and project structure are validated every time.

---

## Logging

Infrastructure events (agent boot, shutdown, crash, task dispatch, etc.) are automatically recorded in `system.log`. Notification delivery and failures between agents are recorded in `message.log`. Agents themselves are unaware of logging.

<details>
<summary>Log format + examples</summary>

**system.log** — infrastructure events:
```
2026-03-03 18:44:35 [info] orchestrator agent_boot researcher session=abc-123
2026-03-03 18:44:35 [warn] monitor crash_detected developer count=0/3
2026-03-03 18:44:35 [error] monitor reboot_limit developer count=3/3
2026-03-03 18:44:35 [info] orchestrator project_shutdown test-project
```

**message.log** — message delivery history:
```
2026-03-03 18:44:35 [delivered] researcher → manager task_complete normal "TASK-001 completed"
2026-03-03 18:44:35 [skipped] manager → researcher need_input normal "Direction choice needed" reason="no claude process"
```

Written by: `cmd.sh` and `monitor.sh` call `log.py system`; `message.sh` calls `log.py message`.

</details>

<details>
<summary>Filtering with grep</summary>

```bash
grep "\[error\]" logs/system.log           # errors only
grep -E "crash|reboot" logs/system.log     # crash/reboot history
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

## Script Reference

The Manager agent runs these internally. Users only directly use `boot-manager` and `shutdown`.

```bash
# User-facing
cmd.sh boot-manager   {project}                   # Boot Manager (entry point)
cmd.sh shutdown       {project}                   # Full shutdown

# Manager-internal
cmd.sh boot           {project}                   # Boot team agents
cmd.sh dispatch       {role} {task-file} {project} # Deliver task
cmd.sh dual-dispatch  {role} {task-file} {project} # Dual-deliver task
cmd.sh spawn          {role} {window} {project}    # Spawn additional agent
cmd.sh kill-agent     {window} {project}           # Terminate spawned agent
cmd.sh reboot         {target} {project}           # Restart agent
cmd.sh refresh        {target} {project}           # Context refresh
cmd.sh status         {project}                   # Status check
cmd.sh monitor-check  {project}                   # Monitor health check

# Notifications (called by agents)
message.sh {project} {from} {to} {kind} {priority} {subject} {content}
```

---

## Project Structure

```
whiplash/
├── agents/                      # Agent definitions (immutable, git tracked)
│   ├── common/                  #   Shared rules + project conventions
│   ├── onboarding/              #   Onboarding agent
│   ├── manager/                 #   Manager agent
│   │   ├── profile.md           #     Role definition + agent-meta
│   │   └── techniques/ (6)      #     Procedures
│   ├── researcher/              #   Researcher agent
│   │   ├── profile.md
│   │   └── techniques/ (6)
│   ├── developer/               #   Developer agent
│   │   ├── profile.md
│   │   └── techniques/ (5)
│   └── monitoring/              #   Monitoring agent
│       ├── profile.md
│       └── techniques/ (2)
├── domains/                     # Domain-specific definitions (git tracked)
├── scripts/                     # Infrastructure scripts
│   ├── cmd.sh                   #   Orchestration (boot, dispatch, reboot, etc.)
│   ├── integration-test.sh      #   tmux-based integration tests
│   ├── message.sh               #   Inter-agent real-time notifications (interactive direct delivery)
│   ├── monitor.sh               #   Health check daemon (crash/hung detection)
│   ├── log.py                   #   Structured logger (fcntl lock, rotation)
│   └── preflight.sh             #   Pre-boot environment validation + auto-install
├── dashboard/                   # Real-time TUI dashboard
│   ├── dashboard.py             #   Rich Live-based status monitoring
│   └── requirements.txt         #   Dashboard dependencies
├── feedback/                    # Framework improvement insights
└── projects/                    # Per-project runtime (mutable, gitignored)
    └── {project-name}/
        ├── project.md           #   Project definition (goal, constraints, operations)
        ├── team/                #   Agent customization (optional)
        │   └── {role}.md        #     Project-specific guidelines
        ├── workspace/           #   Active work in progress
        │   ├── shared/          #     Shared (discussions, meetings, announcements, task directives)
        │   └── teams/           #     Per-role work directories
        ├── memory/              #   Accumulated state
        │   ├── knowledge/       #     Shared knowledge (index, lessons, archives)
        │   ├── manager/         #     sessions.md, assignments.md
        │   └── {role}/          #     Per-role personal memory
        ├── runtime/             #   Runtime state files (manager-state.tsv, reboot-state.tsv, queue/locks)
        ├── logs/                #   Infrastructure logs (system.log, message.log)
        └── reports/             #   User-facing documents
            └── tasks/           #     Top-level task result reports
```

<details>
<summary>Separation rationale</summary>

| Folder | Nature | Git |
|--------|--------|-----|
| `agents/` | Framework definitions (immutable) | tracked |
| `domains/` | Domain-specific definitions (immutable) | tracked |
| `scripts/` | Infrastructure scripts | tracked |
| `dashboard/` | Real-time monitoring TUI | tracked |
| `feedback/` | Framework improvement (independent) | tracked |
| `projects/` | Per-project runtime data (mutable) | ignored |

**The framework core is `agents/` + `domains/` + `scripts/` + `dashboard/` + `feedback/` + `projects/`.** Project data is created at runtime by agents.
Local experimental/support folders such as `pixel-agents/` and `system_develop/` may exist alongside it, but they are outside the core framework boundary.

</details>

<details>
<summary>Agent layer separation</summary>

Agent guidelines follow a 3-layer supplementary system:

| Layer | Location | Content | Change frequency |
|-------|----------|---------|-----------------|
| 1. Base | `agents/{role}/profile.md` | Role definition, rules (what/why) | Stable |
| 2. Domain | `domains/{domain}/{role}.md` | Domain-specific supplement (optional) | Per domain |
| 3. Project | `projects/{name}/team/{role}.md` | Project-specific supplement (optional) | Per project |

Each layer **supplements** the previous one. Never replaces.

Methods are separated:
| File | Content |
|------|---------|
| `techniques/*.md` | Natural language procedures (how) — freely improvable |

</details>

---

## Multi-Project

One framework runs multiple projects simultaneously. Each project gets isolated workspace, memory, logs, and reports.

<details>
<summary>Details</summary>

- Paths like `workspace/`, `memory/`, `reports/` in agent docs resolve relative to the current project
- Each project gets its own tmux session (`whiplash-{project}`)
- Cross-project references use explicit full paths: `projects/{other}/memory/knowledge/...`

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

Adding a new domain:
1. Create `domains/{domain-name}/` folder
2. Write `context.md` — domain background, concepts, terminology, quality criteria
3. (Optional) Write `{role}.md` — role-specific domain guidelines
4. Set domain in project's `project.md`

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
| Role-based File Access | Project code modifiable only by Developer. Enforced via --allowedTools |
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
