#!/bin/bash
# slack.sh -- project.md에 기록된 Slack webhook으로 알림 전송
#
# Usage:
#   slack.sh [--dry-run] [--no-mention] {project} {title} {message} [level]
#
# Examples:
#   bash scripts/slack.sh midi-render "시스템 이슈" "monitor 재시작됨" urgent
#   bash scripts/slack.sh --dry-run midi-render "테스트" "payload 확인"

set -euo pipefail

dry_run=0
include_mention=1

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)
      dry_run=1
      shift
      ;;
    --no-mention)
      include_mention=0
      shift
      ;;
    --help|-h)
      echo "Usage: slack.sh [--dry-run] [--no-mention] {project} {title} {message} [level]" >&2
      exit 0
      ;;
    *)
      break
      ;;
  esac
done

if [ $# -lt 3 ]; then
  echo "Usage: slack.sh [--dry-run] [--no-mention] {project} {title} {message} [level]" >&2
  exit 1
fi

project="$1"
title="$2"
message="$3"
level="${4:-normal}"

if [[ "$project" == */* ]] || [[ "$project" == *..* ]] || [ -z "$project" ]; then
  echo "Error: 잘못된 project 이름: $project" >&2
  exit 1
fi

case "$level" in
  normal|info|urgent|success|failure) ;;
  *)
    echo "Error: 잘못된 level: $level (허용: normal, info, urgent, success, failure)" >&2
    exit 1
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_MD="$REPO_ROOT/projects/$project/project.md"

if [ ! -f "$PROJECT_MD" ]; then
  echo "Error: project.md가 없다: $PROJECT_MD" >&2
  exit 1
fi

parse_output="$(
  python3 - "$PROJECT_MD" <<'PY'
import re
import sys
from pathlib import Path

project_md = Path(sys.argv[1]).read_text(encoding="utf-8")

def find(label: str) -> str:
    pattern = re.compile(rf"^\s*-\s*\*\*{re.escape(label)}\*\*:\s*(.+?)\s*$", re.MULTILINE)
    match = pattern.search(project_md)
    return match.group(1).strip() if match else ""

webhook = find("Slack webhook")
mention = find("Slack 멘션")
if mention:
    mention = re.sub(r"\s*\(.*$", "", mention).strip()

print(webhook)
print(mention)
PY
)"

webhook="$(printf '%s\n' "$parse_output" | sed -n '1p')"
mention="$(printf '%s\n' "$parse_output" | sed -n '2p')"

if [ -z "$webhook" ]; then
  echo "Error: project.md에 Slack webhook이 설정되지 않았다." >&2
  exit 1
fi

payload="$(
  python3 - "$project" "$title" "$message" "$level" "$mention" "$include_mention" <<'PY'
import json
import sys

project, title, message, level, mention, include_mention = sys.argv[1:]

prefix_by_level = {
    "normal": "INFO",
    "info": "INFO",
    "urgent": "URGENT",
    "success": "SUCCESS",
    "failure": "FAILURE",
}
prefix = prefix_by_level[level]

lines = [f"[whiplash/{project}] {prefix} | {title}", message]
if include_mention == "1" and mention:
    lines.append(mention)

print(json.dumps({"text": "\n".join(lines)}, ensure_ascii=False))
PY
)"

if [ "$dry_run" -eq 1 ]; then
  printf '%s\n' "$payload"
  exit 0
fi

curl -fsS -X POST \
  -H 'Content-Type: application/json; charset=utf-8' \
  --data-raw "$payload" \
  "$webhook" >/dev/null

echo "Slack 전송 완료: ${project} | ${level} | ${title}"
