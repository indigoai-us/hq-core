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

echo "PASS: master-hook parallel signal cleanup"
