#!/bin/bash
# deny-core-edits.sh — block Edit/Write/apply_patch tool calls that target
# files under the repo's core/ folder. Mirrors the Claude-side deny in
# .claude/settings.local.json for codex, which has no flat permissions.deny.

set -uo pipefail

INPUT="$(cat 2>/dev/null || echo '{}')"

json_get() {
  printf '%s' "$INPUT" | jq -r "$1" 2>/dev/null || true
}

HOOK_EVENT="$(json_get '.hook_event_name // empty')"
TOOL_NAME="$(json_get '.tool_name // empty')"
CWD="$(json_get '.cwd // empty')"
[ -z "$CWD" ] && CWD="$(pwd)"

REPO_ROOT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || echo "$CWD")"
CORE_DIR="$REPO_ROOT/core"
CORE_REAL="$(cd "$CORE_DIR" 2>/dev/null && pwd -P || echo "$CORE_DIR")"

[ "$HOOK_EVENT" = "PreToolUse" ] || exit 0

collect_paths() {
  case "$TOOL_NAME" in
    Edit|Write)
      json_get '.tool_input.file_path // empty'
      ;;
    apply_patch)
      json_get '.tool_input.input // empty' \
        | grep -E '^(\*\*\* (Add|Update|Delete) File:|--- |\+\+\+ )' \
        | sed -E 's/^\*\*\* (Add|Update|Delete) File: //; s|^--- a/||; s|^\+\+\+ b/||; s|^--- ||; s|^\+\+\+ ||' \
        | grep -v '^/dev/null$'
      ;;
    *)
      ;;
  esac
}

abs_path() {
  local p="$1"
  case "$p" in
    /*) printf '%s\n' "$p" ;;
    *)  printf '%s/%s\n' "$REPO_ROOT" "$p" ;;
  esac
}

is_under_core() {
  local p; p="$(abs_path "$1")"
  case "$p" in
    "$CORE_DIR"/*|"$CORE_REAL"/*) return 0 ;;
  esac
  return 1
}

while IFS= read -r path; do
  [ -z "$path" ] && continue
  if is_under_core "$path"; then
    jq -nc --arg msg "Edits to core/ are denied by deny-core-edits.sh ($path)." \
      '{decision:"block", reason:$msg, hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"deny", permissionDecisionReason:$msg}}'
    exit 0
  fi
done < <(collect_paths)

exit 0
