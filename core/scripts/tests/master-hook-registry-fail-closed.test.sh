#!/usr/bin/env bash
# hq-core: public
# master-hook.sh refuses a guarded tool call when it cannot run the permission
# checks: the scope authorizer's script is missing, or the hook registry
# cannot be read or parsed. With no registry file the scope authorizer runs on
# its own. Context and logging rows keep their behaviour.
#
# Every case reads another company's file from a session bound to one company,
# so a call that gets through is a cross-company read. Each case runs with the
# daemon down (socket missing, and a stale socket file with no daemon) and
# with it up (a stub hqd that allows every policy.check, so only master-hook
# can refuse; then a real hqd when an hq-cli build is found, as in
# master-hook-hqd-single-check.test.sh).
#
#   1. scope authorizer script removed: Bash and Read are refused with one
#      BLOCKED line naming mandatory-scope-authorizer.
#   2. registry that cannot be read or parsed (truncated, empty, not an
#      object, no hooks object, trailing text, mode 000, and a directory,
#      FIFO, symlink to /dev/zero or /dev/null or dangling symlink at its
#      path): every guarded tool is refused with one BLOCKED line naming
#      .claude/hooks/hook-registry.json; also with HQ_HOOK_PARALLEL=1.
#   3. no registry file: the scope authorizer runs on its own, allows an
#      own-company call and refuses a cross-company one; with its script
#      missing too the call is refused.
#   4. a registry repaired with an older mtime is used at once (the
#      unreadable verdict is not cached).
#   5. unchanged: tools the scope authorizer does not guard, and events other
#      than PreToolUse, are not refused by a broken registry; a missing
#      context or logging row's script is skipped; once the registry is
#      repaired the scope authorizer decides again.
# Never touches the real ~/.hq or a running hqd.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
MASTER="${HQ_MASTER_HOOK_TEST_HOOK:-$ROOT/.claude/hooks/master-hook.sh}"

PASS=0
FAILS=0
# HQ_TEST_KEEP_GOING=1 reports every failing case instead of stopping at the
# first one; the run still exits 1.
fail() {
  echo "FAIL: $*" >&2
  FAILS=$((FAILS + 1))
  [ "${HQ_TEST_KEEP_GOING:-0}" = "1" ] || exit 1
}
FAILS_SEEN=0
pass() { # prints "not ok" when a check of this group failed (keep-going mode)
  if [ "$FAILS" -eq "$FAILS_SEEN" ]; then
    PASS=$((PASS + 1)); echo "  ok: $*"
  else
    echo "  not ok: $*"
  fi
  FAILS_SEEN="$FAILS"
}

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
TMP="$(cd "$(mktemp -d /tmp/mhrfc.XXXXXX)" && pwd -P)"
STUB_PID=""
HQD_PID=""
cleanup() {
  for pid in "$STUB_PID" "$HQD_PID"; do
    [ -z "$pid" ] || { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }
  done
  # A hook's detached writer can still create a state directory in the fixture
  # just after the last event; retry briefly so the directory goes.
  local _
  for _ in 1 2 3 4 5; do
    rm -rf "$TMP" 2>/dev/null && return 0
    sleep 0.2
  done
  rm -rf "$TMP" || true
}
trap cleanup EXIT INT TERM

SID="registry-fail-closed-sid"
FIX="$TMP/hq"
HOME_DIR="$TMP/home"
SOCK="$HOME_DIR/.hq/daemon/hqd.sock"
REQ_LOG="$TMP/requests.log"
HOOKS="$FIX/.claude/hooks"
REG="$HOOKS/hook-registry.json"
mkdir -p "$FIX" "$HOME_DIR/.hq/daemon"
chmod 700 "$HOME_DIR" "$HOME_DIR/.hq" "$HOME_DIR/.hq/daemon"

# The fixture root: the real hooks, registry, settings and scripts.
(cd "$ROOT" && tar -cf - --exclude 'core/scripts/tests' \
  .claude/hooks .claude/settings.json core/scripts core/hooks core/core.yaml) | tar -xf - -C "$FIX"
cp "$MASTER" "$HOOKS/master-hook.sh"
cp "$REG" "$TMP/registry.good.json"
mkdir -p "$FIX/companies/acme/policies" "$FIX/companies/acme/settings" "$FIX/companies/otherco/policies" \
  "$FIX/core/policies" "$FIX/personal/policies" "$FIX/workspace/sessions/$SID"
printf 'companies:\n  acme: {}\n  otherco: {}\n' > "$FIX/companies/manifest.yaml"
printf 'other company data\n' > "$FIX/companies/otherco/secret.md"
printf 'own company data\n' > "$FIX/companies/acme/notes.md"
printf 'own company settings\n' > "$FIX/companies/acme/settings/notes.md"
printf 'session_id: %s\nstarted_at: 2026-01-01T00:00:00Z\nsenior: user\ncompany_slug: acme\nsource: test\n' "$SID" \
  > "$FIX/workspace/sessions/$SID/meta.yaml"
# One policy whose trigger word is in a test command, so the policy injector's
# registry prefilter passes and the row reaches the missing-script check.
cat > "$FIX/personal/policies/registry-fail-closed-probe.md" <<'POLICY'
---
id: registry-fail-closed-probe
title: Fixture policy for the registry fail-closed test
scope: personal
trigger: a command that names regfailprobe
when: regfailprobe
on: [PreToolUse, PostToolUse]
enforcement: soft
---

## Rule

Fixture rule for the registry fail-closed test.
POLICY

# Stub hqd: records every request and allows every policy.check, so a refusal
# with the stub up comes from master-hook alone.
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
  $reply = q({"id":1,"ok":true,"result":{"decision":"allow","reasons":[],"additionalContext":""}}) if $line =~ /"op":"policy\.check"/;
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
# A socket file with no daemon behind it (hqd stopped without cleanup).
make_stale_socket() {
  rm -f "$SOCK"
  perl -MIO::Socket::UNIX -e 'IO::Socket::UNIX->new(Type => IO::Socket::UNIX::SOCK_STREAM(), Local => $ARGV[0], Listen => 1) or die "listen: $!\n"' "$SOCK"
  [ -S "$SOCK" ] || fail "could not create a stale socket file"
}

payload() { # <event> <tool> <command or path>
  local ev="$1" tool="$2" arg="${3:-}"
  case "$tool" in
    Bash) jq -nc --arg s "$SID" --arg ev "$ev" --arg cwd "$FIX" --arg c "$arg" \
      '{session_id:$s,hook_event_name:$ev,tool_name:"Bash",cwd:$cwd,tool_input:{command:$c,description:"test"},tool_response:{stdout:"",stderr:"",interrupted:false}}' ;;
    Read) jq -nc --arg s "$SID" --arg ev "$ev" --arg cwd "$FIX" --arg p "$arg" \
      '{session_id:$s,hook_event_name:$ev,tool_name:"Read",cwd:$cwd,tool_input:{file_path:$p}}' ;;
    Write) jq -nc --arg s "$SID" --arg ev "$ev" --arg cwd "$FIX" --arg p "$arg" \
      '{session_id:$s,hook_event_name:$ev,tool_name:"Write",cwd:$cwd,tool_input:{file_path:$p,content:"x"}}' ;;
    Edit) jq -nc --arg s "$SID" --arg ev "$ev" --arg cwd "$FIX" --arg p "$arg" \
      '{session_id:$s,hook_event_name:$ev,tool_name:"Edit",cwd:$cwd,tool_input:{file_path:$p,old_string:"a",new_string:"b"}}' ;;
    MultiEdit) jq -nc --arg s "$SID" --arg ev "$ev" --arg cwd "$FIX" --arg p "$arg" \
      '{session_id:$s,hook_event_name:$ev,tool_name:"MultiEdit",cwd:$cwd,tool_input:{file_path:$p,edits:[{old_string:"a",new_string:"b"}]}}' ;;
    NotebookEdit) jq -nc --arg s "$SID" --arg ev "$ev" --arg cwd "$FIX" --arg p "$arg" \
      '{session_id:$s,hook_event_name:$ev,tool_name:"NotebookEdit",cwd:$cwd,tool_input:{notebook_path:$p,new_source:"x"}}' ;;
    Grep|Glob) jq -nc --arg s "$SID" --arg ev "$ev" --arg cwd "$FIX" --arg p "$arg" --arg t "$tool" \
      '{session_id:$s,hook_event_name:$ev,tool_name:$t,cwd:$cwd,tool_input:{pattern:"data",path:$p}}' ;;
    Agent) jq -nc --arg s "$SID" --arg ev "$ev" --arg cwd "$FIX" --arg p "$arg" \
      '{session_id:$s,hook_event_name:$ev,tool_name:"Agent",cwd:$cwd,tool_input:{prompt:$p}}' ;;
    *) jq -nc --arg s "$SID" --arg ev "$ev" --arg cwd "$FIX" --arg p "$arg" \
      '{session_id:$s,hook_event_name:$ev,cwd:$cwd,prompt:$p}' ;;
  esac
}

# run_event <event> <tool> <command or path> [env assignments...]
# Runs the event the way .claude/settings.json registers it, bounded at 120 s.
# Sets RC; stdout and stderr go to $TMP/stdout and $TMP/stderr.
run_event() {
  local ev="$1" tool="$2" arg="$3"
  shift 3
  : > "$REQ_LOG"
  payload "$ev" "$tool" "$arg" > "$TMP/payload.json"
  RC=0
  (cd "$FIX" && env -i PATH="$PATH" HOME="$HOME_DIR" TMPDIR="${TMPDIR:-/tmp}" \
      CLAUDE_PROJECT_DIR="$FIX" HQ_HOOK_ENGINE=off HQ_HOOK_TIMEOUT_SENTRY=0 HQ_WORK_MESH_DISABLED=1 "$@" \
      perl -e 'alarm shift; exec @ARGV or exit 127' 120 \
      env BASH_ENV=/dev/null bash "$HOOKS/master-hook.sh" "$ev" \
      < "$TMP/payload.json" > "$TMP/stdout" 2> "$TMP/stderr") || RC=$?
}
lines() { grep -c -- "$1" "$TMP/stderr" || true; }
reqs() { grep -c "\"op\":\"$1\"" "$REQ_LOG" || true; }
show() { printf 'rc=%s stderr=[%s]' "$RC" "$(grep -E '^(BLOCKED|Blocked by|HQ |master-hook)' "$TMP/stderr" | tr '\n' '|')"; }

BLOCKED_CMD='cat companies/otherco/secret.md'
ALLOWED_CMD='cat companies/acme/notes.md'
BLOCKED_PATH="$FIX/companies/otherco/secret.md"
SCOPE_MISSING_LINE='^BLOCKED: a required HQ safety check is missing (mandatory-scope-authorizer)\. '
REG_UNPARSABLE_LINE='^BLOCKED: the HQ hook registry \.claude/hooks/hook-registry\.json cannot be read or parsed, so the guards cannot run; failing closed\. From a terminal outside this session run git -C '

# expect_refused <label> <line regex> [strict]: exit 2 and exactly one stderr
# line matching the regex. With strict, no other BLOCKED line either (the
# daemon is down or allows everything, so nothing else may refuse).
expect_refused() {
  local label="$1" re="$2" strict="${3:-}"
  [ "$RC" -eq 2 ] || fail "$label: expected the call to be refused (exit 2). $(show)"
  [ "$(lines "$re")" = "1" ] || fail "$label: expected one stderr line matching $re. $(show)"
  if [ -n "$strict" ]; then
    [ "$(lines '^BLOCKED')" = "1" ] || fail "$label: expected exactly one BLOCKED line. $(show)"
  fi
}
expect_allowed() { # <label>
  [ "$RC" -eq 0 ] || fail "$1: expected exit 0. $(show)"
  [ "$(lines '^BLOCKED')" = "0" ] || fail "$1: unexpected BLOCKED line. $(show)"
}

remove_authorizer() { mv "$HOOKS/mandatory-scope-authorizer.sh" "$TMP/authorizer.off"; }
restore_authorizer() { mv "$TMP/authorizer.off" "$HOOKS/mandatory-scope-authorizer.sh"; }
# A fresh copy gets a new mtime, so master-hook's row cache is re-read. rm -rf
# also takes a directory, a FIFO or a symlink left at the registry path.
restore_registry() { rm -rf "$REG"; cp "$TMP/registry.good.json" "$REG"; }
# <tool>: a cross-company target for each guarded tool.
blocked_arg() {
  case "$1" in
    Bash) printf '%s' "$BLOCKED_CMD" ;;
    Grep|Glob) printf '%s' "$FIX/companies/otherco" ;;
    NotebookEdit) printf '%s' "$FIX/companies/otherco/book.ipynb" ;;
    *) printf '%s' "$BLOCKED_PATH" ;;
  esac
}
GUARDED_TOOLS="Bash Read Write Edit MultiEdit NotebookEdit Grep Glob"

# The story cases, for one daemon state. <state> [strict]
check_both_cases() {
  local state="$1" strict="${2:-}" tool
  remove_authorizer
  run_event PreToolUse Bash "$BLOCKED_CMD"
  expect_refused "$state, scope authorizer missing, Bash" "$SCOPE_MISSING_LINE" "$strict"
  run_event PreToolUse Read "$BLOCKED_PATH"
  expect_refused "$state, scope authorizer missing, Read" "$SCOPE_MISSING_LINE" "$strict"
  restore_authorizer
  pass "$state: with the scope authorizer missing, a cross-company Bash and Read are refused with one line naming it"

  printf '{"hooks": {"PreToolUse": [' > "$REG"
  for tool in $GUARDED_TOOLS; do
    run_event PreToolUse "$tool" "$(blocked_arg "$tool")"
    expect_refused "$state, registry unparsable, $tool" "$REG_UNPARSABLE_LINE" "$strict"
  done
  restore_registry
  pass "$state: with an unparsable registry, a cross-company call by each guarded tool is refused with one line naming the registry"

  rm -rf "$REG"; mkdir "$REG"
  run_event PreToolUse Bash "$BLOCKED_CMD"
  expect_refused "$state, registry is a directory, Bash" "$REG_UNPARSABLE_LINE" "$strict"
  restore_registry
  pass "$state: with a directory at the registry path, a cross-company Bash is refused with one line naming the registry"

  # No registry: the scope authorizer runs on its own and decides.
  rm -f "$REG"
  run_event PreToolUse Bash "$ALLOWED_CMD"
  [ "$RC" -eq 0 ] && [ "$(lines '^BLOCKED')" = "0" ] \
    || fail "$state, registry missing: the authorizer did not allow an own-company Bash. $(show)"
  run_event PreToolUse Bash "$BLOCKED_CMD"
  [ "$RC" -eq 2 ] && [ "$(lines '^BLOCKED: Cross-company scope violation')" -ge 1 ] \
    || fail "$state, registry missing: the authorizer did not refuse a cross-company Bash. $(show)"
  run_event PreToolUse Read "$BLOCKED_PATH"
  [ "$RC" -eq 2 ] && [ "$(lines '^BLOCKED: Cross-company scope violation')" -ge 1 ] \
    || fail "$state, registry missing: the authorizer did not refuse a cross-company Read. $(show)"
  remove_authorizer
  run_event PreToolUse Bash "$BLOCKED_CMD"
  expect_refused "$state, registry and scope authorizer missing, Bash" "$SCOPE_MISSING_LINE" "$strict"
  restore_authorizer
  restore_registry
  pass "$state: with no registry the scope authorizer decides (own company allowed, other company refused), and its absence too refuses"
}

# ---------------------------------------------------------------- 0. baseline
run_event PreToolUse Bash "$BLOCKED_CMD"
[ "$RC" -eq 2 ] && [ "$(lines '^BLOCKED: Cross-company scope violation')" = "1" ] \
  || fail "baseline: the scope authorizer did not refuse the cross-company read. $(show)"
run_event PreToolUse Bash "$ALLOWED_CMD"
expect_allowed "baseline, own-company Bash"
pass "baseline: the intact fixture refuses the cross-company read and allows the own-company read"

# ---------------------------------------------------------------- 1. daemon down
check_both_cases "daemon down (no socket)" strict
make_stale_socket
check_both_cases "daemon down (stale socket)" strict
rm -f "$SOCK"

# Every unparsable form, daemon down.
bad_forms=(
  ''
  '{"hooks": {'
  '[]'
  '"hooks"'
  '{"description": "no hooks key"}'
  '{"hooks": []}'
  '{"hooks": {"PreToolUse": [{"matcher": "", "hooks": "not a list"}]}}'
  '{"hooks": {}} trailing text'
)
for form in "${bad_forms[@]}"; do
  printf '%s' "$form" > "$REG"
  run_event PreToolUse Bash "$BLOCKED_CMD"
  expect_refused "daemon down, registry [$form]" "$REG_UNPARSABLE_LINE" strict
done
restore_registry
cp "$TMP/registry.good.json" "$REG"; chmod 000 "$REG"
run_event PreToolUse Bash "$BLOCKED_CMD"
chmod 600 "$REG"
expect_refused "daemon down, registry unreadable (mode 000)" "$REG_UNPARSABLE_LINE" strict
restore_registry
pass "daemon down: each unparsable registry form (${#bad_forms[@]}) and an unreadable one refuse a cross-company Bash"

# A registry path that exists but is not a regular file is refused without
# running jq (a FIFO with no writer would otherwise hang), sequential and
# parallel. <label> then the setup runs in non_regular_registry.
non_regular_registry() { # <form>
  rm -rf "$REG"
  case "$1" in
    directory) mkdir "$REG" ;;
    fifo) mkfifo "$REG" ;;
    dev-zero) ln -s /dev/zero "$REG" ;;
    dev-null) ln -s /dev/null "$REG" ;;
    dangling) ln -s "$TMP/no-such-registry.json" "$REG" ;;
  esac
}
for form in directory fifo dev-zero dev-null dangling; do
  for par in 0 1; do
    non_regular_registry "$form"
    run_event PreToolUse Bash "$BLOCKED_CMD" HQ_HOOK_PARALLEL="$par"
    expect_refused "daemon down, registry $form, HQ_HOOK_PARALLEL=$par" "$REG_UNPARSABLE_LINE" strict
  done
done
restore_registry
pass "daemon down: a directory, a FIFO, a symlink to /dev/zero or /dev/null, and a dangling symlink at the registry path are refused, sequential and parallel"

# Parallel dispatch reaches the same verdicts.
printf '{"hooks": {' > "$REG"
run_event PreToolUse Bash "$BLOCKED_CMD" HQ_HOOK_PARALLEL=1
expect_refused "HQ_HOOK_PARALLEL=1, registry unparsable, Bash" "$REG_UNPARSABLE_LINE" strict
run_event PreToolUse Read "$BLOCKED_PATH" HQ_HOOK_PARALLEL=1
expect_refused "HQ_HOOK_PARALLEL=1, registry unparsable, Read" "$REG_UNPARSABLE_LINE" strict
restore_registry
remove_authorizer
run_event PreToolUse Bash "$BLOCKED_CMD" HQ_HOOK_PARALLEL=1
expect_refused "HQ_HOOK_PARALLEL=1, scope authorizer missing" "$SCOPE_MISSING_LINE" strict
restore_authorizer
rm -f "$REG"
run_event PreToolUse Bash "$BLOCKED_CMD" HQ_HOOK_PARALLEL=1
[ "$RC" -eq 2 ] && [ "$(lines '^BLOCKED: Cross-company scope violation')" = "1" ] \
  || fail "HQ_HOOK_PARALLEL=1, registry missing: the authorizer did not refuse. $(show)"
run_event PreToolUse Bash "$ALLOWED_CMD" HQ_HOOK_PARALLEL=1
expect_allowed "HQ_HOOK_PARALLEL=1, registry missing, own-company Bash"
restore_registry
pass "HQ_HOOK_PARALLEL=1: the cases are refused or decided the same way"

# ---------------------------------------------------------------- 2. unchanged behaviour
printf '{"hooks": {' > "$REG"
run_event PreToolUse Agent "a prompt"
expect_allowed "registry unparsable, Agent (no scope authorizer row)"
run_event UserPromptSubmit none "a prompt"
expect_allowed "registry unparsable, UserPromptSubmit"
run_event PostToolUse Bash "$BLOCKED_CMD"
expect_allowed "registry unparsable, PostToolUse"
restore_registry
pass "a broken registry refuses no tool the scope authorizer does not guard, and no event but PreToolUse"

# Context and logging rows: a missing script is skipped, as before.
for ctx in inject-policy-on-trigger surface-company-infra-policy merged-write-guard-shadow; do
  mv "$HOOKS/$ctx.sh" "$TMP/$ctx.off"
done
run_event PreToolUse Bash "echo regfailprobe deploy aws; $ALLOWED_CMD" HQ_HOOK_TRACE=1
for ctx in inject-policy-on-trigger surface-company-infra-policy merged-write-guard-shadow; do
  mv "$TMP/$ctx.off" "$HOOKS/$ctx.sh"
done
expect_allowed "context rows missing, own-company Bash"
for ctx in inject-policy-on-trigger surface-company-infra-policy merged-write-guard-shadow; do
  [ "$(lines "^master-hook: skip $ctx (missing-script)")" = "1" ] || fail "context row $ctx: expected a missing-script skip. $(show)"
done
mv "$HOOKS/warn-cross-company-settings.sh" "$TMP/warn.off"
run_event PreToolUse Read "$FIX/companies/acme/settings/notes.md" HQ_HOOK_TRACE=1
mv "$TMP/warn.off" "$HOOKS/warn-cross-company-settings.sh"
expect_allowed "context row warn-cross-company-settings missing, own-company Read"
[ "$(lines '^master-hook: skip warn-cross-company-settings (missing-script)')" = "1" ] \
  || fail "warn-cross-company-settings: expected a missing-script skip. $(show)"
pass "context and logging rows whose script is missing are skipped and the call is allowed, as before"

# The unreadable verdict is not kept once the registry is repaired.
printf '{"hooks": {' > "$REG"
run_event PreToolUse Bash "$ALLOWED_CMD"
[ "$RC" -eq 2 ] || fail "registry unparsable: an own-company Bash was not refused. $(show)"
restore_registry
run_event PreToolUse Bash "$ALLOWED_CMD"
expect_allowed "registry repaired, own-company Bash"
run_event PreToolUse Bash "$BLOCKED_CMD"
[ "$RC" -eq 2 ] && [ "$(lines '^BLOCKED: Cross-company scope violation')" = "1" ] \
  || fail "registry repaired: the scope authorizer did not decide. $(show)"
pass "after the registry is repaired the scope authorizer decides again"

# A repair that keeps an older mtime (cp -p, rsync -a, a backup restore) is
# not held back by a cached refusal. The first call caches valid rows; the
# unreadable verdict must not replace them.
touch -t 202001010000 "$TMP/registry.good.json"
restore_registry
run_event PreToolUse Bash "$ALLOWED_CMD"
expect_allowed "cache primed, own-company Bash"
printf '{"hooks": {' > "$REG"
run_event PreToolUse Bash "$ALLOWED_CMD"
[ "$RC" -eq 2 ] || fail "registry unparsable before the old-mtime repair: an own-company Bash was not refused. $(show)"
rm -f "$REG"; cp -p "$TMP/registry.good.json" "$REG"
run_event PreToolUse Bash "$ALLOWED_CMD"
expect_allowed "registry repaired with an older mtime (cp -p), own-company Bash"
restore_registry
pass "a registry repaired with an older mtime is used at once; the unreadable verdict is not cached"

# ---------------------------------------------------------------- 3. daemon up (stub)
start_stub
run_event PreToolUse Agent "a prompt"
[ "$(reqs policy.check)" = "1" ] && [ "$RC" -eq 0 ] || fail "stub hqd: the stub is not consulted or does not allow. $(show)"
check_both_cases "daemon up (stub allows)" strict
# With the registry unreadable the hqd call is kept, and its allow does not
# override the registry refusal.
printf '{"hooks": {' > "$REG"
run_event PreToolUse Bash "$BLOCKED_CMD"
[ "$(reqs policy.check)" = "1" ] || fail "stub hqd, registry unparsable: expected one policy.check. $(show)"
expect_refused "stub hqd, registry unparsable" "$REG_UNPARSABLE_LINE" strict
restore_registry
pass "daemon up (stub allows): hqd is still asked when the registry is unreadable, and its allow does not undo the refusal"
stop_stub

# ---------------------------------------------------------------- 4. daemon up (real hqd)
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
const r = reg.emptyRegistry();
reg.setEntry(r, reg.keyForDir(root), "acme", "link");
reg.writeRegistry(r, path.join(home, "registry.json"));
await startHqdServer({
  socketPath: sock,
  registryPath: path.join(home, "registry.json"),
  hqRoot: root,
  env: { PATH: process.env.PATH, HOME: home, TMPDIR: process.env.TMPDIR ?? "/tmp",
         HQ_WORK_MESH_ROOT: path.join(home, ".hq", "work-mesh"), WORK_MESH_SEQ_DIR: path.join(home, ".hq", "work-mesh", "seq") },
  runtimeFlagReader: async () => true,
  personSettingReader: async () => true,
  workMeshRoot: path.join(home, ".hq", "work-mesh"),
});
process.stdout.write("ready\n");
JS
rm -f "$SOCK"
env -i PATH="$PATH" HOME="$HOME_DIR" TMPDIR="${TMPDIR:-/tmp}" \
  node "$TMP/hqd.mjs" "$CLI" "$SOCK" "$FIX" "$HOME_DIR" > "$TMP/hqd.log" 2>&1 &
HQD_PID=$!
for _ in $(seq 1 150); do grep -q ready "$TMP/hqd.log" 2>/dev/null && break; sleep 0.1; done
grep -q ready "$TMP/hqd.log" || fail "real hqd did not start: $(cat "$TMP/hqd.log")"
# hqd may print a refusal of its own beside master-hook's line, so the other
# BLOCKED lines are not counted here.
check_both_cases "daemon up (real hqd)"
kill "$HQD_PID" 2>/dev/null || true
wait "$HQD_PID" 2>/dev/null || true
HQD_PID=""

[ "$FAILS" -eq 0 ] || { echo "FAILED: master-hook-registry-fail-closed ($FAILS failures)" >&2; exit 1; }
echo "ALL PASS: master-hook-registry-fail-closed ($PASS checks)"
