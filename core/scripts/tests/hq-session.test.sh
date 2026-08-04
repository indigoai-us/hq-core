#!/usr/bin/env bash
# hq-core: public
# Regression tests for core/scripts/hq-session.sh
#
# Guards two bugs:
#
# 1. REPO_ROOT depth: the script lives in core/scripts/, so it must walk up TWO
#    levels ("../..") to reach the HQ root. A regression to one level ("..")
#    makes SESSIONS_DIR resolve to <root>/core/workspace/sessions, so .current
#    is never found and `set` dies with "no current session".
#
# 2. Wrong-session binds: "current session" must come from this process's own
#    session environment, with workspace/sessions/.current only as a fallback.
#    .current is a single global pointer rewritten by every hook event, so with
#    concurrent sessions it can name a different session — and the scope guard
#    reads the session id from the hook payload, not from .current. Resolving
#    through .current made `hq-session.sh set company_slug <co>` report success
#    while writing to a foreign session's meta.yaml, leaving the calling session
#    unbound and still blocked.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hq-session.sh"
LIB_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# This test runs inside a real session, which exports a session id. Clear the
# whole precedence list so the .current-fallback cases below exercise the
# fallback rather than the ambient session.
unset HQ_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID \
      CODEX_SESSION_ID CODEX_THREAD_ID || true

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"
}

# Build a minimal HQ-shaped layout so the script's BASH_SOURCE-relative
# REPO_ROOT computation has something real to resolve against.
mkdir -p "$TMP/core/scripts/lib" "$TMP/workspace/sessions"
cp "$SRC" "$TMP/core/scripts/hq-session.sh"
cp "$LIB_SRC/session-scope-capability.sh" "$TMP/core/scripts/lib/"
cp "$LIB_SRC/session-id.sh" "$TMP/core/scripts/lib/"
chmod +x "$TMP/core/scripts/hq-session.sh"
HS="$TMP/core/scripts/hq-session.sh"

# 1. No .current yet -> `current` prints empty, exits 0.
out="$("$HS" current)"
assert_eq "$out" "" "current with no session"

# 2. Seed a current session.
printf 'sess-1\n' > "$TMP/workspace/sessions/.current"
mkdir -p "$TMP/workspace/sessions/sess-1"

assert_eq "$("$HS" current)" "sess-1" "current id"

# 3. `path` must resolve under <root>/workspace/sessions, NOT <root>/core/...
#    This is the direct guard against the REPO_ROOT depth regression.
path_out="$("$HS" path)"
assert_eq "$path_out" "$TMP/workspace/sessions/sess-1/meta.yaml" "meta path"
case "$path_out" in
  "$TMP/core/"*) fail "REPO_ROOT resolved one level too shallow: $path_out" ;;
esac

# 4. set/get roundtrip (would error 'no current session' under the bug).
"$HS" set company acme
assert_eq "$("$HS" get company)" "acme" "get after set"

# 5. set replaces in place rather than duplicating.
"$HS" set company beta
assert_eq "$("$HS" get company)" "beta" "get after overwrite"
count="$(grep -c '^company:' "$path_out")"
assert_eq "$count" "1" "company key not duplicated"

# 6. set company_slug mints scope-capability.json for the current session.
"$HS" set company_slug indigo
cap="$TMP/workspace/sessions/sess-1/scope-capability.json"
[ -f "$cap" ] || fail "scope-capability.json not minted"
assert_eq "$(jq -r '.company_slug' "$cap")" "indigo" "capability company_slug"
assert_eq "$(jq -r '.session_id' "$cap")" "sess-1" "capability session_id"

# ── Wrong-session bind regression ──────────────────────────────────────────────
# .current still says sess-1 (another session fired the most recent hook), but
# THIS process belongs to sess-2. Every read and write must follow sess-2.

# 7. The environment wins over .current for `current` and `path`.
assert_eq "$(CLAUDE_CODE_SESSION_ID=sess-2 "$HS" current)" "sess-2" \
  "env session id must beat .current"
assert_eq "$(CLAUDE_CODE_SESSION_ID=sess-2 "$HS" path)" \
  "$TMP/workspace/sessions/sess-2/meta.yaml" "env session meta path"

# 8. `set company_slug` binds THIS session, bootstrapping its record if the hook
#    has not created one yet — and leaves the .current session untouched.
CLAUDE_CODE_SESSION_ID=sess-2 "$HS" set company_slug otherco >/dev/null
cap2="$TMP/workspace/sessions/sess-2/scope-capability.json"
[ -f "$cap2" ] || fail "scope-capability.json not minted for the env session"
assert_eq "$(jq -r '.company_slug' "$cap2")" "otherco" "env session capability slug"
assert_eq "$(jq -r '.session_id' "$cap2")" "sess-2" "env session capability id"
assert_eq "$(CLAUDE_CODE_SESSION_ID=sess-2 "$HS" get company_slug)" "otherco" \
  "env session get company_slug"
assert_eq "$(grep -c '^session_id: sess-2$' "$TMP/workspace/sessions/sess-2/meta.yaml")" "1" \
  "bootstrapped meta.yaml carries its own session_id"

# The .current session must NOT have been rewritten by the sess-2 bind.
assert_eq "$("$HS" get company_slug)" "indigo" ".current session left untouched"
assert_eq "$(jq -r '.company_slug' "$cap")" "indigo" ".current capability left untouched"

# 9. Precedence: HQ_SESSION_ID outranks the host-provided id.
assert_eq "$(HQ_SESSION_ID=sess-3 CLAUDE_CODE_SESSION_ID=sess-2 "$HS" current)" "sess-3" \
  "HQ_SESSION_ID precedence"

# 10. --session-id overrides everything, including the environment.
assert_eq "$(CLAUDE_CODE_SESSION_ID=sess-2 "$HS" --session-id sess-4 current)" "sess-4" \
  "--session-id overrides env"
assert_eq "$(CLAUDE_CODE_SESSION_ID=sess-2 "$HS" --session-id=sess-4 current)" "sess-4" \
  "--session-id= form"

# 11. A malformed session id is never turned into a path segment.
rc=0
"$HS" --session-id '../escape' current >/dev/null 2>&1 || rc=$?
[ "$rc" = "1" ] || fail "expected exit 1 for traversal in --session-id, got $rc"

# A malformed env value is skipped, not fatal — the next source still resolves.
assert_eq "$(CLAUDE_CODE_SESSION_ID='../escape' "$HS" current)" "sess-1" \
  "malformed env session id falls through to .current"

# 12. A malformed .current with no session env yields no session, and `set`
#     fails loudly rather than writing somewhere unexpected.
printf '../escape\n' > "$TMP/workspace/sessions/.current"
assert_eq "$("$HS" current)" "" "malformed .current resolves to empty"
rc=0
"$HS" set company_slug indigo >/dev/null 2>&1 || rc=$?
[ "$rc" = "1" ] || fail "expected exit 1 for set with no resolvable session, got $rc"
[ ! -e "$TMP/workspace/sessions/../escape" ] || fail "traversal target was created"

echo "PASS: hq-session.sh ($(basename "$HS"))"
