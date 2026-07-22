#!/usr/bin/env bash
# hq-core: public
# US-408: session-resume store — write/read mode 600, cross-provider discard,
# TTL expiry at 31 days, malformed-record path.

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

CONV="agt_test#slack:C-resume-1"
PROVIDER="claude"
SID="session-abc-123-xyz"

# ── 1. write / read round-trip + mode 600 + sha256 filename ─────────────────
session_resume_write "$CONV" "$PROVIDER" "$SID" || fail "write failed"
PATH_R="$(session_resume_path "$CONV")"
[ -f "$PATH_R" ] || fail "missing resume file: $PATH_R"
HASH="$(session_resume_sha256 "$CONV")"
echo "$PATH_R" | grep -q "/${HASH}.json" || fail "path not sha256-named: $PATH_R"
MODE="$(stat -f %Lp "$PATH_R" 2>/dev/null || stat -c %a "$PATH_R")"
[ "$MODE" = "600" ] || fail "mode not 600: $MODE"
GOT="$(session_resume_read "$CONV" "$PROVIDER")"
[ "$GOT" = "$SID" ] || fail "read back got='$GOT' want='$SID'"
BODY="$(cat "$PATH_R")"
echo "$BODY" | jq -e --arg p "$PROVIDER" --arg s "$SID" \
  '.provider == $p and .sessionId == $s and (.updatedAt | type == "string" and length > 0)' \
  >/dev/null || fail "body missing fields: $BODY"
pass "write/read round-trip mode 600"

# ── 2. cross-provider discard ───────────────────────────────────────────────
# Record is for claude; read as codex → no sid + file deleted
GOT="$(session_resume_read "$CONV" "codex")"
[ -z "$GOT" ] || fail "cross-provider returned sid: $GOT"
[ ! -f "$PATH_R" ] || fail "cross-provider did not discard record"
pass "cross-provider discard"

# ── 3. TTL expiry at 31 days ────────────────────────────────────────────────
session_resume_write "$CONV" "$PROVIDER" "$SID" || fail "rewrite for ttl"
# Overwrite updatedAt to 31 days ago
OLD_EPOCH=$(( $(date +%s) - 31 * 86400 ))
if date -u -d "@${OLD_EPOCH}" +"%Y-%m-%dT%H:%M:%SZ" >/dev/null 2>&1; then
  OLD_ISO="$(date -u -d "@${OLD_EPOCH}" +"%Y-%m-%dT%H:%M:%SZ")"
else
  OLD_ISO="$(date -u -r "$OLD_EPOCH" +"%Y-%m-%dT%H:%M:%SZ")"
fi
jq --arg u "$OLD_ISO" '.updatedAt = $u' "$PATH_R" > "$PATH_R.tmp" && mv "$PATH_R.tmp" "$PATH_R"
chmod 600 "$PATH_R"
GOT="$(session_resume_read "$CONV" "$PROVIDER")"
[ -z "$GOT" ] || fail "expired record returned sid: $GOT"
[ ! -f "$PATH_R" ] || fail "expired record not deleted"
pass "TTL 31-day expiry"

# ── 4. malformed JSON → exit 0, no sid, delete ──────────────────────────────
mkdir -p "$(dirname "$PATH_R")"
printf 'NOT-JSON{' > "$PATH_R"
chmod 600 "$PATH_R"
set +e
GOT="$(session_resume_read "$CONV" "$PROVIDER")"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "malformed read exit $RC (want 0)"
[ -z "$GOT" ] || fail "malformed returned sid: $GOT"
[ ! -f "$PATH_R" ] || fail "malformed record not deleted"
pass "malformed record"

# ── 5. missing required field → delete ──────────────────────────────────────
jq -nc '{provider:"claude", updatedAt:"2026-07-22T00:00:00Z"}' > "$PATH_R"
chmod 600 "$PATH_R"
GOT="$(session_resume_read "$CONV" "$PROVIDER")"
[ -z "$GOT" ] || fail "missing sessionId returned: $GOT"
[ ! -f "$PATH_R" ] || fail "incomplete record not deleted"
pass "missing required field"

# ── 6. fresh record within TTL still works after expiry test ────────────────
session_resume_write "$CONV" "$PROVIDER" "sid-fresh" || fail "fresh write"
GOT="$(session_resume_read "$CONV" "$PROVIDER")"
[ "$GOT" = "sid-fresh" ] || fail "fresh read got=$GOT"
pass "fresh after cleanup"

echo "PASS: hq-agent-session-resume.test.sh"
