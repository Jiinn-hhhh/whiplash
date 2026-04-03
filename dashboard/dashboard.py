#!/usr/bin/env python3
"""Whiplash 라이브 대시보드 — Rich Live TUI.

Usage:
  python3 dashboard/dashboard.py {project}              # 기본 5초 갱신
  python3 dashboard/dashboard.py {project} --interval 2 # 2초 갱신
"""

import argparse
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import unicodedata
from collections import Counter
from datetime import datetime, timedelta, timezone
from glob import glob
from typing import Any

try:
    from rich.console import Console
    from rich.console import Group
    from rich.layout import Layout
    from rich.live import Live
    from rich.panel import Panel
    from rich.table import Table
    from rich.text import Text
except ImportError:
    Console = Group = Layout = Live = Panel = Table = Text = None

# ──────────────────────────────────────────────
# 상수
# ──────────────────────────────────────────────

_KST = timezone(timedelta(hours=9))

_ROLE_ABBR = {
    "manager": "mgr",
    "discussion": "dis",
    "developer": "dev",
    "researcher": "res",
    "systems-engineer": "sys",
    "monitoring": "mon",
    "monitor": "mon",
}

_ROLE_FULL = {
    "mgr": "manager", "dis": "discussion", "dev": "developer", "res": "researcher",
    "sys": "systems-engineer", "mon": "monitoring",
}

_RECENT_ACTIVITY_WINDOW_SEC = 180

# ──────────────────────────────────────────────
# 유틸리티
# ──────────────────────────────────────────────

def cell_len(s: str) -> int:
    """동아시아 넓은 문자(W/F)를 2로, 나머지를 1로 계산한 표시 폭 반환."""
    width = 0
    for ch in s:
        eaw = unicodedata.east_asian_width(ch)
        width += 2 if eaw in ("W", "F") else 1
    return width


# mtime 캐시: path -> (mtime, parsed_data)
_task_file_cache: dict[str, tuple[float, Any]] = {}

def _repo_root() -> str:
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        print("Error: git not found or not in a git repository.", file=sys.stderr)
        sys.exit(1)


def _now_kst() -> datetime:
    return datetime.now(_KST)


def _format_elapsed(seconds: int) -> str:
    """경과 시간을 짧게 표시."""
    if seconds < 0:
        return "--"
    h, rem = divmod(seconds, 3600)
    m = rem // 60
    if h > 0:
        return f"{h}h {m}m"
    return f"{m}m"


def _read_file(path: str) -> str | None:
    """파일 읽기, 없으면 None."""
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return None


def _read_tail(path: str, lines: int) -> list[str]:
    """파일 마지막 N줄 읽기."""
    try:
        with open(path) as f:
            all_lines = f.readlines()
        return [l.rstrip("\n") for l in all_lines[-lines:]]
    except OSError:
        return []


def _read_tsv_map(path: str) -> dict[str, str]:
    """2열 TSV를 key -> value로 읽기."""
    rows: dict[str, str] = {}
    try:
        with open(path) as f:
            for raw in f:
                line = raw.rstrip("\n")
                if not line:
                    continue
                parts = line.split("\t", 1)
                if len(parts) != 2 or not parts[0]:
                    continue
                rows[parts[0]] = parts[1]
    except OSError:
        return {}
    return rows


def _read_tsv_rows(path: str) -> list[list[str]]:
    """TSV 전체 행 읽기."""
    rows: list[list[str]] = []
    try:
        with open(path) as f:
            for raw in f:
                line = raw.rstrip("\n")
                if not line:
                    continue
                rows.append(line.split("\t"))
    except OSError:
        return []
    return rows



def _clean_project_value(value: str) -> str:
    value = value.replace("**", "").replace("`", "").strip()
    return re.sub(r"\s+\(.*\)$", "", value).strip()


def _parse_project_heading(line: str) -> str | None:
    match = re.match(r"^#\s+(.+)$", line)
    if not match:
        return None
    title = match.group(1).strip()
    if ":" in title:
        key, value = title.split(":", 1)
        if key.strip().lower() in {"project", "프로젝트"}:
            return _clean_project_value(value)
    return _clean_project_value(title)


def _parse_project_field(line: str) -> tuple[str, str] | None:
    match = re.match(r"^-\s+(.+?):\s*(.+)$", line)
    if not match:
        return None
    key = _clean_project_value(match.group(1)).lower()
    value = _clean_project_value(match.group(2))
    if "domain" in key or "도메인" in key:
        return "domain", value
    if "execution preset" in key or "실행 프리셋" in key:
        return "preset", value
    if "execution mode" in key or "실행 모드" in key:
        return "mode", value
    if "control-plane backend" in key or "control-plane 백엔드" in key:
        return "control_plane_backend", value
    if "loop mode" in key or "작업 루프" in key:
        return "loop_mode", value
    return None


def _require_rich() -> None:
    if None in (Console, Group, Layout, Live, Panel, Table, Text):
        print("rich 라이브러리가 필요합니다: pip install rich", file=sys.stderr)
        sys.exit(1)


def _build_console() -> Console:
    """tmux 안에서는 NO_COLOR가 설정돼 있어도 컬러 TUI를 유지한다."""
    return Console(
        force_terminal=True,
        color_system="truecolor",
        no_color=False,
    )


# ──────────────────────────────────────────────
# 파서
# ──────────────────────────────────────────────

def parse_project_md(project_dir: str) -> dict[str, str]:
    """project.md에서 프로젝트 이름, 도메인, 실행/루프 모드 추출."""
    content = _read_file(os.path.join(project_dir, "project.md"))
    info: dict[str, str] = {
        "name": os.path.basename(os.path.normpath(project_dir)),
        "preset": "",
        "mode": "pending",
        "loop_mode": "guided",
        "domain": "general",
        "control_plane_backend": "",
    }
    if not content:
        return info

    for line in content.splitlines():
        name = _parse_project_heading(line)
        if name:
            info["name"] = name
            continue
        field = _parse_project_field(line)
        if not field:
            continue
        key, value = field
        if key == "preset":
            lowered = value.lower()
            if "pending" in lowered or "미정" in value:
                info["preset"] = "pending"
            else:
                info["preset"] = lowered.replace("_", "-").replace(" ", "-")
        elif key == "mode":
            if "dual" in value.lower():
                info["mode"] = "dual"
            elif "pending" in value.lower() or "미정" in value:
                info["mode"] = "pending"
            else:
                info["mode"] = "solo"
        elif key == "control_plane_backend":
            lowered = value.lower()
            if "claude" in lowered:
                info["control_plane_backend"] = "claude"
            elif "codex" in lowered:
                info["control_plane_backend"] = "codex"
            elif "pending" in lowered or "미정" in value:
                info["control_plane_backend"] = "pending"
        elif key == "loop_mode":
            lowered = value.lower()
            if "ralph" in lowered:
                info["loop_mode"] = "ralph"
            elif "pending" in lowered or "미정" in value:
                info["loop_mode"] = "pending"
            else:
                info["loop_mode"] = "guided"
        elif key == "domain" and value:
            info["domain"] = value

    return info


def parse_project_phase(project_dir: str) -> str:
    """project.md의 '현재 상태' 섹션에서 첫 의미 있는 줄 추출."""
    content = _read_file(os.path.join(project_dir, "project.md"))
    if not content:
        return ""
    in_section = False
    for line in content.splitlines():
        if re.match(r"^##\s*현재 상태", line):
            in_section = True
            continue
        if in_section:
            if line.startswith("#"):
                break
            stripped = line.strip()
            if stripped:
                return stripped[:80]
    return ""


def parse_sessions_md(project_dir: str) -> list[dict[str, str]]:
    """sessions.md 파싱 → 에이전트 목록."""
    content = _read_file(
        os.path.join(project_dir, "memory", "manager", "sessions.md")
    )
    if not content:
        return []
    raw_agents = []
    for line in content.splitlines():
        line = line.strip()
        if not line.startswith("|"):
            continue
        cols = [c.strip() for c in line.split("|")]
        cols = [c for c in cols if c]
        if len(cols) < 7:
            print(
                f"[dashboard] sessions.md: 7컬럼 미달 행 무시 ({len(cols)}열): {line!r}",
                file=sys.stderr,
            )
            continue
        if cols[0] in ("역할", "------", "---") or cols[0].startswith("-"):
            continue
        raw_agents.append({
            "role": cols[0],
            "backend": cols[1],
            "session_id": cols[2],
            "tmux_target": cols[3],
            "status": cols[4],
            "start_date": cols[5],
            "model": cols[6],
        })
    deduped: list[dict[str, str]] = []
    seen_targets: set[str] = set()
    for agent in reversed(raw_agents):
        key = agent.get("tmux_target", "")
        if key in seen_targets:
            continue
        seen_targets.add(key)
        deduped.append(agent)
    deduped.reverse()
    return deduped


def get_tmux_activity(session_name: str) -> dict[str, int]:
    """tmux 윈도우별 마지막 활동 시각(epoch) 반환."""
    try:
        out = subprocess.check_output(
            ["tmux", "list-windows", "-t", session_name,
             "-F", "#{window_name}|#{window_activity}"],
            text=True, stderr=subprocess.DEVNULL,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return {}
    result = {}
    for line in out.strip().splitlines():
        parts = line.split("|", 1)
        if len(parts) == 2 and parts[1].isdigit():
            result[parts[0]] = int(parts[1])
    return result


def get_tmux_panes(session_name: str) -> dict[str, dict[str, Any]]:
    """tmux 세션의 모든 윈도우별 첫 pane pid/current_command 반환."""
    try:
        out = subprocess.check_output(
            [
                "tmux", "list-panes", "-s", "-t", session_name,
                "-F", "#{session_name}|#{window_name}|#{pane_pid}|#{pane_current_command}",
            ],
            text=True, stderr=subprocess.DEVNULL,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return {}

    panes: dict[str, dict[str, Any]] = {}
    for line in out.strip().splitlines():
        parts = line.split("|", 3)
        if len(parts) != 4 or not parts[2].isdigit():
            continue
        if parts[0] != session_name:
            continue
        panes.setdefault(parts[1], {"pid": int(parts[2]), "command": parts[3]})
    return panes


def _normalize_command_name(command: str) -> str:
    return os.path.basename(command.strip())


def _command_matches_backend(command: str, backend: str) -> bool:
    normalized = _normalize_command_name(command)
    if not normalized:
        return False
    expected = "codex" if backend == "codex" else "claude"
    return normalized.startswith(expected)


def _agent_process_alive(pane_pid: int, pane_command: str, backend: str) -> bool:
    if _command_matches_backend(pane_command, backend):
        return True

    try:
        child_pids = subprocess.check_output(
            ["pgrep", "-P", str(pane_pid)],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False

    for child_pid in child_pids.splitlines():
        child_pid = child_pid.strip()
        if not child_pid.isdigit():
            continue
        try:
            child_command = subprocess.check_output(
                ["ps", "-o", "comm=", "-p", child_pid],
                text=True,
                stderr=subprocess.DEVNULL,
            ).strip()
        except (subprocess.CalledProcessError, FileNotFoundError):
            continue
        if _command_matches_backend(child_command, backend):
            return True

    return False


def _capture_pane_tail(session_name: str, window_name: str, lines: int = 60) -> str:
    try:
        out = subprocess.check_output(
            [
                "tmux", "capture-pane", "-pJ", "-t", f"{session_name}:{window_name}",
                "-S", f"-{lines}",
            ],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return ""

    stripped = [line for line in out.splitlines() if line.strip()]
    return "\n".join(stripped[-12:])


def _pane_requires_claude_login(pane_text: str) -> bool:
    lowered = pane_text.lower()
    markers = (
        "not logged in",
        "please run /login",
        "run /login",
        "claude auth login",
        "security unlock-keychain",
    )
    return any(marker in lowered for marker in markers)


def _agent_health_state(manager_state: dict[str, str], window_name: str) -> str:
    return manager_state.get(f"agent_health_{window_name}", "")


def _agent_has_auth_block(manager_state: dict[str, str], session_name: str,
                          window_name: str, backend: str) -> bool:
    if backend != "claude":
        return False
    if _agent_health_state(manager_state, window_name) == "AUTH_BLOCKED":
        return True
    return _pane_requires_claude_login(_capture_pane_tail(session_name, window_name))


def check_monitor(project_dir: str) -> dict[str, Any]:
    """모니터 상태 확인."""
    info: dict[str, Any] = {
        "pid": None, "alive": False, "heartbeat_age": None, "queued": 0,
    }
    runtime_root_dir = os.path.join(project_dir, "runtime")
    manager_state = _read_tsv_map(
        os.path.join(runtime_root_dir, "manager-state.tsv")
    )
    for key in ("monitor_lock_pid", "monitor_pid"):
        pid_str = manager_state.get(key)
        if not pid_str or not pid_str.isdigit():
            continue
        pid = int(pid_str)
        if info["pid"] is None:
            info["pid"] = pid
        try:
            os.kill(pid, 0)
            info["pid"] = pid
            info["alive"] = True
            break
        except OSError:
            if key == "monitor_pid":
                info["pid"] = pid

    hb_str = manager_state.get("monitor_heartbeat")
    if hb_str:
        if hb_str.isdigit():
            info["heartbeat_age"] = int(time.time()) - int(hb_str)

    queue_dir = os.path.join(runtime_root_dir, "message-queue")
    if os.path.isdir(queue_dir):
        info["queued"] = len(glob(os.path.join(queue_dir, "*.msg")))

    return info


def parse_boot_times(project_dir: str) -> dict[str, datetime]:
    """system.log에서 각 에이전트의 마지막 부팅 시각 추출."""
    lines = _read_tail(
        os.path.join(project_dir, "logs", "system.log"), 200
    )
    pattern = re.compile(
        r'^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) \[\w+\] (\S+)\s+.*부팅'
    )
    boot_times: dict[str, datetime] = {}
    for line in lines:
        m = pattern.match(line)
        if not m:
            continue
        ts_str, agent_name = m.groups()
        try:
            ts = datetime.strptime(ts_str, "%Y-%m-%d %H:%M:%S").replace(
                tzinfo=_KST
            )
        except ValueError:
            continue
        boot_times[agent_name] = ts
    return boot_times


def parse_system_log(project_dir: str, count: int = 20) -> list[dict]:
    """system.log 마지막 N줄 파싱."""
    lines = _read_tail(
        os.path.join(project_dir, "logs", "system.log"), count
    )
    pattern = re.compile(
        r'^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) \[(\w+)\] (.+)$'
    )
    entries = []
    for line in lines:
        m = pattern.match(line)
        if not m:
            continue
        ts_str, level, message = m.groups()
        try:
            ts = datetime.strptime(ts_str, "%Y-%m-%d %H:%M:%S").replace(
                tzinfo=_KST
            )
        except ValueError:
            continue
        entries.append({"ts": ts, "level": level, "message": message})
    return entries


def parse_message_log(project_dir: str, count: int = 30) -> list[dict]:
    """message.log 마지막 N줄 파싱."""
    lines = _read_tail(
        os.path.join(project_dir, "logs", "message.log"), count
    )
    pattern = re.compile(
        r'^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) '
        r'\[(\w+)\] '
        r'(\S+) → (\S+) '
        r'(?:(\S+) (\S+) )?'
        r'"([^"]+)"'
    )
    entries = []
    for line in lines:
        m = pattern.match(line)
        if not m:
            continue
        ts_str, status, sender, receiver, kind, priority, subject = m.groups()
        try:
            ts = datetime.strptime(ts_str, "%Y-%m-%d %H:%M:%S").replace(
                tzinfo=_KST
            )
        except ValueError:
            continue
        entries.append({
            "ts": ts, "status": status,
            "sender": sender, "receiver": receiver,
            "kind": kind or "", "priority": priority or "",
            "subject": subject,
        })
    return entries


def get_reboot_counts(project_dir: str) -> dict[str, int]:
    """reboot-state.tsv에서 각 역할의 리부팅 횟수 반환."""
    rows = _read_tsv_rows(os.path.join(project_dir, "runtime", "reboot-state.tsv"))
    result: dict[str, int] = {}
    for cols in rows:
        if len(cols) < 2:
            continue
        role, count = cols[0], cols[1]
        if count.isdigit() and int(count) > 0:
            result[role] = int(count)
    return result



def _resolve_task_path(project_dir: str, task_path: str) -> str:
    """태스크 파일 경로를 절대경로로 해석."""
    if os.path.isabs(task_path):
        return task_path
    if task_path.startswith("projects/"):
        repo_root = os.path.dirname(os.path.dirname(project_dir))
        return os.path.join(repo_root, task_path)
    return os.path.join(project_dir, task_path)


def _read_file_cached(path: str) -> str | None:
    """mtime 기반 캐싱으로 태스크 파일 읽기 — 변경 시에만 재읽음."""
    try:
        mtime = os.path.getmtime(path)
    except OSError:
        _task_file_cache.pop(path, None)
        return None
    cached = _task_file_cache.get(path)
    if cached is not None and cached[0] == mtime:
        return cached[1]  # type: ignore[return-value]
    content = _read_file(path)
    _task_file_cache[path] = (mtime, content)
    return content


def _read_task_title(project_dir: str, task_path: str) -> str:
    """태스크 파일 첫 줄에서 제목 추출."""
    full = _resolve_task_path(project_dir, task_path)
    content = _read_file_cached(full)
    if not content:
        return ""
    first = content.splitlines()[0]
    m = re.match(r'^#\s*TASK-\d{3}:\s*(.+)', first)
    return m.group(1).strip() if m else ""


def _read_task_background(project_dir: str, task_path: str) -> str:
    """태스크 파일에서 목표/배경 첫 의미줄 추출."""
    full = _resolve_task_path(project_dir, task_path)
    content = _read_file_cached(full)
    if not content:
        return ""
    in_section = False
    for line in content.splitlines():
        if re.match(r"^##\s*(목표|배경|Goal|Background)", line):
            in_section = True
            continue
        if in_section:
            if line.startswith("#"):
                break
            stripped = line.strip().lstrip("> ").strip()
            if stripped:
                return stripped[:100]
    return ""


def parse_assignments_md(project_dir: str) -> dict[str, dict]:
    """assignments.md에서 active/stale 태스크 매핑."""
    content = _read_file(
        os.path.join(project_dir, "memory", "manager", "assignments.md")
    )
    if not content:
        return {}
    result = {}
    task_re = re.compile(r'TASK-\d{3}')
    for line in content.splitlines():
        line = line.strip()
        if not line.startswith("|"):
            continue
        cols = [c.strip() for c in line.split("|")]
        cols = [c for c in cols if c]
        if len(cols) < 4:
            continue
        if cols[0] in ("역할", "에이전트", "------", "---") or cols[0].startswith("-"):
            continue
        status = cols[3].lower() if len(cols) > 3 else ""
        if "active" not in status and "stale" not in status:
            continue
        role = cols[0]
        task_file = cols[1]
        assign_ts_str = cols[2] if len(cols) > 2 else ""
        is_stale = "stale" in status

        started = None
        try:
            started = datetime.strptime(
                assign_ts_str, "%Y-%m-%d %H:%M"
            ).replace(tzinfo=_KST)
        except ValueError:
            pass

        task_match = task_re.search(task_file)
        if task_match:
            task_id = task_match.group()
            # 파일 경로 형식이면 파일에서 읽기, 아니면 문자열에서 추출
            if "/" in task_file or task_file.endswith(".md"):
                title = _read_task_title(project_dir, task_file)
                background = _read_task_background(project_dir, task_file)
            else:
                # "TASK-014: 대시보드 재설계 — 처음부터" 형태
                desc_match = re.match(r'TASK-\d{3}:\s*(.+)', task_file)
                title = desc_match.group(1).strip() if desc_match else ""
                background = ""
        else:
            task_id = "WORK"
            title = task_file[:40] + ("..." if len(task_file) > 40 else "")
            background = ""

        result[role] = {
            "id": task_id,
            "title": title,
            "background": background,
            "started": started,
            "stale": is_stale,
            "task_ref": task_file,
        }
    return result



# ──────────────────────────────────────────────
# 데이터 수집
# ──────────────────────────────────────────────

def collect(project_dir: str, session_name: str,
            project_info: dict) -> dict[str, Any]:
    """모든 데이터 소스를 읽어 하나의 dict로 반환."""
    now = _now_kst()
    now_epoch = int(time.time())

    agents = parse_sessions_md(project_dir)
    tmux_activity = get_tmux_activity(session_name)
    tmux_panes = get_tmux_panes(session_name)
    reboot_counts = get_reboot_counts(project_dir)
    assignments = parse_assignments_md(project_dir)
    manager_state = _read_tsv_map(os.path.join(project_dir, "runtime", "manager-state.tsv"))
    monitor = check_monitor(project_dir)
    boot_times = parse_boot_times(project_dir)
    system_log = parse_system_log(project_dir, 20)
    message_log = parse_message_log(project_dir, 30)
    project_phase = parse_project_phase(project_dir)

    for agent in agents:
        role = agent["role"]
        tmux_target = agent.get("tmux_target", "")
        win_name = tmux_target.split(":", 1)[1] if ":" in tmux_target else role

        # uptime
        boot_ts = boot_times.get(win_name) or boot_times.get(role)
        if boot_ts:
            agent["uptime_sec"] = int((now - boot_ts).total_seconds())
        else:
            agent["uptime_sec"] = -1

        if agent["status"] != "active":
            agent["display_status"] = "CLOSED"
            agent["status_reason"] = ""
            continue

        pane_info = tmux_panes.get(win_name)
        if pane_info is None:
            agent["display_status"] = "ABSENT"
            agent["status_reason"] = "윈도우 없음"
        elif _agent_process_alive(
            pane_info["pid"], pane_info.get("command", ""), agent.get("backend", "")
        ):
            if _agent_has_auth_block(
                manager_state, session_name, win_name, agent.get("backend", "")
            ):
                agent["display_status"] = "WAIT"
                agent["status_reason"] = "인증 필요"
            else:
                agent["display_status"] = "ALIVE"
                agent["status_reason"] = ""
        else:
            agent["display_status"] = "CRASHED"
            agent["status_reason"] = "프로세스 종료됨"

        task_info = assignments.get(win_name) or assignments.get(role)
        if task_info:
            agent["task_id"] = task_info["id"]
            agent["task_title"] = task_info["title"]
            agent["task_background"] = task_info.get("background", "")
            agent["task_started"] = task_info.get("started")
            agent["task_stale"] = task_info.get("stale", False)
            if agent["display_status"] == "ALIVE":
                agent["display_status"] = "ACTIVE"
                agent["status_reason"] = ""
        else:
            agent["task_id"] = ""
            agent["task_title"] = ""
            agent["task_background"] = ""
            agent["task_started"] = None
            agent["task_stale"] = False
            if agent["display_status"] == "ALIVE":
                activity_ts = tmux_activity.get(win_name)
                if activity_ts and (now_epoch - activity_ts) < _RECENT_ACTIVITY_WINDOW_SEC:
                    agent["display_status"] = "IDLE"
                    agent["status_reason"] = "태스크 대기중"
                else:
                    agent["display_status"] = "IDLE"
                    agent["status_reason"] = "유휴"

        agent["reboots"] = reboot_counts.get(role, 0)
        agent["win_name"] = win_name

    # 활성 태스크 요약 (에이전트별 중복 제거)
    active_task_summaries: list[dict[str, Any]] = []
    summary_map: dict[tuple[str, str], dict[str, Any]] = {}
    for agent in agents:
        if agent.get("display_status") == "CLOSED":
            continue
        task_id = agent.get("task_id", "")
        if not task_id:
            continue
        task_title = agent.get("task_title", "")
        key = (task_id, task_title)
        summary = summary_map.get(key)
        if summary is None:
            summary = {
                "task_id": task_id,
                "task_title": task_title,
                "task_background": agent.get("task_background", ""),
                "assignees": [],
                "started": agent.get("task_started"),
            }
            summary_map[key] = summary
            active_task_summaries.append(summary)

        summary["assignees"].append(agent.get("win_name", agent["role"]))
        started = agent.get("task_started")
        existing_started = summary.get("started")
        if started and (existing_started is None or started < existing_started):
            summary["started"] = started

    active_task_summaries.sort(
        key=lambda item: item.get("started") or datetime.fromtimestamp(0, _KST),
    )

    # 유저 대상 알림 수집
    resolved_subjects = {
        e["subject"]
        for e in message_log
        if e.get("kind") == "alert_resolve" and e.get("receiver") == "user"
    }
    alert_kinds = frozenset({"escalation", "need_input", "user_notice"})
    user_alerts = [
        e for e in message_log
        if e.get("kind") in alert_kinds and e.get("receiver") == "user"
        and e["subject"] not in resolved_subjects
    ]
    user_alerts.sort(key=lambda e: e["ts"], reverse=True)
    user_alerts = user_alerts[:8]

    return {
        "now": now,
        "project": project_info,
        "project_phase": project_phase,
        "agents": agents,
        "active_task_summaries": active_task_summaries,
        "user_alerts": user_alerts,
        "monitor": monitor,
        "system_log": system_log,
        "message_log": message_log,
        "session_exists": bool(tmux_activity),
    }


# ──────────────────────────────────────────────
# 렌더링
# ──────────────────────────────────────────────

_STATUS_DISPLAY = {
    "ACTIVE":  ("● ACTIVE", "bold green"),
    "IDLE":    ("○ IDLE",   "dim"),
    "WAIT":    ("◎ WAIT",   "yellow"),
    "CRASHED": ("✗ CRASH",  "bold red"),
    "ABSENT":  ("— ABSENT", "red"),
    "CLOSED":  ("— CLOSED", "dim"),
}


def _time_ago(ts: datetime) -> str:
    """시간을 '3m', '1h 5m' 등으로 표시."""
    diff = _now_kst() - ts
    secs = int(diff.total_seconds())
    if secs < 0:
        return "now"
    if secs < 60:
        return f"{secs}s"
    m = secs // 60
    if m < 60:
        return f"{m}m"
    h = m // 60
    rm = m % 60
    return f"{h}h {rm}m"


def _render_header(state: dict) -> Panel:
    """프로젝트 컨텍스트 + 모니터 상태 헤더."""
    proj = state["project"]
    now = state["now"]
    mon = state["monitor"]
    phase = state.get("project_phase", "")

    # 첫째 줄: 프로젝트명 + 모드 + 모니터 + 시간
    line1 = Text()
    line1.append("  WHIPLASH", style="bold white")
    line1.append(" › ", style="dim")
    line1.append(proj.get("name", "?"), style="bold cyan")
    line1.append("  ", style="")

    mode = proj.get("preset") or proj.get("mode", "solo")
    loop = proj.get("loop_mode", "guided")
    line1.append(mode, style="bold magenta")
    line1.append("/", style="dim")
    line1.append(loop, style="bold yellow" if loop == "ralph" else "bold green")
    line1.append("  ", style="")

    # monitor
    if mon["alive"]:
        line1.append("● Mon", style="green")
        if mon["heartbeat_age"] is not None:
            hb_style = "green" if mon["heartbeat_age"] < 90 else "red"
            line1.append(f" {mon['heartbeat_age']}s", style=hb_style)
    elif mon["pid"]:
        line1.append("✗ Mon", style="red")
    else:
        line1.append("— Mon", style="dim")

    if mon["queued"] > 0:
        line1.append(f"  Q:{mon['queued']}", style="yellow")

    # 시간 우정렬
    time_str = now.strftime("%H:%M:%S")
    term_width = shutil.get_terminal_size().columns
    current_len = cell_len(line1.plain)
    padding = max(1, term_width - current_len - len(time_str))
    line1.append(" " * padding)
    line1.append(time_str, style="dim")

    # 둘째 줄: 프로젝트 단계
    line2 = Text()
    control_plane_backend = proj.get("control_plane_backend", "")
    if control_plane_backend:
        line2.append("  ", style="")
        line2.append(f"ctrl:{control_plane_backend}", style="dim")
        if phase:
            line2.append("  ", style="")
    if phase:
        line2.append(phase, style="italic dim")

    body = Text()
    body.append_text(line1)
    body.append("\n")
    body.append_text(line2)

    return Panel(body, style="blue", height=4)


def _render_alerts(alerts: list[dict]) -> Panel | None:
    """유저 조치가 필요한 알림. 없으면 None."""
    if not alerts:
        return None

    table = Table(
        show_header=False,
        border_style="red",
        pad_edge=True,
        expand=True,
        show_edge=False,
    )
    table.add_column("icon", width=2)
    table.add_column("subject", ratio=3)
    table.add_column("from", min_width=12)
    table.add_column("time", min_width=6, justify="right")

    for entry in alerts:
        kind = entry.get("kind", "")
        if kind == "escalation":
            icon = Text("!!", style="bold red")
        elif kind == "user_notice":
            icon = Text(">>", style="bold cyan")
        else:
            icon = Text("??", style="bold yellow")

        table.add_row(
            icon,
            Text(entry["subject"], style="bold"),
            Text(entry["sender"], style="dim"),
            Text(_time_ago(entry["ts"]), style="dim"),
        )

    return Panel(
        table,
        title="⚠ 조치 필요",
        title_align="left",
        border_style="bold red",
    )


def _render_tasks(state: dict) -> Panel:
    """활성 태스크 카드 — hero 섹션."""
    summaries = state.get("active_task_summaries", [])
    now = state["now"]

    if not summaries:
        return Panel(
            Text("  활성 태스크 없음", style="dim"),
            title="TASKS",
            title_align="left",
            border_style="cyan",
        )

    lines = Text()
    for i, entry in enumerate(summaries[:8]):
        if i > 0:
            lines.append("\n")

        task_id = entry.get("task_id", "")
        task_title = entry.get("task_title", "")
        background = entry.get("task_background", "")
        assignees = entry.get("assignees", [])
        started = entry.get("started")

        # elapsed
        if started:
            elapsed = _format_elapsed(int((now - started).total_seconds()))
        else:
            elapsed = "--"

        # 첫줄: task id + title + elapsed
        lines.append(f"  ▸ {task_id}", style="bold cyan")
        if task_title:
            lines.append(f"  {task_title}", style="bold")
        # elapsed 우측
        lines.append(f"  ({elapsed})", style="dim")

        lines.append("\n")

        # 둘째줄: 배경
        if background:
            lines.append(f"    {background}", style="dim italic")
            lines.append("\n")

        # 셋째줄: 담당 에이전트
        lines.append("    ", style="")
        for j, assignee in enumerate(assignees):
            if j > 0:
                lines.append("  ", style="")
            lines.append(f"● {assignee}", style="green")
        lines.append("\n")

    return Panel(
        lines,
        title="TASKS",
        title_align="left",
        border_style="cyan",
    )


def _render_agents(state: dict) -> Panel:
    """에이전트 상태 테이블 — 간결하게."""
    table = Table(
        show_header=True,
        header_style="bold dim",
        border_style="dim",
        pad_edge=True,
        expand=True,
        show_edge=False,
    )
    table.add_column("Agent", no_wrap=True, min_width=18)
    table.add_column("Status", no_wrap=True, min_width=10)
    table.add_column("Info", no_wrap=True, ratio=1, overflow="ellipsis")
    table.add_column("Uptime", no_wrap=True, justify="right", min_width=7)

    active_agents = [a for a in state["agents"] if a.get("display_status") != "CLOSED"]

    if not active_agents:
        msg = "⏳ 부팅중..." if state.get("session_exists") else "(세션 없음)"
        table.add_row(msg, "", "", "")
        return Panel(table, title="AGENTS", title_align="left", border_style="dim")

    # 역할 우선순위 정렬
    _ROLE_ORDER = {
        "manager": 0, "discussion": 1, "systems-engineer": 2,
        "researcher": 3, "developer": 4, "monitoring": 5,
    }
    active_agents.sort(key=lambda a: (
        _ROLE_ORDER.get(a["role"], 99),
        a.get("backend", ""),
    ))

    # 듀얼 감지
    role_counts = Counter(a["role"] for a in active_agents)
    is_dual = any(c > 1 for c in role_counts.values())

    for agent in active_agents:
        ds = agent.get("display_status", "CLOSED")
        label, style = _STATUS_DISPLAY.get(ds, ("?", ""))

        # 이름
        win_name = agent.get("win_name", agent["role"])
        if is_dual and role_counts[agent["role"]] > 1:
            name_label = win_name
        else:
            name_label = agent["role"]

        # 정보열: 태스크 or 상태 설명
        task_id = agent.get("task_id", "")
        task_title = agent.get("task_title", "")
        status_reason = agent.get("status_reason", "")

        if task_id and task_title:
            # 제목을 적당히 잘라서 표시
            short_title = task_title[:25] + ("…" if len(task_title) > 25 else "")
            info_str = f"{task_id} {short_title}"
            info_style = ""
        elif task_id:
            info_str = task_id
            info_style = ""
        elif status_reason:
            info_str = status_reason
            info_style = "dim italic"
        else:
            info_str = ""
            info_style = "dim"

        # Uptime
        uptime = agent.get("uptime_sec", -1)
        uptime_str = _format_elapsed(uptime) if uptime >= 0 else "--"

        table.add_row(
            Text(name_label),
            Text(label, style=style),
            Text(info_str, style=info_style),
            Text(uptime_str, style="dim"),
        )

    return Panel(table, title="AGENTS", title_align="left", border_style="dim")


# idle 이벤트 필터
_IDLE_FILTER_EVENTS = frozenset({
    "idle_detected", "idle_recheck", "idle_cleared",
})
_IDLE_FILTER_KR = ["비활성 감지", "재확인 예약", "비활성 재확인", "활동 재개"]

_TASK_PATH_RE = re.compile(r'(?:task=|파일=)\S*/?(TASK-\d{3})\S*')


def _is_idle_event(message: str) -> bool:
    msg_lower = message.lower().replace(" ", "_")
    for ev in _IDLE_FILTER_EVENTS:
        if ev in msg_lower:
            return True
    for kw in _IDLE_FILTER_KR:
        if kw in message:
            return True
    return False


def _summarize_event(message: str) -> str:
    """시스템 로그 메시지를 짧게 요약."""
    m = _TASK_PATH_RE.search(message)
    if m:
        message = _TASK_PATH_RE.sub(m.group(1), message)
    return message[:70]


def _render_recent(state: dict) -> Panel:
    """최근 주요 이벤트 5줄 요약."""
    merged: list[tuple[datetime, str]] = []

    for entry in state["system_log"]:
        if _is_idle_event(entry["message"]):
            continue
        merged.append((entry["ts"], _summarize_event(entry["message"])))

    for entry in state["message_log"]:
        sender = entry["sender"]
        receiver = entry["receiver"]
        subject = entry["subject"]
        m = _TASK_PATH_RE.search(subject)
        if m:
            subject = _TASK_PATH_RE.sub(m.group(1), subject)
        text = f"{sender}→{receiver} {subject}"
        merged.append((entry["ts"], text))

    merged.sort(key=lambda x: x[0])
    recent = merged[-6:]

    table = Table(
        show_header=False,
        border_style="dim",
        pad_edge=False,
        expand=True,
        show_edge=False,
    )
    table.add_column("time", no_wrap=True, width=5, style="dim")
    table.add_column("event", no_wrap=True, ratio=1, overflow="ellipsis")

    if not recent:
        table.add_row("--", "(이벤트 없음)")
    else:
        for ts, text in reversed(recent):
            table.add_row(ts.strftime("%H:%M"), text)

    return Panel(table, title="RECENT", title_align="left", border_style="dim")


def _render_footer(interval: int) -> Text:
    text = Text()
    text.append(" Ctrl-C to exit", style="dim")
    text.append("  │  ", style="dim")
    text.append(f"Refresh: {interval}s", style="dim")
    return text


def render(state: dict, interval: int) -> Layout:
    """전체 대시보드 렌더링."""
    alerts = state.get("user_alerts", [])
    active_agents = [a for a in state.get("agents", []) if a.get("display_status") != "CLOSED"]

    # 동적 높이 계산
    alerts_height = min(len(alerts) + 3, 8) if alerts else 0
    n_agents = len(active_agents)
    # agent table: header(1) + rows + panel borders(2) + title(1)
    bottom_height = max(9, n_agents + 4)

    # tasks 패널: 태스크 수에 맞춰 동적 높이 (각 태스크 ~4줄 + borders 3줄)
    n_tasks = len(state.get("active_task_summaries", []))
    tasks_height = max(6, min(n_tasks * 4 + 3, shutil.get_terminal_size().lines // 2))

    layout = Layout()

    # 알림 유무에 따라 레이아웃 구성
    sections = [
        Layout(name="header", size=4),
    ]
    if alerts_height > 0:
        sections.append(Layout(name="alerts", size=alerts_height))
    sections.append(Layout(name="tasks", size=tasks_height))
    sections.append(Layout(name="bottom", size=bottom_height))
    sections.append(Layout(name="footer", size=1))

    layout.split_column(*sections)

    # bottom: 에이전트 좌측(넓게), 최근 우측(좁게)
    layout["bottom"].split_row(
        Layout(name="agents", ratio=2),
        Layout(name="recent", ratio=1),
    )

    # 렌더링
    layout["header"].update(_render_header(state))

    if alerts_height > 0:
        alerts_panel = _render_alerts(alerts)
        if alerts_panel:
            layout["alerts"].update(alerts_panel)

    layout["tasks"].update(_render_tasks(state))
    layout["agents"].update(_render_agents(state))
    layout["recent"].update(_render_recent(state))
    layout["footer"].update(_render_footer(interval))

    return layout


# ──────────────────────────────────────────────
# 메인
# ──────────────────────────────────────────────

def main() -> None:
    _require_rich()

    parser = argparse.ArgumentParser(description="Whiplash 라이브 대시보드")
    parser.add_argument("project", help="프로젝트 이름")
    parser.add_argument(
        "--interval", type=int, default=5,
        help="갱신 주기 (초, 기본 5)",
    )
    args = parser.parse_args()

    project = args.project
    interval = max(1, args.interval)

    root = _repo_root()
    project_dir = os.path.join(root, "projects", project)
    session_name = f"whiplash-{project}"

    if not os.path.isdir(project_dir):
        print(f"프로젝트 디렉토리 없음: {project_dir}", file=sys.stderr)
        sys.exit(1)

    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))

    console = _build_console()
    project_info = parse_project_md(project_dir)
    if not project_info["name"]:
        project_info["name"] = project
    initial = collect(project_dir, session_name, project_info)
    with Live(
        render(initial, interval),
        console=console,
        refresh_per_second=1,
        screen=True,
    ) as live:
        while True:
            time.sleep(interval)
            try:
                project_info = parse_project_md(project_dir)
                if not project_info["name"]:
                    project_info["name"] = project
                state = collect(project_dir, session_name, project_info)
                live.update(render(state, interval))
            except Exception:
                import traceback
                print(traceback.format_exc(), file=sys.stderr)


if __name__ == "__main__":
    main()
