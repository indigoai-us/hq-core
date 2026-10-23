#!/usr/bin/env bash
# hq-core: public
# Regression (feedback 249): a scheduled run that would launch in a permission
# mode that can stop for approval (anything but bypassPermissions/dontAsk) is refused before launch, marked
# blocked, and the owner is notified. The job's company is bound to a pre-minted
# session before the agent starts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RUN="$ROOT/core/scripts/hq-job-run.sh"

command -v yq >/dev/null 2>&1 || { echo "SKIP: yq not available"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hq-job-run-approval.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

HQ="$TMP/hqroot"
HOME_DIR="$TMP/home"
BIN="$TMP/bin"
mkdir -p "$HQ/personal/jobs" "$HQ/companies/initech-test" "$HQ/.claude" \
  "$HOME_DIR/.claude" "$HOME_DIR/.hq/jobs" "$BIN"
printf '{"claudeAiOauth":{"accessToken":"x"}}\n' >"$HOME_DIR/.claude/.credentials.json"
export HOME="$HOME_DIR" HQ_ROOT="$HQ" PATH="$BIN:$PATH"

cat >"$BIN/claude" <<'STUB'
#!/usr/bin/env bash
echo "claude-stub: $* HQ_SESSION_ID=${HQ_SESSION_ID:-}" >>"$HQ_STUB_LOG"
echo OK
STUB
cat >"$BIN/notify" <<'STUB'
#!/usr/bin/env bash
echo "notify: $*" >>"$HQ_STUB_LOG"
STUB
cat >"$BIN/session" <<'STUB'
#!/usr/bin/env bash
echo "session: $*" >>"$HQ_STUB_LOG"
[ "${HQ_STUB_SESSION_FAIL:-0}" = 1 ] && exit 1
exit 0
STUB
chmod +x "$BIN/claude" "$BIN/notify" "$BIN/session"

cat >"$HQ/personal/jobs/job.yaml" <<'YAML'
id: approval-job
name: Approval job
schedule: "0 9 * * *"
runtime: claude
exec:
  prompt: "Reply OK."
cwd: personal
timeout_seconds: 120
notify: dm
owner: owner@example.com
requirements:
  runtime: claude
  company: initech-test
  secrets: []
YAML

export HQ_STUB_LOG="$TMP/stub.log"
export HQ_JOB_LOCK="$HOME_DIR/.hq/jobs/run.lock"
export HQ_JOB_LOG_DIR="$HOME_DIR/.hq/jobs/logs"
export HQ_JOB_METER_DIR="$HOME_DIR/.hq/jobs/meters"
export HQ_JOB_MANAGED_SETTINGS="$TMP/managed-settings.json"
export HQ_JOB_NOTIFY_BIN="$BIN/notify"
export HQ_JOB_SESSION_BIN="$BIN/session"
export HQ_JOB_RUN_NO_INGEST=1
export HQ_JOB_FLOCK_BIN=true
export HQ_JOB_PROBE_CLAUDE_CRED="$HOME_DIR/.claude/.credentials.json"

run_job() {
  : >"$HQ_STUB_LOG"
  rm -rf "$HQ_JOB_LOG_DIR"
  bash "$RUN" --hq-root "$HQ" --job-id approval-job >"$TMP/out" 2>&1 || fail "runner exited non-zero: $(cat "$TMP/out")"
}
status_file() { ls "$HQ_JOB_LOG_DIR"/approval-job/*.status; }

# 1) Bypass disabled by managed settings, project default plan -> blocked.
printf '{"permissions":{"disableBypassPermissionsMode":"disable"}}\n' >"$HQ_JOB_MANAGED_SETTINGS"
printf '{"permissions":{"defaultMode":"plan"}}\n' >"$HQ/.claude/settings.json"
run_job
grep -q 'claude-stub' "$HQ_STUB_LOG" && fail "agent launched despite plan mode"
grep -q 'blocked=permission_mode' "$(status_file)" || fail "status not marked blocked"
grep -q -- "--outcome blocked" "$HQ_STUB_LOG" || fail "owner not notified with outcome blocked"
grep -q "permission mode 'plan'" "$HQ_STUB_LOG" || fail "notify reason missing resolved mode"
grep -q -- "--owner owner@example.com" "$HQ_STUB_LOG" || fail "notify not addressed to owner"
pass "plan mode (bypass disabled) refuses launch, marks blocked, notifies owner"

# 2) Bypass disabled, no defaultMode anywhere -> default prompting -> blocked.
rm -f "$HQ/.claude/settings.json"
run_job
grep -q 'claude-stub' "$HQ_STUB_LOG" && fail "agent launched despite default mode"
grep -q "permission mode 'default'" "$HQ_STUB_LOG" || fail "default mode not reported"
pass "default prompting mode refuses launch"

# 2b) Bypass disabled, defaultMode acceptEdits -> still prompts for Bash -> blocked.
printf '{"permissions":{"disableBypassPermissionsMode":"disable"}}\n' >"$HQ_JOB_MANAGED_SETTINGS"
printf '{"permissions":{"defaultMode":"acceptEdits"}}\n' >"$HQ/.claude/settings.json"
run_job
grep -q 'claude-stub' "$HQ_STUB_LOG" && fail "agent launched despite acceptEdits mode"
grep -q 'blocked=permission_mode' "$(status_file)" || fail "acceptEdits status not marked blocked"
grep -q -- "--outcome blocked" "$HQ_STUB_LOG" || fail "owner not notified for acceptEdits"
grep -q "permission mode 'acceptEdits'" "$HQ_STUB_LOG" || fail "acceptEdits mode not reported"
pass "acceptEdits (bypass disabled) refuses launch and notifies"

# 2c) Unrecognized mode -> fail closed.
printf '{"permissions":{"defaultMode":"someFutureMode"}}\n' >"$HQ/.claude/settings.json"
run_job
grep -q 'claude-stub' "$HQ_STUB_LOG" && fail "agent launched with unrecognized mode"
grep -q 'blocked=permission_mode' "$(status_file)" || fail "unknown mode not marked blocked"
grep -q -- "--outcome blocked" "$HQ_STUB_LOG" || fail "owner not notified for unknown mode"
pass "unrecognized mode fails closed"

# 2d) dontAsk is non-prompting -> launches.
printf '{"permissions":{"defaultMode":"dontAsk"}}\n' >"$HQ/.claude/settings.json"
run_job
grep -q 'claude-stub' "$HQ_STUB_LOG" || fail "agent did not launch in dontAsk mode"
grep -rq 'permission_note=dontAsk' "$HQ_JOB_LOG_DIR" || fail "dontAsk run not noted in the job log"
pass "dontAsk launches and notes the mode in the log"

# 2d2) auto can fall back to asking -> refused when bypass is disabled.
printf '{"permissions":{"defaultMode":"auto"}}\n' >"$HQ/.claude/settings.json"
run_job
grep -q 'claude-stub' "$HQ_STUB_LOG" && fail "agent launched despite auto mode"
grep -q "permission mode 'auto'" "$HQ_STUB_LOG" || fail "auto mode not reported"
pass "auto (bypass disabled) refuses launch"

# 2e) Unparseable settings file is logged, not silently skipped.
printf '{not json\n' >"$HQ/.claude/settings.local.json"
run_job
grep -rq 'settings_unparseable=.*settings.local.json' "$HQ_JOB_LOG_DIR" || fail "unparseable settings not logged"
rm -f "$HQ/.claude/settings.local.json"
pass "unparseable settings file is logged"

# 3) Bypass allowed (interactive defaultMode plan untouched) -> runs, company bound first.
rm -f "$HQ_JOB_MANAGED_SETTINGS"
printf '{"permissions":{"defaultMode":"plan"}}\n' >"$HQ/.claude/settings.json"
run_job
grep -q 'claude-stub' "$HQ_STUB_LOG" || fail "agent did not launch when bypass is allowed"
sline="$(grep -n '^session:' "$HQ_STUB_LOG" | head -1 | cut -d: -f1)"
cline="$(grep -n '^claude-stub' "$HQ_STUB_LOG" | head -1 | cut -d: -f1)"
[ -n "$sline" ] && [ "$sline" -lt "$cline" ] || fail "company not bound before agent start"
sid="$(sed -n 's/^session: --session-id \([^ ]*\) set company_slug initech-test$/\1/p' "$HQ_STUB_LOG")"
[ -n "$sid" ] || fail "session bind call shape wrong: $(cat "$HQ_STUB_LOG")"
grep -q -- "--session-id $sid .*HQ_SESSION_ID=$sid" "$HQ_STUB_LOG" || fail "agent not launched under the bound session id"
grep -q -- '--outcome blocked' "$HQ_STUB_LOG" && fail "unexpected blocked notify"
pass "bypass allowed: company bound to pre-minted session, agent runs under it"

# 4) Company bind fails -> blocked, agent not started.
export HQ_STUB_SESSION_FAIL=1
run_job
grep -q 'claude-stub' "$HQ_STUB_LOG" && fail "agent launched after failed company bind"
grep -q 'blocked=company_bind' "$(status_file)" || fail "company bind failure not marked blocked"
grep -q -- "--outcome blocked" "$HQ_STUB_LOG" || fail "owner not notified on bind failure"
pass "company bind failure refuses launch and notifies"

echo "ALL PASSED (hq-job-run-approval-mode)"
