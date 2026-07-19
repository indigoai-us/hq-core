#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
HOOK_LIB="$ROOT/core/scripts/hook-lib.sh"
BRIDGE_HEALTH="$ROOT/.claude/hooks/check-claude-desktop-bridge-health.sh"
CODEX_ADAPTER_SRC="$ROOT/.codex/hooks/hq-codex-hook-adapter.sh"
GROK_ADAPTER_SRC="$ROOT/.grok/hooks/hq-grok-hook-adapter.sh"
GATE_SRC="$ROOT/.claude/hooks/hook-gate.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "  ok: $*"
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

. "$HOOK_LIB"

echo "[1] launcher repairs only in-root files and preserves delegated exits"
HQ_FIX="$TMP/hq"
mkdir -p "$HQ_FIX/workspace" "$TMP/outside"

cat >"$HQ_FIX/in-root.sh" <<'EOF'
#!/bin/bash
cat >"$TRACE_FILE"
exit 7
EOF
chmod 0644 "$HQ_FIX/in-root.sh"

export TRACE_FILE="$TMP/in-root.trace"
set +e
hq_launch_shell_path "$HQ_FIX" "$HQ_FIX/in-root.sh" "payload-in-root" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 7 ] || fail "expected delegated exit 7 for in-root file, got $rc"
[ -x "$HQ_FIX/in-root.sh" ] || fail "in-root file was not repaired to executable"
[ "$(cat "$TRACE_FILE")" = "payload-in-root" ] || fail "in-root payload was not forwarded"
pass "in-root file repaired and exit preserved"

cat >"$TMP/outside/outside.sh" <<'EOF'
#!/bin/bash
cat >"$TRACE_FILE"
exit 9
EOF
chmod 0644 "$TMP/outside/outside.sh"
outside_mode_before="$(stat -c %a "$TMP/outside/outside.sh" 2>/dev/null || stat -f %Lp "$TMP/outside/outside.sh")"

export TRACE_FILE="$TMP/outside.trace"
set +e
hq_launch_shell_path "$HQ_FIX" "$TMP/outside/outside.sh" "payload-outside" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 9 ] || fail "expected delegated exit 9 for outside file, got $rc"
outside_mode_after="$(stat -c %a "$TMP/outside/outside.sh" 2>/dev/null || stat -f %Lp "$TMP/outside/outside.sh")"
[ "$outside_mode_after" = "$outside_mode_before" ] || fail "outside file mode must not be changed"
[ "$(cat "$TRACE_FILE")" = "payload-outside" ] || fail "outside payload was not forwarded"
pass "outside file used bash fallback without chmodding outside HQ root"

echo "[2] launch warnings dedupe once per session and stay bounded"
warn_payload='{"session_id":"diag-session"}'
warn_path="$HQ_FIX/scripts/broken.sh"
warn1="$(hq_hook_launch_warning_text \
  "$warn_payload" \
  "$HQ_FIX" \
  "advisory" \
  "script" \
  "broken" \
  "$warn_path" \
  "file is missing under HQ_ROOT")"
warn2="$(hq_hook_launch_warning_text \
  "$warn_payload" \
  "$HQ_FIX" \
  "advisory" \
  "script" \
  "broken" \
  "$warn_path" \
  "file is missing under HQ_ROOT")"
[ -n "$warn1" ] || fail "first warning should be emitted"
[ -z "$warn2" ] || fail "second identical warning should be deduped"
[ "${#warn1}" -le 420 ] || fail "warning must be bounded to 420 chars"
printf '%s' "$warn1" | grep -q 'Repair: chmod u+x "$HQ_ROOT/scripts/broken.sh"' \
  || fail "warning should include the root-contained repair command"
pass "warning dedupe and bounded repair text work"

echo "[3] bridge health hook supports fixture overrides"
BRIDGE_STATE_FIX="$TMP/bridge-state.json"
LOG_FIX="$TMP/main.log"
cat >"$BRIDGE_STATE_FIX" <<'EOF'
{"org:acct":{"enabled":true,"processedMessageUuids":[]}}
EOF
cat >"$LOG_FIX" <<'EOF'
[sessions-bridge] Transport permanently closed code=4090
EOF
bridge_out="$(BRIDGE_STATE_FILE="$BRIDGE_STATE_FIX" LOG_FILE="$LOG_FIX" bash "$BRIDGE_HEALTH" <<<'{}')"
printf '%s' "$bridge_out" | grep -q '<bridge-health-warning>' \
  || fail "bridge-health warning wrapper missing under fixture override"
printf '%s' "$bridge_out" | grep -q '260 GB memory leak on 2026-04-10' \
  || fail "bridge-health warning text missing correlated incident date"
pass "fixture overrides emit the correlated bridge-health warning"

echo "[4] non-desktop runtimes fail-soft for bridge health"
case "$(uname -s 2>/dev/null || echo unknown)" in
  Darwin)
    pass "host is Darwin; non-desktop fast-exit path skipped"
    ;;
  *)
    bridge_out="$(bash "$BRIDGE_HEALTH" <<<'{}')"
    [ -z "$bridge_out" ] || fail "non-desktop runtime should not emit bridge-health output"
    pass "non-desktop runtime skips macOS bridge probes cleanly"
    ;;
esac

echo "[5] Codex keeps structured stdout intact under advisory failures"
CODEX_FIX="$TMP/codex"
mkdir -p "$CODEX_FIX/.codex/hooks" "$CODEX_FIX/.claude/hooks" "$CODEX_FIX/core/scripts"
cp "$CODEX_ADAPTER_SRC" "$CODEX_FIX/.codex/hooks/hq-codex-hook-adapter.sh"
cp "$GATE_SRC" "$CODEX_FIX/.claude/hooks/hook-gate.sh"
cp "$HOOK_LIB" "$CODEX_FIX/core/scripts/hook-lib.sh"
chmod +x \
  "$CODEX_FIX/.codex/hooks/hq-codex-hook-adapter.sh" \
  "$CODEX_FIX/.claude/hooks/hook-gate.sh" \
  "$CODEX_FIX/core/scripts/hook-lib.sh"

cat >"$CODEX_FIX/.claude/hooks/auto-checkpoint-trigger.sh" <<'EOF'
#!/bin/bash
cat >/dev/null
echo "AUTO-CHECKPOINT REQUIRED"
EOF
cat >"$CODEX_FIX/.claude/hooks/auto-mirror-company-skill.sh" <<'EOF'
#!/bin/bash
cat >/dev/null
exit 0
EOF
cat >"$CODEX_FIX/.claude/hooks/hq-autocommit.sh" <<'EOF'
#!/bin/bash
cat >/dev/null
exit 0
EOF
cat >"$CODEX_FIX/.claude/hooks/journal-due.sh" <<'EOF'
#!/bin/bash
cat >/dev/null
exit 0
EOF
cat >"$CODEX_FIX/.claude/hooks/master-sync.sh" <<'EOF'
#!/bin/bash
cat >/dev/null
printf 'MASTER_SYNC_FAIL ' >&2
awk 'BEGIN { for (i = 0; i < 900; i++) printf "x" }' >&2
printf '\n' >&2
exit 9
EOF
chmod +x "$CODEX_FIX/.claude/hooks/"*.sh

codex_payload="$(jq -n --arg cwd "$CODEX_FIX" '{
  hook_event_name: "PostToolUse",
  tool_name: "apply_patch",
  cwd: $cwd,
  session_id: "codex-diag",
  tool_input: {
    command: "*** Begin Patch\n*** Add File: docs/diag.md\n+ok\n*** End Patch"
  },
  tool_response: {exit_code: 0}
}')"
codex_out="$TMP/codex.out"
codex_err="$TMP/codex.err"
set +e
printf '%s' "$codex_payload" | "$CODEX_FIX/.codex/hooks/hq-codex-hook-adapter.sh" >"$codex_out" 2>"$codex_err"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "Codex adapter should fail-soft advisory script errors, got $rc"
jq -e '.hookSpecificOutput.additionalContext | contains("AUTO-CHECKPOINT REQUIRED")' "$codex_out" >/dev/null \
  || fail "Codex stdout lost structured PostToolUse context"
if grep -q 'MASTER_SYNC_FAIL' "$codex_out"; then
  fail "Codex advisory diagnostics leaked onto structured stdout"
fi
grep -q 'MASTER_SYNC_FAIL' "$codex_err" || fail "Codex stderr should surface compacted advisory diagnostics"
[ "$(wc -c <"$codex_err")" -le 500 ] || fail "Codex advisory diagnostics must stay bounded"
pass "Codex keeps stdout JSON clean and emits bounded advisory diagnostics on stderr"

echo "[6] Grok surfaces passive bridge diagnostics without corrupting PreToolUse JSON"
GROK_FIX="$TMP/grok"
mkdir -p "$GROK_FIX/.grok/hooks" "$GROK_FIX/.claude/hooks" "$GROK_FIX/core/scripts"
cp "$GROK_ADAPTER_SRC" "$GROK_FIX/.grok/hooks/hq-grok-hook-adapter.sh"
cp "$GATE_SRC" "$GROK_FIX/.claude/hooks/hook-gate.sh"
cp "$HOOK_LIB" "$GROK_FIX/core/scripts/hook-lib.sh"
chmod +x \
  "$GROK_FIX/.grok/hooks/hq-grok-hook-adapter.sh" \
  "$GROK_FIX/.claude/hooks/hook-gate.sh" \
  "$GROK_FIX/core/scripts/hook-lib.sh"

cat >"$GROK_FIX/.claude/hooks/check-claude-desktop-bridge-health.sh" <<'EOF'
#!/bin/bash
cat >/dev/null
printf 'BRIDGE_ALERT '
awk 'BEGIN { for (i = 0; i < 900; i++) printf "y" }'
printf '\n'
exit 0
EOF
for hook_name in detect-secrets block-core-writes-bash block-hq-root-git-mutation block-on-active-run block-unsafe-package-install; do
  cat >"$GROK_FIX/.claude/hooks/$hook_name.sh" <<'EOF'
#!/bin/bash
cat >/dev/null
exit 0
EOF
done
cat >"$GROK_FIX/.claude/hooks/inject-policy-on-trigger.sh" <<'EOF'
#!/bin/bash
cat >/dev/null
exit 0
EOF
cat >"$GROK_FIX/.claude/hooks/warn-cross-company-settings.sh" <<'EOF'
#!/bin/bash
cat >/dev/null
printf 'WARN_CROSS_COMPANY ' >&2
awk 'BEGIN { for (i = 0; i < 900; i++) printf "z" }' >&2
printf '\n' >&2
exit 9
EOF
for hook_name in check-repo-active-runs inject-local-context auto-startwork check-core-yaml-parity load-journal-index-on-start check-hq-update; do
  cat >"$GROK_FIX/.claude/hooks/$hook_name.sh" <<'EOF'
#!/bin/bash
cat >/dev/null
exit 0
EOF
done
cat >"$GROK_FIX/core/scripts/migrate-policy-triggers.sh" <<'EOF'
#!/bin/bash
cat >/dev/null
exit 0
EOF
chmod +x "$GROK_FIX/.claude/hooks/"*.sh
chmod +x "$GROK_FIX/core/scripts/migrate-policy-triggers.sh"

grok_session_payload="$(jq -n --arg cwd "$GROK_FIX" '{hookEventName:"SessionStart", cwd:$cwd, sessionId:"grok-session"}')"
grok_session_out="$TMP/grok-session.out"
grok_session_err="$TMP/grok-session.err"
set +e
printf '%s' "$grok_session_payload" | "$GROK_FIX/.grok/hooks/hq-grok-hook-adapter.sh" >"$grok_session_out" 2>"$grok_session_err"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "Grok SessionStart should stay advisory, got $rc"
[ ! -s "$grok_session_out" ] || fail "Grok passive bridge diagnostics must not emit stdout payloads"
grep -q 'BRIDGE_ALERT' "$grok_session_err" || fail "Grok should surface bridge-health output via stderr diagnostics"
[ "$(wc -c <"$grok_session_err")" -le 500 ] || fail "Grok passive bridge diagnostics must stay bounded"
pass "Grok bridge diagnostics stay off stdout and remain bounded"

grok_pre_payload="$(jq -n --arg cwd "$GROK_FIX" '{
  hookEventName: "PreToolUse",
  toolName: "Read",
  cwd: $cwd,
  sessionId: "grok-pre",
  toolInput: {file_path: "docs/diag.md"}
}')"
grok_pre_out="$TMP/grok-pre.out"
grok_pre_err="$TMP/grok-pre.err"
set +e
printf '%s' "$grok_pre_payload" | "$GROK_FIX/.grok/hooks/hq-grok-hook-adapter.sh" >"$grok_pre_out" 2>"$grok_pre_err"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "Grok PreToolUse should allow after advisory failure, got $rc"
jq -e '.decision == "allow"' "$grok_pre_out" >/dev/null \
  || fail "Grok allow JSON was corrupted by advisory diagnostics"
if grep -q 'WARN_CROSS_COMPANY' "$grok_pre_out"; then
  fail "Grok advisory diagnostics leaked into allow JSON stdout"
fi
grep -q 'WARN_CROSS_COMPANY' "$grok_pre_err" || fail "Grok stderr should surface advisory diagnostics"
[ "$(wc -c <"$grok_pre_err")" -le 500 ] || fail "Grok advisory diagnostics must stay bounded"
pass "Grok keeps allow JSON intact while surfacing advisory stderr diagnostics"

echo "ALL PASS: hook-runtime-diagnostics"
