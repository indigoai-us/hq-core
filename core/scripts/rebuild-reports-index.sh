#!/usr/bin/env bash
# rebuild-reports-index.sh — regenerate workspace/reports/INDEX.md.
#
# Pure bash. Lists subdirs + individual report files. Skips the curated
# "Report Series" section — that's manually maintained by the gardener.
# Description: prefer first `#` heading for .md, <title> for .html.
# Date: parse YYYY-MM-DD or YYYY-Www prefix from filename, else "—".

set -euo pipefail

HQ_ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$HQ_ROOT"

OUT="workspace/reports/INDEX.md"
DATE=$(date -u +%Y-%m-%d)

[[ -d workspace/reports ]] || { echo "rebuild-reports-index: workspace/reports/ missing, skipping" >&2; exit 0; }

sanitize_cell() {
  printf '%s' "$1" | tr '\n' ' ' | sed -e 's/|/\\|/g' -e 's/  */ /g' -e 's/^ *//' -e 's/ *$//'
}
trunc() {
  local s="$1" n="$2"
  if [[ ${#s} -le $n ]]; then printf '%s' "$s"; else printf '%s…' "${s:0:$((n-1))}"; fi
}

heading_md() {
  awk '/^# / { sub(/^# +/, ""); print; exit }' "$1" 2>/dev/null || true
}
title_html() {
  awk 'BEGIN{IGNORECASE=1} /<title>/ { sub(/.*<title>/, ""); sub(/<\/title>.*/, ""); print; exit }' "$1" 2>/dev/null || true
}

extract_date() {
  local name="$1"
  if [[ "$name" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$name" =~ ^([0-9]{4}-W[0-9]{2}) ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo "—"
  fi
}

describe_file() {
  local f="$1"
  local name
  name=$(basename "$f")
  case "$name" in
    *.md)
      local h
      h=$(heading_md "$f")
      [[ -z "$h" ]] && h="${name%.md}"
      echo "$h"
      ;;
    *.html|*.htm)
      local t
      t=$(title_html "$f")
      [[ -z "$t" ]] && t="${name%.*}"
      echo "$t"
      ;;
    *)
      echo "${name}"
      ;;
  esac
}

describe_subdir() {
  local d="$1"
  local n
  n=$(find "$d" -mindepth 1 -maxdepth 1 ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')
  echo "${n} item(s)"
}

{
  echo "# Reports"
  echo ""
  echo "> Auto-generated. Updated: ${DATE}"
  echo ""
  echo "Personal/HQ reports only. Company reports moved to \`companies/{co}/data/reports/\`."
  echo ""
  echo "## Directories"
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
  done < <(find workspace/reports -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

  echo ""
  echo "## Individual Reports"
  echo ""
  echo "| Name | Date | Description |"
  echo "|------|------|-------------|"
  while IFS= read -r f; do
    name=$(basename "$f")
    [[ "$name" == "INDEX.md" ]] && continue
    [[ "$name" == .* ]] && continue
    d=$(extract_date "$name")
    desc=$(describe_file "$f")
    desc=$(sanitize_cell "$desc")
    desc=$(trunc "$desc" 100)
    [[ -z "$desc" ]] && desc="—"
    printf '| `%s` | %s | %s |\n' "$name" "$d" "$desc"
  done < <(find workspace/reports -mindepth 1 -maxdepth 1 -type f 2>/dev/null | sort)
} > "$OUT"

n=$(find workspace/reports -mindepth 1 -maxdepth 1 -type f ! -name 'INDEX.md' 2>/dev/null | wc -l | tr -d ' ')
echo "rebuild-reports-index: wrote ${OUT} (${n} individual report(s))" >&2
