#!/bin/bash
# user-notify.sh -- manager가 user에게 비차단 알림을 남기는 랄프/자동화용 wrapper

set -euo pipefail

if [ $# -lt 3 ]; then
  echo "Usage: user-notify.sh {project} {title} {message} [level]" >&2
  exit 1
fi

project="$1"
title="$2"
message="$3"
level="${4:-normal}"

case "$level" in
  normal|info|urgent|success|failure) ;;
  *)
    echo "Error: 잘못된 level: $level (허용: normal, info, urgent, success, failure)" >&2
    exit 1
    ;;
esac

priority="normal"
if [ "$level" = "urgent" ]; then
  priority="urgent"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_MD="$REPO_ROOT/projects/$project/project.md"

if [ ! -f "$PROJECT_MD" ]; then
  echo "Error: project.md가 없다: $PROJECT_MD" >&2
  exit 1
fi

bash "$SCRIPT_DIR/message.sh" "$project" manager user user_notice "$priority" "$title" "$message" >/dev/null

has_slack="$(
  python3 - "$PROJECT_MD" <<'PY'
import re
import sys
from pathlib import Path

content = Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(r"^\s*-\s*\*\*Slack webhook\*\*:\s*(.+?)\s*$", content, re.MULTILINE)
if match and match.group(1).strip() not in {"", "미정", "없음"}:
    print("1")
else:
    print("0")
PY
)"

if [ "$has_slack" = "1" ]; then
  if [ "$level" = "urgent" ] || [ "$level" = "failure" ]; then
    bash "$SCRIPT_DIR/slack.sh" "$project" "$title" "$message" "$level" >/dev/null 2>&1 || echo "[user-notify] Warning: Slack 전송 실패 (level=$level)" >&2
  else
    bash "$SCRIPT_DIR/slack.sh" --no-mention "$project" "$title" "$message" "$level" >/dev/null 2>&1 || echo "[user-notify] Warning: Slack 전송 실패 (level=$level)" >&2
  fi
fi

echo "user-notify 완료: ${project} | ${level} | ${title}"
