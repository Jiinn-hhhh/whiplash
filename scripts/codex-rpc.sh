#!/usr/bin/env bash
# codex-rpc.sh — Bash wrapper for codex-rpc.py
# Provides cmd.sh-compatible interface for Codex app-server operations.
#
# Usage:
#   codex-rpc.sh boot     <project> <role> <cwd> [--model MODEL] [--bootstrap MSG]
#   codex-rpc.sh dispatch <project> <role> <message>
#   codex-rpc.sh status   <project> <role>
#   codex-rpc.sh interrupt <project> <role>
#   codex-rpc.sh shutdown <project> <role>
#   codex-rpc.sh monitor  <project>
#
# Exit codes:
#   0 — success
#   1 — error (message on stderr)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CODEX_RPC_PY="${SCRIPT_DIR}/codex-rpc.py"

# Ensure python3 is available
if ! command -v python3 &>/dev/null; then
    echo "ERROR: python3 not found" >&2
    exit 1
fi

# Ensure codex-rpc.py exists
if [ ! -f "$CODEX_RPC_PY" ]; then
    echo "ERROR: ${CODEX_RPC_PY} not found" >&2
    exit 1
fi

# Pass all arguments through to Python
exec python3 "$CODEX_RPC_PY" "$@"
