#!/usr/bin/env bash
set -euo pipefail

workflow_root="${CI_RUNNER_WORKFLOW_ROOT:-.}"
workflow="$workflow_root/.github/workflows/pr-checks.yml"

python3 - "$workflow" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.is_file():
    raise SystemExit(f"FAIL: missing workflow file: {path}")

jobs = {}
current = None
in_jobs = False
for line in path.read_text().splitlines():
    if line == "jobs:":
        in_jobs = True
        continue
    if not in_jobs:
        continue
    match = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
    if match:
        current = match.group(1)
        jobs[current] = None
        continue
    if current is not None and line.startswith("    runs-on:"):
        jobs[current] = line.split(":", 1)[1].strip()

if not jobs or any(runner is None for runner in jobs.values()):
    raise SystemExit("FAIL: could not identify every job runner in pr-checks.yml")

expected_platform_jobs = {
    "shell-smoke-macos": "macos-latest",
    "shell-smoke-windows": "windows-latest",
}
errors = []
for job, runner in jobs.items():
    expected = expected_platform_jobs.get(job, "ubuntu-24.04-arm")
    if runner != expected:
        errors.append(f"{job}: expected {expected}, found {runner}")
if errors:
    raise SystemExit("FAIL: unexpected runner labels:\n" + "\n".join(errors))

print(f"PASS: {len(jobs)} pr-checks jobs use the expected ARM, macOS, or Windows runner")
PY
