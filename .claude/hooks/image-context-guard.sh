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
#   - per agent context, deny a new image once the distinct images already
#     inlined there would push the context past HQ_IMAGE_BUDGET_BYTES
#     (default 8 MiB). Each image is charged its file size, with a floor of
#     HQ_IMAGE_MIN_COST_BYTES (default 64 KiB), so small screenshots cost
#     little and 2 MiB images cost a lot.
#   - per agent context, deny more than HQ_IMAGE_MAX_COUNT (default 32)
#     distinct images, as a ceiling on many tiny images
#
# Agent context: the parent session and each sub-agent keep separate ledgers.
# Claude Code sends agent_id on hook events fired inside a sub-agent (and
# master-hook.sh exports it as HQ_HOOK_AGENT_ID). A sub-agent's image lives in
# its own context window, so it must not spend the parent's budget; that would
# block the delegation route this guard recommends. The payload's agent_id
# wins over an empty HQ_HOOK_AGENT_ID, and a payload with no agent_id but a
# sub-agent transcript_path (<session>/subagents/agent-<id>.jsonl) is charged
# to that sub-agent. A host that runs
# sub-agents under their own session or thread id gets separate ledgers
# through the session key. agent_type alone is not used: manual --agent
# main-thread sessions carry it too.
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
BUDGET_BYTES="${HQ_IMAGE_BUDGET_BYTES:-8388608}"
MIN_COST="${HQ_IMAGE_MIN_COST_BYTES:-65536}"
MAX_COUNT="${HQ_IMAGE_MAX_COUNT:-32}"
case "$MAX_BYTES" in ''|*[!0-9]*) MAX_BYTES=2097152 ;; esac
case "$BUDGET_BYTES" in ''|*[!0-9]*) BUDGET_BYTES=8388608 ;; esac
case "$MIN_COST" in ''|*[!0-9]*) MIN_COST=65536 ;; esac
case "$MAX_COUNT" in ''|*[!0-9]*) MAX_COUNT=32 ;; esac

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

Inline image cost is bytes, not count. Options:

  - Delegate: spawn a sub-agent (Agent tool, or Codex spawn_agent) with the
    image paths and ask for text findings only.
    Each sub-agent has its own image budget; its reads do not count here.
  - Resize first: bash core/scripts/resize-screenshot.sh <path>
  - Text only: OCR the image (macOS Vision, tesseract, Windows OCR) instead
    of inlining it.

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
# Agent context. The payload decides. master-hook.sh exports HQ_HOOK_AGENT_ID
# from the same payload, but an empty value inherited from an outer process
# must not send a sub-agent read to the parent ledger. Order: payload
# agent_id/agentId, a non-empty HQ_HOOK_AGENT_ID, then a sub-agent transcript
# path (<session>/subagents/agent-<id>.jsonl) for a host that omits agent_id.
AGENT_ID=""
TRANSCRIPT=""
if command -v jq >/dev/null 2>&1; then
  AGENT_FIELDS="$(printf '%s' "$STDIN_JSON" | jq -r '
    def str: if type == "string" then . elif type == "number" then tostring else "" end;
    [ ((.agent_id | str) as $a | if $a != "" then $a else (.agentId | str) end),
      ((.transcript_path | str) as $t | if $t != "" then $t else (.transcriptPath | str) end) ]
    | map(gsub("[\t\n]"; " ")) | join("\t")
  ' 2>/dev/null || true)"
  case "$AGENT_FIELDS" in
    *"	"*) AGENT_ID="${AGENT_FIELDS%%	*}"; TRANSCRIPT="${AGENT_FIELDS#*	}" ;;
  esac
else
  AGENT_ID="$(json_field agent_id)"
  [ -z "$AGENT_ID" ] && AGENT_ID="$(json_field agentId)"
  TRANSCRIPT="$(json_field transcript_path)"
  [ -z "$TRANSCRIPT" ] && TRANSCRIPT="$(json_field transcriptPath)"
fi
[ -z "$AGENT_ID" ] && AGENT_ID="${HQ_HOOK_AGENT_ID:-}"
if [ -z "$AGENT_ID" ]; then
  TRANSCRIPT_BASE="${TRANSCRIPT##*/}"
  case "$TRANSCRIPT" in
    */subagents/"$TRANSCRIPT_BASE")
      case "$TRANSCRIPT_BASE" in
        agent-?*.jsonl)
          AGENT_ID="${TRANSCRIPT_BASE#agent-}"
          AGENT_ID="${AGENT_ID%.jsonl}"
          ;;
      esac
      ;;
  esac
fi
if [ -n "$AGENT_ID" ]; then
  AGENT_KEY="$(printf '%s' "$AGENT_ID" | tr -c 'A-Za-z0-9._-' '_')"
  AGENT_KEY="${AGENT_KEY:0:96}"
  # "." or ".." would put the ledger in agents/ or back on the parent.
  case "$AGENT_KEY" in .|..) AGENT_KEY="_$AGENT_KEY" ;; esac
  # The parent keeps the original ledger path; each sub-agent gets its own.
  LEDGER_DIR="$STATE_ROOT/image-context/$SESSION_KEY/agents/$AGENT_KEY"
  CONTEXT_LABEL="this sub-agent"
else
  LEDGER_DIR="$STATE_ROOT/image-context/$SESSION_KEY"
  CONTEXT_LABEL="this session (parent context)"
fi
LEDGER="$LEDGER_DIR/reads.txt"
mkdir -p "$LEDGER_DIR" 2>/dev/null || true

NORM="$PATH_PARAM"
if command -v hq_normpath >/dev/null 2>&1; then
  NORM="$(hq_normpath "$PATH_PARAM")"
fi

COST="$SIZE"
[ "$COST" -lt "$MIN_COST" ] && COST="$MIN_COST"

# Ledger lines are "<charged bytes><TAB><normalized path>". Lines written by
# the older count-only guard hold a bare path; charge them the floor cost.
SEEN=0
COUNT=0
USED=0
if [ -f "$LEDGER" ]; then
  stats="$(awk -F '\t' -v want="$NORM" -v floor="$MIN_COST" '
    NF == 0 || $0 == "" { next }
    {
      if (NF >= 2 && $1 ~ /^[0-9]+$/) { cost = $1 + 0; p = substr($0, length($1) + 2) }
      else { cost = floor + 0; p = $0 }
      if (p == want) seen = 1
      n += 1; used += cost
    }
    END { printf "%d %d %d", seen + 0, n + 0, used + 0 }
  ' "$LEDGER" 2>/dev/null || true)"
  read -r SEEN COUNT USED <<EOF
$stats
EOF
fi
case "$SEEN" in ''|*[!0-9]*) SEEN=0 ;; esac
case "$COUNT" in ''|*[!0-9]*) COUNT=0 ;; esac
case "$USED" in ''|*[!0-9]*) USED=0 ;; esac

# Re-reading an image already charged to this context costs nothing new.
[ "$SEEN" -eq 1 ] && exit 0

if [ "$COUNT" -ge "$MAX_COUNT" ]; then
  block_msg "$CONTEXT_LABEL already inlined $COUNT distinct images (limit $MAX_COUNT)"
  exit 2
fi

if [ $((USED + COST)) -gt "$BUDGET_BYTES" ]; then
  used_mb="$(awk -v s="$USED" 'BEGIN { printf "%.1f", s / 1048576 }')"
  cost_mb="$(awk -v s="$COST" 'BEGIN { printf "%.2f", s / 1048576 }')"
  budget_mb="$(awk -v s="$BUDGET_BYTES" 'BEGIN { printf "%.1f", s / 1048576 }')"
  block_msg "$CONTEXT_LABEL already inlined ${used_mb}MB of images across $COUNT files; ${PATH_PARAM##*/} (${cost_mb}MB) would pass the ${budget_mb}MB image budget"
  exit 2
fi

printf '%s\t%s\n' "$COST" "$NORM" >>"$LEDGER" 2>/dev/null || true
exit 0
