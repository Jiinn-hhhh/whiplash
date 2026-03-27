#!/usr/bin/env python3
"""구조화 텍스트 로거 — system.log / message.log 기록.

Usage:
  python3 log.py system {project} {source} {event} {target} [--detail k=v ...] [--level info]
  python3 log.py message {project} {from} {to} {kind} {priority} {subject} {status} [--reason ...]

출력 형식:
  system.log:   2026-03-03 18:35:42 [info] orchestrator agent_boot researcher session=abc-123
  message.log:  2026-03-03 18:35:42 [delivered] researcher → manager task_complete normal "TASK-001 완료"
               (kind와 priority가 subject 앞에 기록됨)
"""

import argparse
import fcntl
import os
import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path

# ──────────────────────────────────────────────
# 이벤트 → 레벨 자동 결정 테이블
# ──────────────────────────────────────────────

_ERROR_EVENTS = frozenset({
    "agent_boot_fail", "reboot_failed", "reboot_limit",
    "monitor_exit", "monitor_zombie", "manager_crash_alert",
})

_WARN_EVENTS = frozenset({
    "crash_detected", "idle_detected", "idle_dead", "idle_recheck", "agent_kill",
    "monitor_restart", "monitor_orphaned", "session_absent", "notify_delivery_fail",
    "session_absent_confirmed", "reboot_count_reset", "plan_mode_detected",
    "auth_blocked_detected", "auth_blocked_recovery_skip",
})


def _auto_level(event: str) -> str:
    if event in _ERROR_EVENTS:
        return "error"
    if event in _WARN_EVENTS:
        return "warn"
    return "info"


# {target}이 자연스럽게 들어가는 한국어 템플릿
_EVENT_TEMPLATES: dict[str, str] = {
    "project_boot_start": "{target} 프로젝트 부팅 시작",
    "project_boot_end": "{target} 프로젝트 부팅 완료",
    "project_shutdown": "{target} 프로젝트 종료",
    "agent_boot": "{target} 부팅",
    "agent_boot_fail": "{target} 부팅 실패",
    "agent_spawn": "{target} 스폰",
    "agent_kill": "{target} 종료",
    "agent_reboot": "{target} 리부팅",
    "agent_refresh_start": "{target} 리프레시 시작",
    "agent_refresh_end": "{target} 리프레시 완료",
    "manager_boot": "{target} 매니저 부팅",
    "codex_boot": "{target} codex 부팅",
    "task_dispatch": "{target} 태스크 전달",
    "task_assign": "{target} 태스크 할당 기록",
    "task_complete": "{target} 태스크 완료 처리",
    "dual_dispatch": "{target} 듀얼 태스크 전달",
    "crash_detected": "{target} 크래시 감지",
    "reboot_success": "{target} 리부팅 성공",
    "reboot_failed": "{target} 리부팅 실패",
    "reboot_limit": "{target} 리부팅 한도 초과",
    "idle_detected": "{target} 비활성 감지",
    "idle_recheck": "{target} 비활성 재확인",
    "idle_cleared": "{target} 활동 재개",
    "monitor_start": "모니터 시작",
    "monitor_started": "모니터 시작",
    "monitor_restart": "모니터 재시작",
    "monitor_exit": "모니터 종료",
    "monitor_zombie": "모니터 좀비 감지",
    "plan_mode_detected": "{target} plan mode 감지",
    "plan_mode_cleared": "{target} plan mode 해제",
    "auth_blocked_detected": "{target} auth blocked 감지",
    "auth_blocked_cleared": "{target} auth blocked 해제",
    "auth_blocked_recovery_skip": "{target} auth blocked로 복구 중단",
    "session_absent": "{target} 세션 부재",
    "manager_crash_alert": "{target} 매니저 크래시",
    "notify_delivery_fail": "{target} 알림 전달 실패",
    "session_absent_confirmed": "{target} 세션 부재 확인 (대기 모드)",
    "session_recovered": "{target} 세션 복귀 감지",
    "reboot_count_reset": "{target} 리부팅 카운터 리셋",
}


# ──────────────────────────────────────────────
# 유틸리티
# ──────────────────────────────────────────────

def _repo_root() -> str:
    return str(Path(__file__).resolve().parent.parent)


def _validate_project(name: str) -> None:
    if not name or "/" in name or ".." in name:
        raise ValueError(f"잘못된 project 이름: {name}")


_KST = timezone(timedelta(hours=9))


def _now_kst() -> str:
    return datetime.now(_KST).strftime("%Y-%m-%d %H:%M:%S")


# ──────────────────────────────────────────────
# 로테이션 + 쓰기
# ──────────────────────────────────────────────

_MAX_SIZE = 10 * 1024 * 1024  # 10 MB
_MAX_GEN = 3


def _rotate(path: str) -> None:
    """10MB 초과 시 rolling (최대 3세대: .1, .2, .3)."""
    try:
        size = os.path.getsize(path)
    except OSError:
        return
    if size <= _MAX_SIZE:
        return
    for i in range(_MAX_GEN, 1, -1):
        src = f"{path}.{i - 1}"
        dst = f"{path}.{i}"
        if os.path.exists(src):
            os.replace(src, dst)
    if os.path.exists(path):
        os.replace(path, f"{path}.1")


def _append_line(path: str, line: str) -> None:
    """한 줄 append (flock 보호, 로테이션 포함)."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    _rotate(path)
    data = line + "\n"
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        os.write(fd, data.encode())
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


# ──────────────────────────────────────────────
# 서브커맨드 핸들러
# ──────────────────────────────────────────────

def cmd_system(args: argparse.Namespace) -> None:
    _validate_project(args.project)
    level = args.level if args.level else _auto_level(args.event)

    # 2026-03-03 18:35:42 [info] researcher 부팅 session=abc-123
    template = _EVENT_TEMPLATES.get(args.event)
    if template:
        msg = template.format(target=args.target)
    else:
        msg = f"{args.event} {args.target}"

    if args.detail:
        # L-06: detail 값의 뉴라인을 공백으로 치환
        sanitized = [d.replace("\n", " ").replace("\r", " ") for d in args.detail]
        msg += " " + " ".join(sanitized)

    parts = [_now_kst(), f"[{level}]", msg]

    root = _repo_root()
    path = os.path.join(root, "projects", args.project, "logs", "system.log")
    _append_line(path, " ".join(parts))


def cmd_message(args: argparse.Namespace) -> None:
    _validate_project(args.project)
    sender = getattr(args, "from")

    # 2026-03-03 18:35:42 [delivered] researcher → manager task_complete normal "TASK-001 완료"
    msg_parts = [sender, "→", args.to, args.kind, args.priority, f'"{args.subject}"']
    if args.reason:
        msg_parts.append(f'reason="{" ".join(args.reason)}"')

    parts = [_now_kst(), f"[{args.status}]", " ".join(msg_parts)]

    root = _repo_root()
    path = os.path.join(root, "projects", args.project, "logs", "message.log")
    _append_line(path, " ".join(parts))


# ──────────────────────────────────────────────
# CLI
# ──────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(description="구조화 텍스트 로거")
    sub = parser.add_subparsers(dest="command", required=True)

    # system
    p_sys = sub.add_parser("system", help="인프라 이벤트 기록 → system.log")
    p_sys.add_argument("project")
    p_sys.add_argument("source")
    p_sys.add_argument("event")
    p_sys.add_argument("target")
    p_sys.add_argument("--detail", nargs="*", metavar="k=v", help="추가 세부 정보 (key=value)")
    p_sys.add_argument("--level", choices=["info", "warn", "error"], default=None,
                        help="로그 레벨 (미지정 시 이벤트 기반 자동 결정)")

    # message
    p_msg = sub.add_parser("message", help="에이전트 간 메시지 기록 → message.log")
    p_msg.add_argument("project")
    p_msg.add_argument("from", metavar="from")
    p_msg.add_argument("to")
    p_msg.add_argument("kind")
    p_msg.add_argument("priority")
    p_msg.add_argument("subject")
    p_msg.add_argument("status", choices=["delivered", "skipped", "queued"])
    p_msg.add_argument("--reason", nargs="*", help="skipped 사유")

    args = parser.parse_args()

    if args.command == "system":
        cmd_system(args)
    elif args.command == "message":
        cmd_message(args)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"[log.py] {exc}", file=sys.stderr)
        sys.exit(0)  # 로깅 실패가 주 동작을 중단하면 안 됨
