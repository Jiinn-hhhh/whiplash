#!/usr/bin/env python3

from __future__ import annotations

import argparse
import copy
import json
import os
import re
import sys
import tempfile
from pathlib import Path


ROLE_ORDER = [
    "onboarding",
    "manager",
    "discussion",
    "developer",
    "researcher",
    "systems-engineer",
    "monitoring",
]
CONTROL_PLANE_ROLES = {"onboarding", "manager", "discussion"}
DUAL_ROLES = {"developer", "researcher"}

START_MARKER = "<!-- WHIPLASH_EXECUTION_CONFIG:START -->"
END_MARKER = "<!-- WHIPLASH_EXECUTION_CONFIG:END -->"

PRESET_ALIASES = {
    "default": "default",
    "claude": "claude-only",
    "claude-only": "claude-only",
    "claude_only": "claude-only",
    "claudeonly": "claude-only",
    "claude only": "claude-only",
    "codex": "codex-only",
    "codex-only": "codex-only",
    "codex_only": "codex-only",
    "codexonly": "codex-only",
    "codex only": "codex-only",
    "dual": "dual",
}
BACKEND_ALIASES = {
    "claude": "claude",
    "codex": "codex",
}


class ExecutionConfigError(RuntimeError):
    pass


def _repo_root_from_path(path: Path) -> Path:
    return path.resolve().parents[1]


def _project_md_path(repo_root: Path, project: str) -> Path:
    return repo_root / "projects" / project / "project.md"


def _read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def _write_text_atomic(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False, dir=path.parent) as tmp:
        tmp.write(text)
        tmp_path = Path(tmp.name)
    os.replace(tmp_path, path)


def _normalize_spaces(value: str) -> str:
    return re.sub(r"\s+", " ", value.strip())


def normalize_preset(value: str | None) -> str | None:
    if not value:
        return None
    cleaned = re.sub(r"[`*|]", "", value).strip().lower()
    cleaned = cleaned.replace("_", " ").replace("-", " ")
    cleaned = _normalize_spaces(cleaned)
    return PRESET_ALIASES.get(cleaned)


def normalize_backend(value: str | None) -> str | None:
    if not value:
        return None
    cleaned = re.sub(r"[`*|]", "", value).strip().lower()
    cleaned = _normalize_spaces(cleaned)
    return BACKEND_ALIASES.get(cleaned)


def _fallback_claude_model(role: str) -> str:
    return "haiku" if role == "monitoring" else "opus"


def _profile_model(repo_root: Path, role: str) -> str:
    profile = repo_root / "agents" / role / "profile.md"
    if profile.exists():
        for line in profile.read_text(encoding="utf-8").splitlines():
            match = re.match(r"^model:\s*(\S+)\s*$", line.strip())
            if match:
                return match.group(1)
    return _fallback_claude_model(role)


def _codex_default_model(repo_root: Path) -> str:
    for path in (repo_root / ".codex" / "config.toml", Path.home() / ".codex" / "config.toml"):
        if not path.exists():
            continue
        for line in path.read_text(encoding="utf-8").splitlines():
            match = re.match(r'^model\s*=\s*"([^"]+)"\s*$', line.strip())
            if match:
                return match.group(1)
    return "codex"


def default_baseline(repo_root: Path) -> dict[str, dict[str, object]]:
    codex_model = _codex_default_model(repo_root)
    baseline: dict[str, dict[str, object]] = {}
    for role in ROLE_ORDER:
        baseline[role] = {
            "solo_backend": "codex" if role in CONTROL_PLANE_ROLES else "claude",
            "models": {
                "claude": _profile_model(repo_root, role),
                "codex": codex_model,
            },
        }
    return baseline


def _parse_active_agents(text: str) -> list[str]:
    for line in text.splitlines():
        if "활성 에이전트" not in line and "active agents" not in line.lower():
            continue
        if ":" not in line:
            continue
        raw = line.split(":", 1)[1]
        values = [
            part.strip().lower()
            for part in raw.split(",")
            if part.strip()
        ]
        return values
    return []


def _parse_field(text: str, aliases: list[str]) -> str | None:
    alias_set = {alias.lower() for alias in aliases}
    for line in text.splitlines():
        match = re.match(r"^-\s+(.+?):\s*(.+)$", line.strip())
        if not match:
            continue
        key = re.sub(r"[`*|]", "", match.group(1)).strip().lower()
        value = re.sub(r"[`*|]", "", match.group(2)).strip()
        if key in alias_set:
            return value
    return None


def _extract_json_block(text: str) -> dict[str, object] | None:
    if START_MARKER not in text or END_MARKER not in text:
        return None
    block = text.split(START_MARKER, 1)[1].split(END_MARKER, 1)[0]
    block = block.strip()
    if block.startswith("```"):
        parts = block.splitlines()
        if len(parts) >= 2 and parts[0].startswith("```"):
            parts = parts[1:]
        if parts and parts[-1].startswith("```"):
            parts = parts[:-1]
        block = "\n".join(parts).strip()
    if not block:
        return None
    try:
        loaded = json.loads(block)
    except json.JSONDecodeError as exc:
        raise ExecutionConfigError(f"execution config JSON parse failed: {exc}") from exc
    if not isinstance(loaded, dict):
        raise ExecutionConfigError("execution config block must decode to an object")
    return loaded


def _legacy_config(text: str, repo_root: Path) -> dict[str, object]:
    baseline = default_baseline(repo_root)
    exec_preset = normalize_preset(_parse_field(text, ["실행 프리셋", "execution preset"]))
    legacy_mode = _parse_field(text, ["실행 모드", "execution mode"])
    manager_backend = normalize_backend(_parse_field(text, ["control-plane 백엔드", "control-plane backend"]))

    current_preset = exec_preset or ("dual" if (legacy_mode or "").strip().lower() == "dual" else "default")
    current_overrides: dict[str, dict[str, object]] = {}
    if manager_backend == "claude":
        for role in CONTROL_PLANE_ROLES:
            current_overrides[role] = {"backend": "claude"}

    return {
        "version": 1,
        "current_preset": current_preset,
        "baseline": baseline,
        "current_overrides": current_overrides,
    }


def _normalize_models(base: dict[str, object] | None, fallback: dict[str, str]) -> dict[str, str]:
    models = dict(fallback)
    if isinstance(base, dict):
        for backend in ("claude", "codex"):
            value = base.get(backend)
            if isinstance(value, str) and value.strip():
                models[backend] = value.strip()
    return models


def _normalize_role_config(role: str, role_cfg: dict[str, object] | None, fallback: dict[str, object]) -> dict[str, object]:
    cfg = dict(fallback)
    if isinstance(role_cfg, dict):
        backend = normalize_backend(role_cfg.get("solo_backend"))
        if backend:
            cfg["solo_backend"] = backend
        elif normalize_backend(role_cfg.get("backend")):
            cfg["solo_backend"] = normalize_backend(role_cfg.get("backend"))
        cfg["models"] = _normalize_models(role_cfg.get("models"), cfg["models"])  # type: ignore[arg-type]
    return cfg


def normalize_config(raw: dict[str, object], repo_root: Path) -> dict[str, object]:
    defaults = default_baseline(repo_root)
    baseline_raw = raw.get("baseline") if isinstance(raw, dict) else None
    overrides_raw = raw.get("current_overrides") if isinstance(raw, dict) else None

    baseline: dict[str, dict[str, object]] = {}
    for role in ROLE_ORDER:
        role_raw = baseline_raw.get(role) if isinstance(baseline_raw, dict) else None
        baseline[role] = _normalize_role_config(role, role_raw, defaults[role])

    overrides: dict[str, dict[str, object]] = {}
    if isinstance(overrides_raw, dict):
        for role, override in overrides_raw.items():
            if role not in ROLE_ORDER or not isinstance(override, dict):
                continue
            role_override: dict[str, object] = {}
            backend = normalize_backend(override.get("backend"))
            if backend:
                role_override["backend"] = backend
            models = _normalize_models(override.get("models"), {})
            if models:
                role_override["models"] = models
            if role_override:
                overrides[role] = role_override

    preset = normalize_preset(raw.get("current_preset") if isinstance(raw, dict) else None) or "default"
    return {
        "version": 1,
        "current_preset": preset,
        "baseline": baseline,
        "current_overrides": overrides,
    }


def load_config(project_md: Path, repo_root: Path) -> dict[str, object]:
    text = _read_text(project_md)
    block = _extract_json_block(text)
    raw = block if block is not None else _legacy_config(text, repo_root)
    return normalize_config(raw, repo_root)


def _effective_models(cfg: dict[str, object], role: str) -> dict[str, str]:
    baseline = cfg["baseline"][role]  # type: ignore[index]
    models = copy.deepcopy(baseline["models"])  # type: ignore[index]
    override = cfg["current_overrides"].get(role, {})  # type: ignore[index]
    if isinstance(override, dict):
        models.update(override.get("models", {}))
    return models


def resolve_role(cfg: dict[str, object], role: str) -> dict[str, object]:
    if role not in ROLE_ORDER:
        raise ExecutionConfigError(f"unsupported role: {role}")

    preset = cfg["current_preset"]  # type: ignore[index]
    baseline = cfg["baseline"][role]  # type: ignore[index]
    override = cfg["current_overrides"].get(role, {})  # type: ignore[index]
    override_backend = normalize_backend(override.get("backend")) if isinstance(override, dict) else None
    models = _effective_models(cfg, role)

    if preset == "claude-only":
        windows = [{"window_name": role, "backend": "claude", "model": models["claude"]}]
        effective_mode = "single"
    elif preset == "codex-only":
        windows = [{"window_name": role, "backend": "codex", "model": models["codex"]}]
        effective_mode = "single"
    elif preset == "dual" and role in DUAL_ROLES:
        windows = [
            {"window_name": f"{role}-claude", "backend": "claude", "model": models["claude"]},
            {"window_name": f"{role}-codex", "backend": "codex", "model": models["codex"]},
        ]
        effective_mode = "dual"
    else:
        backend = override_backend or normalize_backend(baseline.get("solo_backend")) or ("codex" if role in CONTROL_PLANE_ROLES else "claude")
        windows = [{"window_name": role, "backend": backend, "model": models[backend]}]
        effective_mode = "single"

    return {
        "role": role,
        "current_preset": preset,
        "effective_mode": effective_mode,
        "baseline_backend": normalize_backend(baseline.get("solo_backend")),
        "override_backend": override_backend,
        "models": models,
        "windows": windows,
    }


def _summary_values(cfg: dict[str, object]) -> dict[str, str]:
    manager = resolve_role(cfg, "manager")
    return {
        "execution_preset": cfg["current_preset"],  # type: ignore[index]
        "execution_mode": "dual" if cfg["current_preset"] == "dual" else "solo",  # type: ignore[index]
        "control_plane_backend": manager["windows"][0]["backend"],  # type: ignore[index]
    }


def required_backends(cfg: dict[str, object], active_agents: list[str], include_onboarding: bool = False) -> list[str]:
    roles = {"manager", "discussion"}
    roles.update(role for role in active_agents if role in ROLE_ORDER)
    if include_onboarding:
        roles.add("onboarding")
    found: set[str] = set()
    for role in roles:
        resolved = resolve_role(cfg, role)
        for win in resolved["windows"]:  # type: ignore[index]
            found.add(win["backend"])
    return sorted(found)


def _render_block(cfg: dict[str, object]) -> str:
    rendered = json.dumps(cfg, ensure_ascii=False, indent=2, sort_keys=True)
    return f"{START_MARKER}\n```json\n{rendered}\n```\n{END_MARKER}"


def _find_section(lines: list[str], headings: tuple[str, ...]) -> tuple[int, int] | None:
    start = None
    for idx, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("## "):
            title = stripped[3:]
            if title in headings:
                start = idx
                continue
            if start is not None:
                return start, idx
    if start is not None:
        return start, len(lines)
    return None


def _parse_bullet_label(line: str) -> str | None:
    match = re.match(r"^-\s+(.+?):\s*(.+)$", line.strip())
    if not match:
        return None
    return re.sub(r"[`*|]", "", match.group(1)).strip().lower()


def _upsert_summary_fields(text: str, cfg: dict[str, object]) -> str:
    lines = text.splitlines()
    section = _find_section(lines, ("운영 방식", "Operating Style"))
    summary = _summary_values(cfg)
    if section is None:
        rendered_lines = [
            "## 운영 방식",
            f"- **실행 프리셋**: {summary['execution_preset']}",
            f"- **실행 모드**: {summary['execution_mode']}",
            f"- **control-plane 백엔드**: {summary['control_plane_backend']}",
        ]
        base = text.rstrip("\n")
        if base:
            base += "\n\n"
        return base + "\n".join(rendered_lines) + "\n"
    start, end = section
    content = lines[start + 1:end]
    aliases = {
        "execution_preset": {"실행 프리셋", "execution preset"},
        "execution_mode": {"실행 모드", "execution mode"},
        "control_plane_backend": {"control-plane 백엔드", "control-plane backend"},
    }
    removable = {alias.lower() for names in aliases.values() for alias in names}
    filtered = [line for line in content if (_parse_bullet_label(line) or "") not in removable]
    new_lines = [
        f"- **실행 프리셋**: {summary['execution_preset']}",
        f"- **실행 모드**: {summary['execution_mode']}",
        f"- **control-plane 백엔드**: {summary['control_plane_backend']}",
    ]
    lines[start + 1:end] = new_lines + filtered
    return "\n".join(lines) + ("\n" if text.endswith("\n") else "")


def _insert_or_replace_block(text: str, cfg: dict[str, object]) -> str:
    block = _render_block(cfg)
    if START_MARKER in text and END_MARKER in text:
        pattern = re.compile(
            re.escape(START_MARKER) + r".*?" + re.escape(END_MARKER),
            re.DOTALL,
        )
        return pattern.sub(block, text, count=1)

    lines = text.splitlines()
    section = _find_section(lines, ("운영 방식", "Operating Style"))
    insert_at = len(lines)
    if section is not None:
        _, end = section
        insert_at = end
    block_lines = block.splitlines()
    new_lines = lines[:insert_at] + [""] + block_lines + [""] + lines[insert_at:]
    rendered = "\n".join(new_lines)
    return rendered + ("\n" if text.endswith("\n") or not rendered.endswith("\n") else "")


def save_config(project_md: Path, cfg: dict[str, object]) -> None:
    text = _read_text(project_md)
    updated = _upsert_summary_fields(text, cfg)
    updated = _insert_or_replace_block(updated, cfg)
    _write_text_atomic(project_md, updated)


def build_show_payload(project: str, project_md: Path, repo_root: Path, include_onboarding: bool = False) -> dict[str, object]:
    text = _read_text(project_md)
    cfg = load_config(project_md, repo_root)
    active_agents = _parse_active_agents(text)
    roles = {role: resolve_role(cfg, role) for role in ROLE_ORDER}
    payload = {
        "project": project,
        "project_md": str(project_md),
        "current_preset": cfg["current_preset"],
        "exec_mode": "dual" if cfg["current_preset"] == "dual" else "solo",
        "baseline": cfg["baseline"],
        "current_overrides": cfg["current_overrides"],
        "active_agents": active_agents,
        "control_plane_backend": roles["manager"]["windows"][0]["backend"],
        "required_backends": required_backends(cfg, active_agents, include_onboarding=include_onboarding),
        "roles": roles,
    }
    return payload


def _validate_role(role: str) -> str:
    if role not in ROLE_ORDER:
        raise ExecutionConfigError(f"unsupported role: {role}")
    return role


def _mutate_role_backend(cfg: dict[str, object], role: str, backend: str, scope: str) -> None:
    role = _validate_role(role)
    backend = normalize_backend(backend)
    if backend is None:
        raise ExecutionConfigError(f"unsupported backend: {backend}")
    if scope == "baseline":
        cfg["baseline"][role]["solo_backend"] = backend  # type: ignore[index]
        return
    overrides = cfg.setdefault("current_overrides", {})
    role_override = overrides.setdefault(role, {})
    role_override["backend"] = backend


def _mutate_role_model(cfg: dict[str, object], role: str, backend: str, model: str, scope: str) -> None:
    role = _validate_role(role)
    backend = normalize_backend(backend)
    if backend is None:
        raise ExecutionConfigError(f"unsupported backend: {backend}")
    if not model.strip():
        raise ExecutionConfigError("model must be non-empty")
    if scope == "baseline":
        cfg["baseline"][role]["models"][backend] = model.strip()  # type: ignore[index]
        return
    overrides = cfg.setdefault("current_overrides", {})
    role_override = overrides.setdefault(role, {})
    models = role_override.setdefault("models", {})
    models[backend] = model.strip()


def _mutate_reset_role(cfg: dict[str, object], role: str, scope: str) -> None:
    role = _validate_role(role)
    if scope == "baseline":
        repo_root = _repo_root_from_path(Path(__file__))
        defaults = default_baseline(repo_root)
        cfg["baseline"][role] = copy.deepcopy(defaults[role])  # type: ignore[index]
        return
    cfg.setdefault("current_overrides", {}).pop(role, None)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Whiplash execution config helper")
    parser.add_argument("--repo-root", dest="repo_root", default=None)
    sub = parser.add_subparsers(dest="cmd", required=True)

    show = sub.add_parser("show")
    show.add_argument("--project", required=True)
    show.add_argument("--include-onboarding", action="store_true")

    set_preset = sub.add_parser("set-preset")
    set_preset.add_argument("--project", required=True)
    set_preset.add_argument("--preset", required=True)

    set_role_backend = sub.add_parser("set-role-backend")
    set_role_backend.add_argument("--project", required=True)
    set_role_backend.add_argument("--role", required=True)
    set_role_backend.add_argument("--backend", required=True)
    set_role_backend.add_argument("--scope", choices=["baseline", "current"], default="current")

    set_role_model = sub.add_parser("set-role-model")
    set_role_model.add_argument("--project", required=True)
    set_role_model.add_argument("--role", required=True)
    set_role_model.add_argument("--backend", required=True)
    set_role_model.add_argument("--model", required=True)
    set_role_model.add_argument("--scope", choices=["baseline", "current"], default="current")

    reset_role = sub.add_parser("reset-role")
    reset_role.add_argument("--project", required=True)
    reset_role.add_argument("--role", required=True)
    reset_role.add_argument("--scope", choices=["baseline", "current"], default="current")

    args = parser.parse_args(argv)
    repo_root = Path(args.repo_root).resolve() if args.repo_root else _repo_root_from_path(Path(__file__))
    project_md = _project_md_path(repo_root, args.project)
    if not project_md.exists():
        raise ExecutionConfigError(f"project.md not found: {project_md}")

    if args.cmd == "show":
        payload = build_show_payload(args.project, project_md, repo_root, include_onboarding=args.include_onboarding)
        print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))
        return 0

    cfg = load_config(project_md, repo_root)
    if args.cmd == "set-preset":
        preset = normalize_preset(args.preset)
        if preset is None:
            raise ExecutionConfigError(f"unsupported preset: {args.preset}")
        cfg["current_preset"] = preset
    elif args.cmd == "set-role-backend":
        _mutate_role_backend(cfg, args.role, args.backend, args.scope)
    elif args.cmd == "set-role-model":
        _mutate_role_model(cfg, args.role, args.backend, args.model, args.scope)
    elif args.cmd == "reset-role":
        _mutate_reset_role(cfg, args.role, args.scope)
    else:
        raise ExecutionConfigError(f"unsupported command: {args.cmd}")

    cfg = normalize_config(cfg, repo_root)
    save_config(project_md, cfg)
    payload = build_show_payload(args.project, project_md, repo_root)
    print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except ExecutionConfigError as exc:
        print(f"execution-config: {exc}", file=sys.stderr)
        raise SystemExit(1)
