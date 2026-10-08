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
FLAG_CACHE="$HOME/.hq/hq-anywhere-runtime.flag.cmp_123456"
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
[ "$(NODE_FAIL=true sh "$CACHE")" = true ]
[ "$(wc -l <"$NODE_CALLS" | tr -d ' ')" = 4 ]
printf '%s\n' 'ok   malformed cache plus failed reader defaults on'

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

# The multi-company guard shares the TTL cache but gets its own flag and
# company-scoped file. A fresh true snapshot must avoid invoking Node.
cat >"$TMP/multi-company-flag.cjs" <<'NODE'
process.stdout.write(process.env.HQ_TEST_MULTI_FLAG || "false");
NODE
printf 'true %s\n' "$(now_seconds)" >"$HOME/.hq/hook-flag.multi-company-test.indigo"
calls_before="$(wc -l <"$NODE_CALLS" | tr -d ' ')"
hqd_hook_flag_enabled_for multi-company-test hooks.multi-company-session-lock \
  "$TMP/multi-company-flag.cjs" "$TMP" indigo
[ "$HQD_FLAG_ENABLED" = true ] || { echo 'not ok   cached multi-company flag value is used' >&2; exit 1; }
[ "$(wc -l <"$NODE_CALLS" | tr -d ' ')" = "$calls_before" ] || { echo 'not ok   cached multi-company flag avoids Node' >&2; exit 1; }
printf '%s\n' 'ok   fresh multi-company cache value is used without Node'

# The tri-state reader exposes unknown only to the opted-in kill-switch caller.
printf 'false %s\n' "$(now_seconds)" >"$HOME/.hq/hook-flag.multi-company-test.indigo"
hqd_hook_flag_state_for multi-company-test hooks.multi-company-session-lock \
  "$TMP/multi-company-flag.cjs" "$TMP" indigo indigo
[ "$HQD_FLAG_STATE" = false ] || { echo 'not ok   tri-state reader preserves explicit false' >&2; exit 1; }
printf '%s\n' 'ok   tri-state reader preserves explicit false'
printf 'malformed\n' >"$HOME/.hq/hook-flag.multi-company-test.indigo"
NODE_FAIL=true hqd_hook_flag_state_for multi-company-test hooks.multi-company-session-lock \
  "$TMP/multi-company-flag.cjs" "$TMP" indigo indigo
[ "$HQD_FLAG_STATE" = unknown ] || { echo 'not ok   tri-state reader distinguishes failed refresh' >&2; exit 1; }
printf '%s\n' 'ok   tri-state reader distinguishes failed refresh from explicit false'

cat >"$TMP/multi-company-flag.cjs" <<'NODE'
const fs = require("node:fs");
fs.appendFileSync(process.env.COMPANY_LOG, `${process.env.HQ_COMPANY_SLUG}\n`);
process.stdout.write("true");
NODE
export COMPANY_LOG="$TMP/company-context.log"
rm -f "$HOME/.hq/hook-flag.multi-company-test.indigo"
hqd_hook_flag_state_for multi-company-test hooks.multi-company-session-lock \
  "$TMP/multi-company-flag.cjs" "$TMP" indigo indigo
[ "$HQD_FLAG_STATE" = true ] && grep -qx indigo "$COMPANY_LOG" \
  || { echo 'not ok   live lookup receives the session company slug' >&2; exit 1; }
printf '%s\n' 'ok   live lookup receives the session company slug'

# A fresh snapshot for one tenant must never satisfy another tenant's lookup.
export HQ_COMPANY_UID=cmp_cachea123 HQ_TEST_FLAG=true
. "$HERE/hqd-hook-flag-cache-lib.sh"
hqd_hook_flag_cache_store_enabled
export HQ_COMPANY_UID=cmp_cacheb123 HQ_TEST_FLAG=false
if [ "$(sh "$CACHE")" = false ]; then
  printf '%s\n' 'ok   runtime flag cache is isolated by company UID'
else
  printf '%s\n' 'not ok   runtime flag cache is isolated by company UID' >&2
  exit 1
fi
