#!/usr/bin/env bash
# Regression: the Stop-hook MCP cleanup must never kill another owner's work.
#
# HQ runs a shared multi-agent fleet. This hook used to `pgrep -f <pattern>` the
# whole machine and SIGTERM/SIGKILL every match, which reaps other operators'
# sessions and live Agency/Codex workers. See hard policy
# `no-machine-wide-process-pattern-kills`.
#
# Each case spawns a real process, runs the real hook, and checks who survived.

set -uo pipefail

CORE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT="$(cd "$CORE_ROOT/.." && pwd)"
HOOK="$ROOT/.claude/hooks/cleanup-mcp-processes.sh"
TMP="$(mktemp -d)"

SPAWNED=()
cleanup() {
  for p in ${SPAWNED[@]+"${SPAWNED[@]}"}; do
    kill -KILL "$p" 2>/dev/null || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok — $*"; }

alive() { kill -0 "$1" 2>/dev/null; }

# Wait for a pid to die, up to ~6s. The hook itself sleeps 2s between TERM and
# KILL, so a bounded wait keeps the test honest without being flaky.
died_within() {
  local pid="$1" i=0
  while [ "$i" -lt 60 ]; do
    alive "$pid" || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

run_hook() { printf '{}' | bash "$HOOK" >/dev/null 2>&1; }

mkdir -p "$TMP/bin" "$TMP/bin/slack-mcp/src"
# Stand-ins for the real MCP servers: scripts at the paths the hook matches.
# Each records its own pid so a detached one can still be identified.
make_fixture() {
  cat > "$1" <<'FIXTURE'
#!/usr/bin/env bash
[ -n "${1:-}" ] && printf '%s' "$$" > "$1"
sleep 30
FIXTURE
  chmod +x "$1"
}
make_fixture "$TMP/bin/agent-browser"
make_fixture "$TMP/bin/detached-flush.js"
make_fixture "$TMP/bin/slack-mcp/src/server.ts"

# Both spawners publish to $SPAWN_PID rather than stdout. A command
# substitution would run the spawner in a subshell that exits immediately,
# orphaning the "child" and quietly turning every in-tree case into a
# foreign one — which is exactly the distinction under test.
SPAWN_PID=""

# Spawn as our own child — a descendant of this test, like a session's own
# stdio MCP server.
spawn_child() {
  bash "$@" >/dev/null 2>&1 &
  SPAWN_PID=$!
  SPAWNED+=("$SPAWN_PID")
  # Detach from job control so the shell does not print "Killed" notices when
  # the hook (or the exit trap) reaps these fixtures.
  disown "$SPAWN_PID" 2>/dev/null || true
}

# Spawn so it is NOT our descendant: the inner subshell exits, orphaning the
# process so the kernel reparents it away from this test — the shape of
# another owner's work.
spawn_detached() {
  local script="$1" pidfile="$2" i=0
  rm -f "$pidfile"
  ( setsid bash "$script" "$pidfile" >/dev/null 2>&1 & ) &
  while [ ! -s "$pidfile" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  SPAWN_PID="$(cat "$pidfile" 2>/dev/null)"
  [ -n "$SPAWN_PID" ] && SPAWNED+=("$SPAWN_PID")
}

# ---------------------------------------------------------------------------
echo "[1] a matching process outside this session's tree is left alone"
spawn_detached "$TMP/bin/agent-browser" "$TMP/foreign.pid"
foreign="$SPAWN_PID"
[ -n "$foreign" ] || fail "fixture: foreign process did not report a pid"
alive "$foreign" || fail "fixture: foreign process did not start"
# Prove it really is outside our tree before asserting the hook spares it.
walk="$foreign"; is_descendant=0; guard=0
while [ -n "$walk" ] && [ "$walk" -gt 1 ] 2>/dev/null && [ "$guard" -lt 64 ]; do
  [ "$walk" = "$$" ] && { is_descendant=1; break; }
  walk="$(ps -o ppid= -p "$walk" 2>/dev/null | tr -d ' ')"
  guard=$((guard + 1))
done
[ "$is_descendant" -eq 0 ] || fail "fixture: foreign process is still our descendant"
run_hook
sleep 2.5
alive "$foreign" || fail "the hook killed a process outside its own session tree"
pass "foreign match survived"

# ---------------------------------------------------------------------------
echo "[2] a matching process inside this session's tree is cleaned up"
spawn_child "$TMP/bin/agent-browser"
ours="$SPAWN_PID"
sleep 0.4
alive "$ours" || fail "fixture: in-tree process did not start"
run_hook
died_within "$ours" || fail "the hook did not clean up its own leaked server"
pass "in-tree match cleaned up"

# ---------------------------------------------------------------------------
echo "[3] the foreign process is STILL alive after a real cleanup ran"
alive "$foreign" || fail "foreign process died during an in-tree cleanup"
pass "cleanup stayed inside the session"

# ---------------------------------------------------------------------------
echo "[4] an agent workload is never killed, even in-tree"
make_fixture "$TMP/bin/codex-workflow.mjs"
# A worker whose own command line also matches an MCP pattern — exactly the
# shape that reaped live workers before.
spawn_child "$TMP/bin/codex-workflow.mjs" "$TMP/worker.pid" "--prompt" "drive $TMP/bin/agent-browser for QA"
worker="$SPAWN_PID"
sleep 0.4
alive "$worker" || fail "fixture: worker did not start"
run_hook
sleep 2.5
alive "$worker" || fail "the hook killed an agent workload"
pass "codex worker survived"

# ---------------------------------------------------------------------------
echo "[5] a process that only MENTIONS a pattern in an argument is not matched"
make_fixture "$TMP/bin/ordinary-task"
spawn_child "$TMP/bin/ordinary-task" "$TMP/mentioner.pid" "--note" "remember to install agent-browser later"
mentioner="$SPAWN_PID"
sleep 0.4
alive "$mentioner" || fail "fixture: mentioner did not start"
run_hook
sleep 2.5
alive "$mentioner" || fail "the hook matched a pattern mentioned in an argument"
pass "argument mention did not match"

# ---------------------------------------------------------------------------
echo "[6] the hook contains no machine-wide pattern sweep"
# Comments deliberately NAME the banned calls to explain why they are banned,
# so check executable lines only.
CODE="$TMP/hook-code.sh"
sed 's/[[:space:]]*#.*$//' "$HOOK" > "$CODE"
if grep -qE '\bpkill\b|\bkillall\b' "$CODE"; then
  fail "hook reintroduced pkill/killall"
fi
if grep -qE '\bpgrep\b' "$CODE"; then
  fail "hook reintroduced a pgrep sweep"
fi
grep -q 'no-machine-wide-process-pattern-kills' "$HOOK" \
  || fail "hook lost its pointer to the governing policy"
pass "no pkill/killall/pgrep sweep"

# ---------------------------------------------------------------------------
echo "[7] the header no longer claims scoping it does not implement"
if grep -q 'Use the Claude session.s PPID to find MCP server processes' "$HOOK"; then
  grep -q 'is_ours' "$HOOK" || fail "header claims PPID scoping but none is implemented"
fi
grep -q 'is_ours' "$HOOK" || fail "hook has no ownership check at all"
pass "documented behaviour matches the implementation"

echo "cleanup-mcp session scoping: ok"
