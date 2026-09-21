#!/usr/bin/env bash
# Smoke tests for the auto-conduct SessionStart hook (conduct mode as the
# session default, driven by the `conduct:` block of orchestrator.yaml).

set -euo pipefail

HQ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$HQ_ROOT/.claude/hooks/auto-conduct.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  if ! printf '%s' "$haystack" | grep -qF -e "$needle"; then
    fail "$label: missing '$needle'"
  fi
}

assert_empty() {
  local value="$1" label="$2"
  if [ -n "$value" ]; then
    fail "$label: expected empty output, got: $value"
  fi
}

[ -x "$HOOK" ] || fail "hook is not executable: $HOOK"

mkdir -p "$TMP_ROOT/core/settings" "$TMP_ROOT/core/scripts" "$TMP_ROOT/personal/settings"

# Stub hq-session.sh so the test can see what the hook persisted.
SET_LOG="$TMP_ROOT/set.log"
cat > "$TMP_ROOT/core/scripts/hq-session.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SET_LOG"
STUB
chmod +x "$TMP_ROOT/core/scripts/hq-session.sh"

write_core() {
  cat > "$TMP_ROOT/core/settings/orchestrator.yaml" <<YAML
file_locking:
  enabled: true
conduct:
  default_enabled: $1
  default_engine: $2   # trailing comment
swarm:
  max_concurrency: 4
YAML
}

payload='{"hook_event_name":"SessionStart","source":"startup","session_id":"s-test"}'

# 1. Shipped default: off → silent, nothing persisted.
write_core false codex
out=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" bash "$HOOK" <<<"$payload")
assert_empty "$out" "default_enabled false stays silent"
[ ! -f "$SET_LOG" ] || fail "disabled setting must not persist conduct_engine"

# 2. Enabled → instruction emitted and engine persisted for the session.
write_core true grok
out=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" bash "$HOOK" <<<"$payload")
assert_contains "$out" "<auto-conduct>" "enabled wrapper"
assert_contains "$out" "/conduct grok" "enabled command uses configured engine"
assert_contains "$(cat "$SET_LOG")" "--session-id s-test set conduct_engine grok" "engine persisted to session"

# 3. Missing engine falls back to codex.
rm -f "$SET_LOG"
cat > "$TMP_ROOT/core/settings/orchestrator.yaml" <<'YAML'
conduct:
  default_enabled: true
YAML
out=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" bash "$HOOK" <<<"$payload")
assert_contains "$out" "/conduct codex" "missing engine defaults to codex"

# 4. Unknown engine falls back to codex with a warning on stderr.
write_core true gemini
err=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" bash "$HOOK" <<<"$payload" 2>&1 >/dev/null)
out=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" bash "$HOOK" <<<"$payload" 2>/dev/null)
assert_contains "$err" "unknown conduct.default_engine" "unknown engine warns"
assert_contains "$out" "/conduct codex" "unknown engine defaults to codex"

# 5. Personal settings override the shipped file.
write_core false codex
cat > "$TMP_ROOT/personal/settings/orchestrator.yaml" <<'YAML'
conduct:
  default_enabled: true
  default_engine: claude
YAML
out=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" bash "$HOOK" <<<"$payload")
assert_contains "$out" "/conduct claude" "personal override wins"
rm -f "$TMP_ROOT/personal/settings/orchestrator.yaml"

# 6. Env overrides: HQ_AUTO_CONDUCT=0 silences an enabled setting,
#    HQ_AUTO_CONDUCT=1 turns on a disabled one, HQ_DISABLED_HOOKS opts out.
write_core true codex
out=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" HQ_AUTO_CONDUCT=0 bash "$HOOK" <<<"$payload")
assert_empty "$out" "HQ_AUTO_CONDUCT=0 disables hook"
out=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" HQ_DISABLED_HOOKS=auto-conduct bash "$HOOK" <<<"$payload")
assert_empty "$out" "HQ_DISABLED_HOOKS disables hook"
write_core false grok
out=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" HQ_AUTO_CONDUCT=1 bash "$HOOK" <<<"$payload")
assert_contains "$out" "/conduct grok" "HQ_AUTO_CONDUCT=1 forces on with configured engine"

# 7. Only fresh sessions bootstrap.
write_core true codex
out=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" bash "$HOOK" <<<'{"source":"resume","session_id":"s-test"}')
assert_empty "$out" "resume source does not auto-conduct"
out=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" bash "$HOOK" <<<'{"source":"compact","session_id":"s-test"}')
assert_empty "$out" "compact source does not auto-conduct"

# 8. No settings file at all → silent.
rm -f "$TMP_ROOT/core/settings/orchestrator.yaml"
out=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" bash "$HOOK" <<<"$payload")
assert_empty "$out" "missing settings file stays silent"

echo "auto-conduct smoke: ok"
