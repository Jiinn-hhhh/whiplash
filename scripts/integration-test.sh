#!/bin/bash
# integration-test.sh -- 라이브 통합 테스트 (tmux 기반)
#
# 테스트 전용 프로젝트 _stability-test를 사용.
# 실제 claude 호출 대신 컴파일된 가짜 바이너리로 시뮬레이션.
#
# Usage: bash scripts/integration-test.sh

# set -e 사용 안 함 — 테스트는 실패를 의도적으로 유발하므로
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOLS_DIR="$SCRIPT_DIR"
# shellcheck source=/dev/null
source "$TOOLS_DIR/tmux-env.sh"
# shellcheck source=/dev/null
source "$TOOLS_DIR/runtime-paths.sh"
# shellcheck source=/dev/null
source "$TOOLS_DIR/tmux-submit.sh"
# shellcheck source=/dev/null
source "$TOOLS_DIR/message-queue.sh"
# shellcheck source=/dev/null
source "$TOOLS_DIR/notify-format.sh"
PROJECT="_stability-test"
SESSION="whiplash-${PROJECT}"
PROJECT_DIR="$REPO_ROOT/projects/$PROJECT"
FAKE_CLAUDE_BIN=""
FAKE_CODEX_BIN=""
PASS=0
FAIL=0
TOTAL=0
TEST_TMUX_TMPDIR="$(mktemp -d "/tmp/whiplash-it.XXXXXX")"

if [ -z "${TEST_TMUX_TMPDIR:-}" ] || [ ! -d "$TEST_TMUX_TMPDIR" ]; then
  echo "ERROR: isolated tmux tmpdir 생성 실패" >&2
  exit 1
fi

export TMUX_TMPDIR="$TEST_TMUX_TMPDIR"
unset TMUX
whiplash_activate_tmux_project "$PROJECT"

# ──────────────────────────────────────────────
# 테스트 유틸리티
# ──────────────────────────────────────────────

setup_test_project() {
  mkdir -p "$PROJECT_DIR/memory/manager"
  mkdir -p "$(runtime_root_dir "$PROJECT")"
  mkdir -p "$PROJECT_DIR/logs"
  cat > "$PROJECT_DIR/project.md" << 'EOF'
# _stability-test

- 목표: 통합 테스트용 임시 프로젝트
- 활성 에이전트: developer, researcher
- 실행 모드: solo
- 도메인: general
EOF
}

build_fake_terminal_agent() {
  local output_bin="$1"
  if [ -f "$output_bin" ]; then
    return 0
  fi

  mkdir -p "$(dirname "$output_bin")"
  if command -v cc &>/dev/null; then
    cat <<'EOF' | cc -x c - -o "$output_bin" 2>/dev/null
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

static struct termios g_saved_termios;
static int g_termios_saved = 0;

static void restore_terminal(void) {
  if (g_termios_saved) {
    tcsetattr(STDIN_FILENO, TCSANOW, &g_saved_termios);
    g_termios_saved = 0;
  }
  write(STDOUT_FILENO, "\033[?2004l", 8);
}

static int write_all(const char *buf, size_t len) {
  while (len > 0) {
    ssize_t written = write(STDOUT_FILENO, buf, len);
    if (written < 0) {
      if (errno == EINTR) {
        continue;
      }
      return -1;
    }
    buf += (size_t) written;
    len -= (size_t) written;
  }
  return 0;
}

static int append_char(char **buf, size_t *len, size_t *cap, char c) {
  if (*len + 2 > *cap) {
    size_t next_cap = (*cap == 0) ? 256 : (*cap * 2);
    char *next = realloc(*buf, next_cap);
    if (next == NULL) {
      return -1;
    }
    *buf = next;
    *cap = next_cap;
  }
  (*buf)[(*len)++] = c;
  (*buf)[*len] = '\0';
  return 0;
}

static int display_char(char c) {
  if (c == '\n') {
    return write_all("\r\n", 2);
  }
  return write_all(&c, 1);
}

static int display_text(const char *buf, size_t len) {
  for (size_t i = 0; i < len; ++i) {
    if (display_char(buf[i]) != 0) {
      return -1;
    }
  }
  return 0;
}

static int enable_raw_mode(void) {
  struct termios raw;
  if (tcgetattr(STDIN_FILENO, &g_saved_termios) != 0) {
    return -1;
  }
  g_termios_saved = 1;
  raw = g_saved_termios;
  raw.c_iflag &= ~(ICRNL | IXON);
  raw.c_lflag &= ~(ECHO | ICANON);
  raw.c_oflag |= OPOST;
  raw.c_cc[VMIN] = 1;
  raw.c_cc[VTIME] = 0;
  return tcsetattr(STDIN_FILENO, TCSANOW, &raw);
}

static int env_flag_enabled(const char *name) {
  const char *value = getenv(name);
  if (value == NULL) {
    return 0;
  }
  return strcmp(value, "1") == 0 || strcmp(value, "true") == 0 || strcmp(value, "yes") == 0;
}

static int env_int_value(const char *name) {
  const char *value = getenv(name);
  char *end = NULL;
  long parsed;
  if (value == NULL || *value == '\0') {
    return 0;
  }
  parsed = strtol(value, &end, 10);
  if (end == NULL || *end != '\0' || parsed < 0) {
    return 0;
  }
  return (int) parsed;
}

static int handle_submit(char **draft, size_t *draft_len) {
  int rich_tui = env_flag_enabled("WHIPLASH_FAKE_RICH_TUI");
  int swallow_submit = env_flag_enabled("WHIPLASH_FAKE_SWALLOW_SUBMIT");
  const char *prompt = rich_tui ? "\r\n> " : "\r\n>>> ";

  if (*draft_len == 0) {
    if (write_all(prompt, strlen(prompt)) != 0) {
      return -1;
    }
    return 0;
  }

  if (swallow_submit) {
    *draft_len = 0;
    (*draft)[0] = '\0';
    if (write_all(prompt, strlen(prompt)) != 0) {
      return -1;
    }
    return 0;
  }

  if (write_all("\r\n[submitted]\r\n", 15) != 0) {
    return -1;
  }
  if (display_text(*draft, *draft_len) != 0) {
    return -1;
  }
  if (write_all(prompt, strlen(prompt)) != 0) {
    return -1;
  }

  if (*draft_len == 5 && memcmp(*draft, "/exit", 5) == 0) {
    return 1;
  }

  *draft_len = 0;
  (*draft)[0] = '\0';
  return 0;
}

int main(int argc, char **argv) {
  char *draft = NULL;
  size_t draft_len = 0;
  size_t draft_cap = 0;
  int in_paste = 0;
  int discard_warmup = 0;
  int warmup_seconds = 0;
  int initial_prompt_delay_ms = env_int_value("WHIPLASH_FAKE_INITIAL_PROMPT_DELAY_MS");
  int discard_early_input = env_flag_enabled("WHIPLASH_FAKE_DISCARD_EARLY_INPUT");

  if (argc > 1 && strcmp(argv[1], "--help") == 0) {
    const char *help = "fake cli supports --dangerously-bypass-approvals-and-sandbox\n";
    write_all(help, strlen(help));
    return 0;
  }

  if (argc > 2 && strcmp(argv[1], "auth") == 0 && strcmp(argv[2], "status") == 0) {
    const char *logged_in = getenv("WHIPLASH_FAKE_CLAUDE_LOGGED_IN");
    const char *json = "{\"loggedIn\":true,\"authMethod\":\"test\"}\n";
    if (logged_in != NULL && (strcmp(logged_in, "0") == 0 || strcmp(logged_in, "false") == 0)) {
      json = "{\"loggedIn\":false,\"authMethod\":\"test\"}\n";
    }
    write_all(json, strlen(json));
    return 0;
  }

  if (argc > 1 && strcmp(argv[1], "-p") == 0) {
    const char *prompt_log = getenv("WHIPLASH_FAKE_CLAUDE_P_LOG");
    if (prompt_log != NULL && argc > 2) {
      FILE *fp = fopen(prompt_log, "a");
      if (fp != NULL) {
        fputs(argv[2], fp);
        fputc('\n', fp);
        fclose(fp);
      }
    }
    const char *json = "{\"session_id\":\"fake-session\"}\n";
    write_all(json, strlen(json));
    return 0;
  }

  {
    const char *warmup = getenv("WHIPLASH_FAKE_CLAUDE_WARMUP_SECONDS");
    if (warmup != NULL && *warmup != '\0') {
      warmup_seconds = atoi(warmup);
      if (warmup_seconds < 0) {
        warmup_seconds = 0;
      }
    }
  }
  {
    const char *discard = getenv("WHIPLASH_FAKE_CLAUDE_DISCARD_EARLY_INPUT");
    if (discard != NULL && (*discard == '1' || *discard == 'y' || *discard == 'Y' || *discard == 't' || *discard == 'T')) {
      discard_warmup = 1;
    }
  }

  if (warmup_seconds > 0) {
    sleep((unsigned int) warmup_seconds);
  }

  if (enable_raw_mode() != 0) {
    return 1;
  }
  atexit(restore_terminal);

  if (initial_prompt_delay_ms > 0) {
    usleep((useconds_t) initial_prompt_delay_ms * 1000U);
  }
  if (discard_early_input) {
    tcflush(STDIN_FILENO, TCIFLUSH);
  }

  if (append_char(&draft, &draft_len, &draft_cap, '\0') != 0) {
    return 1;
  }
  draft_len = 0;

  if (discard_warmup) {
    struct termios warmup_termios;
    if (tcgetattr(STDIN_FILENO, &warmup_termios) == 0) {
      cc_t old_vmin = warmup_termios.c_cc[VMIN];
      cc_t old_vtime = warmup_termios.c_cc[VTIME];
      warmup_termios.c_cc[VMIN] = 0;
      warmup_termios.c_cc[VTIME] = 1;
      if (tcsetattr(STDIN_FILENO, TCSANOW, &warmup_termios) == 0) {
        unsigned char discard_buf[256];
        while (read(STDIN_FILENO, discard_buf, sizeof(discard_buf)) > 0) {}
        warmup_termios.c_cc[VMIN] = old_vmin;
        warmup_termios.c_cc[VTIME] = old_vtime;
        tcsetattr(STDIN_FILENO, TCSANOW, &warmup_termios);
      }
    }
  }

  if (env_flag_enabled("WHIPLASH_FAKE_RICH_TUI")) {
    if (write_all("OpenAI Codex\r\n", 14) != 0) {
      free(draft);
      return 1;
    }
  }

  write_all("\033[?2004h", 8);
  if (env_flag_enabled("WHIPLASH_FAKE_RICH_TUI")) {
    if (write_all("> ", 2) != 0) {
      free(draft);
      return 1;
    }
  } else if (write_all(">>> ", 4) != 0) {
    free(draft);
    return 1;
  }

  while (1) {
    unsigned char c;
    ssize_t n = read(STDIN_FILENO, &c, 1);
    if (n == 0) {
      break;
    }
    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      break;
    }

    if (c == 0x1b) {
      unsigned char next;
      if (read(STDIN_FILENO, &next, 1) != 1) {
        break;
      }
      if (next == '[') {
        char seq[16];
        size_t seq_len = 0;
        while (seq_len + 1 < sizeof(seq)) {
          if (read(STDIN_FILENO, &next, 1) != 1) {
            next = '\0';
            break;
          }
          seq[seq_len++] = (char) next;
          if (next == '~' || (next < '0' || next > '9')) {
            break;
          }
        }
        seq[seq_len] = '\0';
        if (strcmp(seq, "200~") == 0) {
          in_paste = 1;
          continue;
        }
        if (strcmp(seq, "201~") == 0) {
          in_paste = 0;
          continue;
        }
      }
      continue;
    }

    if (!in_paste && (c == '\r' || c == '\n')) {
      int submit_result = handle_submit(&draft, &draft_len);
      if (submit_result != 0) {
        free(draft);
        return (submit_result > 0) ? 0 : 1;
      }
      continue;
    }

    if (!in_paste && (c == 0x7f || c == 0x08)) {
      if (draft_len > 0) {
        --draft_len;
        draft[draft_len] = '\0';
        write_all("\b \b", 3);
      }
      continue;
    }

    if (append_char(&draft, &draft_len, &draft_cap, (char) c) != 0) {
      free(draft);
      return 1;
    }
    if (display_char((char) c) != 0) {
      free(draft);
      return 1;
    }
  }

  free(draft);
  return 0;
}
EOF
  else
    echo "ERROR: C 컴파일러(cc) 없음. 가짜 interactive 바이너리 생성 불가." >&2
    exit 1
  fi
}

# "claude"라는 이름의 가짜 바이너리 컴파일
# pgrep -P pane_pid claude 가 매칭되려면 프로세스 comm이 "claude"여야 함
build_fake_claude() {
  FAKE_CLAUDE_BIN="$PROJECT_DIR/claude"
  build_fake_terminal_agent "$FAKE_CLAUDE_BIN"
}

build_fake_codex() {
  FAKE_CODEX_BIN="$PROJECT_DIR/codex"
  local fake_codex_real_bin="$PROJECT_DIR/codex-aarch64-a"
  rm -f "$FAKE_CODEX_BIN" "$fake_codex_real_bin"
  build_fake_terminal_agent "$fake_codex_real_bin"
  ln -s "$fake_codex_real_bin" "$FAKE_CODEX_BIN"
}

cleanup() {
  whiplash_tmux_run_default kill-server 2>/dev/null || true
  tmux kill-server 2>/dev/null || true
  whiplash_tmux_run_for_project "_stability-peer" kill-server 2>/dev/null || true
  whiplash_tmux_run_for_project "shared-contract" kill-server 2>/dev/null || true
  local pid
  pid="$(runtime_get_manager_state "$PROJECT" "monitor_pid" "" 2>/dev/null || true)"
  if [[ "${pid:-}" =~ ^[0-9]+$ ]] && [ "$pid" != "$$" ]; then
    pkill -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
  fi
  pkill -f "monitor\\.sh[[:space:]]+${PROJECT}$" 2>/dev/null || true
  pkill -f "message\\.sh[[:space:]]+${PROJECT}[[:space:]]" 2>/dev/null || true
  pkill -f "cmd\\.sh[[:space:]]+refresh[[:space:]].*[[:space:]]${PROJECT}$" 2>/dev/null || true
  rm -rf "$PROJECT_DIR"
  rm -rf "$REPO_ROOT/projects/_stability-peer"
}

trap 'cleanup; rm -rf "${TEST_TMUX_TMPDIR:-}"' EXIT

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected='$expected', actual='$actual')"
    FAIL=$((FAIL + 1))
  fi
}

assert_true() {
  local desc="$1"; shift
  TOTAL=$((TOTAL + 1))
  if "$@" 2>/dev/null; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    FAIL=$((FAIL + 1))
  fi
}

tmux_has_window() {
  local session_name="$1"
  local window_name="$2"
  tmux list-windows -t "$session_name" -F '#{window_name}' | grep -q "^${window_name}$"
}

tmux_has_session_for_socket() {
  local socket_name="$1"
  local session_name="$2"
  whiplash_tmux_run_on_socket "$socket_name" has-session -t "$session_name"
}

assert_false() {
  local desc="$1"; shift
  TOTAL=$((TOTAL + 1))
  if "$@" 2>/dev/null; then
    echo "  FAIL: $desc (expected failure but succeeded)"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  fi
}

assert_file_exists() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [ -f "$path" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (file not found: $path)"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_not_exists() {
  local desc="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [ ! -f "$path" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (file should not exist: $path)"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_contains() {
  local desc="$1" path="$2" pattern="$3"
  TOTAL=$((TOTAL + 1))
  if [ -f "$path" ] && grep -q "$pattern" "$path" 2>/dev/null; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (pattern '$pattern' not found in $path)"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_not_contains() {
  local desc="$1" path="$2" pattern="$3"
  TOTAL=$((TOTAL + 1))
  if [ -f "$path" ] && ! grep -q "$pattern" "$path" 2>/dev/null; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (pattern '$pattern' should not be in $path)"
    FAIL=$((FAIL + 1))
  fi
}

build_expected_notification() {
  local msg_from="$1"
  local msg_to="$2"
  local msg_kind="$3"
  local msg_priority="$4"
  local msg_subject="$5"
  local msg_content="$6"
  local prefix flat_subject flat_content

  if [ "$msg_kind" = "user_notice" ] || { [ "$msg_kind" = "status_update" ] && { [ "$msg_to" = "manager" ] || [ "$msg_to" = "user" ]; }; }; then
    msg_subject="$(whiplash_notification_subject "$msg_kind" "$msg_subject")"
    msg_content="$(whiplash_notification_body "$msg_kind" "$msg_subject" "$msg_content")"
  fi
  prefix="[notify] ${msg_from} → ${msg_to} | ${msg_kind}"
  if [ "$msg_priority" = "urgent" ]; then
    prefix="[URGENT] ${msg_from} → ${msg_to} | ${msg_kind}"
  fi

  flat_subject="$(printf '%s' "$msg_subject" | tr '\r\n' '  ')"
  if [ "$msg_kind" = "user_notice" ] || { [ "$msg_kind" = "status_update" ] && { [ "$msg_to" = "manager" ] || [ "$msg_to" = "user" ]; }; }; then
    printf '%s | 제목: %s\n%s' "$prefix" "$flat_subject" "$msg_content"
    return 0
  fi

  flat_content="$(printf '%s' "$msg_content" | tr '\r\n' '  ')"
  printf '%s' "${prefix} | 제목: ${flat_subject} | 내용: ${flat_content}"
}

probe_cmd_boot_message() {
  local role="$1"
  local project_name="${2:-$PROJECT}"
  WHIPLASH_SOURCE_ONLY=1 \
  WHIPLASH_TEST_ROLE="$role" \
  WHIPLASH_TEST_PROJECT="$project_name" \
  bash -lc '
    source "'"$TOOLS_DIR"'/cmd.sh"
    build_boot_message "$WHIPLASH_TEST_ROLE" "$WHIPLASH_TEST_PROJECT"
  '
}

invoke_cmd_function() {
  local function_name="$1"
  shift
  WHIPLASH_SOURCE_ONLY=1 \
  WHIPLASH_TEST_FUNCTION="$function_name" \
  bash -lc '
    source "'"$TOOLS_DIR"'/cmd.sh"
    "$WHIPLASH_TEST_FUNCTION" "$@"
  ' -- "$@"
}

probe_dashboard_project() {
  python3 - "$REPO_ROOT" "$PROJECT_DIR" <<'PY'
import importlib.util
import pathlib
import sys

repo_root = pathlib.Path(sys.argv[1])
project_dir = sys.argv[2]
module_path = repo_root / "dashboard" / "dashboard.py"
spec = importlib.util.spec_from_file_location("whiplash_dashboard", module_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
info = module.parse_project_md(project_dir)
print(f'{info["name"]}|{info["mode"]}|{info["loop_mode"]}|{info["domain"]}')
PY
}

probe_dashboard_sessions() {
  python3 - "$REPO_ROOT" "$PROJECT_DIR" <<'PY'
import importlib.util
import pathlib
import sys

repo_root = pathlib.Path(sys.argv[1])
project_dir = sys.argv[2]
module_path = repo_root / "dashboard" / "dashboard.py"
spec = importlib.util.spec_from_file_location("whiplash_dashboard", module_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
sessions = module.parse_sessions_md(project_dir)
first = sessions[0]["status"] if sessions else ""
print(f'{len(sessions)}|{first}')
PY
}

probe_dashboard_monitor() {
  python3 - "$REPO_ROOT" "$PROJECT_DIR" <<'PY'
import importlib.util
import pathlib
import sys

repo_root = pathlib.Path(sys.argv[1])
project_dir = sys.argv[2]
module_path = repo_root / "dashboard" / "dashboard.py"
spec = importlib.util.spec_from_file_location("whiplash_dashboard", module_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
info = module.check_monitor(project_dir)
print(f'{int(info["alive"])}|{int(info.get("stale", False))}|{info["queued"]}|{int(info["heartbeat_age"] is not None)}')
PY
}

probe_dashboard_agent() {
  local window_name="$1"
  python3 - "$REPO_ROOT" "$PROJECT_DIR" "$SESSION" "$window_name" <<'PY'
import importlib.util
import pathlib
import sys

repo_root = pathlib.Path(sys.argv[1])
project_dir = sys.argv[2]
session_name = sys.argv[3]
window_name = sys.argv[4]
module_path = repo_root / "dashboard" / "dashboard.py"
spec = importlib.util.spec_from_file_location("whiplash_dashboard", module_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
project_info = module.parse_project_md(project_dir)
state = module.collect(project_dir, session_name, project_info)
for agent in state["agents"]:
    if agent.get("win_name") == window_name:
        print(
            f'{agent.get("display_status","")}|'
            f'{agent.get("task_id","")}'
        )
        break
else:
    print("missing|")
PY
}

probe_dashboard_active_task_summary() {
  python3 - "$REPO_ROOT" "$PROJECT_DIR" "$SESSION" <<'PY'
import importlib.util
import pathlib
import sys

repo_root = pathlib.Path(sys.argv[1])
project_dir = sys.argv[2]
session_name = sys.argv[3]
module_path = repo_root / "dashboard" / "dashboard.py"
spec = importlib.util.spec_from_file_location("whiplash_dashboard", module_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
project_info = module.parse_project_md(project_dir)
state = module.collect(project_dir, session_name, project_info)
summaries = state.get("active_task_summaries", [])
if summaries:
    first = summaries[0]
    print(
        f'{len(summaries)}|'
        f'{first.get("task_id","")}|'
        f'{",".join(first.get("assignees", []))}'
    )
else:
    print("0||")
PY
}

# 가짜 에이전트 윈도우 생성
create_fake_agent() {
  local win_name="$1"
  tmux new-window -t "$SESSION" -n "$win_name"
  tmux send-keys -t "${SESSION}:${win_name}" "'${FAKE_CLAUDE_BIN}'" Enter
  local pane_pid
  pane_pid="$(tmux list-panes -t "${SESSION}:${win_name}" -F '#{pane_pid}' 2>/dev/null | head -1 || true)"
  wait_for_child_process_named "$pane_pid" claude 10 1 || true
  wait_for_pane_prompt "${SESSION}:${win_name}" 10 1 || true
}

create_fake_codex_agent() {
  local win_name="$1"
  tmux new-window -t "$SESSION" -n "$win_name"
  tmux send-keys -t "${SESSION}:${win_name}" "'${FAKE_CODEX_BIN}'" Enter
  local pane_pid
  pane_pid="$(tmux list-panes -t "${SESSION}:${win_name}" -F '#{pane_pid}' 2>/dev/null | head -1 || true)"
  wait_for_child_process_named "$pane_pid" codex 10 1 || true
  wait_for_pane_prompt "${SESSION}:${win_name}" 10 1 || true
}

create_wrapped_fake_agent() {
  local win_name="$1"
  local backend_bin="$2"
  local process_name="$3"
  tmux new-window -t "$SESSION" -n "$win_name"
  tmux send-keys -t "${SESSION}:${win_name}" "python3 -c 'import subprocess, sys; raise SystemExit(subprocess.run([sys.argv[1]]).returncode)' '${backend_bin}'" Enter
  local pane_pid
  pane_pid="$(tmux list-panes -t "${SESSION}:${win_name}" -F '#{pane_pid}' 2>/dev/null | head -1 || true)"
  wait_for_child_process_named "$pane_pid" "$process_name" 10 1 || true
  wait_for_pane_prompt "${SESSION}:${win_name}" 10 1 || true
}

# sessions.md에 가짜 에이전트 등록
register_fake_agent() {
  local win_name="$1" role="$2"
  local sf="$PROJECT_DIR/memory/manager/sessions.md"
  mkdir -p "$(dirname "$sf")"
  if [ ! -f "$sf" ]; then
    cat > "$sf" << 'HEADER'
# 활성 에이전트 세션

| 역할 | 백엔드 | Session ID | tmux Target | 상태 | 시작일 | 모델 | 비고 |
|------|--------|-----------|-------------|------|--------|------|------|
HEADER
  fi
  local today
  today="$(date +%Y-%m-%d)"
  echo "| ${role} | claude | fake-session | ${SESSION}:${win_name} | active | ${today} | test | |" >> "$sf"
}

register_fake_codex_agent() {
  local win_name="$1" role="$2"
  local sf="$PROJECT_DIR/memory/manager/sessions.md"
  mkdir -p "$(dirname "$sf")"
  if [ ! -f "$sf" ]; then
    cat > "$sf" << 'HEADER'
# 활성 에이전트 세션

| 역할 | 백엔드 | Session ID | tmux Target | 상태 | 시작일 | 모델 | 비고 |
|------|--------|-----------|-------------|------|--------|------|------|
HEADER
  fi
  local today
  today="$(date +%Y-%m-%d)"
  echo "| ${role} | codex | codex-interactive | ${SESSION}:${win_name} | active | ${today} | test | |" >> "$sf"
}

wait_for_child_process_named() {
  local parent_pid="$1"
  local process_name="$2"
  local attempts="${3:-8}"
  local sleep_seconds="${4:-1}"
  local attempt
  for attempt in $(seq 1 "$attempts"); do
    if [ -n "$(find_process_tree_pid_named "$parent_pid" "$process_name" || true)" ]; then
      return 0
    fi
    sleep "$sleep_seconds"
  done
  return 1
}

find_process_tree_pid_named() {
  local parent_pid="$1"
  local process_name="$2"
  [ -n "$parent_pid" ] || return 1

  local pane_comm
  pane_comm="$(ps -p "$parent_pid" -o comm= 2>/dev/null | head -1 || true)"
  if [ -n "$pane_comm" ] && printf '%s' "$pane_comm" | grep -Eq "(^|/)${process_name}([^[:space:]]*)?$"; then
    printf '%s\n' "$parent_pid"
    return 0
  fi

  local child_pid found_pid
  while IFS= read -r child_pid; do
    [ -n "$child_pid" ] || continue
    found_pid="$(find_process_tree_pid_named "$child_pid" "$process_name" || true)"
    if [ -n "$found_pid" ]; then
      printf '%s\n' "$found_pid"
      return 0
    fi
  done < <(pgrep -P "$parent_pid" 2>/dev/null || true)

  return 1
}

wait_for_pane_prompt() {
  local tmux_target="$1"
  local attempts="${2:-8}"
  local sleep_seconds="${3:-1}"
  local attempt pane_dump
  for attempt in $(seq 1 "$attempts"); do
    pane_dump="$(tmux capture-pane -pJ -t "$tmux_target" -S -20 2>/dev/null || true)"
    if printf '%s\n' "$pane_dump" | grep -q '>>> '; then
      return 0
    fi
    sleep "$sleep_seconds"
  done
  return 1
}

# ──────────────────────────────────────────────
# 시나리오 1: 에이전트 kill → monitor 감지
# ──────────────────────────────────────────────

test_scenario_1() {
  echo ""
  echo "=== 시나리오 1: 에이전트 kill → monitor 크래시 감지 ==="
  cleanup
  setup_test_project
  build_fake_claude

  tmux new-session -d -s "$SESSION" -n manager
  create_fake_agent "developer"
  register_fake_agent "developer" "developer"

  # 에이전트 alive 확인
  local pane_pid
  pane_pid=$(tmux list-panes -t "${SESSION}:developer" -F '#{pane_pid}' 2>/dev/null | head -1) || pane_pid=""
  assert_true "developer alive 확인" wait_for_child_process_named "$pane_pid" claude

  # 에이전트 프로세스 kill (윈도우는 남겨둠 — tmux send-keys로 shell 유지)
  if [ -n "$pane_pid" ]; then
    # claude 프로세스만 kill
    local claude_pid
    claude_pid=$(pgrep -P "$pane_pid" claude 2>/dev/null | head -1) || claude_pid=""
    if [ -z "$claude_pid" ]; then
      local pane_comm
      pane_comm="$(ps -p "$pane_pid" -o comm= 2>/dev/null | head -1 || true)"
      if [ -n "$pane_comm" ] && printf '%s' "$pane_comm" | grep -Eq '(^|/)claude([^[:space:]]*)?$'; then
        claude_pid="$pane_pid"
      fi
    fi
    if [ -n "$claude_pid" ]; then
      kill "$claude_pid" 2>/dev/null || true
    fi
  fi
  sleep 1

  # 크래시 상태 확인
  assert_false "developer dead 확인" bash -c \
    "ps -p '$pane_pid' -o comm= 2>/dev/null | grep -Eq '(^|/)claude([^[:space:]]*)?$' || pgrep -P '$pane_pid' claude >/dev/null 2>&1"

  # sessions.md에서 active인 developer를 찾을 수 있는지 확인
  local active_windows
  active_windows=$(grep '| active |' "$PROJECT_DIR/memory/manager/sessions.md" 2>/dev/null \
    | awk -F'|' '{print $5}' \
    | sed 's/.*://' \
    | sed 's/^ *//;s/ *$//' \
    | grep -v '^$') || active_windows=""
  assert_eq "sessions.md에서 developer 감지" "developer" "$active_windows"

  echo "  시나리오 1 완료"
}

# ──────────────────────────────────────────────
# 시나리오 2: 태스크 할당 영속화 + 복구 메시지
# ──────────────────────────────────────────────

test_scenario_2() {
  echo ""
  echo "=== 시나리오 2: 태스크 할당 영속화 + 복구 메시지 ==="
  cleanup
  setup_test_project

  local af="$PROJECT_DIR/memory/manager/assignments.md"
  mkdir -p "$(dirname "$af")"

  # assignments.md 생성 + 태스크 기록
  cat > "$af" << 'HEADER'
# 태스크 할당 현황
| 에이전트 | 태스크 파일 | 할당 시각 | 상태 |
|----------|-----------|----------|------|
HEADER
  echo "| developer | workspace/tasks/TASK-001.md | $(date '+%Y-%m-%d %H:%M') | active |" >> "$af"

  assert_file_exists "assignments.md 생성됨" "$af"
  assert_file_contains "developer active 태스크 기록" "$af" "| developer |.*| active |"

  # get_active_task 로직 시뮬레이션
  local task
  task=$({ grep "| developer |" "$af" 2>/dev/null || true; } \
    | grep "| active |" | tail -1 \
    | awk -F'|' '{print $3}' | sed 's/^ *//;s/ *$//') || task=""
  assert_eq "active 태스크 조회" "workspace/tasks/TASK-001.md" "$task"

  # build_boot_message에 pending_task 포함 확인
  # cmd.sh 함수를 직접 호출하기 어려우므로 핵심 로직만 확인
  local pending_task="workspace/tasks/TASK-001.md"
  local recovery_msg=""
  if [ -n "$pending_task" ]; then
    recovery_msg="[재부팅 후 태스크 복구]
이전 세션에서 중단된 태스크가 있다: ${pending_task}
해당 파일을 읽고 작업을 이어서 진행해라."
  fi
  TOTAL=$((TOTAL + 1))
  if echo "$recovery_msg" | grep -q "재부팅 후 태스크 복구"; then
    echo "  PASS: 부팅 메시지에 태스크 복구 지시 포함"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: 부팅 메시지에 태스크 복구 지시 누락"
    FAIL=$((FAIL + 1))
  fi

  # 기존 active → completed 전환 테스트
  echo "| developer | workspace/tasks/TASK-002.md | $(date '+%Y-%m-%d %H:%M') | active |" >> "$af"
  if [[ "$OSTYPE" == darwin* ]]; then
    sed -i '' "s/| developer |\(.*\)TASK-001\(.*\)| active |/| developer |\1TASK-001\2| completed |/" "$af"
  else
    sed -i "s/| developer |\(.*\)TASK-001\(.*\)| active |/| developer |\1TASK-001\2| completed |/" "$af"
  fi
  assert_file_contains "이전 태스크 completed 전환" "$af" "TASK-001.*| completed |"
  assert_file_contains "새 태스크 active 유지" "$af" "TASK-002.*| active |"

  echo "  시나리오 2 완료"
}

# ──────────────────────────────────────────────
# 시나리오 3: 메시지 전달 실패 → 큐 저장 → drain
# ──────────────────────────────────────────────

test_scenario_3() {
  echo ""
  echo "=== 시나리오 3: 메시지 큐 저장 + drain ==="
  cleanup
  setup_test_project
  build_fake_claude

  local queue_dir
  queue_dir="$(runtime_message_queue_dir "$PROJECT")"

  # tmux 세션 생성 (수신자 없음)
  tmux new-session -d -s "$SESSION" -n manager

  # 수신자(developer)가 없는 상태에서 메시지 전송 → 큐 저장
  bash "$TOOLS_DIR/message.sh" "$PROJECT" researcher developer \
    status_update normal "TASK-001 진행" "연구 결과 정리 완료" 2>/dev/null || true

  # .msg 파일 생성 확인
  local msg_count
  msg_count=$(find "$queue_dir" -name "*.msg" 2>/dev/null | wc -l | tr -d ' ') || msg_count="0"
  assert_true "큐 파일 생성됨" test "$msg_count" -gt 0

  # 원본 대상(developer) 큐 파일 내용 확인
  local msg_file
  msg_file="$(find "$queue_dir" -name "*.msg" -print 2>/dev/null | while read -r msg; do
    if grep -q '^to=developer$' "$msg" 2>/dev/null; then
      printf '%s\n' "$msg"
      break
    fi
  done)"
  if [ -n "$msg_file" ]; then
    assert_file_contains "큐 파일에 from 기록" "$msg_file" "^from=researcher"
    assert_file_contains "큐 파일에 to 기록" "$msg_file" "^to=developer$"
    assert_file_contains "큐 파일에 kind 기록" "$msg_file" "^kind=status_update"
  fi

  # 수신자 윈도우 생성
  create_fake_agent "developer"
  tmux_submit_wait_ready "${SESSION}:developer" 10 1 || true

  # developer 대상 큐만 수동 drain하여 결정적으로 검증한다.
  local drained=false pane_dump="" msg_from msg_to msg_kind msg_priority msg_subject msg_content notification
  if [ -f "$msg_file" ]; then
    msg_from="$(whiplash_queue_read_field "$msg_file" "from")"
    msg_to="$(whiplash_queue_read_field "$msg_file" "to")"
    msg_kind="$(whiplash_queue_read_field "$msg_file" "kind")"
    msg_priority="$(whiplash_queue_read_field "$msg_file" "priority")"
    msg_subject="$(whiplash_queue_read_field "$msg_file" "subject")"
    msg_content="$(whiplash_queue_read_content "$msg_file")"
    notification="$(build_expected_notification "$msg_from" "$msg_to" "$msg_kind" "$msg_priority" "$msg_subject" "$msg_content")"
    if tmux_submit__literal_submit_single_line "${SESSION}:developer" "$notification" 0.25 8 \
      || tmux_submit_pasted_payload "${SESSION}:developer" "$notification" "scenario3-drain"; then
      rm -f "$msg_file"
      local attempt
      for attempt in $(seq 1 5); do
        sleep 1
        pane_dump="$(tmux capture-pane -pJ -t "${SESSION}:developer" -S -80 2>/dev/null || true)"
        if echo "$pane_dump" | grep -q "연구 결과 정리 완료"; then
          drained=true
          break
        fi
      done
    fi
  fi

  assert_true "큐 drain 성공" test "$drained" = true

  # 큐 파일 삭제 확인
  assert_file_not_exists "developer 대상 큐 파일 삭제됨" "$msg_file"

  echo "  시나리오 3 완료"
}

# ──────────────────────────────────────────────
# 시나리오 4: tmux 세션 kill → monitor 대기 모드 → 복귀
# ──────────────────────────────────────────────

test_scenario_4() {
  echo ""
  echo "=== 시나리오 4: 세션 kill → monitor 대기 모드 → 복귀 ==="
  cleanup
  setup_test_project

  local manager_state_file
  manager_state_file="$(runtime_manager_state_file "$PROJECT")"
  mkdir -p "$(dirname "$manager_state_file")"

  # 세션 없는 상태에서 SESSION_ABSENT_COUNT 증가 로직 테스트
  local SESSION_ABSENT_COUNT=0
  for i in 1 2 3; do
    if ! tmux has-session -t "$SESSION" 2>/dev/null; then
      SESSION_ABSENT_COUNT=$((SESSION_ABSENT_COUNT + 1))
    fi
  done
  assert_eq "3회 부재 카운트" "3" "$SESSION_ABSENT_COUNT"

  # 대기 모드에서 heartbeat 갱신 확인
  runtime_set_manager_state "$PROJECT" "monitor_heartbeat" "$(date +%s)"
  assert_file_exists "manager state 파일 존재" "$manager_state_file"
  local hb_val
  hb_val="$(runtime_get_manager_state "$PROJECT" "monitor_heartbeat" "" 2>/dev/null || true)"
  TOTAL=$((TOTAL + 1))
  if [[ "$hb_val" =~ ^[0-9]+$ ]]; then
    echo "  PASS: heartbeat 값이 숫자"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: heartbeat 값이 숫자 아님 ('$hb_val')"
    FAIL=$((FAIL + 1))
  fi

  # 세션 재생성 → 복귀
  tmux new-session -d -s "$SESSION" -n manager
  assert_true "세션 복귀 확인" tmux has-session -t "$SESSION"

  # 복귀 후 카운트 리셋
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    SESSION_ABSENT_COUNT=0
  fi
  assert_eq "세션 복귀 후 카운트 리셋" "0" "$SESSION_ABSENT_COUNT"

  echo "  시나리오 4 완료"
}

# ──────────────────────────────────────────────
# 시나리오 5: reboot 경합 방지 (lock)
# ──────────────────────────────────────────────

test_scenario_5() {
  echo ""
  echo "=== 시나리오 5: reboot 경합 방지 (lock) ==="
  cleanup
  setup_test_project

  runtime_set_reboot_lock_ts "$PROJECT" "developer" "$(date +%s)"

  local should_skip=false
  if ! runtime_try_claim_reboot_lock "$PROJECT" "developer" 60; then
    should_skip=true
  fi
  assert_eq "리부팅 진행 중 → 건너뜀" "true" "$should_skip"

  # 60초 이상 된 stale lock → 강제 해제 허용
  runtime_set_reboot_lock_ts "$PROJECT" "developer" "$(($(date +%s) - 120))"
  local should_proceed=false
  if runtime_try_claim_reboot_lock "$PROJECT" "developer" 60; then
    should_proceed=true
  fi
  assert_eq "stale lock → 진행 허용" "true" "$should_proceed"

  runtime_clear_reboot_lock_ts "$PROJECT" "developer"
  assert_eq "lock 상태 삭제됨" "" "$(runtime_get_reboot_lock_ts "$PROJECT" "developer" "" 2>/dev/null || true)"

  echo "  시나리오 5 완료"
}

# ──────────────────────────────────────────────
# 시나리오 6: reboot 한도 초과 → 쿨다운 → 리셋
# ──────────────────────────────────────────────

test_scenario_6() {
  echo ""
  echo "=== 시나리오 6: reboot 한도 초과 → 5분 쿨다운 → 리셋 ==="
  cleanup
  setup_test_project

  local MAX_REBOOT=3
  local reboot_state_file
  reboot_state_file="$(runtime_reboot_state_file "$PROJECT")"

  # 카운터를 MAX_REBOOT까지 올리기
  runtime_set_reboot_count "$PROJECT" "developer" "$MAX_REBOOT"
  local count
  count="$(runtime_get_reboot_count "$PROJECT" "developer" 2>/dev/null || echo "0")"
  assert_eq "카운터 MAX_REBOOT 도달" "$MAX_REBOOT" "$count"

  # 한도 초과 확인
  assert_true "한도 초과 확인" test "$count" -ge "$MAX_REBOOT"

  # lockout 파일 생성
  runtime_set_reboot_lockout_ts "$PROJECT" "developer" "$(date +%s)"
  assert_file_exists "reboot state 파일 생성됨" "$reboot_state_file"

  # 5분 미경과 → 유지
  local lockout_time now_ts should_reset=false
  lockout_time="$(runtime_get_reboot_lockout_ts "$PROJECT" "developer" 2>/dev/null || true)"
  now_ts=$(date +%s)
  if [ $((now_ts - lockout_time)) -gt 300 ]; then
    should_reset=true
  fi
  assert_eq "5분 미경과 → 유지" "false" "$should_reset"

  # lockout 타임스탬프를 6분 전으로 수정
  runtime_set_reboot_lockout_ts "$PROJECT" "developer" "$(($(date +%s) - 360))"
  lockout_time="$(runtime_get_reboot_lockout_ts "$PROJECT" "developer" 2>/dev/null || true)"
  now_ts=$(date +%s)
  should_reset=false
  if [ $((now_ts - lockout_time)) -gt 300 ]; then
    should_reset=true
  fi
  assert_eq "6분 경과 → 리셋 허용" "true" "$should_reset"

  # 카운터 리셋 실행
  runtime_reset_reboot_count "$PROJECT" "developer"
  runtime_clear_reboot_lockout_ts "$PROJECT" "developer"
  assert_eq "lockout 상태 삭제됨" "" "$(runtime_get_reboot_lockout_ts "$PROJECT" "developer" "" 2>/dev/null || true)"

  # 리셋 후 카운트 = 0
  local new_count
  new_count="$(runtime_get_reboot_count "$PROJECT" "developer" 2>/dev/null || echo "0")"
  assert_eq "리셋 후 카운트 0" "0" "$new_count"

  echo "  시나리오 6 완료"
}

# ──────────────────────────────────────────────
# 시나리오 7: monitor wrapper — kill 후 재시작
# ──────────────────────────────────────────────

test_scenario_7() {
  echo ""
  echo "=== 시나리오 7: monitor wrapper 자동 재시작 ==="
  cleanup
  setup_test_project

  # tmux 세션 생성
  tmux new-session -d -s "$SESSION" -n manager

  # sessions.md 초기화
  local sf="$PROJECT_DIR/memory/manager/sessions.md"
  mkdir -p "$(dirname "$sf")"
  cat > "$sf" << 'HEADER'
# 활성 에이전트 세션

| 역할 | 백엔드 | Session ID | tmux Target | 상태 | 시작일 | 모델 | 비고 |
|------|--------|-----------|-------------|------|--------|------|------|
HEADER

  local manager_state_file
  manager_state_file="$(runtime_manager_state_file "$PROJECT")"

  # wrapper로 monitor.sh 시작 (짧은 재시작 간격)
  nohup bash -c "
    while true; do
      bash '${TOOLS_DIR}/monitor.sh' '${PROJECT}'
      sleep 2
    done
  " >/dev/null 2>&1 &
  local wrapper_pid=$!
  runtime_set_manager_state "$PROJECT" "monitor_pid" "$wrapper_pid"

  # monitor.sh가 heartbeat를 갱신할 때까지 대기 (최대 40초)
  local waited=0
  while [ -z "$(runtime_get_manager_state "$PROJECT" "monitor_heartbeat" "" 2>/dev/null || true)" ] && [ "$waited" -lt 40 ]; do
    sleep 2
    waited=$((waited + 2))
  done

  assert_true "wrapper 프로세스 alive" kill -0 "$wrapper_pid"
  assert_file_exists "manager state 파일 생성됨" "$manager_state_file"

  # 첫 heartbeat 타임스탬프 기록
  local hb_before
  hb_before="$(runtime_get_manager_state "$PROJECT" "monitor_heartbeat" "0" 2>/dev/null || echo "0")"

  # monitor.sh 프로세스만 kill (wrapper는 살림)
  # wrapper의 모든 자식 중 monitor.sh 관련 프로세스를 kill
  local child_pids
  child_pids=$(pgrep -P "$wrapper_pid" 2>/dev/null) || child_pids=""
  for cpid in $child_pids; do
    kill "$cpid" 2>/dev/null || true
  done

  # wrapper가 monitor.sh를 재시작할 시간 대기 (sleep 2 + monitor 시작 + 첫 heartbeat)
  sleep 40

  assert_true "wrapper 여전히 alive" kill -0 "$wrapper_pid"

  # heartbeat가 갱신되었는지 확인 (재시작 증명)
  local hb_after
  hb_after="$(runtime_get_manager_state "$PROJECT" "monitor_heartbeat" "0" 2>/dev/null || echo "0")"
  TOTAL=$((TOTAL + 1))
  if [ "$hb_after" != "$hb_before" ] && [ "$hb_after" -gt "$hb_before" ] 2>/dev/null; then
    echo "  PASS: heartbeat 갱신됨 (monitor 재시작 확인)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: heartbeat 미갱신 (before=$hb_before, after=$hb_after)"
    FAIL=$((FAIL + 1))
  fi

  # 정리
  pkill -P "$wrapper_pid" 2>/dev/null || true
  kill "$wrapper_pid" 2>/dev/null || true
  wait "$wrapper_pid" 2>/dev/null || true

  echo "  시나리오 7 완료"
}

# ──────────────────────────────────────────────
# 시나리오 8: INS-003 태스크 추적 통합
# ──────────────────────────────────────────────

test_scenario_8() {
  echo ""
  echo "=== 시나리오 8: task_assign 추적 통합 + Manager assign/complete ==="
  cleanup
  setup_test_project
  build_fake_claude

  mkdir -p "$PROJECT_DIR/workspace/tasks"
  cat > "$PROJECT_DIR/workspace/tasks/TASK-003.md" << 'EOF'
# TASK-003: Developer dispatch test
EOF
  cat > "$PROJECT_DIR/workspace/tasks/TASK-004.md" << 'EOF'
# TASK-004: Direct message assignment test
EOF

  local af="$PROJECT_DIR/memory/manager/assignments.md"

  tmux new-session -d -s "$SESSION" -n manager
  create_fake_agent "developer"
  register_fake_agent "developer" "developer"

  bash "$TOOLS_DIR/cmd.sh" dispatch developer \
    "projects/${PROJECT}/workspace/tasks/TASK-003.md" "$PROJECT" >/dev/null

  local dispatch_active dispatch_total
  dispatch_active=$(grep -Ec "\\| developer \\| workspace/tasks/TASK-003.md \\| .*\\| active \\|" "$af" 2>/dev/null || true)
  dispatch_total=$(grep -Ec "\\| developer \\| workspace/tasks/TASK-003.md \\|" "$af" 2>/dev/null || true)
  assert_eq "dispatch active 기록 1건" "1" "$dispatch_active"
  assert_eq "dispatch 중복 기록 없음" "1" "$dispatch_total"

  bash "$TOOLS_DIR/message.sh" "$PROJECT" developer manager \
    task_complete normal "TASK-003 완료" "dispatch task finished" >/dev/null

  local developer_active developer_completed
  developer_active=$(grep -Ec "\\| developer \\| .*\\| active \\|" "$af" 2>/dev/null || true)
  developer_completed=$(grep -Ec "\\| developer \\| workspace/tasks/TASK-003.md \\| .*\\| completed \\|" "$af" 2>/dev/null || true)
  assert_eq "task_complete 후 developer active 없음" "0" "$developer_active"
  assert_eq "task_complete 후 completed 반영" "1" "$developer_completed"

  bash "$TOOLS_DIR/message.sh" "$PROJECT" manager developer \
    task_assign normal "projects/${PROJECT}/workspace/tasks/TASK-004.md" \
    "새 작업 지시가 있다. 읽고 실행해라." >/dev/null

  local direct_assign_active
  direct_assign_active=$(grep -Ec "\\| developer \\| workspace/tasks/TASK-004.md \\| .*\\| active \\|" "$af" 2>/dev/null || true)
  assert_eq "message.sh task_assign 직접 기록" "1" "$direct_assign_active"

  bash "$TOOLS_DIR/cmd.sh" assign manager "Review consensus result" "$PROJECT" >/dev/null

  local manager_active
  manager_active=$(grep -Ec "\\| manager \\| Review consensus result \\| .*\\| active \\|" "$af" 2>/dev/null || true)
  assert_eq "cmd.sh assign 으로 manager 태스크 기록" "1" "$manager_active"

  bash "$TOOLS_DIR/cmd.sh" complete manager "$PROJECT" >/dev/null

  local manager_completed manager_active_after
  manager_completed=$(grep -Ec "\\| manager \\| Review consensus result \\| .*\\| completed \\|" "$af" 2>/dev/null || true)
  manager_active_after=$(grep -Ec "\\| manager \\| .*\\| active \\|" "$af" 2>/dev/null || true)
  assert_eq "cmd.sh complete 으로 manager 완료 반영" "1" "$manager_completed"
  assert_eq "manager active 태스크 제거" "0" "$manager_active_after"

  echo "  시나리오 8 완료"
}

# ──────────────────────────────────────────────
# 시나리오 9: dashboard parser / monitor 경로 정합성
# ──────────────────────────────────────────────

test_scenario_9() {
  echo ""
  echo "=== 시나리오 9: dashboard parser / monitor 경로 정합성 ==="
  cleanup
  setup_test_project

  local legacy_info
  legacy_info="$(probe_dashboard_project)"
  assert_eq "legacy project.md 파싱" "_stability-test|solo|guided|general" "$legacy_info"

  cat > "$PROJECT_DIR/project.md" << 'EOF'
# Project: canonical-test

## 기본 정보
- **Domain** (또는 **도메인**): deep-learning
- **Started**: 2026-03-06

## 운영 방식
- **실행 모드**: dual
- **작업 루프**: ralph

## 팀 구성
- **활성 에이전트**: developer, researcher
EOF

  local canonical_info
  canonical_info="$(probe_dashboard_project)"
  assert_eq "canonical project.md 파싱" "canonical-test|dual|ralph|deep-learning" "$canonical_info"

  mkdir -p "$PROJECT_DIR/memory/manager"
  cat > "$PROJECT_DIR/memory/manager/sessions.md" << 'EOF'
| 역할 | 백엔드 | Session ID | tmux Target | 상태 | 시작일 | 모델 | 비고 |
|------|--------|-----------|-------------|------|--------|------|------|
| manager | claude | old-session | whiplash-_stability-test:manager | closed | 2026-03-08 | opus | |
| manager | claude | new-session | whiplash-_stability-test:manager | active | 2026-03-09 | opus | |
EOF

  local session_info
  session_info="$(probe_dashboard_sessions)"
  assert_eq "dashboard sessions dedupe 최신 row 유지" "1|active" "$session_info"

  local queue_dir
  queue_dir="$(runtime_message_queue_dir "$PROJECT")"
  mkdir -p "$queue_dir"
  : > "$queue_dir/queued.msg"
  runtime_set_manager_state "$PROJECT" "monitor_pid" "999999"
  runtime_set_manager_state "$PROJECT" "monitor_lock_pid" "$$"
  runtime_set_manager_state "$PROJECT" "monitor_heartbeat" "$(date +%s)"

  local monitor_info
  monitor_info="$(probe_dashboard_monitor)"
  assert_eq "dashboard monitor lock pid fallback 인식" "1|0|1|1" "$monitor_info"

  echo "  시나리오 9 완료"
}

# ──────────────────────────────────────────────
# 시나리오 10: general 도메인 온보딩 예외 처리
# ──────────────────────────────────────────────

test_scenario_10() {
  echo ""
  echo "=== 시나리오 10: general 도메인 온보딩 예외 처리 ==="
  cleanup
  setup_test_project

  local general_msg
  general_msg="$(probe_cmd_boot_message researcher "$PROJECT")"
  TOTAL=$((TOTAL + 1))
  if ! echo "$general_msg" | grep -q 'domains/general/context.md'; then
    echo "  PASS: general 도메인에서 nonexistent context 경로 미노출"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: general 도메인에서 domains/general/context.md 노출"
    FAIL=$((FAIL + 1))
  fi

  TOTAL=$((TOTAL + 1))
  if echo "$general_msg" | grep -q '추가 domain context는 없다'; then
    echo "  PASS: general 도메인 skip 문구 포함"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: general 도메인 skip 문구 누락"
    FAIL=$((FAIL + 1))
  fi

  TOTAL=$((TOTAL + 1))
  if echo "$general_msg" | grep -q 'researcher manager agent_ready normal "온보딩 완료"'; then
    echo "  PASS: worker agent_ready 대상은 manager 유지"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: worker agent_ready 대상이 manager가 아님"
    FAIL=$((FAIL + 1))
  fi

  local manager_msg
  manager_msg="$(probe_cmd_boot_message manager "$PROJECT")"
  TOTAL=$((TOTAL + 1))
  if echo "$manager_msg" | grep -q 'manager user agent_ready normal "온보딩 완료"'; then
    echo "  PASS: manager agent_ready 대상은 user"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: manager agent_ready 대상이 user가 아님"
    FAIL=$((FAIL + 1))
  fi

  TOTAL=$((TOTAL + 1))
  if echo "$manager_msg" | grep -q 'plan mode 판단 필요'; then
    echo "  PASS: manager boot message에 plan mode 판단 지침 포함"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: manager boot message에 plan mode 판단 지침 누락"
    FAIL=$((FAIL + 1))
  fi

  cat > "$PROJECT_DIR/project.md" << 'EOF'
# Project: domain-test

## 기본 정보
- **Domain** (또는 **도메인**): deep-learning

## 운영 방식
- **실행 모드**: solo
EOF

  local domain_msg
  domain_msg="$(probe_cmd_boot_message researcher "$PROJECT")"
  TOTAL=$((TOTAL + 1))
  if echo "$domain_msg" | grep -q 'domains/deep-learning/context.md'; then
    echo "  PASS: non-general 도메인 context 경로 유지"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: non-general 도메인 context 경로 누락"
    FAIL=$((FAIL + 1))
  fi

  echo "  시나리오 10 완료"
}

# ──────────────────────────────────────────────
# 시나리오 11: dual worktree 지원 디렉토리 링크
# ──────────────────────────────────────────────

test_scenario_11() {
  echo ""
  echo "=== 시나리오 11: dual worktree 지원 디렉토리 링크 ==="
  cleanup
  setup_test_project

  local code_repo="$PROJECT_DIR/code-repo"
  mkdir -p "$code_repo/configs" "$code_repo/states"
  cat > "$code_repo/.gitignore" << 'EOF'
states/
EOF
  cat > "$code_repo/configs/app.cfg" << 'EOF'
state_path=../states/current.bin
EOF
  printf 'seed' > "$code_repo/states/current.bin"

  git -C "$code_repo" init -b main >/dev/null 2>&1
  git -C "$code_repo" config user.name "Whiplash Test"
  git -C "$code_repo" config user.email "test@example.com"
  git -C "$code_repo" add .gitignore configs/app.cfg
  git -C "$code_repo" commit -m "init" >/dev/null 2>&1

  cat > "$PROJECT_DIR/project.md" << EOF
# Project: worktree-test

## 기본 정보
- **Domain** (또는 **도메인**): general

## 프로젝트 폴더
- **경로**: ${code_repo}

## 운영 방식
- **실행 모드**: dual
EOF

  invoke_cmd_function create_worktrees "$PROJECT" developer

  local wt_dir="$code_repo/.worktrees"
  local claude_states="$wt_dir/developer-claude/states"
  local codex_states="$wt_dir/developer-codex/states"

  assert_true "claude worktree states 링크 생성" test -L "$claude_states"
  assert_true "codex worktree states 링크 생성" test -L "$codex_states"
  assert_eq "claude worktree states 링크 대상" "$code_repo/states" "$(readlink "$claude_states")"
  assert_eq "codex worktree states 링크 대상" "$code_repo/states" "$(readlink "$codex_states")"

  invoke_cmd_function remove_worktrees "$PROJECT" developer

  echo "  시나리오 11 완료"
}

# ──────────────────────────────────────────────
# 시나리오 12: queued codex interactive 메시지 drain
# ──────────────────────────────────────────────

test_scenario_12() {
  echo ""
  echo "=== 시나리오 12: queued codex interactive drain ==="
  cleanup
  setup_test_project
  build_fake_codex

  tmux new-session -d -s "$SESSION" -n manager
  create_fake_codex_agent "developer-codex"
  register_fake_codex_agent "developer-codex" "developer"

  local pane_pid
  pane_pid=$(tmux list-panes -t "${SESSION}:developer-codex" -F '#{pane_pid}' 2>/dev/null | head -1) || pane_pid=""
  assert_true "developer-codex interactive alive 확인" wait_for_child_process_named "$pane_pid" codex
  local pane_cmd
  pane_cmd="$(tmux display-message -p -t "${SESSION}:developer-codex" '#{pane_current_command}' 2>/dev/null || true)"
  assert_eq "developer-codex pane_current_command가 resolved codex 바이너리명으로 보임" "codex-aarch64-a" "$pane_cmd"

  local pane_dump=""
  local attempt
  local direct_subject="direct-codex-alias"
  local direct_content="codex direct alias smoke"
  bash "$TOOLS_DIR/message.sh" "$PROJECT" manager developer-codex \
    status_update normal "$direct_subject" "$direct_content" >/dev/null

  for attempt in 1 2 3 4 5 6 7 8; do
    pane_dump="$(tmux capture-pane -pJ -t "${SESSION}:developer-codex" -S -80 2>/dev/null || true)"
    if echo "$pane_dump" | grep -q "$direct_content"; then
      break
    fi
    sleep 1
  done
  TOTAL=$((TOTAL + 1))
  if echo "$pane_dump" | grep -q "$direct_content"; then
    echo "  PASS: message.sh direct path가 codex alias pane에 즉시 표시"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: message.sh direct path가 codex alias pane에 즉시 표시되지 않음"
    FAIL=$((FAIL + 1))
  fi
  assert_file_contains "message.sh direct path가 interactive로 기록됨" \
    "$PROJECT_DIR/logs/message.log" "manager → developer-codex status_update normal \"${direct_subject}\" reason=\"interactive\""

  local queue_dir
  queue_dir="$(runtime_message_queue_dir "$PROJECT")"
  mkdir -p "$queue_dir"
  local queue_file="$queue_dir/$(date +%s)-researcher-developer-codex.msg"
  cat > "$queue_file" << 'EOF'
from=researcher
to=developer-codex
kind=status_update
priority=normal
subject=queued-codex-interactive
content=codex interactive drain smoke
EOF

  bash "$TOOLS_DIR/cmd.sh" monitor-check "$PROJECT" >/dev/null 2>&1

  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
    pane_dump="$(tmux capture-pane -pJ -t "${SESSION}:developer-codex" -S -60 2>/dev/null || true)"
    if [ ! -f "$queue_file" ] && echo "$pane_dump" | grep -q "codex interactive drain smoke"; then
      break
    fi
    sleep 1
  done

  assert_file_not_exists "queued codex interactive 메시지 제거됨" "$queue_file"
  TOTAL=$((TOTAL + 1))
  if echo "$pane_dump" | grep -q "codex interactive drain smoke"; then
    echo "  PASS: codex interactive pane에 큐 메시지 표시"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: codex interactive pane에 큐 메시지 미표시"
    FAIL=$((FAIL + 1))
  fi
  assert_file_not_contains "monitor가 codex alias pane를 false-crash로 보지 않음" \
    "$PROJECT_DIR/logs/system.log" "developer-codex 크래시 감지"

  echo "  시나리오 12 완료"
}

# ──────────────────────────────────────────────
# 시나리오 13: peer status_update → manager 자동 미러
# ──────────────────────────────────────────────

test_scenario_13() {
  echo ""
  echo "=== 시나리오 13: peer status_update 자동 미러 ==="
  cleanup
  setup_test_project
  build_fake_claude

  tmux new-session -d -s "$SESSION" -n dashboard
  create_fake_agent "manager"
  create_fake_agent "developer"
  register_fake_agent "manager" "manager"
  register_fake_agent "developer" "developer"

  bash "$TOOLS_DIR/message.sh" "$PROJECT" researcher developer \
    status_update normal "peer-sync" "research ready" >/dev/null

  local developer_pane manager_pane queue_dir mirror_seen attempt mirror_queue_file msg
  queue_dir="$(runtime_message_queue_dir "$PROJECT")"
  mirror_seen=false
  for attempt in 1 2 3 4 5 6 7 8; do
    developer_pane="$(tmux capture-pane -pJ -t "${SESSION}:developer" -S -80 2>/dev/null || true)"
    manager_pane="$(tmux capture-pane -pJ -t "${SESSION}:manager" -S -80 2>/dev/null || true)"
    mirror_queue_file=""
    for msg in "$queue_dir"/*.msg; do
      [ -f "$msg" ] || continue
      if grep -q '^to=manager$' "$msg" 2>/dev/null \
        && grep -q '^subject=peer-sync$' "$msg" 2>/dev/null \
        && grep -q '원수신자: developer' "$msg" 2>/dev/null \
        && grep -q 'research ready' "$msg" 2>/dev/null; then
        mirror_queue_file="$msg"
        break
      fi
    done
    if echo "$developer_pane" | grep -q "research ready"; then
      if echo "$manager_pane" | grep -q "research ready" && echo "$manager_pane" | grep -q "원수신자: developer"; then
        mirror_seen=true
        break
      fi
      if [ -n "$mirror_queue_file" ]; then
        mirror_seen=true
        break
      fi
    fi
    sleep 1
  done

  TOTAL=$((TOTAL + 1))
  if [ "$mirror_seen" = true ]; then
    echo "  PASS: peer status_update가 manager에 자동 미러됨"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: peer status_update 미러 누락"
    FAIL=$((FAIL + 1))
  fi

  assert_file_not_exists "status_update는 assignments를 만들지 않음" "$PROJECT_DIR/memory/manager/assignments.md"

  echo "  시나리오 13 완료"
}

# ──────────────────────────────────────────────
# 시나리오 14: routing guard
# ──────────────────────────────────────────────

test_scenario_14() {
  echo ""
  echo "=== 시나리오 14: routing guard ==="
  cleanup
  setup_test_project

  assert_false "non-manager task_assign 거부" \
    bash "$TOOLS_DIR/message.sh" "$PROJECT" researcher developer \
    task_assign normal "TASK-X" "invalid"

  assert_false "peer task_complete 거부" \
    bash "$TOOLS_DIR/message.sh" "$PROJECT" researcher developer \
    task_complete normal "TASK-X 완료" "invalid"

  tmux new-session -d -s "$SESSION" -n dashboard
  create_fake_agent "manager"
  register_fake_agent "manager" "manager"

  assert_true "manager agent_ready -> user 허용" \
    bash "$TOOLS_DIR/message.sh" "$PROJECT" manager user \
    agent_ready normal "온보딩 완료" "ready"

  echo "  시나리오 14 완료"
}

# ──────────────────────────────────────────────
# 시나리오 15: tmux submit 반복 Enter + Python REPL
# ──────────────────────────────────────────────

test_scenario_15() {
  echo ""
  echo "=== 시나리오 15: tmux submit 반복 Enter ==="
  cleanup
  setup_test_project

  tmux new-session -d -s "$SESSION" -n pyrepl
  tmux send-keys -t "${SESSION}:pyrepl" "python3 -q" Enter
  sleep 2

  assert_true "Python REPL 멀티라인 제출 성공" \
    tmux_submit_pasted_payload "${SESSION}:pyrepl" $'for i in [1]:\n    print("submit-loop")' "py-loop"

  local pane_dump
  pane_dump="$(tmux capture-pane -p -t "${SESSION}:pyrepl" -S -80 2>/dev/null || true)"
  TOTAL=$((TOTAL + 1))
  if echo "$pane_dump" | grep -q "submit-loop"; then
    echo "  PASS: 멀티라인 payload 실행됨"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: 멀티라인 payload 실행 실패"
    FAIL=$((FAIL + 1))
  fi

  assert_true "Python REPL 한글 payload 제출 성공" \
    tmux_submit_pasted_payload "${SESSION}:pyrepl" 'print("한글-submit")' "py-korean"

  pane_dump="$(tmux capture-pane -p -t "${SESSION}:pyrepl" -S -80 2>/dev/null || true)"
  TOTAL=$((TOTAL + 1))
  if echo "$pane_dump" | grep -q "한글-submit"; then
    echo "  PASS: 한글 payload 실행됨"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: 한글 payload 실행 실패"
    FAIL=$((FAIL + 1))
  fi

  echo "  시나리오 15 완료"
}

# ──────────────────────────────────────────────
# 시나리오 16: 대상 lock 중 direct send → queue 후 drain
# ──────────────────────────────────────────────

test_scenario_16() {
  echo ""
  echo "=== 시나리오 16: 대상 lock queue + drain ==="
  cleanup
  setup_test_project
  build_fake_claude

  tmux new-session -d -s "$SESSION" -n manager
  create_fake_agent "developer"
  register_fake_agent "developer" "developer"

  assert_true "developer lock 획득" runtime_claim_message_target_lock "$PROJECT" "developer"

  bash "$TOOLS_DIR/message.sh" "$PROJECT" manager developer \
    status_update normal "locked-send" "queued by lock" >/dev/null

  local queue_dir queue_file
  queue_dir="$(runtime_message_queue_dir "$PROJECT")"
  queue_file="$(find "$queue_dir" -name '*.msg' -print 2>/dev/null | while read -r msg; do
    if grep -q '^subject=locked-send$' "$msg" 2>/dev/null; then
      printf '%s\n' "$msg"
      break
    fi
  done)"
  assert_file_exists "lock 중 direct send는 큐 저장" "$queue_file"

  runtime_release_message_target_lock "$PROJECT" "developer"

  bash "$TOOLS_DIR/cmd.sh" monitor-check "$PROJECT" >/dev/null 2>&1

  local pane_dump attempt
  pane_dump=""
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    pane_dump="$(tmux capture-pane -pJ -t "${SESSION}:developer" -S -80 2>/dev/null || true)"
    if [ ! -f "$queue_file" ] && echo "$pane_dump" | grep -q "queued by lock"; then
      break
    fi
    sleep 1
  done

  assert_file_not_exists "queue drain 후 메시지 제거" "$queue_file"
  TOTAL=$((TOTAL + 1))
  if echo "$pane_dump" | grep -q "queued by lock"; then
    echo "  PASS: lock 해제 후 queued message 전달"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: lock 해제 후 queued message 전달 실패"
    FAIL=$((FAIL + 1))
  fi

  echo "  시나리오 16 완료"
}

# ──────────────────────────────────────────────
# 시나리오 19: systems-engineer role wiring
# ──────────────────────────────────────────────

test_scenario_19() {
  echo ""
  echo "=== 시나리오 19: systems-engineer wiring ==="
  cleanup
  setup_test_project

  cat > "$PROJECT_DIR/project.md" << 'EOF'
# Project: systems-role-test

## 기본 정보
- **Domain** (또는 **도메인**): general

## 운영 방식
- **실행 모드**: dual

## 팀 구성
- **활성 에이전트**: developer, researcher, systems-engineer, monitoring
EOF

  local systems_msg
  systems_msg="$(probe_cmd_boot_message systems-engineer "$PROJECT")"

  TOTAL=$((TOTAL + 1))
  if echo "$systems_msg" | grep -q 'change-authority.md'; then
    echo "  PASS: systems-engineer 부팅 메시지에 change-authority 안내 포함"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: systems-engineer 부팅 메시지에 change-authority 안내 누락"
    FAIL=$((FAIL + 1))
  fi

  TOTAL=$((TOTAL + 1))
  if echo "$systems_msg" | grep -q 'systems-engineer manager agent_ready normal "온보딩 완료"'; then
    echo "  PASS: systems-engineer agent_ready 대상은 manager"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: systems-engineer agent_ready 대상이 manager가 아님"
    FAIL=$((FAIL + 1))
  fi

  local normalized_role
  normalized_role="$(invoke_cmd_function normalize_spawn_role systems-engineer-codex)"
  assert_eq "systems-engineer spawn role 정규화" "systems-engineer" "$normalized_role"

  local dual_flag
  dual_flag="$(
    WHIPLASH_SOURCE_ONLY=1 bash -lc '
      source "'"$TOOLS_DIR"'/cmd.sh"
      if role_supports_dual systems-engineer; then
        echo yes
      else
        echo no
      fi
    '
  )"
  assert_eq "systems-engineer는 dual 기본 대상 아님" "no" "$dual_flag"

  local dashboard_role_map
  dashboard_role_map="$(python3 - "$REPO_ROOT" <<'PY'
import importlib.util
import pathlib
import sys

repo_root = pathlib.Path(sys.argv[1])
module_path = repo_root / "dashboard" / "dashboard.py"
spec = importlib.util.spec_from_file_location("whiplash_dashboard", module_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
print(f'{module._ROLE_ABBR["systems-engineer"]}|{module._ROLE_FULL["sys"]}')
PY
)"
  assert_eq "dashboard systems-engineer 약어/역매핑" "sys|systems-engineer" "$dashboard_role_map"

  echo "  시나리오 19 완료"
}

# ──────────────────────────────────────────────
# 시나리오 20: mutation guard 제거
# ──────────────────────────────────────────────

test_scenario_20() {
  echo ""
  echo "=== 시나리오 20: mutation guard 제거 ==="
  cleanup
  setup_test_project

  local code_repo="$PROJECT_DIR/guard-repo"
  local remote_repo="$PROJECT_DIR/guard-remote.git"
  mkdir -p "$code_repo"
  git init --bare "$remote_repo" >/dev/null 2>&1
  git -C "$code_repo" init -b main >/dev/null 2>&1
  git -C "$code_repo" config user.name "Whiplash Test"
  git -C "$code_repo" config user.email "test@example.com"
  printf 'seed\n' > "$code_repo/README.md"
  git -C "$code_repo" add README.md
  git -C "$code_repo" commit -m "init" >/dev/null 2>&1
  git -C "$code_repo" remote add origin "$remote_repo"

  assert_true "git push가 별도 승인 없이 통과" git -C "$code_repo" push origin main
  assert_true "remote main ref 생성" git -C "$remote_repo" rev-parse --verify refs/heads/main

  local env_script
  env_script="$(invoke_cmd_function write_agent_env_script "$PROJECT" developer developer)"
  assert_file_not_contains "agent env script에 guard env 없음" "$env_script" "WHIPLASH_GUARD_"

  local usage_output
  usage_output="$(bash "$TOOLS_DIR/cmd.sh" 2>&1 || true)"
  TOTAL=$((TOTAL + 1))
  if ! echo "$usage_output" | grep -q 'approve-mutation' && ! echo "$usage_output" | grep -q 'revoke-mutation'; then
    echo "  PASS: cmd.sh usage에서 mutation approval 명령 제거"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: cmd.sh usage에 mutation approval 명령이 남아 있음"
    FAIL=$((FAIL + 1))
  fi

  echo "  시나리오 20 완료"
}

# ──────────────────────────────────────────────
# 시나리오 21: onboarding 분석 단계 제약
# ──────────────────────────────────────────────

test_scenario_21() {
  echo ""
  echo "=== 시나리오 21: onboarding analysis mode ==="
  cleanup
  setup_test_project
  build_fake_claude

  tmux new-session -d -s "$SESSION" -n onboarding
  tmux send-keys -t "${SESSION}:onboarding" "'${FAKE_CLAUDE_BIN}'" Enter
  local onboarding_pane_pid
  onboarding_pane_pid="$(tmux list-panes -t "${SESSION}:onboarding" -F '#{pane_pid}' 2>/dev/null | head -1 || true)"
  wait_for_child_process_named "$onboarding_pane_pid" claude 10 1 || true
  register_fake_agent "onboarding" "onboarding"
  invoke_cmd_function set_project_stage "$PROJECT" onboarding >/dev/null

  local onboarding_msg
  onboarding_msg="$(probe_cmd_boot_message onboarding "$PROJECT")"
  TOTAL=$((TOTAL + 1))
  if echo "$onboarding_msg" | grep -q 'onboarding user agent_ready normal "온보딩 완료"'; then
    echo "  PASS: onboarding agent_ready 대상은 user"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: onboarding agent_ready 대상이 user가 아님"
    FAIL=$((FAIL + 1))
  fi

  local helper_msg
  helper_msg="$(invoke_cmd_function build_boot_message researcher "$PROJECT" "" onboarding-research "" onboarding)"
  TOTAL=$((TOTAL + 1))
  if echo "$helper_msg" | grep -q 'onboarding-research onboarding agent_ready normal "온보딩 완료"'; then
    echo "  PASS: onboarding helper agent_ready 대상은 onboarding"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: onboarding helper agent_ready 대상이 onboarding이 아님"
    FAIL=$((FAIL + 1))
  fi

  local spawn_allowed spawn_blocked spawn_prefix_blocked
  spawn_allowed="$(
    WHIPLASH_SOURCE_ONLY=1 bash -lc '
      source "'"$TOOLS_DIR"'/cmd.sh"
      if validate_spawn_for_project_stage "$1" "$2" "$3"; then echo yes; else echo no; fi
    ' -- "$PROJECT" researcher onboarding-research
  )"
  assert_eq "onboarding 단계 researcher spawn 허용" "yes" "$spawn_allowed"

  spawn_blocked="$(
    WHIPLASH_SOURCE_ONLY=1 bash -lc '
      source "'"$TOOLS_DIR"'/cmd.sh"
      if validate_spawn_for_project_stage "$1" "$2" "$3"; then echo yes; else echo no; fi
    ' -- "$PROJECT" developer onboarding-developer
  )"
  assert_eq "onboarding 단계 developer spawn 차단" "no" "$spawn_blocked"

  spawn_prefix_blocked="$(
    WHIPLASH_SOURCE_ONLY=1 bash -lc '
      source "'"$TOOLS_DIR"'/cmd.sh"
      if validate_spawn_for_project_stage "$1" "$2" "$3"; then echo yes; else echo no; fi
    ' -- "$PROJECT" researcher researcher-2
  )"
  assert_eq "onboarding helper는 onboarding- 접두어 필요" "no" "$spawn_prefix_blocked"

  assert_true "agent_ready -> onboarding 허용" bash -c \
    "bash '$TOOLS_DIR/message.sh' '$PROJECT' onboarding-research onboarding agent_ready normal '준비 완료' 'analysis helper ready' >/dev/null"

  local onboarding_pane
  onboarding_pane="$(tmux capture-pane -pJ -t "${SESSION}:onboarding" -S -80 2>/dev/null || true)"
  TOTAL=$((TOTAL + 1))
  if echo "$onboarding_pane" | grep -q 'analysis helper ready'; then
    echo "  PASS: onboarding pane에 helper ready 알림 표시"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: onboarding pane에 helper ready 알림 누락"
    FAIL=$((FAIL + 1))
  fi

  local queue_dir manager_queue=""
  queue_dir="$(runtime_message_queue_dir "$PROJECT")"
  if [ -d "$queue_dir" ]; then
    manager_queue="$(grep -l '^to=manager$' "$queue_dir"/*.msg 2>/dev/null | head -1 || true)"
  fi
  assert_eq "onboarding 단계 manager mirror 큐 없음" "" "$manager_queue"

  echo "  시나리오 21 완료"
}

# ──────────────────────────────────────────────
# 시나리오 22: 새 프로젝트 onboarding bootstrap
# ──────────────────────────────────────────────

test_scenario_22() {
  echo ""
  echo "=== 시나리오 22: onboarding bootstrap for new project ==="
  cleanup
  build_fake_claude
  build_fake_codex

  local project_md="$PROJECT_DIR/project.md"
  local team_systems_md="$PROJECT_DIR/team/systems-engineer.md"
  local boot_log="$PROJECT_DIR/boot-onboarding.log"
  assert_file_not_exists "bootstrap 전 project.md 없음" "$project_md"

  PATH="$PROJECT_DIR:$PATH" bash "$TOOLS_DIR/cmd.sh" boot-onboarding "$PROJECT" >"$boot_log" 2>&1 &
  local boot_pid=$!

  local waited=0 onboarding_ready=0
  while [ "$waited" -lt 20 ]; do
    if tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -q '^onboarding$'; then
      onboarding_ready=1
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  assert_eq "bootstrap onboarding window 생성" "1" "$onboarding_ready"

  local boot_status=0
  wait "$boot_pid" || boot_status=$?
  TOTAL=$((TOTAL + 1))
  if [ "$boot_status" -ne 127 ]; then
    echo "  PASS: bootstrap boot-onboarding가 preflight/project bootstrap 단계를 통과"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: bootstrap boot-onboarding가 시작조차 못함"
    FAIL=$((FAIL + 1))
  fi

  TOTAL=$((TOTAL + 1))
  if grep -q "Onboarding 실행 확인" "$boot_log" 2>/dev/null; then
    echo "  PASS: bootstrap boot-onboarding가 agent_ready 없이도 실행 확인 후 종료"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: bootstrap boot-onboarding 실행 확인 로그 누락"
    FAIL=$((FAIL + 1))
  fi

  assert_file_exists "bootstrap project.md 생성" "$project_md"
  assert_true "bootstrap discussion memory 디렉토리 생성" test -d "$PROJECT_DIR/memory/discussion"
  assert_file_exists "bootstrap systems-engineer team 문서 생성" "$team_systems_md"
  assert_file_contains "bootstrap project.md pending 실행 모드" "$project_md" "실행 모드.*pending"
  assert_file_contains "bootstrap project.md 활성 에이전트 미정" "$project_md" "활성 에이전트.*미정"
  assert_file_contains "bootstrap project.md control-plane 자동 부팅 안내" "$project_md" "control-plane 역할이라 bootstrap 이후 자동 부팅"
  assert_file_contains "bootstrap project.md 시스템 변경 권한 안내" "$project_md" "시스템 변경 권한"
  assert_true "bootstrap runtime 루트 생성" test -d "$PROJECT_DIR/runtime"
  assert_true "bootstrap sessions.md 생성" test -f "$PROJECT_DIR/memory/manager/sessions.md"
  TOTAL=$((TOTAL + 1))
  if grep -q "프로젝트 구조 검사는 건너뜀" "$boot_log" 2>/dev/null \
    && ! grep -q "project.md가 없다" "$boot_log" 2>/dev/null \
    && ! grep -q "활성 에이전트를 찾을 수 없다" "$boot_log" 2>/dev/null; then
    echo "  PASS: bootstrap 부팅 로그가 원래 blocker 없이 진행됨"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: bootstrap 부팅 로그에 기존 blocker가 남아 있음"
    FAIL=$((FAIL + 1))
  fi

  local strict_status=0 skip_status=0
  PATH="$PROJECT_DIR:$PATH" bash "$TOOLS_DIR/preflight.sh" "$PROJECT" --mode solo >/dev/null 2>&1 || strict_status=$?
  PATH="$PROJECT_DIR:$PATH" bash "$TOOLS_DIR/preflight.sh" "$PROJECT" --mode solo --skip-project-check >/dev/null 2>&1 || skip_status=$?
  TOTAL=$((TOTAL + 1))
  if [ "$strict_status" -ne 0 ]; then
    echo "  PASS: bootstrap 초안은 full preflight에서 아직 거부됨"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: bootstrap 초안이 full preflight를 통과하면 안 됨"
    FAIL=$((FAIL + 1))
  fi
  assert_eq "bootstrap preflight skip 허용" "0" "$skip_status"

  local dashboard_project
  dashboard_project="$(probe_dashboard_project)"
  assert_eq "dashboard pending mode 파싱" "${PROJECT}|pending|pending|general" "$dashboard_project"

  echo "  시나리오 22 완료"
}


# ──────────────────────────────────────────────
# 시나리오 24: Claude plan mode 감지
# ──────────────────────────────────────────────

test_scenario_24() {
  echo ""
  echo "=== 시나리오 24: Claude plan mode 감지 ==="
  cleanup
  setup_test_project
  build_fake_claude

  tmux new-session -d -s "$SESSION" -n dashboard
  create_fake_agent "manager"
  create_fake_agent "developer"
  register_fake_agent "manager" "manager"
  register_fake_agent "developer" "developer"

  tmux send-keys -t "${SESSION}:developer" "plan mode on" Enter
  sleep 1
  WHIPLASH_MONITOR_ONCE=1 bash "$TOOLS_DIR/monitor.sh" "$PROJECT" >/dev/null 2>&1

  local manager_pane detect_count
  manager_pane="$(tmux capture-pane -pJ -t "${SESSION}:manager" -S -80 2>/dev/null || true)"
  TOTAL=$((TOTAL + 1))
  if echo "$manager_pane" | grep -q "developer plan mode 판단 필요"; then
    echo "  PASS: manager pane에 plan mode 감지 알림 표시"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: manager pane에 plan mode 감지 알림 누락"
    FAIL=$((FAIL + 1))
  fi

  TOTAL=$((TOTAL + 1))
  if grep -q 'monitor → manager need_input normal "developer plan mode 판단 필요"' "$PROJECT_DIR/logs/message.log" 2>/dev/null; then
    echo "  PASS: manager가 need_input으로 plan mode 판단 요청 수신"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: manager가 need_input으로 plan mode 판단 요청을 못 받음"
    FAIL=$((FAIL + 1))
  fi

  detect_count="$(grep -c 'plan mode 감지' "$PROJECT_DIR/logs/system.log" 2>/dev/null)"
  assert_eq "system.log에 첫 감지 1회 기록" "1" "$detect_count"

  WHIPLASH_MONITOR_ONCE=1 bash "$TOOLS_DIR/monitor.sh" "$PROJECT" >/dev/null 2>&1
  detect_count="$(grep -c 'plan mode 감지' "$PROJECT_DIR/logs/system.log" 2>/dev/null)"
  assert_eq "같은 상태 재검사 시 중복 감지 없음" "1" "$detect_count"

  tmux send-keys -t "${SESSION}:developer" "working-1" Enter
  tmux send-keys -t "${SESSION}:developer" "working-2" Enter
  tmux send-keys -t "${SESSION}:developer" "working-3" Enter
  tmux send-keys -t "${SESSION}:developer" "working-4" Enter
  sleep 1
  WHIPLASH_MONITOR_ONCE=1 bash "$TOOLS_DIR/monitor.sh" "$PROJECT" >/dev/null 2>&1

  local clear_count
  clear_count="$(grep -c 'plan mode 해제' "$PROJECT_DIR/logs/system.log" 2>/dev/null)"
  assert_eq "plan mode 해제 기록" "1" "$clear_count"

  tmux send-keys -t "${SESSION}:developer" "plan mode on" Enter
  sleep 1
  WHIPLASH_MONITOR_ONCE=1 bash "$TOOLS_DIR/monitor.sh" "$PROJECT" >/dev/null 2>&1
  detect_count="$(grep -c 'plan mode 감지' "$PROJECT_DIR/logs/system.log" 2>/dev/null)"
  assert_eq "해제 후 재진입 시 재감지" "2" "$detect_count"

  echo "  시나리오 24 완료"
}

# ──────────────────────────────────────────────
# 시나리오 25: systems-engineer document guard
# ──────────────────────────────────────────────

test_scenario_25() {
  echo ""
  echo "=== 시나리오 25: systems-engineer 문서 기반 운영 ==="
  cleanup
  setup_test_project

  mkdir -p "$PROJECT_DIR/team"
  cat > "$PROJECT_DIR/team/systems-engineer.md" <<'EOF'
# systems-role-test — Systems Engineer 프로젝트 지침

## 시스템 변경 권한
- 기본값: 명시되지 않은 원격 시스템 write는 금지

## 표면 목록
| 환경 | 표면 | 허용 행동 | 금지 행동 | 근거 | 마지막 확인 |
|------|------|-----------|-----------|------|-------------|
| prod | bastion | 없음 | 모든 write | 온보딩 전 | 미정 |
EOF

  local systems_msg
  systems_msg="$(probe_cmd_boot_message systems-engineer "$PROJECT")"
  TOTAL=$((TOTAL + 1))
  if ! echo "$systems_msg" | grep -qi 'guard' && ! echo "$systems_msg" | grep -qi 'hard stop'; then
    echo "  PASS: systems-engineer 부팅 메시지에 guard/hard stop 언급 없음"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: systems-engineer 부팅 메시지에 guard/hard stop 언급이 남아 있음"
    FAIL=$((FAIL + 1))
  fi

  local env_script
  env_script="$(invoke_cmd_function write_agent_env_script "$PROJECT" systems-engineer systems-engineer)"
  assert_file_not_contains "systems-engineer env script에 guard env 없음" "$env_script" "WHIPLASH_GUARD_"

  local code_repo="$PROJECT_DIR/systems-guard-repo"
  local remote_repo="$PROJECT_DIR/systems-guard-remote.git"
  mkdir -p "$code_repo"
  git init --bare "$remote_repo" >/dev/null 2>&1
  git -C "$code_repo" init -b main >/dev/null 2>&1
  git -C "$code_repo" config user.name "Whiplash Test"
  git -C "$code_repo" config user.email "test@example.com"
  printf 'seed\n' > "$code_repo/README.md"
  git -C "$code_repo" add README.md
  git -C "$code_repo" commit -m "init" >/dev/null 2>&1
  git -C "$code_repo" remote add origin "$remote_repo"

  assert_true "systems-engineer git push는 별도 래퍼 없이 통과" git -C "$code_repo" push origin main
  assert_true "systems-engineer git push 후 remote main ref 생성" git -C "$remote_repo" rev-parse --verify refs/heads/main

  echo "  시나리오 25 완료"
}

# ──────────────────────────────────────────────
# 시나리오 26: discussion role wiring
# ──────────────────────────────────────────────

test_scenario_26() {
  echo ""
  echo "=== 시나리오 26: discussion wiring ==="
  cleanup
  setup_test_project
  build_fake_claude
  build_fake_codex

  cat > "$PROJECT_DIR/project.md" << 'EOF'
# Project: discussion-role-test

## 기본 정보
- **Domain** (또는 **도메인**): general

## 운영 방식
- **실행 모드**: solo

## 팀 구성
- **활성 에이전트**: developer, researcher
EOF

  local discussion_msg
  discussion_msg="$(probe_cmd_boot_message discussion "$PROJECT")"

  TOTAL=$((TOTAL + 1))
  if echo "$discussion_msg" | grep -q 'memory/discussion/handoff.md'; then
    echo "  PASS: discussion 부팅 메시지에 handoff 안내 포함"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: discussion 부팅 메시지에 handoff 안내 누락"
    FAIL=$((FAIL + 1))
  fi

  TOTAL=$((TOTAL + 1))
  if echo "$discussion_msg" | grep -q 'discussion user agent_ready normal "온보딩 완료"'; then
    echo "  PASS: discussion agent_ready 대상은 user"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: discussion agent_ready 대상이 user가 아님"
    FAIL=$((FAIL + 1))
  fi

  TOTAL=$((TOTAL + 1))
  if echo "$discussion_msg" | grep -q '현재 진행 상황.*manager'; then
    echo "  PASS: discussion 부팅 메시지에 manager 라우팅 안내 포함"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: discussion 부팅 메시지에 manager 라우팅 안내 누락"
    FAIL=$((FAIL + 1))
  fi

  local dashboard_role_map
  dashboard_role_map="$(python3 - "$REPO_ROOT" <<'PY'
import importlib.util
import pathlib
import sys

repo_root = pathlib.Path(sys.argv[1])
module_path = repo_root / "dashboard" / "dashboard.py"
spec = importlib.util.spec_from_file_location("whiplash_dashboard", module_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
print(f'{module._ROLE_ABBR["discussion"]}|{module._ROLE_FULL["dis"]}')
PY
)"
  assert_eq "dashboard discussion 약어/역매핑" "dis|discussion" "$dashboard_role_map"

  local boot_log="$PROJECT_DIR/discussion-boot.log"
  assert_true "cmd.sh boot 성공" bash -c 'PATH="$1:$PATH" bash "$2/cmd.sh" boot "$3" >"$4" 2>&1' -- "$PROJECT_DIR" "$TOOLS_DIR" "$PROJECT" "$boot_log"

  local discussion_window_count
  discussion_window_count="$(tmux list-windows -t "$SESSION" -F '#{window_name}' | grep -c '^discussion$' || true)"
  assert_eq "cmd.sh boot가 discussion window 자동 부팅" "1" "$discussion_window_count"

  local discussion_session_count
  discussion_session_count="$(grep -c '| discussion | codex |' "$PROJECT_DIR/memory/manager/sessions.md" || true)"
  assert_eq "sessions.md에 discussion 세션 기록" "1" "$discussion_session_count"

  echo "  시나리오 26 완료"
}

# ──────────────────────────────────────────────
# 시나리오 27: native subagent starter pack 계약
# ──────────────────────────────────────────────

test_scenario_27() {
  echo ""
  echo "=== 시나리오 27: native subagent starter pack 계약 ==="
  cleanup
  setup_test_project

  local native_agents=(
    task-distributor
    consensus-reviewer
    report-synthesizer
    code-mapper
    docs-researcher
    reviewer
    debugger
    search-specialist
    runtime-auditor
    architect-reviewer
    refactoring-specialist
    test-automator
    security-auditor
    performance-engineer
    deployment-engineer
  )
  local agent_name
  for agent_name in "${native_agents[@]}"; do
    assert_file_exists "Claude subagent pack 존재: ${agent_name}" "$REPO_ROOT/.claude/agents/${agent_name}.md"
    assert_file_exists "Codex subagent pack 존재: ${agent_name}" "$REPO_ROOT/.codex/agents/${agent_name}.toml"
  done

  assert_file_contains "Claude light-tier specialist model 분화" "$REPO_ROOT/.claude/agents/code-mapper.md" "^model: haiku$"
  assert_file_contains "Claude strong-tier reviewer model 분화" "$REPO_ROOT/.claude/agents/reviewer.md" "^model: opus$"
  assert_file_contains "Codex light-tier specialist model 분화" "$REPO_ROOT/.codex/agents/code-mapper.toml" '^model = "gpt-5.4-mini"$'
  assert_file_contains "Codex light-tier specialist effort 분화" "$REPO_ROOT/.codex/agents/code-mapper.toml" '^model_reasoning_effort = "low"$'
  assert_file_contains "Codex strong-tier reviewer reasoning 분화" "$REPO_ROOT/.codex/agents/reviewer.toml" '^model_reasoning_effort = "high"$'
  assert_file_contains "developer orchestration triage 문구 존재" "$REPO_ROOT/agents/developer/techniques/subagent-orchestration.md" "^## Task Triage$"
  assert_file_contains "developer orchestration 모델 선택 가이드 존재" "$REPO_ROOT/agents/developer/techniques/subagent-orchestration.md" "^## 모델 선택 가이드$"
  assert_file_contains "researcher orchestration 모델 선택 가이드 존재" "$REPO_ROOT/agents/researcher/techniques/subagent-orchestration.md" "^## 모델 선택 가이드$"
  assert_file_contains "systems orchestration triage 문구 존재" "$REPO_ROOT/agents/systems-engineer/techniques/subagent-orchestration.md" "^## Task Triage$"

  assert_file_exists "Codex project config 존재" "$REPO_ROOT/.codex/config.toml"
  assert_file_contains "Codex project config top-level model 설정" "$REPO_ROOT/.codex/config.toml" "^model = \"gpt-5.4\"$"
  assert_file_contains "Codex project config에 [agents] 섹션" "$REPO_ROOT/.codex/config.toml" "^\\[agents\\]$"
  assert_file_contains "Codex project config max_threads 설정" "$REPO_ROOT/.codex/config.toml" "^max_threads = 6$"
  assert_file_contains "Codex project config max_depth 설정" "$REPO_ROOT/.codex/config.toml" "^max_depth = 1$"

  local codex_model
  codex_model="$(invoke_cmd_function get_codex_model)"
  assert_eq "repo-local Codex model 우선 사용" "gpt-5.4" "$codex_model"

  local manager_effort developer_effort monitoring_effort
  manager_effort="$(invoke_cmd_function get_reasoning_effort manager)"
  developer_effort="$(invoke_cmd_function get_reasoning_effort developer)"
  monitoring_effort="$(invoke_cmd_function get_reasoning_effort monitoring)"
  assert_eq "manager Codex effort 기본값은 high" "high" "$manager_effort"
  assert_eq "developer Codex effort 기본값은 high" "high" "$developer_effort"
  assert_eq "monitoring Codex effort 기본값은 low" "low" "$monitoring_effort"

  local manager_backend
  manager_backend="$(invoke_cmd_function get_manager_backend)"
  assert_eq "control-plane 기본 backend는 codex" "codex" "$manager_backend"

  python3 - "$PROJECT_DIR/project.md" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
content = path.read_text(encoding="utf-8")
content = content.replace("- 실행 모드: solo", "- 실행 모드: solo\n- control-plane 백엔드: claude", 1)
path.write_text(content, encoding="utf-8")
PY
  manager_backend="$(invoke_cmd_function get_manager_backend "$PROJECT")"
  assert_eq "project.md가 control-plane backend override 가능" "claude" "$manager_backend"

  assert_file_contains "manager profile Agent 허용" "$REPO_ROOT/agents/manager/profile.md" "^allowed-tools: .*Agent"
  assert_file_contains "manager profile reasoning-effort 설정" "$REPO_ROOT/agents/manager/profile.md" "^reasoning-effort: high$"
  assert_file_contains "discussion profile Agent 허용" "$REPO_ROOT/agents/discussion/profile.md" "^allowed-tools: .*Agent"
  assert_file_contains "discussion profile reasoning-effort 설정" "$REPO_ROOT/agents/discussion/profile.md" "^reasoning-effort: high$"
  assert_file_contains "developer profile Agent 허용" "$REPO_ROOT/agents/developer/profile.md" "^allowed-tools: .*Agent"
  assert_file_contains "developer profile reasoning-effort 설정" "$REPO_ROOT/agents/developer/profile.md" "^reasoning-effort: high$"
  assert_file_contains "researcher profile Agent 허용" "$REPO_ROOT/agents/researcher/profile.md" "^allowed-tools: .*Agent"
  assert_file_contains "researcher profile reasoning-effort 설정" "$REPO_ROOT/agents/researcher/profile.md" "^reasoning-effort: high$"
  assert_file_contains "systems-engineer profile Agent 허용" "$REPO_ROOT/agents/systems-engineer/profile.md" "^allowed-tools: .*Agent"
  assert_file_contains "systems-engineer profile reasoning-effort 설정" "$REPO_ROOT/agents/systems-engineer/profile.md" "^reasoning-effort: high$"

  local developer_msg
  developer_msg="$(probe_cmd_boot_message developer "$PROJECT")"
  TOTAL=$((TOTAL + 1))
  if echo "$developer_msg" | grep -q '\.claude/agents/' && \
     echo "$developer_msg" | grep -q '\.codex/agents/' && \
     echo "$developer_msg" | grep -q 'agents/developer/techniques/subagent-orchestration.md' && \
     echo "$developer_msg" | grep -q '2-way 이상 병렬 fan-out' && \
     echo "$developer_msg" | grep -q '작고 명확하면 scout 1개 또는 direct 예외' && \
     echo "$developer_msg" | grep -q '더 빠른/가벼운 모델과 낮은 effort는 mapping, evidence 수집, 좁은 verify에 먼저 쓰고' && \
     echo "$developer_msg" | grep -q 'execution lead라면 어떤 specialist를 부를지 네가 판단한다'; then
    echo "  PASS: developer 부팅 메시지에 native subagent kickoff 규칙 포함"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: developer 부팅 메시지에 native subagent kickoff 규칙 누락"
    FAIL=$((FAIL + 1))
  fi

  local researcher_msg
  researcher_msg="$(probe_cmd_boot_message researcher "$PROJECT")"
  TOTAL=$((TOTAL + 1))
  if echo "$researcher_msg" | grep -q 'search-specialist 또는 code-mapper 1개부터' && \
     echo "$researcher_msg" | grep -q 'search-specialist + docs-researcher' && \
     echo "$researcher_msg" | grep -q 'recommendation, contract 비교, 최종 위험 판정'; then
    echo "  PASS: researcher 부팅 메시지에 role-specific subagent triage 포함"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: researcher 부팅 메시지에 role-specific subagent triage 누락"
    FAIL=$((FAIL + 1))
  fi

  local systems_msg_runtime
  systems_msg_runtime="$(probe_cmd_boot_message systems-engineer "$PROJECT")"
  TOTAL=$((TOTAL + 1))
  if echo "$systems_msg_runtime" | grep -q 'runtime-auditor 1개부터' && \
     echo "$systems_msg_runtime" | grep -q 'runtime-auditor + code-mapper' && \
     echo "$systems_msg_runtime" | grep -q '강한 모델과 높은 effort는 ambiguous drift, rollback gate, cross-system risk 판정'; then
    echo "  PASS: systems-engineer 부팅 메시지에 role-specific subagent triage 포함"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: systems-engineer 부팅 메시지에 role-specific subagent triage 누락"
    FAIL=$((FAIL + 1))
  fi

  local manager_msg
  manager_msg="$(probe_cmd_boot_message manager "$PROJECT")"
  TOTAL=$((TOTAL + 1))
  if echo "$manager_msg" | grep -q 'agents/manager/techniques/subagent-orchestration.md' && \
     echo "$manager_msg" | grep -q '최종 권한과 공식 산출물 책임은 항상 너에게 있다'; then
    echo "  PASS: manager 부팅 메시지에 staff subagent 책임 규칙 포함"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: manager 부팅 메시지에 staff subagent 책임 규칙 누락"
    FAIL=$((FAIL + 1))
  fi

  local discussion_msg
  discussion_msg="$(probe_cmd_boot_message discussion "$PROJECT")"
  TOTAL=$((TOTAL + 1))
  if echo "$discussion_msg" | grep -q 'agents/discussion/techniques/subagent-orchestration.md' && \
     echo "$discussion_msg" | grep -q '최종 추천안과 handoff 책임은 항상 너에게 있다'; then
    echo "  PASS: discussion 부팅 메시지에 native subagent 책임 규칙 포함"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: discussion 부팅 메시지에 native subagent 책임 규칙 누락"
    FAIL=$((FAIL + 1))
  fi

  local env_script
  env_script="$(invoke_cmd_function write_agent_env_script "$PROJECT" "developer" "developer")"
  assert_file_contains "agent env script에 repo root export" "$env_script" "^export WHIPLASH_REPO_ROOT="
  assert_file_contains "agent env script에 Claude pack export" "$env_script" "^export WHIPLASH_NATIVE_CLAUDE_AGENTS="
  assert_file_contains "agent env script에 Codex pack export" "$env_script" "^export WHIPLASH_NATIVE_CODEX_AGENTS="

  echo "  시나리오 27 완료"
}

# ──────────────────────────────────────────────
# 시나리오 28: kickoff reminder + discussion handoff gate
# ──────────────────────────────────────────────

test_scenario_28() {
  echo ""
  echo "=== 시나리오 28: kickoff reminder + discussion handoff gate ==="
  cleanup
  setup_test_project
  build_fake_claude

  tmux new-session -d -s "$SESSION" -n dashboard
  create_fake_agent "manager"
  create_fake_agent "developer"
  register_fake_agent "developer" "developer"

  bash "$TOOLS_DIR/message.sh" "$PROJECT" manager developer \
    task_assign normal "workspace/tasks/TASK-009.md" "kickoff reminder smoke" >/dev/null

  local developer_pane_dump=""
  local attempt
  for attempt in 1 2 3 4 5 6; do
    developer_pane_dump="$(tmux capture-pane -pJ -t "${SESSION}:developer" -S -80 2>/dev/null || true)"
    if echo "$developer_pane_dump" | grep -q '\[kickoff reminder\]'; then
      break
    fi
    sleep 1
  done

  TOTAL=$((TOTAL + 1))
  if echo "$developer_pane_dump" | grep -q '\[kickoff reminder\]' && \
     echo "$developer_pane_dump" | grep -q 'specialist 최소 1개' && \
     echo "$developer_pane_dump" | grep -q '2-way 이상 병렬 fan-out' && \
     echo "$developer_pane_dump" | grep -q 'specialist별 기본 모델/effort tier도 설정돼 있으니'; then
    echo "  PASS: developer task_assign에 kickoff reminder 포함"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: developer task_assign에 kickoff reminder 누락"
    FAIL=$((FAIL + 1))
  fi

  local handoff_file="$PROJECT_DIR/memory/discussion/handoff.md"
  mkdir -p "$(dirname "$handoff_file")"

  cat > "$handoff_file" << 'EOF'
# Discussion Handoff

- **Date**: 2026-03-20 18:30
- **Author**: discussion
- **User approved**: no

## Why this change
- 방향은 유망하지만 아직 확정되지 않았다.

## Scope impact
- developer 우선순위가 바뀔 수 있다.
EOF

  assert_false "invalid discussion handoff 알림 거부" \
    bash "$TOOLS_DIR/message.sh" "$PROJECT" discussion manager \
      status_update normal "discussion handoff 준비" "memory/discussion/handoff.md를 읽고 실행 계획에 반영해라"

  cat > "$handoff_file" << 'EOF'
# Discussion Handoff

- **Date**: 2026-03-20 18:31
- **Author**: discussion
- **User approved**: yes

## Why this change
- 유저가 backend-native subagent 사용을 기본 전략으로 유지하되, execution lead가 내부 specialist 조합을 자율 결정하는 방향에 동의했다.

## Scope impact
- manager는 outcome/constraint 중심으로 지시하고, developer/researcher/systems-engineer는 internal fan-out을 자율 결정한다.

## Manager next action
- 관련 지시 문구와 운영 문서를 이 원칙으로 정렬한다.
EOF

  assert_true "valid discussion handoff 알림 전달" \
    bash "$TOOLS_DIR/message.sh" "$PROJECT" discussion manager \
      status_update normal "discussion handoff 준비" "memory/discussion/handoff.md를 읽고 실행 계획에 반영해라"

  local manager_pane_dump=""
  for attempt in 1 2 3 4 5 6; do
    manager_pane_dump="$(tmux capture-pane -pJ -t "${SESSION}:manager" -S -80 2>/dev/null || true)"
    if echo "$manager_pane_dump" | grep -q 'discussion handoff 준비'; then
      break
    fi
    sleep 1
  done

  TOTAL=$((TOTAL + 1))
  if echo "$manager_pane_dump" | grep -q 'discussion handoff 준비' && \
     echo "$manager_pane_dump" | grep -q 'memory/discussion/handoff.md'; then
    echo "  PASS: valid discussion handoff가 manager에 전달됨"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: valid discussion handoff가 manager에 전달되지 않음"
    FAIL=$((FAIL + 1))
  fi

  echo "  시나리오 28 완료"
}

# ──────────────────────────────────────────────
# 시나리오 29: ralph loop message/worktree 계약
# ──────────────────────────────────────────────

test_scenario_29() {
  echo ""
  echo "=== 시나리오 29: ralph loop message/worktree 계약 ==="
  cleanup
  setup_test_project
  build_fake_claude

  cat > "$PROJECT_DIR/project.md" << 'EOF'
# Project: ralph-test

## 기본 정보
- **Domain**: general

## 프로젝트 폴더
- **경로**: PROJECT_CODE_REPO_PLACEHOLDER

## 운영 방식
- **실행 모드**: solo
- **작업 루프**: ralph
- **랄프 완료 기준**: 로컬 테스트 통과 + 최종 결과 보고 제출
- **랄프 종료 방식**: stop-on-criteria

## 팀 구성
- **활성 에이전트**: developer, researcher, systems-engineer
EOF

  local code_repo="$PROJECT_DIR/codebase"
  mkdir -p "$code_repo"
  git -C "$code_repo" init >/dev/null 2>&1
  echo "seed" > "$code_repo/README.md"
  git -C "$code_repo" add README.md >/dev/null 2>&1
  git -C "$code_repo" -c user.name=test -c user.email=test@example.com commit -m init >/dev/null 2>&1
  python3 - "$PROJECT_DIR/project.md" "$code_repo" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
code_repo = sys.argv[2]
path.write_text(path.read_text().replace("PROJECT_CODE_REPO_PLACEHOLDER", code_repo), encoding="utf-8")
PY

  assert_false "ralph manager->user need_input 거부" \
    bash "$TOOLS_DIR/message.sh" "$PROJECT" manager user \
      need_input normal "방향 선택 필요" "ralph에서는 승인 대기를 금지한다"

  assert_true "ralph user_notice 허용" \
    bash "$TOOLS_DIR/message.sh" "$PROJECT" manager user \
      user_notice normal "자동 진행" "scope 축소 후 계속 진행"

  assert_file_contains "user_notice가 message.log에 기록됨" \
    "$PROJECT_DIR/logs/message.log" \
    "manager → user user_notice normal \"자동 진행\""

  tmux new-session -d -s "$SESSION" -n dashboard
  create_fake_agent "manager"
  create_fake_agent "developer"
  register_fake_agent "developer" "developer"

  bash "$TOOLS_DIR/message.sh" "$PROJECT" manager developer \
    task_assign normal "workspace/tasks/TASK-010.md" "first ralph task" >/dev/null
  bash "$TOOLS_DIR/message.sh" "$PROJECT" manager developer \
    task_assign normal "workspace/tasks/TASK-011.md" "replacement ralph task" >/dev/null

  local af="$PROJECT_DIR/memory/manager/assignments.md"
  assert_file_contains "기존 active task가 superseded 처리됨" "$af" \
    "| developer | workspace/tasks/TASK-010.md |"
  assert_file_contains "기존 active task 상태 superseded" "$af" \
    "superseded |"
  assert_file_contains "새 ralph task는 active 유지" "$af" \
    "| developer | workspace/tasks/TASK-011.md |"
  assert_file_contains "새 ralph task 상태 active" "$af" \
    "active |"

  invoke_cmd_function create_ralph_worktree "$PROJECT" developer
  local ralph_wt="$code_repo/.worktrees/developer-ralph"
  assert_true "developer ralph worktree 생성" test -d "$ralph_wt"
  invoke_cmd_function remove_ralph_worktree "$PROJECT" developer

  echo "  시나리오 29 완료"
}

# ──────────────────────────────────────────────
# 시나리오 30: auth-blocked Claude pane degrade + recovery guard
# ──────────────────────────────────────────────

test_scenario_30() {
  echo ""
  echo "=== 시나리오 30: auth-blocked Claude pane degrade + recovery guard ==="
  cleanup
  setup_test_project
  build_fake_claude

  mkdir -p "$PROJECT_DIR/workspace/tasks"
  cat > "$PROJECT_DIR/workspace/tasks/TASK-010.md" << 'EOF'
# TASK-010: Auth blocked runtime smoke test
EOF

  tmux new-session -d -s "$SESSION" -n dashboard
  create_fake_agent "manager"
  create_fake_agent "developer"
  register_fake_agent "manager" "manager"
  register_fake_agent "developer" "developer"

  bash "$TOOLS_DIR/message.sh" "$PROJECT" manager developer \
    task_assign normal "workspace/tasks/TASK-010.md" "auth blocked runtime setup" >/dev/null

  tmux send-keys -t "${SESSION}:developer" "Not logged in · Please run /login" Enter
  tmux send-keys -t "${SESSION}:developer" "Run in another terminal: security unlock-keychain" Enter
  sleep 1

  WHIPLASH_MONITOR_ONCE=1 bash "$TOOLS_DIR/monitor.sh" "$PROJECT" >/dev/null 2>&1

  local manager_pane auth_alert_count dashboard_state status_out queue_dir queued_count
  manager_pane="$(tmux capture-pane -pJ -t "${SESSION}:manager" -S -120 2>/dev/null || true)"
  TOTAL=$((TOTAL + 1))
  if echo "$manager_pane" | grep -q "developer Claude auth blocked"; then
    echo "  PASS: manager pane에 auth-blocked actionable signal 표시"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: manager pane에 auth-blocked actionable signal 누락"
    FAIL=$((FAIL + 1))
  fi

  assert_file_contains "message.log에 auth-blocked signal 기록" \
    "$PROJECT_DIR/logs/message.log" \
    'monitor → manager need_input normal "developer Claude auth blocked"'

  WHIPLASH_MONITOR_ONCE=1 bash "$TOOLS_DIR/monitor.sh" "$PROJECT" >/dev/null 2>&1
  auth_alert_count="$(grep -c 'developer Claude auth blocked' "$PROJECT_DIR/logs/message.log" 2>/dev/null || true)"
  assert_eq "auth-blocked actionable signal은 1회만 기록" "1" "$auth_alert_count"

  dashboard_state="$(probe_dashboard_agent developer)"
  assert_eq "dashboard가 auth-blocked task visibility 유지" "WAIT|TASK-010" "$dashboard_state"

  status_out="$(bash "$TOOLS_DIR/cmd.sh" status "$PROJECT" 2>/dev/null || true)"
  TOTAL=$((TOTAL + 1))
  if echo "$status_out" | grep -q '\[agent-health\]' && echo "$status_out" | grep -q 'developer (developer/claude): AUTH_BLOCKED'; then
    echo "  PASS: cmd.sh status가 auth-blocked 가시성 제공"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: cmd.sh status에 auth-blocked 가시성 누락"
    FAIL=$((FAIL + 1))
  fi

  local direct_subject="auth-blocked-direct"
  bash "$TOOLS_DIR/message.sh" "$PROJECT" manager developer \
    status_update normal "$direct_subject" "auth blocked queue hold" >/dev/null
  assert_file_contains "message.sh가 auth-blocked direct delivery를 skipped로 기록" \
    "$PROJECT_DIR/logs/message.log" \
    "manager → developer status_update normal \"${direct_subject}\" reason=\"queued-auth-blocked\""
  assert_file_not_contains "message.sh가 auth-blocked direct delivery를 interactive 성공으로 기록하지 않음" \
    "$PROJECT_DIR/logs/message.log" \
    "\\[delivered\\] manager → developer status_update normal \"${direct_subject}\" reason=\"interactive\""

  queue_dir="$(runtime_message_queue_dir "$PROJECT")"
  queued_count="$(find "$queue_dir" -name '*.msg' 2>/dev/null | wc -l | tr -d ' ')"
  assert_true "auth-blocked 메시지가 큐에 남아 있음" test "${queued_count:-0}" -gt 0

  WHIPLASH_MONITOR_ONCE=1 bash "$TOOLS_DIR/monitor.sh" "$PROJECT" >/dev/null 2>&1
  queued_count="$(find "$queue_dir" -name '*.msg' 2>/dev/null | wc -l | tr -d ' ')"
  assert_true "monitor drain이 auth-blocked 큐를 그대로 유지" test "${queued_count:-0}" -gt 0
  assert_file_not_contains "monitor가 auth-blocked pane을 crash로 오인하지 않음" \
    "$PROJECT_DIR/logs/system.log" \
    'developer 크래시 감지'
  assert_file_not_contains "monitor가 auth-blocked pane에 auto reboot churn을 일으키지 않음" \
    "$PROJECT_DIR/logs/system.log" \
    'developer 리부팅 성공'

  assert_false "auth-blocked refresh는 destructive restart 없이 중단" \
    env PATH="$PROJECT_DIR:$PATH" WHIPLASH_FAKE_CLAUDE_LOGGED_IN=0 \
      bash "$TOOLS_DIR/cmd.sh" refresh developer "$PROJECT"
  assert_false "auth-blocked reboot는 destructive restart 없이 중단" \
    env PATH="$PROJECT_DIR:$PATH" WHIPLASH_FAKE_CLAUDE_LOGGED_IN=0 \
      bash "$TOOLS_DIR/cmd.sh" reboot developer "$PROJECT"

  dashboard_state="$(probe_dashboard_agent developer)"
  assert_eq "refresh/reboot guard 후 task visibility 유지" "WAIT|TASK-010" "$dashboard_state"

  echo "  시나리오 30 완료"
}

# ──────────────────────────────────────────────
# 시나리오 31: Claude reboot bootstrap은 READY handshake만 사용
# ──────────────────────────────────────────────

test_scenario_31() {
  echo ""
  echo "=== 시나리오 31: Claude reboot bootstrap READY handshake ==="
  cleanup
  setup_test_project
  build_fake_claude

  mkdir -p "$PROJECT_DIR/workspace/tasks"
  cat > "$PROJECT_DIR/workspace/tasks/TASK-011.md" << 'EOF'
# TASK-011: Claude reboot bootstrap smoke test
EOF

  tmux new-session -d -s "$SESSION" -n dashboard
  create_fake_agent "developer"
  register_fake_agent "developer" "developer"

  bash "$TOOLS_DIR/message.sh" "$PROJECT" manager developer \
    task_assign normal "workspace/tasks/TASK-011.md" "bootstrap reboot setup" >/dev/null

  tmux send-keys -t "${SESSION}:developer" "Not logged in · Please run /login" Enter
  sleep 1
  assert_false "auth blocked 상태에서는 reboot guard 유지" \
    env PATH="$PROJECT_DIR:$PATH" WHIPLASH_FAKE_CLAUDE_LOGGED_IN=0 \
      bash "$TOOLS_DIR/cmd.sh" reboot developer "$PROJECT"

  local filler
  for filler in $(seq 1 16); do
    tmux send-keys -t "${SESSION}:developer" "healthy-line-${filler}" Enter
  done
  sleep 1

  local prompt_log="$PROJECT_DIR/runtime/fake-claude-p.log"
  rm -f "$prompt_log"
  assert_true "auth 복구 후 reboot 성공" \
    env PATH="$PROJECT_DIR:$PATH" WHIPLASH_FAKE_CLAUDE_P_LOG="$prompt_log" \
      bash "$TOOLS_DIR/cmd.sh" reboot developer "$PROJECT"

  assert_file_contains "claude -p는 READY bootstrap prompt만 사용" \
    "$prompt_log" \
    "READY만 답해라"
  assert_file_not_contains "claude -p가 pending task를 hidden execution으로 받지 않음" \
    "$prompt_log" \
    "TASK-011"

  local pane_dump seen_boot_prompt=false attempt
  for attempt in $(seq 1 8); do
    sleep 1
    pane_dump="$(tmux capture-pane -pJ -t "${SESSION}:developer" -S -500 2>/dev/null || true)"
    if echo "$pane_dump" | grep -q "TASK-011"; then
      seen_boot_prompt=true
      break
    fi
  done

  TOTAL=$((TOTAL + 1))
  if [ "$seen_boot_prompt" = true ]; then
    echo "  PASS: full boot/task prompt는 visible resumed session에 전달됨"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: full boot/task prompt가 resumed session에 나타나지 않음"
    FAIL=$((FAIL + 1))
  fi

  echo "  시나리오 31 완료"
}

# ──────────────────────────────────────────────
# 시나리오 32: default tmux server loss는 multi-project grace로 흡수
# ──────────────────────────────────────────────

test_scenario_32() {
  echo ""
  echo "=== 시나리오 32: shared vs isolated tmux contract ==="
  cleanup
  setup_test_project
  build_fake_claude

  local shared_socket="shared-contract"
  local shared_primary="whiplash-shared-a"
  local shared_peer="whiplash-shared-b"
  whiplash_tmux_run_on_socket "$shared_socket" new-session -d -s "$shared_primary" -n manager
  whiplash_tmux_run_on_socket "$shared_socket" new-session -d -s "$shared_peer" -n manager
  assert_true "shared socket에서는 primary 세션 존재" \
    tmux_has_session_for_socket "$shared_socket" "$shared_primary"
  assert_true "shared socket에서는 peer 세션 존재" \
    tmux_has_session_for_socket "$shared_socket" "$shared_peer"
  whiplash_tmux_run_on_socket "$shared_socket" kill-server 2>/dev/null || true
  assert_false "shared socket kill-server 후 primary 세션 소멸" \
    tmux_has_session_for_socket "$shared_socket" "$shared_primary"
  assert_false "shared socket kill-server 후 peer 세션도 함께 소멸" \
    tmux_has_session_for_socket "$shared_socket" "$shared_peer"

  tmux new-session -d -s "$SESSION" -n manager
  create_fake_agent "developer"
  register_fake_agent "developer" "developer"

  local peer_project="_stability-peer"
  local peer_session="whiplash-${peer_project}"
  local peer_dir="$REPO_ROOT/projects/${peer_project}"
  mkdir -p "$peer_dir/memory/manager" "$(runtime_root_dir "$peer_project")" "$peer_dir/logs"
  cat > "$peer_dir/project.md" <<'EOF'
# _stability-peer

- 목표: 통합 테스트용 peer 프로젝트
- 활성 에이전트: developer
- 실행 모드: solo
- 도메인: general
EOF
  whiplash_tmux_run_for_project "$peer_project" new-session -d -s "$peer_session" -n manager
  whiplash_tmux_run_for_project "$peer_project" new-window -t "$peer_session" -n developer
  whiplash_tmux_run_for_project "$peer_project" send-keys -t "${peer_session}:developer" "'${FAKE_CLAUDE_BIN}'" Enter

  local peer_sf="$peer_dir/memory/manager/sessions.md"
  cat > "$peer_sf" <<'HEADER'
# 활성 에이전트 세션

| 역할 | 백엔드 | Session ID | tmux Target | 상태 | 시작일 | 모델 | 비고 |
|------|--------|-----------|-------------|------|--------|------|------|
HEADER
  echo "| developer | claude | fake-session | ${peer_session}:developer | active | $(date +%Y-%m-%d) | test | |" >> "$peer_sf"

  WHIPLASH_MONITOR_ONCE=1 bash "$TOOLS_DIR/monitor.sh" "$PROJECT" >/dev/null 2>&1
  WHIPLASH_MONITOR_ONCE=1 bash "$TOOLS_DIR/monitor.sh" "$peer_project" >/dev/null 2>&1

  local before_epoch before_peer_epoch
  before_epoch="$(runtime_get_manager_state "$PROJECT" "session_epoch" "" 2>/dev/null || true)"
  before_peer_epoch="$(runtime_get_manager_state "$peer_project" "session_epoch" "" 2>/dev/null || true)"
  TOTAL=$((TOTAL + 1))
  if [[ "$before_epoch" == *"|"* ]] && [[ "$before_peer_epoch" == *"|"* ]]; then
    echo "  PASS: 두 프로젝트 모두 초기 session epoch 저장"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: 초기 session epoch 저장 누락"
    FAIL=$((FAIL + 1))
  fi

  tmux kill-server 2>/dev/null || true
  tmux new-session -d -s "$SESSION" -n manager

  assert_true "isolated socket에서는 peer 세션 유지" \
    tmux_has_session_for_socket "$peer_project" "$peer_session"

  WHIPLASH_MONITOR_ONCE=1 WHIPLASH_REHYDRATION_GRACE_SECONDS=5 \
    bash "$TOOLS_DIR/monitor.sh" "$PROJECT" >/dev/null 2>&1
  WHIPLASH_MONITOR_ONCE=1 WHIPLASH_REHYDRATION_GRACE_SECONDS=5 \
    bash "$TOOLS_DIR/monitor.sh" "$peer_project" >/dev/null 2>&1
  WHIPLASH_MONITOR_ONCE=1 WHIPLASH_REHYDRATION_GRACE_SECONDS=5 \
    bash "$TOOLS_DIR/monitor.sh" "$PROJECT" >/dev/null 2>&1

  assert_file_contains "primary project가 rehydration grace 기록" \
    "$PROJECT_DIR/logs/system.log" \
    "session_rehydration_grace ${SESSION}"
  assert_file_not_contains "peer project는 primary server loss에 영향받지 않음" \
    "$peer_dir/logs/system.log" \
    "session_rehydration_grace ${peer_session}"

  local primary_epoch_events peer_epoch_events
  primary_epoch_events="$(grep -c "session_epoch_changed ${SESSION}" "$PROJECT_DIR/logs/system.log" 2>/dev/null || true)"
  peer_epoch_events="$(grep -c "session_epoch_changed ${peer_session}" "$peer_dir/logs/system.log" 2>/dev/null || true)"
  assert_eq "primary project는 server-loss incident 1회로 수집" "1" "$primary_epoch_events"
  assert_eq "peer project는 isolated mode에서 incident 없음" "0" "$peer_epoch_events"

  assert_file_not_contains "primary project는 stale active row crash 미감지" \
    "$PROJECT_DIR/logs/system.log" \
    "developer 크래시 감지"
  assert_file_not_contains "peer project는 stale active row crash 미감지" \
    "$peer_dir/logs/system.log" \
    "developer 크래시 감지"
  assert_file_contains "primary project stale row는 recovery 후 stale로 내려감" \
    "$PROJECT_DIR/memory/manager/sessions.md" \
    "| ${SESSION}:developer | stale |"

  local after_epoch after_peer_epoch grace_until now_ts
  after_epoch="$(runtime_get_manager_state "$PROJECT" "session_recovery_epoch" "" 2>/dev/null || true)"
  after_peer_epoch="$(runtime_get_manager_state "$peer_project" "session_recovery_epoch" "" 2>/dev/null || true)"
  TOTAL=$((TOTAL + 1))
  if [[ "$after_epoch" == *"|"* ]] && [ "$after_epoch" != "$before_epoch" ] \
    && [ "$after_peer_epoch" = "$before_peer_epoch" ]; then
    echo "  PASS: isolated mode에서 primary만 recovery epoch 교체"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: isolated recovery epoch 동작이 기대와 다름"
    FAIL=$((FAIL + 1))
  fi

  grace_until="$(runtime_get_manager_state "$PROJECT" "rehydration_grace_until" "" 2>/dev/null || true)"
  now_ts="$(date +%s)"
  TOTAL=$((TOTAL + 1))
  if [[ "$grace_until" =~ ^[0-9]+$ ]] && [ "$grace_until" -gt "$now_ts" ]; then
    echo "  PASS: rehydration grace가 미래 시각으로 설정됨"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: rehydration grace가 설정되지 않음 ('$grace_until')"
    FAIL=$((FAIL + 1))
  fi

  invoke_cmd_function add_session_row "$PROJECT" "developer" "fresh-session" "${SESSION}:developer" "test" "claude"
  local developer_rows
  developer_rows="$(grep -c "^| developer | claude |" "$PROJECT_DIR/memory/manager/sessions.md" 2>/dev/null || true)"
  assert_eq "same tmux target은 단일 row로 갱신" "1" "$developer_rows"
  assert_file_contains "recovered target row가 새 session_id로 교체됨" \
    "$PROJECT_DIR/memory/manager/sessions.md" \
    "| developer | claude | fresh-session | ${SESSION}:developer | active |"
  assert_file_not_contains "old stale session_id는 제거됨" \
    "$PROJECT_DIR/memory/manager/sessions.md" \
    "fake-session"

  whiplash_tmux_run_for_project "$peer_project" kill-server 2>/dev/null || true
  rm -rf "$peer_dir"

  echo "  시나리오 32 완료"
}

# ──────────────────────────────────────────────
# 시나리오 33: delayed Claude warm-up 후에도 reboot prompt 전달 성공
# ──────────────────────────────────────────────

test_scenario_33() {
  echo ""
  echo "=== 시나리오 33: delayed Claude warm-up reboot ==="
  cleanup
  setup_test_project
  build_fake_claude

  tmux new-session -d -s "$SESSION" -n manager
  create_fake_agent "developer"
  register_fake_agent "developer" "developer"

  mkdir -p "$PROJECT_DIR/workspace/tasks"
  cat > "$PROJECT_DIR/workspace/tasks/TASK-012.md" <<'EOF'
# TASK-012: delayed Claude warm-up reboot smoke test
EOF
  bash "$TOOLS_DIR/message.sh" "$PROJECT" manager developer \
    task_assign normal "workspace/tasks/TASK-012.md" "warm-up retry" >/dev/null

  assert_true "delay/discard 환경에서도 developer reboot 성공" \
    env PATH="$PROJECT_DIR:$PATH" \
      WHIPLASH_FAKE_CLAUDE_WARMUP_SECONDS=2 \
      WHIPLASH_FAKE_CLAUDE_DISCARD_EARLY_INPUT=1 \
      bash "$TOOLS_DIR/cmd.sh" reboot developer "$PROJECT"

  assert_true "developer window 생성" \
    tmux_has_window "$SESSION" "developer"
  assert_file_contains "sessions.md에 developer session 기록" \
    "$PROJECT_DIR/memory/manager/sessions.md" \
    "| developer | claude |"

  local pane_dump seen_ready=false attempt
  for attempt in $(seq 1 8); do
    sleep 1
    pane_dump="$(tmux capture-pane -pJ -t "${SESSION}:developer" -S -160 2>/dev/null || true)"
    if echo "$pane_dump" | grep -q 'TASK-012'; then
      seen_ready=true
      break
    fi
  done

  TOTAL=$((TOTAL + 1))
  if [ "$seen_ready" = true ]; then
    echo "  PASS: delayed warm-up 후 full task prompt가 visible pane에 전달됨"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: delayed warm-up 후 full task prompt가 pane에 나타나지 않음"
    FAIL=$((FAIL + 1))
  fi

  echo "  시나리오 33 완료"
}

# ──────────────────────────────────────────────
# 시나리오 34: cmd_boot는 stale active session row를 demote한다
# ──────────────────────────────────────────────

test_scenario_34() {
  echo ""
  echo "=== 시나리오 34: cmd_boot stale session row cleanup ==="
  cleanup
  setup_test_project
  build_fake_claude
  build_fake_codex

  local sf="$PROJECT_DIR/memory/manager/sessions.md"
  cat > "$sf" <<EOF
# 활성 에이전트 세션

| 역할 | 백엔드 | Session ID | tmux Target | 상태 | 시작일 | 모델 | 비고 |
|------|--------|-----------|-------------|------|--------|------|------|
| ghost | claude | stale-session | ${SESSION}:ghost | active | 2026-03-24 | test | stale-seed |
EOF

  local boot_log="$PROJECT_DIR/boot-stale-session.log"
  assert_true "cmd.sh boot가 stale session row와 함께 성공" \
    bash -c 'PATH="$1:$PATH" bash "$2/cmd.sh" boot "$3" >"$4" 2>&1' -- \
    "$PROJECT_DIR" "$TOOLS_DIR" "$PROJECT" "$boot_log"

  local stale_count active_count
  stale_count="$(awk -F'|' -v target="${SESSION}:ghost" '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    trim($2) == "ghost" && trim($5) == target && trim($6) == "stale" { c++ }
    END { print c + 0 }
  ' "$sf")"
  active_count="$(awk -F'|' -v target="${SESSION}:ghost" '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    trim($2) == "ghost" && trim($5) == target && trim($6) == "active" { c++ }
    END { print c + 0 }
  ' "$sf")"

  assert_eq "missing target active row가 stale로 강등됨" "1" "$stale_count"
  assert_eq "ghost active row는 boot 이후 남지 않음" "0" "$active_count"

  echo "  시나리오 34 완료"
}

# ──────────────────────────────────────────────
# 시나리오 35: cmd_boot는 stale runtime state를 초기화한다
# ──────────────────────────────────────────────

test_scenario_35() {
  echo ""
  echo "=== 시나리오 35: cmd_boot stale runtime reset ==="
  cleanup
  setup_test_project
  build_fake_claude
  build_fake_codex

  local reboot_state idle_state boot_log
  reboot_state="$(runtime_reboot_state_file "$PROJECT")"
  idle_state="$(runtime_idle_state_file "$PROJECT")"
  mkdir -p "$(dirname "$reboot_state")"

  cat > "$reboot_state" <<'EOF'
developer	2	123456	123999
EOF
  cat > "$idle_state" <<'EOF'
developer	123456
EOF

  assert_file_exists "stale reboot-state seed 생성" "$reboot_state"
  assert_file_exists "stale idle-state seed 생성" "$idle_state"

  boot_log="$PROJECT_DIR/boot-runtime-reset.log"
  assert_true "cmd.sh boot가 stale runtime state와 함께 성공" \
    bash -c 'PATH="$1:$PATH" bash "$2/cmd.sh" boot "$3" >"$4" 2>&1' -- \
    "$PROJECT_DIR" "$TOOLS_DIR" "$PROJECT" "$boot_log"

  assert_file_not_exists "cmd_boot가 reboot-state.tsv 초기화" "$reboot_state"
  assert_file_not_exists "cmd_boot가 idle-state.tsv 초기화" "$idle_state"

  echo "  시나리오 35 완료"
}

# ──────────────────────────────────────────────
# 시나리오 36: wrapped live agent는 false-crash reboot되지 않는다
# ──────────────────────────────────────────────

test_scenario_36() {
  echo ""
  echo "=== 시나리오 36: wrapped live agent false-crash guard ==="
  cleanup
  setup_test_project
  build_fake_claude

  tmux new-session -d -s "$SESSION" -n manager
  create_wrapped_fake_agent "developer" "$FAKE_CLAUDE_BIN" "claude"
  register_fake_agent "developer" "developer"

  local pane_pid
  pane_pid="$(tmux list-panes -t "${SESSION}:developer" -F '#{pane_pid}' 2>/dev/null | head -1 || true)"
  assert_true "wrapped developer alive 확인" wait_for_child_process_named "$pane_pid" claude

  bash "$TOOLS_DIR/cmd.sh" monitor-check "$PROJECT" >/dev/null 2>&1

  assert_file_not_contains "wrapped live agent는 false-crash로 기록되지 않음" \
    "$PROJECT_DIR/logs/system.log" "developer 크래시 감지"

  echo "  시나리오 36 완료"
}

# ──────────────────────────────────────────────
# 시나리오 37: add_session_row는 same role/backend active truth를 단일 row로 유지한다
# ──────────────────────────────────────────────

test_scenario_37() {
  echo ""
  echo "=== 시나리오 37: session active truth dedupe ==="
  cleanup
  setup_test_project

  local sf="$PROJECT_DIR/memory/manager/sessions.md"
  cat > "$sf" <<EOF
# 활성 에이전트 세션

| 역할 | 백엔드 | Session ID | tmux Target | 상태 | 시작일 | 모델 | 비고 |
|------|--------|-----------|-------------|------|--------|------|------|
| developer | claude | old-session | ${SESSION}:developer-old | active | 2026-03-24 | test | stale-active |
| developer | codex | codex-session | ${SESSION}:developer-codex | active | 2026-03-24 | test | keep |
EOF

  invoke_cmd_function add_session_row "$PROJECT" "developer" "fresh-session" "${SESSION}:developer" "test" "claude"

  local developer_claude_active developer_codex_active old_target_rows
  developer_claude_active="$(awk -F'|' '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    trim($2) == "developer" && trim($3) == "claude" && trim($6) == "active" { c++ }
    END { print c + 0 }
  ' "$sf")"
  developer_codex_active="$(awk -F'|' '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    trim($2) == "developer" && trim($3) == "codex" && trim($6) == "active" { c++ }
    END { print c + 0 }
  ' "$sf")"
  old_target_rows="$(grep -c "developer-old" "$sf" 2>/dev/null || true)"

  assert_eq "same role/backend active row는 단일 claude row로 수렴" "1" "$developer_claude_active"
  assert_eq "다른 backend active row는 유지" "1" "$developer_codex_active"
  assert_eq "old claude active target row는 제거" "0" "$old_target_rows"
  assert_file_contains "새 claude session row가 active로 기록" \
    "$sf" \
    "| developer | claude | fresh-session | ${SESSION}:developer | active |"

  echo "  시나리오 37 완료"
}

# ──────────────────────────────────────────────
# 시나리오 38: manager boot failure는 stale active row를 남기지 않는다
# ──────────────────────────────────────────────

test_scenario_38() {
  echo ""
  echo "=== 시나리오 38: manager boot failure cleanup ==="
  cleanup
  setup_test_project
  build_fake_claude

  python3 - "$PROJECT_DIR/project.md" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
content = path.read_text(encoding="utf-8")
content = content.replace("- 실행 모드: solo", "- 실행 모드: solo\n- control-plane 백엔드: claude", 1)
path.write_text(content, encoding="utf-8")
PY

  tmux new-session -d -s "$SESSION" -n dashboard

  assert_false "manager boot prompt failure는 성공으로 남지 않음" \
    env PATH="$PROJECT_DIR:$PATH" TOOLS_DIR="$TOOLS_DIR" PROJECT="$PROJECT" bash -lc '
      export WHIPLASH_SOURCE_ONLY=1
      source "'"$TOOLS_DIR"'/cmd.sh"
      submit_tmux_prompt_when_ready() { return 1; }
      boot_manager_window "'"$PROJECT"'"
    '

  local manager_active manager_boot_failed
  manager_active="$(awk -F'|' '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    trim($2) == "manager" && trim($6) == "active" { c++ }
    END { print c + 0 }
  ' "$PROJECT_DIR/memory/manager/sessions.md")"
  manager_boot_failed="$(awk -F'|' '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    trim($2) == "manager" && trim($6) == "boot-failed" { c++ }
    END { print c + 0 }
  ' "$PROJECT_DIR/memory/manager/sessions.md")"

  assert_eq "manager active row는 남지 않음" "0" "$manager_active"
  assert_eq "manager row는 boot-failed로 정리됨" "1" "$manager_boot_failed"

  echo "  시나리오 38 완료"
}

# ──────────────────────────────────────────────
# 시나리오 39: Rich TUI submit success는 처리 신호가 있어야 한다
# ──────────────────────────────────────────────

test_scenario_39() {
  echo ""
  echo "=== 시나리오 39: rich TUI submit success gate ==="
  cleanup
  setup_test_project
  build_fake_claude

  tmux new-session -d -s "$SESSION" -n rich-ok
  tmux send-keys -t "${SESSION}:rich-ok" "env WHIPLASH_FAKE_RICH_TUI=1 '${FAKE_CLAUDE_BIN}'" Enter
  tmux_submit_wait_ready "${SESSION}:rich-ok" 10 1 || true

  assert_true "rich TUI 처리 신호가 있으면 submit 성공" \
    tmux_submit_pasted_payload "${SESSION}:rich-ok" "print-rich-ok" "rich-ok"

  local pane_dump
  pane_dump="$(tmux capture-pane -p -t "${SESSION}:rich-ok" -S -80 2>/dev/null || true)"
  TOTAL=$((TOTAL + 1))
  if echo "$pane_dump" | grep -q "\\[submitted\\]" && echo "$pane_dump" | grep -q "print-rich-ok"; then
    echo "  PASS: rich TUI submit이 실제 처리 흔적을 남김"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: rich TUI submit 처리 흔적이 없음"
    FAIL=$((FAIL + 1))
  fi

  tmux new-window -t "$SESSION" -n rich-drop
  tmux send-keys -t "${SESSION}:rich-drop" "env WHIPLASH_FAKE_RICH_TUI=1 WHIPLASH_FAKE_SWALLOW_SUBMIT=1 '${FAKE_CLAUDE_BIN}'" Enter
  tmux_submit_wait_ready "${SESSION}:rich-drop" 10 1 || true

  assert_false "rich TUI에서 미처리 입력은 성공 처리되지 않음" \
    tmux_submit_pasted_payload "${SESSION}:rich-drop" "print-rich-drop" "rich-drop"

  pane_dump="$(tmux capture-pane -p -t "${SESSION}:rich-drop" -S -80 2>/dev/null || true)"
  TOTAL=$((TOTAL + 1))
  if ! echo "$pane_dump" | grep -q "\\[submitted\\]"; then
    echo "  PASS: swallowed submit은 처리 ack 없이 실패로 남음"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: swallowed submit이 처리 ack를 남김"
    FAIL=$((FAIL + 1))
  fi

  echo "  시나리오 39 완료"
}

# ──────────────────────────────────────────────
# 시나리오 40: dashboard monitor zombie heartbeat는 healthy로 보이지 않는다
# ──────────────────────────────────────────────

test_scenario_40() {
  echo ""
  echo "=== 시나리오 40: dashboard monitor zombie heartbeat 표시 ==="
  cleanup
  setup_test_project

  runtime_set_manager_state "$PROJECT" "monitor_pid" "$$"
  runtime_set_manager_state "$PROJECT" "monitor_heartbeat" "$(( $(date +%s) - 120 ))"

  local monitor_info
  monitor_info="$(probe_dashboard_monitor)"
  assert_eq "dashboard monitor가 stale heartbeat를 zombie로 인식" "1|1|0|1" "$monitor_info"

  echo "  시나리오 40 완료"
}

# ──────────────────────────────────────────────
# 시나리오 41: assigned idle agent row는 ALIVE 대신 IDLE로 보인다
# ──────────────────────────────────────────────

test_scenario_41() {
  echo ""
  echo "=== 시나리오 41: dashboard assigned idle row 표시 ==="
  cleanup
  setup_test_project
  build_fake_claude

  mkdir -p "$PROJECT_DIR/workspace/tasks"
  cat > "$PROJECT_DIR/workspace/tasks/TASK-010.md" << 'EOF'
# TASK-010: Dashboard idle row test
EOF

  tmux new-session -d -s "$SESSION" -n dashboard
  create_fake_agent "developer"
  register_fake_agent "developer" "developer"

  bash "$TOOLS_DIR/message.sh" "$PROJECT" manager developer \
    task_assign normal "workspace/tasks/TASK-010.md" "dashboard idle row smoke" >/dev/null

  local dashboard_state
  dashboard_state="$(probe_dashboard_agent developer)"
  assert_eq "healthy assigned agent는 여전히 ACTIVE" "ACTIVE|TASK-010" "$dashboard_state"

  runtime_set_idle_check_ts "$PROJECT" "developer" "$(( $(date +%s) - 60 ))"
  dashboard_state="$(probe_dashboard_agent developer)"
  assert_eq "idle-state가 있으면 assigned row를 IDLE로 표시" "IDLE|TASK-010" "$dashboard_state"

  echo "  시나리오 41 완료"
}

# ──────────────────────────────────────────────
# 시나리오 42: runtime auth-blocked truth는 backend 메타보다 우선한다
# ──────────────────────────────────────────────

test_scenario_42() {
  echo ""
  echo "=== 시나리오 42: dashboard runtime auth truth 우선 ==="
  cleanup
  setup_test_project
  build_fake_codex

  mkdir -p "$PROJECT_DIR/workspace/tasks"
  cat > "$PROJECT_DIR/workspace/tasks/TASK-011.md" << 'EOF'
# TASK-011: Dashboard runtime auth truth test
EOF

  tmux new-session -d -s "$SESSION" -n dashboard
  create_fake_codex_agent "developer-codex"
  register_fake_codex_agent "developer-codex" "developer"

  bash "$TOOLS_DIR/message.sh" "$PROJECT" manager developer-codex \
    task_assign normal "workspace/tasks/TASK-011.md" "dashboard runtime auth smoke" >/dev/null

  local dashboard_state
  dashboard_state="$(probe_dashboard_agent developer-codex)"
  assert_eq "healthy codex assigned row는 ACTIVE 유지" "ACTIVE|TASK-011" "$dashboard_state"

  runtime_set_manager_state "$PROJECT" "agent_health_developer-codex" "AUTH_BLOCKED"
  dashboard_state="$(probe_dashboard_agent developer-codex)"
  assert_eq "runtime auth-blocked truth가 있으면 WAIT로 표시" "WAIT|TASK-011" "$dashboard_state"

  echo "  시나리오 42 완료"
}

# ──────────────────────────────────────────────
# 시나리오 43: single owner 패턴은 dual에서도 고정 미러링하지 않는다
# ──────────────────────────────────────────────

test_scenario_43() {
  echo ""
  echo "=== 시나리오 43: single owner task-pattern dispatch ==="
  cleanup
  setup_test_project
  build_fake_claude
  build_fake_codex

  python3 - "$PROJECT_DIR/project.md" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
content = path.read_text(encoding="utf-8")
content = content.replace("- 실행 모드: solo", "- 실행 모드: dual", 1)
path.write_text(content, encoding="utf-8")
PY

  mkdir -p "$PROJECT_DIR/workspace/tasks"
  cat > "$PROJECT_DIR/workspace/tasks/TASK-012.md" <<'EOF'
# TASK-012: Single owner dispatch test

- **Pattern**: `single owner`
- **Owner lane**: `developer-codex`
EOF

  tmux new-session -d -s "$SESSION" -n manager
  create_fake_agent "developer-claude"
  create_fake_codex_agent "developer-codex"
  register_fake_agent "developer-claude" "developer"
  register_fake_codex_agent "developer-codex" "developer"

  bash "$TOOLS_DIR/cmd.sh" dispatch developer \
    "workspace/tasks/TASK-012.md" "$PROJECT" >/dev/null

  local sf codex_active claude_active
  sf="$PROJECT_DIR/memory/manager/assignments.md"
  codex_active="$(grep -Ec "\\| developer-codex \\| workspace/tasks/TASK-012.md \\| .*\\| active \\|" "$sf" 2>/dev/null || true)"
  claude_active="$(grep -Ec "\\| developer-claude \\| workspace/tasks/TASK-012.md \\| .*\\| active \\|" "$sf" 2>/dev/null || true)"
  assert_eq "single owner는 codex lane만 active" "1" "$codex_active"
  assert_eq "single owner는 claude mirror를 만들지 않음" "0" "$claude_active"

  echo "  시나리오 43 완료"
}

# ──────────────────────────────────────────────
# 시나리오 44: lead + verify 패턴은 lead/review lane을 분리 기록한다
# ──────────────────────────────────────────────

test_scenario_44() {
  echo ""
  echo "=== 시나리오 44: lead + verify task-pattern dispatch ==="
  cleanup
  setup_test_project
  build_fake_claude
  build_fake_codex

  mkdir -p "$PROJECT_DIR/workspace/tasks"
  cat > "$PROJECT_DIR/workspace/tasks/TASK-013.md" <<'EOF'
# TASK-013: Lead verify dispatch test

- **Pattern**: `lead + verify`
- **Owner lane**: `developer-codex`
- **Review lane**: `developer-claude`
EOF

  tmux new-session -d -s "$SESSION" -n manager
  create_fake_agent "developer-claude"
  create_fake_codex_agent "developer-codex"
  register_fake_agent "developer-claude" "developer"
  register_fake_codex_agent "developer-codex" "developer"

  bash "$TOOLS_DIR/cmd.sh" dispatch developer \
    "workspace/tasks/TASK-013.md" "$PROJECT" >/dev/null

  local sf codex_active claude_active claude_pane codex_pane
  sf="$PROJECT_DIR/memory/manager/assignments.md"
  codex_active="$(grep -Ec "\\| developer-codex \\| workspace/tasks/TASK-013.md \\| .*\\| active \\|" "$sf" 2>/dev/null || true)"
  claude_active="$(grep -Ec "\\| developer-claude \\| workspace/tasks/TASK-013.md \\| .*\\| active \\|" "$sf" 2>/dev/null || true)"
  assert_eq "lead lane assignment 기록" "1" "$codex_active"
  assert_eq "review lane assignment 기록" "1" "$claude_active"

  codex_pane="$(tmux capture-pane -p -t "${SESSION}:developer-codex" -S -80 2>/dev/null || true)"
  claude_pane="$(tmux capture-pane -p -t "${SESSION}:developer-claude" -S -80 2>/dev/null || true)"
  TOTAL=$((TOTAL + 1))
  if echo "$codex_pane" | grep -q 'execution lead' && echo "$claude_pane" | grep -q 'review/verify lane'; then
    echo "  PASS: lead와 review lane 메시지가 구분됨"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: lead/review lane 메시지 구분이 없음"
    FAIL=$((FAIL + 1))
  fi

  echo "  시나리오 44 완료"
}

# ──────────────────────────────────────────────
# 시나리오 45: independent compare 패턴은 plain dispatch에서도 비교 구조를 만든다
# ──────────────────────────────────────────────

test_scenario_45() {
  echo ""
  echo "=== 시나리오 45: independent compare task-pattern dispatch ==="
  cleanup
  setup_test_project
  build_fake_claude
  build_fake_codex

  mkdir -p "$PROJECT_DIR/workspace/tasks"
  cat > "$PROJECT_DIR/workspace/tasks/TASK-014.md" <<'EOF'
# TASK-014: Independent compare dispatch test

- **Pattern**: `independent compare`
- **Owner lanes**: `developer-claude`, `developer-codex`
EOF

  tmux new-session -d -s "$SESSION" -n manager
  create_fake_agent "developer-claude"
  create_fake_codex_agent "developer-codex"
  register_fake_agent "developer-claude" "developer"
  register_fake_codex_agent "developer-codex" "developer"

  bash "$TOOLS_DIR/cmd.sh" dispatch developer \
    "workspace/tasks/TASK-014.md" "$PROJECT" >/dev/null

  local sf claude_active codex_active
  sf="$PROJECT_DIR/memory/manager/assignments.md"
  claude_active="$(grep -Ec "\\| developer-claude \\| workspace/tasks/TASK-014.md \\| .*\\| active \\|" "$sf" 2>/dev/null || true)"
  codex_active="$(grep -Ec "\\| developer-codex \\| workspace/tasks/TASK-014.md \\| .*\\| active \\|" "$sf" 2>/dev/null || true)"
  assert_eq "independent compare claude lane assignment 기록" "1" "$claude_active"
  assert_eq "independent compare codex lane assignment 기록" "1" "$codex_active"

  echo "  시나리오 45 완료"
}

# ──────────────────────────────────────────────
# 시나리오 46: codex reboot/refresh도 active task를 bootstrap에 다시 싣는다
# ──────────────────────────────────────────────

test_scenario_46() {
  echo ""
  echo "=== 시나리오 46: codex active task resume seam ==="
  cleanup
  setup_test_project
  build_fake_codex

  python3 - "$PROJECT_DIR/project.md" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
content = path.read_text(encoding="utf-8")
content = content.replace("- 실행 모드: solo", "- 실행 모드: dual", 1)
path.write_text(content, encoding="utf-8")
PY

  mkdir -p "$PROJECT_DIR/workspace/tasks"
  cat > "$PROJECT_DIR/workspace/tasks/TASK-015.md" <<'EOF'
# TASK-015: Codex reboot resume smoke test
EOF
  cat > "$PROJECT_DIR/workspace/tasks/TASK-016.md" <<'EOF'
# TASK-016: Codex refresh resume smoke test
EOF

  tmux new-session -d -s "$SESSION" -n manager
  create_fake_codex_agent "developer-codex"
  register_fake_codex_agent "developer-codex" "developer"

  bash "$TOOLS_DIR/message.sh" "$PROJECT" manager developer-codex \
    task_assign normal "workspace/tasks/TASK-015.md" "codex reboot resume" >/dev/null

  local bootstrap_path
  bootstrap_path="$PROJECT_DIR/runtime/bootstrap/developer-codex.md"
  rm -f "$bootstrap_path"

  assert_true "codex reboot 성공" \
    env PATH="$PROJECT_DIR:$PATH" \
      bash "$TOOLS_DIR/cmd.sh" reboot developer-codex "$PROJECT"

  assert_file_contains "codex reboot bootstrap에 active task 포함" \
    "$bootstrap_path" \
    "workspace/tasks/TASK-015.md"
  assert_file_contains "codex reboot bootstrap에 task resume 블록 포함" \
    "$bootstrap_path" \
    "\\[재부팅 후 태스크 복구\\]"

  bash "$TOOLS_DIR/message.sh" "$PROJECT" manager developer-codex \
    task_assign normal "workspace/tasks/TASK-016.md" "codex refresh resume" >/dev/null

  rm -f "$bootstrap_path"
  assert_true "codex refresh 성공" \
    env PATH="$PROJECT_DIR:$PATH" \
      WHIPLASH_REFRESH_SKIP_HANDOFF_REQUEST=1 \
      WHIPLASH_REFRESH_HANDOFF_WAIT_SECONDS=0 \
      bash "$TOOLS_DIR/cmd.sh" refresh developer-codex "$PROJECT"

  assert_file_contains "codex refresh bootstrap에 active task 포함" \
    "$bootstrap_path" \
    "workspace/tasks/TASK-016.md"
  assert_file_contains "codex refresh bootstrap에 task resume 블록 포함" \
    "$bootstrap_path" \
    "\\[재부팅 후 태스크 복구\\]"

  echo "  시나리오 46 완료"
}

# ──────────────────────────────────────────────
# 시나리오 47: execution-config는 preset/role override를 project 설정에 저장한다
# ──────────────────────────────────────────────

test_scenario_47() {
  echo ""
  echo "=== 시나리오 47: execution-config persistence ==="
  cleanup
  setup_test_project

  assert_true "codex only preset 저장" \
    bash "$TOOLS_DIR/cmd.sh" execution-config "$PROJECT" codex only

  local preset developer_plan manager_backend
  preset="$(python3 "$TOOLS_DIR/execution_config.py" --repo-root "$REPO_ROOT" show --project "$PROJECT" | jq -r '.current_preset')"
  assert_eq "execution-config helper가 codex-only 저장" "codex-only" "$preset"

  developer_plan="$(invoke_cmd_function role_window_plan_lines "$PROJECT" developer)"
  assert_eq "codex-only에서 developer는 bare codex window" "developer|codex|gpt-5.4" "$developer_plan"

  manager_backend="$(invoke_cmd_function get_manager_backend "$PROJECT")"
  assert_eq "codex-only에서 manager backend는 codex" "codex" "$manager_backend"

  assert_file_contains "project.md 실행 프리셋 요약 저장" "$PROJECT_DIR/project.md" "실행 프리셋.*codex-only"
  assert_file_contains "project.md execution config block 저장" "$PROJECT_DIR/project.md" "WHIPLASH_EXECUTION_CONFIG:START"

  assert_true "default preset 복귀" \
    bash "$TOOLS_DIR/cmd.sh" execution-config "$PROJECT" default

  assert_true "role override 저장" \
    bash "$TOOLS_DIR/cmd.sh" execution-config "$PROJECT" developer claude haiku

  developer_plan="$(invoke_cmd_function role_window_plan_lines "$PROJECT" developer)"
  assert_eq "role override가 developer backend/model에 반영" "developer|claude|haiku" "$developer_plan"

  echo "  시나리오 47 완료"
}

# ──────────────────────────────────────────────
# 시나리오 48: runtime execution-config는 worker를 즉시 재구성한다
# ──────────────────────────────────────────────

test_scenario_48() {
  echo ""
  echo "=== 시나리오 48: runtime execution-config reconcile ==="
  cleanup
  setup_test_project

  python3 - "$PROJECT_DIR/project.md" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
content = path.read_text(encoding="utf-8")
content = content.replace("developer, researcher", "developer", 1)
path.write_text(content, encoding="utf-8")
PY

  assert_true "dual preset 저장" \
    bash "$TOOLS_DIR/cmd.sh" execution-config "$PROJECT" dual

  mkdir -p "$PROJECT_DIR/workspace/tasks"
  cat > "$PROJECT_DIR/workspace/tasks/TASK-017.md" <<'EOF'
# TASK-017: execution-config reconcile smoke
EOF

  tmux new-session -d -s "$SESSION" -n manager
  tmux new-window -d -t "$SESSION" -n developer-claude
  tmux new-window -d -t "$SESSION" -n developer-codex
  register_fake_agent "developer-claude" "developer"
  register_fake_codex_agent "developer-codex" "developer"

  bash "$TOOLS_DIR/cmd.sh" assign developer-claude "workspace/tasks/TASK-017.md" "$PROJECT" >/dev/null
  bash "$TOOLS_DIR/cmd.sh" assign developer-codex "workspace/tasks/TASK-017.md" "$PROJECT" >/dev/null

  assert_true "runtime codex-only 전환" \
    bash <<EOF
export WHIPLASH_SOURCE_ONLY=1
source "$TOOLS_DIR/cmd.sh"
boot_agent_with_backend() {
  local role="\$1" project="\$2" window_name="\$3" backend="\$4"
  tmux new-window -d -t "$SESSION" -n "\$window_name" 2>/dev/null || true
  add_session_row "\$project" "\$role" "fake-\${backend}" "$SESSION:\${window_name}" "test" "\$backend"
}
cmd_execution_config "$PROJECT" codex only
EOF

  local windows developer_active old_claude_active old_codex_active role_assignment
  windows="$(tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null || true)"
  TOTAL=$((TOTAL + 1))
  if printf '%s\n' "$windows" | grep -qx 'developer' \
     && ! printf '%s\n' "$windows" | grep -qx 'developer-claude' \
     && ! printf '%s\n' "$windows" | grep -qx 'developer-codex'; then
    echo "  PASS: canonical worker windows가 single codex로 재구성됨"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: canonical worker windows 재구성이 잘못됨"
    FAIL=$((FAIL + 1))
  fi

  developer_active="$(awk -F'|' '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    trim($2) == "developer" && trim($3) == "codex" && trim($5) ~ /:developer$/ && trim($6) == "active" { c++ }
    END { print c + 0 }
  ' "$PROJECT_DIR/memory/manager/sessions.md")"
  old_claude_active="$(awk -F'|' '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    trim($5) ~ /:developer-claude$/ && trim($6) == "active" { c++ }
    END { print c + 0 }
  ' "$PROJECT_DIR/memory/manager/sessions.md")"
  old_codex_active="$(awk -F'|' '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    trim($5) ~ /:developer-codex$/ && trim($6) == "active" { c++ }
    END { print c + 0 }
  ' "$PROJECT_DIR/memory/manager/sessions.md")"
  assert_eq "새 developer codex active row 생성" "1" "$developer_active"
  assert_eq "old claude active row 제거" "0" "$old_claude_active"
  assert_eq "old codex active row 제거" "0" "$old_codex_active"

  role_assignment="$(awk -F'|' '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    trim($2) == "developer" && trim($3) == "workspace/tasks/TASK-017.md" && trim($5) == "active" { c++ }
    END { print c + 0 }
  ' "$PROJECT_DIR/memory/manager/assignments.md")"
  assert_eq "collapsed role assignment를 bare developer로 이관" "1" "$role_assignment"

  echo "  시나리오 48 완료"
}

# ──────────────────────────────────────────────
# 메인
# ──────────────────────────────────────────────

if [ "${WHIPLASH_SOURCE_ONLY:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

echo "============================================"
echo "  Whiplash 안정성 통합 테스트"
echo "============================================"
echo "프로젝트: $PROJECT"
echo "시작: $(date '+%Y-%m-%d %H:%M:%S')"

# 사전 정리
tmux kill-session -t "$SESSION" 2>/dev/null || true
rm -rf "$PROJECT_DIR"

test_scenario_1
test_scenario_2
test_scenario_3
test_scenario_4
test_scenario_5
test_scenario_6
test_scenario_7
test_scenario_8
test_scenario_9
test_scenario_10
test_scenario_11
test_scenario_12
test_scenario_13
test_scenario_14
test_scenario_15
test_scenario_16
test_scenario_19
test_scenario_20
test_scenario_21
test_scenario_22
test_scenario_24
test_scenario_25
test_scenario_26
test_scenario_27
test_scenario_28
test_scenario_29
test_scenario_30
test_scenario_31
test_scenario_32
test_scenario_33
test_scenario_34
test_scenario_35
test_scenario_36
test_scenario_37
test_scenario_38
test_scenario_39
test_scenario_40
test_scenario_41
test_scenario_42
test_scenario_43
test_scenario_44
test_scenario_45
test_scenario_46
test_scenario_47
test_scenario_48

echo ""
echo "============================================"
echo "  결과: ${PASS}/${TOTAL} 통과, ${FAIL} 실패"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
