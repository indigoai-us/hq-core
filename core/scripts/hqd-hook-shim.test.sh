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

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }

TMP=$(mktemp -d /tmp/hqshim.XXXXXX)
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
if [ "$RC" -eq 2 ] && [ "$ERR" = "$UNREACHABLE" ]; then pass "stale hqd socket without marker: company write still fails closed"
else fail "stale hqd socket without marker: company write still fails closed" "rc=$RC err=$ERR"; fi
# The marker alone (daemon says hqd should run, socket gone): fail closed.
mkdir -p "$TMP/hqd-marker"
: >"$TMP/hqd-marker/hqd.enabled"
run_shim "$TMP/hqd-marker/hqd.sock" "$WRITE_OTHERCO" PreToolUse
if [ "$RC" -eq 2 ] && [ "$ERR" = "$UNREACHABLE" ]; then pass "enabled marker without socket: company write fails closed"
else fail "enabled marker without socket: company write fails closed" "rc=$RC err=$ERR"; fi

# Exercise the packaged Claude launcher without an explicit socket override.
# hqd's default socket is under <HOME>/.hq/daemon, matching hqdSocketPath().
LAUNCHER_ROOT="$TMP/plugin"
mkdir -p "$LAUNCHER_ROOT/scripts/hq" "$HOME/.hq/daemon"
cp "$HERE/hq-claude-plugin-launch.sh" "$LAUNCHER_ROOT/scripts/hq-claude-plugin-launch.sh"
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
if [ "$RC" -eq 2 ] && [ "$ERR" = "$UNREACHABLE" ]; then pass "stale enabled cache: first company write still reaches fail-closed shim"
else fail "stale enabled cache: first company write still enforces" "rc=$RC err=$ERR"; fi

run_shim "$NOSOCK" "$WRITE_OTHERCO" PreToolUse
if [ "$RC" -eq 2 ] && [ "$ERR" = "$UNREACHABLE" ]; then pass "absent socket: Write to companies/ blocks with one unreachable line"
else fail "absent socket: Write to companies/ blocks" "rc=$RC err=$ERR"; fi

PRETTY_WRITE='{
  "session_id": "s1",
  "hook_event_name": "PreToolUse",
  "cwd": "/tmp/foreign-repo",
  "tool_name": "Write",
  "tool_input": {"file_path": "companies/otherco/x.md"}
}'
run_shim "$NOSOCK" "$PRETTY_WRITE" PreToolUse
if [ "$RC" -eq 2 ] && [ "$ERR" = "$UNREACHABLE" ]; then pass "multiline JSON payload: company write still blocks"
else fail "multiline JSON payload" "rc=$RC err=$ERR"; fi

run_shim "$NOSOCK" "$WRITE_ABS"
if [ "$RC" -eq 2 ]; then pass "absent socket: absolute companies/ path blocks (event from payload)"
else fail "absent socket: absolute companies/ path blocks" "rc=$RC err=$ERR"; fi

RELATIVE_COMPANY_WRITE='{"session_id":"s1","hook_event_name":"PreToolUse","cwd":"/tmp/HQ/companies/acme","tool_name":"Write","tool_input":{"file_path":"knowledge/file.md"}}'
run_shim "$NOSOCK" "$RELATIVE_COMPANY_WRITE" PreToolUse
if [ "$RC" -eq 2 ] && [ "$ERR" = "$UNREACHABLE" ]; then pass "absent socket: relative file write from a company cwd blocks"
else fail "relative company cwd write blocks" "rc=$RC err=$ERR"; fi

RELATIVE_SHELL_WRITE='{"session_id":"s1","hook_event_name":"PreToolUse","cwd":"/tmp/HQ","tool_name":"Bash","tool_input":{"command":"cd companies && touch acme/file"}}'
run_shim "$NOSOCK" "$RELATIVE_SHELL_WRITE" PreToolUse
if [ "$RC" -eq 2 ] && [ "$ERR" = "$UNREACHABLE" ]; then pass "absent socket: shell writes after cd into a company block"
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
if [ "$RC" -eq 2 ] && [ "$ERR" = "$UNREACHABLE" ] && [ -z "$OUT" ]; then pass "large company-write payload over 128 KiB blocks"
else fail "large company-write payload over 128 KiB blocks" "rc=$RC out=${#OUT} err=$ERR"; fi

run_shim "$NOSOCK" "$BASH_OTHERCO" PreToolUse
if [ "$RC" -eq 2 ]; then pass "absent socket: Bash naming companies/ blocks"
else fail "absent socket: Bash naming companies/ blocks" "rc=$RC"; fi

run_shim "$NOSOCK" "$EXEC_CMD_OTHERCO" PreToolUse
if [ "$RC" -eq 2 ] && [ "$ERR" = "$UNREACHABLE" ]; then pass "absent socket: exec_command cmd writing companies/ blocks"
else fail "absent socket: exec_command cmd writing companies/ blocks" "rc=$RC err=$ERR"; fi

run_shim "$NOSOCK" "$WRITE_OTHER" PreToolUse
if [ "$RC" -eq 0 ] && [ "$ERR" = "$UNREACHABLE" ]; then pass "absent socket: non-company write allowed, still not silent"
else fail "absent socket: non-company write allowed" "rc=$RC err=$ERR"; fi

run_shim "$NOSOCK" "$READ_OTHERCO" PreToolUse
if [ "$RC" -eq 0 ] && [ "$ERR" = "$UNREACHABLE" ]; then pass "absent socket: Read of companies/ allowed with the line"
else fail "absent socket: Read allowed" "rc=$RC err=$ERR"; fi

run_shim "$NOSOCK" "$START" SessionStart
if [ "$RC" -eq 0 ] && [ "$ERR" = "$UNREACHABLE" ] && printf '%s' "$OUT" | grep -q 'bound to company: personal'; then
  pass "absent socket: SessionStart binds personal"
else fail "absent socket: SessionStart binds personal" "rc=$RC out=$OUT err=$ERR"; fi

run_shim "$NOSOCK" "$PROMPT" UserPromptSubmit
if [ "$RC" -eq 0 ] && [ "$ERR" = "$UNREACHABLE" ]; then pass "absent socket: UserPromptSubmit passes with the line"
else fail "absent socket: UserPromptSubmit" "rc=$RC err=$ERR"; fi

SOCK="$TMP/stub.sock"
start_stub "$SOCK" hang
t0=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
run_shim "$SOCK" "$WRITE_OTHERCO" PreToolUse
t1=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
el=$((t1 - t0))
if [ "$RC" -eq 2 ] && [ "$ERR" = "$UNREACHABLE" ] && [ "$el" -lt 1500 ]; then pass "hung daemon: times out (${el}ms) and blocks the company write"
else fail "hung daemon: times out and blocks" "rc=$RC err=$ERR elapsed=${el}ms"; fi
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

start_stub "$SOCK" '{"id":1,"ok":true,"result":{"runtime":"claude","sessionId":"s1","cwd":"/tmp/foreign-repo","company":"indigo"}}'
run_shim "$SOCK" "$START" SessionStart
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'bound to company: indigo' && grep -q '"op":"session.open"' "$TMP/req"; then
  pass "SessionStart sends session.open and reports the bound company"
else fail "SessionStart session.open" "rc=$RC out=$OUT req=$(cat "$TMP/req")"; fi
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

    # Median round-trip over 100 hook calls (SessionStart-style session ops;
    # policy.check time is the scope authorizer's own and is reported too).
    P_F=$(printf '{"session_id":"e2e","hook_event_name":"UserPromptSubmit","cwd":"%s","prompt":"hi"}' "$FOREIGN")
    : >"$TMP/times"
    n=0
    while [ $n -lt 100 ]; do
      a=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000000')
      printf '%s' "$P_F" | HQ_HQD_SOCKET="$HQD_SOCK" sh "$SHIM" UserPromptSubmit >/dev/null 2>"$TMP/err"
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
