#!/usr/bin/env bash
# export-skill-catalog.sh — print the bounded SessionStart skill catalog body.
#
# Thin wrapper around session-skill-catalog.sh for CLI tools, desktop bootstrap,
# and regression tests. Prints name + one-line description lines only.
#
# Usage:
#   bash core/scripts/export-skill-catalog.sh --root <hq-root> --company <slug>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/session-skill-catalog.sh
source "$SCRIPT_DIR/lib/session-skill-catalog.sh"
# shellcheck source=lib/session-authz.sh
source "$SCRIPT_DIR/lib/session-authz.sh"

usage() {
  cat <<'EOF'
Usage: export-skill-catalog.sh --root <hq-root> --company <slug>

Builds the bounded HQ skill catalog (company scope first, then root, then
packages) and prints the rendered markdown body on stdout.
EOF
}

HQ_ROOT=""
COMPANY=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] || { echo "--root requires a path" >&2; usage >&2; exit 64; }
      HQ_ROOT="$2"
      shift 2
      ;;
    --company)
      [ "$#" -ge 2 ] || { echo "--company requires a slug" >&2; usage >&2; exit 64; }
      COMPANY="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

[ -n "$HQ_ROOT" ] || { echo "--root is required" >&2; usage >&2; exit 64; }
[ -n "$COMPANY" ] || { echo "--company is required" >&2; usage >&2; exit 64; }

HQ_ROOT="$(cd "$HQ_ROOT" && pwd -P)"
session_resolve_company_dir "$HQ_ROOT" "$COMPANY" >/dev/null
session_skill_catalog_build "$HQ_ROOT" "$COMPANY" >/dev/null
if [ -n "${SESSION_SKILL_CATALOG_BODY:-}" ]; then
  printf '%s\n' "$SESSION_SKILL_CATALOG_BODY"
else
  printf '(no skills available)\n'
fi
