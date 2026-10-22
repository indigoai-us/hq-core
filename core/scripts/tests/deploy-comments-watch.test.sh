#!/usr/bin/env bash
# Regression: comments-watch.sh seeds without replaying the backlog, reports each
# new comment once, survives restarts, reports outages and a disabled thread, and
# never prints the bearer token. The real deploy-api-request.sh runs; only curl
# is stubbed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SRC="$ROOT/.claude/skills/deploy/scripts/comments-watch.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }
[ -x "$SRC" ] || fail "comments-watch.sh is missing or not executable"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TOKEN='token-secret-should-not-leak'
mkdir -p "$TMP/bin"

cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
body_file=""; url=""; method=GET; headers=""
for ((i = 1; i <= $#; i++)); do
  arg="${!i}"
  case "$arg" in
    -o) next=$((i + 1)); body_file="${!next}" ;;
    -X) next=$((i + 1)); method="${!next}" ;;
    -H) next=$((i + 1)); headers="$headers|${!next}" ;;
    http://*|https://*) url="$arg" ;;
  esac
done
printf '%s %s %s\n' "$method" "$url" "$headers" >> "$MOCK_DIR/calls"
cp "$MOCK_DIR/response" "$body_file"
cat "$MOCK_DIR/status"
STUB
chmod +x "$TMP/bin/curl"

comment() { # id createdAt body
  printf '{"id":"%s","body":"%s","author":{"email":"viewer@example.com","name":"Viewer"},"anchor":{"mode":"text","quote":"intro"},"status":"open","deployId":"dep-1","createdAt":"%s"}' "$1" "$3" "$2"
}
respond() { # status json
  printf '%s' "$1" > "$TMP/status"
  printf '%s' "$2" > "$TMP/response"
}
watch_once() {
  PATH="$TMP/bin:$PATH" MOCK_DIR="$TMP" HQ_DEPLOY_API=http://api.test HQ_DEPLOY_JWT="$TOKEN" \
    "$SRC" watch --app app-1 --org acme --cursor-file "$TMP/state/app-1.cursor" --label "Launch page" --once 2>"$TMP/stderr"
}

C1="$(comment c1 2026-10-01T00:00:00Z first)"
C2="$(comment c2 2026-10-02T00:00:00Z second)"
C3="$(comment c3 2026-10-03T00:00:00Z third)"

# First run seeds the existing backlog and reports none of it.
respond 200 "{\"commentsEnabled\":true,\"comments\":[$C1,$C2]}"
out="$(watch_once)" || fail "seeding run failed: $out"
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "seeding run printed more than the armed line: $out"
printf '%s' "$out" | jq -e '.type == "armed" and .app == "Launch page" and .seeded == 2' >/dev/null || fail "armed line wrong: $out"
grep -Fq 'GET http://api.test/api/apps/app-1/manage/comments' "$TMP/calls" || fail "did not poll the owner comments route"
grep -Fq 'X-Org-Slug: acme' "$TMP/calls" || fail "did not send the org header"
pass "first run seeds the backlog without replaying it"

# A new comment is reported once with author, body, anchor and deploy.
respond 200 "{\"commentsEnabled\":true,\"comments\":[$C1,$C2,$C3]}"
out="$(watch_once)" || fail "second run failed: $out"
printf '%s\n' "$out" | jq -se 'map(select(.type == "comment")) | length == 1 and .[0].id == "c3"
  and .[0].body == "third" and .[0].author.name == "Viewer" and .[0].author.email == "viewer@example.com"
  and .[0].anchor.quote == "intro" and .[0].deployId == "dep-1" and .[0].app == "Launch page"' >/dev/null \
  || fail "new comment not reported correctly: $out"
pass "a new comment is reported with its details"

# A restart does not repeat it.
out="$(watch_once)" || fail "third run failed: $out"
printf '%s\n' "$out" | jq -se 'map(select(.type == "comment")) | length == 0' >/dev/null || fail "restart replayed a comment: $out"
pass "a restart does not repeat reported comments"

# Comments turned off is reported, and nothing is replayed.
respond 403 '{"error":{"code":"COMMENTS_DISABLED","message":"off"},"requestId":"req-1"}'
out="$(watch_once)" || fail "disabled run failed: $out"
printf '%s\n' "$out" | jq -se 'map(.type) | index("comments_disabled") != null' >/dev/null || fail "comments_disabled not reported: $out"
respond 200 "{\"commentsEnabled\":false,\"comments\":[$C1,$C2,$C3]}"
out="$(watch_once)" || fail "disabled-flag run failed: $out"
printf '%s\n' "$out" | jq -se '(map(.type) | index("comments_disabled") != null) and (map(select(.type == "comment")) | length == 0)' >/dev/null \
  || fail "commentsEnabled false not reported: $out"
pass "a disabled thread is reported without replay"

# A failing poll is reported and the cursor is untouched.
before="$(cat "$TMP/state/app-1.cursor")"
respond 500 '{"error":{"code":"INTERNAL","message":"boom"},"requestId":"req-2"}'
out="$(watch_once)" || fail "failing run exited non-zero: $out"
printf '%s\n' "$out" | jq -se 'map(.type) | index("poll_failing") != null' >/dev/null || fail "poll_failing not reported: $out"
[ "$(cat "$TMP/state/app-1.cursor")" = "$before" ] || fail "cursor changed on a failed poll"
pass "a failed poll is reported and keeps the cursor"

# An unwritable cursor holds the comment back so it is reported later.
respond 200 "{\"commentsEnabled\":true,\"comments\":[$C1,$C2,$C3,$(comment c4 2026-10-04T00:00:00Z fourth)]}"
chmod 555 "$TMP/state"
set +e; out="$(watch_once)"; code=$?; set -e
chmod 755 "$TMP/state"
[ "$code" -ne 0 ] || fail "cursor write failure exited zero"
printf '%s\n' "$out" | jq -se '(map(.type) | index("cursor_write_failed") != null) and (map(select(.type == "comment")) | length == 0)' >/dev/null \
  || fail "cursor write failure not handled: $out"
out="$(watch_once)" || fail "recovery run failed: $out"
printf '%s\n' "$out" | jq -se 'map(select(.type == "comment")) | length == 1 and .[0].id == "c4"' >/dev/null || fail "held-back comment not reported: $out"
pass "a cursor write failure holds the comment for the next poll"

# Arguments are validated and the token never reaches output.
set +e
bad="$("$SRC" watch --app app-1 --org acme --cursor-file "$TMP/x" --interval 10 2>&1)"; code=$?
set -e
[ "$code" = 64 ] || fail "interval under 30s exited $code: $bad"
printf "%s" "$bad" | grep >/dev/null -F "at least 30" || fail "interval under 30s was accepted: $bad"
! grep -rFq "$TOKEN" "$TMP/stderr" "$TMP/state" || fail "token leaked"
pass "short intervals are rejected and the token never leaks"
