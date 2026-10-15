#!/usr/bin/env bash
# Regression: the SessionEnd MCP cleanup must only stop helpers its own session
# started, and only when the session is actually exiting.
#
# History: the hook used to `pgrep -f` the whole machine (policy
# `no-machine-wide-process-pattern-kills`), then ran on Stop (every turn) with
# an "any ancestor" ownership test that reached the shared desktop app, so it
# reaped its own live helpers and sibling sessions' helpers (feedback_1f67ad54).
#
# Each case runs the real hook inside a fake session host and checks who
# survived. The fake host is a symlink to bash under a test-only name, matched
# through the HQ_CLEANUP_HOST_NAMES seam, so a developer running this inside a
# real Claude or Codex session never has that session treated as the owner.

set -uo pipefail

CORE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT="$(cd "$CORE_ROOT/.." && pwd)"
HOOK="$ROOT/.claude/hooks/cleanup-mcp-processes.sh"
REGISTRY="$ROOT/.claude/hooks/hook-registry.json"
TMP="$(mktemp -d)"
HOST_NAME="hqtesthost"
export HQ_CLEANUP_HOST_NAMES="$HOST_NAME"
export HQ_CLEANUP_GRACE_SECONDS=1

SPAWNED=()
cleanup() {
  for p in ${SPAWNED[@]+"${SPAWNED[@]}"}; do
    kill -KILL "$p" 2>/dev/null || true
  done
  [ -f "$TMP/all.pids" ] && while read -r p; do kill -KILL "$p" 2>/dev/null || true; done < "$TMP/all.pids"
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok - $*"; }
alive() { kill -0 "$1" 2>/dev/null; }
wait_for_file() { local i=0; while [ ! -s "$1" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done; [ -s "$1" ]; }
died_within() {
  local pid="$1" i=0
  while [ "$i" -lt 60 ]; do alive "$pid" || return 0; sleep 0.1; i=$((i + 1)); done
  return 1
}

mkdir -p "$TMP/bin/slack-mcp/src" "$TMP/hostbin"
ln -s "$(command -v bash)" "$TMP/hostbin/$HOST_NAME"
HOST="$TMP/hostbin/$HOST_NAME"

# Stand-in MCP helper: records its pid, then sleeps. With a trigger file it
# re-execs into a different command line (same pid, new identity) when the
# trigger appears; with "term-exec" it does the same on SIGTERM.
make_helper() {
  cat > "$1" <<'FIXTURE'
#!/usr/bin/env bash
pidfile="$1"; mode="${2:-}"; trigger="${3:-}"
printf '%s\n' "$$" > "$pidfile"
printf '%s\n' "$$" >> "${ALL_PIDS:-/dev/null}"
if [ "$mode" = "term-exec" ]; then
  trap 'exec sleep 31' TERM
fi
i=0
while [ "$i" -lt 300 ]; do
  if [ "$mode" = "exec-on-trigger" ] && [ -f "$trigger" ]; then exec sleep 32; fi
  sleep 0.1; i=$((i + 1))
done
FIXTURE
  chmod +x "$1"
}
make_helper "$TMP/bin/agent-browser"
make_helper "$TMP/bin/slack-mcp/src/server.ts"
for runner in workflow-runner.mjs ultracode-workflow.mjs codex-workflow.mjs; do
  cat > "$TMP/bin/$runner" <<'RUNNER'
#!/usr/bin/env bash
# Protected agent workload that itself spawns a helper.
"$1" "$2" &
wait
RUNNER
  chmod +x "$TMP/bin/$runner"
done
export ALL_PIDS="$TMP/all.pids"

# A fake session: start helpers, then (optionally) run the hook as its own
# descendant with the given SessionEnd payload, then stay alive.
# session_script <name> <payload|-> <lines...>
session_script() {
  local name="$1" payload="$2"; shift 2
  {
    printf '#!/usr/bin/env bash\n'
    printf '%s\n' "$@"
    printf 'sleep 0.5\n'
    if [ "$payload" != "-" ]; then
      printf "printf '%%s' '%s' | %s bash '%s' 2>'%s'\n" "$payload" "${HOOK_ENV:-}" "$HOOK" "$TMP/$name.err"
      printf ": > '%s'\n" "$TMP/$name.done"
    fi
    printf 'sleep 30\n'
  } > "$TMP/$name.sh"
}
start_host() {
  # start_host <script> [extra host args...]
  "$HOST" "$@" >/dev/null 2>&1 &
  SPAWNED+=("$!")
  disown "$!" 2>/dev/null || true
  LAST_HOST=$!
}
wait_done() { local i=0; while [ ! -e "$TMP/$1.done" ] && [ "$i" -lt 150 ]; do sleep 0.1; i=$((i + 1)); done; [ -e "$TMP/$1.done" ]; }
helper_line() { printf "'%s' '%s' %s &" "$1" "$2" "${3:-}"; }

# ---------------------------------------------------------------------------
echo "[0] registration: SessionEnd, not Stop"
jq -e '[.hooks.Stop[]?.hooks[]? | select(.id == "cleanup-mcp-processes")] | length == 0' "$REGISTRY" >/dev/null \
  || fail "cleanup-mcp-processes is still registered for Stop (fires every turn)"
jq -e '[.hooks.SessionEnd[]?.hooks[]? | select(.id == "cleanup-mcp-processes")] | length == 1' "$REGISTRY" >/dev/null \
  || fail "cleanup-mcp-processes is not registered for SessionEnd"
pass "registered for SessionEnd only"

# ---------------------------------------------------------------------------
echo "[A] no session host in the chain: nothing is signalled"
"$TMP/bin/agent-browser" "$TMP/a.pid" >/dev/null 2>&1 &
SPAWNED+=("$!"); disown "$!" 2>/dev/null || true
wait_for_file "$TMP/a.pid" || fail "fixture A did not start"
a_helper="$(cat "$TMP/a.pid")"
printf '{"reason":"other"}' | bash "$HOOK" 2>"$TMP/a.err"
sleep 1.5
alive "$a_helper" || fail "A: helper killed with no identifiable owner"
grep -q 'owner not identified' "$TMP/a.err" || fail "A: diagnostic missing: $(cat "$TMP/a.err")"
pass "fails closed without an owner"

# ---------------------------------------------------------------------------
echo "[D] own helper is stopped on an exit reason; [C] sibling session helper survives"
session_script sib - "$(helper_line "$TMP/bin/agent-browser" "$TMP/c.pid")"
start_host "$TMP/sib.sh"
session_script own '{"reason":"prompt_input_exit"}' "$(helper_line "$TMP/bin/slack-mcp/src/server.ts" "$TMP/d.pid")"
start_host "$TMP/own.sh"
own_host="$LAST_HOST"
wait_for_file "$TMP/c.pid" || fail "fixture C did not start"
wait_for_file "$TMP/d.pid" || fail "fixture D did not start"
c_helper="$(cat "$TMP/c.pid")"; d_helper="$(cat "$TMP/d.pid")"
wait_done own || fail "D: hook did not finish: $(cat "$TMP/own.err" 2>/dev/null)"
died_within "$d_helper" || fail "D: own helper survived session exit"
alive "$c_helper" || fail "C: sibling session's helper was killed"
alive "$own_host" || fail "D: the session host itself was signalled"
grep -q 'signalled=1' "$TMP/own.err" || fail "D: report missing signalled=1: $(cat "$TMP/own.err")"
pass "own helper stopped, sibling helper and host untouched"

# ---------------------------------------------------------------------------
echo "[I] /clear (reason=clear) signals nothing"
session_script clr '{"reason":"clear"}' "$(helper_line "$TMP/bin/agent-browser" "$TMP/i.pid")"
start_host "$TMP/clr.sh"
wait_for_file "$TMP/i.pid" || fail "fixture I did not start"
i_helper="$(cat "$TMP/i.pid")"
wait_done clr || fail "I: hook did not finish"
sleep 1.5
alive "$i_helper" || fail "I: helper killed on /clear"
grep -q 'reason=clear; not a session exit' "$TMP/clr.err" || fail "I: diagnostic missing"
pass "clear skipped"

echo "[I2] missing reason (a Stop-shaped payload) signals nothing"
session_script nor '{}' "$(helper_line "$TMP/bin/agent-browser" "$TMP/i2.pid")"
start_host "$TMP/nor.sh"
wait_for_file "$TMP/i2.pid" || fail "fixture I2 did not start"
i2_helper="$(cat "$TMP/i2.pid")"
wait_done nor || fail "I2: hook did not finish"
sleep 1.5
alive "$i2_helper" || fail "I2: helper killed without an exit reason"
pass "missing reason fails closed"

# ---------------------------------------------------------------------------
echo "[H] server-mode owner signals nothing"
session_script srv '{"reason":"other"}' "$(helper_line "$TMP/bin/agent-browser" "$TMP/h.pid")"
start_host "$TMP/srv.sh" app-server
wait_for_file "$TMP/h.pid" || fail "fixture H did not start"
h_helper="$(cat "$TMP/h.pid")"
wait_done srv || fail "H: hook did not finish"
sleep 1.5
alive "$h_helper" || fail "H: helper killed under a server-mode owner"
grep -q 'server-mode host' "$TMP/srv.err" || fail "H: diagnostic missing: $(cat "$TMP/srv.err")"
pass "server-mode owner fails closed"

# ---------------------------------------------------------------------------
echo "[B] owner shared with another host below it signals nothing"
session_script nested - "$(helper_line "$TMP/bin/agent-browser" "$TMP/b-nested.pid")"
session_script shr '{"reason":"other"}' \
  "'$HOST' '$TMP/nested.sh' &" \
  "$(helper_line "$TMP/bin/agent-browser" "$TMP/b.pid")"
start_host "$TMP/shr.sh"
wait_for_file "$TMP/b.pid" || fail "fixture B did not start"
wait_for_file "$TMP/b-nested.pid" || fail "fixture B nested did not start"
b_helper="$(cat "$TMP/b.pid")"; b_nested="$(cat "$TMP/b-nested.pid")"
wait_done shr || fail "B: hook did not finish"
sleep 1.5
alive "$b_helper" || fail "B: helper killed under a shared owner"
alive "$b_nested" || fail "B: nested host's helper killed"
grep -q 'shared with another session host' "$TMP/shr.err" || fail "B: diagnostic missing: $(cat "$TMP/shr.err")"
pass "shared owner fails closed"

# ---------------------------------------------------------------------------
echo "[E] protected workflow runners survive; [E2] helpers under them survive"
for runner in workflow-runner.mjs ultracode-workflow.mjs codex-workflow.mjs; do
  tag="e-${runner%%.*}"
  session_script "$tag" '{"reason":"other"}' \
    "'$TMP/bin/$runner' '$TMP/bin/agent-browser' '$TMP/$tag.pid' &" \
    "printf '%s' \$! > '$TMP/$tag.runner'"
  start_host "$TMP/$tag.sh"
  wait_for_file "$TMP/$tag.pid" || fail "fixture $tag did not start"
  e_helper="$(cat "$TMP/$tag.pid")"
  wait_done "$tag" || fail "$tag: hook did not finish"
  e_runner="$(cat "$TMP/$tag.runner")"
  sleep 1.5
  alive "$e_runner" || fail "E: $runner killed"
  alive "$e_helper" || fail "E2: helper under $runner killed"
  pass "$runner and its helper survived"
done

# ---------------------------------------------------------------------------
echo "[F1] identity change between collection and TERM is not signalled"
# Run the hook with a pause inside this host so the test can re-exec the helper
# after it was collected.
{
  printf '#!/usr/bin/env bash\n'
  printf '%s\n' "$(helper_line "$TMP/bin/agent-browser" "$TMP/f1.pid" "exec-on-trigger '$TMP/f1.trigger'")"
  printf 'sleep 0.5\n'
  printf "printf '%%s' '{\"reason\":\"other\"}' | HQ_CLEANUP_TEST_PAUSE_SECONDS=2 HQ_CLEANUP_TEST_COLLECTED_FILE='%s' bash '%s' 2>'%s'\n" "$TMP/f1.collected" "$HOOK" "$TMP/f1.err"
  printf ": > '%s'\n" "$TMP/f1.done"
  printf 'sleep 30\n'
} > "$TMP/f1.sh"
start_host "$TMP/f1.sh"
wait_for_file "$TMP/f1.pid" || fail "fixture F1 did not start"
f1_helper="$(cat "$TMP/f1.pid")"
i=0; while [ ! -e "$TMP/f1.collected" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
[ -e "$TMP/f1.collected" ] || fail "F1: hook never reached collection"
: > "$TMP/f1.trigger"
wait_done f1 || fail "F1: hook did not finish"
sleep 1.5
alive "$f1_helper" || fail "F1: re-exec'd pid was signalled after its identity changed"
grep -q 'reused=1' "$TMP/f1.err" || fail "F1: report missing reused=1: $(cat "$TMP/f1.err")"
pass "identity change before TERM skipped"

echo "[F2] identity change between TERM and KILL is not force-killed"
session_script f2 '{"reason":"other"}' "$(helper_line "$TMP/bin/agent-browser" "$TMP/f2.pid" term-exec)"
start_host "$TMP/f2.sh"
wait_for_file "$TMP/f2.pid" || fail "fixture F2 did not start"
f2_helper="$(cat "$TMP/f2.pid")"
wait_done f2 || fail "F2: hook did not finish"
sleep 1.5
alive "$f2_helper" || fail "F2: KILL sent although the identity changed after TERM"
pass "identity change before KILL skipped"

# ---------------------------------------------------------------------------
echo "[G] temp sweep removes only old files of dead pids"
mkdir -p "$TMP/sweep"
sleep 60 & live_pid=$!; SPAWNED+=("$live_pid"); disown "$live_pid" 2>/dev/null || true
dead_pid=999999; while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid - 1)); done
old_ts="$(date -v-2H +%Y%m%d%H%M 2>/dev/null || date -d '2 hours ago' +%Y%m%d%H%M)"
touch -t "$old_ts" "$TMP/sweep/hq-checkpoint-last-$live_pid" "$TMP/sweep/hq-checkpoint-last-$dead_pid" "$TMP/sweep/hq-screenshot-count-$dead_pid"
touch "$TMP/sweep/hq-screenshot-count-$((dead_pid - 1))"
printf '{"reason":"clear"}' | HQ_CLEANUP_TMP_DIR="$TMP/sweep" bash "$HOOK" 2>/dev/null
[ -e "$TMP/sweep/hq-checkpoint-last-$live_pid" ] || fail "G: live-owner file removed"
[ -e "$TMP/sweep/hq-screenshot-count-$((dead_pid - 1))" ] || fail "G: recent file removed"
[ ! -e "$TMP/sweep/hq-checkpoint-last-$dead_pid" ] || fail "G: old dead-owner checkpoint file kept"
[ ! -e "$TMP/sweep/hq-screenshot-count-$dead_pid" ] || fail "G: old dead-owner screenshot file kept"
pass "temp sweep scoped to old files of dead pids"

# ---------------------------------------------------------------------------
echo "[5] a process that only MENTIONS a pattern in an argument is not matched"
cat > "$TMP/bin/ordinary-task" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$1"
sleep 30
SH
chmod +x "$TMP/bin/ordinary-task"
session_script men '{"reason":"other"}' "'$TMP/bin/ordinary-task' '$TMP/men.pid' --note 'install agent-browser later' &"
start_host "$TMP/men.sh"
wait_for_file "$TMP/men.pid" || fail "fixture 5 did not start"
m_pid="$(cat "$TMP/men.pid")"
wait_done men || fail "5: hook did not finish"
sleep 1.5
alive "$m_pid" || fail "the hook matched a pattern mentioned in an argument"
pass "argument mention did not match"

# ---------------------------------------------------------------------------
echo "[T] bounded process-table work: two snapshots, no per-row grep"
mkdir -p "$TMP/counting-bin"
PS_TABLE_CALLS="$TMP/ps-table-calls"; GREP_CALLS="$TMP/grep-calls"
: > "$PS_TABLE_CALLS"; : > "$GREP_CALLS"
cat > "$TMP/counting-bin/ps" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = "-A" ] && printf 'table\n' >> "$PS_TABLE_CALLS"
exec "$REAL_PS" "$@"
SH
cat > "$TMP/counting-bin/grep" <<'SH'
#!/usr/bin/env bash
printf 'grep\n' >> "$GREP_CALLS"
exec "$REAL_GREP" "$@"
SH
chmod +x "$TMP/counting-bin/ps" "$TMP/counting-bin/grep"
HOOK_ENV="env PATH='$TMP/counting-bin:$PATH' PS_TABLE_CALLS='$PS_TABLE_CALLS' GREP_CALLS='$GREP_CALLS' REAL_PS='$(command -v ps)' REAL_GREP='$(command -v grep)'" \
  session_script cnt '{"reason":"other"}' ":"
start_host "$TMP/cnt.sh"
wait_done cnt || fail "T: hook did not finish: $(cat "$TMP/cnt.err" 2>/dev/null)"
table_calls="$(wc -l < "$PS_TABLE_CALLS" | tr -d ' ')"
grep_calls="$(wc -l < "$GREP_CALLS" | tr -d ' ')"
[ "$table_calls" -eq 2 ] || fail "T: expected two process-table snapshots, got $table_calls"
[ "$grep_calls" -eq 0 ] || fail "T: expected no grep forks, got $grep_calls"
pass "two snapshots, no grep forks"

# ---------------------------------------------------------------------------
echo "[7] the hook contains no machine-wide pattern sweep"
CODE="$TMP/hook-code.sh"
sed 's/[[:space:]]*#.*$//' "$HOOK" > "$CODE"
if grep -qE '\bpkill\b|\bkillall\b' "$CODE"; then fail "hook reintroduced pkill/killall"; fi
if grep -qE '\bpgrep\b' "$CODE"; then fail "hook reintroduced a pgrep sweep"; fi
grep -q 'no-machine-wide-process-pattern-kills' "$HOOK" || fail "hook lost its pointer to the governing policy"
pass "no pkill/killall/pgrep sweep"

echo "cleanup-mcp session scoping: ok"
