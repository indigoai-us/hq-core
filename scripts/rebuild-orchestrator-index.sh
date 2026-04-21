#!/usr/bin/env bash
# rebuild-orchestrator-index.sh — regenerate workspace/orchestrator/INDEX.md.
#
# Pure bash + jq. Reads workspace/orchestrator/<project>/state.json files.
# Lists only non-completed projects; _archive/ and _pipeline/ excluded.

set -euo pipefail

HQ_ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$HQ_ROOT"

OUT="workspace/orchestrator/INDEX.md"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

mkdir -p workspace/orchestrator

STATE_FILES=()
while IFS= read -r line; do
  STATE_FILES+=("$line")
done < <(
  find workspace/orchestrator -mindepth 2 -maxdepth 2 -name state.json 2>/dev/null \
    | grep -v '/_archive/' \
    | grep -v '/_pipeline/' \
    || true
)

rows=""
if [[ ${#STATE_FILES[@]} -gt 0 ]]; then
  rows=$(jq -rs '
    .[] | select((.status // "") != "completed") |
    [
      (.project // "-"),
      (((.prd_path // "") | capture("companies/(?<co>[^/]+)/") | .co) // "-"),
      (.status // "-"),
      ((.progress.completed // 0) | tostring) + "/" + ((.progress.total // 0) | tostring),
      (.updated_at // "-")
    ] | @tsv
  ' "${STATE_FILES[@]}" 2>/dev/null || true)
fi

{
  echo "# Orchestrator Projects"
  echo ""
  echo "Generated: ${TS}"
  echo ""
  echo "Active runs only. Archived runs in \`workspace/orchestrator/_archive/\`."
  echo ""
  echo "| Project | Company | Status | Progress | Last Updated |"
  echo "|---------|---------|--------|----------|--------------|"
  if [[ -n "$rows" ]]; then
    printf "%s\n" "$rows" | awk -F'\t' 'NF>=5 { printf "| %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5 }'
  fi
} > "$OUT"

active=$(printf "%s" "$rows" | grep -c . || true)
echo "rebuild-orchestrator-index: wrote ${OUT} (${active} active)" >&2
