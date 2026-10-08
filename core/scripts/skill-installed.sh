#!/usr/bin/env bash
# Report whether a skill is in the active session's company-scoped catalog.

set -euo pipefail

skill="${1:-}"
company="${2:-${HQ_ACTIVE_COMPANY:-}}"
HQ_ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
resolver="$HQ_ROOT/core/scripts/lib/session-skill-catalog.sh"

if [[ -z "$company" ]]; then
  company="$(bash "$HQ_ROOT/core/scripts/hq-session.sh" get company_slugs 2>/dev/null || true)"
fi

if [[ ! "$skill" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
  exit 1
fi
if [[ -z "$company" ]]; then
  # The catalog requires a company to enumerate skills. This impossible
  # company slug selects the same root and package skills without a tenant.
  company="__hq_unbound_session__"
else
  IFS=, read -r -a companies <<< "$company"
  for slug in "${companies[@]}"; do
    [[ "$slug" =~ ^[a-z][a-z0-9_-]*$ ]] || exit 1
  done
fi

if [[ ! -r "$resolver" ]]; then
  printf 'skill availability resolver is missing: %s\n' "$resolver" >&2
  exit 2
fi

# Use the same ordered, company-scoped catalog as session skill discovery.
# shellcheck source=core/scripts/lib/session-skill-catalog.sh
source "$resolver"
session_skill_catalog_build "$HQ_ROOT" "$company" >/dev/null

while IFS=$'\t' read -r catalog_skill catalog_path _; do
  [[ "$catalog_skill" == "$skill" && -f "$catalog_path" ]] && exit 0
done <<< "${SESSION_SKILL_CATALOG_TSV:-}"

exit 1
