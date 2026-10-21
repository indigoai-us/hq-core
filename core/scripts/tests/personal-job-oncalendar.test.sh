#!/usr/bin/env bash
# hq-core: public
# Personal OnCalendar output must match origin/main (hq-core-staging 5c9760db
# and later). Company jobs render wildcard minutes in lib/company-jobs.mjs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RECON="$ROOT/core/scripts/outpost-jobs-reconcile.sh"
RUNNER="$ROOT/core/scripts/hq-job-run.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

[ -f "$RECON" ] || fail "missing $RECON"
[ -f "$RUNNER" ] || fail "missing $RUNNER"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/personal-oncalendar.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

render_oncalendar() {
  local script="$1" minute="$2" hour="$3" dom="$4" month="$5" dow="$6" fns
  fns="$(awk 'BEGIN{p=0} /^# --- cron → systemd OnCalendar/{p=1} /^# --- unit writers/{exit} p{print}' "$script")"
  [ -n "$fns" ] || fail "cron converter functions not found in $script"
  printf '%s\n' "$fns" >"$TMP/cron-fns.sh"
  cat >>"$TMP/cron-fns.sh" <<'EOF'
cron_to_oncalendar "$1" "$2" "$3" "$4" "$5"
EOF
  bash "$TMP/cron-fns.sh" "$minute" "$hour" "$dom" "$month" "$dow"
}

expect_oncalendar() {
  local minute="$1" hour="$2" dom="$3" month="$4" dow="$5" expected="$6" actual
  actual="$(render_oncalendar "$RECON" "$minute" "$hour" "$dom" "$month" "$dow")"
  [ "$actual" = "$expected" ] || fail "$minute $hour $dom $month $dow rendered '$actual', expected '$expected'"
  pass "$minute $hour $dom $month $dow -> $actual"
}

# minute *, */15, fixed minute, range, day-of-week. A wildcard minute stays
# 00; steps and ranges use systemd syntax (00/15, 00..30). The full table
# is in outpost-cron-oncalendar.test.sh.
expect_oncalendar '*' '9' '*' '*' '*' '*-*-* 09:00:00'
expect_oncalendar '*/15' '9' '*' '*' '*' '*-*-* 09:00/15:00'
expect_oncalendar '30' '9' '*' '*' '*' '*-*-* 09:30:00'
expect_oncalendar '0-30' '9' '*' '*' '*' '*-*-* 09:00..30:00'
expect_oncalendar '15' '9' '*' '*' '1-5' 'Mon..Fri *-*-* 09:15:00'

# Neither flag nor HQ_MACHINE_AUTH_REQUIRED: personal entry, node is not exec'd.
cat >"$TMP/node" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >>"${PERSONAL_ONCALENDAR_NODE_LOG:?}"
exit 99
EOF
chmod +x "$TMP/node"
: >"$TMP/node-log"
help="$(PATH="$TMP:$PATH" PERSONAL_ONCALENDAR_NODE_LOG="$TMP/node-log" bash "$RECON" --help)" || fail "personal reconcile --help failed"
printf '%s\n' "$help" | grep -q 'outpost-jobs-reconcile' || fail "personal reconcile help missing"
if [ -s "$TMP/node-log" ]; then
  fail "personal reconcile --help executed node"
fi
run_help="$(PATH="$TMP:$PATH" PERSONAL_ONCALENDAR_NODE_LOG="$TMP/node-log" bash "$RUNNER" --help)" || fail "personal hq-job-run --help failed"
printf '%s\n' "$run_help" | grep -q 'hq-job-run' || fail "personal hq-job-run help missing"
if [ -s "$TMP/node-log" ]; then
  fail "personal entry points executed node without --company-machine"
fi
pass "personal entry points ignore company routing when the flag and env are absent"

guard_rejects() {
  local script="$1" label="$2" status
  set +e
  HQ_MACHINE_AUTH_REQUIRED=1 bash "$script" --help >"$TMP/out" 2>"$TMP/err"
  status=$?
  set -e
  [ "$status" -eq 2 ] || fail "$label with HQ_MACHINE_AUTH_REQUIRED=1 exited $status, expected 2"
  grep -q 'company jobs require --company-machine <config>' "$TMP/err" || fail "$label did not refuse the legacy path"
  pass "$label refuses the legacy path when machine auth is required"
}
guard_rejects "$RECON" "reconcile"
guard_rejects "$RUNNER" "hq-job-run"

: >"$TMP/node-log"
set +e
PATH="$TMP:$PATH" PERSONAL_ONCALENDAR_NODE_LOG="$TMP/node-log" bash "$RECON" --company-machine /etc/hq/company-jobs.json >"$TMP/out" 2>"$TMP/err"
status=$?
set -e
[ "$status" -eq 99 ] || fail "company reconcile flag should exec node, exited $status"
grep -q 'company-jobs.mjs' "$TMP/node-log" || fail "company reconcile did not exec company-jobs.mjs"
grep -q '^reconcile$' "$TMP/node-log" || fail "company reconcile did not pass action reconcile"
printf '%s\n' "$(cat "$TMP/out")" | grep -q 'Usage:' && fail "company reconcile fell through to personal usage"
pass "reconcile --company-machine dispatches to the company runner"

: >"$TMP/node-log"
set +e
PATH="$TMP:$PATH" PERSONAL_ONCALENDAR_NODE_LOG="$TMP/node-log" bash "$RUNNER" --company-machine /etc/hq/company-jobs.json job_abc revision1 >"$TMP/out" 2>"$TMP/err"
status=$?
set -e
[ "$status" -eq 99 ] || fail "company run flag should exec node, exited $status"
grep -q '^run$' "$TMP/node-log" || fail "company run did not pass action run"
pass "hq-job-run --company-machine dispatches to the company runner"

echo "ALL PASSED (personal-job-oncalendar)"
