#!/usr/bin/env bash
# rebuild-social-drafts-index.sh — regenerate workspace/social-drafts/INDEX.md.
#
# Pure bash. Lists:
#   - "Recent Drafts": 20 most-recently-modified .md files under date-channel
#     subdirs (x/, linkedin/, blog/, tiktok/). Description = first `#` heading.
#   - "Directories": top-level subdirs + loose files with description.

set -euo pipefail

HQ_ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# shellcheck source=core/scripts/lib/portable.sh
. "$HQ_ROOT/core/scripts/lib/portable.sh"
cd "$HQ_ROOT"

OUT="workspace/social-drafts/INDEX.md"
DATE=$(date -u +%Y-%m-%d)

[[ -d workspace/social-drafts ]] || { echo "rebuild-social-drafts-index: workspace/social-drafts/ missing, skipping" >&2; exit 0; }

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

describe_subdir() {
  local d="$1"
  local name
  name=$(basename "$d")
  local n_files n_dirs
  n_files=$(find "$d" -mindepth 1 -maxdepth 1 -type f ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')
  n_dirs=$(find "$d" -mindepth 1 -maxdepth 1 -type d ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')
  case "$name" in
    x)        echo "X/Twitter post drafts (${n_files} files)" ;;
    linkedin) echo "LinkedIn post drafts (${n_files} files)" ;;
    blog)     echo "Blog post drafts (${n_files} files)" ;;
    tiktok)   echo "TikTok scripts/drafts (${n_files} files)" ;;
    images)   echo "Infographics and post images (${n_dirs} dirs)" ;;
    *)
      if [[ "$n_dirs" -gt 0 ]]; then
        echo "${n_dirs} subdir(s), ${n_files} file(s)"
      else
        echo "${n_files} file(s)"
      fi
      ;;
  esac
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
    *.json)
      echo "${name%.json} data"
      ;;
    *.py|*.sh)
      echo "Script: ${name}"
      ;;
    *)
      echo "${name}"
      ;;
  esac
}

{
  echo "# Social Drafts"
  echo ""
  echo "> Auto-generated. Updated: ${DATE}"
  echo ""
  echo "## Recent Drafts"
  echo ""
  # 20 most-recently-modified .md files in date-channel subdirs
  # (use find -printf if GNU; macOS find lacks -printf — fall back to stat)
  while IFS= read -r f; do
    rel="${f#workspace/social-drafts/}"
    desc=$(heading_md "$f")
    [[ -z "$desc" ]] && desc=$(basename "$f" .md)
    desc=$(sanitize_cell "$desc")
    desc=$(trunc "$desc" 100)
    printf -- '- `%s` - %s\n' "$rel" "$desc"
  done < <(
    {
      for chan in x linkedin blog tiktok; do
        [[ -d "workspace/social-drafts/${chan}" ]] || continue
        find "workspace/social-drafts/${chan}" -mindepth 1 -maxdepth 1 -type f -name '*.md' 2>/dev/null
      done
    } | while IFS= read -r f; do
      # Sortable timestamp (portable BSD/GNU stat)
      ts=$(portable_stat_mtime "$f" 2>/dev/null || echo 0)
      printf '%s\t%s\n' "$ts" "$f"
    done | sort -rn | head -20 | cut -f2
  )

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
  done < <(find workspace/social-drafts -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

  # Loose top-level files
  while IFS= read -r f; do
    name=$(basename "$f")
    [[ "$name" == "INDEX.md" ]] && continue
    [[ "$name" == .* ]] && continue
    desc=$(describe_file "$f")
    desc=$(sanitize_cell "$desc")
    desc=$(trunc "$desc" 100)
    printf '| `%s` | %s |\n' "$name" "$desc"
  done < <(find workspace/social-drafts -mindepth 1 -maxdepth 1 -type f 2>/dev/null | sort)
} > "$OUT"

n=$(find workspace/social-drafts -mindepth 2 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
echo "rebuild-social-drafts-index: wrote ${OUT} (${n} draft file(s))" >&2
