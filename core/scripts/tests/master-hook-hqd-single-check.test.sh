#!/usr/bin/env bash
# hq-core: public
# One scope check per tool call, with the hqd socket on or off.
#
# In the HQ-root Claude project master-hook.sh runs the registry hooks and
# also routes the event to hqd through core/scripts/hqd-hook-shim.sh. For a
# PreToolUse, hqd's policy.check runs mandatory-scope-authorizer.sh and
# inject-policy-on-trigger.sh, the same two scripts the registry runs. With
# the socket on, each ran twice and a blocked command printed two block
# messages. The registry owns the check (it works with the daemon down), so
# master-hook sends no policy.check when its own registry loop will run the
# authorizer for the tool call.
#
# Checked here, against a throwaway HQ root with the real registry, the real
# two scripts and an isolated HOME:
#   1. stub hqd that records every request and answers policy.check with a
#      block: a blocked Bash command and a blocked Read each give one block
#      message, one scope-guard run and no request to hqd; an allowed command
#      stays allowed; the run counts equal those with the socket missing.
#   2. the hqd call is kept whenever the registry will not run the authorizer
#      in this invocation: authorizer opted out, another harness dispatched
#      the registry, authorizer script missing, tool without an authorizer row.
#   3. events with no hqd operation send nothing; SessionStart and SessionEnd
#      still send session.open and session.close.
#   4. real hqd from an hq-cli build (HQ_CLI_DIR, else the global install):
#      a blocked Bash command gives one block message, and a process trace of
#      the event shows mandatory-scope-authorizer once, started by master-hook.
#      With the authorizer opted out, hqd still blocks the command.
# Never touches the real ~/.hq or a running hqd.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
MASTER="${HQ_MASTER_HOOK_TEST_HOOK:-$ROOT/.claude/hooks/master-hook.sh}"

PASS=0
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { PASS=$((PASS + 1)); echo "  ok: $*"; }

[ -f "$MASTER" ] || fail "master-hook.sh not found at $MASTER"
for dep in perl jq tar; do
  command -v "$dep" >/dev/null 2>&1 || fail "$dep required"
done
case "${OSTYPE:-}" in
  # hqd uses a named pipe on Windows; master-hook never routes there.
  msys*|cygwin*|win32*) echo "SKIP: no hqd Unix socket on Windows"; exit 0 ;;
esac

# Unix socket paths are capped near 104 bytes, and hqd refuses a socket path
# with a symlink in it (/tmp is one on macOS): use the physical /tmp path.
TMP="$(cd "$(mktemp -d /tmp/mhsc.XXXXXX)" && pwd -P)"
STUB_PID=""
HQD_PID=""
cleanup() {
  for pid in "$STUB_PID" "$HQD_PID"; do
    [ -z "$pid" ] || { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }
  done
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

SID="single-check-sid"
FIX="$TMP/hq"
HOME_DIR="$TMP/home"
SOCK="$HOME_DIR/.hq/daemon/hqd.sock"
RUN_LOG="$TMP/runs.tsv"
REQ_LOG="$TMP/requests.log"
mkdir -p "$FIX" "$HOME_DIR/.hq/daemon"
chmod 700 "$HOME_DIR" "$HOME_DIR/.hq" "$HOME_DIR/.hq/daemon"

# The fixture root: the real hooks, registry, settings and scripts.
(cd "$ROOT" && tar -cf - --exclude 'core/scripts/tests' \
  .claude/hooks .claude/settings.json core/scripts core/hooks core/core.yaml) | tar -xf - -C "$FIX"
cp "$MASTER" "$FIX/.claude/hooks/master-hook.sh"
mkdir -p "$FIX/companies/acme/policies" "$FIX/companies/otherco/policies" \
  "$FIX/core/policies" "$FIX/personal/policies" "$FIX/workspace/sessions/$SID"
printf 'companies:\n  acme: {}\n  otherco: {}\n' > "$FIX/companies/manifest.yaml"
printf 'other company data\n' > "$FIX/companies/otherco/secret.md"
printf 'own company data\n' > "$FIX/companies/acme/notes.md"
printf 'session_id: %s\nstarted_at: 2026-01-01T00:00:00Z\nsenior: user\ncompany_slug: acme\nsource: test\n' "$SID" \
  > "$FIX/workspace/sessions/$SID/meta.yaml"
# One policy whose trigger word is in the test commands, so the policy
# injector's registry prefilter matches whatever core policies exist.
cat > "$FIX/personal/policies/single-check-probe.md" <<'POLICY'
---
id: single-check-probe
title: Fixture policy for the single-check test
scope: personal
trigger: a command that names singlecheckprobe
when: singlecheckprobe
on: [PreToolUse, PostToolUse]
enforcement: soft
---

## Rule

Fixture rule for the single-check test.
POLICY

# Process trace. One line per run of a traced script: name, pid, and the
# commands of the process and its ancestors, so the line shows who started it.
cat > "$TMP/trace-point.sh" <<'TRACE'
#!/bin/sh
name="$1"; cur="$2"; chain=''; n=0
while [ -n "$cur" ] && [ "$cur" -gt 1 ] 2>/dev/null && [ $n -lt 7 ]; do
  cmd=$(ps -o command= -p "$cur" 2>/dev/null | cut -c1-120)
  chain="$chain${chain:+ <- }$cmd"
  cur=$(ps -o ppid= -p "$cur" 2>/dev/null | tr -d ' ')
  n=$((n + 1))
done
printf '%s\t%s\t%s\n' "$name" "$2" "$chain" >> "$HQ_TEST_RUN_LOG"
TRACE
add_trace_point() { # <script> <name> <pid expression>
  local script="$1" name="$2" pid_expr="$3"
  TRACE_NAME="$name" TRACE_PID="$pid_expr" perl -0pi -e '
    my $line = q{[ -z "${HQ_TEST_RUN_LOG:-}" ] || /bin/sh "${HQ_TEST_TRACE_POINT}" } . $ENV{TRACE_NAME}
      . q{ "} . $ENV{TRACE_PID} . q{" </dev/null >/dev/null 2>&1 || true};
    s{\A(#![^\n]*\n)}{$1$line\n} or die "no shebang in $ARGV\n";' "$script"
}
# bash 3.2 has no BASHPID. There $$ names the shell the subshell was forked
# from, whose ancestors are the same, so the chain still shows who started it.
add_trace_point "$FIX/.claude/hooks/mandatory-scope-authorizer.sh" mandatory-scope-authorizer '${BASHPID:-$$}'
add_trace_point "$FIX/.claude/hooks/inject-policy-on-trigger.sh" inject-policy-on-trigger '${BASHPID:-$$}'
add_trace_point "$FIX/core/scripts/hqd-hook-shim.sh" hqd-hook-shim '$$'

# Stub hqd: appends every request line to $REQ_LOG. policy.check is answered
# with a block, so a policy.check that should not have been sent shows up as a
# second block message (or as a block of an allowed command).
start_stub() {
  rm -f "$SOCK"
  STUB_REQ_LOG="$REQ_LOG" perl -MIO::Socket::UNIX -e '
my $srv = IO::Socket::UNIX->new(Type => IO::Socket::UNIX::SOCK_STREAM(), Local => $ARGV[0], Listen => 16) or die "listen: $!\n";
$| = 1;
while (my $c = $srv->accept) {
  my $line = <$c>;
  next unless defined $line;
  open my $f, ">>", $ENV{STUB_REQ_LOG}; print $f $line; close $f;
  my $reply = q({"id":1,"ok":true,"result":{}});
  $reply = q({"id":1,"ok":true,"result":{"decision":"block","reasons":["hqd stub block"],"additionalContext":""}}) if $line =~ /"op":"policy\.check"/;
  $reply = q({"id":1,"ok":true,"result":{"company":"acme"}}) if $line =~ /"op":"session\.open"/;
  $reply = q({"id":1,"ok":true,"result":{"closed":true}}) if $line =~ /"op":"session\.close"/;
  print $c $reply, "\n"; close $c;
}' "$SOCK" &
  STUB_PID=$!
  for _ in $(seq 1 100); do [ -S "$SOCK" ] && break; sleep 0.05; done
  [ -S "$SOCK" ] || fail "stub hqd socket did not become ready"
}
stop_stub() {
  [ -z "$STUB_PID" ] || { kill "$STUB_PID" 2>/dev/null || true; wait "$STUB_PID" 2>/dev/null || true; }
  STUB_PID=""
  rm -f "$SOCK"
}

payload() { # <event> <tool> <command or path>
  local ev="$1" tool="$2" arg="${3:-}"
  case "$tool" in
    Bash) jq -nc --arg s "$SID" --arg ev "$ev" --arg cwd "$FIX" --arg c "$arg" \
      '{session_id:$s,hook_event_name:$ev,tool_name:"Bash",cwd:$cwd,tool_input:{command:$c,description:"test"},tool_response:{stdout:"",stderr:"",interrupted:false}}' ;;
    Read) jq -nc --arg s "$SID" --arg ev "$ev" --arg cwd "$FIX" --arg p "$arg" \
      '{session_id:$s,hook_event_name:$ev,tool_name:"Read",cwd:$cwd,tool_input:{file_path:$p}}' ;;
    Agent) jq -nc --arg s "$SID" --arg ev "$ev" --arg cwd "$FIX" \
      '{session_id:$s,hook_event_name:$ev,tool_name:"Agent",cwd:$cwd,tool_input:{prompt:"test"}}' ;;
    *) jq -nc --arg s "$SID" --arg ev "$ev" --arg cwd "$FIX" \
      '{session_id:$s,hook_event_name:$ev,cwd:$cwd,prompt:"singlecheckprobe"}' ;;
  esac
}

# run_event <event> <tool> <command or path> [env assignments...]
# Runs the event the way .claude/settings.json registers it. Sets RC; stdout
# and stderr go to $TMP/stdout and $TMP/stderr; the logs start empty.
run_event() {
  local ev="$1" tool="$2" arg="$3"
  shift 3
  : > "$RUN_LOG"
  : > "$REQ_LOG"
  payload "$ev" "$tool" "$arg" > "$TMP/payload.json"
  RC=0
  (cd "$FIX" && env -i PATH="$PATH" HOME="$HOME_DIR" TMPDIR="${TMPDIR:-/tmp}" \
      CLAUDE_PROJECT_DIR="$FIX" HQ_HOOK_ENGINE=off HQ_HOOK_TIMEOUT_SENTRY=0 HQ_WORK_MESH_DISABLED=1 \
      HQ_TEST_RUN_LOG="$RUN_LOG" HQ_TEST_TRACE_POINT="$TMP/trace-point.sh" "$@" \
      env BASH_ENV=/dev/null bash "$FIX/.claude/hooks/master-hook.sh" "$ev" \
      < "$TMP/payload.json" > "$TMP/stdout" 2> "$TMP/stderr") || RC=$?
}
runs() { awk -F'\t' -v n="$1" '$1 == n' "$RUN_LOG" | wc -l | tr -d ' '; }
reqs() { grep -c "\"op\":\"$1\"" "$REQ_LOG" || true; }
req_total() { wc -l < "$REQ_LOG" | tr -d ' '; }
lines() { grep -c "$1" "$TMP/stderr" || true; }
show() { printf 'rc=%s runs=[%s] requests=[%s] stderr=[%s]' "$RC" "$(cut -f1 "$RUN_LOG" | tr '\n' ' ')" \
  "$(tr '\n' ' ' < "$REQ_LOG")" "$(grep -E '^(BLOCKED|Blocked by|Session:|hqd stub)' "$TMP/stderr" | tr '\n' '|')"; }

BLOCKED_CMD='echo singlecheckprobe; cat companies/otherco/secret.md'
ALLOWED_CMD='echo singlecheckprobe; cat companies/acme/notes.md'
BLOCKED_PATH="$FIX/companies/otherco/secret.md"

# assert_one_block <label>: exit 2, one block message from the registry's
# authorizer under the session's own id, one scope-guard run.
assert_one_block() {
  local label="$1"
  [ "$RC" -eq 2 ] || fail "$label: expected a block (exit 2). $(show)"
  [ "$(lines '^BLOCKED: Cross-company scope violation')" = "1" ] || fail "$label: expected one block message. $(show)"
  [ "$(lines '^Blocked by hook ')" = "1" ] || fail "$label: expected one 'Blocked by hook' line. $(show)"
  grep -q '^Blocked by hook mandatory-scope-authorizer\.$' "$TMP/stderr" || fail "$label: the block is not the registry authorizer's. $(show)"
  grep -q "^Session: $SID\$" "$TMP/stderr" || fail "$label: the block is not under the session's own id. $(show)"
  [ "$(runs mandatory-scope-authorizer)" = "1" ] || fail "$label: expected one scope-guard run. $(show)"
}

# ---------------------------------------------------------------- 0. socket missing
run_event PreToolUse Bash "$BLOCKED_CMD"
assert_one_block "socket missing, blocked Bash"
OFF_INJECT_BASH="$(runs inject-policy-on-trigger)"
[ "$OFF_INJECT_BASH" = "1" ] || fail "socket missing: expected one policy-injector run for Bash. $(show)"
[ "$(runs hqd-hook-shim)" = "0" ] || fail "socket missing: the hqd shim was started. $(show)"
pass "socket missing: a blocked Bash command gives one block message, one scope-guard run, one policy-injector run"
run_event PreToolUse Read "$BLOCKED_PATH"
assert_one_block "socket missing, blocked Read"
OFF_INJECT_READ="$(runs inject-policy-on-trigger)"
pass "socket missing: a blocked Read gives one block message and one scope-guard run"

# ---------------------------------------------------------------- 1. stub hqd, socket on
start_stub
run_event PreToolUse Bash "$BLOCKED_CMD"
assert_one_block "socket on, blocked Bash"
[ "$(req_total)" = "0" ] || fail "socket on, blocked Bash: a request went to hqd. $(show)"
[ "$(runs hqd-hook-shim)" = "0" ] || fail "socket on, blocked Bash: the hqd shim was started. $(show)"
[ "$(runs inject-policy-on-trigger)" = "$OFF_INJECT_BASH" ] \
  || fail "socket on, blocked Bash: policy-injector runs differ from the socket-missing count ($OFF_INJECT_BASH). $(show)"
pass "socket on: a blocked Bash command gives one block message, one scope-guard run, one policy-injector run, no hqd request"

run_event PreToolUse Read "$BLOCKED_PATH"
assert_one_block "socket on, blocked Read"
[ "$(req_total)" = "0" ] || fail "socket on, blocked Read: a request went to hqd. $(show)"
[ "$(runs inject-policy-on-trigger)" = "$OFF_INJECT_READ" ] \
  || fail "socket on, blocked Read: policy-injector runs differ from the socket-missing count ($OFF_INJECT_READ). $(show)"
pass "socket on: a blocked Read gives one block message, one scope-guard run, no hqd request"

run_event PreToolUse Bash "$ALLOWED_CMD"
[ "$RC" -eq 0 ] || fail "socket on, allowed Bash: exit $RC. $(show)"
[ "$(runs mandatory-scope-authorizer)" = "1" ] || fail "socket on, allowed Bash: expected one scope-guard run. $(show)"
[ "$(runs inject-policy-on-trigger)" = "1" ] || fail "socket on, allowed Bash: expected one policy-injector run. $(show)"
[ "$(req_total)" = "0" ] || fail "socket on, allowed Bash: a request went to hqd. $(show)"
pass "socket on: an allowed Bash command runs each check once and stays allowed"

# A socket file with no daemon behind it (hqd stopped): still one block.
stop_stub
perl -MIO::Socket::UNIX -e 'IO::Socket::UNIX->new(Type => IO::Socket::UNIX::SOCK_STREAM(), Local => $ARGV[0], Listen => 1) or die "listen: $!\n"' "$SOCK"
[ -S "$SOCK" ] || fail "could not create a stale socket file"
run_event PreToolUse Bash "$BLOCKED_CMD"
assert_one_block "stale socket, blocked Bash"
rm -f "$SOCK"
pass "stale socket (daemon down): a blocked Bash command is still blocked, once"

# ---------------------------------------------------------------- 2. the hqd call is kept
start_stub
run_event PreToolUse Bash "$BLOCKED_CMD" HQ_DISABLED_HOOKS=mandatory-scope-authorizer
[ "$(runs mandatory-scope-authorizer)" = "0" ] || fail "opt-out: the registry still ran the authorizer. $(show)"
[ "$(reqs policy.check)" = "1" ] || fail "opt-out: expected one policy.check to hqd. $(show)"
[ "$RC" -eq 2 ] && grep -q '^hqd stub block$' "$TMP/stderr" || fail "opt-out: hqd's block was lost. $(show)"
[ "$(lines '^Blocked by hook ')" = "1" ] || fail "opt-out: expected one 'Blocked by hook' line. $(show)"
pass "authorizer opted out: hqd is still asked, and its block holds"

run_event PreToolUse Bash "$BLOCKED_CMD" HQ_HARNESS=codex
[ "$(runs mandatory-scope-authorizer)" = "0" ] || fail "HQ_HARNESS=codex: master-hook ran the registry authorizer. $(show)"
[ "$(reqs policy.check)" = "1" ] || fail "HQ_HARNESS=codex: expected one policy.check to hqd. $(show)"
[ "$RC" -eq 2 ] || fail "HQ_HARNESS=codex: hqd's block was lost. $(show)"
pass "registry dispatched by another harness: hqd is still asked"

mv "$FIX/.claude/hooks/mandatory-scope-authorizer.sh" "$FIX/.claude/hooks/mandatory-scope-authorizer.sh.off"
run_event PreToolUse Bash "$BLOCKED_CMD"
mv "$FIX/.claude/hooks/mandatory-scope-authorizer.sh.off" "$FIX/.claude/hooks/mandatory-scope-authorizer.sh"
[ "$(reqs policy.check)" = "1" ] || fail "authorizer script missing: expected one policy.check to hqd. $(show)"
[ "$RC" -eq 2 ] || fail "authorizer script missing: the command was not blocked. $(show)"
pass "authorizer script missing: hqd is still asked"

run_event PreToolUse Agent ""
[ "$(reqs policy.check)" = "1" ] || fail "tool without an authorizer row: expected one policy.check to hqd. $(show)"
[ "$(runs mandatory-scope-authorizer)" = "0" ] || fail "tool without an authorizer row: the registry ran the authorizer. $(show)"
pass "tool with no authorizer row in the registry: hqd is still asked, once"

# ---------------------------------------------------------------- 3. events with no hqd operation
for ev in UserPromptSubmit PostToolUse Stop SubagentStop; do
  run_event "$ev" Bash "$ALLOWED_CMD"
  [ "$(req_total)" = "0" ] || fail "$ev: a request went to hqd. $(show)"
  [ "$(runs hqd-hook-shim)" = "0" ] || fail "$ev: the hqd shim was started. $(show)"
done
pass "UserPromptSubmit, PostToolUse, Stop and SubagentStop send nothing to hqd and start no shim"
run_event SessionStart none ""
[ "$(reqs session.open)" = "1" ] && [ "$(req_total)" = "1" ] || fail "SessionStart: expected exactly one session.open. $(show)"
run_event SessionEnd none ""
[ "$(reqs session.close)" = "1" ] && [ "$(req_total)" = "1" ] || fail "SessionEnd: expected exactly one session.close. $(show)"
pass "SessionStart sends one session.open and SessionEnd one session.close"
stop_stub

# ---------------------------------------------------------------- 4. real hqd
CLI=""
GLOBAL_NPM_ROOT=""
if command -v npm >/dev/null 2>&1; then
  GLOBAL_NPM_ROOT="$(npm root -g 2>/dev/null || true)"
fi
for d in "${HQ_CLI_DIR:-}" "${GLOBAL_NPM_ROOT:+$GLOBAL_NPM_ROOT/@indigoai-us/hq-cli}"; do
  if [ -n "$d" ] && [ -f "$d/dist/lib/daemon/server.js" ]; then CLI="$(cd "$d" && pwd)"; break; fi
done
if [ -z "$CLI" ] || ! command -v node >/dev/null 2>&1; then
  fail "the real-hqd part needs a built hq-cli daemon package (set HQ_CLI_DIR or install the pinned @indigoai-us/hq-cli package)"
fi

cat > "$TMP/hqd.mjs" <<'JS'
import * as path from "node:path";
const [cli, sock, root, home] = process.argv.slice(2);
const { startHqdServer } = await import(path.join(cli, "dist/lib/daemon/server.js"));
const reg = await import(path.join(cli, "dist/lib/registry/registry.js"));
// Link the fixture root to the session's company, so policy.check resolves a
// company from the payload cwd on any hq-cli version.
const r = reg.emptyRegistry();
reg.setEntry(r, reg.keyForDir(root), "acme", "link");
reg.writeRegistry(r, path.join(home, "registry.json"));
await startHqdServer({
  socketPath: sock,
  registryPath: path.join(home, "registry.json"),
  hqRoot: root,
  env: { PATH: process.env.PATH, HOME: home, TMPDIR: process.env.TMPDIR ?? "/tmp",
         HQ_WORK_MESH_ROOT: path.join(home, ".hq", "work-mesh"), WORK_MESH_SEQ_DIR: path.join(home, ".hq", "work-mesh", "seq"),
         HQ_TEST_RUN_LOG: process.env.HQ_TEST_RUN_LOG, HQ_TEST_TRACE_POINT: process.env.HQ_TEST_TRACE_POINT },
  // Keep the daemon on the enabled path without consulting live flag state.
  runtimeFlagReader: async () => true,
  personSettingReader: async () => true,
  workMeshRoot: path.join(home, ".hq", "work-mesh"),
});
process.stdout.write("ready\n");
JS
rm -f "$SOCK"
env -i PATH="$PATH" HOME="$HOME_DIR" TMPDIR="${TMPDIR:-/tmp}" \
  HQ_TEST_RUN_LOG="$RUN_LOG" HQ_TEST_TRACE_POINT="$TMP/trace-point.sh" \
  node "$TMP/hqd.mjs" "$CLI" "$SOCK" "$FIX" "$HOME_DIR" > "$TMP/hqd.log" 2>&1 &
HQD_PID=$!
for _ in $(seq 1 150); do grep -q ready "$TMP/hqd.log" 2>/dev/null && break; sleep 0.1; done
grep -q ready "$TMP/hqd.log" || fail "real hqd did not start: $(cat "$TMP/hqd.log")"

run_event PreToolUse Bash "$BLOCKED_CMD"
assert_one_block "real hqd, blocked Bash"
pass "real hqd: a blocked Bash command returns exactly one block message"
trace_line="$(awk -F'\t' '$1 == "mandatory-scope-authorizer"' "$RUN_LOG")"
case "$trace_line" in
  *master-hook.sh*) ;;
  *) fail "real hqd: the one scope-guard run was not started by master-hook: $trace_line" ;;
esac
case "$trace_line" in
  *hqd.mjs*) fail "real hqd: the scope-guard run was started by the daemon: $trace_line" ;;
esac
[ "$(runs inject-policy-on-trigger)" = "$OFF_INJECT_BASH" ] \
  || fail "real hqd: policy-injector runs differ from the socket-missing count ($OFF_INJECT_BASH). $(show)"
pass "real hqd: the process trace shows mandatory-scope-authorizer once, started by master-hook"

# The guard is not lost when the registry does not run it: hqd runs it, once.
run_event PreToolUse Bash "$BLOCKED_CMD" HQ_DISABLED_HOOKS=mandatory-scope-authorizer
[ "$RC" -eq 2 ] || fail "real hqd, authorizer opted out: the command was not blocked. $(show)"
[ "$(lines '^BLOCKED: Cross-company scope violation')" = "1" ] || fail "real hqd, authorizer opted out: expected one block message. $(show)"
[ "$(lines '^Blocked by hook ')" = "1" ] || fail "real hqd, authorizer opted out: expected one 'Blocked by hook' line. $(show)"
[ "$(runs mandatory-scope-authorizer)" = "1" ] || fail "real hqd, authorizer opted out: expected one scope-guard run. $(show)"
case "$(awk -F'\t' '$1 == "mandatory-scope-authorizer"' "$RUN_LOG")" in
  *hqd.mjs*) ;;
  *) fail "real hqd, authorizer opted out: the scope-guard run was not started by the daemon. $(show)" ;;
esac
pass "real hqd, authorizer opted out: hqd runs the scope guard once and blocks"

kill "$HQD_PID" 2>/dev/null || true
wait "$HQD_PID" 2>/dev/null || true
HQD_PID=""

echo "ALL PASS: master-hook-hqd-single-check ($PASS checks)"
