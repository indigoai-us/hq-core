#!/usr/bin/env bash
# hq-core: public
# UserPromptSubmit: enqueue turn_start; optional ask-once + board.md inject (US-010).
# Never spawns node or curl. Target p95 < 20ms.
set -uo pipefail

case "${HQ_WORK_MESH_DISABLED:-}" in 1|true|TRUE|yes|YES|on|ON) exit 0 ;; esac
case ",${HQ_DISABLED_HOOKS:-}," in *,work-mesh,*|*,work-mesh-live,*|*,\*,*) exit 0 ;; esac

HOOK_FILE="${BASH_SOURCE[0]}"
if [ -z "${HQ_ROOT:-}" ]; then
  HQ_ROOT="$(cd "${HOOK_FILE%/*}/../../.." 2>/dev/null && pwd)" || exit 0
fi
# shellcheck source=core/scripts/lib/work-mesh-enqueue.sh
. "$HQ_ROOT/core/scripts/lib/work-mesh-enqueue.sh" 2>/dev/null || exit 0

INPUT=""
IFS= read -r -d '' INPUT || true
[ -n "$INPUT" ] || INPUT='{}'

SID="${HQ_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-${CODEX_SESSION_ID:-${CODEX_THREAD_ID:-}}}}}"
SID="${SID//[[:space:]]/}"
PROMPT=""
EVENT="UserPromptSubmit"
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
if [ -z "$SID" ]; then
  _wm_json_str "$INPUT" session_id; SID=$REPLY
  [ -n "$SID" ] || { _wm_json_str "$INPUT" sessionId; SID=$REPLY; }
  SID="${SID//[[:space:]]/}"
fi
_wm_json_str "$INPUT" prompt; PROMPT=$REPLY
_wm_json_str "$INPUT" hook_event_name; [ -n "$REPLY" ] && EVENT=$REPLY
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
  --kind turn_start \
  --session-id "$SID" \
  --harness "$HARNESS" \
  --adapter-version "$ADAPTER" \
  --seq "$SEQ" \
  --cwd "${PWD:-}" \
  --hq-root "$HQ_ROOT" \
  || true

# US-011: if organize rebound to a different project, close old card / open new.
if [ -f "$HQ_ROOT/core/scripts/lib/work-mesh-live-rebind.sh" ]; then
  # shellcheck source=core/scripts/lib/work-mesh-live-hook.sh
  . "$HQ_ROOT/core/scripts/lib/work-mesh-live-hook.sh" 2>/dev/null || true
  # shellcheck source=core/scripts/lib/work-mesh-live-rebind.sh
  . "$HQ_ROOT/core/scripts/lib/work-mesh-live-rebind.sh" 2>/dev/null || true
  if command -v work_mesh_live_maybe_rebind_from_state >/dev/null 2>&1; then
    work_mesh_live_maybe_rebind_from_state "$SID" || true
  fi
fi

# Slash / short: record turn, never ask.
SKIP_ASK=0
case "$PROMPT" in /*) SKIP_ASK=1 ;; esac
if [ "$SKIP_ASK" -eq 0 ]; then
  # shellcheck disable=SC2086
  set -- $PROMPT
  [ "$#" -lt 3 ] && SKIP_ASK=1
fi

CTX=""
WC_HOME="${WORK_MESH_HOME:-$HOME}"
STATE="$WC_HOME/.hq/work-context/sessions/$SID.json"
SURFACED="$WC_HOME/.hq/work-context/sessions/$SID.ask-surfaced"
BOARD="$WC_HOME/.hq/work-context/sessions/$SID/board.md"

if [ "$SKIP_ASK" -eq 0 ] && [ -f "$STATE" ] && [ ! -f "$SURFACED" ] && command -v jq >/dev/null 2>&1; then
  ASK_AFTER="$(jq -r '.decision.askAfter // empty' "$STATE" 2>/dev/null || true)"
  DECISION_ID="$(jq -r '.decision.decisionId // empty' "$STATE" 2>/dev/null || true)"
  OPTIONS_JSON="$(jq -c '.decision.options // []' "$STATE" 2>/dev/null || printf '[]')"
  case "$ASK_AFTER" in
    true|True|1)
      case "$HARNESS" in
        grok)
          PENDING="$WC_HOME/.hq/work-context/sessions/$SID.pending-decision"
          jq -c '{decisionId:.decision.decisionId,options:.decision.options,askAfter:true}' "$STATE" \
            >"$PENDING" 2>/dev/null || printf '{"decisionId":"%s"}\n' "$DECISION_ID" >"$PENDING"
          chmod 600 -- "$PENDING" 2>/dev/null || true
          : >"$SURFACED" 2>/dev/null || true
          CTX="WORK MESH: a project/task clarification is pending (decisionId=${DECISION_ID}). Run: hq mesh context organize --session ${SID} list  then submit with hq mesh context organize --session ${SID} --decision <decisionId> --option <optionId> && bash core/scripts/work-mesh-live-rebind.sh --session ${SID} --from-state. Do not invent a project."
          ;;
        codex)
          CTX="WORK MESH CLARIFICATION (once): call request_user_input with exactly these stable options from decision ${DECISION_ID}: ${OPTIONS_JSON}. After the user picks, run: hq mesh context organize --session ${SID} --decision ${DECISION_ID} --option <optionId> && bash core/scripts/work-mesh-live-rebind.sh --session ${SID} --from-state. Do not create a project yourself."
          : >"$SURFACED" 2>/dev/null || true
          ;;
        *)
          CTX="WORK MESH CLARIFICATION (once): use AskUserQuestion with exactly these stable options from decision ${DECISION_ID}: ${OPTIONS_JSON}. After the user picks, run: hq mesh context organize --session ${SID} --decision ${DECISION_ID} --option <optionId> && bash core/scripts/work-mesh-live-rebind.sh --session ${SID} --from-state. Do not create a project yourself."
          : >"$SURFACED" 2>/dev/null || true
          ;;
      esac
      ;;
  esac
fi

if [ -f "$BOARD" ]; then
  BOARD_TXT="$(head -c 8000 -- "$BOARD" 2>/dev/null || true)"
  if [ -n "$BOARD_TXT" ]; then
    if [ -n "$CTX" ]; then
      CTX="${CTX}"$'\n\n'"BOARD SNAPSHOT (board.md):"$'\n'"${BOARD_TXT}"
    else
      CTX="BOARD SNAPSHOT (board.md):"$'\n'"${BOARD_TXT}"
    fi
  fi
fi

if [ -n "$CTX" ] && command -v jq >/dev/null 2>&1; then
  jq -n --arg ctx "$CTX" --arg ev "$EVENT" \
    '{hookSpecificOutput:{hookEventName:$ev,additionalContext:$ctx}}' 2>/dev/null || true
fi
exit 0
