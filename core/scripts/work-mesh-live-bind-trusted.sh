#!/usr/bin/env bash
# hq-core: public
# US-011 — write session meta + reconcile with observation.trustedContext.
# No --trusted CLI flag in hq-cli; trusted bind is the observation field.
set -euo pipefail

ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-}}"
if [ -z "$ROOT" ]; then
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

COMPANY=""
PROJECT=""
TASK=""
SESSION_ID=""
NO_RECONCILE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --company|--company-slug) COMPANY="${2:-}"; shift 2 ;;
    --project) PROJECT="${2:-}"; shift 2 ;;
    --task) TASK="${2:-}"; shift 2 ;;
    --session|--session-id) SESSION_ID="${2:-}"; shift 2 ;;
    --no-reconcile) NO_RECONCILE=1; shift ;;
    --root) ROOT="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) shift ;;
  esac
done

HQ_SESSION="$ROOT/core/scripts/hq-session.sh"

pin=()
if [ -n "$SESSION_ID" ]; then
  pin=(--session-id "$SESSION_ID")
fi

if [ -n "$COMPANY" ]; then
  bash "$HQ_SESSION" "${pin[@]}" set company_slug "$COMPANY"
fi
if [ -n "$PROJECT" ]; then
  bash "$HQ_SESSION" "${pin[@]}" set project "$PROJECT"
fi
if [ -n "$TASK" ]; then
  bash "$HQ_SESSION" "${pin[@]}" set task "$TASK"
fi

if [ "$NO_RECONCILE" -eq 1 ]; then
  exit 0
fi

# Resolve session id for observation when not passed.
if [ -z "$SESSION_ID" ]; then
  SESSION_ID="${HQ_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-${CODEX_SESSION_ID:-${CODEX_THREAD_ID:-}}}}}"
  SESSION_ID="$(printf '%s' "$SESSION_ID" | tr -d '[:space:]')"
  if [ -z "$SESSION_ID" ] && [ -f "$ROOT/workspace/sessions/.current" ]; then
    SESSION_ID="$(tr -d '[:space:]' <"$ROOT/workspace/sessions/.current")"
  fi
fi
[ -n "$SESSION_ID" ] || exit 0

# shellcheck source=lib/work-mesh-enqueue.sh
. "$ROOT/core/scripts/lib/work-mesh-enqueue.sh" 2>/dev/null || true

HARNESS="${HQ_HARNESS:-${HQ_WORK_MESH_HARNESS:-claude-code}}"
case "$HARNESS" in
  claude|Claude|ClaudeCode) HARNESS=claude-code ;;
  Codex) HARNESS=codex ;;
  Grok) HARNESS=grok ;;
esac
ADAPTER="${HQ_ADAPTER_CONTRACT_VERSION:-1.0.0}"

if command -v work_mesh_ulid >/dev/null 2>&1; then
  work_mesh_ulid >/dev/null; CLIENT_OP=$REPLY
else
  CLIENT_OP="cop_$(date +%s)_$$"
fi

json_quote() {
  if command -v work_mesh_json_quote >/dev/null 2>&1; then
    work_mesh_json_quote "$1"; printf '%s' "$REPLY"
    return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg s "$1" '$s'
    return 0
  fi
  # bash-only fallback (hooks-no-python)
  local s=$1
  s=${s//'\'/'\\'}
  s=${s//'"'/'\"'}
  s=${s//$'\n'/'\n'}
  s=${s//$'\r'/'\r'}
  s=${s//$'\t'/'\t'}
  printf '"%s"' "$s"
}

_q_sid="$(json_quote "$SESSION_ID")"
_q_har="$(json_quote "$HARNESS")"
_q_ad="$(json_quote "$ADAPTER")"
_q_op="$(json_quote "$CLIENT_OP")"
_q_cwd="$(json_quote "${PWD:-}")"
_q_root="$(json_quote "$ROOT")"

OBS='{"contractVersion":1,"clientOperationId":'"$_q_op"',"identity":{"sessionId":'"$_q_sid"',"harness":'"$_q_har"',"adapterVersion":'"$_q_ad"'},"cwd":'"$_q_cwd"',"hqRoot":'"$_q_root"
if [ -n "$COMPANY" ] || [ -n "$PROJECT" ] || [ -n "$TASK" ]; then
  OBS+=',"trustedContext":{'
  _first=1
  if [ -n "$COMPANY" ]; then
    OBS+='"companySlug":'"$(json_quote "$COMPANY")"
    _first=0
  fi
  if [ -n "$PROJECT" ]; then
    [ "$_first" -eq 1 ] || OBS+=','
    OBS+='"project":'"$(json_quote "$PROJECT")"
    _first=0
  fi
  if [ -n "$TASK" ]; then
    [ "$_first" -eq 1 ] || OBS+=','
    OBS+='"task":'"$(json_quote "$TASK")"
  fi
  OBS+='}'
fi
OBS+='}'

OBS_DIR="${TMPDIR:-/tmp}/hq-work-mesh-obs"
mkdir -p -- "$OBS_DIR" 2>/dev/null || true
chmod 700 -- "$OBS_DIR" 2>/dev/null || true
OBS_FILE="$OBS_DIR/$SESSION_ID.bind.$$.json"
printf '%s\n' "$OBS" >"$OBS_FILE"

if [ -n "${HQ_WORK_MESH_RECONCILE_LOG:-}" ]; then
  printf 'reconcile-trusted %s\n' "$OBS_FILE" >>"$HQ_WORK_MESH_RECONCILE_LOG" 2>/dev/null || true
fi

if [ "${HQ_WORK_MESH_RECONCILE_STUB:-}" = "1" ]; then
  exit 0
fi

HQ_BIN="$(command -v hq 2>/dev/null || true)"
if [ -n "$HQ_BIN" ] && [ -f "$OBS_FILE" ]; then
  nohup "$HQ_BIN" mesh context reconcile --observation-file "$OBS_FILE" --machine \
    >/dev/null 2>&1 </dev/null &
  disown 2>/dev/null || true
fi
exit 0
