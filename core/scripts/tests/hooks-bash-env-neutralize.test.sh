#!/usr/bin/env bash
# Regression: HQ hook entry points must neutralize BASH_ENV so child bash
# processes on the hook path do not source the host profile.
#
# Hosts like Claude Code export BASH_ENV to a user profile. Each non-interactive
# bash then sources that file before running (nvm in the profile is ~1-11s). The
# hook path spawns many of those (master-hook, hook-gate per hook, the Grok
# adapter, the Grok user bridge, the Codex adapter). Measured 2026-09-21 macOS:
# adapter 18-32s, bridge 28s, master-hook 4.5s; with BASH_ENV=/dev/null: 4.0s / 3.5s.
#
# Bash sources $BASH_ENV before any line of the invoked script, so the entry
# process itself cannot prevent its own load. The poison below records only
# *child* loads (the hook path the fix targets). After neutralize, that log
# stays empty and the hook still returns its normal allow/deny output.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
MASTER="$ROOT/.claude/hooks/master-hook.sh"
GATE="$ROOT/.claude/hooks/hook-gate.sh"
ADAPTER="$ROOT/.grok/hooks/hq-grok-hook-adapter.sh"
BRIDGE="$ROOT/.grok/hooks/hq-grok-user-bridge.sh"
CODEX="$ROOT/.codex/hooks/hq-codex-hook-adapter.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

[ -f "$MASTER" ] || fail "missing $MASTER"
[ -f "$GATE" ] || fail "missing $GATE"
[ -f "$ADAPTER" ] || fail "missing $ADAPTER"
[ -f "$BRIDGE" ] || fail "missing $BRIDGE"
[ -f "$CODEX" ] || fail "missing $CODEX"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LOG="$TMP/bash-env-loads.log"
POISON="$TMP/poison-profile.sh"
PROBE="$TMP/probe-hook.sh"
: > "$LOG"

# Child-only marker: the first bash to source this file is the entry process
# (unavoidable). It exports a sentinel so every nested bash that sources us
# appends to the log. Neutralized children inherit BASH_ENV=/dev/null and
# never reach this file.
cat > "$POISON" <<'EOF'
if [ -n "${_HQ_BASH_ENV_CHILD:-}" ]; then
  [ -n "${HQ_BASH_ENV_MARKER_LOG:-}" ] && printf 'LOADED\n' >> "$HQ_BASH_ENV_MARKER_LOG"
else
  export _HQ_BASH_ENV_CHILD=1
fi
EOF

cat > "$PROBE" <<'EOF'
#!/bin/bash
cat >/dev/null
exit 0
EOF
chmod +x "$PROBE"

cd "$ROOT"

READ_CLAUDE="$(jq -nc --arg p "$ROOT/README.md" --arg cwd "$ROOT" \
  '{session_id:"bash-env-neutralize",hook_event_name:"PreToolUse",tool_name:"Read",cwd:$cwd,tool_input:{file_path:$p}}')"
READ_GROK="$(jq -nc --arg p "$ROOT/README.md" --arg cwd "$ROOT" \
  '{session_id:"bash-env-neutralize",hookEventName:"PreToolUse",toolName:"read_file",cwd:$cwd,toolInput:{file_path:$p}}')"

run_entry() {
  local out="$1" err="$2" script="$3"
  shift 3
  : > "$LOG"
  set +e
  printf '%s' "$PAYLOAD" | env \
    BASH_ENV="$POISON" \
    HQ_BASH_ENV_MARKER_LOG="$LOG" \
    HQ_ALLOW_HQ_WORKTREE=1 \
    HQ_HOOK_TIMEOUT_SENTRY=0 \
    CLAUDE_PROJECT_DIR="$ROOT" \
    HQ_ROOT="$ROOT" \
    bash "$script" "$@" >"$out" 2>"$err"
  RC=$?
  set -e
}

assert_no_child_profile_load() {
  local label="$1"
  if [ -s "$LOG" ]; then
    fail "$label: BASH_ENV child loads were recorded (hook path sourced the profile): $(tr '\n' ' ' < "$LOG")"
  fi
  pass "$label: no child BASH_ENV profile load"
}

echo "[1] master-hook.sh PreToolUse Read does not source BASH_ENV on child bash"
PAYLOAD="$READ_CLAUDE"
run_entry "$TMP/master.out" "$TMP/master.err" "$MASTER" PreToolUse
[ "$RC" -eq 0 ] || fail "master-hook.sh expected allow exit 0, got $RC stderr=$(cat "$TMP/master.err")"
assert_no_child_profile_load "master-hook.sh"

echo "[2] hook-gate.sh allow path does not source BASH_ENV on child bash"
PAYLOAD='{}'
run_entry "$TMP/gate.out" "$TMP/gate.err" "$GATE" detect-secrets "$PROBE"
[ "$RC" -eq 0 ] || fail "hook-gate.sh expected delegated exit 0, got $RC stderr=$(cat "$TMP/gate.err")"
assert_no_child_profile_load "hook-gate.sh"

echo "[3] grok adapter PreToolUse read_file does not source BASH_ENV on child bash"
PAYLOAD="$READ_GROK"
run_entry "$TMP/adapter.out" "$TMP/adapter.err" "$ADAPTER"
[ "$RC" -eq 0 ] || fail "hq-grok-hook-adapter.sh expected allow exit 0, got $RC stderr=$(cat "$TMP/adapter.err")"
grep -q '"decision":"allow"' "$TMP/adapter.out" \
  || fail "hq-grok-hook-adapter.sh expected allow JSON, got stdout=$(cat "$TMP/adapter.out")"
assert_no_child_profile_load "hq-grok-hook-adapter.sh"

echo "[4] grok user bridge PreToolUse read_file does not source BASH_ENV on child bash"
PAYLOAD="$READ_GROK"
run_entry "$TMP/bridge.out" "$TMP/bridge.err" "$BRIDGE"
[ "$RC" -eq 0 ] || fail "hq-grok-user-bridge.sh expected allow exit 0, got $RC stderr=$(cat "$TMP/bridge.err")"
grep -q '"decision":"allow"' "$TMP/bridge.out" \
  || fail "hq-grok-user-bridge.sh expected allow JSON, got stdout=$(cat "$TMP/bridge.out")"
assert_no_child_profile_load "hq-grok-user-bridge.sh"

echo "[5] Codex adapter PreToolUse Read does not source BASH_ENV on dispatched gates"
PAYLOAD="$READ_CLAUDE"
run_entry "$TMP/codex.out" "$TMP/codex.err" "$CODEX"
[ "$RC" -eq 0 ] || fail "hq-codex-hook-adapter.sh expected allow exit 0, got $RC stderr=$(cat "$TMP/codex.err")"
assert_no_child_profile_load "hq-codex-hook-adapter.sh"

echo "hooks-bash-env-neutralize: ok"
