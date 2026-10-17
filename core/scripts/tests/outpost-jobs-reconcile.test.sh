#!/usr/bin/env bash
# hq-core: public
# Regression: outpost-jobs-reconcile.sh units, readiness gate, owner filter, idempotency (US-004).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RECON="${HQ_JOB_RECONCILE_TEST_SCRIPT_SOURCE:-$ROOT/core/scripts/outpost-jobs-reconcile.sh}"
FIX_VALID="$ROOT/core/scripts/tests/fixtures/jobs/valid"

command -v yq >/dev/null 2>&1 || { echo "SKIP: yq not available"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }
[ -f "$RECON" ] || { echo "FAIL: missing $RECON" >&2; exit 1; }
[ -x "$RECON" ] || chmod +x "$RECON"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hq-job-recon-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

AWS_PROFILE="us-110-111-test"
AWS_SHARED_CREDENTIALS_FILE="$TMP/empty-aws-credentials"
AWS_CONFIG_FILE="$TMP/empty-aws-config"
AWS_EC2_METADATA_DISABLED=true
: >"$AWS_SHARED_CREDENTIALS_FILE"
: >"$AWS_CONFIG_FILE"
export AWS_PROFILE AWS_SHARED_CREDENTIALS_FILE AWS_CONFIG_FILE AWS_EC2_METADATA_DISABLED
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN \
  AWS_WEB_IDENTITY_TOKEN_FILE AWS_ROLE_ARN AWS_CONTAINER_CREDENTIALS_RELATIVE_URI \
  AWS_CONTAINER_CREDENTIALS_FULL_URI AWS_CONTAINER_AUTHORIZATION_TOKEN

HQ="$TMP/hqroot"
HOME_DIR="$TMP/home"
UNIT_DIR="$TMP/units"
CACHE="$TMP/status-cache"
BIN="$TMP/bin"
mkdir -p "$HQ/personal/jobs" "$HQ/companies/indigo/jobs" "$HQ/companies/indigo/projects/outpost-scheduled-jobs"
mkdir -p "$HOME_DIR" "$UNIT_DIR" "$CACHE" "$BIN" "$HOME_DIR/.hq/jobs/reconcile"
mkdir -p "$HQ/core/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$HQ/core/scripts/hq-job-run.sh"
for blocked_binary in aws sst pulumi systemctl hq curl; do
  cat >"$BIN/$blocked_binary" <<'STUB'
#!/usr/bin/env bash
printf 'unexpected external binary: %s\n' "${0##*/}" >&2
exit 97
STUB
  chmod +x "$BIN/$blocked_binary"
done
export HOME="$HOME_DIR"
export HQ_ROOT="$HQ"
export PATH="$BIN:$PATH"
for blocked_binary in aws sst pulumi systemctl hq curl; do
  [ "$(command -v "$blocked_binary")" = "$BIN/$blocked_binary" ] \
    || fail "the test must not resolve the host $blocked_binary binary"
done
export HQ_JOB_UNIT_DIR="$UNIT_DIR"
export HQ_JOB_STATUS_CACHE_DIR="$CACHE"
export HQ_JOB_SYSTEMCTL=":"
export HQ_JOB_OWNER_EMAIL="owner@example.com"
export HQ_JOB_OWNER_UID="prs_owner"
export HQ_JOB_RANDOMIZE_SEC=45
unset HQ_ACCESS_TOKEN HQ_PRO_API_URL HQ_API_URL HQ_VAULT_API_URL

# Stub probe — records calls; optionally writes cache via env.
cat >"$BIN/hq-job-probe-stub.sh" <<'STUB'
#!/usr/bin/env bash
# Not used directly — we point PROBE via PATH? Reconcile calls absolute PROBE path.
exit 0
STUB
chmod +x "$BIN/hq-job-probe-stub.sh"

# Copy valid personal job; rewrite owner to match box.
cp "$FIX_VALID/personal-daily-digest.yaml" "$HQ/personal/jobs/digest.yaml"
# Force owner email match
yq -i '.owner = "owner@example.com"' "$HQ/personal/jobs/digest.yaml"

# Company job owned by someone else — must be ignored.
cp "$FIX_VALID/company-with-requirements.yaml" "$HQ/companies/indigo/jobs/other-owner.yaml"
yq -i '.owner = "other@example.com"' "$HQ/companies/indigo/jobs/other-owner.yaml"

# Company job owned by this box — candidate once ready.
cp "$FIX_VALID/company-with-requirements.yaml" "$HQ/companies/indigo/jobs/mine.yaml"
yq -i '.owner = "owner@example.com"' "$HQ/companies/indigo/jobs/mine.yaml"
yq -i '.id = "sentry-triage-mine"' "$HQ/companies/indigo/jobs/mine.yaml"

# Disabled personal job
cat >"$HQ/personal/jobs/disabled.yaml" <<'YAML'
id: disabled-job
name: Disabled
schedule: "0 9 * * *"
timezone: UTC
runtime: claude
exec:
  prompt: "noop"
timeout_seconds: 120
notify: none
enabled: false
owner: owner@example.com
created_at: "2026-08-23T14:00:00Z"
requirements:
  runtime: claude
  secrets: []
YAML

# Seed readiness=ready for personal digest only
jq -nc '{job_id:"daily-inbox-digest",readiness:"ready",updated_at:"2026-08-23T18:00:00Z",source:"test"}' \
  >"$CACHE/daily-inbox-digest.json"
# mine stays unknown/pending — should not arm
jq -nc '{job_id:"sentry-triage-mine",readiness:"pending_probe",updated_at:"2026-08-23T18:00:00Z",source:"test"}' \
  >"$CACHE/sentry-triage-mine.json"

# A failed systemctl enable must be reported as an error on both the write and
# idempotent paths. These stubs never invoke the host's systemctl binary.
cat >"$BIN/systemctl-fail-enable" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${HQ_JOB_SYSTEMCTL_TEST_LOG:?}"
if [[ "$*" == "--user daemon-reload" ]]; then
  exit 0
fi
if [[ "$*" == "--user enable --now hq-job-daily-inbox-digest.timer" ]]; then
  echo "Failed to connect to bus: No medium found" >&2
  exit 37
fi
exit 0
STUB
chmod +x "$BIN/systemctl-fail-enable"
cat >"$BIN/systemctl-success" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${HQ_JOB_SYSTEMCTL_TEST_LOG:?}"
STUB
chmod +x "$BIN/systemctl-success"
cat >"$BIN/systemctl-no-user-bus" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${HQ_JOB_SYSTEMCTL_TEST_LOG:?}"
if [[ "$*" == "--user show-environment" ]]; then
  echo "Failed to connect to bus: No medium found" >&2
  exit 37
fi
exit 0
STUB
chmod +x "$BIN/systemctl-no-user-bus"
assert_enable_failure() {
  local label="$1" rc=0 summary_file="$HOME_DIR/.hq/jobs/reconcile/last-reconcile.json"
  export HQ_JOB_SYSTEMCTL_TEST_LOG="$TMP/$label.systemctl.log"
  HQ_JOB_SYSTEMCTL="$BIN/systemctl-fail-enable" bash "$RECON" --hq-root "$HQ" --no-probe \
    >"$TMP/$label.out" 2>"$TMP/$label.err" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "$label systemctl failure should make reconcile exit non-zero"
  jq -e '.errors == 1 and .armed == 0 and .skipped == 3' "$summary_file" >/dev/null \
    || fail "$label summary must report the failed job as skipped (plus two fixture skips): $(cat "$summary_file")"
  ! grep -Fq 'armed daily-inbox-digest' "$TMP/$label.err" \
    || fail "$label must not log the failed timer as armed"
  grep -Fq 'systemctl enable timer failed for job daily-inbox-digest exit=37: Failed to connect to bus: No medium found' \
    "$TMP/$label.err" || fail "$label must log the job id, exit code, and systemctl message"
  grep -Fq 'not-scheduled job daily-inbox-digest reason=Failed to connect to bus: No medium found' \
    "$TMP/$label.err" || fail "$label must report the timer as not-scheduled with the bus failure reason"
  grep -Fqx -- '--user show-environment' "$HQ_JOB_SYSTEMCTL_TEST_LOG" \
    || fail "$label must probe the user manager before trying to enable the timer"
  [ -f "$UNIT_DIR/hq-job-daily-inbox-digest.service" ] \
    && [ -f "$UNIT_DIR/hq-job-daily-inbox-digest.timer" ] \
    || fail "$label systemctl failure must leave the generated unit files in place"
}

# A successful enable continues to count as armed on the no-op path.
export HQ_JOB_SYSTEMCTL_TEST_LOG="$TMP/systemctl-success.log"
HQ_JOB_SYSTEMCTL="$BIN/systemctl-success" bash "$RECON" --hq-root "$HQ" --no-probe \
  >"$TMP/enable-success.out" 2>"$TMP/enable-success.err"
jq -e '.errors == 0 and .armed == 1' "$HOME_DIR/.hq/jobs/reconcile/last-reconcile.json" >/dev/null \
  || fail "successful systemctl enable should report armed=1 and errors=0"
grep -Fqx -- '--user enable --now hq-job-daily-inbox-digest.timer' "$HQ_JOB_SYSTEMCTL_TEST_LOG" \
  || fail "successful systemctl stub must receive the timer enable request"

# A missing systemctl binary cannot report the timer as armed.
rc=0
HQ_JOB_SYSTEMCTL="$TMP/systemctl-not-installed" bash "$RECON" --hq-root "$HQ" --no-probe \
  >"$TMP/systemctl-unavailable.out" 2>"$TMP/systemctl-unavailable.err" || rc=$?
[ "$rc" -ne 0 ] || fail "an unavailable systemctl must make reconcile report a scheduling failure"
jq -e '.errors == 1 and .armed == 0 and .skipped == 3' "$HOME_DIR/.hq/jobs/reconcile/last-reconcile.json" >/dev/null \
  || fail "an unavailable systemctl must report the job as not-scheduled"
grep -Fq 'not-scheduled job daily-inbox-digest' \
  "$TMP/systemctl-unavailable.err" \
  || fail "an unavailable systemctl must report the not-scheduled outcome: $(cat "$TMP/systemctl-unavailable.err")"
grep -Fq 'systemctl command is unavailable' "$TMP/systemctl-unavailable.err" \
  || fail "an unavailable systemctl must report its reason: $(cat "$TMP/systemctl-unavailable.err")"
! grep -Fq 'armed daily-inbox-digest' "$TMP/systemctl-unavailable.err" \
  || fail "an unavailable systemctl must not take the armed success path"
[ -f "$UNIT_DIR/hq-job-daily-inbox-digest.service" ] \
  && [ -f "$UNIT_DIR/hq-job-daily-inbox-digest.timer" ] \
  || fail "an unavailable systemctl must leave the generated unit files written"

# Start from an absent unit pair so failed-enable checks cover a write and then
# an idempotent reconcile separately.
rm -f "$UNIT_DIR/hq-job-daily-inbox-digest.service" "$UNIT_DIR/hq-job-daily-inbox-digest.timer"

# A failed user-bus probe must also be not-scheduled on write and no-op paths.
assert_enable_failure "enable-failure-write"
assert_enable_failure "enable-failure-noop"

# A missing user bus during the read-only manager probe must stop before enable.
export HQ_JOB_SYSTEMCTL_TEST_LOG="$TMP/systemctl-no-user-bus.log"
rc=0
HQ_JOB_SYSTEMCTL="$BIN/systemctl-no-user-bus" bash "$RECON" --hq-root "$HQ" --no-probe \
  >"$TMP/no-user-bus.out" 2>"$TMP/no-user-bus.err" || rc=$?
[ "$rc" -ne 0 ] || fail "a missing user bus must make reconcile report a scheduling failure"
jq -e '.errors == 1 and .armed == 0 and .skipped == 3' \
  "$HOME_DIR/.hq/jobs/reconcile/last-reconcile.json" >/dev/null \
  || fail "a missing user bus must be not-scheduled, not armed: $(cat "$HOME_DIR/.hq/jobs/reconcile/last-reconcile.json")"
grep -Fq 'not-scheduled job daily-inbox-digest reason=Failed to connect to bus: No medium found' \
  "$TMP/no-user-bus.err" || fail "a missing user bus must report not-scheduled and its reason"
grep -Fqx -- '--user show-environment' "$HQ_JOB_SYSTEMCTL_TEST_LOG" \
  || fail "a missing user bus must fail during the manager probe"
! grep -Fq -- '--user enable --now hq-job-daily-inbox-digest.timer' "$HQ_JOB_SYSTEMCTL_TEST_LOG" \
  || fail "a failed manager probe must prevent timer enablement"
[ -f "$UNIT_DIR/hq-job-daily-inbox-digest.service" ] \
  && [ -f "$UNIT_DIR/hq-job-daily-inbox-digest.timer" ] \
  || fail "a missing user bus must leave the generated unit files written"
pass "systemctl failures are reported and successful enables remain armed"

# feedback_6ce027d7: outpost-jobs-reconcile.service is a system unit with
# User=ec2-user, so it runs without XDG_RUNTIME_DIR / DBUS_SESSION_BUS_ADDRESS.
# This stub behaves like the real systemctl: without the user runtime env it
# cannot reach the user manager.
RUNTIME_BASE="$TMP/run-user"
TEST_UID="$(id -u)"
cat >"$BIN/systemctl-needs-user-env" <<'STUB'
#!/usr/bin/env bash
printf '%s|XDG=%s|DBUS=%s\n' "$*" "${XDG_RUNTIME_DIR:-}" "${DBUS_SESSION_BUS_ADDRESS:-}" >>"${HQ_JOB_SYSTEMCTL_TEST_LOG:?}"
if [ "${XDG_RUNTIME_DIR:-}" != "${HQ_TEST_EXPECT_XDG:?}" ] \
  || [ "${DBUS_SESSION_BUS_ADDRESS:-}" != "unix:path=${HQ_TEST_EXPECT_XDG}/bus" ]; then
  echo "Failed to connect to bus: No medium found" >&2
  exit 1
fi
exit 0
STUB
chmod +x "$BIN/systemctl-needs-user-env"

# Linger on: /run/user/<uid> and its bus exist → reconcile derives the env and arms.
mkdir -p "$RUNTIME_BASE/$TEST_UID"
: >"$RUNTIME_BASE/$TEST_UID/bus"
export HQ_JOB_SYSTEMCTL_TEST_LOG="$TMP/systemctl-user-env.log"
rc=0
env -u XDG_RUNTIME_DIR -u DBUS_SESSION_BUS_ADDRESS \
  HQ_TEST_EXPECT_XDG="$RUNTIME_BASE/$TEST_UID" HQ_JOB_USER_RUNTIME_BASE="$RUNTIME_BASE" \
  HQ_JOB_SYSTEMCTL="$BIN/systemctl-needs-user-env" \
  bash "$RECON" --hq-root "$HQ" --no-probe >"$TMP/user-env.out" 2>"$TMP/user-env.err" || rc=$?
[ "$rc" -eq 0 ] || fail "reconcile without a login session must derive the user bus env and succeed: $(cat "$TMP/user-env.err")"
jq -e '.errors == 0 and .armed == 1' "$HOME_DIR/.hq/jobs/reconcile/last-reconcile.json" >/dev/null \
  || fail "derived user bus env must arm the ready job: $(cat "$HOME_DIR/.hq/jobs/reconcile/last-reconcile.json")"
grep -Fq -- "--user enable --now hq-job-daily-inbox-digest.timer|XDG=$RUNTIME_BASE/$TEST_UID|DBUS=unix:path=$RUNTIME_BASE/$TEST_UID/bus" \
  "$HQ_JOB_SYSTEMCTL_TEST_LOG" || fail "systemctl --user enable must receive XDG_RUNTIME_DIR and DBUS_SESSION_BUS_ADDRESS"
grep -Fq "XDG_RUNTIME_DIR was unset; using $RUNTIME_BASE/$TEST_UID" "$TMP/user-env.err" \
  || fail "reconcile must log that it derived XDG_RUNTIME_DIR"

# A caller-provided XDG_RUNTIME_DIR is kept as-is.
mkdir -p "$TMP/caller-runtime"
: >"$TMP/caller-runtime/bus"
export HQ_JOB_SYSTEMCTL_TEST_LOG="$TMP/systemctl-caller-env.log"
rc=0
env -u DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR="$TMP/caller-runtime" \
  HQ_TEST_EXPECT_XDG="$TMP/caller-runtime" HQ_JOB_USER_RUNTIME_BASE="$RUNTIME_BASE" \
  HQ_JOB_SYSTEMCTL="$BIN/systemctl-needs-user-env" \
  bash "$RECON" --hq-root "$HQ" --no-probe >"$TMP/caller-env.out" 2>"$TMP/caller-env.err" || rc=$?
[ "$rc" -eq 0 ] || fail "an existing XDG_RUNTIME_DIR must be kept: $(cat "$TMP/caller-env.err")"
! grep -Fq 'XDG_RUNTIME_DIR was unset' "$TMP/caller-env.err" \
  || fail "reconcile must not override a caller-provided XDG_RUNTIME_DIR"

# Linger off: no /run/user/<uid> → not-scheduled, a linger hint, and a non-zero exit.
rm -rf "$RUNTIME_BASE"
export HQ_JOB_SYSTEMCTL_TEST_LOG="$TMP/systemctl-no-runtime.log"
rc=0
env -u XDG_RUNTIME_DIR -u DBUS_SESSION_BUS_ADDRESS \
  HQ_TEST_EXPECT_XDG="$RUNTIME_BASE/$TEST_UID" HQ_JOB_USER_RUNTIME_BASE="$RUNTIME_BASE" \
  HQ_JOB_SYSTEMCTL="$BIN/systemctl-needs-user-env" \
  bash "$RECON" --hq-root "$HQ" --no-probe >"$TMP/no-runtime.out" 2>"$TMP/no-runtime.err" || rc=$?
[ "$rc" -ne 0 ] || fail "a missing user runtime dir must make reconcile exit non-zero"
jq -e '.errors == 1 and .armed == 0' "$HOME_DIR/.hq/jobs/reconcile/last-reconcile.json" >/dev/null \
  || fail "a missing user runtime dir must report errors=1 armed=0"
grep -Fq 'enable linger: sudo loginctl enable-linger' "$TMP/no-runtime.err" \
  || fail "a missing user runtime dir must log the linger remedy: $(cat "$TMP/no-runtime.err")"
pass "reconcile derives the user bus env outside a login session (feedback_6ce027d7)"

# 1) Ready personal job → units written with Persistent + RandomizedDelaySec + OnCalendar
set +e
bash "$RECON" --hq-root "$HQ" --no-probe --dry-run >"$TMP/out1.json" 2>"$TMP/err1.txt"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "reconcile dry-run failed: $(cat "$TMP/err1.txt")"
[ -f "$UNIT_DIR/hq-job-daily-inbox-digest.service" ] || fail "service unit missing"
[ -f "$UNIT_DIR/hq-job-daily-inbox-digest.timer" ] || fail "timer unit missing"
grep -q 'Persistent=true' "$UNIT_DIR/hq-job-daily-inbox-digest.timer" || fail "Persistent=true missing"
grep -q 'RandomizedDelaySec=45' "$UNIT_DIR/hq-job-daily-inbox-digest.timer" || fail "RandomizedDelaySec missing"
# Characterization: guard the timezone rendering shipped in hq-core-staging#927.
timer_calendar="$(awk '
  /^\[Timer\]$/ { in_timer = 1; next }
  /^\[/ { in_timer = 0 }
  in_timer && /^OnCalendar=/ {
    count++
    value = substr($0, index($0, "=") + 1)
  }
  END {
    if (count != 1) exit 1
    print value
  }
' "$UNIT_DIR/hq-job-daily-inbox-digest.timer")" \
  || fail "timer must contain exactly one OnCalendar directive in its Timer section"
[ "$timer_calendar" = 'Mon..Fri *-*-* 09:00:00 America/New_York' ] \
  || fail "#927 timezone characterization expected OnCalendar in America/New_York, got: $timer_calendar"
! awk '
  /^\[Timer\]$/ { in_timer = 1; next }
  /^\[/ { in_timer = 0 }
  in_timer && /^Timezone=/ { found = 1 }
  END { exit !found }
' "$UNIT_DIR/hq-job-daily-inbox-digest.timer" \
  || fail "#927 timezone characterization must not contain an unsupported Timezone= directive"
grep -q 'hq-job-run.sh' "$UNIT_DIR/hq-job-daily-inbox-digest.service" || fail "service must ExecStart hq-job-run.sh"
grep -Fq "ExecStart=$HQ/core/scripts/hq-job-run.sh" "$UNIT_DIR/hq-job-daily-inbox-digest.service" \
  || fail "service runner must use the selected HQ root"
pass "ready personal job materializes service+timer, root path, and #927 timezone rendering"

# A job without a declared timezone uses the generated OnCalendar expression unchanged.
yq -i 'del(.timezone)' "$HQ/personal/jobs/digest.yaml"
bash "$RECON" --hq-root "$HQ" --no-probe --dry-run >"$TMP/no-zone.out" 2>"$TMP/no-zone.err"
grep -q '^OnCalendar=Mon..Fri \*-\*-\* 09:00:00$' "$UNIT_DIR/hq-job-daily-inbox-digest.timer" \
  || fail "OnCalendar must stay unchanged when no timezone is declared"
! grep -q '^Timezone=' "$UNIT_DIR/hq-job-daily-inbox-digest.timer" \
  || fail "timer without a timezone must not write a Timezone= directive"
pass "no declared timezone leaves OnCalendar unchanged"

# Newlines and other unsafe characters in a zone must not become unit-file keys.
yq -i '.timezone = "America/New_York\nPersistent=false"' "$HQ/personal/jobs/digest.yaml"
set +e
bash "$RECON" --hq-root "$HQ" --no-probe --dry-run >"$TMP/invalid-zone.out" 2>"$TMP/invalid-zone.err"
invalid_zone_rc=$?
set -e
[ "$invalid_zone_rc" -ne 0 ] || fail "unsafe timezone should fail reconcile"
grep -Fq 'invalid timezone' "$TMP/invalid-zone.err" || fail "unsafe timezone must have a clear log line"
[ ! -f "$UNIT_DIR/hq-job-daily-inbox-digest.timer" ] \
  || fail "unsafe timezone must not leave a generated timer"
pass "unsafe timezone is rejected without unit-file injection"

yq -i '.timezone = "America/New_York"' "$HQ/personal/jobs/digest.yaml"
bash "$RECON" --hq-root "$HQ" --no-probe --dry-run >"$TMP/restore-zone.out" 2>"$TMP/restore-zone.err"

# 2) Other-owner company job ignored; non-ready company job not armed
[ ! -f "$UNIT_DIR/hq-job-sentry-triage-indigo.timer" ] || fail "other-owner company job should not arm"
[ ! -f "$UNIT_DIR/hq-job-sentry-triage-mine.timer" ] || fail "pending_probe job should not arm"
grep -q "owner 'other@example.com' does not match" "$TMP/err1.txt" || fail "expected other-owner skip log"
grep -q 'readiness=pending_probe' "$TMP/err1.txt" || fail "expected pending_probe skip log"
pass "owner filter + readiness gate"

# 3) Disabled job → no units
[ ! -f "$UNIT_DIR/hq-job-disabled-job.timer" ] || fail "disabled job should not have timer"
pass "disabled job omitted"

# 4) Idempotent second run (no content change)
cp "$UNIT_DIR/hq-job-daily-inbox-digest.timer" "$TMP/timer.before"
bash "$RECON" --hq-root "$HQ" --no-probe --dry-run >"$TMP/out2.json" 2>"$TMP/err2.txt"
cmp -s "$TMP/timer.before" "$UNIT_DIR/hq-job-daily-inbox-digest.timer" || fail "second run mutated timer"
grep -q 'noop daily-inbox-digest' "$TMP/err2.txt" || fail "expected noop log on second run"
pass "idempotent second reconcile is noop"

# 5) Delete job from registry → units removed
rm -f "$HQ/personal/jobs/digest.yaml"
bash "$RECON" --hq-root "$HQ" --no-probe --dry-run >"$TMP/out3.json" 2>"$TMP/err3.txt"
[ ! -f "$UNIT_DIR/hq-job-daily-inbox-digest.timer" ] || fail "deleted job timer should be gone"
[ ! -f "$UNIT_DIR/hq-job-daily-inbox-digest.service" ] || fail "deleted job service should be gone"
grep -q 'orphaned\|deleted' "$TMP/err3.txt" || fail "expected orphan removal log"
pass "deleted registry job removes units"

# 6) Ready company job owned by box → arms
jq -nc '{job_id:"sentry-triage-mine",readiness:"ready",updated_at:"2026-08-23T19:00:00Z",source:"test"}' \
  >"$CACHE/sentry-triage-mine.json"
bash "$RECON" --hq-root "$HQ" --no-probe --dry-run >"$TMP/out4.json" 2>"$TMP/err4.txt"
[ -f "$UNIT_DIR/hq-job-sentry-triage-mine.timer" ] || fail "ready owned company job should arm"
grep -q 'America/Los_Angeles' "$UNIT_DIR/hq-job-sentry-triage-mine.timer" || fail "company job tz missing"
pass "ready company job on creator Outpost arms"

# 6b) feedback_6ce027d7: under the box's machine identity, `hq whoami --json`
# reports the owner only as delegatedEmail/delegatedSub. Company jobs owned by
# either value must match this box.
WHOAMI_BIN="$TMP/whoami-bin"
mkdir -p "$WHOAMI_BIN"
cat >"$WHOAMI_BIN/hq" <<'STUB'
#!/usr/bin/env bash
if [ "$*" = "whoami --json" ]; then
  printf '%s\n' '{"tokenSource":"machine","email":null,"sub":null,"delegatedEmail":"delegated@example.com","delegatedSub":"14c81468-c081-70b8-ca57-d29b4d522d44"}'
  exit 0
fi
exit 97
STUB
chmod +x "$WHOAMI_BIN/hq"
cp "$FIX_VALID/company-with-requirements.yaml" "$HQ/companies/indigo/jobs/delegated-email.yaml"
yq -i '.owner = "Delegated@example.com" | .id = "delegated-email-job"' "$HQ/companies/indigo/jobs/delegated-email.yaml"
cp "$FIX_VALID/company-with-requirements.yaml" "$HQ/companies/indigo/jobs/delegated-sub.yaml"
yq -i '.owner = "14c81468-c081-70b8-ca57-d29b4d522d44" | .id = "delegated-sub-job"' "$HQ/companies/indigo/jobs/delegated-sub.yaml"
for jid in delegated-email-job delegated-sub-job; do
  jq -nc --arg id "$jid" '{job_id:$id,readiness:"ready",updated_at:"2026-08-23T19:00:00Z",source:"test"}' >"$CACHE/$jid.json"
done
PATH="$WHOAMI_BIN:$PATH" bash "$RECON" --hq-root "$HQ" --no-probe --dry-run >"$TMP/delegated.out" 2>"$TMP/delegated.err"
[ -f "$UNIT_DIR/hq-job-delegated-email-job.timer" ] \
  || fail "company job owned by the delegated owner email should arm: $(cat "$TMP/delegated.err")"
[ -f "$UNIT_DIR/hq-job-delegated-sub-job.timer" ] \
  || fail "company job owned by the delegated owner Cognito id should arm: $(cat "$TMP/delegated.err")"
rm -f "$HQ/companies/indigo/jobs/delegated-email.yaml" "$HQ/companies/indigo/jobs/delegated-sub.yaml"
bash "$RECON" --hq-root "$HQ" --no-probe --dry-run >/dev/null 2>&1
pass "company jobs match the delegated Outpost owner by email or Cognito id"

# 7) --ensure-hook installs Stop hook
bash "$RECON" --hq-root "$HQ" --ensure-hook --no-probe --dry-run >/dev/null 2>"$TMP/err5.txt"
[ -f "$HQ/personal/hooks/Stop/90-outpost-jobs-reconcile.sh" ] || fail "Stop hook not installed"
grep -q 'outpost-jobs-reconcile.sh' "$HQ/personal/hooks/Stop/90-outpost-jobs-reconcile.sh" || fail "hook content wrong"
pass "ensure-hook installs personal/hooks/Stop reconciler"

# 7b) The Stop hook surfaces a failed reconcile instead of swallowing it
# (feedback_6ce027d7), and still does not fail the sync cycle.
HOOK_ROOT="$TMP/hook-root"
mkdir -p "$HOOK_ROOT/core/scripts" "$HOME_DIR/.hq/jobs/reconcile"
printf '#!/usr/bin/env bash\necho "done armed=0 errors=23" >&2\nexit 1\n' >"$HOOK_ROOT/core/scripts/outpost-jobs-reconcile.sh"
rc=0
OUTPOST_HQ_ROOT="$HOOK_ROOT" bash "$HQ/personal/hooks/Stop/90-outpost-jobs-reconcile.sh" \
  >"$TMP/hook.out" 2>"$TMP/hook.err" || rc=$?
[ "$rc" -eq 0 ] || fail "Stop hook must not fail the sync cycle"
grep -Fq 'after-sync reconcile reported errors' "$TMP/hook.err" \
  || fail "Stop hook must warn on stderr when reconcile fails"
grep -Fq 'after-sync reconcile reported errors' "$HOME_DIR/.hq/jobs/reconcile/after-sync.log" \
  || fail "Stop hook must record the failure in after-sync.log"
printf '#!/usr/bin/env bash\nexit 0\n' >"$HOOK_ROOT/core/scripts/outpost-jobs-reconcile.sh"
OUTPOST_HQ_ROOT="$HOOK_ROOT" bash "$HQ/personal/hooks/Stop/90-outpost-jobs-reconcile.sh" \
  >"$TMP/hook-ok.out" 2>"$TMP/hook-ok.err"
[ ! -s "$TMP/hook-ok.err" ] || fail "Stop hook must stay quiet on success: $(cat "$TMP/hook-ok.err")"
pass "Stop hook warns on reconcile errors without failing sync"

# 8) Blocked readiness removes previously armed timer
# Re-arm digest
cp "$FIX_VALID/personal-daily-digest.yaml" "$HQ/personal/jobs/digest.yaml"
yq -i '.owner = "owner@example.com"' "$HQ/personal/jobs/digest.yaml"
jq -nc '{job_id:"daily-inbox-digest",readiness:"ready",updated_at:"2026-08-23T18:00:00Z",source:"test"}' \
  >"$CACHE/daily-inbox-digest.json"
bash "$RECON" --hq-root "$HQ" --no-probe --dry-run >/dev/null 2>&1
[ -f "$UNIT_DIR/hq-job-daily-inbox-digest.timer" ] || fail "setup arm failed"
jq -nc '{job_id:"daily-inbox-digest",readiness:"blocked",updated_at:"2026-08-23T20:00:00Z",source:"test"}' \
  >"$CACHE/daily-inbox-digest.json"
bash "$RECON" --hq-root "$HQ" --no-probe --dry-run >"$TMP/out6.json" 2>"$TMP/err6.txt"
[ ! -f "$UNIT_DIR/hq-job-daily-inbox-digest.timer" ] || fail "blocked job should stop/remove timer"
grep -q 'non-ready\|readiness=blocked' "$TMP/err6.txt" || fail "expected blocked skip log"
pass "blocked readiness stops timer"

echo "ALL PASSED (outpost-jobs-reconcile)"
