#!/usr/bin/env bash
# hq-core: public
# hq-delegate-secrets.sh — grant a delegation recipient access to the secrets
# a project needs, BY NAME ONLY. No command in this helper ever reads,
# prints, logs, or interpolates a secret value.
#
# Usage:
#   core/scripts/hq-delegate-secrets.sh --manifest <path> [--yes] [--no-secrets]
#     [--env-schema <path>]
#
# Behavior:
#   - derives required secret NAMES from the project's / repo's .env.schema
#     (--env-schema overrides discovery); no schema -> records secrets: []
#     and says so plainly rather than guessing at credentials
#   - without --yes: prints a full-prose confirmation listing every name and
#     the principal, then exits 2 granting nothing — this step is a privilege
#     handover and gets its own confirmation, separate from the file grants
#   - with --yes: hq secrets share <NAME> --with <principal> --permission read
#     per name, then records the names (and only the names) in the manifest
#   - --no-secrets: skips everything, records {secrets: [], secretsSkipped: true}
#
# Consumption on the recipient's side is via `hq run` / `hq secrets exec` —
# documented in the brief; values never appear in any delegation artifact
# (policy hq-delegate-never-inlines-secrets-or-share-urls).
#
# Env: HQ_ROOT — HQ root override (default: resolved from script location)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HQ_ROOT="${HQ_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

usage() { sed -n '3,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die()   { echo "hq-delegate-secrets: $*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required but not installed"

MANIFEST="" YES=0 NO_SECRETS=0 ENV_SCHEMA=""
while [ $# -gt 0 ]; do
  case "$1" in
    --manifest)   MANIFEST="${2:-}"; shift 2 ;;
    --yes)        YES=1; shift ;;
    --no-secrets) NO_SECRETS=1; shift ;;
    --env-schema) ENV_SCHEMA="${2:-}"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$MANIFEST" ] || die "--manifest is required"
[ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"
jq -e . "$MANIFEST" >/dev/null 2>&1 || die "manifest is not valid JSON: $MANIFEST"

COMPANY="$(jq -r '.company // empty' "$MANIFEST")"
PRINCIPAL="$(jq -r '.to.principal // empty' "$MANIFEST")"
PROJECT="$(jq -r '.project.name // empty' "$MANIFEST")"
[ -n "$COMPANY" ]   || die "manifest has no company"
[ -n "$PRINCIPAL" ] || die "manifest has no to.principal"

update_manifest() { # jq-filter
  local tmp
  tmp="$(mktemp)"
  jq "$1" "$MANIFEST" > "$tmp" && mv "$tmp" "$MANIFEST"
}

# --- explicit skip ------------------------------------------------------------

if [ "$NO_SECRETS" -eq 1 ]; then
  update_manifest '.secrets = [] | .secretsSkipped = true'
  echo "hq-delegate-secrets: skipped (--no-secrets) — no credential access granted"
  exit 0
fi

# --- discover the env schema --------------------------------------------------

if [ -z "$ENV_SCHEMA" ]; then
  REPO_REL="$(jq -r '.repo.path // empty' "$MANIFEST")"
  for candidate in \
    "$HQ_ROOT/companies/$COMPANY/projects/$PROJECT/.env.schema" \
    "${REPO_REL:+$HQ_ROOT/$REPO_REL/.env.schema}"; do
    [ -n "$candidate" ] && [ -f "$candidate" ] && { ENV_SCHEMA="$candidate"; break; }
  done
fi

if [ -z "$ENV_SCHEMA" ] || [ ! -f "$ENV_SCHEMA" ]; then
  update_manifest '.secrets = [] | .secretsSkipped = false'
  echo "hq-delegate-secrets: no .env.schema found for this project or its repo — no secret names to grant. If the project needs credentials, add an .env.schema and re-run, or grant them manually with 'hq secrets share'."
  exit 0
fi

# --- parse names (KEY= lines; comments and blanks ignored) --------------------

NAMES="$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$ENV_SCHEMA" | cut -d= -f1 | sort -u)"
if [ -z "$NAMES" ]; then
  update_manifest '.secrets = [] | .secretsSkipped = false'
  echo "hq-delegate-secrets: $ENV_SCHEMA declares no secret names — nothing to grant"
  exit 0
fi
NAME_COUNT="$(printf '%s\n' "$NAMES" | wc -l | tr -d ' ')"

# --- confirmation gate (full prose; separate from the file-grant confirm) ----

echo "Secret access handover — this grants the recipient the ability to use these credentials."
echo
echo "The following $NAME_COUNT secret name(s), declared by $(basename "$ENV_SCHEMA") for project '$PROJECT', will be shared with read permission to '$PRINCIPAL' in company '$COMPANY':"
echo
printf '%s\n' "$NAMES" | sed 's/^/  - /'
echo
echo "Only the names are granted and recorded; no secret value is read, printed, or transmitted by this step. The recipient consumes them through 'hq run' / 'hq secrets exec'."

if [ "$YES" -ne 1 ]; then
  echo
  echo "hq-delegate-secrets: confirmation required — re-run with --yes after the user approves (or --no-secrets to skip)" >&2
  exit 2
fi

# --- grant each name (names only — never a value read) ------------------------

printf '%s\n' "$NAMES" | while IFS= read -r name; do
  hq secrets share "$name" --with "$PRINCIPAL" --permission read --company "$COMPANY" \
    || die "failed to grant '$name' to '$PRINCIPAL' — aborting; manifest not updated"
  echo "hq-delegate-secrets: granted read on '$name' to '$PRINCIPAL'"
done

NAMES_JSON="$(printf '%s\n' "$NAMES" | jq -R . | jq -cs .)"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
update_manifest ".secrets = $NAMES_JSON | .secretsSkipped = false | .secretsGrantedAt = \"$NOW\""

echo "hq-delegate-secrets: $NAME_COUNT secret name(s) granted and recorded (names only)"
