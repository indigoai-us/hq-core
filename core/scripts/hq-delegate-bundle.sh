#!/usr/bin/env bash
# hq-core: public
# hq-delegate-bundle.sh — freeze a project into a portable delegation bundle.
#
# Usage:
#   core/scripts/hq-delegate-bundle.sh build \
#     --company <slug> --project <name> --to <principal> \
#     [--to-kind person|agent] [--to-name <display name>] \
#     [--mode transfer|share] [--dry-run]
#
# --dry-run prints the manifest JSON to stdout and writes nothing.
#
# Writes workspace/delegations/<delegationId>/{manifest.json,BRIEF.md} and
# prints the delegationId on stdout. The manifest is the single source of
# truth for every downstream delegation step (grants, verification, pickup
# prompt) — schema documented in
# core/knowledge/public/hq-core/delegation-bundle-spec.md.
#
# Fails closed (non-zero, nothing written) when:
#   - required arguments are missing
#   - the project directory or its prd.json does not exist / parses invalid
#   - the generated manifest or BRIEF matches a secret-detection pattern
#
# Env:
#   HQ_ROOT — HQ root override (default: resolved from this script's location)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HQ_ROOT="${HQ_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# shellcheck source=lib/secret-patterns.sh
. "$SCRIPT_DIR/lib/secret-patterns.sh"

usage() {
  sed -n '3,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
  echo "hq-delegate-bundle: $*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || die "jq is required but not installed"

# --- argument parsing --------------------------------------------------------

[ "${1:-}" = "build" ] || { usage >&2; exit 1; }
shift

COMPANY="" PROJECT="" TO="" TO_KIND="person" TO_NAME="" MODE="transfer" DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --company) COMPANY="${2:-}"; shift 2 ;;
    --project) PROJECT="${2:-}"; shift 2 ;;
    --to)      TO="${2:-}"; shift 2 ;;
    --to-kind) TO_KIND="${2:-}"; shift 2 ;;
    --to-name) TO_NAME="${2:-}"; shift 2 ;;
    --mode)    MODE="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$COMPANY" ] || die "--company is required"
[ -n "$PROJECT" ] || die "--project is required"
[ -n "$TO" ]      || die "--to is required"
case "$MODE" in transfer|share) ;; *) die "--mode must be transfer or share" ;; esac
case "$TO_KIND" in person|agent) ;; *) die "--to-kind must be person or agent" ;; esac

PROJECT_DIR="$HQ_ROOT/companies/$COMPANY/projects/$PROJECT"
PRD="$PROJECT_DIR/prd.json"
[ -d "$PROJECT_DIR" ] || die "project directory not found: companies/$COMPANY/projects/$PROJECT"
[ -f "$PRD" ] || die "project has no prd.json: companies/$COMPANY/projects/$PROJECT/prd.json"
jq -e . "$PRD" >/dev/null 2>&1 || die "prd.json is not valid JSON: $PRD"

# --- identity ----------------------------------------------------------------

CREATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DELEGATION_ID="dlg-$(date -u +%Y%m%d-%H%M%S)-$PROJECT"
FROM_EMAIL="" FROM_UID=""
if command -v hq >/dev/null 2>&1; then
  WHOAMI_JSON="$(hq whoami --json 2>/dev/null || true)"
  if [ -n "$WHOAMI_JSON" ] && printf '%s' "$WHOAMI_JSON" | jq -e . >/dev/null 2>&1; then
    FROM_EMAIL="$(printf '%s' "$WHOAMI_JSON" | jq -r '.email // empty')"
    FROM_UID="$(printf '%s' "$WHOAMI_JSON" | jq -r '.personUid // .uid // empty')"
  fi
fi

# --- checksum helper (macOS + Linux) -----------------------------------------

file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# --- derive vault prefixes, knowledge, policies ------------------------------
#
# Vault prefixes are BUCKET-RELATIVE (never prefixed with companies/<slug>/)
# and always in trailing-slash folder form — see hq-files "Prefix Conventions".

PROJECT_PREFIX="projects/$PROJECT/"

# knowledge entries from prd metadata: split into vault-grantable (under this
# company), policies (under this company's policies/), and repo-based docs
# (recorded for the brief, never granted as vault prefixes).
KNOWLEDGE_JSON="$(jq -c '[.metadata.knowledge // [] | .[]]' "$PRD")"

VAULT_READ_PREFIXES="$(printf '%s' "$KNOWLEDGE_JSON" | jq -r --arg co "$COMPANY" '
  [ .[]
    | select(startswith("companies/" + $co + "/"))
    | sub("^companies/" + $co + "/"; "")
    # a file path -> its containing folder; a dir path -> itself with slash
    | if endswith("/") then . else (split("/")[:-1] | join("/") + "/") end
  ] | unique | .[]')"

MANIFEST_KNOWLEDGE="$(printf '%s' "$KNOWLEDGE_JSON" | jq -c --arg co "$COMPANY" '
  [ .[] | select((startswith("companies/" + $co + "/policies/")) | not) ] | unique')"
MANIFEST_POLICIES="$(printf '%s' "$KNOWLEDGE_JSON" | jq -c --arg co "$COMPANY" '
  [ .[] | select(startswith("companies/" + $co + "/policies/")) ] | unique')"

# vaultPrefixes[]: write on the project dossier, read on referenced knowledge.
VAULT_PREFIXES_JSON="$(
  {
    jq -cn --arg p "$PROJECT_PREFIX" \
      '{prefix: $p, permission: "write", reason: "project dossier"}'
    if [ -n "$VAULT_READ_PREFIXES" ]; then
      printf '%s\n' "$VAULT_READ_PREFIXES" | while IFS= read -r pfx; do
        [ -n "$pfx" ] || continue
        jq -cn --arg p "$pfx" \
          '{prefix: $p, permission: "read", reason: "referenced knowledge/policies"}'
      done
    fi
  } | jq -cs 'unique_by(.prefix)'
)"

# Guard: every prefix must be folder form and company-relative.
printf '%s' "$VAULT_PREFIXES_JSON" | jq -e '
  all(.[]; (.prefix | endswith("/")) and (.prefix | startswith("companies/") | not))
' >/dev/null || die "internal error: derived a non-folder or company-anchored prefix"

# --- repo block (recorded here; verified/pushed by the US-004 step) ----------

REPO_PATH="$(jq -r '.metadata.repoPath // empty' "$PRD")"
if [ -n "$REPO_PATH" ]; then
  REPO_JSON="$(jq -cn \
    --arg path "$REPO_PATH" \
    --arg branch "$(jq -r '.branchName // empty' "$PRD")" \
    --arg base "$(jq -r '.metadata.baseBranch // "main"' "$PRD")" \
    '{path: $path, remote: null, branch: (if $branch == "" then null else $branch end),
      baseBranch: $base, headSha: null, dirtyFiles: [], accessVerified: false}')"
else
  REPO_JSON="null"
fi

# --- board id ----------------------------------------------------------------

BOARD_ID="null"
BOARD_FILE="$HQ_ROOT/companies/$COMPANY/board.json"
if [ -f "$BOARD_FILE" ]; then
  BOARD_ID="$(jq --arg prd "companies/$COMPANY/projects/$PROJECT/prd.json" \
    '[.projects // [] | .[] | select(.prd_path == $prd) | .id] | first // null' \
    "$BOARD_FILE" 2>/dev/null || echo null)"
fi

# --- checksums of the project dossier ----------------------------------------

CHECKSUMS_JSON="$(
  cd "$HQ_ROOT" || exit 1
  find "companies/$COMPANY/projects/$PROJECT" -type f ! -name '.DS_Store' | sort | head -200 | \
  while IFS= read -r f; do
    jq -cn --arg p "$f" --arg h "$(file_sha256 "$f")" '{key: $p, value: $h}'
  done | jq -s 'from_entries'
)"

# --- build in a temp dir, scan, then move into place -------------------------

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

jq -n \
  --arg id "$DELEGATION_ID" \
  --arg createdAt "$CREATED_AT" \
  --arg mode "$MODE" \
  --arg fromEmail "$FROM_EMAIL" \
  --arg fromUid "$FROM_UID" \
  --arg toKind "$TO_KIND" \
  --arg toPrincipal "$TO" \
  --arg toName "$TO_NAME" \
  --arg company "$COMPANY" \
  --arg project "$PROJECT" \
  --arg prdPath "companies/$COMPANY/projects/$PROJECT/prd.json" \
  --argjson boardId "$BOARD_ID" \
  --argjson vaultPrefixes "$VAULT_PREFIXES_JSON" \
  --argjson repo "$REPO_JSON" \
  --argjson knowledge "$MANIFEST_KNOWLEDGE" \
  --argjson policies "$MANIFEST_POLICIES" \
  --argjson checksums "$CHECKSUMS_JSON" \
  '{
    schemaVersion: 1,
    delegationId: $id,
    createdAt: $createdAt,
    mode: $mode,
    from: {email: (if $fromEmail == "" then null else $fromEmail end),
           personUid: (if $fromUid == "" then null else $fromUid end)},
    to: {kind: $toKind, principal: $toPrincipal,
         displayName: (if $toName == "" then null else $toName end)},
    company: $company,
    project: {name: $project, prdPath: $prdPath, boardId: $boardId},
    vaultPrefixes: $vaultPrefixes,
    repo: $repo,
    secrets: [],
    knowledge: $knowledge,
    policies: $policies,
    checksums: $checksums,
    status: "building"
  }' > "$STAGE/manifest.json"

# --- BRIEF.md — full prose for a reader who has never seen the project -------

DESCRIPTION="$(jq -r '.description // "No description recorded."' "$PRD")"
GOAL="$(jq -r '.metadata.goal // empty' "$PRD")"
TOTAL_STORIES="$(jq -r '[.userStories // [] | .[]] | length' "$PRD")"
DONE_STORIES="$(jq -r '[.userStories // [] | .[] | select(.passes == true)] | length' "$PRD")"
DONE_LIST="$(jq -r '[.userStories // [] | .[] | select(.passes == true)] | .[] | "- \(.id): \(.title)"' "$PRD")"
NEXT_STEPS="$(jq -r '[.userStories // [] | .[] | select(.passes != true)]
  | sort_by(.priority) | .[:3] | .[]
  | "### \(.id): \(.title)\n\n\(.description)\n"' "$PRD")"
OPEN_QUESTIONS="$(jq -r '[.metadata.openQuestions // [] | .[]] | .[] | "- \(.)"' "$PRD")"
TRAPS="$(jq -r '[.metadata.securityNotes // empty, (.metadata.executionConventions // [] | .[])]
  | .[] | "- \(.)"' "$PRD")"

{
  echo "# Delegation brief — $PROJECT"
  echo
  echo "You are receiving ownership of the **$PROJECT** project in the **$COMPANY** company. This brief is written assuming you have never seen the project before. Everything referenced here is covered by the access you have already been granted — nothing below requires asking the delegator for permissions."
  echo
  echo "## What this project is"
  echo
  echo "$DESCRIPTION"
  if [ -n "$GOAL" ]; then
    echo
    echo "## The goal"
    echo
    echo "$GOAL"
  fi
  echo
  echo "## Where things stand"
  echo
  echo "$DONE_STORIES of $TOTAL_STORIES stories are complete."
  if [ -n "$DONE_LIST" ]; then
    echo
    echo "Already done:"
    echo
    echo "$DONE_LIST"
  fi
  echo
  echo "## The next three steps"
  echo
  if [ -n "$NEXT_STEPS" ]; then
    echo "$NEXT_STEPS"
  else
    echo "All stories are complete. Remaining work, if any, is described in the project's post-implementation notes."
  fi
  if [ -n "$OPEN_QUESTIONS" ]; then
    echo "## Open questions"
    echo
    echo "$OPEN_QUESTIONS"
    echo
  fi
  if [ -n "$TRAPS" ]; then
    echo "## Known traps and conventions"
    echo
    echo "$TRAPS"
    echo
  fi
  echo "## Where everything lives"
  echo
  echo "The full PRD (every story, acceptance criteria, and decision history) is at \`companies/$COMPANY/projects/$PROJECT/prd.json\`. The pickup prompt that accompanied this brief pulls every file you need on demand — you do not need to run a full sync."
} > "$STAGE/BRIEF.md"

# --- fail-closed secret scan -------------------------------------------------

if ! hq_scan_secrets "$STAGE/manifest.json" "$STAGE/BRIEF.md"; then
  die "generated bundle matched a secret-detection pattern — nothing written (see stderr above)"
fi

# --- dry run: print the manifest, write nothing ------------------------------

if [ "$DRY_RUN" -eq 1 ]; then
  cat "$STAGE/manifest.json"
  rm -rf "$STAGE"
  trap - EXIT
  echo "hq-delegate-bundle: dry run — nothing written" >&2
  exit 0
fi

# --- move into place ---------------------------------------------------------

DEST="$HQ_ROOT/workspace/delegations/$DELEGATION_ID"
mkdir -p "$(dirname "$DEST")"
mv "$STAGE" "$DEST"
trap - EXIT

echo "$DELEGATION_ID"
echo "hq-delegate-bundle: wrote workspace/delegations/$DELEGATION_ID/{manifest.json,BRIEF.md}" >&2
