#!/usr/bin/env bash
# rebuild-public-knowledge-index.sh — regenerate core/knowledge/public/INDEX.md.
#
# Pure bash + jq. Lists each public-knowledge subdir with a file count.
# Description: prefer the subdir's README.md first heading, else first
# alphabetical .md file's first heading, else "{N} file(s)".

set -euo pipefail

HQ_ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$HQ_ROOT"

KNOWLEDGE_DIR="core/knowledge/public"
OUT="${KNOWLEDGE_DIR}/INDEX.md"
DATE=$(date -u +%Y-%m-%d)

[[ -d "$KNOWLEDGE_DIR" ]] || { echo "rebuild-public-knowledge-index: ${KNOWLEDGE_DIR}/ missing, skipping" >&2; exit 0; }

sanitize_cell() {
  printf '%s' "$1" | tr '\n' ' ' | sed -e 's/|/\\|/g' -e 's/  */ /g' -e 's/^ *//' -e 's/ *$//'
}
trunc() {
  local s="$1" n="$2"
  if [[ ${#s} -le $n ]]; then printf '%s' "$s"; else printf '%s…' "${s:0:$((n-1))}"; fi
}

heading_of() {
  awk '/^# / { sub(/^# +/, ""); print; exit }' "$1" 2>/dev/null || true
}

describe_subdir() {
  local d="$1"
  local n
  n=$(find "$d" -mindepth 1 -maxdepth 1 -name '*.md' ! -name 'INDEX.md' 2>/dev/null | wc -l | tr -d ' ')
  local readme="${d}/README.md"
  local h=""
  if [[ -f "$readme" ]]; then
    h=$(heading_of "$readme")
  fi
  if [[ -z "$h" ]]; then
    # First alphabetical .md file (excluding INDEX.md, README.md).
    local first
    first=$(find "$d" -mindepth 1 -maxdepth 1 -name '*.md' ! -name 'INDEX.md' ! -name 'README.md' 2>/dev/null | sort | head -1)
    [[ -n "$first" ]] && h=$(heading_of "$first")
  fi
  if [[ -n "$h" ]]; then
    echo "${h} (${n} file(s))"
  else
    echo "${n} file(s)"
  fi
}

{
  echo "# Public Knowledge"
  echo ""
  echo "> Auto-generated. Updated: ${DATE}"
  echo ""
  echo "| Name | Description |"
  echo "|------|-------------|"
  while IFS= read -r d; do
    name=$(basename "$d")
    [[ "$name" == .* ]] && continue
    desc=$(describe_subdir "$d")
    desc=$(sanitize_cell "$desc")
    desc=$(trunc "$desc" 100)
    printf '| `%s/` | %s |\n' "$name" "$desc"
  done < <(find "$KNOWLEDGE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

  # Loose top-level .md files
  while IFS= read -r f; do
    name=$(basename "$f")
    [[ "$name" == "INDEX.md" ]] && continue
    [[ "$name" == .* ]] && continue
    desc=$(heading_of "$f")
    [[ -z "$desc" ]] && desc="$name"
    desc=$(sanitize_cell "$desc")
    desc=$(trunc "$desc" 100)
    printf '| `%s` | %s |\n' "$name" "$desc"
  done < <(find "$KNOWLEDGE_DIR" -mindepth 1 -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort)
} > "$OUT"

n=$(find "$KNOWLEDGE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
echo "rebuild-public-knowledge-index: wrote ${OUT} (${n} subdir(s))" >&2
