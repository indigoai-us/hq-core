#!/usr/bin/env bash
# hq-core: public
# Integration: hq-job-run.sh classify → remediate → ingest → notify (US-006).
#
# Covers ACs / e2e-shaped cases:
#   - exit 0 → one ok dm + run ingest failure_class null
#   - 3 consecutive agent_error → exactly one failure dm
#   - auth failure (CLI logged out) → no device-login loop; dm names re-login
#   - trust: only requirements.secrets[] via hq secrets exec --only
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RUN="$ROOT/core/scripts/hq-job-run.sh"

command -v yq >/dev/null 2>&1 || { echo "SKIP: yq not available"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }
[ -f "$RUN" ] || { echo "FAIL: missing $RUN" >&2; exit 1; }
[ -x "$RUN" ] || chmod +x "$RUN"
chmod +x "$ROOT/core/scripts/hq-job-notify.sh" "$ROOT/core/scripts/hq-job-remediate.sh" 2>/dev/null || true

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hq-job-alerts-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

HQ="$TMP/hqroot"
HOME_DIR="$TMP/home"
BIN="$TMP/bin"
mkdir -p "$HQ/personal/jobs" "$HQ/personal/settings" "$HQ/personal"
mkdir -p "$HOME_DIR/.claude" "$HOME_DIR/.codex" "$HOME_DIR/.hq/jobs" "$BIN"
export HOME="$HOME_DIR"
export HQ_ROOT="$HQ"
export PATH="$BIN:$PATH"

export HQ_STUB_LOG="$TMP/stub.log"
export HQ_DM_LOG="$TMP/dm.log"
export HQ_CURL_LOG="$TMP/curl.log"
: >"$HQ_STUB_LOG"
: >"$HQ_DM_LOG"
: >"$HQ_CURL_LOG"

export HQ_JOB_LOCK="$HOME_DIR/.hq/jobs/run.lock"
export HQ_JOB_LOG_DIR="$HOME_DIR/.hq/jobs/logs"
export HQ_JOB_METER_DIR="$HOME_DIR/.hq/jobs/meters"
export HQ_JOB_ALERT_DIR="$HOME_DIR/.hq/jobs/alerts"
export HQ_JOB_NOW="2026-08-23T18:00:00Z"
export HQ_JOB_NOTIFY_COLLAPSE_SEC=86400
export HQ_JOB_NOTIFY_NOW_EPOCH=2000000
export OUTPOST_USER_ID="user-sub-1"
export OUTPOST_INSTANCE_TOKEN="tok-1"
export OUTPOST_ID="box-1"
export HQ_PRO_API_URL="https://hqapi.test"
export HQ_JOB_RUN_CURL="$BIN/curl"
export HQ_JOB_REMEDIATE_AUTH_REFRESH_CMD="$BIN/auth-refresh.sh"
export HQ_JOB_REMEDIATE_SYNC_PULL_CMD="$BIN/sync-pull.sh"

cat >"$HQ/personal/settings/schedule-alerts.yaml" <<'YAML'
channel: dm
updated_at: "2026-08-23T18:00:00Z"
YAML

cat >"$HQ/personal/jobs/digest.yaml" <<'YAML'
id: alert-digest
name: Alert digest
schedule: "0 9 * * *"
timezone: UTC
runtime: claude
exec:
  prompt: "Reply OK"
cwd: personal
timeout_seconds: 120
notify: profile
enabled: true
owner: owner@example.com
created_at: "2026-08-23T14:00:00Z"
requirements:
  runtime: claude
  secrets:
    - SENTRY_API_TOKEN
YAML

# --- stubs ---
cat >"$BIN/claude" <<'STUB'
#!/usr/bin/env bash
echo "claude-stub ok"
exit "${HQ_CLAUDE_EXIT:-0}"
STUB
chmod +x "$BIN/claude"

cat >"$BIN/auth-refresh.sh" <<'STUB'
#!/usr/bin/env bash
echo "auth-refresh" >>"${HQ_STUB_LOG}"
exit 0
STUB
chmod +x "$BIN/auth-refresh.sh"

cat >"$BIN/sync-pull.sh" <<'STUB'
#!/usr/bin/env bash
echo "sync-pull" >>"${HQ_STUB_LOG}"
exit 0
STUB
chmod +x "$BIN/sync-pull.sh"

cat >"$BIN/hq" <<'STUB'
#!/usr/bin/env bash
echo "hq: $*" >>"${HQ_STUB_LOG}"
if [ "${1:-}" = "secrets" ]; then
  shift
  only=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --company) shift 2 ;;
      --personal) shift ;;
      exec) shift ;;
      --only) only="${2:-}"; shift 2 ;;
      --script) shift 2 ;;
      --) shift; break ;;
      *) shift ;;
    esac
  done
  echo "hq-secrets-exec only=$only" >>"${HQ_STUB_LOG}"
  exec "$@"
fi
if [ "${1:-}" = "dm" ]; then
  recipient="$2"
  headline="$3"
  details=""
  shift 3 || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --details) details="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  printf 'recipient=%s\nheadline=%s\ndetails=%s\n---\n' \
    "$recipient" "$headline" "$details" >>"${HQ_DM_LOG}"
  exit 0
fi
if [ "${1:-}" = "auth" ] && [ "${2:-}" = "refresh" ]; then
  echo "hq-auth-refresh" >>"${HQ_STUB_LOG}"
  exit 0
fi
exit 0
STUB
chmod +x "$BIN/hq"

cat >"$BIN/curl" <<'STUB'
#!/usr/bin/env bash
out="/dev/null"
hdr="/dev/null"
data=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="${2:-}"; shift 2 ;;
    -D) hdr="${2:-}"; shift 2 ;;
    --data|-d) data="${2:-}"; shift 2 ;;
    -H) shift 2 ;;
    -sS|-s|-S) shift ;;
    -m) shift 2 ;;
    -X) shift 2 ;;
    http*|https*) shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "$data" >>"${HQ_CURL_LOG}"
printf 'HTTP/1.1 200 OK\r\n\r\n' >"$hdr"
echo '{"ok":true}' >"$out"
exit 0
STUB
chmod +x "$BIN/curl"

# ---------- 1) exit 0 → one ok dm + ingest null failure_class ----------
echo '{"token":"x"}' >"$HOME_DIR/.claude/.credentials.json"
: >"$HQ_DM_LOG"
: >"$HQ_CURL_LOG"
: >"$HQ_STUB_LOG"
export HQ_CLAUDE_EXIT=0
bash "$RUN" --hq-root "$HQ" --job-id alert-digest
grep -c '^recipient=' "$HQ_DM_LOG" | grep -qx 1 || fail "expected exactly one ok dm"
grep -qi 'ok' "$HQ_DM_LOG" || fail "ok dm missing ok"
grep -q '"kind":"run"' "$HQ_CURL_LOG" || fail "expected run ingest"
# failure_class null on success
grep -q '"failure_class":null' "$HQ_CURL_LOG" || fail "success ingest should clear failure_class"
# trust 7A: only declared secret
grep -q 'hq-secrets-exec only=SENTRY_API_TOKEN' "$HQ_STUB_LOG" || fail "expected secrets allowlist only"
pass "exit 0 → one ok dm + failure_class null ingest"

# ---------- 2) three consecutive agent_error → exactly one failure dm ----------
# Reset alert state so prior ok doesn't confuse; start fresh job id via new yaml
cat >"$HQ/personal/jobs/failing.yaml" <<'YAML'
id: alert-failing
name: Failing job
schedule: "0 9 * * *"
timezone: UTC
runtime: claude
exec:
  prompt: "fail please"
cwd: personal
timeout_seconds: 120
notify: profile
enabled: true
owner: owner@example.com
created_at: "2026-08-23T14:00:00Z"
requirements:
  runtime: claude
  secrets: []
YAML

export HQ_CLAUDE_EXIT=1
: >"$HQ_DM_LOG"
: >"$HQ_CURL_LOG"
export HQ_JOB_NOTIFY_NOW_EPOCH=3000000
set +e
bash "$RUN" --hq-root "$HQ" --job-id alert-failing
set -e
grep -c '^recipient=' "$HQ_DM_LOG" | grep -qx 1 || fail "first failure should dm once"
grep -qi 'agent_error' "$HQ_DM_LOG" || fail "failure dm should include agent_error"
grep -q '"failure_class":"agent_error"' "$HQ_CURL_LOG" || fail "ingest failure_class agent_error"

: >"$HQ_DM_LOG"
export HQ_JOB_NOTIFY_NOW_EPOCH=3003600
set +e
bash "$RUN" --hq-root "$HQ" --job-id alert-failing
set -e
[ ! -s "$HQ_DM_LOG" ] || fail "second failure must be collapsed (no dm)"

: >"$HQ_DM_LOG"
export HQ_JOB_NOTIFY_NOW_EPOCH=3007200
set +e
bash "$RUN" --hq-root "$HQ" --job-id alert-failing
set -e
[ ! -s "$HQ_DM_LOG" ] || fail "third failure must be collapsed (no dm)"
pass "3 consecutive agent_error → exactly one failure dm"

# ---------- 3) auth failure → no device-login loop; dm names re-login ----------
rm -f "$HOME_DIR/.claude/.credentials.json"
: >"$HQ_DM_LOG"
: >"$HQ_STUB_LOG"
: >"$HQ_CURL_LOG"
export HQ_JOB_NOTIFY_NOW_EPOCH=4000000
set +e
bash "$RUN" --hq-root "$HQ" --job-id alert-digest
arc=$?
set -e
[ "$arc" -eq 0 ] || fail "auth skip should exit 0, got $arc"
grep -qi 're-login' "$HQ_DM_LOG" || fail "auth dm should name re-login"
grep -q '"failure_class":"auth"' "$HQ_CURL_LOG" || fail "ingest failure_class auth"
# Cognito refresh may run; device login must not
if grep -Eqi 'device-code|claude login|codex login' "$HQ_STUB_LOG"; then
  fail "must not device-login loop on auth failure"
fi
grep -q 'auth-refresh' "$HQ_STUB_LOG" || fail "expected cognito/auth refresh attempt"
pass "auth failure dm names re-login; no device-login loop"

echo "ALL PASSED (hq-job-alerts)"
