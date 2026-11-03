#!/bin/sh
# Regression test: hqd-hook-shim.sh under LC_ALL=C.utf8 LANG=C.utf8.
#
# Apple's system Perl 5.34 exits 9 with
#   panic: locale.c: 4486: Could not change LC_CTYPE locale to C.utf8
# when it inherits that locale (C.utf8 is not installed on macOS). Before the
# fix the shim's capability probe (`perl -MJSON::PP -MIO::Socket::UNIX -e 1`)
# failed, the shim concluded Perl was unavailable, and every PreToolUse hook
# exited 2 with "HQ daemon unreachable" even though hqd was answering.
#
# This test runs the shim against a stub hqd socket with the bad locale set on
# the shim itself and asserts the hqd answer is honored: allow -> exit 0 and no
# output, block -> exit 2 with the daemon's reasons (not the unreachable line).
# On a host where Perl accepts C.utf8 (most Linux) the bug cannot reproduce, so
# the test also runs a probe that proves the locale is actually unusable for a
# bare perl and reports it; the shim assertions run either way.
#
# Usage: sh core/scripts/tests/hqd-hook-shim-locale.test.sh   (cwd inside the repo)

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "not in a git repo" >&2; exit 2; }
SCRIPTS="$ROOT/core/scripts"
SHIM="$SCRIPTS/hqd-hook-shim.sh"
UNREACHABLE='HQ daemon unreachable: run hq daemon status'

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }

command -v perl >/dev/null 2>&1 || { echo "perl required"; exit 2; }
command -v node >/dev/null 2>&1 || { echo "node required (flag fixture)"; exit 2; }

TMP=$(mktemp -d /tmp/hqshimloc.XXXXXX)
STUB_PID=''
cleanup() {
  [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

export HOME="$TMP/home"
mkdir -p "$HOME/.hq/daemon"
. "$SCRIPTS/tests/hq-anywhere-flag-fixture.sh"
hq_anywhere_flag_fixture "$TMP/fake-cli"
HQ_CLI_BIN="$TMP/fake-cli/bin/hq" HQ_FLAGS_API_URL=https://flags.test HQ_COMPANY_UID=cmp_123456 HQ_TEST_FLAG=true
export HQ_CLI_BIN HQ_FLAGS_API_URL HQ_COMPANY_UID HQ_TEST_FLAG
unset HQ_REGISTRY_DIR HQ_HQD_SOCKET HQ_HQD_SHIM_TIMEOUT_MS

SOCK="$TMP/hqd.sock"

# Stub hqd: answers every request line with $1. Pinned to LC_ALL=C so the stub
# itself starts on a host whose Perl rejects the locale under test.
start_stub() {
  rm -f "$SOCK"
  STUB_REPLY="$1" LC_ALL=C perl -e '
use IO::Socket::UNIX;
my $srv = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Local => $ARGV[0], Listen => 5) or die "listen: $!";
while (my $c = $srv->accept) {
  my $line = <$c>;
  print $c $ENV{STUB_REPLY}, "\n"; close $c;
}' "$SOCK" &
  STUB_PID=$!
  _i=0
  while [ ! -S "$SOCK" ] && [ $_i -lt 50 ]; do sleep 0.1; _i=$((_i + 1)); done
}
stop_stub() { [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null; wait "$STUB_PID" 2>/dev/null; STUB_PID=''; }

# run_shim <payload> [args...] -> $RC, $OUT, $ERR. The shim runs under the
# locale that makes Apple Perl panic.
run_shim() {
  _payload="$1"; shift
  printf '%s' "$_payload" | LC_ALL=C.utf8 LANG=C.utf8 HQ_HQD_SOCKET="$SOCK" sh "$SHIM" "$@" >"$TMP/out" 2>"$TMP/err"
  RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}

BASH_OTHERCO='{"session_id":"s1","hook_event_name":"PreToolUse","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"echo hi > companies/otherco/x.md"}}'
ALLOW='{"id":1,"ok":true,"result":{"decision":"allow","reasons":[],"additionalContext":""}}'
BLOCK='{"id":1,"ok":true,"result":{"decision":"block","reasons":["cross-company write refused"],"additionalContext":""}}'

# Report whether this host's Perl actually panics on the locale (macOS) so a
# green run on Linux is not mistaken for proof of the macOS fix.
if LC_ALL=C.utf8 LANG=C.utf8 perl -e 1 >/dev/null 2>&1; then
  printf 'note this host Perl accepts C.utf8; the macOS panic cannot reproduce here\n'
else
  printf 'note this host Perl rejects C.utf8 (reproduces the macOS panic)\n'
fi

# hqd is expected: marker beside the socket, flag on.
: >"$TMP/hqd.enabled"
sh "$SCRIPTS/hqd-hook-flag-cache.sh" --refresh >/dev/null 2>&1

start_stub "$ALLOW"
run_shim "$BASH_OTHERCO" PreToolUse
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ "$ERR" != "$UNREACHABLE" ] && [ -z "$ERR" ]; then
  pass "C.utf8 locale: hqd allow reaches the shim (exit 0, no unreachable line)"
else fail "C.utf8 locale: hqd allow reaches the shim" "rc=$RC out=$OUT err=$ERR"; fi
stop_stub

start_stub "$BLOCK"
run_shim "$BASH_OTHERCO" PreToolUse
if [ "$RC" -eq 2 ] && [ "$ERR" != "$UNREACHABLE" ] && printf '%s' "$ERR" | grep -q 'cross-company write refused'; then
  pass "C.utf8 locale: hqd block reasons are relayed (exit 2 from the daemon, not from the probe)"
else fail "C.utf8 locale: hqd block reasons are relayed" "rc=$RC out=$OUT err=$ERR"; fi
stop_stub

# The same event under LANG alone (LC_ALL unset) takes the same Perl path.
start_stub "$ALLOW"
printf '%s' "$BASH_OTHERCO" | env -u LC_ALL LANG=C.utf8 HQ_HQD_SOCKET="$SOCK" sh "$SHIM" PreToolUse >"$TMP/out" 2>"$TMP/err"
RC=$?; ERR=$(cat "$TMP/err")
if [ "$RC" -eq 0 ] && [ -z "$ERR" ]; then pass "LANG=C.utf8 alone: hqd allow reaches the shim"
else fail "LANG=C.utf8 alone: hqd allow reaches the shim" "rc=$RC err=$ERR"; fi
stop_stub

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
