#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SOURCE_RUNNER="$ROOT/core/scripts/ci/run-shell-smoke-timeout-tests.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/shell-smoke-timeout-runner-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

REPO="$TMP/repo"
mkdir -p "$REPO/core/scripts/ci" "$REPO/core/scripts/tests" "$TMP/signals"
git -C "$REPO" init -q
cp "$SOURCE_RUNNER" "$REPO/core/scripts/ci/run-shell-smoke-timeout-tests.sh"

cat > "$REPO/core/scripts/tests/hook-timeout-sentry.test.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: > "$SHELL_SMOKE_BARRIER_DIR/sentry.started"
attempt=0
while [ ! -f "$SHELL_SMOKE_BARRIER_DIR/attribution.started" ]; do
  [ "$attempt" -lt 300 ] || { echo 'sentry timed out waiting for sibling' >&2; exit 31; }
  attempt=$((attempt + 1))
  sleep 0.01
done
printf '%s\n' 'SENTRY_COMPLETE'
EOF
cat > "$REPO/core/scripts/tests/hook-timeout-watchdog-attribution.test.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: > "$SHELL_SMOKE_BARRIER_DIR/attribution.started"
attempt=0
while [ ! -f "$SHELL_SMOKE_BARRIER_DIR/sentry.started" ]; do
  [ "$attempt" -lt 300 ] || { echo 'attribution timed out waiting for sibling' >&2; exit 32; }
  attempt=$((attempt + 1))
  sleep 0.01
done
printf '%s\n' 'ATTRIBUTION_COMPLETE'
EOF
chmod +x "$REPO/core/scripts/tests/hook-timeout-sentry.test.sh" "$REPO/core/scripts/tests/hook-timeout-watchdog-attribution.test.sh"

if output="$(cd "$REPO" && SHELL_SMOKE_BARRIER_DIR="$TMP/signals" bash core/scripts/ci/run-shell-smoke-timeout-tests.sh 2>&1)"; then
  :
else
  fail "parallel runner failed: $output"
fi
grep -Fq '===== Hook timeout Sentry watchdog (exit 0) =====' <<< "$output" \
  || fail 'the first complete test log must have its own labeled section'
grep -Fq '===== Hook timeout attribution tags and compact sequence (exit 0) =====' <<< "$output" \
  || fail 'the second complete test log must have its own labeled section'
grep -Fq 'SENTRY_COMPLETE' <<< "$output" || fail 'the Sentry test output must be preserved'
grep -Fq 'ATTRIBUTION_COMPLETE' <<< "$output" || fail 'the attribution test output must be preserved'
pass 'both children entered their barrier before either could complete; output remains labeled'

cat > "$REPO/core/scripts/tests/hook-timeout-watchdog-attribution.test.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'ATTRIBUTION_FAILURE_OUTPUT'
exit 23
EOF
if output="$(cd "$REPO" && SHELL_SMOKE_BARRIER_DIR="$TMP/signals" bash core/scripts/ci/run-shell-smoke-timeout-tests.sh 2>&1)"; then
  fail 'a failing child must fail the overall shell-smoke job'
fi
grep -Fq '===== Hook timeout Sentry watchdog (exit 0) =====' <<< "$output" \
  || fail 'successful sibling output must remain visible when the other child fails'
grep -Fq '===== Hook timeout attribution tags and compact sequence (exit 23) =====' <<< "$output" \
  || fail 'failure status must be attributed to the failing test'
grep -Fq 'ATTRIBUTION_FAILURE_OUTPUT' <<< "$output" \
  || fail 'the failing child output must remain visible'
pass 'a child failure propagates while both labeled logs remain readable'
