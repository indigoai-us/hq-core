#!/usr/bin/env bash
# Smoke tests for context-threshold checkpoint hooks.
#
# context-warning-50.sh is RETIRED (2026-09-07): Stop-hook stdout never reaches
# the model, and its transcript-size threshold was uncalibrated. These tests
# pin the retirement — the stub must stay silent at any transcript size and
# must not be registered anywhere — and keep the PreCompact directive, which
# is the one mechanical checkpoint trigger the model actually receives.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
CONTEXT_HOOK="$ROOT/.claude/hooks/context-warning-50.sh"
PRECOMPACT_HOOK="$ROOT/.claude/hooks/auto-checkpoint-precompact.sh"
PRECOMPACT_THRASH_HOOK="$ROOT/.claude/hooks/precompact-thrashing-detector.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local value="$1" needle="$2" label="$3"
  if [[ "$value" != *"$needle"* ]]; then
    fail "$label: expected to find '$needle' in output: $value"
  fi
}

assert_empty() {
  local value="$1" label="$2"
  if [ -n "$value" ]; then
    fail "$label: expected empty output, got: $value"
  fi
}

TRANSCRIPT="$TMP_ROOT/transcript.jsonl"
payload=$(printf '{"session_id":"s-test","transcript_path":"%s"}' "$TRANSCRIPT")

printf 'short' > "$TRANSCRIPT"
out=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" CLAUDE_CONTEXT_WINDOW=100 bash "$CONTEXT_HOOK" <<<"$payload")
assert_empty "$out" "retired hook is silent below any threshold"

python3 - "$TRANSCRIPT" <<'PY'
import pathlib, sys
pathlib.Path(sys.argv[1]).write_text("x" * 220)
PY
out=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" CLAUDE_CONTEXT_WINDOW=100 bash "$CONTEXT_HOOK" <<<"$payload")
assert_empty "$out" "retired hook is silent above the old threshold"
[ -d "$TMP_ROOT/workspace/.context-warnings" ] && fail "retired hook must not write state" || true

# The retirement must hold in dispatch, not just in the file.
if grep -q 'context-warning-50' "$ROOT/.claude/settings.json"; then
  fail "context-warning-50 is still registered in .claude/settings.json"
fi
if grep -q 'context-warning-50' "$ROOT/.claude/hooks/hook-gate.sh"; then
  fail "context-warning-50 is still allowlisted in hook-gate.sh"
fi

out_precompact=$(bash "$PRECOMPACT_HOOK")
assert_contains "$out_precompact" "AUTO-CHECKPOINT REQUIRED" "precompact directive"
assert_contains "$out_precompact" "run /checkpoint" "precompact checkpoint command"
assert_contains "$out_precompact" "Do not ask the user first" "precompact no prompt"

# Transcript byte accounting reads filesystem metadata and must retain the
# exact recorded size without scanning the transcript contents.
SIZE_ROOT="$TMP_ROOT/size-check"
mkdir -p "$SIZE_ROOT"
SIZE_TRANSCRIPT="$TMP_ROOT/size-check-transcript.jsonl"
printf '12345' > "$SIZE_TRANSCRIPT"
SIZE_PAYLOAD="$(printf '{"session_id":"s-size-check","transcript_path":"%s"}' "$SIZE_TRANSCRIPT")"
printf '%s' "$SIZE_PAYLOAD" | CLAUDE_PROJECT_DIR="$SIZE_ROOT" bash "$PRECOMPACT_THRASH_HOOK" >/dev/null 2>&1
SIZE_HISTORY="$SIZE_ROOT/workspace/.compact-history/s-size-check.jsonl"
grep -Fq '"bytes":5' "$SIZE_HISTORY" \
  || fail "precompact history did not preserve the transcript byte count"

echo "context checkpoint hooks smoke: ok"
