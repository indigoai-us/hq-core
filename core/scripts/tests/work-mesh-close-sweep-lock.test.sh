#!/usr/bin/env bash
# hq-core: public
# Regression: SessionStart leftover 36-work-mesh-sweep.sh nohup'd a new
# __sweep_bg__ on every invocation with no process lock, timeout, or cooldown.
# Overlapping jq scans of a large spool pinned agent boxes (Mercer: 329
# processes, load ~106 on 2 vCPUs). This suite asserts the bounded sweep:
# cheap empty-spool exit, single-flight lock with stale reclaim, cooldown
# skip, and a hard timeout that always releases the lock.
#
# Hermetic: leftover work-mesh-lib.sh is stubbed (that file stays deleted from
# the release; boxes still have a drifted copy). bash-3.2 + CI compatible.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SRC_HOOK="$REPO_ROOT/core/hooks/work-mesh-close.sh"
[ -f "$SRC_HOOK" ] || { echo "FATAL: missing $SRC_HOOK" >&2; exit 1; }

bash -n "$SRC_HOOK"
echo "  ok:   bash -n work-mesh-close.sh"

SANDBOX="$(mktemp -d)"
cleanup() {
  local i=0
  rm -rf "$SANDBOX" 2>/dev/null || true
  while [ -d "$SANDBOX" ] && [ "$i" -lt 40 ]; do
    sleep 0.05; rm -rf "$SANDBOX" 2>/dev/null || true; i=$((i + 1))
  done
}
trap cleanup EXIT

mkdir -p "$SANDBOX/core/hooks" "$SANDBOX/core/scripts" \
         "$SANDBOX/workspace/sessions" "$SANDBOX/workspace/metrics" \
         "$SANDBOX/workspace/logs" "$SANDBOX/workspace/work-mesh"

cp "$SRC_HOOK" "$SANDBOX/core/hooks/work-mesh-close.sh"
chmod +x "$SANDBOX/core/hooks/work-mesh-close.sh"

# Minimal lib stub: enough for the sweep guards + a no-op body.
cat > "$SANDBOX/core/scripts/work-mesh-lib.sh" <<'LIB'
wm_hq_root() { printf '%s' "${HQ_ROOT}"; }
wm_spool_file() { printf '%s/workspace/metrics/work-sessions.jsonl' "$(wm_hq_root)"; }
wm_log_file() { printf '%s/workspace/logs/work-mesh-hook.log' "$(wm_hq_root)"; }
wm_log() { local f; f="$(wm_log_file)"; mkdir -p "$(dirname "$f")" 2>/dev/null || true; printf '%s\n' "${1:-}" >>"$f" 2>/dev/null || true; }
wm_file_mtime() {
  local f="${1:-}" value
  value="$(stat -f %m "$f" 2>/dev/null)" || value=""
  case "$value" in ''|*[!0-9]*) ;; *) printf '%s' "$value"; return 0 ;; esac
  value="$(stat -c %Y "$f" 2>/dev/null)" || value=""
  case "$value" in ''|*[!0-9]*) return 1 ;; *) printf '%s' "$value"; return 0 ;; esac
}
wm_safe_path_component() { [ -n "${1:-}" ]; }
wm_registered_slugs() {
  if [ -n "${WM_STUB_SLEEP:-}" ] && [ "${WM_STUB_SLEEP}" != "0" ]; then
    sleep "$WM_STUB_SLEEP"
  fi
  printf '%s' "${WM_STUB_SLUGS:-}"
}
wm_active_threshold() { printf '%s' "${HQ_WORK_MESH_ACTIVE_THRESHOLD_SEC:-900}"; }
wm_find_transcript() { printf ''; }
wm_reconciled_marker() { printf '%s/workspace/sessions/%s/work-mesh-reconciled-%s' "$(wm_hq_root)" "$1" "$2"; }
wm_copied_marker() { printf '%s/workspace/sessions/%s/work-mesh-copied-%s' "$(wm_hq_root)" "$1" "$2"; }
wm_terminal_marker() { printf '%s/workspace/sessions/%s/work-mesh-terminal-%s' "$(wm_hq_root)" "$1" "$2"; }
wm_sweep_claim() { printf '%s/workspace/sessions/%s/work-mesh-sweep-claim-%s' "$(wm_hq_root)" "$1" "$2"; }
wm_sweep_try_claim() { return 0; }
wm_hold_claim() { :; }
wm_release_claim() { :; }
LIB

HOOK="$SANDBOX/core/hooks/work-mesh-close.sh"
SPOOL="$SANDBOX/workspace/metrics/work-sessions.jsonl"
LOCK="$SANDBOX/workspace/work-mesh/sweep.lock"
LAST="$SANDBOX/workspace/work-mesh/sweep.last"

export HQ_ROOT="$SANDBOX"
export HOME="$SANDBOX"
export PATH="/usr/bin:/bin"

PASS=0; FAIL=0
pass()  { PASS=$((PASS + 1)); echo "  ok:   $1"; }
failc() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else failc "$1 (expected '$3', got '$2')"; fi; }
assert_true() { local l="$1"; shift; if "$@"; then pass "$l"; else failc "$l"; fi; }
assert_false() { local l="$1"; shift; if "$@"; then failc "$l (expected failure)"; else pass "$l"; fi; }

plant_work() {
  mkdir -p "$(dirname "$SPOOL")"
  printf '%s\n' '{"event":"attempt","sessionId":"sid-pending","companySlug":"indigo"}' >"$SPOOL"
}

run_sweep_bg() {
  HQ_ROOT="$SANDBOX" WM_ROOT="$SANDBOX" bash "$HOOK" __sweep_bg__ </dev/null
}

run_sweep_fg() {
  HQ_ROOT="$SANDBOX" WM_ROOT="$SANDBOX" bash "$HOOK" sweep </dev/null
}

echo "CASE 1: cheap exit when the spool is missing"
rm -f "$SPOOL" "$LAST"
rm -rf "$LOCK"
run_sweep_bg
assert_false "cheap-exit: no lock left" test -d "$LOCK"
assert_false "cheap-exit: last-run not written" test -f "$LAST"

echo "CASE 2: cheap exit when the spool has no attempt/posted lines"
printf '%s\n' '{"event":"reconciled","sessionId":"sid-x"}' >"$SPOOL"
rm -f "$LAST"
rm -rf "$LOCK"
run_sweep_bg
assert_false "cheap-exit-empty: no lock left" test -d "$LOCK"
assert_false "cheap-exit-empty: last-run not written" test -f "$LAST"

echo "CASE 3: live process lock skips a second sweep"
plant_work
rm -f "$LAST"
mkdir -p "$LOCK"
printf '%s\n' "$$" >"$LOCK/pid"
run_sweep_bg
assert_false "live-lock: skipped sweep did not write last-run" test -f "$LAST"
assert_eq "live-lock: held pid unchanged" "$(tr -dc '0-9' < "$LOCK/pid")" "$$"
rm -rf "$LOCK"

echo "CASE 4: dead-pid lock is reclaimed and the sweep completes"
plant_work
rm -f "$LAST"
mkdir -p "$LOCK"
printf '%s\n' "999999" >"$LOCK/pid"
run_sweep_bg
assert_true "stale-lock: last-run written after reclaim" test -f "$LAST"
assert_false "stale-lock: lock released" test -d "$LOCK"

echo "CASE 5: foreground cooldown skips spawn"
plant_work
date +%s >"$LAST"
before="$(cat "$LAST")"
rm -rf "$LOCK"
HQ_WORK_MESH_SWEEP_COOLDOWN_SEC=300 run_sweep_fg
sleep 0.2
assert_false "cooldown: did not spawn a lock-holding bg sweep" test -d "$LOCK"
assert_eq "cooldown: last-run unchanged" "$(cat "$LAST")" "$before"

echo "CASE 6: foreground live-lock skip"
plant_work
rm -f "$LAST"
mkdir -p "$LOCK"
printf '%s\n' "$$" >"$LOCK/pid"
run_sweep_fg
sleep 0.2
assert_false "fg-lock: last-run not written" test -f "$LAST"
assert_eq "fg-lock: pid unchanged" "$(tr -dc '0-9' < "$LOCK/pid")" "$$"
rm -rf "$LOCK"

echo "CASE 7: hard timeout releases the lock"
plant_work
rm -f "$LAST"
rm -rf "$LOCK"
t0="$(date +%s)"
HQ_WORK_MESH_SWEEP_TIMEOUT_SEC=1 WM_STUB_SLEEP=8 run_sweep_bg || true
t1="$(date +%s)"
elapsed=$((t1 - t0))
echo "  (timeout elapsed: ${elapsed}s with 8s stub sleep)"
if [ "$elapsed" -lt 6 ]; then pass "timeout: returned well before the 8s stub"; else failc "timeout: took ${elapsed}s (expected <6)"; fi
assert_false "timeout: lock released" test -d "$LOCK"
assert_false "timeout: last-run not written (next session may continue)" test -f "$LAST"

echo "CASE 8: concurrent __sweep_bg__ is single-flight"
plant_work
rm -f "$LAST"
rm -rf "$LOCK"
HQ_ROOT="$SANDBOX" WM_ROOT="$SANDBOX" WM_STUB_SLEEP=1 bash "$HOOK" __sweep_bg__ </dev/null &
p1=$!
HQ_ROOT="$SANDBOX" WM_ROOT="$SANDBOX" WM_STUB_SLEEP=1 bash "$HOOK" __sweep_bg__ </dev/null &
p2=$!
wait "$p1" "$p2" || true
assert_true "single-flight: last-run written by the winner" test -f "$LAST"
assert_false "single-flight: lock released" test -d "$LOCK"

echo "CASE 9: successful empty-body sweep writes last-run and drops the lock"
plant_work
rm -f "$LAST"
rm -rf "$LOCK"
run_sweep_bg
assert_true "success: last-run written" test -f "$LAST"
assert_false "success: lock released" test -d "$LOCK"

echo
echo "work-mesh-close sweep lock: ${PASS} passed, ${FAIL} failed"
if [ "$FAIL" -ne 0 ]; then
  echo "FAIL: work-mesh-close-sweep-lock.test.sh" >&2
  exit 1
fi
echo "PASS: work-mesh-close-sweep-lock.test.sh"
