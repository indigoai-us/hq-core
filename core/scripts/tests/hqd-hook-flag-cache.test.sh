#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d /tmp/hqd-flag-cache.XXXXXX)
trap 'rm -rf "$TMP"' EXIT INT TERM
. "$HERE/tests/hq-anywhere-flag-fixture.sh"
hq_anywhere_flag_fixture "$TMP/cli"
REAL_NODE=$(command -v node)
mkdir -p "$TMP/bin" "$TMP/home/.hq"
cat >"$TMP/bin/node" <<'SH'
#!/bin/sh
printf 'called\n' >>"$NODE_CALLS"
[ "${NODE_FAIL:-false}" = true ] && exit 1
exec "$REAL_NODE" "$@"
SH
chmod 700 "$TMP/bin/node"
export REAL_NODE NODE_CALLS="$TMP/node-calls" PATH="$TMP/bin:$PATH" HOME="$TMP/home"
export HQ_CLI_BIN="$TMP/cli/bin/hq" HQ_FLAGS_API_URL=https://flags.test HQ_COMPANY_UID=cmp_123456 HQ_TEST_FLAG=true
CACHE="$HERE/hqd-hook-flag-cache.sh"
FLAG_CACHE="$HOME/.hq/hq-anywhere-runtime.flag"
. "$HERE/hqd-hook-flag-cache-lib.sh"
NOW=$(now_seconds)

printf 'true %s\n' "$NOW" >"$FLAG_CACHE"
[ "$(sh "$CACHE")" = true ]
[ ! -e "$NODE_CALLS" ]
printf '%s\n' 'ok   fresh cache returns true without Node'

printf 'true %s\n' "$((NOW - 61))" >"$FLAG_CACHE"
[ "$(sh "$CACHE")" = true ]
[ "$(wc -l <"$NODE_CALLS" | tr -d ' ')" = 1 ]
case "$(cat "$FLAG_CACHE")" in "true "*) ;; *) exit 1 ;; esac
[ "$(sh "$CACHE")" = true ]
[ "$(wc -l <"$NODE_CALLS" | tr -d ' ')" = 1 ]
printf '%s\n' 'ok   stale cache refreshes once and uses enabled value for this event'

rm -f "$FLAG_CACHE"
[ "$(sh "$CACHE")" = true ]
[ "$(wc -l <"$NODE_CALLS" | tr -d ' ')" = 2 ]
[ "$(sh "$CACHE")" = true ]
[ "$(wc -l <"$NODE_CALLS" | tr -d ' ')" = 2 ]
printf '%s\n' 'ok   missing cache refreshes once and uses enabled value for this event'

printf 'true %s\n' "$((NOW - 61))" >"$FLAG_CACHE"
[ "$(HQ_TEST_FLAG=false sh "$CACHE")" = false ]
[ "$(wc -l <"$NODE_CALLS" | tr -d ' ')" = 3 ]
printf '%s\n' 'ok   stale enabled cache with flag off refreshes and remains off'

printf 'enabled maybe\n' >"$FLAG_CACHE"
[ "$(NODE_FAIL=true sh "$CACHE")" = false ]
[ "$(wc -l <"$NODE_CALLS" | tr -d ' ')" = 4 ]
printf '%s\n' 'ok   malformed cache plus failed reader fails off'

printf 'true %s\ninvalid trailing data\n' "$NOW" >"$FLAG_CACHE"
[ "$(sh "$CACHE")" = true ]
[ "$(wc -l <"$NODE_CALLS" | tr -d ' ')" = 5 ]
[ "$(sh "$CACHE")" = true ]
printf '%s\n' 'ok   trailing cache data is malformed and refreshes for this event'

printf 'false %s\n' "$NOW" >"$FLAG_CACHE"
calls_before="$(wc -l <"$NODE_CALLS" | tr -d ' ')"
hqd_hook_flag_cache_store_enabled
[ "$(sh "$CACHE")" = true ]
[ "$(wc -l <"$NODE_CALLS" | tr -d ' ')" = "$calls_before" ]
printf '%s\n' 'ok   master-hook can publish its verified enabled decision without a second flag lookup'

[ "$(perl -e 'printf "%o", (stat($ARGV[0]))[2] & 07777' "$HOME/.hq")" = 700 ]
[ "$(perl -e 'printf "%o", (stat($ARGV[0]))[2] & 07777' "$FLAG_CACHE")" = 600 ]
printf '%s\n' 'ok   cache directory and file are user-only'
