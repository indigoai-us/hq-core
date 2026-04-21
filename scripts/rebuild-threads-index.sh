#!/usr/bin/env bash
# rebuild-threads-index.sh — regenerate workspace/threads/INDEX.md from thread JSON files.
#
# Pure bash + jq. Zero Claude context. Reads active thread JSONs (not archive/),
# batches metadata through a single jq invocation (vs 1 subprocess per file).
#
# Usage:
#   scripts/rebuild-threads-index.sh              # regen INDEX.md
#   scripts/rebuild-threads-index.sh --recent     # regen recent.md only (last 15)
#   scripts/rebuild-threads-index.sh --both       # regen both

set -euo pipefail

HQ_ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$HQ_ROOT"

MODE="${1:---index}"

THREADS_DIR="workspace/threads"
INDEX_PATH="${THREADS_DIR}/INDEX.md"
RECENT_PATH="${THREADS_DIR}/recent.md"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

mkdir -p "$THREADS_DIR"

# Gather active thread files (exclude archive/), newest first by mtime.
# Portable (bash 3.x compatible) — avoid mapfile.
THREAD_FILES=()
while IFS= read -r line; do
  THREAD_FILES+=("$line")
done < <(ls -t "$THREADS_DIR"/T-*.json 2>/dev/null || true)
COUNT=${#THREAD_FILES[@]}

extract_metadata() {
  [[ $# -eq 0 ]] && return 0
  jq -rs '
    .[] | [
      (.thread_id // "-"),
      (.type // "-"),
      (.updated_at // "-"),
      ((.metadata.title // "-") | gsub("\\|"; "/") | gsub("\n"; " "))
    ] | @tsv
  ' "$@" 2>/dev/null || true
}

write_table() {
  local out="$1"; shift
  local title="$1"; shift
  local limit="$1"; shift
  # remaining args are files

  {
    echo "# ${title}"
    echo ""
    echo "Generated: ${TS}"
    echo "Active threads: ${COUNT} (archive/ excluded)"
    echo ""
    echo "| Thread | Type | Updated | Title |"
    echo "|--------|------|---------|-------|"
    if [[ $# -gt 0 ]]; then
      local rows
      rows=$(extract_metadata "$@")
      if [[ "$limit" -gt 0 ]]; then
        rows=$(printf "%s\n" "$rows" | head -n "$limit")
      fi
      printf "%s\n" "$rows" | awk -F'\t' 'NF>=4 { printf "| %s | %s | %s | %s |\n", $1, $2, $3, $4 }'
    fi
  } > "$out"
}

if [[ "$MODE" == "--index" || "$MODE" == "--both" ]]; then
  write_table "$INDEX_PATH" "Threads INDEX" 0 "${THREAD_FILES[@]}"
  echo "rebuild-threads-index: wrote ${INDEX_PATH} (${COUNT} threads)" >&2
fi

if [[ "$MODE" == "--recent" || "$MODE" == "--both" ]]; then
  write_table "$RECENT_PATH" "Recent Threads" 15 "${THREAD_FILES[@]}"
  echo "rebuild-threads-index: wrote ${RECENT_PATH} (last 15)" >&2
fi
