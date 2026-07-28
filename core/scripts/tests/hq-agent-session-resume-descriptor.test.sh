#!/usr/bin/env bash
# hq-core: public
# agent-self-learning: the conversation descriptor carried on a resume record.
#
# The record is keyed by sha256(convKey), so on its own it is a one-way hash and
# nothing can start FROM the records and get back to a conversation. The
# descriptor adds just enough routing for the idle-reflection sweep to re-enter
# one. These tests pin the two properties that matter: the descriptor can never
# shadow the canonical resume fields, and adding it cannot break a resume.

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "  ok: $1"; }

export HOME="$TMP/home"
mkdir -p "$HOME"

# shellcheck source=/dev/null
. "$SRC_ROOT/core/scripts/lib/session-resume.sh"

CONV="agt_desc#slack:C-desc-1:1712345.678"
PROVIDER="claude"
SID="sid-descriptor-1"
AGENT="agt_desc"
CO="indigo"
CHAN="slack"

# ── 1. descriptor is persisted alongside the canonical fields ───────────────
DESC="$(session_resume_descriptor "$CONV" "$AGENT" "$CO" "$CHAN")"
echo "$DESC" | jq -e 'type == "object"' >/dev/null || fail "descriptor not an object: $DESC"
session_resume_write "$CONV" "$PROVIDER" "$SID" "$DESC" || fail "write with descriptor failed"
P="$(session_resume_path "$CONV")"
BODY="$(cat "$P")"
echo "$BODY" | jq -e \
  --arg c "$CONV" --arg a "$AGENT" --arg co "$CO" --arg ch "$CHAN" \
  --arg p "$PROVIDER" --arg s "$SID" \
  '.convKey == $c and .agentUid == $a and .companySlug == $co and .channel == $ch
   and .provider == $p and .sessionId == $s
   and (.updatedAt | type == "string" and length > 0)' \
  >/dev/null || fail "descriptor fields missing: $BODY"
pass "descriptor persisted with canonical fields"

# ── 2. mode is still 600 and the resume still reads ─────────────────────────
# GNU stat first, BSD second — NOT the other way round. GNU's `-f` means
# "filesystem status", so it SUCCEEDS on Linux and prints a filesystem dump
# instead of failing over to `-c`, and the mode assertion then compares against
# that dump. BSD stat has no `-c`, so it errors cleanly and the fallback runs.
MODE="$(stat -c %a "$P" 2>/dev/null || stat -f %Lp "$P" 2>/dev/null)"
[ "$MODE" = "600" ] || fail "mode not 600 with descriptor: $MODE"
GOT="$(session_resume_read "$CONV" "$PROVIDER")"
[ "$GOT" = "$SID" ] || fail "resume broke with descriptor: got='$GOT'"
pass "descriptor does not disturb mode 600 or resume"

# ── 3. a descriptor can NEVER shadow the canonical fields ───────────────────
# Canonical fields are merged OVER the descriptor, so a hostile or stale
# descriptor cannot redirect a resume to another session or provider.
HOSTILE="$(jq -nc '{provider:"grok", sessionId:"attacker-sid", updatedAt:"1999-01-01T00:00:00Z", convKey:"other"}')"
session_resume_write "$CONV" "$PROVIDER" "$SID" "$HOSTILE" || fail "write with hostile descriptor failed"
BODY="$(cat "$P")"
echo "$BODY" | jq -e --arg p "$PROVIDER" --arg s "$SID" \
  '.provider == $p and .sessionId == $s and .updatedAt != "1999-01-01T00:00:00Z"' \
  >/dev/null || fail "descriptor shadowed canonical fields: $BODY"
pass "canonical fields win over descriptor"

# ── 4. malformed descriptor is dropped, never fatal ────────────────────────
# Losing the descriptor costs one skipped reflection. Losing the resume record
# costs a user their conversation history — so a bad descriptor must not fail
# the write.
session_resume_write "$CONV" "$PROVIDER" "sid-malformed" "not-json-at-all" \
  || fail "malformed descriptor made the write fail"
BODY="$(cat "$P")"
echo "$BODY" | jq -e '.sessionId == "sid-malformed"' >/dev/null \
  || fail "record not written with malformed descriptor: $BODY"
echo "$BODY" | jq -e 'has("convKey") | not' >/dev/null \
  || fail "malformed descriptor leaked keys: $BODY"
pass "malformed descriptor dropped, write still succeeds"

# ── 5. a JSON scalar is not an object → also dropped ───────────────────────
session_resume_write "$CONV" "$PROVIDER" "sid-scalar" '"a string"' \
  || fail "scalar descriptor made the write fail"
jq -e '.sessionId == "sid-scalar"' "$P" >/dev/null || fail "scalar descriptor broke write"
pass "non-object JSON descriptor dropped"

# ── 6. backward compatible: the 3-arg call still works ─────────────────────
session_resume_write "$CONV" "$PROVIDER" "sid-legacy" || fail "3-arg write failed"
GOT="$(session_resume_read "$CONV" "$PROVIDER")"
[ "$GOT" = "sid-legacy" ] || fail "3-arg read got='$GOT'"
jq -e 'has("convKey") | not' "$P" >/dev/null || fail "3-arg write invented a descriptor"
pass "3-arg call unchanged (backward compatible)"

# ── 7. empty descriptor fields are omitted, not written as "" ───────────────
DESC="$(session_resume_descriptor "$CONV" "$AGENT" "" "")"
session_resume_write "$CONV" "$PROVIDER" "sid-partial" "$DESC" || fail "partial write failed"
jq -e '(has("companySlug") | not) and (has("channel") | not) and (.convKey | length > 0)' "$P" >/dev/null \
  || fail "empty descriptor fields not omitted: $(cat "$P")"
pass "empty descriptor fields omitted"

echo "PASS: hq-agent-session-resume-descriptor.test.sh"
