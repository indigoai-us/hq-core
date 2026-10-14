#!/usr/bin/env bash
# hq-core: public
# hq-delegate-transfer.sh — make a delegation real everywhere HQ tracks
# ownership: board entry, PRD metadata, work mesh, and the project journal.
#
# Usage:
#   core/scripts/hq-delegate-transfer.sh --manifest <path>
#
# Behavior (mode "transfer"; mode "share" skips every mutation):
#   1. companies/<co>/board.json — the project's entry gets owner=<recipient>
#      and a bumped updated_at; created (once) if absent. A brainstorm-stage
#      entry (status exploring, brainstorm_path set) is matched by
#      brainstorm_path and keeps its status.
#   2. prd.json metadata gains owner, delegatedFrom, delegatedAt; for a
#      brainstorm-stage project the same three keys land in the
#      brainstorm.md frontmatter (owner, delegated_from, delegated_at)
#   3. work-mesh: a thread note broadcasts the reassignment and
#      `hq mesh project reassign` transfers project ownership and the
#      delegator's open stories; manifest workMeshOwnership becomes
#      "confirmed" only on a server receipt naming the recipient. Silently
#      skipped when hq is unavailable — the transfer still succeeds
#   4. a dated "Delegated" stanza is appended to the project journal naming
#      the recipient, delegation id, and transferred scope
#
# Idempotent: re-running updates owner/timestamps in place — never a
# duplicate board entry, never a duplicated journal stanza.
#
# The delegator's own vault access is untouched (granting the recipient
# write does not revoke anything).
#
# Env: HQ_ROOT — HQ root override (default: resolved from script location)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HQ_ROOT="${HQ_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

usage() { sed -n '3,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die()   { echo "hq-delegate-transfer: $*" >&2; exit 1; }

# shellcheck source=lib/delegate-brainstorm.sh
. "$SCRIPT_DIR/lib/delegate-brainstorm.sh"

command -v jq >/dev/null 2>&1 || die "jq is required but not installed"

MANIFEST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --manifest) MANIFEST="${2:-}"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$MANIFEST" ] || die "--manifest is required"
[ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"
jq -e . "$MANIFEST" >/dev/null 2>&1 || die "manifest is not valid JSON: $MANIFEST"

MODE="$(jq -r '.mode // "transfer"' "$MANIFEST")"
COMPANY="$(jq -r '.company // empty' "$MANIFEST")"
PROJECT="$(jq -r '.project.name // empty' "$MANIFEST")"
PRINCIPAL="$(jq -r '.to.principal // empty' "$MANIFEST")"
DISPLAY="$(jq -r '.to.displayName // .to.principal // empty' "$MANIFEST")"
DELEGATION_ID="$(jq -r '.delegationId // empty' "$MANIFEST")"
FROM="$(jq -r '.from.email // .from.personUid // "unknown"' "$MANIFEST")"
[ -n "$COMPANY" ]   || die "manifest has no company"
[ -n "$PROJECT" ]   || die "manifest has no project.name"
[ -n "$PRINCIPAL" ] || die "manifest has no to.principal"

if [ "$MODE" = "share" ]; then
  echo "hq-delegate-transfer: mode is 'share' — ownership stays with the delegator, nothing mutated"
  exit 0
fi

jq -e '.status == "granted"' "$MANIFEST" >/dev/null || die "transfer requires confirmed grants (status granted)"
[ "$FROM" != "unknown" ] && [ -n "$FROM" ] || die "sender identity missing; rebuild the bundle"
NOW="$(jq -r '.ownershipTransferredAt // empty' "$MANIFEST")"
[ -n "$NOW" ] || NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TODAY="$(date -u +%Y-%m-%d)"
STAGE="$(jq -r '.project.stage // "prd"' "$MANIFEST")"
PROJECT_REL="companies/$COMPANY/projects/$PROJECT"
PRD_PATH="$PROJECT_REL/prd.json"
PRD_ABS="$HQ_ROOT/$PRD_PATH"
BRAINSTORM_PATH="$PROJECT_REL/brainstorm.md"
BRAINSTORM_ABS="$HQ_ROOT/$BRAINSTORM_PATH"
PROJECT_DIR="$HQ_ROOT/$PROJECT_REL"
BOARD="$HQ_ROOT/companies/$COMPANY/board.json"

case "$STAGE" in
  prd)        [ -f "$PRD_ABS" ] || die "prd not found: $PRD_PATH" ;;
  brainstorm) [ -f "$BRAINSTORM_ABS" ] || die "brainstorm.md not found: $BRAINSTORM_PATH" ;;
  *)          die "manifest project.stage is '$STAGE' — expected prd or brainstorm" ;;
esac

# --- 1. board entry: update in place, create once if absent ------------------

if [ -f "$BOARD" ]; then
  jq -e . "$BOARD" >/dev/null 2>&1 || die "board.json is not valid JSON: $BOARD"
else
  echo '{"projects": []}' > "$BOARD"
fi

if [ "$STAGE" = prd ]; then
  TITLE="$(jq -r '.name // empty' "$PRD_ABS")"
  DESC="$(jq -r '.description // ""' "$PRD_ABS" | head -c 300)"
  MATCH_PRD="$PRD_PATH"
  MATCH_BS=""
  NEW_STATUS="in_progress"
else
  TITLE="$(hq_brainstorm_title "$BRAINSTORM_ABS")"
  DESC="$(hq_brainstorm_summary "$BRAINSTORM_ABS" | head -c 300)"
  MATCH_PRD=""
  MATCH_BS="$BRAINSTORM_PATH"
  NEW_STATUS="exploring"
fi
[ -n "$TITLE" ] || TITLE="$PROJECT"

# An existing entry is matched by prd_path (PRD stage) or brainstorm_path
# (brainstorm stage). The match is by path, so a brainstorm entry whose
# prd_path is null still updates in place and keeps its status.
TMP_BOARD="$(mktemp)"
jq \
  --arg prd "$MATCH_PRD" \
  --arg bs "$MATCH_BS" \
  --arg owner "$PRINCIPAL" \
  --arg now "$NOW" \
  --arg title "$TITLE" \
  --arg desc "$DESC" \
  --arg project "$PROJECT" \
  --arg status "$NEW_STATUS" \
  '
  def matches: ($prd != "" and .prd_path == $prd) or ($bs != "" and .brainstorm_path == $bs);
  if ([.projects // [] | .[] | select(matches)] | length) > 0 then
    .projects = [.projects[] |
      if matches then .owner = $owner | .updated_at = $now else . end]
  else
    .projects = (.projects // []) + [{
      id: ("proj-" + $project),
      title: $title,
      description: $desc,
      status: $status,
      owner: $owner,
      prd_path: (if $prd == "" then null else $prd end),
      created_at: $now,
      updated_at: $now
    } + (if $bs == "" then {} else {brainstorm_path: $bs} end)]
  end
  | .updated_at = $now
  ' "$BOARD" > "$TMP_BOARD" && mv "$TMP_BOARD" "$BOARD"

# --- 2. ownership on the source of truth -------------------------------------
# PRD stage: prd.json metadata. Brainstorm stage: brainstorm.md frontmatter.

if [ "$STAGE" = prd ]; then
  TMP_PRD="$(mktemp)"
  jq \
    --arg owner "$PRINCIPAL" \
    --arg from "$FROM" \
    --arg now "$NOW" \
    '.metadata.owner = $owner
     | .metadata.delegatedFrom = $from
     | .metadata.delegatedAt = $now' \
    "$PRD_ABS" > "$TMP_PRD" && mv "$TMP_PRD" "$PRD_ABS"
else
  hq_brainstorm_frontmatter_set "$BRAINSTORM_ABS" owner "$PRINCIPAL"
  hq_brainstorm_frontmatter_set "$BRAINSTORM_ABS" delegated_from "$FROM"
  hq_brainstorm_frontmatter_set "$BRAINSTORM_ABS" delegated_at "$NOW"
fi

# --- 3. work mesh: close the delegator's thread, broadcast reassignment ------
MESH_OWNERSHIP="unconfirmed"
TO_UID="$(jq -r '.to.uid // .to.personUid // .to.agentUid // .to.principal // empty' "$MANIFEST")"
MESH_PROJECT="$PROJECT"
if [ "$STAGE" = prd ]; then
  MESH_PROJECT="$(jq -r --arg p "$PROJECT" '.metadata.workMeshProjectId // .metadata.projectId // $p' "$PRD_ABS" 2>/dev/null || printf '%s' "$PROJECT")"
fi
# Silently tolerated when unavailable (local/offline installs no-op).

if command -v hq >/dev/null 2>&1; then
  # `--session-id` is the CLI option (hq-cli 5.157+ rejects `--session` with
  # "unknown option"); --company-slug/--project attribute the note to the
  # delegated project.
  #
  # The session id must be unique per delegation. The mesh keys session
  # ownership on (company, sessionId): a shared literal such as "delegate" is
  # owned by whoever ran the first delegation in the company, and every later
  # delegator is rejected with SESSION_OWNER_MISMATCH even as company owner.
  MESH_SESSION_ID="${HQ_SESSION_ID:-$DELEGATION_ID}"
  hq mesh session note --enqueue --session-id "$MESH_SESSION_ID" --seq 1 \
    --harness claude-code --adapter-version 1.0.0 \
    --company-slug "$COMPANY" --project "$PROJECT" \
    --summary "Delegated to $DISPLAY ($PRINCIPAL) — delegation $DELEGATION_ID; ownership transferred" \
    || echo "hq-delegate-transfer: mesh note failed; authoritative mesh ownership remains unconfirmed" >&2

  # Authoritative transfer: `hq mesh project reassign` moves project thread
  # ownership and the delegator's open stories to the recipient. Confirmed only
  # when the server answers with the recipient as owner; an older CLI or server
  # (unknown command, 404) leaves ownership "unconfirmed" and the run continues.
  # PROJECT_VIEW_NOT_FOUND means the project was never registered on the board:
  # there is nothing to reassign, so that is "not-registered", not "unconfirmed".
  # The mesh directory matches uids, not emails. A recipient resolved by
  # hq-delegate-resolve.sh is often known only by email, so look up the
  # personUid from company membership first. If that fails, the email is
  # passed through and the reassign reports unconfirmed as before.
  case "$TO_UID" in
    *@*)
      RESOLVED_UID="$(hq people resolve "$TO_UID" --company "$COMPANY" --membership-only --json 2>/dev/null \
        | jq -r 'select(.status == "found") | .person.personUid // empty' 2>/dev/null || true)"
      case "$RESOLVED_UID" in prs_*) TO_UID="$RESOLVED_UID" ;; esac
      ;;
  esac
  REASSIGN_ERR="$(mktemp)"
  REASSIGN_OUT="$(hq mesh project reassign "$MESH_PROJECT" --company "$COMPANY" \
    --to "$TO_UID" --include-open-stories \
    --note "Delegated via /delegate ($DELEGATION_ID)" --json 2>"$REASSIGN_ERR" || true)"
  REASSIGN_ERR_TEXT="$(cat "$REASSIGN_ERR" 2>/dev/null || true)"
  rm -f "$REASSIGN_ERR"
  if printf '%s' "$REASSIGN_OUT" | jq -e --arg to "$TO_UID" \
      '(.ok != false) and ((.ownerUid // "") != "") and ((.ownerUid == $to) or ($to | test("@")))' >/dev/null 2>&1; then
    MESH_OWNERSHIP="confirmed"
  elif printf '%s\n%s' "$REASSIGN_OUT" "$REASSIGN_ERR_TEXT" | grep -q 'PROJECT_VIEW_NOT_FOUND'; then
    MESH_OWNERSHIP="not-registered"
    echo "hq-delegate-transfer: project $MESH_PROJECT has no Work Mesh board; local ownership is authoritative; nothing to reassign. To track it on the board, register it with \`hq mesh project register\` (see \`hq mesh project --help\`)" >&2
  else
    echo "hq-delegate-transfer: hq mesh project reassign did not confirm; Work Mesh ownership remains unconfirmed" >&2
  fi
fi

# --- 4. journal: one dated stanza per delegation id --------------------------

JOURNAL_DIR="$PROJECT_DIR/journal"
JOURNAL_FILE="$JOURNAL_DIR/delegations.md"
mkdir -p "$JOURNAL_DIR"
if [ ! -f "$JOURNAL_FILE" ]; then
  {
    echo "# Delegation log — $PROJECT"
    echo
    echo "Ownership handoffs for this project, appended by /delegate."
  } > "$JOURNAL_FILE"
fi

if ! grep -qF "$DELEGATION_ID" "$JOURNAL_FILE"; then
  SCOPE="$(jq -r '[.vaultPrefixes // [] | .[] | .prefix] | join(", ")' "$MANIFEST")"
  {
    echo
    echo "## $TODAY — Delegated to $DISPLAY"
    echo
    echo "- Delegation: \`$DELEGATION_ID\`"
    echo "- From: $FROM"
    echo "- To: $DISPLAY ($PRINCIPAL)"
    echo "- Transferred scope: $SCOPE"
    if [ "$STAGE" = prd ]; then
      echo "- Local board and PRD ownership updated; Work Mesh ownership is $MESH_OWNERSHIP. Existing delegator access is unchanged."
    else
      echo "- Brainstorm-stage project (no PRD yet). Local board and brainstorm.md ownership updated; Work Mesh ownership is $MESH_OWNERSHIP. Existing delegator access is unchanged."
    fi
  } >> "$JOURNAL_FILE"
fi

# --- record on the manifest ---------------------------------------------------

TMP_MANIFEST="$(mktemp)"
jq --arg now "$NOW" --arg mesh "$MESH_OWNERSHIP" '.ownershipTransferredAt = $now | .workMeshOwnership = $mesh' "$MANIFEST" > "$TMP_MANIFEST" \
  && mv "$TMP_MANIFEST" "$MANIFEST"

if [ "$STAGE" = prd ]; then
  echo "hq-delegate-transfer: ownership of '$PROJECT' transferred to $DISPLAY ($PRINCIPAL) — local board, PRD, and journal updated; Work Mesh ownership $MESH_OWNERSHIP"
else
  echo "hq-delegate-transfer: ownership of '$PROJECT' (brainstorm stage) transferred to $DISPLAY ($PRINCIPAL) — local board, brainstorm.md, and journal updated; Work Mesh ownership $MESH_OWNERSHIP"
fi
