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
    auto_merge='{"mergeMethod":"SQUASH"}'
    printf '{"headRefOid":"%s","autoMergeRequest":%s,"labels":%s}\n' "$head_sha" "$auto_merge" "$labels"
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
  # Auto-merge is armed in every case; only a hold-release may disarm it.
  if [[ "$expect_hold" == already ]]; then
    grep -Fq -- '--disable-auto' "$case_dir/gh.log" || fail "$case_id: a held PR must have auto-merge disarmed"
  elif grep -Fq -- '--disable-auto' "$case_dir/gh.log"; then
    fail "$case_id: must leave auto-merge armed on a release PR without hold-release"
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
run_case failed-current-head-already-held failure "$SHA
$SHA" 1 already no "hold-release was already present" 2

# A genuine failure on the current head refuses the merge but never labels the
# PR: release PRs stay ready to merge, and the scheduled recheck merges them
# once the checks pass. An all-green head merges only the SHA it checked.
run_case failed-current-head failure "$SHA
$SHA" 1 no no company-seed-renderer
run_case timed-out-current-head timed_out "$SHA
$SHA" 1 no no company-seed-renderer
run_case action-required-current-head action_required "$SHA
$SHA" 1 no no company-seed-renderer
run_case all-green success "$SHA
$SHA" 0 no yes "Merged hq-core PR #331"

if [[ -z "$GATE_TEST_CASE" ]]; then
  PROMOTE_WORKFLOW="$ROOT/.github/workflows/promote-to-hq-core.yml"
  RECHECK_WORKFLOW="$ROOT/.github/workflows/recheck-hq-core-release-gate.yml"
  grep -Fq 'path: staging' "$PROMOTE_WORKFLOW" || fail "promotion workflow must check out staging under staging/"
  grep -Fq 'run: bash staging/core/scripts/release-pr-check-gate.sh ' "$PROMOTE_WORKFLOW" || fail "promotion workflow must invoke the gate from staging/"
  # hq-core linux-checks-2/-3 run past 10 minutes; a 600s wait timed out every promotion.
  gate_wait="$(sed -nE 's/.*release-pr-check-gate\.sh "\$TARGET_REPO" "\$PR_NUMBER" "\$PR_HEAD_SHA" ([0-9]+) [0-9]+.*/\1/p' "$PROMOTE_WORKFLOW")"
  [[ -n "$gate_wait" ]] && (( gate_wait >= 1800 )) || fail "promotion gate must wait at least 1800s for hq-core checks (got '${gate_wait}')"
  grep -Fq 'gh pr merge "$NUM" --repo "$TARGET_REPO" --auto --squash --match-head-commit "$PR_HEAD_SHA"' "$PROMOTE_WORKFLOW" || fail "promotion workflow must arm auto-merge on the release PR"
  # The workflow disarms auto-merge only on a held PR (hq-core #366 lost it to
  # an unconditional disarm before every update).
  [[ "$(grep -Fc -- '--disable-auto' "$PROMOTE_WORKFLOW")" == 1 ]] || fail "promotion workflow must disarm auto-merge in exactly one place"
  grep -Fq "(any(.labels[]?.name; . == \"hold-release\")) and (.autoMergeRequest != null)" "$PROMOTE_WORKFLOW" || fail "promotion workflow may disarm auto-merge only when hold-release is present"
  # Arm auto-merge on the commit this run pushed, not a possibly stale API read.
  grep -Fq 'PR_HEAD_SHA="$(git rev-parse "refs/heads/${BRANCH}")"' "$PROMOTE_WORKFLOW" || fail "promotion workflow must take the PR head from the pushed branch"
  # Executed commands only; the PR body still tells humans how to add a hold.
  if grep -Eq -- '^[[:space:]]*gh pr edit .*--add-label[[:space:]]+hold-release' "$PROMOTE_WORKFLOW" "$GATE"; then fail "automation must never add hold-release"; fi
  grep -Fq '      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4' "$RECHECK_WORKFLOW" || fail "recheck workflow must check out the repository root"
  if grep -Fq 'path:' "$RECHECK_WORKFLOW"; then fail "recheck workflow checkout must remain at the repository root"; fi
  grep -Fq 'bash core/scripts/release-pr-check-gate.sh ' "$RECHECK_WORKFLOW" || fail "recheck workflow must invoke the gate from its root checkout"
  printf '%s\n' 'PASS: promotion and scheduled recheck workflows invoke the gate from their checkout paths'
fi

# ── Promote on dispatch only, and the open release PR guard ──
# Promote must not run on push: each staging merge and its Auto-beta stamp
# commit used to force-push the release PR and restart the hq-core checks.
GUARD="$ROOT/core/scripts/promote-release-pr-guard.sh"
[ -x "$GUARD" ] || fail "open release PR guard is missing"
mkdir -p "$TMP/guardbin"
cat > "$TMP/guardbin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$GUARD_LOG"
case "$*" in
  *'pr list '*) printf '%s\n' "${GUARD_OPEN_PR:-}" ;;
  *'pr view '*)
    held=false; approved=false
    [[ "${GUARD_HELD:-no}" == yes ]] && held=true
    [[ "${GUARD_APPROVED:-no}" == yes ]] && approved=true
    printf '%s %s\n' "$held" "$approved" ;;
  *) printf 'unexpected gh invocation: %s\n' "$*" >&2; exit 90 ;;
esac
GH
chmod +x "$TMP/guardbin/gh"

guard_case() {
  local id="$1" open_pr="$2" held="$3" approved="$4" force="$5" expected_rc="$6" expected_text="$7"
  [[ -z "$GATE_TEST_CASE" || "$GATE_TEST_CASE" == "guard-$id" ]] || return 0
  local dir="$TMP/guard-$id" out rc
  mkdir -p "$dir"
  : > "$dir/gh.log"
  set +e
  out="$(PATH="$TMP/guardbin:$PATH" GUARD_LOG="$dir/gh.log" GUARD_OPEN_PR="$open_pr" \
    GUARD_HELD="$held" GUARD_APPROVED="$approved" GITHUB_OUTPUT="$dir/out" \
    bash "$GUARD" "$REPO" promote/auto-main "$force" 2>&1)"
  rc=$?
  set -e
  [[ "$rc" == "$expected_rc" ]] || fail "guard $id: expected exit $expected_rc, got $rc; output: $out"
  grep -Fq -- "$expected_text" <<< "$out" || fail "guard $id: missing '$expected_text'; output: $out"
  if grep -Eq 'pr (merge|edit|close)|push' "$dir/gh.log"; then fail "guard $id: guard must only read PR state"; fi
  grep -Fxq "existing=${open_pr}" "$dir/out" || fail "guard $id: must record existing=${open_pr}"
  printf 'PASS: guard %s\n' "$id"
}
guard_case no-open-pr '' no no false 0 'a new release PR will be opened'
guard_case open-unapproved 392 no no false 0 'updated in place'
guard_case approved-no-force 392 no yes false 3 'already open and approved'
guard_case approved-force 392 no yes true 0 'force=true'
guard_case held-no-force 392 yes no false 3 'hold-release'
guard_case held-force 392 yes no true 3 'hold-release'
guard_case held-approved-force 392 yes yes true 3 'hold-release'

if [[ -z "$GATE_TEST_CASE" ]]; then
  PROMOTE_WORKFLOW="$ROOT/.github/workflows/promote-to-hq-core.yml"
  on_keys="$(awk '/^on:[[:space:]]*$/ {f=1; next} f && /^[^[:space:]#]/ {exit} f && /^  [a-z_]+:/ {sub(/:.*/,""); gsub(/ /,""); print}' "$PROMOTE_WORKFLOW")"
  [[ "$on_keys" == workflow_dispatch ]] || fail "promotion workflow must trigger only on workflow_dispatch (got: $(tr '\n' ' ' <<< "$on_keys"))"
  grep -Eq '^      force:$' "$PROMOTE_WORKFLOW" || fail "promotion dispatch must offer a force input"
  if grep -Fq '"$EVENT" = "push"' "$PROMOTE_WORKFLOW"; then fail "promotion workflow must not branch on a push event"; fi
  grep -Fq 'run: bash staging/core/scripts/promote-release-pr-guard.sh "$TARGET_REPO" "$BRANCH" "${INPUT_FORCE:-false}"' "$PROMOTE_WORKFLOW" || fail "promotion workflow must run the open-PR guard"
  # The guard step must come before every push to hq-core.
  guard_line="$(grep -n 'promote-release-pr-guard.sh' "$PROMOTE_WORKFLOW" | head -1 | cut -d: -f1)"
  push_count=0
  while IFS=: read -r ln _; do
    push_count=$((push_count + 1))
    (( ln > guard_line )) || fail "promotion workflow pushes (line $ln) before the open-PR guard (line $guard_line)"
  done < <(grep -n 'git push' "$PROMOTE_WORKFLOW")
  (( push_count > 0 )) || fail "expected git push steps in the promotion workflow"
  # Closing the standing PR is guarded too: a held or approved PR is never closed.
  close_block="$(awk '/- name: Close stale standing PR/ {f=1} f && /- name: Build PR body/ {exit} f {print}' "$PROMOTE_WORKFLOW")"
  grep -Fq 'gh pr close' <<< "$close_block" || fail "expected the stale standing PR close step"
  grep -Fq 'if ! bash staging/core/scripts/promote-release-pr-guard.sh "$TARGET_REPO" "$BRANCH" "${INPUT_FORCE:-false}"; then' <<< "$close_block" \
    || fail "closing the standing PR must go through the open-PR guard"
  (( $(grep -n 'promote-release-pr-guard' <<< "$close_block" | head -1 | cut -d: -f1) < $(grep -n 'gh pr close' <<< "$close_block" | cut -d: -f1) )) \
    || fail "the guard must run before gh pr close"
  grep -Fq 'refs/heads/main' "$PROMOTE_WORKFLOW" || fail "patch-train dispatch must be limited to main"
  # No other workflow may dispatch or chain into promote.
  for wf in "$ROOT"/.github/workflows/*.yml; do
    [[ "$wf" == "$PROMOTE_WORKFLOW" ]] && continue
    if grep -Eq 'workflow run promote-to-hq-core|promote-to-hq-core\.yml/dispatches|workflow_run:' "$wf" \
       && grep -Fq 'Promote to hq-core' "$wf"; then
      fail "$(basename "$wf") must not dispatch or chain into promote-to-hq-core"
    fi
  done
  printf '%s\n' 'PASS: promotion runs on dispatch only and guards held/approved release PRs before any push'
fi
