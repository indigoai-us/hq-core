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

# Resolve session id before metadata writes so a known session is pinned even
# when the caller omitted --session-id. Empty `pin` must still be safe on
# macOS Bash 3.2 (`set -u` + `"${pin[@]}"` is an unbound-variable abort).
if [ -z "$SESSION_ID" ]; then
  SESSION_ID="${HQ_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-${CODEX_SESSION_ID:-${CODEX_THREAD_ID:-}}}}}"
  SESSION_ID="$(printf '%s' "$SESSION_ID" | tr -d '[:space:]')"
  if [ -z "$SESSION_ID" ] && [ -f "$ROOT/workspace/sessions/.current" ]; then
    SESSION_ID="$(tr -d '[:space:]' <"$ROOT/workspace/sessions/.current")"
  fi
fi

pin=()
if [ -n "$SESSION_ID" ]; then
  pin=(--session-id "$SESSION_ID")
fi

if [ -n "$COMPANY" ]; then
  bash "$HQ_SESSION" ${pin[@]+"${pin[@]}"} set company_slug "$COMPANY"
fi
if [ -n "$PROJECT" ]; then
  bash "$HQ_SESSION" ${pin[@]+"${pin[@]}"} set project "$PROJECT"
fi
if [ -n "$TASK" ]; then
  bash "$HQ_SESSION" ${pin[@]+"${pin[@]}"} set task "$TASK"
fi

if [ "$NO_RECONCILE" -eq 1 ]; then
  exit 0
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
if [ -z "$HQ_BIN" ]; then
  printf '%s\n' 'Work Mesh reconcile skipped: hq CLI not found on PATH.' >&2
else
  flag_reader="$ROOT/.claude/hooks/work-mesh-daemon-not-loaded-flag.cjs"
  daemon_warning_enabled=false
  if [[ -n "${HQ_FLAGS_API_URL:-}" \
    && "${HQ_COMPANY_UID:-}" =~ ^cmp_[A-Za-z0-9]{3,128}$ ]] \
    && command -v node >/dev/null 2>&1 && [[ -f "$flag_reader" ]]; then
    daemon_warning_enabled="$(HQ_CLI_BIN="$HQ_BIN" node "$flag_reader")" || daemon_warning_enabled=false
  fi
  if [ "$daemon_warning_enabled" = "true" ]; then
    # Status only reads the installed service and its live state. Keep this hook
    # bounded, and fail quiet when the CLI or service manager cannot answer.
    daemon_status_file="$(mktemp "${TMPDIR:-/tmp}/hq-work-mesh-daemon-status.XXXXXX" 2>/dev/null)" || daemon_status_file=""
    if [ -n "$daemon_status_file" ]; then
      HQ_NO_UPDATE_CHECK=1 "$HQ_BIN" mesh daemon status --json >"$daemon_status_file" 2>/dev/null &
      daemon_status_pid=$!
      ( sleep 2; kill "$daemon_status_pid" 2>/dev/null || true ) &
      daemon_status_watchdog=$!
      daemon_status_rc=0
      wait "$daemon_status_pid" || daemon_status_rc=$?
      kill "$daemon_status_watchdog" 2>/dev/null || true
      wait "$daemon_status_watchdog" 2>/dev/null || true
      if [ "$daemon_status_rc" -eq 0 ] && command -v jq >/dev/null 2>&1 && \
        jq -e '(.ok == true) and (.running == false) and (.message | type == "string" and contains("installed ("))' \
          "$daemon_status_file" >/dev/null 2>&1; then
        printf '%s\n' 'Work Mesh daemon is installed but not loaded; start it with: hq mesh daemon install' >&2
      fi
      rm -f "$daemon_status_file" 2>/dev/null || true
    fi
  fi
  if [ -f "$OBS_FILE" ]; then
    nohup "$HQ_BIN" mesh context reconcile --observation-file "$OBS_FILE" --machine \
      >/dev/null 2>&1 </dev/null &
    disown 2>/dev/null || true
  fi
fi
exit 0
