#!/usr/bin/env bash
# hq-core: public
# Regression: hq-job-probe.sh requirements checks + hq-pro ingest (US-008).
#
# Cases:
#   1. all-green → ready ingest
#   2. missing secret → blocked + share next_action
#   3. logged-out CLI → blocked + re-login next_action
#   4. API down → StatusIngestError path, marker written, not spuriously ready
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PROBE="$ROOT/core/scripts/hq-job-probe.sh"
FIX="$ROOT/core/scripts/tests/fixtures/jobs-probe"

command -v yq >/dev/null 2>&1 || { echo "SKIP: yq not available"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }
[ -f "$PROBE" ] || { echo "FAIL: missing $PROBE" >&2; exit 1; }
[ -x "$PROBE" ] || chmod +x "$PROBE"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hq-job-probe-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Fake HQ root with company + cwd paths referenced by fixtures.
HQ="$TMP/hqroot"
mkdir -p "$HQ/companies/indigo/projects/outpost-scheduled-jobs"
mkdir -p "$HQ/personal/jobs"
cp "$FIX/green/job.yaml" "$HQ/personal/jobs/probe-green-digest.yaml"

# Isolated HOME for credentials + probe markers.
HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/.claude" "$HOME_DIR/.codex" "$HOME_DIR/.hq/jobs/probes"
export HOME="$HOME_DIR"

STATE_DIR="$HOME_DIR/.hq/jobs/probes"
BIN="$TMP/bin"
mkdir -p "$BIN"

# --- stubs -------------------------------------------------------------------

# hq secrets list — prints a table; names only.
cat > "$BIN/hq" <<'STUB'
#!/usr/bin/env bash
# Usage shapes exercised by the probe:
#   hq secrets list --company <slug>
#   hq secrets list --personal
if [ "${1:-}" = "secrets" ] && [ "${2:-}" = "list" ]; then
  company=""
  personal=0
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --company) company="${2:-}"; shift 2 ;;
      --personal) personal=1; shift ;;
      *) shift ;;
    esac
  done
  if [ -n "${HQ_STUB_SECRETS_FAIL:-}" ]; then
    echo "hq: secrets list failed (stub)" >&2
    exit 1
  fi
  echo "Secrets for stub:"
  echo "NAME                                                                      ACCESS  TIER      SCRIPT LOCK  LAST MODIFIED"
  # Default visible key for green / api-down fixtures.
  echo "SENTRY_API_TOKEN                                                          admin   standard  off          2026-08-23T00:00:00.000Z"
  if [ -n "${HQ_STUB_EXTRA_SECRET:-}" ]; then
    echo "${HQ_STUB_EXTRA_SECRET}                                                   admin   standard  off          2026-08-23T00:00:00.000Z"
  fi
  # Intentionally do NOT list MISSING_VAULT_KEY
  exit 0
fi
echo "hq stub: unexpected invocation: $*" >&2
exit 2
STUB
chmod +x "$BIN/hq"

# claude / codex presence
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$BIN/claude"
cat > "$BIN/codex" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$BIN/codex"

# curl stub: records request; behavior via HQ_STUB_CURL_MODE
cat > "$BIN/curl" <<'STUB'
#!/usr/bin/env bash
# Minimal curl stub for POST ingest. Honors -o / -D / -H / --data.
out="/dev/null"
hdr="/dev/null"
data=""
url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="${2:-}"; shift 2 ;;
    -D) hdr="${2:-}"; shift 2 ;;
    --data|-d) data="${2:-}"; shift 2 ;;
    -H) shift 2 ;;
    -sS|-s|-S|-f|-fsS) shift ;;
    -m) shift 2 ;;
    -X) shift 2 ;;
    http*|https*) url="$1"; shift ;;
    *) shift ;;
  esac
done

mkdir -p "$(dirname "$HOME/.hq/jobs/probes/.curl-last")" 2>/dev/null || true
printf '%s\n' "$data" >"${HQ_STUB_CURL_CAPTURE:-$HOME/.hq/jobs/probes/.curl-last.json}"
printf '%s\n' "$url" >"${HQ_STUB_CURL_URL:-$HOME/.hq/jobs/probes/.curl-last.url}"

mode="${HQ_STUB_CURL_MODE:-ok}"
case "$mode" in
  ok)
    printf 'HTTP/1.1 200 OK\r\n\r\n' >"$hdr"
    readiness="$(printf '%s' "$data" | jq -r '.readiness // "ready"' 2>/dev/null || echo ready)"
    job_id="$(printf '%s' "$data" | jq -r '.jobId // empty' 2>/dev/null || true)"
    printf '{"ok":true,"idempotent":false,"status":{"job_id":"%s","readiness":"%s","next_actions":[],"updated_at":"2026-08-23T18:00:00Z","cache_guidance_seconds":30}}\n' \
      "$job_id" "$readiness" >"$out"
    exit 0
    ;;
  down)
    # Simulate transport failure (API unreachable)
    printf 'HTTP/1.1 000\r\n\r\n' >"$hdr" 2>/dev/null || true
    echo "curl: (7) Failed to connect" >&2
    exit 7
    ;;
  http503)
    printf 'HTTP/1.1 503 Service Unavailable\r\n\r\n' >"$hdr"
    printf '{"error":true,"code":"StatusIngestError","step":"persist","message":"throttled","retryable":true}\n' >"$out"
    exit 0
    ;;
  *)
    echo "curl stub: unknown mode $mode" >&2
    exit 99
    ;;
esac
STUB
chmod +x "$BIN/curl"

export PATH="$BIN:$PATH"
export HQ_ROOT="$HQ"
export HQ_PRO_API_URL="https://hqapi.test.example"
export OUTPOST_USER_ID="user_test_owner"
export OUTPOST_INSTANCE_TOKEN="tok-test-aaaaaaaaaaaaaaaaaaaaaaaa"
export OUTPOST_ID="out_test1"
export HQ_JOB_PROBE_STATE_DIR="$STATE_DIR"
export HQ_JOB_PROBE_SLEEP=":"
export HQ_JOB_PROBE_NOW="2026-08-23T18:00:00Z"
export HQ_JOB_PROBE_MAX_ATTEMPTS=3
export HQ_JOB_PROBE_BACKOFF_BASE_SEC=1
export HQ_STUB_CURL_CAPTURE="$TMP/curl-last.json"
export HQ_STUB_CURL_URL="$TMP/curl-last.url"

# Fresh credentials for "logged in" cases
write_creds() {
  printf '{"claudeAiOauth":{"accessToken":"test"}}\n' >"$HOME_DIR/.claude/.credentials.json"
  printf '{"auth_mode":"chatgpt","tokens":{"access_token":"test"}}\n' >"$HOME_DIR/.codex/auth.json"
}
clear_creds() {
  rm -f "$HOME_DIR/.claude/.credentials.json" "$HOME_DIR/.codex/auth.json"
}
write_creds

# =============================================================================
echo "[1] all-green → ready ingest"
export HQ_STUB_CURL_MODE=ok
rm -f "$HQ_STUB_CURL_CAPTURE" "$HQ_STUB_CURL_URL"
rc=0
out="$(bash "$PROBE" --hq-root "$HQ" "$FIX/green/job.yaml" 2>"$TMP/err1.txt")" || rc=$?
[ "$rc" -eq 0 ] || fail "green expected exit 0, got $rc :: out=$out err=$(cat "$TMP/err1.txt")"
echo "$out" | jq -e '.readiness == "ready"' >/dev/null || fail "green readiness: $out"
echo "$out" | jq -e '.ingest == "ok"' >/dev/null || fail "green ingest: $out"
echo "$out" | jq -e '.checks.auth == "ok"' >/dev/null || fail "green auth check: $out"
echo "$out" | jq -e '.checks.secrets.status == "ok"' >/dev/null || fail "green secrets: $out"
[ -f "$HQ_STUB_CURL_CAPTURE" ] || fail "green did not POST"
jq -e '.kind == "probe" and .readiness == "ready" and .jobId == "probe-green-digest"' \
  "$HQ_STUB_CURL_CAPTURE" >/dev/null || fail "green payload: $(cat "$HQ_STUB_CURL_CAPTURE")"
grep -q '/outpost/internal/jobs-status' "$HQ_STUB_CURL_URL" || fail "green URL: $(cat "$HQ_STUB_CURL_URL")"
# Marker written on success too
[ -f "$STATE_DIR/probe-green-digest/last-attempt.json" ] || fail "green marker missing"
jq -e '.ingest.ok == true and .reported_readiness == "ready"' \
  "$STATE_DIR/probe-green-digest/last-attempt.json" >/dev/null \
  || fail "green marker content"
pass "all-green ready ingest"

# =============================================================================
echo "[2] missing secret → blocked"
export HQ_STUB_CURL_MODE=ok
rm -f "$HQ_STUB_CURL_CAPTURE"
rc=0
out="$(bash "$PROBE" --hq-root "$HQ" "$FIX/blocked-secret/job.yaml" 2>"$TMP/err2.txt")" || rc=$?
[ "$rc" -eq 1 ] || fail "missing secret expected exit 1, got $rc :: $out"
echo "$out" | jq -e '.readiness == "blocked"' >/dev/null || fail "secret readiness: $out"
echo "$out" | jq -e '.checks.secrets.status == "missing"' >/dev/null || fail "secret status: $out"
echo "$out" | jq -e '.checks.secrets.missing | index("MISSING_VAULT_KEY") != null' >/dev/null \
  || fail "secret missing list: $out"
echo "$out" | jq -e --arg p 'hq secrets share MISSING_VAULT_KEY' '
  .next_actions | map(select(startswith($p))) | length > 0
' >/dev/null || fail "secret next_actions should mention share: $out"
jq -e '.readiness == "blocked"' "$HQ_STUB_CURL_CAPTURE" >/dev/null || fail "blocked secret should still ingest blocked"
pass "missing secret → blocked"

# =============================================================================
echo "[3] logged-out CLI → blocked"
clear_creds
export HQ_STUB_CURL_MODE=ok
rm -f "$HQ_STUB_CURL_CAPTURE"
rc=0
out="$(bash "$PROBE" --hq-root "$HQ" "$FIX/blocked-auth/job.yaml" 2>"$TMP/err3.txt")" || rc=$?
[ "$rc" -eq 1 ] || fail "logged-out expected exit 1, got $rc :: $out"
echo "$out" | jq -e '.readiness == "blocked"' >/dev/null || fail "auth readiness: $out"
echo "$out" | jq -e '.checks.auth == "missing"' >/dev/null || fail "auth check: $out"
echo "$out" | jq -e '
  .next_actions | map(select(test("re-login"; "i"))) | length > 0
' >/dev/null || fail "auth next_actions should mention re-login: $out"
# Ensure we never printed credential values
if grep -Eiq 'accessToken|access_token|sk-|api[_-]?key' "$TMP/err3.txt" "$HQ_STUB_CURL_CAPTURE" 2>/dev/null; then
  fail "auth case leaked credential-shaped output"
fi
pass "logged-out CLI → blocked"
write_creds

# =============================================================================
echo "[4] API down → StatusIngestError path (not spuriously ready)"
export HQ_STUB_CURL_MODE=down
rm -f "$HQ_STUB_CURL_CAPTURE"
rm -f "$STATE_DIR/probe-api-down/last-attempt.json"
rc=0
out="$(bash "$PROBE" --hq-root "$HQ" "$FIX/api-down/job.yaml" 2>"$TMP/err4.txt")" || rc=$?
[ "$rc" -eq 3 ] || fail "API down expected exit 3 (StatusIngestError), got $rc :: $out err=$(cat "$TMP/err4.txt")"
echo "$out" | jq -e '.ingest == "StatusIngestError"' >/dev/null || fail "api-down ingest field: $out"
echo "$out" | jq -e '.readiness != "ready"' >/dev/null || fail "api-down must not claim ready: $out"
echo "$out" | jq -e '.readiness == "unknown"' >/dev/null || fail "api-down readiness should be unknown: $out"
echo "$out" | jq -e '
  .next_actions | index("status ingest failed — retry probe") != null
' >/dev/null || fail "api-down next_action missing: $out"
[ -f "$STATE_DIR/probe-api-down/last-attempt.json" ] || fail "api-down marker missing under ~/.hq/jobs/probes/{id}/"
jq -e '
  .ingest.ok == false
  and .ingest.code == "StatusIngestError"
  and .reported_readiness == null
  and .local_readiness == "ready"
' "$STATE_DIR/probe-api-down/last-attempt.json" >/dev/null \
  || fail "api-down marker: $(cat "$STATE_DIR/probe-api-down/last-attempt.json")"
# Retries happened (stderr mentions backoff) — with SLEEP=: still logs attempts
if ! grep -q 'ingest attempt' "$TMP/err4.txt"; then
  fail "expected backoff retry logs on stderr: $(cat "$TMP/err4.txt")"
fi
pass "API down → StatusIngestError + marker; not ready"

# =============================================================================
echo "[5] HTTP 503 StatusIngestError also fails closed"
export HQ_STUB_CURL_MODE=http503
rm -f "$STATE_DIR/probe-api-down/last-attempt.json"
rc=0
out="$(bash "$PROBE" --hq-root "$HQ" "$FIX/api-down/job.yaml" 2>"$TMP/err5.txt")" || rc=$?
[ "$rc" -eq 3 ] || fail "503 expected exit 3, got $rc :: $out"
echo "$out" | jq -e '.readiness != "ready" and .ingest == "StatusIngestError"' >/dev/null \
  || fail "503 must not be ready: $out"
pass "HTTP 503 StatusIngestError fails closed"

# =============================================================================
echo "[6] dry-run skips ingest"
export HQ_STUB_CURL_MODE=ok
rm -f "$HQ_STUB_CURL_CAPTURE"
rc=0
out="$(bash "$PROBE" --hq-root "$HQ" --dry-run "$FIX/green/job.yaml" 2>"$TMP/err6.txt")" || rc=$?
[ "$rc" -eq 0 ] || fail "dry-run green expected 0, got $rc"
echo "$out" | jq -e '.dry_run == true and .ingest == "dry_run" and .readiness == "ready"' >/dev/null \
  || fail "dry-run payload: $out"
[ ! -f "$HQ_STUB_CURL_CAPTURE" ] || fail "dry-run must not POST"
pass "dry-run skips ingest"

# =============================================================================
echo "[7] resolve by job id from registry"
export HQ_STUB_CURL_MODE=ok
rc=0
out="$(bash "$PROBE" --hq-root "$HQ" --dry-run probe-green-digest 2>"$TMP/err7.txt")" || rc=$?
[ "$rc" -eq 0 ] || fail "id resolve expected 0: $(cat "$TMP/err7.txt")"
echo "$out" | jq -e '.job_id == "probe-green-digest"' >/dev/null || fail "id resolve: $out"
pass "resolve job id from personal/jobs"

echo "PASS: hq-job-probe"
