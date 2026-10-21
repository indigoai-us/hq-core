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

# Staging Linux jobs run on self-hosted runners when the Linux ARM repository
# variable is set. Without the variable, and always for fork PRs and for
# hq-core, the job
# uses the hosted label.
STAGING_SAME_REPO = (
    "github.repository == 'indigoai-us/hq-core-staging' && "
    "(github.event_name != 'pull_request' || "
    "github.event.pull_request.head.repo.full_name == github.repository)"
)


def runner_expr(var: str, hosted: str) -> str:
    return (
        "${{ " + STAGING_SAME_REPO
        + f" && fromJSON(vars.{var} || '\"{hosted}\"') || '{hosted}' " + "}}"
    )


ARM = runner_expr("HQ_STAGING_RUNNER_LINUX_ARM", "ubuntu-24.04-arm")
expected_platform_jobs = {
    # macOS and Windows stay on GitHub-hosted runners.
    "shell-smoke-macos": "macos-latest",
    "shell-smoke-windows": "windows-latest",
    "codex-windows-hook-launcher": "windows-latest",
    # These jobs need passwordless sudo, which the self-hosted fleet lacks.
    "knowledge-repo-glob-shells": "ubuntu-24.04-arm",
    "company-jobs": "ubuntu-24.04-arm",
}
errors = []
for job, runner in jobs.items():
    expected = expected_platform_jobs.get(job, ARM)
    if runner != expected:
        errors.append(f"{job}: expected {expected}, found {runner}")
for job in sorted(set(expected_platform_jobs) - set(jobs)):
    errors.append(f"{job}: job is missing")
if errors:
    raise SystemExit("FAIL: unexpected runner labels:\n" + "\n".join(errors))

print(
    f"PASS: {len(jobs)} pr-checks jobs use the expected self-hosted-or-hosted "
    "ARM, macOS, or Windows runner"
)
PY
