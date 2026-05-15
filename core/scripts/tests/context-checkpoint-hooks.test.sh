#!/usr/bin/env bash
# Smoke tests for context-threshold checkpoint hooks.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
CONTEXT_HOOK="$ROOT/.claude/hooks/context-warning-50.sh"
PRECOMPACT_HOOK="$ROOT/.claude/hooks/auto-checkpoint-precompact.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if ! printf '%s' "$haystack" | grep -qF "$needle"; then
    fail "$label: missing '$needle'"
  fi
}

assert_empty() {
  local value="$1"
  local label="$2"
  if [ -n "$value" ]; then
    fail "$label: expected empty output, got: $value"
  fi
}

[ -x "$CONTEXT_HOOK" ] || fail "context hook is not executable: $CONTEXT_HOOK"
[ -x "$PRECOMPACT_HOOK" ] || fail "precompact hook is not executable: $PRECOMPACT_HOOK"

mkdir -p "$TMP_ROOT/workspace"
TRANSCRIPT="$TMP_ROOT/transcript.jsonl"

printf 'short' > "$TRANSCRIPT"
payload=$(printf '{"session_id":"s-test","transcript_path":"%s"}' "$TRANSCRIPT")
out=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" CLAUDE_CONTEXT_WINDOW=100 bash "$CONTEXT_HOOK" <<<"$payload")
assert_empty "$out" "below threshold is quiet"

python3 - "$TRANSCRIPT" <<'PY'
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_text("x" * 220)
PY

out=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" CLAUDE_CONTEXT_WINDOW=100 bash "$CONTEXT_HOOK" <<<"$payload")
assert_contains "$out" "AUTO-CHECKPOINT REQUIRED" "50 percent directive"
assert_contains "$out" "Run /checkpoint now" "50 percent checkpoint command"
assert_contains "$out" "Do not ask the user first" "50 percent no prompt"

out_again=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" CLAUDE_CONTEXT_WINDOW=100 bash "$CONTEXT_HOOK" <<<"$payload")
assert_empty "$out_again" "context hook fires once per session"

escape_payload=$(printf '{"session_id":"../outside/session","transcript_path":"%s"}' "$TRANSCRIPT")
out_escape=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" CLAUDE_CONTEXT_WINDOW=100 bash "$CONTEXT_HOOK" <<<"$escape_payload")
assert_contains "$out_escape" "AUTO-CHECKPOINT REQUIRED" "escaped session id still triggers"
if [ -e "$TMP_ROOT/outside/session" ] || [ -d "$TMP_ROOT/outside" ]; then
  fail "session id escaped state directory"
fi

out_precompact=$(bash "$PRECOMPACT_HOOK")
assert_contains "$out_precompact" "AUTO-CHECKPOINT REQUIRED" "precompact directive"
assert_contains "$out_precompact" "run /checkpoint" "precompact checkpoint command"
assert_contains "$out_precompact" "Do not ask the user first" "precompact no prompt"

echo "context checkpoint hooks smoke: ok"
