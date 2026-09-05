#!/usr/bin/env bash
# hq-core: public
# SessionEnd: enqueue session_end (US-010). Fail-soft. Target p95 < 20ms.
set -uo pipefail

case "${HQ_WORK_MESH_DISABLED:-}" in 1|true|TRUE|yes|YES|on|ON) exit 0 ;; esac
case ",${HQ_DISABLED_HOOKS:-}," in *,work-mesh,*|*,work-mesh-live,*|*,\*,*) exit 0 ;; esac

HOOK_FILE="${BASH_SOURCE[0]}"
if [ -z "${HQ_ROOT:-}" ]; then
  HQ_ROOT="$(cd "${HOOK_FILE%/*}/../../.." 2>/dev/null && pwd)" || exit 0
fi
# shellcheck source=core/scripts/lib/work-mesh-enqueue.sh
. "$HQ_ROOT/core/scripts/lib/work-mesh-enqueue.sh" 2>/dev/null || exit 0

SID="${HQ_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-${CODEX_SESSION_ID:-${CODEX_THREAD_ID:-}}}}}"
SID="${SID//[[:space:]]/}"
if [ -z "$SID" ]; then
  INPUT=""
  IFS= read -r -d '' INPUT || true
  [ -n "$INPUT" ] || INPUT='{}'
  case "$INPUT" in
    *'"session_id"'*)
      rest="${INPUT#*\"session_id\"}"; rest="${rest#*:}"
      while [ "${rest#"${rest%%[![:space:]]*}"}" != "$rest" ]; do rest="${rest#?}"; done
      case "$rest" in \"*) rest="${rest#\"}"; SID="${rest%%\"*}" ;; esac
      ;;
  esac
  if [ -z "$SID" ]; then
    case "$INPUT" in
      *'"sessionId"'*)
        rest="${INPUT#*\"sessionId\"}"; rest="${rest#*:}"
        while [ "${rest#"${rest%%[![:space:]]*}"}" != "$rest" ]; do rest="${rest#?}"; done
        case "$rest" in \"*) rest="${rest#\"}"; SID="${rest%%\"*}" ;; esac
        ;;
    esac
  fi
  SID="${SID//[[:space:]]/}"
fi
[ -n "$SID" ] || exit 0

HARNESS="${HQ_HARNESS:-${HQ_WORK_MESH_HARNESS:-${HQ_CHECKPOINT_RUNTIME:-claude-code}}}"
case "$HARNESS" in
  claude|Claude|ClaudeCode) HARNESS=claude-code ;;
  Codex) HARNESS=codex ;;
  Grok) HARNESS=grok ;;
esac
ADAPTER="${HQ_ADAPTER_CONTRACT_VERSION:-1.0.0}"

SEQ_DIR="${WORK_MESH_SEQ_DIR:-$HOME/.hq/work-mesh/seq}"
if [ ! -d "$SEQ_DIR" ]; then
  mkdir -p -- "$SEQ_DIR" 2>/dev/null || true
  chmod 700 -- "$SEQ_DIR" 2>/dev/null || true
fi
SEQ_FILE="$SEQ_DIR/$SID"
SEQ=0
if [ -f "$SEQ_FILE" ]; then
  SEQ="$(<"$SEQ_FILE")"
  SEQ="${SEQ//[[:space:]]/}"
fi
case "$SEQ" in ""|*[!0-9]*) SEQ=0 ;; esac
SEQ=$((SEQ + 1))
printf '%s\n' "$SEQ" >"$SEQ_FILE"

work_mesh_enqueue \
  --kind session_end \
  --session-id "$SID" \
  --harness "$HARNESS" \
  --adapter-version "$ADAPTER" \
  --seq "$SEQ" \
  --cwd "${PWD:-}" \
  --hq-root "$HQ_ROOT" \
  || true
exit 0
