#!/usr/bin/env bash
# rebuild-company-knowledge-index.sh — regenerate companies/{co}/knowledge/INDEX.md.
#
# Pure bash + jq. One INDEX.md per company knowledge dir, at the top level only
# (no descent into subdirs — embedded git repos manage their own internals).
#
# Description extraction:
#   - .md files → first `#` heading (stripped)
#   - .yaml files → `description:` field if present
#   - .json files → `description` field if present
#   - directories → "{N} item(s)"
#
# Most company knowledge dirs are embedded git repos (160000 gitlinks). The
# generated INDEX.md lives inside the inner repo; HQ git won't track its
# content directly, but it gets refreshed on every handoff.

set -euo pipefail

HQ_ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$HQ_ROOT"

DATE=$(date -u +%Y-%m-%d)

titleize() {
  echo "$1" | awk -F'-' '{
    for (i=1; i<=NF; i++) { $i = toupper(substr($i,1,1)) substr($i,2) }
    print
  }' OFS=' '
}

sanitize_cell() {
  printf '%s' "$1" | tr '\n' ' ' | sed -e 's/|/\\|/g' -e 's/  */ /g' -e 's/^ *//' -e 's/ *$//'
}
trunc() {
  local s="$1" n="$2"
  if [[ ${#s} -le $n ]]; then printf '%s' "$s"; else printf '%s…' "${s:0:$((n-1))}"; fi
}

describe_item() {
  local path="$1"
  local name="$2"
  if [[ -d "$path" ]]; then
    local n
    n=$(find "$path" -mindepth 1 -maxdepth 1 ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')
    echo "${n} item(s)"
    return
  fi
  case "$name" in
    *.md)
      local h
      h=$(awk '/^# / { sub(/^# +/, ""); print; exit }' "$path" 2>/dev/null || true)
      [[ -z "$h" ]] && h="$name"
      echo "$h"
      ;;
    *.yaml|*.yml)
      local d
      d=$(awk -F: '/^description:/ { sub(/^description: */, ""); gsub(/^["\x27]|["\x27]$/, ""); print; exit }' "$path" 2>/dev/null || true)
      [[ -z "$d" ]] && d="$name"
      echo "$d"
      ;;
    *.json)
      local d
      d=$(jq -r '.description // .name // empty' "$path" 2>/dev/null || true)
      [[ -z "$d" ]] && d="$name"
      echo "$d"
      ;;
    *)
      echo "$name"
      ;;
  esac
}

write_knowledge_index() {
  local co="$1"
  local kdir="companies/${co}/knowledge"
  [[ -d "$kdir" ]] || return 0
  local out="${kdir}/INDEX.md"
  local title
  title="$(titleize "$co") Knowledge"

  {
    echo "# ${title}"
    echo ""
    echo "> Auto-generated. Updated: ${DATE}"
    echo ""
    echo "| Name | Description |"
    echo "|------|-------------|"

    # Directories first (sorted), then files (sorted). Skip dotfiles, INDEX.md.
    while IFS= read -r item; do
      local name
      name=$(basename "$item")
      [[ "$name" == .* ]] && continue
      [[ "$name" == "INDEX.md" ]] && continue
      local desc
      desc=$(describe_item "$item" "$name")
      desc=$(sanitize_cell "$desc")
      desc=$(trunc "$desc" 100)
      [[ -z "$desc" ]] && desc="—"
      if [[ -d "$item" ]]; then
        printf '| `%s/` | %s |\n' "$name" "$desc"
      else
        printf '| `%s` | %s |\n' "$name" "$desc"
      fi
    done < <(
      {
        find "$kdir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort
        find "$kdir" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | sort
      }
    )
  } > "$out"

  echo "rebuild-company-knowledge-index: wrote ${out}" >&2
}

COUNT=0
while IFS= read -r dir; do
  co=$(basename "$dir")
  [[ "$co" == _* ]] && continue
  [[ "$co" == .* ]] && continue
  if [[ -d "companies/${co}/knowledge" ]]; then
    write_knowledge_index "$co"
    COUNT=$((COUNT+1))
  fi
done < <(find companies -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

echo "rebuild-company-knowledge-index: regenerated ${COUNT} knowledge INDEX.md file(s)" >&2
