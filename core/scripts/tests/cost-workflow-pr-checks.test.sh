#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/pr-checks.yml"
JOB="$(sed -n '/^  codex-pii-rubric:$/,/^  [[:alnum:]_-][[:alnum:]_-]*:$/p' "$WORKFLOW" | sed '$d')"
DENYLIST_JOB="$(sed -n '/^  denylist-scan:$/,/^  policy-rationale-scan:$/p' "$WORKFLOW" | sed '$d')"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

CONCURRENCY="$(sed -n '/^concurrency:$/,/^jobs:$/p' "$WORKFLOW" | sed '$d')"
grep -Fq 'group: pr-checks-${{ github.ref }}' <<< "$CONCURRENCY" \
  || fail 'runs must share the workflow ref concurrency group'
grep -Fqx '  cancel-in-progress: true' <<< "$CONCURRENCY" \
  || fail 'new runs must cancel superseded runs on the same ref'

# Workflows that gained a concurrency group share it per ref only in staging.
# Elsewhere the group is per run, so hq-core keeps its current behaviour.
for wf in audit-cleanup:true hook-registration:true release:false; do
  file="$ROOT/.github/workflows/${wf%%:*}.yml"
  block="$(sed -n '/^concurrency:$/,/^[a-z]/p' "$file")"
  grep -Fqx "  group: \${{ github.repository == 'indigoai-us/hq-core-staging' && format('{0}-{1}', github.workflow, github.ref) || format('{0}-{1}', github.workflow, github.run_id) }}" <<< "$block" \
    || fail "${wf%%:*} must use the staging-only per-ref concurrency group"
  grep -Fqx "  cancel-in-progress: ${wf##*:}" <<< "$block" \
    || fail "${wf%%:*} must set cancel-in-progress: ${wf##*:}"
done

# Staging PRs run hook registration on Linux only. Hosted macOS and Windows
# have no pull_request leg on staging; workflow_dispatch and hq-core keep all three.
HOOK_REG="$ROOT/.github/workflows/hook-registration.yml"
grep -Fqx "        os: \${{ fromJSON(github.repository == 'indigoai-us/hq-core-staging' && github.event_name == 'pull_request' && '[\"ubuntu-latest\"]' || '[\"ubuntu-latest\",\"macos-latest\",\"windows-latest\"]') }}" "$HOOK_REG" \
  || fail 'hook-registration must drop hosted macOS and Windows from staging pull requests and keep them elsewhere'
[ "$(grep -Ec '^        os: ' "$HOOK_REG")" -eq 1 ] \
  || fail 'hook-registration must define exactly one matrix os line'
grep -Fqx '  workflow_dispatch:' "$HOOK_REG" \
  || fail 'hook-registration must keep a manual run for the full matrix'

WINDOWS_JOB="$(sed -n '/^  shell-smoke-windows:$/,/^  shell-smoke-macos:$/p' "$WORKFLOW")"
grep -Fq '!cancelled()' <<< "$WINDOWS_JOB" \
  || fail 'Windows shell-smoke must stop when workflow concurrency cancels a superseded PR run'
if grep -Fq 'always()' <<< "$WINDOWS_JOB"; then
  fail 'Windows shell-smoke must not override workflow cancellation'
fi
WINDOWS_NODE_SETUP="$(sed -n '/      - uses: actions\/setup-node@v4/,/      - name: Install pinned hq CLI for forwarded scaffold scripts/p' <<< "$WINDOWS_JOB")"
grep -Fq '          cache: npm' <<< "$WINDOWS_NODE_SETUP" \
  || fail 'Windows shell-smoke must cache npm package downloads before installing the pinned CLI'
grep -Fq '            core/core.yaml' <<< "$WINDOWS_NODE_SETUP" \
  || fail 'Windows npm cache key must include the CLI floor source'
grep -Fq '            core/scripts/cli-hosted.yaml' <<< "$WINDOWS_NODE_SETUP" \
  || fail 'Windows npm cache key must include the hosted CLI minimum-version source'

MACOS_JOB="$(sed -n '/^  shell-smoke-macos:$/,/^  [[:alnum:]_-][[:alnum:]_-]*:$/p' "$WORKFLOW" | sed '$d')"
grep -Fq "needs['denylist-scan'].outputs.macos_shell_smoke == 'true'" <<< "$MACOS_JOB" \
  || fail 'macOS shell smoke must remain gated by the existing path filter'
grep -Fq '        run: bash core/scripts/tests/session-journal-cli-port.test.sh' <<< "$WINDOWS_JOB" \
  || fail 'Windows shell smoke must run the session-journal CLI port regression'
grep -Fq '        run: bash core/scripts/tests/session-journal-cli-port.test.sh' <<< "$MACOS_JOB" \
  || fail 'macOS shell smoke must run the session-journal CLI port regression'
if grep -Eq 'always\(\)|needs\[.denylist-scan.\].result != .success.' <<< "$MACOS_JOB"; then
  fail 'macOS shell smoke must not bypass its path filter for scan failures'
fi
# Hosted macOS and Windows run on dispatch, the schedule and staging release
# tags only. A push condition is allowed only as the staging release-tag clause.
SMOKE_TAG_CLAUSE="(github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v') && github.repository == 'indigoai-us/hq-core-staging')"
SMOKE_EVENTS="(github.event_name == 'workflow_dispatch' || github.event_name == 'schedule' || $SMOKE_TAG_CLAUSE)"
grep -Fq "\${{ $SMOKE_EVENTS" <<< "$MACOS_JOB" \
  || fail 'macOS shell smoke must run only on workflow_dispatch, the schedule and staging release tags (hosted macOS stays off pull requests)'
grep -Fq "&& $SMOKE_EVENTS" <<< "$WINDOWS_JOB" \
  || fail 'Windows shell smoke must run only on workflow_dispatch, the schedule and staging release tags (hosted Windows stays off pull requests)'
if grep -Fq "github.event_name == 'pull_request'" <<< "$MACOS_JOB$WINDOWS_JOB"; then
  fail 'hosted macOS and Windows shell smoke must not be reachable from pull_request events'
fi
for smoke_job in "$MACOS_JOB" "$WINDOWS_JOB"; do
  [ "$(grep -Fo "github.event_name == 'push'" <<< "$smoke_job" | wc -l | tr -d ' ')" -eq 1 ] \
    && [ "$(grep -Fo "$SMOKE_TAG_CLAUSE" <<< "$smoke_job" | wc -l | tr -d ' ')" -eq 1 ] \
    || fail 'hosted macOS and Windows shell smoke may key on push only through the staging release-tag clause'
done

grep -Fq '      - name: Hook timeout Sentry watchdog' <<< "$WINDOWS_JOB" \
  || fail 'Windows must keep the timing-sensitive Sentry watchdog in its isolated step'
grep -Fq '        run: bash core/scripts/tests/hook-timeout-sentry.test.sh' <<< "$WINDOWS_JOB" \
  || fail 'Windows must keep the Sentry watchdog test command'
[ "$(grep -Fxc '        run: bash core/scripts/tests/hook-timeout-sentry.test.sh' <<< "$WINDOWS_JOB")" -eq 1 ] \
  || fail 'Windows must run the Sentry watchdog once'
if grep -Fq '        run: bash core/scripts/tests/hook-timeout-watchdog-attribution.test.sh' <<< "$WINDOWS_JOB"; then
  [ "$(grep -Fxc '        run: bash core/scripts/tests/hook-timeout-watchdog-attribution.test.sh' <<< "$WINDOWS_JOB")" -eq 1 ] \
    || fail 'Windows must run the attribution test once'
  grep -Fq "          HQ_CLI_REQUIRED_IN_CI: '1'" <<< "$WINDOWS_JOB" \
    || fail 'Windows must preserve the required-in-CI attribution-test mode'
elif grep -Fq '        run: HQ_CLI_REQUIRED_IN_CI=1 bash core/scripts/tests/hook-timeout-watchdog-attribution.test.sh' <<< "$WINDOWS_JOB"; then
  : # Accept the original inline environment assignment while checking main.
else
  fail 'Windows must keep the attribution test command'
fi

[ "$(grep -Fxc '        run: bash core/scripts/ci/run-shell-smoke-timeout-tests.sh' <<< "$MACOS_JOB")" -eq 1 ] \
  || fail 'macOS must use the bounded parallel timeout-test runner exactly once'
grep -Fq "          HQ_CLI_REQUIRED_IN_CI: '1'" <<< "$MACOS_JOB" \
  || fail 'macOS must preserve the required-in-CI attribution-test mode'
HELPER="$ROOT/core/scripts/ci/run-shell-smoke-timeout-tests.sh"
grep -Fq 'core/scripts/tests/hook-timeout-sentry.test.sh' "$HELPER" \
  || fail 'the parallel runner must keep the Sentry watchdog test'
grep -Fq 'core/scripts/tests/hook-timeout-watchdog-attribution.test.sh' "$HELPER" \
  || fail 'the parallel runner must keep the watchdog attribution test'
grep -Fq 'bash core/scripts/tests/shell-smoke-timeout-runner.test.sh' <<< "$DENYLIST_JOB" \
  || fail 'the overlap and failure regression test must run in CI'

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

echo 'PASS: Windows npm cache and isolated timeout tests, main concurrency, macOS path gating and parallel timeout-test coverage, and batched rubric behavior'
