#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/pr-checks.yml"
JOB="$(sed -n '/^  codex-pii-rubric:$/,/^  [[:alnum:]_-][[:alnum:]_-]*:$/p' "$WORKFLOW" | sed '$d')"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

CONCURRENCY="$(sed -n '/^concurrency:$/,/^jobs:$/p' "$WORKFLOW" | sed '$d')"
grep -Fq 'group: pr-checks-${{ github.ref }}' <<< "$CONCURRENCY" \
  || fail 'main pushes must share the workflow ref concurrency group'
grep -Fqx '  cancel-in-progress: true' <<< "$CONCURRENCY" \
  || fail 'new main pushes must cancel superseded main runs'

MACOS_JOB="$(sed -n '/^  shell-smoke-macos:$/,/^  [[:alnum:]_-][[:alnum:]_-]*:$/p' "$WORKFLOW" | sed '$d')"
grep -Fq "needs['denylist-scan'].outputs.macos_shell_smoke == 'true'" <<< "$MACOS_JOB" \
  || fail 'macOS shell smoke must remain gated by the existing path filter'
if grep -Eq 'always\(\)|github.event_name == .push.|needs\[.denylist-scan.\].result != .success.' <<< "$MACOS_JOB"; then
  fail 'macOS shell smoke must not bypass its path filter for main pushes or scan failures'
fi

grep -Fq 'POLICY_FILES: ${{ needs.collect-policy-changes.outputs.files }}' <<< "$JOB" \
  || fail 'the batched job must receive the complete changed-policy list'
grep -Fq 'while IFS= read -r file;' <<< "$JOB" \
  || fail 'the batched job must invoke the rubric once for each policy file'
grep -Fq "done < <(jq -r '.[]' <<< \"\$POLICY_FILES\")" <<< "$JOB" \
  || fail 'the policy list must be decoded from its JSON array'
grep -Fq 'bash .leak-scan/codex-rubric.sh "$file"' <<< "$JOB" \
  || fail 'each changed policy must be passed to the existing rubric command'
grep -Fq 'echo "## Rubric: $file"' <<< "$JOB" \
  || fail 'each policy verdict must have its own summary section'
grep -Fq 'if [[ "$failed" -ne 0 ]]; then' <<< "$JOB" \
  || fail 'any failed per-file rubric must fail the batched job'
if grep -Fq '    strategy:' <<< "$JOB"; then
  fail 'the rubric job still creates one matrix runner per policy file'
fi

echo 'PASS: main concurrency, macOS path gating, and batched rubric behavior'
