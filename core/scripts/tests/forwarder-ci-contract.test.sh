#!/usr/bin/env bash
# Keep pr-checks.yml's hq CLI install steps synchronized with shell tests that
# exercise one of core/scripts' CLI forwarders.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

# The forwarder inventory is intentionally mechanical. Do not replace this
# with a manually maintained script list.
mapfile -t FORWARDERS < <(
  cd "$ROOT"
  grep -l 'FORWARDER —' core/scripts/*.sh
)

if [ "${#FORWARDERS[@]}" -eq 0 ]; then
  echo "FAIL: no core/scripts forwarders found" >&2
  exit 1
fi

python3 - "$ROOT" "${FORWARDERS[@]}" <<'PY'
from __future__ import annotations

from collections import defaultdict
from pathlib import Path
import re
import sys

try:
    import yaml
except ImportError as exc:
    raise SystemExit(
        "FAIL: forwarder CI contract requires PyYAML to parse "
        ".github/workflows/pr-checks.yml"
    ) from exc


root = Path(sys.argv[1])
forwarders = {Path(path).name for path in sys.argv[2:]}
tests_dir = root / "core/scripts/tests"
workflow_path = root / ".github/workflows/pr-checks.yml"

# Static shell analysis cannot always prove that a copied fixture is later
# executed. Therefore every forwarder name mentioned anywhere in a test is a
# potential execution until this pair is explicitly allowlisted. Entries below
# are intentionally limited to tests that install same-named fixture stubs or
# copies but are not run by pr-checks; add a pair here only with that rationale.
NON_EXECUTING_REFERENCE_ALLOWLIST = {
    ("core/scripts/tests/handoff-post-no-claude.test.sh", "archive-old-threads.sh"),
    ("core/scripts/tests/handoff-post-no-claude.test.sh", "rebuild-orchestrator-index.sh"),
    ("core/scripts/tests/handoff-post-no-claude.test.sh", "rebuild-threads-index.sh"),
    ("core/scripts/tests/handoff-followups-runtime.test.sh", "archive-old-threads.sh"),
    ("core/scripts/tests/handoff-followups-runtime.test.sh", "hq-status-summary.sh"),
    ("core/scripts/tests/handoff-followups-runtime.test.sh", "rebuild-orchestrator-index.sh"),
    ("core/scripts/tests/handoff-followups-runtime.test.sh", "rebuild-threads-index.sh"),
}

# This test's own allowlist contains forwarder names as Python metadata. The
# analyzer does not execute those scripts, so account for those references too.
ANALYZER_METADATA_ALLOWLIST = {
    ("core/scripts/tests/forwarder-ci-contract.test.sh", "archive-old-threads.sh"),
    ("core/scripts/tests/forwarder-ci-contract.test.sh", "hq-status-summary.sh"),
    ("core/scripts/tests/forwarder-ci-contract.test.sh", "rebuild-orchestrator-index.sh"),
    ("core/scripts/tests/forwarder-ci-contract.test.sh", "rebuild-threads-index.sh"),
    # Named in references_forwarder()'s docstring as the worked example of the
    # suffix false positive it exists to prevent. Prose, not execution.
    ("core/scripts/tests/forwarder-ci-contract.test.sh", "worktree.sh"),
}
ALLOWLISTED_REFERENCES = (
    NON_EXECUTING_REFERENCE_ALLOWLIST | ANALYZER_METADATA_ALLOWLIST
)


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)


def references_forwarder(source: str, forwarder: str) -> bool:
    """True when `forwarder` appears as a filename in its own right.

    A plain substring test also fires on any LONGER filename that happens to end
    with the forwarder's name — e.g. the hook
    `10-Edit,Write,MultiEdit--block-repo-edits-use-worktree.sh` ends with
    `worktree.sh`, so a test that merely names that hook was reported as
    executing the worktree forwarder and told to install the hq CLI it never
    calls. Requiring the preceding character to be a non-filename character (or
    start of input) keeps a real `core/scripts/worktree.sh` reference matching
    while dropping the false positive. Deliberately still permissive about what
    FOLLOWS the name: static analysis cannot prove a mentioned script is never
    executed, which is what the allowlist below is for.
    """
    pattern = r"(?<![A-Za-z0-9_.\-])" + re.escape(forwarder)
    return re.search(pattern, source) is not None


references: set[tuple[str, str]] = set()
for test_path in tests_dir.rglob("*"):
    if not test_path.is_file():
        continue
    relative_path = test_path.relative_to(root).as_posix()
    source = test_path.read_text(encoding="utf-8", errors="replace")
    for forwarder in forwarders:
        if references_forwarder(source, forwarder):
            references.add((relative_path, forwarder))

unknown_allowlist_entries = ALLOWLISTED_REFERENCES - references
if unknown_allowlist_entries:
    for test_path, forwarder in sorted(unknown_allowlist_entries):
        fail(
            f"stale non-executing allowlist entry for {test_path} and "
            f"{forwarder}; remove it or restore the reference"
        )
    raise SystemExit(1)

with workflow_path.open(encoding="utf-8") as workflow_file:
    workflow = yaml.safe_load(workflow_file)

jobs = workflow.get("jobs") if isinstance(workflow, dict) else None
if not isinstance(jobs, dict):
    raise SystemExit("FAIL: .github/workflows/pr-checks.yml has no jobs mapping")

test_jobs: dict[str, set[str]] = defaultdict(set)
jobs_with_hq_install: set[str] = set()
# Find tests only when a workflow shell actually executes them. A raw test path
# can also appear in an array passed to shellcheck, which is not test execution.
# The separators cover independent commands in multiline shell blocks and after
# `&&`/`;`; unsupported command syntax deliberately fails to map a test rather
# than silently accepting an unverified job.
test_command_pattern = re.compile(
    r"(?:^|[;&|]\s*|\n\s*)"
    r"(?:bash|sh)\s+['\"]?"
    r"(core/scripts/tests/[A-Za-z0-9_.-]+)['\"]?(?=\s|$)"
)
required_install_tokens = (
    "npm install -g @indigoai-us/hq-cli",
    "command -v hq",
    "hq core --help",
)

for job_name, job in jobs.items():
    if not isinstance(job, dict):
        continue
    for step in job.get("steps", []):
        if not isinstance(step, dict):
            continue
        run = step.get("run")
        if not isinstance(run, str):
            continue
        for test_path in test_command_pattern.findall(run):
            test_jobs[test_path].add(job_name)
        if all(token in run for token in required_install_tokens):
            jobs_with_hq_install.add(job_name)

failures: list[str] = []
covered_references = references - ALLOWLISTED_REFERENCES
for test_path, forwarder in sorted(covered_references):
    matching_jobs = sorted(test_jobs.get(test_path, set()))
    if not matching_jobs:
        failures.append(
            f"{test_path} references potential forwarder execution {forwarder}, "
            "but no pr-checks job runs this test; wire it into a job with the "
            "hq CLI install/validation step"
        )
        continue
    for job_name in matching_jobs:
        if job_name not in jobs_with_hq_install:
            failures.append(
                f"job {job_name} runs forwarder-dependent test {test_path} "
                f"({forwarder}) but lacks the hq CLI install/validation step; "
                "add the 'Install hq CLI for forwarded scaffold scripts' step"
            )

if failures:
    for failure in failures:
        fail(failure)
    raise SystemExit(1)

print(
    "forwarder CI contract passed: "
    f"{len(forwarders)} forwarders, {len(references)} potential test references, "
    f"{len(NON_EXECUTING_REFERENCE_ALLOWLIST)} explicit fixture/comment allowlist entries"
)
PY
