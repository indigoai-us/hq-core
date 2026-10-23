#!/usr/bin/env bash
# hq-core: public
# master-hook-hook-engine-bridge.test.sh — master-hook.sh runs a registry hook
# through the hq-cli `hq-hook` engine when the engine's bridge plan lists the
# hook id (per-hook flag hook-engine-port-<id> set to shadow or on), and is a
# strict no-op otherwise: no binary, kill switch, no port flag in any flag
# snapshot, or a failing plan command (US-021).
#
# A stub hq-hook in the temp dir implements the CLI contract:
#   bridge-plan --min-version X --schema N   prints the lines in plan.txt
#   bridge <id> --mode M ... --script S -- args...
#     logs argv and stdin length; `on` prints a distinctive JSON object,
#     `shadow` runs S with the args on the same stdin and prints its output.
#
# Sections:
#   [a] no binary: output byte-identical to a master-hook with the bridge
#       call site removed; the stub is never started
#   [b] plan says on: bash hook not run, engine output returned, argv logged
#   [c] plan says shadow: bash hook ran once, its own output returned
#   [d] HQ_HOOK_ENGINE=off: stub never started, bash hook ran
#   [e] ~/.hq/hook-engine.off: same as [d]
#   [f] no snapshot mentions hook-engine-port-: pre-gate, stub never started
#   [g] pointer file ~/.hq/bin/hq-hook/current discovers the binary
#   [h] bridge-plan exits 1: bash hook ran, no bridge call
#   [i] a hook the plan does not list keeps the bash path
#   [j] a bridge-plan that hangs is killed at HQ_HOOK_ENGINE_PLAN_TIMEOUT
#       (default 5 s); the event finishes with byte-identical bash output
#   [k] an engine exit other than 0 or 2 (1, 127, timeout) is no verdict: the
#       bash guard runs and its block lands; exit 2 from the engine blocks
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
MASTER="$ROOT/.claude/hooks/master-hook.sh"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable" >&2; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mh-hook-engine-bridge.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
# master-hook resolves its root with pwd -P; compare script paths in that form
# (macOS TMPDIR ends in a slash and may sit under a symlink).
TMP="$(cd "$TMP" && pwd -P)"
FIX="$TMP/hq"
FIX_NOBRIDGE="$TMP/hq-nobridge"
FAKE_HOME="$TMP/home"
CACHE="$FAKE_HOME/.cache"
ENGINE="$TMP/engine"
STUB="$ENGINE/hq-hook"
CALLS="$ENGINE/calls.log"
PLAN="$ENGINE/plan.txt"
PLAN_RC="$ENGINE/plan-rc"
PLAN_SLEEP="$ENGINE/plan-sleep"
HOOK_ID="fixture-port"
PLAIN_ID="fixture-plain"
HOOK_TIMEOUT=7
# The interpreter under test is pinned: HQ_TEST_BASH when set, else /bin/bash
# (what settings.json resolves on macOS), else the first bash on PATH.
TEST_BASH="${HQ_TEST_BASH:-/bin/bash}"
[ -x "$TEST_BASH" ] || TEST_BASH="$(command -v bash)"
echo "interpreter under test: $TEST_BASH ($("$TEST_BASH" -c 'echo "$BASH_VERSION"'))"
mkdir -p "$FAKE_HOME" "$CACHE/hq/flags" "$ENGINE"

make_fixture() { # <root>
  local root="$1"
  mkdir -p "$root/.claude/hooks" "$root/core/scripts/lib" "$root/workspace/orchestrator"
  cp "$MASTER" "$root/.claude/hooks/master-hook.sh"
  for f in hook-timeout-probe.sh hook-timeout-watchdog.sh hook-gate.sh; do
    cp "$ROOT/.claude/hooks/$f" "$root/.claude/hooks/"
  done
  cp "$ROOT/core/scripts/lib/hook-adapter-core.sh" "$ROOT/core/scripts/lib/trigger-fact-text.awk" "$root/core/scripts/lib/"
  cp "$ROOT/core/scripts/resolve-hq-root.sh" "$root/core/scripts/"
  printf 'hqVersion: "15.0.131"\n' > "$root/core/core.yaml"
  # Registry hooks. Each appends a line to ran.log next to itself and prints a
  # JSON object naming itself and its argv, so the test can tell which path
  # produced the output.
  cat > "$root/.claude/hooks/$HOOK_ID.sh" <<'HOOK'
#!/usr/bin/env bash
payload="$(cat)"
here="$(cd "$(dirname "$0")" && pwd)"
printf 'port stdin=%s args=%s\n' "${#payload}" "$*" >> "$here/ran.log"
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"bash-hook:fixture-port:%s"}}\n' "$*"
exit 0
HOOK
  cat > "$root/.claude/hooks/$PLAIN_ID.sh" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
here="$(cd "$(dirname "$0")" && pwd)"
printf 'plain args=%s\n' "$*" >> "$here/ran.log"
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"bash-hook:fixture-plain:%s"}}\n' "$*"
exit 0
HOOK
  chmod +x "$root/.claude/hooks/$HOOK_ID.sh" "$root/.claude/hooks/$PLAIN_ID.sh"
  jq -nc --arg id "$HOOK_ID" --arg s ".claude/hooks/$HOOK_ID.sh" \
    --arg pid "$PLAIN_ID" --arg ps ".claude/hooks/$PLAIN_ID.sh" --argjson t "$HOOK_TIMEOUT" '
    {hooks: {PreToolUse: [{matcher: "Bash", hooks: [
      {id: $id, script: $s, timeout: $t, gated: false, runner: "exec", args: ["PreToolUse"]},
      {id: $pid, script: $ps, timeout: $t, gated: false, runner: "exec", args: ["PreToolUse"]}
    ]}]}}' > "$root/.claude/hooks/hook-registry.json"
}
make_fixture "$FIX"
make_fixture "$FIX_NOBRIDGE"

# [a] reference: the dispatcher this branch was cut from (the merge base with
# origin/main), which has no bridge at all. When that commit is not available
# (shallow or offline checkout), fall back to the same dispatcher with the
# bridge call site replaced by an empty mode.
BASE_SHA="$(git -C "$ROOT" merge-base HEAD origin/main 2>/dev/null || true)"
REFERENCE="merge-base ${BASE_SHA:-unavailable}"
if [ -n "$BASE_SHA" ] && git -C "$ROOT" show "$BASE_SHA:.claude/hooks/master-hook.sh" > "$FIX_NOBRIDGE/.claude/hooks/master-hook.sh.base" 2>/dev/null \
  && [ -s "$FIX_NOBRIDGE/.claude/hooks/master-hook.sh.base" ]; then
  mv -f "$FIX_NOBRIDGE/.claude/hooks/master-hook.sh.base" "$FIX_NOBRIDGE/.claude/hooks/master-hook.sh"
else
  rm -f "$FIX_NOBRIDGE/.claude/hooks/master-hook.sh.base"
  REFERENCE="sed-removed call site"
  CALL_SITE='master_hook_engine_bridge_mode "$rid"'
  n="$(grep -c "^ *$CALL_SITE\$" "$FIX_NOBRIDGE/.claude/hooks/master-hook.sh")"
  [ "$n" = "1" ] || { echo "FAIL: expected one bridge call site in master-hook.sh, found $n" >&2; exit 1; }
  sed "s/^\\( *\\)$CALL_SITE\$/\\1HOOK_ENGINE_BRIDGE_MODE=\"\"/" "$FIX_NOBRIDGE/.claude/hooks/master-hook.sh" > "$FIX_NOBRIDGE/.claude/hooks/master-hook.sh.new"
  mv -f "$FIX_NOBRIDGE/.claude/hooks/master-hook.sh.new" "$FIX_NOBRIDGE/.claude/hooks/master-hook.sh"
  grep -q "$CALL_SITE" "$FIX_NOBRIDGE/.claude/hooks/master-hook.sh" && { echo "FAIL: bridge call site survived the sed" >&2; exit 1; }
fi
echo "reference dispatcher: $REFERENCE"

# Stub hq-hook. Paths are relative to the stub's own directory.
cat > "$STUB" <<'STUB'
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
cmd="${1:-}"
[ $# -eq 0 ] || shift
case "$cmd" in
  bridge-plan)
    printf 'bridge-plan %s\n' "$*" >> "$here/calls.log"
    # A hung engine: become the sleeping process so the timeout runner's
    # kill is what ends it.
    if [ -f "$here/plan-sleep" ]; then
      printf '%s\n' "$$" > "$here/plan-pid"
      exec sleep "$(cat "$here/plan-sleep")"
    fi
    if [ -f "$here/plan-rc" ]; then
      rc="$(cat "$here/plan-rc")"
      exit "$rc"
    fi
    [ ! -f "$here/plan.txt" ] || cat "$here/plan.txt"
    exit 0
    ;;
  bridge)
    payload="$(cat)"
    printf 'bridge %s stdin=%s\n' "$*" "${#payload}" >> "$here/calls.log"
    # Engine faults: hang (killed by run_child's timeout) or exit with no verdict.
    if [ -f "$here/bridge-sleep" ]; then
      printf '%s\n' "$$" > "$here/bridge-pid"
      exec sleep "$(cat "$here/bridge-sleep")"
    fi
    if [ -f "$here/bridge-rc" ]; then
      exit "$(cat "$here/bridge-rc")"
    fi
    id="${1:-}"
    [ $# -eq 0 ] || shift
    mode=""
    script=""
    args=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --mode) mode="${2:-}"; shift 2 ;;
        --script) script="${2:-}"; shift 2 ;;
        --event|--timeout) shift 2 ;;
        --) shift; args=("$@"); break ;;
        *) shift ;;
      esac
    done
    if [ "$mode" = "shadow" ]; then
      printf '%s' "$payload" | "$script" ${args[@]+"${args[@]}"}
      exit "${PIPESTATUS[1]}"
    fi
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"bridged:%s:%s"}}\n' "$id" "$mode"
    exit 0
    ;;
  *)
    echo "stub hq-hook: unknown command $cmd" >&2
    exit 2
    ;;
esac
STUB
chmod +x "$STUB"

PAYLOAD="$(jq -nc --arg d "$FIX" '{session_id:"bridge-test",hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$d,tool_input:{command:"echo hi"}}')"

snapshot_with_port() {
  printf '%s\n' '{"flags":{"hook-engine-port-fixture-port":"on","hq-anywhere-runtime":false}}' > "$CACHE/hq/flags/snapshot-cmp_123456.json"
}
snapshot_without_port() {
  printf '%s\n' '{"flags":{"hq-anywhere-runtime":false}}' > "$CACHE/hq/flags/snapshot-cmp_123456.json"
}
reset_logs() {
  rm -f "$CALLS" "$PLAN_RC" "$PLAN_SLEEP" "$ENGINE/plan-pid" "$ENGINE/bridge-rc" "$ENGINE/bridge-sleep" "$ENGINE/bridge-pid" "$FIX/.claude/hooks/ran.log" "$FIX_NOBRIDGE/.claude/hooks/ran.log" \
    "$FAKE_HOME/.hq/hook-engine.off"
  rm -rf "$FAKE_HOME/.hq/bin"
}

# run <root> [ENV=VALUE ...] -> RC, stdout in $TMP/out, stderr in $TMP/err
run() {
  local root="$1"; shift
  RC=0
  printf '%s' "$PAYLOAD" | (cd "$root" && env HOME="$FAKE_HOME" XDG_CACHE_HOME="$CACHE" \
    HQ_HOOK_PROFILE=standard CLAUDE_PROJECT_DIR="$root" HQ_ROOT="$root" \
    HQ_HOOK_DEDUPE=0 HQ_HOOK_TIMEOUT_SENTRY=0 HQ_FLAGS_API_URL= HQ_COMPANY_UID= \
    "$@" "$TEST_BASH" "$root/.claude/hooks/master-hook.sh" PreToolUse) \
    >"$TMP/out" 2>"$TMP/err" || RC=$?
}
ran_count() { # <root> <prefix>
  [ -f "$1/.claude/hooks/ran.log" ] || { echo 0; return; }
  grep -c "^$2 " "$1/.claude/hooks/ran.log" || true
}
bridge_calls() {
  [ -f "$CALLS" ] || { echo 0; return; }
  grep -c '^bridge ' "$CALLS" || true
}
out_has() { grep -qF "$1" "$TMP/out"; }

echo "[a] no binary: byte-identical to the dispatcher without a bridge call site"
reset_logs
snapshot_with_port
printf '%s\t%s\n' "$HOOK_ID" on > "$PLAN"
run "$FIX"
rc_a="$RC"; cp "$TMP/out" "$TMP/out-a"; cp "$TMP/err" "$TMP/err-a"
run "$FIX_NOBRIDGE"
if [ "$rc_a" = "$RC" ] && cmp -s "$TMP/out-a" "$TMP/out" && cmp -s "$TMP/err-a" "$TMP/err"; then
  ok "stdout, stderr and exit code match (rc=$RC)"
else
  bad "output differs: rc $rc_a vs $RC; out-a=$(head -c 200 "$TMP/out-a") out=$(head -c 200 "$TMP/out") err-a=$(head -c 200 "$TMP/err-a") err=$(head -c 200 "$TMP/err")"
fi
[ ! -e "$CALLS" ] && ok "stub never started" || bad "stub was started: $(cat "$CALLS")"
[ "$(ran_count "$FIX" port)" = "1" ] && out_has "bash-hook:$HOOK_ID:PreToolUse" \
  && ok "bash hook ran once and its output was returned" \
  || bad "bash hook ran $(ran_count "$FIX" port) times; out=$(head -c 300 "$TMP/out")"

echo "[b] plan says on: engine replaces the bash hook"
reset_logs
snapshot_with_port
printf '%s\t%s\n' "$HOOK_ID" on > "$PLAN"
run "$FIX" HQ_HOOK_ENGINE_BIN="$STUB"
[ "$RC" = "0" ] && ok "rc 0" || bad "rc=$RC err=$(head -c 300 "$TMP/err")"
[ "$(ran_count "$FIX" port)" = "0" ] && ok "bash hook not run" || bad "bash hook ran: $(cat "$FIX/.claude/hooks/ran.log")"
out_has "bridged:$HOOK_ID:on" && ok "output carries bridged:$HOOK_ID:on" || bad "out=$(head -c 300 "$TMP/out")"
! out_has "bash-hook:$HOOK_ID:" && ok "bash hook output absent" || bad "bash hook output present: $(head -c 300 "$TMP/out")"
expected="bridge $HOOK_ID --mode on --event PreToolUse --timeout $HOOK_TIMEOUT --script $FIX/.claude/hooks/$HOOK_ID.sh -- PreToolUse stdin=${#PAYLOAD}"
if [ -f "$CALLS" ] && grep -qxF "$expected" "$CALLS"; then
  ok "call log: $expected"
else
  bad "call log missing [$expected]; got: $(cat "$CALLS" 2>/dev/null)"
fi
[ "$(bridge_calls)" = "1" ] && ok "one bridge call" || bad "$(bridge_calls) bridge calls"
[ "$(grep -c '^bridge-plan ' "$CALLS")" = "1" ] \
  && grep -qxF "bridge-plan --min-version 0.2.0 --schema 1" "$CALLS" \
  && ok "one bridge-plan call with the min version and schema" \
  || bad "bridge-plan calls: $(grep '^bridge-plan' "$CALLS")"
# Trace names the bridge.
run "$FIX" HQ_HOOK_ENGINE_BIN="$STUB" HQ_HOOK_TRACE=1
grep -qF "master-hook: bridge $HOOK_ID (on)" "$TMP/err" && ok "trace line names the bridged hook and mode" \
  || bad "trace missing: $(head -c 400 "$TMP/err")"

echo "[c] plan says shadow: bash hook output returned, bash hook ran once"
reset_logs
snapshot_with_port
printf '%s\t%s\n' "$HOOK_ID" shadow > "$PLAN"
run "$FIX" HQ_HOOK_ENGINE_BIN="$STUB"
[ "$RC" = "0" ] && ok "rc 0" || bad "rc=$RC err=$(head -c 300 "$TMP/err")"
[ "$(ran_count "$FIX" port)" = "1" ] && ok "bash hook ran once (through the engine)" \
  || bad "bash hook ran $(ran_count "$FIX" port) times"
grep -qF "port stdin=${#PAYLOAD} args=PreToolUse" "$FIX/.claude/hooks/ran.log" \
  && ok "bash hook saw the full payload and its args" \
  || bad "ran.log: $(cat "$FIX/.claude/hooks/ran.log")"
out_has "bash-hook:$HOOK_ID:PreToolUse" && ! out_has "bridged:" \
  && ok "bash hook output returned, no engine output" || bad "out=$(head -c 300 "$TMP/out")"
grep -qF "bridge $HOOK_ID --mode shadow --event PreToolUse" "$CALLS" && ok "bridge called in shadow mode" \
  || bad "calls: $(cat "$CALLS")"

echo "[d] HQ_HOOK_ENGINE=off disables the bridge"
for v in off OFF Off; do
  reset_logs
  snapshot_with_port
  printf '%s\t%s\n' "$HOOK_ID" on > "$PLAN"
  run "$FIX" HQ_HOOK_ENGINE_BIN="$STUB" HQ_HOOK_ENGINE="$v"
  [ ! -e "$CALLS" ] && [ "$(ran_count "$FIX" port)" = "1" ] && out_has "bash-hook:$HOOK_ID:PreToolUse" \
    && ok "HQ_HOOK_ENGINE=$v: stub never started, bash hook ran" \
    || bad "HQ_HOOK_ENGINE=$v: calls=$(cat "$CALLS" 2>/dev/null) ran=$(ran_count "$FIX" port)"
done

echo "[e] ~/.hq/hook-engine.off disables the bridge"
reset_logs
snapshot_with_port
printf '%s\t%s\n' "$HOOK_ID" on > "$PLAN"
mkdir -p "$FAKE_HOME/.hq"
: > "$FAKE_HOME/.hq/hook-engine.off"
run "$FIX" HQ_HOOK_ENGINE_BIN="$STUB"
[ ! -e "$CALLS" ] && [ "$(ran_count "$FIX" port)" = "1" ] && out_has "bash-hook:$HOOK_ID:PreToolUse" \
  && ok "marker file: stub never started, bash hook ran" \
  || bad "marker file: calls=$(cat "$CALLS" 2>/dev/null) ran=$(ran_count "$FIX" port)"

echo "[f] no snapshot mentions hook-engine-port-: pre-gate stops before any process"
reset_logs
snapshot_without_port
printf '%s\t%s\n' "$HOOK_ID" on > "$PLAN"
run "$FIX" HQ_HOOK_ENGINE_BIN="$STUB"
[ ! -e "$CALLS" ] && [ "$(ran_count "$FIX" port)" = "1" ] && out_has "bash-hook:$HOOK_ID:PreToolUse" \
  && ok "no port flag in snapshots: stub never started, bash hook ran" \
  || bad "pre-gate: calls=$(cat "$CALLS" 2>/dev/null) ran=$(ran_count "$FIX" port)"
rm -f "$CACHE/hq/flags/snapshot-cmp_123456.json"
rm -f "$CALLS" "$FIX/.claude/hooks/ran.log"
run "$FIX" HQ_HOOK_ENGINE_BIN="$STUB"
[ ! -e "$CALLS" ] && [ "$(ran_count "$FIX" port)" = "1" ] \
  && ok "no snapshot file at all: stub never started, bash hook ran" \
  || bad "no snapshot: calls=$(cat "$CALLS" 2>/dev/null) ran=$(ran_count "$FIX" port)"

echo "[g] pointer file discovery"
reset_logs
snapshot_with_port
printf '%s\t%s\n' "$HOOK_ID" on > "$PLAN"
mkdir -p "$FAKE_HOME/.hq/bin/hq-hook"
printf '%s\n' "$STUB" > "$FAKE_HOME/.hq/bin/hq-hook/current"
run "$FIX"
[ "$RC" = "0" ] && [ "$(ran_count "$FIX" port)" = "0" ] && out_has "bridged:$HOOK_ID:on" \
  && grep -qF "bridge $HOOK_ID --mode on --event PreToolUse --timeout $HOOK_TIMEOUT --script $FIX/.claude/hooks/$HOOK_ID.sh -- PreToolUse" "$CALLS" \
  && ok "pointer file: behaves like [b]" \
  || bad "pointer file: rc=$RC ran=$(ran_count "$FIX" port) out=$(head -c 300 "$TMP/out") calls=$(cat "$CALLS" 2>/dev/null)"
# A pointer at a non-executable path disables the bridge.
reset_logs
snapshot_with_port
mkdir -p "$FAKE_HOME/.hq/bin/hq-hook"
printf '%s\n' "$ENGINE/plan.txt" > "$FAKE_HOME/.hq/bin/hq-hook/current"
run "$FIX"
[ ! -e "$CALLS" ] && [ "$(ran_count "$FIX" port)" = "1" ] \
  && ok "pointer at a non-executable path: bash hook ran" \
  || bad "bad pointer: calls=$(cat "$CALLS" 2>/dev/null) ran=$(ran_count "$FIX" port)"

echo "[h] bridge-plan failure keeps the bash hook"
reset_logs
snapshot_with_port
printf '%s\t%s\n' "$HOOK_ID" on > "$PLAN"
printf '1\n' > "$PLAN_RC"
run "$FIX" HQ_HOOK_ENGINE_BIN="$STUB"
[ "$RC" = "0" ] && [ "$(bridge_calls)" = "0" ] && [ "$(ran_count "$FIX" port)" = "1" ] && out_has "bash-hook:$HOOK_ID:PreToolUse" \
  && ok "plan exit 1: bash hook ran, no bridge call" \
  || bad "plan exit 1: rc=$RC calls=$(cat "$CALLS" 2>/dev/null) ran=$(ran_count "$FIX" port)"
# An empty plan (exit 0, no lines) also keeps the bash hook.
reset_logs
snapshot_with_port
: > "$PLAN"
run "$FIX" HQ_HOOK_ENGINE_BIN="$STUB"
[ "$(bridge_calls)" = "0" ] && [ "$(ran_count "$FIX" port)" = "1" ] \
  && ok "empty plan: bash hook ran, no bridge call" \
  || bad "empty plan: calls=$(cat "$CALLS" 2>/dev/null) ran=$(ran_count "$FIX" port)"

echo "[i] a hook the plan does not list keeps the bash path"
reset_logs
snapshot_with_port
printf '%s\t%s\n' "$HOOK_ID" on > "$PLAN"
run "$FIX" HQ_HOOK_ENGINE_BIN="$STUB"
[ "$(ran_count "$FIX" plain)" = "1" ] && out_has "bash-hook:$PLAIN_ID:PreToolUse" && out_has "bridged:$HOOK_ID:on" \
  && [ "$(bridge_calls)" = "1" ] \
  && ok "unlisted sibling ran as bash while the listed hook was bridged" \
  || bad "sibling: ran=$(ran_count "$FIX" plain) calls=$(cat "$CALLS" 2>/dev/null) out=$(head -c 300 "$TMP/out")"
# An unknown mode in the plan is ignored.
reset_logs
snapshot_with_port
printf '%s\t%s\n' "$HOOK_ID" maybe > "$PLAN"
run "$FIX" HQ_HOOK_ENGINE_BIN="$STUB"
[ "$(bridge_calls)" = "0" ] && [ "$(ran_count "$FIX" port)" = "1" ] \
  && ok "unknown plan mode: bash hook ran" \
  || bad "unknown mode: calls=$(cat "$CALLS" 2>/dev/null) ran=$(ran_count "$FIX" port)"

echo "[j] a hung bridge-plan is killed at HQ_HOOK_ENGINE_PLAN_TIMEOUT and every hook stays on bash"
reset_logs
snapshot_with_port
printf '%s\t%s\n' "$HOOK_ID" on > "$PLAN"
printf '30\n' > "$PLAN_SLEEP"
started="$(date +%s)"
run "$FIX" HQ_HOOK_ENGINE_BIN="$STUB"
elapsed=$(( $(date +%s) - started ))
rc_j="$RC"; cp "$TMP/out" "$TMP/out-j"; cp "$TMP/err" "$TMP/err-j"
# The default plan timeout is 5 s; the 30 s stub must never run to completion.
[ "$elapsed" -le 20 ] && ok "master-hook finished in ${elapsed}s with a 30 s plan stub" \
  || bad "master-hook took ${elapsed}s with a hung plan stub"
[ "$(bridge_calls)" = "0" ] && [ "$(ran_count "$FIX" port)" = "1" ] && out_has "bash-hook:$HOOK_ID:PreToolUse" \
  && ok "hung plan: bash hook ran, no bridge call" \
  || bad "hung plan: calls=$(cat "$CALLS" 2>/dev/null) ran=$(ran_count "$FIX" port) out=$(head -c 300 "$TMP/out")"
sleep 1
if [ -s "$ENGINE/plan-pid" ] && kill -0 "$(cat "$ENGINE/plan-pid")" 2>/dev/null; then
  bad "the plan stub (pid $(cat "$ENGINE/plan-pid")) survived the timeout"
  kill -9 "$(cat "$ENGINE/plan-pid")" 2>/dev/null || true
else
  ok "the plan stub was killed, not left sleeping"
fi
rm -f "$FIX_NOBRIDGE/.claude/hooks/ran.log"
run "$FIX_NOBRIDGE"
if [ "$rc_j" = "$RC" ] && cmp -s "$TMP/out-j" "$TMP/out" && cmp -s "$TMP/err-j" "$TMP/err"; then
  ok "hung plan: stdout, stderr and exit code match the reference dispatcher (rc=$RC)"
else
  bad "hung plan output differs: rc $rc_j vs $RC; out-j=$(head -c 200 "$TMP/out-j") out=$(head -c 200 "$TMP/out") err-j=$(head -c 200 "$TMP/err-j") err=$(head -c 200 "$TMP/err")"
fi
# A shorter budget from the environment is honoured.
reset_logs
snapshot_with_port
printf '%s\t%s\n' "$HOOK_ID" on > "$PLAN"
printf '30\n' > "$PLAN_SLEEP"
started="$(date +%s)"
run "$FIX" HQ_HOOK_ENGINE_BIN="$STUB" HQ_HOOK_ENGINE_PLAN_TIMEOUT=1
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -le 10 ] && [ "$(ran_count "$FIX" port)" = "1" ] && [ "$(bridge_calls)" = "0" ] \
  && ok "HQ_HOOK_ENGINE_PLAN_TIMEOUT=1 honoured (${elapsed}s), bash hook ran" \
  || bad "plan timeout override: ${elapsed}s calls=$(cat "$CALLS" 2>/dev/null) ran=$(ran_count "$FIX" port)"
# Values that would disable the timeout (0, 00, 000) and non-integers fall back
# to the 5 s default instead of waiting on the stub.
for bad_timeout in 0 00 000 abc 2.5; do
  reset_logs
  snapshot_with_port
  printf '%s\t%s\n' "$HOOK_ID" on > "$PLAN"
  printf '30\n' > "$PLAN_SLEEP"
  started="$(date +%s)"
  run "$FIX" HQ_HOOK_ENGINE_BIN="$STUB" HQ_HOOK_ENGINE_PLAN_TIMEOUT="$bad_timeout"
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -le 20 ] && [ "$(ran_count "$FIX" port)" = "1" ] && [ "$(bridge_calls)" = "0" ] \
    && ok "HQ_HOOK_ENGINE_PLAN_TIMEOUT=$bad_timeout rejected, default budget applied (${elapsed}s)" \
    || bad "plan timeout $bad_timeout: ${elapsed}s calls=$(cat "$CALLS" 2>/dev/null) ran=$(ran_count "$FIX" port)"
done

echo "[k] an engine fault (exit 1, exit 127, timeout) never loses a guard's block"
BLOCK_ID="fixture-block"
cat > "$FIX/.claude/hooks/$BLOCK_ID.sh" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
here="$(cd "$(dirname "$0")" && pwd)"
printf 'block args=%s\n' "$*" >> "$here/ran.log"
printf 'BLOCKED: fixture-block refuses this command\n' >&2
exit 2
HOOK
chmod +x "$FIX/.claude/hooks/$BLOCK_ID.sh"
cp "$FIX/.claude/hooks/hook-registry.json" "$TMP/registry.orig"
jq -nc --arg id "$BLOCK_ID" --arg s ".claude/hooks/$BLOCK_ID.sh" --argjson t "$HOOK_TIMEOUT" '
  {hooks: {PreToolUse: [{matcher: "Bash", hooks: [
    {id: $id, script: $s, timeout: $t, gated: false, runner: "exec", args: ["PreToolUse"]}
  ]}]}}' > "$FIX/.claude/hooks/hook-registry.json"
# 70 is the engine's own fault code (hq-cli #2129: usage error, bad argument,
# bash that cannot be spawned, oversized output); it must never read as a block.
for fault in 1 70 127 timeout; do
  reset_logs
  snapshot_with_port
  printf '%s\t%s\n' "$BLOCK_ID" on > "$PLAN"
  if [ "$fault" = timeout ]; then
    printf '30\n' > "$ENGINE/bridge-sleep"
  else
    printf '%s\n' "$fault" > "$ENGINE/bridge-rc"
  fi
  started="$(date +%s)"
  run "$FIX" HQ_HOOK_ENGINE_BIN="$STUB"
  elapsed=$(( $(date +%s) - started ))
  if [ "$RC" = "2" ] && grep -q "BLOCKED: fixture-block" "$TMP/err" \
    && [ "$(ran_count "$FIX" block)" = "1" ] && [ "$(bridge_calls)" = "1" ]; then
    ok "engine $fault: bridge tried once, bash guard ran and its block landed (rc=2, ${elapsed}s)"
  else
    bad "engine $fault: rc=$RC ran=$(ran_count "$FIX" block) calls=$(cat "$CALLS" 2>/dev/null) err=$(head -c 300 "$TMP/err")"
  fi
  if [ "$fault" = timeout ]; then
    # The bridge gets the registry timeout ($HOOK_TIMEOUT s); the bash fallback
    # runs after it, so the event is bounded by twice that budget.
    [ "$elapsed" -le $((HOOK_TIMEOUT * 2 + 5)) ] && ok "timeout fault bounded (${elapsed}s)" || bad "timeout fault took ${elapsed}s"
    sleep 1
    if [ -s "$ENGINE/bridge-pid" ] && kill -0 "$(cat "$ENGINE/bridge-pid")" 2>/dev/null; then
      bad "the bridge stub (pid $(cat "$ENGINE/bridge-pid")) survived the registry timeout"
      kill -9 "$(cat "$ENGINE/bridge-pid")" 2>/dev/null || true
    else
      ok "the bridge stub was killed at the registry timeout"
    fi
  fi
done
# Same faults in shadow mode: the engine would have returned bash's result
# itself; when it cannot, bash still runs and still blocks.
reset_logs
snapshot_with_port
printf '%s\t%s\n' "$BLOCK_ID" shadow > "$PLAN"
printf '1\n' > "$ENGINE/bridge-rc"
run "$FIX" HQ_HOOK_ENGINE_BIN="$STUB"
[ "$RC" = "2" ] && grep -q "BLOCKED: fixture-block" "$TMP/err" && [ "$(ran_count "$FIX" block)" = "1" ] \
  && ok "shadow with engine exit 1: block landed" \
  || bad "shadow engine fault: rc=$RC ran=$(ran_count "$FIX" block) err=$(head -c 300 "$TMP/err")"
# A verdict from the engine is kept as is: exit 2 blocks without running bash.
reset_logs
snapshot_with_port
printf '%s\t%s\n' "$BLOCK_ID" on > "$PLAN"
printf '2\n' > "$ENGINE/bridge-rc"
run "$FIX" HQ_HOOK_ENGINE_BIN="$STUB"
[ "$RC" = "2" ] && [ "$(ran_count "$FIX" block)" = "0" ] \
  && ok "engine exit 2 is a block verdict; bash not run" \
  || bad "engine exit 2: rc=$RC ran=$(ran_count "$FIX" block)"
cp "$TMP/registry.orig" "$FIX/.claude/hooks/hook-registry.json"
reset_logs

if [ "$fail" -eq 0 ]; then
  echo "ALL PASS: master-hook-hook-engine-bridge ($pass)"
  exit 0
fi
echo "FAILURES: master-hook-hook-engine-bridge ($fail failed, $pass passed)" >&2
exit 1
