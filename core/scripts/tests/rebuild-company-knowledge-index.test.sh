#!/usr/bin/env bash
# Regression test for real-directory company knowledge indexing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/core/scripts/rebuild-company-knowledge-index.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

KNOWLEDGE="$TMP/hq/companies/acme/knowledge"
mkdir -p "$KNOWLEDGE/docs"
printf '# Team Guide\n' > "$KNOWLEDGE/guide.md"
printf '# Runbook\n' > "$KNOWLEDGE/docs/runbook.md"

HQ_ROOT="$TMP/hq" bash "$SCRIPT" >/dev/null
INDEX="$KNOWLEDGE/INDEX.md"

if ! grep -Fq '| `docs/` | 1 item(s) |' "$INDEX"; then
  echo "FAIL: knowledge directory row missing from INDEX.md" >&2
  exit 1
fi

if ! grep -Fq '| `guide.md` | Team Guide |' "$INDEX"; then
  echo "FAIL: knowledge file row missing from INDEX.md" >&2
  exit 1
fi

echo "rebuild-company-knowledge-index: 2 passed, 0 failed"
