#!/usr/bin/env bash
# Regression (HP-21): codex-preflight.sh doctor must report when Grok's
# managed policy pins allow_managed_hooks_only.
#
# Why this exists. Grok 1.0.40+ lets a managed settings file set
# allow_managed_hooks_only. On such a host Grok loads only managed hooks: the
# HQ user bridge under ~/.grok/hooks and the project .grok/hooks are skipped
# without any error. Every other doctor probe (trust, bridge installed,
# version) still comes back OK, so an operator sees a clean doctor on a host
# where no HQ guard runs. The pin is visible in exactly one place, a line in
# `grok inspect`. This test puts a stub grok on PATH whose `inspect` prints
# that line and checks doctor says so, then checks a clean inspect stays quiet.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
PREFLIGHT="$ROOT/core/scripts/codex-preflight.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

[ -f "$PREFLIGHT" ] || fail "missing $PREFLIGHT"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/grok-managed-pin.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
mkdir -p "$BIN"

# <inspect-line> : stub grok; `--version` is current, `inspect` prints the line.
make_grok() {
  cat > "$BIN/grok" <<STUB
#!/bin/sh
case "\$1" in
  --version) echo "grok 1.0.41 (deadbeef)" ;;
  inspect) printf '%s\n' "Hooks: 3 registered" "$1" ;;
esac
exit 0
STUB
  chmod +x "$BIN/grok"
}

# BASH_ENV neutralised so a host profile cannot re-export PATH over the stub
# (same reason as grok-min-version.test.sh).
run_doctor() {
  PATH="$BIN:$PATH" BASH_ENV=/dev/null bash "$PREFLIGHT" doctor 2>&1 || true
}

make_grok "Hooks outside managed policy disabled"
probe="$(PATH="$BIN:$PATH" BASH_ENV=/dev/null bash -c 'command -v grok')"
[ "$probe" = "$BIN/grok" ] || fail "stub grok not on PATH inside the test shell (resolved $probe)"
pass "stub grok resolves at $probe"

echo "[1] the managed pin is reported"
out="$(run_doctor)"
case "$out" in
  *"HOOKS DISABLED BY MANAGED POLICY"*) pass "doctor reports the pin" ;;
  *) fail "doctor did not report the managed-hooks pin. Output: $out" ;;
esac
case "$out" in
  *"allow_managed_hooks_only"*) pass "doctor names the setting" ;;
  *) fail "doctor did not name allow_managed_hooks_only" ;;
esac

echo "[2] a host without the pin is not flagged"
make_grok "Managed policy: none"
out="$(run_doctor)"
case "$out" in
  *"HOOKS DISABLED BY MANAGED POLICY"*) fail "doctor flagged a host with no pin: $out" ;;
esac
pass "clean inspect stays quiet"

echo "[3] the version line still prints alongside the pin check"
make_grok "Hooks outside managed policy disabled"
out="$(run_doctor)"
case "$out" in
  *"grok: grok 1.0.41"*) pass "version line present" ;;
  *) fail "version line missing: $out" ;;
esac

echo "grok-managed-hooks-pin: all cases passed"
