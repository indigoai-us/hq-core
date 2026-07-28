#!/usr/bin/env bash
# hq-core: public
# Skill-name extraction is LINE-BASED, so a multi-line /slash message does not
# resolve. Pins that contract explicitly.
#
# Why this exists: session_skill_dispatch extracts the skill token with
#   sed -E 's|^/([A-Za-z0-9_./-]+).*|\1|'
# sed applies the expression to EVERY line. On a multi-line message it rewrites
# line 1 and passes the remaining lines through untouched, so the extracted
# "name" is the whole blob rather than the skill token — the catalog lookup
# misses and the caller gets disposition=clarify.
#
# That is easy to trip over from the producer side: an automated caller that
# builds a nicely formatted multi-line "/learn …" prompt gets a silent no-op,
# not an error. (This is exactly how the idle-reflection sweep in
# personal/scripts/hq-agent-reflect.sh shipped broken the first time.)
#
# These tests do NOT assert that multi-line SHOULD fail — they pin the behaviour
# as it is, so a producer can rely on it and so a future change to the
# extraction is a deliberate, visible decision rather than a silent one.

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "  ok: $1"; }

# shellcheck source=/dev/null
. "$SRC_ROOT/core/scripts/lib/session-skill-dispatch.sh"

RUN_DIR="$TMP/run"
mkdir -p "$RUN_DIR"
: > "$RUN_DIR/system.txt"

SKILL_DIR="$TMP/skills/learn"
mkdir -p "$SKILL_DIR"
printf -- '---\nname: learn\ndescription: capture reusable rules\n---\n\nBody.\n' \
  > "$SKILL_DIR/SKILL.md"

export SESSION_SKILL_CATALOG_TSV="learn	$SKILL_DIR/SKILL.md	core"

# ── 1. single-line /learn resolves ──────────────────────────────────────────
: > "$RUN_DIR/system.txt"
session_skill_dispatch "$RUN_DIR" "/learn capture what happened in this conversation"
[ "$SESSION_SKILL_NAME" = "learn" ] \
  || fail "single-line name='$SESSION_SKILL_NAME' want 'learn'"
[ "$SESSION_SKILL_DISPATCHED" = "1" ] \
  || fail "single-line did not dispatch (clarify=$SESSION_SKILL_CLARIFY)"
pass "single-line /learn dispatches"

# ── 2. bare /learn resolves ─────────────────────────────────────────────────
: > "$RUN_DIR/system.txt"
session_skill_dispatch "$RUN_DIR" "/learn"
[ "$SESSION_SKILL_DISPATCHED" = "1" ] || fail "bare /learn did not dispatch"
pass "bare /learn dispatches"

# ── 3. MULTI-LINE /learn does NOT resolve ──────────────────────────────────
# The whole point of the pin. A producer that formats its prompt across lines
# does NOT get its skill.
#
# On some platforms it is worse than a clean miss. The extracted "name" still
# carries the embedded newlines, and the clarify path feeds it to
# session_levenshtein as `awk -v s="<blob>"`. BSD awk (macOS) rejects a literal
# newline in a -v assignment with `awk: newline in string`; under
# hq-agent-session.sh's `set -euo pipefail` that aborts the caller mid-function
# rather than degrading to a clarify response. mawk and gawk — mawk is what
# ubuntu-latest ships — generally accept it and carry on.
#
# That divergence is deliberately NOT asserted: it is a property of whichever
# awk is installed, not of this code, and pinning it would fail CI for a reason
# unrelated to the behaviour under test. Recorded here so the macOS-only abort
# is not mistaken for a fresh bug. What IS asserted below is the part that holds
# on every platform, because it is pure sed and string comparison: a multi-line
# /slash message never resolves to a skill.
: > "$RUN_DIR/system.txt"
MULTILINE='/learn

Capture what happened in this conversation.'
set +e
session_skill_dispatch "$RUN_DIR" "$MULTILINE" 2>/dev/null
set -e
[ "${SESSION_SKILL_DISPATCHED:-0}" != "1" ] \
  || fail "multi-line unexpectedly dispatched — extraction changed, update producers"
case "${SESSION_SKILL_NAME:-}" in
  learn) fail "multi-line resolved cleanly to 'learn' — behaviour changed" ;;
esac
pass "multi-line /slash never dispatches the skill (platform-independent)"

# ── 4. leading whitespace is still tolerated on a single line ──────────────
: > "$RUN_DIR/system.txt"
session_skill_dispatch "$RUN_DIR" "   /learn with leading spaces"
[ "$SESSION_SKILL_DISPATCHED" = "1" ] || fail "leading-whitespace single line did not dispatch"
pass "leading whitespace tolerated on a single line"

echo
echo "PASS: hq-agent-session-skill-dispatch-multiline.test.sh"
