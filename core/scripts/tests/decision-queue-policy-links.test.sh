#!/usr/bin/env bash
# Regression: relative Markdown links in the decision-queue policy must resolve.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
POLICY="$ROOT/core/policies/decision-queue-one-at-a-time.md"

python3 - "$POLICY" <<'PY'
import re
import sys
from pathlib import Path
from urllib.parse import unquote

policy = Path(sys.argv[1])
missing = []

for line_number, line in enumerate(policy.read_text(encoding="utf-8").splitlines(), 1):
    for match in re.finditer(r"(?<!!)\[[^]]+\]\(([^)]+)\)", line):
        destination = match.group(1).strip().split(maxsplit=1)[0].strip("<>")
        if destination.startswith(("#", "/", "//")) or re.match(
            r"^[A-Za-z][A-Za-z0-9+.-]*:", destination
        ):
            continue
        relative_path = unquote(destination.split("#", 1)[0].split("?", 1)[0])
        if relative_path and not (policy.parent / relative_path).exists():
            missing.append(f"{policy}:{line_number}: missing relative link target: {destination}")

if missing:
    print("\n".join(missing), file=sys.stderr)
    raise SystemExit(1)

print("PASS: decision-queue policy relative links resolve")
PY
