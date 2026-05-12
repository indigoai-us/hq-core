#!/bin/bash
# One-time backfill: walk workspace/threads/*.json and replay each through
# the mirror hook so existing sessions are represented in their companies'
# workspace/ folders.
#
# Idempotent: hardlinks use ln -f, index.jsonl rows are deduped by
# (thread_id, ts, kind). Safe to re-run.
#
# Usage:  bash core/scripts/backfill-workspace-mirror.sh [HQ_ROOT]

set -euo pipefail

HQ_ROOT="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
HOOK="$HQ_ROOT/.claude/hooks/mirror-thread-to-company.sh"
THREADS_DIR="$HQ_ROOT/workspace/threads"

[ -x "$HOOK" ] || { echo "Mirror hook missing or not executable: $HOOK" >&2; exit 1; }
[ -d "$THREADS_DIR" ] || { echo "No threads dir at $THREADS_DIR" >&2; exit 1; }

mirrored=0
skipped=0
total=0

for thread in "$THREADS_DIR"/T-*.json; do
  [ -f "$thread" ] || continue
  total=$((total + 1))

  has_company=$(jq -r 'if .metadata.company then "yes" else "no" end' "$thread" 2>/dev/null || echo "no")
  if [ "$has_company" != "yes" ]; then
    skipped=$((skipped + 1))
    continue
  fi

  printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$thread" \
    | bash "$HOOK"

  mirrored=$((mirrored + 1))
done

echo "Backfill complete:"
echo "  Total threads:   $total"
echo "  Mirrored:        $mirrored"
echo "  Skipped (no co): $skipped"
echo
echo "Per-company index.jsonl row counts:"
for index_file in "$HQ_ROOT"/companies/*/workspace/index.jsonl; do
  [ -f "$index_file" ] || continue
  co=$(basename "$(dirname "$(dirname "$index_file")")")
  rows=$(wc -l < "$index_file" | tr -d ' ')
  printf "  %-20s %s rows\n" "$co" "$rows"
done
