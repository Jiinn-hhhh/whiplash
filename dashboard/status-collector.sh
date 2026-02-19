#!/usr/bin/env bash
# status-collector.sh — Whiplash 에이전트 상태 수집 → JSON stdout
# Usage: ./status-collector.sh {project-name}
set -euo pipefail

PROJECT="${1:?Usage: $0 <project-name>}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$REPO_ROOT/projects/$PROJECT"

# ── Validation ──────────────────────────────────────────────
if [[ ! -d "$PROJECT_DIR" ]]; then
  echo '{"error":"project not found","project":"'"$PROJECT"'"}' ; exit 1
fi

SESSIONS_FILE="$PROJECT_DIR/memory/manager/sessions.md"
HEARTBEAT_FILE="$PROJECT_DIR/memory/manager/monitor.heartbeat"
PID_FILE="$PROJECT_DIR/memory/manager/monitor.pid"
HUNG_DIR="$PROJECT_DIR/memory/manager/hung-flags"
REBOOT_DIR="$PROJECT_DIR/memory/manager/reboot-counts"
MAILBOX_DIR="$PROJECT_DIR/workspace/shared/mailbox"
ANNOUNCE_DIR="$PROJECT_DIR/workspace/shared/announcements"
TMUX_SESSION="whiplash-$PROJECT"

NOW=$(date +%s)

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

# ── tmux window activity map ────────────────────────────────
declare -A WINDOW_ACTIVITY
if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
  tmux_active=true
  while IFS='|' read -r wname wact; do
    [[ -n "$wname" ]] && WINDOW_ACTIVITY["$wname"]="$wact"
  done < <(tmux list-windows -t "$TMUX_SESSION" -F '#{window_name}|#{window_activity}' 2>/dev/null || true)
else
  tmux_active=false
fi

# ── Parse sessions.md ───────────────────────────────────────
declare -A AGENT_ROLE AGENT_MODEL AGENT_STATUS AGENT_TMUX AGENT_BACKEND

if [[ -f "$SESSIONS_FILE" ]]; then
  while IFS='|' read -r _ role backend _sid tmux_target status _date model _notes _; do
    role=$(echo "$role" | xargs)
    backend=$(echo "$backend" | xargs)
    status=$(echo "$status" | xargs)
    model=$(echo "$model" | xargs)
    tmux_target=$(echo "$tmux_target" | xargs)

    [[ -z "$role" || "$role" == "역할" || "$role" == "---"* ]] && continue

    # For dual mode, key by role-backend; for solo, just role
    if [[ "$backend" == "codex" ]]; then
      key="${role}-codex"
    else
      key="$role"
    fi

    AGENT_ROLE["$key"]="$role"
    AGENT_MODEL["$key"]="$model"
    AGENT_STATUS["$key"]="$status"
    AGENT_BACKEND["$key"]="$backend"

    # Extract window name from tmux target (format: session:window)
    win_name="${tmux_target##*:}"
    AGENT_TMUX["$key"]="$win_name"
  done < "$SESSIONS_FILE"
fi

# ── Helper: get idle seconds for a tmux window ─────────────
get_idle() {
  local win="$1"
  local act="${WINDOW_ACTIVITY[$win]:-0}"
  if [[ "$act" == "0" || -z "$act" ]]; then
    echo "-1"
  else
    echo $(( NOW - act ))
  fi
}

# ── Helper: determine agent state ──────────────────────────
# Priority: crashed > hung > rebooting > offline > working > idle > sleeping
get_state() {
  local key="$1"
  local session_status="${AGENT_STATUS[$key]:-unknown}"
  local win="${AGENT_TMUX[$key]:-}"
  local has_tmux_win=false

  if [[ -n "$win" && -n "${WINDOW_ACTIVITY[$win]+x}" ]]; then
    has_tmux_win=true
  fi

  # 1. Crashed
  if [[ "$session_status" == "crashed" ]] && ! $has_tmux_win; then
    echo "crashed"; return
  fi

  # 2. Hung
  if [[ -f "$HUNG_DIR/${win}.hung" ]]; then
    echo "hung"; return
  fi

  # 3. Rebooting
  local reboot_file="$REBOOT_DIR/${win}.count"
  if [[ -f "$reboot_file" ]]; then
    local rc
    rc=$(cat "$reboot_file" 2>/dev/null || echo "0")
    if [[ "$rc" -gt 0 ]] && $has_tmux_win; then
      echo "rebooting"; return
    fi
  fi

  # 4. Offline
  if ! $has_tmux_win || [[ "$session_status" == "closed" || "$session_status" == "refreshed" ]]; then
    echo "offline"; return
  fi

  # 5-7. Activity based
  local idle
  idle=$(get_idle "$win")
  if [[ "$idle" -lt 0 ]]; then
    echo "offline"; return
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
    local count
    count=$(find "$new_dir" -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ')
    echo "$count"
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

  # Find most recent TASK file assigned to this role
  local latest=""
  local latest_title=""
  for f in "$ANNOUNCE_DIR"/TASK-*.md; do
    [[ -f "$f" ]] || continue
    # Check if file mentions this role in team assignment section
    if grep -qi "$role" "$f" 2>/dev/null; then
      local fname
      fname=$(basename "$f" .md)
      local title
      title=$(head -1 "$f" 2>/dev/null | sed 's/^#\s*//')
      if [[ -z "$latest" || "$f" > "$latest" ]]; then
        latest="$f"
        latest_title="$fname: $title"
      fi
    fi
  done

  if [[ -n "$latest_title" ]]; then
    # JSON-escape the title
    echo "\"$(echo "$latest_title" | sed 's/"/\\"/g' | head -c 60)\""
  else
    echo "null"
  fi
}

# ── Build JSON output ───────────────────────────────────────
agents_json=""
for key in "${!AGENT_ROLE[@]}"; do
  role="${AGENT_ROLE[$key]}"
  model="${AGENT_MODEL[$key]:-unknown}"
  session_status="${AGENT_STATUS[$key]:-unknown}"
  win="${AGENT_TMUX[$key]:-}"
  state=$(get_state "$key")
  idle=$(get_idle "$win")
  reboot_count=$(get_reboot_count "$win")
  is_hung=false
  [[ -f "$HUNG_DIR/${win}.hung" ]] && is_hung=true
  mailbox_new=$(get_mailbox_new "$role")
  current_task=$(get_current_task "$role")

  agent_json=$(cat <<AGENT
    "$key": {
      "role": "$role",
      "model": "$model",
      "session_status": "$session_status",
      "idle_seconds": $idle,
      "state": "$state",
      "reboot_count": $reboot_count,
      "is_hung": $is_hung,
      "mailbox_new": $mailbox_new,
      "current_task": $current_task
    }
AGENT
  )

  if [[ -n "$agents_json" ]]; then
    agents_json="$agents_json,"$'\n'"$agent_json"
  else
    agents_json="$agent_json"
  fi
done

cat <<JSON
{
  "project": "$PROJECT",
  "timestamp": $NOW,
  "monitor": {
    "alive": $monitor_alive,
    "heartbeat_age_sec": $heartbeat_age
  },
  "agents": {
${agents_json}
  }
}
JSON
