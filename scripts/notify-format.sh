#!/bin/bash
# notify-format.sh -- 알림 포맷팅 공통 함수
# message.sh, monitor.sh에서 source된다.

# 파이프 문자 이스케이프 (알림 구분자 충돌 방지)
_escape_pipe() {
  printf '%s' "$1" | tr '|' '∣'
}

build_notification() {
  local msg_from="$1"
  local msg_to="$2"
  local msg_kind="$3"
  local msg_priority="$4"
  local msg_subject="$5"
  local msg_content="$6"
  local flat_subject flat_content
  local prefix="[notify] ${msg_from} → ${msg_to} | ${msg_kind}"
  if [ "$msg_priority" = "urgent" ]; then
    prefix="[URGENT] ${msg_from} → ${msg_to} | ${msg_kind}"
  fi
  flat_subject="$(_escape_pipe "$(printf '%s' "$msg_subject" | tr '\r\n' '  ')")"
  if [ "$msg_kind" = "user_notice" ] || { [ "$msg_kind" = "status_update" ] && { [ "$msg_to" = "manager" ] || [ "$msg_to" = "user" ]; }; }; then
    printf '%s | 제목: %s\n%s' "$prefix" "$flat_subject" "$msg_content"
    return 0
  fi
  flat_content="$(_escape_pipe "$(printf '%s' "$msg_content" | tr '\r\n' '  ')")"
  printf '%s' "${prefix} | 제목: ${flat_subject} | 내용: ${flat_content}"
}

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
