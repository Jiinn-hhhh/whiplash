#!/bin/bash
# enforce-role.sh — PreToolUse hook for Whiplash agent role enforcement
#
# - Unrestricted roles (developer, systems-engineer, discussion): 전부 허용
# - Manager: Write/Edit는 프레임워크 경로만 허용, Bash는 readonly 패턴 차단
# - Readonly roles (researcher, monitoring, onboarding): Bash 수정 명령 차단
# - 비 Whiplash 세션 (WHIPLASH_AGENT_ROLE 미설정): 전부 허용
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

# Parse tool input
input="$(cat)"
tool_name="$(printf '%s' "$input" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null || true)"

# ──────────────────────────────────────────────
# Manager: 경로 기반 Write/Edit 제한 + Bash readonly
# ──────────────────────────────────────────────

if [ "$WHIPLASH_AGENT_ROLE" = "manager" ]; then

  # Write/Edit 도구: 프레임워크 경로 화이트리스트
  if [ "$tool_name" = "Write" ] || [ "$tool_name" = "Edit" ]; then
    file_path="$(printf '%s' "$input" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_input',{}).get('file_path',''))" 2>/dev/null || true)"

    if [ -z "$file_path" ]; then
      exit 0
    fi

    case "$file_path" in
      */projects/*/memory/*)          exit 0 ;;
      */projects/*/workspace/tasks/*) exit 0 ;;
      */projects/*/reports/*)         exit 0 ;;
      */projects/*/project.md)        exit 0 ;;
      */projects/*/team/*)            exit 0 ;;
    esac

    printf '{"result":"block","reason":"[role-guard] Manager는 이 경로에 쓸 수 없다. Developer에게 위임해라: %s"}\n' "$file_path"
    exit 2
  fi

  # Bash 도구: readonly 패턴 차단 (아래 공통 블록으로 fall through)
  if [ "$tool_name" != "Bash" ]; then
    exit 0
  fi

  command="$(printf '%s' "$input" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_input',{}).get('command',''))" 2>/dev/null || true)"

  if [ -z "$command" ]; then
    exit 0
  fi

  # Manager가 실행해야 하는 명령은 허용
  if printf '%s' "$command" | grep -qE '(^|[[:space:];|&])bash[[:space:]]+.*/scripts/(cmd|message|monitor)\.sh'; then
    exit 0
  fi

  # Manager Bash → readonly 블록으로 fall through
fi

# ──────────────────────────────────────────────
# Readonly roles (+ Manager Bash): 수정 명령 차단
# ──────────────────────────────────────────────

if [ "$tool_name" != "Bash" ]; then
  exit 0
fi

if [ -z "${command:-}" ]; then
  command="$(printf '%s' "$input" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_input',{}).get('command',''))" 2>/dev/null || true)"
fi

if [ -z "$command" ]; then
  exit 0
fi

# Block: environment variable tampering
if printf '%s' "$command" | grep -q 'WHIPLASH_AGENT_ROLE'; then
  printf '{"result":"block","reason":"[role-guard] %s 역할은 WHIPLASH_AGENT_ROLE 환경변수를 변경할 수 없다."}\n' "$WHIPLASH_AGENT_ROLE"
  exit 2
fi

# Block patterns for readonly roles — check each category separately
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
