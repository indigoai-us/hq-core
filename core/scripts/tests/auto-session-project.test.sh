#!/usr/bin/env bash
# Smoke tests for auto-session-project UserPromptSubmit hook.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$label: missing '$needle'"
}

assert_empty() {
  local value="$1" label="$2"
  [ -z "$value" ] || fail "$label: expected empty output, got: $value"
}

mkdir -p "$TMP/.claude/hooks" "$TMP/core/scripts" "$TMP/personal/projects/native-project-journaling"
cp "$ROOT/.claude/hooks/auto-session-project.sh" "$TMP/.claude/hooks/auto-session-project.sh"
cp "$ROOT/core/scripts/session-project.sh" "$TMP/core/scripts/session-project.sh"
# The hook sources hook-lib.sh relative to its own location (../../core/scripts).
cp "$ROOT/core/scripts/hook-lib.sh" "$TMP/core/scripts/hook-lib.sh"
chmod +x "$TMP/.claude/hooks/auto-session-project.sh" "$TMP/core/scripts/session-project.sh"

cat > "$TMP/personal/projects/native-project-journaling/prd.json" <<'JSON'
{
  "name": "native-project-journaling",
  "description": "Automatically journal native Claude and Codex executions into project folders and prd.json files.",
  "metadata": {
    "goal": "Native plan mode project capture"
  },
  "userStories": []
}
JSON

payload='{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"in hqwork make native claude/codex executions automatically journal to project prd files"}'
out=$(CLAUDE_PROJECT_DIR="$TMP" "$TMP/.claude/hooks/auto-session-project.sh" <<<"$payload")
assert_contains "$out" "auto-session-project" "context wrapper"
assert_contains "$out" "personal/projects/native-project-journaling" "reused related project"
assert_contains "$(cat "$TMP/.claude/state/active-session-project")" "native-project-journaling" "active pointer"

out_second=$(CLAUDE_PROJECT_DIR="$TMP" "$TMP/.claude/hooks/auto-session-project.sh" <<<"$payload")
assert_empty "$out_second" "second prompt is quiet"

payload_traversal='{"hook_event_name":"UserPromptSubmit","session_id":"../escape","prompt":"in hqwork make native claude/codex executions automatically journal to project prd files"}'
out_traversal=$(CLAUDE_PROJECT_DIR="$TMP" "$TMP/.claude/hooks/auto-session-project.sh" <<<"$payload_traversal")
assert_contains "$out_traversal" "auto-session-project" "traversal payload still handled"
[ -f "$TMP/.claude/state/auto-session-project-.._escape" ] || fail "sanitized session marker missing"
[ ! -e "$TMP/.claude/escape" ] || fail "session id escaped state dir"

out_disabled=$(CLAUDE_PROJECT_DIR="$TMP" HQ_AUTO_SESSION_PROJECT=0 "$TMP/.claude/hooks/auto-session-project.sh" <<<"$payload")
assert_empty "$out_disabled" "disabled env is quiet"

out_trivial=$(CLAUDE_PROJECT_DIR="$TMP" "$TMP/.claude/hooks/auto-session-project.sh" <<<'{"session_id":"s2","prompt":"thanks"}')
assert_empty "$out_trivial" "trivial prompt is quiet"

echo "auto-session-project smoke: ok"
