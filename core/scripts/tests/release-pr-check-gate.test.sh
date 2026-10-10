#!/usr/bin/env bash
# Regression coverage for the hq-core release PR check gate. All GitHub data is
# synthetic; no API call or merge can reach GitHub from this test.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
GATE="${GATE_SCRIPT:-$ROOT/core/scripts/release-pr-check-gate.sh}"
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
    view_count=0
    if [[ -f "$GH_PR_VIEW_COUNT" ]]; then view_count="$(cat "$GH_PR_VIEW_COUNT")"; fi
    view_count=$((view_count + 1))
    printf '%s\n' "$view_count" > "$GH_PR_VIEW_COUNT"
    head_sha="$(sed -n "${view_count}p" "$GH_PR_HEADS")"
    if [[ -z "$head_sha" ]]; then head_sha="$(tail -n 1 "$GH_PR_HEADS")"; fi
    labels='[]'
    if { [[ -f "$GH_LABEL_STATE" ]] && [[ "$(cat "$GH_LABEL_STATE")" == hold-release ]]; } \
      || { [[ -n "${GH_LABEL_AFTER_VIEW:-}" ]] && (( view_count >= GH_LABEL_AFTER_VIEW )); }; then
      labels='[{"name":"hold-release"}]'
      printf '%s\n' hold-release >> "$GH_LABEL_OBSERVATIONS"
    else
      printf '%s\n' absent >> "$GH_LABEL_OBSERVATIONS"
    fi
    printf '{"headRefOid":"%s","autoMergeRequest":null,"labels":%s}\n' "$head_sha" "$labels"
    ;;
  *'check-runs?per_page=100'*) cat "$GH_CHECK_RUNS_JSON" ;;
  *'statuses?per_page=100'*) cat "$GH_STATUSES_JSON" ;;
  *'pr merge 331 '* ) exit 0 ;;
  *'pr edit 331 '* )
    case "$*" in
      *'--add-label hold-release'*) printf '%s\n' hold-release > "$GH_LABEL_STATE" ;;
      *'--remove-label hold-release'*) : > "$GH_LABEL_STATE" ;;
      *) printf 'unexpected label edit: %s\n' "$*" >&2; exit 91 ;;
    esac
    ;;
  *) printf 'unexpected gh invocation: %s\n' "$*" >&2; exit 90 ;;
esac
GH
chmod +x "$TMP/bin/gh"
REPO='indigoai-us/hq-core'
PR=331
SHA='0123456789012345678901234567890123456789'
MOVED_SHA='abcdefabcdefabcdefabcdefabcdefabcdefabcd'
GATE_TEST_CASE="${GATE_TEST_CASE:-}"

write_check_payload() {
  local output_file="$1" conclusion="$2"
  node - "$output_file" "$conclusion" <<'NODE'
const fs = require('node:fs');
const [, , outputFile, conclusion] = process.argv;
const checkRuns = conclusion === 'success'
  ? [
      { name: 'company-seed-renderer', status: 'completed', conclusion: 'success' },
      { name: 'shell-smoke-windows', status: 'completed', conclusion: 'neutral' },
    ]
  : [{ name: 'company-seed-renderer', status: 'completed', conclusion }];
fs.writeFileSync(outputFile, JSON.stringify([{
  total_count: 1,
  check_runs: checkRuns,
  padding: 'x'.repeat(3 * 1024 * 1024),
}]));
NODE
}

run_case() {
  local case_id="$1" conclusion="$2" head_sequence="$3"
  local expected_rc="$4" expect_hold="$5" expect_merge="$6" expected_text="$7"
  local label_after_view="${8:-}"
  [[ -z "$GATE_TEST_CASE" || "$GATE_TEST_CASE" == "$case_id" ]] || return 0

  local case_dir="$TMP/$case_id" output rc
  mkdir -p "$case_dir"
  printf '%s\n' "$head_sequence" > "$case_dir/heads.jsonl"
  printf '%s\n' '[[]]' > "$case_dir/statuses.json"
  write_check_payload "$case_dir/checks.json" "$conclusion"
  set +e
  output="$(PATH="$TMP/bin:$PATH" GH_STUB_LOG="$case_dir/gh.log" \
    GH_PR_HEADS="$case_dir/heads.jsonl" GH_PR_VIEW_COUNT="$case_dir/views" \
    GH_LABEL_STATE="$case_dir/labels" GH_LABEL_AFTER_VIEW="$label_after_view" \
    GH_LABEL_OBSERVATIONS="$case_dir/label-observations" \
    GH_CHECK_RUNS_JSON="$case_dir/checks.json" \
    GH_STATUSES_JSON="$case_dir/statuses.json" \
    bash "$GATE" "$REPO" "$PR" "$SHA" 1 0 2>&1)"
  rc=$?
  set -e

  [[ "$rc" == "$expected_rc" ]] || fail "$case_id: expected exit $expected_rc, got $rc; output: $output"
  if [[ "$expect_hold" == yes ]]; then
    grep -Fq -- '--add-label hold-release' "$case_dir/gh.log" || fail "$case_id: expected hold-release to be added"
    [[ "$(cat "$case_dir/labels")" == hold-release ]] || fail "$case_id: expected hold-release to remain"
    grep -Fq 'hold-release' <<< "$output" || fail "$case_id: output must explain the release hold"
  elif [[ "$expect_hold" == rollback ]]; then
    grep -Fq -- '--add-label hold-release' "$case_dir/gh.log" || fail "$case_id: expected temporary hold-release"
    grep -Fq -- '--remove-label hold-release' "$case_dir/gh.log" || fail "$case_id: expected hold-release rollback"
    [[ ! -s "$case_dir/labels" ]] || fail "$case_id: rolled-back hold-release must not remain"
  elif [[ "$expect_hold" == already ]]; then
    if grep -Fq -- '--add-label hold-release' "$case_dir/gh.log"; then fail "$case_id: must not add an already-present hold"; fi
    if grep -Fq -- '--squash' "$case_dir/gh.log"; then fail "$case_id: must not merge with a hold"; fi
    [[ "$(sed -n '1p' "$case_dir/label-observations")" == absent ]] || fail "$case_id: first PR read must not show hold-release"
    [[ "$(sed -n '2p' "$case_dir/label-observations")" == hold-release ]] || fail "$case_id: second PR read must show hold-release"
  else
    if grep -Fq 'pr edit 331' "$case_dir/gh.log"; then fail "$case_id: must not add hold-release"; fi
  fi
  if [[ "$expect_merge" == yes ]]; then
    grep -Fq -- '--squash' "$case_dir/gh.log" || fail "$case_id: expected merge"
    grep -Fq -- "--match-head-commit $SHA" "$case_dir/gh.log" || fail "$case_id: merge must pin the checked head SHA"
  else
    if grep -Fq -- '--squash' "$case_dir/gh.log"; then fail "$case_id: must not merge"; fi
  fi
  if [[ -n "$expected_text" ]]; then
    grep -Fq "$expected_text" <<< "$output" || fail "$case_id: missing output '$expected_text'; output: $output"
  fi
  printf 'PASS: %s\n' "$case_id"
}

# These changed-behavior cases are individually run against origin/main
# before implementation, then must pass against this branch.
run_case cancelled-superseded-head cancelled "$SHA
$MOVED_SHA" 0 no no "head moved"
run_case cancelled-current-head cancelled "$SHA
$SHA" 1 no no cancelled
run_case stale-current-head stale "$SHA
$SHA" 1 no no stale
run_case failed-superseded-head failure "$SHA
$MOVED_SHA" 0 no no "head moved"
run_case failed-head-moves-during-hold failure "$SHA
$SHA
$MOVED_SHA" 0 rollback no "after hold-release was applied"
run_case failed-current-head-already-held failure "$SHA
$SHA" 1 already no "hold-release was already present" 2

# Existing invariants remain covered: a genuine failure on the current head
# holds the release, while an all-green head merges only the SHA it checked.
run_case failed-current-head failure "$SHA
$SHA" 1 yes no company-seed-renderer
run_case timed-out-current-head timed_out "$SHA
$SHA" 1 yes no company-seed-renderer
run_case action-required-current-head action_required "$SHA
$SHA" 1 yes no company-seed-renderer
run_case all-green success "$SHA
$SHA" 0 no yes "Merged hq-core PR #331"

if [[ -z "$GATE_TEST_CASE" ]]; then
  PROMOTE_WORKFLOW="$ROOT/.github/workflows/promote-to-hq-core.yml"
  RECHECK_WORKFLOW="$ROOT/.github/workflows/recheck-hq-core-release-gate.yml"
  grep -Fq 'path: staging' "$PROMOTE_WORKFLOW" || fail "promotion workflow must check out staging under staging/"
  grep -Fq 'run: bash staging/core/scripts/release-pr-check-gate.sh ' "$PROMOTE_WORKFLOW" || fail "promotion workflow must invoke the gate from staging/"
  grep -Fq '      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4' "$RECHECK_WORKFLOW" || fail "recheck workflow must check out the repository root"
  if grep -Fq 'path:' "$RECHECK_WORKFLOW"; then fail "recheck workflow checkout must remain at the repository root"; fi
  grep -Fq 'bash core/scripts/release-pr-check-gate.sh ' "$RECHECK_WORKFLOW" || fail "recheck workflow must invoke the gate from its root checkout"
  printf '%s\n' 'PASS: promotion and scheduled recheck workflows invoke the gate from their checkout paths'
fi
