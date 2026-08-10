#!/usr/bin/env bash
# hq-core: public
# harness-settings-dispatch.test.sh
#
# Parity guard for single-source hook dispatch. The Codex and Grok adapters read
# .claude/settings.json live (via core/scripts/lib/hook-adapter-core.sh) instead
# of carrying their own hand-written dispatch tables. This test proves that for
# every event/tool, each adapter dispatches AT LEAST every hook settings.json
# registers for Claude — i.e. neither adapter can silently drop a hook again
# (the drift this design removes). It also pins the specific hooks that were
# previously missing (Grok: checkpoint-stop-gate, mandatory-scope-authorizer;
# Codex: warn-cross-company-settings, block-hq-glob).
#
# Mechanism: a throwaway fixture HQ root with a STUB hook-gate.sh / master-hook.sh
# that record the hook-id they are handed instead of running the real hook. The
# real settings.json, hook-adapter-core.sh, and both adapters are copied in. We
# feed each adapter a benign event payload and diff the recorded ids against the
# settings-derived expectation.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
SRC_SETTINGS="$ROOT/.claude/settings.json"
SRC_CORE="$ROOT/core/scripts/lib/hook-adapter-core.sh"
SRC_CODEX="$ROOT/.codex/hooks/hq-codex-hook-adapter.sh"
SRC_GROK="$ROOT/.grok/hooks/hq-grok-hook-adapter.sh"

FAIL=0
pass() { echo "  ok: $1"; }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable" >&2; exit 0; }

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

mkdir -p "$FIX/.claude/hooks" "$FIX/.codex/hooks" "$FIX/.grok/hooks" \
         "$FIX/core/scripts/lib"
cp "$SRC_SETTINGS" "$FIX/.claude/settings.json"
cp "$SRC_CORE" "$FIX/core/scripts/lib/hook-adapter-core.sh"
cp "$SRC_CODEX" "$FIX/.codex/hooks/hq-codex-hook-adapter.sh"
cp "$SRC_GROK" "$FIX/.grok/hooks/hq-grok-hook-adapter.sh"
# Empty hook-lib so the adapters take the plain `bash "$GATE" <id> <script>`
# fallback path (no hq_launch_shell_path), which the stub gate below records.
: > "$FIX/core/scripts/hook-lib.sh"
: > "$FIX/core/scripts/migrate-policy-triggers.sh"

# Stub gate: drain stdin FIRST (avoid SIGPIPE to the caller's printf under
# pipefail), then record the hook-id ($1). Never runs the real hook.
cat > "$FIX/.claude/hooks/hook-gate.sh" <<'STUB'
#!/bin/bash
cat >/dev/null 2>&1 || true
{ printf 'gate:%s\n' "$1" >> "${HQAD_TEST_LOG:-/dev/null}"; } 2>/dev/null || true
exit 0
STUB
# Stub master-hook + reindex (script-kind) so their dispatch is recorded too.
cat > "$FIX/.claude/hooks/master-hook.sh" <<'STUB'
#!/bin/bash
cat >/dev/null 2>&1 || true
{ printf 'master:%s\n' "$1" >> "${HQAD_TEST_LOG:-/dev/null}"; } 2>/dev/null || true
exit 0
STUB
cat > "$FIX/.claude/hooks/reindex.sh" <<'STUB'
#!/bin/bash
cat >/dev/null 2>&1 || true
{ printf 'script:reindex\n' >> "${HQAD_TEST_LOG:-/dev/null}"; } 2>/dev/null || true
exit 0
STUB
# Every other referenced hook script must exist (adapters/mode-check stat them)
# and be harmless if ever exec'd directly (script-kind). Stub them all.
for id in $(jq -r '.hooks[][]?.hooks[]?.command' "$FIX/.claude/settings.json" \
              | grep -oE '/[a-z0-9-]+\.sh"' | tr -d '/"' | sort -u); do
  f="$FIX/.claude/hooks/$id"
  [ -e "$f" ] && continue
  printf '#!/bin/bash\nexit 0\n' > "$f"
done
chmod +x "$FIX/.claude/hooks/"*.sh 2>/dev/null || true
# The Codex-only supplement + auto-capture-registry live under .claude/hooks too.
for extra in inject-codex-checkpoint-reprompt auto-capture-registry; do
  f="$FIX/.claude/hooks/$extra.sh"
  [ -e "$f" ] || { printf '#!/bin/bash\nexit 0\n' > "$f"; chmod +x "$f"; }
done

export HQ_ROOT="$FIX" HQ_ALLOW_HQ_WORKTREE=1

# settings-derived expected gate ids for an (event, canonical_tool).
expected_gate_ids() {
  local event="$1" tool="$2"
  ( set +u; . "$FIX/core/scripts/lib/hook-adapter-core.sh"
    HQ_ROOT="$FIX" hqad_iter_settings "$event" "$tool" \
      | awk -F'\t' '$1=="gate"{print $2}' | sort -u )
}

# recorded gate ids after running an adapter with a payload.
recorded_gate_ids() {
  local adapter="$1" payload="$2" log
  log="$(mktemp)"
  HQAD_TEST_LOG="$log" HQ_ROOT="$FIX" HQ_ALLOW_HQ_WORKTREE=1 \
    bash "$adapter" >/dev/null 2>&1 <<<"$payload" || true
  grep '^gate:' "$log" 2>/dev/null | sed 's/^gate://' | sort -u
  rm -f "$log"
}

# Assert recorded ⊇ expected (adapter drops nothing settings registers).
assert_superset() {
  local label="$1" expected="$2" recorded="$3" missing
  missing="$(comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$recorded"))"
  if [ -z "$missing" ]; then
    pass "$label dispatches all settings hooks"
  else
    fail "$label DROPPED: $(printf '%s' "$missing" | tr '\n' ' ')"
  fi
}

assert_contains() {
  local label="$1" set="$2" needle="$3"
  if printf '%s\n' "$set" | grep -qx "$needle"; then
    pass "$label runs $needle"
  else
    fail "$label MISSING $needle"
  fi
}

echo "[codex] event/tool dispatch parity"
cx_bash='{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"'"$FIX"'","session_id":"t","tool_input":{"command":"echo hi"}}'
cx_read='{"hook_event_name":"PreToolUse","tool_name":"Read","cwd":"'"$FIX"'","session_id":"t","tool_input":{"file_path":"'"$FIX"'/README"}}'
cx_glob='{"hook_event_name":"PreToolUse","tool_name":"Glob","cwd":"'"$FIX"'","session_id":"t","tool_input":{"path":"'"$FIX"'"}}'
cx_stop='{"hook_event_name":"Stop","cwd":"'"$FIX"'","session_id":"t"}'
assert_superset "codex PreToolUse/Bash" "$(expected_gate_ids PreToolUse Bash)" "$(recorded_gate_ids "$FIX/.codex/hooks/hq-codex-hook-adapter.sh" "$cx_bash")"
CX_READ="$(recorded_gate_ids "$FIX/.codex/hooks/hq-codex-hook-adapter.sh" "$cx_read")"
assert_superset "codex PreToolUse/Read" "$(expected_gate_ids PreToolUse Read)" "$CX_READ"
assert_contains "codex Read" "$CX_READ" "warn-cross-company-settings"
CX_GLOB="$(recorded_gate_ids "$FIX/.codex/hooks/hq-codex-hook-adapter.sh" "$cx_glob")"
assert_contains "codex Glob" "$CX_GLOB" "block-hq-glob"
CX_STOP="$(recorded_gate_ids "$FIX/.codex/hooks/hq-codex-hook-adapter.sh" "$cx_stop")"
assert_superset "codex Stop" "$(expected_gate_ids Stop ANY)" "$CX_STOP"
assert_contains "codex Stop" "$CX_STOP" "checkpoint-stop-gate"

echo "[grok] event/tool dispatch parity"
gk_bash='{"hookEventName":"PreToolUse","toolName":"run_terminal_command","cwd":"'"$FIX"'","sessionId":"t","toolInput":{"command":"echo hi"}}'
gk_read='{"hookEventName":"PreToolUse","toolName":"read_file","cwd":"'"$FIX"'","sessionId":"t","toolInput":{"file_path":"'"$FIX"'/README"}}'
gk_glob='{"hookEventName":"PreToolUse","toolName":"list_dir","cwd":"'"$FIX"'","sessionId":"t","toolInput":{"target_directory":"'"$FIX"'"}}'
gk_stop='{"hookEventName":"Stop","cwd":"'"$FIX"'","sessionId":"t"}'
GK_BASH="$(recorded_gate_ids "$FIX/.grok/hooks/hq-grok-hook-adapter.sh" "$gk_bash")"
assert_superset "grok PreToolUse/Bash" "$(expected_gate_ids PreToolUse Bash)" "$GK_BASH"
assert_contains "grok Bash" "$GK_BASH" "mandatory-scope-authorizer"
GK_READ="$(recorded_gate_ids "$FIX/.grok/hooks/hq-grok-hook-adapter.sh" "$gk_read")"
assert_superset "grok PreToolUse/Read" "$(expected_gate_ids PreToolUse Read)" "$GK_READ"
GK_GLOB="$(recorded_gate_ids "$FIX/.grok/hooks/hq-grok-hook-adapter.sh" "$gk_glob")"
assert_contains "grok Glob" "$GK_GLOB" "block-hq-glob"
GK_STOP="$(recorded_gate_ids "$FIX/.grok/hooks/hq-grok-hook-adapter.sh" "$gk_stop")"
assert_superset "grok Stop" "$(expected_gate_ids Stop ANY)" "$GK_STOP"
assert_contains "grok Stop" "$GK_STOP" "checkpoint-stop-gate"

if [ "$FAIL" -eq 0 ]; then
  echo "harness-settings-dispatch: all passed"
  exit 0
fi
echo "harness-settings-dispatch: $FAIL failed" >&2
exit 1
