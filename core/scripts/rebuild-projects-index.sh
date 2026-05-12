#!/usr/bin/env bash
# rebuild-projects-index.sh — regenerate the HQ-root projects/INDEX.md.
#
# Pure bash + jq. Reads projects/*/prd.json for the Personal/HQ Projects table
# and lists companies/*/projects directories for cross-reference. Status comes
# from workspace/orchestrator/{name}/state.json (fallback: passes-all → complete).

set -euo pipefail

HQ_ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$HQ_ROOT"

OUT="projects/INDEX.md"
DATE=$(date -u +%Y-%m-%d)

[[ -d projects ]] || { echo "rebuild-projects-index: projects/ missing, skipping" >&2; exit 0; }

sanitize_cell() {
  printf '%s' "$1" | tr '\n' ' ' | sed -e 's/|/\\|/g' -e 's/  */ /g' -e 's/^ *//' -e 's/ *$//'
}
trunc() {
  local s="$1"
  local n="$2"
  if [[ ${#s} -le $n ]]; then printf '%s' "$s"; else printf '%s…' "${s:0:$((n-1))}"; fi
}

project_status() {
  local project="$1"
  local prd="$2"
  local state="workspace/orchestrator/${project}/state.json"
  if [[ -f "$state" ]]; then
    local raw
    raw=$(jq -r '.status // "active"' "$state" 2>/dev/null || echo "active")
    case "$raw" in
      completed|complete) echo "complete" ;;
      in_progress|active|started) echo "active" ;;
      archived) echo "archived" ;;
      *) echo "$raw" ;;
    esac
    return
  fi
  if [[ -f "$prd" ]]; then
    local total passes
    total=$(jq '[.userStories[]?] | length' "$prd" 2>/dev/null || echo 0)
    passes=$(jq '[.userStories[]? | select(.passes==true)] | length' "$prd" 2>/dev/null || echo 0)
    if [[ "$total" -gt 0 ]] && [[ "$total" == "$passes" ]]; then
      echo "complete"
      return
    fi
  fi
  echo "—"
}

{
  echo "# Projects"
  echo ""
  echo "> Auto-generated. Updated: ${DATE}"
  echo ""
  echo "Personal/HQ projects only. Company-scoped projects live in \`companies/{co}/projects/\`."
  echo ""
  echo "## Company Project Directories"
  echo ""
  echo "| Company | Path |"
  echo "|---------|------|"
  while IFS= read -r dir; do
    co=$(basename "$dir")
    [[ "$co" == _* ]] && continue
    [[ "$co" == .* ]] && continue
    if [[ -d "companies/${co}/projects" ]]; then
      printf '| %s | `companies/%s/projects/` |\n' "$co" "$co"
    fi
  done < <(find companies -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

  echo ""
  echo "## Personal/HQ Projects"
  echo ""
  echo "Projects here are HQ infrastructure or cross-company tools."
  echo ""
  echo "| Project | Stories | Status | Description |"
  echo "|---------|---------|--------|-------------|"

  while IFS= read -r p; do
    name=$(basename "$p")
    [[ "$name" == _* ]] && continue
    [[ "$name" == .* ]] && continue
    prd="${p}/prd.json"
    desc=""
    stories="—"
    if [[ -f "$prd" ]]; then
      desc=$(jq -r '.description // ""' "$prd" 2>/dev/null || echo "")
      stories=$(jq '[.userStories[]?] | length' "$prd" 2>/dev/null || echo 0)
      [[ "$stories" == "0" ]] && stories="—"
    fi
    status=$(project_status "$name" "$prd")
    desc=$(sanitize_cell "$desc")
    desc=$(trunc "$desc" 110)
    [[ -z "$desc" ]] && desc="—"
    printf '| `%s/` | %s | %s | %s |\n' "$name" "$stories" "$status" "$desc"
  done < <(find projects -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
} > "$OUT"

count=$(find projects -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
echo "rebuild-projects-index: wrote ${OUT} (${count} HQ project(s))" >&2
