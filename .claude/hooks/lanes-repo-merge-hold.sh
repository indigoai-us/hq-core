#!/usr/bin/env bash
# Ask hq-cli to enforce the company-gated repo merge hold before Bash calls.
# hq-cli intentionally treats every check error as allow; this shim does too.
set -uo pipefail

readonly HOOK_ID="lanes-repo-merge-hold"

allow_with_notice() {
  printf '%s: %s; allowing command\n' "$HOOK_ID" "$1" >&2
  exit 0
}

deny() {
  jq -cn --arg reason "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason}}'
  exit 0
}

if ! command -v jq >/dev/null 2>&1; then
  allow_with_notice "jq is unavailable"
fi

INPUT="$(cat 2>/dev/null || true)"
if ! printf '%s' "$INPUT" | jq -e 'type == "object"' >/dev/null 2>&1; then
  allow_with_notice "could not parse the PreToolUse payload"
fi

TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
[ "$TOOL_NAME" = "Bash" ] || exit 0

# A sentinel keeps jq's raw output from losing command-ending newlines through
# Bash command substitution. Remove only the sentinel after the read.
RAW_COMMAND="$(printf '%s' "$INPUT" | jq -jr 'if (.tool_input.command | type) == "string" then .tool_input.command, "\u0001" else empty end' 2>/dev/null || true)"
case "$RAW_COMMAND" in
  *$'\001') COMMAND_TEXT="${RAW_COMMAND%$'\001'}" ;;
  *) allow_with_notice "the Bash command is missing or malformed" ;;
esac

# Bash concatenates adjacent quoted and unquoted word fragments before invoking
# a command. Remove only shell quoting characters from a copy for this cheap
# prefilter; hq-cli still parses the original command text unchanged.
PREFILTER_COMMAND="$COMMAND_TEXT"
PREFILTER_COMMAND="${PREFILTER_COMMAND//\"/}"
PREFILTER_COMMAND="${PREFILTER_COMMAND//\'/}"
PREFILTER_COMMAND="${PREFILTER_COMMAND//\\/}"
case "$PREFILTER_COMMAND" in
  *[mM][eE][rR][gG][eE]*)
  :
    ;;
  *) exit 0 ;;
esac

HQ_BIN="$(command -v hq 2>/dev/null || true)"
[ -n "$HQ_BIN" ] || allow_with_notice "hq is unavailable"

TIMEOUT_BIN="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
[ -n "$TIMEOUT_BIN" ] || allow_with_notice "a bounded timeout command is unavailable"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/lanes-repo-merge-hold.XXXXXX" 2>/dev/null || true)"
[ -n "$TMP" ] && [ -d "$TMP" ] || allow_with_notice "temporary output files could not be created"
trap 'rm -rf "$TMP"' EXIT

status=0
# Keep HQ_NO_UPDATE_CHECK on every bounded hq invocation: startup must not
# trigger a global install while the five-second hook deadline is running.
HQ_NO_UPDATE_CHECK=1 "$TIMEOUT_BIN" -k 1s 5s "$HQ_BIN" lanes hold check \
  --command "$COMMAND_TEXT" --json >"$TMP/stdout" 2>"$TMP/stderr" || status=$?

if [ "$status" -eq 0 ]; then
  exit 0
fi

if [ "$status" -eq 3 ]; then
  if ! jq -e -s '
    length == 1
    and (.[0] | type == "object")
    and (.[0].ok == false)
    and (.[0].error | type == "string" and length > 0)
  ' "$TMP/stdout" >/dev/null 2>&1; then
    allow_with_notice "hq lanes hold check returned an invalid exit-3 response"
  fi

  error="$(jq -r '.error' "$TMP/stdout")"
  repo="$(jq -r 'if (.repo | type == "string" and length > 0) then .repo else empty end' "$TMP/stdout")"
  reason="$(jq -r 'if (.reason | type == "string" and length > 0) then .reason else empty end' "$TMP/stdout")"
  hold_until="$(jq -r 'if (.until | type == "string" and length > 0) then .until else empty end' "$TMP/stdout")"
  message="$(jq -r 'if (.message | type == "string" and length > 0) then .message else empty end' "$TMP/stdout")"

  if [ -n "$message" ]; then
    deny "$HOOK_ID: $message"
  fi

  if [ "$error" = "repo_merge_held" ]; then
    repo_label="${repo:-unknown repo}"
    reason_label="${reason:-unspecified hold reason}"
    until_label="${hold_until:-unknown}"
    details=""
    [ -n "$repo" ] && details=" For details, run: hq lanes hold show $repo."
    deny "Repo merge hold for $repo_label: $reason_label. Until $until_label.$details"
  fi

  repo_label="${repo:-unknown repo}"
  response="$error for $repo_label"
  [ -n "$reason" ] && response="$response. Reason: $reason"
  [ -n "$hold_until" ] && response="$response. Until $hold_until"
  [ -n "$repo" ] && response="$response. For details, run: hq lanes hold show $repo."
  deny "$response"
fi

# This gate fails open by design to match hq-cli, which treats all check
# errors (including older CLIs without `lanes hold`) as allow. Capture child
# stderr so a timeout wrapper or older CLI still produces only one line.
allow_with_notice "hq lanes hold check did not confirm a hold (exit $status)"
