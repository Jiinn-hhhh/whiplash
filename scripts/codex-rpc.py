#!/usr/bin/env python3
"""Codex app-server JSON-RPC client for Whiplash framework.

Provides programmatic control of Codex agents via the app-server stdio protocol,
replacing the tmux-based interactive CLI approach.

Usage:
    codex-rpc.py boot      <project> <role> <cwd> [--model MODEL] [--bootstrap MSG|FILE]
    codex-rpc.py dispatch   <project> <role> <message> [--cwd CWD]
    codex-rpc.py status     <project> <role>
    codex-rpc.py interrupt  <project> <role>
    codex-rpc.py shutdown   <project> <role>
    codex-rpc.py monitor    <project>
    codex-rpc.py reboot     <project> <role> <cwd> [--model MODEL] [--bootstrap MSG|FILE]
"""

import argparse
import asyncio
import json
import logging
import os
import signal
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

CLIENT_NAME = "whiplash"
CLIENT_VERSION = "0.2.0"
TURN_TIMEOUT_S = 300        # 5 minutes per turn
INIT_TIMEOUT_S = 15
COMPACT_RETRY_DELAY_S = 3
MAX_ERROR_RETRIES = 2
HTTP_RETRY_DELAY_S = 5

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
                "role": parts[0],
                "thread_id": parts[1],
                "pid": int(parts[2]) if parts[2].isdigit() else None,
                "status": parts[3],
                "created_at": parts[4],
                "last_turn_id": parts[5] if len(parts) > 5 else None,
            }
    return None


def save_thread_info(project: str, role: str, thread_id: str,
                     pid: int, status: str = "idle",
                     last_turn_id: str = ""):
    tsv = get_threads_file(project)
    tsv.parent.mkdir(parents=True, exist_ok=True)

    lines = []
    found = False
    if tsv.exists():
        for line in tsv.read_text().splitlines():
            if line.startswith("#") or not line.strip():
                lines.append(line)
                continue
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
    if not tsv.exists():
        return
    lines = [l for l in tsv.read_text().splitlines()
             if l.startswith("#") or not l.strip() or l.split("\t")[0] != role]
    tsv.write_text("\n".join(lines) + "\n")


def write_pid_file(project: str, role: str, pid: int):
    pf = get_pid_file(project, role)
    pf.parent.mkdir(parents=True, exist_ok=True)
    pf.write_text(str(pid))


def read_pid_file(project: str, role: str) -> Optional[int]:
    pf = get_pid_file(project, role)
    if pf.exists():
        try:
            return int(pf.read_text().strip())
        except ValueError:
            return None
    return None


def remove_pid_file(project: str, role: str):
    pf = get_pid_file(project, role)
    pf.unlink(missing_ok=True)


def is_pid_alive(pid: Optional[int]) -> bool:
    if not pid:
        return False
    try:
        os.kill(pid, 0)
        return True
    except (OSError, ProcessLookupError):
        return False


# ---------------------------------------------------------------------------
# JSON-RPC client
# ---------------------------------------------------------------------------

@dataclass
class CodexAppServerClient:
    """Async JSON-RPC 2.0 client for Codex app-server (stdio transport)."""

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

    # -- Lifecycle ----------------------------------------------------------

    async def start(self, model: Optional[str] = None,
                    cwd: str = ".",
                    sandbox: str = "danger-full-access"):
        """Spawn app-server process, handshake, and create thread."""
        self.process = subprocess.Popen(
            ["codex", "app-server", "--listen", "stdio://",
             "--session-source", CLIENT_NAME],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        logger.info("app-server started (PID %d)", self.process.pid)
        write_pid_file(self.project, self.role, self.process.pid)

        self._reader_task = asyncio.create_task(self._read_loop())

        result = await self._request("initialize", {
            "clientInfo": {
                "name": f"{CLIENT_NAME}-{self.project}",
                "title": f"Whiplash {self.project}/{self.role}",
                "version": CLIENT_VERSION,
            },
            "capabilities": {"experimentalApi": False},
        }, timeout=INIT_TIMEOUT_S)
        logger.info("Initialized: %s", result.get("userAgent", "?"))

        await self._notify("initialized", {})

        params: dict[str, Any] = {
            "cwd": cwd,
            "approvalPolicy": "never",
            "sandbox": sandbox,
        }
        if model:
            params["model"] = model

        result = await self._request("thread/start", params, timeout=INIT_TIMEOUT_S)
        self.thread_id = result["thread"]["id"]
        actual_model = result.get("model", "default")

        save_thread_info(self.project, self.role, self.thread_id,
                         self.process.pid, "idle")
        logger.info("Thread created: %s (model=%s)", self.thread_id, actual_model)
        return self.thread_id

    async def start_and_resume(self, thread_id: str,
                               model: Optional[str] = None,
                               cwd: str = "."):
        """Spawn app-server, handshake, and resume existing thread."""
        self.process = subprocess.Popen(
            ["codex", "app-server", "--listen", "stdio://",
             "--session-source", CLIENT_NAME],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        logger.info("app-server started for resume (PID %d)", self.process.pid)
        write_pid_file(self.project, self.role, self.process.pid)

        self._reader_task = asyncio.create_task(self._read_loop())

        await self._request("initialize", {
            "clientInfo": {
                "name": f"{CLIENT_NAME}-{self.project}",
                "title": f"Whiplash {self.project}/{self.role}",
                "version": CLIENT_VERSION,
            },
            "capabilities": {"experimentalApi": False},
        }, timeout=INIT_TIMEOUT_S)
        await self._notify("initialized", {})

        params: dict[str, Any] = {"threadId": thread_id}
        if model:
            params["model"] = model
        result = await self._request("thread/resume", params, timeout=INIT_TIMEOUT_S)
        self.thread_id = result["thread"]["id"]

        save_thread_info(self.project, self.role, self.thread_id,
                         self.process.pid, "idle")
        logger.info("Thread resumed: %s", self.thread_id)
        return self.thread_id

    async def shutdown(self):
        """Gracefully shut down the app-server process."""
        if self._reader_task:
            self._reader_task.cancel()
            try:
                await self._reader_task
            except asyncio.CancelledError:
                pass
        if self.process:
            try:
                self.process.stdin.close()
            except (BrokenPipeError, OSError):
                pass
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=3)
            logger.info("app-server shut down (PID %d)", self.process.pid)
        remove_pid_file(self.project, self.role)

    # -- Turn operations ----------------------------------------------------

    async def send_turn(self, message: str,
                        timeout: float = TURN_TIMEOUT_S) -> dict:
        """Send a turn and wait for completion. Returns turn result with agent_text."""
        if not self.thread_id:
            raise RuntimeError("No active thread")

        self._agent_text = ""
        self._last_turn_items = []

        result = await self._request("turn/start", {
            "threadId": self.thread_id,
            "input": [{"type": "text", "text": message}],
        }, timeout=10)

        turn_id = result["turn"]["id"]
        save_thread_info(self.project, self.role, self.thread_id,
                         self.process.pid, "active", turn_id)
        logger.info("Turn started: %s", turn_id)

        completed = await self._wait_notification(
            "turn/completed",
            lambda p: p.get("turn", {}).get("id") == turn_id,
            timeout=timeout,
        )

        turn = completed.get("turn", {})
        status = turn.get("status", "unknown")
        turn["agent_text"] = self._agent_text
        turn["items"] = self._last_turn_items

        save_thread_info(self.project, self.role, self.thread_id,
                         self.process.pid, "idle", turn_id)

        if status == "failed":
            error = turn.get("error", {})
            error_info = error.get("codexErrorInfo", "")
            logger.error("Turn failed: %s — %s", error_info, error.get("message", "?"))

            # Auto-recovery
            turn = await self._handle_turn_error(error_info, message, timeout)

        return turn

    async def _handle_turn_error(self, error_info: str,
                                 original_message: str,
                                 timeout: float) -> dict:
        """Attempt auto-recovery based on codexErrorInfo."""
        if error_info == "ContextWindowExceeded":
            logger.info("Context window exceeded — compacting thread...")
            try:
                await self._request("thread/compact/start", {
                    "threadId": self.thread_id,
                }, timeout=30)
                await asyncio.sleep(COMPACT_RETRY_DELAY_S)
                logger.info("Compact done, retrying turn...")
                return await self.send_turn(original_message, timeout)
            except Exception as e:
                logger.error("Compact+retry failed: %s", e)
                return {"status": "failed", "error": {"codexErrorInfo": error_info,
                        "message": f"Compact retry failed: {e}"}, "agent_text": ""}

        if error_info in ("HttpConnectionFailed", "ResponseStreamConnectionFailed",
                          "ResponseStreamDisconnected"):
            logger.info("Network error (%s) — retrying after %ds...",
                        error_info, HTTP_RETRY_DELAY_S)
            await asyncio.sleep(HTTP_RETRY_DELAY_S)
            try:
                return await self.send_turn(original_message, timeout)
            except Exception as e:
                logger.error("Retry failed: %s", e)
                return {"status": "failed", "error": {"codexErrorInfo": error_info,
                        "message": f"Retry failed: {e}"}, "agent_text": ""}

        # Non-recoverable errors — return as-is
        return {"status": "failed", "error": {"codexErrorInfo": error_info},
                "agent_text": self._agent_text}

    async def interrupt(self) -> bool:
        if not self.thread_id:
            return False
        try:
            await self._request("turn/interrupt", {
                "threadId": self.thread_id,
                "turnId": "",
            }, timeout=5)
            return True
        except Exception as e:
            logger.warning("Interrupt failed: %s", e)
            return False

    async def get_status(self) -> dict:
        if not self.thread_id:
            return {"type": "no_thread"}
        try:
            result = await self._request("thread/read", {
                "threadId": self.thread_id,
                "includeTurns": False,
            }, timeout=5)
            return result.get("thread", {}).get("status", {})
        except Exception as e:
            logger.warning("Status check failed: %s", e)
            return {"type": "error", "message": str(e)}

    # -- Internal JSON-RPC --------------------------------------------------

    async def _request(self, method: str, params: dict,
                       timeout: float = 10) -> dict:
        self._request_id += 1
        msg_id = self._request_id
        future: asyncio.Future = asyncio.get_event_loop().create_future()
        self._pending[msg_id] = future

        msg = json.dumps({"method": method, "id": msg_id, "params": params})
        try:
            self.process.stdin.write(msg + "\n")
            self.process.stdin.flush()
        except (BrokenPipeError, OSError) as e:
            self._pending.pop(msg_id, None)
            raise RuntimeError(f"app-server pipe broken: {e}")
        logger.debug(">>> %s (id=%d)", method, msg_id)

        try:
            result = await asyncio.wait_for(future, timeout=timeout)
        except asyncio.TimeoutError:
            self._pending.pop(msg_id, None)
            raise TimeoutError(f"{method} timed out after {timeout}s")

        if "error" in result:
            err = result["error"]
            raise RuntimeError(
                f"RPC error {err.get('code')}: {err.get('message')} "
                f"[{err.get('data', {}).get('codexErrorInfo', '')}]"
            )
        return result.get("result", {})

    async def _notify(self, method: str, params: dict):
        msg = json.dumps({"method": method, "params": params})
        self.process.stdin.write(msg + "\n")
        self.process.stdin.flush()

    async def _read_loop(self):
        loop = asyncio.get_event_loop()
        reader = asyncio.StreamReader()
        transport, _ = await loop.connect_read_pipe(
            lambda: asyncio.StreamReaderProtocol(reader),
            self.process.stdout
        )

        try:
            while True:
                line = await reader.readline()
                if not line:
                    break
                text = line.decode().strip() if isinstance(line, bytes) else line.strip()
                if not text:
                    continue
                try:
                    msg = json.loads(text)
                except json.JSONDecodeError:
                    continue

                if "id" in msg and msg["id"] in self._pending:
                    future = self._pending.pop(msg["id"])
                    if not future.done():
                        future.set_result(msg)
                    continue

                if "id" in msg and "method" in msg:
                    await self._handle_server_request(msg)
                    continue

                method = msg.get("method", "")
                params = msg.get("params", {})
                self._dispatch_notification(method, params)

        except asyncio.CancelledError:
            pass
        except Exception as e:
            logger.error("Reader loop error: %s", e)
            # Wake up any pending futures with error
            for mid, fut in list(self._pending.items()):
                if not fut.done():
                    fut.set_exception(RuntimeError(f"Reader loop died: {e}"))
            self._pending.clear()
        finally:
            transport.close()

    async def _handle_server_request(self, msg: dict):
        method = msg.get("method", "")
        msg_id = msg["id"]

        if "requestApproval" in method:
            response = json.dumps({"id": msg_id, "result": {"decision": "accept"}})
            self.process.stdin.write(response + "\n")
            self.process.stdin.flush()
            logger.debug("Auto-approved: %s", method)
        elif method == "item/tool/requestUserInput":
            response = json.dumps({"id": msg_id, "result": {"answers": []}})
            self.process.stdin.write(response + "\n")
            self.process.stdin.flush()
        elif method == "item/tool/call":
            response = json.dumps({
                "id": msg_id,
                "result": {"contentItems": [{"type": "text", "text": "OK"}], "success": True},
            })
            self.process.stdin.write(response + "\n")
            self.process.stdin.flush()
        else:
            logger.warning("Unhandled server request: %s", method)

    def _dispatch_notification(self, method: str, params: dict):
        if method == "item/agentMessage/delta":
            self._agent_text += params.get("delta", "")

        if method == "item/completed":
            item = params.get("item", {})
            self._last_turn_items.append({
                "type": item.get("type"),
                "id": item.get("id"),
                "text": item.get("text", ""),
            })

        for key, waiters in list(self._notification_handlers.items()):
            if key == method:
                for waiter_future, predicate in waiters[:]:
                    if predicate is None or predicate(params):
                        if not waiter_future.done():
                            waiter_future.set_result(params)
                        waiters.remove((waiter_future, predicate))
                if not waiters:
                    del self._notification_handlers[key]

    async def _wait_notification(self, method: str,
                                 predicate=None,
                                 timeout: float = 60) -> dict:
        future: asyncio.Future = asyncio.get_event_loop().create_future()
        self._notification_handlers.setdefault(method, []).append(
            (future, predicate)
        )
        return await asyncio.wait_for(future, timeout=timeout)


# ---------------------------------------------------------------------------
# CLI subcommands
# ---------------------------------------------------------------------------

async def cmd_boot(args):
    """Boot a Codex agent: spawn app-server, create thread, send bootstrap."""
    client = CodexAppServerClient(project=args.project, role=args.role)
    try:
        thread_id = await client.start(model=args.model, cwd=args.cwd)
        print(f"thread_id={thread_id}")
        print(f"pid={client.process.pid}")

        if args.bootstrap:
            bootstrap_msg = args.bootstrap
            if os.path.isfile(bootstrap_msg):
                bootstrap_msg = Path(bootstrap_msg).read_text()
            turn = await client.send_turn(bootstrap_msg)
            print(f"bootstrap_status={turn.get('status', 'unknown')}")
            if turn.get("agent_text"):
                # Check for agent_ready signal
                if "agent_ready" in turn["agent_text"].lower() or \
                   "준비 완료" in turn["agent_text"]:
                    print("agent_ready=true")
                else:
                    print("agent_ready=pending")

        print(f"OK")

    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        await client.shutdown()
        remove_thread_info(args.project, args.role)
        sys.exit(1)

    # Keep process alive in background — write state and detach
    # The process stays running; monitor checks PID liveness
    if args.daemon:
        logger.info("Daemon mode: keeping app-server alive (PID %d)", client.process.pid)
        # Don't shutdown — process continues running
        # Parent (cmd.sh) reads stdout, gets OK, and moves on
        return
    else:
        await client.shutdown()


async def cmd_dispatch(args):
    """Send a message to a Codex agent via turn/start on a resumed thread."""
    info = load_thread_info(args.project, args.role)
    if not info:
        print(f"ERROR: No thread found for {args.role}", file=sys.stderr)
        sys.exit(1)

    # Check if existing process is alive
    old_pid = info.get("pid")
    if is_pid_alive(old_pid):
        # Process alive but we can't attach to its stdio.
        # For dispatch, we spawn a new app-server and resume the thread.
        pass

    client = CodexAppServerClient(project=args.project, role=args.role)
    try:
        await client.start_and_resume(
            thread_id=info["thread_id"],
            cwd=args.cwd or ".",
        )
        turn = await client.send_turn(args.message)

        status = turn.get("status", "unknown")
        agent_text = turn.get("agent_text", "")
        print(f"turn_status={status}")
        if agent_text:
            print(f"agent_text={agent_text[:500]}")

        if status == "failed":
            error = turn.get("error", {})
            print(f"error_info={error.get('codexErrorInfo', 'unknown')}")

    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)
    finally:
        await client.shutdown()


async def cmd_status(args):
    """Check status of a Codex agent."""
    info = load_thread_info(args.project, args.role)
    if not info:
        print(json.dumps({"alive": False, "reason": "no_thread_entry"}))
        return

    pid = info.get("pid")
    # Also check PID file
    pid_from_file = read_pid_file(args.project, args.role)
    effective_pid = pid_from_file or pid
    alive = is_pid_alive(effective_pid)

    print(json.dumps({
        "alive": alive,
        "thread_id": info["thread_id"],
        "pid": effective_pid,
        "status": info["status"],
        "last_turn_id": info.get("last_turn_id"),
        "created_at": info.get("created_at"),
    }))


async def cmd_interrupt(args):
    """Interrupt by sending SIGINT to app-server process."""
    info = load_thread_info(args.project, args.role)
    pid = read_pid_file(args.project, args.role)
    if not pid:
        pid = info.get("pid") if info else None
    if not pid:
        print("ERROR: No PID found", file=sys.stderr)
        sys.exit(1)

    if is_pid_alive(pid):
        os.kill(pid, signal.SIGINT)
        print(f"SIGINT sent to PID {pid}")
    else:
        print(f"Process {pid} not alive", file=sys.stderr)
        sys.exit(1)


async def cmd_shutdown(args):
    """Shut down a Codex agent: kill process, clean up state."""
    info = load_thread_info(args.project, args.role)
    pid = read_pid_file(args.project, args.role)
    if not pid:
        pid = info.get("pid") if info else None

    if pid and is_pid_alive(pid):
        os.kill(pid, signal.SIGTERM)
        # Wait briefly for clean exit
        for _ in range(10):
            if not is_pid_alive(pid):
                break
            time.sleep(0.5)
        if is_pid_alive(pid):
            os.kill(pid, signal.SIGKILL)
        print(f"Process {pid} terminated")

    remove_pid_file(args.project, args.role)
    # Keep thread_id in tsv for potential resume — mark as stopped
    if info:
        save_thread_info(args.project, args.role, info["thread_id"],
                         0, "stopped", info.get("last_turn_id", ""))
    print("OK")


async def cmd_reboot(args):
    """Reboot: kill existing process, resume thread in new app-server."""
    info = load_thread_info(args.project, args.role)

    # Kill existing process
    old_pid = read_pid_file(args.project, args.role)
    if not old_pid and info:
        old_pid = info.get("pid")
    if old_pid and is_pid_alive(old_pid):
        os.kill(old_pid, signal.SIGTERM)
        time.sleep(1)
        if is_pid_alive(old_pid):
            os.kill(old_pid, signal.SIGKILL)
        logger.info("Killed old process PID %d", old_pid)

    client = CodexAppServerClient(project=args.project, role=args.role)
    try:
        if info and info.get("thread_id"):
            # Resume existing thread (session preservation)
            logger.info("Resuming thread %s", info["thread_id"])
            try:
                await client.start_and_resume(
                    thread_id=info["thread_id"],
                    model=args.model,
                    cwd=args.cwd,
                )
                print(f"thread_id={client.thread_id}")
                print(f"pid={client.process.pid}")
                print(f"resumed=true")
            except Exception as e:
                logger.warning("Resume failed (%s), creating new thread", e)
                await _cleanup_client(client)
                client = CodexAppServerClient(project=args.project, role=args.role)
                await client.start(model=args.model, cwd=args.cwd)
                print(f"thread_id={client.thread_id}")
                print(f"pid={client.process.pid}")
                print(f"resumed=false")
        else:
            # No previous thread — fresh start
            await client.start(model=args.model, cwd=args.cwd)
            print(f"thread_id={client.thread_id}")
            print(f"pid={client.process.pid}")
            print(f"resumed=false")

        # Send bootstrap if provided
        if args.bootstrap:
            bootstrap_msg = args.bootstrap
            if os.path.isfile(bootstrap_msg):
                bootstrap_msg = Path(bootstrap_msg).read_text()
            turn = await client.send_turn(bootstrap_msg)
            print(f"bootstrap_status={turn.get('status', 'unknown')}")

        print("OK")

    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        await _cleanup_client(client)
        sys.exit(1)

    if args.daemon:
        return
    else:
        await client.shutdown()


async def cmd_monitor(args):
    """Check all Codex agents for a project."""
    tsv = get_threads_file(args.project)
    if not tsv.exists():
        print(json.dumps({"agents": []}))
        return

    agents = []
    for line in tsv.read_text().splitlines():
        if line.startswith("#") or not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 4:
            continue
        role, thread_id, pid_str, status = parts[0], parts[1], parts[2], parts[3]
        pid = int(pid_str) if pid_str.isdigit() else None
        # Also check PID file
        pid_from_file = read_pid_file(args.project, role)
        effective_pid = pid_from_file or pid
        alive = is_pid_alive(effective_pid)

        agents.append({
            "role": role,
            "thread_id": thread_id,
            "pid": effective_pid,
            "status": status,
            "alive": alive,
        })

    print(json.dumps({"agents": agents}))


async def _cleanup_client(client: CodexAppServerClient):
    """Clean up a client, ignoring errors."""
    try:
        await client.shutdown()
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Codex app-server JSON-RPC client for Whiplash"
    )
    parser.add_argument("-v", "--verbose", action="store_true")
    sub = parser.add_subparsers(dest="command", required=True)

    # boot
    p_boot = sub.add_parser("boot", help="Boot a Codex agent")
    p_boot.add_argument("project")
    p_boot.add_argument("role")
    p_boot.add_argument("cwd")
    p_boot.add_argument("--model", default=None)
    p_boot.add_argument("--bootstrap", default=None,
                        help="Bootstrap message or path to bootstrap file")
    p_boot.add_argument("--daemon", action="store_true",
                        help="Keep app-server process alive after boot")

    # dispatch
    p_disp = sub.add_parser("dispatch", help="Dispatch message to agent")
    p_disp.add_argument("project")
    p_disp.add_argument("role")
    p_disp.add_argument("message")
    p_disp.add_argument("--cwd", default=None)

    # status
    p_stat = sub.add_parser("status", help="Check agent status")
    p_stat.add_argument("project")
    p_stat.add_argument("role")

    # interrupt
    p_int = sub.add_parser("interrupt", help="Interrupt active turn")
    p_int.add_argument("project")
    p_int.add_argument("role")

    # shutdown
    p_shut = sub.add_parser("shutdown", help="Shut down agent")
    p_shut.add_argument("project")
    p_shut.add_argument("role")

    # reboot
    p_reb = sub.add_parser("reboot", help="Reboot agent (resume thread)")
    p_reb.add_argument("project")
    p_reb.add_argument("role")
    p_reb.add_argument("cwd")
    p_reb.add_argument("--model", default=None)
    p_reb.add_argument("--bootstrap", default=None)
    p_reb.add_argument("--daemon", action="store_true")

    # monitor
    p_mon = sub.add_parser("monitor", help="Monitor all agents")
    p_mon.add_argument("project")

    args = parser.parse_args()

    level = logging.DEBUG if args.verbose else logging.INFO
    logging.basicConfig(
        level=level,
        format="%(asctime)s [%(levelname)s] %(message)s",
        stream=sys.stderr,
    )

    cmd_map = {
        "boot": cmd_boot,
        "dispatch": cmd_dispatch,
        "status": cmd_status,
        "interrupt": cmd_interrupt,
        "shutdown": cmd_shutdown,
        "reboot": cmd_reboot,
        "monitor": cmd_monitor,
    }

    asyncio.run(cmd_map[args.command](args))


if __name__ == "__main__":
    main()
