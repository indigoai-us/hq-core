#!/usr/bin/env bash
# hq-core: public
# startwork-context.sh — the compact capability block /startwork renders for a
# bound company: what the company is, where its repos and knowledge live, which
# connected apps the caller can use, the most recently touched projects, the
# company's workers, and where the skill index is. One line per fact, under
# about 3 KB, no network, no file reads outside the bound company plus the
# shared manifest, registry, and integrations cache. HP-13.
#
# Usage:
#   core/scripts/startwork-context.sh resolve --arg <slug|alias|repo-name>
#       Prints {"company":"<slug>","via":"slug|repo|alias"} or
#       {"company":"","candidates":[...]} and exits 3 when nothing matches.
#   core/scripts/startwork-context.sh block --company <slug> [--project <name>]
#       Prints the <startwork-context> block.
#
# Env: HQ_ROOT (default: derived from this script), HQ_STARTWORK_MAX_LIST
#      (list items shown before "+N more", default 8).
set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}}"
MANIFEST="$ROOT/companies/manifest.yaml"
REGISTRY="$ROOT/core/workers/registry.yaml"
MAX="${HQ_STARTWORK_MAX_LIST:-8}"

usage() { sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "startwork-context: $*" >&2; exit 2; }
valid_slug() { [ -n "${1:-}" ] && printf '%s' "$1" | grep -qE '^[a-z0-9][a-z0-9-]*$'; }

# company_field SLUG KEY -> scalar value from the company's manifest block.
company_field() {
  awk -v slug="$1" -v key="$2" '
    /^  [a-z0-9-]+:[[:space:]]*$/ { inb = ($0 == "  " slug ":") ; next }
    inb && index($0, "    " key ":") == 1 {
      v = substr($0, length(key) + 6); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
      gsub(/^["\x27]|["\x27]$/, "", v); print v; exit
    }' "$MANIFEST"
}
# company_list SLUG KEY -> one item per line from a block-style or flow list.
company_list() {
  awk -v slug="$1" -v key="$2" '
    /^  [a-z0-9-]+:[[:space:]]*$/ { inb = ($0 == "  " slug ":"); inl = 0; next }
    inb && index($0, "    " key ":") == 1 {
      v = substr($0, length(key) + 6); sub(/^[ \t]+/, "", v)
      if (v ~ /^\[/) { gsub(/^\[|\]$/, "", v); n = split(v, a, ","); for (i = 1; i <= n; i++) { x = a[i]; gsub(/^[ \t"\x27]+|[ \t"\x27]+$/, "", x); if (x != "") print x }; exit }
      inl = 1; next
    }
    inl && /^    - / { x = $0; sub(/^    - /, "", x); gsub(/^[ \t"\x27]+|[ \t"\x27]+$/, "", x); print x; next }
    inl && /^    [a-z]/ { exit }
  ' "$MANIFEST"
}
company_exists() { grep -qE "^  $1:[[:space:]]*$" "$MANIFEST" 2>/dev/null; }

join_max() { # stdin items -> "a, b, c (+N more)"
  awk -v max="$MAX" 'NF { n++; if (n <= max) { s = s (n > 1 ? ", " : "") $0 } } END { if (n == 0) print "none"; else if (n > max) print s " (+" n - max " more)"; else print s }'
}

file_age_min() { # minutes since mtime, or empty
  local m now; [ -f "$1" ] || return 0
  m="$(stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null)" || return 0
  now="$(date +%s)"; echo $(( (now - m) / 60 ))
}

cmd_resolve() {
  local arg="" ; while [ $# -gt 0 ]; do case "$1" in --arg) arg="${2:-}"; shift 2 ;; *) shift ;; esac; done
  [ -n "$arg" ] || die "resolve needs --arg"
  [ -f "$MANIFEST" ] || die "no manifest at $MANIFEST"
  local a; a="$(printf '%s' "$arg" | tr 'A-Z' 'a-z')"
  if company_exists "$a"; then printf '{"company":"%s","via":"slug"}\n' "$a"; return 0; fi
  # repo name: a company whose repos list ends with /<arg>
  local hit; hit="$(awk -v want="/$a" '
    /^  [a-z0-9-]+:[[:space:]]*$/ { slug = $0; sub(/^  /, "", slug); sub(/:.*/, "", slug); inl = 0; next }
    /^    repos:/ { inl = 1; next }
    inl && /^    - / { x = $0; sub(/^    - /, "", x); gsub(/[ \t"\x27]/, "", x); if (substr(x, length(x) - length(want) + 1) == want) print slug; next }
    inl && /^    [a-z]/ { inl = 0 }' "$MANIFEST" | sort -u)"
  if [ "$(printf '%s\n' "$hit" | grep -c .)" -eq 1 ]; then printf '{"company":"%s","via":"repo"}\n' "$hit"; return 0; fi
  # alias: slug prefix or company name match (whole token)
  local cands; cands="$(awk -v a="$a" '
    /^  [a-z0-9-]+:[[:space:]]*$/ { slug = $0; sub(/^  /, "", slug); sub(/:.*/, "", slug); if (index(slug, a) == 1) print slug; next }
    /^    name:/ { v = tolower($0); sub(/^    name:[ \t]*/, "", v); gsub(/["\x27]/, "", v); if (v == a) print slug }' "$MANIFEST" | sort -u)"
  if [ "$(printf '%s\n' "$cands" | grep -c .)" -eq 1 ]; then printf '{"company":"%s","via":"alias"}\n' "$cands"; return 0; fi
  printf '{"company":"","candidates":[%s]}\n' "$(printf '%s\n' "$cands" "$hit" | grep . | sort -u | sed 's/.*/"&"/' | paste -sd, -)"
  return 3
}

cmd_block() {
  local co="" project=""
  while [ $# -gt 0 ]; do case "$1" in --company) co="${2:-}"; shift 2 ;; --project) project="${2:-}"; shift 2 ;; *) shift ;; esac; done
  valid_slug "$co" || die "block needs --company <slug>"
  [ -f "$MANIFEST" ] || die "no manifest at $MANIFEST"
  company_exists "$co" || die "company '$co' is not in the manifest"
  local cdir="$ROOT/companies/$co"
  local name cloud qmd knowledge sources repos
  name="$(company_field "$co" name)"; [ -n "$name" ] || name="$co"
  cloud="$(company_field "$co" cloud_uid)"
  qmd="$(company_list "$co" qmd_collections | join_max)"; [ "$qmd" = "none" ] && qmd="$co"
  knowledge="$(company_field "$co" knowledge)"; [ -n "$knowledge" ] || knowledge="companies/$co/knowledge/"
  sources="$(company_list "$co" sources | join_max)"
  repos="$(company_list "$co" repos | sed "s|^repos/[a-z]*/||" | join_max)"
  local nrepos; nrepos="$(company_list "$co" repos | grep -c . || true)"

  local kfolders=""; [ -d "$ROOT/$knowledge" ] && kfolders="$(find "$ROOT/$knowledge" -mindepth 1 -maxdepth 1 -type d ! -name '_*' ! -name '.*' 2>/dev/null | sed 's|.*/||' | sort | join_max)"
  local sfolders=""; [ -d "$cdir/sources" ] && sfolders="$(find "$cdir/sources" -mindepth 1 -maxdepth 1 ! -name '.*' 2>/dev/null | sed 's|.*/||' | sort | join_max)"

  # Integrations: cache only, never the network.
  local cache="$ROOT/.hq/usable-integrations/$co.json" integ age
  if [ -f "$cache" ] && command -v jq >/dev/null 2>&1 && [ "$(jq -r '.company // ""' "$cache" 2>/dev/null)" = "$co" ]; then
    age="$(file_age_min "$cache")"
    integ="$(jq -r '.apps[]? | "\(.name) (\(.selector))"' "$cache" 2>/dev/null | join_max)"
    [ "$integ" = "none" ] && integ="no connected apps shared with you"
    integ="$integ  [cached ${age:-?}m ago; refresh: core/scripts/usable-integrations.sh show --company $co]"
  else
    integ="not cached; run: core/scripts/usable-integrations.sh show --company $co (then hq integrations list --company $co --json for flags)"
  fi

  # Projects: five most recently touched, with local stage and open-story count
  # (labelled local; the board is the work mesh).
  local projects=""
  if [ -d "$cdir/projects" ]; then
    projects="$(ls -t "$cdir"/projects/*/prd.json 2>/dev/null | grep -v '/_archive/' | head -5 \
      | while IFS= read -r p; do
          d="$(basename "$(dirname "$p")")"
          if command -v jq >/dev/null 2>&1; then
            jq -r --arg d "$d" '"\($d) [\(.metadata.stage // "prd")] \([.userStories[]? | select((.status // "") != "done" and (.passes // false) != true)] | length)/\(.userStories | length) open"' "$p" 2>/dev/null || echo "$d"
          else echo "$d"; fi
        done | paste -sd';' - | sed 's/;/; /g')"
  fi
  [ -n "$projects" ] || projects="none"

  # Workers: registry rows for this company (company field or path prefix).
  local workers="" nworkers=0
  if [ -f "$REGISTRY" ]; then
    workers="$(awk -v co="$co" '
      /^  - id:/ { flush(); id = $0; sub(/^  - id:[ \t]*/, "", id); gsub(/"/, "", id); next }
      /^    path:/ { p = $0; sub(/^    path:[ \t]*/, "", p); gsub(/"/, "", p); next }
      /^    company:/ { c = $0; sub(/^    company:[ \t]*/, "", c); gsub(/"/, "", c); next }
      /^    description:/ { d = $0; sub(/^    description:[ \t]*/, "", d); gsub(/"/, "", d); next }
      /^    status:/ { s = $0; sub(/^    status:[ \t]*/, "", s); gsub(/"/, "", s); next }
      function flush() { if (id != "" && (c == co || index(p, "companies/" co "/workers/") == 1) && (s == "" || s == "active")) print id " - " substr(d, 1, 70); id = ""; p = ""; c = ""; d = ""; s = "" }
      END { flush() }' "$REGISTRY")"
    nworkers="$(printf '%s\n' "$workers" | grep -c . || true)"
    workers="$(printf '%s\n' "$workers" | join_max)"
  else workers="registry missing"; fi

  local nskills=0; nskills="$(find "$ROOT/.claude/skills" -maxdepth 1 -name "$co:*" 2>/dev/null | wc -l | tr -d ' ')"
  local index="core/settings/intent-index.yaml"; [ -f "$ROOT/workspace/orchestrator/intent-index.yaml" ] && index="workspace/orchestrator/intent-index.yaml"

  printf '<startwork-context company="%s">\n' "$co"
  printf 'Company: %s (%s) · qmd: -c %s · vault: %s\n' "$name" "$co" "$qmd" "$([ -n "$cloud" ] && echo cloud || echo local-only)"
  printf 'Repos (%s): %s\n' "$nrepos" "$repos"
  printf 'Knowledge: %s%s · Sources: %s\n' "$knowledge" "$([ -n "$kfolders" ] && [ "$kfolders" != none ] && echo " [$kfolders]")" "$([ -n "$sfolders" ] && [ "$sfolders" != none ] && echo "companies/$co/sources/ [$sfolders]" || echo "$sources")"
  printf 'Integrations: %s\n' "$integ"
  printf 'Projects (recent, local counts): %s\n' "$projects"
  printf 'Workers (%s): %s\n' "$nworkers" "$workers"
  printf 'Skills: %s company skills (/%s:*) · full index: %s\n' "$nskills" "$co" "$index"
  if [ -n "$project" ]; then
    local pd="$cdir/projects/$project"
    if [ -f "$pd/prd.json" ] && command -v jq >/dev/null 2>&1; then
      jq -r '"Project: \(.name // "") · \(.goal // .description // "" | .[0:140]) · branch: \(.metadata.branchName // .branchName // "n/a") · board: work mesh (hq mesh story)"' "$pd/prd.json" 2>/dev/null
    else
      printf 'Project: %s (no prd.json under companies/%s/projects/)\n' "$project" "$co"
    fi
  fi
  printf '</startwork-context>\n'
}

case "${1:-}" in
  resolve) shift; cmd_resolve "$@" ;;
  block) shift; cmd_block "$@" ;;
  -h|--help|"") usage; exit 0 ;;
  *) die "unknown command: $1" ;;
esac
