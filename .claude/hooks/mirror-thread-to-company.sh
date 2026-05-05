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

# Parse thread metadata. company can be string or array.
COMPANIES_JSON=$(jq -r '
  .metadata.company // empty
  | if type == "array" then . else [.] end
  | .[]
' "$FILE_PATH" 2>/dev/null || true)

[ -z "$COMPANIES_JSON" ] && exit 0

THREAD_ID=$(jq -r '.thread_id // empty' "$FILE_PATH")
[ -z "$THREAD_ID" ] && exit 0

UPDATED_AT=$(jq -r '.updated_at // .created_at // empty' "$FILE_PATH")
KIND=$(jq -r '.type // "unknown"' "$FILE_PATH")
TITLE=$(jq -r '.metadata.title // .conversation_summary // ""' "$FILE_PATH" | head -c 200)

# Mirror to each touched company
echo "$COMPANIES_JSON" | while IFS= read -r CO; do
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
