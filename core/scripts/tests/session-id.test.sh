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
      CODEX_SESSION_ID CODEX_THREAD_ID || true

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
           CODEX_SESSION_ID CODEX_THREAD_ID; do
  got="$(env "$var=from-$var" bash -c '. "$1"; session_id_resolve "$2"' _ "$LIB" "$TMP")"
  assert_eq "$got" "from-$var" "$var must beat .current"
done

echo "[5] precedence runs HQ_SESSION_ID -> Claude -> Codex, first wins"
got="$(env HQ_SESSION_ID=a CLAUDE_CODE_SESSION_ID=b CLAUDE_SESSION_ID=c \
        CODEX_SESSION_ID=d CODEX_THREAD_ID=e \
        bash -c '. "$1"; session_id_resolve "$2"' _ "$LIB" "$TMP")"
assert_eq "$got" "a" "HQ_SESSION_ID outranks all"
got="$(env CLAUDE_CODE_SESSION_ID=b CLAUDE_SESSION_ID=c CODEX_SESSION_ID=d \
        bash -c '. "$1"; session_id_resolve "$2"' _ "$LIB" "$TMP")"
assert_eq "$got" "b" "CLAUDE_CODE_SESSION_ID outranks CLAUDE_SESSION_ID and Codex"
got="$(env CLAUDE_SESSION_ID=c CODEX_SESSION_ID=d CODEX_THREAD_ID=e \
        bash -c '. "$1"; session_id_resolve "$2"' _ "$LIB" "$TMP")"
assert_eq "$got" "c" "CLAUDE_SESSION_ID outranks Codex"
got="$(env CODEX_SESSION_ID=d CODEX_THREAD_ID=e \
        bash -c '. "$1"; session_id_resolve "$2"' _ "$LIB" "$TMP")"
assert_eq "$got" "d" "CODEX_SESSION_ID outranks CODEX_THREAD_ID"

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

echo "PASS: session-id.test.sh"
