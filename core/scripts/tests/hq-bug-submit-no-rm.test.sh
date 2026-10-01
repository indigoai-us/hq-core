#!/usr/bin/env bash
set -euo pipefail

ROOT="${HQ_CORE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
SKILL="${ROOT}/.claude/skills/hq-bug/SKILL.md"
[[ -f "$SKILL" ]] || { echo "FAIL: hq-bug skill missing: $SKILL" >&2; exit 1; }

python3 - "$SKILL" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
commands = [
    (number, line.strip())
    for number, line in enumerate(path.read_text().splitlines(), start=1)
    if line.lstrip().startswith("hq feedback ")
]
if not commands:
    print("FAIL: no hq feedback submit commands found", file=sys.stderr)
    raise SystemExit(1)
failures = []
violations = [(number, command) for number, command in commands if "rm " in command]
for number, command in violations:
    failures.append(f"submit command at {path}:{number} contains rm: {command}")

text = path.read_text()
fixed_delimiter_lines = [number for number, line in enumerate(text.splitlines(), start=1) if line == "HQ_FEEDBACK_BODY"]
if fixed_delimiter_lines:
    failures.append("documented stdin command uses fixed HQ_FEEDBACK_BODY delimiter on line(s): " + ", ".join(map(str, fixed_delimiter_lines)))

step8 = text.split("### 8. Submit", 1)[-1].split("### 9. Report", 1)[0]
import re
template = re.search(r"Template:\s*```bash\n(.*?)\n```", step8, re.DOTALL)
# The primary template is the first bash block in Step 8; it must read the Write-tool file.
if template is None:
    blocks = re.findall(r"```bash\n(.*?)\n```", step8, re.DOTALL)
    template_text = blocks[0] if blocks else ""
else:
    template_text = template.group(1)
primary = next((line.strip() for line in template_text.splitlines() if line.lstrip().startswith("hq feedback ")), "")
if '--body-file "<body-path>"' not in primary:
    failures.append('primary Step 8 template must use --body-file "<body-path>"')

if failures:
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    raise SystemExit(1)
print(f"PASS: checked {len(commands)} submit commands; no rm, no fixed delimiter, primary template uses the body file")
PY
