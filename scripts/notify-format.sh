#!/bin/bash

whiplash_notification_subject() {
  local kind="$1"
  local subject="$2"
  local flat

  flat="$(printf '%s' "$subject" | tr '\r\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
  if [ "$kind" = "user_notice" ] || [ "$kind" = "status_update" ]; then
    if [ "${#flat}" -gt 72 ]; then
      flat="${flat:0:69}..."
    fi
  fi

  printf '%s' "$flat"
}

whiplash_notification_body() {
  local kind="$1"
  local subject="$2"
  local content="$3"
  local lines=()
  local line

  if [ "$kind" != "user_notice" ] && [ "$kind" != "status_update" ]; then
    printf '%s' "$content"
    return 0
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    line="$(printf '%s' "$line" | tr '\r' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
    [ -n "$line" ] || continue
    lines+=("$line")
  done <<< "$content"

  if [ "${#lines[@]}" -ge 2 ] && [ "${#lines[@]}" -le 4 ]; then
    printf '%s\n' "${lines[@]}"
    return 0
  fi

  if [ "${#lines[@]}" -gt 4 ]; then
    printf '%s\n' "${lines[@]:0:4}"
    return 0
  fi

  local change_line="업데이트 없음"
  if [ "${#lines[@]}" -eq 1 ]; then
    change_line="${lines[0]}"
  fi

  printf '현재 상태: %s\n변경점: %s\n다음 행동: 확인 후 계속 진행' "$subject" "$change_line"
}
