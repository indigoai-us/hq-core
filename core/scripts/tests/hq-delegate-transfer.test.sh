#!/usr/bin/env bash
# Regression: hq-delegate-transfer.sh must reassign ownership everywhere HQ
# tracks it — board, PRD metadata, work mesh, journal — idempotently, with
# --share mode mutating nothing and offline installs still succeeding.
#
# Guards:
#   1. Project already on the board -> owner set, updated_at bumped, array
#      length unchanged (update in place, no duplicate).
#   2. Project absent from the board -> exactly one entry created with the
#      correct prd_path.
#   3. Run twice -> still one board entry, exactly one journal stanza for
#      the delegation id.
#   4. work-mesh.sh present -> invoked with done + company + project + a
#      summary naming the recipient; absent -> transfer still exits 0 and
#      the board/PRD mutations land.
#   5. mode "share" -> board.json and prd.json byte-identical afterward.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HELPER="$ROOT/core/scripts/hq-delegate-transfer.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$HELPER" ] || fail "missing helper: $HELPER"

# --- fixture -----------------------------------------------------------------

make_fixture() { # root  (fresh HQ root with project + board + fake work-mesh)
  local fix="$1"
  rm -rf "$fix"
  mkdir -p "$fix/companies/acme/projects/widget" "$fix/core/scripts"
  cat > "$fix/companies/acme/projects/widget/prd.json" <<'JSON'
{"name": "widget", "description": "Build the widget.", "metadata": {"goal": "ship"}}
JSON
  cat > "$fix/companies/acme/board.json" <<'JSON'
{"projects": [
  {"id": "ac-proj-1", "title": "other", "prd_path": "companies/acme/projects/other/prd.json", "updated_at": "2026-01-01T00:00:00Z"},
  {"id": "ac-proj-7", "title": "widget", "prd_path": "companies/acme/projects/widget/prd.json", "updated_at": "2026-01-01T00:00:00Z"}
]}
JSON
  cat > "$fix/core/scripts/work-mesh.sh" <<'MESH'
#!/usr/bin/env bash
echo "$*" >> "$MESH_STUB_LOG"
exit 0
MESH
  chmod +x "$fix/core/scripts/work-mesh.sh"
}

write_manifest() { # path mode
  cat > "$1" <<JSON
{
  "schemaVersion": 1,
  "delegationId": "dlg-20260807-widget",
  "mode": "$2",
  "company": "acme",
  "from": {"email": "owner@acme.test", "personUid": "prs_owner1"},
  "to": {"kind": "person", "principal": "alice@acme.test", "displayName": "Alice"},
  "project": {"name": "widget", "prdPath": "companies/acme/projects/widget/prd.json", "boardId": "ac-proj-7"},
  "vaultPrefixes": [{"prefix": "projects/widget/", "permission": "write", "reason": "project dossier"}],
  "status": "granted"
}
JSON
}

FIX="$TMP/hqroot"
M="$TMP/manifest.json"
export MESH_STUB_LOG="$TMP/mesh.log"

# --- 1+4. existing board entry: in-place update; work-mesh invoked -----------

make_fixture "$FIX"
write_manifest "$M" transfer
: > "$MESH_STUB_LOG"
HQ_ROOT="$FIX" bash "$HELPER" --manifest "$M" >/dev/null 2>&1 \
  || fail "transfer exited non-zero"

BOARD="$FIX/companies/acme/board.json"
jq -e '(.projects | length) == 2' "$BOARD" >/dev/null \
  || fail "board array length must be unchanged: $(jq '.projects | length' "$BOARD")"
jq -e '.projects[] | select(.prd_path == "companies/acme/projects/widget/prd.json") | .owner == "alice@acme.test" and .updated_at != "2026-01-01T00:00:00Z"' \
  "$BOARD" >/dev/null || fail "board entry must gain owner + bumped updated_at"

PRD="$FIX/companies/acme/projects/widget/prd.json"
jq -e '.metadata.owner == "alice@acme.test" and .metadata.delegatedFrom == "owner@acme.test" and .metadata.delegatedAt != null' \
  "$PRD" >/dev/null || fail "prd metadata must record owner/delegatedFrom/delegatedAt"

grep -q '^done --company acme --project widget' "$MESH_STUB_LOG" \
  || fail "work-mesh must be invoked with done for the company/project: $(cat "$MESH_STUB_LOG")"
grep -q 'alice@acme.test' "$MESH_STUB_LOG" \
  || fail "work-mesh summary must name the recipient"

JOURNAL="$FIX/companies/acme/projects/widget/journal/delegations.md"
[ -f "$JOURNAL" ] || fail "journal delegation log must be created"
grep -q 'dlg-20260807-widget' "$JOURNAL" || fail "journal must name the delegation id"
grep -q 'Alice' "$JOURNAL" || fail "journal must name the recipient"
grep -q 'projects/widget/' "$JOURNAL" || fail "journal must record the transferred scope"

jq -e '.ownershipTransferredAt != null' "$M" >/dev/null \
  || fail "manifest must record ownershipTransferredAt"

# --- 3. idempotent second run ------------------------------------------------

HQ_ROOT="$FIX" bash "$HELPER" --manifest "$M" >/dev/null 2>&1 \
  || fail "second transfer run exited non-zero"
jq -e '(.projects | length) == 2' "$BOARD" >/dev/null \
  || fail "second run must not add a board entry"
STANZAS="$(grep -c '^## ' "$JOURNAL")"
[ "$STANZAS" -eq 1 ] || fail "second run must not duplicate the journal stanza (got $STANZAS)"

# --- 2. project absent from board -> exactly one entry created ---------------

make_fixture "$FIX"
jq 'del(.projects[1])' "$FIX/companies/acme/board.json" > "$TMP/b" && mv "$TMP/b" "$FIX/companies/acme/board.json"
write_manifest "$M" transfer
HQ_ROOT="$FIX" bash "$HELPER" --manifest "$M" >/dev/null 2>&1 \
  || fail "transfer (absent from board) exited non-zero"
COUNT="$(jq '[.projects[] | select(.prd_path == "companies/acme/projects/widget/prd.json")] | length' "$FIX/companies/acme/board.json")"
[ "$COUNT" -eq 1 ] || fail "exactly one board entry must be created, got $COUNT"
jq -e '.projects[] | select(.prd_path == "companies/acme/projects/widget/prd.json") | .owner == "alice@acme.test"' \
  "$FIX/companies/acme/board.json" >/dev/null || fail "created entry must carry the owner"

# --- 4b. work-mesh unavailable -> still succeeds -----------------------------

make_fixture "$FIX"
rm "$FIX/core/scripts/work-mesh.sh"
write_manifest "$M" transfer
HQ_ROOT="$FIX" bash "$HELPER" --manifest "$M" >/dev/null 2>&1 \
  || fail "transfer must exit 0 when work-mesh.sh is unavailable"
jq -e '.projects[] | select(.prd_path == "companies/acme/projects/widget/prd.json") | .owner == "alice@acme.test"' \
  "$FIX/companies/acme/board.json" >/dev/null \
  || fail "board mutation must land even without work-mesh"

# --- 5. share mode mutates nothing -------------------------------------------

make_fixture "$FIX"
write_manifest "$M" share
BOARD_BEFORE="$(cat "$FIX/companies/acme/board.json")"
PRD_BEFORE="$(cat "$FIX/companies/acme/projects/widget/prd.json")"
: > "$MESH_STUB_LOG"
HQ_ROOT="$FIX" bash "$HELPER" --manifest "$M" >/dev/null 2>&1 \
  || fail "share mode must exit 0"
[ "$(cat "$FIX/companies/acme/board.json")" = "$BOARD_BEFORE" ] \
  || fail "share mode must leave board.json byte-identical"
[ "$(cat "$FIX/companies/acme/projects/widget/prd.json")" = "$PRD_BEFORE" ] \
  || fail "share mode must leave prd.json byte-identical"
[ ! -s "$MESH_STUB_LOG" ] || fail "share mode must not touch the work mesh"
[ ! -d "$FIX/companies/acme/projects/widget/journal" ] \
  || fail "share mode must not write a journal stanza"

echo "hq-delegate-transfer: ok (in-place board update, single created entry, idempotent journal, offline work-mesh tolerated, share mode inert)"
