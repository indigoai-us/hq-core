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

echo "[3] no hq on PATH: the shell body refuses and writes no units"
# Its units start `hq core job run`; without hq they would fail at fire time.
# The refusal also looks under `npm prefix -g`/bin, as the units do. A stub npm
# that reports an empty prefix keeps a host npm from supplying an hq here.
rm -f "$TMP/calls"
mkdir -p "$TMP/units-nohq" "$TMP/npm-none/bin" "$TMP/npm-none/prefix"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\n' "$TMP/npm-none/prefix" >"$TMP/npm-none/bin/npm"
chmod +x "$TMP/npm-none/bin/npm"
HQ_JOB_UNIT_DIR="$TMP/units-nohq" run_reconcile "$MIN" "$TMP/npm-none/bin:/usr/bin:/bin" --no-probe --hq-root "$HQ"
[ ! -e "$TMP/calls" ] || fail "hq was called without being on PATH"
[ "$STATUS" -eq 2 ] || fail "expected exit 2 without hq, got $STATUS: $(cat "$TMP/err")"
grep -q "^outpost-jobs-reconcile: job units run 'hq core job run', which needs hq-cli >= 5.296.0 on PATH; no units written" "$TMP/err" \
  || fail "missing-hq refusal not printed: $(cat "$TMP/err")"
[ -z "$(ls -A "$TMP/units-nohq")" ] || fail "units written without hq: $(ls -A "$TMP/units-nohq")"
pass "missing hq: shell body refused with exit 2 and no units"

echo "[3b] hq below the job-run floor: the shell body refuses"
rm -f "$TMP/calls"
run_reconcile "5.295.9" "$BIN:/usr/bin:/bin" --no-probe --hq-root "$HQ"
[ ! -e "$TMP/calls" ] || fail "an hq below the job-run floor was handed work: $(cat "$TMP/calls")"
[ "$STATUS" -eq 2 ] || fail "expected exit 2 below the job-run floor, got $STATUS: $(cat "$TMP/err")"
grep -q "needs hq-cli >= 5.296.0 on PATH; no units written" "$TMP/err" \
  || fail "below-floor refusal not printed: $(cat "$TMP/err")"
pass "hq 5.295.9: shell body refused with exit 2"

echo "[4] HQ_JOB_RECONCILE_SHELL=1 keeps the shell body"
rm -f "$TMP/calls"
HQ_JOB_RECONCILE_SHELL=1 run_reconcile "$MIN" "$BIN:/usr/bin:/bin" --no-probe --hq-root "$HQ"
[ ! -e "$TMP/calls" ] || fail "HQ_JOB_RECONCILE_SHELL=1 still called hq"
grep -q '^outpost-jobs-reconcile: ' "$TMP/err" || fail "shell body did not run: $(cat "$TMP/err")"
pass "HQ_JOB_RECONCILE_SHELL=1: shell body ran"

echo "[5] the one-release hq-job-run.sh forwarder hands old units to hq core job run"
# Units from older reconciles still start core/scripts/hq-job-run.sh, and
# /update-hq does not rerun the reconcile.
FWD="$ROOT/core/scripts/hq-job-run.sh"
rm -f "$TMP/calls"
set +e
env -u HQ_NO_UPDATE_CHECK PATH="$BIN:/usr/bin:/bin" STUB_HQ_VERSION="$MIN" STUB_HQ_CALLS="$TMP/calls" \
  bash "$FWD" --hq-root "$HQ" --job-id daily-digest >"$TMP/out" 2>"$TMP/err"
STATUS=$?
set -e
[ "$STATUS" -eq 7 ] || fail "forwarder did not return the hq exit status 7, got $STATUS: $(cat "$TMP/err")"
expected="$(printf '%s\n' "HQ_NO_UPDATE_CHECK=1" core job run --hq-root "$HQ" --job-id daily-digest)"
[ "$(cat "$TMP/calls")" = "$expected" ] || fail "unexpected forwarder argv: $(cat "$TMP/calls")"
set +e
env PATH="/usr/bin:/bin" bash "$FWD" --hq-root "$HQ" --job-id daily-digest >"$TMP/out" 2>"$TMP/err"
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] || fail "forwarder without hq: expected exit 2, got $STATUS"
grep -q "the hq CLI is not on PATH" "$TMP/err" || fail "forwarder without hq: no message: $(cat "$TMP/err")"
pass "forwarder: argv and exit status passed through; refuses without hq"

echo "ALL PASSED (outpost-jobs-reconcile-native-route)"
