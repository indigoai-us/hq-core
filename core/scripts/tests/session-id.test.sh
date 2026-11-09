#!/usr/bin/env bash
# hq-core: public
# Unit tests for core/scripts/lib/session-id.sh
#
# The resolver decides which session every per-session artifact is written to,
# so its precedence and its validation are both load-bearing:
#
#   - Precedence: the session environment describes the process actually
#     running; workspace/sessions/.current is one global pointer that every hook
#     event rewrites, so it is the last resort, not the first.
#   - Validation: the id becomes a path segment under workspace/sessions/, so a
#     traversal- or separator-shaped value must never be returned.

set -euo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/session-id.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"; }

# The test process may itself carry a session id; start from a clean slate.
unset HQ_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID \
      CODEX_SESSION_ID CODEX_THREAD_ID GROK_SESSION_ID HQ_FLEET_SESSION_ID || true

# shellcheck source=../lib/session-id.sh
. "$LIB"

mkdir -p "$TMP/workspace/sessions"

echo "[1] validation accepts ordinary ids and rejects path-shaped ones"
for good in abc sess-1 08f64a43-b69b-4105-90bd-1ff2fd989f85 run.2026_08 A1; do
  session_id_is_valid "$good" || fail "should accept '$good'"
done
for bad in "" "." ".." "../escape" "a/b" 'a b' 'a$b' 'a;b' '/abs' 'a\b'; do
  if session_id_is_valid "$bad"; then
    fail "should reject '$bad'"
  fi
done

echo "[2] no env and no .current resolves to empty"
assert_eq "$(session_id_resolve "$TMP")" "" "empty resolution"

echo "[3] .current is used when the environment is silent"
printf 'from-current\n' > "$TMP/workspace/sessions/.current"
assert_eq "$(session_id_resolve "$TMP")" "from-current" ".current fallback"

echo "[4] every supported env var beats .current"
for var in HQ_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID \
           CODEX_SESSION_ID CODEX_THREAD_ID GROK_SESSION_ID HQ_FLEET_SESSION_ID; do
  got="$(env "$var=from-$var" bash -c '. "$1"; session_id_resolve "$2"' _ "$LIB" "$TMP")"
  assert_eq "$got" "from-$var" "$var must beat .current"
done

echo "[5] precedence runs HQ_SESSION_ID -> Claude -> Codex -> Grok, first wins"
got="$(env HQ_SESSION_ID=a CLAUDE_CODE_SESSION_ID=b CLAUDE_SESSION_ID=c \
        CODEX_SESSION_ID=d CODEX_THREAD_ID=e GROK_SESSION_ID=g \
        bash -c '. "$1"; session_id_resolve "$2"' _ "$LIB" "$TMP")"
assert_eq "$got" "a" "HQ_SESSION_ID outranks all"
got="$(env CLAUDE_CODE_SESSION_ID=b CLAUDE_SESSION_ID=c CODEX_SESSION_ID=d \
        bash -c '. "$1"; session_id_resolve "$2"' _ "$LIB" "$TMP")"
assert_eq "$got" "b" "CLAUDE_CODE_SESSION_ID outranks CLAUDE_SESSION_ID and Codex"
got="$(env CLAUDE_SESSION_ID=c CODEX_SESSION_ID=d CODEX_THREAD_ID=e \
        bash -c '. "$1"; session_id_resolve "$2"' _ "$LIB" "$TMP")"
assert_eq "$got" "c" "CLAUDE_SESSION_ID outranks Codex"
got="$(env CODEX_SESSION_ID=d CODEX_THREAD_ID=e GROK_SESSION_ID=g \
        bash -c '. "$1"; session_id_resolve "$2"' _ "$LIB" "$TMP")"
assert_eq "$got" "d" "CODEX_SESSION_ID outranks CODEX_THREAD_ID and Grok"
got="$(env CODEX_THREAD_ID=e GROK_SESSION_ID=g \
        bash -c '. "$1"; session_id_resolve "$2"' _ "$LIB" "$TMP")"
assert_eq "$got" "e" "CODEX_THREAD_ID outranks Grok"
got="$(env GROK_SESSION_ID=g \
        bash -c '. "$1"; session_id_resolve "$2"' _ "$LIB" "$TMP")"
assert_eq "$got" "g" "GROK_SESSION_ID beats .current"

echo "[6] a malformed or empty env value is skipped, not fatal"
got="$(env HQ_SESSION_ID=../escape CLAUDE_CODE_SESSION_ID=good-one \
        bash -c '. "$1"; session_id_resolve "$2"' _ "$LIB" "$TMP")"
assert_eq "$got" "good-one" "malformed high-precedence value falls through"
got="$(env HQ_SESSION_ID= CLAUDE_CODE_SESSION_ID=good-one \
        bash -c '. "$1"; session_id_resolve "$2"' _ "$LIB" "$TMP")"
assert_eq "$got" "good-one" "empty high-precedence value falls through"
got="$(env HQ_SESSION_ID=../escape \
        bash -c '. "$1"; session_id_resolve "$2"' _ "$LIB" "$TMP")"
assert_eq "$got" "from-current" "malformed env falls all the way to .current"

echo "[7] surrounding whitespace is tolerated in both sources"
got="$(env CLAUDE_CODE_SESSION_ID='  padded-id  ' \
        bash -c '. "$1"; session_id_resolve "$2"' _ "$LIB" "$TMP")"
assert_eq "$got" "padded-id" "env value is trimmed"
printf '  padded-current  \n' > "$TMP/workspace/sessions/.current"
assert_eq "$(session_id_resolve "$TMP")" "padded-current" ".current value is trimmed"

echo "[8] a malformed .current yields empty rather than a traversal"
printf '../escape\n' > "$TMP/workspace/sessions/.current"
assert_eq "$(session_id_resolve "$TMP")" "" "malformed .current rejected"

echo "[9] a missing root is not fatal"
assert_eq "$(session_id_resolve "$TMP/nope")" "" "missing root resolves empty"
assert_eq "$(session_id_resolve "")" "" "empty root resolves empty"

echo "[10] HQ_FLEET_SESSION_ID (HQ Fleet runtime scheduled jobs) is a source"
printf 'from-current\n' > "$TMP/workspace/sessions/.current"
got="$(env HQ_FLEET_SESSION_ID=fleet-job-1 \
        bash -c '. "$1"; session_id_resolve "$2"' _ "$LIB" "$TMP")"
assert_eq "$got" "fleet-job-1" "HQ_FLEET_SESSION_ID alone beats .current"
got="$(env HQ_SESSION_ID=a CLAUDE_CODE_SESSION_ID=b GROK_SESSION_ID=g HQ_FLEET_SESSION_ID=fleet-job-1 \
        bash -c '. "$1"; session_id_resolve "$2"' _ "$LIB" "$TMP")"
assert_eq "$got" "a" "explicit and runtime ids outrank the fleet id"
got="$(env GROK_SESSION_ID=g HQ_FLEET_SESSION_ID=fleet-job-1 \
        bash -c '. "$1"; session_id_resolve "$2"' _ "$LIB" "$TMP")"
assert_eq "$got" "g" "runtime ids outrank the fleet id"
got="$(env HQ_FLEET_SESSION_ID=../escape \
        bash -c '. "$1"; session_id_resolve "$2"' _ "$LIB" "$TMP")"
assert_eq "$got" "from-current" "malformed fleet id is rejected"
got="$(env HQ_FLEET_SESSION_ID='  fleet-pad  ' \
        bash -c '. "$1"; session_id_resolve "$2"' _ "$LIB" "$TMP")"
assert_eq "$got" "fleet-pad" "fleet id is trimmed"

echo "[11] hq-session.sh binds a company with only HQ_FLEET_SESSION_ID set"
SRC_SCRIPTS="$(cd "$(dirname "$LIB")/.." && pwd)"
FR="$TMP/fleetroot"
mkdir -p "$FR/core/scripts/lib" "$FR/.codex/hooks" "$FR/workspace/sessions" \
         "$FR/companies/indigo" "$FR/home"
cp "$SRC_SCRIPTS/hq-session.sh" "$FR/core/scripts/hq-session.sh"
cp "$SRC_SCRIPTS/lib/session-scope-capability.sh" "$SRC_SCRIPTS/lib/session-id.sh" "$FR/core/scripts/lib/"
cp "$SRC_SCRIPTS/hqd-hook-flag-cache-lib.sh" "$FR/core/scripts/"
cp "$SRC_SCRIPTS/../../.codex/hooks/codex-explicit-path-flag.cjs" "$FR/.codex/hooks/"
chmod +x "$FR/core/scripts/hq-session.sh"
fleet_hs() {
  env -u HQ_ROOT -u CLAUDE_PROJECT_DIR HOME="$FR/home" HQ_HQ_SESSION_NO_CLI=1 \
      HQ_FLEET_SESSION_ID=fleet-job-1 "$FR/core/scripts/hq-session.sh" "$@"
}
fleet_hs set company_slug indigo >/dev/null 2>"$TMP/fleet.err" \
  || fail "set company_slug failed with only HQ_FLEET_SESSION_ID: $(cat "$TMP/fleet.err")"
assert_eq "$(fleet_hs get company_slug)" "indigo" "company bound to the fleet session"
[ -d "$FR/workspace/sessions/fleet-job-1" ] || fail "session record not keyed by fleet id"

echo "[12] Cursor: shared CURSOR_TRACE_ID is never an identity; the write error names the Cursor fix"
# Cursor exports CURSOR_AGENT=1 and a per-window CURSOR_TRACE_ID that every chat
# in the window shares, and no conversation id. Resolving either would bind two
# concurrent chats to one session record.
printf 'from-current\n' > "$TMP/workspace/sessions/.current"
got="$(env -u CURSOR_AGENT -u CURSOR_TRACE_ID CURSOR_AGENT=1 CURSOR_TRACE_ID=trace-shared \
        bash -c '. "$1"; session_id_from_env' _ "$LIB")"
assert_eq "$got" "" "Cursor marker variables are not a session id"
got="$(env CURSOR_AGENT=1 CURSOR_TRACE_ID=trace-shared \
        bash -c '. "$1"; session_id_resolve "$2"' _ "$LIB" "$TMP")"
assert_eq "$got" "from-current" "Cursor markers do not outrank .current"
cursor_hs() {
  env -u HQ_ROOT -u CLAUDE_PROJECT_DIR -u HQ_FLEET_SESSION_ID -u CURSOR_AGENT -u CURSOR_TRACE_ID \
      HOME="$FR/home" HQ_HQ_SESSION_NO_CLI=1 "$@"
}
if cursor_hs CURSOR_AGENT=1 CURSOR_TRACE_ID=trace-shared \
     "$FR/core/scripts/hq-session.sh" set company_slug indigo >/dev/null 2>"$TMP/cursor.err"; then
  fail "Cursor write with no session id must fail"
fi
grep -q 'Cursor does not export a session id' "$TMP/cursor.err" \
  || fail "Cursor write error lacks the Cursor hint: $(cat "$TMP/cursor.err")"
grep -q 'export HQ_SESSION_ID=<id>' "$TMP/cursor.err" \
  || fail "Cursor hint does not name HQ_SESSION_ID: $(cat "$TMP/cursor.err")"
[ ! -e "$FR/workspace/sessions/trace-shared" ] || fail "CURSOR_TRACE_ID was used as a session id"
if cursor_hs CURSOR_TRACE_ID=trace-shared \
     "$FR/core/scripts/hq-session.sh" set company_slug indigo >/dev/null 2>"$TMP/cursor-term.err"; then
  fail "Cursor terminal write with no session id must fail"
fi
grep -q 'Cursor does not export a session id' "$TMP/cursor-term.err" \
  || fail "Cursor terminal write error lacks the Cursor hint"
if cursor_hs "$FR/core/scripts/hq-session.sh" set company_slug indigo >/dev/null 2>"$TMP/plain.err"; then
  fail "write with no session id must fail outside Cursor"
fi
if grep -q 'Cursor' "$TMP/plain.err"; then
  fail "Cursor hint printed outside Cursor: $(cat "$TMP/plain.err")"
fi
cursor_hs CURSOR_AGENT=1 CURSOR_TRACE_ID=trace-shared HQ_SESSION_ID=cursor-chat-1 \
    "$FR/core/scripts/hq-session.sh" set company_slug indigo >/dev/null 2>"$TMP/cursor-ok.err" \
  || fail "Cursor write with HQ_SESSION_ID failed: $(cat "$TMP/cursor-ok.err")"
[ -d "$FR/workspace/sessions/cursor-chat-1" ] || fail "Cursor session record not keyed by HQ_SESSION_ID"
cursor_hs CURSOR_AGENT=1 "$FR/core/scripts/hq-session.sh" --session-id cursor-chat-2 \
    set company_slug indigo >/dev/null 2>"$TMP/cursor-flag.err" \
  || fail "Cursor write with --session-id failed: $(cat "$TMP/cursor-flag.err")"
[ -d "$FR/workspace/sessions/cursor-chat-2" ] || fail "Cursor session record not keyed by --session-id"

echo "PASS: session-id.test.sh"
