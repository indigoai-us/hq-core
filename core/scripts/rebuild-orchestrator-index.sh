#!/usr/bin/env bash
# rebuild-orchestrator-index.sh — regenerate workspace/orchestrator/INDEX.md.
#
# Pure bash + jq. Reads workspace/orchestrator/<project>/state.json files.
# Tolerates two on-disk schemas: project-run state (run-project.sh — .project,
# .prd_path, .progress, terminal on .status == "completed") and garden state
# (/garden — .run_id, .scope, .findings_count, terminal on .phase == "complete").
# Lists only non-terminal runs; _archive/ and _pipeline/ excluded.
# Each state.json is parsed independently: a malformed file is reported to stderr
# and skipped, never silently wiping the rest of the index
# (see core/policies/hq-never-swallow-errors.md).

set -euo pipefail

HQ_ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
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

# Project column: .project (project-run) else .run_id (garden) else "-".
# Company column: parsed from .prd_path (project-run) or .scope (garden); a bare
#   slug or non-companies/ path yields "-". Progress: only project-run rows carry
#   .progress; garden rows render "-". Terminal exclusion keys off BOTH
#   .status == "completed"/"complete" (project-run + drift guard) AND
#   .phase == "complete" (garden's real terminal marker).
ROW_FILTER='
  select((.status // "") != "completed" and (.status // "") != "complete")
  | select((.phase // "") != "complete")
  | [
      (.project // .run_id // "-"),
      (((.prd_path // .scope // "") | capture("companies/(?<co>[^/]+)/") | .co) // "-"),
      (.status // "-"),
      (if .progress
       then ((.progress.completed // 0) | tostring) + "/" + ((.progress.total // 0) | tostring)
       else "-" end),
      (.updated_at // "-")
    ] | @tsv
'

ERR_FILE=$(mktemp)
trap 'rm -f "$ERR_FILE"' EXIT

NL=$'\n'
rows=""
# Guard the array expansion: "${arr[@]}" on an empty array errors under `set -u`
# on bash 3.2 (macOS). See core/policies/hq-bash-discipline.md rule 4.
if [[ ${#STATE_FILES[@]} -gt 0 ]]; then
  for sf in "${STATE_FILES[@]}"; do
    row=""
    if row=$(jq -r "$ROW_FILTER" "$sf" 2>"$ERR_FILE"); then
      [ -n "$row" ] && rows="${rows:+$rows$NL}$row"
    else
      echo "rebuild-orchestrator-index: WARNING: skipped unparseable ${sf}: $(tr '\n' ' ' < "$ERR_FILE")" >&2
    fi
  done
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
