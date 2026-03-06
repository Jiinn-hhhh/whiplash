#!/bin/bash
# tmux-submit.sh -- tmux pane에 붙여넣은 입력이 실제 제출되었는지 확인하는 헬퍼
#
# 전략:
#   1. payload를 tmux buffer로 붙여넣는다.
#   2. pane tail을 캡처해서 payload가 입력창 하단에 실제로 들어갔는지 확인한다.
#   3. Enter를 보내고, payload가 pane 하단 draft에서 사라질 때까지 계속 확인한다.
#   4. draft가 그대로 남아 있으면 잠시 기다렸다가 Enter를 다시 보낸다.
#   5. tmux target이 사라지지 않는 한, 제출될 때까지 반복한다.

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

tmux_submit__tail_has_payload_at_end() {
  local capture="$1"
  local payload="$2"
  local capture_trim capture_norm_trim payload_trim
  capture_trim="$(tmux_submit__trim_trailing_ws "$capture")"
  capture_norm_trim="$(tmux_submit__trim_trailing_ws "$(tmux_submit__normalize_capture_for_match "$capture")")"
  payload_trim="$(tmux_submit__trim_trailing_ws "$payload")"

  [ -n "$payload_trim" ] || return 1
  [[ "$capture_trim" == *"$payload_trim" ]] || [[ "$capture_norm_trim" == *"$payload_trim" ]]
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
    if tmux_submit__tail_has_payload_at_end "$capture" "$payload"; then
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
  local settle_attempts="${3:-8}"
  local settle_delay="${4:-0.25}"
  local repeat_delay="${5:-0.9}"

  while :; do
    if tmux_submit__wait_for_payload_state "$tmux_target" "$payload" cleared "$settle_attempts" "$settle_delay"; then
      return 0
    fi

    if ! tmux_submit__target_exists "$tmux_target"; then
      return 1
    fi

    sleep "$repeat_delay"
    if ! tmux send-keys -t "$tmux_target" Enter 2>/dev/null; then
      return 1
    fi
  done
}

tmux_submit_pasted_payload() {
  local tmux_target="$1"
  local payload="$2"
  local buf_prefix="${3:-tmux-submit}"
  local tmpfile buf_name

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
  if ! tmux_submit__wait_for_payload_state "$tmux_target" "$payload" visible 5 0.12; then
    return 1
  fi

  if ! tmux send-keys -t "$tmux_target" Enter 2>/dev/null; then
    return 1
  fi

  tmux_submit__enter_until_cleared "$tmux_target" "$payload" 8 0.25 0.9
}
