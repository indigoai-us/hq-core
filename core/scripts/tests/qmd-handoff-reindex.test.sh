#!/usr/bin/env bash
# qmd-handoff-reindex.test.sh — single-flight handoff reindex helper.
#
# Guards the agent qmd concurrency fix:
#   - managed user-half wins when present (no raw qmd mutation)
#   - finalize + post share one in-flight mutation
#   - sequential finalize → post collides via recent-completion dedupe
#   - developer fallback runs cleanup → update → embed under a user lock
#   - live owner lock preserved; dead/stale owner reclaimed
#   - lock contention / failures stay non-blocking for handoff
#   - log truncate only happens for the winner; post-run byte cap enforced
#   - finalize-only (agent ritual) still schedules a refresh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HELPER="$ROOT/core/scripts/qmd-handoff-reindex.sh"
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
trap 'rm -rf "$TMP"' EXIT

HOME_DIR="$TMP/home"
BIN="$TMP/bin"
LOG="$TMP/qmd-handoff.log"
MUTATION_LOG="$TMP/mutations.log"
MANAGED="$TMP/managed/qmd-index-user"
LOCK_DIR="$HOME_DIR/.hq/locks/qmd-handoff-reindex.lock"
COMPLETE_STAMP="$HOME_DIR/.hq/locks/qmd-handoff-reindex.completed"
mkdir -p "$HOME_DIR/.hq/locks" "$BIN" "$TMP/managed" "$TMP/logs" "$TMP/repo/core/scripts" \
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

# --- fake managed user-half ---
cat > "$MANAGED" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'managed %s\n' "$*" >> "${MUTATION_LOG:?}"
if [[ -n "${MANAGED_HOLD_FILE:-}" && -f "${MANAGED_HOLD_FILE}" ]]; then
  while [[ -f "${MANAGED_HOLD_FILE}" ]]; do
    sleep 0.05
  done
fi
if [[ "${MANAGED_OVERFLOW_BYTES:-0}" -gt 0 ]]; then
  # Oversized stdout to exercise post-run log cap (winner-only).
  python3 - <<PY
import os
n = int(os.environ["MANAGED_OVERFLOW_BYTES"])
print("OVERFLOW_START")
print("x" * n)
print("OVERFLOW_END")
PY
fi
if [[ "${MANAGED_FAIL:-0}" == "1" ]]; then
  echo "managed boom" >&2
  exit "${MANAGED_FAIL_RC:-1}"
fi
exit 0
SH
chmod +x "$MANAGED"

run_helper() {
  env -i \
    PATH="$BIN:/usr/bin:/bin" \
    HOME="$HOME_DIR" \
    MUTATION_LOG="$MUTATION_LOG" \
    QMD_HANDOFF_LOG="$LOG" \
    HQ_QMD_INDEX_USER="${HQ_QMD_INDEX_USER:-}" \
    QMD_HOLD_FILE="${QMD_HOLD_FILE:-}" \
    QMD_FAIL_CMD="${QMD_FAIL_CMD:-}" \
    QMD_FAIL_RC="${QMD_FAIL_RC:-}" \
    MANAGED_HOLD_FILE="${MANAGED_HOLD_FILE:-}" \
    MANAGED_FAIL="${MANAGED_FAIL:-0}" \
    MANAGED_FAIL_RC="${MANAGED_FAIL_RC:-1}" \
    MANAGED_OVERFLOW_BYTES="${MANAGED_OVERFLOW_BYTES:-0}" \
    QMD_HANDOFF_DEDUPE_SEC="${QMD_HANDOFF_DEDUPE_SEC:-90}" \
    QMD_HANDOFF_LOG_MAX_BYTES="${QMD_HANDOFF_LOG_MAX_BYTES:-65536}" \
    QMD_HANDOFF_LOCK_GRACE_SEC="${QMD_HANDOFF_LOCK_GRACE_SEC:-5}" \
    bash "$HELPER"
}

reset_state() {
  rm -f "$MUTATION_LOG" "$LOG" "$COMPLETE_STAMP"
  rm -rf "$HOME_DIR/.hq/locks"
  mkdir -p "$HOME_DIR/.hq/locks"
  : > "$MUTATION_LOG"
}

# =============================================================================
# 1) managed present: routes to managed without --embed; raw qmd never runs
# =============================================================================
reset_state
HQ_QMD_INDEX_USER="$MANAGED" run_helper
grep -q '^managed' "$MUTATION_LOG" || fail "managed wrapper was not invoked"
if grep -q '^managed .*--embed' "$MUTATION_LOG"; then
  fail "managed wrapper must be invoked without --embed"
fi
if grep -q '^qmd ' "$MUTATION_LOG"; then
  fail "raw qmd must not run when managed wrapper exists"
fi
ok "managed present routes to user-half without --embed; raw qmd idle"

# =============================================================================
# 2) managed absent: fallback cleanup → update → embed
# =============================================================================
reset_state
HQ_QMD_INDEX_USER="$TMP/managed/does-not-exist" run_helper
mapfile -t steps < <(grep '^qmd ' "$MUTATION_LOG" || true)
[[ "${#steps[@]}" -eq 3 ]] || fail "expected 3 raw qmd steps, got ${#steps[@]}: $(cat "$MUTATION_LOG")"
[[ "${steps[0]}" == "qmd cleanup" ]] || fail "step1 want cleanup, got ${steps[0]}"
[[ "${steps[1]}" == "qmd update" ]] || fail "step2 want update, got ${steps[1]}"
[[ "${steps[2]}" == "qmd embed" ]] || fail "step3 want embed, got ${steps[2]}"
ok "developer fallback runs cleanup → update → embed"

# =============================================================================
# 3) fallback lock contention: second caller does not mutate or truncate log
# =============================================================================
reset_state
HOLD="$TMP/hold-raw"
: > "$HOLD"
env -i PATH="$BIN:/usr/bin:/bin" HOME="$HOME_DIR" MUTATION_LOG="$MUTATION_LOG" \
  QMD_HANDOFF_LOG="$LOG" QMD_HOLD_FILE="$HOLD" HQ_QMD_INDEX_USER="$TMP/nope" \
  bash "$HELPER" &
winner_pid=$!

# Wait until winner has acquired lock and started mutating (and truncated log).
for _ in $(seq 1 100); do
  if grep -q '^qmd cleanup' "$MUTATION_LOG" 2>/dev/null; then
    break
  fi
  sleep 0.05
done
grep -q '^qmd cleanup' "$MUTATION_LOG" || fail "winner never started raw pipeline"

# Plant evidence in the log that a loser must not wipe.
echo "WINNER_EVIDENCE" >> "$LOG"
before_log="$(cat "$LOG")"
before_mut="$(cat "$MUTATION_LOG")"

HQ_QMD_INDEX_USER="$TMP/nope" run_helper
after_log="$(cat "$LOG")"
after_mut="$(cat "$MUTATION_LOG")"

[[ "$before_log" == "$after_log" ]] || fail "loser truncated/changed winner log"
[[ "$before_mut" == "$after_mut" ]] || fail "loser performed extra raw mutation"
grep -q 'WINNER_EVIDENCE' "$LOG" || fail "winner log evidence missing after loser"

rm -f "$HOLD"
wait "$winner_pid" || true
ok "fallback lock contention: loser is quiet and does not truncate log"

# =============================================================================
# 4) concurrent finalize-style + post-style helper calls: at most one mutation set
# =============================================================================
reset_state
HOLD="$TMP/hold-concurrent"
: > "$HOLD"
for _ in 1 2; do
  env -i PATH="$BIN:/usr/bin:/bin" HOME="$HOME_DIR" MUTATION_LOG="$MUTATION_LOG" \
    QMD_HANDOFF_LOG="$LOG" QMD_HOLD_FILE="$HOLD" HQ_QMD_INDEX_USER="$TMP/nope" \
    bash "$HELPER" &
done
# Let both race the lock.
sleep 0.2
rm -f "$HOLD"
wait || true
cleanup_n=$(grep -c '^qmd cleanup' "$MUTATION_LOG" || true)
update_n=$(grep -c '^qmd update' "$MUTATION_LOG" || true)
embed_n=$(grep -c '^qmd embed' "$MUTATION_LOG" || true)
[[ "$cleanup_n" -eq 1 && "$update_n" -eq 1 && "$embed_n" -eq 1 ]] \
  || fail "expected one raw pipeline, got cleanup=$cleanup_n update=$update_n embed=$embed_n ($(cat "$MUTATION_LOG"))"
ok "concurrent helpers: at most one raw mutation pipeline"

# Concurrent managed: at most one managed invocation
reset_state
HOLD="$TMP/hold-managed"
: > "$HOLD"
for _ in 1 2; do
  env -i PATH="$BIN:/usr/bin:/bin" HOME="$HOME_DIR" MUTATION_LOG="$MUTATION_LOG" \
    QMD_HANDOFF_LOG="$LOG" HQ_QMD_INDEX_USER="$MANAGED" MANAGED_HOLD_FILE="$HOLD" \
    bash "$HELPER" &
done
sleep 0.2
rm -f "$HOLD"
wait || true
managed_n=$(grep -c '^managed' "$MUTATION_LOG" || true)
[[ "$managed_n" -eq 1 ]] || fail "expected one managed call, got $managed_n"
if grep -q '^qmd ' "$MUTATION_LOG"; then
  fail "raw qmd ran under concurrent managed mode"
fi
ok "concurrent helpers: at most one managed mutation"

# =============================================================================
# 5) managed/raw failure is non-blocking (exit 0)
# =============================================================================
reset_state
set +e
MANAGED_FAIL=1 HQ_QMD_INDEX_USER="$MANAGED" run_helper
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "managed failure should exit 0, got $rc"
ok "managed failure is non-blocking (exit 0)"

reset_state
set +e
QMD_FAIL_CMD=update QMD_FAIL_RC=7 HQ_QMD_INDEX_USER="$TMP/nope" run_helper
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "raw qmd failure should exit 0, got $rc"
grep -q '^qmd cleanup' "$MUTATION_LOG" || fail "cleanup should still run before failed update"
if grep -q '^qmd embed' "$MUTATION_LOG"; then
  fail "embed should not run after failed update"
fi
ok "raw qmd failure is non-blocking (exit 0)"

# =============================================================================
# 5b) failed flight does not stamp; immediate second call retries (M1)
#     Dedupe must collapse successful finalize→post only — not blackout a
#     failed first flight for DEDUPE_SEC.
# =============================================================================
reset_state
set +e
MANAGED_FAIL=1 QMD_HANDOFF_DEDUPE_SEC=90 HQ_QMD_INDEX_USER="$MANAGED" run_helper
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "managed failure should exit 0, got $rc"
if [[ -f "$COMPLETE_STAMP" ]]; then
  fail "failed managed flight must not write completion stamp (got $(cat "$COMPLETE_STAMP"))"
fi
managed_n=$(grep -c '^managed' "$MUTATION_LOG" || true)
[[ "$managed_n" -eq 1 ]] || fail "first failed managed expected 1 invocation, got $managed_n"

# Immediate second call within default dedupe window must still mutate.
set +e
MANAGED_FAIL=1 QMD_HANDOFF_DEDUPE_SEC=90 HQ_QMD_INDEX_USER="$MANAGED" run_helper
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "second managed failure should exit 0, got $rc"
managed_n=$(grep -c '^managed' "$MUTATION_LOG" || true)
[[ "$managed_n" -eq 2 ]] \
  || fail "failed managed must allow immediate retry within dedupe window; managed=$managed_n"
if [[ -f "$COMPLETE_STAMP" ]]; then
  fail "second failed managed must still not stamp (got $(cat "$COMPLETE_STAMP"))"
fi
# Success after failures stamps and subsequent call dedupes.
MANAGED_FAIL=0 QMD_HANDOFF_DEDUPE_SEC=90 HQ_QMD_INDEX_USER="$MANAGED" run_helper
[[ -f "$COMPLETE_STAMP" ]] || fail "successful managed after fail should stamp"
managed_n=$(grep -c '^managed' "$MUTATION_LOG" || true)
[[ "$managed_n" -eq 3 ]] || fail "success after fails expected 3 managed total, got $managed_n"
MANAGED_FAIL=0 QMD_HANDOFF_DEDUPE_SEC=90 HQ_QMD_INDEX_USER="$MANAGED" run_helper
managed_n=$(grep -c '^managed' "$MUTATION_LOG" || true)
[[ "$managed_n" -eq 3 ]] || fail "success stamp should dedupe next call; managed=$managed_n"
ok "failed managed does not stamp; second call retries; success then dedupes"

# Raw: update failure (embed skipped) must not stamp; immediate retry mutates.
reset_state
set +e
QMD_FAIL_CMD=update QMD_FAIL_RC=7 QMD_HANDOFF_DEDUPE_SEC=90 \
  HQ_QMD_INDEX_USER="$TMP/nope" run_helper
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "raw update failure should exit 0, got $rc"
if [[ -f "$COMPLETE_STAMP" ]]; then
  fail "failed raw update must not write completion stamp (got $(cat "$COMPLETE_STAMP"))"
fi
if grep -q '^qmd embed' "$MUTATION_LOG"; then
  fail "embed must not run after failed update (stamp regression setup)"
fi
cleanup_n=$(grep -c '^qmd cleanup' "$MUTATION_LOG" || true)
[[ "$cleanup_n" -eq 1 ]] || fail "first raw fail expected 1 cleanup, got $cleanup_n"

QMD_FAIL_CMD=update QMD_FAIL_RC=7 QMD_HANDOFF_DEDUPE_SEC=90 \
  HQ_QMD_INDEX_USER="$TMP/nope" run_helper
cleanup_n=$(grep -c '^qmd cleanup' "$MUTATION_LOG" || true)
update_n=$(grep -c '^qmd update' "$MUTATION_LOG" || true)
[[ "$cleanup_n" -eq 2 && "$update_n" -eq 2 ]] \
  || fail "failed raw update must allow immediate retry; c=$cleanup_n u=$update_n"
if [[ -f "$COMPLETE_STAMP" ]]; then
  fail "second failed raw update must still not stamp"
fi
# Successful raw after failure stamps (cleanup → update → embed).
unset QMD_FAIL_CMD QMD_FAIL_RC
QMD_HANDOFF_DEDUPE_SEC=90 HQ_QMD_INDEX_USER="$TMP/nope" run_helper
[[ -f "$COMPLETE_STAMP" ]] || fail "successful raw after fail should stamp"
cleanup_n=$(grep -c '^qmd cleanup' "$MUTATION_LOG" || true)
embed_n=$(grep -c '^qmd embed' "$MUTATION_LOG" || true)
[[ "$cleanup_n" -eq 3 && "$embed_n" -eq 1 ]] \
  || fail "success raw after fails expected c=3 e=1, got c=$cleanup_n e=$embed_n"
QMD_HANDOFF_DEDUPE_SEC=90 HQ_QMD_INDEX_USER="$TMP/nope" run_helper
cleanup_n=$(grep -c '^qmd cleanup' "$MUTATION_LOG" || true)
[[ "$cleanup_n" -eq 3 ]] || fail "raw success stamp should dedupe next call; c=$cleanup_n"
ok "failed raw update does not stamp; second call retries; success then dedupes"

# =============================================================================
# 6) log behavior is bounded and deterministic (winner truncates once)
# =============================================================================
reset_state
python3 - <<'PY' > "$LOG"
print("OLD_LINE\n" * 500, end="")
PY
HQ_QMD_INDEX_USER="$TMP/nope" run_helper
if grep -q 'OLD_LINE' "$LOG"; then
  fail "winner should truncate prior log content"
fi
[[ -f "$LOG" ]] || fail "log missing after run"
lines=$(wc -l < "$LOG")
[[ "$lines" -lt 100 ]] || fail "log not bounded: $lines lines"
ok "log truncate is deterministic and bounded"

# Busy loser does not create/truncate when log already has winner content
reset_state
HOLD="$TMP/hold-log"
: > "$HOLD"
env -i PATH="$BIN:/usr/bin:/bin" HOME="$HOME_DIR" MUTATION_LOG="$MUTATION_LOG" \
  QMD_HANDOFF_LOG="$LOG" QMD_HOLD_FILE="$HOLD" HQ_QMD_INDEX_USER="$TMP/nope" \
  QMD_HANDOFF_DEDUPE_SEC=0 \
  bash "$HELPER" &
wpid=$!
for _ in $(seq 1 100); do
  grep -q '^qmd cleanup' "$MUTATION_LOG" 2>/dev/null && break
  sleep 0.05
done
echo "KEEP_ME" >> "$LOG"
size_before=$(wc -c < "$LOG")
QMD_HANDOFF_DEDUPE_SEC=0 HQ_QMD_INDEX_USER="$TMP/nope" run_helper
size_after=$(wc -c < "$LOG")
[[ "$size_before" -eq "$size_after" ]] || fail "loser changed log size"
grep -q 'KEEP_ME' "$LOG" || fail "loser wiped KEEP_ME"
rm -f "$HOLD"
wait "$wpid" || true
ok "busy caller leaves winner log untouched"

# Oversized managed output is capped by the winner; completion tail retained.
reset_state
MAX_BYTES=4096
OVERFLOW=20000
MANAGED_OVERFLOW_BYTES="$OVERFLOW" QMD_HANDOFF_LOG_MAX_BYTES="$MAX_BYTES" \
  HQ_QMD_INDEX_USER="$MANAGED" run_helper
[[ -f "$LOG" ]] || fail "log missing after oversized managed run"
log_size=$(wc -c <"$LOG" | tr -d '[:space:]')
[[ "$log_size" -le "$MAX_BYTES" ]] \
  || fail "log not capped: size=$log_size max=$MAX_BYTES"
grep -q 'qmd-handoff-reindex done mode=managed' "$LOG" \
  || fail "capped log lost completion evidence"
grep -q '^managed' "$MUTATION_LOG" || fail "oversized managed run did not mutate"
ok "oversized managed log is capped while retaining completion tail"

# =============================================================================
# 7) finalize-only path schedules the helper (agent ritual compatible)
# =============================================================================
reset_state
cp "$FINALIZE" "$TMP/repo/core/scripts/handoff-finalize.sh"
cp "$HELPER" "$TMP/repo/core/scripts/qmd-handoff-reindex.sh"
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
chmod +x "$TMP/repo/core/scripts/"*.sh

cat > "$TMP/repo/workspace/baseline/hq-local-baseline.json" <<'JSON'
{"categories":[{"name":"baseline","patterns":["workspace/*"]}]}
JSON

# Interpose helper via a wrapper that records scheduling, then execs real helper.
REAL_HELPER="$TMP/repo/core/scripts/qmd-handoff-reindex.sh"
mv "$REAL_HELPER" "$TMP/repo/core/scripts/qmd-handoff-reindex.real.sh"
cat > "$REAL_HELPER" <<SH
#!/usr/bin/env bash
printf 'scheduled\n' >> "$TMP/helper-scheduled.log"
exec bash "$TMP/repo/core/scripts/qmd-handoff-reindex.real.sh" "\$@"
SH
chmod +x "$REAL_HELPER" "$TMP/repo/core/scripts/qmd-handoff-reindex.real.sh"

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
    env -i PATH="$BIN:/usr/bin:/bin" HOME="$HOME_DIR" \
      MUTATION_LOG="$MUTATION_LOG" \
      QMD_HANDOFF_LOG="$LOG" \
      HQ_QMD_INDEX_USER="$TMP/nope" \
      QMD_HANDOFF_DEDUPE_SEC=0 \
      bash core/scripts/handoff-finalize.sh \
        --title "Handoff: qmd ritual" \
        --summary "finalize-only schedules reindex" \
        --message "ritual" \
        --next-steps-json '[]' \
        --files-touched-json '["tracked.txt"]' \
        --learnings-json '[]' \
        --tags-json '["test"]' \
        --slug "qmd-ritual"
  )
  echo "$out" > "$TMP/finalize-out.json"
  qmd_pid=$(jq -r '.qmd_pid // empty' <<<"$out")
  [[ -n "$qmd_pid" ]] || fail "finalize-only did not report qmd_pid"
  for _ in $(seq 1 100); do
    [[ -f "$TMP/helper-scheduled.log" ]] && break
    sleep 0.05
  done
  [[ -f "$TMP/helper-scheduled.log" ]] || fail "finalize-only never scheduled helper"
  for _ in $(seq 1 100); do
    grep -q '^qmd embed' "$MUTATION_LOG" 2>/dev/null && break
    sleep 0.05
  done
  grep -q '^qmd cleanup' "$MUTATION_LOG" || fail "finalize-only helper did not run raw pipeline"
)

ok "finalize-only (agent ritual) schedules single-flight helper"

# =============================================================================
# 8) finalize + post both route through helper; single flight under managed
# =============================================================================
reset_state
cp "$POST" "$TMP/repo/core/scripts/handoff-post.sh"
chmod +x "$TMP/repo/core/scripts/handoff-post.sh"
cat > "$TMP/repo/core/scripts/archive-old-threads.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$TMP/repo/core/scripts/archive-old-threads.sh"

rm -f "$TMP/helper-scheduled.log" "$MUTATION_LOG" "$COMPLETE_STAMP"
: > "$MUTATION_LOG"
: > "$TMP/helper-scheduled.log"

HOLD="$TMP/hold-fp"
: > "$HOLD"

(
  cd "$TMP/repo"
  # Mirror full /handoff double-schedule: helper from finalize + post.
  env -i PATH="$BIN:/usr/bin:/bin" HOME="$HOME_DIR" \
    MUTATION_LOG="$MUTATION_LOG" QMD_HANDOFF_LOG="$LOG" \
    HQ_QMD_INDEX_USER="$MANAGED" MANAGED_HOLD_FILE="$HOLD" \
    QMD_HANDOFF_DEDUPE_SEC=0 \
    bash core/scripts/qmd-handoff-reindex.sh &
  env -i PATH="$BIN:/usr/bin:/bin" HOME="$HOME_DIR" \
    MUTATION_LOG="$MUTATION_LOG" QMD_HANDOFF_LOG="$LOG" \
    HQ_QMD_INDEX_USER="$MANAGED" MANAGED_HOLD_FILE="$HOLD" \
    HANDOFF_LOG_DIR="$TMP/logs" \
    QMD_HANDOFF_DEDUPE_SEC=0 \
    bash core/scripts/handoff-post.sh workspace/threads/T-missing.json ""
  sleep 0.1
  rm -f "$HOLD"
  wait || true
)

managed_n=$(grep -c '^managed' "$MUTATION_LOG" || true)
[[ "$managed_n" -eq 1 ]] || fail "finalize+post managed single-flight expected 1, got $managed_n ($(cat "$MUTATION_LOG"))"
if grep -q '^qmd ' "$MUTATION_LOG"; then
  fail "raw qmd ran when managed present via post path"
fi
ok "finalize+post route managed single-flight; raw qmd idle"

# post alone with managed present
reset_state
(
  cd "$TMP/repo"
  env -i PATH="$BIN:/usr/bin:/bin" HOME="$HOME_DIR" \
    MUTATION_LOG="$MUTATION_LOG" QMD_HANDOFF_LOG="$LOG" \
    HQ_QMD_INDEX_USER="$MANAGED" HANDOFF_LOG_DIR="$TMP/logs" \
    QMD_HANDOFF_DEDUPE_SEC=0 \
    bash core/scripts/handoff-post.sh workspace/threads/T-missing.json ""
  for _ in $(seq 1 100); do
    grep -q '^managed' "$MUTATION_LOG" 2>/dev/null && break
    sleep 0.05
  done
)
grep -q '^managed' "$MUTATION_LOG" || fail "post did not invoke managed helper path"
if grep -q '^qmd ' "$MUTATION_LOG"; then
  fail "post managed path invoked raw qmd"
fi
ok "post routes through helper to managed user-half"

# =============================================================================
# 9) structural: callers no longer inline raw qmd cleanup/update/embed
# =============================================================================
if grep -nE "nohup bash -c 'qmd |qmd cleanup|qmd update && qmd embed" "$FINALIZE" | grep -vE '^\s*#|:\s*#' >/dev/null 2>&1; then
  # Live inline launches are forbidden; comments may mention the old pattern.
  live=$(grep -nE "nohup bash -c 'qmd |[^#]*\bqmd cleanup\b|[^#]*\bqmd update\b.*\bqmd embed\b" "$FINALIZE" || true)
  if [[ -n "$live" ]]; then
    # Filter comment-only lines
    if echo "$live" | grep -vE '^[0-9]+:[[:space:]]*#' >/dev/null; then
      fail "handoff-finalize.sh still launches raw qmd inline: $live"
    fi
  fi
fi
grep -q 'qmd-handoff-reindex' "$FINALIZE" || fail "finalize does not call qmd-handoff-reindex"
grep -q 'qmd-handoff-reindex' "$POST" || fail "post does not call qmd-handoff-reindex"
if grep -nE "nohup bash -c 'qmd |qmd cleanup|qmd update && qmd embed" "$POST" | grep -vE '^[0-9]+:[[:space:]]*#' >/dev/null 2>&1; then
  fail "handoff-post.sh still launches raw qmd inline"
fi
ok "finalize and post delegate to shared helper (no inline raw pipeline)"

# =============================================================================
# 10) sequential finalize + post after first fully completed → one mutation
#     (dedupe window override; no sleeps)
# =============================================================================
reset_state
QMD_HANDOFF_DEDUPE_SEC=60 HQ_QMD_INDEX_USER="$MANAGED" run_helper
[[ -f "$COMPLETE_STAMP" ]] || fail "completion stamp missing after first run"
first_mut="$(cat "$MUTATION_LOG")"
managed_n=$(grep -c '^managed' "$MUTATION_LOG" || true)
[[ "$managed_n" -eq 1 ]] || fail "first sequential call expected 1 managed, got $managed_n"

# Second call after first fully completed (sync). Within window → no mutation.
QMD_HANDOFF_DEDUPE_SEC=60 HQ_QMD_INDEX_USER="$MANAGED" run_helper
second_mut="$(cat "$MUTATION_LOG")"
[[ "$first_mut" == "$second_mut" ]] \
  || fail "sequential second call mutated: before=[$first_mut] after=[$second_mut]"
managed_n=$(grep -c '^managed' "$MUTATION_LOG" || true)
[[ "$managed_n" -eq 1 ]] || fail "sequential dedupe expected 1 managed total, got $managed_n"
ok "sequential finalize+post after completion: one managed mutation (dedupe)"

# Window disabled → second call runs a full mutation (ritual still works).
reset_state
QMD_HANDOFF_DEDUPE_SEC=0 HQ_QMD_INDEX_USER="$MANAGED" run_helper
QMD_HANDOFF_DEDUPE_SEC=0 HQ_QMD_INDEX_USER="$MANAGED" run_helper
managed_n=$(grep -c '^managed' "$MUTATION_LOG" || true)
[[ "$managed_n" -eq 2 ]] || fail "dedupe=0 expected 2 managed, got $managed_n"
ok "dedupe window override 0 allows sequential re-run (ritual cadence)"

# Raw sequential path also collapses to one pipeline.
reset_state
QMD_HANDOFF_DEDUPE_SEC=90 HQ_QMD_INDEX_USER="$TMP/nope" run_helper
QMD_HANDOFF_DEDUPE_SEC=90 HQ_QMD_INDEX_USER="$TMP/nope" run_helper
cleanup_n=$(grep -c '^qmd cleanup' "$MUTATION_LOG" || true)
update_n=$(grep -c '^qmd update' "$MUTATION_LOG" || true)
embed_n=$(grep -c '^qmd embed' "$MUTATION_LOG" || true)
[[ "$cleanup_n" -eq 1 && "$update_n" -eq 1 && "$embed_n" -eq 1 ]] \
  || fail "sequential raw dedupe expected one pipeline, got c=$cleanup_n u=$update_n e=$embed_n"
ok "sequential raw finalize+post: one mutation pipeline via dedupe"

# =============================================================================
# 11) stale-owner recovery: live owner preserved; dead owner reclaimed
# =============================================================================
reset_state
# Live owner: plant lock with this shell's PID and keep process alive.
mkdir -p "$LOCK_DIR"
{
  echo "pid=$$"
  echo "ts=$(date +%s)"
  echo "nonce=live-test"
} >"$LOCK_DIR/owner"
before_mut="$(cat "$MUTATION_LOG")"
QMD_HANDOFF_DEDUPE_SEC=0 HQ_QMD_INDEX_USER="$MANAGED" run_helper
after_mut="$(cat "$MUTATION_LOG")"
[[ "$before_mut" == "$after_mut" ]] || fail "live owner lock was stolen (mutation occurred)"
[[ -d "$LOCK_DIR" ]] || fail "live owner lock dir was removed"
[[ -f "$LOCK_DIR/owner" ]] || fail "live owner record was removed"
grep -q "^pid=$$" "$LOCK_DIR/owner" || fail "live owner pid rewritten"
ok "live owner lock is preserved (no reclaim, no mutation)"

# Dead/stale owner: PID that is definitely not alive.
reset_state
mkdir -p "$LOCK_DIR"
DEAD_PID=$(( $$ + 1000000 ))
# Ensure kill -0 fails for this synthetic pid (and does not match us).
if kill -0 "$DEAD_PID" 2>/dev/null; then
  # Extremely unlikely; pick a high unused number.
  DEAD_PID=2147483646
  kill -0 "$DEAD_PID" 2>/dev/null && fail "could not find a dead pid for stale-owner test"
fi
{
  echo "pid=$DEAD_PID"
  echo "ts=1"
  echo "nonce=dead-test"
} >"$LOCK_DIR/owner"
QMD_HANDOFF_DEDUPE_SEC=0 HQ_QMD_INDEX_USER="$MANAGED" run_helper
managed_n=$(grep -c '^managed' "$MUTATION_LOG" || true)
[[ "$managed_n" -eq 1 ]] || fail "stale/dead owner should be reclaimed; managed=$managed_n"
# Lock should be released after successful flight.
if [[ -d "$LOCK_DIR" ]]; then
  fail "lock dir still present after reclaimed run completed"
fi
[[ -f "$COMPLETE_STAMP" ]] || fail "completion stamp missing after reclaim run"
ok "dead/stale owner lock is reclaimed; mutation proceeds"

# Empty pre-owner lock dir (legacy / SIGKILL before owner write) is reclaimable
# once past the owner-write grace window (simulate age via grace=0).
reset_state
mkdir -p "$LOCK_DIR"
QMD_HANDOFF_DEDUPE_SEC=0 QMD_HANDOFF_LOCK_GRACE_SEC=0 \
  HQ_QMD_INDEX_USER="$MANAGED" run_helper
managed_n=$(grep -c '^managed' "$MUTATION_LOG" || true)
[[ "$managed_n" -eq 1 ]] || fail "empty lock dir should be reclaimed; managed=$managed_n"
ok "empty lock dir without owner is reclaimed"

echo "PASS: qmd-handoff-reindex ($ASSERTIONS assertions)"
