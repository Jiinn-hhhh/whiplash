#!/usr/bin/env python3
"""Whiplash 라이브 대시보드 — Rich Live TUI.

Usage:
  python3 dashboard/dashboard.py {project}              # 기본 5초 갱신
  python3 dashboard/dashboard.py {project} --interval 2 # 2초 갱신
"""

import argparse
import os
import re
import signal
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone
from glob import glob
from typing import Any

try:
    from rich.console import Console
    from rich.console import Group
    from rich.live import Live
    from rich.panel import Panel
    from rich.table import Table
    from rich.text import Text
except ImportError:
    Console = Group = Live = Panel = Table = Text = None

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

_SUCCESS_EVENTS = frozenset({
    "agent_boot", "agent_spawn", "task_dispatch", "dual_dispatch",
    "reboot_success", "agent_refresh_end", "project_boot_end",
    "idle_cleared", "session_recovered",
})

_WARN_EVENTS = frozenset({
    "idle_detected", "idle_recheck", "crash_detected", "session_absent",
    "session_absent_confirmed", "monitor_restart",
    "notify_delivery_fail", "agent_kill", "reboot_count_reset",
    "plan_mode_detected",
})

_ERROR_EVENTS = frozenset({
    "agent_boot_fail", "reboot_failed", "reboot_limit",
    "monitor_exit", "monitor_zombie", "manager_crash_alert",
})

_RECENT_ACTIVITY_WINDOW_SEC = 180

# ──────────────────────────────────────────────
# 유틸리티
# ──────────────────────────────────────────────

def _repo_root() -> str:
    return subprocess.check_output(
        ["git", "rev-parse", "--show-toplevel"],
        text=True,
    ).strip()


def _now_kst() -> datetime:
    return datetime.now(_KST)


def _relative_time(dt: datetime) -> str:
    """datetime을 'N분 전', 'N초 전' 형태로 변환."""
    diff = _now_kst() - dt
    secs = int(diff.total_seconds())
    if secs < 0:
        return "방금"
    if secs < 60:
        return f"{secs}초 전"
    mins = secs // 60
    if mins < 60:
        return f"{mins}분 전"
    hours = mins // 60
    return f"{hours}시간 전"


def _format_idle(seconds: int) -> str:
    """초를 'm분 s초' 형태로 변환."""
    if seconds < 0:
        return "--"
    m, s = divmod(seconds, 60)
    if m > 0:
        return f"{m}m {s}s"
    return f"{s}s"


def _format_elapsed_compact(seconds: int) -> str:
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


def _abbr(name: str) -> str:
    return _ROLE_ABBR.get(name, name[:3])


def _sanitize_report_component(value: str, default: str) -> str:
    value = value.replace(" ", "-")
    value = re.sub(r"[^A-Za-z0-9._-]", "", value)
    value = value.strip("-.")
    return value or default


def _task_report_key(task_ref: str) -> str:
    base = os.path.basename(task_ref)
    stem, _ = os.path.splitext(base)
    return _sanitize_report_component(stem or base or task_ref, "task")


def _task_report_path(project_dir: str, task_ref: str, author: str) -> str:
    key = _task_report_key(task_ref)
    author_key = _sanitize_report_component(author, "agent")
    return os.path.join(project_dir, "reports", "tasks", f"{key}-{author_key}.md")


def _read_report_status(report_path: str) -> str:
    content = _read_file(report_path)
    if not content:
        return "missing"
    match = re.search(r"^- \*\*Status\*\*: ([A-Za-z0-9_-]+)\s*$", content, re.MULTILINE)
    if not match:
        return "unknown"
    return match.group(1).lower()


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
    if "execution mode" in key or "실행 모드" in key:
        return "mode", value
    if "loop mode" in key or "작업 루프" in key:
        return "loop_mode", value
    return None


def _require_rich() -> None:
    if None in (Console, Group, Live, Panel, Table, Text):
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
        "mode": "pending",
        "loop_mode": "guided",
        "domain": "general",
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
        if key == "mode":
            if "dual" in value.lower():
                info["mode"] = "dual"
            elif "pending" in value.lower() or "미정" in value:
                info["mode"] = "pending"
            else:
                info["mode"] = "solo"
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
        # cols[0]은 빈 문자열 (| 앞), cols[-1]도 빈 문자열
        cols = [c for c in cols if c]
        if len(cols) < 7:
            continue
        # 헤더/구분선 건너뛰기
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


def get_tmux_panes(session_name: str) -> dict[str, int]:
    """tmux 세션의 모든 윈도우별 첫 pane pid 반환."""
    try:
        out = subprocess.check_output(
            [
                "tmux", "list-panes", "-a", "-t", session_name,
                "-F", "#{session_name}|#{window_name}|#{pane_pid}",
            ],
            text=True, stderr=subprocess.DEVNULL,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return {}

    panes: dict[str, int] = {}
    for line in out.strip().splitlines():
        parts = line.split("|", 2)
        if len(parts) != 3 or not parts[2].isdigit():
            continue
        if parts[0] != session_name:
            continue
        panes.setdefault(parts[1], int(parts[2]))
    return panes


def _agent_process_alive(pane_pid: int, backend: str) -> bool:
    expected = "codex" if backend == "codex" else "claude"
    try:
        return subprocess.run(
            ["pgrep", "-P", str(pane_pid), expected],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        ).returncode == 0
    except FileNotFoundError:
        return False


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
        boot_times[agent_name] = ts  # 마지막 부팅이 덮어씀
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


def parse_message_log(project_dir: str, count: int = 10) -> list[dict]:
    """message.log 마지막 N줄 파싱."""
    lines = _read_tail(
        os.path.join(project_dir, "logs", "message.log"), count
    )
    # 새 포맷: kind+priority 포함, 하위 호환: kind/priority 없는 기존 로그도 파싱
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


def parse_waiting_state(project_dir: str) -> dict[str, dict[str, Any]]:
    """waiting-state.tsv에서 완료 후 대기 상태를 읽는다."""
    rows = _read_tsv_rows(os.path.join(project_dir, "runtime", "waiting-state.tsv"))
    result: dict[str, dict[str, Any]] = {}
    for cols in rows:
        if len(cols) < 4:
            continue
        agent, ts_raw, subject, task_ref = cols[:4]
        if not agent:
            continue
        report_path = cols[4] if len(cols) > 4 else ""
        ts = None
        if ts_raw.isdigit():
            ts = datetime.fromtimestamp(int(ts_raw), _KST)
        result[agent] = {
            "ts": ts,
            "subject": subject,
            "task_ref": task_ref,
            "report_path": report_path,
        }
    return result


def _read_task_title(project_dir: str, task_path: str) -> str:
    """태스크 파일 첫 줄에서 제목 추출. '# TASK-013: 설명' → '설명'."""
    # 절대경로면 그대로, repo-root 상대경로는 repo_root 기준,
    # 그 외 상대경로는 project_dir 기준 결합
    if os.path.isabs(task_path):
        full = task_path
    elif task_path.startswith("projects/"):
        repo_root = os.path.dirname(os.path.dirname(project_dir))
        full = os.path.join(repo_root, task_path)
    else:
        full = os.path.join(project_dir, task_path)
    content = _read_file(full)
    if not content:
        return ""
    first = content.splitlines()[0]
    # "# TASK-NNN: 제목" 패턴
    m = re.match(r'^#\s*TASK-\d{3}:\s*(.+)', first)
    return m.group(1).strip() if m else ""


def parse_assignments_md(project_dir: str) -> dict[str, dict]:
    """assignments.md에서 active/stale 태스크 매핑 (role → {id, title, started, stale})."""
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
        # cols: [에이전트, 태스크파일, 할당시각, 상태, ...]
        status = cols[3].lower() if len(cols) > 3 else ""
        if "active" not in status and "stale" not in status:
            continue
        role = cols[0]
        task_file = cols[1]
        assign_ts_str = cols[2] if len(cols) > 2 else ""
        is_stale = "stale" in status

        # 할당 시각 파싱
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
            title = _read_task_title(project_dir, task_file)
        else:
            task_id = "WORK"
            title = task_file[:30] + ("..." if len(task_file) > 30 else "")

        result[role] = {
            "id": task_id,
            "title": title,
            "started": started,
            "stale": is_stale,
            "task_ref": task_file,
        }
    return result


def resolve_task_report(project_dir: str, task_ref: str, authors: list[str]) -> dict[str, str]:
    for author in authors:
        report_path = _task_report_path(project_dir, task_ref, author)
        if os.path.isfile(report_path):
            return {
                "path": os.path.relpath(report_path, project_dir),
                "status": _read_report_status(report_path),
            }
    primary_path = _task_report_path(project_dir, task_ref, authors[0])
    return {
        "path": os.path.relpath(primary_path, project_dir),
        "status": "missing",
    }


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
    waiting_state = parse_waiting_state(project_dir)
    monitor = check_monitor(project_dir)
    boot_times = parse_boot_times(project_dir)
    system_log = parse_system_log(project_dir, 20)
    message_log = parse_message_log(project_dir, 30)

    # 에이전트별 uptime 및 상태 계산
    for agent in agents:
        role = agent["role"]
        tmux_target = agent.get("tmux_target", "")
        win_name = tmux_target.split(":", 1)[1] if ":" in tmux_target else role

        # uptime: system.log 부팅 시각 기준
        boot_ts = boot_times.get(win_name) or boot_times.get(role)
        if boot_ts:
            agent["uptime_sec"] = int((now - boot_ts).total_seconds())
        else:
            agent["uptime_sec"] = -1

        if agent["status"] != "active":
            agent["display_status"] = "CLOSED"
            continue
        pane_pid = tmux_panes.get(win_name)
        if pane_pid is None:
            agent["display_status"] = "ABSENT"
        elif _agent_process_alive(pane_pid, agent.get("backend", "")):
            agent["display_status"] = "ALIVE"
        else:
            agent["display_status"] = "CRASHED"

        task_info = assignments.get(win_name) or assignments.get(role)
        if task_info:
            agent["task_id"] = task_info["id"]
            agent["task_title"] = task_info["title"]
            agent["task_started"] = task_info.get("started")
            agent["task_stale"] = task_info.get("stale", False)
            report_info = resolve_task_report(
                project_dir,
                task_info["task_ref"],
                [win_name, role] if win_name != role else [role],
            )
            agent["report_path"] = report_info["path"]
            agent["report_status"] = report_info["status"]
        else:
            agent["task_id"] = ""
            agent["task_title"] = ""
            agent["task_started"] = None
            agent["task_stale"] = False
            agent["report_path"] = ""
            agent["report_status"] = ""
            if agent["display_status"] == "ALIVE":
                activity_ts = tmux_activity.get(win_name)
                if activity_ts is None or (now_epoch - activity_ts) > _RECENT_ACTIVITY_WINDOW_SEC:
                    agent["display_status"] = "READY"
        agent["reboots"] = reboot_counts.get(role, 0)
        agent["win_name"] = win_name

    waiting_reports: list[dict[str, Any]] = []
    for agent in agents:
        win_name = agent.get("win_name", agent["role"])
        waiting_info = waiting_state.get(win_name) or waiting_state.get(agent["role"])
        if not waiting_info:
            continue
        if agent.get("task_id"):
            continue
        if agent.get("display_status") not in ("ALIVE", "READY"):
            continue
        waiting_reports.append({
            "agent": win_name,
            "role": agent["role"],
            "status": agent.get("display_status", ""),
            "subject": waiting_info.get("subject", ""),
            "task_ref": waiting_info.get("task_ref", ""),
            "report_path": waiting_info.get("report_path", ""),
            "ts": waiting_info.get("ts"),
        })

    waiting_reports.sort(
        key=lambda item: item["ts"] or datetime.fromtimestamp(0, _KST),
        reverse=True,
    )

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

    return {
        "now": now,
        "project": project_info,
        "agents": agents,
        "active_task_summaries": active_task_summaries,
        "waiting_reports": waiting_reports,
        "monitor": monitor,
        "system_log": system_log,
        "message_log": message_log,
        "session_exists": bool(tmux_activity),
    }


# ──────────────────────────────────────────────
# 렌더링
# ──────────────────────────────────────────────

_STATUS_STYLE = {
    "ALIVE": ("● ALIVE", "green"),
    "READY": ("○ READY", "cyan"),
    "CRASHED": ("✗ CRASHED", "red"),
    "ABSENT": ("○ ABSENT", "red"),
    "CLOSED": ("— CLOSED", "dim"),
}

_REPORT_STYLE = {
    "final": ("FINAL", "green"),
    "draft": ("DRAFT", "yellow"),
    "missing": ("MISS", "red"),
    "unknown": ("UNK", "yellow"),
}


def _render_header(state: dict) -> Panel:
    proj = state["project"]
    now = state["now"]
    name = proj.get("name", "?")
    mode = proj.get("mode", "solo")
    loop_mode = proj.get("loop_mode", "guided")
    time_str = now.strftime("%Y-%m-%d %H:%M:%S")
    mode_label = f"{mode}/{loop_mode}"
    left = f"  WHIPLASH  {name}  {mode_label}"
    title = Text()
    title.append("  WHIPLASH", style="bold white")
    title.append("  ")
    title.append(name, style="bold cyan")
    title.append("  ")
    title.append(mode, style="bold magenta")
    title.append("/", style="bold white")
    title.append(loop_mode, style="bold yellow" if loop_mode == "ralph" else "bold green")
    # right-align time: Panel adds ~4 chars of border
    padding = max(1, 72 - len(left) - len(time_str))
    title.append(" " * padding)
    title.append(time_str, style="dim")
    return Panel(title, style="bold blue")


def _render_agents(state: dict) -> Table:
    table = Table(
        title="AGENTS",
        title_style="bold white",
        show_header=True,
        header_style="bold",
        border_style="dim",
        pad_edge=True,
    )
    table.add_column("Role", min_width=10)
    table.add_column("Status", min_width=10)
    table.add_column("Model", min_width=5)
    table.add_column("Task Time", min_width=7, justify="right")
    table.add_column("Current Task", min_width=20, max_width=40)
    table.add_column("Report", min_width=6)
    table.add_column("Reboot", min_width=6, justify="right")

    # CLOSED 제외
    active_agents = [a for a in state["agents"] if a.get("display_status") != "CLOSED"]

    if not active_agents:
        msg = "⏳ Booting..." if state.get("session_exists") else "(No session)"
        table.add_row(msg, "", "", "", "", "", "")
        return table

    # 역할 우선순위 정렬: manager → discussion → systems-engineer → researcher → developer → monitoring
    _ROLE_ORDER = {
        "manager": 0,
        "discussion": 1,
        "systems-engineer": 2,
        "researcher": 3,
        "developer": 4,
        "monitoring": 5,
    }
    active_agents.sort(key=lambda a: (
        _ROLE_ORDER.get(a["role"], 99),
        a.get("backend", ""),  # 같은 role 내: claude < codex
    ))

    # 듀얼 모드 감지: 같은 role이 2개 이상이면 backend 표시
    from collections import Counter
    role_counts = Counter(a["role"] for a in active_agents)
    is_dual = any(c > 1 for c in role_counts.values())

    prev_role = None
    for agent in active_agents:
        # 역할 그룹 간 빈 줄 구분
        if prev_role is not None and agent["role"] != prev_role:
            table.add_row("", "", "", "", "", "", "")
        prev_role = agent["role"]
        ds = agent.get("display_status", "CLOSED")
        label, style = _STATUS_STYLE.get(ds, ("?", ""))

        # 태스크 작업 시간: ALIVE + 태스크 있으면 할당 시각부터 경과, 아니면 "--"
        task_started = agent.get("task_started")
        if ds in ("ALIVE",) and task_started:
            elapsed = int((state["now"] - task_started).total_seconds())
            h, rem = divmod(elapsed, 3600)
            m = rem // 60
            time_str = f"{h}h {m}m" if h > 0 else f"{m}m"
        else:
            time_str = "--"

        reboot_str = str(agent["reboots"]) if agent["reboots"] > 0 else ""

        # 듀얼 모드에서 같은 role이 복수면 backend 구분 표시
        role_label = agent["role"]
        if is_dual and role_counts[agent["role"]] > 1:
            backend = agent.get("backend", "")
            role_label = f"{agent['role']}/{backend}"

        # 태스크 표시: 제목이 있으면 "TASK-NNN 제목", 없으면 "--"
        task_id = agent.get("task_id", "")
        task_title = agent.get("task_title", "")
        if task_id and task_title:
            task_str = f"{task_id} {task_title}"
        elif task_id:
            task_str = task_id
        else:
            task_str = "--"

        task_stale = agent.get("task_stale", False)
        report_status = agent.get("report_status", "")
        report_label, report_style = _REPORT_STYLE.get(report_status, ("--", "dim"))
        table.add_row(
            Text(role_label),
            Text(label, style=style),
            Text(agent.get("model", "?")),
            Text(time_str),
            Text(task_str, style="dim" if task_stale else ""),
            Text(report_label, style=report_style),
            Text(reboot_str, style="yellow" if agent["reboots"] > 0 else ""),
        )
    return table


def _render_active_tasks(state: dict) -> Panel | None:
    summaries = state.get("active_task_summaries", [])
    if not summaries:
        return None

    table = Table(
        show_header=True,
        header_style="bold",
        border_style="dim",
        pad_edge=True,
    )
    table.add_column("Task", min_width=20, max_width=38)
    table.add_column("Assignee", min_width=14, max_width=26)
    table.add_column("Elapsed", min_width=7, justify="right")

    now = state["now"]
    for entry in summaries[:6]:
        task_title = entry.get("task_title", "")
        task_label = entry.get("task_id", "")
        if task_title:
            task_label = f"{task_label} {task_title}"
        assignees = ", ".join(entry.get("assignees", []))
        started = entry.get("started")
        if started:
            elapsed = int((now - started).total_seconds())
        else:
            elapsed = -1
        table.add_row(
            Text(task_label or "--"),
            Text(assignees or "--"),
            Text(_format_elapsed_compact(elapsed), style="dim"),
        )

    return Panel(table, title="ACTIVE TASKS", title_align="left", border_style="cyan", expand=False)


_ALERT_KINDS = frozenset({"escalation", "need_input", "user_notice"})


def _render_user_alerts(state: dict) -> Panel | None:
    """유저 대상 알림 패널. alert_resolve로 해결된 건 숨김."""
    # resolve된 subject 수집
    resolved_subjects = {
        e["subject"]
        for e in state["message_log"]
        if e.get("kind") == "alert_resolve" and e.get("receiver") == "user"
    }
    alerts = [
        e for e in state["message_log"]
        if e.get("kind") in _ALERT_KINDS and e.get("receiver") == "user"
        and e["subject"] not in resolved_subjects
    ]
    if not alerts:
        return None
    # 최근 10개, 시간순 역정렬
    alerts.sort(key=lambda e: e["ts"], reverse=True)
    alerts = alerts[:10]

    table = Table(
        show_header=True,
        header_style="bold",
        border_style="dim",
        pad_edge=True,
    )
    table.add_column("Time", min_width=10)
    table.add_column("", min_width=1)  # icon
    table.add_column("From", min_width=8)
    table.add_column("Subject", min_width=30)

    for entry in alerts:
        kind = entry.get("kind", "")
        if kind == "escalation":
            icon = Text("!", style="bold red")
        elif kind == "user_notice":
            icon = Text("i", style="bold cyan")
        else:
            icon = Text("?", style="bold yellow")
        table.add_row(
            Text(_timeline_time(entry["ts"]), style="dim"),
            icon,
            Text(entry["sender"]),
            Text(entry["subject"]),
        )
    return Panel(table, title="USER ALERTS", title_align="left", border_style="red", expand=False)


def _render_waiting_reports(state: dict) -> Panel | None:
    waiting = state.get("waiting_reports", [])
    if not waiting:
        return None

    entry = waiting[0]
    status = entry.get("status", "")
    status_label, status_style = _STATUS_STYLE.get(status, ("?", ""))
    subject = entry.get("subject") or entry.get("task_ref") or "--"
    task_ref = entry.get("task_ref") or "--"
    agent = entry.get("agent", "")
    ts = entry.get("ts")

    body = Text()
    body.append(_timeline_time(ts) if ts else "--", style="dim")
    body.append("  |  ", style="dim")
    body.append(subject, style="bold")
    body.append("\n")
    body.append(agent, style="")
    body.append("  |  ", style="dim")
    body.append(status_label, style=status_style)
    if task_ref and task_ref != "--":
        body.append("  |  ", style="dim")
        body.append(task_ref, style="dim")

    return Panel(
        body,
        title="NEXT TASK WAITING",
        title_align="left",
        border_style="cyan",
        expand=False,
    )


def _render_health_check(state: dict) -> Panel:
    mon = state["monitor"]
    line = Text("  ")
    sep = "  │  "
    if mon["pid"]:
        if mon["alive"]:
            line.append("● Running", style="green")
        else:
            line.append("✗ Down", style="red")
        line.append(sep, style="dim")
        line.append(f"PID {mon['pid']}", style="")
        if mon["heartbeat_age"] is not None:
            hb_style = "green" if mon["heartbeat_age"] < 90 else "red"
            line.append(sep, style="dim")
            line.append(f"Heartbeat {mon['heartbeat_age']}s ago", style=hb_style)
    else:
        line.append("— Not started", style="dim")
    line.append(sep, style="dim")
    line.append(f"Queued {mon['queued']}", style="")
    return Panel(line, title="HEALTH CHECK", title_align="left", border_style="dim", expand=False)


def _event_icon(level: str, message: str) -> tuple[str, str]:
    """이벤트 메시지에 맞는 아이콘과 스타일 반환."""
    msg_lower = message.lower()
    # Check for specific event keywords
    for ev in _ERROR_EVENTS:
        kw = ev.replace("_", " ")
        if kw in msg_lower or ev in msg_lower:
            return "✗", "red"
    for ev in _WARN_EVENTS:
        kw = ev.replace("_", " ")
        if kw in msg_lower or ev in msg_lower:
            return "⚠", "yellow"
    for ev in _SUCCESS_EVENTS:
        kw = ev.replace("_", " ")
        if kw in msg_lower or ev in msg_lower:
            return "✓", "green"

    # Fallback: use log level
    if level == "error":
        return "✗", "red"
    if level == "warn":
        return "⚠", "yellow"
    return "●", ""


# Korean keyword → event type mapping for icon detection
_KR_WARN_KEYWORDS = ["비활성 감지", "재확인", "크래시 감지", "세션 부재", "좀비"]
_KR_SUCCESS_KEYWORDS = ["부팅", "부팅 완료", "활동 재개", "리프레시 완료",
                         "스폰", "전달", "리부팅 성공", "복귀 감지"]
_KR_ERROR_KEYWORDS = ["부팅 실패", "리부팅 실패", "한도 초과", "모니터 종료"]


def _event_icon_kr(level: str, message: str) -> tuple[str, str]:
    """한국어 메시지 기반 아이콘."""
    for kw in _KR_ERROR_KEYWORDS:
        if kw in message:
            return "✗", "red"
    for kw in _KR_WARN_KEYWORDS:
        if kw in message:
            return "⚠", "yellow"
    for kw in _KR_SUCCESS_KEYWORDS:
        if kw in message:
            return "✓", "green"
    return _event_icon(level, message)


_IDLE_FILTER_EVENTS = frozenset({
    "idle_detected", "idle_recheck", "idle_cleared",
})

_IDLE_FILTER_KR = ["비활성 감지", "재확인 예약", "비활성 재확인", "활동 재개"]

_TASK_PATH_RE = re.compile(r'(?:task=|파일=)\S*/?(TASK-\d{3})\S*')

_ROLE_FULL = {
    "mgr": "manager", "dis": "discussion", "dev": "developer", "res": "researcher", "sys": "systems-engineer",
    "mon": "monitoring", "orc": "orchestrator",
}


def _full_name(name: str) -> str:
    return _ROLE_FULL.get(name, name)


def _simplify_system_message(message: str) -> str:
    """풀 경로를 TASK-NNN만 추출하여 축약."""
    m = _TASK_PATH_RE.search(message)
    if m:
        message = _TASK_PATH_RE.sub(m.group(1), message)
    return message


def _is_idle_event(message: str) -> bool:
    """idle_detected/idle_recheck/idle_cleared 이벤트인지 확인."""
    msg_lower = message.lower().replace(" ", "_")
    for ev in _IDLE_FILTER_EVENTS:
        if ev in msg_lower:
            return True
    for kw in _IDLE_FILTER_KR:
        if kw in message:
            return True
    return False


def _classify_system_event(message: str) -> tuple[str, str]:
    """시스템 로그 메시지 → (이벤트 유형 라벨, 스타일)."""
    checks = [
        ("부팅 실패", "boot fail", "red"),
        ("리부팅 실패", "reboot fail", "red"),
        ("한도 초과", "limit hit", "red"),
        ("모니터 종료", "monitor exit", "red"),
        ("크래시 감지", "crash", "red"),
        ("좀비", "zombie", "red"),
        ("세션 부재", "absent", "yellow"),
        ("plan mode 감지", "plan mode", "yellow"),
        ("듀얼 태스크 전달", "task dispatch", ""),
        ("태스크 전달", "task dispatch", ""),
        ("부팅 완료", "boot", ""),
        ("리부팅 성공", "reboot", ""),
        ("스폰", "spawn", ""),
        ("리프레시", "refresh", ""),
        ("활동 재개", "resumed", ""),
        ("모니터 시작", "monitor", ""),
    ]
    for kw, label, style in checks:
        if kw in message:
            return label, style
    return "system", ""


def _timeline_time(ts: datetime) -> str:
    """3분 이내면 'N분 N초 전', 아니면 HH:MM:SS."""
    diff = _now_kst() - ts
    secs = int(diff.total_seconds())
    if secs < 0:
        return "방금"
    if secs < 180:
        m, s = divmod(secs, 60)
        if m > 0:
            return f"{m}분 {s}초 전"
        return f"{s}초 전"
    return ts.strftime("%H:%M:%S")


def _render_timeline(state: dict) -> Table:
    table = Table(
        title="TIMELINE",
        title_style="bold white",
        show_header=True,
        header_style="bold",
        border_style="dim",
    )
    table.add_column("Time", min_width=10)
    table.add_column("Type", min_width=10)
    table.add_column("Event", min_width=40)

    # (ts, type_label, type_style, event_text)
    merged: list[tuple[datetime, str, str, str]] = []

    # system.log
    for entry in state["system_log"]:
        if _is_idle_event(entry["message"]):
            continue
        type_label, type_style = _classify_system_event(entry["message"])
        text = _simplify_system_message(entry["message"])
        merged.append((entry["ts"], type_label, type_style, text))

    # message.log
    for entry in state["message_log"]:
        st = entry["status"]
        if st == "delivered":
            type_label, type_style = "message", ""
        elif st == "skipped":
            type_label, type_style = "msg skip", "yellow"
        elif st == "queued":
            type_label, type_style = "msg queue", "yellow"
        else:
            type_label, type_style = "message", ""
        sender = _full_name(entry["sender"])
        receiver = _full_name(entry["receiver"])
        subject = entry["subject"]
        tm = _TASK_PATH_RE.search(subject)
        if tm:
            subject = _TASK_PATH_RE.sub(tm.group(1), subject)
        text = f'{sender} → {receiver} "{subject}"'
        merged.append((entry["ts"], type_label, type_style, text))

    merged.sort(key=lambda x: x[0])
    recent = merged[-12:]

    if not recent:
        table.add_row("--", "--", "(로그 없음)")
        return table

    for ts, type_label, type_style, text in reversed(recent):
        table.add_row(
            Text(_timeline_time(ts), style="dim"),
            Text(type_label, style=type_style),
            Text(text),
        )
    return table


def _render_footer(interval: int) -> Text:
    text = Text()
    text.append(" Ctrl-C to exit", style="dim")
    text.append("  |  ", style="dim")
    text.append(f"Refresh: {interval}s", style="dim")
    return text


def render(state: dict, interval: int) -> Group:
    """전체 대시보드 렌더링."""
    parts: list = [
        _render_header(state),
        Text(),
        _render_agents(state),
    ]
    active_tasks_panel = _render_active_tasks(state)
    if active_tasks_panel is not None:
        parts.append(Text())
        parts.append(active_tasks_panel)
    parts.extend([
        Text(),
        _render_health_check(state),
    ])
    alerts_panel = _render_user_alerts(state)
    if alerts_panel is not None:
        parts.append(Text())
        parts.append(alerts_panel)
    waiting_panel = _render_waiting_reports(state)
    if waiting_panel is not None:
        parts.append(Text())
        parts.append(waiting_panel)
    parts.extend([
        Text(),
        _render_timeline(state),
        Text(),
        _render_footer(interval),
    ])
    return Group(*parts)


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

    # 프로젝트 정보 (첫 로드만)
    project_info = parse_project_md(project_dir)
    if not project_info["name"]:
        project_info["name"] = project

    # Ctrl-C 깨끗한 종료
    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))

    console = _build_console()
    initial = collect(project_dir, session_name, project_info)
    with Live(
        render(initial, interval),
        console=console,
        refresh_per_second=1,
        screen=False,
    ) as live:
        while True:
            time.sleep(interval)
            state = collect(project_dir, session_name, project_info)
            live.update(render(state, interval))


if __name__ == "__main__":
    main()
