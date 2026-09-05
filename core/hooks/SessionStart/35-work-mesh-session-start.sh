#!/usr/bin/env bash
# hq-core: public
# SessionStart: enqueue session_start + detached hq mesh context reconcile (US-010).
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
CWD="${PWD:-}"
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
_wm_json_str "$INPUT" cwd; [ -n "$REPLY" ] && CWD=$REPLY
[ -n "$SID" ] || exit 0

HARNESS="${HQ_HARNESS:-${HQ_WORK_MESH_HARNESS:-${HQ_CHECKPOINT_RUNTIME:-claude-code}}}"
case "$HARNESS" in
  claude|Claude|ClaudeCode) HARNESS=claude-code ;;
  Codex) HARNESS=codex ;;
  Grok) HARNESS=grok ;;
esac
ADAPTER="${HQ_ADAPTER_CONTRACT_VERSION:-1.0.0}"
RUNTIME="${HQ_RUNTIME_VERSION:-${CLAUDE_CODE_VERSION:-${CODEX_VERSION:-${GROK_VERSION:-}}}}"

COMPANY="${HQ_SPAWN_COMPANY:-}"
PROJECT="${HQ_SPAWN_PROJECT:-}"
TASK="${HQ_SPAWN_TASK:-}"
# Skip meta.yaml forks unless spawn context is incomplete and a session meta exists.
if [ -z "$COMPANY" ] || [ -z "$PROJECT" ] || [ -z "$TASK" ]; then
  meta="$HQ_ROOT/workspace/sessions/$SID/meta.yaml"
  if [ -f "$meta" ]; then
    meta_get() {
      awk -v k="$1" '$1==k":"{ sub(/^[^:]+:[[:space:]]*/,""); gsub(/^"|"$/,""); print; exit }' "$meta" 2>/dev/null
    }
    [ -n "$COMPANY" ] || COMPANY="$(meta_get company_slug)"
    [ -n "$PROJECT" ] || PROJECT="$(meta_get project)"
    [ -n "$TASK" ] || TASK="$(meta_get task)"
  fi
fi

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

ENQ=(--kind session_start --session-id "$SID" --harness "$HARNESS" --adapter-version "$ADAPTER" --seq "$SEQ" --cwd "$CWD" --hq-root "$HQ_ROOT")
[ -n "$RUNTIME" ] && ENQ+=(--runtime-version "$RUNTIME")
[ -n "$COMPANY" ] && ENQ+=(--company-slug "$COMPANY")
[ -n "$PROJECT" ] && ENQ+=(--project "$PROJECT")
[ -n "$TASK" ] && ENQ+=(--task "$TASK")
work_mesh_enqueue "${ENQ[@]}" || true

# US-011: record live binding so mid-session organize can detect rebind.
if [ -n "$PROJECT" ] && [ -f "$HQ_ROOT/core/scripts/lib/work-mesh-live-rebind.sh" ]; then
  # shellcheck source=core/scripts/lib/work-mesh-live-rebind.sh
  . "$HQ_ROOT/core/scripts/lib/work-mesh-live-rebind.sh" 2>/dev/null || true
  if command -v work_mesh_live_write_binding_marker >/dev/null 2>&1; then
    work_mesh_live_write_binding_marker "$SID" "$COMPANY" "$PROJECT" "$TASK" || true
  fi
fi

# Timing / test stub: still record reconcile intent without building a large obs.
if [ "${HQ_WORK_MESH_RECONCILE_STUB:-}" = "1" ]; then
  if [ -n "${HQ_WORK_MESH_RECONCILE_LOG:-}" ]; then
    printf 'reconcile stub %s\n' "$SID" >>"$HQ_WORK_MESH_RECONCILE_LOG" 2>/dev/null || true
  fi
  exit 0
fi

work_mesh_ulid >/dev/null; CLIENT_OP=$REPLY
work_mesh_json_quote "$SID"; _q_sid=$REPLY
work_mesh_json_quote "$HARNESS"; _q_har=$REPLY
work_mesh_json_quote "$ADAPTER"; _q_ad=$REPLY
work_mesh_json_quote "$CLIENT_OP"; _q_op=$REPLY
work_mesh_json_quote "$CWD"; _q_cwd=$REPLY
work_mesh_json_quote "$HQ_ROOT"; _q_root=$REPLY
OBS='{"contractVersion":1,"clientOperationId":'"$_q_op"',"identity":{"sessionId":'"$_q_sid"',"harness":'"$_q_har"',"adapterVersion":'"$_q_ad"
if [ -n "$RUNTIME" ]; then
  work_mesh_json_quote "$RUNTIME"; _q_rt=$REPLY
  OBS+=',"runtimeVersion":'"$_q_rt"
fi
OBS+='},"cwd":'"$_q_cwd"',"hqRoot":'"$_q_root"
if [ -n "$COMPANY" ] || [ -n "$PROJECT" ] || [ -n "$TASK" ]; then
  OBS+=',"trustedContext":{'; _first=1
  if [ -n "$COMPANY" ]; then work_mesh_json_quote "$COMPANY"; OBS+='"companySlug":'"$REPLY"; _first=0; fi
  if [ -n "$PROJECT" ]; then work_mesh_json_quote "$PROJECT"; [ "$_first" -eq 1 ] || OBS+=','; OBS+='"project":'"$REPLY"; _first=0; fi
  if [ -n "$TASK" ]; then work_mesh_json_quote "$TASK"; [ "$_first" -eq 1 ] || OBS+=','; OBS+='"task":'"$REPLY"; fi
  OBS+='}'
fi
OBS+='}'

OBS_DIR="${TMPDIR:-/tmp}/hq-work-mesh-obs"
mkdir -p -- "$OBS_DIR" 2>/dev/null || true
chmod 700 -- "$OBS_DIR" 2>/dev/null || true
OBS_FILE="$OBS_DIR/$SID.$SEQ.json"
printf '%s\n' "$OBS" >"$OBS_FILE" 2>/dev/null || true
if [ -n "${HQ_WORK_MESH_RECONCILE_LOG:-}" ]; then
  printf 'reconcile %s\n' "$OBS_FILE" >>"$HQ_WORK_MESH_RECONCILE_LOG" 2>/dev/null || true
fi
HQ_BIN="$(command -v hq 2>/dev/null || true)"
if [ -n "$HQ_BIN" ] && [ -f "$OBS_FILE" ]; then
  nohup "$HQ_BIN" mesh context reconcile --observation-file "$OBS_FILE" --machine \
    >/dev/null 2>&1 </dev/null &
  disown 2>/dev/null || true
fi
exit 0
