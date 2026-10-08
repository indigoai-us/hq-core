#!/usr/bin/env bash
# policy-retrieval-report.sh — per-policy retrieval evidence from the durable
# retrieval ledger that .claude/hooks/record-policy-retrieval.sh appends to
# (workspace/orchestrator/policy-retrieval-ledger.jsonl).
#
# Prints, per policy:
#   last_retrieved  retrieval_count  path
# sorted stale-first: never-retrieved policies first, then oldest
# last_retrieved. A policy with no ledger rows shows `never` and 0.
#
# Usage: policy-retrieval-report.sh [policy-dir ...]
#        (no dirs: core/policies and personal/policies under HQ_ROOT)
#
# Kept separate from policy-age-report.sh, which is a generated forwarder to
# `hq core policy age-report` and must match the CLI-hosted manifest byte for byte.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}}"

command -v jq >/dev/null 2>&1 || { echo "policy-retrieval-report.sh: requires jq" >&2; exit 127; }
ret_dirs=("$@")
if [ "${#ret_dirs[@]}" -eq 0 ]; then
  for d in "$HQ_ROOT/core/policies" "$HQ_ROOT/personal/policies"; do
    [ -d "$d" ] && ret_dirs+=("$d")
  done
fi
[ "${#ret_dirs[@]}" -gt 0 ] || { echo "policy-retrieval-report.sh: no policy directories under $HQ_ROOT" >&2; exit 2; }
ret_ledger="$HQ_ROOT/workspace/orchestrator/policy-retrieval-ledger.jsonl"
ret_tmp="$(mktemp -d "${TMPDIR:-/tmp}/policy-retrieval-report.XXXXXX")" || { echo "policy-retrieval-report.sh: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$ret_tmp"' EXIT
: > "$ret_tmp/stats"
if [ -f "$ret_ledger" ]; then
  # slug <TAB> last ts <TAB> count
  jq -r '[.policy, .ts] | @tsv' "$ret_ledger" \
    | awk -F'\t' '{ n[$1]++; if ($2 > last[$1]) last[$1] = $2 } END { for (k in n) printf "%s\t%s\t%d\n", k, last[k], n[k] }' \
    > "$ret_tmp/stats" || { echo "policy-retrieval-report.sh: failed to read $ret_ledger" >&2; exit 1; }
fi
for d in "${ret_dirs[@]}"; do
  [ -d "$d" ] || { echo "policy-retrieval-report.sh: policy directory not found: $d" >&2; exit 2; }
  find "$d" -maxdepth 1 -type f -name '*.md' ! -name 'README.md' ! -name 'example-policy.md' ! -name '_digest*'
done > "$ret_tmp/files" || { echo "policy-retrieval-report.sh: failed to list policies" >&2; exit 1; }
printf 'last_retrieved\tretrieval_count\tpolicy\n'
awk -F'\t' -v root="$HQ_ROOT/" '
  FILENAME == ARGV[1] { last[$1] = $2; cnt[$1] = $3; next }
  {
    n = split($0, parts, "/"); slug = parts[n]; sub(/\.md$/, "", slug)
    rel = $0; if (index(rel, root) == 1) rel = substr(rel, length(root) + 1)
    # Sort key: "0" for never so it sorts before any ISO timestamp.
    if (slug in last) printf "%s\t%s\t%d\t%s\n", last[slug], last[slug], cnt[slug], rel
    else printf "0\tnever\t0\t%s\n", rel
  }
' "$ret_tmp/stats" "$ret_tmp/files" | LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k4,4 | cut -f2-
