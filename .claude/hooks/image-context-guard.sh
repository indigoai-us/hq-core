#!/bin/bash
# image-context-guard.sh — PreToolUse hook (Read / view_image).
#
# Cost is driven by image *bytes*, not image count. A six-image call that
# inlines tens of megabytes is policy-compliant under a count cap and still
# blows the context window. This hook is the mechanical control for
# core/policies/image-context-isolation.md:
#   - deny a local image over HQ_IMAGE_MAX_BYTES (default 2 MiB)
#   - deny Codex detail=original (full-resolution inline)
#   - deny more than one image path in a single call
#   - deny more than HQ_IMAGE_MAX_COUNT (default 8) distinct images per session
#
# Allows:
#   - non-image reads
#   - missing files (the tool will fail on its own)
#   - HQ_ALLOW_INLINE_IMAGE=1, or the literal token ALLOW_INLINE_IMAGE in the payload
#
# Fails open when the payload cannot be read or the tool is not an image read.
# Exit 2 blocks. python-free.
#
# Backs policy hq-image-context-isolation.

set -uo pipefail

STDIN_JSON="$(cat 2>/dev/null || echo '{}')"

self_src="${BASH_SOURCE[0]:-$0}"
ROOT="$(cd "$(dirname "$self_src")/../.." 2>/dev/null && pwd)"
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$CLAUDE_PROJECT_DIR" ]; then
  ROOT="$CLAUDE_PROJECT_DIR"
elif [ -n "${HQ_ROOT:-}" ] && [ -d "$HQ_ROOT" ]; then
  ROOT="$HQ_ROOT"
fi

if [ -f "$ROOT/core/scripts/hook-lib.sh" ]; then
  # shellcheck source=core/scripts/hook-lib.sh
  . "$ROOT/core/scripts/hook-lib.sh"
fi

MAX_BYTES="${HQ_IMAGE_MAX_BYTES:-2097152}"
MAX_COUNT="${HQ_IMAGE_MAX_COUNT:-8}"
case "$MAX_BYTES" in ''|*[!0-9]*) MAX_BYTES=2097152 ;; esac
case "$MAX_COUNT" in ''|*[!0-9]*) MAX_COUNT=8 ;; esac

case "${HQ_ALLOW_INLINE_IMAGE:-0}" in
  1|true|TRUE|yes|YES) exit 0 ;;
esac
case "$STDIN_JSON" in
  *ALLOW_INLINE_IMAGE*) exit 0 ;;
esac

if [ "${HQ_HOOK_TOOL_NAME+set}" = "set" ]; then
  TOOL="$HQ_HOOK_TOOL_NAME"
elif command -v hq_json_get >/dev/null 2>&1; then
  TOOL="$(printf '%s' "$STDIN_JSON" | hq_json_get tool_name)"
  [ -z "$TOOL" ] && TOOL="$(printf '%s' "$STDIN_JSON" | hq_json_get toolName)"
else
  TOOL="$(printf '%s' "$STDIN_JSON" | jq -r '.tool_name // .toolName // empty' 2>/dev/null || true)"
fi

json_field() {
  local key="$1" value=""
  if command -v hq_json_get >/dev/null 2>&1; then
    value="$(printf '%s' "$STDIN_JSON" | hq_json_get "$key")"
  fi
  if [ -z "$value" ]; then
    value="$(printf '%s' "$STDIN_JSON" | jq -r --arg k "$key" '
      ($k | split(".")) as $p
      | getpath($p) // empty
      | if . == null then empty else tostring end
    ' 2>/dev/null || true)"
  fi
  printf '%s' "$value"
}

# Hygiene/cost guard: a dispatcher mismatch must not brick unrelated tools.
case "$TOOL" in
  Read|view_image|ViewImage|view_file) ;;
  '')
    # Empty tool name: still inspect a path that looks like an image, otherwise
    # fail open.
    ;;
  *)
    exit 0
    ;;
esac

PATH_PARAM="$(json_field tool_input.file_path)"
[ -z "$PATH_PARAM" ] && PATH_PARAM="$(json_field tool_input.path)"
[ -z "$PATH_PARAM" ] && PATH_PARAM="$(json_field tool_input.image_path)"
[ -z "$PATH_PARAM" ] && PATH_PARAM="$(json_field toolInput.file_path)"
[ -z "$PATH_PARAM" ] && PATH_PARAM="$(json_field toolInput.path)"

DETAIL="$(json_field tool_input.detail)"
[ -z "$DETAIL" ] && DETAIL="$(json_field toolInput.detail)"

image_file_size() {
  local f="$1" value
  [ -n "$f" ] && [ -f "$f" ] || return 1
  value="$(stat -f %z "$f" 2>/dev/null)" || value=""
  case "$value" in
    ''|*[!0-9]*) ;;
    *) printf '%s' "$value"; return 0 ;;
  esac
  value="$(stat -c %s "$f" 2>/dev/null)" || value=""
  case "$value" in
    ''|*[!0-9]*) return 1 ;;
    *) printf '%s' "$value"; return 0 ;;
  esac
}

is_image_path() {
  local p="$1" lower
  lower="$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *.png|*.jpg|*.jpeg|*.gif|*.webp) return 0 ;;
    *) return 1 ;;
  esac
}

block_msg() {
  cat >&2 <<EOF
Blocked: $1

Inline image cost is bytes, not count. Delegate inspection to a sub-agent
(text findings only), or resize first:

  bash core/scripts/resize-screenshot.sh <path>

Escape hatch: HQ_ALLOW_INLINE_IMAGE=1, or the literal token ALLOW_INLINE_IMAGE.
EOF
}

# Codex original-resolution inline is unbounded even for a "small" file.
case "$DETAIL" in
  original|Original|ORIGINAL)
    block_msg "image detail=original inlines full-resolution bytes"
    exit 2
    ;;
esac

MULTI=0
if command -v jq >/dev/null 2>&1; then
  MULTI="$(printf '%s' "$STDIN_JSON" | jq -r '
    [.tool_input.images, .tool_input.paths, .toolInput.images, .toolInput.paths]
    | map(select(type == "array"))
    | map(length)
    | max // 0
  ' 2>/dev/null || echo 0)"
fi
case "$MULTI" in ''|*[!0-9]*) MULTI=0 ;; esac
if [ "$MULTI" -gt 1 ]; then
  block_msg "this call inlines $MULTI images; one image per call, then delegate"
  exit 2
fi

[ -n "$PATH_PARAM" ] || exit 0
is_image_path "$PATH_PARAM" || exit 0

# Missing files: the Read/view itself will fail. Do not block on size we cannot
# measure, and do not consume a session slot for a no-op.
if [ ! -f "$PATH_PARAM" ]; then
  exit 0
fi

SIZE="$(image_file_size "$PATH_PARAM" || true)"
case "$SIZE" in ''|*[!0-9]*) SIZE=0 ;; esac
if [ "$SIZE" -gt "$MAX_BYTES" ]; then
  mb="$(awk -v s="$SIZE" 'BEGIN { printf "%.1f", s / 1048576 }')"
  cap="$(awk -v s="$MAX_BYTES" 'BEGIN { printf "%.1f", s / 1048576 }')"
  name="${PATH_PARAM##*/}"
  block_msg "$name is ${mb}MB, over the ${cap}MB inline-image limit"
  exit 2
fi

SESSION_KEY="session"
if command -v hq_hook_session_key_from_payload >/dev/null 2>&1; then
  SESSION_KEY="$(hq_hook_session_key_from_payload "$STDIN_JSON")"
fi
STATE_ROOT="$ROOT/workspace/orchestrator/hook-state"
if command -v hq_hook_state_dir >/dev/null 2>&1; then
  STATE_ROOT="$(hq_hook_state_dir "$ROOT")"
fi
LEDGER_DIR="$STATE_ROOT/image-context/$SESSION_KEY"
LEDGER="$LEDGER_DIR/reads.txt"
mkdir -p "$LEDGER_DIR" 2>/dev/null || true

NORM="$PATH_PARAM"
if command -v hq_normpath >/dev/null 2>&1; then
  NORM="$(hq_normpath "$PATH_PARAM")"
fi

if [ -f "$LEDGER" ] && grep -F -x -q -- "$NORM" "$LEDGER" 2>/dev/null; then
  exit 0
fi

COUNT=0
if [ -f "$LEDGER" ]; then
  COUNT="$(grep -c . "$LEDGER" 2>/dev/null || true)"
fi
case "$COUNT" in ''|*[!0-9]*) COUNT=0 ;; esac
if [ "$COUNT" -ge "$MAX_COUNT" ]; then
  block_msg "this session already inlined $COUNT images (limit $MAX_COUNT). Delegate further inspection"
  exit 2
fi

printf '%s\n' "$NORM" >>"$LEDGER" 2>/dev/null || true
exit 0
