#!/usr/bin/env python3
"""Codex app-server JSON-RPC client for Whiplash framework.

Daemon architecture: boot --daemon forks a long-lived child that holds the
app-server subprocess and watches a file-based command queue.  dispatch writes
a command file and polls for the result.  The daemon PID is stored so monitor
and status can verify liveness.

Usage:
    codex-rpc.py boot      <project> <role> <cwd> [--model M] [--bootstrap MSG] [--daemon]
    codex-rpc.py dispatch   <project> <role> <message> [--cwd CWD]
    codex-rpc.py status     <project> <role>
    codex-rpc.py interrupt  <project> <role>
    codex-rpc.py shutdown   <project> <role>
    codex-rpc.py monitor    <project>
    codex-rpc.py reboot     <project> <role> <cwd> [--model M] [--bootstrap MSG] [--daemon]
"""

import argparse
import asyncio
import glob as globmod
import json
import logging
import os
import signal
import subprocess
import sys
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

CLIENT_NAME = "whiplash"
CLIENT_VERSION = "0.3.0"
TURN_TIMEOUT_S = 300
INIT_TIMEOUT_S = 15
COMPACT_RETRY_DELAY_S = 3
HTTP_RETRY_DELAY_S = 5
DAEMON_POLL_INTERVAL_S = 0.3
DISPATCH_POLL_INTERVAL_S = 0.5
DISPATCH_TIMEOUT_S = 300

logger = logging.getLogger("codex-rpc")


# ---------------------------------------------------------------------------
# Runtime paths
# ---------------------------------------------------------------------------

def get_project_root(project: str) -> Path:
    whiplash_root = Path(os.environ.get(
        "WHIPLASH_ROOT",
        Path(__file__).resolve().parent.parent
    ))
    return whiplash_root / "projects" / project


def get_threads_file(project: str) -> Path:
    return get_project_root(project) / "runtime" / "codex-threads.tsv"

def get_pid_file(project: str, role: str) -> Path:
    return get_project_root(project) / "runtime" / f"codex-{role}.pid"

def get_queue_dir(project: str, role: str) -> Path:
    return get_project_root(project) / "runtime" / "codex-queue" / role

def get_daemon_log(project: str, role: str) -> Path:
    return get_project_root(project) / "logs" / f"codex-{role}-daemon.log"


# --- Thread info persistence ---

def load_thread_info(project: str, role: str) -> Optional[dict]:
    tsv = get_threads_file(project)
    if not tsv.exists():
        return None
    for line in tsv.read_text().splitlines():
        if line.startswith("#") or not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) >= 5 and parts[0] == role:
            return {
                "role": parts[0], "thread_id": parts[1],
                "pid": int(parts[2]) if parts[2].isdigit() else None,
                "status": parts[3], "created_at": parts[4],
                "last_turn_id": parts[5] if len(parts) > 5 else None,
            }
    return None

def save_thread_info(project: str, role: str, thread_id: str,
                     pid: int, status: str = "idle", last_turn_id: str = ""):
    tsv = get_threads_file(project)
    tsv.parent.mkdir(parents=True, exist_ok=True)
    lines, found = [], False
    if tsv.exists():
        for line in tsv.read_text().splitlines():
            if line.startswith("#") or not line.strip():
                lines.append(line); continue
            parts = line.split("\t")
            if parts[0] == role:
                found = True
                lines.append(f"{role}\t{thread_id}\t{pid}\t{status}\t"
                             f"{time.strftime('%Y-%m-%dT%H:%M:%S')}\t{last_turn_id}")
            else:
                lines.append(line)
    if not found:
        if not lines:
            lines.append("# role\tthread_id\tpid\tstatus\tcreated_at\tlast_turn_id")
        lines.append(f"{role}\t{thread_id}\t{pid}\t{status}\t"
                     f"{time.strftime('%Y-%m-%dT%H:%M:%S')}\t{last_turn_id}")
    tsv.write_text("\n".join(lines) + "\n")

def remove_thread_info(project: str, role: str):
    tsv = get_threads_file(project)
    if not tsv.exists(): return
    lines = [l for l in tsv.read_text().splitlines()
             if l.startswith("#") or not l.strip() or l.split("\t")[0] != role]
    tsv.write_text("\n".join(lines) + "\n")


# --- PID helpers ---

def write_pid_file(project: str, role: str, pid: int):
    pf = get_pid_file(project, role)
    pf.parent.mkdir(parents=True, exist_ok=True)
    pf.write_text(str(pid))

def read_pid_file(project: str, role: str) -> Optional[int]:
    pf = get_pid_file(project, role)
    if pf.exists():
        try: return int(pf.read_text().strip())
        except ValueError: return None
    return None

def remove_pid_file(project: str, role: str):
    get_pid_file(project, role).unlink(missing_ok=True)

def is_pid_alive(pid: Optional[int]) -> bool:
    if not pid: return False
    try: os.kill(pid, 0); return True
    except (OSError, ProcessLookupError): return False

def kill_pid(pid, graceful_wait=5):
    if not is_pid_alive(pid): return
    os.kill(pid, signal.SIGTERM)
    for _ in range(graceful_wait * 2):
        if not is_pid_alive(pid): return
        time.sleep(0.5)
    if is_pid_alive(pid):
        os.kill(pid, signal.SIGKILL)


# ---------------------------------------------------------------------------
# JSON-RPC client  (unchanged core — async, holds app-server subprocess)
# ---------------------------------------------------------------------------

@dataclass
class CodexAppServerClient:
    project: str
    role: str
    process: Optional[subprocess.Popen] = field(default=None, repr=False)
    thread_id: Optional[str] = None
    _request_id: int = 0
    _pending: dict = field(default_factory=dict, repr=False)
    _reader_task: Optional[asyncio.Task] = field(default=None, repr=False)
    _notification_handlers: dict = field(default_factory=dict, repr=False)
    _agent_text: str = field(default="", repr=False)
    _last_turn_items: list = field(default_factory=list, repr=False)

    async def start(self, model=None, cwd=".", sandbox="danger-full-access"):
        self.process = subprocess.Popen(
            ["codex", "app-server", "--listen", "stdio://", "--session-source", CLIENT_NAME],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, bufsize=1,
        )
        logger.info("app-server PID %d", self.process.pid)
        self._reader_task = asyncio.create_task(self._read_loop())
        result = await self._request("initialize", {
            "clientInfo": {"name": f"{CLIENT_NAME}-{self.project}",
                           "title": f"Whiplash {self.project}/{self.role}",
                           "version": CLIENT_VERSION},
            "capabilities": {"experimentalApi": False},
        }, timeout=INIT_TIMEOUT_S)
        logger.info("Initialized: %s", result.get("userAgent", "?"))
        await self._notify("initialized", {})
        params: dict[str, Any] = {"cwd": cwd, "approvalPolicy": "never", "sandbox": sandbox}
        if model: params["model"] = model
        result = await self._request("thread/start", params, timeout=INIT_TIMEOUT_S)
        self.thread_id = result["thread"]["id"]
        logger.info("Thread %s (model=%s)", self.thread_id, result.get("model", "?"))
        return self.thread_id

    async def start_and_resume(self, thread_id, model=None, cwd="."):
        self.process = subprocess.Popen(
            ["codex", "app-server", "--listen", "stdio://", "--session-source", CLIENT_NAME],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, bufsize=1,
        )
        logger.info("app-server PID %d (resume)", self.process.pid)
        self._reader_task = asyncio.create_task(self._read_loop())
        await self._request("initialize", {
            "clientInfo": {"name": f"{CLIENT_NAME}-{self.project}",
                           "title": f"Whiplash {self.project}/{self.role}",
                           "version": CLIENT_VERSION},
            "capabilities": {"experimentalApi": False},
        }, timeout=INIT_TIMEOUT_S)
        await self._notify("initialized", {})
        params: dict[str, Any] = {"threadId": thread_id}
        if model: params["model"] = model
        result = await self._request("thread/resume", params, timeout=INIT_TIMEOUT_S)
        self.thread_id = result["thread"]["id"]
        logger.info("Thread resumed: %s", self.thread_id)
        return self.thread_id

    async def shutdown(self):
        if self._reader_task:
            self._reader_task.cancel()
            try: await self._reader_task
            except asyncio.CancelledError: pass
        if self.process:
            try: self.process.stdin.close()
            except (BrokenPipeError, OSError): pass
            self.process.terminate()
            try: self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill(); self.process.wait(timeout=3)
            logger.info("app-server shut down")

    async def send_turn(self, message: str, timeout: float = TURN_TIMEOUT_S) -> dict:
        if not self.thread_id: raise RuntimeError("No active thread")
        self._agent_text = ""
        self._last_turn_items = []
        result = await self._request("turn/start", {
            "threadId": self.thread_id,
            "input": [{"type": "text", "text": message}],
        }, timeout=10)
        turn_id = result["turn"]["id"]
        logger.info("Turn started: %s", turn_id)
        completed = await self._wait_notification(
            "turn/completed",
            lambda p: p.get("turn", {}).get("id") == turn_id,
            timeout=timeout,
        )
        turn = completed.get("turn", {})
        turn["agent_text"] = self._agent_text
        turn["items"] = self._last_turn_items
        status = turn.get("status", "unknown")
        if status == "failed":
            error_info = turn.get("error", {}).get("codexErrorInfo", "")
            logger.error("Turn failed: %s", error_info)
            turn = await self._handle_turn_error(error_info, message, timeout)
        return turn

    async def _handle_turn_error(self, error_info, original_message, timeout):
        if error_info == "ContextWindowExceeded":
            try:
                await self._request("thread/compact/start", {"threadId": self.thread_id}, timeout=30)
                await asyncio.sleep(COMPACT_RETRY_DELAY_S)
                return await self.send_turn(original_message, timeout)
            except Exception as e:
                return {"status": "failed", "error": {"codexErrorInfo": error_info, "message": str(e)}, "agent_text": ""}
        if error_info in ("HttpConnectionFailed", "ResponseStreamConnectionFailed", "ResponseStreamDisconnected"):
            await asyncio.sleep(HTTP_RETRY_DELAY_S)
            try: return await self.send_turn(original_message, timeout)
            except Exception as e:
                return {"status": "failed", "error": {"codexErrorInfo": error_info, "message": str(e)}, "agent_text": ""}
        return {"status": "failed", "error": {"codexErrorInfo": error_info}, "agent_text": self._agent_text}

    # --- low-level JSON-RPC ---

    async def _request(self, method, params, timeout=10):
        self._request_id += 1
        mid = self._request_id
        fut = asyncio.get_event_loop().create_future()
        self._pending[mid] = fut
        msg = json.dumps({"method": method, "id": mid, "params": params})
        try: self.process.stdin.write(msg + "\n"); self.process.stdin.flush()
        except (BrokenPipeError, OSError) as e:
            self._pending.pop(mid, None); raise RuntimeError(f"pipe broken: {e}")
        try: result = await asyncio.wait_for(fut, timeout=timeout)
        except asyncio.TimeoutError:
            self._pending.pop(mid, None); raise TimeoutError(f"{method} timed out ({timeout}s)")
        if "error" in result:
            err = result["error"]
            raise RuntimeError(f"RPC {err.get('code')}: {err.get('message')} [{err.get('data',{}).get('codexErrorInfo','')}]")
        return result.get("result", {})

    async def _notify(self, method, params):
        self.process.stdin.write(json.dumps({"method": method, "params": params}) + "\n")
        self.process.stdin.flush()

    async def _read_loop(self):
        loop = asyncio.get_event_loop()
        reader = asyncio.StreamReader()
        transport, _ = await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), self.process.stdout)
        try:
            while True:
                line = await reader.readline()
                if not line: break
                text = line.decode().strip() if isinstance(line, bytes) else line.strip()
                if not text: continue
                try: msg = json.loads(text)
                except json.JSONDecodeError: continue
                if "id" in msg and msg["id"] in self._pending:
                    f = self._pending.pop(msg["id"])
                    if not f.done(): f.set_result(msg)
                    continue
                if "id" in msg and "method" in msg:
                    await self._handle_server_request(msg); continue
                self._dispatch_notification(msg.get("method", ""), msg.get("params", {}))
        except asyncio.CancelledError: pass
        except Exception as e:
            logger.error("Reader died: %s", e)
            for f in self._pending.values():
                if not f.done(): f.set_exception(RuntimeError(str(e)))
            self._pending.clear()
        finally: transport.close()

    async def _handle_server_request(self, msg):
        method, mid = msg.get("method", ""), msg["id"]
        if "requestApproval" in method:
            self.process.stdin.write(json.dumps({"id": mid, "result": {"decision": "accept"}}) + "\n"); self.process.stdin.flush()
        elif method == "item/tool/requestUserInput":
            self.process.stdin.write(json.dumps({"id": mid, "result": {"answers": []}}) + "\n"); self.process.stdin.flush()
        elif method == "item/tool/call":
            self.process.stdin.write(json.dumps({"id": mid, "result": {"contentItems": [{"type": "text", "text": "OK"}], "success": True}}) + "\n"); self.process.stdin.flush()

    def _dispatch_notification(self, method, params):
        if method == "item/agentMessage/delta":
            self._agent_text += params.get("delta", "")
        if method == "item/completed":
            item = params.get("item", {})
            self._last_turn_items.append({"type": item.get("type"), "text": item.get("text", "")})
        for key, waiters in list(self._notification_handlers.items()):
            if key == method:
                for wf, pred in waiters[:]:
                    if pred is None or pred(params):
                        if not wf.done(): wf.set_result(params)
                        waiters.remove((wf, pred))
                if not waiters: del self._notification_handlers[key]

    async def _wait_notification(self, method, predicate=None, timeout=60):
        fut = asyncio.get_event_loop().create_future()
        self._notification_handlers.setdefault(method, []).append((fut, predicate))
        return await asyncio.wait_for(fut, timeout=timeout)


# ---------------------------------------------------------------------------
# Daemon process  (long-lived, watches command queue)
# ---------------------------------------------------------------------------

async def daemon_main(project: str, role: str, client: CodexAppServerClient):
    """Event loop for the daemon: watch queue dir for command files."""
    qdir = get_queue_dir(project, role)
    qdir.mkdir(parents=True, exist_ok=True)
    logger.info("Daemon ready, watching %s", qdir)

    save_thread_info(project, role, client.thread_id,
                     client.process.pid, "idle")

    while True:
        # Check app-server health
        if client.process.poll() is not None:
            logger.error("app-server process died (exit=%s)", client.process.returncode)
            save_thread_info(project, role, client.thread_id, 0, "crashed")
            break

        # Scan for command files
        cmd_files = sorted(globmod.glob(str(qdir / "cmd-*.json")))
        for cmd_path in cmd_files:
            cmd_file = Path(cmd_path)
            try:
                cmd = json.loads(cmd_file.read_text())
            except Exception:
                cmd_file.unlink(missing_ok=True)
                continue

            cmd_id = cmd.get("id", cmd_file.stem)
            action = cmd.get("action", "turn")
            result_file = qdir / f"result-{cmd_id}.json"

            if action == "turn":
                message = cmd.get("message", "")
                logger.info("Processing turn: %s", cmd_id)
                save_thread_info(project, role, client.thread_id,
                                 client.process.pid, "active")
                try:
                    turn = await client.send_turn(message, timeout=TURN_TIMEOUT_S)
                    result_file.write_text(json.dumps({
                        "status": turn.get("status", "unknown"),
                        "agent_text": turn.get("agent_text", ""),
                        "error": turn.get("error"),
                    }))
                except Exception as e:
                    logger.error("Turn error: %s", e)
                    result_file.write_text(json.dumps({
                        "status": "failed",
                        "agent_text": "",
                        "error": {"message": str(e)},
                    }))
                save_thread_info(project, role, client.thread_id,
                                 client.process.pid, "idle")

            elif action == "shutdown":
                logger.info("Shutdown requested")
                result_file.write_text(json.dumps({"status": "ok"}))
                cmd_file.unlink(missing_ok=True)
                break

            cmd_file.unlink(missing_ok=True)
        else:
            await asyncio.sleep(DAEMON_POLL_INTERVAL_S)
            continue
        # break from inner loop → exit outer
        break

    # Cleanup
    await client.shutdown()
    save_thread_info(project, role, client.thread_id or "", 0, "stopped")
    remove_pid_file(project, role)
    logger.info("Daemon exiting")


def fork_daemon(project: str, role: str):
    """Double-fork to daemonize. Returns child PID to parent, runs daemon in child."""
    # First fork
    pid = os.fork()
    if pid > 0:
        # Parent: return daemon PID
        return pid

    # Child: create new session
    os.setsid()

    # Second fork (prevent acquiring terminal)
    pid2 = os.fork()
    if pid2 > 0:
        os._exit(0)

    # Grandchild: this is the daemon
    # Redirect stdio to log file
    log_path = get_daemon_log(project, role)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_fd = os.open(str(log_path), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    os.dup2(log_fd, 1)  # stdout
    os.dup2(log_fd, 2)  # stderr
    devnull = os.open(os.devnull, os.O_RDONLY)
    os.dup2(devnull, 0)  # stdin

    # Write PID file
    write_pid_file(project, role, os.getpid())
    return 0  # signal that we are the daemon


# ---------------------------------------------------------------------------
# CLI subcommands
# ---------------------------------------------------------------------------

async def cmd_boot(args):
    """Boot: start app-server, create/resume thread, optionally daemonize."""
    # Kill any leftover daemon
    old_pid = read_pid_file(args.project, args.role)
    if old_pid and is_pid_alive(old_pid):
        kill_pid(old_pid)

    # Clean queue
    qdir = get_queue_dir(args.project, args.role)
    if qdir.exists():
        for f in qdir.iterdir():
            f.unlink(missing_ok=True)

    # Try resume existing thread
    info = load_thread_info(args.project, args.role)
    client = CodexAppServerClient(project=args.project, role=args.role)

    try:
        if info and info.get("thread_id") and info["status"] != "stopped":
            try:
                await client.start_and_resume(info["thread_id"], model=args.model, cwd=args.cwd)
                print(f"thread_id={client.thread_id}")
                print(f"resumed=true")
            except Exception:
                await _safe_shutdown(client)
                client = CodexAppServerClient(project=args.project, role=args.role)
                await client.start(model=args.model, cwd=args.cwd)
                print(f"thread_id={client.thread_id}")
                print(f"resumed=false")
        else:
            await client.start(model=args.model, cwd=args.cwd)
            print(f"thread_id={client.thread_id}")
            print(f"resumed=false")

        print(f"pid={client.process.pid}")

        # Bootstrap
        if args.bootstrap:
            msg = args.bootstrap
            if os.path.isfile(msg):
                msg = Path(msg).read_text()
            turn = await client.send_turn(msg)
            print(f"bootstrap_status={turn.get('status', 'unknown')}")

    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        await _safe_shutdown(client)
        sys.exit(1)

    if args.daemon:
        # Save state, then fork daemon
        save_thread_info(args.project, args.role, client.thread_id,
                         client.process.pid, "idle")
        # We need to hand the app-server process to the daemon.
        # Since we can't pass subprocess across fork easily,
        # the daemon approach: shut down this client, fork, re-start in daemon.
        # Store thread_id for resume.
        thread_id = client.thread_id
        await client.shutdown()

        daemon_pid = fork_daemon(args.project, args.role)
        if daemon_pid > 0:
            # Parent: wait a moment for daemon to start, then report
            time.sleep(1)
            actual_pid = read_pid_file(args.project, args.role)
            print(f"daemon_pid={actual_pid or daemon_pid}")
            print("OK")
            return

        # We are the daemon process now — need a fresh event loop
        logging.basicConfig(
            level=logging.INFO,
            format="%(asctime)s [%(levelname)s] %(message)s",
            force=True,
        )
        logger.info("Daemon started (PID %d), resuming thread %s", os.getpid(), thread_id)

        async def _daemon_entry():
            daemon_client = CodexAppServerClient(project=args.project, role=args.role)
            try:
                await daemon_client.start_and_resume(thread_id, model=args.model, cwd=args.cwd)
                save_thread_info(args.project, args.role, daemon_client.thread_id,
                                 os.getpid(), "idle")
                await daemon_main(args.project, args.role, daemon_client)
            except Exception as e:
                logger.error("Daemon startup failed: %s", e)
                await _safe_shutdown(daemon_client)
                save_thread_info(args.project, args.role, thread_id, 0, "crashed")
                remove_pid_file(args.project, args.role)

        asyncio.run(_daemon_entry())
        os._exit(0)
    else:
        print("OK")
        await client.shutdown()


async def cmd_dispatch(args):
    """Dispatch: write command to queue, poll for result."""
    info = load_thread_info(args.project, args.role)
    if not info:
        print("ERROR: No thread found", file=sys.stderr)
        sys.exit(1)

    daemon_pid = read_pid_file(args.project, args.role)

    if daemon_pid and is_pid_alive(daemon_pid):
        # Daemon alive — use file-based IPC
        qdir = get_queue_dir(args.project, args.role)
        qdir.mkdir(parents=True, exist_ok=True)
        cmd_id = str(uuid.uuid4())[:8]
        cmd_file = qdir / f"cmd-{cmd_id}.json"
        result_file = qdir / f"result-{cmd_id}.json"

        cmd_file.write_text(json.dumps({
            "id": cmd_id,
            "action": "turn",
            "message": args.message,
        }))

        # Poll for result
        deadline = time.time() + DISPATCH_TIMEOUT_S
        while time.time() < deadline:
            if result_file.exists():
                try:
                    result = json.loads(result_file.read_text())
                    result_file.unlink(missing_ok=True)
                    print(f"turn_status={result.get('status', 'unknown')}")
                    if result.get("agent_text"):
                        print(f"agent_text={result['agent_text'][:500]}")
                    if result.get("status") == "failed":
                        err = result.get("error", {})
                        print(f"error_info={err.get('codexErrorInfo', err.get('message', 'unknown'))}")
                    return
                except Exception as e:
                    print(f"ERROR: bad result: {e}", file=sys.stderr)
                    result_file.unlink(missing_ok=True)
                    sys.exit(1)
            time.sleep(DISPATCH_POLL_INTERVAL_S)

        # Timeout
        cmd_file.unlink(missing_ok=True)
        print("ERROR: dispatch timed out", file=sys.stderr)
        sys.exit(1)

    else:
        # No daemon — spawn ephemeral app-server, resume, do turn, shut down
        client = CodexAppServerClient(project=args.project, role=args.role)
        try:
            await client.start_and_resume(info["thread_id"], cwd=args.cwd or ".")
            turn = await client.send_turn(args.message)
            print(f"turn_status={turn.get('status', 'unknown')}")
            if turn.get("agent_text"):
                print(f"agent_text={turn['agent_text'][:500]}")
            save_thread_info(args.project, args.role, client.thread_id,
                             0, "idle", turn.get("id", ""))
        except Exception as e:
            print(f"ERROR: {e}", file=sys.stderr)
            sys.exit(1)
        finally:
            await client.shutdown()


async def cmd_status(args):
    info = load_thread_info(args.project, args.role)
    if not info:
        print(json.dumps({"alive": False, "reason": "no_thread_entry"}))
        return
    pid = read_pid_file(args.project, args.role) or info.get("pid")
    print(json.dumps({
        "alive": is_pid_alive(pid),
        "thread_id": info["thread_id"],
        "pid": pid,
        "status": info["status"],
        "last_turn_id": info.get("last_turn_id"),
    }))


async def cmd_interrupt(args):
    pid = read_pid_file(args.project, args.role)
    if pid and is_pid_alive(pid):
        os.kill(pid, signal.SIGINT)
        print(f"SIGINT sent to PID {pid}")
    else:
        print("ERROR: No live process", file=sys.stderr)
        sys.exit(1)


async def cmd_shutdown(args):
    info = load_thread_info(args.project, args.role)
    pid = read_pid_file(args.project, args.role)
    if not pid and info:
        pid = info.get("pid")

    if pid and is_pid_alive(pid):
        # Try graceful via queue
        qdir = get_queue_dir(args.project, args.role)
        qdir.mkdir(parents=True, exist_ok=True)
        cmd_id = "shutdown"
        (qdir / f"cmd-{cmd_id}.json").write_text(json.dumps({"id": cmd_id, "action": "shutdown"}))
        # Wait briefly
        for _ in range(10):
            if not is_pid_alive(pid): break
            time.sleep(0.5)
        if is_pid_alive(pid):
            kill_pid(pid)
        print(f"Process {pid} terminated")

    remove_pid_file(args.project, args.role)
    if info:
        save_thread_info(args.project, args.role, info["thread_id"],
                         0, "stopped", info.get("last_turn_id", ""))
    print("OK")


async def cmd_reboot(args):
    """Kill existing, then boot (with resume)."""
    # Shutdown existing
    old_pid = read_pid_file(args.project, args.role)
    if old_pid and is_pid_alive(old_pid):
        kill_pid(old_pid)
    remove_pid_file(args.project, args.role)

    # Delegate to boot (which tries resume)
    await cmd_boot(args)


async def cmd_monitor(args):
    tsv = get_threads_file(args.project)
    if not tsv.exists():
        print(json.dumps({"agents": []})); return
    agents = []
    for line in tsv.read_text().splitlines():
        if line.startswith("#") or not line.strip(): continue
        parts = line.split("\t")
        if len(parts) < 4: continue
        role, thread_id, pid_str, status = parts[0], parts[1], parts[2], parts[3]
        pid = read_pid_file(args.project, role) or (int(pid_str) if pid_str.isdigit() else None)
        agents.append({"role": role, "thread_id": thread_id, "pid": pid,
                        "status": status, "alive": is_pid_alive(pid)})
    print(json.dumps({"agents": agents}))


async def _safe_shutdown(client):
    try: await client.shutdown()
    except Exception: pass


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Codex app-server JSON-RPC client")
    parser.add_argument("-v", "--verbose", action="store_true")
    sub = parser.add_subparsers(dest="command", required=True)

    for name, hlp in [("boot", "Boot agent"), ("reboot", "Reboot agent")]:
        p = sub.add_parser(name, help=hlp)
        p.add_argument("project"); p.add_argument("role"); p.add_argument("cwd")
        p.add_argument("--model", default=None)
        p.add_argument("--bootstrap", default=None)
        p.add_argument("--daemon", action="store_true")

    p = sub.add_parser("dispatch", help="Send message")
    p.add_argument("project"); p.add_argument("role"); p.add_argument("message")
    p.add_argument("--cwd", default=None)

    for name in ["status", "interrupt", "shutdown"]:
        p = sub.add_parser(name)
        p.add_argument("project"); p.add_argument("role")

    p = sub.add_parser("monitor"); p.add_argument("project")

    args = parser.parse_args()
    level = logging.DEBUG if args.verbose else logging.INFO
    logging.basicConfig(level=level, format="%(asctime)s [%(levelname)s] %(message)s", stream=sys.stderr)

    asyncio.run({"boot": cmd_boot, "dispatch": cmd_dispatch, "status": cmd_status,
                 "interrupt": cmd_interrupt, "shutdown": cmd_shutdown,
                 "reboot": cmd_reboot, "monitor": cmd_monitor}[args.command](args))

if __name__ == "__main__":
    main()
