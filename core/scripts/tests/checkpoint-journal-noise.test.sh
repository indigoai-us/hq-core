#!/usr/bin/env bash
# Regression: checkpoint and journal PostToolUse hooks must not over-trigger.
#
# Covers the acceptance criteria from the 2026-07-30 over-triggering report:
#   1. Many edits inside the debounce window produce at most one checkpoint.
#   2. Concurrent sessions keep independent counters and debounce state.
#   3. Failed tool calls do not trigger journal reminders.
#   4. The edit threshold announces once, not on every later edit.
#   5. A journal entry resets only the writing session's counter.
#   6. Checkpoint git metadata matches the active worktree, not HQ root.
#   7. Per-edit checkpoints are advisory, not AUTO-CHECKPOINT REQUIRED.

set -uo pipefail

CORE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT="$(cd "$CORE_ROOT/.." && pwd)"
HOOKS="$ROOT/.claude/hooks"
HELPER="$ROOT/core/scripts/session-journal.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok — $*"; }
set_mtime_seconds_ago() {
  local seconds="$1" path="$2" stamp
  stamp="$(node -e 'const d = new Date(Date.now() - Number(process.argv[1]) * 1000); const p = n => String(n).padStart(2, "0"); process.stdout.write(`${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}${p(d.getHours())}${p(d.getMinutes())}.${p(d.getSeconds())}`)' "$seconds")"
  [ -n "$stamp" ] || fail "could not build a touch -t timestamp for $seconds seconds ago"
  touch -t "$stamp" "$path" || fail "could not set a touch -t timestamp for $seconds seconds ago"
}

# A throwaway HQ root that carries the real scripts the hooks depend on.
make_root() {
  local fr="$1"
  mkdir -p "$fr/core/scripts" "$fr/.claude/hooks" "$fr/workspace/threads"
  cp "$ROOT/core/scripts/hook-lib.sh" "$fr/core/scripts/hook-lib.sh"
  cp "$ROOT/core/scripts/session-journal.sh" "$fr/core/scripts/session-journal.sh"
  cp "$HOOKS/journal-due.sh" "$fr/.claude/hooks/journal-due.sh"
  cp "$HOOKS/hook-timeout-probe.sh" "$fr/.claude/hooks/hook-timeout-probe.sh"
  cp "$HOOKS/auto-checkpoint-trigger.sh" "$fr/.claude/hooks/auto-checkpoint-trigger.sh"
  chmod +x "$fr/core/scripts"/*.sh "$fr/.claude/hooks"/*.sh
  git -C "$fr" init -q 2>/dev/null
  git -C "$fr" config user.email t@t.t 2>/dev/null
  git -C "$fr" config user.name t 2>/dev/null
  echo root > "$fr/README.md"
  git -C "$fr" add -A >/dev/null 2>&1
  git -C "$fr" commit -qm root >/dev/null 2>&1
}

FR="$TMP_ROOT/hq"
make_root "$FR"

unwrap_context() {
  local output="$1"
  [ -n "$output" ] || return 0
  jq -r '.hookSpecificOutput.additionalContext // empty' <<<"$output"
}
journal_hook() {
  local output
  output="$(CLAUDE_PROJECT_DIR="$FR" bash "$FR/.claude/hooks/journal-due.sh" <<<"$1")"
  unwrap_context "$output"
}
checkpoint_hook() {
  local output
  output="$(CLAUDE_PROJECT_DIR="$FR" bash "$FR/.claude/hooks/auto-checkpoint-trigger.sh" <<<"$1")"
  unwrap_context "$output"
}

edit_payload() {
  printf '{"session_id":"%s","tool_name":"Edit","cwd":"%s","tool_input":{"file_path":"%s/src/app.ts"},"tool_response":{"exit_code":0}}' \
    "$1" "$FR" "$FR"
}
bash_payload() {
  printf '{"session_id":"%s","tool_name":"Bash","cwd":"%s","tool_input":{"command":"%s"},"tool_response":{"exit_code":%s}}' \
    "$1" "$FR" "$2" "$3"
}

# ---------------------------------------------------------------------------
echo "[1] many edits in one window produce at most one checkpoint"
count=0
for _ in $(seq 1 25); do
  out="$(checkpoint_hook "$(edit_payload s-one)")"
  case "$out" in *AUTO-CHECKPOINT*) count=$((count + 1)) ;; esac
done
[ "$count" -le 1 ] || fail "25 edits produced $count checkpoint nudges (expected at most 1)"
[ "$count" -eq 1 ] || fail "sustained editing produced no checkpoint at all"
pass "25 edits → exactly 1 checkpoint nudge"

# ---------------------------------------------------------------------------
echo "[2] the checkpoint nudge is advisory, not mandatory"
out="$(checkpoint_hook "$(bash_payload s-adv 'git commit -m demo' 0)")"
case "$out" in
  *"AUTO-CHECKPOINT SUGGESTED"*) ;;
  *) fail "checkpoint nudge is not advisory: $out" ;;
esac
case "$out" in
  *"AUTO-CHECKPOINT REQUIRED ("*) fail "per-tool hook still emits a mandatory directive" ;;
esac
pass "emits AUTO-CHECKPOINT SUGGESTED"

# ---------------------------------------------------------------------------
echo "[3] checkpoint git metadata follows the active repo, not HQ root"
APP="$TMP_ROOT/app"
mkdir -p "$APP"
git -C "$APP" init -q
git -C "$APP" config user.email t@t.t
git -C "$APP" config user.name t
git -C "$APP" checkout -q -b feature/app-branch
echo app > "$APP/main.ts"
git -C "$APP" add -A >/dev/null 2>&1
git -C "$APP" commit -qm app >/dev/null 2>&1
APP_SHA="$(git -C "$APP" rev-parse --short HEAD)"
HQ_SHA="$(git -C "$FR" rev-parse --short HEAD)"
[ "$APP_SHA" != "$HQ_SHA" ] || fail "fixture repos share a HEAD — test cannot discriminate"

payload="$(printf '{"session_id":"s-git","tool_name":"Bash","cwd":"%s","tool_input":{"command":"git commit -m app"},"tool_response":{"exit_code":0}}' "$APP")"
out="$(checkpoint_hook "$payload")"
case "$out" in
  *"current_commit: \"$APP_SHA\""*) ;;
  *) fail "checkpoint recorded the wrong commit (wanted $APP_SHA): $out" ;;
esac
case "$out" in
  *'branch: "feature/app-branch"'*) ;;
  *) fail "checkpoint recorded the wrong branch: $out" ;;
esac
pass "records the worktree's branch and commit ($APP_SHA)"

# ---------------------------------------------------------------------------
echo "[4] failed tool calls do not trigger journal reminders"
# Prime the session with edits so a green run WOULD otherwise be a milestone.
for _ in $(seq 1 3); do journal_hook "$(edit_payload s-fail)" >/dev/null; done
out="$(journal_hook "$(bash_payload s-fail 'pnpm test' 1)")"
[ -z "$out" ] || fail "a failed test run emitted a journal reminder: $out"
out="$(journal_hook "$(printf '{"session_id":"s-fail","tool_name":"Bash","tool_input":{"command":"pnpm test"},"tool_response":{"interrupted":true}}')")"
[ -z "$out" ] || fail "an interrupted test run emitted a journal reminder: $out"
pass "failed and interrupted runs stay silent"

# ---------------------------------------------------------------------------
echo "[5] a green test run reminds once per window, not per rerun"
out1="$(journal_hook "$(bash_payload s-fail 'pnpm test' 0)")"
case "$out1" in *"JOURNAL ENTRY DUE"*) ;; *) fail "green test run after real edits did not remind" ;; esac
out2="$(journal_hook "$(bash_payload s-fail 'pnpm test' 0)")"
[ -z "$out2" ] || fail "a rerun inside the debounce window reminded again"
pass "one reminder per debounce window"

# ---------------------------------------------------------------------------
echo "[6] a test run with no edits since the last entry is not a milestone"
out="$(journal_hook "$(bash_payload s-clean 'pytest' 0)")"
[ -z "$out" ] || fail "test run with no intervening edits reminded: $out"
pass "no edits since last entry → no reminder"

# ---------------------------------------------------------------------------
echo "[7] the edit threshold announces once, not on every later edit"
reminders=0
for _ in $(seq 1 19); do
  out="$(journal_hook "$(edit_payload s-thresh)")"
  case "$out" in *"JOURNAL ENTRY DUE"*) reminders=$((reminders + 1)) ;; esac
done
[ "$reminders" -eq 1 ] || fail "19 edits produced $reminders reminders (expected exactly 1)"
out="$(journal_hook "$(edit_payload s-thresh)")"
case "$out" in *"JOURNAL ENTRY DUE"*) ;; *) fail "the 20th edit did not announce the next threshold" ;; esac
pass "announces at 10 and 20, never in between"

# ---------------------------------------------------------------------------
echo "[8] concurrent sessions keep independent counters"
for _ in $(seq 1 9); do journal_hook "$(edit_payload s-alpha)" >/dev/null; done
for _ in $(seq 1 9); do journal_hook "$(edit_payload s-beta)" >/dev/null; done
alpha_n="$(HQ_ROOT="$FR" "$HELPER" tool-counter read --session s-alpha)"
beta_n="$(HQ_ROOT="$FR" "$HELPER" tool-counter read --session s-beta)"
[ "$alpha_n" = "9" ] || fail "alpha counter is $alpha_n, expected 9 (cross-session contamination)"
[ "$beta_n" = "9" ] || fail "beta counter is $beta_n, expected 9 (cross-session contamination)"
out="$(journal_hook "$(edit_payload s-alpha)")"
case "$out" in *"JOURNAL ENTRY DUE"*) ;; *) fail "alpha's own 10th edit did not remind" ;; esac
out="$(journal_hook "$(edit_payload s-beta)")"
case "$out" in *"JOURNAL ENTRY DUE"*) ;; *) fail "beta's own 10th edit did not remind" ;; esac
pass "18 interleaved edits did not cross-trigger"

# ---------------------------------------------------------------------------
echo "[9] concurrent sessions keep independent checkpoint debounce"
# s-one already burned its checkpoint above and is inside its debounce window.
out="$(checkpoint_hook "$(bash_payload s-one 'gh pr create' 0)")"
[ -z "$out" ] || fail "s-one nudged again inside its own debounce window"
out="$(checkpoint_hook "$(bash_payload s-two 'gh pr create' 0)")"
case "$out" in *AUTO-CHECKPOINT*) ;; *) fail "s-two was suppressed by another session's debounce" ;; esac
pass "debounce is per session"

# ---------------------------------------------------------------------------
echo "[10] a journal entry resets only the writing session's counter"
HQ_ROOT="$FR" "$HELPER" tool-counter reset --session s-alpha >/dev/null
HQ_ROOT="$FR" "$HELPER" tool-counter increment --session s-alpha >/dev/null
HQ_ROOT="$FR" "$HELPER" tool-counter reset --session s-beta >/dev/null
for _ in $(seq 1 4); do HQ_ROOT="$FR" "$HELPER" tool-counter increment --session s-beta >/dev/null; done
HQ_ROOT="$FR" "$HELPER" write "alpha milestone" --session s-alpha >/dev/null
alpha_n="$(HQ_ROOT="$FR" "$HELPER" tool-counter read --session s-alpha)"
beta_n="$(HQ_ROOT="$FR" "$HELPER" tool-counter read --session s-beta)"
[ "$alpha_n" = "0" ] || fail "writing a journal did not reset the writer's counter (got $alpha_n)"
[ "$beta_n" = "4" ] || fail "writing a journal clobbered another session's counter (got $beta_n, expected 4)"
pass "reset is scoped to the writing session"

# ---------------------------------------------------------------------------
echo "[11] counter increments survive concurrent writers"
HQ_ROOT="$FR" "$HELPER" tool-counter reset --session s-race >/dev/null
for _ in $(seq 1 30); do
  HQ_ROOT="$FR" "$HELPER" tool-counter increment --session s-race >/dev/null &
done
wait
race_n="$(HQ_ROOT="$FR" "$HELPER" tool-counter read --session s-race)"
[ "$race_n" = "30" ] || fail "30 concurrent increments landed as $race_n (lost update)"
pass "30 concurrent increments → 30"

# ---------------------------------------------------------------------------
echo "[12] writing a journal entry re-arms the reminder for that session"
# /journal runs from a plain shell that cannot know the hook's session key, so
# the hook must notice the new entry itself and clear its own counter.
for _ in $(seq 1 10); do journal_hook "$(edit_payload s-heal)" >/dev/null; done
before="$(HQ_ROOT="$FR" "$HELPER" tool-counter read --session s-heal)"
[ "$before" = "10" ] || fail "s-heal counter is $before, expected 10"
HQ_ROOT="$FR" "$HELPER" write "heal milestone" >/dev/null   # no --session, as /journal does
journal_hook "$(edit_payload s-heal)" >/dev/null
after="$(HQ_ROOT="$FR" "$HELPER" tool-counter read --session s-heal)"
[ "$after" = "1" ] || fail "counter did not re-arm after a journal entry (got $after, expected 1)"
reminders=0
for _ in $(seq 1 9); do
  out="$(journal_hook "$(edit_payload s-heal)")"
  case "$out" in *"JOURNAL ENTRY DUE"*) reminders=$((reminders + 1)) ;; esac
done
[ "$reminders" -eq 1 ] || fail "post-journal threshold produced $reminders reminders (expected 1)"
pass "a journal entry resets the counter and the next 10 edits remind once"

# ---------------------------------------------------------------------------
echo "[13] hook state is not keyed by PPID and not written to /tmp"
grep -q 'hq-checkpoint-last-\${PPID}' "$HOOKS/auto-checkpoint-trigger.sh" \
  && fail "auto-checkpoint-trigger.sh still keys its debounce by PPID"
grep -q '"/tmp/' "$HOOKS/auto-checkpoint-trigger.sh" \
  && fail "auto-checkpoint-trigger.sh still stores state in /tmp"
[ -d "$FR/workspace/orchestrator/hook-state" ] || fail "hook state dir was not created under the HQ root"
pass "state lives under workspace/orchestrator/hook-state"

# ---------------------------------------------------------------------------
echo "[14] counter lock exhaustion skips without changing or removing a live lock"
HQ_ROOT="$FR" "$HELPER" tool-counter reset --session s-lock-exhausted >/dev/null
lock_dir="$(HQ_ROOT="$FR" "$HELPER" dir-path)/.tool-count-s-lock-exhausted.lock"
mkdir -p "$lock_dir"
# This test process remains alive while the helper contends, so the lock is
# demonstrably live and must not be reclaimed.
printf '%s\n' "$$" > "$lock_dir/pid"
HQ_JOURNAL_COUNTER_LOCK_TRIES=5 HQ_ROOT="$FR" "$HELPER" tool-counter increment --session s-lock-exhausted >/dev/null 2>&1
lock_n="$(HQ_ROOT="$FR" "$HELPER" tool-counter read --session s-lock-exhausted)"
[ "$lock_n" = "0" ] || fail "lock exhaustion ran the callback unlocked (counter is $lock_n)"
[ -d "$lock_dir" ] || fail "lock exhaustion removed a live lock owned by another process"
[ "$(cat "$lock_dir/pid")" = "$$" ] || fail "live lock owner marker changed"
pass "live-lock exhaustion skipped the counter callback and preserved the lock"

# ---------------------------------------------------------------------------
echo "[15] dead-owner counter locks are reclaimed before the callback"
HQ_ROOT="$FR" "$HELPER" tool-counter reset --session s-stale-lock >/dev/null
stale_lock_dir="$(HQ_ROOT="$FR" "$HELPER" dir-path)/.tool-count-s-stale-lock.lock"
mkdir -p "$stale_lock_dir"
printf '%s\n' 999999999 > "$stale_lock_dir/pid"
HQ_ROOT="$FR" "$HELPER" tool-counter increment --session s-stale-lock >/dev/null 2>&1
stale_n="$(HQ_ROOT="$FR" "$HELPER" tool-counter read --session s-stale-lock)"
[ "$stale_n" = "1" ] || fail "dead-owner lock was not reclaimed (counter is $stale_n)"
[ ! -d "$stale_lock_dir" ] || fail "stale lock directory remains after successful reclaim"
pass "dead-owner lock was reclaimed and the increment ran under the new lock"

# ---------------------------------------------------------------------------
echo "[16] fresh PID-less counter locks are not reclaimed"
HQ_ROOT="$FR" "$HELPER" tool-counter reset --session s-pidless-fresh >/dev/null
fresh_lock_dir="$(HQ_ROOT="$FR" "$HELPER" dir-path)/.tool-count-s-pidless-fresh.lock"
mkdir -p "$fresh_lock_dir"
set_mtime_seconds_ago 30 "$fresh_lock_dir"
HQ_JOURNAL_COUNTER_LOCK_TRIES=1 HQ_ROOT="$FR" "$HELPER" tool-counter increment --session s-pidless-fresh >/dev/null 2>&1
fresh_n="$(HQ_ROOT="$FR" "$HELPER" tool-counter read --session s-pidless-fresh)"
[ "$fresh_n" = "0" ] || fail "fresh PID-less lock was reclaimed (counter is $fresh_n)"
[ -d "$fresh_lock_dir" ] || fail "fresh PID-less lock directory was removed"
pass "30-second PID-less lock stayed in place and the update was skipped"

# ---------------------------------------------------------------------------
echo "[17] aged PID-less counter locks from interrupted creators are reclaimed"
HQ_ROOT="$FR" "$HELPER" tool-counter reset --session s-pidless-lock >/dev/null
pidless_lock_dir="$(HQ_ROOT="$FR" "$HELPER" dir-path)/.tool-count-s-pidless-lock.lock"
mkdir -p "$pidless_lock_dir"
set_mtime_seconds_ago 61 "$pidless_lock_dir"
HQ_ROOT="$FR" "$HELPER" tool-counter increment --session s-pidless-lock >/dev/null 2>&1
pidless_n="$(HQ_ROOT="$FR" "$HELPER" tool-counter read --session s-pidless-lock)"
[ "$pidless_n" = "1" ] || fail "aged PID-less lock was not reclaimed (counter is $pidless_n)"
[ ! -d "$pidless_lock_dir" ] || fail "aged PID-less lock directory remains after successful reclaim"
pass "aged PID-less lock was reclaimed and increment ran under the new lock"

echo "[18] paused publisher retries after reclaiming a legacy PID-less lock"
HQ_ROOT="$FR" "$HELPER" tool-counter reset --session s-paused-publisher >/dev/null
paused_lock_dir="$(HQ_ROOT="$FR" "$HELPER" dir-path)/.tool-count-s-paused-publisher.lock"
pause_bin="$TMP_ROOT/pause-bin"
mkdir -p "$pause_bin"
mkfifo "$TMP_ROOT/publish-ready" "$TMP_ROOT/publish-release"
real_mkdir="$(command -v mkdir)"
cat > "$pause_bin/mkdir" <<'MKDIR'
#!/usr/bin/env bash
if [ "${1:-}" = "$HQ_JOURNAL_TEST_PAUSE_TARGET.publish" ] && mkdir "$HQ_JOURNAL_TEST_PAUSE_ONCE" 2>/dev/null; then
  : > "$HQ_JOURNAL_TEST_PUBLISH_READY"
  IFS= read -r _ < "$HQ_JOURNAL_TEST_PUBLISH_RELEASE"
fi
exec "$HQ_JOURNAL_TEST_REAL_MKDIR" "$@"
MKDIR
chmod +x "$pause_bin/mkdir"
PATH="$pause_bin:$PATH" HQ_ROOT="$FR" \
  HQ_JOURNAL_TEST_PAUSE_TARGET="$paused_lock_dir" \
  HQ_JOURNAL_TEST_PAUSE_ONCE="$TMP_ROOT/publish-paused" \
  HQ_JOURNAL_TEST_PUBLISH_READY="$TMP_ROOT/publish-ready" \
  HQ_JOURNAL_TEST_PUBLISH_RELEASE="$TMP_ROOT/publish-release" \
  HQ_JOURNAL_TEST_REAL_MKDIR="$real_mkdir" "$HELPER" tool-counter increment --session s-paused-publisher >/dev/null 2>&1 &
paused_publisher_pid=$!
IFS= read -r _ < "$TMP_ROOT/publish-ready"
mkdir -p "$paused_lock_dir"
injected_now=$(($(date -u +%s) + 61))
HQ_JOURNAL_COUNTER_NOW="$injected_now" HQ_ROOT="$FR" "$HELPER" tool-counter increment --session s-paused-publisher >/dev/null 2>&1
: > "$TMP_ROOT/publish-release"
wait "$paused_publisher_pid" || fail "paused publisher did not finish"
paused_total="$(HQ_ROOT="$FR" "$HELPER" tool-counter read --session s-paused-publisher)"
[ "$paused_total" = "2" ] || fail "paused publisher and reclaimer produced $paused_total increments instead of 2"
pass "reclaimer took the aged legacy lock; resumed publisher retried and both increments landed"

# ---------------------------------------------------------------------------
echo "[19] dead publisher claims are reclaimed"
HQ_ROOT="$FR" "$HELPER" tool-counter reset --session s-dead-publish-claim >/dev/null
dead_publish_claim="$(HQ_ROOT="$FR" "$HELPER" dir-path)/.tool-count-s-dead-publish-claim.lock.publish"
mkdir -p "$dead_publish_claim"
printf '%s\n' 999999999 > "$dead_publish_claim/pid"
printf '%s\n' dead-owner > "$dead_publish_claim/owner-token"
HQ_ROOT="$FR" "$HELPER" tool-counter increment --session s-dead-publish-claim >/dev/null 2>&1
dead_publish_n="$(HQ_ROOT="$FR" "$HELPER" tool-counter read --session s-dead-publish-claim)"
[ "$dead_publish_n" = "1" ] || fail "dead publisher claim blocked increment (counter is $dead_publish_n)"
[ ! -e "$dead_publish_claim" ] || fail "dead publisher claim remains after successful reclaim"
pass "dead publisher claim was reclaimed and the counter incremented"

# ---------------------------------------------------------------------------
echo "[20] aged PID-less publisher claims are reclaimed with the injected clock"
HQ_ROOT="$FR" "$HELPER" tool-counter reset --session s-pidless-publish-claim >/dev/null
pidless_publish_claim="$(HQ_ROOT="$FR" "$HELPER" dir-path)/.tool-count-s-pidless-publish-claim.lock.publish"
mkdir -p "$pidless_publish_claim"
set_mtime_seconds_ago 61 "$pidless_publish_claim"
injected_now=$(($(date -u +%s) + 61))
HQ_JOURNAL_COUNTER_NOW="$injected_now" HQ_ROOT="$FR" "$HELPER" tool-counter increment --session s-pidless-publish-claim >/dev/null 2>&1
pidless_publish_n="$(HQ_ROOT="$FR" "$HELPER" tool-counter read --session s-pidless-publish-claim)"
[ "$pidless_publish_n" = "1" ] || fail "aged PID-less publisher claim blocked increment (counter is $pidless_publish_n)"
[ ! -e "$pidless_publish_claim" ] || fail "aged PID-less publisher claim remains after successful reclaim"
pass "aged PID-less publisher claim was reclaimed using the injected clock"

# ---------------------------------------------------------------------------
echo "[21] aged orphan publisher temp directories are cleaned"
HQ_ROOT="$FR" "$HELPER" tool-counter reset --session s-orphan-publish-temp >/dev/null
orphan_lock_dir="$(HQ_ROOT="$FR" "$HELPER" dir-path)/.tool-count-s-orphan-publish-temp.lock"
orphan_temp="${orphan_lock_dir}.tmp.orphan"
mkdir -p "$orphan_temp"
printf '%s\n' orphan-token > "$orphan_temp/owner-token"
set_mtime_seconds_ago 61 "$orphan_temp"
injected_now=$(($(date -u +%s) + 61))
HQ_JOURNAL_COUNTER_NOW="$injected_now" HQ_ROOT="$FR" "$HELPER" tool-counter increment --session s-orphan-publish-temp >/dev/null 2>&1
orphan_temp_n="$(HQ_ROOT="$FR" "$HELPER" tool-counter read --session s-orphan-publish-temp)"
[ "$orphan_temp_n" = "1" ] || fail "orphan temp cleanup prevented increment (counter is $orphan_temp_n)"
[ ! -e "$orphan_temp" ] || fail "aged orphan temp directory was not cleaned"
pass "aged PID-less orphan temp directory was cleaned before publish"

# ---------------------------------------------------------------------------
echo "[21b] aged orphan temp directories left by the native helper are cleaned"
# Older hq-cli native builds named publisher temp dirs <lock>.tmp-XXXXXX. The
# shell reclaimer must still clean those so neither implementation strands
# the other's orphans.
HQ_ROOT="$FR" "$HELPER" tool-counter reset --session s-native-orphan-temp >/dev/null
native_orphan_lock_dir="$(HQ_ROOT="$FR" "$HELPER" dir-path)/.tool-count-s-native-orphan-temp.lock"
native_orphan_temp="${native_orphan_lock_dir}.tmp-AbC123"
mkdir -p "$native_orphan_temp"
printf '%s\n' 999999999 > "$native_orphan_temp/pid"
printf '%s\n' native-orphan-token > "$native_orphan_temp/owner-token"
set_mtime_seconds_ago 61 "$native_orphan_temp"
injected_now=$(($(date -u +%s) + 61))
HQ_JOURNAL_COUNTER_NOW="$injected_now" HQ_ROOT="$FR" "$HELPER" tool-counter increment --session s-native-orphan-temp >/dev/null 2>&1
native_orphan_n="$(HQ_ROOT="$FR" "$HELPER" tool-counter read --session s-native-orphan-temp)"
[ "$native_orphan_n" = "1" ] || fail "native orphan temp cleanup prevented increment (counter is $native_orphan_n)"
[ ! -e "$native_orphan_temp" ] || fail "aged native-prefix orphan temp directory was not cleaned"
pass "aged orphan temp directory from the native helper was cleaned before publish"

# ---------------------------------------------------------------------------
echo "[22] Windows cross-PID lock ownership diagnostics and parity"
case "${OSTYPE:-}" in
  msys*|cygwin*|win32*)
    winpid="$(cat "/proc/$$/winpid" 2>/dev/null || true)"
    [ -n "$winpid" ] || fail "Git Bash did not expose this shell's Win32 PID"
    echo "  tasklist.exe resolution: $(command -v tasklist.exe || echo MISSING)"
    raw_tasklist="$(MSYS_NO_PATHCONV=1 tasklist.exe /FO CSV /NH /FI "PID eq $winpid" 2>&1)" \
      || fail "tasklist.exe failed for live Win32 PID $winpid: $raw_tasklist"
    parsed_tasklist="$(printf '%s\n' "$raw_tasklist" | tr -d '\r"' | cut -d, -f2)"
    echo "  tasklist raw row: $raw_tasklist"
    echo "  tasklist parsed PID: $parsed_tasklist"
    printf '0\n' >"$FR/workspace/threads/journal/$(date +%Y-%m-%d)/.tool-count-s-winpid-busy"
    winpid_lock_dir="$FR/workspace/threads/journal/$(date +%Y-%m-%d)/.tool-count-s-winpid-busy.lock"
    mkdir -p "$winpid_lock_dir"
    printf '%s\n' 999999999 >"$winpid_lock_dir/pid"
    printf '%s\n' "$winpid" >"$winpid_lock_dir/winpid"
    HQ_JOURNAL_COUNTER_LOCK_TRIES=1 HQ_ROOT="$FR" "$HELPER" tool-counter increment --session s-winpid-busy >/dev/null 2>&1
    winpid_n="$(HQ_ROOT="$FR" "$HELPER" tool-counter read --session s-winpid-busy)"
    [ "$winpid_n" = "0" ] || fail "live Win32 lock owner was treated as dead (counter is $winpid_n)"
    [ -d "$winpid_lock_dir" ] || fail "lock with a live Win32 owner was reclaimed"
    pass "live Win32 PID keeps the cross-PID lock busy"
    ;;
  *)
    echo "  skipped: Windows Git Bash only"
    ;;
esac

echo "checkpoint/journal over-trigger regressions: ok"
