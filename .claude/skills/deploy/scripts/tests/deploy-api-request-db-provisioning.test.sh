#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
REQUEST="$ROOT/.claude/skills/deploy/scripts/deploy-api-request.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
mkdir -p "$TMP_ROOT/bin"

cat > "$TMP_ROOT/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -u
out=''
while [ "$#" -gt 0 ]; do
  if [ "$1" = '-o' ]; then out="$2"; shift 2; else shift; fi
done
count_file="$FAKE_STATE/count"
n=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
printf '%s' "$n" > "$count_file"
if [ "$n" -le "$FAKE_PROVISIONING_REPLIES" ]; then
  printf '{"error":"database still being created","code":"DATABASE_PROVISIONING","retryAfterSeconds":5}' > "$out"
  printf '503'
else
  printf '{"deployId":"dep-1","statusUrl":"/api/apps/x/deploys/dep-1/status"}' > "$out"
  printf '200'
fi
STUB
chmod +x "$TMP_ROOT/bin/curl"

cat > "$TMP_ROOT/bin/fake-sleep" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FAKE_STATE/sleeps"
STUB
chmod +x "$TMP_ROOT/bin/fake-sleep"

run_request() {
  local replies="$1" wait_secs="$2"
  export FAKE_STATE="$TMP_ROOT/state-$replies-$wait_secs"
  mkdir -p "$FAKE_STATE"
  export FAKE_PROVISIONING_REPLIES="$replies"
  PATH="$TMP_ROOT/bin:$PATH" HQ_DEPLOY_JWT=test-jwt \
    HQ_DEPLOY_SLEEP_CMD="$TMP_ROOT/bin/fake-sleep" HQ_DEPLOY_DB_WAIT_SECS="$wait_secs" \
    "$REQUEST" --stage app-deploy --method POST --url https://api.example.test/api/apps/x/deploy \
    --expect '(.deployId | type == "string" and length > 0)'
}

OUT="$(run_request 3 600 2>"$TMP_ROOT/err1")" || { echo 'FAIL: deploy should succeed after provisioning replies' >&2; cat "$TMP_ROOT/err1" >&2; exit 1; }
case "$OUT" in *'"deployId":"dep-1"'*) ;; *) echo "FAIL: unexpected body: $OUT" >&2; exit 1 ;; esac
[ "$(cat "$TMP_ROOT/state-3-600/count")" = 4 ] || { echo 'FAIL: expected exactly 4 requests (3 provisioning + 1 success)' >&2; exit 1; }
[ "$(wc -l < "$TMP_ROOT/state-3-600/sleeps" | tr -d ' ')" = 3 ] || { echo 'FAIL: expected 3 waits' >&2; exit 1; }
grep -q 'app database is being created' "$TMP_ROOT/err1" || { echo 'FAIL: progress message missing' >&2; exit 1; }

if run_request 99 10 >"$TMP_ROOT/out2" 2>"$TMP_ROOT/err2"; then
  echo 'FAIL: expected failure once the wait limit is spent' >&2
  exit 1
fi
[ "$(cat "$TMP_ROOT/state-99-10/count")" = 3 ] || { echo 'FAIL: expected 3 requests inside a 10 second limit' >&2; exit 1; }
grep -q 'api_code=DATABASE_PROVISIONING' "$TMP_ROOT/err2" || { echo 'FAIL: final diagnostic should name DATABASE_PROVISIONING' >&2; exit 1; }

run_request 0 600 >/dev/null 2>&1
[ "$(cat "$TMP_ROOT/state-0-600/count")" = 1 ] || { echo 'FAIL: a first-try success must not be repeated' >&2; exit 1; }
[ ! -e "$TMP_ROOT/state-0-600/sleeps" ] || { echo 'FAIL: no wait expected on success' >&2; exit 1; }

printf 'PASS: cold database deploys repeat the same request, stop at success, and stop at the wait limit\n'
