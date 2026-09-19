#!/usr/bin/env bash
# Regression: Windows Git Bash chmod writes NTFS DENY ACEs that can make the
# owner unable to read core files (POSIX mode still looks like -rw-r--r--).
# When hook-lib.sh is in that state, hook-gate used to abort under set -e and
# every registered hook failed to dispatch — including check-hq-hooks.sh.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
GATE="$ROOT/.claude/hooks/hook-gate.sh"
HOOK_LIB="$ROOT/core/scripts/hook-lib.sh"
REPAIR="$ROOT/core/scripts/repair-windows-core-acls.sh"
SETUP="$ROOT/core/scripts/setup.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }
[ -f "$GATE" ] || fail "hook-gate.sh not found"
[ -f "$HOOK_LIB" ] || fail "hook-lib.sh not found"
[ -f "$REPAIR" ] || fail "repair-windows-core-acls.sh not found"

TMP="$(mktemp -d)"
trap 'chmod -R u+rwx "$TMP" 2>/dev/null || true; rm -rf "$TMP"' EXIT

echo "[1] hook-gate still dispatches when hook-lib.sh exists but is unreadable"
FIX="$TMP/hq-unreadable-lib"
mkdir -p "$FIX/core/scripts" "$FIX/.claude/hooks"
cp "$GATE" "$FIX/.claude/hooks/hook-gate.sh"
# Present, not readable — the Windows DENY-ACE shape on POSIX.
printf 'echo SOURCED_UNREADABLE_LIB >&2\n' >"$FIX/core/scripts/hook-lib.sh"
chmod 000 "$FIX/core/scripts/hook-lib.sh"
cat >"$TMP/fake-hook.sh" <<'HOOK'
#!/bin/bash
cat >/dev/null
echo "FAKE_HOOK_RAN" >&2
exit 2
HOOK
chmod 0755 "$TMP/fake-hook.sh"
set +e
printf '{}' | bash "$FIX/.claude/hooks/hook-gate.sh" detect-secrets "$TMP/fake-hook.sh" 2>"$TMP/err1"
code=$?
set -e
chmod u+rw "$FIX/core/scripts/hook-lib.sh" 2>/dev/null || true
grep -q FAKE_HOOK_RAN "$TMP/err1" || fail "hook did not run when hook-lib was unreadable (stderr: $(cat "$TMP/err1"))"
grep -q SOURCED_UNREADABLE_LIB "$TMP/err1" && fail "unreadable hook-lib must not be sourced"
[ "$code" -eq 2 ] || fail "expected delegated exit 2, got $code"
pass "gate fail-opens past unreadable hook-lib and still runs the hook"

echo "[2] Windows launch skips chmod (mode stays 0644) and uses bash"
WIN_FIX="$TMP/hq-win"
mkdir -p "$WIN_FIX/workspace"
cat >"$WIN_FIX/in-root.sh" <<'EOF'
#!/bin/bash
cat >"$TRACE_FILE"
exit 7
EOF
chmod 0644 "$WIN_FIX/in-root.sh"
mode_before="$(stat -c %a "$WIN_FIX/in-root.sh" 2>/dev/null || stat -f %Lp "$WIN_FIX/in-root.sh")"
export TRACE_FILE="$TMP/win.trace"
set +e
HQ_LIB_WINSEP=1 bash -c '
  set -euo pipefail
  . "$1"
  hq_launch_shell_path "$2" "$2/in-root.sh" "payload-win"
' bash "$HOOK_LIB" "$WIN_FIX"
rc=$?
set -e
mode_after="$(stat -c %a "$WIN_FIX/in-root.sh" 2>/dev/null || stat -f %Lp "$WIN_FIX/in-root.sh")"
[ "$rc" -eq 7 ] || fail "expected delegated exit 7 on Windows launch path, got $rc"
[ "$mode_after" = "$mode_before" ] || fail "Windows launch must not chmod (before=$mode_before after=$mode_after)"
[ "$(cat "$TRACE_FILE")" = "payload-win" ] || fail "Windows bash fallback did not forward payload"
pass "HQ_LIB_WINSEP=1 launches via bash without chmod"

echo "[3] Windows repair command names icacls, not chmod"
repair_cmd="$(HQ_LIB_WINSEP=1 bash -c '
  . "$1"
  hq_hook_repair_command "$2" "$2/in-root.sh"
' bash "$HOOK_LIB" "$WIN_FIX")"
printf '%s' "$repair_cmd" | grep -q 'icacls' || fail "Windows repair command should name icacls: $repair_cmd"
printf '%s' "$repair_cmd" | grep -q 'chmod' && fail "Windows repair command must not recommend chmod: $repair_cmd"
pass "Windows repair text is icacls"

echo "[4] unreadable in-root file is repaired through a mocked icacls"
mkdir -p "$TMP/mock-bin"
cat >"$TMP/mock-bin/icacls" <<'MOCK'
#!/bin/bash
# Test stand-in: restore owner-read on any existing path argument.
for a in "$@"; do
  case "$a" in
    /*|*/*)
      if [ -e "$a" ]; then
        chmod u+r "$a" 2>/dev/null || true
      fi
      ;;
  esac
done
exit 0
MOCK
chmod +x "$TMP/mock-bin/icacls"
UNREAD="$WIN_FIX/denied.sh"
cat >"$UNREAD" <<'EOF'
#!/bin/bash
cat >/dev/null
echo DENIED_HOOK_RAN >&2
exit 3
EOF
chmod 000 "$UNREAD"
export TRACE_FILE="$TMP/denied.trace"
set +e
PATH="$TMP/mock-bin:$PATH" HQ_LIB_WINSEP=1 bash -c '
  set -euo pipefail
  . "$1"
  hq_launch_shell_path "$2" "$2/denied.sh" "payload-denied"
' bash "$HOOK_LIB" "$WIN_FIX" 2>"$TMP/err4"
rc=$?
set -e
chmod u+rw "$UNREAD" 2>/dev/null || true
[ "$rc" -eq 3 ] || fail "expected delegated exit 3 after ACL repair, got $rc (stderr: $(cat "$TMP/err4"))"
grep -q DENIED_HOOK_RAN "$TMP/err4" || fail "repaired hook did not run"
pass "mocked icacls restores read and the hook runs"

echo "[5] repair-windows-core-acls.sh is a no-op off Windows"
set +e
out="$(bash "$REPAIR" --root "$WIN_FIX" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "expected exit 0 off Windows, got $rc: $out"
printf '%s' "$out" | grep -q 'not Windows' || fail "off-Windows path should say not Windows: $out"
pass "repair script no-ops off Windows"

echo "[6] setup.sh does not chmod +x on Git Bash"
grep -Fq 'MINGW*|MSYS*|CYGWIN*' "$SETUP" || fail "setup.sh must skip chmod on Windows"
grep -Fq 'NTFS DENY' "$SETUP" || fail "setup.sh should name the NTFS DENY reason"
pass "setup.sh skips chmod on Windows"

echo "[7] hook-gate inline fallback does not chmod on Windows"
grep -Fq 'hq_gate_win' "$GATE" || fail "hook-gate must skip chmod on Windows in the inline fallback"
pass "hook-gate Windows fallback skips chmod"

echo "ALL PASS: windows-ntfs-deny-acl"
