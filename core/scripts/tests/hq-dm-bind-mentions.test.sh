#!/usr/bin/env bash
# Regression: every dm-bind post @-mentions someone. --no-mention is gone,
# --to narrows the line, and an unreadable roster refuses instead of posting
# an update that notifies nobody.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/root/core/scripts" "$SANDBOX/bin" "$SANDBOX/home"
cp "$ROOT/core/scripts/hq-dm-bind.sh" "$SANDBOX/root/core/scripts/"
mkdir -p "$SANDBOX/home/.hq"
printf '{}\n' > "$SANDBOX/home/.hq/config.json"
printf '{}\n' > "$SANDBOX/home/.hq/cognito-tokens.json"

# Stub session helper: fixed session id, channel already bound.
cat > "$SANDBOX/root/core/scripts/hq-session.sh" <<'S'
#!/usr/bin/env bash
case "$1" in current) printf 'sess-test' ;; get) echo '"room"' ;; *) : ;; esac
S
# Stub hq: quiet. Posting no longer goes through the CLI.
cat > "$SANDBOX/bin/hq" <<'S'
#!/usr/bin/env bash
if [ "$1" = dm ] && [ "$2" = channel ]; then echo "${CHANNEL_JSON:-[]}"; fi
exit 0
S
# Stub node: `roster` prints $ROSTER (name<TAB>uid rows); `send` records the
# JSON payload and answers with a fresh event id.
cat > "$SANDBOX/bin/node" <<'S'
#!/usr/bin/env bash
cat >/dev/null
case "$2" in
  roster) printf '%s' "${ROSTER:-}" ;;
  send) printf '%s\n' "$4" >> "$SENT"; n="$(wc -l < "$SENT" | tr -d ' ')"; printf 'evt-%s' "$n" ;;
esac
S
chmod +x "$SANDBOX/bin/hq" "$SANDBOX/bin/node"
export PATH="$SANDBOX/bin:$PATH" HOME="$SANDBOX/home" HQ_ROOT="$SANDBOX/root" SENT="$SANDBOX/sent"
BIND="$SANDBOX/root/core/scripts/hq-dm-bind.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

export ROSTER=$'Ada Lovelace\tprs_ada\nGrace Hopper\tprs_grace\ngeorge\tagt_george\n'
rm -f "$SENT"; bash "$BIND" post --title "T" --line "one" >/dev/null
[ "$(jq -r '.body' "$SENT" | head -1)" = '@Ada Lovelace @Grace Hopper' ] || fail "default post must name every human member without quotes, and no bot: $(jq -r .body "$SENT" | head -1)"
[ "$(jq -c '[.mentions[]|[.participantUid,.participantType]]' "$SENT")" = '[["prs_ada","human"],["prs_grace","human"]]' ] || fail "mentions must be structured with the right types: $(jq -c .mentions "$SENT")"
[ "$(jq -r 'has("rootEventId")' "$SENT")" = false ] || fail "first post on a topic must be a root"
echo "PASS: default post mentions every human member and no bot"

rm -f "$SENT"; bash "$BIND" post --title "T" --to "grace" --to "@george" >/dev/null
[ "$(jq -r '.body' "$SENT" | head -1)" = '@Grace Hopper @george' ] || fail "--to must narrow the line: $(jq -r .body "$SENT" | head -1)"
[ "$(jq -c '[.mentions[]|.participantType]' "$SENT")" = '["human","agent"]' ] || fail "--to must be able to name a bot: $(jq -c .mentions "$SENT")"
[ "$(jq -r '.rootEventId' "$SENT")" = evt-1 ] || fail "second post on the same topic must reply under the first root: $(jq -c . "$SENT")"
echo "PASS: a later post on the same topic is a threaded reply"

rm -f "$SENT"; bash "$BIND" post --title "Other topic" >/dev/null
[ "$(jq -r 'has("rootEventId")' "$SENT")" = false ] || fail "a new topic must start a new root"
rm -f "$SENT"; bash "$BIND" post --title "T" --new-thread >/dev/null
[ "$(jq -r 'has("rootEventId")' "$SENT")" = false ] || fail "--new-thread must start a new root"
echo "PASS: a new topic and --new-thread start a new root"
echo "PASS: --to narrows to the named members (case-insensitive, partial, leading @)"

export CHANNEL_JSON='[{"eventId":"aaaa1111-x","fromDisplayName":"Stefan","body":"Billing lane","replyCount":2},{"eventId":"bbbb2222-y","rootEventId":"aaaa1111-x","body":"a reply"},{"eventId":"aaaa9999-z","fromDisplayName":"Corey","body":"Bot bugs here"}]'
bash "$BIND" threads | grep -q '^aaaa1111' || fail "threads must list top-level messages"
bash "$BIND" threads | grep -q '^bbbb2222' && fail "threads must not list replies"
rm -f "$SENT"; bash "$BIND" post --title "Billing note" --under aaaa1 >/dev/null
[ "$(jq -r '.rootEventId' "$SENT")" = aaaa1111-x ] || fail "--under must reply under the existing thread: $(jq -c . "$SENT")"
rm -f "$SENT"; bash "$BIND" post --title "Billing note" >/dev/null
[ "$(jq -r '.rootEventId' "$SENT")" = aaaa1111-x ] || fail "later posts on the topic must stay under that thread"
rm -f "$SENT"; rc=0; bash "$BIND" post --title "X" --under aaaa >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && [ ! -e "$SENT" ] || fail "ambiguous --under must refuse (rc=$rc)"
echo "PASS: --under replies under an existing thread and the topic stays there"

rm -f "$SENT"; rc=0; bash "$BIND" post --title "T" --to "Nobody Here" >/dev/null 2>"$SANDBOX/err" || rc=$?
[ "$rc" = 2 ] && [ ! -e "$SENT" ] || fail "unknown --to must refuse without posting (rc=$rc)"
grep -q 'Ada Lovelace' "$SANDBOX/err" || fail "unknown --to must list the members"
echo "PASS: unknown --to refuses and lists members"

rm -f "$SENT"; rc=0; bash "$BIND" post --title "T" --to "a" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && [ ! -e "$SENT" ] || fail "ambiguous --to must refuse without posting (rc=$rc)"
echo "PASS: ambiguous --to refuses"

rm -f "$SENT"; rc=0; bash "$BIND" post --title "T" --no-mention >/dev/null 2>"$SANDBOX/err" || rc=$?
[ "$rc" = 2 ] && [ ! -e "$SENT" ] || fail "--no-mention must be rejected without posting (rc=$rc)"
grep -q -- '--to' "$SANDBOX/err" || fail "--no-mention rejection must point at --to"
echo "PASS: --no-mention is rejected"

rm -f "$SENT" "$SANDBOX/root/workspace/sessions/sess-test/dm-bind.roster"; rc=0
ROSTER="" bash "$BIND" post --title "T" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && [ ! -e "$SENT" ] || fail "unreadable roster must refuse without posting (rc=$rc)"
echo "PASS: unreadable roster refuses instead of posting unmentioned"
