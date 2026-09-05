#!/usr/bin/env bash
# UserPromptSubmit hook (US-011 shim): never select or create a project from
# prompt text. Read the work-context state file and only ensure the local
# project folder exists for a server-bound project (materialize prd.json from
# Board snapshot / cache when absent).

set -uo pipefail

STDIN_JSON="$(cat 2>/dev/null || echo '{}')"
HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"

case "${HQ_AUTO_SESSION_PROJECT:-1}" in
  0|false|FALSE|off|OFF|no|NO) exit 0 ;;
esac

disabled_hooks=",${HQ_DISABLED_HOOKS:-},"
disabled_hooks="$(printf '%s' "$disabled_hooks" | tr -d '[:space:]')"
case "$disabled_hooks" in
  *,auto-session-project,*) exit 0 ;;
esac

. "$HQ_ROOT/core/scripts/hook-lib.sh" 2>/dev/null || exit 0

extract() {
  printf '%s' "$STDIN_JSON" | hq_json_get "$1"
}

SESSION_ID="$(extract session_id)"
[ -z "$SESSION_ID" ] && SESSION_ID="$(extract sessionId)"
[ -z "$SESSION_ID" ] && SESSION_ID="${HQ_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}}"
SESSION_ID="$(printf '%s' "$SESSION_ID" | tr -d '[:space:]')"
[ -n "$SESSION_ID" ] || exit 0

# Sanitize session id for paths (no traversal).
case "$SESSION_ID" in
  *..*|*/*|*\\*|*" "*) exit 0 ;;
esac

WC_HOME="${WORK_MESH_HOME:-$HOME}"
STATE="$WC_HOME/.hq/work-context/sessions/$SESSION_ID.json"
[ -f "$STATE" ] || exit 0

# Require jq for safe JSON; fail closed (no project creation).
command -v jq >/dev/null 2>&1 || exit 0

STATUS="$(jq -r '.contextStatus // empty' "$STATE" 2>/dev/null || true)"
[ "$STATUS" = "bound" ] || exit 0

COMPANY="$(jq -r '.companySlug // empty' "$STATE" 2>/dev/null || true)"
PROJECT="$(jq -r '.projectId // empty' "$STATE" 2>/dev/null || true)"
TASK="$(jq -r '.taskId // empty' "$STATE" 2>/dev/null || true)"
COMPANY_UID="$(jq -r '.companyUid // empty' "$STATE" 2>/dev/null || true)"

[ -n "$PROJECT" ] || exit 0

# Prefer slug from state; fall back to session meta.
if [ -z "$COMPANY" ]; then
  meta="$HQ_ROOT/workspace/sessions/$SESSION_ID/meta.yaml"
  if [ -f "$meta" ]; then
    COMPANY="$(awk '$1=="company_slug:"{ sub(/^[^:]+:[[:space:]]*/,""); gsub(/^"|"$/,""); print; exit }' "$meta" 2>/dev/null || true)"
  fi
fi

# Cannot place a local folder without a company slug (never invent one).
[ -n "$COMPANY" ] || exit 0
case "$COMPANY" in
  *[!a-z0-9_-]*|"") exit 0 ;;
esac
case "$PROJECT" in
  *[!a-zA-Z0-9._-]*|"") exit 0 ;;
esac

# Only materialize under a registered company — never mkdir ghost tenants.
MANIFEST="$HQ_ROOT/companies/manifest.yaml"
if [ -f "$MANIFEST" ]; then
  if ! awk -v slug="$COMPANY" '
    BEGIN { found=0 }
    /^companies:[[:space:]]*$/ { wrapped=1; next }
    wrapped && /^[^[:space:]]/ { wrapped=0 }
    wrapped && $1 == slug ":" { found=1; exit }
    !wrapped && $1 == slug ":" { found=1; exit }
    END { exit found ? 0 : 1 }
  ' "$MANIFEST"; then
    exit 0
  fi
else
  exit 0
fi

PROJECT_DIR="$HQ_ROOT/companies/$COMPANY/projects/$PROJECT"
PRD_PATH="$PROJECT_DIR/prd.json"
mkdir -p "$PROJECT_DIR" 2>/dev/null || exit 0

materialize_prd_from_board() {
  local board="$WC_HOME/.hq/work-context/sessions/$SESSION_ID/board.md"
  local cache="" name="$PROJECT" stories_json="[]"

  if [ -n "$COMPANY_UID" ]; then
    cache="$WC_HOME/.hq/work-mesh/cache/projects/$COMPANY_UID/$PROJECT.json"
  fi
  if [ -z "$cache" ] || [ ! -f "$cache" ]; then
    cache="$WC_HOME/.hq/work-mesh/cache/projects/$COMPANY/$PROJECT.json"
  fi

  if [ -f "$cache" ]; then
    name="$(jq -r '.name // .projectName // .title // empty' "$cache" 2>/dev/null || true)"
    [ -n "$name" ] || name="$PROJECT"
    if jq -e '.userStories|type=="array"' "$cache" >/dev/null 2>&1; then
      stories_json="$(jq -c '.userStories' "$cache" 2>/dev/null || printf '[]')"
    elif jq -e '.stories|type=="array"' "$cache" >/dev/null 2>&1; then
      stories_json="$(jq -c '[.stories[] | {
        id: (.id // .storyId // "US-?"),
        title: (.title // .name // ""),
        description: (.description // ""),
        acceptanceCriteria: (.acceptanceCriteria // []),
        priority: (.priority // 3),
        passes: (.passes // false)
      }]' "$cache" 2>/dev/null || printf '[]')"
    fi
  elif [ -f "$board" ]; then
    # Parse "## Stories" bullets: - ID [status] — title
    stories_json="$(
      awk '
        BEGIN { IGNORECASE=1 }
        /^##[ ]+[Ss]tories/ { in_stories=1; next }
        in_stories && /^## / { exit }
        !in_stories { next }
        {
          line=$0
          sub(/^[[:space:]]+/, "", line)
          if (line !~ /^-/) next
          sub(/^-[[:space:]]*/, "", line)
          id=line; sub(/[[:space:]].*/, "", id)
          rest=line; sub(/^[^[:space:]]+[[:space:]]*/, "", rest)
          status=""
          if (rest ~ /^\[/) {
            status=rest
            sub(/^\[/, "", status)
            sub(/\].*/, "", status)
            sub(/^\[[^]]*\][[:space:]]*/, "", rest)
          }
          sub(/^[—–-]+[[:space:]]*/, "", rest)
          title=rest
          gsub(/\|/, "/", id)
          gsub(/\|/, "/", status)
          gsub(/\|/, "/", title)
          printf "%s\t%s\t%s\n", id, status, title
        }
      ' "$board" 2>/dev/null \
      | jq -Rsc '
          split("\n")
          | map(select(length>0))
          | map(split("\t"))
          | map(select(length>=1 and .[0] != ""))
          | map({
              id: .[0],
              title: (if (.[2] // "") == "" then .[0] else .[2] end),
              description: "",
              acceptanceCriteria: [],
              priority: 3,
              passes: ((.[1] // "") | ascii_downcase | IN("done","passes","complete","completed","pass"))
            })
        ' 2>/dev/null || printf "[]"
    )"
    name="$(awk -F': ' '/^- projectName:/{print $2; exit}' "$board" 2>/dev/null || true)"
    [ -n "$name" ] || name="$PROJECT"
  else
    return 0
  fi

  jq -n \
    --arg name "$name" \
    --arg desc "Materialized from Work Mesh Board for bound session (local spec only)." \
    --argjson stories "$stories_json" \
    '{
      name: $name,
      description: $desc,
      branchName: "",
      userStories: $stories,
      metadata: { origin: "work-mesh-live-board", source: "board-or-cache" }
    }' >"$PRD_PATH" 2>/dev/null || true
  chmod 600 -- "$PRD_PATH" 2>/dev/null || true
}

if [ ! -f "$PRD_PATH" ]; then
  materialize_prd_from_board
fi

# Quiet success — no additionalContext that invents a project. Optional pointer.
if [ -f "$PRD_PATH" ] && command -v jq >/dev/null 2>&1; then
  CTX="WORK MESH BOUND PROJECT
Company: $COMPANY
Project: $PROJECT
Local: companies/$COMPANY/projects/$PROJECT
PRD: companies/$COMPANY/projects/$PROJECT/prd.json
Task: ${TASK:-"(none)"}
Local prd.json is spec only — Board/state is live status. Do not create another project."
  jq -n --arg ctx "<auto-session-project>
$CTX
</auto-session-project>" '{
    hookSpecificOutput: {
      hookEventName: "UserPromptSubmit",
      additionalContext: $ctx
    }
  }'
fi
exit 0
