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
_wm_json_str "$INPUT" session_id; ENGINE_SID=$REPLY
[ -n "$ENGINE_SID" ] || { _wm_json_str "$INPUT" sessionId; ENGINE_SID=$REPLY; }
ENGINE_SID="${ENGINE_SID//[[:space:]]/}"
PARENT_SID="${HQ_PARENT_SESSION_ID:-${HQ_SESSION_ID:-}}"
PARENT_SID="${PARENT_SID//[[:space:]]/}"

# Conduct lanes retain HQ_SESSION_ID for parent pool accounting. Their engine
# supplies a new session id in SessionStart stdin; use that child id for mesh
# binding and reconciliation instead of relabeling the already-bound parent.
if [ -n "${HQ_SPAWN_COMPANY:-}" ] && [ -n "$ENGINE_SID" ]; then
  SID="$ENGINE_SID"
else
  SID="${HQ_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-${CODEX_SESSION_ID:-${CODEX_THREAD_ID:-}}}}}"
  SID="${SID//[[:space:]]/}"
  [ -n "$SID" ] || SID="$ENGINE_SID"
fi
_wm_json_str "$INPUT" cwd; [ -n "$REPLY" ] && CWD=$REPLY
[ -n "$SID" ] || exit 0

BOUND_COMPANY=""
WORK_CONTEXT_ROOT="${HQ_WORK_CONTEXT_ROOT:-${HOME:-}/.hq/work-context}"
WORK_CONTEXT_STATE_EXISTED=0
[ -f "$WORK_CONTEXT_ROOT/sessions/$SID.json" ] && WORK_CONTEXT_STATE_EXISTED=1
if [ -f "$HQ_ROOT/core/scripts/lib/session-auto-bind.sh" ]; then
  # shellcheck source=core/scripts/lib/session-scope-capability.sh
  . "$HQ_ROOT/core/scripts/lib/session-scope-capability.sh" 2>/dev/null || true
  # shellcheck source=core/scripts/lib/session-auto-bind.sh
  . "$HQ_ROOT/core/scripts/lib/session-auto-bind.sh" 2>/dev/null || true
  if command -v session_auto_bind_apply >/dev/null 2>&1; then
    # Device defaults are intentionally left to hq mesh context reconcile. It
    # sees cwd + repository evidence and can return company_conflict; promoting
    # a preference into meta/scope here would make it trusted too early.
    HQ_SESSION_AUTO_BIND_SKIP_DEVICE_DEFAULT=1 session_auto_bind_apply "$HQ_ROOT" "$SID" "$PARENT_SID" || true
    BOUND_COMPANY="$(session_auto_bind_meta_slug "$HQ_ROOT" "$SID" 2>/dev/null || true)"
  fi
fi

HARNESS="${HQ_HARNESS:-${HQ_WORK_MESH_HARNESS:-${HQ_CHECKPOINT_RUNTIME:-claude-code}}}"
case "$HARNESS" in
  claude|Claude|ClaudeCode) HARNESS=claude-code ;;
  Codex) HARNESS=codex ;;
  Grok) HARNESS=grok ;;
esac
ADAPTER="${HQ_ADAPTER_CONTRACT_VERSION:-1.0.0}"
RUNTIME="${HQ_RUNTIME_VERSION:-${CLAUDE_CODE_VERSION:-${CODEX_VERSION:-${GROK_VERSION:-}}}}"

COMPANY="${BOUND_COMPANY:-${HQ_SPAWN_COMPANY:-}}"
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
  # Resolve an otherwise-unbound session before writing a device-default scope.
  # The observation deliberately carries cwd/repo evidence without a trusted
  # company, so the CLI can classify a default conflict instead of accepting a
  # shell-level preference as a dispatch fact.
  if [ -z "$BOUND_COMPANY" ] && command -v session_auto_bind_run_with_timeout >/dev/null 2>&1; then
    PREFLIGHT_STATE_EXISTED=0
    PREFLIGHT_REPAIR=false
    [ -f "${HQ_WORK_CONTEXT_ROOT:-${HOME:-}/.hq/work-context}/sessions/$SID.json" ] && PREFLIGHT_STATE_EXISTED=1
    PREFLIGHT_STATUS=0
    PREFLIGHT_RESULT="$(session_auto_bind_run_with_timeout "$HQ_BIN" mesh context reconcile --observation-file "$OBS_FILE" --machine --offline 2>/dev/null)" || PREFLIGHT_STATUS=$?
    PREFLIGHT_CLASSIFICATION=""
    PREFLIGHT_SLUG=""
    PREFLIGHT_UID=""
    if [ "$PREFLIGHT_STATUS" -eq 0 ] && command -v jq >/dev/null 2>&1; then
      PREFLIGHT_CLASSIFICATION="$(printf '%s' "$PREFLIGHT_RESULT" | jq -er --arg sid "$SID" --arg op "$CLIENT_OP" '
        if type == "object"
          and .contractVersion == 1
          and (.sessionId | type == "string") and .sessionId == $sid
          and (.clientOperationId | type == "string") and .clientOperationId == $op
          and (.kind | type == "string")
          and (.classification | type == "string")
          and (.delivery | type == "string") and (.delivery == "clean" or .delivery == "queued" or .delivery == "acked" or .delivery == "quarantined")
          and (.lifecycle | type == "string") and (.lifecycle == "open" or .lifecycle == "terminal")
        then .classification else empty end
      ' 2>/dev/null)" || PREFLIGHT_CLASSIFICATION=""
      PREFLIGHT_SLUG="$(printf '%s' "$PREFLIGHT_RESULT" | jq -er '.companySlug | select(type == "string" and length > 0)' 2>/dev/null)" || PREFLIGHT_SLUG=""
      PREFLIGHT_UID="$(printf '%s' "$PREFLIGHT_RESULT" | jq -er '.companyUid | select(type == "string" and length > 0)' 2>/dev/null)" || PREFLIGHT_UID=""
      PREFLIGHT_REPAIR="$("$HQ_BIN" mesh context default get --json 2>/dev/null | jq -er '(.repairHeldWithDefault // (.defaultCompany.repairHeldWithDefault // false)) | if . == true then "true" else "false" end' 2>/dev/null)" || PREFLIGHT_REPAIR=false
    fi
    case "$PREFLIGHT_CLASSIFICATION" in
      company_conflict|bound|needs_project|needs_task)
        PREFLIGHT_KIND="$(printf '%s' "$PREFLIGHT_RESULT" | jq -er '.kind' 2>/dev/null)" || PREFLIGHT_KIND=""
        case "$PREFLIGHT_CLASSIFICATION:$PREFLIGHT_KIND" in
          company_conflict:company_conflict)
            printf '%s\n' 'work-mesh: company_conflict; leaving device-default session unbound' >&2
            ;;
          bound:bound|bound:queued|needs_project:needs_project|needs_project:queued|needs_task:needs_task|needs_task:queued)
            # Bind the exact slug/uid validated for this session+operation;
            # never re-read the mutable device default after preflight.
            [ -n "$PREFLIGHT_SLUG" ] && [ -n "$PREFLIGHT_UID" ] && \
              session_auto_bind_apply_validated_default "$HQ_ROOT" "$SID" "$PREFLIGHT_SLUG" "$PREFLIGHT_UID" "$PREFLIGHT_STATE_EXISTED" "$PREFLIGHT_REPAIR" || true
            ;;
          *)
            printf '%s\n' 'work-mesh: preflight unresolved; leaving device-default session unbound' >&2
            ;;
        esac
        ;;
      needs_company)
        # No configured/validated default is an ordinary no-op, not an error.
        ;;
      *)
        printf '%s\n' 'work-mesh: preflight unresolved; leaving device-default session unbound' >&2
        ;;
    esac
  fi
  nohup "$HQ_BIN" mesh context reconcile --observation-file "$OBS_FILE" --machine \
    >/dev/null 2>&1 </dev/null &
  disown 2>/dev/null || true
fi
exit 0
