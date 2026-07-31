#!/usr/bin/env bash
# qmd-handoff-reindex.test.sh — single-flight handoff reindex helper.
#
# Guards the agent qmd concurrency fix:
#   - managed user-half wins when present (no raw qmd mutation)
#   - finalize + post share one in-flight mutation
#   - developer fallback runs cleanup → update → embed under a user lock
#   - lock contention / failures stay non-blocking for handoff
#   - log truncate only happens for the winner
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
    bash "$HELPER"
}

reset_state() {
  rm -f "$MUTATION_LOG" "$LOG"
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
  bash "$HELPER" &
wpid=$!
for _ in $(seq 1 100); do
  grep -q '^qmd cleanup' "$MUTATION_LOG" 2>/dev/null && break
  sleep 0.05
done
echo "KEEP_ME" >> "$LOG"
size_before=$(wc -c < "$LOG")
HQ_QMD_INDEX_USER="$TMP/nope" run_helper
size_after=$(wc -c < "$LOG")
[[ "$size_before" -eq "$size_after" ]] || fail "loser changed log size"
grep -q 'KEEP_ME' "$LOG" || fail "loser wiped KEEP_ME"
rm -f "$HOLD"
wait "$wpid" || true
ok "busy caller leaves winner log untouched"

# =============================================================================
# 7) finalize-only path schedules the helper (agent ritual compatible)
# =============================================================================
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

  rm -f "$TMP/helper-scheduled.log" "$MUTATION_LOG"
  : > "$MUTATION_LOG"
  out=$(
    env -i PATH="$BIN:/usr/bin:/bin" HOME="$HOME_DIR" \
      MUTATION_LOG="$MUTATION_LOG" \
      QMD_HANDOFF_LOG="$LOG" \
      HQ_QMD_INDEX_USER="$TMP/nope" \
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
cp "$POST" "$TMP/repo/core/scripts/handoff-post.sh"
chmod +x "$TMP/repo/core/scripts/handoff-post.sh"
cat > "$TMP/repo/core/scripts/archive-old-threads.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$TMP/repo/core/scripts/archive-old-threads.sh"

rm -f "$TMP/helper-scheduled.log" "$MUTATION_LOG"
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
    bash core/scripts/qmd-handoff-reindex.sh &
  env -i PATH="$BIN:/usr/bin:/bin" HOME="$HOME_DIR" \
    MUTATION_LOG="$MUTATION_LOG" QMD_HANDOFF_LOG="$LOG" \
    HQ_QMD_INDEX_USER="$MANAGED" MANAGED_HOLD_FILE="$HOLD" \
    HANDOFF_LOG_DIR="$TMP/logs" \
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

echo "PASS: qmd-handoff-reindex ($ASSERTIONS assertions)"
