#!/usr/bin/env bash
# Length guard for hq-dm-bind.sh post: refuse over-budget posts before any
# network call so nothing partial is ever sent.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/root/core/scripts/lib" "$SANDBOX/bin" "$SANDBOX/home"
cp "$ROOT/core/scripts/hq-dm-bind.sh" "$SANDBOX/root/core/scripts/"
cp "$ROOT/core/scripts/lib/forwarder.sh" "$SANDBOX/root/core/scripts/lib/forwarder.sh"
cp "$ROOT/core/scripts/lib/hq-cli-floor.sh" "$SANDBOX/root/core/scripts/lib/hq-cli-floor.sh"
mkdir -p "$SANDBOX/home/.hq"
printf '{}\n' > "$SANDBOX/home/.hq/config.json"
printf '{}\n' > "$SANDBOX/home/.hq/cognito-tokens.json"

# Stub session helper: fixed session id, channel already bound.
cat > "$SANDBOX/root/core/scripts/hq-session.sh" <<'S'
#!/usr/bin/env bash
case "$1" in current) printf 'sess-test' ;; get) echo '"room"' ;; *) : ;; esac
S
# Stub hq: quiet.
REAL_HQ="$(command -v hq)"
REAL_NODE="$(command -v node)"
export REAL_HQ REAL_NODE
cat > "$SANDBOX/bin/hq" <<'S'
#!/usr/bin/env bash
if [ "${1:-}" = --version ] || [ "${1:-}" = core ]; then exec "$REAL_NODE" "$REAL_HQ" "$@"; fi
if [ "$1" = dm ] && [ "$2" = channel ]; then echo "${CHANNEL_JSON:-[]}"; fi
exit 0
S
chmod +x "$SANDBOX/bin/hq" "$SANDBOX/root/core/scripts/hq-session.sh"
# The native dm-bind (hq-cli >= 5.345.193) reads the roster and posts through
# the notify API with the human session, so serve that API locally. The fake
# records each posted payload in $SENT and answers with an event id.
ROSTER_FILE="$SANDBOX/roster" SENT="$SANDBOX/sent"
# shellcheck source=lib/fake-notify-api.sh
. "$ROOT/core/scripts/tests/lib/fake-notify-api.sh"
trap 'kill "${FAKE_NOTIFY_API_PID:-}" 2>/dev/null || true; rm -rf "$SANDBOX"' EXIT
fake_notify_api_start "$REAL_NODE" "$SANDBOX/home" "$ROSTER_FILE" "$SENT"
export PATH="$SANDBOX/bin:$PATH" HOME="$SANDBOX/home" HQ_ROOT="$SANDBOX/root" SENT
BIND="$SANDBOX/root/core/scripts/hq-dm-bind.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

printf 'Ada Lovelace\tprs_ada\nGrace Hopper\tprs_grace\n' > "$ROSTER_FILE"

# --- PASS: a post within budget sends normally ---
rm -f "$SENT"
bash "$BIND" post --title "Status update" \
  --line "Work is on track" \
  --line "PR is up for review" \
  --next "Merge when green" >/dev/null
[ -e "$SENT" ] || fail "under-budget post must send"
echo "PASS: under-budget post sends normally"

# --- PASS: a post over the total budget (600 chars) refuses and sends nothing ---
# 120-char line; five of them (600 chars of bullets alone) + title + mention pushes well past 600
LONG_LINE="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
rm -f "$SENT"; rc=0
bash "$BIND" post \
  --title "Big update" \
  --line "$LONG_LINE" \
  --line "$LONG_LINE" \
  --line "$LONG_LINE" \
  --line "$LONG_LINE" \
  --line "$LONG_LINE" \
  2>/dev/null || rc=$?
[ "$rc" = 2 ] || fail "over-total-budget post must exit 2 (got $rc)"
[ ! -e "$SENT" ] || fail "over-total-budget post must not call send (SENT exists)"
echo "PASS: post over 600-char total budget refuses and sends nothing"

# --- PASS: a single --line over 140 chars refuses and names that bullet ---
# 141 uppercase A's, deterministic
LONG_BULLET="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
rm -f "$SENT"; rc=0; err=""
err="$(bash "$BIND" post --title "T" --line "$LONG_BULLET" 2>&1 >/dev/null)" || rc=$?
[ "$rc" = 2 ] || fail "over-140-char --line must exit 2 (got $rc)"
[ ! -e "$SENT" ] || fail "over-140-char --line must not send"
echo "$err" | grep >/dev/null 'too long' || fail "refusal must say 'too long': $err"
echo "$err" | grep >/dev/null 'AAAAAAAAAA' || fail "refusal must quote the first 60 chars of the offending bullet: $err"
echo "PASS: --line over 140 chars refuses and quotes the bullet"

# --- PASS: a single --next over 140 chars refuses ---
LONG_NEXT="NNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNN"
rm -f "$SENT"; rc=0
bash "$BIND" post --title "T" --next "$LONG_NEXT" 2>/dev/null || rc=$?
[ "$rc" = 2 ] || fail "over-140-char --next must exit 2 (got $rc)"
[ ! -e "$SENT" ] || fail "over-140-char --next must not send"
echo "PASS: --next over 140 chars refuses"

# --- PASS: a single --ask over 140 chars refuses ---
LONG_ASK="QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ"
rm -f "$SENT"; rc=0
bash "$BIND" post --title "T" --ask "$LONG_ASK" 2>/dev/null || rc=$?
[ "$rc" = 2 ] || fail "over-140-char --ask must exit 2 (got $rc)"
[ ! -e "$SENT" ] || fail "over-140-char --ask must not send"
echo "PASS: --ask over 140 chars refuses"

# --- PASS: too many --line bullets (>6) refuses ---
rm -f "$SENT"; rc=0
bash "$BIND" post --title "T" \
  --line "one" --line "two" --line "three" \
  --line "four" --line "five" --line "six" --line "seven" \
  2>/dev/null || rc=$?
[ "$rc" = 2 ] || fail "seven --line bullets must exit 2 (got $rc)"
[ ! -e "$SENT" ] || fail "seven --line bullets must not send"
echo "PASS: more than 6 --line bullets refuses"

# --- PASS: too many --next items (>2) refuses ---
rm -f "$SENT"; rc=0
bash "$BIND" post --title "T" \
  --next "first" --next "second" --next "third" \
  2>/dev/null || rc=$?
[ "$rc" = 2 ] || fail "three --next items must exit 2 (got $rc)"
[ ! -e "$SENT" ] || fail "three --next items must not send"
echo "PASS: more than 2 --next items refuses"

# --- PASS: too many --ask items (>1) refuses ---
rm -f "$SENT"; rc=0
bash "$BIND" post --title "T" \
  --ask "first question" --ask "second question" \
  2>/dev/null || rc=$?
[ "$rc" = 2 ] || fail "two --ask items must exit 2 (got $rc)"
[ ! -e "$SENT" ] || fail "two --ask items must not send"
echo "PASS: more than 1 --ask item refuses"

# --- PASS: --allow-long lets an over-budget post through ---
rm -f "$SENT"; rc=0
bash "$BIND" post --title "Big update" --allow-long \
  --line "$LONG_LINE" \
  --line "$LONG_LINE" \
  --line "$LONG_LINE" \
  --line "$LONG_LINE" \
  --line "$LONG_LINE" \
  >/dev/null || rc=$?
[ "$rc" = 0 ] || fail "--allow-long post must succeed (rc=$rc)"
[ -e "$SENT" ] || fail "--allow-long post must call send"
echo "PASS: --allow-long lets an over-budget post through"

# --- PASS: unreadable roster still fails closed (existing behaviour not broken) ---
rm -f "$SENT" "$SANDBOX/root/workspace/sessions/sess-test/dm-bind.roster"; rc=0
: > "$ROSTER_FILE"
bash "$BIND" post --title "T" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && [ ! -e "$SENT" ] || fail "unreadable roster must refuse without posting (rc=$rc)"
echo "PASS: unreadable roster still refuses (mention guard not broken by length guard)"
