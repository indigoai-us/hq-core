#!/usr/bin/env bash
# Keep pr-checks.yml's pinned hq CLI install steps synchronized with shell tests that
# exercise one of core/scripts' CLI forwarders.

set -euo pipefail

ROOT="${FORWARDER_CI_CONTRACT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"

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
import os

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
required_cli_tests: set[str] = set()
for test_path in tests_dir.rglob("*"):
    if not test_path.is_file():
        continue
    relative_path = test_path.relative_to(root).as_posix()
    source = test_path.read_text(encoding="utf-8", errors="replace")
    if "HQ_CLI_REQUIRED_IN_CI:" in "\n".join(source.splitlines()[:12]):
        required_cli_tests.add(relative_path)
    for forwarder in forwarders:
        if references_forwarder(source, forwarder):
            references.add((relative_path, forwarder))

unknown_allowlist_entries = ALLOWLISTED_REFERENCES - references
if unknown_allowlist_entries and os.environ.get("FORWARDER_CI_CONTRACT_FIXTURE") != "1":
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
    r"(?:timeout\s+[0-9]+s\s+)?"
    r"(?:HQ_CLI_REQUIRED_IN_CI=1\s+)?"
    r"(?:bash|sh)\s+['\"]?"
    r"(core/scripts/tests/[A-Za-z0-9_.-]+)['\"]?(?=\s|$)"
)
required_install_tokens = ("bash core/scripts/ci/install-pinned-hq-cli.sh",)
required_cli_env_jobs: dict[str, set[str]] = defaultdict(set)

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
            if test_path in required_cli_tests and re.search(
                r"(?:^|[;&|]\s*|\n\s*)HQ_CLI_REQUIRED_IN_CI=1\s+"
                r"(?:bash|sh)\s+['\"]?"
                + re.escape(test_path)
                + r"['\"]?(?=\s|$)",
                run,
            ):
                required_cli_env_jobs[test_path].add(job_name)
        if all(token in run for token in required_install_tokens):
            jobs_with_hq_install.add(job_name)

failures: list[str] = []
for job_name in (
    "core-write-protection",
    "personal-policy-overlay",
    "prefer-native-capabilities",
):
    job = jobs.get(job_name)
    if not isinstance(job, dict):
        continue
    steps = job.get("steps", [])
    setup_node_indexes = [
        index
        for index, step in enumerate(steps)
        if isinstance(step, dict) and step.get("uses", "").startswith("actions/setup-node@")
    ]
    install_indexes = [
        index
        for index, step in enumerate(steps)
        if isinstance(step, dict)
        and isinstance(step.get("run"), str)
        and "bash core/scripts/ci/install-pinned-hq-cli.sh" in step["run"]
    ]
    if len(install_indexes) != 1 or not setup_node_indexes or install_indexes[0] <= setup_node_indexes[0]:
        failures.append(
            f"job {job_name} must install the pinned CLI exactly once after setup-node"
        )

if os.environ.get("FORWARDER_CI_CONTRACT_FIXTURE") != "1":
    policy_job = jobs.get("policy-forwarders")
    if not isinstance(policy_job, dict):
        failures.append("policy-forwarders job is missing")
    else:
        policy_steps = policy_job.get("steps", [])
        install_indexes = [
            index for index, step in enumerate(policy_steps)
            if isinstance(step, dict)
            and isinstance(step.get("run"), str)
            and "bash core/scripts/ci/install-pinned-hq-cli.sh" in step["run"]
        ]
        catalog_indexes = [
            index for index, step in enumerate(policy_steps)
            if isinstance(step, dict)
            and isinstance(step.get("run"), str)
            and "bash core/scripts/check-cli-hosted.sh" in step["run"]
        ]
        if len(install_indexes) != 1:
            failures.append("policy-forwarders must have exactly one pinned CLI install step")
        else:
            install_run = policy_steps[install_indexes[0]].get("run", "")
            for required in ("command -v hq", "hq core --help"):
                if required not in install_run:
                    failures.append(
                        f"policy-forwarders install step must validate the CLI with {required}"
                    )
        if len(catalog_indexes) != 1:
            failures.append("policy-forwarders must have exactly one CLI catalog check step")
        elif len(install_indexes) == 1 and catalog_indexes[0] <= install_indexes[0]:
            failures.append(
                "policy-forwarders catalog check must run after the CLI install step so "
                "GITHUB_PATH and GITHUB_ENV are applied"
            )

    health_job = jobs.get("hook-health-prevention")
    health_install_runs = [
        step.get("run", "")
        for step in health_job.get("steps", [])
        if isinstance(step, dict)
        and step.get("name") == "Install pinned hq CLI for doctor-path coverage"
    ] if isinstance(health_job, dict) else []
    if len(health_install_runs) != 1 or "bash core/scripts/ci/install-pinned-hq-cli.sh" not in health_install_runs[0]:
        failures.append(
            "hook-health-prevention must install the CLI selected from core.yaml and forwarded floors"
        )

catalog_job = jobs.get("cli-hosted-forwarders")
catalog_steps: list[dict[str, object]] = []
if isinstance(catalog_job, dict):
    for step in catalog_job.get("steps", []):
        if isinstance(step, dict) and step.get("name") == "Current published CLI catalog parity":
            catalog_steps.append(step)
if len(catalog_steps) != 1:
    failures.append(
        "cli-hosted-forwarders must have exactly one current published CLI catalog parity step"
    )
else:
    catalog_run = catalog_steps[0].get("run", "")
    required_catalog_fragments = (
        'current_prefix="$RUNNER_TEMP/hq-cli-current"',
        'npm_config_prefix="$current_prefix" bash core/scripts/ci/install-pinned-hq-cli.sh --version latest',
        'export PATH="$current_prefix/bin:$PATH"',
        "pinned hq-cli:",
        "current published hq-cli:",
        "HQ_CLI_REQUIRED_IN_CI=1 bash core/scripts/check-cli-hosted.sh",
    )
    if not isinstance(catalog_run, str) or not all(
        fragment in catalog_run for fragment in required_catalog_fragments
    ):
        failures.append(
            "current published CLI catalog parity must install latest in a separate npm prefix, "
            "print pinned and current versions, and require the catalog check"
        )

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
                "add the pinned hq CLI setup step"
            )

for test_path in sorted(required_cli_tests):
    matching_jobs = sorted(test_jobs.get(test_path, set()))
    if not matching_jobs:
        failures.append(
            f"{test_path} requires a real hq CLI in CI but no pr-checks job runs it"
        )
        continue
    for job_name in matching_jobs:
        if job_name not in jobs_with_hq_install:
            failures.append(
                f"job {job_name} runs CLI-required test {test_path} but lacks the "
                "pinned hq CLI install step"
            )
        if job_name not in required_cli_env_jobs.get(test_path, set()):
            failures.append(
                f"job {job_name} runs CLI-required test {test_path} without "
                "HQ_CLI_REQUIRED_IN_CI=1, so a rejected probe could be treated as a skip"
            )

if failures:
    for failure in failures:
        fail(failure)
    raise SystemExit(1)

print(
    "forwarder CI contract passed: "
    f"{len(forwarders)} forwarders, {len(references)} potential test references, "
    f"{len(NON_EXECUTING_REFERENCE_ALLOWLIST)} explicit fixture/comment allowlist entries, "
    f"{len(required_cli_tests)} tests marked as requiring a real hq CLI"
)
PY

if [ "${FORWARDER_CI_CONTRACT_SKIP_SELF_TEST:-0}" != "1" ]; then
  CONTRACT_FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/forwarder-ci-contract.XXXXXX")"
  trap 'rm -rf "$CONTRACT_FIXTURE"' EXIT
  mkdir -p "$CONTRACT_FIXTURE/core/scripts/tests" "$CONTRACT_FIXTURE/.github/workflows"
  cat > "$CONTRACT_FIXTURE/core/scripts/fixture-forwarder.sh" <<'SH'
#!/usr/bin/env bash
# FORWARDER — synthetic contract fixture
SH
  cat > "$CONTRACT_FIXTURE/core/scripts/tests/cli-required-fixture.test.sh" <<'SH'
#!/usr/bin/env bash
# HQ_CLI_REQUIRED_IN_CI: synthetic real CLI test
# References core/scripts/fixture-forwarder.sh.
SH
  cat > "$CONTRACT_FIXTURE/.github/workflows/pr-checks.yml" <<'YAML'
jobs:
  core-write-protection:
    steps:
      - uses: actions/setup-node@v4
      - run: bash core/scripts/ci/install-pinned-hq-cli.sh
      - run: bash core/scripts/ci/install-pinned-hq-cli.sh
  fixture:
    steps:
      - run: HQ_CLI_REQUIRED_IN_CI=1 bash core/scripts/tests/cli-required-fixture.test.sh
YAML
  if FORWARDER_CI_CONTRACT_ROOT="$CONTRACT_FIXTURE" FORWARDER_CI_CONTRACT_FIXTURE=1 \
    FORWARDER_CI_CONTRACT_SKIP_SELF_TEST=1 bash "${BASH_SOURCE[0]}" \
      >"$CONTRACT_FIXTURE/negative.out" 2>"$CONTRACT_FIXTURE/negative.err"; then
    echo "FAIL: CI contract accepted a real-CLI test without a pinned install step" >&2
    exit 1
  elif ! grep -F -q 'lacks the pinned hq CLI install step' "$CONTRACT_FIXTURE/negative.err" \
    || ! grep -F -q 'core-write-protection must install the pinned CLI exactly once after setup-node' "$CONTRACT_FIXTURE/negative.err"; then
    cat "$CONTRACT_FIXTURE/negative.err" >&2
    echo "FAIL: CI contract negative control failed for an unexpected reason" >&2
    exit 1
  fi
  cat > "$CONTRACT_FIXTURE/.github/workflows/pr-checks.yml" <<'YAML'
jobs:
  fixture:
    steps:
      - run: bash core/scripts/tests/cli-required-fixture.test.sh
      - run: bash core/scripts/ci/install-pinned-hq-cli.sh
YAML
  if FORWARDER_CI_CONTRACT_ROOT="$CONTRACT_FIXTURE" FORWARDER_CI_CONTRACT_FIXTURE=1 \
    FORWARDER_CI_CONTRACT_SKIP_SELF_TEST=1 bash "${BASH_SOURCE[0]}" \
      >"$CONTRACT_FIXTURE/unmarked.out" 2>"$CONTRACT_FIXTURE/unmarked.err"; then
    echo "FAIL: CI contract accepted a CLI-required test without required-mode behavior" >&2
    exit 1
  elif ! grep -F -q 'without HQ_CLI_REQUIRED_IN_CI=1' "$CONTRACT_FIXTURE/unmarked.err"; then
    cat "$CONTRACT_FIXTURE/unmarked.err" >&2
    echo "FAIL: CI contract environment negative control failed for an unexpected reason" >&2
    exit 1
  fi
  cat > "$CONTRACT_FIXTURE/.github/workflows/pr-checks.yml" <<'YAML'
jobs:
  cli-hosted-forwarders:
    steps:
      - run: bash core/scripts/ci/install-pinned-hq-cli.sh
      - run: HQ_CLI_REQUIRED_IN_CI=1 bash core/scripts/tests/cli-required-fixture.test.sh
      - name: Catalog parity without the published CLI step
        run: HQ_CLI_REQUIRED_IN_CI=1 bash core/scripts/check-cli-hosted.sh
YAML
  if FORWARDER_CI_CONTRACT_ROOT="$CONTRACT_FIXTURE" FORWARDER_CI_CONTRACT_FIXTURE=1 \
    FORWARDER_CI_CONTRACT_SKIP_SELF_TEST=1 bash "${BASH_SOURCE[0]}" \
      >"$CONTRACT_FIXTURE/no-current-cli.out" 2>"$CONTRACT_FIXTURE/no-current-cli.err"; then
    echo "FAIL: CI contract accepted a missing current-published CLI catalog step" >&2
    exit 1
  elif ! grep -F -q 'must have exactly one current published CLI catalog parity step' "$CONTRACT_FIXTURE/no-current-cli.err"; then
    cat "$CONTRACT_FIXTURE/no-current-cli.err" >&2
    echo "FAIL: current-published CLI negative control failed for an unexpected reason" >&2
    exit 1
  fi
  cat > "$CONTRACT_FIXTURE/.github/workflows/pr-checks.yml" <<'YAML'
jobs:
  cli-hosted-forwarders:
    steps:
      - run: bash core/scripts/ci/install-pinned-hq-cli.sh
      - run: HQ_CLI_REQUIRED_IN_CI=1 bash core/scripts/tests/cli-required-fixture.test.sh
      - name: Current published CLI catalog parity
        run: |
          pinned_hq="$(command -v hq)"
          pinned_version="$("$pinned_hq" --version)"
          current_prefix="$RUNNER_TEMP/hq-cli-current"
          npm_config_prefix="$current_prefix" bash core/scripts/ci/install-pinned-hq-cli.sh --version latest
          export PATH="$current_prefix/bin:$PATH"
          current_version="$(hq --version)"
          printf 'pinned hq-cli: %s\ncurrent published hq-cli: %s\n' "$pinned_version" "$current_version"
          HQ_CLI_REQUIRED_IN_CI=1 bash core/scripts/check-cli-hosted.sh
YAML
  FORWARDER_CI_CONTRACT_ROOT="$CONTRACT_FIXTURE" FORWARDER_CI_CONTRACT_FIXTURE=1 \
    FORWARDER_CI_CONTRACT_SKIP_SELF_TEST=1 bash "${BASH_SOURCE[0]}" \
      >"$CONTRACT_FIXTURE/positive.out" 2>"$CONTRACT_FIXTURE/positive.err" \
    || { cat "$CONTRACT_FIXTURE/positive.err" >&2; exit 1; }
  echo "forwarder CI contract negative controls passed: a real-CLI test without an install step or required-mode environment, and a current CLI parity step without the required setup, fail"
fi
