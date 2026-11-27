#!/bin/sh
# Tests for core/scripts/hqd-hook-shim.sh (hq-anywhere-runtime US-010).
#
# Part 1 runs the shim against a stub hqd (a perl socket server that returns a
# canned response or never answers) and against a missing socket.
# Part 2 starts the real hqd from an hq-cli build on a temp socket, in a temp
# HOME with a fixture HQ root, and checks the cross-company block end to end
# plus the median round-trip (<50ms over 100 calls).
#   HQ_CLI_DIR  hq-cli checkout with dist/ built (default: the hq-anywhere
#               worktree, the local checkout, then the pinned global install).
# Never touches the real ~/.hq.
#
# Usage: sh core/scripts/hqd-hook-shim.test.sh

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
SHIM="$HERE/hqd-hook-shim.sh"
UNREACHABLE='HQ daemon unreachable: run hq daemon status'
CONNECT_FAIL='HQ daemon unreachable: could not connect (daemon not running): run hq daemon status'

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }

# The physical path: hqd refuses a socket path with a symlink in it, and /tmp
# is a symlink on macOS.
TMP=$(cd "$(mktemp -d /tmp/hqshim.XXXXXX)" && pwd -P)
STUB_PID=''
HQD_PID=''
cleanup() {
  [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null
  [ -n "$HQD_PID" ] && kill "$HQD_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

REAL_HOME="${HOME:-}"
export HOME="$TMP/home"
mkdir -p "$HOME/.hq"
. "$HERE/tests/hq-anywhere-flag-fixture.sh"
hq_anywhere_flag_fixture "$TMP/fake-cli"
HQ_CLI_BIN="$TMP/fake-cli/bin/hq" HQ_FLAGS_API_URL=https://flags.test HQ_COMPANY_UID=cmp_123456 HQ_TEST_FLAG=true
export HQ_CLI_BIN HQ_FLAGS_API_URL HQ_COMPANY_UID HQ_TEST_FLAG
unset HQ_REGISTRY_DIR

# run_shim <socket> <payload> [args...] -> $RC, $OUT, $ERR
run_shim() {
  _sock="$1"; _payload="$2"; shift 2
  printf '%s' "$_payload" | HQ_HQD_SOCKET="$_sock" sh "$SHIM" "$@" >"$TMP/out" 2>"$TMP/err"
  RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}

# Stub hqd: answers every request line with $2 (or never, when $2 is "hang").
start_stub() {
  _sock="$1"; _reply="$2"
  rm -f "$_sock" "$TMP/req"
  STUB_REPLY="$_reply" STUB_REQ="$TMP/req" perl -e '
use IO::Socket::UNIX;
my $srv = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Local => $ARGV[0], Listen => 5) or die "listen: $!";
while (my $c = $srv->accept) {
  my $line = <$c>;
  open my $f, ">", $ENV{STUB_REQ}; print $f $line; close $f;
  if ($ENV{STUB_REPLY} eq "hang") { sleep 5; next; }
  print $c $ENV{STUB_REPLY}, "\n"; close $c;
}' "$_sock" &
  STUB_PID=$!
  _i=0
  while [ ! -S "$_sock" ] && [ $_i -lt 50 ]; do sleep 0.1; _i=$((_i + 1)); done
}
stop_stub() { [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null; wait "$STUB_PID" 2>/dev/null; STUB_PID=''; }

WRITE_OTHERCO='{"session_id":"s1","hook_event_name":"PreToolUse","cwd":"/tmp/foreign-repo","tool_name":"Write","tool_input":{"file_path":"companies/otherco/x.md","content":"hi"}}'
WRITE_ABS='{"session_id":"s1","hook_event_name":"PreToolUse","cwd":"/tmp/foreign-repo","tool_name":"Edit","tool_input":{"file_path":"/opt/HQ/companies/indigo/a.md"}}'
BASH_OTHERCO='{"session_id":"s1","hook_event_name":"PreToolUse","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"echo hi > companies/otherco/x.md"}}'
EXEC_CMD_OTHERCO='{"session_id":"s1","hook_event_name":"PreToolUse","cwd":"/tmp","tool_name":"exec_command","tool_input":{"cmd":"printf x > companies/otherco/x.md"}}'
WRITE_OTHER='{"session_id":"s1","hook_event_name":"PreToolUse","cwd":"/tmp/foreign-repo","tool_name":"Write","tool_input":{"file_path":"/tmp/foreign-repo/notes.md"}}'
READ_OTHERCO='{"session_id":"s1","hook_event_name":"PreToolUse","cwd":"/tmp","tool_name":"Read","tool_input":{"file_path":"companies/otherco/x.md"}}'
START='{"session_id":"s1","hook_event_name":"SessionStart","cwd":"/tmp/foreign-repo","source":"startup"}'
PROMPT='{"session_id":"s1","hook_event_name":"UserPromptSubmit","cwd":"/tmp","prompt":"hi"}'

# ---------------------------------------------------------------- part 1
NOSOCK="$TMP/absent.sock"
# hqd is expected on this machine (the daemon's enabled marker sits beside the
# socket path), so an absent socket below means "hqd unreachable".
: >"$TMP/hqd.enabled"

HQ_TEST_FLAG=false run_shim "$NOSOCK" "$WRITE_OTHERCO" PreToolUse
if [ "$RC" -eq 0 ] && [ -z "$OUT$ERR" ]; then pass "flag off: shim is inert"
else fail "flag off: shim is inert" "rc=$RC out=$OUT err=$ERR"; fi

HQ_TEST_FLAG=true
export HQ_TEST_FLAG
rm -f "$HOME/.hq/hq-anywhere-runtime.flag.cmp_123456"
sh "$HERE/hqd-hook-flag-cache.sh" --refresh

# hqd not set up on this machine (HQ Anywhere off in settings): no socket and no
# enabled marker. The shim must not block work it has no daemon to route to.
mkdir -p "$TMP/hqd-off"
run_shim "$TMP/hqd-off/hqd.sock" "$WRITE_OTHERCO" PreToolUse
if [ "$RC" -eq 0 ] && [ -z "$OUT$ERR" ]; then pass "hqd not set up (no socket, no marker): company write is not blocked"
else fail "hqd not set up (no socket, no marker): company write is not blocked" "rc=$RC out=$OUT err=$ERR"; fi
run_shim "$TMP/hqd-off/hqd.sock" "$READ_OTHERCO" PreToolUse
if [ "$RC" -eq 0 ] && [ -z "$OUT$ERR" ]; then pass "hqd not set up: company read is not blocked"
else fail "hqd not set up: company read is not blocked" "rc=$RC out=$OUT err=$ERR"; fi
# A stale socket file without the marker still means hqd was running: fail closed.
mkdir -p "$TMP/hqd-stale"
perl -MIO::Socket::UNIX -e 'IO::Socket::UNIX->new(Type => IO::Socket::UNIX::SOCK_STREAM(), Local => $ARGV[0], Listen => 1) or die "listen: $!"' "$TMP/hqd-stale/hqd.sock"
run_shim "$TMP/hqd-stale/hqd.sock" "$WRITE_OTHERCO" PreToolUse
if [ "$RC" -eq 2 ] && [ "$ERR" = "$CONNECT_FAIL" ]; then pass "stale hqd socket without marker: company write still fails closed"
else fail "stale hqd socket without marker: company write still fails closed" "rc=$RC err=$ERR"; fi
# One shim call starts perl once (feedback_0f247c64). A separate module probe
# doubled every call's perl launches; on macOS a high exec rate is linked to
# watchdog panics.
mkdir -p "$TMP/perl-count"
REAL_PERL=$(command -v perl)
cat > "$TMP/perl-count/perl" <<PERL_COUNT
#!/bin/sh
printf 'x\n' >> "$TMP/perl-count/log"
exec "$REAL_PERL" "\$@"
PERL_COUNT
chmod +x "$TMP/perl-count/perl"
: >"$TMP/perl-count/log"
printf '%s' "$WRITE_OTHERCO" | env PATH="$TMP/perl-count:$PATH" HQ_HQD_SOCKET="$TMP/hqd-stale/hqd.sock" \
  sh "$SHIM" PreToolUse >"$TMP/out" 2>"$TMP/err"
RC=$?; ERR=$(cat "$TMP/err")
PERL_STARTS=$(wc -l <"$TMP/perl-count/log" | tr -d ' ')
if [ "$PERL_STARTS" -eq 1 ] && [ "$RC" -eq 2 ] && [ "$ERR" = "$CONNECT_FAIL" ]; then
  pass "one shim call starts perl once"
else fail "one shim call starts perl once" "perl_starts=$PERL_STARTS rc=$RC err=$ERR"; fi
# The marker alone (daemon says hqd should run, socket gone): fail closed.
mkdir -p "$TMP/hqd-marker"
: >"$TMP/hqd-marker/hqd.enabled"
run_shim "$TMP/hqd-marker/hqd.sock" "$WRITE_OTHERCO" PreToolUse
if [ "$RC" -eq 2 ] && [ "$ERR" = "$CONNECT_FAIL" ]; then pass "enabled marker without socket: company write fails closed"
else fail "enabled marker without socket: company write fails closed" "rc=$RC err=$ERR"; fi

# Exercise the packaged Claude launcher without an explicit socket override.
# hqd's default socket is under <HOME>/.hq/daemon, matching hqdSocketPath().
LAUNCHER_ROOT="$TMP/plugin"
mkdir -p "$LAUNCHER_ROOT/scripts/hq" "$HOME/.hq/daemon"
cp "$HERE/../../.github/release/hq-anywhere/hq-claude-plugin-launch.sh" "$LAUNCHER_ROOT/scripts/hq-claude-plugin-launch.sh"
cp "$SHIM" "$HERE/hq-anywhere-runtime-flag.cjs" "$HERE/hqd-hook-flag-cache-lib.sh" "$LAUNCHER_ROOT/scripts/hq/"
unset HQ_HQD_SOCKET HQ_HQD_SHIM_TIMEOUT_MS
run_plugin_launcher() {
  _payload="$1"
  printf '%s' "$_payload" | /bin/sh "$LAUNCHER_ROOT/scripts/hq-claude-plugin-launch.sh" hook PreToolUse >"$TMP/out" 2>"$TMP/err"
  RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}
ALLOW='{"id":1,"ok":true,"result":{"decision":"allow","reasons":[],"additionalContext":""}}'
start_stub "$HOME/.hq/daemon/hqd.sock" "$ALLOW"
run_plugin_launcher "$BASH_OTHERCO"
if [ "$RC" -eq 0 ] && [ -z "$ERR" ]; then pass "Claude plugin launcher: default hqd socket under .hq/daemon reaches hqd"
else fail "Claude plugin launcher: default hqd socket under .hq/daemon reaches hqd" "rc=$RC err=$ERR"; fi
stop_stub

mkdir -p "$TMP/registry/daemon"
start_stub "$TMP/registry/daemon/hqd.sock" "$ALLOW"
HQ_REGISTRY_DIR="$TMP/registry" run_plugin_launcher "$BASH_OTHERCO"
if [ "$RC" -eq 0 ] && [ -z "$ERR" ]; then pass "Claude plugin launcher: HQ_REGISTRY_DIR socket under daemon reaches hqd"
else fail "Claude plugin launcher: HQ_REGISTRY_DIR socket under daemon reaches hqd" "rc=$RC err=$ERR"; fi
stop_stub

mkdir -p "$TMP/no-perl-modules"
cat > "$TMP/no-perl-modules/perl" <<'NO_PERL_MODULES'
#!/bin/sh
exit 1
NO_PERL_MODULES
chmod +x "$TMP/no-perl-modules/perl"
printf '%s' "$WRITE_OTHERCO" | env PATH="$TMP/no-perl-modules:$PATH" \
  HQ_HQD_SHIM_REPORT_UNREACHABLE=1 HQ_HQD_SOCKET="$NOSOCK" \
  sh "$SHIM" PreToolUse >"$TMP/out" 2>"$TMP/err"
RC=$?
OUT=$(cat "$TMP/out")
ERR=$(cat "$TMP/err")
if [ "$RC" -eq 75 ] && [ -z "$OUT$ERR" ]; then pass "routing mode reports unavailable Perl modules for direct fallback"
else fail "routing mode reports unavailable Perl modules for direct fallback" "rc=$RC out=$OUT err=$ERR"; fi

printf 'true 0\n' >"$HOME/.hq/hq-anywhere-runtime.flag.cmp_123456"
run_shim "$NOSOCK" "$WRITE_OTHERCO" PreToolUse
if [ "$RC" -eq 2 ] && [ "$ERR" = "$CONNECT_FAIL" ]; then pass "stale enabled cache: first company write still reaches fail-closed shim"
else fail "stale enabled cache: first company write still enforces" "rc=$RC err=$ERR"; fi

run_shim "$NOSOCK" "$WRITE_OTHERCO" PreToolUse
if [ "$RC" -eq 2 ] && [ "$ERR" = "$CONNECT_FAIL" ]; then pass "absent socket: Write to companies/ blocks with one unreachable line"
else fail "absent socket: Write to companies/ blocks" "rc=$RC err=$ERR"; fi

PRETTY_WRITE='{
  "session_id": "s1",
  "hook_event_name": "PreToolUse",
  "cwd": "/tmp/foreign-repo",
  "tool_name": "Write",
  "tool_input": {"file_path": "companies/otherco/x.md"}
}'
run_shim "$NOSOCK" "$PRETTY_WRITE" PreToolUse
if [ "$RC" -eq 2 ] && [ "$ERR" = "$CONNECT_FAIL" ]; then pass "multiline JSON payload: company write still blocks"
else fail "multiline JSON payload" "rc=$RC err=$ERR"; fi

run_shim "$NOSOCK" "$WRITE_ABS"
if [ "$RC" -eq 2 ]; then pass "absent socket: absolute companies/ path blocks (event from payload)"
else fail "absent socket: absolute companies/ path blocks" "rc=$RC err=$ERR"; fi

RELATIVE_COMPANY_WRITE='{"session_id":"s1","hook_event_name":"PreToolUse","cwd":"/tmp/HQ/companies/acme","tool_name":"Write","tool_input":{"file_path":"knowledge/file.md"}}'
run_shim "$NOSOCK" "$RELATIVE_COMPANY_WRITE" PreToolUse
if [ "$RC" -eq 2 ] && [ "$ERR" = "$CONNECT_FAIL" ]; then pass "absent socket: relative file write from a company cwd blocks"
else fail "relative company cwd write blocks" "rc=$RC err=$ERR"; fi

RELATIVE_SHELL_WRITE='{"session_id":"s1","hook_event_name":"PreToolUse","cwd":"/tmp/HQ","tool_name":"Bash","tool_input":{"command":"cd companies && touch acme/file"}}'
run_shim "$NOSOCK" "$RELATIVE_SHELL_WRITE" PreToolUse
if [ "$RC" -eq 2 ] && [ "$ERR" = "$CONNECT_FAIL" ]; then pass "absent socket: shell writes after cd into a company block"
else fail "relative shell company write blocks" "rc=$RC err=$ERR"; fi

mkdir -p "$TMP/no-perl-path"
printf '%s' "$RELATIVE_SHELL_WRITE" | env PATH="$TMP/no-perl-path" \
  HQ_HQD_SOCKET="$NOSOCK" HOME="$HOME" HQ_COMPANY_UID="$HQ_COMPANY_UID" \
  /bin/sh "$SHIM" PreToolUse >"$TMP/out" 2>"$TMP/err"
RC=$?; OUT=$(cat "$TMP/out"); ERR=$(cat "$TMP/err")
if [ "$RC" -eq 2 ] && [ "$ERR" = "$UNREACHABLE" ] && [ -z "$OUT" ]; then
  pass "no Perl in PATH: relative shell company write fails closed"
else fail "no Perl in PATH: relative shell company write fails closed" "rc=$RC out=$OUT err=$ERR"; fi

# Codex registers one shim command for every hook event and does not pass the
# event as argv. Exercise that real invocation shape without Perl.
CODEX_SHIM="$TMP/codex-hook-shim.sh"
cp "$SHIM" "$CODEX_SHIM"
cp "$HERE/hq-anywhere-runtime-flag.cjs" "$HERE/hqd-hook-flag-cache-lib.sh" "$TMP/"
CODEX_ABS_WRITE='{"hook_event_name":"PreToolUse","cwd":"/tmp","tool_name":"Write","tool_input":{"file_path":"/tmp/HQ/companies/acme/x.md"}}'
CODEX_REL_WRITE='{"hook_event_name" : "PreToolUse","cwd":"/tmp/HQ","tool_name":"Bash","tool_input":{"command":"cd companies && touch acme/x.md"}}'
CODEX_UNKNOWN_TOOL='{"cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"echo hi"}}'
CODEX_UNKNOWN_COMPANY='{"cwd":"/tmp","command":"touch companies/acme/x.md"}'
CODEX_PRETOOL_EVENT_ONLY='{"hook_event_name":"PreToolUse","cwd":"/tmp"}'
CODEX_PRETOOL_EVENT_ONLY_SPACED='{"hook_event_name" : "PreToolUse","cwd":"/tmp"}'
CODEX_STOP='{"hook_event_name":"Stop","cwd":"/tmp","session_id":"s1"}'
CODEX_SESSION_START='{"hook_event_name":"SessionStart","cwd":"/tmp","session_id":"s1"}'
run_codex_no_perl() {
  _payload="$1"
  printf '%s' "$_payload" | env PATH="$TMP/no-perl-path" HOME="$HOME" \
    HQ_COMPANY_UID="$HQ_COMPANY_UID" HQ_HQD_SOCKET="$NOSOCK" \
    /bin/sh "$CODEX_SHIM" >"$TMP/out" 2>"$TMP/err"
  RC=$?; OUT=$(cat "$TMP/out"); ERR=$(cat "$TMP/err")
}
run_codex_no_perl "$CODEX_ABS_WRITE"
if [ "$RC" -eq 2 ] && [ "$ERR" = "$UNREACHABLE" ] && [ -z "$OUT" ]; then
  pass "no Perl, Codex no-arg PreToolUse absolute companies write blocks"
else fail "no Perl, Codex no-arg PreToolUse absolute companies write blocks" "rc=$RC out=$OUT err=$ERR"; fi
run_codex_no_perl "$CODEX_REL_WRITE"
if [ "$RC" -eq 2 ] && [ "$ERR" = "$UNREACHABLE" ] && [ -z "$OUT" ]; then
  pass "no Perl, Codex no-arg PreToolUse relative cd companies write blocks"
else fail "no Perl, Codex no-arg PreToolUse relative cd companies write blocks" "rc=$RC out=$OUT err=$ERR"; fi
run_codex_no_perl "$CODEX_UNKNOWN_TOOL"
if [ "$RC" -eq 2 ] && [ "$ERR" = "$UNREACHABLE" ] && [ -z "$OUT" ]; then
  pass "no Perl, Codex unknown event with tool_name fails closed"
else fail "no Perl, Codex unknown event with tool_name fails closed" "rc=$RC out=$OUT err=$ERR"; fi
run_codex_no_perl "$CODEX_UNKNOWN_COMPANY"
if [ "$RC" -eq 2 ] && [ "$ERR" = "$UNREACHABLE" ] && [ -z "$OUT" ]; then
  pass "no Perl, Codex unknown event naming companies/ fails closed"
else fail "no Perl, Codex unknown event naming companies/ fails closed" "rc=$RC out=$OUT err=$ERR"; fi
run_codex_no_perl "$CODEX_PRETOOL_EVENT_ONLY"
if [ "$RC" -eq 2 ] && [ "$ERR" = "$UNREACHABLE" ] && [ -z "$OUT" ]; then
  pass "no Perl, Codex event-only PreToolUse blocks without whitespace"
else fail "no Perl, Codex event-only PreToolUse blocks without whitespace" "rc=$RC out=$OUT err=$ERR"; fi
run_codex_no_perl "$CODEX_PRETOOL_EVENT_ONLY_SPACED"
if [ "$RC" -eq 2 ] && [ "$ERR" = "$UNREACHABLE" ] && [ -z "$OUT" ]; then
  pass "no Perl, Codex event-only PreToolUse blocks with whitespace around colon"
else fail "no Perl, Codex event-only PreToolUse with whitespace around colon" "rc=$RC out=$OUT err=$ERR"; fi
run_codex_no_perl "$CODEX_STOP"
if [ "$RC" -eq 0 ]; then pass "no Perl, Codex no-arg Stop passes"
else fail "no Perl, Codex no-arg Stop passes" "rc=$RC out=$OUT err=$ERR"; fi
run_codex_no_perl "$CODEX_SESSION_START"
if [ "$RC" -eq 0 ]; then pass "no Perl, Codex no-arg SessionStart passes"
else fail "no Perl, Codex no-arg SessionStart passes" "rc=$RC out=$OUT err=$ERR"; fi

perl -MJSON::PP -e 'print JSON::PP->new->encode({session_id=>"large",hook_event_name=>"PreToolUse",cwd=>"/tmp/HQ",tool_name=>"Write",tool_input=>{file_path=>"companies/acme/large.md",content=>"x" x 140000}})' >"$TMP/large-company-write.json"
HQ_HQD_SOCKET="$NOSOCK" sh "$SHIM" PreToolUse <"$TMP/large-company-write.json" >"$TMP/out" 2>"$TMP/err"
RC=$?; OUT=$(cat "$TMP/out"); ERR=$(cat "$TMP/err")
if [ "$RC" -eq 2 ] && [ "$ERR" = "$CONNECT_FAIL" ] && [ -z "$OUT" ]; then pass "large company-write payload over 128 KiB blocks"
else fail "large company-write payload over 128 KiB blocks" "rc=$RC out=${#OUT} err=$ERR"; fi

run_shim "$NOSOCK" "$BASH_OTHERCO" PreToolUse
if [ "$RC" -eq 2 ]; then pass "absent socket: Bash naming companies/ blocks"
else fail "absent socket: Bash naming companies/ blocks" "rc=$RC"; fi

run_shim "$NOSOCK" "$EXEC_CMD_OTHERCO" PreToolUse
if [ "$RC" -eq 2 ] && [ "$ERR" = "$CONNECT_FAIL" ]; then pass "absent socket: exec_command cmd writing companies/ blocks"
else fail "absent socket: exec_command cmd writing companies/ blocks" "rc=$RC err=$ERR"; fi

run_shim "$NOSOCK" "$WRITE_OTHER" PreToolUse
if [ "$RC" -eq 0 ] && [ "$ERR" = "$CONNECT_FAIL" ]; then pass "absent socket: non-company write allowed, still not silent"
else fail "absent socket: non-company write allowed" "rc=$RC err=$ERR"; fi

run_shim "$NOSOCK" "$READ_OTHERCO" PreToolUse
if [ "$RC" -eq 0 ] && [ "$ERR" = "$CONNECT_FAIL" ]; then pass "absent socket: Read of companies/ allowed with the line"
else fail "absent socket: Read allowed" "rc=$RC err=$ERR"; fi

run_shim "$NOSOCK" "$START" SessionStart
if [ "$RC" -eq 0 ] && [ "$ERR" = "$CONNECT_FAIL" ] && printf '%s' "$OUT" | grep -q 'bound to company: personal'; then
  pass "absent socket: SessionStart binds personal"
else fail "absent socket: SessionStart binds personal" "rc=$RC out=$OUT err=$ERR"; fi

# UserPromptSubmit has no hqd operation, so the daemon is not contacted and an
# absent socket is not reported on it. (The line used to come from a
# session.get whose reply was discarded.) SessionStart and PreToolUse above
# still report it.
run_shim "$NOSOCK" "$PROMPT" UserPromptSubmit
if [ "$RC" -eq 0 ] && [ -z "$OUT$ERR" ]; then pass "absent socket: UserPromptSubmit passes without contacting the daemon"
else fail "absent socket: UserPromptSubmit" "rc=$RC out=$OUT err=$ERR"; fi

SOCK="$TMP/stub.sock"
start_stub "$SOCK" hang
HQ_HQD_SHIM_TIMEOUT_MS=300; export HQ_HQD_SHIM_TIMEOUT_MS
t0=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
run_shim "$SOCK" "$WRITE_OTHERCO" PreToolUse
t1=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
el=$((t1 - t0))
if [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q '^HQ daemon timed out after 300 ms (daemon busy)' && [ "$el" -lt 1500 ]; then pass "hung daemon: times out (${el}ms) and blocks the company write"
else fail "hung daemon: times out and blocks" "rc=$RC err=$ERR elapsed=${el}ms"; fi
stop_stub
unset HQ_HQD_SHIM_TIMEOUT_MS

# Busy daemon: answers after 1s. Under the old 500ms/no-retry shim this blocked
# a company write; with the 3000ms default it must be allowed.
start_slow_stub() {
  _sock="$1"; _reply="$2"; _delay="$3"
  rm -f "$_sock" "$TMP/conns"
  STUB_REPLY="$_reply" STUB_DELAY="$_delay" STUB_CONNS="$TMP/conns" perl -e '
use IO::Socket::UNIX; use Time::HiRes ();
my $srv = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Local => $ARGV[0], Listen => 5) or die "listen: $!";
$SIG{CHLD} = "IGNORE";
while (my $c = $srv->accept) {
  open my $f, ">>", $ENV{STUB_CONNS}; print $f "x\n"; close $f;
  next if fork;
  my $line = <$c>;
  Time::HiRes::sleep($ENV{STUB_DELAY});
  print $c $ENV{STUB_REPLY}, "\n"; close $c; exit 0;
}' "$_sock" &
  STUB_PID=$!
  _i=0
  while [ ! -S "$_sock" ] && [ $_i -lt 50 ]; do sleep 0.1; _i=$((_i + 1)); done
}
SLOW_ALLOW='{"id":1,"ok":true,"result":{"decision":"allow","reasons":[],"additionalContext":""}}'
start_slow_stub "$SOCK" "$SLOW_ALLOW" 1
run_shim "$SOCK" "$WRITE_OTHERCO" PreToolUse
if [ "$RC" -eq 0 ] && [ -z "$ERR" ]; then pass "daemon replying after 1s: company write is allowed (default 3000ms budget)"
else fail "daemon replying after 1s: company write is allowed" "rc=$RC err=$ERR"; fi
stop_stub

# The env override still works, and a slow daemon gets one attempt: one
# connection, then the busy message, inside the budget. A timeout is never
# retried (a second attempt doubled the worst case under load).
start_slow_stub "$SOCK" "$SLOW_ALLOW" 1
t0=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
HQ_HQD_SHIM_TIMEOUT_MS=300 run_shim "$SOCK" "$WRITE_OTHERCO" PreToolUse
unset HQ_HQD_SHIM_TIMEOUT_MS HQ_HQD_SHIM_DEADLINE_MS HQ_HQD_SHIM_REPORT_UNREACHABLE PERL5LIB
t1=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
el=$((t1 - t0))
CONNS=$(wc -l <"$TMP/conns" | tr -d ' ')
if [ "$RC" -eq 2 ] && [ "$CONNS" -eq 1 ] && [ "$el" -lt 1500 ] && printf '%s' "$ERR" | grep -q 'timed out after 300 ms (daemon busy)'; then
  pass "busy daemon past the budget: one attempt, fails closed with the busy message (${el}ms)"
else fail "busy daemon past the budget: one attempt, then fails closed" "rc=$RC conns=$CONNS elapsed=${el}ms err=$ERR"; fi
stop_stub

# A daemon that accepts and never reads, with a payload larger than the
# socket send buffer (8 KB on macOS, about 208 KB on Linux): the write blocks
# after a partial send.
# An alarm-only timeout could not interrupt that write; the non-blocking client
# must still stop at the budget.
start_noread_stub() {
  _sock="$1"
  rm -f "$_sock"
  perl -e '
use IO::Socket::UNIX;
my $srv = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Local => $ARGV[0], Listen => 5) or die "listen: $!";
my @held;
while (my $c = $srv->accept) { push @held, $c; }' "$_sock" &
  STUB_PID=$!
  _i=0
  while [ ! -S "$_sock" ] && [ $_i -lt 50 ]; do sleep 0.1; _i=$((_i + 1)); done
}
BIG_CMD=$(perl -e 'print "x" x 1100000')
BIG_WRITE=$(printf '{"session_id":"s1","hook_event_name":"PreToolUse","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"echo %s > companies/otherco/x.md"}}' "$BIG_CMD")
BIG_OTHER=$(printf '{"session_id":"s1","hook_event_name":"PreToolUse","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"echo %s"}}' "$BIG_CMD")
start_noread_stub "$SOCK"
t0=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
HQ_HQD_SHIM_TIMEOUT_MS=500 run_shim "$SOCK" "$BIG_WRITE" PreToolUse
unset HQ_HQD_SHIM_TIMEOUT_MS HQ_HQD_SHIM_DEADLINE_MS HQ_HQD_SHIM_REPORT_UNREACHABLE PERL5LIB
t1=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
el=$((t1 - t0))
if [ "$RC" -eq 2 ] && [ "$el" -lt 2500 ] && printf '%s' "$ERR" | grep -q 'timed out after 500 ms (daemon busy)'; then
  pass "daemon that stops reading a 1.1 MB payload: bounded at the budget, company write fails closed (${el}ms)"
else fail "daemon that stops reading a large payload is bounded by the budget" "rc=$RC elapsed=${el}ms err=$ERR"; fi
t0=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
HQ_HQD_SHIM_TIMEOUT_MS=500 run_shim "$SOCK" "$BIG_OTHER" PreToolUse
unset HQ_HQD_SHIM_TIMEOUT_MS HQ_HQD_SHIM_DEADLINE_MS HQ_HQD_SHIM_REPORT_UNREACHABLE PERL5LIB
t1=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
el=$((t1 - t0))
if [ "$RC" -eq 0 ] && [ "$el" -lt 2500 ]; then pass "daemon that stops reading: non-company call passes inside the budget (${el}ms)"
else fail "daemon that stops reading: non-company call" "rc=$RC elapsed=${el}ms err=$ERR"; fi
t0=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
HQ_HQD_SHIM_REPORT_UNREACHABLE=1 HQ_HQD_SHIM_TIMEOUT_MS=500 run_shim "$SOCK" "$BIG_WRITE" PreToolUse
unset HQ_HQD_SHIM_TIMEOUT_MS HQ_HQD_SHIM_DEADLINE_MS HQ_HQD_SHIM_REPORT_UNREACHABLE PERL5LIB
t1=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
el=$((t1 - t0))
if [ "$RC" -eq 75 ] && [ -z "$ERR" ] && [ "$el" -lt 2500 ]; then pass "daemon that stops reading, master-hook mode: reports 75 inside the budget (${el}ms)"
else fail "daemon that stops reading, master-hook mode reports 75" "rc=$RC elapsed=${el}ms err=$ERR"; fi

# Caller deadline (master-hook passes its own start + budget): the budget
# shrinks to the time left, and a deadline already past fails at once.
t0=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
HQ_HQD_SHIM_DEADLINE_MS=$((t0 + 400)) run_shim "$SOCK" "$WRITE_OTHERCO" PreToolUse
unset HQ_HQD_SHIM_TIMEOUT_MS HQ_HQD_SHIM_DEADLINE_MS HQ_HQD_SHIM_REPORT_UNREACHABLE PERL5LIB
t1=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
el=$((t1 - t0))
if [ "$RC" -eq 2 ] && [ "$el" -lt 1200 ] && printf '%s' "$ERR" | grep -q 'HQ daemon timed out after'; then
  pass "caller deadline 400 ms away cuts the 3000 ms default budget (${el}ms)"
else fail "caller deadline cuts the budget" "rc=$RC elapsed=${el}ms err=$ERR"; fi
t0=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
HQ_HQD_SHIM_REPORT_UNREACHABLE=1 HQ_HQD_SHIM_DEADLINE_MS=$((t0 - 5000)) run_shim "$SOCK" "$WRITE_OTHERCO" PreToolUse
unset HQ_HQD_SHIM_TIMEOUT_MS HQ_HQD_SHIM_DEADLINE_MS HQ_HQD_SHIM_REPORT_UNREACHABLE PERL5LIB
t1=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
el=$((t1 - t0))
if [ "$RC" -eq 75 ] && [ "$el" -lt 1500 ]; then pass "caller deadline already past: falls back at once (${el}ms)"
else fail "caller deadline already past falls back at once" "rc=$RC elapsed=${el}ms err=$ERR"; fi
HQ_HQD_SHIM_DEADLINE_MS=not-a-number run_shim "$NOSOCK" "$WRITE_OTHERCO" PreToolUse
unset HQ_HQD_SHIM_TIMEOUT_MS HQ_HQD_SHIM_DEADLINE_MS HQ_HQD_SHIM_REPORT_UNREACHABLE PERL5LIB
if [ "$RC" -eq 2 ] && [ "$ERR" = "$CONNECT_FAIL" ]; then pass "malformed caller deadline is ignored"
else fail "malformed caller deadline is ignored" "rc=$RC err=$ERR"; fi
stop_stub

# Hard timer: perl stalls while loading a module (before any socket work).
# The default-action SIGALRM ends it 250 ms after the budget; the shim treats
# that as a timeout.
mkdir -p "$TMP/slowlib/JSON"
# Only the client perl (it alone has HQD_SHIM_SOCKET) stalls; the module probe
# before it loads the stand-in at once.
printf 'package JSON::PP; sleep 30 if $ENV{HQD_SHIM_SOCKET}; 1;\n' >"$TMP/slowlib/JSON/PP.pm"
start_stub "$SOCK" hang
t0=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
PERL5LIB="$TMP/slowlib" HQ_HQD_SHIM_TIMEOUT_MS=400 run_shim "$SOCK" "$WRITE_OTHERCO" PreToolUse
unset HQ_HQD_SHIM_TIMEOUT_MS HQ_HQD_SHIM_DEADLINE_MS HQ_HQD_SHIM_REPORT_UNREACHABLE PERL5LIB
t1=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
el=$((t1 - t0))
if [ "$RC" -eq 2 ] && [ "$el" -lt 1500 ] && printf '%s' "$ERR" | grep -q 'HQ daemon timed out after 400 ms'; then
  pass "perl stalled in a module load: hard timer ends it, company write fails closed (${el}ms)"
else fail "perl stalled in a module load is ended by the hard timer" "rc=$RC elapsed=${el}ms err=$ERR"; fi
t0=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
PERL5LIB="$TMP/slowlib" HQ_HQD_SHIM_REPORT_UNREACHABLE=1 HQ_HQD_SHIM_TIMEOUT_MS=400 run_shim "$SOCK" "$WRITE_OTHERCO" PreToolUse
unset HQ_HQD_SHIM_TIMEOUT_MS HQ_HQD_SHIM_DEADLINE_MS HQ_HQD_SHIM_REPORT_UNREACHABLE PERL5LIB
t1=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
el=$((t1 - t0))
if [ "$RC" -eq 75 ] && [ "$el" -lt 1500 ]; then pass "perl stalled in a module load, master-hook mode: reports 75 (${el}ms)"
else fail "perl stalled in a module load, master-hook mode" "rc=$RC elapsed=${el}ms err=$ERR"; fi
stop_stub

# A client module that fails to load: the client perl exits 76 before it
# reads the payload. master-hook mode falls back (75); otherwise the answer is
# the one for no usable perl (company write fails closed).
mkdir -p "$TMP/nolib/JSON"
printf 'package JSON::PP; die "JSON::PP unavailable\\n" if $ENV{HQD_SHIM_SOCKET}; 1;\n' >"$TMP/nolib/JSON/PP.pm"
PERL5LIB="$TMP/nolib" run_shim "$NOSOCK" "$WRITE_OTHERCO" PreToolUse
unset HQ_HQD_SHIM_TIMEOUT_MS HQ_HQD_SHIM_DEADLINE_MS HQ_HQD_SHIM_REPORT_UNREACHABLE PERL5LIB
if [ "$RC" -eq 2 ] && [ "$ERR" = "$UNREACHABLE" ]; then pass "JSON::PP missing: company write fails closed"
else fail "JSON::PP missing: company write fails closed" "rc=$RC err=$ERR"; fi
PERL5LIB="$TMP/nolib" HQ_HQD_SHIM_REPORT_UNREACHABLE=1 run_shim "$NOSOCK" "$WRITE_OTHERCO" PreToolUse
unset HQ_HQD_SHIM_TIMEOUT_MS HQ_HQD_SHIM_DEADLINE_MS HQ_HQD_SHIM_REPORT_UNREACHABLE PERL5LIB
if [ "$RC" -eq 75 ]; then pass "JSON::PP missing, master-hook mode: reports 75"
else fail "JSON::PP missing, master-hook mode: reports 75" "rc=$RC err=$ERR"; fi

# A daemon that recovers after a slow first answer is not retried: the one
# attempt times out and the shim fails closed.
start_slow_stub "$SOCK" "$SLOW_ALLOW" 1
HQ_HQD_SHIM_TIMEOUT_MS=300 run_shim "$SOCK" "$WRITE_OTHERCO" PreToolUse
unset HQ_HQD_SHIM_TIMEOUT_MS HQ_HQD_SHIM_DEADLINE_MS HQ_HQD_SHIM_REPORT_UNREACHABLE PERL5LIB
CONNS=$(wc -l <"$TMP/conns" | tr -d ' ')
if [ "$RC" -eq 2 ] && [ "$CONNS" -eq 1 ]; then pass "timed-out attempt is not retried (one connection)"
else fail "timed-out attempt is not retried" "rc=$RC conns=$CONNS err=$ERR"; fi
stop_stub

# No socket at all (marker present): still fails closed with the connect message.
run_shim "$NOSOCK" "$WRITE_OTHERCO" PreToolUse
if [ "$RC" -eq 2 ] && [ "$ERR" = "$CONNECT_FAIL" ]; then pass "no socket: company write still fails closed with the not-running message"
else fail "no socket still fails closed" "rc=$RC err=$ERR"; fi

# Zero spelled with extra digits must not disable the alarm (fail-open): a
# daemon that accepts and never replies is still cut off and the write blocked.
_zero10=$(printf '%010d' 0)
for _z in 00 000 "$_zero10"; do
  start_stub "$SOCK" hang
  _t0=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
  HQ_HQD_SHIM_TIMEOUT_MS=$_z HQ_HQD_SHIM_RETRY_BACKOFF_MS=$_z run_shim "$SOCK" "$WRITE_OTHERCO" PreToolUse
  _t1=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
  unset HQ_HQD_SHIM_TIMEOUT_MS HQ_HQD_SHIM_RETRY_BACKOFF_MS
  _el=$((_t1 - _t0))
  if [ "$RC" -eq 2 ] && [ "$_el" -lt 8000 ] && printf '%s' "$ERR" | grep -q 'timed out after 3000 ms'; then
    pass "timeout '$_z' normalizes to the 3000ms default and still blocks (${_el}ms)"
  else fail "timeout '$_z' must not disable the alarm" "rc=$RC elapsed=${_el}ms err=$ERR"; fi
  stop_stub
done

# A huge value is accepted without overflow and still works against a fast daemon.
start_slow_stub "$SOCK" "$SLOW_ALLOW" 1
_huge=$(printf '%023d' 0 | tr 0 9)
HQ_HQD_SHIM_TIMEOUT_MS=$_huge run_shim "$SOCK" "$WRITE_OTHERCO" PreToolUse
unset HQ_HQD_SHIM_TIMEOUT_MS
if [ "$RC" -eq 0 ] && [ -z "$ERR" ]; then pass "huge timeout value: capped, no overflow, daemon answer honored"
else fail "huge timeout value" "rc=$RC err=$ERR"; fi
stop_stub

# A client perl that starts (prints its started marker) and then dies (exit
# 255): a PreToolUse on a companies/ path must still fail closed; a
# non-company call is allowed. A perl that never starts the client is covered
# by the "unavailable Perl modules" cases above.
mkdir -p "$TMP/perl-dies"
cat > "$TMP/perl-dies/perl" <<'PERL_DIES'
#!/bin/sh
printf '%s' '@@hqd-shim-started@@'
exit 255
PERL_DIES
chmod +x "$TMP/perl-dies/perl"
printf '%s' "$WRITE_OTHERCO" | env PATH="$TMP/perl-dies:$PATH" HQ_HQD_SOCKET="$NOSOCK" sh "$SHIM" PreToolUse >"$TMP/out" 2>"$TMP/err"
RC=$?; ERR=$(cat "$TMP/err")
if [ "$RC" -eq 2 ] && [ "$ERR" = "$UNREACHABLE" ]; then pass "perl exits 255: companies/ write fails closed"
else fail "perl exits 255: companies/ write fails closed" "rc=$RC err=$ERR"; fi
printf '%s' "$WRITE_OTHER" | env PATH="$TMP/perl-dies:$PATH" HQ_HQD_SOCKET="$NOSOCK" sh "$SHIM" PreToolUse >"$TMP/out" 2>"$TMP/err"
RC=$?
if [ "$RC" -eq 0 ]; then pass "perl exits 255: non-company call is not blocked"
else fail "perl exits 255: non-company call" "rc=$RC"; fi

# SessionEnd has a 3s hook budget: a hung daemon is not retried and is capped at 1s.
start_stub "$SOCK" hang
unset HQ_HQD_SHIM_TIMEOUT_MS
SESSION_END='{"session_id":"s1","hook_event_name":"SessionEnd","cwd":"/tmp"}'
t0=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
run_shim "$SOCK" "$SESSION_END" SessionEnd
t1=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
el=$((t1 - t0))
if [ "$RC" -eq 0 ] && [ "$el" -ge 900 ] && [ "$el" -lt 2000 ] && printf "%s" "$ERR" | grep -q "after 1000 ms"; then pass "SessionEnd on a hung daemon: capped at 1s, exits 0 (${el}ms)"
else fail "SessionEnd on a hung daemon stays inside its 3s hook budget" "rc=$RC elapsed=${el}ms err=$ERR"; fi
stop_stub

start_stub "$SOCK" '{"id":1,"ok":true,"result":{"decision":"block","reasons":["BLOCKED: Cross-company scope violation"],"additionalContext":""}}'
run_shim "$SOCK" "$WRITE_OTHERCO" PreToolUse
if [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q 'Cross-company scope violation'; then pass "stub block: exit 2 with reasons on stderr"
else fail "stub block" "rc=$RC err=$ERR"; fi
if grep -q '"op":"policy.check"' "$TMP/req" && grep -q '"sessionId":"s1"' "$TMP/req" && grep -q '"cwd":"/tmp/foreign-repo"' "$TMP/req"; then
  pass "PreToolUse forwards policy.check with sessionId and cwd"
else fail "PreToolUse request shape" "$(cat "$TMP/req")"; fi
stop_stub

start_stub "$SOCK" '{"id":1,"ok":true,"result":{"decision":"allow","reasons":[],"additionalContext":"Policy X applies"}}'
run_shim "$SOCK" "$WRITE_OTHER" PreToolUse --runtime codex
if [ "$RC" -eq 0 ] && [ -z "$ERR" ] && printf '%s' "$OUT" | grep -q '"additionalContext":"Policy X applies"' && printf '%s' "$OUT" | grep -q '"hookEventName":"PreToolUse"'; then
  pass "stub allow: additionalContext in hookSpecificOutput"
else fail "stub allow context" "rc=$RC out=$OUT err=$ERR"; fi
if grep -q '"runtime":"codex"' "$TMP/req"; then pass "--runtime codex is forwarded"
else fail "--runtime codex is forwarded" "$(cat "$TMP/req")"; fi
stop_stub

start_stub "$SOCK" '{"id":1,"ok":true,"result":{"additionalContext":"missing decision"}}'
run_shim "$SOCK" "$WRITE_OTHERCO" PreToolUse
if [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -qi 'policy check failed'; then pass "missing policy decision fails closed for company writes"
else fail "missing policy decision fails closed" "rc=$RC err=$ERR"; fi
stop_stub

start_stub "$SOCK" '{"id":1,"ok":true,"result":{"decision":"permit","additionalContext":"unknown decision"}}'
run_shim "$SOCK" "$WRITE_OTHERCO" PreToolUse
if [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -qi 'policy check failed'; then pass "unknown policy decision fails closed for company writes"
else fail "unknown policy decision fails closed" "rc=$RC err=$ERR"; fi
stop_stub

start_stub "$SOCK" '{"id":1,"ok":false,"error":{"code":"bad_args","message":"company is required"}}'
run_shim "$SOCK" "$WRITE_OTHERCO" PreToolUse
if [ "$RC" -eq 2 ]; then pass "daemon error on a company write fails closed"
else fail "daemon error on a company write fails closed" "rc=$RC err=$ERR"; fi
run_shim "$SOCK" "$WRITE_OTHER" PreToolUse
if [ "$RC" -eq 0 ] && printf '%s' "$ERR" | grep -q 'company is required'; then pass "daemon error on other writes allows and reports"
else fail "daemon error on other writes" "rc=$RC err=$ERR"; fi
stop_stub

# hqd cannot read the HQ folder (macOS privacy refusal under ~/Documents): the
# shim runs the HQ root's scope authorizer in its own process. A fake HQ root
# holds a copy of the shim and a stub authorizer that records its input.
FAKE_HQ="$TMP/fake-hq"
mkdir -p "$FAKE_HQ/core/scripts" "$FAKE_HQ/.claude/hooks"
cp "$SHIM" "$HERE/hq-anywhere-runtime-flag.cjs" "$HERE"/hqd-hook-flag-cache*.sh "$FAKE_HQ/core/scripts/"
FAKE_SHIM="$FAKE_HQ/core/scripts/hqd-hook-shim.sh"
FAKE_AUTH="$FAKE_HQ/.claude/hooks/mandatory-scope-authorizer.sh"
FAKE_TRIGGER="$FAKE_HQ/.claude/hooks/inject-policy-on-trigger.sh"
# stub_authorizer <exit-code> [stderr line] [stdout line]: records its stdin,
# cwd and any HQ_HOOK_* / HQ_SCOPE_FOLD_COPY it was given.
stub_authorizer() {
  printf '#!/bin/sh\ncat >"%s"\npwd -P >"%s"\nenv | grep -E "^(HQ_HOOK_|HQ_SCOPE_FOLD_COPY)" >"%s"\n[ ! -f "%s" ] || cat "%s"\n[ -z "%s" ] || printf "%%s\\n" "%s" >&2\nexit %s\n' \
    "$TMP/auth-in" "$TMP/auth-cwd" "$TMP/auth-env" "$TMP/auth-stdout" "$TMP/auth-stdout" "${2:-}" "${2:-}" "$1" >"$FAKE_AUTH"
  rm -f "$TMP/auth-in" "$TMP/auth-cwd" "$TMP/auth-env" "$TMP/auth-stdout"
  [ -z "${3:-}" ] || printf '%s\n' "$3" >"$TMP/auth-stdout"
}
# run_fake_shim <socket> <payload> [args...] -> $RC, $OUT, $ERR
run_fake_shim() {
  _sock="$1"; _payload="$2"; shift 2
  printf '%s' "$_payload" | HQ_HQD_SOCKET="$_sock" sh "$FAKE_SHIM" "$@" >"$TMP/out" 2>"$TMP/err"
  RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}
LS_OTHERCO='{"session_id":"s1","hook_event_name":"PreToolUse","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"ls companies/otherco"}}'
EPERM_REPLY=$(printf '{"id":1,"ok":false,"error":{"code":"internal","message":"EPERM: operation not permitted, open '\''%s/workspace/sessions/s1/meta.yaml'\''"}}' "$FAKE_HQ")

start_stub "$SOCK" "$EPERM_REPLY"
stub_authorizer 0
run_fake_shim "$SOCK" "$LS_OTHERCO" PreToolUse
if [ "$RC" -eq 0 ] && grep -q '"ls companies/otherco"' "$TMP/auth-in" 2>/dev/null \
  && [ "$(cat "$TMP/auth-cwd" 2>/dev/null)" = "$(cd "$FAKE_HQ" && pwd -P)" ]; then
  pass "daemon EPERM: local scope authorizer decides (allow) with the original payload"
else fail "daemon EPERM: local authorizer allows" "rc=$RC err=$ERR in=$(cat "$TMP/auth-in" 2>/dev/null)"; fi

stub_authorizer 2 'BLOCKED: stub cross-company'
run_fake_shim "$SOCK" "$LS_OTHERCO" PreToolUse
if [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q 'BLOCKED: stub cross-company'; then pass "daemon EPERM: local scope authorizer block is kept"
else fail "daemon EPERM: local authorizer blocks" "rc=$RC err=$ERR"; fi

stub_authorizer 0
run_fake_shim "$SOCK" "$READ_OTHERCO" PreToolUse
if [ "$RC" -eq 0 ] && [ -s "$TMP/auth-in" ]; then pass "daemon EPERM: reads are checked locally too"
else fail "daemon EPERM: reads checked locally" "rc=$RC err=$ERR"; fi

stub_authorizer 0
# A prefix assignment on a function call persists in POSIX sh, so unset it.
HQ_HQD_SHIM_REPORT_UNREACHABLE=1 run_fake_shim "$SOCK" "$LS_OTHERCO" PreToolUse
unset HQ_HQD_SHIM_REPORT_UNREACHABLE
if [ "$RC" -eq 0 ] && [ -s "$TMP/auth-in" ]; then pass "daemon EPERM, master-hook mode: local authorizer decides instead of falling back"
else fail "daemon EPERM, master-hook mode: local authorizer decides" "rc=$RC err=$ERR"; fi

# The scripts trust HQ_HOOK_* over the payload, and HQ_SCOPE_FOLD_COPY relaxes
# the check: a value the caller exported must not reach the local run.
stub_authorizer 0
export HQ_HOOK_TOOL_NAME=TodoWrite HQ_HOOK_SESSION_ID=other HQ_SCOPE_FOLD_COPY=1
run_fake_shim "$SOCK" "$LS_OTHERCO" PreToolUse
unset HQ_HOOK_TOOL_NAME HQ_HOOK_SESSION_ID HQ_SCOPE_FOLD_COPY
if [ "$RC" -eq 0 ] && [ -f "$TMP/auth-env" ] && [ ! -s "$TMP/auth-env" ]; then pass "daemon EPERM: caller HQ_HOOK_* and HQ_SCOPE_FOLD_COPY do not reach the local authorizer"
else fail "daemon EPERM: hook env stripped" "rc=$RC env=$(cat "$TMP/auth-env" 2>/dev/null)"; fi

stub_authorizer 0 '' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"stub json deny"}}'
run_fake_shim "$SOCK" "$LS_OTHERCO" PreToolUse
if [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q 'stub json deny'; then pass "daemon EPERM: a JSON deny from the local authorizer blocks"
else fail "daemon EPERM: JSON deny blocks" "rc=$RC out=$OUT err=$ERR"; fi

stub_authorizer 0
printf '#!/bin/sh\ncat >/dev/null\nprintf "%%s\\n" "{\\"hookSpecificOutput\\":{\\"hookEventName\\":\\"PreToolUse\\",\\"additionalContext\\":\\"stub policy context\\"}}"\n' >"$FAKE_TRIGGER"
run_fake_shim "$SOCK" "$LS_OTHERCO" PreToolUse
rm -f "$FAKE_TRIGGER"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '"additionalContext":"stub policy context"' && printf '%s' "$OUT" | grep -q '"hookEventName":"PreToolUse"'; then
  pass "daemon EPERM: the local policy trigger supplies the policy context"
else fail "daemon EPERM: local policy trigger context" "rc=$RC out=$OUT err=$ERR"; fi

stub_authorizer 0
run_fake_shim "$SOCK" "$START" SessionStart
if [ "$RC" -eq 0 ] && [ ! -f "$TMP/auth-in" ]; then pass "daemon EPERM on SessionStart: no local scope check"
else fail "daemon EPERM on SessionStart: no local scope check" "rc=$RC err=$ERR"; fi

stub_authorizer 1 'boom'
run_fake_shim "$SOCK" "$LS_OTHERCO" PreToolUse
if [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q 'failing closed'; then pass "daemon EPERM: authorizer error fails closed"
else fail "daemon EPERM: authorizer error fails closed" "rc=$RC err=$ERR"; fi

rm -f "$FAKE_AUTH"
run_fake_shim "$SOCK" "$LS_OTHERCO" PreToolUse
if [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q 'could not check this call'; then pass "daemon EPERM, no local authorizer: company tool call fails closed"
else fail "daemon EPERM, no local authorizer: fails closed" "rc=$RC err=$ERR"; fi
# Same answer as any other daemon error: only a call that may write a company
# path is refused; a Read tool call is not.
run_fake_shim "$SOCK" "$READ_OTHERCO" PreToolUse
if [ "$RC" -eq 0 ] && printf '%s' "$ERR" | grep -q 'could not check this call'; then pass "daemon EPERM, no local authorizer: Read is allowed and reported, as before"
else fail "daemon EPERM, no local authorizer: Read allowed" "rc=$RC err=$ERR"; fi
HQ_HQD_SHIM_REPORT_UNREACHABLE=1 run_fake_shim "$SOCK" "$LS_OTHERCO" PreToolUse
unset HQ_HQD_SHIM_REPORT_UNREACHABLE
if [ "$RC" -eq 75 ]; then pass "daemon EPERM, no local authorizer, master-hook mode: reports 75"
else fail "daemon EPERM, no local authorizer, master-hook mode: reports 75" "rc=$RC err=$ERR"; fi

# Interaction with #2073 ("stop the perl launch storm"): on an EPERM allow with
# empty authorizer and empty trigger output, the shim must still start perl only
# once (no extra hook_json perl launches).
stub_authorizer 0
printf '#!/bin/sh\ncat >/dev/null\nexit 0\n' >"$FAKE_TRIGGER"
: >"$TMP/perl-count/log"
printf '%s' "$LS_OTHERCO" | env PATH="$TMP/perl-count:$PATH" HQ_HQD_SOCKET="$SOCK" \
  sh "$FAKE_SHIM" PreToolUse >"$TMP/out" 2>"$TMP/err"
RC=$?; ERR=$(cat "$TMP/err")
PERL_STARTS=$(wc -l <"$TMP/perl-count/log" | tr -d ' ')
rm -f "$FAKE_TRIGGER"
if [ "$PERL_STARTS" -eq 1 ] && [ "$RC" -eq 0 ] && [ -s "$TMP/auth-in" ]; then
  pass "daemon EPERM fallback with empty authorizer/trigger output starts perl once"
else fail "daemon EPERM fallback starts perl once" "perl_starts=$PERL_STARTS rc=$RC err=$ERR"; fi
stop_stub

# EPERM path through a symlink pointing to the HQ root still matches the HQ root.
ln -s "$FAKE_HQ" "$TMP/fake-hq-link"
EPERM_SYMLINK_ROOT=$(printf '{"id":1,"ok":false,"error":{"code":"internal","message":"EPERM: operation not permitted, open '\''%s/workspace/sessions/s1/meta.yaml'\''"}}' "$TMP/fake-hq-link")
start_stub "$SOCK" "$EPERM_SYMLINK_ROOT"
stub_authorizer 0
run_fake_shim "$SOCK" "$LS_OTHERCO" PreToolUse
if [ "$RC" -eq 0 ] && [ -s "$TMP/auth-in" ]; then pass "daemon EPERM via symlinked HQ root: local scope authorizer decides"
else fail "daemon EPERM via symlinked HQ root" "rc=$RC err=$ERR"; fi
stop_stub

# Raw EPERM fallback requires code "internal" and a path under this HQ root.
# Unrelated paths, sibling prefixes, .. escapes, symlink escapes, non-internal
# codes, and pathless EPERM messages must NOT trigger the local fallback.
mkdir -p "$TMP/outside-hq"
ln -s "$TMP/outside-hq" "$FAKE_HQ/escape-link"
for _case in \
  "outside HQ root|internal|EPERM: operation not permitted, open '/x/daemon-state/meta.yaml'" \
  "sibling prefix|internal|EPERM: operation not permitted, open '${FAKE_HQ}-other/workspace/sessions/s1/meta.yaml'" \
  "dot-dot escape|internal|EPERM: operation not permitted, open '${FAKE_HQ}/../other/meta.yaml'" \
  "symlink escape|internal|EPERM: operation not permitted, open '${FAKE_HQ}/escape-link/meta.yaml'" \
  "non-internal code|bad_args|EPERM: operation not permitted, open '${FAKE_HQ}/workspace/sessions/s1/meta.yaml'" \
  "pathless EPERM|internal|EPERM: operation not permitted"
do
  _label=${_case%%|*}
  _rest=${_case#*|}
  _code=${_rest%%|*}
  _msg=${_rest#*|}
  _reply=$(printf '{"id":1,"ok":false,"error":{"code":"%s","message":"%s"}}' "$_code" "$_msg")
  start_stub "$SOCK" "$_reply"
  stub_authorizer 0
  run_fake_shim "$SOCK" "$LS_OTHERCO" PreToolUse
  if [ "$RC" -eq 2 ] && [ ! -f "$TMP/auth-in" ] && printf '%s' "$ERR" | grep -q 'HQ policy check failed'; then
    pass "daemon EPERM ($_label): does not run local authorizer, company call fails closed"
  else
    fail "daemon EPERM ($_label): fails closed without local authorizer" "rc=$RC auth_ran=$([ -f "$TMP/auth-in" ] && echo yes || echo no) err=$ERR"
  fi
  if [ "$_label" = "outside HQ root" ]; then
    stub_authorizer 0
    run_fake_shim "$SOCK" "$WRITE_OTHER" PreToolUse
    if [ "$RC" -eq 0 ] && [ ! -f "$TMP/auth-in" ] && printf '%s' "$ERR" | grep -q 'HQ daemon: policy.check failed'; then
      pass "daemon EPERM (outside HQ root): non-company call allows and reports without local authorizer"
    else
      fail "daemon EPERM (outside HQ root): non-company call" "rc=$RC auth_ran=$([ -f "$TMP/auth-in" ] && echo yes || echo no) err=$ERR"
    fi
  fi
  stop_stub
done
rm -f "$FAKE_HQ/escape-link"

start_stub "$SOCK" '{"id":1,"ok":false,"error":{"code":"hq_root_unreadable","message":"hqd cannot read the HQ folder"}}'
stub_authorizer 0
run_fake_shim "$SOCK" "$LS_OTHERCO" PreToolUse
if [ "$RC" -eq 0 ] && [ -s "$TMP/auth-in" ]; then pass "daemon hq_root_unreadable code: local scope authorizer decides"
else fail "daemon hq_root_unreadable: local authorizer decides" "rc=$RC err=$ERR"; fi
stop_stub

# hqd answers anywhere_disabled when the live HQ Anywhere flag is off while the
# shim's flag cache still says on. That is not a verdict on the call: the local
# scope authorizer decides, so a bound-company write or a read-only command in
# a company folder goes through, and a cross-company one is still refused.
start_stub "$SOCK" '{"id":1,"ok":false,"error":{"code":"anywhere_disabled","message":"HQ Anywhere is disabled by the hq-anywhere-runtime flag."}}'
stub_authorizer 0
run_fake_shim "$SOCK" "$WRITE_OTHERCO" PreToolUse
if [ "$RC" -eq 0 ] && [ -s "$TMP/auth-in" ] && [ -z "$ERR" ]; then pass "anywhere_disabled: company write is decided by the local authorizer (allow)"
else fail "anywhere_disabled: company write decided locally (allow)" "rc=$RC out=$OUT err=$ERR"; fi
BASH_GREP_CO='{"session_id":"s1","hook_event_name":"PreToolUse","cwd":"/tmp/HQ","tool_name":"Bash","tool_input":{"command":"cd companies/otherco/notes && grep draft file.md"}}'
stub_authorizer 0
run_fake_shim "$SOCK" "$BASH_GREP_CO" PreToolUse
if [ "$RC" -eq 0 ] && grep -q 'grep draft' "$TMP/auth-in" 2>/dev/null; then pass "anywhere_disabled: bash in a company folder is decided by the local authorizer"
else fail "anywhere_disabled: bash in a company folder decided locally" "rc=$RC out=$OUT err=$ERR"; fi
stub_authorizer 2 'BLOCKED: stub cross-company'
run_fake_shim "$SOCK" "$WRITE_OTHERCO" PreToolUse
if [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q 'BLOCKED: stub cross-company'; then pass "anywhere_disabled: a cross-company write is still blocked by the local authorizer"
else fail "anywhere_disabled: cross-company write still blocked" "rc=$RC err=$ERR"; fi
stub_authorizer 0
run_fake_shim "$SOCK" "$START" SessionStart
if [ "$RC" -eq 0 ] && [ -z "$ERR" ] && [ ! -f "$TMP/auth-in" ]; then pass "anywhere_disabled on SessionStart: quiet, no local scope check"
else fail "anywhere_disabled on SessionStart: quiet" "rc=$RC err=$ERR"; fi
stop_stub

start_stub "$SOCK" '{"id":1,"ok":false,"error":{"code":"bad_args","message":"company is required"}}'
run_shim "$SOCK" "$LS_OTHERCO" PreToolUse
if [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q 'refusing a tool call that may touch a companies/ path'; then pass "other daemon errors still fail closed, worded as a tool call (not a write)"
else fail "other daemon errors fail closed with tool-call wording" "rc=$RC err=$ERR"; fi
stop_stub

# The same fallback with the REAL scope authorizer (not a stub): a fixture HQ
# root holds a copy of the shim, the repo's mandatory-scope-authorizer.sh and
# the helpers it sources, a manifest with two companies and session s1 bound
# to indigo. When hqd declines (EPERM, hq_root_unreadable, anywhere_disabled),
# a call into another company must stay blocked and an ordinary call must pass.
REAL_HQ="$TMP/real-scope-hq"
mkdir -p "$REAL_HQ/core/scripts/lib" "$REAL_HQ/.claude/hooks" \
  "$REAL_HQ/workspace/sessions/s1" "$REAL_HQ/workspace/output" \
  "$REAL_HQ/companies/indigo/settings" "$REAL_HQ/companies/otherco/settings"
cp "$SHIM" "$HERE/hq-anywhere-runtime-flag.cjs" "$HERE"/hqd-hook-flag-cache*.sh "$HERE/hook-lib.sh" "$REAL_HQ/core/scripts/"
for lib in session-authz session-scope-capability session-id hook-caller-lineage; do
  cp "$HERE/lib/$lib.sh" "$REAL_HQ/core/scripts/lib/"
done
cp "$ROOT/.claude/hooks/mandatory-scope-authorizer.sh" "$ROOT/.claude/hooks/bash-arith-subst-guard-lib.sh" \
  "$ROOT/.claude/hooks/path-fold-lib.sh" "$REAL_HQ/.claude/hooks/"
printf 'companies:\n  indigo:\n    name: Indigo\n  otherco:\n    name: Other\n' >"$REAL_HQ/companies/manifest.yaml"
printf 'company_slug: indigo\n' >"$REAL_HQ/workspace/sessions/s1/meta.yaml"
printf '{"session_id":"s1","company_slug":"indigo","minted_at":"2026-10-22T00:00:00Z"}\n' >"$REAL_HQ/workspace/sessions/s1/scope-capability.json"
printf 'own\n' >"$REAL_HQ/companies/indigo/settings/README.md"
printf 'foreign\n' >"$REAL_HQ/companies/otherco/settings/README.md"
printf 'notes\n' >"$REAL_HQ/workspace/output/notes.md"
REAL_HQ_P=$(cd "$REAL_HQ" && pwd -P)
REAL_SHIM="$REAL_HQ/core/scripts/hqd-hook-shim.sh"
# real_payload <tool> <input-json> -> payload with cwd at the fixture root
real_payload() {
  printf '{"session_id":"s1","hook_event_name":"PreToolUse","cwd":"%s","tool_name":"%s","tool_input":%s}' "$REAL_HQ_P" "$1" "$2"
}
# run_real_shim <socket> <payload> -> $RC, $OUT, $ERR
run_real_shim() {
  printf '%s' "$2" | HQ_HQD_SOCKET="$1" sh "$REAL_SHIM" PreToolUse >"$TMP/out" 2>"$TMP/err"
  RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}
# real_case <block|allow> <name> <payload>: block is exit 2 with the
# authorizer's own BLOCKED message (not a fail-closed error from the shim);
# allow is exit 0 with no missing-file error.
real_case() {
  run_real_shim "$SOCK" "$3"
  if [ "$1" = block ]; then
    if [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q 'BLOCKED' \
      && ! printf '%s' "$ERR" | grep -q 'failing closed\|No such file or directory'; then pass "$2"
    else fail "$2" "rc=$RC err=$ERR"; fi
  else
    if [ "$RC" -eq 0 ] && ! printf '%s' "$ERR" | grep -q 'BLOCKED\|failing closed\|No such file or directory'; then pass "$2"
    else fail "$2" "rc=$RC out=$OUT err=$ERR"; fi
  fi
}
R_READ_OTHERCO=$(real_payload Read '{"file_path":"companies/otherco/settings/README.md"}')
R_BASH_OTHERCO=$(real_payload Bash '{"command":"cat companies/otherco/settings/README.md"}')
R_WRITE_OTHERCO=$(real_payload Write '{"file_path":"companies/otherco/settings/x.md","content":"hi"}')
R_READ_OWN=$(real_payload Read '{"file_path":"companies/indigo/settings/README.md"}')
R_READ_PLAIN=$(real_payload Read '{"file_path":"workspace/output/notes.md"}')
R_BASH_PLAIN=$(real_payload Bash '{"command":"ls workspace/output"}')
R_WRITE_PLAIN=$(real_payload Write '{"file_path":"workspace/output/new.md","content":"hi"}')

REAL_EPERM_REPLY=$(printf '{"id":1,"ok":false,"error":{"code":"internal","message":"EPERM: operation not permitted, open '\''%s/workspace/sessions/s1/meta.yaml'\''"}}' "$REAL_HQ_P")
start_stub "$SOCK" "$REAL_EPERM_REPLY"
real_case block "real authorizer, daemon EPERM: Read of another company's file stays blocked" "$R_READ_OTHERCO"
real_case block "real authorizer, daemon EPERM: Bash cat of another company's file stays blocked" "$R_BASH_OTHERCO"
real_case allow "real authorizer, daemon EPERM: Read of a non-company path is allowed" "$R_READ_PLAIN"
real_case allow "real authorizer, daemon EPERM: Bash ls of a non-company path is allowed" "$R_BASH_PLAIN"
real_case allow "real authorizer, daemon EPERM: Read in the bound company is allowed" "$R_READ_OWN"
stop_stub

start_stub "$SOCK" '{"id":1,"ok":false,"error":{"code":"hq_root_unreadable","message":"hqd cannot read the HQ folder"}}'
real_case block "real authorizer, hq_root_unreadable: Read of another company's file stays blocked" "$R_READ_OTHERCO"
real_case allow "real authorizer, hq_root_unreadable: Read of a non-company path is allowed" "$R_READ_PLAIN"
stop_stub

start_stub "$SOCK" '{"id":1,"ok":false,"error":{"code":"anywhere_disabled","message":"HQ Anywhere is disabled by the hq-anywhere-runtime flag."}}'
real_case block "real authorizer, anywhere_disabled: Write into another company stays blocked" "$R_WRITE_OTHERCO"
real_case allow "real authorizer, anywhere_disabled: Write to a non-company path is allowed" "$R_WRITE_PLAIN"
stop_stub

start_stub "$SOCK" '{"id":1,"ok":true,"result":{"runtime":"claude","sessionId":"s1","cwd":"/tmp/foreign-repo","company":"indigo"}}'
run_shim "$SOCK" "$START" SessionStart
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'bound to company: indigo' && grep -q '"op":"session.open"' "$TMP/req"; then
  pass "SessionStart sends session.open and reports the bound company"
else fail "SessionStart session.open" "rc=$RC out=$OUT req=$(cat "$TMP/req")"; fi
stop_stub

# Events with no hqd operation send nothing. The shim used to send session.get
# on each of them and discard the reply. The stub writes every request line it
# receives to $TMP/req, so a missing file means no request was made.
start_stub "$SOCK" '{"id":1,"ok":true,"result":{"sessions":[]}}'
for _ev in UserPromptSubmit PostToolUse Stop SubagentStop PreCompact Notification; do
  rm -f "$TMP/req"
  _p=$(printf '{"session_id":"s1","hook_event_name":"%s","cwd":"/tmp"}' "$_ev")
  run_shim "$SOCK" "$_p" "$_ev"
  if [ "$RC" -eq 0 ] && [ -z "$OUT$ERR" ] && [ ! -e "$TMP/req" ]; then pass "$_ev: no request to the daemon, no output"
  else fail "$_ev: no request to the daemon, no output" "rc=$RC out=$OUT err=$ERR req=$(cat "$TMP/req" 2>/dev/null)"; fi
  # Codex passes no event argument: the event comes from the payload.
  run_shim "$SOCK" "$_p" --runtime codex
  if [ "$RC" -eq 0 ] && [ -z "$OUT$ERR" ] && [ ! -e "$TMP/req" ]; then pass "$_ev named only in the payload: no request to the daemon"
  else fail "$_ev named only in the payload: no request to the daemon" "rc=$RC out=$OUT err=$ERR req=$(cat "$TMP/req" 2>/dev/null)"; fi
done
stop_stub

# The three events with an operation still send it, with or without the event
# argument, and none of them sends session.get.
start_stub "$SOCK" '{"id":1,"ok":true,"result":{"closed":true}}'
run_shim "$SOCK" '{"session_id":"s1","hook_event_name":"SessionEnd","cwd":"/tmp"}' SessionEnd
if [ "$RC" -eq 0 ] && grep -q '"op":"session.close"' "$TMP/req" && grep -q '"sessionId":"s1"' "$TMP/req"; then
  pass "SessionEnd sends session.close"
else fail "SessionEnd sends session.close" "rc=$RC req=$(cat "$TMP/req" 2>/dev/null)"; fi
rm -f "$TMP/req"
run_shim "$SOCK" '{"session_id":"s1","hook_event_name":"SessionEnd","cwd":"/tmp"}' --runtime codex
if [ "$RC" -eq 0 ] && grep -q '"op":"session.close"' "$TMP/req"; then pass "SessionEnd named only in the payload sends session.close"
else fail "SessionEnd named only in the payload sends session.close" "rc=$RC req=$(cat "$TMP/req" 2>/dev/null)"; fi
stop_stub
start_stub "$SOCK" '{"id":1,"ok":true,"result":{"decision":"allow","reasons":[],"additionalContext":""}}'
run_shim "$SOCK" "$WRITE_OTHER" --runtime codex
if [ "$RC" -eq 0 ] && grep -q '"op":"policy.check"' "$TMP/req"; then pass "PreToolUse named only in the payload sends policy.check"
else fail "PreToolUse named only in the payload sends policy.check" "rc=$RC req=$(cat "$TMP/req" 2>/dev/null)"; fi
stop_stub
start_stub "$SOCK" '{"id":1,"ok":true,"result":{"runtime":"codex","sessionId":"s1","cwd":"/tmp/foreign-repo","company":"acme"}}'
run_shim "$SOCK" "$START" --runtime codex
if [ "$RC" -eq 0 ] && grep -q '"op":"session.open"' "$TMP/req" && printf '%s' "$OUT" | grep -q 'bound to company: acme'; then
  pass "SessionStart named only in the payload sends session.open"
else fail "SessionStart named only in the payload sends session.open" "rc=$RC out=$OUT req=$(cat "$TMP/req" 2>/dev/null)"; fi
stop_stub

# ---------------------------------------------------------------- part 2
CLI=''
GLOBAL_NPM_ROOT=''
if command -v npm >/dev/null 2>&1; then
  GLOBAL_NPM_ROOT="$(npm root -g)" || fail "could not resolve the global npm package root"
fi
for d in "${HQ_CLI_DIR:-}" "$ROOT/../../hq-cli-anywhere" "$REAL_HOME/Documents/HQ/workspace/worktrees/hq-cli-anywhere"; do
  [ -n "$d" ] && [ -f "$d/dist/lib/daemon/server.js" ] && { CLI=$(cd "$d" && pwd); break; }
done
if [ -z "$CLI" ] && [ -n "$GLOBAL_NPM_ROOT" ] \
  && [ -f "$GLOBAL_NPM_ROOT/@indigoai-us/hq-cli/dist/lib/daemon/server.js" ]; then
  CLI="$GLOBAL_NPM_ROOT/@indigoai-us/hq-cli"
fi

if [ -z "$CLI" ] || ! command -v node >/dev/null 2>&1; then
  fail "real hqd test requires a built hq-cli daemon package (set HQ_CLI_DIR or install the pinned @indigoai-us/hq-cli package)"
else
  HQR="$TMP/hqr"
  for co in indigo otherco; do mkdir -p "$HQR/companies/$co/policies"; done
  printf 'companies:\n  indigo: {}\n  otherco: {}\n' >"$HQR/companies/manifest.yaml"
  mkdir -p "$HQR/core/policies" "$HQR/personal/policies" "$HQR/workspace/sessions" "$HQR/.claude/hooks"
  cp "$ROOT/.claude/hooks/mandatory-scope-authorizer.sh" "$ROOT/.claude/hooks/inject-policy-on-trigger.sh" "$HQR/.claude/hooks/"
  cp -R "$ROOT/core/scripts" "$HQR/core/scripts"
  FOREIGN="$TMP/foreign-repo"
  mkdir -p "$FOREIGN"
  HQD_SOCK="$TMP/hqd.sock"

  cat >"$TMP/hqd.mjs" <<'JS'
import * as path from "node:path";
const [cli, sock, root, foreign, home] = process.argv.slice(2);
const { startHqdServer } = await import(path.join(cli, "dist/lib/daemon/server.js"));
const reg = await import(path.join(cli, "dist/lib/registry/registry.js"));
const r = reg.emptyRegistry();
reg.setEntry(r, reg.keyForDir(foreign), "indigo", "link");
reg.writeRegistry(r, path.join(home, "registry.json"));
await startHqdServer({
  socketPath: sock,
  registryPath: path.join(home, "registry.json"),
  hqRoot: root,
  env: { PATH: process.env.PATH, HOME: home, TMPDIR: process.env.TMPDIR ?? "/tmp",
         HQ_WORK_MESH_ROOT: path.join(home, ".hq", "work-mesh"), WORK_MESH_SEQ_DIR: path.join(home, ".hq", "work-mesh", "seq") },
  // Keep the real-daemon probe on the enabled path without consulting live flag state.
  runtimeFlagReader: async () => true,
  personSettingReader: async () => true,
  workMeshRoot: path.join(home, ".hq", "work-mesh"),
});
process.stdout.write("ready\n");
JS
  node "$TMP/hqd.mjs" "$CLI" "$HQD_SOCK" "$HQR" "$FOREIGN" "$HOME" >"$TMP/hqd.log" 2>&1 &
  HQD_PID=$!
  i=0
  while ! grep -q ready "$TMP/hqd.log" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done

  if ! grep -q ready "$TMP/hqd.log"; then
    fail "real hqd started" "$(cat "$TMP/hqd.log")"
  else
    START_F=$(printf '{"session_id":"e2e","hook_event_name":"SessionStart","cwd":"%s","source":"startup"}' "$FOREIGN")
    run_shim "$HQD_SOCK" "$START_F" SessionStart
    if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'bound to company: indigo'; then pass "real hqd: session in /tmp/foreign-repo binds indigo"
    else fail "real hqd: session binds indigo" "rc=$RC out=$OUT err=$ERR"; fi

    W_F=$(printf '{"session_id":"e2e","hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Write","tool_input":{"file_path":"%s/companies/otherco/x.md","content":"hi"}}' "$FOREIGN" "$HQR")
    run_shim "$HQD_SOCK" "$W_F" PreToolUse
    if [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -qi 'cross-company'; then pass "real hqd: Write to companies/otherco blocks with the cross-company message"
    else fail "real hqd: cross-company block" "rc=$RC err=$ERR"; fi

    OK_F=$(printf '{"session_id":"e2e","hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Write","tool_input":{"file_path":"%s/notes.md","content":"hi"}}' "$FOREIGN" "$FOREIGN")
    run_shim "$HQD_SOCK" "$OK_F" PreToolUse
    if [ "$RC" -eq 0 ]; then pass "real hqd: write inside the foreign repo is allowed"
    else fail "real hqd: foreign repo write allowed" "rc=$RC err=$ERR"; fi

    # Median round-trip over 100 hook calls. The calls are SessionStart
    # (session.open): UserPromptSubmit, used here before, no longer contacts
    # the daemon, so timing it would not measure a round-trip.
    : >"$TMP/times"
    n=0
    while [ $n -lt 100 ]; do
      a=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000000')
      printf '%s' "$START_F" | HQ_HQD_SOCKET="$HQD_SOCK" sh "$SHIM" SessionStart >/dev/null 2>"$TMP/err"
      b=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000000')
      echo $(((b - a) / 1000)) >>"$TMP/times"
      n=$((n + 1))
    done
    med=$(sort -n "$TMP/times" | sed -n '50p')
    if [ -s "$TMP/err" ]; then fail "real hqd: round-trip calls were quiet" "$(cat "$TMP/err")"; fi
    if [ "$med" -lt 50 ]; then pass "real hqd: median hook round-trip ${med}ms (<50ms, n=100)"
    else fail "real hqd: median hook round-trip under 50ms" "median=${med}ms"; fi

    kill "$HQD_PID" 2>/dev/null; wait "$HQD_PID" 2>/dev/null; HQD_PID=''
    run_shim "$HQD_SOCK" "$W_F" PreToolUse
    if [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q 'HQ daemon unreachable'; then pass "hqd stopped: same Write blocks and reports unreachable"
    else fail "hqd stopped: Write blocks" "rc=$RC err=$ERR"; fi
  fi
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
