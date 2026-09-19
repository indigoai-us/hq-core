#!/bin/bash
# inject-local-context.sh — SessionStart hook
# Emits a <local-context> block with routing data derived from structured files.
# The SCRIPT is generic (no hardcoded PII) → safe to publish.
# The OUTPUT is ephemeral (session-only) → PII stays in memory only.
#
# Sources:
#   companies/manifest.yaml → company slugs + qmd collections
#   core/workers/registry.yaml → company worker counts + missing-path drift
#   agents-profile.md       → owner name + ## Challenges section
#
# Falls back gracefully if files are missing (fresh install).

set -euo pipefail

HQ_ROOT="${CLAUDE_PROJECT_DIR:-.}"
HOOK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

MANIFEST="$HQ_ROOT/companies/manifest.yaml"
REGISTRY="$HQ_ROOT/core/workers/registry.yaml"
PROFILE="$HQ_ROOT/agents-profile.md"

MISSING_WORKERS=""
if [ -r "$HOOK_ROOT/core/scripts/lib/workers-registry.sh" ]; then
  # shellcheck disable=SC1091
  . "$HOOK_ROOT/core/scripts/lib/workers-registry.sh"
  MISSING_WORKERS="$(hq_workers_registry_missing "$HQ_ROOT" || true)"
fi

# --- Owner name ---
OWNER="(not configured)"
if [ -f "$PROFILE" ]; then
  # Extract name from first heading: "# Firstname Lastname - Profile"
  OWNER=$(head -1 "$PROFILE" | sed 's/^# \(.*\) - Profile$/\1/' | sed 's/^# //')
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
    flag && NF { print }
  ' "$PROFILE" | head -5 | paste -sd ';' - | sed 's/;/; /g' || true)
fi

# --- Company slugs ---
COMPANIES=""
COMPANY_COUNT=0
if [ -f "$MANIFEST" ]; then
  # Direct child keys under the top-level companies: block.
  COMPANY_SLUGS=$(awk '
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ { next }
    in_companies && /^[^[:space:]#]/ { exit }
    /^companies:[[:space:]]*$/ { in_companies=1; next }
    in_companies && /^  [a-z][a-z0-9_-]*:[[:space:]]*$/ {
      slug=$0
      sub(/^  /, "", slug)
      sub(/:[[:space:]]*$/, "", slug)
      if (slug != "_template") print slug
    }
  ' "$MANIFEST")
  if [ -n "$COMPANY_SLUGS" ]; then
    COMPANIES=$(printf '%s\n' "$COMPANY_SLUGS" | paste -sd ',' - | sed 's/,/, /g')
    COMPANY_COUNT=$(printf '%s\n' "$COMPANY_SLUGS" | awk 'NF { n++ } END { print n+0 }')
  fi
fi

# --- Company worker counts ---
WORKER_COUNTS=""
if [ -f "$REGISTRY" ]; then
  # Count workers grouped by company field (only private/company-scoped workers)
  # Filter out template-placeholder company values ({product}, {company}) that
  # leak in from core/workers/public/ entries imported from the starter kit without
  # per-company substitution. Don't surface noise in the local-context banner.
  WORKER_COUNTS=$(grep -E '^\s+company:' "$REGISTRY" | sed 's/.*company: *//' | grep -v '{' | sort | uniq -c | sort -rn | awk '{printf "%s (%d), ", $2, $1}' | sed 's/, $//' || true)
fi

# --- QMD collections ---
QMD_COLLECTIONS="hq"
if [ -n "$COMPANIES" ]; then
  QMD_COLLECTIONS="hq, $COMPANIES"
fi

# --- Emit ---
echo "<local-context>"
echo "Owner: $OWNER"
if [ -n "$CHALLENGES" ]; then
  echo "Challenges: $CHALLENGES"
fi
if [ -n "$COMPANIES" ]; then
  echo "Companies ($COMPANY_COUNT): $COMPANIES"
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
echo "</local-context>"
