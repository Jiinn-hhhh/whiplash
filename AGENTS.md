# Repository Guidelines

## Immediate Start Instructions (Codex Session Start)

You are Whiplash framework's **Onboarding agent** by default.

### First Action
1. Check the `projects/` directory.
2. If existing projects are present, show the list and ask:
   "기존 프로젝트를 이어할까, 새 프로젝트를 시작할까?"
3. If no project exists, start new-project onboarding.

### Role Activation
- Onboarding procedure: `agents/onboarding/techniques/project-design.md`
- Role definition: `agents/onboarding/profile.md`
- If the user explicitly specifies another agent role, read `agents/{role}/profile.md` and switch to that role.

## Project Structure & Module Organization
Whiplash is a document-driven multi-agent framework. Core framework paths are `agents/`, `domains/`, `scripts/`, `dashboard/`, `feedback/`, and `projects/`. Agent role definitions and operating rules live under `agents/<role>/`; domain-specific guidance lives in `domains/`. Shell orchestration is in `scripts/`, and the Rich TUI dashboard is in `dashboard/`. Runtime project state is generated under `projects/<project-name>/` and should be treated as project data, not framework source. Nearby folders such as `pixel-agents/` and `system_develop/` are auxiliary experiments.

## Build, Test, and Development Commands
Run commands from the repository root.

- `bash scripts/preflight.sh <project> --mode solo`: validates local dependencies and project structure before boot.
- `bash scripts/cmd.sh boot-onboarding <project>`: creates a tmux session and starts onboarding.
- `bash scripts/cmd.sh boot-manager <project>`: starts Manager directly for an existing project.
- `python3 dashboard/dashboard.py <project> --interval 3`: runs the dashboard manually.
- `bash scripts/integration-test.sh`: runs tmux-based integration coverage for orchestration, monitoring, and dashboard flows.

Install baseline tools before contributing: `tmux`, `jq`, `python3`, `pip install rich`, and optionally Codex CLI for dual mode.

## Coding Style & Naming Conventions
Use 4-space indentation in Python and POSIX-friendly Bash in `scripts/*.sh`. Prefer descriptive, kebab-case shell filenames such as `preflight.sh` and `integration-test.sh`. Keep agent and domain docs concise, operational, and Markdown-first. Match existing terminology exactly: `systems-engineer`, `boot-onboarding`, `boot-manager`, `task_assign`, and similar runtime labels are contract-like names.

## Testing Guidelines
Primary validation is integration-heavy rather than unit-heavy. Add or update scenarios in `scripts/integration-test.sh` when changing orchestration, tmux routing, dashboard parsing, monitor behavior, or queue delivery. For dashboard-only changes, also run `python3 dashboard/dashboard.py <project>` against a sample project. Name Python tests `test_*.py` if you add dedicated tests.

## Commit & Pull Request Guidelines
Recent history favors short, imperative commit subjects such as `Wire onboarding bootstrap and systems support` or `Fix dashboard agent and monitor status detection`. Keep commits focused and describe the behavioral change, not the implementation details. PRs should include: purpose, affected paths, verification commands run, and screenshots or terminal snippets for dashboard or tmux-visible changes.

## Security & Configuration Tips
Do not commit secrets, API tokens, or generated runtime state. Treat files under `projects/*/runtime`, `projects/*/logs`, and `.storage/` as ephemeral unless a change explicitly targets fixtures or documentation.
