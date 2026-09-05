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

WC_HOME="${WORK_MESH_HOME:-$HOME}"
PATH_JSON="$WC_HOME/.hq/work-context/sessions/$SID.json"
DIR_JSON="${PATH_JSON%/*}"
if [ ! -d "$DIR_JSON" ]; then
  mkdir -p -- "$DIR_JSON" 2>/dev/null || true
  chmod 700 -- "$DIR_JSON" 2>/dev/null || true
fi
CUR=0
if [ -f "$PATH_JSON" ]; then
  _body="$(<"$PATH_JSON")"
  case "$_body" in
    *"\"toolWrites\""*)
      _rest="${_body#*\"toolWrites\"}"
      _rest="${_rest#*:}"
      while [ "${_rest#"${_rest%%[![:space:]]*}"}" != "$_rest" ]; do _rest="${_rest#?}"; done
      CUR="${_rest%%[!0-9]*}"
      ;;
  esac
fi
case "$CUR" in ""|*[!0-9]*) CUR=0 ;; esac
NEXT=$((CUR + 1))
TMP="$PATH_JSON.tmp.$$"
if ! TZ=UTC printf -v TS '%(%Y-%m-%dT%H:%M:%S)T.000Z' -1 2>/dev/null; then
  TS=""
fi
[ -n "$TS" ] || TS="1970-01-01T00:00:00.000Z"
printf '{"contractVersion":1,"sessionId":"%s","contextStatus":"unresolved","toolWrites":%s,"updatedAt":"%s"}\n' "$SID" "$NEXT" "$TS" >"$TMP"
mv -f -- "$TMP" "$PATH_JSON" 2>/dev/null || rm -f -- "$TMP"
chmod 600 -- "$PATH_JSON" 2>/dev/null || true
exit 0
