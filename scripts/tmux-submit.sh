#!/bin/bash
# tmux-submit.sh -- tmux pane에 붙여넣은 입력이 실제 제출되었는지 확인하는 헬퍼
#
# 전략:
#   1. payload를 tmux buffer로 붙여넣는다.
#   2. pane tail을 캡처해서 payload가 입력창 하단에 실제로 들어갔는지 확인한다.
#   3. Enter를 보내고, payload가 pane 하단 draft에서 사라질 때까지 계속 확인한다.
#   4. draft가 그대로 남아 있으면 잠시 기다렸다가 Enter를 다시 보낸다.
#   5. tmux target이 사라지지 않는 한, 제출될 때까지 반복한다.

TMUX_SUBMIT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$TMUX_SUBMIT_SCRIPT_DIR/tmux-env.sh"
whiplash_tmux_maybe_activate_from_env

tmux_submit__trim_trailing_ws() {
  local text="$1"
  while :; do
    case "$text" in
      *$'\n') text="${text%$'\n'}" ;;
      *$'\r') text="${text%$'\r'}" ;;
      *$'\t') text="${text%$'\t'}" ;;
      *" ")   text="${text% }" ;;
      *) break ;;
    esac
  done
  printf '%s' "$text"
}

tmux_submit__capture_lines() {
  local payload="$1"
  local lines
  lines=$(printf '%s' "$payload" | awk 'END { print NR }')
  [ -n "$lines" ] || lines=1
  lines=$((lines + 12))
  if [ "$lines" -lt 16 ]; then
    lines=16
  fi
  if [ "$lines" -gt 160 ]; then
    lines=160
  fi
  printf '%s\n' "$lines"
}

tmux_submit__capture_tail() {
  local tmux_target="$1"
  local payload="$2"
  local lines="${3:-}"
  [ -n "$lines" ] || lines="$(tmux_submit__capture_lines "$payload")"
  tmux capture-pane -pJ -t "$tmux_target" -S "-${lines}" 2>/dev/null || true
}

tmux_submit__capture_recent() {
  local tmux_target="$1"
  local lines="${2:-60}"
  tmux capture-pane -pJ -t "$tmux_target" -S "-${lines}" 2>/dev/null || true
}

tmux_submit__target_exists() {
  local tmux_target="$1"
  tmux list-panes -t "$tmux_target" >/dev/null 2>&1
}

tmux_submit__normalize_capture_for_match() {
  local capture="$1"
  printf '%s\n' "$capture" | awk '
    {
      sub(/\r$/, "", $0)
      if ($0 ~ /^>>> ?$/ || $0 ~ /^\.\.\. ?$/) {
        next
      }
      sub(/^>>> /, "", $0)
      sub(/^\.\.\. /, "", $0)
      print
    }
  '
}

tmux_submit__payload_tail_line() {
  local payload="$1"
  local line last_line=""
  while IFS= read -r line || [ -n "$line" ]; do
    line="$(tmux_submit__trim_trailing_ws "$line")"
    [ -n "$line" ] || continue
    last_line="$line"
  done <<< "$payload"
  printf '%s' "$last_line"
}

tmux_submit__payload_tail_pair() {
  local payload="$1"
  local line prev_line="" last_line=""
  while IFS= read -r line || [ -n "$line" ]; do
    line="$(tmux_submit__trim_trailing_ws "$line")"
    [ -n "$line" ] || continue
    prev_line="$last_line"
    last_line="$line"
  done <<< "$payload"

  if [ -n "$prev_line" ] && [ -n "$last_line" ]; then
    printf '%s\n%s' "$prev_line" "$last_line"
  fi
}

tmux_submit__capture_has_payload_anywhere() {
  local capture="$1"
  local payload="$2"
  local capture_norm payload_trim tail_line tail_pair
  capture_norm="$(tmux_submit__normalize_capture_for_match "$capture")"
  payload_trim="$(tmux_submit__trim_trailing_ws "$payload")"
  [ -n "$payload_trim" ] || return 1
  if [[ "$capture" == *"$payload_trim"* ]] || [[ "$capture_norm" == *"$payload_trim"* ]]; then
    return 0
  fi

  tail_pair="$(tmux_submit__trim_trailing_ws "$(tmux_submit__payload_tail_pair "$payload")")"
  if [ -n "$tail_pair" ] && { [[ "$capture" == *"$tail_pair"* ]] || [[ "$capture_norm" == *"$tail_pair"* ]]; }; then
    return 0
  fi

  tail_line="$(tmux_submit__trim_trailing_ws "$(tmux_submit__payload_tail_line "$payload")")"
  [ -n "$tail_line" ] || return 1
  [[ "$capture" == *"$tail_line"* ]] || [[ "$capture_norm" == *"$tail_line"* ]]
}

tmux_submit__capture_has_submission_progress() {
  local capture="$1"
  printf '%s\n' "$capture" | grep -Eiq '(\[submitted\]|✻ |⏺ |thinking|working|processing|responding|analyzing|flummoxing|honking)'
}

tmux_submit__is_rich_tui_capture() {
  local capture="$1"
  printf '%s\n' "$capture" | grep -Eq '(Claude Code v|OpenAI Codex|gpt-5\.|bypass permissions on|ctrl\+g to edit in Vim|Update available! Run: brew upgrade c)'
}

tmux_submit__capture_has_prompt_ready() {
  local capture="$1"
  local recent
  recent="$(printf '%s\n' "$capture" | tail -n 12)"

  if tmux_submit__is_rich_tui_capture "$capture"; then
    printf '%s\n' "$recent" | grep -Eiq '(^[❯›] |^> ?$|esc to interrupt|shift\+tab to cycle|bypass permissions on|ctrl\+t to hide tasks|% left ·)'
    return
  fi

  printf '%s\n' "$recent" | grep -Eq '(>>> |^> ?$)'
}

tmux_submit__submission_confirmed() {
  local capture="$1"
  if tmux_submit__is_rich_tui_capture "$capture"; then
    tmux_submit__capture_has_submission_progress "$capture"
    return
  fi
  if tmux_submit__capture_has_submission_progress "$capture"; then
    return 0
  fi
  tmux_submit__capture_has_prompt_ready "$capture"
}

tmux_submit_wait_ready() {
  local tmux_target="$1"
  local attempts="${2:-20}"
  local delay="${3:-1}"
  local attempt capture

  for attempt in $(seq 1 "$attempts"); do
    if ! tmux_submit__target_exists "$tmux_target"; then
      return 1
    fi
    capture="$(tmux_submit__capture_recent "$tmux_target" 120)"
    TMUX_SUBMIT_LAST_CAPTURE="$capture"
    if tmux_submit__capture_has_prompt_ready "$capture"; then
      return 0
    fi
    sleep "$delay"
  done

  return 1
}

tmux_submit_wait_app_ready() {
  local tmux_target="$1"
  local attempts="${2:-12}"
  local delay="${3:-1}"
  local probe_attempts="${4:-6}"
  local attempt probe_try baseline capture

  for attempt in $(seq 1 "$attempts"); do
    if ! tmux_submit_wait_ready "$tmux_target" 1 0; then
      sleep "$delay"
      continue
    fi

    # Codex --no-alt-screen ignores empty Enter, so skip the Enter probe
    # and trust the prompt-ready check above.
    baseline="${TMUX_SUBMIT_LAST_CAPTURE:-$(tmux_submit__capture_recent "$tmux_target" 120)}"
    if printf '%s\n' "$baseline" | grep -q 'OpenAI Codex'; then
      return 0
    fi

    if ! tmux send-keys -t "$tmux_target" Enter 2>/dev/null; then
      return 1
    fi

    for probe_try in $(seq 1 "$probe_attempts"); do
      sleep 0.2
      capture="$(tmux_submit__capture_recent "$tmux_target" 120)"
      TMUX_SUBMIT_LAST_CAPTURE="$capture"
      if tmux_submit__capture_has_submission_progress "$capture"; then
        return 0
      fi
      if [ "$capture" != "$baseline" ] && tmux_submit__capture_has_prompt_ready "$capture"; then
        return 0
      fi
    done

    sleep "$delay"
  done

  return 1
}

tmux_submit_wait_for_prompt_ready() {
  tmux_submit_wait_ready "$@"
}

tmux_submit__tail_has_payload_at_end() {
  local capture="$1"
  local payload="$2"
  local match_mode="${3:-any}"
  local capture_trim capture_norm_trim payload_trim tail_line tail_pair
  capture_trim="$(tmux_submit__trim_trailing_ws "$capture")"
  capture_norm_trim="$(tmux_submit__trim_trailing_ws "$(tmux_submit__normalize_capture_for_match "$capture")")"
  payload_trim="$(tmux_submit__trim_trailing_ws "$payload")"

  [ -n "$payload_trim" ] || return 1
  if { [ "$match_mode" = "raw" ] || [ "$match_mode" = "any" ]; } && [[ "$capture_trim" == *"$payload_trim" ]]; then
    return 0
  fi
  if { [ "$match_mode" = "normalized" ] || [ "$match_mode" = "any" ]; } && [[ "$capture_norm_trim" == *"$payload_trim" ]]; then
    return 0
  fi

  tail_pair="$(tmux_submit__trim_trailing_ws "$(tmux_submit__payload_tail_pair "$payload")")"
  if [ -n "$tail_pair" ] && [ "${#tail_pair}" -ge 12 ]; then
    if { [ "$match_mode" = "raw" ] || [ "$match_mode" = "any" ]; } && [[ "$capture_trim" == *"$tail_pair" ]]; then
      return 0
    fi
    if { [ "$match_mode" = "normalized" ] || [ "$match_mode" = "any" ]; } && [[ "$capture_norm_trim" == *"$tail_pair" ]]; then
      return 0
    fi
  fi

  tail_line="$(tmux_submit__trim_trailing_ws "$(tmux_submit__payload_tail_line "$payload")")"
  [ -n "$tail_line" ] || return 1
  if { [ "$match_mode" = "raw" ] || [ "$match_mode" = "any" ]; } && [[ "$capture_trim" == *"$tail_line" ]]; then
    return 0
  fi
  if { [ "$match_mode" = "normalized" ] || [ "$match_mode" = "any" ]; } && [[ "$capture_norm_trim" == *"$tail_line" ]]; then
    return 0
  fi
  return 1
}

tmux_submit__literal_submit_single_line() {
  local tmux_target="$1"
  local payload="$2"
  local repeat_delay="${3:-1.0}"
  local max_repeat_enters="${4:-12}"
  local capture attempt

  if ! tmux send-keys -t "$tmux_target" -l -- "$payload" 2>/dev/null; then
    return 1
  fi

  for attempt in 1 2 3 4 5 6; do
    capture="$(tmux_submit__capture_recent "$tmux_target" 80)"
    if tmux_submit__capture_has_payload_anywhere "$capture" "$payload"; then
      break
    fi
    sleep 0.15
  done

  if ! tmux send-keys -t "$tmux_target" Enter 2>/dev/null; then
    return 1
  fi

  attempt=0
  while [ "$attempt" -lt "$max_repeat_enters" ]; do
    sleep "$repeat_delay"
    capture="$(tmux_submit__capture_recent "$tmux_target" 100)"
    TMUX_SUBMIT_LAST_CAPTURE="$capture"
    if tmux_submit__submission_confirmed "$capture"; then
      return 0
    fi
    if ! tmux_submit__capture_has_payload_anywhere "$capture" "$payload" && \
       ! tmux_submit__is_rich_tui_capture "$capture" && \
       tmux_submit__capture_has_prompt_ready "$capture"; then
      return 0
    fi
    if ! tmux send-keys -t "$tmux_target" Enter 2>/dev/null; then
      return 1
    fi
    attempt=$((attempt + 1))
  done

  capture="$(tmux_submit__capture_recent "$tmux_target" 100)"
  TMUX_SUBMIT_LAST_CAPTURE="$capture"
  tmux_submit__submission_confirmed "$capture"
}

tmux_submit__wait_for_payload_state() {
  local tmux_target="$1"
  local payload="$2"
  local expected_state="$3"  # visible | cleared
  local attempts="${4:-5}"
  local delay="${5:-0.25}"
  local lines capture
  lines="$(tmux_submit__capture_lines "$payload")"
  capture=""

  while [ "$attempts" -gt 0 ]; do
    capture="$(tmux_submit__capture_tail "$tmux_target" "$payload" "$lines")"
    if tmux_submit__tail_has_payload_at_end "$capture" "$payload" "$([ "$expected_state" = "cleared" ] && printf 'raw' || printf 'any')"; then
      if [ "$expected_state" = "visible" ]; then
        TMUX_SUBMIT_LAST_CAPTURE="$capture"
        return 0
      fi
    elif [ "$expected_state" = "cleared" ]; then
      TMUX_SUBMIT_LAST_CAPTURE="$capture"
      return 0
    fi
    attempts=$((attempts - 1))
    [ "$attempts" -gt 0 ] && sleep "$delay"
  done

  TMUX_SUBMIT_LAST_CAPTURE="$capture"
  return 1
}

tmux_submit__enter_until_cleared() {
  local tmux_target="$1"
  local payload="$2"
  local settle_attempts="${3:-12}"
  local settle_delay="${4:-0.35}"
  local repeat_delay="${5:-1.0}"
  local max_repeat_enters="${6:-12}"
  local sent_repeat_enters=0

  while :; do
    if tmux_submit__wait_for_payload_state "$tmux_target" "$payload" cleared "$settle_attempts" "$settle_delay"; then
      local confirm_capture="" lines confirm_attempts
      confirm_attempts=3
      lines="$(tmux_submit__capture_lines "$payload")"
      while [ "$confirm_attempts" -gt 0 ]; do
        sleep 0.15
        confirm_capture="$(tmux_submit__capture_tail "$tmux_target" "$payload" "$lines")"
        if tmux_submit__tail_has_payload_at_end "$confirm_capture" "$payload" raw; then
          break
        fi
        confirm_attempts=$((confirm_attempts - 1))
      done
      if [ "$confirm_attempts" -eq 0 ]; then
        TMUX_SUBMIT_LAST_CAPTURE="$confirm_capture"
        if tmux_submit__submission_confirmed "$confirm_capture"; then
          return 0
        fi
      fi
    fi

    if ! tmux_submit__target_exists "$tmux_target"; then
      return 1
    fi

    if [ "$sent_repeat_enters" -ge "$max_repeat_enters" ]; then
      return 1
    fi

    sleep "$repeat_delay"
    if ! tmux send-keys -t "$tmux_target" Enter 2>/dev/null; then
      return 1
    fi
    sent_repeat_enters=$((sent_repeat_enters + 1))
  done
}

tmux_submit_pasted_payload() {
  local tmux_target="$1"
  local payload="$2"
  local buf_prefix="${3:-tmux-submit}"
  local tmpfile buf_name

  if [[ "$payload" != *$'\n'* ]]; then
    tmux_submit__literal_submit_single_line "$tmux_target" "$payload" 2.0 8
    return
  fi

  tmpfile="$(mktemp)"
  printf '%s' "$payload" > "$tmpfile"
  buf_name="${buf_prefix}-$$-${RANDOM}"

  if ! tmux load-buffer -b "$buf_name" "$tmpfile" 2>/dev/null; then
    rm -f "$tmpfile"
    return 1
  fi

  if ! tmux paste-buffer -b "$buf_name" -t "$tmux_target" -dp 2>/dev/null; then
    tmux delete-buffer -b "$buf_name" 2>/dev/null || true
    rm -f "$tmpfile"
    return 1
  fi

  tmux delete-buffer -b "$buf_name" 2>/dev/null || true
  rm -f "$tmpfile"

  # 붙여넣은 내용이 pane 하단에 실제로 보일 때까지 대기한다.
  if ! tmux_submit__wait_for_payload_state "$tmux_target" "$payload" visible 8 0.15; then
    # Fallback: Claude Code TUI는 멀티라인 페이스트를 "[Pasted text #N +XX lines]"로
    # 접어서 표시한다. 이 경우 원본 텍스트 매칭이 불가능하므로, Rich TUI에서
    # [Pasted text 패턴이 보이면 붙여넣기 성공으로 간주한다.
    local fallback_capture
    fallback_capture="$(tmux_submit__capture_recent "$tmux_target" 20)"
    if ! tmux_submit__is_rich_tui_capture "$fallback_capture" || \
       ! printf '%s\n' "$fallback_capture" | grep -q '\[Pasted text'; then
      return 1
    fi
  fi

  if ! tmux send-keys -t "$tmux_target" Enter 2>/dev/null; then
    return 1
  fi

  tmux_submit__enter_until_cleared "$tmux_target" "$payload" 12 0.35 1.0 12
}
