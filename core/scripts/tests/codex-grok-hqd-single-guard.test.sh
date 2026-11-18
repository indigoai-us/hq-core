#!/usr/bin/env bash
# hq-core: public
# One policy guard run per tool call under Codex and Grok, with hqd on or off.
#
# The Codex and Grok adapters run the registry gates themselves, the scope
# authorizer (mandatory-scope-authorizer.sh) included, and then run
# master-hook.sh with HQ_HARNESS=codex|grok, which skips the registry. With
# the hqd socket present master-hook then sent policy.check, and hqd ran the
# scope authorizer a second time. An adapter that launched the authorizer for
# this PreToolUse now starts master-hook with HQ_ADAPTER_SCOPE_AUTHORIZER_RAN,
# and master-hook skips the policy.check when the marker names its parent and
# the parent is that adapter.
#
# Guard runs per event = mandatory-scope-authorizer runs + policy.check
# requests to hqd (the real hqd runs the authorizer once per policy.check).
# Checked against a throwaway HQ root with the real hooks, registry, settings
# and adapters, an isolated HOME, and a stub hqd that answers policy.check
# with allow (so the hqd reply never changes a verdict):
#   1. Claude, Codex and Grok each count 1 for an allowed Bash call, daemon on
#      and off, with the same verdict either way.
#   2. A cross-company read under Codex and Grok, daemon on: blocked, 1 run.
#   3. The policy.check is still sent (the guard runs) when the adapter did
#      not run the authorizer: the authorizer opted out, a tool with no
#      authorizer row, the marker set by hand to a made-up pid, the marker
#      naming master-hook's real parent when that parent is not the adapter
#      (with a control under the adapter's file name), an inherited marker,
#      and an authorizer the Codex adapter could not launch under
#      HQ_CODEX_LAUNCH_FAIL_OPEN=1.
# HQ_TEST_SOURCE_ROOT takes the hooks and adapters from another checkout
# (for example origin/main, where Codex and Grok count 2).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SRC="${HQ_TEST_SOURCE_ROOT:-$ROOT}"
MASTER="${HQ_MASTER_HOOK_TEST_HOOK:-$SRC/.claude/hooks/master-hook.sh}"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

[ -f "$MASTER" ] || fail "master-hook.sh not found at $MASTER"
for dep in perl jq tar; do
  command -v "$dep" >/dev/null 2>&1 || fail "$dep required"
done
case "${OSTYPE:-}" in
  # hqd uses a named pipe on Windows; master-hook never routes there.
  msys*|cygwin*|win32*) echo "SKIP: no hqd Unix socket on Windows"; exit 0 ;;
esac

# Unix socket paths are capped near 104 bytes: physical path under /tmp.
TMP="$(cd "$(mktemp -d /tmp/cgsg.XXXXXX)" && pwd -P)"
STUB_PID=""
# Every stub ever started, so the exit trap stops them all and a caller
# piping this test (bash test.sh | tail) is not held open by a stray stub.
ALL_STUB_PIDS=""
cleanup() {
  local pid
  for pid in $ALL_STUB_PIDS; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  [ ! -d "$TMP/hq/.claude/hooks" ] || chmod -R u+rwX "$TMP/hq/.claude/hooks" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

SID="single-guard-sid"
FIX="$TMP/hq"
HOME_DIR="$TMP/home"
SOCK="$HOME_DIR/.hq/daemon/hqd.sock"
RUN_LOG="$TMP/runs.tsv"
REQ_LOG="$TMP/requests.log"
mkdir -p "$FIX" "$HOME_DIR/.hq/daemon"
chmod 700 "$HOME_DIR" "$HOME_DIR/.hq" "$HOME_DIR/.hq/daemon"

(cd "$SRC" && tar -cf - --exclude 'core/scripts/tests' \
  .claude/hooks .claude/settings.json core/scripts core/hooks core/core.yaml \
  .codex/hooks .grok/hooks) | tar -xf - -C "$FIX"
cp "$MASTER" "$FIX/.claude/hooks/master-hook.sh"
mkdir -p "$FIX/companies/acme/policies" "$FIX/companies/otherco/policies" \
  "$FIX/core/policies" "$FIX/personal/policies" "$FIX/workspace/sessions/$SID"
printf 'companies:\n  acme: {}\n  otherco: {}\n' > "$FIX/companies/manifest.yaml"
printf 'other company data\n' > "$FIX/companies/otherco/secret.md"
printf 'own company data\n' > "$FIX/companies/acme/notes.md"
printf 'session_id: %s\nstarted_at: 2026-01-01T00:00:00Z\nsenior: user\ncompany_slug: acme\nsource: test\n' "$SID" \
  > "$FIX/workspace/sessions/$SID/meta.yaml"

# One line per run of the scope authorizer.
cat > "$TMP/trace-point.sh" <<'TRACE'
#!/bin/sh
printf '%s\t%s\n' "$1" "$2" >> "$HQ_TEST_RUN_LOG"
TRACE
TRACE_LINE='[ -z "${HQ_TEST_RUN_LOG:-}" ] || /bin/sh "${HQ_TEST_TRACE_POINT}" mandatory-scope-authorizer "$$" </dev/null >/dev/null 2>&1 || true'
TRACE_LINE="$TRACE_LINE" perl -0pi -e 's{\A(#![^\n]*\n)}{$1$ENV{TRACE_LINE}\n} or die "no shebang\n";' \
  "$FIX/.claude/hooks/mandatory-scope-authorizer.sh"

# Stub hqd: logs every request line; policy.check is answered with allow.
start_stub() {
  stop_stub
  STUB_REQ_LOG="$REQ_LOG" perl -MIO::Socket::UNIX -e '
my $srv = IO::Socket::UNIX->new(Type => IO::Socket::UNIX::SOCK_STREAM(), Local => $ARGV[0], Listen => 16) or die "listen: $!\n";
$| = 1;
while (my $c = $srv->accept) {
  my $line = <$c>;
  next unless defined $line;
  open my $f, ">>", $ENV{STUB_REQ_LOG}; print $f $line; close $f;
  my $reply = q({"id":1,"ok":true,"result":{}});
  $reply = q({"id":1,"ok":true,"result":{"decision":"allow","reasons":[],"additionalContext":""}}) if $line =~ /"op":"policy\.check"/;
  print $c $reply, "\n"; close $c;
}' "$SOCK" &
  STUB_PID=$!
  ALL_STUB_PIDS="$ALL_STUB_PIDS $STUB_PID"
  for _ in $(seq 1 100); do [ -S "$SOCK" ] && break; sleep 0.05; done
  [ -S "$SOCK" ] || fail "stub hqd socket did not become ready"
}
stop_stub() {
  [ -z "$STUB_PID" ] || { kill "$STUB_PID" 2>/dev/null || true; wait "$STUB_PID" 2>/dev/null || true; }
  STUB_PID=""
  rm -f "$SOCK"
}

payload() { # <tool> <command, path or url>
  local tool="$1" arg="$2"
  case "$tool" in
    Bash) jq -nc --arg s "$SID" --arg cwd "$FIX" --arg c "$arg" \
      '{session_id:$s,hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$cwd,tool_input:{command:$c,description:"test"}}' ;;
    *) jq -nc --arg s "$SID" --arg cwd "$FIX" --arg t "$tool" --arg u "$arg" \
      '{session_id:$s,hook_event_name:"PreToolUse",tool_name:$t,cwd:$cwd,tool_input:{url:$u,prompt:"test"}}' ;;
  esac
}

# run_event <runtime> <tool> <arg> [env...]
# runtime: claude|codex|grok|master-codex|master-grok|wrapper:<script>.
# claude runs master-hook as .claude/settings.json does; codex and grok run
# the adapter the way their harness does; master-codex and master-grok run
# master-hook directly with HQ_HARNESS set (no adapter parent); wrapper:<script>
# runs /bin/bash <script>, which starts master-hook as its child.
run_event() {
  local runtime="$1" tool="$2" arg="$3" launch=()
  shift 3
  : > "$RUN_LOG"
  : > "$REQ_LOG"
  payload "$tool" "$arg" > "$TMP/payload.json"
  case "$runtime" in
    claude) launch=(bash "$FIX/.claude/hooks/master-hook.sh" PreToolUse) ;;
    codex) launch=(/bin/bash "$FIX/.codex/hooks/hq-codex-hook-adapter.sh") ;;
    grok) launch=(/bin/bash "$FIX/.grok/hooks/hq-grok-hook-adapter.sh") ;;
    master-codex) launch=(env HQ_HARNESS=codex bash "$FIX/.claude/hooks/master-hook.sh" PreToolUse) ;;
    master-grok) launch=(env HQ_HARNESS=grok bash "$FIX/.claude/hooks/master-hook.sh" PreToolUse) ;;
    wrapper:*) launch=(/bin/bash "${runtime#wrapper:}") ;;
    *) fail "unknown runtime $runtime" ;;
  esac
  RC=0
  (cd "$FIX" && env -i PATH="$PATH" HOME="$HOME_DIR" TMPDIR="${TMPDIR:-/tmp}" \
      CLAUDE_PROJECT_DIR="$FIX" HQ_HOOK_ENGINE=off HQ_HOOK_TIMEOUT_SENTRY=0 HQ_WORK_MESH_DISABLED=1 \
      HQ_TEST_RUN_LOG="$RUN_LOG" HQ_TEST_TRACE_POINT="$TMP/trace-point.sh" "$@" \
      env BASH_ENV=/dev/null "${launch[@]}" \
      < "$TMP/payload.json" > "$TMP/stdout" 2> "$TMP/stderr") || RC=$?
}
scope_runs() { awk -F'\t' '$1 == "mandatory-scope-authorizer"' "$RUN_LOG" | wc -l | tr -d ' '; }
checks() { grep -c '"op":"policy\.check"' "$REQ_LOG" || true; }
guard_runs() { echo $(( $(scope_runs) + $(checks) )); }
# Verdict: exit status plus whether any output denies the call.
verdict() {
  local denied=allow
  if grep -q 'Cross-company scope violation' "$TMP/stderr" "$TMP/stdout" 2>/dev/null \
    || grep -Eq '"(permissionDecision|decision)" *: *"(deny|block)"' "$TMP/stdout" 2>/dev/null; then
    denied=deny
  fi
  printf 'rc=%s %s' "$RC" "$denied"
}
show() { printf '%s scope_runs=%s policy_checks=%s stderr=[%s]' "$(verdict)" "$(scope_runs)" "$(checks)" \
  "$(grep -E '^(BLOCKED|Blocked by|ERROR)' "$TMP/stderr" | tr '\n' '|')"; }

ALLOWED_CMD='cat companies/acme/notes.md'
BLOCKED_CMD='cat companies/otherco/secret.md'

# ------------------------------------------- 1. allowed Bash, daemon off and on
# Every runtime is counted before the section fails, so one run shows all
# three counts.
SECTION_FAIL=""
for runtime in claude codex grok; do
  stop_stub
  run_event "$runtime" Bash "$ALLOWED_CMD"
  off_verdict="$(verdict)"
  off_runs="$(guard_runs)"
  if [ "$off_runs" = "1" ]; then
    pass "$runtime daemon-off guard runs=$off_runs ($off_verdict)"
  else
    echo "  not ok: $runtime daemon-off guard runs=$off_runs, want 1. $(show)" >&2
    SECTION_FAIL="$SECTION_FAIL $runtime-off"
  fi

  start_stub
  run_event "$runtime" Bash "$ALLOWED_CMD"
  on_verdict="$(verdict)"
  on_runs="$(guard_runs)"
  [ "$on_verdict" = "$off_verdict" ] || fail "$runtime: verdict with the daemon on ($on_verdict) differs from off ($off_verdict)"
  [ "$on_verdict" = "rc=0 allow" ] || fail "$runtime: an allowed command was not allowed. $(show)"
  if [ "$on_runs" = "1" ]; then
    pass "$runtime daemon-on guard runs=$on_runs ($on_verdict)"
  else
    echo "  not ok: $runtime daemon-on guard runs=$on_runs, want 1. $(show)" >&2
    SECTION_FAIL="$SECTION_FAIL $runtime-on"
  fi
done
[ -z "$SECTION_FAIL" ] || fail "guard ran more or less than once per event:$SECTION_FAIL"

# ------------------------------------------- 2. blocked read, daemon on
# start_stub stops the stub the last loop iteration left running first.
start_stub
for runtime in codex grok; do
  run_event "$runtime" Bash "$BLOCKED_CMD"
  case "$(verdict)" in
    *deny) ;;
    *) fail "$runtime daemon on: a cross-company read was not blocked. $(show)" ;;
  esac
  [ "$(guard_runs)" = "1" ] || fail "$runtime daemon on, blocked read: guard runs=$(guard_runs), want 1. $(show)"
  pass "$runtime daemon-on blocked read: $(verdict), guard runs=$(guard_runs)"
done

# ------------------------------------------- 3. the guard still runs
# 3a. Authorizer opted out: the adapter does not run it, so hqd is asked.
for runtime in codex grok; do
  run_event "$runtime" Bash "$ALLOWED_CMD" HQ_DISABLED_HOOKS=mandatory-scope-authorizer
  [ "$(scope_runs)" = "0" ] || fail "$runtime opted out: the authorizer ran. $(show)"
  [ "$(checks)" = "1" ] || fail "$runtime opted out: no policy.check was sent. $(show)"
  pass "$runtime authorizer opted out: scope runs=0, policy.check=1"
done

# 3b. A tool with no authorizer row: the policy.check is sent as before. The
# Grok adapter dispatches no PreToolUse hooks (master-hook included) for tools
# outside Bash, Read, Write, Edit, Grep and Glob, on main as here, so Grok
# sends none for WebFetch.
for runtime in claude codex grok; do
  want=1
  [ "$runtime" != "grok" ] || want=0
  run_event "$runtime" WebFetch "https://example.com/"
  [ "$(scope_runs)" = "0" ] || fail "$runtime WebFetch: the authorizer ran. $(show)"
  [ "$(checks)" = "$want" ] || fail "$runtime WebFetch: policy.check count $(checks), want $want. $(show)"
  pass "$runtime WebFetch (no authorizer row): scope runs=0, policy.check=$want"
done

# 3c. Marker set by hand to a made-up pid, no adapter parent and no registry
# run: the call stays.
for runtime in master-codex master-grok; do
  run_event "$runtime" Bash "$ALLOWED_CMD" HQ_ADAPTER_SCOPE_AUTHORIZER_RAN="PreToolUse:4242"
  [ "$(scope_runs)" = "0" ] || fail "$runtime: the authorizer ran with HQ_HARNESS set. $(show)"
  [ "$(checks)" = "1" ] || fail "$runtime hand-set marker: policy.check count $(checks), want 1. $(show)"
  pass "$runtime hand-set marker naming a made-up pid: policy.check=1"
done

# 3d. Marker naming master-hook's real parent, where that parent is not the
# adapter. A wrapper script starts master-hook as its child and sets the
# marker to its own pid, so the marker matches PPID and only the
# parent-is-the-adapter check (master_parent_is_harness_adapter) keeps the
# call. The control runs the same wrapper under the adapter's file name: the
# parent check passes and no call is sent, which shows the marker matched in
# the first run. The check trusts the parent's command line only, so this
# control passing is expected behaviour, not a bypass.
for harness in codex grok; do
  adapter_name="hq-$harness-hook-adapter.sh"
  mkdir -p "$TMP/wrap-$harness/not-adapter" "$TMP/wrap-$harness/named-adapter"
  for wrapper in "$TMP/wrap-$harness/not-adapter/not-the-adapter.sh" \
    "$TMP/wrap-$harness/named-adapter/$adapter_name"; do
    printf '#!/bin/bash\nHQ_ADAPTER_SCOPE_AUTHORIZER_RAN="PreToolUse:$$" bash %q PreToolUse\n' \
      "$FIX/.claude/hooks/master-hook.sh" > "$wrapper"
  done
  run_event "wrapper:$TMP/wrap-$harness/not-adapter/not-the-adapter.sh" Bash "$ALLOWED_CMD" HQ_HARNESS="$harness"
  [ "$(scope_runs)" = "0" ] || fail "$harness non-adapter wrapper: the authorizer ran. $(show)"
  [ "$(checks)" = "1" ] || fail "$harness marker naming a non-adapter parent: policy.check count $(checks), want 1. $(show)"
  pass "$harness marker naming a non-adapter parent: policy.check=1"
  run_event "wrapper:$TMP/wrap-$harness/named-adapter/$adapter_name" Bash "$ALLOWED_CMD" HQ_HARNESS="$harness"
  [ "$(checks)" = "0" ] || fail "$harness control, wrapper named $adapter_name: policy.check count $(checks), want 0. $(show)"
  pass "$harness control, marker naming a parent named $adapter_name: policy.check=0"
done

# 3e. Marker inherited by the adapter from its own environment does not
# survive into a run where the authorizer is opted out.
for runtime in codex grok; do
  run_event "$runtime" Bash "$ALLOWED_CMD" HQ_DISABLED_HOOKS=mandatory-scope-authorizer \
    HQ_ADAPTER_SCOPE_AUTHORIZER_RAN="PreToolUse:4242"
  [ "$(checks)" = "1" ] || fail "$runtime inherited marker, authorizer opted out: policy.check count $(checks), want 1. $(show)"
  pass "$runtime inherited marker with the authorizer opted out: policy.check=1"
done

# 3f. The authorizer cannot be launched and HQ_CODEX_LAUNCH_FAIL_OPEN=1 lets
# the Codex adapter pass the launch failure. The authorizer never ran, so it
# did not exit 0, and no marker may be set. Today run_hook exits the adapter
# with the launch status (126) as soon as the authorizer fails to launch, so
# master-hook never starts and hqd gets no request at all: the fail-open
# switch passes the call before master-hook, on main as here. If the adapter
# ever carries on to master-hook after a launch failure, master-hook must
# send the policy.check (the HQAD_CHILD_RC = 0 check is what stops the
# marker). Grok has no fail-open switch.
AUTHZ="$FIX/.claude/hooks/mandatory-scope-authorizer.sh"
chmod 000 "$AUTHZ"
run_event codex Bash "$ALLOWED_CMD" HQ_CODEX_LAUNCH_FAIL_OPEN=1
chmod 755 "$AUTHZ"
[ "$(scope_runs)" = "0" ] || fail "codex fail-open: the unlaunchable authorizer ran. $(show)"
if [ "$(checks)" = "1" ]; then
  pass "codex authorizer not launched, HQ_CODEX_LAUNCH_FAIL_OPEN=1: scope runs=0, policy.check=1"
elif [ "$RC" = "126" ] && [ ! -s "$REQ_LOG" ]; then
  pass "codex authorizer not launched, HQ_CODEX_LAUNCH_FAIL_OPEN=1: adapter exited 126 before master-hook, no marker, no hqd request"
else
  fail "codex fail-open, authorizer not launched: master-hook ran and sent policy.check $(checks) times, want 1. $(show)"
fi
stop_stub

echo "ALL PASS: codex-grok-hqd-single-guard"
