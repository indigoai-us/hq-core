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

# 1. default_enabled: false → silent (the per-machine off switch).
write_core false
out=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" bash "$HOOK" <<<"$payload")
assert_empty "$out" "default_enabled false stays silent"

# 1b. The shipped core/settings/orchestrator.yaml has conduct on (v16 default),
#     and the hook, run against the real tree with no personal override,
#     emits the conductor core. HQ_AUTO_CONDUCT is cleared so an operator's
#     own environment cannot make this pass or fail.
shipped="$(awk '
  /^[^[:space:]#]/ { in_block = ($0 ~ /^conduct:[[:space:]]*(#.*)?$/) ; next }
  in_block && /^[[:space:]]+default_enabled:/ { sub(/^[^:]+:[[:space:]]*/, ""); sub(/[[:space:]]*#.*$/, ""); print; exit }
' "$HQ_ROOT/core/settings/orchestrator.yaml")"
[ "$shipped" = "true" ] || fail "shipped core/settings/orchestrator.yaml must carry conduct.default_enabled: true (got '${shipped:-<empty>}')"
SHIPPED_ROOT="$TMP_ROOT/shipped"
mkdir -p "$SHIPPED_ROOT/core/settings" "$SHIPPED_ROOT/core/scripts"
cp "$HQ_ROOT/core/settings/orchestrator.yaml" "$SHIPPED_ROOT/core/settings/orchestrator.yaml"
cp "$TMP_ROOT/core/scripts/hq-session.sh" "$SHIPPED_ROOT/core/scripts/hq-session.sh"
out=$(env -u HQ_AUTO_CONDUCT -u HQ_DISABLED_HOOKS CLAUDE_PROJECT_DIR="$SHIPPED_ROOT" bash "$HOOK" <<<"$payload")
assert_contains "$out" "<auto-conduct>" "shipped settings open a fresh session in conduct mode"
assert_not_contains "$out" "ask which engine" "shipped default still asks no engine at session start"

# 2. Enabled → instruction emitted, no engine chosen, nothing persisted.
write_core true
out=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" bash "$HOOK" <<<"$payload")
assert_contains "$out" "<auto-conduct>" "enabled wrapper"
assert_contains "$out" "Triage each message" "enabled block carries the conductor core triage rule"
assert_contains "$out" "intent-index.yaml" "enabled block points at the intent index"
assert_not_contains "$out" "ask which engine" "no engine question at session start"
assert_not_contains "$out" 'Run `/conduct` now' "no instruction to run /conduct before any task"
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
assert_contains "$out" "<auto-conduct>" "legacy default_engine key ignored"
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

# 5b. Unattended sessions never get the block: a bot or a box has nobody to
#     answer the engine question and must not spawn lanes. Each marker is the
#     one that runtime already exports (local bot: HQ_BOT_AGENT_UID or
#     HQ_MACHINE_CREDS_FILE; fleet box: HQ_AGENT_CLAUDE_TASKFILE,
#     HQ_AGENT_COMPANY_DIR, HQ_AGENT_STATUS_FILE; launchers: HQ_UNATTENDED,
#     HQ_SESSION_UNATTENDED, CLAUDE_HEADLESS). HQ_AUTO_CONDUCT=1 is the one
#     way back in, for a brief that names its engine.
write_core true
for marker in HQ_UNATTENDED=1 HQ_SESSION_UNATTENDED=true CLAUDE_HEADLESS=1 \
              HQ_BOT_AGENT_UID=agt_test HQ_MACHINE_CREDS_FILE=/tmp/creds.json \
              HQ_AGENT_CLAUDE_TASKFILE=/tmp/task.txt HQ_AGENT_COMPANY_DIR=/tmp/co \
              HQ_AGENT_STATUS_FILE=/tmp/status.json; do
  out=$(env -u HQ_AUTO_CONDUCT "$marker" CLAUDE_PROJECT_DIR="$TMP_ROOT" bash "$HOOK" <<<"$payload")
  assert_empty "$out" "unattended marker $marker stays silent"
done
out=$(env HQ_UNATTENDED=1 HQ_AUTO_CONDUCT=1 CLAUDE_PROJECT_DIR="$TMP_ROOT" bash "$HOOK" <<<"$payload")
assert_contains "$out" "<auto-conduct>" "HQ_AUTO_CONDUCT=1 overrides the unattended gate"
assert_not_contains "$out" "ask which engine" "unattended override still asks no engine"
# A value of 0/false on the flags is attended.
out=$(env -u HQ_AUTO_CONDUCT HQ_UNATTENDED=0 HQ_SESSION_UNATTENDED=false CLAUDE_HEADLESS=0 CLAUDE_PROJECT_DIR="$TMP_ROOT" bash "$HOOK" <<<"$payload")
assert_contains "$out" "<auto-conduct>" "unattended flags set to 0/false do not gate"

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


# 8. With the conductor core doc present, the block between the inject markers
#    is emitted verbatim and stays under the size budget.
write_core true
mkdir -p "$TMP_ROOT/.claude/skills/conduct"
cp "$HQ_ROOT/.claude/skills/conduct/conductor-core.md" "$TMP_ROOT/.claude/skills/conduct/conductor-core.md"
out=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" bash "$HOOK" <<<"$payload")
expected="$(awk '/<!-- inject:start -->/ { on = 1; next } /<!-- inject:end -->/ { on = 0 } on' "$TMP_ROOT/.claude/skills/conduct/conductor-core.md")"
[ "$out" = "$expected" ] || fail "core doc inject block not emitted verbatim"
bytes=$(printf '%s' "$out" | wc -c | tr -d ' ')
[ "$bytes" -le 750 ] || fail "conductor core inject block is $bytes bytes; budget is 750"
assert_not_contains "$out" "engine to use" "core doc never asks the engine question"

echo "auto-conduct smoke: ok"
