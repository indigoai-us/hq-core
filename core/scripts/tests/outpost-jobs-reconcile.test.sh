#!/usr/bin/env bash
# hq-core: public
# Regression: outpost-jobs-reconcile.sh units, readiness gate, owner filter, idempotency (US-004).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RECON="$ROOT/core/scripts/outpost-jobs-reconcile.sh"
FIX_VALID="$ROOT/core/scripts/tests/fixtures/jobs/valid"

command -v yq >/dev/null 2>&1 || { echo "SKIP: yq not available"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }
[ -f "$RECON" ] || { echo "FAIL: missing $RECON" >&2; exit 1; }
[ -x "$RECON" ] || chmod +x "$RECON"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hq-job-recon-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

HQ="$TMP/hqroot"
HOME_DIR="$TMP/home"
UNIT_DIR="$TMP/units"
CACHE="$TMP/status-cache"
BIN="$TMP/bin"
mkdir -p "$HQ/personal/jobs" "$HQ/companies/indigo/jobs" "$HQ/companies/indigo/projects/outpost-scheduled-jobs"
mkdir -p "$HOME_DIR" "$UNIT_DIR" "$CACHE" "$BIN" "$HOME_DIR/.hq/jobs/reconcile"
export HOME="$HOME_DIR"
export HQ_ROOT="$HQ"
export PATH="$BIN:$PATH"
export HQ_JOB_UNIT_DIR="$UNIT_DIR"
export HQ_JOB_STATUS_CACHE_DIR="$CACHE"
export HQ_JOB_SYSTEMCTL=":"
export HQ_JOB_OWNER_EMAIL="owner@example.com"
export HQ_JOB_OWNER_UID="prs_owner"
export HQ_JOB_RANDOMIZE_SEC=45

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
grep -q 'Timezone=America/New_York' "$UNIT_DIR/hq-job-daily-inbox-digest.timer" || fail "Timezone missing"
grep -q 'OnCalendar=' "$UNIT_DIR/hq-job-daily-inbox-digest.timer" || fail "OnCalendar missing"
grep -q 'Mon..Fri' "$UNIT_DIR/hq-job-daily-inbox-digest.timer" || fail "weekday OnCalendar expected for 1-5"
grep -q 'hq-job-run.sh' "$UNIT_DIR/hq-job-daily-inbox-digest.service" || fail "service must ExecStart hq-job-run.sh"
pass "ready personal job materializes service+timer"

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

# 7) --ensure-hook installs Stop hook
bash "$RECON" --hq-root "$HQ" --ensure-hook --no-probe --dry-run >/dev/null 2>"$TMP/err5.txt"
[ -f "$HQ/personal/hooks/Stop/90-outpost-jobs-reconcile.sh" ] || fail "Stop hook not installed"
grep -q 'outpost-jobs-reconcile.sh' "$HQ/personal/hooks/Stop/90-outpost-jobs-reconcile.sh" || fail "hook content wrong"
pass "ensure-hook installs personal/hooks/Stop reconciler"

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
