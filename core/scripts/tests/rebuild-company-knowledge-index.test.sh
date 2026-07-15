#!/usr/bin/env bash
# Regression test for symlinked company knowledge directory indexing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/core/scripts/rebuild-company-knowledge-index.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/hq/companies/acme" "$TMP/knowledge/docs"
printf '# Team Guide\n' > "$TMP/knowledge/guide.md"
printf '# Runbook\n' > "$TMP/knowledge/docs/runbook.md"
ln -s "$TMP/knowledge" "$TMP/hq/companies/acme/knowledge"

HQ_ROOT="$TMP/hq" bash "$SCRIPT" >/dev/null
INDEX="$TMP/knowledge/INDEX.md"

if ! grep -Fq '| `docs/` | 1 item(s) |' "$INDEX"; then
  echo "FAIL: symlinked knowledge directory row missing from INDEX.md" >&2
  exit 1
fi

if ! grep -Fq '| `guide.md` | Team Guide |' "$INDEX"; then
  echo "FAIL: symlinked knowledge file row missing from INDEX.md" >&2
  exit 1
fi

echo "rebuild-company-knowledge-index: 2 passed, 0 failed"
