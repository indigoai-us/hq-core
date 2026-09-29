#!/usr/bin/env bash
# hq-core-staging: thin Stop-hook shim for the hq-cli lane monitor gate.
#
# The lane store reader, Monitor evidence reader, exit-code contract and
# recommendation formatter live in hq-cli. This file only translates that
# command's result into the Claude Stop-hook protocol.
#
# Error policy: Claude fails closed. A missing hq binary, an old CLI without
# monitor-check, malformed JSON, or hq exit 3 emits a loud error and a Stop
# block when the payload can be encoded. The structured Stop protocol consumes
# that JSON on stdout only when the hook exits successfully, so every Claude
# block path below returns 0 after emitting its decision. A Codex/Grok adapter
# passes its engine explicitly; those engines have no Claude Monitor tool and
# therefore never receive a block from this shim.
#
# That engine check is load-bearing, not belt-and-braces. Both adapters now
# translate a Stop hook's decision into their own stop protocol, so a block
# emitted here WOULD hold a Codex or Grok turn — demanding a Monitor call the
# engine has no tool to make. The non-zero returns below are what keep it off
# them: the Grok adapter treats exit 2 as a block and every other non-zero exit
# as fail-open, and these paths return 3.
#
# stop_hook_active is the recursion guard supplied by Claude Code. When it is
# true, do not issue a second block: report the unresolved coverage/error on
# stderr and return non-zero so the session can perform the named remedy.
# This makes the guard's own remedy reachable without turning a repeated Stop
# callback into an unbounded block loop.

set -uo pipefail

# master-hook.sh gives each registry child 30 seconds. Keep the CLI call below
# that deadline so this shim can emit its own fail-closed decision if hq hangs.
LANES_MONITOR_CHECK_TIMEOUT_SECONDS=20

# Drain before any early exit. The dispatcher may still be writing the payload;
# leaving it unread turns a legitimate hook status into a SIGPIPE/141 report.
{ INPUT="$(</dev/stdin)"; } 2>/dev/null || INPUT=''

HOOK_PATH="${BASH_SOURCE[0]:-$0}"
case "$HOOK_PATH" in
  */*) HOOK_DIR="${HOOK_PATH%/*}" ;;
  *) HOOK_DIR="." ;;
esac
HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$HOOK_DIR/../.." 2>/dev/null && pwd -P || true)}}"

# Establish the adapter's engine before jq parsing. This preserves the
# no-Monitor exception even when jq itself is unavailable.
ENGINE_RAW="${HQ_HARNESS:-claude}"
normalize_engine() {
  case "$1" in
    claude|claude-code|claude_code|[cC][lL][aA][uU][dD][eE]|[cC][lL][aA][uU][dD][eE]-[cC][oO][dD][eE]|[cC][lL][aA][uU][dD][eE]_[cC][oO][dD][eE]) ENGINE=claude ;;
    codex|[cC][oO][dD][eE][xX]) ENGINE=codex ;;
    grok|[gG][rR][oO][kK]) ENGINE=grok ;;
    *) ENGINE=unknown ;;
  esac
}
normalize_engine "$ENGINE_RAW"
STOP_HOOK_ACTIVE=false
if [[ "$INPUT" =~ \"stop_hook_active\"[[:space:]]*:[[:space:]]*true ]]; then
  STOP_HOOK_ACTIVE=true
fi

early_gate_error() {
  local detail="$1"
  printf 'ERROR: lanes Stop gate could not verify Monitor coverage: %s\n' "$detail" >&2
  case "$ENGINE" in
    codex|grok)
      return 3
      ;;
  esac
  if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
    printf 'WARNING: stop_hook_active=true; no second Stop block was emitted. Resolve the hook error, or run hq lanes stop / hq lanes reparent.\n' >&2
    return 3
  fi
  # No parser is available here, so keep the fallback block static and safely
  # JSON-encoded. The detailed diagnostic is already on stderr.
  printf '%s\n' '{"decision":"block","reason":"Lane Monitor coverage could not be verified. Repair or update hq-cli, then retry; or run hq lanes stop / hq lanes reparent for lanes that should leave this senior."}'
  # CLAUDE_EARLY_ERROR_BLOCK_RETURN
  return 0
}

if ! command -v jq >/dev/null 2>&1; then
  rc=0
  early_gate_error "cannot parse the hook payload because jq is unavailable" || rc=$?
  exit "$rc"
fi

if ! PARSED="$(printf '%s' "$INPUT" | jq -jer '
  if type != "object" then error("hook payload is not an object") else
    [
      (.session_id // .sessionId // "" | tostring),
      (if .stop_hook_active == true then "true" else "false" end),
      (.engine // .engine_name // "" | tostring)
    ] | join("\u001e")
  end
' 2>/dev/null)"; then
  rc=0
  early_gate_error "received malformed hook JSON; monitor coverage is unknown" || rc=$?
  exit "$rc"
fi

SESSION_ID="${PARSED%%$'\x1e'*}"
PARSED_REST="${PARSED#*$'\x1e'}"
STOP_HOOK_ACTIVE="${PARSED_REST%%$'\x1e'*}"
ENGINE_RAW="${PARSED_REST#*$'\x1e'}"
[ -n "$ENGINE_RAW" ] || ENGINE_RAW="${HQ_HARNESS:-claude}"
normalize_engine "$ENGINE_RAW"
case "$ENGINE" in
  unknown)
    ENGINE=unknown
    rc=0
    early_gate_error "received unsupported engine '$ENGINE_RAW'; monitor coverage is unknown" || rc=$?
    exit "$rc"
    ;;
esac

compact_detail() {
  # Keep dependency diagnostics bounded; the CLI owns the authoritative error.
  printf '%s' "$1" | head -c 4000 || true
}

emit_block() {
  local reason="$1"
  jq -cn --arg reason "$reason" '{decision:"block",reason:$reason}' 2>/dev/null
}

gate_error() {
  local detail="$1"
  local reason
  printf 'ERROR: lanes Stop gate could not verify Monitor coverage: %s\n' "$detail" >&2

  # Codex/Grok cannot satisfy this Claude-only gate: neither has a Monitor tool
  # to arm. Their adapters DO translate a Stop block now, so this check is the
  # only thing standing between them and a demand they cannot meet. Return 3 —
  # non-zero and not 2 — which both adapters read as fail-open.
  case "$ENGINE" in
    codex|grok)
    return 3
    ;;
  esac

  # Claude Code sets this after a Stop block has already caused a continuation.
  # The first block names the remedy; a second block would trap that remedy.
  if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
    printf 'WARNING: stop_hook_active=true; no second Stop block was emitted. Resolve the named coverage/error remedy, or run hq lanes stop / hq lanes reparent.\n' >&2
    return 3
  fi

  reason="Monitor coverage could not be verified. Repair or update hq-cli, then retry. If the lane should no longer remain under this senior, run hq lanes stop <lane-id> or hq lanes reparent <lane-id> <senior>."
  reason="${reason}
Detail: $detail"
  if ! emit_block "$reason"; then
    echo "ERROR: lanes Stop gate could not emit its block decision." >&2
    return 3
  fi
  # CLAUDE_ERROR_FAIL_CLOSED_RETURN
  return 0
}

run_hq_with_timeout() {
  local seconds="$1" marker="$2" rc child watchdog timeout_bin perl_bin
  shift 2

  timeout_bin="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
  if [ -n "$timeout_bin" ]; then
    "$timeout_bin" "$seconds" "$@"
    rc=$?
    case "$rc" in
      124|137|142|143) : > "$marker" 2>/dev/null || true ;;
    esac
    return "$rc"
  fi

  perl_bin="$(command -v perl 2>/dev/null || true)"
  if [ -n "$perl_bin" ]; then
    "$perl_bin" -e 'alarm shift; exec {$ARGV[0]} @ARGV' "$seconds" "$@"
    rc=$?
    case "$rc" in
      124|137|142|143) : > "$marker" 2>/dev/null || true ;;
    esac
    return "$rc"
  fi

  # Last-resort POSIX-shell watchdog. It kills the direct hq child and marks
  # the result before returning, so an environment without timeout or perl is
  # still bounded by the same fixed deadline.
  "$@" &
  child=$!
  (
    sleep "$seconds"
    if kill -0 "$child" 2>/dev/null; then
      : > "$marker" 2>/dev/null || true
      kill "$child" 2>/dev/null || true
    fi
  ) &
  watchdog=$!
  wait "$child"
  rc=$?
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  return "$rc"
}

emit_uncovered() {
  local result="$1"
  local uncovered calls reason
  uncovered="$(printf '%s' "$result" | jq -r '.uncovered_lane_ids[] | "- " + .' 2>/dev/null || true)"
  calls="$(printf '%s' "$result" | jq -r '
    .monitor_calls[]
    | "Monitor(command=" + (.command | tojson)
      + ", timeout_ms=" + (.timeout_ms | tostring)
      + ", persistent=" + (.persistent | tostring) + ")"
  ' 2>/dev/null || true)"
  [ -n "$uncovered" ] || return 1
  [ -n "$calls" ] || return 1

  reason="Lane Monitor coverage is required before this session can stop.
Uncovered lane ids:
$uncovered
Exact Monitor calls to copy:
$calls
Remedy: arm the Monitor call(s) above; or run hq lanes stop <lane-id> / hq lanes reparent <lane-id> <senior> so the lane is no longer this session's active senior lane."

  if [ "$ENGINE" != "claude" ]; then
    printf 'ERROR: hq-cli reported uncovered lanes for engine %s, which has no Claude Monitor requirement.\n%s\n' "$ENGINE" "$reason" >&2
    return 3
  fi
  if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
    printf 'WARNING: stop_hook_active=true; no second Stop block was emitted.\n%s\n' "$reason" >&2
    # ACTIVE_STOP_MUST_NOT_BLOCK
    return 3
  fi
  if ! emit_block "$reason"; then
    echo "ERROR: lanes Stop gate could not emit its block decision." >&2
    return 3
  fi
  # UNCOVERED_BLOCK_RETURN
  return 0
}

if [ -z "$SESSION_ID" ]; then
  rc=0
  gate_error "hook payload did not contain session_id" || rc=$?
  exit "$rc"
fi

HQ_BIN="$(command -v hq 2>/dev/null || true)"
if [ -z "$HQ_BIN" ]; then
  rc=0
  # MISSING_HQ_MUST_ERROR
  gate_error "hq CLI is missing from PATH; install or update hq-cli" || rc=$?
  exit "$rc"
fi

ERR_FILE="$(mktemp "${TMPDIR:-/tmp}/hq-lanes-monitor-check.XXXXXX" 2>/dev/null || true)"
if [ -z "$ERR_FILE" ]; then
  rc=0
  gate_error "could not allocate a bounded stderr capture for hq-cli" || rc=$?
  exit "$rc"
fi
TIMEOUT_MARKER="${ERR_FILE}.timeout"
if [ -e "$TIMEOUT_MARKER" ]; then
  rm -f "$ERR_FILE" 2>/dev/null || true
  rc=0
  gate_error "the bounded hq-cli timeout marker path is already occupied" || rc=$?
  exit "$rc"
fi
cleanup() {
  rm -f "$ERR_FILE" "$TIMEOUT_MARKER" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

HQ_RC=0
HQ_NO_UPDATE_CHECK=1
CLAUDE_PROJECT_DIR="$HQ_ROOT"
export HQ_NO_UPDATE_CHECK HQ_ROOT CLAUDE_PROJECT_DIR
RESULT="$(run_hq_with_timeout "$LANES_MONITOR_CHECK_TIMEOUT_SECONDS" "$TIMEOUT_MARKER" \
  "$HQ_BIN" lanes monitor-check --session "$SESSION_ID" --engine "$ENGINE" --json \
  2>"$ERR_FILE")" || HQ_RC=$?
{ HQ_ERR="$(<"$ERR_FILE")"; } 2>/dev/null || HQ_ERR=''

if [ -f "$TIMEOUT_MARKER" ]; then
  detail="hq lanes monitor-check timed out after ${LANES_MONITOR_CHECK_TIMEOUT_SECONDS}s"
  [ -n "$HQ_ERR" ] && detail="$detail: $(compact_detail "$HQ_ERR")"
  rc=0
  # INNER_TIMEOUT_MUST_FAIL_CLOSED
  gate_error "$detail" || rc=$?
  exit "$rc"
fi

case "$HQ_RC" in
  0)
    if [ -z "$RESULT" ] || ! printf '%s' "$RESULT" | jq -e '
      type == "object" and .action == "monitor-check" and .ok == true
    ' >/dev/null 2>&1; then
      detail="hq lanes monitor-check returned invalid success JSON"
      [ -n "$HQ_ERR" ] && detail="$detail: $(compact_detail "$HQ_ERR")"
      rc=0
      gate_error "$detail" || rc=$?
      exit "$rc"
    fi
    # PASS_RESULT_RETURN
    exit 0
    ;;
  2)
    if ! printf '%s' "$RESULT" | jq -e '
      type == "object"
      and .action == "monitor-check"
      and ((.uncovered_lane_ids | type) == "array")
      and ((.monitor_calls | type) == "array")
      and (.uncovered_lane_ids | length > 0)
      and (.monitor_calls | length > 0)
      and all(.monitor_calls[];
        ((.command | type) == "string")
        and ((.timeout_ms | type) == "number")
        and ((.persistent | type) == "boolean")
      )
    ' >/dev/null 2>&1; then
      detail="hq lanes monitor-check returned invalid uncovered JSON"
      [ -n "$HQ_ERR" ] && detail="$detail: $(compact_detail "$HQ_ERR")"
      rc=0
      gate_error "$detail" || rc=$?
      exit "$rc"
    fi
    rc=0
    emit_uncovered "$RESULT" || rc=$?
    if [ "$rc" -eq 1 ]; then
      gate_error "hq lanes monitor-check exit 2 did not contain usable uncovered lane ids and Monitor calls" || rc=$?
    fi
    exit "$rc"
    ;;
  *)
    detail="hq lanes monitor-check exited $HQ_RC"
    [ -n "$HQ_ERR" ] && detail="$detail: $(compact_detail "$HQ_ERR")"
    rc=0
    gate_error "$detail" || rc=$?
    exit "$rc"
    ;;
esac
