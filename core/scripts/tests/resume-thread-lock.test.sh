#!/usr/bin/env bash
# Regression coverage for /resumework's durable, user-confirmed thread lock.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/core/scripts/resume-thread-lock.sh"
SKILL="$ROOT/.claude/skills/resumework/SKILL.md"
STARTWORK_SKILL="$ROOT/.claude/skills/startwork/SKILL.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

THREAD_ID="T-resume-lock-test"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_json() {
  local json="$1" filter="$2" message="$3"
  jq -e "$filter" <<<"$json" >/dev/null || fail "$message: $json"
}

[[ -x "$SCRIPT" ]] || fail "resume lock helper is missing or not executable"
[[ -f "$SKILL" ]] || fail "resumework skill is missing"
[[ -f "$STARTWORK_SKILL" ]] || fail "startwork skill is missing"

# The locked state must be rendered through the runtime's explicit decision
# surface; the helper supplies the interpolated prompt, but never auto-forces.
grep -Fq 'resume-thread-lock.sh inspect "$thread_id"' "$SKILL" \
  || fail "resumework does not inspect the durable lock"
grep -Fq 'AskUserQuestion' "$SKILL" \
  || fail "resumework lacks the explicit confirmation surface"
grep -Fq 'Re-resume anyway?' "$SKILL" \
  || fail "resumework lacks the locked-thread confirmation wording"
grep -Fq '**`locked` or `stale`** — use **AskUserQuestion** and wait.' "$SKILL" \
  || fail "resumework does not route every existing marker through confirmation"
grep -Fq 'resume-thread-lock.sh acquire "$thread_id" --replace' "$SKILL" \
  || fail "resumework cannot refresh a confirmed lock"
grep -Fq -- '--expected-generation' "$SKILL" \
  || fail "resumework does not pin a confirmed re-resume to the inspected lock"
grep -Fq -- "-path 'workspace/threads/resume-locks' -prune" "$SKILL" \
  || fail "resumework resolution can mistake a lock record for a thread"
grep -Fq 'same resume-lock confirmation procedure from `/resumework` Step 2' "$STARTWORK_SKILL" \
  || fail "startwork latest-handoff resume bypasses the lock"
grep -Fq 'resume-thread-lock.sh inspect "{thread_id}"' "$STARTWORK_SKILL" \
  || fail "startwork does not inspect the latest thread lock"

mkdir -p "$TMP/workspace/threads"

# Unlocked threads proceed: inspection reports unlocked, then acquisition writes
# a session-attributed marker beside the thread store (not inside archived data).
unlocked="$(HQ_ROOT="$TMP" "$SCRIPT" inspect "$THREAD_ID")"
assert_json "$unlocked" '.status == "unlocked"' "unlocked thread was not allowed to proceed"

created="$(HQ_ROOT="$TMP" "$SCRIPT" acquire "$THREAD_ID" --session-id session-first)"
assert_json "$created" '.status == "acquired"' "first resume did not acquire the lock"
assert_json "$created" '.session_id == "session-first"' "first lock missed its owning session"
marker="$TMP/workspace/threads/resume-locks/$THREAD_ID.lock/current.json"
[[ -f "$marker" ]] || fail "first resume did not write the lock marker"
git -C "$ROOT" check-ignore -q "workspace/threads/resume-locks/$THREAD_ID.lock/current.json" \
  || fail "resume lock markers must be local runtime state, not handoff changeset noise"

# The resolver must continue to find an archived handoff by partial/full id
# without treating the marker's current.json as a second candidate.
archived_thread="$TMP/workspace/threads/archive/2026-07/$THREAD_ID.json"
mkdir -p "$(dirname "$archived_thread")"
printf '%s\n' '{"thread_id":"T-resume-lock-test"}' > "$archived_thread"
archived_matches="$(
  cd "$TMP"
  find workspace/threads \
    -path 'workspace/threads/resume-locks' -prune -o \
    -name '*.json' ! -name '*.changeset.json' -path "*${THREAD_ID}*" -print
)"
assert_json "$(printf '%s\n' "$archived_matches" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
  '[.] == [["workspace/threads/archive/2026-07/T-resume-lock-test.json"]]' \
  "resume lock marker leaked into archived-thread resolution"

# A second ordinary resume is rejected by the helper and yields the exact
# user-facing prompt data that the skill presents through AskUserQuestion.
set +e
duplicate="$(HQ_ROOT="$TMP" "$SCRIPT" acquire "$THREAD_ID" --session-id session-second 2>&1)"
duplicate_status=$?
set -e
[[ "$duplicate_status" -eq 3 ]] || fail "second resume should require confirmation (exit $duplicate_status)"
assert_json "$duplicate" '.status == "locked"' "second resume did not report a lock"
assert_json "$duplicate" '.session_id == "session-first"' "locked prompt lost the original session"
assert_json "$duplicate" '.prompt | contains("already resumed by session-first")' "locked-path prompt did not fire"

# Once the user confirms, re-resume refreshes the marker to the new session.
first_generation="$(jq -r '.lock_generation' <<<"$duplicate")"
refreshed="$(HQ_ROOT="$TMP" "$SCRIPT" acquire "$THREAD_ID" --replace --expected-generation "$first_generation" --session-id session-second)"
assert_json "$refreshed" '.status == "acquired"' "confirmed re-resume did not refresh the lock"
assert_json "$(cat "$marker")" '.session_id == "session-second"' "refresh did not retain the new owner"

# A re-resume confirmation is pinned to the marker the user saw. If another
# session refreshes it while the question is open, the older confirmation must
# re-inspect and ask again instead of silently replacing the newer owner.
second_state="$(HQ_ROOT="$TMP" "$SCRIPT" inspect "$THREAD_ID")"
second_generation="$(jq -r '.lock_generation' <<<"$second_state")"
third_resume="$(HQ_ROOT="$TMP" "$SCRIPT" acquire "$THREAD_ID" --replace --expected-generation "$second_generation" --session-id session-third)"
assert_json "$third_resume" '.status == "acquired"' "concurrent refresh setup failed"

set +e
stale_confirmation="$(HQ_ROOT="$TMP" "$SCRIPT" acquire "$THREAD_ID" --replace --expected-generation "$second_generation" --session-id session-second 2>&1)"
stale_confirmation_status=$?
set -e
[[ "$stale_confirmation_status" -eq 4 ]] || fail "changed lock should require a fresh confirmation (exit $stale_confirmation_status)"
assert_json "$stale_confirmation" '.session_id == "session-third"' "changed lock did not report the newer owner"
assert_json "$(cat "$marker")" '.session_id == "session-third"' "stale confirmation overwrote the newer lock"

# The compare-and-replace window is itself serialized, so two confirmations
# cannot both pass a generation comparison and overwrite each other.
replace_claim="$TMP/workspace/threads/resume-locks/$THREAD_ID.lock/.replace-claim"
mkdir "$replace_claim"
third_state="$(HQ_ROOT="$TMP" "$SCRIPT" inspect "$THREAD_ID")"
third_generation="$(jq -r '.lock_generation' <<<"$third_state")"
set +e
claimed_confirmation="$(HQ_ROOT="$TMP" "$SCRIPT" acquire "$THREAD_ID" --replace --expected-generation "$third_generation" --session-id session-fourth 2>&1)"
claimed_confirmation_status=$?
set -e
[[ "$claimed_confirmation_status" -eq 4 ]] || fail "active replacement claim should force a fresh confirmation (exit $claimed_confirmation_status)"
assert_json "$claimed_confirmation" '.session_id == "session-third"' "active claim did not return the current lock owner"
assert_json "$(cat "$marker")" '.session_id == "session-third"' "active claim allowed a concurrent overwrite"
rmdir "$replace_claim"

# Expired markers remain visible as stale rather than being silently deleted;
# the skill must still ask before --replace can recover them.
STALE_ID="T-stale-resume-lock"
stale_marker="$TMP/workspace/threads/resume-locks/$STALE_ID.lock/current.json"
mkdir -p "$(dirname "$stale_marker")"
printf '%s\n' '{"version":1,"thread_id":"T-stale-resume-lock","session_id":"session-old","resumed_at":"1970-01-01T00:00:01Z","resumed_epoch":1,"generation":"stale-lock-generation"}' > "$stale_marker"

stale="$(HQ_ROOT="$TMP" "$SCRIPT" inspect "$STALE_ID")"
assert_json "$stale" '.status == "stale"' "expired marker was not surfaced as stale"
assert_json "$stale" '.stale_reason == "expired"' "stale marker lacked its expiry reason"
assert_json "$stale" '.prompt | contains("already resumed by session-old")' "stale lock did not preserve the confirmation prompt"

set +e
stale_duplicate="$(HQ_ROOT="$TMP" "$SCRIPT" acquire "$STALE_ID" --session-id session-new 2>&1)"
stale_status=$?
set -e
[[ "$stale_status" -eq 3 ]] || fail "stale resume should still require confirmation (exit $stale_status)"
assert_json "$stale_duplicate" '.status == "stale"' "stale acquisition did not preserve the confirmation gate"

stale_generation="$(jq -r '.lock_generation' <<<"$stale_duplicate")"
stale_refreshed="$(HQ_ROOT="$TMP" "$SCRIPT" acquire "$STALE_ID" --replace --expected-generation "$stale_generation" --session-id session-new)"
assert_json "$stale_refreshed" '.status == "acquired"' "confirmed stale re-resume did not refresh the lock"

echo "PASS: resume-thread-lock"
