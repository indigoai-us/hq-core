#!/usr/bin/env bash
# hq-core: public
# PostToolUse: atomically bump toolWrites for file-writing tools (US-010).
# Hot path exits before any mkdir when the tool is not a write.
set -uo pipefail

case "${HQ_WORK_MESH_DISABLED:-}" in 1|true|TRUE|yes|YES|on|ON) exit 0 ;; esac
case ",${HQ_DISABLED_HOOKS:-}," in *,work-mesh,*|*,work-mesh-live,*|*,\*,*) exit 0 ;; esac

INPUT=""
IFS= read -r -d '' INPUT || true
[ -n "$INPUT" ] || INPUT='{}'

_wm_json_str() {
  local json=$1 key=$2 rest
  REPLY=
  local needle="\"$key\""
  case "$json" in
    *"$needle"*)
      rest="${json#*"$needle"}"
      rest="${rest#*:}"
      while [ "${rest#"${rest%%[![:space:]]*}"}" != "$rest" ]; do rest="${rest#?}"; done
      case "$rest" in
        \"*) rest="${rest#\"}"; REPLY="${rest%%\"*}" ;;
      esac
      ;;
  esac
}

TOOL=""
_wm_json_str "$INPUT" tool_name; TOOL=$REPLY
[ -n "$TOOL" ] || { _wm_json_str "$INPUT" toolName; TOOL=$REPLY; }

IS_WRITE=0
CMD=""
case "$TOOL" in
  Edit|Write|MultiEdit|NotebookEdit|apply_patch|StrReplace|search_replace|write) IS_WRITE=1 ;;
  Bash|Shell|run_terminal_command)
    _wm_json_str "$INPUT" command; CMD=$REPLY
    case "$CMD" in *\>*|*tee\ *|*mv\ *|*cp\ *|*truncate\ *|*sed\ -i*|*dd\ if=*) IS_WRITE=1 ;; esac
    ;;
esac
[ "$IS_WRITE" -eq 1 ] || exit 0

SID="${HQ_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-${CODEX_SESSION_ID:-${CODEX_THREAD_ID:-}}}}}"
SID="${SID//[[:space:]]/}"
if [ -z "$SID" ]; then
  _wm_json_str "$INPUT" session_id; SID=$REPLY
  [ -n "$SID" ] || { _wm_json_str "$INPUT" sessionId; SID=$REPLY; }
  SID="${SID//[[:space:]]/}"
fi
[ -n "$SID" ] || exit 0

# Merge-safe bump via the shared helper: only toolWrites and updatedAt change;
# companyUid/companySlug/projectId/taskId/startedAt/bindingEpisodeId/decision/
# contextStatus written by the hq-cli reconcile/ack path are preserved. The
# helper creates the minimal stub when the file is absent, keeps temp+mv and
# chmod 600, and leaves a file it cannot parse untouched.
HOOK_FILE="${BASH_SOURCE[0]}"
if [ -z "${HQ_ROOT:-}" ]; then
  HQ_ROOT="$(cd "${HOOK_FILE%/*}/../../.." 2>/dev/null && pwd)" || exit 0
fi
# shellcheck source=core/scripts/lib/work-mesh-live-hook.sh
. "$HQ_ROOT/core/scripts/lib/work-mesh-live-hook.sh" 2>/dev/null || exit 0
work_mesh_live_bump_tool_writes "$SID" || true
exit 0
