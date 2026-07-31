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

# A throwaway HQ root that carries the real scripts the hooks depend on.
make_root() {
  local fr="$1"
  mkdir -p "$fr/core/scripts" "$fr/.claude/hooks" "$fr/workspace/threads"
  cp "$ROOT/core/scripts/hook-lib.sh" "$fr/core/scripts/hook-lib.sh"
  cp "$ROOT/core/scripts/session-journal.sh" "$fr/core/scripts/session-journal.sh"
  cp "$HOOKS/journal-due.sh" "$fr/.claude/hooks/journal-due.sh"
  cp "$HOOKS/auto-checkpoint-trigger.sh" "$fr/.claude/hooks/auto-checkpoint-trigger.sh"
  chmod +x "$fr/core/scripts"/*.sh "$fr/.claude/hooks"/*.sh
  git -C "$fr" init -q 2>/dev/null
  git -C "$fr" config user.email [EMAIL] 2>/dev/null
  git -C "$fr" config user.name t 2>/dev/null
  echo root > "$fr/README.md"
  git -C "$fr" add -A >/dev/null 2>&1
  git -C "$fr" commit -qm root >/dev/null 2>&1
}

FR="$TMP_ROOT/hq"
make_root "$FR"

journal_hook() { CLAUDE_PROJECT_DIR="$FR" bash "$FR/.claude/hooks/journal-due.sh" <<<"$1"; }
checkpoint_hook() { CLAUDE_PROJECT_DIR="$FR" bash "$FR/.claude/hooks/auto-checkpoint-trigger.sh" <<<"$1"; }

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
git -C "$APP" config user.email [EMAIL]
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

echo "checkpoint/journal over-trigger regressions: ok"
