#!/bin/bash
# PostToolUse(Write|Edit): mirror workspace/threads/*.json into companies/{co}/workspace/
# when metadata.company is populated.
#
# Side effects per matched write:
#   1. Hardlink thread file → companies/{co}/workspace/sessions/{thread_id}.json
#   2. Append a row to companies/{co}/workspace/index.jsonl (deduped by thread_id+ts+kind)
#   3. Create per-company .gitignore (sessions/) on first mirror
#
# Skip conditions (fast path, exit 0):
#   - tool_name not in {Write, Edit}
#   - file_path doesn't match workspace/threads/T-*.json
#   - thread JSON missing/unparseable
#   - metadata.company missing
#
# This hook is purely additive. The canonical thread store at workspace/threads/
# remains the source of truth.

set -euo pipefail

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
case "$TOOL_NAME" in
  Write|Edit) ;;
  *) exit 0 ;;
esac

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
[ -z "$FILE_PATH" ] && exit 0

# Match only thread snapshots, not handoff.json / recent.md / INDEX.md
case "$FILE_PATH" in
  */workspace/threads/T-*.json) ;;
  *) exit 0 ;;
esac

[ -f "$FILE_PATH" ] || exit 0

# Resolve HQ root from the thread file path (parent of workspace/)
HQ_ROOT="${FILE_PATH%/workspace/threads/*}"
[ -d "$HQ_ROOT/companies" ] || exit 0

# A thread mirror is safe only when it belongs to exactly one company and
# every company path in its changeset agrees with the session binding. Never
# use the list of touched companies as a list of mirror destinations.
THREAD_COMPANIES_JSON=$(jq -c '
  .metadata.company // empty
  | if type == "array" then . else [.] end
  | map(select(type == "string" and test("^[a-z][a-z0-9_-]*$")))
  | unique
' "$FILE_PATH" 2>/dev/null || printf '[]')
[ "$(jq 'length' <<< "$THREAD_COMPANIES_JSON")" -eq 1 ] || exit 0
COMPANY=$(jq -r '.[0]' <<< "$THREAD_COMPANIES_JSON")

THREAD_PATH_COMPANIES_JSON=$(jq -c --arg hq_root "$HQ_ROOT" '
  [ ((.files_touched // []) | if type == "array" then .[] else empty end)
    | (if type == "string" then . elif type == "object" and (.path | type) == "string" then .path else "" end)
    | (if startswith($hq_root + "/") then .[(($hq_root | length) + 1):] else . end)
    | sub("^\\./"; "")
    | (try capture("^companies/(?<company>[a-z][a-z0-9_-]*)/").company catch null)
    | select(type == "string")
  ] | unique
' "$FILE_PATH" 2>/dev/null || printf '[]')
[ "$(jq 'length' <<< "$THREAD_PATH_COMPANIES_JSON")" -le 1 ] || exit 0
if [ "$(jq 'length' <<< "$THREAD_PATH_COMPANIES_JSON")" -eq 1 ] && \
   [ "$(jq -r '.[0]' <<< "$THREAD_PATH_COMPANIES_JSON")" != "$COMPANY" ]; then
  exit 0
fi

source "$HQ_ROOT/core/scripts/lib/session-id.sh"
SESSION_ID=$(session_id_resolve "$HQ_ROOT")
[ -n "$SESSION_ID" ] || exit 0
SESSION_META="$HQ_ROOT/workspace/sessions/$SESSION_ID/meta.yaml"
[ -r "$SESSION_META" ] || exit 0
BOUND_COMPANY=$(awk '$1 == "company_slug:" { sub(/^[^:]+:[[:space:]]*/, ""); gsub(/^"|"$/, ""); print; exit }' "$SESSION_META" 2>/dev/null || true)
[ "$BOUND_COMPANY" = "$COMPANY" ] || exit 0

THREAD_ID=$(jq -r '.thread_id // empty' "$FILE_PATH")
[ -z "$THREAD_ID" ] && exit 0

UPDATED_AT=$(jq -r '.updated_at // .created_at // empty' "$FILE_PATH")
KIND=$(jq -r '.type // "unknown"' "$FILE_PATH")
TITLE=$(jq -r '.metadata.title // .conversation_summary // ""' "$FILE_PATH" | head -c 200)

# Mirror only into the bound company.
printf '%s\n' "$COMPANY" | while IFS= read -r CO; do
  [ -z "$CO" ] && continue
  CO_DIR="$HQ_ROOT/companies/$CO"
  [ -d "$CO_DIR" ] || continue

  WORKSPACE_DIR="$CO_DIR/workspace"
  SESSIONS_DIR="$WORKSPACE_DIR/sessions"
  INDEX_FILE="$WORKSPACE_DIR/index.jsonl"
  GITIGNORE="$WORKSPACE_DIR/.gitignore"

  mkdir -p "$SESSIONS_DIR"

  # First-time scaffolding: per-company .gitignore that excludes sessions/ but
  # tracks index.jsonl. Idempotent.
  if [ ! -f "$GITIGNORE" ]; then
    {
      echo "# HQ workspace mirror — sessions are gitignored, index.jsonl is committed"
      echo "sessions/"
    } > "$GITIGNORE"
  fi

  # Hardlink the thread snapshot. -f makes it idempotent (replaces existing).
  TARGET="$SESSIONS_DIR/$THREAD_ID.json"
  ln -f "$FILE_PATH" "$TARGET" 2>/dev/null || cp -f "$FILE_PATH" "$TARGET"

  # Build the row, then append only if (thread_id, ts, kind) not already present.
  ROW=$(jq -nc \
    --arg tid "$THREAD_ID" \
    --arg ts "$UPDATED_AT" \
    --arg kind "$KIND" \
    --arg title "$TITLE" \
    --arg company "$CO" \
    '{thread_id:$tid, ts:$ts, kind:$kind, company:$company, title:$title}')

  DEDUP_KEY="\"thread_id\":\"$THREAD_ID\",\"ts\":\"$UPDATED_AT\",\"kind\":\"$KIND\""
  if [ -f "$INDEX_FILE" ] && grep -qF "$DEDUP_KEY" "$INDEX_FILE"; then
    continue
  fi

  echo "$ROW" >> "$INDEX_FILE"
done

exit 0
