#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/resumework-benchmark.yml"
BENCHMARK="$ROOT/core/scripts/tests/resumework-benchmark.mjs"
SCALE_BENCHMARK="$ROOT/core/scripts/tests/resumework-lock-scale.mjs"

require_text() {
  local file="$1" text="$2"
  if ! grep -Fq -- "$text" "$file"; then
    printf 'FAIL: %s must contain %s\n' "$file" "$text" >&2
    exit 1
  fi
}

for trigger in 'workflow_dispatch:' 'pull_request:'; do
  require_text "$WORKFLOW" "$trigger"
done
for runner in 'windows-latest' 'ubuntu-latest'; do
  require_text "$WORKFLOW" "$runner"
done
require_text "$WORKFLOW" 'node core/scripts/tests/resumework-benchmark.mjs'
require_text "$WORKFLOW" 'bash core/scripts/tests/resumework-benchmark-workflow.test.sh'
require_text "$BENCHMARK" 'const expectedGeneratedFileCount = 6000;'
require_text "$BENCHMARK" 'const sampleCount = 5;'
python3 - "$BENCHMARK" <<'PYPOINTER'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
cleanup_start = source.index("function cleanup() {")
cleanup_end = source.index("\n}\n", cleanup_start) + 3
cleanup = source[cleanup_start:cleanup_end]
setup_start = source.index("fs.mkdirSync(homeNative, { recursive: true });")
setup_end = source.index("for (const dir of generatedDirectories)", setup_start)
setup = source[setup_start:setup_end]

restore = "fs.copyFileSync(currentBackup, currentPointer);"
save = "fs.copyFileSync(currentPointer, currentBackup);"
if restore not in cleanup or save in cleanup:
    raise SystemExit("FAIL: cleanup() must restore currentBackup to currentPointer")
if save not in setup or restore in setup:
    raise SystemExit("FAIL: setup must save currentPointer to currentBackup")
print("PASS: current pointer backup and restore directions are correct")
PYPOINTER
require_text "$ROOT/core/scripts/tests/resumework-timing.test.sh" 'MIN_RUNS="${RESUMEWORK_TIMING_MIN_RUNS:-20}"'
require_text "$BENCHMARK" "path.posix.join(rootPosix, '.claude/hooks/inject-policy-on-trigger.sh')"
require_text "$BENCHMARK" 'const policySessionId = `${runId}-policy-${i}`;'
for phase in tree_walk glob_scan policy_loading; do
  require_text "$BENCHMARK" "emitPhase('$phase'"
done
require_text "$BENCHMARK" 'phase=network_calls status=not_measured'
require_text "$BENCHMARK" 'phase=hook_chain p50_ms='
# Keep the report mapping in lockstep with the timing script's measured steps.
python3 - "$ROOT/core/scripts/tests/resumework-timing.test.sh" "$BENCHMARK" <<'PYCONTRACT'
import pathlib
import re
import sys

timing = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
benchmark = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
labels_block = re.search(r"(?m)^labels=\(([^)]*)\)$", timing)
if not labels_block:
    raise SystemExit("FAIL: could not read measured step labels from resumework-timing.test.sh")
measured_labels = re.findall(r'"([^"\n]+)"', labels_block.group(1))
steps_block = re.search(r"const measuredSteps = \[(.*?)\n  \];", benchmark, re.S)
if not steps_block:
    raise SystemExit("FAIL: benchmark has no measuredSteps report mapping")
reported_steps = re.findall(r"\{ label: '([^']+)', phase: '([^']+)' ", steps_block.group(1))
reported_labels = [label for label, _ in reported_steps]
if measured_labels != reported_labels:
    raise SystemExit(
        "FAIL: command phase mapping must match every timing step; "
        f"measured={measured_labels!r} reported={reported_labels!r}"
    )
if len(set(reported_labels)) != len(reported_labels):
    raise SystemExit("FAIL: command phase mapping contains duplicate measured labels")
if "const phaseLine = `phase=command_${step.phase}" not in benchmark:
    raise SystemExit("FAIL: measured command phases are not emitted as structured phase lines")
print(f"PASS: command phase coverage for {len(measured_labels)} measured steps")
PYCONTRACT
require_text "$BENCHMARK" 'phase=estimated_run_total p50_ms='
require_text "$BENCHMARK" 'status=not_measured prefetch_status='
require_text "$BENCHMARK" 'phase=index_reads elapsed_ms=0'
require_text "$BENCHMARK" 'scope_guard_reproduced='
require_text "$BENCHMARK" 'BLOCKED: Cross-company scope violation'
for runner in 'windows-latest' 'ubuntu-latest'; do
  require_text "$WORKFLOW" "$runner"
done
require_text "$WORKFLOW" 'scale_only:'
require_text "$WORKFLOW" 'node core/scripts/tests/resumework-lock-scale.mjs'
require_text "$SCALE_BENCHMARK" 'const sizes = [6000, 18000];'
require_text "$SCALE_BENCHMARK" 'const sampleCount = 3;'
require_text "$SCALE_BENCHMARK" 'RESUMEWORK_OPEN_STEPS_TIMINGS'
require_text "$SCALE_BENCHMARK" 'RESUMEWORK_TRACE_OPEN_STEPS=1'
require_text "$SCALE_BENCHMARK" 'EPOCHREALTIME'
require_text "$SCALE_BENCHMARK" 'stat_call_elapsed_p50_ms='

printf '%s\n' 'PASS: resumework-benchmark-workflow.test.sh'
