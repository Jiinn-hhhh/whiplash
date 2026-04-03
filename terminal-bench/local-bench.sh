#!/usr/bin/env bash
# local-bench.sh — Terminal-Bench 로컬 하네스 (Docker 없이)
# 사용: ./local-bench.sh [task-id...] [--whiplash] [--vanilla] [--both]
#
# Max 구독의 claude CLI를 그대로 사용. API 키 불필요.
# /app → 임시 디렉토리로 치환하여 동일한 pytest 검증.

set -euo pipefail

DATASET_DIR="${TB_DATASET_DIR:-$HOME/.cache/terminal-bench/terminal-bench-core/0.1.1}"
RESULTS_DIR="${TB_RESULTS_DIR:-$(cd "$(dirname "$0")/.." && pwd)/test-results/local}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- CLAUDE.md for Whiplash mode ---
WHIPLASH_CLAUDE_MD="$SCRIPT_DIR/terminal_bench_whiplash/claude-md-content.md"

# --- Defaults ---
MODE="whiplash"  # whiplash | vanilla | both
TASKS=()
MODEL_FLAG=""

usage() {
  echo "Usage: $0 [OPTIONS] [task-id ...]"
  echo ""
  echo "Options:"
  echo "  --whiplash     Run with Whiplash CLAUDE.md (default)"
  echo "  --vanilla      Run vanilla Claude Code"
  echo "  --both         Run both and compare"
  echo "  --model MODEL  Set ANTHROPIC_MODEL (e.g. claude-sonnet-4-20250514)"
  echo "  --list         List available tasks"
  echo "  --help         Show this help"
  exit 0
}

list_tasks() {
  echo "Available tasks in $DATASET_DIR:"
  for d in "$DATASET_DIR"/*/; do
    task_id=$(basename "$d")
    difficulty=$(grep "^difficulty:" "$d/task.yaml" 2>/dev/null | awk '{print $2}')
    echo "  $task_id ($difficulty)"
  done
  exit 0
}

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --whiplash) MODE="whiplash"; shift ;;
    --vanilla)  MODE="vanilla"; shift ;;
    --both)     MODE="both"; shift ;;
    --model)    MODEL_FLAG="$2"; shift 2 ;;
    --list)     list_tasks ;;
    --help)     usage ;;
    *)          TASKS+=("$1"); shift ;;
  esac
done

# Default: hello-world if no tasks specified
if [[ ${#TASKS[@]} -eq 0 ]]; then
  TASKS=("hello-world")
fi

# --- Helper: run one task with one mode ---
run_task() {
  local task_id="$1"
  local agent_mode="$2"  # whiplash | vanilla
  local task_dir="$DATASET_DIR/$task_id"
  local task_yaml="$task_dir/task.yaml"

  if [[ ! -f "$task_yaml" ]]; then
    echo "ERROR: Task '$task_id' not found at $task_dir"
    return 1
  fi

  # Extract instruction from task.yaml
  local instruction
  instruction=$(python3 -c "
import yaml, sys
with open('$task_yaml') as f:
    data = yaml.safe_load(f)
print(data['instruction'])
")

  # Create isolated working directory (simulates /app)
  local workdir
  workdir=$(mktemp -d "/tmp/tb-${task_id}-${agent_mode}-XXXXXX")

  # Copy any existing task files (Dockerfile context) except docker/test files
  # Some tasks have data files in their directory
  for f in "$task_dir"/*; do
    fname=$(basename "$f")
    case "$fname" in
      Dockerfile|docker-compose.yaml|task.yaml|solution.sh|solution.yaml|tests|run-tests.sh)
        continue ;;
      *)
        cp -r "$f" "$workdir/" 2>/dev/null || true ;;
    esac
  done

  # If whiplash mode, write CLAUDE.md
  if [[ "$agent_mode" == "whiplash" ]] && [[ -f "$WHIPLASH_CLAUDE_MD" ]]; then
    cp "$WHIPLASH_CLAUDE_MD" "$workdir/CLAUDE.md"
  fi

  echo "━━━ Running: $task_id [$agent_mode] ━━━"
  echo "  Instruction: ${instruction:0:80}..."
  echo "  Workdir: $workdir"

  # Replace /app references in instruction with actual workdir
  local adapted_instruction
  adapted_instruction=$(echo "$instruction" | sed "s|/app|$workdir|g")

  # Run claude
  local start_time
  start_time=$(date +%s)

  local claude_exit=0
  local model_args=""
  if [[ -n "$MODEL_FLAG" ]]; then
    model_args="--model $MODEL_FLAG"
  fi

  # Run Claude Code in the working directory
  (cd "$workdir" && claude -p "$adapted_instruction" \
    --allowedTools Bash Edit Write Read Glob Grep Agent \
    --dangerously-skip-permissions \
    $model_args \
    --output-format text \
    --max-turns 30 \
    2>/dev/null) > "$workdir/.claude-output.txt" 2>&1 || claude_exit=$?

  local end_time
  end_time=$(date +%s)
  local duration=$((end_time - start_time))

  echo "  Claude finished in ${duration}s (exit: $claude_exit)"

  # --- Run tests ---
  # Copy test files and adapt /app → workdir
  local test_tmpdir
  test_tmpdir=$(mktemp -d "/tmp/tb-test-${task_id}-XXXXXX")

  cp -r "$task_dir/tests/"* "$test_tmpdir/" 2>/dev/null || true

  # Replace /app with actual workdir in test files
  find "$test_tmpdir" -name "*.py" -exec sed -i '' "s|/app|$workdir|g" {} + 2>/dev/null || \
  find "$test_tmpdir" -name "*.py" -exec sed -i "s|/app|$workdir|g" {} + 2>/dev/null || true

  # Run pytest
  local test_exit=0
  local test_output
  test_output=$(cd "$workdir" && TEST_DIR="$test_tmpdir" python3 -m pytest "$test_tmpdir/test_outputs.py" -rA 2>&1) || test_exit=$?

  local passed="FAIL"
  if [[ $test_exit -eq 0 ]]; then
    passed="PASS"
  fi

  echo "  Result: $passed"
  if [[ "$passed" == "FAIL" ]]; then
    echo "  Test output:"
    echo "$test_output" | tail -15 | sed 's/^/    /'
  fi

  # Save results
  local result_dir="$RESULTS_DIR/$agent_mode/$task_id"
  mkdir -p "$result_dir"
  cat > "$result_dir/result.json" << EOF
{
  "task_id": "$task_id",
  "agent_mode": "$agent_mode",
  "passed": $([ "$passed" == "PASS" ] && echo true || echo false),
  "duration_sec": $duration,
  "claude_exit": $claude_exit,
  "test_exit": $test_exit
}
EOF
  echo "$test_output" > "$result_dir/test_output.txt"
  cp "$workdir/.claude-output.txt" "$result_dir/claude_output.txt" 2>/dev/null || true

  # Cleanup
  rm -rf "$test_tmpdir"
  # Keep workdir for debugging (cleaned up at end)

  echo ""
  echo "$passed"
}

# --- Main ---
mkdir -p "$RESULTS_DIR"

# Use temp files for results (bash 3 compat, no assoc arrays)
TMPRESULTS=$(mktemp -d "/tmp/tb-results-XXXXXX")

for task_id in "${TASKS[@]}"; do
  if [[ "$MODE" == "whiplash" ]] || [[ "$MODE" == "both" ]]; then
    result=$(run_task "$task_id" "whiplash")
    echo "$result" | tail -1 > "$TMPRESULTS/whiplash-$task_id"
  fi

  if [[ "$MODE" == "vanilla" ]] || [[ "$MODE" == "both" ]]; then
    result=$(run_task "$task_id" "vanilla")
    echo "$result" | tail -1 > "$TMPRESULTS/vanilla-$task_id"
  fi
done

# --- Summary ---
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "RESULTS SUMMARY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ "$MODE" == "both" ]]; then
  printf "%-35s  %-10s  %-10s\n" "Task" "Whiplash" "Vanilla"
  printf "%-35s  %-10s  %-10s\n" "---" "---" "---"
  w_pass=0; v_pass=0; total=${#TASKS[@]}
  for task_id in "${TASKS[@]}"; do
    wr=$(cat "$TMPRESULTS/whiplash-$task_id" 2>/dev/null || echo "N/A")
    vr=$(cat "$TMPRESULTS/vanilla-$task_id" 2>/dev/null || echo "N/A")
    printf "%-35s  %-10s  %-10s\n" "$task_id" "$wr" "$vr"
    [[ "$wr" == "PASS" ]] && ((w_pass++)) || true
    [[ "$vr" == "PASS" ]] && ((v_pass++)) || true
  done
  echo ""
  echo "Whiplash: $w_pass/$total ($(( w_pass * 100 / total ))%)"
  echo "Vanilla:  $v_pass/$total ($(( v_pass * 100 / total ))%)"
else
  printf "%-35s  %-10s\n" "Task" "Result"
  printf "%-35s  %-10s\n" "---" "---"
  pass_count=0; total=${#TASKS[@]}
  for task_id in "${TASKS[@]}"; do
    r=$(cat "$TMPRESULTS/${MODE}-$task_id" 2>/dev/null || echo "N/A")
    printf "%-35s  %-10s\n" "$task_id" "$r"
    [[ "$r" == "PASS" ]] && ((pass_count++)) || true
  done
  echo ""
  echo "Score: $pass_count/$total ($(( pass_count * 100 / total ))%)"
fi

rm -rf "$TMPRESULTS"
echo ""
echo "Results saved to: $RESULTS_DIR"
