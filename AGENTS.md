# Repository Guidelines

## Project Structure & Module Organization
This repository is documentation-first and organized into three top-level folders:
- `agents/`: core framework definitions (tracked). Each role has `profile.md` and `techniques/` docs.
- `domains/`: domain-specific context (tracked), e.g. `domains/deep-learning/`.
- `projects/`: runtime project data (gitignored except `.gitkeep`).

Keep framework changes in `agents/` and `domains/`. Do not commit runtime artifacts under `projects/`.

## Build, Test, and Development Commands
There is no build pipeline or package manager in this repo. Use lightweight checks:
- `rg --files agents domains` — list managed docs and verify expected files exist.
- `find agents domains -name '*.md'` — inspect Markdown coverage before PRs.
- `git status --short` — confirm only intended files are staged.
- `git log --oneline -n 10` — review recent commit style before writing commit messages.

## Coding Style & Naming Conventions
- Write documentation in Markdown with clear heading hierarchy (`#`, `##`, `###`).
- Prefer concise, directive sentences and stable terminology across files.
- Keep existing language convention: framework docs are primarily in Korean.
- Use kebab-case for technique filenames (e.g. `knowledge-management.md`).
- Use role/domain path patterns exactly: `agents/{role}/...`, `domains/{domain}/...`.

## Testing Guidelines
No automated test suite exists. Treat validation as document integrity checks:
- Verify internal paths and referenced files exist.
- Ensure structural consistency with templates in `agents/common/`.
- When updating process docs, check related role docs for conflicts.

## Commit & Pull Request Guidelines
Recent history uses short, imperative, sentence-style commits (e.g. `Add Onboarding agent for conversational project design`). Follow the same pattern:
- Start with a verb (`Add`, `Refactor`, `Update`).
- Keep subject focused on one logical change.

For pull requests:
- Include a concise summary of changed paths and rationale.
- Link related issues/tasks when available.
- Note any cross-file consistency updates (especially `agents/common/` impacts).
- Add before/after snippets only when wording or structure changes are non-obvious.

## Security & Configuration Tips
- Respect `.gitignore`: `projects/*` is runtime state and should remain untracked.
- Avoid embedding secrets or project-specific private data in framework docs.
