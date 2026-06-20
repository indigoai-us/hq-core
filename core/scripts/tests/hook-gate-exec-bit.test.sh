#!/usr/bin/env bash
# Regression: hook-gate.sh must run a gate-wrapped hook even when the hook
# script has lost its executable bit. Cross-machine HQ sync can strip POSIX mode
# (e.g. S3 objects predating hq-cloud's hq-mode metadata stamp). Before the fix
# the gate exec'd the script directly, so a non-executable hook failed with
# "Permission denied" (exit 126) and was silently disabled.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
GATE="$ROOT/.claude/hooks/hook-gate.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }
[ -f "$GATE" ] || fail "hook-gate.sh not found at $GATE"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# Fake in-profile hook: consume stdin, mark that it ran, exit 2 so we can assert
# the gate propagates the delegated exit code.
cat > "$TMP/fake-hook.sh" <<'HOOK'
#!/bin/bash
cat >/dev/null
echo "FAKE_HOOK_RAN" >&2
exit 2
HOOK

# detect-secrets is in every profile, so the gate runs it under the default.
run_gate() { printf '{}' | bash "$GATE" detect-secrets "$TMP/fake-hook.sh" 2>"$TMP/err"; }

echo "[1] non-executable hook still runs through the gate"
chmod 0644 "$TMP/fake-hook.sh"
set +e; run_gate; code=$?; set -e
grep -q FAKE_HOOK_RAN "$TMP/err" || fail "hook did not run (stderr: $(cat "$TMP/err"))"
[ "$code" -eq 2 ] || fail "expected delegated exit 2 from non-exec hook, got $code"
pass "ran non-executable hook and propagated exit 2"

echo "[2] executable hook still runs (no regression)"
chmod 0755 "$TMP/fake-hook.sh"
set +e; run_gate; code=$?; set -e
grep -q FAKE_HOOK_RAN "$TMP/err" || fail "hook did not run when executable"
[ "$code" -eq 2 ] || fail "expected exit 2 from exec hook, got $code"
pass "ran executable hook and propagated exit 2"

echo "[3] out-of-profile hook is pass-through (exit 0) and NOT executed"
chmod 0644 "$TMP/fake-hook.sh"
set +e
printf '{}' | bash "$GATE" some-unknown-hook-id "$TMP/fake-hook.sh" 2>"$TMP/err"; code=$?
set -e
[ "$code" -eq 0 ] || fail "skipped hook should exit 0, got $code"
grep -q FAKE_HOOK_RAN "$TMP/err" && fail "skipped hook must not run"
pass "out-of-profile hook is pass-through, not executed"

echo "ALL PASS: hook-gate-exec-bit"
