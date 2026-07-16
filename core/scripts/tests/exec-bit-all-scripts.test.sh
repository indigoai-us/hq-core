#!/usr/bin/env bash
# exec-bit-all-scripts.test.sh — every tracked *.sh must be mode 100755 in the git index.
# Catches execute bits stripped by sync tools or careless add (US-004).
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

BAD="$(git ls-files -s -- '*.sh' | awk '$1 == "100644" { print $4 }')"
if [ -n "$BAD" ]; then
  echo "FAIL: tracked .sh files with mode 100644 (expected 100755):" >&2
  printf '%s\n' "$BAD" >&2
  echo "Fix: git update-index --chmod=+x -- <file>" >&2
  exit 1
fi

echo "ALL PASS: exec-bit-all-scripts (all tracked .sh are 100755)"
exit 0
