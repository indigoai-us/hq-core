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
# Library always comes from this hook's tree. HQ_ROOT is the companies/ tree
# (tests point it at a sandbox); when unset it is the same tree.
HOOK_FILE="${BASH_SOURCE[0]}"
LIB_ROOT="$(cd "${HOOK_FILE%/*}/../../.." 2>/dev/null && pwd)" || exit 0
if [ -z "${HQ_ROOT:-}" ]; then
  HQ_ROOT="$LIB_ROOT"
fi
# shellcheck source=core/scripts/lib/work-mesh-live-hook.sh
. "$LIB_ROOT/core/scripts/lib/work-mesh-live-hook.sh" 2>/dev/null || exit 0
work_mesh_live_bump_tool_writes "$SID" || true

# US-040: path-based bind + PRD sync. Bash/Shell redirects stay a counter bump
# only — the written path is not in the tool input.
case "$TOOL" in
  Bash|Shell|run_terminal_command) exit 0 ;;
esac

_wm_json_str "$INPUT" file_path; FILE=$REPLY
[ -n "$FILE" ] || exit 0

# Reject traversal. Accept absolute paths under HQ_ROOT, or paths relative to it.
case "$FILE" in
  *..*) exit 0 ;;
esac
case "$FILE" in
  "$HQ_ROOT"/*) REL="${FILE#"$HQ_ROOT"/}" ;;
  /*) exit 0 ;;
  *) REL="$FILE" ;;
esac
case "$REL" in
  ./*) REL="${REL#./}" ;;
esac

# companies/<co>/projects/<slug>/<rest>
case "$REL" in
  companies/*/*) ;;
  *) exit 0 ;;
esac
_rest="${REL#companies/}"
CO="${_rest%%/*}"
_rest="${_rest#*/}"
case "$CO" in
  ""|*[!A-Za-z0-9._-]*) exit 0 ;;
esac
case "$_rest" in
  projects/*/*) ;;
  *) exit 0 ;;
esac
_rest="${_rest#projects/}"
SLUG="${_rest%%/*}"
TAIL="${_rest#*/}"
case "$SLUG" in
  ""|*[!A-Za-z0-9._-]*) exit 0 ;;
esac

STATE="$(work_mesh_live_state_path "$SID")"
[ -f "$STATE" ] || exit 0
STATE_BODY=""
IFS= read -r -d '' STATE_BODY <"$STATE" || true
[ -n "$STATE_BODY" ] || exit 0
_wm_json_str "$STATE_BODY" companySlug; SESS_CO=$REPLY
[ -n "$SESS_CO" ] || exit 0
[ "$SESS_CO" = "$CO" ] || exit 0
_wm_json_str "$STATE_BODY" contextStatus; SESS_STATUS=$REPLY
_wm_json_str "$STATE_BODY" projectId; SESS_PID=$REPLY
_wm_json_str "$STATE_BODY" projectSlug; SESS_PSLUG=$REPLY

SHOULD_BIND=0
if [ "$SESS_STATUS" = "needs_project" ] || [ -z "$SESS_PID" ]; then
  SHOULD_BIND=1
fi
IS_THIS=0
if [ "$SHOULD_BIND" -eq 1 ] || [ "$SESS_PID" = "$SLUG" ] || [ "$SESS_PSLUG" = "$SLUG" ]; then
  IS_THIS=1
fi
# F14: same-company other-project prd.json still reaches prd-sync. hq-cli
# rebinds the session (PR 759). Other files in another project stay skipped.
# Cross-company already exited above.
[ "$IS_THIS" -eq 1 ] || [ "$TAIL" = "prd.json" ] || exit 0

WM_DIR="${STATE%/*}"
WM_LOG="$WM_DIR/${SID}.wm-mesh.log"

# A flight lock is busy while its worker pid is alive, or for a few seconds
# before that pid file exists. A dead pid or an abandoned lock is reclaimed.
_wm_mtime() {
  if stat -f %m "$1" >/dev/null 2>&1; then
    stat -f %m "$1"
  else
    stat -c %Y "$1" 2>/dev/null || echo 0
  fi
}
_wm_flight_busy() {
  # $1 lock  $2 pidfile. Return 0 when a live flight holds the lock.
  local lock="$1" pidf="$2" holder now mt
  [ -f "$lock" ] || return 1
  holder="$(cat "$pidf" 2>/dev/null || true)"
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
    return 0
  fi
  if [ -z "$holder" ]; then
    now=$(date +%s)
    mt="$(_wm_mtime "$lock")"
    if [ $((now - mt)) -lt 15 ]; then
      return 0
    fi
  fi
  rm -f -- "$lock" "$pidf"
  return 1
}

if [ "$SHOULD_BIND" -eq 1 ]; then
  MARKER="$WM_DIR/${SID}.wm-bind-${SLUG}"
  BACKOFF="$WM_DIR/${SID}.wm-bind-${SLUG}.backoff"
  BIND_LOCK="$WM_DIR/${SID}.wm-bind-${SLUG}.lock"
  BIND_PID="$WM_DIR/${SID}.wm-bind-${SLUG}.pid"
  # Success marker only. A failed bind leaves a backoff epoch instead, so a
  # later write in this session retries after that instant.
  if [ ! -f "$MARKER" ]; then
    _wm_bind_skip=0
    if [ -f "$BACKOFF" ]; then
      _wm_until="$(cat "$BACKOFF" 2>/dev/null || echo 0)"
      _wm_now=$(date +%s)
      if [ "${_wm_until:-0}" -gt "${_wm_now:-0}" ] 2>/dev/null; then
        _wm_bind_skip=1
      fi
    fi
    if [ "$_wm_bind_skip" -eq 0 ] && _wm_flight_busy "$BIND_LOCK" "$BIND_PID"; then
      _wm_bind_skip=1
    fi
    if [ "$_wm_bind_skip" -eq 0 ]; then
      if ( set -o noclobber; : >"$BIND_LOCK" ) 2>/dev/null; then
        HQ_WM_BIND_MARKER="$MARKER" \
        HQ_WM_BIND_BACKOFF="$BACKOFF" \
        HQ_WM_BIND_LOCK="$BIND_LOCK" \
        HQ_WM_BIND_SLUG="$SLUG" \
        HQ_WM_BIND_SID="$SID" \
        nohup bash -c '
          trap "rm -f -- \"\$HQ_WM_BIND_LOCK\"" EXIT
          _sec="${HQ_WM_BIND_BACKOFF_SEC:-15}"
          case "$_sec" in
            ""|*[!0-9]*) _sec=15 ;;
          esac
          if hq mesh context bind-project "$HQ_WM_BIND_SLUG" --session "$HQ_WM_BIND_SID" --json; then
            : >"$HQ_WM_BIND_MARKER"
            rm -f -- "$HQ_WM_BIND_BACKOFF"
          else
            printf "%s\n" "$(( $(date +%s) + _sec ))" >"$HQ_WM_BIND_BACKOFF"
          fi
        ' >>"$WM_LOG" 2>&1 &
        echo $! >"$BIND_PID"
      fi
    fi
  fi
fi

if [ "$TAIL" = "prd.json" ]; then
  _wm_prd_sync_supported() {
    local base ver cache ans
    base="${WORK_MESH_HOME:-$HOME}"
    ver="$(hq --version 2>/dev/null | head -n 1)"
    ver="${ver//[^A-Za-z0-9._-]/_}"
    [ -n "$ver" ] || ver="unknown"
    cache="$base/.hq/work-context/prd-sync-probe-${ver}"
    if [ -f "$cache" ]; then
      ans="$(cat "$cache" 2>/dev/null || true)"
      [ "$ans" = "yes" ]
      return
    fi
    mkdir -p -- "$base/.hq/work-context" 2>/dev/null || true
    if hq mesh context prd-sync --help >/dev/null 2>&1; then
      printf 'yes\n' >"$cache" 2>/dev/null || true
      return 0
    fi
    printf 'no\n' >"$cache" 2>/dev/null || true
    return 1
  }
  if _wm_prd_sync_supported; then
    case "$FILE" in
      /*) ABS="$FILE" ;;
      *) ABS="$HQ_ROOT/$REL" ;;
    esac
    # One prd-sync flight per session. A write while it runs stores the latest
    # path in the dirty file; the flight syncs that path once more, then stops.
    PRD_LOCK="$WM_DIR/${SID}.wm-prd.lock"
    PRD_PID="$WM_DIR/${SID}.wm-prd.pid"
    PRD_DIRTY="$WM_DIR/${SID}.wm-prd.dirty"
    if _wm_flight_busy "$PRD_LOCK" "$PRD_PID"; then
      printf '%s\n' "$ABS" >"$PRD_DIRTY"
    elif ( set -o noclobber; : >"$PRD_LOCK" ) 2>/dev/null; then
      printf '%s\n' "$ABS" >"$PRD_DIRTY"
      HQ_WM_PRD_DIRTY="$PRD_DIRTY" \
      HQ_WM_PRD_LOCK="$PRD_LOCK" \
      HQ_WM_PRD_SID="$SID" \
      nohup bash -c '
        trap "rm -f -- \"\$HQ_WM_PRD_LOCK\"" EXIT
        while :; do
          _f=$(cat "$HQ_WM_PRD_DIRTY" 2>/dev/null || true)
          rm -f -- "$HQ_WM_PRD_DIRTY"
          [ -n "$_f" ] || break
          hq mesh context prd-sync --session "$HQ_WM_PRD_SID" --file "$_f" || true
          [ -f "$HQ_WM_PRD_DIRTY" ] || break
        done
      ' >>"$WM_LOG" 2>&1 &
      echo $! >"$PRD_PID"
    else
      printf '%s\n' "$ABS" >"$PRD_DIRTY"
    fi
  fi
fi
exit 0
