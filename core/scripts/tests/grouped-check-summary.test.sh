#!/usr/bin/env bash
# Regression test for core/scripts/ci/grouped-check-summary.sh, which lists
# per-former-job results for the grouped linux-checks-N jobs in pr-checks.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/core/scripts/ci/grouped-check-summary.sh"
WORKFLOW="$ROOT/.github/workflows/pr-checks.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail 'jq is required'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Fixture: alpha-job passed, beta-job failed on its second step (third step
# skipped), gamma-job was skipped, and non-test steps are ignored.
cat > "$tmp/steps.json" <<'JSON'
{
  "checkout": {"outcome": "success", "conclusion": "success"},
  "t_alpha_job__1": {"outcome": "success", "conclusion": "success"},
  "t_alpha_job__2": {"outcome": "success", "conclusion": "success"},
  "t_beta_job__1": {"outcome": "success", "conclusion": "success"},
  "t_beta_job__2": {"outcome": "failure", "conclusion": "failure"},
  "t_beta_job__3": {"outcome": "skipped", "conclusion": "skipped"},
  "t_gamma_job__1": {"outcome": "skipped", "conclusion": "skipped"}
}
JSON

summary="$tmp/summary.md"
: > "$summary"
set +e
out="$(STEPS_JSON="$(cat "$tmp/steps.json")" GITHUB_STEP_SUMMARY="$summary" bash "$SCRIPT" 2>&1)"
status=$?
set -e

[ "$status" -eq 0 ] || fail "summary script must only report and exit 0, got $status"
grep -Fqx '### Per-check results' "$summary" || fail 'summary heading missing'
grep -Fqx '| alpha-job | 2 | success | - |' "$summary" || fail 'alpha-job row wrong'
grep -Fqx '| beta-job | 3 | failure | 2 |' "$summary" || fail 'beta-job row must name the first failed step'
grep -Fqx '| gamma-job | 1 | skipped | - |' "$summary" || fail 'gamma-job row wrong'
if grep -Fq 'checkout' "$summary"; then
  fail 'non-test steps must not appear in the table'
fi
grep -Fqx '| Former job | Steps | Result | First failed step |' "$summary" || fail 'table header missing'
[ "$(grep -c '^| [a-z]' "$summary")" -eq 3 ] || fail 'expected exactly 3 job rows'

grep -Fqx '::error title=grouped check failed::beta-job' <<< "$out" \
  || fail 'a failed former job must be annotated with its name'
[ "$(grep -c '::error' <<< "$out")" -eq 1 ] || fail 'only failed former jobs may be annotated'

# Empty input reports and exits 0 without writing a table.
: > "$summary"
STEPS_JSON='' GITHUB_STEP_SUMMARY="$summary" bash "$SCRIPT" 2>/dev/null \
  || fail 'empty STEPS_JSON must exit 0'
[ ! -s "$summary" ] || fail 'empty STEPS_JSON must not write a table'

# Wiring: every grouped job ends with the summary step, and every former job
# in a group keeps at least one t_<job>__N step so it can be attributed.
python3 - "$WORKFLOW" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
blocks = re.split(r"(?m)^  (?=[A-Za-z0-9_-]+:\s*$)", text.split("\njobs:\n", 1)[1])
groups = 0
errors = []
for block in blocks:
    name = block.split(":", 1)[0]
    if not name.startswith("linux-checks-"):
        continue
    groups += 1
    if "run: bash core/scripts/ci/grouped-check-summary.sh" not in block:
        errors.append(f"{name}: missing Per-check results step")
    if "STEPS_JSON: \"${{ toJSON(steps) }}\"" not in block:
        errors.append(f"{name}: summary step must receive toJSON(steps)")
    members = set(re.findall(r"- name: \"?\[([a-z0-9-]+)\]", block))
    ids = {m.replace("_", "-") for m in re.findall(r"id: t_([a-z0-9_]+?)__\d+", block)}
    for member in sorted(members - ids):
        errors.append(f"{name}: member {member} has no t_<job>__N step id")
    for job_id in sorted(ids - members):
        errors.append(f"{name}: step id t_{job_id} has no [member] step name")
if groups == 0:
    errors.append("no linux-checks-N grouped jobs found")
if errors:
    raise SystemExit("FAIL: " + "\n".join(errors))
print(f"grouped wiring ok: {groups} grouped jobs")
PY

echo 'PASS: grouped-check-summary'
