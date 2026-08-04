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

# --- fake qmd: records ordered mutations; optional hold for concurrency ---
cat > "$BIN/qmd" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
printf 'qmd %s\n' "$cmd" >> "${MUTATION_LOG:?}"
if [[ -n "${QMD_HOLD_FILE:-}" && -f "${QMD_HOLD_FILE}" ]]; then
  # Hold while the marker exists so a second caller can race the lock.
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

# Shared env for helper runs (isolated HOME + PATH; no real agent markers).
helper_env() {
  # shellcheck disable=SC2086
  env -i \
    PATH="$BIN:/usr/bin:/bin" \
    HOME="$HOME_DIR" \
    MUTATION_LOG="$MUTATION_LOG" \
    QMD_REINDEX_LOG="$LOG" \
    QMD_HANDOFF_LOG="$LOG" \
    QMD_HOLD_FILE="${QMD_HOLD_FILE:-}" \
    QMD_FAIL_CMD="${QMD_FAIL_CMD:-}" \
    QMD_FAIL_RC="${QMD_FAIL_RC:-}" \
    QMD_HANDOFF_DEDUPE_SEC="${QMD_HANDOFF_DEDUPE_SEC:-90}" \
    QMD_HANDOFF_LOG_MAX_BYTES="${QMD_HANDOFF_LOG_MAX_BYTES:-65536}" \
    QMD_HANDOFF_LOCK_GRACE_SEC="${QMD_HANDOFF_LOCK_GRACE_SEC:-5}" \
    HQ_AGENT_BOX="${HQ_AGENT_BOX:-}" \
    HQ_QMD_REINDEX_MODE="${HQ_QMD_REINDEX_MODE:-}" \
    "$@"
}

# Synchronous worker path (pipeline under lock).
run_worker() {
  helper_env bash "$HELPER" --worker --log "$LOG"
}

# Launcher path (prints skipped-agent / skipped / pid).
run_launcher() {
  helper_env bash "$HELPER" --log "$LOG"
}

reset_state() {
  # Drain prior async workers before wiping lock/stamp state.
  reap_workers
  rm -f "$MUTATION_LOG" "$LOG" "$COMPLETE_STAMP"
  rm -rf "$HOME_DIR/.hq/locks"
  mkdir -p "$HOME_DIR/.hq/locks"
  : > "$MUTATION_LOG"
  # Clear any env that prior cases set in this shell (run_* inherit via ${VAR:-}).
  unset QMD_HOLD_FILE QMD_FAIL_CMD QMD_FAIL_RC HQ_AGENT_BOX HQ_QMD_REINDEX_MODE
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

wait_for_mutations() {
  local want="${1:-1}" i=0
  for i in $(seq 1 100); do
    local n
    n=$(inv_count)
    n=${n//$'\n'/}
    [[ "$n" -ge "$want" ]] 2>/dev/null && return 0
    sleep 0.05
  done
  return 1
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
  env -i PATH="/usr/bin:/bin" HOME="$HOME_DIR" \
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

# Structural: helper never treats managed path as an invoke target.
if grep -nE 'HQ_QMD_INDEX_USER|qmd-index-user' "$HELPER" | grep -vE '^\s*#|:\s*#|hard-skip|never|managed|agent' >/dev/null 2>&1; then
  # Allow comments that mention managed as skip markers; forbid assignment/exec.
  live=$(grep -nE '\$\{?HQ_QMD_INDEX_USER|exec .*qmd-index-user|bash .*qmd-index-user' "$HELPER" || true)
  if [[ -n "$live" ]]; then
    if echo "$live" | grep -vE '^[0-9]+:[[:space:]]*#' >/dev/null; then
      fail "helper must not invoke managed user-half: $live"
    fi
  fi
fi
# Presence of managed binary path is only a *detection* marker in is_agent_box.
grep -q 'qmd-index-user' "$HELPER" || fail "helper should detect managed path as agent marker"
if grep -nE 'run_qmd .*qmd-index|bash .*/qmd-index-user' "$HELPER" | grep -vE '^[0-9]+:[[:space:]]*#' >/dev/null 2>&1; then
  fail "helper must not exec qmd-index-user"
fi
ok "A5: managed path is skip marker only (never invoke target)"

# =============================================================================
# L) Laptop single-flight pipeline
# =============================================================================
reset_state
run_worker
mapfile -t steps < <(grep '^qmd ' "$MUTATION_LOG" || true)
[[ "${#steps[@]}" -eq 3 ]] || fail "expected 3 raw qmd steps, got ${#steps[@]}: $(cat "$MUTATION_LOG")"
[[ "${steps[0]}" == "qmd cleanup" ]] || fail "step1 want cleanup, got ${steps[0]}"
[[ "${steps[1]}" == "qmd update" ]] || fail "step2 want update, got ${steps[1]}"
[[ "${steps[2]}" == "qmd embed" ]] || fail "step3 want embed, got ${steps[2]}"
[[ -f "$COMPLETE_STAMP" ]] || fail "success should write completion stamp"
ok "L1: laptop --worker runs cleanup → update → embed and stamps"

# Concurrent workers: at most one pipeline
reset_state
HOLD="$TMP/hold-concurrent"
: > "$HOLD"
for _ in 1 2; do
  QMD_HOLD_FILE="$HOLD" QMD_HANDOFF_DEDUPE_SEC=0 helper_env bash "$HELPER" --worker --log "$LOG" &
done
# Let both race the lock.
sleep 0.15
rm -f "$HOLD"
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
for _ in $(seq 1 100); do
  grep -q '^qmd cleanup' "$MUTATION_LOG" 2>/dev/null && break
  sleep 0.05
done
grep -q '^qmd cleanup' "$MUTATION_LOG" || fail "winner never started raw pipeline"
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
out=$(
  env -i PATH="/usr/bin:/bin" HOME="$HOME_DIR" \
    QMD_REINDEX_LOG="$LOG" \
    bash "$HELPER" --log "$LOG"
)
[[ "$out" == "skipped" ]] || fail "missing qmd non-agent want skipped, got '$out'"
ok "S2: missing qmd non-agent → skipped, exit 0"

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
# Poll async worker mutations
wait_for_mutations 3 || fail "launcher worker did not complete pipeline: $(cat "$MUTATION_LOG")"
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
    HQ_ROOT="$TMP/repo" \
    MUTATION_LOG="$MUTATION_LOG" \
    QMD_REINDEX_LOG="$LOG" \
    HANDOFF_LOG_DIR="$TMP/logs" \
    QMD_HOLD_FILE="$HOLD" \
    QMD_HANDOFF_DEDUPE_SEC=0 \
    bash core/scripts/handoff-post.sh workspace/threads/T-missing.json "" \
    >"$TMP/r3-post-out.txt" 2>&1 &
  post_pid=$!

  # Keep hold until: one raw pipeline started AND both callers scheduled helper.
  # Otherwise a fast post can finish before finalize reaches qmd (2 pipelines).
  for _ in $(seq 1 200); do
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
  # Brief window so the second worker observes the live lock.
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

# Drain all detached workers before PASS so EXIT cleanup is idle.
reap_workers
wait 2>/dev/null || true

echo "PASS: qmd-handoff-reindex ($ASSERTIONS assertions)"
