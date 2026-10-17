#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/pr-checks.yml"
WINDOWS_JOB="$(awk '
  /^  shell-smoke-windows:$/ { in_job=1; next }
  in_job && /^  [[:alnum:]_-]+:$/ { exit }
  in_job { print }
' "$WORKFLOW")"
fail() { echo "FAIL: $*" >&2; exit 1; }

grep -Fq 'name: Measure hook benchmark on Git Bash' <<<"$WINDOWS_JOB" \
  || fail 'shell-smoke-windows is missing the Git Bash hook benchmark step'
grep -Fq 'bash core/scripts/bench-hook-corpus.sh run --corpus core/scripts/bench-hook-corpus-default.json' <<<"$WINDOWS_JOB" \
  || fail 'benchmark step must run the default hook corpus'
grep -Fq 'bash core/scripts/bench-hooks.sh --tool Bash' <<<"$WINDOWS_JOB" \
  || fail 'benchmark step must run bench-hooks.sh for Bash'
grep -Fq 'p50_ms=' <<<"$WINDOWS_JOB" \
  || fail 'benchmark step must print per-Bash-call p50'
grep -Fq 'p95_ms=' <<<"$WINDOWS_JOB" \
  || fail 'benchmark step must print per-Bash-call p95'
grep -Fq 'actions/upload-artifact@v4' <<<"$WINDOWS_JOB" \
  || fail 'shell-smoke-windows must upload the raw benchmark result'
grep -Fq 'if: ${{ !cancelled() }}' <<<"$WINDOWS_JOB" \
  || fail 'benchmark artifact upload must respect workflow cancellation'

grep -Fq 'run: bash .claude/hooks/tests/inject-policy-fact-helper-windows-shim.test.sh' <<<"$WINDOWS_JOB" \
  || fail 'shell-smoke-windows must run the npm hq shim policy-hook regression (US-001)'
grep -Fq 'run: bash core/scripts/tests/master-hook-hqd-socket-path.test.sh' <<<"$WINDOWS_JOB" \
  || fail 'shell-smoke-windows must run the master-hook hqd socket path regression (US-001)'

echo 'PASS: Windows hook benchmark is wired into shell-smoke-windows'
