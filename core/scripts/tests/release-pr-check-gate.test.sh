#!/usr/bin/env bash
# Regression coverage for the hq-core release PR check gate. All GitHub data is
# synthetic; no API call or merge can reach GitHub from this test.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
GATE="$ROOT/core/scripts/release-pr-check-gate.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[ -x "$GATE" ] || fail "release promotion gate is missing"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$GH_STUB_LOG"
case "$*" in
  *'pr view 331 '* )
    printf '%s\n' '{"headRefOid":"0123456789012345678901234567890123456789","autoMergeRequest":null,"labels":[]}'
    ;;
  *'check-runs?per_page=100'*) cat "$GH_CHECK_RUNS_JSON" ;;
  *'statuses?per_page=100'*) cat "$GH_STATUSES_JSON" ;;
  *'pr merge 331 '* ) exit 0 ;;
  *'pr edit 331 '* ) exit 0 ;;
  *) printf 'unexpected gh invocation: %s\n' "$*" >&2; exit 90 ;;
esac
GH
chmod +x "$TMP/bin/gh"
REPO='indigoai-us/hq-core'
PR=331
SHA='0123456789012345678901234567890123456789'
: > "$TMP/failed.log"
write_check_payload() {
  local output_file="$1" conclusion="$2" padding_bytes=$((3 * 1024 * 1024))
  node - "$output_file" "$conclusion" "$padding_bytes" <<'NODE'
const fs = require('node:fs');
const [, , outputFile, conclusion, paddingBytes] = process.argv;
const checkRuns = conclusion === 'success'
  ? [
      { name: 'company-seed-renderer', status: 'completed', conclusion: 'success' },
      { name: 'shell-smoke-windows', status: 'completed', conclusion: 'neutral' },
    ]
  : [{ name: 'company-seed-renderer', status: 'completed', conclusion }];
const payload = [{
  total_count: 1,
  check_runs: checkRuns,
  padding: 'x'.repeat(Number(paddingBytes)),
}];
fs.writeFileSync(outputFile, JSON.stringify(payload));
NODE
}
write_check_payload "$TMP/failed-checks.json" failure
printf '%s\n' '[[]]' > "$TMP/failed-statuses.json"
set +e
failed_output="$(PATH="$TMP/bin:$PATH" GH_STUB_LOG="$TMP/failed.log" GH_CHECK_RUNS_JSON="$TMP/failed-checks.json" GH_STATUSES_JSON="$TMP/failed-statuses.json" bash "$GATE" "$REPO" "$PR" "$SHA" 1 0 2>&1)"
failed_rc=$?
set -e
[ "$failed_rc" -ne 0 ] || fail "a failed non-required check must block the merge"
grep -q 'company-seed-renderer' <<< "$failed_output" || fail "failure output must name the failed check; gate output: $failed_output"
if grep -q -- '--squash' "$TMP/failed.log"; then fail "failed check must not invoke merge"; fi
grep -q 'hold-release' "$TMP/failed.log" || fail "failed check must apply hold-release"
printf '%s\n' 'PASS: failed non-required check blocks merge and applies hold-release'

: > "$TMP/green.log"
write_check_payload "$TMP/green-checks.json" success
printf '%s\n' '[[{"state":"success","context":"legacy-status","created_at":"2026-10-01T00:00:00Z"}]]' > "$TMP/green-statuses.json"
PATH="$TMP/bin:$PATH" GH_STUB_LOG="$TMP/green.log" GH_CHECK_RUNS_JSON="$TMP/green-checks.json" GH_STATUSES_JSON="$TMP/green-statuses.json" bash "$GATE" "$REPO" "$PR" "$SHA" 1 0
grep -q -- '--squash' "$TMP/green.log" || fail "all-green checks must invoke merge"
grep -q -- "--match-head-commit $SHA" "$TMP/green.log" || fail "merge must pin the checked head SHA"
printf '%s\n' 'PASS: accepted check conclusions merge the exact checked head'

PROMOTE_WORKFLOW="$ROOT/.github/workflows/promote-to-hq-core.yml"
RECHECK_WORKFLOW="$ROOT/.github/workflows/recheck-hq-core-release-gate.yml"
grep -Fq 'path: staging' "$PROMOTE_WORKFLOW" || fail "promotion workflow must check out staging under staging/"
grep -Fq 'run: bash staging/core/scripts/release-pr-check-gate.sh ' "$PROMOTE_WORKFLOW" || fail "promotion workflow must invoke the gate from staging/"
grep -Fq '      - uses: actions/checkout@v4' "$RECHECK_WORKFLOW" || fail "recheck workflow must check out the repository root"
if grep -Fq 'path:' "$RECHECK_WORKFLOW"; then fail "recheck workflow checkout must remain at the repository root"; fi
grep -Fq 'bash core/scripts/release-pr-check-gate.sh ' "$RECHECK_WORKFLOW" || fail "recheck workflow must invoke the gate from its root checkout"
printf '%s\n' 'PASS: promotion and scheduled recheck workflows invoke the gate from their checkout paths'
