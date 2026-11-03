#!/usr/bin/env bash
# master-hook-parallel-signal-cleanup.test.sh
#
# With HQ_HOOK_PARALLEL=1, master-hook keeps each child's stdout, stderr, exit
# code and marker in "*.par.*" result files (beside the completion markers in
# workspace/.hook-timeout-completions, or in a hq-par.* temp dir). A TERM or
# INT that arrives while a child is still running must not leave those files
# behind, since they hold hook output.
#
# Cases: SIGTERM alone, SIGINT alone, and SIGTERM followed by SIGINT, each sent
# to master-hook while a 30 s child is running.
#
# SIGKILL cannot be trapped, so a killed run leaves its files. A later
# master-hook run removes result files and hq-par.* temp dirs that are stale:
# the owner PID does not exist and the file is older than the stale bound
# (60 min). Names from before the owner PID was added are removed by age
# alone. Cases, in both dispatch modes:
#   - a killed run's fresh files stay (a run whose PID the sweeper cannot see,
#     e.g. in another PID namespace, looks exactly like this); once aged past
#     the bound they are removed
#   - an old file of a live owner stays; an old file whose owner answers
#     kill -0 with anything but "No such process" (EPERM) stays
#   - an old pre-PID name is removed, a recent one stays
#   - a live parallel run keeps its verdict while a run that cannot see its
#     PID ("No such process") sweeps the same workspace mid-dispatch
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
MASTER="$ROOT/.claude/hooks/master-hook.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

[ -f "$MASTER" ] || fail "missing $MASTER"
command -v jq >/dev/null 2>&1 || fail "jq is required"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mh-par-signal.XXXXXX")"
cleanup() {
  [ -z "${MPID:-}" ] || kill -KILL "$MPID" 2>/dev/null || true
  pkill -f "$TMP/" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

BASH_BIN="${MASTER_HOOK_PARALLEL_BASH:-$(command -v bash)}"
bash_ok="$("$BASH_BIN" -c '[ "${BASH_VERSINFO[0]}" -gt 5 ] || { [ "${BASH_VERSINFO[0]}" -eq 5 ] && [ "${BASH_VERSINFO[1]}" -ge 1 ]; } && echo 1 || echo 0')"
[ "$bash_ok" = 1 ] || fail "$BASH_BIN is older than bash 5.1; set MASTER_HOOK_PARALLEL_BASH to a bash 5.1+ binary"

FIX="$TMP/root"
H="$FIX/.claude/hooks"
ST="$TMP/state"
SCRATCH="$TMP/scratch"
mkdir -p "$H" "$FIX/core/scripts/lib" "$FIX/workspace" "$ST" "$SCRATCH"
cp "$MASTER" "$H/master-hook.sh"
cp "$ROOT/.claude/hooks/hook-gate.sh" "$H/hook-gate.sh"
cp "$ROOT/.claude/hooks/hook-timeout-probe.sh" "$H/hook-timeout-probe.sh"
cp "$ROOT/.claude/hooks/hook-timeout-watchdog.sh" "$H/hook-timeout-watchdog.sh"
cp "$ROOT/core/scripts/lib/hook-adapter-core.sh" "$FIX/core/scripts/lib/hook-adapter-core.sh"
[ ! -f "$ROOT/core/scripts/lib/advisory-cap.sh" ] || cp "$ROOT/core/scripts/lib/advisory-cap.sh" "$FIX/core/scripts/lib/advisory-cap.sh"
[ ! -f "$ROOT/core/scripts/resolve-hq-root.sh" ] || cp "$ROOT/core/scripts/resolve-hq-root.sh" "$FIX/core/scripts/resolve-hq-root.sh"
chmod +x "$H/master-hook.sh" "$H/hook-gate.sh"

stub() { # <path> <body>: executable hook that drains stdin first
  printf '#!/usr/bin/env bash\ncat >/dev/null\n%s\n' "$2" > "$1"
  chmod +x "$1"
}
stub "$H/fast.sh" 'echo "fast output"'
stub "$H/slow.sh" 'echo "slow output"; : > "'"$ST"'/slow.started"; sleep 30'

cat > "$H/hook-registry.json" <<'JSON'
{
  "$schema": "hq-hook-registry@1",
  "description": "fixture",
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [
        {"id": "fast", "script": ".claude/hooks/fast.sh", "gated": false},
        {"id": "slow", "script": ".claude/hooks/slow.sh", "gated": false, "timeout": 60}
      ]}
    ]
  }
}
JSON

payload() {
  printf '{"session_id":"par-signal","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo hi"},"cwd":"%s"}' "$FIX"
}

leftovers() {
  find "$FIX/workspace" "$SCRATCH" \( -name '*.par.*' -o -name 'hq-par.*' \) 2>/dev/null || true
}

# run_case <label> <signal...>
run_case() {
  local label="$1" sig waited=0
  shift
  rm -f "$ST/slow.started"
  payload > "$TMP/in.json"
  # A non-interactive shell starts background jobs with SIGINT ignored, and a
  # signal ignored at entry cannot be trapped. Job control (set -m) starts the
  # job with default dispositions, as when a host runs the hook directly.
  set -m
  env -i "HOME=$TMP" "PATH=$PATH" "TMPDIR=$SCRATCH" "HQ_ROOT=$FIX" "CLAUDE_PROJECT_DIR=$FIX" \
    "BASH_ENV=/dev/null" "HQ_HOOK_TIMEOUT_SENTRY=0" "HQ_HOOK_PARALLEL=1" \
    "$BASH_BIN" "$H/master-hook.sh" PreToolUse <"$TMP/in.json" >"$TMP/$label.out" 2>"$TMP/$label.err" &
  MPID=$!
  set +m
  while [ ! -e "$ST/slow.started" ]; do
    waited=$((waited + 1))
    [ "$waited" -le 200 ] || fail "$label: slow child never started"
    sleep 0.05
  done
  # Let the fast child finish so its result files exist too.
  sleep 0.5
  [ -n "$(leftovers)" ] || fail "$label: no parallel result files seen mid-dispatch (fixture is not exercising the parallel path)"
  for sig in "$@"; do
    kill -s "$sig" "$MPID" 2>/dev/null || true
    sleep 0.2
  done
  waited=0
  while kill -0 "$MPID" 2>/dev/null; do
    waited=$((waited + 1))
    [ "$waited" -le 100 ] || { kill -KILL "$MPID" 2>/dev/null || true; fail "$label: master-hook still running 10 s after $*"; }
    sleep 0.1
  done
  wait "$MPID" 2>/dev/null || true
  MPID=""
  sleep 0.3
  local left
  left="$(leftovers)"
  [ -z "$left" ] || fail "$label: parallel result files left after $*: $left"
  pass "$label: no .par.* result files remain after $*"
}

run_case term TERM
run_case int INT
run_case term-int TERM INT

COMPLETIONS="$FIX/workspace/.hook-timeout-completions"

# A PID that no longer belongs to any process.
dead_pid() {
  local pid
  sleep 0 &
  pid=$!
  wait "$pid" 2>/dev/null || true
  printf '%s' "$pid"
}

# age <path...>: set mtime two hours back, past the 60 min stale bound.
age() { perl -e 'my $t = time - 7200; utime($t, $t, @ARGV) == @ARGV or exit 1' "$@"; }

# sweep_run <label> <flag> [bash_env]: one quick master-hook run that matches
# no child (tool Read), so only the start-of-run sweep touches the files.
sweep_run() {
  local label="$1" flag="$2" bash_env="${3:-/dev/null}"
  printf '{"session_id":"par-signal","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/dev/null"},"cwd":"%s"}' \
    "$FIX" > "$TMP/sweep-in.json"
  env -i "HOME=$TMP" "PATH=$PATH" "TMPDIR=$SCRATCH" "HQ_ROOT=$FIX" "CLAUDE_PROJECT_DIR=$FIX" \
    "BASH_ENV=$bash_env" "HQ_HOOK_TIMEOUT_SENTRY=0" "HQ_HOOK_PARALLEL=$flag" \
    "$BASH_BIN" "$H/master-hook.sh" PreToolUse <"$TMP/sweep-in.json" >"$TMP/$label.out" 2>"$TMP/$label.err" || true
}

# killed_files: result files of killed runs (not the decoys below).
killed_files() {
  find "$FIX/workspace" "$SCRATCH" \( -name '*.par.*' -o -name 'hq-par.*' \) \
    ! -name 'decoy-*' 2>/dev/null || true
}

# run_kill_case <label> <sweep-flag>: SIGKILL master-hook mid-dispatch, then
# check what the next runs (flag on or off) keep and remove.
run_kill_case() {
  local label="$1" sweep_flag="$2" waited=0 left f dead
  rm -f "$ST/slow.started"
  payload > "$TMP/in.json"
  set -m
  env -i "HOME=$TMP" "PATH=$PATH" "TMPDIR=$SCRATCH" "HQ_ROOT=$FIX" "CLAUDE_PROJECT_DIR=$FIX" \
    "BASH_ENV=/dev/null" "HQ_HOOK_TIMEOUT_SENTRY=0" "HQ_HOOK_PARALLEL=1" \
    "$BASH_BIN" "$H/master-hook.sh" PreToolUse <"$TMP/in.json" >"$TMP/$label.out" 2>"$TMP/$label.err" &
  MPID=$!
  set +m
  while [ ! -e "$ST/slow.started" ]; do
    waited=$((waited + 1))
    [ "$waited" -le 200 ] || fail "$label: slow child never started"
    sleep 0.05
  done
  sleep 0.5
  [ -n "$(leftovers)" ] || fail "$label: no parallel result files seen mid-dispatch (fixture is not exercising the parallel path)"
  # Kill the whole job: master-hook, its dispatch subshells and the hooks, as a
  # host that kills the process group would. Nothing is left to write later.
  kill -KILL -- "-$MPID" 2>/dev/null || kill -KILL "$MPID" 2>/dev/null || true
  wait "$MPID" 2>/dev/null || true
  MPID=""
  sleep 0.3
  [ -n "$(killed_files)" ] || fail "$label: SIGKILL left no result files, so the sweep is not being tested"

  dead="$(dead_pid)"
  # Old, owner alive (this test shell): keep.
  : > "$COMPLETIONS/decoy-live.par.$$.0.out"
  # Old, owner answers kill -0 with EPERM or is alive (PID 1): keep.
  : > "$COMPLETIONS/decoy-eperm.par.1.0.out"
  # Old pre-PID name: remove. Recent pre-PID name: keep.
  : > "$COMPLETIONS/decoy-oldform-aged.par.0.out"
  : > "$COMPLETIONS/decoy-oldform-recent.par.0.out"
  # Recent, owner gone (or in a namespace the sweeper cannot see): keep.
  : > "$COMPLETIONS/decoy-recent-dead.par.$dead.0.out"
  # Old, owner gone: remove.
  : > "$COMPLETIONS/decoy-aged-dead.par.$dead.0.out"
  age "$COMPLETIONS/decoy-live.par.$$.0.out" "$COMPLETIONS/decoy-eperm.par.1.0.out" \
    "$COMPLETIONS/decoy-oldform-aged.par.0.out" "$COMPLETIONS/decoy-aged-dead.par.$dead.0.out"

  # 1. The killed run's files are recent: the next run keeps them.
  sweep_run "$label-sweep-recent" "$sweep_flag"
  [ -n "$(killed_files)" ] || fail "$label: the sweep removed a recent result file (its owner may be a live run the sweeper cannot see)"
  [ -e "$COMPLETIONS/decoy-recent-dead.par.$dead.0.out" ] \
    || fail "$label: the sweep removed a recent file whose owner PID it cannot see"
  [ ! -e "$COMPLETIONS/decoy-aged-dead.par.$dead.0.out" ] \
    || fail "$label: the sweep kept an old file whose owner is gone"
  [ ! -e "$COMPLETIONS/decoy-oldform-aged.par.0.out" ] \
    || fail "$label: the sweep kept an old result file name from before the owner PID was added"
  [ -e "$COMPLETIONS/decoy-oldform-recent.par.0.out" ] \
    || fail "$label: the sweep removed a recent result file name from before the owner PID was added"
  [ -e "$COMPLETIONS/decoy-live.par.$$.0.out" ] || fail "$label: the sweep removed an old file whose owner is running"
  [ -e "$COMPLETIONS/decoy-eperm.par.1.0.out" ] \
    || fail "$label: the sweep removed an old file whose owner kill -0 could not rule out (EPERM)"

  # 2. Once aged past the bound, the next run removes the killed run's files.
  while IFS= read -r f; do [ -z "$f" ] || age "$f"; done <<< "$(killed_files)"
  sweep_run "$label-sweep-aged" "$sweep_flag"
  left="$(killed_files)"
  [ -z "$left" ] || fail "$label: files of the killed run left after they aged past the bound (HQ_HOOK_PARALLEL=$sweep_flag): $left"
  rm -f "$COMPLETIONS"/decoy-*
  pass "$label: HQ_HOOK_PARALLEL=$sweep_flag sweep keeps recent and live-owner files, removes aged files of a SIGKILLed run"
}

run_kill_case kill-then-par 1
run_kill_case kill-then-seq 0

# A live parallel run and a run that cannot see its PID share the workspace.
# The foreign run's kill -0 reports "No such process" for every PID, so only
# the age bound protects the live run's results. The live run must keep its
# allow verdict (no fail-closed block for a missing result).
cat > "$H/allow-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
exit 0
SH
cat > "$H/slow3.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
sleep 3
exit 0
SH
chmod +x "$H/allow-guard.sh" "$H/slow3.sh"
cp "$H/hook-registry.json" "$TMP/registry.saved"
cat > "$H/hook-registry.json" <<'JSON'
{
  "$schema": "hq-hook-registry@1",
  "description": "fixture",
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [
        {"id": "allow-guard", "script": ".claude/hooks/allow-guard.sh", "gated": false},
        {"id": "slow3", "script": ".claude/hooks/slow3.sh", "gated": false, "timeout": 60}
      ]}
    ]
  }
}
JSON
rm -rf "$FIX/workspace/orchestrator/hook-state/registry-rows"
cat > "$TMP/foreign-ns.env" <<'ENV'
kill() {
  if [ "${1:-}" = "-0" ]; then
    printf 'bash: kill: (%s) - No such process\n' "${2:-}" >&2
    return 1
  fi
  builtin kill "$@"
}
ENV
payload > "$TMP/xns-in.json"
xns_rc=0
env -i "HOME=$TMP" "PATH=$PATH" "TMPDIR=$SCRATCH" "HQ_ROOT=$FIX" "CLAUDE_PROJECT_DIR=$FIX" \
  "BASH_ENV=/dev/null" "HQ_HOOK_TIMEOUT_SENTRY=0" "HQ_HOOK_PARALLEL=1" \
  "$BASH_BIN" "$H/master-hook.sh" PreToolUse <"$TMP/xns-in.json" >"$TMP/xns.out" 2>"$TMP/xns.err" &
xns_pid=$!
waited=0
until compgen -G "$COMPLETIONS/*.par.*.rc" >/dev/null 2>&1; do
  waited=$((waited + 1))
  [ "$waited" -le 100 ] || { kill "$xns_pid" 2>/dev/null || true; fail "xns: the fast guard never wrote its result"; }
  sleep 0.05
done
sweep_run xns-sweep-flag-off 0 "$TMP/foreign-ns.env"
sweep_run xns-sweep-flag-on 1 "$TMP/foreign-ns.env"
wait "$xns_pid" || xns_rc=$?
[ "$xns_rc" -eq 0 ] || fail "xns: the live run returned $xns_rc after a foreign-namespace sweep (stderr: $(head -c 300 "$TMP/xns.err"))"
! grep -q 'BLOCKED' "$TMP/xns.err" || fail "xns: the live run blocked after a foreign-namespace sweep: $(head -c 300 "$TMP/xns.err")"
cp "$TMP/registry.saved" "$H/hook-registry.json"
rm -rf "$FIX/workspace/orchestrator/hook-state/registry-rows"
pass "xns: a live parallel run keeps its allow verdict while a run that cannot see its PID sweeps the workspace"

# Temp-dir fallback: with the marker dir unusable, results go to a
# hq-par.<pid>.* dir under TMPDIR. A parallel run that needs the fallback
# removes old dirs of a gone owner and old pre-PID dirs, and keeps a live
# owner's dir and a recent dir of a gone owner.
dead="$(dead_pid)"
mkdir -p "$SCRATCH/hq-par.$dead.stale1" "$SCRATCH/hq-par.$dead.recent1" "$SCRATCH/hq-par.$$.live1" "$SCRATCH/hq-par.Ab12Cd"
: > "$SCRATCH/hq-par.$dead.stale1/0.out"
age "$SCRATCH/hq-par.$dead.stale1" "$SCRATCH/hq-par.$$.live1" "$SCRATCH/hq-par.Ab12Cd"
# A plain file where the marker dir belongs makes it unusable, also for root
# (a read-only dir is still writable for root).
rm -rf "$COMPLETIONS"
: > "$COMPLETIONS"
sweep_run tmp-sweep 1
rm -f "$COMPLETIONS"
[ ! -e "$SCRATCH/hq-par.$dead.stale1" ] || fail "tmp-sweep: an old hq-par dir of a gone owner was not removed"
[ ! -e "$SCRATCH/hq-par.Ab12Cd" ] || fail "tmp-sweep: an old pre-PID hq-par dir was not removed"
[ -d "$SCRATCH/hq-par.$dead.recent1" ] || fail "tmp-sweep: a recent hq-par dir was removed"
[ -d "$SCRATCH/hq-par.$$.live1" ] || fail "tmp-sweep: a live owner's hq-par dir was removed"
rm -rf "$SCRATCH/hq-par.$dead.recent1" "$SCRATCH/hq-par.$$.live1"
left="$(leftovers)"
[ -z "$left" ] || fail "tmp-sweep: files left after the fallback run: $left"
pass "tmp-sweep: the temp-dir fallback removes old stale hq-par dirs and keeps recent and live ones"

echo "PASS: master-hook parallel signal cleanup"
