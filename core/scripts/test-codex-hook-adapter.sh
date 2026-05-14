#!/bin/bash
# Focused regression tests for .codex/hooks/hq-codex-hook-adapter.sh.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/.codex/hooks" "$TMP/.claude/hooks"
cp "$ROOT/.codex/hooks/hq-codex-hook-adapter.sh" "$TMP/.codex/hooks/hq-codex-hook-adapter.sh"
chmod +x "$TMP/.codex/hooks/hq-codex-hook-adapter.sh"

git -C "$TMP" init -q

cat > "$TMP/.claude/hooks/hook-gate.sh" <<'SH'
#!/bin/bash
set -euo pipefail
hook_id="$1"
script="$2"
shift 2
echo "$hook_id" >> "$TEST_LOG"
"$script" "$@"
SH
chmod +x "$TMP/.claude/hooks/hook-gate.sh"

cat > "$TMP/.claude/hooks/detect-secrets.sh" <<'SH'
#!/bin/bash
input="$(cat)"
if printf '%s' "$input" | grep -q 'sk-testSECRET'; then
  echo "blocked secret" >&2
  exit 2
fi
exit 0
SH

cat > "$TMP/.claude/hooks/block-on-active-run.sh" <<'SH'
#!/bin/bash
input="$(cat)"
path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')"
[ -n "$path" ] && echo "active-run:$path" >> "$TEST_LOG"
if [ "$path" = "blocked.txt" ]; then
  echo "blocked active run" >&2
  exit 2
fi
exit 0
SH

cat > "$TMP/.claude/hooks/protect-core.sh" <<'SH'
#!/bin/bash
input="$(cat)"
path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')"
echo "protect:$path" >> "$TEST_LOG"
if [ "$path" = ".claude/settings.json" ]; then
  echo "blocked core" >&2
  exit 2
fi
exit 0
SH

cat > "$TMP/.claude/hooks/auto-checkpoint-trigger.sh" <<'SH'
#!/bin/bash
cat >/dev/null
echo "AUTO-CHECKPOINT REQUIRED"
SH

cat > "$TMP/.claude/hooks/auto-capture-registry.sh" <<'SH'
#!/bin/bash
cat >/dev/null
exit 0
SH

cat > "$TMP/.claude/hooks/load-policies-for-session.sh" <<'SH'
#!/bin/bash
cat >/dev/null
echo "POLICY"
SH

cat > "$TMP/.claude/hooks/inject-local-context.sh" <<'SH'
#!/bin/bash
cat >/dev/null
echo "LOCAL"
SH

cat > "$TMP/.claude/hooks/auto-startwork.sh" <<'SH'
#!/bin/bash
cat >/dev/null
echo "AUTO-STARTWORK"
SH

cat > "$TMP/.claude/hooks/observe-patterns.sh" <<'SH'
#!/bin/bash
cat >/dev/null
echo "OBSERVE"
SH

cat > "$TMP/.claude/hooks/cleanup-mcp-processes.sh" <<'SH'
#!/bin/bash
cat >/dev/null
exit 0
SH

cat > "$TMP/.claude/hooks/context-warning-50.sh" <<'SH'
#!/bin/bash
cat >/dev/null
exit 0
SH

cat > "$TMP/.claude/hooks/capture-estimates.sh" <<'SH'
#!/bin/bash
cat >/dev/null
exit 0
SH

cat > "$TMP/.claude/hooks/precompact-thrashing-detector.sh" <<'SH'
#!/bin/bash
cat >/dev/null
exit 0
SH

cat > "$TMP/.claude/hooks/auto-checkpoint-precompact.sh" <<'SH'
#!/bin/bash
cat >/dev/null
echo "PRECOMPACT CHECKPOINT"
SH

cat > "$TMP/.claude/hooks/journal-precompact.sh" <<'SH'
#!/bin/bash
cat >/dev/null
exit 0
SH

chmod +x "$TMP/.claude/hooks/"*.sh

ADAPTER="$TMP/.codex/hooks/hq-codex-hook-adapter.sh"
export TEST_LOG="$TMP/hook-calls.log"

run_adapter() {
  local payload="$1"
  (cd "$TMP" && printf '%s' "$payload" | "$ADAPTER")
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if ! printf '%s' "$haystack" | grep -qF "$needle"; then
    echo "Expected output to contain: $needle" >&2
    echo "Actual output:" >&2
    printf '%s\n' "$haystack" >&2
    exit 1
  fi
}

payload_session='{"hook_event_name":"SessionStart","source":"startup","cwd":"'"$TMP"'","session_id":"s1","model":"test"}'
out="$(run_adapter "$payload_session")"
assert_contains "$out" "POLICY"
assert_contains "$out" "LOCAL"
assert_contains "$out" "AUTO-STARTWORK"

payload_secret='{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"'"$TMP"'","tool_input":{"command":"echo sk-testSECRET1234567890"}}'
if err="$(run_adapter "$payload_secret" 2>&1 >/dev/null)"; then
  echo "Expected secret payload to be blocked" >&2
  exit 1
fi
assert_contains "$err" "blocked secret"

payload_patch_core='{"hook_event_name":"PreToolUse","tool_name":"apply_patch","cwd":"'"$TMP"'","tool_input":{"command":"*** Begin Patch\n*** Update File: .claude/settings.json\n@@\n x\n*** End Patch"}}'
if err="$(run_adapter "$payload_patch_core" 2>&1 >/dev/null)"; then
  echo "Expected protected apply_patch payload to be blocked" >&2
  exit 1
fi
assert_contains "$err" "blocked core"
assert_contains "$(cat "$TEST_LOG")" "protect:.claude/settings.json"

payload_post_patch='{"hook_event_name":"PostToolUse","tool_name":"apply_patch","cwd":"'"$TMP"'","tool_input":{"command":"*** Begin Patch\n*** Add File: docs/test.md\n+ok\n*** End Patch"},"tool_response":{"exit_code":0}}'
out="$(run_adapter "$payload_post_patch")"
printf '%s' "$out" | python3 -m json.tool >/dev/null
assert_contains "$out" "AUTO-CHECKPOINT REQUIRED"

payload_stop='{"hook_event_name":"Stop","cwd":"'"$TMP"'","last_assistant_message":"done"}'
out="$(run_adapter "$payload_stop")"
printf '%s' "$out" | python3 -m json.tool >/dev/null
assert_contains "$out" "OBSERVE"
assert_contains "$(cat "$TEST_LOG")" "context-warning-50"

payload_precompact='{"hook_event_name":"PreCompact","cwd":"'"$TMP"'","session_id":"s1"}'
out="$(run_adapter "$payload_precompact")"
printf '%s' "$out" | python3 -m json.tool >/dev/null
assert_contains "$out" "PRECOMPACT CHECKPOINT"

echo "codex hook adapter tests passed"
