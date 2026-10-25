#!/bin/bash
# inject-local-context.sh — SessionStart hook
# Emits a <local-context> block with routing data derived from structured files.
# The SCRIPT is generic (no hardcoded PII) → safe to publish.
# The OUTPUT is ephemeral (session-only) → PII stays in memory only.
#
# Sources:
#   companies/manifest.yaml → company slugs + qmd collections
#   core/workers/registry.yaml → company worker counts + missing-path drift
#   personal/agents-profile.md (or legacy agents-profile.md) → owner name + ## Challenges section
#
# Falls back gracefully if files are missing (fresh install).
#
# Tests that pin this script's output (run them after any banner change):
#   .claude/hooks/tests/inject-local-context-owner-groups.test.sh
#   core/scripts/tests/manifest-nested-parse.test.sh        (Companies line)
#   core/scripts/tests/inject-local-context-process-budget.test.sh
#   core/scripts/tests/workers-registry-missing.test.sh     (worker drift line)
#   core/scripts/tests/hook-runtime-diagnostics.test.sh

set -euo pipefail

HQ_ROOT="${CLAUDE_PROJECT_DIR:-.}"
HOOK_DIR="${BASH_SOURCE[0]%/*}"
[ "$HOOK_DIR" != "${BASH_SOURCE[0]}" ] || HOOK_DIR=.
HOOK_ROOT="$(cd "$HOOK_DIR/../.." && pwd)"

MANIFEST="$HQ_ROOT/companies/manifest.yaml"
REGISTRY="$HQ_ROOT/core/workers/registry.yaml"
# /personal-interview writes personal/agents-profile.md (the charter's path).
# Older installs kept it at the HQ root, so fall back there (feedback_e5ed5205).
PROFILE="$HQ_ROOT/personal/agents-profile.md"
[ -f "$PROFILE" ] || PROFILE="$HQ_ROOT/agents-profile.md"

MISSING_WORKERS=""
if [ -r "$HOOK_ROOT/core/scripts/lib/workers-registry.sh" ]; then
  # shellcheck disable=SC1091
  . "$HOOK_ROOT/core/scripts/lib/workers-registry.sh"
  MISSING_WORKERS="$(hq_workers_registry_missing "$HQ_ROOT" || true)"
fi

# --- Owner name ---
OWNER="(not configured)"
if [ -f "$PROFILE" ]; then
  # Extract the first heading without spawning head/sed processes.
  OWNER_LINE=""
  IFS= read -r OWNER_LINE < "$PROFILE" || true
  case "$OWNER_LINE" in
    '# '*" - Profile") OWNER="${OWNER_LINE#\# }"; OWNER="${OWNER% - Profile}" ;;
    '# '*) OWNER="${OWNER_LINE#\# }" ;;
    *) OWNER="$OWNER_LINE" ;;
  esac
fi

# --- Standing challenges (Phase 1 Q4 from /setup) ---
# Surface the user's pain points so every session lands with them in working
# memory. Bounded: first 5 non-empty lines, joined with `; ` to keep the
# banner compact. Stops at the next `## ` heading.
CHALLENGES=""
if [ -f "$PROFILE" ]; then
  CHALLENGES=$(awk '
    /^## Challenges[[:space:]]*$/ { flag=1; next }
    /^## / && flag { flag=0 }
    flag && NF && count < 5 {
      line=$0
      gsub(/;/, "; ", line)
      if (count) printf "; "
      printf "%s", line
      count++
    }
  ' "$PROFILE" || true)
fi

# --- Company slugs, grouped by the owner's relationship ---
# Each company may carry `owner_role` (self | operate | side | client | family |
# system | unclassified) and `owner_status` (active | slow-burn | on-hold |
# handover-pending | review). Missing role → unclassified, so older manifests
# keep working. `system` companies (workspace scaffold) are hidden from the
# banner but still count toward QMD collections.
COMPANIES=""
COMPANY_COUNT=0
GROUP_LINES=""
OWNER_SUMMARY=""
if [ -f "$MANIFEST" ]; then
  # One awk pass (process budget: inject-local-context-process-budget.test.sh)
  # emits the optional top-level owner_summary as "@summary<TAB>summary<TAB>text"
  # (tabs are IFS whitespace, so a leading field cannot be empty) and
  # each direct child of the companies: block as "slug<TAB>role<TAB>status".
  ROLE_SELF=""; ROLE_OPERATE=""; ROLE_SIDE=""; ROLE_CLIENT=""
  ROLE_FAMILY=""; ROLE_UNCLASSIFIED=""
  while IFS=$'\t' read -r slug role st; do
    if [ "$slug" = "@summary" ]; then
      OWNER_SUMMARY="$st"
      continue
    fi
    [ -n "$slug" ] || continue
    COMPANIES="${COMPANIES:+$COMPANIES, }$slug"
    COMPANY_COUNT=$((COMPANY_COUNT + 1))
    label="$slug"
    case "$st" in
      handover-pending) label="$slug (handover)" ;;
      on-hold) label="$slug (hold)" ;;
    esac
    case "$role" in
      self) ROLE_SELF="${ROLE_SELF:+$ROLE_SELF, }$label" ;;
      operate) ROLE_OPERATE="${ROLE_OPERATE:+$ROLE_OPERATE, }$label" ;;
      side) ROLE_SIDE="${ROLE_SIDE:+$ROLE_SIDE, }$label" ;;
      client) ROLE_CLIENT="${ROLE_CLIENT:+$ROLE_CLIENT, }$label" ;;
      family) ROLE_FAMILY="${ROLE_FAMILY:+$ROLE_FAMILY, }$label" ;;
      system) : ;;
      *) ROLE_UNCLASSIFIED="${ROLE_UNCLASSIFIED:+$ROLE_UNCLASSIFIED, }$label" ;;
    esac
  done < <(awk '
    function flush() {
      if (slug != "" && slug != "_template") printf "%s\t%s\t%s\n", slug, role, status
      slug=""; role=""; status=""
    }
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ { next }
    /^owner_summary:[[:space:]]*/ {
      v=$0
      sub(/^owner_summary:[[:space:]]*/, "", v)
      sub(/[[:space:]]+$/, "", v)
      if (v ~ /^".*"$/ || v ~ /^\x27.*\x27$/) v=substr(v, 2, length(v)-2)
      if (v != "") printf "@summary\tsummary\t%s\n", v
      next
    }
    in_companies && /^[^[:space:]#]/ { flush(); in_companies=0; next }
    /^companies:[[:space:]]*$/ { in_companies=1; next }
    in_companies && /^  [a-z][a-z0-9_-]*:[[:space:]]*$/ {
      flush()
      slug=$0
      sub(/^  /, "", slug)
      sub(/:[[:space:]]*$/, "", slug)
      next
    }
    in_companies && slug != "" && /^    owner_role:[[:space:]]*/ {
      role=$0; sub(/^    owner_role:[[:space:]]*/, "", role)
      gsub(/[[:space:]\x27"]/, "", role); next
    }
    in_companies && slug != "" && /^    owner_status:[[:space:]]*/ {
      status=$0; sub(/^    owner_status:[[:space:]]*/, "", status)
      gsub(/[[:space:]\x27"]/, "", status); next
    }
    END { flush() }
  ' "$MANIFEST")
  [ -z "$ROLE_SELF" ] || GROUP_LINES="${GROUP_LINES}Self: $ROLE_SELF"$'\n'
  [ -z "$ROLE_OPERATE" ] || GROUP_LINES="${GROUP_LINES}Jobs (operate): $ROLE_OPERATE"$'\n'
  [ -z "$ROLE_SIDE" ] || GROUP_LINES="${GROUP_LINES}Side projects: $ROLE_SIDE"$'\n'
  [ -z "$ROLE_CLIENT" ] || GROUP_LINES="${GROUP_LINES}Client / consulting: $ROLE_CLIENT"$'\n'
  [ -z "$ROLE_FAMILY" ] || GROUP_LINES="${GROUP_LINES}Family: $ROLE_FAMILY"$'\n'
  [ -z "$ROLE_UNCLASSIFIED" ] || GROUP_LINES="${GROUP_LINES}Unclassified (confirm): $ROLE_UNCLASSIFIED"$'\n'
fi

# --- Company worker counts ---
WORKER_COUNTS=""
if [ -f "$REGISTRY" ]; then
  # Count workers grouped by company field (only private/company-scoped workers)
  # Filter out template-placeholder company values ({product}, {company}) that
  # leak in from core/workers/public/ entries imported from the starter kit without
  # per-company substitution. Don't surface noise in the local-context banner.
  WORKER_COUNTS=$(awk '
    /^[[:space:]]+company:/ {
      company=$0
      sub(/.*company:[[:space:]]*/, "", company)
      if (company !~ /\{/) counts[company]++
    }
    END {
      for (company in counts) printf "%d\t%s\n", counts[company], company
    }
  ' "$REGISTRY" | sort -rn | awk -F '\t' '
    { printf "%s%s (%d)", (NR == 1 ? "" : ", "), $2, $1 }
    END { if (NR) printf "\n" }
  ' || true)
fi

# --- QMD collections ---
QMD_COLLECTIONS="hq"
if [ -n "$COMPANIES" ]; then
  QMD_COLLECTIONS="hq, $COMPANIES"
fi

# --- Data platform (vyg) ---
# One line when a vyg MCP server is registered for this HQ or this user, so
# sessions route customer-scale and event-scale data to vyg instead of HQ.
# Server names only; config values are never read. HOME is honored so tests
# can isolate the user-level registration.
VYG_MCP=""
for mcp_cfg in "$HQ_ROOT/.mcp.json" "${HOME:-/nonexistent}/.claude.json"; do
  [ -f "$mcp_cfg" ] || continue
  if grep -q '"[^"]*vyg[^"]*"[[:space:]]*:' "$mcp_cfg" 2>/dev/null; then VYG_MCP=1; break; fi
done

# --- Emit ---
echo "<local-context>"
echo "Owner: $OWNER"
if [ -n "$CHALLENGES" ]; then
  echo "Challenges: $CHALLENGES"
fi
if [ -n "$COMPANIES" ]; then
  echo "Companies ($COMPANY_COUNT), grouped by the owner's relationship:"
  printf '%s' "$GROUP_LINES"
  if [ -n "$OWNER_SUMMARY" ]; then
    echo "Owner jobs: $OWNER_SUMMARY"
  fi
fi
if [ -n "$WORKER_COUNTS" ]; then
  echo "Company workers: $WORKER_COUNTS"
fi
if [ -n "$MISSING_WORKERS" ]; then
  # Cap the banner: a long stale registry must not blow the SessionStart budget.
  MISSING_LINE="$(printf '%s\n' "$MISSING_WORKERS" | awk -F '\t' '
    NF >= 2 && n < 8 { printf "%s%s → %s", (n ? "; " : ""), $1, $2; n++ }
    END { if (NR > 8) printf " (+%d more)", NR - 8 }
  ')"
  echo "Missing workers (registry path absent): $MISSING_LINE"
  echo "Do not treat missing workers as available and do not fall back to a raw ingest script. Run hq sync to fetch the directories, or hq reindex to drop stale registry rows."
fi
echo "QMD collections: $QMD_COLLECTIONS"
if [ -n "$VYG_MCP" ]; then
  echo "Data platform: vyg MCP connected. Large customer databases, CDP, website visit/event data, big data integrations and data workflows go to vyg (mcp__vyg*), not the HQ vault or app databases. Policy: hq-suggest-vyg-for-big-data."
fi
echo "</local-context>"
