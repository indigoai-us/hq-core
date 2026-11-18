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
#   - derives required secret NAMES from, in order: --env-schema, the project
#     folder's .env.schema, prd.json metadata.secrets, then the repo's
#     .env.schema (the widest source, used only when the project declares
#     nothing); no source -> records secrets: [] and says so plainly rather
#     than guessing at credentials. The plan output names the source.
#   - before sharing anything, every name is checked against
#     `hq secrets list --company <co>` (names only); one missing name aborts
#     the whole step with nothing shared
#   - without --yes: prints a full-prose confirmation listing every name and
#     the principal, then exits 2 granting nothing — this step is a privilege
#     handover and gets its own confirmation, separate from the file grants
#   - with --yes: hq secrets --company <co> share <NAME> --with <principal>
#     --permission read (agent/person uids use the grant step's grantPrincipal)
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

# Secret-ACL principals must be an email, grp_<id>, out_<id>, or @all. An
# agent (agt_...) or person uid (prs_...) is rejected by `hq secrets share`, so
# share with the principal the grant step resolved and recorded in
# .grantPrincipal: the per-agent delegation group (grp_dlg...) for an agent,
# the mapped email for a person uid. The grant step runs first.
SHARE_PRINCIPAL="$PRINCIPAL"
case "$PRINCIPAL" in
  agt_*|prs_*)
    RECORDED="$(jq -r '.grantPrincipal // empty' "$MANIFEST" | tr -d '\r')"
    case "$PRINCIPAL:$RECORDED" in
      agt_*:grp_dlg*) SHARE_PRINCIPAL="$RECORDED" ;;
      prs_*:?*@?*)    SHARE_PRINCIPAL="$RECORDED" ;;
      *)              SHARE_PRINCIPAL="" ;;
    esac
    ;;
esac

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

# Narrowest declaration first. A project-scoped source (the project folder's
# .env.schema or prd.json metadata.secrets) names what this lane needs; the
# repo's .env.schema names everything the whole repo needs and is only used
# when the project declares nothing.
SOURCE_KIND="" SOURCE_PATH="" NAMES=""
NAME_RE='^[A-Z][A-Z0-9_]*(/[A-Z][A-Z0-9_]+)*$'
names_from_schema() { # schema-path -> stdout (KEY= lines; comments and blanks ignored)
  grep -E '^[A-Z][A-Z0-9_]*(/[A-Z][A-Z0-9_]+)*=' "$1" | cut -d= -f1 | sort -u
}
PROJECT_DIR="$HQ_ROOT/companies/$COMPANY/projects/$PROJECT"
if [ -n "$ENV_SCHEMA" ]; then
  [ -f "$ENV_SCHEMA" ] || die "--env-schema not found: $ENV_SCHEMA"
  SOURCE_KIND="--env-schema"; SOURCE_PATH="$ENV_SCHEMA"
  NAMES="$(names_from_schema "$ENV_SCHEMA")"
elif [ -f "$PROJECT_DIR/.env.schema" ]; then
  SOURCE_KIND="project .env.schema"; SOURCE_PATH="$PROJECT_DIR/.env.schema"
  NAMES="$(names_from_schema "$SOURCE_PATH")"
elif [ -f "$PROJECT_DIR/prd.json" ] \
  && jq -e '(.metadata.secrets // null) | type == "array" and length > 0' "$PROJECT_DIR/prd.json" >/dev/null 2>&1; then
  SOURCE_KIND="prd.json metadata.secrets"; SOURCE_PATH="$PROJECT_DIR/prd.json"
  NAMES="$(jq -r '.metadata.secrets[] | if type == "object" then (.name // empty) else . end' "$SOURCE_PATH" | sort -u)"
  BAD="$(printf '%s\n' "$NAMES" | grep -v -E "$NAME_RE" || true)"
  [ -z "$BAD" ] || die "prd.json metadata.secrets has an entry that is not a secret name: $(printf '%s' "$BAD" | tr '\n' ' ')— nothing granted"
else
  REPO_REL="$(jq -r '.repo.path // empty' "$MANIFEST")"
  if [ -n "$REPO_REL" ] && [ -f "$HQ_ROOT/$REPO_REL/.env.schema" ]; then
    SOURCE_KIND="repo .env.schema"; SOURCE_PATH="$HQ_ROOT/$REPO_REL/.env.schema"
    NAMES="$(names_from_schema "$SOURCE_PATH")"
  fi
fi

if [ -z "$SOURCE_PATH" ]; then
  update_manifest '.secrets = [] | .secretsSkipped = false'
  echo "hq-delegate-secrets: no .env.schema found for this project or its repo, and prd.json declares no metadata.secrets — no secret names to grant. If the project needs credentials, add a project .env.schema (or prd.json metadata.secrets) and re-run, or grant them manually with 'hq secrets share'."
  exit 0
fi

if [ -z "$NAMES" ]; then
  update_manifest '.secrets = [] | .secretsSkipped = false'
  echo "hq-delegate-secrets: $SOURCE_PATH declares no secret names — nothing to grant"
  exit 0
fi
NAME_COUNT="$(printf '%s\n' "$NAMES" | wc -l | tr -d ' ')"

# --- confirmation gate (full prose; separate from the file-grant confirm) ----

echo "Secret access handover — this grants the recipient the ability to use these credentials."
echo
echo "Source: $SOURCE_KIND ($SOURCE_PATH)"
if [ "$SOURCE_KIND" = "repo .env.schema" ]; then
  echo "The project declares no secrets of its own, so the repo-wide schema is used. Narrow it with a project .env.schema or prd.json metadata.secrets if the lane needs fewer."
fi
echo
echo "The following $NAME_COUNT secret name(s), declared by $(basename "$SOURCE_PATH") for project '$PROJECT', will be shared with read permission to '$PRINCIPAL' in company '$COMPANY':"
echo
printf '%s\n' "$NAMES" | sed 's/^/  - /'
echo
if [ "$SHARE_PRINCIPAL" != "$PRINCIPAL" ]; then
  if [ -n "$SHARE_PRINCIPAL" ]; then
    echo "Access flows through '$SHARE_PRINCIPAL', the principal the grant step resolved for '$PRINCIPAL'."
  else
    echo "Access will flow through the principal the grant step records for '$PRINCIPAL' (run hq-delegate-grant.sh --yes first)."
  fi
  echo
fi
echo "Only the names are granted and recorded; no secret value is read, printed, or transmitted by this step. The recipient consumes them through 'hq run' / 'hq secrets exec'."

if [ "$YES" -ne 1 ]; then
  echo
  echo "hq-delegate-secrets: confirmation required — re-run with --yes after the user approves (or --no-secrets to skip)" >&2
  exit 2
fi

# --- grant each name (names only — never a value read) ------------------------

[ -n "$SHARE_PRINCIPAL" ] \
  || die "recipient '$PRINCIPAL' cannot be a secret-ACL principal and the manifest has no usable grantPrincipal — run hq-delegate-grant.sh --yes first; nothing granted"

# Every name must exist in the company vault before any share runs, so a
# typo or an undeclared secret never leaves a partial grant behind. Names
# only: `hq secrets list` prints no values.
LISTED="$(hq secrets list --company "$COMPANY" 2>/dev/null)" \
  || die "could not list secret names for company '$COMPANY' (hq secrets list failed) — nothing granted"
MISSING=""
while IFS= read -r name; do
  [ -n "$name" ] || continue
  printf '%s\n' "$LISTED" | awk -v n="$name" '$1 == n { found = 1 } END { exit !found }' \
    || MISSING="$MISSING $name"
done <<EOF
$NAMES
EOF
if [ -n "$MISSING" ]; then
  die "these name(s) from $SOURCE_KIND do not exist in company '$COMPANY':${MISSING} — nothing granted; add them with 'hq secrets set' or remove them from $SOURCE_PATH, then re-run"
fi

printf '%s\n' "$NAMES" | while IFS= read -r name; do
  hq secrets --company "$COMPANY" share "$name" --with "$SHARE_PRINCIPAL" --permission read \
    || die "failed to grant '$name' to '$SHARE_PRINCIPAL' — aborting; manifest not updated"
  echo "hq-delegate-secrets: granted read on '$name' to '$SHARE_PRINCIPAL'"
done

NAMES_JSON="$(printf '%s\n' "$NAMES" | jq -R . | jq -cs .)"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
update_manifest ".secrets = $NAMES_JSON | .secretsSkipped = false | .secretsGrantedAt = \"$NOW\""

echo "hq-delegate-secrets: $NAME_COUNT secret name(s) granted and recorded (names only)"
