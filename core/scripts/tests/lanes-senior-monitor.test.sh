#!/usr/bin/env bash
# hq-core: public
# Regression tests for core/scripts/lib/lanes-senior-monitor.sh
# (SessionStart + UserPromptSubmit wrappers under core/hooks/).
#
# A test that has not been watched fail is not a test: the five required
# guard mutations are applied to a copy of the hook and asserted to go red.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LIB="$SRC/core/scripts/lib/lanes-senior-monitor.sh"
WRAP_SS="$SRC/core/hooks/SessionStart/45-lanes-senior-monitor.sh"
WRAP_UPS="$SRC/core/hooks/UserPromptSubmit/45-lanes-senior-monitor.sh"
MASTER="$SRC/.claude/hooks/master-hook.sh"
HS_SRC="$SRC/core/scripts/hq-session.sh"
LIB_SRC="$SRC/core/scripts/lib"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

assert_empty() {
  local value="$1" label="$2"
  if [ -n "$value" ]; then
    fail "$label: expected empty, got: $value"
  fi
}
assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  if ! grep -qF "$needle" <<<"$haystack"; then
    fail "$label: missing '$needle' in: $haystack"
  fi
}
assert_not_contains() {
  local haystack="$1" needle="$2" label="$3"
  if grep -qF "$needle" <<<"$haystack"; then
    fail "$label: unexpectedly contains '$needle' in: $haystack"
  fi
}

[ -f "$LIB" ] || fail "missing $LIB"
[ -f "$WRAP_SS" ] || fail "missing $WRAP_SS"
[ -f "$WRAP_UPS" ] || fail "missing $WRAP_UPS"
command -v jq >/dev/null 2>&1 || fail "jq required"

# This test may run inside a real session. Clear the whole precedence list.
unset HQ_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID \
      CODEX_SESSION_ID CODEX_THREAD_ID GROK_SESSION_ID || true

FIX="$TMP/hq"
mkdir -p "$FIX/core/scripts/lib" "$FIX/workspace/sessions" \
  "$FIX/workspace/lanes/lanes" "$FIX/core/hooks/SessionStart" \
  "$FIX/core/hooks/UserPromptSubmit" "$FIX/.claude/hooks"
cp "$HS_SRC" "$FIX/core/scripts/hq-session.sh"
cp "$LIB_SRC/session-id.sh" "$FIX/core/scripts/lib/"
cp "$LIB_SRC/session-scope-capability.sh" "$FIX/core/scripts/lib/"
chmod +x "$FIX/core/scripts/hq-session.sh" "$LIB" "$WRAP_SS" "$WRAP_UPS"

SID="sess-senior-a"
LANES="$FIX/workspace/lanes/lanes"
EXTRA_ENV=()

reset_store() {
  rm -rf "$FIX/workspace/lanes" "$FIX/workspace/sessions"
  mkdir -p "$LANES" "$FIX/workspace/sessions/$SID"
  printf 'session_id: %s\nstarted_at: "2026-01-01T00:00:00Z"\nsenior: user\n' "$SID" \
    > "$FIX/workspace/sessions/$SID/meta.yaml"
}

write_lane() {
  local id="$1" state="$2" senior_id="$3"
  local project="${4:-hq-cli-lanes}" story="${5:-US-001}"
  jq -n --arg id "$id" --arg st "$state" --arg sid "$senior_id" \
    --arg p "$project" --arg s "$story" \
    '{schema_version:"hq-lane.v1",lane_id:$id,state:$st,
      senior:{kind:"session",id:$sid},project_id:$p,story_id:$s}' \
    > "$LANES/${id}.json"
}

# run_lib <event> [hook-path]
# Sets OUT, ERR, RC.
run_lib() {
  local event="${1:-SessionStart}"
  local hook="${2:-$LIB}"
  local errf outf
  errf="$(mktemp "$TMP/err.XXXXXX")"
  outf="$(mktemp "$TMP/out.XXXXXX")"
  RC=0
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID \
    -u CODEX_SESSION_ID -u CODEX_THREAD_ID -u GROK_SESSION_ID \
    -u HQ_HARNESS -u HQ_WORK_MESH_HARNESS -u HQ_CHECKPOINT_RUNTIME \
    HQ_ROOT="$FIX" CLAUDE_PROJECT_DIR="$FIX" HQ_SESSION_ID="$SID" \
    HQ_HQ_SESSION_NO_CLI=1 HQ_LANES_SENIOR_MONITOR_THROTTLE_S="${THROTTLE:-0}" \
    ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
    bash "$hook" "$event" </dev/null >"$outf" 2>"$errf" || RC=$?
  OUT="$(cat "$outf")"
  ERR="$(cat "$errf")"
  rm -f "$outf" "$errf"
}

silent_ok() {
  local label="$1"
  [ "$RC" = "0" ] || fail "$label: expected rc 0, got $RC stderr=$ERR"
  assert_empty "$OUT" "$label stdout"
  assert_empty "$ERR" "$label stderr"
}

# ── 1. silent_when_not_senior: no lanes directory ──────────────────────────
reset_store
rm -rf "$FIX/workspace/lanes"
run_lib SessionStart
silent_ok "silent_when_not_senior (missing dir)"
pass "silent_when_not_senior (missing dir)"

# ── 2. empty lanes directory is silent (distinct from unreadable) ──────────
reset_store
run_lib SessionStart
silent_ok "empty lanes dir"
pass "empty lanes dir is silent"

# ── 3. other session's running lane is silent ──────────────────────────────
reset_store
write_lane "lane-other" "running" "sess-someone-else"
run_lib SessionStart
silent_ok "other_session_silent"
pass "other_session_silent"

# ── 4. terminal states are silent ──────────────────────────────────────────
reset_store
for st in "done" failed interrupted cancelled killed; do
  write_lane "lane-${st}" "$st" "$SID"
done
run_lib SessionStart
silent_ok "terminal_lanes_silent"
pass "terminal_lanes_silent"

# ── 5. running lane of this session instructs ──────────────────────────────
reset_store
write_lane "lane-run-1" "running" "$SID" "hq-cli-lanes" "US-SENIOR-MONITOR"
run_lib SessionStart
[ "$RC" = "0" ] || fail "instruct running: rc=$RC stderr=$ERR"
assert_empty "$ERR" "instruct running stderr"
assert_contains "$OUT" "lane-run-1" "instruct running lane id"
assert_contains "$OUT" "hq-cli-lanes" "instruct running project"
assert_contains "$OUT" "US-SENIOR-MONITOR" "instruct running story"
assert_contains "$OUT" "every 20 minutes" "instruct running cadence"
assert_contains "$OUT" "state changes" "instruct running state changes"
assert_contains "$OUT" "question" "instruct running questions"
assert_contains "$OUT" "terminal state" "instruct running terminal"
assert_contains "$OUT" "dies with this session" "instruct running mortality"
CTX="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext')"
[ -n "$CTX" ] || fail "instruct running: additionalContext empty"
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null \
  || fail "instruct running: hookEventName"
pass "instructs_for_running"

# Capture exact one-lane text for the report.
ONE_LANE_TEXT="$CTX"

# ── 6. queued / awaiting_input / blocked also instruct ─────────────────────
for st in queued awaiting_input blocked; do
  reset_store
  write_lane "lane-$st" "$st" "$SID"
  run_lib SessionStart
  [ "$RC" = "0" ] || fail "state $st: rc=$RC stderr=$ERR"
  assert_contains "$OUT" "lane-$st" "state $st lane id"
done
pass "queued/awaiting_input/blocked instruct"

# ── 7. instruct_once_per_lane: second event is silent ──────────────────────
reset_store
write_lane "lane-run-1" "running" "$SID"
run_lib SessionStart
assert_contains "$OUT" "lane-run-1" "first instruct"
run_lib SessionStart
silent_ok "instruct_once_per_lane second event"
pass "instruct_once_per_lane"

# ── 8. a lane created later still instructs (once per lane, not session) ───
reset_store
write_lane "lane-a" "running" "$SID"
run_lib SessionStart
assert_contains "$OUT" "lane-a" "first lane"
assert_not_contains "$OUT" "lane-b" "first event must not mention lane-b"
write_lane "lane-b" "running" "$SID" "proj-b" "US-002"
run_lib SessionStart
assert_contains "$OUT" "lane-b" "new lane must instruct"
assert_not_contains "$OUT" "lane-a" "already-instructed lane-a must not repeat"
pass "once_per_lane_not_per_session"

# ── 9. unreadable_store_errors (PATH-injected ls; works as root) ───────────
reset_store
write_lane "lane-run-1" "running" "$SID"
mkdir -p "$TMP/fakels"
cat > "$TMP/fakels/ls" <<'EOF'
#!/bin/bash
for a in "$@"; do
  case "$a" in
    *lanes*)
      echo "ls: cannot open directory '$a': Permission denied" >&2
      exit 2
      ;;
  esac
done
exec /bin/ls "$@"
EOF
chmod +x "$TMP/fakels/ls"
errf="$(mktemp "$TMP/err.XXXXXX")"
outf="$(mktemp "$TMP/out.XXXXXX")"
RC=0
env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID \
  -u CODEX_SESSION_ID -u CODEX_THREAD_ID -u GROK_SESSION_ID \
  -u HQ_HARNESS -u HQ_WORK_MESH_HARNESS -u HQ_CHECKPOINT_RUNTIME \
  PATH="$TMP/fakels:/usr/bin:/bin" \
  HQ_ROOT="$FIX" CLAUDE_PROJECT_DIR="$FIX" HQ_SESSION_ID="$SID" \
  HQ_HQ_SESSION_NO_CLI=1 HQ_LANES_SENIOR_MONITOR_THROTTLE_S=0 \
  bash "$LIB" SessionStart </dev/null >"$outf" 2>"$errf" || RC=$?
OUT="$(cat "$outf")"; ERR="$(cat "$errf")"
rm -f "$outf" "$errf"
[ "$RC" != "0" ] || fail "unreadable_store_errors: expected non-zero rc, got 0 stdout=$OUT"
assert_contains "$ERR" "cannot read lanes directory" "unreadable_store_errors stderr"
assert_empty "$OUT" "unreadable_store_errors stdout"
pass "unreadable_store_errors"

# ── 10. malformed record is an error, not silent ───────────────────────────
reset_store
printf 'not-json\n' > "$LANES/bad.json"
run_lib SessionStart
[ "$RC" != "0" ] || fail "malformed: expected non-zero, got 0 stdout=$OUT"
assert_contains "$ERR" "malformed lane record" "malformed stderr"
assert_empty "$OUT" "malformed stdout"
pass "malformed_record_errors"

# ── 11. mixed: valid match still instructs; malformed still errors ─────────
reset_store
write_lane "lane-run-1" "running" "$SID"
printf 'not-json\n' > "$LANES/bad.json"
run_lib SessionStart
[ "$RC" != "0" ] || fail "mixed malformed: expected non-zero"
assert_contains "$ERR" "malformed lane record" "mixed malformed stderr"
assert_contains "$OUT" "lane-run-1" "mixed malformed still instructs"
pass "malformed among matches still instructs and errors"

# ── 12. throttle: UserPromptSubmit skips; SessionStart does not ────────────
reset_store
write_lane "lane-run-1" "running" "$SID"
mkdir -p "$FIX/workspace/sessions/$SID"
NOW="${EPOCHSECONDS:-$(date +%s)}"
jq -n --argjson ts "$NOW" '{instructed:[],last_scan_unix:$ts}' \
  > "$FIX/workspace/sessions/$SID/lanes-senior-monitor.json"
THROTTLE=180
run_lib UserPromptSubmit
silent_ok "throttle UserPromptSubmit"
run_lib SessionStart
[ "$RC" = "0" ] || fail "throttle SessionStart rc=$RC stderr=$ERR"
assert_contains "$OUT" "lane-run-1" "SessionStart bypasses throttle"
THROTTLE=0
pass "throttle"

# ── 13. stdin drain on the no-session early return ─────────────────────────
reset_store
unset HQ_SESSION_ID || true
: > "$FIX/workspace/sessions/.current"
st="$(env -u HQ_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID \
  -u CODEX_SESSION_ID -u CODEX_THREAD_ID -u GROK_SESSION_ID \
  -u HQ_HARNESS -u HQ_WORK_MESH_HARNESS -u HQ_CHECKPOINT_RUNTIME \
  HQ_ROOT="$FIX" CLAUDE_PROJECT_DIR="$FIX" HQ_HQ_SESSION_NO_CLI=1 \
  bash -c '
    set -o pipefail
    dd if=/dev/zero bs=1024 count=1024 2>/dev/null | tr "\0" "x" | bash "$1" SessionStart >/dev/null 2>&1
  ' _ "$LIB" && echo 0 || echo $?)"
[ "$st" = "0" ] || fail "stdin drain: pipeline status $st (SIGPIPE would be 141)"
pass "stdin drain"

# ── 14. master-hook: no lanes and broken store leave sibling intact ─────────
MH="$TMP/mh"
mkdir -p "$MH/.claude/hooks" "$MH/core/hooks/SessionStart" \
  "$MH/core/scripts/lib" "$MH/workspace/sessions" "$MH/workspace/lanes/lanes"
cp "$MASTER" "$MH/.claude/hooks/master-hook.sh"
cp "$HS_SRC" "$MH/core/scripts/hq-session.sh"
cp "$LIB_SRC/session-id.sh" "$MH/core/scripts/lib/"
cp "$LIB_SRC/session-scope-capability.sh" "$MH/core/scripts/lib/"
cp "$LIB" "$MH/core/scripts/lib/lanes-senior-monitor.sh"
cp "$WRAP_SS" "$MH/core/hooks/SessionStart/45-lanes-senior-monitor.sh"
chmod +x "$MH/.claude/hooks/master-hook.sh" "$MH/core/scripts/hq-session.sh" \
  "$MH/core/scripts/lib/lanes-senior-monitor.sh" \
  "$MH/core/hooks/SessionStart/45-lanes-senior-monitor.sh"
cat > "$MH/core/hooks/SessionStart/99-sibling.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null 2>/dev/null || true
jq -nc '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:"SIBLING-OK"}}'
exit 0
EOF
chmod +x "$MH/core/hooks/SessionStart/99-sibling.sh"

run_master() { # sets MOUT MRC MERR
  local errf outf
  errf="$(mktemp "$TMP/merr.XXXXXX")"
  outf="$(mktemp "$TMP/mout.XXXXXX")"
  MRC=0
  printf '%s' "$2" | env -u HQ_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
    -u CLAUDE_SESSION_ID -u CODEX_SESSION_ID -u CODEX_THREAD_ID -u GROK_SESSION_ID \
    -u HQ_HARNESS -u HQ_WORK_MESH_HARNESS -u HQ_CHECKPOINT_RUNTIME \
    HQ_HOOK_TIMEOUT_SENTRY=0 HQ_ALLOW_HQ_WORKTREE=1 \
    HQ_SESSION_ID="$SID" HQ_HQ_SESSION_NO_CLI=1 \
    HQ_LANES_SENIOR_MONITOR_THROTTLE_S=0 \
    CLAUDE_PROJECT_DIR="$MH" HQ_ROOT="$MH" \
    PATH="${3:-$PATH}" \
    bash "$MH/.claude/hooks/master-hook.sh" "$1" >"$outf" 2>"$errf" || MRC=$?
  MOUT="$(cat "$outf")"; MERR="$(cat "$errf")"
  rm -f "$outf" "$errf"
}

PAYLOAD="$(jq -nc --arg sid "$SID" '{session_id:$sid,hook_event_name:"SessionStart"}')"
run_master SessionStart "$PAYLOAD"
assert_contains "$MOUT" "SIBLING-OK" "master no-lanes sibling"
assert_not_contains "$MOUT" "Arm a Monitor" "master no-lanes must not instruct"
[ "$MRC" = "0" ] || fail "master no-lanes rc=$MRC stderr=$MERR"
pass "master-hook sibling intact with no lanes"

run_master SessionStart "$PAYLOAD" "$TMP/fakels:/usr/bin:/bin"
assert_contains "$MOUT" "SIBLING-OK" "master broken-store sibling"
assert_contains "$MERR" "cannot read lanes directory" "master broken-store stderr"
pass "master-hook sibling intact with broken store"

# ── 15. wrapper files exec the lib ─────────────────────────────────────────
reset_store
write_lane "lane-wrap" "running" "$SID"
run_lib SessionStart "$WRAP_SS"
assert_contains "$OUT" "lane-wrap" "SessionStart wrapper"
run_lib UserPromptSubmit "$WRAP_UPS"
# already instructed by the SessionStart wrapper run
silent_ok "UserPromptSubmit wrapper second look"
pass "wrappers exec the lib"

# ═══════════════════════════════════════════════════════════════════════════
# Mutations: each required guard, applied to a copy, must go red.
# ═══════════════════════════════════════════════════════════════════════════

mutate_copy() {
  local dest="$1"
  cp "$LIB" "$dest"
}

run_mut() {
  local hook="$1" event="${2:-SessionStart}"
  local errf outf
  errf="$(mktemp "$TMP/err.XXXXXX")"
  outf="$(mktemp "$TMP/out.XXXXXX")"
  RC=0
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID \
    -u CODEX_SESSION_ID -u CODEX_THREAD_ID -u GROK_SESSION_ID \
    -u HQ_HARNESS -u HQ_WORK_MESH_HARNESS -u HQ_CHECKPOINT_RUNTIME \
    HQ_ROOT="$FIX" CLAUDE_PROJECT_DIR="$FIX" HQ_SESSION_ID="$SID" \
    HQ_HQ_SESSION_NO_CLI=1 HQ_LANES_SENIOR_MONITOR_THROTTLE_S="${THROTTLE:-0}" \
    ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
    bash "$hook" "$event" </dev/null >"$outf" 2>"$errf" || RC=$?
  OUT="$(cat "$outf")"; ERR="$(cat "$errf")"
  rm -f "$outf" "$errf"
}

# Mutation 1: no-match early return removed → not silent for a non-senior session
reset_store
write_lane "lane-other" "running" "sess-someone-else"
MUT="$TMP/mut-no-match.sh"
mutate_copy "$MUT"
# Delete the no-match-silent guard (the early return).
sed -i '/# GUARD no-match-silent/,/# \/GUARD no-match-silent/d' "$MUT"
run_mut "$MUT"
if [ -z "$OUT" ]; then
  fail "mutation no-match-silent did not go red (still silent). hook still has the guard?"
fi
echo "MUTATION_RED: silent_when_not_senior / deleted GUARD no-match-silent"
pass "mutation 1 went red (no-match-silent)"

# Mutation 2: terminal-state filter dropped → done lane instructs
reset_store
write_lane "lane-done" "done" "$SID"
MUT="$TMP/mut-terminal.sh"
mutate_copy "$MUT"
sed -i 's/select(.state == "queued" or .state == "running" or .state == "awaiting_input" or .state == "blocked")/select(true)/' "$MUT"
run_mut "$MUT"
if ! grep -qF "lane-done" <<<"$OUT"; then
  fail "mutation terminal-state did not go red (done lane still silent). out=$OUT err=$ERR"
fi
echo "MUTATION_RED: terminal_lanes_silent / select(true) for state filter"
pass "mutation 2 went red (terminal-state)"

# Mutation 3: already-instructed check dropped → second event re-instructs
reset_store
write_lane "lane-run-1" "running" "$SID"
MUT="$TMP/mut-dedup.sh"
mutate_copy "$MUT"
sed -i '/# GUARD already-instructed/,/# \/GUARD already-instructed/d' "$MUT"
run_mut "$MUT"
assert_contains "$OUT" "lane-run-1" "mutation 3 first instruct"
run_mut "$MUT"
if ! grep -qF "lane-run-1" <<<"$OUT"; then
  fail "mutation already-instructed did not go red (second event still silent). out=$OUT"
fi
echo "MUTATION_RED: instruct_once_per_lane / deleted GUARD already-instructed"
pass "mutation 3 went red (already-instructed)"

# Mutation 4: senior match loosened to any lane
reset_store
write_lane "lane-other" "running" "sess-someone-else"
MUT="$TMP/mut-senior.sh"
mutate_copy "$MUT"
sed -i 's/select(.senior.kind == "session" and .senior.id == $sid)/select(true)/' "$MUT"
run_mut "$MUT"
if ! grep -qF "lane-other" <<<"$OUT"; then
  fail "mutation senior-match did not go red (other session still silent). out=$OUT err=$ERR"
fi
echo "MUTATION_RED: other_session_silent / select(true) for senior match"
pass "mutation 4 went red (senior-match)"

# Mutation 5: unreadable dir treated as empty (exit 0 instead of exit 1)
reset_store
write_lane "lane-run-1" "running" "$SID"
MUT="$TMP/mut-unread.sh"
mutate_copy "$MUT"
sed -i 's/exit 1  # unreadable-store/exit 0  # unreadable-store/' "$MUT"
errf="$(mktemp "$TMP/err.XXXXXX")"
outf="$(mktemp "$TMP/out.XXXXXX")"
RC=0
env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID \
  -u CODEX_SESSION_ID -u CODEX_THREAD_ID -u GROK_SESSION_ID \
  -u HQ_HARNESS -u HQ_WORK_MESH_HARNESS -u HQ_CHECKPOINT_RUNTIME \
  PATH="$TMP/fakels:/usr/bin:/bin" \
  HQ_ROOT="$FIX" CLAUDE_PROJECT_DIR="$FIX" HQ_SESSION_ID="$SID" \
  HQ_HQ_SESSION_NO_CLI=1 HQ_LANES_SENIOR_MONITOR_THROTTLE_S=0 \
  bash "$MUT" SessionStart </dev/null >"$outf" 2>"$errf" || RC=$?
OUT="$(cat "$outf")"; ERR="$(cat "$errf")"
rm -f "$outf" "$errf"
# Original test unreadable_store_errors requires non-zero rc. Mutated copy
# exits 0 — that is the red. It may still print the error line before exiting.
if [ "$RC" != "0" ]; then
  fail "mutation unreadable-store did not go red (still non-zero rc=$RC err=$ERR)"
fi
echo "MUTATION_RED: unreadable_store_errors / exit 0 on unreadable dir"
pass "mutation 5 went red (unreadable-store)"

# ── 16. finding 1: empty SessionStart must not throttle a later UPS ────────
reset_store
rm -rf "$FIX/workspace/lanes"
THROTTLE=180
run_lib SessionStart
silent_ok "empty SessionStart before late lane"
STATE="$FIX/workspace/sessions/$SID/lanes-senior-monitor.json"
if [ -f "$STATE" ]; then
  [ "$(jq -r '.last_scan_unix' "$STATE")" = "0" ] \
    || fail "empty SessionStart armed last_scan=$(jq -r .last_scan_unix "$STATE")"
fi
mkdir -p "$LANES"
write_lane "lane-late" "running" "$SID"
run_lib UserPromptSubmit
[ "$RC" = "0" ] || fail "late UPS after empty SS rc=$RC stderr=$ERR"
assert_contains "$OUT" "lane-late" "UPS must see a lane created after empty SessionStart"
THROTTLE=0
pass "empty store does not stamp last_scan"

# ── 17. finding 2: mixed store does not stamp last_scan ────────────────────
reset_store
write_lane "lane-run-1" "running" "$SID"
printf 'not-json\n' > "$LANES/bad.json"
run_lib SessionStart
[ "$RC" != "0" ] || fail "mixed: expected non-zero"
assert_contains "$OUT" "lane-run-1" "mixed still instructs"
STATE="$FIX/workspace/sessions/$SID/lanes-senior-monitor.json"
[ -f "$STATE" ] || fail "mixed: missing state file"
[ "$(jq -r '.last_scan_unix' "$STATE")" = "0" ] \
  || fail "mixed stamped last_scan=$(jq -r .last_scan_unix "$STATE")"
jq -e --arg id "lane-run-1" '.instructed | index($id) != null' "$STATE" >/dev/null \
  || fail "mixed: instructed[] missing lane-run-1"
THROTTLE=180
run_lib UserPromptSubmit
[ "$RC" != "0" ] || fail "mixed UPS after stamp-0 should still surface store error"
assert_contains "$ERR" "malformed lane record" "mixed UPS still reports malformed"
THROTTLE=0
pass "mixed store does not stamp last_scan"

# ── 18. finding 3: Grok does not record instructed[] ───────────────────────
reset_store
write_lane "lane-run-1" "running" "$SID"
EXTRA_ENV=(HQ_HARNESS=grok HQ_WORK_MESH_HARNESS=grok HQ_CHECKPOINT_RUNTIME=grok)
run_lib SessionStart
EXTRA_ENV=()
[ "$RC" != "0" ] || fail "grok: expected non-zero rc, got 0 stdout=$OUT"
assert_contains "$ERR" "cannot receive additionalContext" "grok stderr"
assert_empty "$OUT" "grok must not emit additionalContext JSON"
STATE="$FIX/workspace/sessions/$SID/lanes-senior-monitor.json"
if [ -f "$STATE" ]; then
  jq -e --arg id "lane-run-1" '.instructed | index($id) == null' "$STATE" >/dev/null \
    || fail "grok recorded instructed[]=$(jq -c .instructed "$STATE")"
fi
pass "grok does not record a discarded delivery"

# ── 19. finding 4: no jq, no lanes, stays silent ───────────────────────────
reset_store
rm -rf "$FIX/workspace/lanes"
NOJQ="$TMP/nojq"
rm -rf "$NOJQ"
mkdir -p "$NOJQ"
for d in /usr/bin /bin /usr/sbin; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    b="$(basename "$f")"
    [ "$b" = "jq" ] && continue
    [ -e "$NOJQ/$b" ] && continue
    ln -s "$f" "$NOJQ/$b" 2>/dev/null || true
  done
done
RC=0
env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID \
  -u CODEX_SESSION_ID -u CODEX_THREAD_ID -u GROK_SESSION_ID \
  -u HQ_HARNESS -u HQ_WORK_MESH_HARNESS -u HQ_CHECKPOINT_RUNTIME \
  PATH="$NOJQ" HQ_ROOT="$FIX" CLAUDE_PROJECT_DIR="$FIX" HQ_SESSION_ID="$SID" \
  HQ_HQ_SESSION_NO_CLI=1 HQ_LANES_SENIOR_MONITOR_THROTTLE_S=0 \
  bash "$LIB" SessionStart </dev/null >"$TMP/nojq.out" 2>"$TMP/nojq.err" || RC=$?
NOJQ_OUT="$(cat "$TMP/nojq.out")"
NOJQ_ERR="$(cat "$TMP/nojq.err")"
[ "$RC" = "0" ] || fail "no-jq empty store rc=$RC stderr=$NOJQ_ERR"
assert_empty "$NOJQ_OUT" "no-jq empty stdout"
assert_empty "$NOJQ_ERR" "no-jq empty stderr"
pass "no jq, no lanes, silent"

# ── 20. finding 5: state path as a directory is an error ───────────────────
reset_store
write_lane "lane-run-1" "running" "$SID"
STATE="$FIX/workspace/sessions/$SID/lanes-senior-monitor.json"
rm -f "$STATE"
mkdir -p "$STATE"
run_lib SessionStart
[ "$RC" != "0" ] || fail "state-dir: expected non-zero, got 0 stdout=$OUT"
assert_contains "$ERR" "state path is not a file" "state-dir stderr"
assert_empty "$OUT" "state-dir must not instruct"
# mv must not have dropped a temp file into the directory as "success".
if ls -1A "$STATE" 2>/dev/null | grep -q 'lanes-senior-monitor.json.tmp'; then
  fail "state-dir: write_state moved a temp file into the directory"
fi
pass "state path as directory errors"

# ── 21. finding 6: directory symlink at lanes/lanes is refused ─────────────
reset_store
rm -rf "$LANES"
mkdir -p "$FIX/outside" "$FIX/workspace/lanes"
jq -n --arg sid "$SID" \
  '{schema_version:"hq-lane.v1",lane_id:"from-symlink",state:"running",
    senior:{kind:"session",id:$sid},project_id:"p",story_id:"US-1"}' \
  > "$FIX/outside/from-symlink.json"
ln -s "$FIX/outside" "$LANES"
run_lib SessionStart
[ "$RC" != "0" ] || fail "symlink-store: expected non-zero, got 0 stdout=$OUT"
assert_contains "$ERR" "symlink" "symlink-store stderr"
assert_not_contains "$OUT" "from-symlink" "symlink-store must not instruct"
pass "lanes dir symlink is refused"

# Mutation 6: empty-store stamps last_scan (finding 1)
reset_store
rm -rf "$FIX/workspace/lanes"
MUT="$TMP/mut-empty-stamp.sh"
mutate_copy "$MUT"
sed -i 's/STAMP_SCAN=0  # empty-store/STAMP_SCAN=1  # empty-store/' "$MUT"
THROTTLE=180
run_mut "$MUT"
mkdir -p "$LANES"
write_lane "lane-late" "running" "$SID"
run_mut "$MUT" UserPromptSubmit
if grep -qF "lane-late" <<<"$OUT"; then
  fail "mutation empty-no-stamp did not go red (UPS still saw late lane). out=$OUT"
fi
THROTTLE=0
echo "MUTATION_RED: empty_store_no_stamp / STAMP_SCAN=1 on empty-store"
pass "mutation 6 went red (empty-store last_scan)"

# Mutation 7: mixed store stamps last_scan (finding 2)
reset_store
write_lane "lane-run-1" "running" "$SID"
printf 'not-json\n' > "$LANES/bad.json"
MUT="$TMP/mut-mixed-stamp.sh"
mutate_copy "$MUT"
sed -i 's/STAMP_SCAN=0  # store-error/STAMP_SCAN=1  # store-error/' "$MUT"
run_mut "$MUT"
THROTTLE=180
run_mut "$MUT" UserPromptSubmit
if [ "$RC" != "0" ] || [ -n "$ERR" ]; then
  fail "mutation no-stamp-on-store-error did not go red (UPS still saw store error rc=$RC err=$ERR)"
fi
THROTTLE=0
echo "MUTATION_RED: mixed_no_last_scan / STAMP_SCAN=1 on store-error"
pass "mutation 7 went red (mixed last_scan)"

# Mutation 8: unconditional instructed[] write on Grok (finding 3)
reset_store
write_lane "lane-run-1" "running" "$SID"
MUT="$TMP/mut-grok-instructed.sh"
mutate_copy "$MUT"
sed -i '/# GUARD grok-no-false-instructed/,/# \/GUARD grok-no-false-instructed/d' "$MUT"
EXTRA_ENV=(HQ_HARNESS=grok HQ_WORK_MESH_HARNESS=grok HQ_CHECKPOINT_RUNTIME=grok)
run_mut "$MUT"
EXTRA_ENV=()
STATE="$FIX/workspace/sessions/$SID/lanes-senior-monitor.json"
if [ ! -f "$STATE" ] || ! jq -e --arg id "lane-run-1" '.instructed | index($id) != null' "$STATE" >/dev/null; then
  fail "mutation grok-no-false-instructed did not go red (instructed still empty). state=$(cat "$STATE" 2>/dev/null || echo missing)"
fi
echo "MUTATION_RED: grok_no_false_instructed / deleted GUARD grok-no-false-instructed"
pass "mutation 8 went red (grok instructed write)"

# Mutation 9: jq check moved before the empty-store return (finding 4)
reset_store
rm -rf "$FIX/workspace/lanes"
MUT="$TMP/mut-jq-early.sh"
mutate_copy "$MUT"
# Insert a fatal jq requirement immediately after session-id resolution,
# before the missing-dir silence path — the original defect.
sed -i '/^# No session identity:/,/^fi/{
  /^fi$/a\
if ! command -v jq >/dev/null 2>\&1; then\
  echo "lanes-senior-monitor: jq is required to inspect lane records" >\&2\
  exit 1\
fi
}' "$MUT"
RC=0
env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID \
  -u CODEX_SESSION_ID -u CODEX_THREAD_ID -u GROK_SESSION_ID \
  -u HQ_HARNESS -u HQ_WORK_MESH_HARNESS -u HQ_CHECKPOINT_RUNTIME \
  PATH="$NOJQ" HQ_ROOT="$FIX" CLAUDE_PROJECT_DIR="$FIX" HQ_SESSION_ID="$SID" \
  HQ_HQ_SESSION_NO_CLI=1 HQ_LANES_SENIOR_MONITOR_THROTTLE_S=0 \
  bash "$MUT" SessionStart </dev/null >"$TMP/mut-jq.out" 2>"$TMP/mut-jq.err" || RC=$?
if [ "$RC" = "0" ]; then
  fail "mutation jq-early did not go red (still silent without jq). out=$(cat "$TMP/mut-jq.out") err=$(cat "$TMP/mut-jq.err")"
fi
echo "MUTATION_RED: jq_after_empty / early jq check on empty store"
pass "mutation 9 went red (jq before empty silence)"

# Mutation 10: state-dir check removed (finding 5)
reset_store
write_lane "lane-run-1" "running" "$SID"
STATE="$FIX/workspace/sessions/$SID/lanes-senior-monitor.json"
rm -f "$STATE"
mkdir -p "$STATE"
MUT="$TMP/mut-state-dir.sh"
mutate_copy "$MUT"
sed -i '/# GUARD state-not-file/,/# \/GUARD state-not-file/d' "$MUT"
run_mut "$MUT"
if [ "$RC" != "0" ]; then
  fail "mutation state-not-file did not go red (still non-zero rc=$RC err=$ERR)"
fi
echo "MUTATION_RED: state_not_file / deleted GUARD state-not-file"
pass "mutation 10 went red (state dir)"

# Mutation 11: symlink store followed (finding 6)
reset_store
rm -rf "$LANES"
mkdir -p "$FIX/outside" "$FIX/workspace/lanes"
jq -n --arg sid "$SID" \
  '{schema_version:"hq-lane.v1",lane_id:"from-symlink",state:"running",
    senior:{kind:"session",id:$sid},project_id:"p",story_id:"US-1"}' \
  > "$FIX/outside/from-symlink.json"
ln -s "$FIX/outside" "$LANES"
MUT="$TMP/mut-symlink.sh"
mutate_copy "$MUT"
sed -i '/# GUARD refuse-symlink-store/,/# \/GUARD refuse-symlink-store/d' "$MUT"
run_mut "$MUT"
if ! grep -qF "from-symlink" <<<"$OUT"; then
  fail "mutation refuse-symlink-store did not go red (still silent). out=$OUT err=$ERR"
fi
echo "MUTATION_RED: refuse_symlink_store / deleted GUARD refuse-symlink-store"
pass "mutation 11 went red (symlink store)"

# Persist the one-lane injected text for the report writer.
printf '%s\n' "$ONE_LANE_TEXT" > "$TMP/one-lane-text.txt"
# Copy to a stable path under the worktree tmp is gone; write next to the test
# is wrong. The report harvests ONE_LANE_TEXT from a passing run of test 5
# by re-running a tiny extract:
mkdir -p "$SRC/workspace/scratch"
printf '%s\n' "$ONE_LANE_TEXT" > "$SRC/workspace/scratch/lanes-senior-monitor-one-lane.txt"

echo "ALL PASS: lanes-senior-monitor"
exit 0
