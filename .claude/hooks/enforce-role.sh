#!/bin/bash
# enforce-role.sh — PreToolUse hook for Whiplash agent role enforcement
#
# Blocks dangerous Bash commands for readonly roles (manager, researcher, monitoring).
# Unrestricted roles (developer, systems-engineer, discussion) and non-Whiplash
# sessions (no WHIPLASH_AGENT_ROLE) are always allowed.
#
# Exit codes: 0 = allow, 2 = block (with reason on stdout JSON)

set -euo pipefail

# No role set → not a Whiplash agent session → allow everything
if [ -z "${WHIPLASH_AGENT_ROLE:-}" ]; then
  exit 0
fi

# Unrestricted roles
case "$WHIPLASH_AGENT_ROLE" in
  developer|systems-engineer|discussion)
    exit 0
    ;;
esac

# Readonly roles: manager, researcher, monitoring
# Only Bash tool needs filtering — other tools are controlled by allowedTools
input="$(cat)"
tool_name="$(printf '%s' "$input" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null || true)"

if [ "$tool_name" != "Bash" ]; then
  exit 0
fi

command="$(printf '%s' "$input" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_input',{}).get('command',''))" 2>/dev/null || true)"

if [ -z "$command" ]; then
  exit 0
fi

# Block: environment variable tampering
if printf '%s' "$command" | grep -q 'WHIPLASH_AGENT_ROLE'; then
  printf '{"result":"block","reason":"[role-guard] %s 역할은 WHIPLASH_AGENT_ROLE 환경변수를 변경할 수 없다."}\n' "$WHIPLASH_AGENT_ROLE"
  exit 2
fi

# Block patterns for readonly roles — check each category separately
# Word boundary: command at start of line or after separator
WB='(^|[[:space:];|&])'

blocked=0

# File modification commands
printf '%s' "$command" | grep -qE "${WB}(sed[[:space:]]+-i|perl[[:space:]]+-[ip]e|awk[[:space:]]+-i)" && blocked=1
# Redirect write
printf '%s' "$command" | grep -qE '>' && blocked=1
# Tee
printf '%s' "$command" | grep -qE "${WB}tee([[:space:]]|$)" && blocked=1
# Filesystem modify
printf '%s' "$command" | grep -qE "${WB}(cp|mv|rm|mkdir|rmdir|touch|chmod|chown|chgrp|ln|dd|install)[[:space:]]" && blocked=1
# Git write
printf '%s' "$command" | grep -qE "${WB}git[[:space:]]+(add|commit|push|merge|rebase|reset|cherry-pick|revert|stash|tag)[[:space:]]*" && blocked=1
# Package managers
printf '%s' "$command" | grep -qE "${WB}(npm|npx|yarn|pnpm|pip|pip3|conda|brew)[[:space:]]+(install|uninstall|remove|update|upgrade)" && blocked=1
# Curl write
printf '%s' "$command" | grep -qE "${WB}curl[[:space:]]+.*-[dXPoOJ]" && blocked=1

if [ "$blocked" -eq 1 ]; then
  printf '{"result":"block","reason":"[role-guard] %s 역할은 이 명령을 실행할 수 없다: readonly 역할의 Bash 수정 명령 차단."}\n' "$WHIPLASH_AGENT_ROLE"
  exit 2
fi

# Allow: command didn't match any block pattern
exit 0
