#!/usr/bin/env bash
# Regression for feedback_aba2d75e-fb4d-4910-9e65-3cc501abc8f3:
# JOURNAL ENTRY DUE and AUTO-CHECKPOINT SUGGESTED fired on nearly every test
# run and PR operation. Each advisory reminder now fires at most once per
# 30 minutes per trigger type per session. Mandatory precompact checkpoints
# are never suppressed.
#
# Time is simulated by rewriting the session's epoch stamps in the hook-state
# dir, so the test does not sleep.

set -uo pipefail

CORE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT="$(cd "$CORE_ROOT/.." && pwd)"
HOOKS="$ROOT/.claude/hooks"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok - $*"; }

FR="$TMP_ROOT/hq"
mkdir -p "$FR/core/scripts" "$FR/.claude/hooks" "$FR/workspace/threads"
cp "$ROOT/core/scripts/hook-lib.sh" "$ROOT/core/scripts/session-journal.sh" "$FR/core/scripts/"
cp "$HOOKS/journal-due.sh" "$HOOKS/hook-timeout-probe.sh" "$HOOKS/auto-checkpoint-trigger.sh" \
   "$HOOKS/auto-checkpoint-precompact.sh" "$FR/.claude/hooks/"
chmod +x "$FR/core/scripts"/*.sh "$FR/.claude/hooks"/*.sh
git -C "$FR" init -q
git -C "$FR" config user.email t@example.com
git -C "$FR" config user.name t
echo root > "$FR/README.md"
git -C "$FR" add -A >/dev/null 2>&1
git -C "$FR" commit -qm root >/dev/null 2>&1
STATE="$FR/workspace/orchestrator/hook-state"

unwrap() { [ -n "$1" ] || return 0; jq -r '.hookSpecificOutput.additionalContext // empty' <<<"$1"; }
cp_hook() { unwrap "$(CLAUDE_PROJECT_DIR="$FR" bash "$FR/.claude/hooks/auto-checkpoint-trigger.sh" <<<"$1")"; }
jr_hook() { unwrap "$(CLAUDE_PROJECT_DIR="$FR" bash "$FR/.claude/hooks/journal-due.sh" <<<"$1")"; }
bash_p() {
  jq -cn --arg s "$1" --arg cwd "$FR" --arg c "$2" \
    '{session_id:$s,tool_name:"Bash",cwd:$cwd,tool_input:{command:$c},tool_response:{exit_code:0}}'
}
edit_p() {
  jq -cn --arg s "$1" --arg cwd "$FR" \
    '{session_id:$s,tool_name:"Edit",cwd:$cwd,tool_input:{file_path:($cwd+"/src/a.ts")},tool_response:{exit_code:0}}'
}
# age_session <session> <seconds>: move every epoch stamp of this session back.
age_session() {
  local f v
  for f in "$STATE"/*"$1"*; do
    [ -f "$f" ] || continue
    v="$(tr -dc '0-9' < "$f")"
    [ -n "$v" ] && [ "$v" -gt 999999999 ] || continue
    printf '%s' "$(( v - $2 ))" > "$f"
  done
}
fires() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

CK="AUTO-CHECKPOINT SUGGESTED"
JD="JOURNAL ENTRY DUE"

echo "[1] checkpoint: a second git commit in the same session is suppressed"
fires "$(cp_hook "$(bash_p c1 'git commit -m one')")" "$CK" || fail "first commit did not suggest a checkpoint"
fires "$(cp_hook "$(bash_p c1 'git commit -m two')")" "$CK" && fail "second commit re-fired immediately"
pass "commit fires once"

echo "[2] checkpoint: a second git push in the same session is suppressed"
fires "$(cp_hook "$(bash_p c2 'git push origin x')")" "$CK" || fail "first push did not suggest a checkpoint"
fires "$(cp_hook "$(bash_p c2 'git push origin x')")" "$CK" && fail "second push re-fired immediately"
pass "push fires once"

echo "[3] checkpoint: the window for one trigger type is 30 minutes"
fires "$(cp_hook "$(bash_p c3 'gh pr merge 1 --squash')")" "$CK" || fail "first pr op did not fire"
age_session c3 600
fires "$(cp_hook "$(bash_p c3 'gh pr merge 2 --squash')")" "$CK" && fail "pr op re-fired after 10 minutes"
age_session c3 1250
fires "$(cp_hook "$(bash_p c3 'gh pr merge 3 --squash')")" "$CK" || fail "pr op did not fire again after 31 minutes"
pass "pr-operation: silent at 10 min, fires again after 30 min"

echo "[4] checkpoint: commit after 10 minutes is still suppressed"
age_session c1 600
fires "$(cp_hook "$(bash_p c1 'git commit -m three')")" "$CK" && fail "commit re-fired after 10 minutes"
pass "commit stays quiet inside 30 minutes"

echo "[5] checkpoint: a different trigger type has its own window"
fires "$(cp_hook "$(bash_p c1 'gh pr create --fill')")" "$CK" || fail "pr-operation was suppressed by the git-commit window"
pass "trigger types are independent"

echo "[6] checkpoint: sessions are independent"
fires "$(cp_hook "$(bash_p c6 'git commit -m x')")" "$CK" || fail "another session's commit window leaked into c6"
pass "per-session"

echo "[7] journal: commit reminder fires once per 30 minutes"
fires "$(jr_hook "$(bash_p j1 'git commit -m one')")" "$JD" || fail "first commit did not remind"
fires "$(jr_hook "$(bash_p j1 'git commit -m two')")" "$JD" && fail "journal reminder fired on every commit"
age_session j1 1000
fires "$(jr_hook "$(bash_p j1 'git commit -m three')")" "$JD" && fail "commit reminder re-fired after 16 minutes"
age_session j1 900
fires "$(jr_hook "$(bash_p j1 'git commit -m four')")" "$JD" || fail "commit reminder did not fire again after 31 minutes"
pass "journal commit reminder: once per 30 minutes"

echo "[8] journal: test-run window is 30 minutes"
for _ in 1 2 3; do jr_hook "$(edit_p j2)" >/dev/null; done
fires "$(jr_hook "$(bash_p j2 'pnpm test')")" "$JD" || fail "first green test run did not remind"
age_session j2 1000
fires "$(jr_hook "$(bash_p j2 'pnpm test')")" "$JD" && fail "test-run reminder re-fired after 16 minutes"
pass "test-run reminder stays quiet inside 30 minutes"

echo "[9] journal: commit and test-run are separate trigger types"
fires "$(jr_hook "$(bash_p j2 'git commit -m x')")" "$JD" || fail "commit reminder was suppressed by the test-run window"
pass "trigger types are independent"

echo "[10] mandatory precompact checkpoint is never suppressed"
out="$(CLAUDE_PROJECT_DIR="$FR" bash "$FR/.claude/hooks/auto-checkpoint-precompact.sh" </dev/null)"
fires "$out" "AUTO-CHECKPOINT REQUIRED" || fail "precompact checkpoint was suppressed"
grep -qE 'hook-state|within_window' "$HOOKS/auto-checkpoint-precompact.sh" \
  && fail "precompact hook now reads throttle state"
pass "precompact still emits AUTO-CHECKPOINT REQUIRED"

echo "[11] a future-dated stamp does not wedge reminders silent"
fires "$(cp_hook "$(bash_p f1 'git commit -m a')")" "$CK" || fail "first commit did not fire"
for f in "$STATE"/*f1*; do [ -f "$f" ] || continue; v="$(tr -dc '0-9' < "$f")"; [ "${#v}" -ge 10 ] && printf '99999999999' > "$f"; done
fires "$(cp_hook "$(bash_p f1 'git commit -m b')")" "$CK" || fail "a future checkpoint stamp silenced reminders"
fires "$(jr_hook "$(bash_p f2 'git commit -m a')")" "$JD" || fail "first journal commit did not fire"
printf '99999999999' > "$STATE/journal-commit-f2"
fires "$(jr_hook "$(bash_p f2 'git commit -m b')")" "$JD" || fail "a future journal stamp silenced reminders"
v="$(tr -dc '0-9' < "$STATE/journal-commit-f2")"
[ "$v" -le "$(date +%s)" ] || fail "the future stamp was not overwritten"
pass "future stamps count as expired and are overwritten"

echo "[12] a garbage or oversized stamp does not wedge reminders silent"
printf 'x9999999999' > "$STATE/journal-commit-g1"
fires "$(jr_hook "$(bash_p g1 'git commit -m a')")" "$JD" || fail "a non-numeric stamp silenced reminders"
printf '99999999999999999999999' > "$STATE/journal-commit-g2"
fires "$(jr_hook "$(bash_p g2 'git commit -m a')")" "$JD" || fail "an oversized stamp silenced reminders"
fires "$(jr_hook "$(bash_p g2 'git commit -m b')")" "$JD" && fail "window did not re-arm after an oversized stamp"
pass "garbage and oversized stamps count as expired"

echo "reminder throttle (30 min per trigger type per session): ok"
