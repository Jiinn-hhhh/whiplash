#!/bin/bash

whiplash_queue_flatten_preview() {
  printf '%s' "$1" | tr '\r\n' '  ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//'
}

whiplash_queue_encode() {
  python3 -c 'import base64, sys; sys.stdout.write(base64.b64encode(sys.stdin.buffer.read()).decode("ascii"))'
}

whiplash_queue_decode() {
  python3 -c 'import base64, sys; data = sys.stdin.read().strip(); sys.stdout.buffer.write(base64.b64decode(data) if data else b"")'
}

whiplash_queue_write_file() {
  local target_path="$1"
  local msg_from="$2"
  local msg_to="$3"
  local msg_kind="$4"
  local msg_priority="$5"
  local msg_subject="$6"
  local msg_content="$7"
  local content_preview content_b64

  content_preview="$(whiplash_queue_flatten_preview "$msg_content")"
  content_b64="$(printf '%s' "$msg_content" | whiplash_queue_encode)"

  # M-05: subject 뉴라인을 공백으로 치환 (단일 행 필드 보장)
  local safe_subject
  safe_subject="$(printf '%s' "$msg_subject" | tr '\r\n' '  ')"

  cat > "$target_path" <<MSGEOF
from=${msg_from}
to=${msg_to}
kind=${msg_kind}
priority=${msg_priority}
subject=${safe_subject}
content=${content_preview}
content_b64=${content_b64}
MSGEOF
}

whiplash_queue_read_field() {
  local msg_file="$1"
  local field_name="$2"
  grep "^${field_name}=" "$msg_file" 2>/dev/null | head -1 | sed "s/^${field_name}=//"
}

whiplash_queue_read_content() {
  local msg_file="$1"
  local encoded
  encoded="$(whiplash_queue_read_field "$msg_file" "content_b64")"
  if [ -n "$encoded" ]; then
    printf '%s' "$encoded" | whiplash_queue_decode
    return 0
  fi

  whiplash_queue_read_field "$msg_file" "content"
}
