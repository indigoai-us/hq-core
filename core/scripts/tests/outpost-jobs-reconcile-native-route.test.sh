#!/usr/bin/env bash
# hq-core: public
# US-043: outpost-jobs-reconcile.sh hands the whole reconcile to
# `hq core jobs reconcile` when the installed hq-cli has the native job runner,
# and keeps its shell body on an older or missing hq or when
# HQ_JOB_RECONCILE_SHELL=1.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/outpost-reconcile-native.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
HQ="$TMP/hq"
BIN="$TMP/bin"
mkdir -p "$HQ/core/scripts/lib" "$BIN" "$TMP/home"
cp "$ROOT/core/scripts/outpost-jobs-reconcile.sh" "$HQ/core/scripts/"
cp "$ROOT/core/scripts/lib/hq-cli-floor.sh" "$HQ/core/scripts/lib/"
HQ_CANON="$(cd "$HQ" && pwd)"
# The floor the script declares; 5.345.224 when it declares none (origin/main).
MIN="$(sed -n 's/^HQ_JOB_RECONCILE_NATIVE_MIN_CLI=//p' "$HQ/core/scripts/outpost-jobs-reconcile.sh")"
MIN="${MIN:-5.345.224}"

cat >"$BIN/hq" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then printf '%s\n' "$STUB_HQ_VERSION"; exit 0; fi
printf '%s\n' "HQ_NO_UPDATE_CHECK=${HQ_NO_UPDATE_CHECK:-}" "$@" >"$STUB_HQ_CALLS"
exit 7
STUB
chmod +x "$BIN/hq"

run_reconcile() {
  local version="$1" path="$2"
  shift 2
  set +e
  env -u HQ_ROOT HOME="$TMP/home" XDG_CACHE_HOME="$TMP/cache-$version" PATH="$path" \
    STUB_HQ_VERSION="$version" STUB_HQ_CALLS="$TMP/calls" \
    bash "$HQ/core/scripts/outpost-jobs-reconcile.sh" "$@" >"$TMP/out" 2>"$TMP/err"
  STATUS=$?
  set -e
}

echo "[1] hq at the native floor runs hq core jobs reconcile with every argument"
rm -f "$TMP/calls"
run_reconcile "$MIN" "$BIN:/usr/bin:/bin" --after-sync --no-probe --hq-root "$HQ"
[ "$STATUS" -eq 7 ] || fail "expected the hq exit status 7, got $STATUS: $(cat "$TMP/err")"
[ -f "$TMP/calls" ] || fail "hq core was not called"
expected="$(printf '%s\n' "HQ_NO_UPDATE_CHECK=1" core --hq-root "$HQ_CANON" jobs reconcile --after-sync --no-probe --hq-root "$HQ")"
[ "$(cat "$TMP/calls")" = "$expected" ] || fail "unexpected hq argv: $(cat "$TMP/calls")"
pass "native reconcile with the original arguments and exit status"

echo "[2] an older hq keeps the shell body"
# 5.345.223 was published before hq-cli#2871 merged (2184f4c85 is 9 commits
# ahead of v5.345.223), so its jobs reconcile still writes the old units.
rm -f "$TMP/calls"
run_reconcile "5.345.223" "$BIN:/usr/bin:/bin" --no-probe --hq-root "$HQ"
[ ! -e "$TMP/calls" ] || fail "an older hq was handed the reconcile: $(cat "$TMP/calls")"
grep -q '^outpost-jobs-reconcile: ' "$TMP/err" || fail "shell body did not run: $(cat "$TMP/err")"
pass "older hq: shell body ran (exit $STATUS)"

echo "[3] no hq on PATH keeps the shell body"
rm -f "$TMP/calls"
run_reconcile "$MIN" "/usr/bin:/bin" --no-probe --hq-root "$HQ"
[ ! -e "$TMP/calls" ] || fail "hq was called without being on PATH"
grep -q '^outpost-jobs-reconcile: ' "$TMP/err" || fail "shell body did not run: $(cat "$TMP/err")"
pass "missing hq: shell body ran (exit $STATUS)"

echo "[4] HQ_JOB_RECONCILE_SHELL=1 keeps the shell body"
rm -f "$TMP/calls"
HQ_JOB_RECONCILE_SHELL=1 run_reconcile "$MIN" "$BIN:/usr/bin:/bin" --no-probe --hq-root "$HQ"
[ ! -e "$TMP/calls" ] || fail "HQ_JOB_RECONCILE_SHELL=1 still called hq"
grep -q '^outpost-jobs-reconcile: ' "$TMP/err" || fail "shell body did not run: $(cat "$TMP/err")"
pass "HQ_JOB_RECONCILE_SHELL=1: shell body ran"

echo "ALL PASSED (outpost-jobs-reconcile-native-route)"
