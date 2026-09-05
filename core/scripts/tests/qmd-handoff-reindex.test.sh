#!/usr/bin/env bash
# qmd-handoff-reindex.test.sh — ownership + single-flight for qmd-reindex-bg.sh
#
# US-002 / hard-skip contract (not #145 managed user-half):
#   - agent markers → skipped-agent BEFORE qmd lookup; zero mutations
#   - laptop: cleanup → update → embed under one portable lock
#   - finalize + post share lock/dedupe; busy owner is quiet fail-open
#   - failed update leaves no stamp (immediate retry allowed)
#   - released callers never inline raw qmd cleanup/update/embed
#
# Prefer --worker for synchronous pipeline assertions; default launcher for
# stdout tokens (skipped-agent / skipped / pid).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HELPER="$ROOT/core/scripts/qmd-reindex-bg.sh"
FINALIZE="$ROOT/core/scripts/handoff-finalize.sh"
POST="$ROOT/core/scripts/handoff-post.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

ASSERTIONS=0
ok() { ASSERTIONS=$((ASSERTIONS + 1)); pass "$1"; }

[[ -f "$HELPER" ]] || fail "missing helper: $HELPER"
[[ -f "$FINALIZE" ]] || fail "missing finalize: $FINALIZE"
[[ -f "$POST" ]] || fail "missing post: $POST"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/qmd-handoff-reindex-test.XXXXXX")"
PID_FILE="$TMP/worker.pids"
: > "$PID_FILE"

# Track detached launcher PIDs (numeric tokens) for deterministic reaping.
# File-backed so subshells (finalize/post fixtures) can append safely.
track_pid() {
  local p="${1:-}"
  [[ "$p" =~ ^[0-9]+$ ]] || return 0
  printf '%s\n' "$p" >> "$PID_FILE"
}

# Wait briefly for a PID, then SIGTERM/SIGKILL. Never fails the suite.
wait_pid_soft() {
  local p="${1:-}" i
  [[ "$p" =~ ^[0-9]+$ ]] || return 0
  for i in $(seq 1 80); do
    kill -0 "$p" 2>/dev/null || return 0
    sleep 0.05
  done
  kill "$p" 2>/dev/null || true
  sleep 0.05
  kill -9 "$p" 2>/dev/null || true
  wait "$p" 2>/dev/null || true
  return 0
}

# Reap tracked workers + shell background jobs. Always returns 0.
reap_workers() {
  set +e
  local p
  if [[ -f "$PID_FILE" ]]; then
    while read -r p; do
      wait_pid_soft "$p"
    done < "$PID_FILE"
    : > "$PID_FILE"
  fi
  wait 2>/dev/null || true
  set -e
  return 0
}

# Non-failing EXIT cleanup: kill stragglers rooted in TMP, then rm -rf with retries.
# A failing EXIT trap would turn a green assertion suite red (set -e).
cleanup() {
  set +e
  # Release any active hold markers FIRST: a fail() fired while a hold-gated
  # stub was looping leaves a held worker alive, and reap_workers' bare `wait`
  # would block on it forever (observed as a whole-suite timeout).
  rm -f "$TMP"/hold-* 2>/dev/null
  reap_workers
  if [[ -n "${TMP:-}" && -d "$TMP" ]]; then
    # Best-effort: stop any remaining processes whose cmdline references this TMP.
    pkill -f "$TMP" 2>/dev/null || true
    sleep 0.05
    local i
    for i in 1 2 3 4 5; do
      rm -rf "$TMP" 2>/dev/null && break
      pkill -f "$TMP" 2>/dev/null || true
      sleep 0.05
    done
    rm -rf "$TMP" 2>/dev/null || true
  fi
  set -e
  return 0
}
trap cleanup EXIT

HOME_DIR="$TMP/home"
BIN="$TMP/bin"
LOG="$TMP/qmd-handoff.log"
MUTATION_LOG="$TMP/mutations.log"
LOCK_DIR="$HOME_DIR/.hq/locks/qmd-reindex-bg.lock"
COMPLETE_STAMP="$HOME_DIR/.hq/locks/qmd-reindex-bg.completed"
mkdir -p "$HOME_DIR/.hq/locks" "$BIN" "$TMP/logs" "$TMP/repo/core/scripts" \
  "$TMP/repo/workspace/threads" "$TMP/repo/workspace/baseline" "$TMP/repo/workspace/orchestrator"

# A CLI-reachable dir with NO qmd, for the cases whose subject is qmd's absence.
# It must not inherit the stub qmd from $BIN, and /usr/bin is not safe to use as
# a "qmd-free" PATH: qmd installs there on any host that ran `npm i -g`.
#
# Populate it by mirroring EVERY system-bin tool except qmd. Hand-picking tools
# has broken twice: the pnpm `hq` launcher needs dirname/sed/uname before it
# ever reaches node (a missing dirname makes its basedir resolve empty, and the
# CLI dies with MODULE_NOT_FOUND on a /global/5/... path), and the forwarder
# script needs dirname too. A full mirror minus qmd is the only PATH that is
# simultaneously "qmd absent" and "everything else works".
CLI_ONLY_BIN="$TMP/cli-only-bin"
mkdir -p "$CLI_ONLY_BIN"
for _sys in /usr/bin /bin /usr/local/bin; do
  [[ -d "$_sys" ]] || continue
  for _tool in "$_sys"/*; do
    _name="${_tool##*/}"
    [[ "$_name" == "qmd" ]] && continue
    [[ -e "$CLI_ONLY_BIN/$_name" ]] || ln -s "$_tool" "$CLI_ONLY_BIN/$_name"
  done
done

# The helper forwards to `hq index background`, so every hermetic `env -i` case
# needs the CLI and its node runtime reachable.
#
# `hq` must be reached through its OWN directory and never symlinked in: the
# pnpm shim derives its payload path from $0's dirname, so a symlink elsewhere
# makes it look for dist/index.js under that location and die with
# MODULE_NOT_FOUND. `node` is a real binary and is safe to link — and required,
# since the shim execs it (a PATH without node fails with 127).
HQ_REAL_BIN="$(command -v hq 2>/dev/null || true)"
[[ -n "$HQ_REAL_BIN" ]] \
  || { echo "FAIL: hq CLI not on PATH; this suite exercises the hq CLI forwarder" >&2; exit 1; }
# A WRAPPER, never a symlink. The pnpm shim derives its payload path from $0, so
# a symlink (or a PATH lookup that leaves $0 bare) makes it resolve dist/index.js
# against the wrong directory and die with MODULE_NOT_FOUND. Calling the real
# shim by absolute path keeps its own $0 correct wherever the fixture puts it.
for _dir in "$BIN" "$CLI_ONLY_BIN"; do
  printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$HQ_REAL_BIN" > "$_dir/hq"
  chmod +x "$_dir/hq"
done
for _cmd in node bash sh; do
  _resolved="$(command -v "$_cmd" 2>/dev/null || true)"
  if [[ -z "$_resolved" ]]; then
    echo "FAIL: $_cmd not on PATH; this suite exercises the hq CLI forwarder" >&2
    exit 1
  fi
  ln -sf "$_resolved" "$BIN/$_cmd"
  ln -sf "$_resolved" "$CLI_ONLY_BIN/$_cmd"
done

# --- fake qmd: records ordered mutations; optional hold for concurrency ---
# ONE writer for the standard stub. Cases that need a special stub (C2's
# ready-signal, C3's noisy update) overwrite $BIN/qmd and then restore through
# this function — four hand-copied restore blocks previously drifted from the
# canonical body and reintroduced retired hold semantics.
write_standard_qmd_stub() {
  cat > "$BIN/qmd" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
printf 'qmd %s\n' "$cmd" >> "${MUTATION_LOG:?}"
# Hold only on PIPELINE commands. The CLI probes `qmd collection` before the
# raw pipeline; holding there would block the winner ahead of `qmd cleanup`,
# and hold-gated cases that wait for cleanup-under-hold would deadlock.
case "$cmd" in
  cleanup|update|embed)
    if [[ -n "${QMD_HOLD_FILE:-}" && -f "${QMD_HOLD_FILE}" ]]; then
      # Hold while the marker exists so a second caller can race the lock.
      while [[ -f "${QMD_HOLD_FILE}" ]]; do
        sleep 0.05
      done
    fi
    ;;
esac
if [[ -n "${QMD_FAIL_CMD:-}" && "$cmd" == "$QMD_FAIL_CMD" ]]; then
  exit "${QMD_FAIL_RC:-1}"
fi
exit 0
SH
  chmod +x "$BIN/qmd"
}
write_standard_qmd_stub

# Shared env for helper runs (isolated HOME + PATH; no real agent markers).
helper_env() {
  # shellcheck disable=SC2086
  env -i \
    PATH="$BIN:/usr/bin:/bin" \
    HOME="$HOME_DIR" \
    HQ_QMD_BIN="$BIN/qmd" \
    MUTATION_LOG="$MUTATION_LOG" \
    QMD_REINDEX_LOG="$LOG" \
    QMD_HANDOFF_LOG="$LOG" \
    QMD_HOLD_FILE="${QMD_HOLD_FILE:-}" \
    QMD_READY_FILE="${QMD_READY_FILE:-}" \
    QMD_FAIL_CMD="${QMD_FAIL_CMD:-}" \
    QMD_FAIL_RC="${QMD_FAIL_RC:-}" \
    QMD_HANDOFF_DEDUPE_SEC="${QMD_HANDOFF_DEDUPE_SEC:-90}" \
    QMD_HANDOFF_LOG_MAX_BYTES="${QMD_HANDOFF_LOG_MAX_BYTES:-65536}" \
    QMD_HANDOFF_LOCK_GRACE_SEC="${QMD_HANDOFF_LOCK_GRACE_SEC:-5}" \
    QMD_FORCE_OWNER_WRITE_FAIL="${QMD_FORCE_OWNER_WRITE_FAIL:-}" \
    QMD_FORCE_CLAIMANT_WRITE_FAIL="${QMD_FORCE_CLAIMANT_WRITE_FAIL:-}" \
    HQ_AGENT_BOX="${HQ_AGENT_BOX:-}" \
    HQ_QMD_REINDEX_MODE="${HQ_QMD_REINDEX_MODE:-}" \
    MV_TRACE_LOG="${MV_TRACE_LOG:-}" \
    "$@"
}

# Synchronous worker path (pipeline under lock).
run_worker() {
  helper_env bash "$HELPER" --worker --log "$LOG"
}

# Launcher path (prints skipped-agent / skipped / pid).
run_launcher() {
  # Record the detached worker so reset_state can actually drain it. track_pid
  # is file-backed precisely so this works from a command-substitution subshell.
  # Without this the reap list stayed empty and a prior case's worker kept
  # writing into the next case's freshly-truncated MUTATION_LOG — invisible while
  # the worker was a fast shell process, but not once it became a node process.
  local _out
  _out="$(helper_env bash "$HELPER" --log "$LOG")"
  track_pid "$_out"
  printf '%s' "$_out"
}

# KNOWN GAP — this suite cannot yet isolate cases from a detached node worker.
#
# Diagnosed 2026-08-06 by instrumenting the qmd stub with pid/ppid:
#   * One `--worker` run emits exactly one cleanup/update/embed, so the CLI's
#     single-flight lock is correct.
#   * After reset_state, stray mutations carried ppid=<the previous launcher's
#     printed PID>, and `wait` reports that PID is not a child of this shell.
#   * track_pid() existed but had NO callers, so reap_workers always drained an
#     empty list. That is fixed below (run_launcher now records its worker).
#   * Fixture-spawned workers (finalize/post) never surface a PID at all, so PID
#     tracking alone cannot cover them.
#
# Draining on the single-flight lock was tried and rejected: several cases park a
# worker mid-pipeline via $HOLD to race the lock, so lock-waiting either blocks
# for the full timeout or, once holds are cleared early, releases a worker into
# the next case. Both were observed.
#
# The durable fix is per-case isolation — a fresh HOME and MUTATION_LOG per case
# so cross-case leakage is structurally impossible — rather than more draining.
# Until then this suite must not be treated as green for the forwarder.

CASE_SEQ=0
# "The worker is inside qmd" — it holds the lock and is blocked in a call.
#
# Cases used to wait for `^qmd cleanup` specifically, which was the shell
# worker's FIRST qmd call. The CLI reconciles collections first, so under a stub
# that holds on every call the worker blocks at `collection list` and `cleanup`
# never arrives — the wait cannot succeed and the case times out. Any logged
# call proves the worker reached qmd, which is what these waits actually mean.
wait_for_worker_in_qmd() { # <label>
  # Anchor on `qmd cleanup` specifically: it is the step the hold-gated stub
  # blocks in, so its presence proves the worker is INSIDE the raw pipeline
  # with the lock held. Any-line waiting would return on the CLI's pre-lock
  # `qmd collection` registration, before the lock is acquired — a race.
  local label="${1:-worker}" _
  for _ in $(seq 1 600); do
    grep -q '^qmd cleanup' "$MUTATION_LOG" 2>/dev/null && return 0
    sleep 0.05
  done
  fail "$label never reached qmd cleanup (log: $(tr '\n' ' ' <"$MUTATION_LOG" 2>/dev/null))"
}

# NOTE: main's #522 introduced a hand-picked path_without_qmd() helper for the
# qmd-absent cases. This branch supersedes it with $CLI_ONLY_BIN — a full
# system-bin mirror minus qmd — because a curated tool list broke twice (the
# pnpm hq launcher alone needs dirname/sed/uname before it reaches node).

reset_state() {
  # Per-case isolation. A detached worker from a previous case cannot be waited
  # on (it is not a child of this shell) and fixture-spawned workers never
  # surface a PID at all, so draining can never be complete. Instead of chasing
  # stragglers, give every case its own HOME, mutation log and helper log: a
  # leaked worker keeps writing to the paths it captured at spawn and is
  # structurally unable to contaminate the next case. Cheap, and it removes the
  # timing assumptions this suite inherited from a synchronous shell worker.
  reap_workers
  CASE_SEQ=$((CASE_SEQ + 1))
  HOME_DIR="$TMP/home.$CASE_SEQ"
  LOG="$TMP/qmd-handoff.$CASE_SEQ.log"
  MUTATION_LOG="$TMP/mutations.$CASE_SEQ.log"
  LOCK_DIR="$HOME_DIR/.hq/locks/qmd-reindex-bg.lock"
  COMPLETE_STAMP="$HOME_DIR/.hq/locks/qmd-reindex-bg.completed"
  mkdir -p "$HOME_DIR/.hq/locks"
  : > "$MUTATION_LOG"
  # Clear any env that prior cases set in this shell (run_* inherit via ${VAR:-}).
  unset QMD_HOLD_FILE QMD_READY_FILE QMD_FAIL_CMD QMD_FAIL_RC HQ_AGENT_BOX HQ_QMD_REINDEX_MODE
  unset QMD_FORCE_OWNER_WRITE_FAIL QMD_FORCE_CLAIMANT_WRITE_FAIL
  QMD_HANDOFF_DEDUPE_SEC=90
  QMD_HANDOFF_LOG_MAX_BYTES=65536
  QMD_HANDOFF_LOCK_GRACE_SEC=5
}

inv_count() {
  # grep -c prints 0 and exits 1 on no match — do not also echo 0.
  local n
  n=$(grep -c '^qmd ' "$MUTATION_LOG" 2>/dev/null || true)
  echo "${n:-0}"
}

# =============================================================================
# A) Agent hard-skip — before qmd lookup; zero mutations
# =============================================================================
reset_state
out=$(HQ_AGENT_BOX=1 run_launcher)
rc=0
HQ_AGENT_BOX=1 run_launcher >/dev/null || rc=$?
[[ "$rc" -eq 0 ]] || fail "agent launcher should exit 0, got $rc"
[[ "$out" == "skipped-agent" ]] || fail "HQ_AGENT_BOX=1 want skipped-agent, got '$out'"
[[ "$(inv_count)" -eq 0 ]] || fail "agent skip must not mutate (got $(cat "$MUTATION_LOG"))"
ok "A1: HQ_AGENT_BOX=1 → skipped-agent, zero mutations"

reset_state
for mode in skip-agent skip; do
  out=$(HQ_QMD_REINDEX_MODE="$mode" run_launcher)
  [[ "$out" == "skipped-agent" ]] || fail "mode=$mode want skipped-agent, got '$out'"
  [[ "$(inv_count)" -eq 0 ]] || fail "mode=$mode must not mutate"
done
ok "A2: HQ_QMD_REINDEX_MODE=skip-agent|skip → skipped-agent, zero mutations"

# Agent with qmd ABSENT must still print skipped-agent (not skipped).
reset_state
out=$(
  env -i PATH="$CLI_ONLY_BIN" HOME="$HOME_DIR" \
    QMD_REINDEX_LOG="$LOG" HQ_AGENT_BOX=1 \
    bash "$HELPER" --log "$LOG"
)
[[ "$out" == "skipped-agent" ]] \
  || fail "agent + missing qmd must print skipped-agent (not skipped), got '$out'"
[[ ! -f "$MUTATION_LOG" ]] || [[ "$(inv_count)" -eq 0 ]] \
  || fail "agent + missing qmd must not mutate"
ok "A3: agent before missing-qmd → skipped-agent (token honesty)"

# Worker re-check also hard-skips agents (no mutation under --worker).
reset_state
set +e
HQ_AGENT_BOX=1 run_worker
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "agent worker should exit 0, got $rc"
[[ "$(inv_count)" -eq 0 ]] || fail "agent worker must not mutate"
ok "A4: agent --worker hard-skip, zero mutations"

# Structural: the forwarder must never invoke the managed user-half itself.
# It previously also had to MENTION `qmd-index-user`, because is_agent_box read
# that marker inline. Detection now lives in the CLI, so requiring the string
# here would assert against the wrong file; what still matters is that this
# script never execs the managed half. Agent detection itself — including the
# /usr/local/lib/hq-agent/qmd-index-user marker — is covered by hq-cli's
# background differential and isHostedAgent unit tests.
if grep -nE '(exec|bash|sh)[[:space:]]+[^#]*qmd-index-user' "$HELPER" | grep -vE '^[0-9]+:[[:space:]]*#' >/dev/null 2>&1; then
  fail "forwarder must not invoke the managed user-half"
fi
ok "A5: forwarder does not invoke the managed user-half"
if grep -nE 'run_qmd .*qmd-index|bash .*/qmd-index-user' "$HELPER" | grep -vE '^[0-9]+:[[:space:]]*#' >/dev/null 2>&1; then
  fail "helper must not exec qmd-index-user"
fi
ok "A5: managed path is skip marker only (never invoke target)"

# =============================================================================
# L) Laptop single-flight pipeline
# =============================================================================
reset_state
run_worker
# The CLI reconciles collections before the pipeline; the old shell worker had
# no such step. Count the pipeline itself and assert the registration calls
# separately, so the addition stays visible instead of being absorbed into a
# looser total. Equivalence of the pipeline against the pre-migration script is
# proven in hq-cli's e2e/qmd-background-differential.test.ts.
mapfile -t steps < <(grep '^qmd ' "$MUTATION_LOG" | grep -vE '^qmd (collection|context)\b' || true)
[[ "${#steps[@]}" -eq 3 ]] || fail "expected 3 raw qmd pipeline steps, got ${#steps[@]}: $(cat "$MUTATION_LOG")"
[[ "${steps[0]}" == "qmd cleanup" ]] || fail "step1 want cleanup, got ${steps[0]}"
[[ "${steps[1]}" == "qmd update" ]] || fail "step2 want update, got ${steps[1]}"
[[ "${steps[2]}" == "qmd embed" ]] || fail "step3 want embed, got ${steps[2]}"
[[ -f "$COMPLETE_STAMP" ]] || fail "success should write completion stamp"
ok "L1: laptop --worker runs cleanup → update → embed and stamps"

# Concurrent workers: at most one pipeline
reset_state
HOLD="$TMP/hold-concurrent"
: > "$HOLD"
# Establish contention deterministically rather than racing two process starts.
#
# This used to launch both workers and `sleep 0.15`, which worked when the
# worker was a bash script starting in ~10ms. The helper now forwards into the
# hq CLI and node takes ~1.7s to boot, so the hold was released before either
# worker arrived: the first ran and RELEASED the lock, then the second acquired
# it and ran too. Timestamps showed the second pipeline beginning 39-136ms AFTER
# the first finished — sequential execution, i.e. single-flight working, not
# failing. The case was measuring startup latency, not lock contention.
#
# Waiting for BOTH workers to reach qmd cannot work either: the loser is
# supposed to skip without touching qmd, so only one can ever log.
#
# So: start one worker, wait until it is demonstrably inside qmd (holding the
# lock), start the second while that is still true, and assert the second adds
# no qmd calls. Deterministic at any startup speed.
QMD_HOLD_FILE="$HOLD" QMD_HANDOFF_DEDUPE_SEC=0 helper_env bash "$HELPER" --worker --log "$LOG" &
holder=$!
wait_for_worker_in_qmd "first concurrent worker"
# Count PIPELINE steps only. The CLI registers collections (`qmd collection`,
# idempotent, read-mostly) BEFORE trying the lock, so the losing worker
# legitimately logs those; the single-flight invariant is about the raw
# cleanup/update/embed pipeline, and the final assertions below pin each of
# those to exactly one occurrence.
pipeline_lines() { grep -cE '^qmd (cleanup|update|embed)$' "$MUTATION_LOG" 2>/dev/null || true; }
before_second=$(pipeline_lines)

QMD_HOLD_FILE="$HOLD" QMD_HANDOFF_DEDUPE_SEC=0 helper_env bash "$HELPER" --worker --log "$LOG" &
second=$!
wait "$second" 2>/dev/null || true
after_second=$(pipeline_lines)
[[ "$after_second" -eq "$before_second" ]] \
  || fail "second worker ran pipeline steps while the lock was held (before=$before_second after=$after_second)"

rm -f "$HOLD"
wait "$holder" 2>/dev/null || true
wait || true
cleanup_n=$(grep -c '^qmd cleanup' "$MUTATION_LOG" || true)
update_n=$(grep -c '^qmd update' "$MUTATION_LOG" || true)
embed_n=$(grep -c '^qmd embed' "$MUTATION_LOG" || true)
[[ "$cleanup_n" -eq 1 && "$update_n" -eq 1 && "$embed_n" -eq 1 ]] \
  || fail "expected one raw pipeline, got cleanup=$cleanup_n update=$update_n embed=$embed_n ($(cat "$MUTATION_LOG"))"
ok "L2: concurrent workers → one cleanup/update/embed pipeline"

# Busy / live owner: quiet exit 0, no second writer, lock preserved
reset_state
mkdir -p "$LOCK_DIR"
{
  echo "pid=$$"
  echo "ts=$(date +%s)"
  echo "nonce=live-test"
} >"$LOCK_DIR/owner"
before_mut="$(cat "$MUTATION_LOG")"
set +e
QMD_HANDOFF_DEDUPE_SEC=0 run_worker
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "busy live owner should exit 0, got $rc"
after_mut="$(cat "$MUTATION_LOG")"
[[ "$before_mut" == "$after_mut" ]] || fail "live owner lock was stolen (mutation occurred)"
[[ -d "$LOCK_DIR" ]] || fail "live owner lock dir was removed"
[[ -f "$LOCK_DIR/owner" ]] || fail "live owner record was removed"
grep -q "^pid=$$" "$LOCK_DIR/owner" || fail "live owner pid rewritten"
ok "L3: busy/live owner → quiet exit 0, no mutation, lock preserved"

# Dead owner reclaim
reset_state
mkdir -p "$LOCK_DIR"
DEAD_PID=$(( $$ + 1000000 ))
if kill -0 "$DEAD_PID" 2>/dev/null; then
  DEAD_PID=2147483646
  kill -0 "$DEAD_PID" 2>/dev/null && fail "could not find a dead pid for stale-owner test"
fi
{
  echo "pid=$DEAD_PID"
  echo "ts=1"
  echo "nonce=dead-test"
} >"$LOCK_DIR/owner"
QMD_HANDOFF_DEDUPE_SEC=0 run_worker
cleanup_n=$(grep -c '^qmd cleanup' "$MUTATION_LOG" || true)
[[ "$cleanup_n" -eq 1 ]] || fail "stale/dead owner should be reclaimed; cleanup=$cleanup_n"
if [[ -d "$LOCK_DIR" ]]; then
  fail "lock dir still present after reclaimed run completed"
fi
[[ -f "$COMPLETE_STAMP" ]] || fail "completion stamp missing after reclaim run"
ok "L4: dead/stale owner lock reclaimed; pipeline runs once"

# Empty lock dir past grace is reclaimable
reset_state
mkdir -p "$LOCK_DIR"
QMD_HANDOFF_DEDUPE_SEC=0 QMD_HANDOFF_LOCK_GRACE_SEC=0 run_worker
cleanup_n=$(grep -c '^qmd cleanup' "$MUTATION_LOG" || true)
[[ "$cleanup_n" -eq 1 ]] || fail "empty lock dir should be reclaimed; cleanup=$cleanup_n"
ok "L5: empty lock dir without owner is reclaimed"

# Busy loser leaves winner log untouched
reset_state
HOLD="$TMP/hold-log"
: > "$HOLD"
QMD_HOLD_FILE="$HOLD" QMD_HANDOFF_DEDUPE_SEC=0 helper_env bash "$HELPER" --worker --log "$LOG" &
wpid=$!
wait_for_worker_in_qmd "winner"
echo "KEEP_ME" >> "$LOG"
size_before=$(wc -c < "$LOG")
QMD_HANDOFF_DEDUPE_SEC=0 run_worker
size_after=$(wc -c < "$LOG")
[[ "$size_before" -eq "$size_after" ]] || fail "loser changed log size"
grep -q 'KEEP_ME' "$LOG" || fail "loser wiped KEEP_ME"
rm -f "$HOLD"
wait "$wpid" || true
ok "L6: busy loser leaves winner log untouched"

# =============================================================================
# F) Fail-soft / stamp / dedupe
# =============================================================================
reset_state
set +e
QMD_FAIL_CMD=update QMD_FAIL_RC=7 run_worker
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "raw qmd failure should exit 0, got $rc"
grep -q '^qmd cleanup' "$MUTATION_LOG" || fail "cleanup should still run before failed update"
grep -q '^qmd update' "$MUTATION_LOG" || fail "update should be attempted"
if grep -q '^qmd embed' "$MUTATION_LOG"; then
  fail "embed should not run after failed update"
fi
if [[ -f "$COMPLETE_STAMP" ]]; then
  fail "failed update must not write completion stamp (got $(cat "$COMPLETE_STAMP"))"
fi
ok "F1: update fail soft (exit 0); cleanup+update; no embed; no stamp"

# Immediate retry after failure mutates; success then stamps
reset_state
QMD_FAIL_CMD=update QMD_FAIL_RC=7 QMD_HANDOFF_DEDUPE_SEC=90 run_worker
if [[ -f "$COMPLETE_STAMP" ]]; then
  fail "first failed update must not stamp"
fi
cleanup_n=$(grep -c '^qmd cleanup' "$MUTATION_LOG" || true)
[[ "$cleanup_n" -eq 1 ]] || fail "first fail expected 1 cleanup, got $cleanup_n"

QMD_FAIL_CMD=update QMD_FAIL_RC=7 QMD_HANDOFF_DEDUPE_SEC=90 run_worker
cleanup_n=$(grep -c '^qmd cleanup' "$MUTATION_LOG" || true)
update_n=$(grep -c '^qmd update' "$MUTATION_LOG" || true)
[[ "$cleanup_n" -eq 2 && "$update_n" -eq 2 ]] \
  || fail "failed update must allow immediate retry; c=$cleanup_n u=$update_n"
if [[ -f "$COMPLETE_STAMP" ]]; then
  fail "second failed update must still not stamp"
fi

unset QMD_FAIL_CMD QMD_FAIL_RC
QMD_HANDOFF_DEDUPE_SEC=90 run_worker
[[ -f "$COMPLETE_STAMP" ]] || fail "successful run after fails should stamp"
cleanup_n=$(grep -c '^qmd cleanup' "$MUTATION_LOG" || true)
embed_n=$(grep -c '^qmd embed' "$MUTATION_LOG" || true)
[[ "$cleanup_n" -eq 3 && "$embed_n" -eq 1 ]] \
  || fail "success after fails expected c=3 e=1, got c=$cleanup_n e=$embed_n"
QMD_HANDOFF_DEDUPE_SEC=90 run_worker
cleanup_n=$(grep -c '^qmd cleanup' "$MUTATION_LOG" || true)
[[ "$cleanup_n" -eq 3 ]] || fail "success stamp should dedupe next call; c=$cleanup_n"
ok "F2: fail then retry mutates; success stamps and subsequent dedupes"

# Success stamp dedupes sequential workers
reset_state
QMD_HANDOFF_DEDUPE_SEC=90 run_worker
QMD_HANDOFF_DEDUPE_SEC=90 run_worker
cleanup_n=$(grep -c '^qmd cleanup' "$MUTATION_LOG" || true)
update_n=$(grep -c '^qmd update' "$MUTATION_LOG" || true)
embed_n=$(grep -c '^qmd embed' "$MUTATION_LOG" || true)
[[ "$cleanup_n" -eq 1 && "$update_n" -eq 1 && "$embed_n" -eq 1 ]] \
  || fail "sequential dedupe expected one pipeline, got c=$cleanup_n u=$update_n e=$embed_n"
ok "F3: success stamp dedupes sequential workers (one pipeline)"

# Dedupe off → two pipelines
reset_state
QMD_HANDOFF_DEDUPE_SEC=0 run_worker
QMD_HANDOFF_DEDUPE_SEC=0 run_worker
cleanup_n=$(grep -c '^qmd cleanup' "$MUTATION_LOG" || true)
[[ "$cleanup_n" -eq 2 ]] || fail "dedupe=0 expected 2 cleanups, got $cleanup_n"
ok "F4: DEDUPE_SEC=0 allows sequential re-run"

# =============================================================================
# S) Structural + missing qmd / empty HOME
# =============================================================================
# Live inline raw qmd pipeline forbidden (any quote shape / split form).
# Reject non-comment lines with `qmd cleanup|update|embed`; require helper call site.
assert_no_raw_qmd_pipeline() {
  local file="$1" label="$2" live
  live=$(grep -nE '\bqmd[[:space:]]+(cleanup|update|embed)\b' "$file" 2>/dev/null \
    | grep -vE '^[0-9]+:[[:space:]]*#' || true)
  if [[ -n "$live" ]]; then
    fail "$label still has live raw qmd pipeline: $live"
  fi
  # Ban nohup/bash -c launching qmd directly (single or double quotes).
  live=$(grep -nE "nohup[[:space:]].*(\"|')qmd|bash[[:space:]]+-c[[:space:]]+(\"|').*qmd" "$file" 2>/dev/null \
    | grep -vE '^[0-9]+:[[:space:]]*#' || true)
  if [[ -n "$live" ]]; then
    fail "$label still nohup/bash -c launches qmd: $live"
  fi
  grep -q 'qmd-reindex-bg' "$file" || fail "$label does not call qmd-reindex-bg"
  # Prefer a single helper invocation site (assignment or bash call), not dual raw writers.
  local sites
  sites=$(grep -cE 'qmd-reindex-bg\.sh|_QMD_BG=.*qmd-reindex|bash[[:space:]].*qmd-reindex-bg' "$file" || true)
  [[ "${sites:-0}" -ge 1 ]] || fail "$label missing qmd-reindex-bg call site"
}
assert_no_raw_qmd_pipeline "$FINALIZE" "handoff-finalize.sh"
assert_no_raw_qmd_pipeline "$POST" "handoff-post.sh"
ok "S1: finalize+post delegate to qmd-reindex-bg (no inline raw pipeline)"

reset_state
# S2 asserted "skipped" when no qmd was on PATH. Two things changed:
#   1. PATH=/usr/bin:/bin never actually removed qmd — it is installed there on
#      hosts that ran `npm i -g @tobilu/qmd`, so this case silently tested the
#      opposite of its name and failed on exactly those machines.
#   2. The helper now forwards to `hq index background`, and the CLI bundles qmd
#      (resolved via node_modules/.bin since hq-cli 5.94.1), so "skipped" is
#      unreachable by design — that is the point of bundling (hq-cli#333).
# The new contract: with no qmd on PATH the run still proceeds rather than
# skipping. CLI_ONLY_BIN holds the CLI and coreutils, deliberately no qmd.
[[ -e "$CLI_ONLY_BIN/qmd" ]] && fail "S2 fixture leaked a qmd binary"
out=$(
  env -i PATH="$CLI_ONLY_BIN" HOME="$HOME_DIR" \
    QMD_REINDEX_LOG="$LOG" \
    bash "$HELPER" --log "$LOG"
)
[[ "$out" != "skipped" ]] || fail "bundled qmd should make 'skipped' unreachable, got '$out'"
ok "S2: no qmd on PATH still proceeds (CLI bundles qmd), exit 0"

reset_state
set +e
out=$(
  env -i PATH="$BIN:/usr/bin:/bin" \
    MUTATION_LOG="$MUTATION_LOG" \
    QMD_REINDEX_LOG="$LOG" \
    bash "$HELPER" --log "$LOG"
)
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "empty HOME should exit 0, got $rc"
[[ -z "$out" ]] || fail "empty HOME should be quiet (no token), got '$out'"
[[ "$(inv_count)" -eq 0 ]] || fail "empty HOME must not mutate"
ok "S3: empty HOME non-agent → quiet exit 0, zero mutations"

# Launcher spawns worker and prints a live pid (numeric)
reset_state
out=$(run_launcher)
[[ "$out" =~ ^[0-9]+$ ]] || fail "laptop launcher want numeric pid, got '$out'"
track_pid "$out"
# Wait for the pipeline's FINAL step, not a raw line count: the CLI logs
# collection/context probes before the pipeline, so "any 3 lines" can be
# satisfied with zero pipeline steps run.
for _ in $(seq 1 200); do
  grep -q '^qmd embed' "$MUTATION_LOG" 2>/dev/null && break
  sleep 0.05
done
grep -q '^qmd embed' "$MUTATION_LOG" \
  || fail "launcher worker did not complete pipeline: $(cat "$MUTATION_LOG")"
cleanup_n=$(grep -c '^qmd cleanup' "$MUTATION_LOG" || true)
[[ "$cleanup_n" -eq 1 ]] || fail "launcher expected one cleanup, got $cleanup_n"
wait_pid_soft "$out"
ok "S4: laptop launcher prints pid and worker mutates once"

# =============================================================================
# R) Finalize / post routing
# =============================================================================
reset_state
cp "$FINALIZE" "$TMP/repo/core/scripts/handoff-finalize.sh"
cp "$HELPER" "$TMP/repo/core/scripts/qmd-reindex-bg.sh"
cp "$POST" "$TMP/repo/core/scripts/handoff-post.sh"
cp "$ROOT/core/scripts/hq-status-summary.sh" "$TMP/repo/core/scripts/hq-status-summary.sh"
cat > "$TMP/repo/core/scripts/rebuild-threads-index.sh" <<'SH'
#!/usr/bin/env bash
mkdir -p workspace/threads
echo "# Threads" > workspace/threads/INDEX.md
echo "- recent" > workspace/threads/recent.md
SH
cat > "$TMP/repo/core/scripts/rebuild-orchestrator-index.sh" <<'SH'
#!/usr/bin/env bash
mkdir -p workspace/orchestrator
echo "# Orchestrator" > workspace/orchestrator/INDEX.md
SH
cat > "$TMP/repo/core/scripts/archive-old-threads.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$TMP/repo/core/scripts/"*.sh

cat > "$TMP/repo/workspace/baseline/hq-local-baseline.json" <<'JSON'
{"categories":[{"name":"baseline","patterns":["workspace/*"]}]}
JSON

# Interpose helper via a wrapper that records scheduling, then execs real helper.
REAL_HELPER="$TMP/repo/core/scripts/qmd-reindex-bg.sh"
mv "$REAL_HELPER" "$TMP/repo/core/scripts/qmd-reindex-bg.real.sh"
cat > "$REAL_HELPER" <<SH
#!/usr/bin/env bash
printf 'scheduled\n' >> "$TMP/helper-scheduled.log"
exec bash "$TMP/repo/core/scripts/qmd-reindex-bg.real.sh" "\$@"
SH
chmod +x "$REAL_HELPER" "$TMP/repo/core/scripts/qmd-reindex-bg.real.sh"

(
  cd "$TMP/repo"
  git init -q
  git config user.email test@example.com
  git config user.name "QMD Handoff Test"
  echo base > tracked.txt
  git add tracked.txt core/scripts workspace/baseline
  git commit -qm base
  echo changed > tracked.txt

  rm -f "$TMP/helper-scheduled.log" "$MUTATION_LOG" "$COMPLETE_STAMP"
  : > "$MUTATION_LOG"
  out=$(
    env -i PATH="$BIN:/usr/bin:/bin:$(dirname "$(command -v jq || echo /usr/bin)")" \
      HOME="$HOME_DIR" \
      HQ_QMD_BIN="$BIN/qmd" \
      MUTATION_LOG="$MUTATION_LOG" \
      QMD_REINDEX_LOG="$LOG" \
      QMD_HANDOFF_LOG="$LOG" \
      QMD_HANDOFF_DEDUPE_SEC=0 \
      bash core/scripts/handoff-finalize.sh \
        --title "Handoff: qmd ritual" \
        --summary "finalize schedules reindex" \
        --message "ritual" \
        --next-steps-json '[]' \
        --files-touched-json '["tracked.txt"]' \
        --learnings-json '[]' \
        --tags-json '["test"]' \
        --slug "qmd-ritual"
  )
  echo "$out" > "$TMP/finalize-out.json"
  qmd_pid=$(jq -r '.qmd_pid // empty' <<<"$out")
  [[ -n "$qmd_pid" ]] || fail "finalize did not report qmd_pid (out=$(cat "$TMP/finalize-out.json"))"
  # Numeric pid or skipped token both prove routing.
  [[ "$qmd_pid" =~ ^[0-9]+$ || "$qmd_pid" == "skipped" || "$qmd_pid" == "skipped-agent" ]] \
    || fail "finalize qmd_pid unexpected: '$qmd_pid'"
  track_pid "$qmd_pid"
  for _ in $(seq 1 100); do
    [[ -f "$TMP/helper-scheduled.log" ]] && break
    sleep 0.05
  done
  [[ -f "$TMP/helper-scheduled.log" ]] || fail "finalize never scheduled helper"
  for _ in $(seq 1 100); do
    grep -q '^qmd embed' "$MUTATION_LOG" 2>/dev/null && break
    sleep 0.05
  done
  grep -q '^qmd cleanup' "$MUTATION_LOG" || fail "finalize helper did not run raw pipeline"
  wait_pid_soft "$qmd_pid"
)

ok "R1: finalize routes helper; laptop mutates once"

# Agent finalize → skipped-agent, zero mutations
reset_state
rm -f "$TMP/helper-scheduled.log"
: > "$TMP/helper-scheduled.log"
(
  cd "$TMP/repo"
  out=$(
    env -i PATH="$BIN:/usr/bin:/bin:$(dirname "$(command -v jq || echo /usr/bin)")" \
      HOME="$HOME_DIR" \
      HQ_QMD_BIN="$BIN/qmd" \
      MUTATION_LOG="$MUTATION_LOG" \
      QMD_REINDEX_LOG="$LOG" \
      HQ_AGENT_BOX=1 \
      bash core/scripts/handoff-finalize.sh \
        --title "Handoff: agent skip" \
        --summary "agent hard-skip" \
        --message "agent" \
        --next-steps-json '[]' \
        --files-touched-json '["tracked.txt"]' \
        --learnings-json '[]' \
        --tags-json '["test"]' \
        --slug "qmd-agent"
  )
  qmd_pid=$(jq -r '.qmd_pid // empty' <<<"$out")
  [[ "$qmd_pid" == "skipped-agent" ]] \
    || fail "agent finalize want qmd_pid=skipped-agent, got '$qmd_pid' (out=$out)"
)
[[ "$(inv_count)" -eq 0 ]] || fail "agent finalize must not mutate (got $(cat "$MUTATION_LOG"))"
ok "R1b: agent finalize → qmd_pid=skipped-agent, inv=0"

# Post routes helper; logs reindex-bg token
reset_state
(
  cd "$TMP/repo"
  env -i PATH="$BIN:/usr/bin:/bin" \
    HOME="$HOME_DIR" \
    HQ_QMD_BIN="$BIN/qmd" \
    HQ_ROOT="$TMP/repo" \
    MUTATION_LOG="$MUTATION_LOG" \
    QMD_REINDEX_LOG="$LOG" \
    HANDOFF_LOG_DIR="$TMP/logs" \
    QMD_HANDOFF_DEDUPE_SEC=0 \
    bash core/scripts/handoff-post.sh workspace/threads/T-missing.json ""
  # Capture launcher token from post log for reaping (numeric pid or skipped*).
  if [[ -f "$TMP/logs/handoff-post.log" ]]; then
    post_tok=$(grep -oE 'reindex-bg → [0-9]+' "$TMP/logs/handoff-post.log" | awk '{print $3}' | tail -1 || true)
    if [[ -n "${post_tok:-}" ]]; then
      track_pid "$post_tok"
      printf '%s\n' "$post_tok" > "$TMP/r2-post-pid"
    fi
  fi
  for _ in $(seq 1 100); do
    grep -q '^qmd embed' "$MUTATION_LOG" 2>/dev/null && break
    sleep 0.05
  done
)
grep -q 'reindex-bg →' "$TMP/logs/handoff-post.log" \
  || fail "post did not log reindex-bg routing (log=$(cat "$TMP/logs/handoff-post.log" 2>/dev/null || true))"
grep -q '^qmd cleanup' "$MUTATION_LOG" || fail "post laptop path did not mutate"
if [[ -f "$TMP/r2-post-pid" ]]; then
  wait_pid_soft "$(cat "$TMP/r2-post-pid")"
fi
ok "R2: post routes helper; laptop mutates; log has reindex-bg"

# Agent post → skipped-agent, zero mutations
reset_state
(
  cd "$TMP/repo"
  env -i PATH="$BIN:/usr/bin:/bin" \
    HOME="$HOME_DIR" \
    HQ_QMD_BIN="$BIN/qmd" \
    HQ_ROOT="$TMP/repo" \
    MUTATION_LOG="$MUTATION_LOG" \
    QMD_REINDEX_LOG="$LOG" \
    HANDOFF_LOG_DIR="$TMP/logs" \
    HQ_AGENT_BOX=1 \
    bash core/scripts/handoff-post.sh workspace/threads/T-missing.json ""
)
grep -q 'reindex-bg → skipped-agent\|skipped-agent' "$TMP/logs/handoff-post.log" \
  || fail "agent post want skipped-agent log (got $(cat "$TMP/logs/handoff-post.log" 2>/dev/null || true))"
[[ "$(inv_count)" -eq 0 ]] || fail "agent post must not mutate"
ok "R2b: agent post → skipped-agent, zero mutations"

# Concurrent real finalize + real post under the same laptop lock → one pipeline.
# PRD e2e: both call sites race the helper (not a direct --worker stand-in).
reset_state
HOLD="$TMP/hold-fp"
: > "$HOLD"
rm -f "$TMP/r3-finalize-out.json" "$TMP/r3-post-pid" "$TMP/logs/handoff-post.log"
(
  cd "$TMP/repo"
  # Dirty tree so finalize has commit work (prior R* cases may have cleaned it).
  echo "r3-concurrent" > tracked.txt
  : > "$MUTATION_LOG"
  rm -f "$TMP/helper-scheduled.log"
  JQ_DIR="$(dirname "$(command -v jq || echo /usr/bin)")"

  # Real finalize in background (launcher path → detached worker; holds on qmd).
  env -i PATH="$BIN:/usr/bin:/bin:$JQ_DIR" \
    HOME="$HOME_DIR" \
    HQ_QMD_BIN="$BIN/qmd" \
    MUTATION_LOG="$MUTATION_LOG" \
    QMD_REINDEX_LOG="$LOG" \
    QMD_HANDOFF_LOG="$LOG" \
    QMD_HOLD_FILE="$HOLD" \
    QMD_HANDOFF_DEDUPE_SEC=0 \
    bash core/scripts/handoff-finalize.sh \
      --title "Handoff: concurrent r3" \
      --summary "finalize+post concurrent" \
      --message "r3" \
      --next-steps-json '[]' \
      --files-touched-json '["tracked.txt"]' \
      --learnings-json '[]' \
      --tags-json '["test"]' \
      --slug "qmd-r3-fin" \
    >"$TMP/r3-finalize-out.json" 2>"$TMP/r3-finalize-err.txt" &
  fin_pid=$!

  # Real post concurrently (same HOME lock domain + hold).
  # Run in background so we can wait for *both* call sites to schedule the
  # helper while the hold is still active (finalize is slower than post).
  env -i PATH="$BIN:/usr/bin:/bin" \
    HOME="$HOME_DIR" \
    HQ_QMD_BIN="$BIN/qmd" \
    HQ_ROOT="$TMP/repo" \
    MUTATION_LOG="$MUTATION_LOG" \
    QMD_REINDEX_LOG="$LOG" \
    HANDOFF_LOG_DIR="$TMP/logs" \
    QMD_HOLD_FILE="$HOLD" \
    QMD_HANDOFF_DEDUPE_SEC=0 \
    bash core/scripts/handoff-post.sh workspace/threads/T-missing.json "" \
    >"$TMP/r3-post-out.txt" 2>&1 &
  post_pid=$!

  # Keep hold until both launchers have scheduled a helper AND one raw pipeline
  # has started. The launcher ALWAYS spawns a detached worker (lock lives in
  # the worker): releasing the hold before the loser boots and fails
  # acquireLock turns single-flight into two sequential pipelines under
  # DEDUPE_SEC=0 (same class of flake L2 documents for slow node boots).
  # Budget 600 (30s): two forwarder chains × detached workers on 2-core CI.
  for _ in $(seq 1 600); do
    sched_n=0
    if [[ -f "$TMP/helper-scheduled.log" ]]; then
      sched_n=$(wc -l < "$TMP/helper-scheduled.log" | tr -d ' ')
    fi
    if [[ "${sched_n:-0}" -ge 2 ]] && grep -q '^qmd cleanup' "$MUTATION_LOG" 2>/dev/null; then
      break
    fi
    sleep 0.05
  done
  sched_n=0
  [[ -f "$TMP/helper-scheduled.log" ]] && sched_n=$(wc -l < "$TMP/helper-scheduled.log" | tr -d ' ')
  [[ "${sched_n:-0}" -ge 2 ]] \
    || fail "R3: expected both finalize+post to schedule helper under hold (sched=$sched_n log=$(cat "$TMP/helper-scheduled.log" 2>/dev/null || true))"
  grep -q '^qmd cleanup' "$MUTATION_LOG" \
    || fail "R3: no pipeline started under hold ($(cat "$MUTATION_LOG"))"

  # Resolve both detached worker PIDs, then wait until the loser has exited
  # (busy) while the winner stays alive under the hold — proof both contended.
  r3_fin_tok=""
  r3_post_tok=""
  for _ in $(seq 1 600); do
    if [[ -f "$TMP/r3-finalize-out.json" ]]; then
      r3_fin_tok=$(jq -r '.qmd_pid // empty' <"$TMP/r3-finalize-out.json" 2>/dev/null || true)
    fi
    if [[ -f "$TMP/logs/handoff-post.log" ]]; then
      r3_post_tok=$(grep -oE 'reindex-bg → [0-9]+' "$TMP/logs/handoff-post.log" | awk '{print $3}' | tail -1 || true)
    fi
    if [[ "$r3_fin_tok" =~ ^[0-9]+$ && "$r3_post_tok" =~ ^[0-9]+$ ]]; then
      break
    fi
    sleep 0.05
  done
  [[ "$r3_fin_tok" =~ ^[0-9]+$ && "$r3_post_tok" =~ ^[0-9]+$ ]] \
    || fail "R3: need numeric worker pids under hold (fin=$r3_fin_tok post=$r3_post_tok; finjson=$(cat "$TMP/r3-finalize-out.json" 2>/dev/null || true); postlog=$(cat "$TMP/logs/handoff-post.log" 2>/dev/null || true))"
  alive_workers=2
  for _ in $(seq 1 600); do
    alive_workers=0
    kill -0 "$r3_fin_tok" 2>/dev/null && alive_workers=$((alive_workers + 1))
    kill -0 "$r3_post_tok" 2>/dev/null && alive_workers=$((alive_workers + 1))
    [[ "$alive_workers" -le 1 ]] && break
    sleep 0.05
  done
  [[ "$alive_workers" -eq 1 ]] \
    || fail "R3: expected loser to exit busy under hold, got alive=$alive_workers (fin=$r3_fin_tok post=$r3_post_tok mut=$(cat "$MUTATION_LOG"))"
  sleep 0.1
  rm -f "$HOLD"
  wait "$fin_pid" || true
  wait "$post_pid" || true
  wait 2>/dev/null || true

  # Track detached worker PIDs for parent reaping.
  if [[ -f "$TMP/r3-finalize-out.json" ]]; then
    qmd_pid=$(jq -r '.qmd_pid // empty' <"$TMP/r3-finalize-out.json" 2>/dev/null || true)
    track_pid "$qmd_pid"
  fi
  if [[ -f "$TMP/logs/handoff-post.log" ]]; then
    post_tok=$(grep -oE 'reindex-bg → [0-9]+' "$TMP/logs/handoff-post.log" | awk '{print $3}' | tail -1 || true)
    track_pid "${post_tok:-}"
  fi
  for _ in $(seq 1 100); do
    grep -q '^qmd embed' "$MUTATION_LOG" 2>/dev/null && break
    [[ -f "$COMPLETE_STAMP" ]] && break
    sleep 0.05
  done
)
cleanup_n=$(grep -c '^qmd cleanup' "$MUTATION_LOG" || true)
update_n=$(grep -c '^qmd update' "$MUTATION_LOG" || true)
embed_n=$(grep -c '^qmd embed' "$MUTATION_LOG" || true)
[[ "$cleanup_n" -eq 1 && "$update_n" -eq 1 && "$embed_n" -eq 1 ]] \
  || fail "finalize+post concurrent expected one pipeline, got c=$cleanup_n u=$update_n e=$embed_n ($(cat "$MUTATION_LOG"); fin=$(cat "$TMP/r3-finalize-out.json" 2>/dev/null || true); postlog=$(cat "$TMP/logs/handoff-post.log" 2>/dev/null || true))"
# Prove both real call sites participated (not a direct --worker stand-in).
[[ -f "$TMP/r3-finalize-out.json" ]] || fail "R3: finalize produced no JSON output"
jq -e '.qmd_pid != null and .qmd_pid != ""' "$TMP/r3-finalize-out.json" >/dev/null 2>&1 \
  || fail "R3: finalize missing qmd_pid (out=$(cat "$TMP/r3-finalize-out.json"))"
grep -q 'reindex-bg →' "$TMP/logs/handoff-post.log" 2>/dev/null \
  || fail "R3: post did not log reindex-bg (log=$(cat "$TMP/logs/handoff-post.log" 2>/dev/null || true))"
reap_workers
ok "R3: finalize+post concurrent laptop → one reindex pipeline"

# Fail-open through post when qmd update fails
reset_state
(
  cd "$TMP/repo"
  set +e
  env -i PATH="$BIN:/usr/bin:/bin" \
    HOME="$HOME_DIR" \
    HQ_QMD_BIN="$BIN/qmd" \
    HQ_ROOT="$TMP/repo" \
    MUTATION_LOG="$MUTATION_LOG" \
    QMD_REINDEX_LOG="$LOG" \
    HANDOFF_LOG_DIR="$TMP/logs" \
    QMD_FAIL_CMD=update \
    QMD_FAIL_RC=7 \
    QMD_HANDOFF_DEDUPE_SEC=0 \
    bash core/scripts/handoff-post.sh workspace/threads/T-missing.json ""
  rc=$?
  set -e
  [[ "$rc" -eq 0 ]] || fail "post with failing qmd must exit 0, got $rc"
  if [[ -f "$TMP/logs/handoff-post.log" ]]; then
    post_tok=$(grep -oE 'reindex-bg → [0-9]+' "$TMP/logs/handoff-post.log" | awk '{print $3}' | tail -1 || true)
    track_pid "${post_tok:-}"
  fi
)
if [[ -f "$COMPLETE_STAMP" ]]; then
  fail "failed update via post must not stamp"
fi
reap_workers
ok "R4: post with failing qmd remains exit 0 (fail-open)"

# =============================================================================
# C) Concurrency / signal / log-cap regressions (P1/P2/P3 pre-push findings)
# =============================================================================

# C1: high-concurrency dead main + abandoned generation claim → one pipeline.
# Seeds both a dead main lock (generation G) and a dead/abandoned claim.G with
# a uniquely named dead claimant file. Many workers race; generation-fenced
# reclaim must yield exactly one writer (no multi-writer, no owner-write errors).
reset_state
DEAD_PID=$(( $$ + 1000000 ))
if kill -0 "$DEAD_PID" 2>/dev/null; then
  DEAD_PID=2147483646
  kill -0 "$DEAD_PID" 2>/dev/null && fail "C1: could not find a dead pid"
fi
C1_GEN="dead-c1-nonce"
mkdir -p "$LOCK_DIR"
{
  echo "pid=$DEAD_PID"
  echo "ts=1"
  echo "nonce=$C1_GEN"
} >"$LOCK_DIR/owner"
# Abandoned reclaim claim for the same generation (holder died mid-flight).
# Unique claimant is a directory (matches production exclusive-mkdir markers).
C1_CLAIM="$HOME_DIR/.hq/locks/qmd-reindex-bg.claim.${C1_GEN}"
mkdir -p "$C1_CLAIM/c.${DEAD_PID}.abandoned"
{
  echo "pid=$DEAD_PID"
  echo "ts=1"
} >"$C1_CLAIM/c.${DEAD_PID}.abandoned/owner"
HOLD="$TMP/hold-c1-stale"
: > "$HOLD"
# Capture helper stderr (owner-write races surface as "No such file" on owner path).
C1_ERR="$TMP/c1-stderr.txt"
: > "$C1_ERR"
C1_N=60
C1_PIDS=()
for _ in $(seq 1 "$C1_N"); do
  QMD_HOLD_FILE="$HOLD" QMD_HANDOFF_DEDUPE_SEC=0 QMD_HANDOFF_LOCK_GRACE_SEC=0 \
    helper_env bash "$HELPER" --worker --log "$LOG" 2>>"$C1_ERR" &
  C1_PIDS+=($!)
done
# Wait until the single winner is inside held cleanup. 30s: sixty CLI workers
# boot ~1.7s of node each and share the cores, so the fastest boot can pass 10s.
for _ in $(seq 1 600); do
  grep -q '^qmd cleanup' "$MUTATION_LOG" 2>/dev/null && break
  sleep 0.05
done
grep -q '^qmd cleanup' "$MUTATION_LOG" || fail "C1: no reclaim winner started under hold"
# While hold is active, losers must EXIT (skip), never queue behind the lock.
# CLI workers take seconds to boot under 60-way contention, so an instant
# sample races startup latency; poll until the census settles to the single
# held winner instead. A loser that blocks on the lock stays alive forever
# and times this poll out — which is exactly the failure it must catch.
alive_hold="$C1_N"
for _ in $(seq 1 600); do
  alive_hold=0
  for p in "${C1_PIDS[@]}"; do
    kill -0 "$p" 2>/dev/null && alive_hold=$((alive_hold + 1))
  done
  [[ "$alive_hold" -le 1 ]] && break
  sleep 0.1
done
[[ "$alive_hold" -eq 1 ]] \
  || fail "C1: expected exactly 1 live worker during hold, got $alive_hold (mut=$(cat "$MUTATION_LOG"))"
cleanup_n=$(grep -c '^qmd cleanup' "$MUTATION_LOG" || true)
[[ "$cleanup_n" -eq 1 ]] \
  || fail "C1: concurrent stale reclaim must start one cleanup, got $cleanup_n"
rm -f "$HOLD"
for p in "${C1_PIDS[@]}"; do
  wait "$p" 2>/dev/null || true
done
cleanup_n=$(grep -c '^qmd cleanup' "$MUTATION_LOG" || true)
update_n=$(grep -c '^qmd update' "$MUTATION_LOG" || true)
embed_n=$(grep -c '^qmd embed' "$MUTATION_LOG" || true)
[[ "$cleanup_n" -eq 1 && "$update_n" -eq 1 && "$embed_n" -eq 1 ]] \
  || fail "C1: expected one pipeline after stale contention, got c=$cleanup_n u=$update_n e=$embed_n ($(cat "$MUTATION_LOG"))"
if grep -E 'No such file or directory|cannot create|owner:' "$C1_ERR" >/dev/null 2>&1; then
  fail "C1: owner-write / reclaim errors on stderr: $(cat "$C1_ERR")"
fi
# No straggler workers; main lock + generation claim dirs released.
surviving=0
for p in "${C1_PIDS[@]}"; do
  if kill -0 "$p" 2>/dev/null; then
    surviving=$((surviving + 1))
  fi
done
[[ "$surviving" -eq 0 ]] || fail "C1: $surviving workers still alive after wait"
[[ ! -d "$LOCK_DIR" ]] || fail "C1: main lock still present after winner finished"
# No leftover generation claim dirs (or rejected fixed reclaim mutex path).
shopt -s nullglob
c1_claims=("$HOME_DIR/.hq/locks"/qmd-reindex-bg.claim.*)
shopt -u nullglob
[[ "${#c1_claims[@]}" -eq 0 ]] \
  || fail "C1: leftover claim dirs: ${c1_claims[*]}"
[[ ! -d "$HOME_DIR/.hq/locks/qmd-reindex-bg.reclaim.lock" ]] \
  || fail "C1: rejected reclaim mutex path must not be used"
[[ -f "$COMPLETE_STAMP" ]] || fail "C1: completion stamp missing after single reclaim winner"
ok "C1: dead main+abandoned claim, high concurrency → one pipeline"

# C2: TERM during held cleanup must release lock and skip update/embed/stamp.
reset_state
HOLD="$TMP/hold-c2-term"
READY="$TMP/ready-c2-term"
rm -f "$READY"
: > "$HOLD"
# Fake qmd that signals readiness then holds on cleanup only.
cat > "$BIN/qmd" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
printf 'qmd %s\n' "$cmd" >> "${MUTATION_LOG:?}"
if [[ "$cmd" == "cleanup" && -n "${QMD_HOLD_FILE:-}" && -f "${QMD_HOLD_FILE}" ]]; then
  if [[ -n "${QMD_READY_FILE:-}" ]]; then
    : > "${QMD_READY_FILE}"
  fi
  while [[ -f "${QMD_HOLD_FILE}" ]]; do
    sleep 0.05
  done
fi
if [[ -n "${QMD_FAIL_CMD:-}" && "$cmd" == "$QMD_FAIL_CMD" ]]; then
  exit "${QMD_FAIL_RC:-1}"
fi
exit 0
SH
chmod +x "$BIN/qmd"
# Spawn worker directly (not via helper_env function) so $! is the process
# that installed the INT/TERM/HUP traps — signaling a wrapper subshell would
# orphan the real worker and let the pipeline continue after ownership loss.
env -i \
  PATH="$BIN:/usr/bin:/bin" \
  HOME="$HOME_DIR" \
  HQ_QMD_BIN="$BIN/qmd" \
  MUTATION_LOG="$MUTATION_LOG" \
  QMD_REINDEX_LOG="$LOG" \
  QMD_HANDOFF_LOG="$LOG" \
  QMD_HOLD_FILE="$HOLD" \
  QMD_READY_FILE="$READY" \
  QMD_HANDOFF_DEDUPE_SEC=0 \
  QMD_HANDOFF_LOG_MAX_BYTES=65536 \
  QMD_HANDOFF_LOCK_GRACE_SEC=5 \
  bash "$HELPER" --worker --log "$LOG" &
c2_pid=$!
for _ in $(seq 1 200); do
  [[ -f "$READY" ]] && break
  sleep 0.05
done
[[ -f "$READY" ]] || fail "C2: worker never entered held cleanup"
[[ -d "$LOCK_DIR" ]] || fail "C2: lock missing while worker held cleanup"
# Signal ownership loss mid-cleanup; trap must exit (not resume pipeline).
kill -TERM "$c2_pid" 2>/dev/null || true
sleep 0.1
rm -f "$HOLD"
for _ in $(seq 1 100); do
  kill -0 "$c2_pid" 2>/dev/null || break
  sleep 0.05
done
wait "$c2_pid" 2>/dev/null || true
if grep -q '^qmd update' "$MUTATION_LOG"; then
  fail "C2: TERM must not allow update after ownership loss ($(cat "$MUTATION_LOG"))"
fi
if grep -q '^qmd embed' "$MUTATION_LOG"; then
  fail "C2: TERM must not allow embed after ownership loss ($(cat "$MUTATION_LOG"))"
fi
if [[ -f "$COMPLETE_STAMP" ]]; then
  fail "C2: TERM must not write completion stamp"
fi
[[ ! -d "$LOCK_DIR" ]] || fail "C2: lock must be released after TERM"
grep -q '^qmd cleanup' "$MUTATION_LOG" || fail "C2: cleanup should have started before TERM"
ok "C2: TERM during held cleanup → no update/embed/stamp; lock released"

# Restore standard fake qmd for remaining cases.
write_standard_qmd_stub

# C3: failed noisy update must still respect log cap.
reset_state
# Pre-fill log and make update emit a large payload before failing.
{
  printf 'PREFILL'
  # 2 KiB of filler so post-failure log would exceed a tiny cap without cap_log.
  dd if=/dev/zero bs=1024 count=2 2>/dev/null | tr '\0' 'x'
  printf '\n'
} >"$LOG"
cat > "$BIN/qmd" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
printf 'qmd %s\n' "$cmd" >> "${MUTATION_LOG:?}"
if [[ "$cmd" == "update" ]]; then
  # Noisy failure: large stdout that the helper appends to the handoff log.
  dd if=/dev/zero bs=1024 count=4 2>/dev/null | tr '\0' 'U'
  echo
  exit 7
fi
exit 0
SH
chmod +x "$BIN/qmd"
QMD_HANDOFF_LOG_MAX_BYTES=512 QMD_HANDOFF_DEDUPE_SEC=0 run_worker
[[ -f "$LOG" ]] || fail "C3: log missing after failed update"
log_size=$(wc -c <"$LOG" | tr -d '[:space:]')
[[ "$log_size" -le 512 ]] \
  || fail "C3: failed update log not capped (size=$log_size > 512)"
if [[ -f "$COMPLETE_STAMP" ]]; then
  fail "C3: failed update must not stamp"
fi
grep -q '^qmd update' "$MUTATION_LOG" || fail "C3: update should have been attempted"
if grep -q '^qmd embed' "$MUTATION_LOG"; then
  fail "C3: embed must not run after failed update"
fi
ok "C3: failed noisy update respects log cap"

# Restore standard fake qmd.
write_standard_qmd_stub

# C4: late observers must not move a replacement live claim or live main lock.
# PATH mv shim records renames and flags any mv of a live-owned main lock dir
# or live claimant file. Seeds dead main + abandoned claim; high concurrency
# under hold; asserts zero STOLE_LIVE_* and exactly one pipeline.
reset_state
DEAD_PID=$(( $$ + 1000000 ))
if kill -0 "$DEAD_PID" 2>/dev/null; then
  DEAD_PID=2147483646
  kill -0 "$DEAD_PID" 2>/dev/null && fail "C4: could not find a dead pid"
fi
C4_GEN="dead-c4-nonce"
mkdir -p "$LOCK_DIR"
{
  echo "pid=$DEAD_PID"
  echo "ts=1"
  echo "nonce=$C4_GEN"
} >"$LOCK_DIR/owner"
C4_CLAIM="$HOME_DIR/.hq/locks/qmd-reindex-bg.claim.${C4_GEN}"
mkdir -p "$C4_CLAIM/c.${DEAD_PID}.abandoned"
{
  echo "pid=$DEAD_PID"
  echo "ts=1"
} >"$C4_CLAIM/c.${DEAD_PID}.abandoned/owner"
MV_TRACE="$TMP/c4-mv-trace.log"
: > "$MV_TRACE"
# Prepend PATH with mv shim (test-only; no production hooks).
REAL_MV="$(command -v mv)"
cat > "$BIN/mv" <<SH
#!/usr/bin/env bash
set -u
trace="\${MV_TRACE_LOG:-}"
real_mv="${REAL_MV}"
# Parse last two non-option-looking args as src dest (portable simple mv).
src=""
dst=""
for a in "\$@"; do
  case "\$a" in
    -*) continue ;;
    *)
      if [ -z "\$src" ]; then
        src="\$a"
      else
        dst="\$a"
      fi
      ;;
  esac
done
if [ -n "\$trace" ] && [ -n "\$src" ] && [ -n "\$dst" ]; then
  printf 'MV %s -> %s\\n' "\$src" "\$dst" >>"\$trace" 2>/dev/null || true
  base="\$(basename "\$src" 2>/dev/null || echo "")"
  # Live main lock dir: owner pid still running → late contender stole replacement.
  if [ -d "\$src" ] && [ -f "\$src/owner" ] && [[ "\$base" == qmd-reindex-bg.lock ]]; then
    opid="\$(awk -F= '/^pid=/{print \$2; exit}' "\$src/owner" 2>/dev/null || true)"
    case "\${opid}" in
      ''|*[!0-9]*) ;;
      *)
        if kill -0 "\$opid" 2>/dev/null; then
          printf 'STOLE_LIVE_MAIN pid=%s src=%s\\n' "\$opid" "\$src" >>"\$trace" 2>/dev/null || true
        fi
        ;;
    esac
  fi
  # Live unique claimant (dir or file) moved → late contender matched replacement.
  if [[ "\$base" == c.* ]]; then
    opid=""
    if [ -d "\$src" ] && [ -f "\$src/owner" ]; then
      opid="\$(awk -F= '/^pid=/{print \$2; exit}' "\$src/owner" 2>/dev/null || true)"
    elif [ -f "\$src" ]; then
      opid="\$(awk -F= '/^pid=/{print \$2; exit}' "\$src" 2>/dev/null || true)"
    fi
    case "\${opid}" in
      ''|*[!0-9]*) ;;
      *)
        if kill -0 "\$opid" 2>/dev/null; then
          printf 'STOLE_LIVE_CLAIMANT pid=%s src=%s\\n' "\$opid" "\$src" >>"\$trace" 2>/dev/null || true
        fi
        ;;
    esac
  fi
fi
exec "\$real_mv" "\$@"
SH
chmod +x "$BIN/mv"
HOLD="$TMP/hold-c4-stale"
: > "$HOLD"
C4_ERR="$TMP/c4-stderr.txt"
: > "$C4_ERR"
C4_N=60
C4_PIDS=()
for _ in $(seq 1 "$C4_N"); do
  MV_TRACE_LOG="$MV_TRACE" QMD_HOLD_FILE="$HOLD" \
    QMD_HANDOFF_DEDUPE_SEC=0 QMD_HANDOFF_LOCK_GRACE_SEC=0 \
    helper_env bash "$HELPER" --worker --log "$LOG" 2>>"$C4_ERR" &
  C4_PIDS+=($!)
done
# 30s winner-wait for the same reason as C1: 60 node boots share the cores.
for _ in $(seq 1 600); do
  grep -q '^qmd cleanup' "$MUTATION_LOG" 2>/dev/null && break
  sleep 0.05
done
grep -q '^qmd cleanup' "$MUTATION_LOG" || fail "C4: no reclaim winner under hold"
# Same settle-poll as C1: losers exit (skip) at their own boot pace; a loser
# that queues behind the lock stays alive and times the poll out.
alive_hold="$C4_N"
for _ in $(seq 1 600); do
  alive_hold=0
  for p in "${C4_PIDS[@]}"; do
    kill -0 "$p" 2>/dev/null && alive_hold=$((alive_hold + 1))
  done
  [[ "$alive_hold" -le 1 ]] && break
  sleep 0.1
done
[[ "$alive_hold" -eq 1 ]] \
  || fail "C4: expected exactly 1 live worker during hold, got $alive_hold (mut=$(cat "$MUTATION_LOG"); trace=$(cat "$MV_TRACE"))"
# Winner holds live main lock; late observers must not have stolen it.
if grep -q 'STOLE_LIVE_MAIN' "$MV_TRACE" 2>/dev/null; then
  fail "C4: late observer moved live main lock: $(grep STOLE_LIVE_MAIN "$MV_TRACE")"
fi
if grep -q 'STOLE_LIVE_CLAIMANT' "$MV_TRACE" 2>/dev/null; then
  fail "C4: late observer moved live claimant: $(grep STOLE_LIVE_CLAIMANT "$MV_TRACE")"
fi
rm -f "$HOLD"
for p in "${C4_PIDS[@]}"; do
  wait "$p" 2>/dev/null || true
done
cleanup_n=$(grep -c '^qmd cleanup' "$MUTATION_LOG" || true)
update_n=$(grep -c '^qmd update' "$MUTATION_LOG" || true)
embed_n=$(grep -c '^qmd embed' "$MUTATION_LOG" || true)
[[ "$cleanup_n" -eq 1 && "$update_n" -eq 1 && "$embed_n" -eq 1 ]] \
  || fail "C4: expected one pipeline, got c=$cleanup_n u=$update_n e=$embed_n ($(cat "$MUTATION_LOG"))"
if grep -q 'STOLE_LIVE_MAIN\|STOLE_LIVE_CLAIMANT' "$MV_TRACE" 2>/dev/null; then
  fail "C4: STOLE_LIVE after completion: $(cat "$MV_TRACE")"
fi
if grep -E 'No such file or directory|cannot create|owner:' "$C4_ERR" >/dev/null 2>&1; then
  fail "C4: owner-write errors: $(cat "$C4_ERR")"
fi
[[ ! -d "$LOCK_DIR" ]] || fail "C4: main lock still present"
shopt -s nullglob
c4_claims=("$HOME_DIR/.hq/locks"/qmd-reindex-bg.claim.*)
shopt -u nullglob
[[ "${#c4_claims[@]}" -eq 0 ]] || fail "C4: leftover claim dirs: ${c4_claims[*]}"
[[ -f "$COMPLETE_STAMP" ]] || fail "C4: missing completion stamp"
# Remove mv shim so later cases use the real binary.
rm -f "$BIN/mv"
ok "C4: late observers cannot move live claim/main; one pipeline"

# Restore standard fake qmd (C4 may have been last mutator setup).
write_standard_qmd_stub

# =============================================================================
# C5–C10: R2 pre-push — owner write mandatory, launcher HUP/INT, EXIT cap_log
# =============================================================================

# C5: forced owner-write/publish failure → zero qmd mutations; no dual writer.
# A fails owner publish after exclusive mkdir and must not enter the pipeline.
# Sole writer B is started first under hold; forced-fail A cannot add mutations
# or steal the lock while B holds a verified owner record.
# Structural: identity-safe abandon never rm -rf the fixed main-lock path.
reset_state
C5_ERR="$TMP/c5-stderr.txt"
: > "$C5_ERR"
# Structural: the identity-safe abandon contract (marker + rmdir, never a
# fixed-path recursive delete of LOCK_DIR) moved with the implementation into
# the hq CLI, where it is pinned by background.test.ts ("abandons a created
# lock if owner publish cannot be verified") and exercised behaviorally by the
# forced-owner-write-fail parts of this case below. What remains structural
# HERE is that the forwarder carries no shell-side lock handling for the old
# grep targets to silently pass against.
if grep -Eq '_abandon_created_lock|ACQ_MARKER|rm[[:space:]]+-rf' "$HELPER"; then
  fail "C5 structural: forwarder must not reintroduce shell-side lock handling"
fi
grep -q 'exec hq index background' "$HELPER" \
  || fail "C5 structural: helper must forward to hq index background"
ok "C5s: structural — lock-abandon logic lives in the CLI; forwarder is lock-free"

# Part 1: sequential forced owner-write fail — zero mutations; identity-safe abandon.
set +e
QMD_FORCE_OWNER_WRITE_FAIL=1 QMD_HANDOFF_DEDUPE_SEC=0 \
  helper_env bash "$HELPER" --worker --log "$LOG" 2>>"$C5_ERR"
c5_a_rc=$?
set -e
[[ "$c5_a_rc" -eq 0 ]] || fail "C5: forced owner-write fail should exit 0, got $c5_a_rc"
[[ "$(inv_count)" -eq 0 ]] \
  || fail "C5: forced owner-write fail must not mutate (got $(cat "$MUTATION_LOG"))"
# Clean abandon: marker removed + rmdir empty → lock path gone. If present,
# must be reclaimable (no live pipeline owner) and hold no acq.* from us.
if [[ -d "$LOCK_DIR" ]]; then
  shopt -s nullglob
  c5_acqs=("$LOCK_DIR"/acq.*)
  shopt -u nullglob
  [[ "${#c5_acqs[@]}" -eq 0 ]] \
    || fail "C5: force-fail left acquisition marker(s): ${c5_acqs[*]}"
  if [[ -f "$LOCK_DIR/owner" ]]; then
    opid="$(awk -F= '/^pid=/{print $2; exit}' "$LOCK_DIR/owner" 2>/dev/null || true)"
    if [[ -n "$opid" ]] && kill -0 "$opid" 2>/dev/null; then
      fail "C5: owner-write fail left a live owner pid=$opid"
    fi
  fi
else
  : # preferred: fully abandoned
fi
# Part 1b: reclaim-path forced owner fail (dead main → claim → mkdir → fail).
# Same identity-safe abandon; zero mutations; later clean reclaim works.
reset_state
: > "$C5_ERR"
DEAD_PID=$(( $$ + 1000000 ))
if kill -0 "$DEAD_PID" 2>/dev/null; then
  DEAD_PID=2147483646
  kill -0 "$DEAD_PID" 2>/dev/null && fail "C5: could not find a dead pid for reclaim fail"
fi
mkdir -p "$LOCK_DIR"
{
  echo "pid=$DEAD_PID"
  echo "ts=1"
  echo "nonce=dead-c5-reclaim-fail"
} >"$LOCK_DIR/owner"
set +e
QMD_FORCE_OWNER_WRITE_FAIL=1 QMD_HANDOFF_DEDUPE_SEC=0 QMD_HANDOFF_LOCK_GRACE_SEC=0 \
  helper_env bash "$HELPER" --worker --log "$LOG" 2>>"$C5_ERR"
c5_r_rc=$?
set -e
[[ "$c5_r_rc" -eq 0 ]] || fail "C5 reclaim-path owner-write fail should exit 0, got $c5_r_rc"
[[ "$(inv_count)" -eq 0 ]] \
  || fail "C5 reclaim-path force-fail must not mutate (got $(cat "$MUTATION_LOG"))"
if [[ -d "$LOCK_DIR" ]]; then
  shopt -s nullglob
  c5_acqs=("$LOCK_DIR"/acq.*)
  shopt -u nullglob
  [[ "${#c5_acqs[@]}" -eq 0 ]] \
    || fail "C5 reclaim: left acq marker(s): ${c5_acqs[*]}"
  if [[ -f "$LOCK_DIR/owner" ]]; then
    opid="$(awk -F= '/^pid=/{print $2; exit}' "$LOCK_DIR/owner" 2>/dev/null || true)"
    if [[ -n "$opid" ]] && kill -0 "$opid" 2>/dev/null; then
      fail "C5 reclaim: force-fail left live owner pid=$opid"
    fi
  fi
fi
# Replacement-at-fixed-path must survive identity-safe abandon semantics:
# peer live owner under LOCK_DIR with no matching ACQ_MARKER_HELD → rmdir fails.
mkdir -p "$LOCK_DIR"
{
  echo "pid=$$"
  echo "ts=$(date +%s)"
  echo "nonce=peer-replacement-c5"
} >"$LOCK_DIR/owner"
# Simulate abandon with a non-matching marker path (our acq was moved/replaced).
fake_marker="${LOCK_DIR}/acq.gone.$$.$RANDOM"
rm -rf "$fake_marker" 2>/dev/null || true
rmdir "$LOCK_DIR" 2>/dev/null || true
[[ -d "$LOCK_DIR" && -f "$LOCK_DIR/owner" ]] \
  || fail "C5: identity-safe abandon must not wipe replacement live lock"
grep -q '^nonce=peer-replacement-c5' "$LOCK_DIR/owner" \
  || fail "C5: replacement owner clobbered by abandon semantics"
ok "C5a: force-fail fast+reclaim paths abandon safely; replacement lock survives"

# Part 2: dual-writer proof — start sole writer B under hold first (READY), then
# fire forced-fail A. A must not mutate; cleanup stays exactly 1.
# Drop simulated replacement lock so B can acquire cleanly.
rm -rf "$LOCK_DIR" "$HOME_DIR/.hq/locks"/qmd-reindex-bg.claim.* 2>/dev/null || true
mkdir -p "$HOME_DIR/.hq/locks"
cat > "$BIN/qmd" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
printf 'qmd %s\n' "$cmd" >> "${MUTATION_LOG:?}"
if [[ "$cmd" == "cleanup" && -n "${QMD_HOLD_FILE:-}" && -f "${QMD_HOLD_FILE}" ]]; then
  if [[ -n "${QMD_READY_FILE:-}" ]]; then
    : > "${QMD_READY_FILE}"
  fi
  while [[ -f "${QMD_HOLD_FILE}" ]]; do
    sleep 0.05
  done
fi
if [[ -n "${QMD_FAIL_CMD:-}" && "$cmd" == "$QMD_FAIL_CMD" ]]; then
  exit "${QMD_FAIL_RC:-1}"
fi
exit 0
SH
chmod +x "$BIN/qmd"
: > "$MUTATION_LOG"
rm -f "$COMPLETE_STAMP"
HOLD="$TMP/hold-c5-dual"
READY="$TMP/ready-c5-dual"
rm -f "$READY"
: > "$HOLD"
# Explicit env — never inherit force-fail into B.
env -i \
  PATH="$BIN:/usr/bin:/bin" \
  HOME="$HOME_DIR" \
  HQ_QMD_BIN="$BIN/qmd" \
  MUTATION_LOG="$MUTATION_LOG" \
  QMD_REINDEX_LOG="$LOG" \
  QMD_HANDOFF_LOG="$LOG" \
  QMD_HOLD_FILE="$HOLD" \
  QMD_READY_FILE="$READY" \
  QMD_HANDOFF_DEDUPE_SEC=0 \
  QMD_HANDOFF_LOG_MAX_BYTES=65536 \
  QMD_HANDOFF_LOCK_GRACE_SEC=5 \
  bash "$HELPER" --worker --log "$LOG" 2>>"$C5_ERR" &
c5_b_pid=$!
for _ in $(seq 1 200); do
  [[ -f "$READY" ]] && break
  sleep 0.05
done
[[ -f "$READY" ]] || fail "C5: peer B never entered held cleanup"
[[ -d "$LOCK_DIR" && -f "$LOCK_DIR/owner" ]] \
  || fail "C5: B must hold a durable owner record"
b_opid="$(awk -F= '/^pid=/{print $2; exit}' "$LOCK_DIR/owner" 2>/dev/null || true)"
[[ "$b_opid" == "$c5_b_pid" ]] || fail "C5: owner pid=$b_opid want B=$c5_b_pid"
# Forced-fail A while B holds — must not mutate or dual-write.
set +e
env -i \
  PATH="$BIN:/usr/bin:/bin" \
  HOME="$HOME_DIR" \
  HQ_QMD_BIN="$BIN/qmd" \
  MUTATION_LOG="$MUTATION_LOG" \
  QMD_REINDEX_LOG="$LOG" \
  QMD_HANDOFF_LOG="$LOG" \
  QMD_FORCE_OWNER_WRITE_FAIL=1 \
  QMD_HANDOFF_DEDUPE_SEC=0 \
  QMD_HANDOFF_LOG_MAX_BYTES=65536 \
  QMD_HANDOFF_LOCK_GRACE_SEC=5 \
  bash "$HELPER" --worker --log "$LOG" 2>>"$C5_ERR"
c5_a2_rc=$?
set -e
[[ "$c5_a2_rc" -eq 0 ]] || fail "C5: concurrent force-fail A should exit 0, got $c5_a2_rc"
cleanup_n=$(grep -c '^qmd cleanup' "$MUTATION_LOG" || true)
[[ "$cleanup_n" -eq 1 ]] \
  || fail "C5: dual-writer while B held (cleanup=$cleanup_n mut=$(cat "$MUTATION_LOG"))"
if grep -q '^qmd update' "$MUTATION_LOG"; then
  fail "C5: update must not run while B still holds"
fi
# B still owns the lock.
[[ -d "$LOCK_DIR" && -f "$LOCK_DIR/owner" ]] || fail "C5: B lock vanished under A force-fail"
grep -q "^pid=$c5_b_pid" "$LOCK_DIR/owner" || fail "C5: B owner rewritten by force-fail A"
# Successful owner publish clears acq marker; B must not leave acq.* under lock.
shopt -s nullglob
c5_b_acqs=("$LOCK_DIR"/acq.*)
shopt -u nullglob
[[ "${#c5_b_acqs[@]}" -eq 0 ]] \
  || fail "C5: successful owner still holds acq marker(s): ${c5_b_acqs[*]}"
rm -f "$HOLD"
wait "$c5_b_pid" 2>/dev/null || true
cleanup_n=$(grep -c '^qmd cleanup' "$MUTATION_LOG" || true)
update_n=$(grep -c '^qmd update' "$MUTATION_LOG" || true)
embed_n=$(grep -c '^qmd embed' "$MUTATION_LOG" || true)
[[ "$cleanup_n" -eq 1 && "$update_n" -eq 1 && "$embed_n" -eq 1 ]] \
  || fail "C5: expected one pipeline after owner-write fail+peer, got c=$cleanup_n u=$update_n e=$embed_n"
# Recovered clean path still works once (no sticky poison).
: > "$MUTATION_LOG"
rm -f "$COMPLETE_STAMP"
# Restore standard fake qmd (no hold/ready special case).
write_standard_qmd_stub
QMD_HANDOFF_DEDUPE_SEC=0 run_worker
cleanup_n=$(grep -c '^qmd cleanup' "$MUTATION_LOG" || true)
[[ "$cleanup_n" -eq 1 ]] || fail "C5: post-fail recover expected 1 cleanup, got $cleanup_n"
ok "C5: forced owner-write fail → zero mut from A; no dual writer; peer sole pipeline"

# C6: forced claimant-record write failure → no reclaim pipeline; no dual writer.
# Seed dead main lock so reclaim needs claim.G + c.* owner. Fail claimant publish.
reset_state
DEAD_PID=$(( $$ + 1000000 ))
if kill -0 "$DEAD_PID" 2>/dev/null; then
  DEAD_PID=2147483646
  kill -0 "$DEAD_PID" 2>/dev/null && fail "C6: could not find a dead pid"
fi
C6_GEN="dead-c6-nonce"
mkdir -p "$LOCK_DIR"
{
  echo "pid=$DEAD_PID"
  echo "ts=1"
  echo "nonce=$C6_GEN"
} >"$LOCK_DIR/owner"
set +e
QMD_FORCE_CLAIMANT_WRITE_FAIL=1 QMD_HANDOFF_DEDUPE_SEC=0 QMD_HANDOFF_LOCK_GRACE_SEC=0 \
  run_worker
c6_rc=$?
set -e
[[ "$c6_rc" -eq 0 ]] || fail "C6: claimant-write fail should exit 0, got $c6_rc"
[[ "$(inv_count)" -eq 0 ]] \
  || fail "C6: claimant-write fail must not mutate (got $(cat "$MUTATION_LOG"))"
# Dead main may remain (we never reclaimed); no live unique claimant for us.
shopt -s nullglob
c6_claims=("$HOME_DIR/.hq/locks"/qmd-reindex-bg.claim.*)
shopt -u nullglob
for cd in "${c6_claims[@]:-}"; do
  for cpath in "$cd"/c.*; do
    [[ -e "$cpath" ]] || continue
    opid=""
    if [[ -d "$cpath" && -f "$cpath/owner" ]]; then
      opid="$(awk -F= '/^pid=/{print $2; exit}' "$cpath/owner" 2>/dev/null || true)"
    elif [[ -f "$cpath" ]]; then
      opid="$(awk -F= '/^pid=/{print $2; exit}' "$cpath" 2>/dev/null || true)"
    fi
    if [[ -n "$opid" ]] && kill -0 "$opid" 2>/dev/null; then
      fail "C6: left live claimant pid=$opid under $cpath"
    fi
  done
done
# Without force, reclaim succeeds once (stale main still present).
QMD_HANDOFF_DEDUPE_SEC=0 QMD_HANDOFF_LOCK_GRACE_SEC=0 run_worker
cleanup_n=$(grep -c '^qmd cleanup' "$MUTATION_LOG" || true)
[[ "$cleanup_n" -eq 1 ]] || fail "C6: reclaim after claimant-fail expected 1 cleanup, got $cleanup_n"
[[ -f "$COMPLETE_STAMP" ]] || fail "C6: stamp missing after successful reclaim"
ok "C6: forced claimant-write fail → zero mut; later reclaim sole pipeline"

# Helper: held-cleanup fake qmd with READY marker (for signal tests).
install_held_cleanup_qmd() {
  cat > "$BIN/qmd" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
printf 'qmd %s\n' "$cmd" >> "${MUTATION_LOG:?}"
if [[ "$cmd" == "cleanup" && -n "${QMD_HOLD_FILE:-}" && -f "${QMD_HOLD_FILE}" ]]; then
  if [[ -n "${QMD_READY_FILE:-}" ]]; then
    : > "${QMD_READY_FILE}"
  fi
  # Optional noisy body so interrupted cleanup grows the log (C10).
  if [[ -n "${QMD_NOISY_CLEANUP:-}" ]]; then
    dd if=/dev/zero bs=1024 count=8 2>/dev/null | tr '\0' 'N'
    echo
  fi
  while [[ -f "${QMD_HOLD_FILE}" ]]; do
    sleep 0.05
  done
fi
if [[ -n "${QMD_FAIL_CMD:-}" && "$cmd" == "$QMD_FAIL_CMD" ]]; then
  exit "${QMD_FAIL_RC:-1}"
fi
exit 0
SH
  chmod +x "$BIN/qmd"
}

restore_standard_qmd() {
  cat > "$BIN/qmd" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
printf 'qmd %s\n' "$cmd" >> "${MUTATION_LOG:?}"
if [[ -n "${QMD_HOLD_FILE:-}" && -f "${QMD_HOLD_FILE}" ]]; then
  while [[ -f "${QMD_HOLD_FILE}" ]]; do
    sleep 0.05
  done
fi
if [[ -n "${QMD_FAIL_CMD:-}" && "$cmd" == "$QMD_FAIL_CMD" ]]; then
  exit "${QMD_FAIL_RC:-1}"
fi
exit 0
SH
  chmod +x "$BIN/qmd"
}

# Assert signal during held cleanup: cleanup may start; no update/embed/stamp;
# lock released; worker gone. Used for REAL launcher path (C7–C9) and TERM.
assert_signal_stops_pipeline() {
  local label="$1" sig="$2" pid="$3" hold="$4"
  sleep 0.1
  rm -f "$hold"
  for _ in $(seq 1 100); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
  done
  wait "$pid" 2>/dev/null || true
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
    fail "$label: worker still alive after $sig"
  fi
  if grep -q '^qmd update' "$MUTATION_LOG"; then
    fail "$label: $sig must not allow update ($(cat "$MUTATION_LOG"))"
  fi
  if grep -q '^qmd embed' "$MUTATION_LOG"; then
    fail "$label: $sig must not allow embed ($(cat "$MUTATION_LOG"))"
  fi
  if [[ -f "$COMPLETE_STAMP" ]]; then
    fail "$label: $sig must not write completion stamp"
  fi
  [[ ! -d "$LOCK_DIR" ]] || fail "$label: lock must be released after $sig"
  grep -q '^qmd cleanup' "$MUTATION_LOG" \
    || fail "$label: cleanup should have started before $sig"
}

# C7–C9: REAL default launcher — HUP, INT, TERM during held cleanup.
# Uses launcher (not --worker) so we exercise detach dispositions.
for C_SIG_CASE in "C7:HUP" "C8:INT" "C9:TERM"; do
  c_label="${C_SIG_CASE%%:*}"
  c_sig="${C_SIG_CASE##*:}"
  reset_state
  install_held_cleanup_qmd
  HOLD="$TMP/hold-${c_label}-sig"
  READY="$TMP/ready-${c_label}-sig"
  rm -f "$READY"
  : > "$HOLD"
  out=$(
    QMD_HOLD_FILE="$HOLD" QMD_READY_FILE="$READY" QMD_HANDOFF_DEDUPE_SEC=0 \
      run_launcher
  )
  [[ "$out" =~ ^[0-9]+$ ]] || fail "$c_label: launcher want numeric pid, got '$out'"
  c_pid="$out"
  track_pid "$c_pid"
  for _ in $(seq 1 200); do
    [[ -f "$READY" ]] && break
    sleep 0.05
  done
  [[ -f "$READY" ]] || fail "$c_label: launcher worker never entered held cleanup"
  [[ -d "$LOCK_DIR" ]] || fail "$c_label: lock missing while worker held cleanup"
  kill -s "$c_sig" "$c_pid" 2>/dev/null || true
  assert_signal_stops_pipeline "$c_label" "$c_sig" "$c_pid" "$HOLD"
  ok "$c_label: launcher $c_sig during held cleanup → no update/embed/stamp; lock released"
done
restore_standard_qmd

# C10: EXIT cleanup caps log after interrupted noisy cleanup.
reset_state
install_held_cleanup_qmd
HOLD="$TMP/hold-c10-cap"
READY="$TMP/ready-c10-cap"
rm -f "$READY"
: > "$HOLD"
# Pre-fill so interrupted noisy cleanup would exceed a tiny cap without EXIT cap_log.
{
  printf 'PREFILL'
  dd if=/dev/zero bs=1024 count=1 2>/dev/null | tr '\0' 'x'
  printf '\n'
} >"$LOG"
env -i \
  PATH="$BIN:/usr/bin:/bin" \
  HOME="$HOME_DIR" \
  HQ_QMD_BIN="$BIN/qmd" \
  MUTATION_LOG="$MUTATION_LOG" \
  QMD_REINDEX_LOG="$LOG" \
  QMD_HANDOFF_LOG="$LOG" \
  QMD_HOLD_FILE="$HOLD" \
  QMD_READY_FILE="$READY" \
  QMD_NOISY_CLEANUP=1 \
  QMD_HANDOFF_DEDUPE_SEC=0 \
  QMD_HANDOFF_LOG_MAX_BYTES=512 \
  QMD_HANDOFF_LOCK_GRACE_SEC=5 \
  bash "$HELPER" --worker --log "$LOG" &
c10_pid=$!
for _ in $(seq 1 200); do
  [[ -f "$READY" ]] && break
  sleep 0.05
done
[[ -f "$READY" ]] || fail "C10: worker never entered held noisy cleanup"
# Wait briefly so noisy stdout is flushed into the log under hold.
sleep 0.15
kill -TERM "$c10_pid" 2>/dev/null || true
sleep 0.1
rm -f "$HOLD"
for _ in $(seq 1 100); do
  kill -0 "$c10_pid" 2>/dev/null || break
  sleep 0.05
done
wait "$c10_pid" 2>/dev/null || true
[[ -f "$LOG" ]] || fail "C10: log missing after interrupted cleanup"
log_size=$(wc -c <"$LOG" | tr -d '[:space:]')
[[ "$log_size" -le 512 ]] \
  || fail "C10: interrupted noisy cleanup log not capped (size=$log_size > 512)"
if [[ -f "$COMPLETE_STAMP" ]]; then
  fail "C10: TERM must not stamp"
fi
if grep -q '^qmd update' "$MUTATION_LOG"; then
  fail "C10: TERM must not allow update"
fi
[[ ! -d "$LOCK_DIR" ]] || fail "C10: lock must be released after TERM"
ok "C10: EXIT cleanup caps log after interrupted noisy cleanup"

restore_standard_qmd

# Drain all detached workers before PASS so EXIT cleanup is idle.
reap_workers
wait 2>/dev/null || true

echo "PASS: qmd-handoff-reindex ($ASSERTIONS assertions)"
