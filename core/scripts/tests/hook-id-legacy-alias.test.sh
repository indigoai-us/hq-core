#!/usr/bin/env bash
# Regression: indigoai-us/hq-core-staging#1495 renamed a SessionStart hook id to
# desktop-memory-leak-check with no alias, so HQ_DISABLED_HOOKS entries naming
# the retired id silently stopped disabling the hook. hook-gate.sh now treats
# the retired id as an alias, matched by sha256. The retired id is never stored
# in plain text: the test decodes it from a hex fixture at run time.
# Runs under bash 3.2 (macOS /bin/bash) and bash 5.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
GATE="${HQ_TEST_HOOK_GATE:-$ROOT/.claude/hooks/hook-gate.sh}"
HEX_FILE="$ROOT/core/scripts/tests/fixtures/hook-id-alias/retired-id.hex"
NEW_ID=desktop-memory-leak-check
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }
[ -f "$GATE" ] || fail "hook-gate.sh not found at $GATE"
[ -f "$HEX_FILE" ] || fail "fixture missing: $HEX_FILE"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Decode the hex fixture into the retired id without echoing it.
hex="$(tr -d ' \n' <"$HEX_FILE")"
esc=""
while [ -n "$hex" ]; do
  esc="$esc\\x${hex:0:2}"
  hex="${hex:2}"
done
OLD="$(printf '%b' "$esc")"
[ "${#OLD}" -eq 19 ] || fail "decoded fixture has the wrong length"
OLD_UPPER="$(printf '%s' "$OLD" | tr '[:lower:]' '[:upper:]')"

# shellcheck disable=SC1090
. "$GATE" --lib
[ "$(printf '%s' "$OLD" | hq_hook_sha256_stdin | awk '{print $1}')" = "$HQ_HOOK_LEGACY_ALIAS_SHA256" ] \
  || fail "fixture does not hash to the alias sha256"
pass "fixture decodes to the retired id (by hash)"

reset_cache() { _hq_hook_alias_cache_key=""; _hq_hook_alias_cache_hit=""; _hq_hook_alias_noted=""; }

# allows <list> <id>: prints allowed|disabled
allows() {
  reset_cache
  if HQ_DISABLED_HOOKS="$1" hq_hook_profile_allows "$2" standard 2>/dev/null; then
    echo allowed
  else
    echo disabled
  fi
}

[ "$(allows "$OLD" "$NEW_ID")" = disabled ] || fail "retired id does not disable $NEW_ID"
pass "retired id disables $NEW_ID"
[ "$(allows "  $OLD_UPPER  " "$NEW_ID")" = disabled ] || fail "trimmed uppercase retired id does not disable $NEW_ID"
pass "retired id matches case-insensitively after trimming"
[ "$(allows "$NEW_ID" "$NEW_ID")" = disabled ] || fail "new id no longer disables $NEW_ID"
pass "new id still disables $NEW_ID"
[ "$(allows "abcdefghij-klmnopqr" "$NEW_ID")" = allowed ] || fail "unrelated 19-char id disabled $NEW_ID"
[ "$(allows "detect-secrets" "$NEW_ID")" = allowed ] || fail "unrelated id disabled $NEW_ID"
[ "$(allows "" "$NEW_ID")" = allowed ] || fail "empty list disabled $NEW_ID"
pass "unrelated ids do not match"
[ "$(allows "detect-secrets, $OLD ,journal-due" "$NEW_ID")" = disabled ] || fail "mixed list did not disable $NEW_ID"
[ "$(allows "detect-secrets, $OLD ,journal-due" detect-secrets)" = disabled ] || fail "mixed list lost detect-secrets"
[ "$(allows "$OLD,journal-due" block-hq-glob)" = allowed ] || fail "alias leaked onto another hook"
pass "mixed list disables both named hooks and nothing else"

# Deprecation note: once per process, names only the new id.
reset_cache
HQ_DISABLED_HOOKS="$OLD"
hq_hook_profile_allows "$NEW_ID" standard 2>"$TMP/err1" || true
hq_hook_profile_allows "$NEW_ID" standard 2>"$TMP/err2" || true
[ "$(wc -l <"$TMP/err1" | tr -d ' ')" = 1 ] || fail "expected one deprecation line"
[ ! -s "$TMP/err2" ] || fail "deprecation note printed twice"
grep -qF "$NEW_ID" "$TMP/err1" || fail "deprecation note does not name $NEW_ID"
if grep -qiF "$OLD" "$TMP/err1"; then fail "deprecation note names the retired id"; fi
pass "deprecation note printed once and names only $NEW_ID"

# Cache: a second call with the same list needs no hash tool.
saved_path="$PATH"
PATH="$TMP/empty"
hq_hook_legacy_alias_disabled 2>/dev/null || { PATH="$saved_path"; fail "cached result lost"; }
PATH="$saved_path"
pass "result cached per process"
unset HQ_DISABLED_HOOKS

# No hash process for lists without a candidate entry.
mkdir -p "$TMP/spy"
for t in shasum sha256sum; do
  printf '#!/bin/sh\necho called >>"%s/spy.log"\ncat >/dev/null\n' "$TMP" >"$TMP/spy/$t"
  chmod +x "$TMP/spy/$t"
done
reset_cache
PATH="$TMP/spy:$PATH" HQ_DISABLED_HOOKS="detect-secrets,journal-due" hq_hook_legacy_alias_disabled || true
[ ! -f "$TMP/spy.log" ] || fail "hashed an entry that cannot be the retired id"
pass "no hash process for ordinary entries"

# Fail safe: with no shasum or sha256sum the alias cannot be proven, so the hook runs.
mkdir -p "$TMP/nohash"
ln -s "$(command -v tr)" "$TMP/nohash/tr"
reset_cache
if PATH="$TMP/nohash" HQ_DISABLED_HOOKS="$OLD" hq_hook_profile_allows "$NEW_ID" standard 2>/dev/null; then
  :
else
  fail "alias matched without a hash tool"
fi
reset_cache
if PATH="$TMP/nohash" HQ_DISABLED_HOOKS="$NEW_ID" hq_hook_profile_allows "$NEW_ID" standard; then
  fail "new id stopped working without a hash tool"
fi
pass "without a hash tool the alias fails safe (hook runs) and the new id still works"

# Standalone gate path (hook-gate.sh <id> <script>).
cat >"$TMP/probe.sh" <<'HOOK'
#!/bin/bash
cat >/dev/null
echo ran >"$PROBE_OUT"
HOOK
chmod +x "$TMP/probe.sh"
gate_runs() {
  rm -f "$TMP/probe.out"
  PROBE_OUT="$TMP/probe.out" HQ_HOOK_PROFILE=standard HQ_DISABLED_HOOKS="$1" HQ_HOOK_TIMEOUT_SENTRY=0 \
    bash "$GATE" "$NEW_ID" "$TMP/probe.sh" </dev/null 2>"$TMP/gate.err" || true
  if [ -f "$TMP/probe.out" ]; then echo ran; else echo skipped; fi
}
[ "$(gate_runs "x,$OLD")" = skipped ] || fail "gate ran $NEW_ID with the retired id disabled"
grep -qF "$NEW_ID" "$TMP/gate.err" || fail "gate did not print the deprecation note"
[ "$(gate_runs "$NEW_ID")" = skipped ] || fail "gate ran $NEW_ID with the new id disabled"
[ "$(gate_runs "abcdefghij-klmnopqr")" = ran ] || fail "gate skipped $NEW_ID for an unrelated id"
[ "$(gate_runs "")" = ran ] || fail "gate skipped $NEW_ID with an empty list"
pass "standalone gate honours the alias"

echo "PASS: hook-id-legacy-alias"
