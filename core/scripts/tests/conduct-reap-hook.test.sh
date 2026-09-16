#!/usr/bin/env bash
# hq-core: public
# Regression test for core/hooks/SessionStart/40-conduct-reap.sh.
#
# Covers the three properties that make a SessionStart hook safe to add: it
# must never make the user wait, it must not run several sweeps at once when
# sessions are opened in a burst, and it must be switchable off. A sweep that
# signals processes is exactly the kind of thing that must not fire twice
# concurrently or fire on every window the user opens.
#
# Strategy: point HQ_ROOT at a throwaway tree whose conduct-reap.sh is a stub
# that records its invocations, so nothing real is ever signalled.

set -euo pipefail

SRC_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$SRC_ROOT/core/hooks/SessionStart/40-conduct-reap.sh"
[ -f "$HOOK" ] || { echo "conduct-reap-hook: skipped (hook missing)"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/core/scripts"
cat > "$TMP/core/scripts/conduct-reap.sh" <<'STUB'
#!/usr/bin/env bash
echo "invoked $*" >> "$STUB_CALLS"
sleep "${STUB_DELAY:-0}"
STUB
chmod +x "$TMP/core/scripts/conduct-reap.sh"

export HQ_ROOT="$TMP"
export STUB_CALLS="$TMP/calls"
: > "$STUB_CALLS"

fail() { echo "conduct-reap-hook.test: FAIL — $1" >&2; exit 1; }
wait_for_calls() {
  for _ in $(seq 1 60); do
    [ "$(wc -l < "$STUB_CALLS")" -ge "$1" ] && return 0
    sleep 0.1
  done
  return 1
}

# --- the hook must return immediately, even when the sweep is slow ------------
# A session start that waits on a process sweep is a hang the user feels.
export STUB_DELAY=5
start=$(date +%s)
bash "$HOOK" </dev/null >/dev/null 2>&1 || fail "hook exited non-zero"
elapsed=$(( $(date +%s) - start ))
[ "$elapsed" -le 2 ] || fail "hook blocked session start for ${elapsed}s"
wait_for_calls 1 || fail "hook never invoked the sweep"

grep -q -- '--apply --kill' "$STUB_CALLS" || fail "sweep was not invoked in its acting mode: $(cat "$STUB_CALLS")"
grep -q -- '--min-age' "$STUB_CALLS" || fail "sweep was invoked without an age gate: $(cat "$STUB_CALLS")"

# --- a burst of sessions must not start a second concurrent sweep -------------
before="$(wc -l < "$STUB_CALLS")"
bash "$HOOK" </dev/null >/dev/null 2>&1 || fail "hook exited non-zero during burst"
sleep 1
[ "$(wc -l < "$STUB_CALLS")" -eq "$before" ] \
  || fail "a second session start ran a concurrent sweep"

# Let the first sweep finish and release its lock.
for _ in $(seq 1 100); do [ -d "$TMP/workspace/tmp/conduct-reap/.lock" ] || break; sleep 0.2; done
[ -d "$TMP/workspace/tmp/conduct-reap/.lock" ] && fail "sweep did not release its lock"

# --- and must not re-sweep on every session within the dedupe window ----------
before="$(wc -l < "$STUB_CALLS")"
export STUB_DELAY=0
bash "$HOOK" </dev/null >/dev/null 2>&1 || fail "hook exited non-zero after sweep"
sleep 1
[ "$(wc -l < "$STUB_CALLS")" -eq "$before" ] \
  || fail "hook re-swept inside the dedupe window"

# --- the off switch must work ------------------------------------------------
rm -f "$TMP/workspace/tmp/conduct-reap/.last-sweep"
before="$(wc -l < "$STUB_CALLS")"
HQ_DISABLED_HOOKS=conduct-reap bash "$HOOK" </dev/null >/dev/null 2>&1 || fail "disabled hook exited non-zero"
sleep 0.5
[ "$(wc -l < "$STUB_CALLS")" -eq "$before" ] || fail "HQ_DISABLED_HOOKS did not disable the sweep"

echo "conduct-reap-hook.test: PASS"
