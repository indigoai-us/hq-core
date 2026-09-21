#!/usr/bin/env bash
# Smoke tests for the auto-conduct SessionStart hook (conduct mode as the
# session default, driven by the `conduct:` block of orchestrator.yaml).
# There is no default engine: the hook must never pick one.

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

assert_not_contains() {
  local haystack="$1" needle="$2" label="$3"
  if printf '%s' "$haystack" | grep -qF -e "$needle"; then
    fail "$label: unexpected '$needle'"
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

# Stub hq-session.sh: the hook must never persist an engine on its own.
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
  default_enabled: $1   # trailing comment
swarm:
  max_concurrency: 4
YAML
}

payload='{"hook_event_name":"SessionStart","source":"startup","session_id":"s-test"}'

# 1. Shipped default: off → silent.
write_core false
out=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" bash "$HOOK" <<<"$payload")
assert_empty "$out" "default_enabled false stays silent"

# 2. Enabled → instruction emitted, no engine chosen, nothing persisted.
write_core true
out=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" bash "$HOOK" <<<"$payload")
assert_contains "$out" "<auto-conduct>" "enabled wrapper"
assert_contains "$out" 'Run `/conduct` now' "enabled command has no engine argument"
assert_contains "$out" "ask which engine to use" "instruction tells the assistant to ask"
assert_not_contains "$out" "/conduct codex" "no engine preset (codex)"
assert_not_contains "$out" "/conduct claude" "no engine preset (claude)"
[ ! -f "$SET_LOG" ] || fail "hook must not persist conduct_engine"

# 3. A stale default_engine key is ignored, not honoured.
cat > "$TMP_ROOT/core/settings/orchestrator.yaml" <<'YAML'
conduct:
  default_enabled: true
  default_engine: grok
YAML
out=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" bash "$HOOK" <<<"$payload")
assert_contains "$out" 'Run `/conduct` now' "legacy default_engine key ignored"
assert_not_contains "$out" "grok" "legacy default_engine value never surfaces"

# 4. Personal settings override the shipped file.
write_core false
cat > "$TMP_ROOT/personal/settings/orchestrator.yaml" <<'YAML'
conduct:
  default_enabled: true
YAML
out=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" bash "$HOOK" <<<"$payload")
assert_contains "$out" "<auto-conduct>" "personal override wins"
rm -f "$TMP_ROOT/personal/settings/orchestrator.yaml"

# 5. Env overrides: HQ_AUTO_CONDUCT=0 silences an enabled setting,
#    HQ_AUTO_CONDUCT=1 turns on a disabled one, HQ_DISABLED_HOOKS opts out.
write_core true
out=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" HQ_AUTO_CONDUCT=0 bash "$HOOK" <<<"$payload")
assert_empty "$out" "HQ_AUTO_CONDUCT=0 disables hook"
out=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" HQ_DISABLED_HOOKS=auto-conduct bash "$HOOK" <<<"$payload")
assert_empty "$out" "HQ_DISABLED_HOOKS disables hook"
write_core false
out=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" HQ_AUTO_CONDUCT=1 bash "$HOOK" <<<"$payload")
assert_contains "$out" "<auto-conduct>" "HQ_AUTO_CONDUCT=1 forces on"

# 6. Only fresh sessions bootstrap.
write_core true
out=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" bash "$HOOK" <<<'{"source":"resume","session_id":"s-test"}')
assert_empty "$out" "resume source does not auto-conduct"
out=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" bash "$HOOK" <<<'{"source":"compact","session_id":"s-test"}')
assert_empty "$out" "compact source does not auto-conduct"

# 7. No settings file at all → silent.
rm -f "$TMP_ROOT/core/settings/orchestrator.yaml"
out=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" bash "$HOOK" <<<"$payload")
assert_empty "$out" "missing settings file stays silent"

echo "auto-conduct smoke: ok"
