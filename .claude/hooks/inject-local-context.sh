#!/bin/bash
# inject-local-context.sh — SessionStart hook
# Emits a <local-context> block with routing data derived from structured files.
# The SCRIPT is generic (no hardcoded PII) → safe to publish.
# The OUTPUT is ephemeral (session-only) → PII stays in memory only.
#
# Sources:
#   companies/manifest.yaml → company slugs + qmd collections
#   workers/registry.yaml   → company worker counts
#   agents-profile.md       → owner name
#
# Falls back gracefully if files are missing (fresh install).

set -euo pipefail

HQ_ROOT="${CLAUDE_PROJECT_DIR:-.}"

MANIFEST="$HQ_ROOT/companies/manifest.yaml"
REGISTRY="$HQ_ROOT/workers/registry.yaml"
PROFILE="$HQ_ROOT/agents-profile.md"

# --- Owner name ---
OWNER="(not configured)"
if [ -f "$PROFILE" ]; then
  # Extract name from first heading: "# Firstname Lastname - Profile"
  OWNER=$(head -1 "$PROFILE" | sed 's/^# \(.*\) - Profile$/\1/' | sed 's/^# //')
fi

# --- Company slugs ---
COMPANIES=""
COMPANY_COUNT=0
if [ -f "$MANIFEST" ]; then
  # Top-level keys in manifest (lines starting with a word, ending with colon, no indentation)
  # Exclude comment lines and the _template entry
  COMPANIES=$(grep -E '^[a-z][a-z0-9_-]*:' "$MANIFEST" | sed 's/://' | grep -v '^_template$' | paste -sd ',' - | sed 's/,/, /g')
  COMPANY_COUNT=$(grep -cE '^[a-z][a-z0-9_-]*:' "$MANIFEST" | tr -d ' ')
fi

# --- Company worker counts ---
WORKER_COUNTS=""
if [ -f "$REGISTRY" ]; then
  # Count workers grouped by company field (only private/company-scoped workers)
  # Filter out template-placeholder company values ({product}, {company}) that
  # leak in from workers/public/ entries imported from the starter kit without
  # per-company substitution. Don't surface noise in the local-context banner.
  WORKER_COUNTS=$(grep -E '^\s+company:' "$REGISTRY" | sed 's/.*company: *//' | grep -v '{' | sort | uniq -c | sort -rn | awk '{printf "%s (%d), ", $2, $1}' | sed 's/, $//')
fi

# --- QMD collections ---
QMD_COLLECTIONS="hq"
if [ -n "$COMPANIES" ]; then
  QMD_COLLECTIONS="hq, $COMPANIES"
fi

# --- Emit ---
echo "<local-context>"
echo "Owner: $OWNER"
if [ -n "$COMPANIES" ]; then
  echo "Companies ($COMPANY_COUNT): $COMPANIES"
fi
if [ -n "$WORKER_COUNTS" ]; then
  echo "Company workers: $WORKER_COUNTS"
fi
echo "QMD collections: $QMD_COLLECTIONS"
echo "</local-context>"
