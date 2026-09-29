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

mkdir -p "$SANDBOX/core/hooks" "$SANDBOX/core/scripts" "$SANDBOX/bin" \
         "$SANDBOX/workspace/sessions" "$SANDBOX/workspace/metrics" \
         "$SANDBOX/workspace/logs" "$SANDBOX/workspace/work-mesh"

cp "$SRC_HOOK" "$SANDBOX/core/hooks/work-mesh-close.sh"
chmod +x "$SANDBOX/core/hooks/work-mesh-close.sh"

REAL_JQ="$(command -v jq 2>/dev/null || true)"
[ -n "$REAL_JQ" ] || { echo "FATAL: jq is required for this test" >&2; exit 1; }
cat >"$SANDBOX/bin/jq" <<'JQ'
#!/usr/bin/env bash
for argument in "$@"; do
  if [ "$argument" = "${WM_TEST_SPOOL:-}" ] && [ -n "${WM_TEST_JQ_COUNTER:-}" ]; then
    printf '%s\n' read >>"$WM_TEST_JQ_COUNTER"
    break
  fi
done
exec "$WM_TEST_REAL_JQ" "$@"
JQ
chmod +x "$SANDBOX/bin/jq"

# Minimal lib stub: enough for sweep guards and a hermetic no-token reconcile.
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
wm_safe_path_component() {
  local value="${1:-}"
  [ -n "$value" ] || return 1
  LC_ALL=C printf '%s\n' "$value" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'
}
wm_registered_slugs() {
  local sid="${1:-}" spf
  if [ -z "${WM_STUB_SPOOL_LOOKUP:-}" ]; then
    printf '%s' "${WM_STUB_SLUGS:-}"
    return 0
  fi
  [ -n "$sid" ] || return 0
  spf="$(wm_spool_file)"
  [ -f "$spf" ] || return 0
  jq -r --arg s "$sid" '
    select(.sessionId==$s and (.event=="attempt" or .event=="posted"))
    | .companySlug // empty' "$spf" 2>/dev/null | grep -v '^$' | sort -u
}
wm_active_threshold() { printf '%s' "${HQ_WORK_MESH_ACTIVE_THRESHOLD_SEC:-900}"; }
wm_find_transcript() {
  if [ -n "${WM_TEST_TRANSCRIPT_TRACE:-}" ]; then
    printf '%s\n' "${1:-}" >>"$WM_TEST_TRANSCRIPT_TRACE"
  fi
  if [ -n "${WM_STUB_SLEEP:-}" ] && [ "${WM_STUB_SLEEP}" != "0" ]; then
    sleep "$WM_STUB_SLEEP" &
    if [ -n "${WM_STUB_SLEEP_PIDFILE:-}" ]; then
      printf '%s\n' "$!" >"$WM_STUB_SLEEP_PIDFILE"
    fi
    wait $! || true
  fi
  printf '%s' "${WM_STUB_TRANSCRIPT:-}"
}
wm_reconciled_marker() { printf '%s/workspace/sessions/%s/work-mesh-reconciled-%s' "$(wm_hq_root)" "$1" "$2"; }
wm_copied_marker() { printf '%s/workspace/sessions/%s/work-mesh-copied-%s' "$(wm_hq_root)" "$1" "$2"; }
wm_terminal_marker() { printf '%s/workspace/sessions/%s/work-mesh-terminal-%s' "$(wm_hq_root)" "$1" "$2"; }
wm_sweep_claim() { printf '%s/workspace/sessions/%s/work-mesh-sweep-claim-%s' "$(wm_hq_root)" "$1" "$2"; }
wm_sweep_try_claim() {
  if [ -n "${WM_TEST_CLAIM_TRACE:-}" ]; then
    printf '%s\t%s\t%s\n' "$1" "$2" "${ismulti:-missing}" >>"$WM_TEST_CLAIM_TRACE"
  fi
  return 0
}
wm_hold_claim() { :; }
wm_release_claim() { :; }
wm_api_base() { printf 'https://unit.invalid'; }
wm_read_token() { return 1; }
wm_spool_build() { printf '{}'; }
wm_spool() { :; }
LIB

HOOK="$SANDBOX/core/hooks/work-mesh-close.sh"
SPOOL="$SANDBOX/workspace/metrics/work-sessions.jsonl"
LOCK="$SANDBOX/workspace/work-mesh/sweep.lock"
LAST="$SANDBOX/workspace/work-mesh/sweep.last"
JQ_COUNTER="$SANDBOX/jq-spool-reads"
TRANSCRIPT_TRACE="$SANDBOX/transcript-lookups"
CLAIM_TRACE="$SANDBOX/claim-calls"
export WM_TEST_REAL_JQ="$REAL_JQ" WM_TEST_SPOOL="$SPOOL" WM_TEST_JQ_COUNTER="$JQ_COUNTER"
export WM_TEST_TRANSCRIPT_TRACE="$TRANSCRIPT_TRACE"
export WM_TEST_CLAIM_TRACE="$CLAIM_TRACE"
: >"$JQ_COUNTER"; : >"$TRANSCRIPT_TRACE"; : >"$CLAIM_TRACE"

export HQ_ROOT="$SANDBOX"
export HOME="$SANDBOX"
export PATH="$SANDBOX/bin:/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"

PASS=0; FAIL=0
pass()  { PASS=$((PASS + 1)); echo "  ok:   $1"; }
failc() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else failc "$1 (expected '$3', got '$2')"; fi; }
assert_true() { local l="$1"; shift; if "$@"; then pass "$l"; else failc "$l"; fi; }
assert_false() { local l="$1"; shift; if "$@"; then failc "$l (expected failure)"; else pass "$l"; fi; }
line_count() {
  local f="$1" n
  [ -f "$f" ] || { printf '0'; return 0; }
  n="$(wc -l <"$f" | tr -d '[:space:]')"
  printf '%s' "${n:-0}"
}
clear_traces() {
  : >"$JQ_COUNTER"; : >"$TRANSCRIPT_TRACE"; : >"$CLAIM_TRACE"
}

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

echo "CASE 7: hard timeout releases the lock and starts cooldown"
plant_work
rm -f "$LAST"
rm -rf "$LOCK"
STUBPIDFILE="$SANDBOX/stub-sleep.pid"
rm -f "$STUBPIDFILE"
t0="$(date +%s)"
HQ_WORK_MESH_SWEEP_TIMEOUT_SEC=1 WM_STUB_SPOOL_LOOKUP=1 WM_STUB_SLEEP=8 WM_STUB_SLEEP_PIDFILE="$STUBPIDFILE" run_sweep_bg || true
t1="$(date +%s)"
elapsed=$((t1 - t0))
echo "  (timeout elapsed: ${elapsed}s with 8s stub sleep)"
if [ "$elapsed" -lt 6 ]; then pass "timeout: returned well before the 8s stub"; else failc "timeout: took ${elapsed}s (expected <6)"; fi
assert_false "timeout: lock released" test -d "$LOCK"
assert_true "timeout: last-run written to start cooldown" test -f "$LAST"
if [ -f "$STUBPIDFILE" ]; then
  stubpid="$(tr -dc '0-9' < "$STUBPIDFILE")"
  if [ -n "$stubpid" ] && kill -0 "$stubpid" 2>/dev/null; then
    failc "timeout: stub descendant pid $stubpid still alive"
  else
    pass "timeout: stub descendant reaped"
  fi
else
  failc "timeout: stub pidfile missing (sleep never started)"
fi
reads_after_timeout="$(line_count "$JQ_COUNTER")"
HQ_WORK_MESH_SWEEP_COOLDOWN_SEC=300 WM_STUB_SPOOL_LOOKUP=1 run_sweep_fg
sleep 0.3
assert_eq "timeout-cooldown: next trigger does not rescan the spool" "$(line_count "$JQ_COUNTER")" "$reads_after_timeout"
assert_false "timeout-cooldown: next trigger did not start another sweep" test -d "$LOCK"

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

echo "CASE 10: successful sweep does not orphan watchdog sleep"
plant_work
rm -f "$LAST"
rm -rf "$LOCK"
# Unique duration so we can grep the process list.
HQ_WORK_MESH_SWEEP_TIMEOUT_SEC=17 run_sweep_bg
assert_true "success-watchdog: last-run written" test -f "$LAST"
assert_false "success-watchdog: lock released" test -d "$LOCK"
# No leftover `sleep 17` from this watchdog. Match exact argv only —
# substring match false-fails when any process cmdline contains "sleep 17"
# (this agent, `sleep 170`, the test file path, etc.).
leftover=0
# portable ps
while read -r args; do
  set -- $args
  if [ "${1:-}" = "sleep" ] && { [ "${2:-}" = "17" ] || [ "${2:-}" = "17s" ]; }; then
    leftover=$((leftover+1))
  fi
done <<EOF
$(ps -axo args= 2>/dev/null || ps -eo args= 2>/dev/null || true)
EOF
if [ "$leftover" -eq 0 ]; then pass "success-watchdog: no orphan sleep 17"; else failc "success-watchdog: $leftover orphan sleep 17"; fi

echo "CASE 11: one bounded spool-read pass serves N sessions"
rm -f "$LAST" "$SPOOL"
rm -rf "$LOCK"
clear_traces
i=1
while [ "$i" -le 12 ]; do
  printf '{"event":"attempt","sessionId":"sid-bounded-%s","companySlug":"indigo"}\n' "$i" >>"$SPOOL"
  i=$((i + 1))
done
WM_STUB_SPOOL_LOOKUP=1 run_sweep_bg
reads="$(line_count "$JQ_COUNTER")"
if [ "$reads" -le 2 ]; then pass "single-pass: 12 sessions used at most 2 spool jq reads"; else failc "single-pass: 12 sessions used $reads spool jq reads"; fi
assert_eq "single-pass: all 12 sessions reached reconcile claim" "$(line_count "$CLAIM_TRACE")" "12"
assert_eq "single-pass: all 12 sessions retained transcript lookup" "$(line_count "$TRANSCRIPT_TRACE")" "12"

echo "CASE 12: fully terminal sessions skip transcript lookup and reconcile"
rm -f "$LAST" "$SPOOL"
rm -rf "$LOCK"
clear_traces
printf '%s\n' \
  '{"event":"attempt","sessionId":"sid-terminal-all","companySlug":"indigo"}' \
  '{"event":"posted","sessionId":"sid-terminal-all","companySlug":"companyx"}' >"$SPOOL"
mkdir -p "$SANDBOX/workspace/sessions/sid-terminal-all"
: >"$SANDBOX/workspace/sessions/sid-terminal-all/work-mesh-reconciled-indigo"
: >"$SANDBOX/workspace/sessions/sid-terminal-all/work-mesh-copied-indigo"
: >"$SANDBOX/workspace/sessions/sid-terminal-all/work-mesh-terminal-companyx"
WM_STUB_SPOOL_LOOKUP=1 run_sweep_bg
assert_eq "terminal: no transcript lookup" "$(line_count "$TRANSCRIPT_TRACE")" "0"
assert_eq "terminal: no reconcile claim or call" "$(line_count "$CLAIM_TRACE")" "0"

echo "CASE 13: multi-company session keeps both slugs and ismulti=1"
rm -f "$LAST" "$SPOOL"
rm -rf "$LOCK"
clear_traces
printf '%s\n' \
  '{"event":"attempt","sessionId":"sid-multi","companySlug":"indigo"}' \
  '{"event":"posted","sessionId":"sid-multi","companySlug":"companyx"}' >"$SPOOL"
WM_STUB_SPOOL_LOOKUP=1 run_sweep_bg
tab="$(printf '\t')"
assert_true "multi-company: companyx reconciled with ismulti=1" grep -Fqx "sid-multi${tab}companyx${tab}1" "$CLAIM_TRACE"
assert_true "multi-company: indigo reconciled with ismulti=1" grep -Fqx "sid-multi${tab}indigo${tab}1" "$CLAIM_TRACE"

echo "CASE 14: live and fresh-transcript skips remain unchanged"
rm -f "$LAST" "$SPOOL"
rm -rf "$LOCK"
clear_traces
printf '%s\n' \
  '{"event":"attempt","sessionId":"sid-live","companySlug":"indigo"}' \
  '{"event":"posted","sessionId":"sid-fresh","companySlug":"indigo"}' >"$SPOOL"
printf '%s\n' 'sid-live' >"$SANDBOX/workspace/sessions/.current"
printf '%s\n' 'synthetic transcript' >"$SANDBOX/fresh-transcript.jsonl"
WM_STUB_SPOOL_LOOKUP=1 WM_STUB_TRANSCRIPT="$SANDBOX/fresh-transcript.jsonl" run_sweep_bg
assert_eq "skip: only fresh session reached transcript lookup" "$(line_count "$TRANSCRIPT_TRACE")" "1"
assert_true "skip: fresh session transcript was inspected" grep -Fxq 'sid-fresh' "$TRANSCRIPT_TRACE"
assert_eq "skip: live and fresh sessions made no reconcile claims" "$(line_count "$CLAIM_TRACE")" "0"
: >"$SANDBOX/workspace/sessions/.current"

echo "CASE 15: unsafe session and company path components are refused"
rm -f "$LAST" "$SPOOL"
rm -rf "$LOCK"
clear_traces
printf '%s\n' \
  '{"event":"attempt","sessionId":"../sid-unsafe","companySlug":"indigo"}' \
  '{"event":"posted","sessionId":"sid-unsafe-slug","companySlug":"../company"}' \
  '{"event":"attempt","sessionId":"sid-safe","companySlug":"indigo"}' >"$SPOOL"
WM_STUB_SPOOL_LOOKUP=1 run_sweep_bg
tab="$(printf '\t')"
assert_eq "unsafe-path: only the safe pair reached a reconcile claim" "$(line_count "$CLAIM_TRACE")" "1"
assert_true "unsafe-path: the valid session still reached reconciliation" grep -Fqx "sid-safe${tab}indigo${tab}0" "$CLAIM_TRACE"
assert_false "unsafe-path: unsafe session was refused" grep -Fq '../sid-unsafe' "$CLAIM_TRACE"
assert_false "unsafe-path: unsafe company was refused" grep -Fq 'sid-unsafe-slug' "$CLAIM_TRACE"

echo "CASE 16: malformed spool lines do not discard valid records"
rm -f "$LAST" "$SPOOL" "$SANDBOX/workspace/logs/work-mesh-hook.log"
rm -rf "$LOCK"
clear_traces
printf '%s\n' '{"event":"attempt","sessionId":"sid-before-malformed","companySlug":"indigo"}' >"$SPOOL"
printf '%s\n' '{"event":"attempt","sessionId":' >>"$SPOOL"
printf '%s\n' '{"event":"posted","sessionId":"sid-after-malformed","companySlug":"indigo"}' >>"$SPOOL"
WM_STUB_SPOOL_LOOKUP=1 run_sweep_bg
tab="$(printf '\t')"
assert_eq "malformed-spool: valid rows on both sides reach reconcile" "$(line_count "$CLAIM_TRACE")" "2"
assert_true "malformed-spool: first valid session reconciled" grep -Fqx "sid-before-malformed${tab}indigo${tab}0" "$CLAIM_TRACE"
assert_true "malformed-spool: later valid session reconciled" grep -Fqx "sid-after-malformed${tab}indigo${tab}0" "$CLAIM_TRACE"
assert_true "malformed-spool: malformed row count logged" grep -Fq "sweep: ignored 1 malformed JSONL line from spool" "$SANDBOX/workspace/logs/work-mesh-hook.log"

echo
echo "work-mesh-close sweep lock: ${PASS} passed, ${FAIL} failed"
if [ "$FAIL" -ne 0 ]; then
  echo "FAIL: work-mesh-close-sweep-lock.test.sh" >&2
  exit 1
fi
echo "PASS: work-mesh-close-sweep-lock.test.sh"
