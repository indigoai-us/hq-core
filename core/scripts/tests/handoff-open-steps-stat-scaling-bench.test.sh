#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
BENCH="${HANDOFF_STAT_SCALING_BENCH:-$ROOT/core/scripts/tests/handoff-open-steps-stat-scaling-bench.sh}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/handoff-stat-bench-failure-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

FAIL_BIN="$TMP/fail-bin"
mkdir -p "$FAIL_BIN"
cat > "$FAIL_BIN/python3" <<'PYTHON_SHIM'
#!/usr/bin/env bash
printf 'forced fixture measurement failure\n' >&2
exit 73
PYTHON_SHIM
chmod +x "$FAIL_BIN/python3"

output="$TMP/benchmark-output"
if PATH="$FAIL_BIN:$PATH" bash "$BENCH" >"$output" 2>&1; then
  printf 'FAIL: benchmark returned success after measure_size fixture preparation failed\n' >&2
  cat "$output" >&2
  exit 1
else
  status=$?
fi

if [[ "$status" -eq 0 ]]; then
  printf 'FAIL: benchmark failure status was lost\n' >&2
  exit 1
fi

printf 'PASS: benchmark propagated measure_size failure (exit=%s)\n' "$status"

FAIL_SCRIPT="$TMP/fail-script.sh"
cat > "$FAIL_SCRIPT" <<'SCRIPT_SH'
#!/usr/bin/env bash
printf 'forced measured command failure\n' >&2
exit 74
SCRIPT_SH
chmod +x "$FAIL_SCRIPT"

output="$TMP/benchmark-command-output"
if HANDOFF_OPEN_STEPS_SCRIPT="$FAIL_SCRIPT" bash "$BENCH" >"$output" 2>&1; then
  printf 'FAIL: benchmark returned success after the measured command failed\n' >&2
  cat "$output" >&2
  exit 1
else
  status=$?
fi

if [[ "$status" -eq 0 ]]; then
  printf 'FAIL: benchmark failure status was lost for the measured command\n' >&2
  exit 1
fi

printf 'PASS: benchmark propagated measured command failure (exit=%s)\n' "$status"
