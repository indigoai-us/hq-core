#!/bin/bash
# PostToolUse(Write|Edit): mirror workspace/threads/*.json into companies/{co}/workspace/
# when metadata.company is populated.
#
# Side effects per matched write:
#   1. Write a tenant-redacted thread snapshot to companies/{co}/workspace/sessions/{thread_id}.json
#   2. Append a row to companies/{co}/workspace/index.jsonl (deduped by thread_id+ts+kind)
#   3. Create per-company .gitignore (sessions/) on first mirror
#
# Skip conditions (fast path, exit 0):
#   - tool_name not in {Write, Edit}
#   - file_path doesn't match workspace/threads/T-*.json
#   - thread JSON missing/unparseable
#   - metadata.company missing
#
# Refusals (exit 2, reason on stderr; handoff-finalize turns these into exit 5
# when it asked for a mirror):
#   - ambiguous or invalid ownership
#   - a scope capability exists but yields no lock set (no meta.yaml fallback)
#   - no capability and no meta.yaml company_slug (no lock set at all)
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

# Full records have one owner. Arrays of touched tenants are not recipients.
# Reject ambiguous or invalid ownership before any tenant directories or rows exist.
COMPANY=$(jq -er '
  .metadata.company
  | if . == null or . == [] or . == "" then ""
    elif type == "string" then .
    elif type == "array" and length == 1 then .[0]
    else error("thread must have exactly one company owner") end
  | if type != "string" then error("invalid company owner")
    elif . == "" or test("^[a-z0-9][a-z0-9_-]*$") then .
    else error("invalid company owner") end
' "$FILE_PATH") || {
  echo "mirror-thread-to-company: refusing invalid or ambiguous ownership" >&2
  exit 2
}
[ -z "$COMPANY" ] && exit 0

THREAD_PATH_COMPANIES_JSON=$(jq -c --arg hq_root "$HQ_ROOT" '
  [ ((.files_touched // []) | if type == "array" then .[] else empty end)
    | (if type == "string" then . elif type == "object" and (.path | type) == "string" then .path else "" end)
    | (if startswith($hq_root + "/") then .[(($hq_root | length) + 1):] else . end)
    | sub("^\\./"; "")
    | (try capture("^companies/(?<company>[a-z0-9][a-z0-9_-]*)/").company catch null)
    | select(type == "string")
  ] | unique
' "$FILE_PATH" 2>/dev/null || printf '[]')
if [ "$(jq 'length' <<< "$THREAD_PATH_COMPANIES_JSON")" -gt 1 ]; then
  echo "mirror-thread-to-company: refusing invalid or ambiguous ownership" >&2
  exit 2
fi
if [ "$(jq 'length' <<< "$THREAD_PATH_COMPANIES_JSON")" -eq 1 ] && \
   [ "$(jq -r '.[0]' <<< "$THREAD_PATH_COMPANIES_JSON")" != "$COMPANY" ]; then
  echo "mirror-thread-to-company: refusing invalid or ambiguous ownership" >&2
  exit 2
fi

source "$HQ_ROOT/core/scripts/lib/session-id.sh"
SESSION_ID=$(session_id_resolve "$HQ_ROOT")
[ -n "$SESSION_ID" ] || exit 0
SESSION_META="$HQ_ROOT/workspace/sessions/$SESSION_ID/meta.yaml"
SESSION_CAPABILITY="$HQ_ROOT/workspace/sessions/$SESSION_ID/scope-capability.json"
# Always apply the session lock, including desktop sessions with a session id
# and no meta.yaml. Missing-meta used to skip this check and mirror into the
# thread owner even when that company was outside the locked set.
LOCKED_COMPANIES=""
if [ -f "$SESSION_CAPABILITY" ]; then
  # A capability that exists is authoritative. If it is malformed, written for
  # another session or agent, or names a symlinked company, it yields no lock
  # set, and meta.yaml must not override that refusal.
  if [ -f "$HQ_ROOT/core/scripts/lib/session-scope-capability.sh" ]; then
    # shellcheck source=core/scripts/lib/session-scope-capability.sh
    . "$HQ_ROOT/core/scripts/lib/session-scope-capability.sh" 2>/dev/null || true
    if command -v session_scope_read_companies >/dev/null 2>&1; then
      LOCKED_COMPANIES="$(session_scope_read_companies "$HQ_ROOT" "$SESSION_ID" 2>/dev/null || true)"
    fi
  fi
  if [ -z "$LOCKED_COMPANIES" ]; then
    echo "mirror-thread-to-company: refusing to mirror into $COMPANY: the session scope capability is invalid or does not match this session" >&2
    exit 2
  fi
elif [ -r "$SESSION_META" ]; then
  # Fall back to meta.yaml only when no capability file exists.
  LOCKED_COMPANIES=$(awk '$1 == "company_slug:" { sub(/^[^:]+:[[:space:]]*/, ""); gsub(/^"|"$/, ""); print; exit }' "$SESSION_META" 2>/dev/null || true)
fi
# Fail closed, and loudly, when there is no lock set (no capability and no
# meta.yaml company). handoff-finalize reports a non-zero exit as
# "company mirror failed" when a mirror was requested.
if [ -z "$LOCKED_COMPANIES" ]; then
  echo "mirror-thread-to-company: refusing to mirror into $COMPANY: session has no company lock (no scope capability and no meta.yaml company_slug)" >&2
  exit 2
fi
printf '%s\n' "$LOCKED_COMPANIES" | awk -v wanted="$COMPANY" '$0 == wanted { found = 1 } END { exit !found }' || exit 0

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

  # Company mirrors must not copy the root thread's other locked-company
  # identities. Keep the full lock set in the canonical root thread only.
  TARGET="$SESSIONS_DIR/$THREAD_ID.json"
  MIRROR_TMP="$(mktemp "$SESSIONS_DIR/.mirror-XXXXXX")"
  if ! jq --arg company "$CO" '.metadata.company_slugs = [$company]' "$FILE_PATH" > "$MIRROR_TMP"; then
    rm -f "$MIRROR_TMP"
    continue
  fi
  mv -f "$MIRROR_TMP" "$TARGET"

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
