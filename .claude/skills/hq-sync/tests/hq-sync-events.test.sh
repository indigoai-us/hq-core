#!/usr/bin/env bash
# hq-core: public
# /hq-sync event handling — partial reporting (P2), conflict residue (P3),
# and the auth path (P1). Feeds recorded ndjson fixtures through
# `.claude/skills/hq-sync/scripts/hq-sync-events.sh`. Never spawns a runner and
# never touches the vault.
set -euo pipefail

HQ_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
LIB="$HQ_SRC/.claude/skills/hq-sync/scripts/hq-sync-events.sh"

pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { pass=$((pass+1)); printf '  ok %s\n' "$1"; }

[ -f "$LIB" ] || fail "library not found at $LIB"
command -v jq >/dev/null || fail "jq required"

# shellcheck source=/dev/null
. "$LIB"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# (a) all-complete with partial=true lists the non-complete companies and the
#     helper reports the documented partial exit code.
# ---------------------------------------------------------------------------
out="$TMP/partial.ndjson"
cat > "$out" <<'NDJSON'
{"type":"fanout-plan","companies":[{"slug":"acme"},{"slug":"northwind"},{"slug":"meridian"}]}
{"type":"complete","company":"acme","filesDownloaded":4,"filesUploaded":1,"conflicts":0}
{"type":"all-complete","companiesAttempted":3,"filesDownloaded":4,"bytesDownloaded":900,"filesUploaded":1,"bytesUploaded":30,"conflictPaths":[],"errors":[],"transient":[{"company":"meridian","message":"ETIMEDOUT reaching vault"}],"partial":true,"companies":[{"company":"acme","status":"complete","filesDownloaded":4,"bytesDownloaded":900,"filesUploaded":1,"bytesUploaded":30},{"company":"northwind","status":"aborted","filesDownloaded":0,"bytesDownloaded":0,"filesUploaded":0,"bytesUploaded":0},{"company":"meridian","status":"transient-network","filesDownloaded":0,"bytesDownloaded":0,"filesUploaded":0,"bytesUploaded":0}]}
NDJSON

rc=0
summary="$(hq_sync_report_summary "$out")" || rc=$?
[ "$rc" = "3" ] || fail "(a) partial run should return 3, got $rc"
[ "$rc" = "$HQ_SYNC_PARTIAL_EXIT" ] || fail "(a) return code should be HQ_SYNC_PARTIAL_EXIT"
printf '%s' "$summary" | grep -q "northwind: aborted" \
  || fail "(a) expected the aborted company and its status; got: $summary"
printf '%s' "$summary" | grep -q "meridian: transient-network" \
  || fail "(a) expected the transient-network company and its status"
if printf '%s' "$summary" | grep -q "acme: complete"; then
  fail "(a) a completed company must not be listed as not finished"
fi
printf '%s' "$summary" | grep -q "ETIMEDOUT reaching vault" \
  || fail "(a) expected the transient[] diagnostic to be surfaced"
ok "partial=true lists every non-complete company and exits non-zero"

# A clean run must stay quiet and return 0.
clean="$TMP/clean.ndjson"
cat > "$clean" <<'NDJSON'
{"type":"all-complete","companiesAttempted":1,"filesDownloaded":2,"bytesDownloaded":10,"filesUploaded":0,"bytesUploaded":0,"conflictPaths":[],"errors":[],"transient":[],"partial":false,"companies":[{"company":"acme","status":"complete","filesDownloaded":2,"bytesDownloaded":10,"filesUploaded":0,"bytesUploaded":0}]}
NDJSON
rc=0
clean_out="$(hq_sync_report_summary "$clean")" || rc=$?
[ "$rc" = "0" ] || fail "(a) a clean run should return 0, got $rc"
if printf '%s' "$clean_out" | grep -q "This sync did not finish"; then
  fail "(a) a clean run must not print the partial block"
fi
ok "partial=false returns 0 and prints no partial block"

# Exit code 75 maps to the plain retry message.
note="$(hq_sync_exit_note 75)"
printf '%s' "$note" | grep -q "The network interrupted the sync. Nothing is corrupt. Run /hq-sync again." \
  || fail "(a) exit 75 should map to the plain retry message; got: $note"
[ -z "$(hq_sync_exit_note 0)" ] || fail "(a) exit 0 should print nothing"
ok "runner exit 75 maps to a plain retry message"

# ---------------------------------------------------------------------------
# (b) conflicts-remaining plus on-disk twins produce the doctor command.
# ---------------------------------------------------------------------------
root="$TMP/hq"
mkdir -p "$root/tenants/acme/policies" "$root/node_modules/pkg" \
  "$root/workspace/tmp" "$root/.git"
: > "$root/tenants/acme/policies/a.md.conflict-1750000000-macbook"
: > "$root/tenants/acme/policies/b.md.conflict-1750000001-macbook"
# Excluded locations must not inflate the count.
: > "$root/node_modules/pkg/x.js.conflict-1750000002-macbook"
: > "$root/workspace/tmp/scratch.md.conflict-1750000003-macbook"
: > "$root/.git/HEAD.conflict-1750000004-macbook"

twins="$(hq_sync_count_conflict_twins "$root")"
[ "$twins" = "2" ] || fail "(b) expected 2 twins outside excluded dirs, got $twins"

conf="$TMP/conflicts.ndjson"
cat > "$conf" <<'NDJSON'
{"type":"all-complete","companiesAttempted":1,"filesDownloaded":0,"bytesDownloaded":0,"filesUploaded":0,"bytesUploaded":0,"conflictPaths":[],"errors":[],"transient":[],"partial":false,"companies":[{"company":"acme","status":"complete","filesDownloaded":0,"bytesDownloaded":0,"filesUploaded":0,"bytesUploaded":0}]}
{"type":"conflicts-remaining","count":20,"samplePaths":["tenants/acme/policies/a.md","tenants/acme/policies/b.md"]}
NDJSON

report="$(hq_sync_report_conflicts_remaining "$conf" "$root")"
printf '%s' "$report" | grep -q "20 conflict entr" \
  || fail "(b) expected the ledger count from conflicts-remaining; got: $report"
printf '%s' "$report" | grep -q "tenants/acme/policies/a.md" \
  || fail "(b) expected a sample path from conflicts-remaining"
printf '%s' "$report" | grep -q "/resolve-conflicts" \
  || fail "(b) expected the existing /resolve-conflicts pointer"
printf '%s' "$report" | grep -q "2 .conflict-\* twin file" \
  || fail "(b) expected the on-disk twin count; got: $report"
printf '%s' "$report" | grep -qF "hq sync doctor --reconcile-conflicts --hq-root $root" \
  || fail "(b) expected the exact doctor dry-run command; got: $report"
ok "conflicts-remaining plus on-disk twins produce the doctor command"

# Twins with no conflicts-remaining event still surface the doctor command.
quiet="$TMP/quiet.ndjson"
: > "$quiet"
report="$(hq_sync_report_conflicts_remaining "$quiet" "$root")"
printf '%s' "$report" | grep -qF "hq sync doctor --reconcile-conflicts --hq-root $root" \
  || fail "(b) twins alone should still produce the doctor command"
ok "on-disk twins alone still produce the doctor command"

# A clean tree prints nothing.
clean_root="$TMP/clean-hq"
mkdir -p "$clean_root"
[ -z "$(hq_sync_report_conflicts_remaining "$quiet" "$clean_root")" ] \
  || fail "(b) a clean tree with no event must print nothing"
ok "no conflicts means no conflict output"

# ---------------------------------------------------------------------------
# (c) a token file with an ISO-string expiresAt does not abort the script.
#     The skill only checks that the file exists; the runner owns validity.
# ---------------------------------------------------------------------------
fake_home="$TMP/home"
mkdir -p "$fake_home/.hq"
cat > "$fake_home/.hq/cognito-tokens.json" <<'JSON'
{"expiresAt":"2026-09-17T18:04:00.000Z"}
JSON

# The auth gate, transcribed from SKILL.md Step 2. An ISO-string expiresAt used
# to reach `[ "$expires_ms" -le "$now_ms" ]` and kill the script under `set -e`.
auth_probe="$TMP/auth-probe.sh"
cat > "$auth_probe" <<'PROBE'
#!/usr/bin/env bash
set -euo pipefail
if [ ! -f "$HOME/.hq/cognito-tokens.json" ]; then
  echo "Not signed in — run /hq-login" >&2
  exit 2
fi
echo "auth-gate-passed"
PROBE
chmod +x "$auth_probe"

rc=0
probe_out="$(HOME="$fake_home" "$auth_probe" 2>&1)" || rc=$?
[ "$rc" = "0" ] || fail "(c) ISO-string expiresAt must not abort the script, got exit $rc: $probe_out"
printf '%s' "$probe_out" | grep -q "auth-gate-passed" \
  || fail "(c) expected the auth gate to pass through"
ok "ISO-string expiresAt does not abort the script"

# The skill must no longer do expiry arithmetic of its own.
SKILL="$HQ_SRC/.claude/skills/hq-sync/SKILL.md"
[ -f "$SKILL" ] || fail "(c) SKILL.md not found at $SKILL"
# `expiresAt` may still appear in prose explaining WHY the skill ignores it.
# What must be gone is the code that reads and compares it.
if grep -q "jq -r '\.expiresAt" "$SKILL"; then
  fail "(c) SKILL.md still reads expiresAt out of the token file"
fi
if grep -q "now_ms" "$SKILL"; then
  fail "(c) SKILL.md still computes token expiry"
fi
if grep -q "cognito-tokens.json\"" "$SKILL" && grep -qE '\$\(date \+%s\)' "$SKILL"; then
  fail "(c) SKILL.md still does clock arithmetic against the token file"
fi
ok "SKILL.md no longer does its own token-expiry arithmetic"

# A missing token file still stops the run with exit 2.
empty_home="$TMP/empty-home"
mkdir -p "$empty_home"
rc=0
probe_out="$(HOME="$empty_home" "$auth_probe" 2>&1)" || rc=$?
[ "$rc" = "2" ] || fail "(c) a missing token file should exit 2, got $rc"
printf '%s' "$probe_out" | grep -q "Not signed in — run /hq-login" \
  || fail "(c) expected the sign-in message"
ok "missing token file exits 2 with the sign-in message"

# ---------------------------------------------------------------------------
# (d) an auth-error line on stderr yields the sign-in message and exit 2.
# ---------------------------------------------------------------------------
err="$TMP/stderr.ndjson"
cat > "$err" <<'NDJSON'
{"type":"error","diagnostic":true,"component":"vault","event":"probe","path":"(vault)","message":"warming up"}
{"type":"auth-error","message":"no valid token available"}
NDJSON

hq_sync_has_auth_error "$err" || fail "(d) auth-error on stderr should be detected"

auth_runner="$TMP/auth-runner.sh"
cat > "$auth_runner" <<PROBE
#!/usr/bin/env bash
set -euo pipefail
. "$LIB"
if hq_sync_has_auth_error "$err"; then
  hq_sync_print_auth_error
  exit 2
fi
echo "no-auth-error"
PROBE
chmod +x "$auth_runner"
rc=0
probe_out="$("$auth_runner" 2>&1)" || rc=$?
[ "$rc" = "2" ] || fail "(d) auth-error should exit 2, got $rc"
printf '%s' "$probe_out" | grep -q "Not signed in — run /hq-login" \
  || fail "(d) expected the sign-in message; got: $probe_out"
ok "auth-error yields the sign-in message and exit 2"

# Ordinary diagnostics on stderr are not an auth error.
plain_err="$TMP/plain-stderr.ndjson"
cat > "$plain_err" <<'NDJSON'
{"type":"error","message":"one file failed","path":"tenants/acme/x.md"}
NDJSON
if hq_sync_has_auth_error "$plain_err"; then
  fail "(d) a plain error event must not be read as an auth error"
fi
ok "a plain error event is not treated as an auth error"

echo ""
echo "PASS ($pass assertions)"
