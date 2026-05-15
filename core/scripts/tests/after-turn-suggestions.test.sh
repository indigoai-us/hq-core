#!/usr/bin/env bash
# Smoke tests for the global after-turn suggestion Stop hook.

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$SRC_ROOT/hooks/Stop/50-after-turn-suggestions.sh"
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

[ -x "$HOOK" ] || fail "hook is not executable: $HOOK"

mkdir -p "$TMP_ROOT/.claude/state" "$TMP_ROOT/workspace" "$TMP_ROOT/projects/demo/journal"

cat > "$TMP_ROOT/projects/demo/journal/active.md" <<'EOF'
---
skill: prd
started_at: 2026-05-13T00:00:00Z
thread_id: test
project: projects/demo
status: active
auto_capture: true
summary: ""
---

## Decisions
EOF

printf '%s' "$TMP_ROOT/projects/demo/journal/active.md" > "$TMP_ROOT/.claude/state/active-journal"

cat > "$TMP_ROOT/projects/demo/prd.json" <<'EOF'
{
  "name": "demo",
  "userStories": [
    { "id": "US-001", "title": "First story", "passes": false },
    { "id": "US-002", "title": "Second story", "passes": true }
  ]
}
EOF

TRANSCRIPT="$TMP_ROOT/transcript.jsonl"
cat > "$TRANSCRIPT" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"text","text":"Project **demo** created with 2 user stories.\nFiles:\n  projects/demo/prd.json"}]}}
EOF

payload=$(printf '{"session_id":"s-test","transcript_path":"%s"}' "$TRANSCRIPT")

out=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" HQ_AFTER_TURN_SUGGESTIONS=1 bash "$HOOK" <<<"$payload")
assert_contains "$out" "<hq-suggestions>" "suggestion wrapper"
assert_contains "$out" "/execute-task demo/US-001" "next incomplete story suggestion"
assert_contains "$out" "HQ_AFTER_TURN_SUGGESTIONS=0" "first-run disable hint"

out_disabled=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" HQ_AFTER_TURN_SUGGESTIONS=0 bash "$HOOK" <<<"$payload")
assert_empty "$out_disabled" "HQ_AFTER_TURN_SUGGESTIONS=0 disables hook"

out_disabled_hook=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" HQ_DISABLED_HOOKS=after-turn-suggestions bash "$HOOK" <<<"$payload")
assert_empty "$out_disabled_hook" "HQ_DISABLED_HOOKS disables hook"

touch "$TMP_ROOT/.claude/state/after-turn-suggestions.disabled"
out_disabled_file=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" bash "$HOOK" <<<"$payload")
assert_empty "$out_disabled_file" "state file disables hook"

echo "after-turn-suggestions smoke: ok"
