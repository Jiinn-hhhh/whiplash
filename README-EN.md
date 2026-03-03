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

| Agent | Role | Model |
|-------|------|-------|
| **Onboarding** | Designs projects via user conversation. Creates project.md, hands off to Manager | - |
| **Manager** | User ↔ team hub. Agent lifecycle, task distribution, coordination, reporting | sonnet |
| **Researcher** | Source collection/analysis, experiments (prototype-level), direction proposals | opus |
| **Developer** | Production code, architecture design, infrastructure | sonnet |
| **Monitoring** | Independent observer. Infra/environment health checks | haiku |

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

<details>
<summary>Boot flow</summary>

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

Per-agent boot process:
1. `claude -p "{boot_message}" --output-format json` → session_id
2. `tmux new-window -n {role}` → window created
3. `claude --resume {session_id}` → interactive session starts
4. Recorded in `sessions.md`

</details>

<details>
<summary>Communication</summary>

| Channel | Purpose | Method |
|---------|---------|--------|
| **Notify** (notify.sh) | Real-time status delivery | tmux direct delivery (fire-and-forget) |
| **Discussions** (DISC-NNN.md) | Structured discussion | Markdown append-only |
| **Meetings** (MEET-NNN.md) | 3-round debate | Position → response → synthesis |
| **Announcements** (announcements/) | Task directives | Markdown files |

Notification types: task_complete, status_update, need_input, escalation, agent_ready, reboot_notice, consensus_request

</details>

<details>
<summary>Task execution</summary>

1. Manager writes directive → `orchestrator.sh dispatch {role} {task-file}`
2. Delivered to agent via tmux send-keys
3. Agent completes → reports task_complete via notify.sh
4. Dual mode: `dual-dispatch` to both backends → Manager drives consensus

</details>

<details>
<summary>Dynamic spawn</summary>

Spawn an additional instance of the same role when an agent is busy:

```bash
orchestrator.sh spawn researcher researcher-2 myproject     # spawn
orchestrator.sh kill-agent researcher-2 myproject            # terminate
```

- Shares the same project memory/workspace. No concurrent edits to the same file
- monitor.sh automatically watches spawned agents (including crash reboot)

</details>

<details>
<summary>Failure recovery</summary>

`monitor.sh` is a 30-second health-check daemon:

- **Crash detection**: tmux window disappearance → `orchestrator.sh reboot` (max 3 attempts)
- **Hung detection**: 10-minute inactivity → one-time alert to Manager (no auto-kill)
- **Heartbeat**: writes timestamp every 30s. If 90s+ stale → zombie verdict → restart
- **Session refresh**: when context grows too large, `orchestrator.sh refresh` → handoff to new session

</details>

<details>
<summary>CLI commands (Manager-internal)</summary>

These are run internally by the Manager agent. Users do not run them directly.

```bash
# Boot/Shutdown
orchestrator.sh boot-manager   {project}
orchestrator.sh boot           {project}
orchestrator.sh shutdown       {project}

# Tasks
orchestrator.sh dispatch       {role} {task-file} {project}
orchestrator.sh dual-dispatch  {role} {task-file} {project}

# Dynamic Spawn
orchestrator.sh spawn          {role} {window-name} {project}
orchestrator.sh kill-agent     {window-name} {project}

# Recovery/Management
orchestrator.sh reboot         {target} {project}
orchestrator.sh refresh        {target} {project}
orchestrator.sh status         {project}
orchestrator.sh monitor-check  {project}
```

</details>

---

## Logging

Infrastructure scripts automatically log to `logs/`. Agents are unaware of logging.

| File | Content |
|------|---------|
| `logs/system.log` | Infrastructure events (boot/shutdown/crash/dispatch etc.) |
| `logs/message.log` | Agent-to-agent message delivery history |

<details>
<summary>system.log example</summary>

```
2026-03-03 18:44:35 [info] test-project 프로젝트 부팅 시작 mode=solo
2026-03-03 18:44:35 [info] researcher 부팅 session=abc-123
2026-03-03 18:44:35 [info] developer 부팅 session=def-456
2026-03-03 18:44:35 [error] monitoring 부팅 실패 reason=claude -p execution failed
2026-03-03 18:44:35 [info] 모니터 시작 pid=12345
2026-03-03 18:44:35 [info] researcher 태스크 전달 task=TASK-001.md
2026-03-03 18:44:35 [warn] developer 크래시 감지 count=0/3
2026-03-03 18:44:35 [info] developer 리부팅 성공 count=1/3
2026-03-03 18:44:35 [error] developer 리부팅 실패 count=2/3
2026-03-03 18:44:35 [error] developer 리부팅 한도 초과 count=3/3
2026-03-03 18:44:35 [warn] researcher 비활성 감지 idle_min=12
2026-03-03 18:44:35 [info] researcher 활동 재개
2026-03-03 18:44:35 [info] test-project 프로젝트 종료
```

</details>

<details>
<summary>message.log example</summary>

```
2026-03-03 18:44:35 [delivered] researcher → manager "TASK-001 completed"
2026-03-03 18:44:35 [delivered] developer → manager "TASK-002 implemented"
2026-03-03 18:44:35 [skipped] manager → researcher "Direction choice needed" reason="no claude process"
2026-03-03 18:44:35 [skipped] monitor → manager "developer crash" reason="no window"
```

</details>

<details>
<summary>Filtering with grep</summary>

```bash
# Errors only
grep "\[error\]" logs/system.log

# Crash/reboot history
grep -E "크래시|리부팅" logs/system.log

# Failed messages
grep "skipped" logs/message.log

# Specific agent
grep "researcher" logs/system.log
```

</details>

<details>
<summary>Auto log level</summary>

Level is auto-determined by event type:

| Level | Events |
|-------|--------|
| **error** | Boot failure, reboot failure, reboot limit, monitor exit, monitor zombie |
| **warn** | Crash detected, hung detected, agent kill, monitor restart, session absent, notify delivery failure |
| **info** | Everything else (boot, dispatch, shutdown — normal operations) |

Override with `--level` option.

</details>

<details>
<summary>Rotation</summary>

Each log file auto-rotates when exceeding 10MB:

```
system.log      ← current
system.log.1    ← previous
system.log.2    ← older
system.log.3    ← oldest (deleted after)
```

Concurrent write protection: `fcntl.flock()` ensures safety when multiple scripts write simultaneously.

</details>

---

## Project Structure

```
whiplash/
├── agents/                      # Agent definitions (immutable, git tracked)
├── domains/                     # Domain-specific definitions (git tracked)
├── scripts/                     # Infrastructure scripts (orchestrator, monitor, notify, log)
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
