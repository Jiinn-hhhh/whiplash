#!/usr/bin/env bash
# status-collector.sh — Whiplash 에이전트 상태 수집 → JSON stdout
# Usage: ./status-collector.sh {project-name}
# Compatible with bash 3.x (macOS default)
set -euo pipefail

PROJECT="${1:?Usage: $0 <project-name>}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$REPO_ROOT/projects/$PROJECT"

if [[ ! -d "$PROJECT_DIR" ]]; then
  echo '{"error":"project not found","project":"'"$PROJECT"'"}' ; exit 1
fi

NOW=$(date +%s)

# ── agent-team 모드 감지: project.md에서 실행 모드 확인 ────
EXEC_MODE="solo"
if grep -q "agent-team" "$PROJECT_DIR/project.md" 2>/dev/null; then
  EXEC_MODE="agent-team"
fi

if [[ "$EXEC_MODE" == "agent-team" ]]; then
  # 분산 자기보고: 각 에이전트의 memory/{role}/status.json을 수집
  python3 -c "
import json, sys, time, os

now = int(time.time())
project_dir = sys.argv[1]
project = sys.argv[2]

roles = ['researcher', 'developer', 'monitoring']
agents = {}

# Manager 상태: 기본값
agents['manager'] = {
    'role': 'manager', 'model': 'sonnet', 'session_status': 'active',
    'idle_seconds': 0, 'state': 'working', 'reboot_count': 0,
    'is_hung': False, 'mailbox_new': 0, 'current_task': '팀 조율 중',
    'last_update': now
}

# 레거시 중앙 파일 (있으면 베이스로 사용)
legacy = os.path.join(project_dir, 'memory/manager/agent-team-status.json')
if os.path.exists(legacy):
    with open(legacy) as f:
        data = json.load(f)
    agents.update(data.get('agents', {}))

# 개별 에이전트 상태 (있으면 레거시 덮어쓰기)
for role in roles:
    status_file = os.path.join(project_dir, f'memory/{role}/status.json')
    if os.path.exists(status_file):
        try:
            with open(status_file) as f:
                s = json.load(f)
            base = agents.get(role, {
                'role': role, 'model': 'sonnet', 'session_status': 'active',
                'idle_seconds': 0, 'state': 'idle', 'reboot_count': 0,
                'is_hung': False, 'mailbox_new': 0, 'current_task': None,
                'last_update': now
            })
            base['state'] = s.get('state', base.get('state', 'idle'))
            base['current_task'] = s.get('current_task', base.get('current_task'))
            base['last_update'] = s.get('last_update', now)
            agents[role] = base
        except: pass

    # Manager 오버라이드 (crash/reboot)
    override = os.path.join(project_dir, f'memory/manager/overrides/{role}.json')
    if os.path.exists(override):
        try:
            with open(override) as f:
                ov = json.load(f)
            if role in agents:
                agents[role].update(ov)
        except: pass

# idle_seconds 계산 (표시용)
for agent in agents.values():
    lu = agent.get('last_update', now)
    agent['idle_seconds'] = now - lu

result = {
    'project': project,
    'timestamp': now,
    'monitor': {'alive': False, 'heartbeat_age_sec': -1},
    'agents': agents
}
json.dump(result, sys.stdout, ensure_ascii=False)
" "$PROJECT_DIR" "$PROJECT" 2>/dev/null || cat <<JSON
{
  "project": "$PROJECT",
  "timestamp": $NOW,
  "monitor": { "alive": false, "heartbeat_age_sec": -1 },
  "agents": {}
}
JSON
  exit 0
fi

# ── 이하 기존 tmux 기반 코드 ─────────────────────────────

SESSIONS_FILE="$PROJECT_DIR/memory/manager/sessions.md"
HEARTBEAT_FILE="$PROJECT_DIR/memory/manager/monitor.heartbeat"
PID_FILE="$PROJECT_DIR/memory/manager/monitor.pid"
HUNG_DIR="$PROJECT_DIR/memory/manager/hung-flags"
REBOOT_DIR="$PROJECT_DIR/memory/manager/reboot-counts"
MAILBOX_DIR="$PROJECT_DIR/workspace/shared/mailbox"
ANNOUNCE_DIR="$PROJECT_DIR/workspace/shared/announcements"
TMUX_SESSION="whiplash-$PROJECT"

# ── Temp dir for intermediate data ──────────────────────────
TMPDIR_COLL=$(mktemp -d)
trap 'rm -rf "$TMPDIR_COLL"' EXIT

# ── Monitor health ──────────────────────────────────────────
monitor_alive=false
heartbeat_age=-1

if [[ -f "$PID_FILE" ]]; then
  pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    monitor_alive=true
  fi
fi

if [[ -f "$HEARTBEAT_FILE" ]]; then
  hb=$(cat "$HEARTBEAT_FILE" 2>/dev/null || echo "0")
  heartbeat_age=$(( NOW - hb ))
fi

# ── tmux window activity → temp files ───────────────────────
# Creates $TMPDIR_COLL/tmux_{window_name} with activity epoch as content
mkdir -p "$TMPDIR_COLL/tmux"
if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
  tmux list-windows -t "$TMUX_SESSION" -F '#{window_name}|#{window_activity}' 2>/dev/null | \
  while IFS='|' read -r wname wact; do
    [[ -n "$wname" ]] && echo "$wact" > "$TMPDIR_COLL/tmux/$wname"
  done
fi

# ── Helper: get tmux window activity epoch ──────────────────
get_window_activity() {
  local win="$1"
  local f="$TMPDIR_COLL/tmux/$win"
  if [[ -f "$f" ]]; then
    cat "$f"
  else
    echo ""
  fi
}

# ── Helper: check if tmux window exists ─────────────────────
has_tmux_window() {
  local win="$1"
  [[ -f "$TMPDIR_COLL/tmux/$win" ]]
}

# ── Helper: get idle seconds ────────────────────────────────
get_idle() {
  local win="$1"
  local act
  act=$(get_window_activity "$win")
  if [[ -z "$act" || "$act" == "0" ]]; then
    echo "-1"
  else
    echo $(( NOW - act ))
  fi
}

# ── Helper: determine agent state ───────────────────────────
get_state() {
  local session_status="$1"
  local win="$2"

  # 1. Crashed
  if [[ "$session_status" == "crashed" ]] && ! has_tmux_window "$win"; then
    echo "crashed"; return
  fi

  # 2. Hung
  if [[ -n "$win" && -f "$HUNG_DIR/${win}.hung" ]]; then
    echo "hung"; return
  fi

  # 3. Rebooting
  if [[ -n "$win" && -f "$REBOOT_DIR/${win}.count" ]]; then
    local rc
    rc=$(cat "$REBOOT_DIR/${win}.count" 2>/dev/null || echo "0")
    if [[ "$rc" -gt 0 ]] && has_tmux_window "$win"; then
      echo "rebooting"; return
    fi
  fi

  # 4. Offline
  if ! has_tmux_window "$win" || [[ "$session_status" == "closed" || "$session_status" == "refreshed" ]]; then
    echo "offline"; return
  fi

  # 5-7. Activity based
  local idle
  idle=$(get_idle "$win")
  if [[ "$idle" -lt 0 ]]; then
    echo "offline"
  elif [[ "$idle" -lt 120 ]]; then
    echo "working"
  elif [[ "$idle" -lt 600 ]]; then
    echo "idle"
  else
    echo "sleeping"
  fi
}

# ── Helper: get new mailbox count ───────────────────────────
get_mailbox_new() {
  local role="$1"
  local new_dir="$MAILBOX_DIR/$role/new"
  if [[ -d "$new_dir" ]]; then
    find "$new_dir" -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' '
  else
    echo "0"
  fi
}

# ── Helper: get reboot count ───────────────────────────────
get_reboot_count() {
  local win="$1"
  local file="$REBOOT_DIR/${win}.count"
  if [[ -f "$file" ]]; then
    cat "$file" 2>/dev/null || echo "0"
  else
    echo "0"
  fi
}

# ── Helper: get current task for a role ─────────────────────
get_current_task() {
  local role="$1"
  if [[ ! -d "$ANNOUNCE_DIR" ]]; then
    echo "null"; return
  fi

  local latest=""
  local latest_title=""
  for f in "$ANNOUNCE_DIR"/TASK-*.md; do
    [[ -f "$f" ]] || continue
    if grep -qi "$role" "$f" 2>/dev/null; then
      local fname
      fname=$(basename "$f" .md)
      local title
      title=$(head -1 "$f" 2>/dev/null | sed 's/^# *//')
      if [[ -z "$latest" || "$f" > "$latest" ]]; then
        latest="$f"
        latest_title="$fname: $title"
      fi
    fi
  done

  if [[ -n "$latest_title" ]]; then
    # JSON-escape: backslash, double quote, truncate
    local escaped
    escaped=$(printf '%s' "$latest_title" | sed 's/\\/\\\\/g; s/"/\\"/g' | cut -c1-60)
    echo "\"$escaped\""
  else
    echo "null"
  fi
}

# ── Parse sessions.md and build JSON ────────────────────────
agents_json=""

if [[ -f "$SESSIONS_FILE" ]]; then
  while IFS='|' read -r _ role backend _sid tmux_target status _date model _notes _; do
    # Trim whitespace (bash 3.x compatible)
    role=$(echo "$role" | sed 's/^ *//;s/ *$//')
    backend=$(echo "$backend" | sed 's/^ *//;s/ *$//')
    status=$(echo "$status" | sed 's/^ *//;s/ *$//')
    model=$(echo "$model" | sed 's/^ *//;s/ *$//')
    tmux_target=$(echo "$tmux_target" | sed 's/^ *//;s/ *$//')

    # Skip header and separator rows
    [[ -z "$role" || "$role" == "역할" || "$role" == "---"* || "$role" == "-"* ]] && continue

    # Key: role-codex for dual mode, role for solo
    if [[ "$backend" == "codex" ]]; then
      key="${role}-codex"
    else
      key="$role"
    fi

    # Extract window name from tmux target (session:window → window)
    win_name="${tmux_target##*:}"

    state=$(get_state "$status" "$win_name")
    idle=$(get_idle "$win_name")
    reboot_count=$(get_reboot_count "$win_name")
    is_hung=false
    [[ -n "$win_name" && -f "$HUNG_DIR/${win_name}.hung" ]] && is_hung=true
    mailbox_new=$(get_mailbox_new "$role")
    current_task=$(get_current_task "$role")

    agent_json="    \"$key\": {
      \"role\": \"$role\",
      \"model\": \"$model\",
      \"session_status\": \"$status\",
      \"idle_seconds\": $idle,
      \"state\": \"$state\",
      \"reboot_count\": $reboot_count,
      \"is_hung\": $is_hung,
      \"mailbox_new\": $mailbox_new,
      \"current_task\": $current_task
    }"

    if [[ -n "$agents_json" ]]; then
      agents_json="$agents_json,
$agent_json"
    else
      agents_json="$agent_json"
    fi
  done < "$SESSIONS_FILE"
fi

cat <<JSON
{
  "project": "$PROJECT",
  "timestamp": $NOW,
  "monitor": {
    "alive": $monitor_alive,
    "heartbeat_age_sec": $heartbeat_age
  },
  "agents": {
$agents_json
  }
}
JSON
