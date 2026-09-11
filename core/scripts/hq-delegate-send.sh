#!/usr/bin/env bash
# hq-core: public
# hq-delegate-send.sh — generate the self-sufficient pickup prompt for a
# delegation and deliver it by DM. The prompt IS the handoff: pasted into a
# fresh agent session on a clean HQ install, it pulls every file on demand
# (hq files get per prefix — no /hq-sync run) and reaches the first
# next-step with no follow-up question to the delegator.
#
# Usage:
#   core/scripts/hq-delegate-send.sh --manifest <path> [--send]
#     [--headline <text>] [--note <text>]
#
# Without --send: (re)generates PICKUP-PROMPT.md next to the manifest and
# prints its path — inspectable, idempotent, sends nothing.
# With --send: requires manifest status "verified" (the US-008 probe must
# have passed), then delivers ONE `hq dm` with --prompt-file/--details-file
# and advances status to "sent", recording the DM eventId.
#
# The caller (the /delegate skill) humanizes --headline / --note per
# core/knowledge/public/hq-core/humanize-before-send.md (channel dm, light)
# BEFORE invoking; this helper never rewrites recipients, flags, or the
# generated command lines.
#
# Fail-closed: the generated prompt is scanned for secret-shaped content and
# share-session URLs; a match aborts before anything is written or sent
# (policy hq-delegate-never-inlines-secrets-or-share-urls).
#
# Env: HQ_ROOT — HQ root override (default: resolved from script location)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HQ_ROOT="${HQ_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# shellcheck source=lib/secret-patterns.sh
. "$SCRIPT_DIR/lib/secret-patterns.sh"

usage() { sed -n '3,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die()   { echo "hq-delegate-send: $*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required but not installed"

MANIFEST="" SEND=0 HEADLINE="" NOTE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --manifest) MANIFEST="${2:-}"; shift 2 ;;
    --send)     SEND=1; shift ;;
    --headline) HEADLINE="${2:-}"; shift 2 ;;
    --note)     NOTE="${2:-}"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$MANIFEST" ] || die "--manifest is required"
[ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"
jq -e . "$MANIFEST" >/dev/null 2>&1 || die "manifest is not valid JSON: $MANIFEST"
LOCK="$MANIFEST.send-lock"
if [ "$SEND" -eq 1 ]; then
  mkdir "$LOCK" 2>/dev/null || die "verification or delivery is active; retry after it finishes"
  trap 'rmdir "$LOCK"' EXIT
fi

BUNDLE_DIR="$(cd "$(dirname "$MANIFEST")" && pwd)"
BRIEF="$BUNDLE_DIR/BRIEF.md"
PROMPT="$BUNDLE_DIR/PICKUP-PROMPT.md"

COMPANY="$(jq -r '.company // empty' "$MANIFEST")"
PROJECT="$(jq -r '.project.name // empty' "$MANIFEST")"
PRINCIPAL="$(jq -r '.to.principal // empty' "$MANIFEST")"
DISPLAY="$(jq -r '.to.displayName // .to.principal' "$MANIFEST")"
FROM="$(jq -r '.from.email // .from.personUid // "your teammate"' "$MANIFEST")"
DELEGATION_ID="$(jq -r '.delegationId // empty' "$MANIFEST")"
STATUS="$(jq -r '.status // empty' "$MANIFEST")"
MODE="$(jq -r '.mode // "transfer"' "$MANIFEST")"
[ -n "$COMPANY" ]   || die "manifest has no company"
[ -n "$PROJECT" ]   || die "manifest has no project.name"
[ -n "$PRINCIPAL" ] || die "manifest has no to.principal"

PRD_ABS="$HQ_ROOT/$(jq -r '.project.prdPath' "$MANIFEST")"

# --- assemble prompt sections from the manifest (single source of truth) -----

GOAL="" STATE_LINE="" NEXT_STEPS=""
if [ -f "$PRD_ABS" ] && jq -e . "$PRD_ABS" >/dev/null 2>&1; then
  GOAL="$(jq -r '.metadata.goal // .description // ""' "$PRD_ABS")"
  TOTAL="$(jq -r '[.userStories // [] | .[]] | length' "$PRD_ABS")"
  DONE="$(jq -r '[.userStories // [] | .[] | select(.passes == true)] | length' "$PRD_ABS")"
  STATE_LINE="$DONE of $TOTAL stories are complete."
  NEXT_STEPS="$(jq -r '[.userStories // [] | .[] | select(.passes != true)]
    | sort_by(.priority) | .[:3] | to_entries | .[]
    | "\(.key + 1). **\(.value.id): \(.value.title)** — \(.value.description)"' "$PRD_ABS")"
fi

GET_LINES="$(jq -r --arg co "$COMPANY" \
  '.vaultPrefixes[] | "hq files get \(.prefix) --company \($co)"' "$MANIFEST")"

REPO_IS_NULL="$(jq -r 'if .repo == null then "yes" else "no" end' "$MANIFEST")"
REPO_SECTION=""
if [ "$REPO_IS_NULL" = "no" ]; then
  R_PATH="$(jq -r '.repo.path // empty' "$MANIFEST")"
  R_REMOTE="$(jq -r '.repo.remote // empty' "$MANIFEST")"
  R_BRANCH="$(jq -r '.repo.branch // empty' "$MANIFEST")"
  R_BASE="$(jq -r '.repo.baseBranch // "main"' "$MANIFEST")"
  R_SHA="$(jq -r '.repo.headSha // empty' "$MANIFEST")"
  R_ACCESS="$(jq -r '.repo.accessNote // empty' "$MANIFEST")"
  if [ -n "$R_BRANCH" ] && git check-ref-format --branch "$R_BRANCH" >/dev/null 2>&1 && [ -n "$R_SHA" ]; then
    REPO_SECTION="## Get the code

The work lives on branch \`$R_BRANCH\` (base: \`$R_BASE\`)${R_SHA:+ at \`$R_SHA\`}.

\`\`\`bash
# From your HQ root; clone first if the repo is not present${R_REMOTE:+ (remote: $R_REMOTE)}:
git -C $(printf '%q' "$R_PATH") fetch origin
git -C $(printf '%q' "$R_PATH") switch -- $(printf '%q' "$R_BRANCH")
\`\`\`
${R_ACCESS:+
> $R_ACCESS
}"
  fi
fi

SECRET_NAMES="$(jq -r '[.secrets // [] | .[]] | join(",")' "$MANIFEST")"
SECRETS_SECTION=""
if [ -n "$SECRET_NAMES" ]; then
  SECRETS_SECTION="## Credentials

You have been granted read access to the secret names this project needs: \`$SECRET_NAMES\`. Values never travel in this handoff — consume them at runtime:

\`\`\`bash
# Inject from the project's .env.schema:
hq run -- <your command>
# Or explicitly by name:
hq secrets exec --only $SECRET_NAMES --company $COMPANY -- <your command>
\`\`\`
"
fi

# --- write the prompt (staged, scanned, then placed) -------------------------

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"; [ "$SEND" -eq 0 ] || rmdir "$LOCK"' EXIT

{
  echo "# Project handoff: $PROJECT"
  echo
  if [ "$MODE" = "share" ]; then
    echo "$FROM has shared the **$PROJECT** project ($COMPANY) with you${NOTE:+ — $NOTE}. You are working on it together; ownership stays with them."
  else
    echo "$FROM has delegated the **$PROJECT** project ($COMPANY) to you${NOTE:+ — $NOTE}. Transfer status is recorded in the dossier. Work Mesh ownership requires separate confirmation. Delegation id: \`$DELEGATION_ID\`."
  fi
  echo
  echo "Completed grant and publication steps are recorded as receipts in the manifest. Sender-side checks do not prove your access: pull the files below and acknowledge receipt, or report any access error."
  echo
  if [ -n "$GOAL" ]; then
    echo "## The goal"
    echo
    echo "$GOAL"
    echo
  fi
  if [ -n "$STATE_LINE" ]; then
    echo "## Where things stand"
    echo
    echo "$STATE_LINE"
    echo
  fi
  echo "## Pull the files (on demand — no sync)"
  echo
  echo "Run these from your HQ root; each materializes exactly that path locally:"
  echo
  echo '```bash'
  printf '%s\n' "$GET_LINES"
  echo '```'
  echo
  echo "Start with the project dossier: \`companies/$COMPANY/projects/$PROJECT/\` now contains the PRD (\`prd.json\`), a full brief (\`README.md\` / the DM's details pane), and the delegation journal."
  echo
  if [ -n "$REPO_SECTION" ]; then
    printf '%s\n' "$REPO_SECTION"
    echo
  fi
  if [ -n "$SECRETS_SECTION" ]; then
    printf '%s\n' "$SECRETS_SECTION"
    echo
  fi
  if [ -n "$NEXT_STEPS" ]; then
    echo "## Your next three steps"
    echo
    printf '%s\n' "$NEXT_STEPS"
    echo
  fi
  echo "## If something is off"
  echo
  echo "The manifest and BRIEF.md are published under \`delegation/$DELEGATION_ID/\` within \`companies/$COMPANY/projects/$PROJECT/\`. If a pull fails or a path looks empty, report it to $FROM."
} > "$STAGE/PICKUP-PROMPT.md"

# fail-closed scans: secret shapes + share-session capability URLs
if ! hq_scan_secrets "$STAGE/PICKUP-PROMPT.md" "$BRIEF"; then
  die "generated pickup prompt matched a secret-detection pattern — aborting, nothing written or sent"
fi
if grep -Eq 'share-session/[A-Za-z0-9_-]+' "$STAGE/PICKUP-PROMPT.md" "$BRIEF" 2>/dev/null; then
  die "a share-session URL appeared in a delegation artifact — forbidden (direct grants only), aborting"
fi

mv "$STAGE/PICKUP-PROMPT.md" "$PROMPT"
rm -rf "$STAGE"
trap '[ "$SEND" -eq 0 ] || rmdir "$LOCK"' EXIT

echo "hq-delegate-send: pickup prompt written: $PROMPT"

[ "$SEND" -eq 1 ] || exit 0

# --- deliver: ONE hq dm invocation, file flags only --------------------------

STATUS="$(jq -r '.status' "$MANIFEST")"
[ "$STATUS" = "verified" ] \
  || die "manifest status is '$STATUS' — the reachability probe (hq-delegate-verify.sh) must pass before sending"
[ -f "$BRIEF" ] || die "BRIEF.md missing from the bundle — cannot send without the details pane"
jq -e '.publication.verifiedAt != null and (.publication.files | type == "object" and length > 0)' "$MANIFEST" >/dev/null \
  || die "verified publication receipt missing; run verification again"
file_hash() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d ' ' -f1; else shasum -a 256 "$1" | cut -d ' ' -f1; fi
}
while IFS= read -r row; do
  path="$(printf '%s' "$row" | jq -r '.key')"
  expected="$(printf '%s' "$row" | jq -r '.value')"
  [ -f "$HQ_ROOT/$path" ] && [ "$(file_hash "$HQ_ROOT/$path")" = "$expected" ] \
    || die "published artifact changed: $path; run verification again"
done < <(jq -c '.publication.files | to_entries[]' "$MANIFEST")
PUBLISHED="$HQ_ROOT/$(jq -r '.publication.manifestPath' "$MANIFEST")"
[ -f "$PUBLISHED" ] || die "published manifest missing; run verification again"
NORMALIZED="$(jq -cS '.status="granted" | .recipientAccess="unconfirmed" | del(.publication,.verifiedAt,.sentAt,.dmEventId)' "$MANIFEST")"
[ "$NORMALIZED" = "$(jq -cS . "$PUBLISHED")" ] || die "manifest changed since publication; run verification again"
[ "$(file_hash "$BRIEF")" = "$(file_hash "$(dirname "$PUBLISHED")/BRIEF.md")" ] \
  || die "brief changed since publication; run verification again"

[ -n "$HEADLINE" ] || HEADLINE="Project handoff: $PROJECT — open the brief, pull the files, and acknowledge receipt"

TMP_MANIFEST="$(mktemp "${MANIFEST}.tmp.XXXXXX")"
if ! jq '.status = "sending"' "$MANIFEST" > "$TMP_MANIFEST" || ! mv "$TMP_MANIFEST" "$MANIFEST"; then
  rm -f "$TMP_MANIFEST"
  die "could not persist sending state; no DM attempted"
fi
DM_OUT="$(hq dm "$PRINCIPAL" "$HEADLINE" --prompt-file "$PROMPT" --details-file "$BRIEF")" \
  || die "hq dm delivery outcome is uncertain; status is sending, inspect DM history before retrying"

EVENT_ID="$(printf '%s' "$DM_OUT" | grep -oE 'eventId[: ]+[A-Za-z0-9_-]+' | head -1 | sed -E 's/eventId[: ]+//' || true)"
[ -n "$EVENT_ID" ] || die "DM response has no receipt; status is sending, reconcile DM history before retrying"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

TMP_MANIFEST="$(mktemp "${MANIFEST}.tmp.XXXXXX")"
if ! jq --arg now "$NOW" --arg ev "${EVENT_ID:-}" \
  '.status = "sent" | .sentAt = $now
   | .dmEventId = (if $ev == "" then null else $ev end)' \
  "$MANIFEST" > "$TMP_MANIFEST" || ! mv "$TMP_MANIFEST" "$MANIFEST"; then
  rm -f "$TMP_MANIFEST"
  die "DM delivered but receipt could not be saved; reconcile delivery before retrying"
fi

echo "hq-delegate-send: DM delivered to $DISPLAY ($PRINCIPAL)${EVENT_ID:+ (eventId $EVENT_ID)} — status advanced to 'sent'"
