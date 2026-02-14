#!/bin/bash
# mailbox.sh -- 다른 에이전트의 mailbox에 메시지 전달
#
# Maildir 원자적 전달 패턴: tmp/에 작성 후 new/로 이동
# 이렇게 하면 monitor.sh가 불완전한 파일을 읽는 일이 없다.
#
# Usage:
#   mailbox.sh {project} {from} {to} {kind} {priority} {subject} {content}
#
# Arguments:
#   project   -- 프로젝트 이름
#   from      -- 발신자 역할 (manager, researcher, developer, monitoring)
#   to        -- 수신자 역할
#   kind      -- 메시지 종류: task_complete | status_update | need_input | escalation | agent_ready
#   priority  -- normal | urgent
#   subject   -- 제목 (한 줄)
#   content   -- 본문 (짧게. 상세 내용은 별도 문서에 두고 참조)

set -euo pipefail

if [ $# -lt 7 ]; then
  echo "Usage: mailbox.sh {project} {from} {to} {kind} {priority} {subject} {content}" >&2
  exit 1
fi

project="$1"
from="$2"
to="$3"
kind="$4"
priority="$5"
subject="$6"
content="$7"

repo_root="$(git rev-parse --show-toplevel)"
mailbox_dir="$repo_root/projects/$project/workspace/shared/mailbox/$to"
msg_id="MSG-$(date +%s)-${from}-$$-${RANDOM}"

# mailbox 디렉토리 확인
if [ ! -d "$mailbox_dir/tmp" ] || [ ! -d "$mailbox_dir/new" ]; then
  echo "Error: mailbox 디렉토리가 없다: $mailbox_dir/{tmp,new}" >&2
  echo "orchestrator.sh boot로 먼저 초기화하라." >&2
  exit 1
fi

# tmp/에 작성 후 new/로 이동 (원자적 전달)
cat > "$mailbox_dir/tmp/${msg_id}.md" << EOF
---
id: ${msg_id}
from: ${from}
to: ${to}
kind: ${kind}
priority: ${priority}
timestamp: $(date -Iseconds)
subject: ${subject}
---

${content}
EOF

mv "$mailbox_dir/tmp/${msg_id}.md" "$mailbox_dir/new/${msg_id}.md"

# 감사 로그 기록
audit_log="$repo_root/projects/$project/memory/manager/logs/mailbox-audit.log"
mkdir -p "$(dirname "$audit_log")"
echo "$(date -Iseconds) | ${msg_id} | ${from} → ${to} | ${kind} | ${priority} | ${subject}" >> "$audit_log"

echo "전달 완료: ${msg_id} → ${to}/new/"
