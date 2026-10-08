#!/usr/bin/env bash
# Regression: a brainstorm-stage project (brainstorm.md, research/, journal/,
# no prd.json yet) must be delegatable end to end. Policy
# hq-brainstorm-leaves-handoffable-project-folder says such a folder is
# handoff-able; before this change every helper after the bundle step still
# assumed prd.json.
#
# Guards (the bundle-level cases live in hq-delegate-bundle.test.sh):
#   1. transfer: a board entry with status "exploring" and brainstorm_path is
#      matched by brainstorm_path, gains owner + bumped updated_at, keeps its
#      status, and no prd.json is created; ownership lands in the brainstorm.md
#      frontmatter (owner, delegated_from, delegated_at); a second run is
#      idempotent (one frontmatter owner line, one journal stanza).
#   2. transfer: absent from the board -> exactly one "exploring" entry with
#      brainstorm_path and a null prd_path.
#   3. publish: snapshots the manifest dossier (brainstorm.md, research/**,
#      newest journal note) plus the delegation journal, brief and manifest;
#      a frontmatter owner that does not match the recipient is refused; a
#      dossier file missing on disk is refused.
#   4. send (prompt generation): the pickup prompt says brainstorm stage, no
#      PRD yet, and names /plan <slug> as the next step; it never prints a
#      "0 of 0 stories" state line.
#   5. verify --dry-run: the plan names the brainstorm stage, /plan, and the
#      dossier files, and still writes nothing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TRANSFER="$ROOT/core/scripts/hq-delegate-transfer.sh"
PUBLISH="$ROOT/core/scripts/hq-delegate-publish.sh"
SEND="$ROOT/core/scripts/hq-delegate-send.sh"
VERIFY="$ROOT/core/scripts/hq-delegate-verify.sh"
TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

for h in "$TRANSFER" "$PUBLISH" "$SEND" "$VERIFY"; do
  [ -f "$h" ] || fail "missing helper: $h"
done

FIX="$TMP/hqroot"
CLOUD="$TMP/cloud"
REL="companies/acme/projects/spark"
PROJ="$FIX/$REL"
BUNDLE="$FIX/workspace/delegations/dlg-20260807-spark"
M="$BUNDLE/manifest.json"
export MESH_STUB_LOG="$TMP/mesh.log"
export HQ_TEST_CLOUD="$CLOUD"

make_fixture() {
  rm -rf "$FIX" "$CLOUD"
  mkdir -p "$PROJ/research" "$PROJ/journal" "$BUNDLE" "$FIX/bin" "$CLOUD"
  cat > "$PROJ/brainstorm.md" <<'MD'
---
company: acme
created_at: 2026-08-01T00:00:00Z
status: exploring
promoted_to: null
---

# Spark

> Light a spark in the widget line.

## Context

Why this exists.

## What We Don't Know

- Whether sparks need a permit.

## Recommendation

Option A, the small spark first.

## Next Steps

- Promote with /plan.
MD
  echo "landscape note" > "$PROJ/research/landscape.md"
  echo "older" > "$PROJ/journal/2026-08-01-0900-brainstorm-adhoc.md"
  echo "newest" > "$PROJ/journal/2026-08-02-0900-brainstorm-adhoc.md"
  cat > "$FIX/companies/acme/board.json" <<'JSON'
{"projects": [
  {"id": "ac-proj-1", "title": "other", "status": "prd_created", "prd_path": "companies/acme/projects/other/prd.json", "updated_at": "2026-01-01T00:00:00Z"},
  {"id": "ac-proj-9", "title": "Spark", "status": "exploring", "prd_path": null, "brainstorm_path": "companies/acme/projects/spark/brainstorm.md", "updated_at": "2026-01-01T00:00:00Z"}
]}
JSON
  echo '# Brief' > "$BUNDLE/BRIEF.md"
  # hq stub: whoami for the bundle/dry-run path, mesh note for transfer,
  # sync push + files cat for publish (mirrors the project into $HQ_TEST_CLOUD).
  cat > "$FIX/bin/hq" <<'HQ'
#!/usr/bin/env bash
echo "$*" >> "${MESH_STUB_LOG:-/dev/null}"
case "${1:-} ${2:-}" in
  'whoami '*) echo '{"email": "owner@acme.test", "personUid": "prs_owner1"}'; exit 0 ;;
  'sync push')
    rel="${3%/}"
    mkdir -p "$HQ_TEST_CLOUD/$(dirname "$rel")"
    rm -rf "$HQ_TEST_CLOUD/$rel"
    cp -R "$HQ_ROOT/$rel" "$HQ_TEST_CLOUD/$rel"
    exit 0 ;;
  'files cat') cat "$HQ_TEST_CLOUD/companies/acme/$3"; exit 0 ;;
esac
exit 0
HQ
  chmod +x "$FIX/bin/hq"
}

write_manifest() { # status
  cat > "$M" <<JSON
{
  "schemaVersion": 1,
  "delegationId": "dlg-20260807-spark",
  "createdAt": "2026-08-07T00:00:00Z",
  "mode": "transfer",
  "company": "acme",
  "from": {"email": "owner@acme.test", "personUid": "prs_owner1"},
  "to": {"kind": "person", "principal": "alice@acme.test", "displayName": "Alice"},
  "project": {
    "name": "spark",
    "stage": "brainstorm",
    "prdPath": null,
    "sourcePath": "$REL/brainstorm.md",
    "boardId": "ac-proj-9",
    "dossier": ["$REL/brainstorm.md", "$REL/research/landscape.md", "$REL/journal/2026-08-02-0900-brainstorm-adhoc.md"]
  },
  "vaultPrefixes": [{"prefix": "projects/spark/", "permission": "write", "reason": "project dossier"}],
  "repo": null,
  "secrets": [],
  "knowledge": [],
  "policies": [],
  "checksums": {},
  "status": "$1"
}
JSON
}

run_transfer() {
  PATH="$FIX/bin:$PATH" HQ_ROOT="$FIX" bash "$TRANSFER" --manifest "$M" >"$TMP/transfer.out" 2>"$TMP/transfer.err"
}

frontmatter_get() { # key
  awk -v key="$1" 'NR==1{next} /^---/{exit} { split($0, kv, ":"); if (kv[1]==key) { sub("^[^:]*:[[:space:]]*", "", $0); print; exit } }' "$PROJ/brainstorm.md"
}

# --- 1. transfer: exploring board entry matched by brainstorm_path -----------

make_fixture
write_manifest granted
: > "$MESH_STUB_LOG"
run_transfer || fail "transfer exited non-zero on a brainstorm-stage project: $(cat "$TMP/transfer.err")"
grep -q 'brainstorm stage' "$TMP/transfer.out" || fail "transfer must report the brainstorm stage"

BOARD="$FIX/companies/acme/board.json"
jq -e '(.projects | length) == 2' "$BOARD" >/dev/null || fail "board array length must be unchanged"
jq -e '.projects[] | select(.id == "ac-proj-9") | .owner == "alice@acme.test" and .status == "exploring" and .prd_path == null and .updated_at != "2026-01-01T00:00:00Z"' \
  "$BOARD" >/dev/null || fail "exploring entry must gain owner + bumped updated_at and keep status/prd_path: $(jq '.projects[1]' "$BOARD")"
[ ! -f "$PROJ/prd.json" ] || fail "transfer must not create a prd.json for a brainstorm-stage project"

[ "$(frontmatter_get owner)" = "alice@acme.test" ] || fail "brainstorm.md frontmatter must record owner: $(head -8 "$PROJ/brainstorm.md")"
[ "$(frontmatter_get delegated_from)" = "owner@acme.test" ] || fail "brainstorm.md frontmatter must record delegated_from"
[ -n "$(frontmatter_get delegated_at)" ] || fail "brainstorm.md frontmatter must record delegated_at"
[ "$(frontmatter_get status)" = "exploring" ] || fail "frontmatter status must survive the ownership write"
grep -q '^# Spark$' "$PROJ/brainstorm.md" || fail "brainstorm.md body must be intact after the frontmatter write"

grep -q 'mesh session note' "$MESH_STUB_LOG" || fail "mesh note must be invoked"
JOURNAL="$PROJ/journal/delegations.md"
[ -f "$JOURNAL" ] || fail "delegation journal must be created"
grep -q 'Brainstorm-stage project' "$JOURNAL" || fail "journal stanza must say the project is brainstorm-stage"
jq -e '.ownershipTransferredAt != null' "$M" >/dev/null || fail "manifest must record ownershipTransferredAt"

# idempotent second run
run_transfer || fail "second transfer run exited non-zero"
jq -e '(.projects | length) == 2' "$BOARD" >/dev/null || fail "second run must not add a board entry"
[ "$(grep -c '^owner:' "$PROJ/brainstorm.md")" -eq 1 ] || fail "second run must not duplicate the frontmatter owner line"
[ "$(grep -c '^## ' "$JOURNAL")" -eq 1 ] || fail "second run must not duplicate the journal stanza"

# --- 2. transfer: absent from the board -> one exploring entry ---------------

make_fixture
jq 'del(.projects[1])' "$BOARD" > "$TMP/b" && mv "$TMP/b" "$BOARD"
write_manifest granted
run_transfer || fail "transfer (absent from board) exited non-zero: $(cat "$TMP/transfer.err")"
COUNT="$(jq --arg bs "$REL/brainstorm.md" '[.projects[] | select(.brainstorm_path == $bs)] | length' "$BOARD")"
[ "$COUNT" -eq 1 ] || fail "exactly one board entry must be created, got $COUNT"
jq -e --arg bs "$REL/brainstorm.md" '.projects[] | select(.brainstorm_path == $bs) | .status == "exploring" and .prd_path == null and .owner == "alice@acme.test" and .title == "Spark"' \
  "$BOARD" >/dev/null || fail "created entry must be exploring with brainstorm_path, null prd_path, owner, and the H1 title: $(jq '.projects[-1]' "$BOARD")"

# --- 3. publish: dossier snapshot, owner gate, missing-file gate -------------

make_fixture
write_manifest granted
run_transfer || fail "transfer before publish failed: $(cat "$TMP/transfer.err")"
PATH="$FIX/bin:$PATH" HQ_ROOT="$FIX" bash "$PUBLISH" --manifest "$M" >"$TMP/publish.out" 2>"$TMP/publish.err" \
  || fail "publish exited non-zero on a brainstorm-stage project: $(cat "$TMP/publish.err")"
for key in "$REL/brainstorm.md" "$REL/research/landscape.md" "$REL/journal/2026-08-02-0900-brainstorm-adhoc.md" \
  "$REL/journal/delegations.md" "$REL/delegation/dlg-20260807-spark/BRIEF.md" "$REL/delegation/dlg-20260807-spark/manifest.json"; do
  jq -e --arg k "$key" '.publication.files[$k] != null' "$M" >/dev/null \
    || fail "publication receipt must cover $key: $(jq '.publication.files' "$M")"
done
jq -e '.publication.files | has("companies/acme/projects/spark/prd.json") | not' "$M" >/dev/null \
  || fail "publication must not claim a prd.json for a brainstorm-stage project"
jq -e '.publication.files | has("companies/acme/projects/spark/journal/2026-08-01-0900-brainstorm-adhoc.md") | not' "$M" >/dev/null \
  || fail "only the newest journal note is part of the dossier"
[ -f "$PROJ/delegation/dlg-20260807-spark/BRIEF.md" ] || fail "brief must be published into the project"

# owner mismatch in the frontmatter is refused
make_fixture
write_manifest granted
run_transfer
sed -i.bak 's/^owner: .*/owner: someone-else@acme.test/' "$PROJ/brainstorm.md" && rm -f "$PROJ/brainstorm.md.bak"
if PATH="$FIX/bin:$PATH" HQ_ROOT="$FIX" bash "$PUBLISH" --manifest "$M" >/dev/null 2>&1; then
  fail "publish must refuse when the brainstorm.md owner does not match the recipient"
fi
jq -e '.publication == null' "$M" >/dev/null || fail "refused publish must not leave a receipt"

# a promised dossier file missing on disk is refused
make_fixture
write_manifest granted
run_transfer
rm "$PROJ/research/landscape.md"
if PATH="$FIX/bin:$PATH" HQ_ROOT="$FIX" bash "$PUBLISH" --manifest "$M" >/dev/null 2>"$TMP/publish.err"; then
  fail "publish must refuse when a dossier file is missing"
fi
grep -q 'dossier file missing' "$TMP/publish.err" || fail "missing-dossier refusal must name the cause: $(cat "$TMP/publish.err")"

# --- 4. send: pickup prompt for a brainstorm-stage project -------------------

make_fixture
write_manifest verified
PATH="$FIX/bin:$PATH" HQ_ROOT="$FIX" bash "$SEND" --manifest "$M" >/dev/null 2>"$TMP/send.err" \
  || fail "prompt generation exited non-zero: $(cat "$TMP/send.err")"
PROMPT="$BUNDLE/PICKUP-PROMPT.md"
[ -f "$PROMPT" ] || fail "pickup prompt not written"
grep -q 'brainstorm stage' "$PROMPT" || fail "pickup prompt must say the project is at the brainstorm stage"
grep -q 'no PRD yet' "$PROMPT" || fail "pickup prompt must say there is no PRD yet"
grep -q '/plan spark' "$PROMPT" || fail "pickup prompt must name /plan <slug> as the next step"
grep -q 'Light a spark' "$PROMPT" || fail "pickup prompt goal must come from brainstorm.md"
! grep -q '0 of 0 stories' "$PROMPT" || fail "pickup prompt must not print a PRD story count for a brainstorm"
grep -q 'hq files get projects/spark/ --company acme' "$PROMPT" || fail "pickup prompt must keep the on-demand pull line"
! grep -Eq 'share-session/' "$PROMPT" || fail "pickup prompt must never carry a share-session URL"

# --- 5. verify --dry-run names the stage and writes nothing ------------------

make_fixture
rm -rf "$FIX/workspace/delegations"
OUT="$(PATH="$FIX/bin:$PATH" HQ_ROOT="$FIX" bash "$VERIFY" --dry-run --company acme --project spark --to alice@acme.test 2>"$TMP/dry.err")" \
  || fail "dry run exited non-zero: $(cat "$TMP/dry.err")"
grep -q 'Stage:      brainstorm' <<<"$OUT" || fail "dry-run plan must name the brainstorm stage: $OUT"
grep -q '/plan spark' <<<"$OUT" || fail "dry-run plan must recommend /plan <slug>"
grep -q "$REL/research/landscape.md" <<<"$OUT" || fail "dry-run plan must list the dossier files"
grep -q "write	on projects/spark/" <<<"$OUT" || fail "dry-run plan must keep the dossier write grant"
[ ! -d "$FIX/workspace/delegations" ] || fail "dry run must create nothing under workspace/delegations/"

echo "hq-delegate-brainstorm: ok (transfer keeps exploring + writes frontmatter owner, creates one exploring entry, publish ships dossier + gates owner/missing files, pickup prompt says brainstorm/no PRD//plan, dry run names the stage)"
