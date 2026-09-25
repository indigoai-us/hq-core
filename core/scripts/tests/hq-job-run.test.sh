#!/usr/bin/env bash
# hq-core: public
# Regression: hq-job-run.sh flock, skip-on-missing-auth, meter marker, logs (US-004).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RUN="$ROOT/core/scripts/hq-job-run.sh"

command -v yq >/dev/null 2>&1 || { echo "SKIP: yq not available"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }
[ -f "$RUN" ] || { echo "FAIL: missing $RUN" >&2; exit 1; }
[ -x "$RUN" ] || chmod +x "$RUN"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hq-job-run-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

HQ="$TMP/hqroot"
HOME_DIR="$TMP/home"
BIN="$TMP/bin"
mkdir -p "$HQ/personal/jobs" "$HQ/companies/indigo/projects/outpost-scheduled-jobs"
mkdir -p "$HOME_DIR/.claude" "$HOME_DIR/.codex" "$HOME_DIR/.hq/jobs"
mkdir -p "$BIN"
export HOME="$HOME_DIR"
export HQ_ROOT="$HQ"
export PATH="$BIN:$PATH"

# Stub claude/codex that record invocations.
cat >"$BIN/claude" <<'STUB'
#!/usr/bin/env bash
echo "claude-stub: $*" >>"${HQ_STUB_LOG:-/dev/null}"
echo "OK"
exit 0
STUB
chmod +x "$BIN/claude"

cat >"$BIN/codex" <<'STUB'
#!/usr/bin/env bash
echo "codex-stub: $*" >>"${HQ_STUB_LOG:-/dev/null}"
# Verify spike flags present
printf '%s\n' "$*" | grep -q -- '-s workspace-write' || exit 11
printf '%s\n' "$*" | grep -q -- 'ask-for-approval' && exit 12
echo "codex OK"
exit 0
STUB
chmod +x "$BIN/codex"

cat >"$BIN/hq" <<'STUB'
#!/usr/bin/env bash
# secrets exec: hq secrets [--company S|--personal] exec --only K --script P -- <cmd>
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
  echo "hq-secrets-exec only=$only" >>"${HQ_STUB_LOG:-/dev/null}"
  exec "$@"
fi
echo "hq stub unexpected: $*" >&2
exit 2
STUB
chmod +x "$BIN/hq"

# --- fixture job ---
cat >"$HQ/personal/jobs/digest.yaml" <<'YAML'
id: test-daily-digest
name: Test daily digest
schedule: "0 9 * * 1-5"
timezone: America/New_York
runtime: claude
exec:
  prompt: "Reply with exactly: OK."
cwd: personal
timeout_seconds: 120
notify: dm
enabled: true
owner: owner@example.com
created_at: "2026-08-23T14:00:00Z"
requirements:
  runtime: claude
  secrets: []
YAML

mkdir -p "$HQ/personal"

export HQ_STUB_LOG="$TMP/stub.log"
export HQ_JOB_LOCK="$HOME_DIR/.hq/jobs/run.lock"
export HQ_JOB_LOG_DIR="$HOME_DIR/.hq/jobs/logs"
export HQ_JOB_METER_DIR="$HOME_DIR/.hq/jobs/meters"
export HQ_JOB_NOW="2026-08-23T18:00:00Z"
# US-004 suite isolates runner mechanics; US-006 covers notify/ingest/remediate.
export HQ_JOB_RUN_NO_NOTIFY=1
export HQ_JOB_RUN_NO_INGEST=1

# 1) Missing auth → skip exit 0, meter marker with skip_reason
rm -f "$HOME_DIR/.claude/.credentials.json"
: >"$HQ_STUB_LOG"
set +e
bash "$RUN" --hq-root "$HQ" --job-id test-daily-digest
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "missing auth should exit 0 (skip), got $rc"
grep -q '"skip_reason"' "$HOME_DIR/.hq/jobs/meters/runs.jsonl" || fail "meter marker missing skip_reason"
grep -Eq 'not authenticated|not installed' "$HOME_DIR/.hq/jobs/meters/runs.jsonl" || fail "skip_reason text missing"
pass "missing auth skips cleanly with meter marker"

# 2) With auth → runs claude, logs + meter exit 0
echo '{"token":"x"}' >"$HOME_DIR/.claude/.credentials.json"
: >"$HQ_STUB_LOG"
set +e
bash "$RUN" --hq-root "$HQ" --job-id test-daily-digest
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "authed run should exit 0, got $rc"
grep -q 'claude-stub' "$HQ_STUB_LOG" || fail "claude was not invoked"
grep -q '"exit_status":0' "$HOME_DIR/.hq/jobs/meters/runs.jsonl" || fail "meter missing exit_status 0"
ls "$HOME_DIR/.hq/jobs/logs/test-daily-digest/"*.log >/dev/null || fail "log file missing"
pass "authed claude run writes log + meter"

# 3) Codex spike flags (not --ask-for-approval never)
cat >"$HQ/personal/jobs/codex.yaml" <<'YAML'
id: test-codex-hygiene
name: Codex hygiene
schedule: "0 2 * * *"
timezone: UTC
runtime: codex
exec:
  prompt: "Reply OK"
cwd: personal
timeout_seconds: 180
notify: none
enabled: true
owner: owner@example.com
created_at: "2026-08-23T16:00:00Z"
requirements:
  runtime: codex
  secrets: []
YAML
echo '{"token":"y"}' >"$HOME_DIR/.codex/auth.json"
: >"$HQ_STUB_LOG"
set +e
bash "$RUN" --hq-root "$HQ" --job-id test-codex-hygiene
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "codex run should exit 0, got $rc"
grep -q 'codex-stub' "$HQ_STUB_LOG" || fail "codex was not invoked"
pass "codex uses -s workspace-write (spike flags)"

# 4) Flock serialization — second waiter starts after first releases
cat >"$BIN/claude" <<'STUB'
#!/usr/bin/env bash
# Hold for 2s so a concurrent run must wait on the flock.
sleep 2
echo OK
exit 0
STUB
chmod +x "$BIN/claude"

HQ_JOB_FLOCK_BIN="$(command -v flock)"
export HQ_JOB_FLOCK_BIN
START_A=$(date +%s)
bash "$RUN" --hq-root "$HQ" --job-id test-daily-digest >"$TMP/a.out" 2>"$TMP/a.err" &
PID_A=$!
sleep 0.3
bash "$RUN" --hq-root "$HQ" --job-id test-daily-digest >"$TMP/b.out" 2>"$TMP/b.err" &
PID_B=$!
wait $PID_A; RA=$?
wait $PID_B; RB=$?
END_B=$(date +%s)
[ "$RA" -eq 0 ] && [ "$RB" -eq 0 ] || fail "flock runs should both exit 0 ($RA,$RB)"
# B should not finish before A started + ~2s (serialized)
DUR_B_FROM_A_START=$((END_B - START_A))
[ "$DUR_B_FROM_A_START" -ge 3 ] || fail "expected serialized delay; B finished too soon (${DUR_B_FROM_A_START}s from A start)"
pass "global flock serializes concurrent runs"

# 5) Secrets allowlist via hq secrets exec
cat >"$BIN/claude" <<'STUB'
#!/usr/bin/env bash
echo "claude-stub ok"
exit 0
STUB
chmod +x "$BIN/claude"
cat >"$HQ/personal/jobs/secreted.yaml" <<'YAML'
id: test-with-secret
name: With secret
schedule: "0 9 * * *"
timezone: UTC
runtime: claude
exec:
  prompt: "OK"
timeout_seconds: 120
notify: none
enabled: true
owner: owner@example.com
created_at: "2026-08-23T14:00:00Z"
requirements:
  runtime: claude
  secrets:
    - SENTRY_API_TOKEN
YAML
: >"$HQ_STUB_LOG"
bash "$RUN" --hq-root "$HQ" --job-id test-with-secret
grep -q 'hq-secrets-exec only=SENTRY_API_TOKEN' "$HQ_STUB_LOG" || fail "expected hq secrets exec --only"
pass "requirements.secrets injected via hq secrets exec --only"

# 6) Instance auth stays out of curl argv, proc cmdline, logs, and xtrace.
cat >"$BIN/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\0' "$@" >"$HQ_STUB_CURL_ARGV"
while IFS= read -r -d '' cmd_arg; do
  printf '%s\0' "$cmd_arg"
done </proc/self/cmdline >"$HQ_STUB_CURL_PROC_CMDLINE" || true

out="/dev/null"
hdr="/dev/null"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -H)
      header_spec="${2:-}"
      case "$header_spec" in
        @*)
          header_file="${header_spec#@}"
          printf '%s\n' "$header_file" >"$HQ_STUB_CURL_HEADER_PATH"
          cat "$header_file" >"$HQ_STUB_CURL_HEADER"
          stat -c '%a' "$header_file" >"$HQ_STUB_CURL_HEADER_MODE"
          ;;
      esac
      shift 2
      ;;
    -o) out="${2:-}"; shift 2 ;;
    -D) hdr="${2:-}"; shift 2 ;;
    --data|-d|-m|-X) shift 2 ;;
    -sS|-s|-S|-f|-fsS) shift ;;
    *) shift ;;
  esac
done

if [ "${HQ_STUB_CURL_MODE:-ok}" = "fail" ]; then
  echo "curl stub: transport failure" >&2
  exit 7
fi
printf 'HTTP/1.1 200 OK\r\n\r\n' >"$hdr"
printf '{"ok":true}\n' >"$out"
STUB
chmod +x "$BIN/curl"

TOKEN="tok-us017-run-test-aaaaaaaa"
export OUTPOST_USER_ID="user_test_owner"
export OUTPOST_INSTANCE_TOKEN="$TOKEN"
export HQ_JOB_RUN_CURL="$BIN/curl"
export HQ_JOB_RUN_NO_INGEST=0
export HQ_JOB_RUN_SKIP_EXEC=1
export HQ_STUB_CURL_ARGV="$TMP/curl.argv"
export HQ_STUB_CURL_PROC_CMDLINE="$TMP/curl.proc-cmdline"
export HQ_STUB_CURL_HEADER_PATH="$TMP/curl.header-path"
export HQ_STUB_CURL_HEADER="$TMP/curl.header"
export HQ_STUB_CURL_HEADER_MODE="$TMP/curl.header-mode"

assert_token_absent() {
  local file
  for file in "$@"; do
    [ -e "$file" ] || continue
    if grep -R -aFq -- "$TOKEN" "$file"; then
      fail "instance token appeared in $file"
    fi
  done
}

run_auth_case() {
  local mode="$1" label="$2" rc=0 header_file
  rm -f "$HQ_STUB_CURL_ARGV" "$HQ_STUB_CURL_PROC_CMDLINE" "$HQ_STUB_CURL_HEADER_PATH" \
    "$HQ_STUB_CURL_HEADER" "$HQ_STUB_CURL_HEADER_MODE"
  export HQ_STUB_CURL_MODE="$mode"
  : >"$TMP/run-auth-$label.stdout"
  : >"$TMP/run-auth-$label.stderr"
  bash -x "$RUN" --hq-root "$HQ" --job-id test-daily-digest \
    >"$TMP/run-auth-$label.stdout" 2>"$TMP/run-auth-$label.stderr" || rc=$?
  [ "$rc" -eq 0 ] || fail "run auth $label should preserve successful job exit, got $rc"
  [ -s "$HQ_STUB_CURL_ARGV" ] || fail "curl argv not captured for run auth $label"
  [ -s "$HQ_STUB_CURL_PROC_CMDLINE" ] || fail "curl /proc cmdline not captured for run auth $label"
  assert_token_absent "$HQ_STUB_CURL_ARGV" "$HQ_STUB_CURL_PROC_CMDLINE" \
    "$TMP/run-auth-$label.stdout" "$TMP/run-auth-$label.stderr" "$HOME_DIR/.hq/jobs/logs"
  grep -Fxq "x-outpost-instance-token: $TOKEN" "$HQ_STUB_CURL_HEADER" || \
    fail "run auth $label did not deliver the expected header"
  [ "$(cat "$HQ_STUB_CURL_HEADER_MODE")" = "600" ] || fail "run auth $label header file was not mode 600"
  header_file="$(cat "$HQ_STUB_CURL_HEADER_PATH")"
  [ ! -e "$header_file" ] || fail "run auth $label header file remained after curl returned"
}

run_auth_case ok success
run_auth_case fail failure
pass "instance token stays out of run curl argv, proc cmdline, logs, and xtrace; header file is private and cleaned"

echo "ALL PASSED (hq-job-run)"
