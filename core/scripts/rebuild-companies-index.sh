#!/usr/bin/env bash
# rebuild-companies-index.sh — regenerate companies/{co}/INDEX.md for each company.
#
# Pure bash + jq. Zero Claude context. Iterates companies/*/ (skips _template,
# dotfiles), summarizes top-level dirs, scans projects/*/prd.json and
# workspace/orchestrator/{name}/state.json to populate the Projects table.
#
# Schema per knowledge/public/hq-core/index-md-spec.md (Company Root variant):
#   - "# {Company Title}" + "> Auto-generated. Updated: YYYY-MM-DD"
#   - Top-level Name | Description table (dirs and 1-line desc)
#   - "## Projects" table (Project | Status | Description)
#   - "## Deployments" placeholder (None for now — manifest-driven enrichment deferred)

set -euo pipefail

HQ_ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$HQ_ROOT"

DATE=$(date -u +%Y-%m-%d)

# Title-case a slug: "example-co" -> "Example Co"
titleize() {
  echo "$1" | awk -F'-' '{
    for (i=1; i<=NF; i++) {
      $i = toupper(substr($i,1,1)) substr($i,2)
    }
    print
  }' OFS=' '
}

describe_dir() {
  local co="$1"
  local d="$2"
  local path="companies/${co}/${d}"
  [[ -d "$path" ]] || return 0
  case "$d" in
    data)
      local n
      n=$(find "$path" -mindepth 1 -maxdepth 1 ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')
      echo "${n} item(s)"
      ;;
    knowledge)
      if [[ -e "${path}/.git" ]]; then
        echo "Embedded git repo"
      else
        local n
        n=$(find "$path" -mindepth 1 -maxdepth 1 -type d ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')
        echo "Inline knowledge (${n} subdirs)"
      fi
      ;;
    settings)
      local n
      n=$(find "$path" -mindepth 1 -maxdepth 1 -type d ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')
      echo "${n} integration(s)"
      ;;
    policies)
      local n
      n=$(find "$path" -mindepth 1 -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
      echo "${n} policy file(s)"
      ;;
    projects)
      local n
      n=$(find "$path" -mindepth 1 -maxdepth 1 -type d ! -name '_*' ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')
      echo "${n} project(s)"
      ;;
    workers)
      local n
      n=$(find "$path" -mindepth 1 -maxdepth 1 -type d ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')
      echo "${n} worker(s)"
      ;;
    repos)
      local n
      n=$(find "$path" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')
      echo "${n} repo link(s)"
      ;;
    registry)
      local n
      n=$(find "${path}/resources" -mindepth 1 -maxdepth 1 -name '*.yaml' 2>/dev/null | wc -l | tr -d ' ')
      echo "Resource registry (${n} resource(s))"
      ;;
    scripts)
      local n
      n=$(find "$path" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
      echo "${n} script(s)"
      ;;
    *)
      echo "—"
      ;;
  esac
}

# Resolve project status: orchestrator state.json wins, else story-pass fallback.
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
  echo "active"
}

# Sanitize a string for Markdown table cells (single line, no pipes).
sanitize_cell() {
  printf '%s' "$1" | tr '\n' ' ' | sed -e 's/|/\\|/g' -e 's/  */ /g' -e 's/^ *//' -e 's/ *$//'
}

# Truncate to N chars.
trunc() {
  local s="$1"
  local n="$2"
  if [[ ${#s} -le $n ]]; then
    printf '%s' "$s"
  else
    printf '%s…' "${s:0:$((n-1))}"
  fi
}

write_company_index() {
  local co="$1"
  local out="companies/${co}/INDEX.md"
  local title
  title=$(titleize "$co")

  # Header + top-level dir table
  {
    echo "# ${title}"
    echo ""
    echo "> Auto-generated. Updated: ${DATE}"
    echo ""
    echo "| Name | Description |"
    echo "|------|-------------|"
    # Stable order matching company template.
    for d in data knowledge policies projects registry repos scripts settings workers; do
      if [[ -d "companies/${co}/${d}" ]]; then
        local desc
        desc=$(describe_dir "$co" "$d")
        printf '| `%s/` | %s |\n' "$d" "$(sanitize_cell "$desc")"
      fi
    done
    echo ""
    echo "## Projects"
    echo ""

    local proj_dir="companies/${co}/projects"
    if [[ -d "$proj_dir" ]]; then
      echo "| Project | Status | Description |"
      echo "|---------|--------|-------------|"
      # List immediate project subdirs, skip _archive and dotfiles.
      while IFS= read -r p; do
        local name
        name=$(basename "$p")
        [[ "$name" == _* ]] && continue
        [[ "$name" == .* ]] && continue
        local prd="${p}/prd.json"
        local desc=""
        if [[ -f "$prd" ]]; then
          desc=$(jq -r '.description // ""' "$prd" 2>/dev/null || echo "")
        fi
        local status
        status=$(project_status "$name" "$prd")
        desc=$(sanitize_cell "$desc")
        desc=$(trunc "$desc" 110)
        [[ -z "$desc" ]] && desc="—"
        printf '| `%s` | %s | %s |\n' "$name" "$status" "$desc"
      done < <(find "$proj_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
    else
      echo "_No projects directory._"
    fi

    echo ""
    echo "## Deployments"
    echo ""
    echo "_See \`companies/manifest.yaml\` for deployment targets._"
  } > "$out"

  echo "rebuild-companies-index: wrote ${out}" >&2
}

COUNT=0
while IFS= read -r dir; do
  co=$(basename "$dir")
  [[ "$co" == _* ]] && continue
  [[ "$co" == .* ]] && continue
  write_company_index "$co"
  COUNT=$((COUNT+1))
done < <(find companies -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

echo "rebuild-companies-index: regenerated ${COUNT} company INDEX.md file(s)" >&2
