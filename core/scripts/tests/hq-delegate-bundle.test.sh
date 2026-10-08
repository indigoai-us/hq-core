#!/usr/bin/env bash
# Regression: hq-delegate-bundle.sh must freeze a project into a valid v1
# delegation bundle, fail closed on missing inputs, and fail closed (writing
# nothing) when its own output matches a secret-detection pattern.
#
# Guards:
#   1. A fixture project with a prd.json builds a manifest that validates
#      against the documented v1 schema, plus a non-empty prose BRIEF.md, and
#      the delegationId is printed on stdout.
#   2. Vault prefixes are bucket-relative folder form: every prefix ends in
#      "/" and none starts with "companies/".
#   3. Neither prd.json nor brainstorm.md → non-zero exit naming both files,
#      nothing written.
#   4. Secret-shaped content in the prd → non-zero exit, no new directory
#      under workspace/delegations/.
#   5. The shared secret-pattern lib stays a superset of the runtime hook's
#      patterns (.claude/hooks/detect-secrets.sh) so the two cannot drift.
#   6. A brainstorm-stage project (brainstorm.md + research/ + journal/, no
#      prd.json) builds: stage "brainstorm", prdPath null, sourcePath =
#      brainstorm.md, board id matched by brainstorm_path, dossier =
#      brainstorm.md + research/** + newest journal note, repo null, no
#      knowledge grants, and a brief that says brainstorm stage / no PRD yet /
#      next step /plan. Secret-shaped brainstorm content still fails closed.
#   7. The PRD path is unchanged: stage "prd", prdPath set, and no dossier
#      list (the publish step keeps its PRD file set).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
BUILDER="$ROOT/core/scripts/hq-delegate-bundle.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$BUILDER" ] || fail "missing builder: $BUILDER"

# --- fixture HQ root ---------------------------------------------------------

FIX="$TMP/hqroot"
PROJ="$FIX/companies/acme/projects/widget"
mkdir -p "$PROJ" "$FIX/workspace" "$FIX/companies/acme/knowledge/insights"
echo "insight body" > "$FIX/companies/acme/knowledge/insights/widget-notes.md"

cat > "$PROJ/prd.json" <<'JSON'
{
  "name": "widget",
  "description": "Build the widget.",
  "branchName": "feature/widget",
  "metadata": {
    "goal": "Widgets ship.",
    "repoPath": "repos/public/widget-repo",
    "baseBranch": "main",
    "knowledge": [
      "companies/acme/knowledge/insights/widget-notes.md",
      "companies/acme/policies/widget-policy.md",
      "repos/public/widget-repo/docs/widget.md"
    ],
    "openQuestions": ["Should widgets spin?"],
    "executionConventions": ["Branch from origin/main"]
  },
  "userStories": [
    {"id": "US-001", "title": "Frame", "description": "Build the frame.", "priority": 1, "passes": true},
    {"id": "US-002", "title": "Spin", "description": "Make it spin.", "priority": 1, "passes": false},
    {"id": "US-003", "title": "Paint", "description": "Paint it.", "priority": 2, "passes": false}
  ]
}
JSON

cat > "$FIX/companies/acme/board.json" <<'JSON'
{"projects": [{"id": "ac-proj-7", "prd_path": "companies/acme/projects/widget/prd.json"}]}
JSON

# Stub hq CLI so `hq whoami --json` works offline.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/hq" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "whoami" ]; then
  echo '{"email": "owner@acme.test", "personUid": "prs_owner1"}'
  exit 0
fi
exit 0
STUB
chmod +x "$TMP/bin/hq"
export PATH="$TMP/bin:$PATH"

# --- 1+2. happy path ---------------------------------------------------------

OUT="$(HQ_ROOT="$FIX" bash "$BUILDER" build --company acme --project widget \
  --to alice@acme.test --to-name "Alice" 2>"$TMP/stderr.log")" \
  || fail "builder exited non-zero on valid fixture: $(cat "$TMP/stderr.log")"

DID="$(printf '%s' "$OUT" | head -1)"
case "$DID" in dlg-*-widget) ;; *) fail "stdout is not a delegationId: '$OUT'" ;; esac

BUNDLE="$FIX/workspace/delegations/$DID"
MANIFEST="$BUNDLE/manifest.json"
BRIEF="$BUNDLE/BRIEF.md"
[ -f "$MANIFEST" ] || fail "manifest not written: $MANIFEST"
[ -f "$BRIEF" ] || fail "BRIEF not written: $BRIEF"

# Schema validation — required fields, correct values.
jq -e '
  .schemaVersion == 1 and
  .delegationId != null and
  .createdAt != null and
  .mode == "transfer" and
  .from.email == "owner@acme.test" and
  .to.kind == "person" and
  .to.principal == "alice@acme.test" and
  .to.displayName == "Alice" and
  .company == "acme" and
  .project.name == "widget" and
  .project.prdPath == "companies/acme/projects/widget/prd.json" and
  .project.boardId == "ac-proj-7" and
  (.vaultPrefixes | type) == "array" and (.vaultPrefixes | length) >= 2 and
  .repo.path == "repos/public/widget-repo" and
  .repo.branch == "feature/widget" and
  .repo.baseBranch == "main" and
  .secrets == [] and
  (.checksums | type) == "object" and (.checksums | length) >= 1 and
  .status == "building"
' "$MANIFEST" >/dev/null || fail "manifest does not validate against the v1 schema: $(cat "$MANIFEST")"

# Write on the project dossier, read on referenced knowledge.
jq -e '.vaultPrefixes[] | select(.prefix == "projects/widget/" and .permission == "write")' \
  "$MANIFEST" >/dev/null || fail "missing write grant on projects/widget/"
jq -e '.vaultPrefixes[] | select(.prefix == "knowledge/insights/" and .permission == "read")' \
  "$MANIFEST" >/dev/null || fail "missing read grant on knowledge/insights/"
jq -e '.vaultPrefixes[] | select(.prefix == "policies/" and .permission == "read")' \
  "$MANIFEST" >/dev/null || fail "missing read grant on policies/"

# Prefix conventions: folder form, bucket-relative, no repo paths.
jq -e 'all(.vaultPrefixes[]; (.prefix | endswith("/")) and (.prefix | startswith("companies/") | not) and (.prefix | startswith("repos/") | not))' \
  "$MANIFEST" >/dev/null || fail "a vault prefix violates conventions (folder form, bucket-relative, no repos/)"

# Repo docs recorded as knowledge but never granted.
jq -e '.knowledge | index("repos/public/widget-repo/docs/widget.md")' "$MANIFEST" >/dev/null \
  || fail "repo-based doc missing from knowledge[]"
jq -e '.policies == ["companies/acme/policies/widget-policy.md"]' "$MANIFEST" >/dev/null \
  || fail "policy path not routed into policies[]"

# BRIEF is non-empty prose covering the required sections.
[ -s "$BRIEF" ] || fail "BRIEF.md is empty"
for section in "What this project is" "Where things stand" "The next three steps" "Open questions" "Known traps"; do
  grep -q "$section" "$BRIEF" || fail "BRIEF missing section: $section"
done
grep -q "US-002" "$BRIEF" || fail "BRIEF next steps must name the top incomplete story"
grep -q "1 of 3 stories" "$BRIEF" || fail "BRIEF must state where things stand (1 of 3)"

# --- 3. neither prd.json nor brainstorm.md → non-zero, nothing written -------

mkdir -p "$FIX/companies/acme/projects/empty/research"
echo "a note without a brainstorm" > "$FIX/companies/acme/projects/empty/research/note.md"
if HQ_ROOT="$FIX" bash "$BUILDER" build --company acme --project empty \
  --to alice@acme.test >/dev/null 2>"$TMP/empty.err"; then
  fail "builder must exit non-zero when the project has neither prd.json nor brainstorm.md"
fi
grep -q 'neither prd.json nor brainstorm.md' "$TMP/empty.err" \
  || fail "refusal must name both accepted sources: $(cat "$TMP/empty.err")"
[ -z "$(find "$FIX/workspace/delegations" -maxdepth 1 -name '*empty*' 2>/dev/null)" ] \
  || fail "builder wrote a bundle for a project with neither source"

# Missing --company is a usage error.
if HQ_ROOT="$FIX" bash "$BUILDER" build --project widget --to a@b.c >/dev/null 2>&1; then
  fail "builder must exit non-zero when --company is missing"
fi

# --- 4. secret-shaped prd → fail closed, no bundle ---------------------------

SECRET_PROJ="$FIX/companies/acme/projects/leaky"
mkdir -p "$SECRET_PROJ"
jq '.name = "leaky" | .description = "key is AKIA" + "ABCDEFGHIJKLMNOP"' \
  "$PROJ/prd.json" > "$SECRET_PROJ/prd.json"

BEFORE_COUNT="$(find "$FIX/workspace/delegations" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')"
if HQ_ROOT="$FIX" bash "$BUILDER" build --company acme --project leaky \
  --to alice@acme.test >/dev/null 2>&1; then
  fail "builder must fail closed when output matches a secret pattern"
fi
AFTER_COUNT="$(find "$FIX/workspace/delegations" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')"
[ "$BEFORE_COUNT" = "$AFTER_COUNT" ] \
  || fail "builder wrote a bundle despite a secret-pattern match"

# --- 5. shared pattern lib is a superset of the runtime hook -----------------

HOOK="$ROOT/.claude/hooks/detect-secrets.sh"
LIB="$ROOT/core/scripts/lib/secret-patterns.sh"
[ -f "$LIB" ] || fail "missing shared secret-pattern lib: $LIB"
if [ -f "$HOOK" ]; then
  # Extract each pattern literal from the hook's PATTERNS array and require it
  # verbatim in the lib.
  grep -oE '^  "[^"]+"' "$HOOK" | sed 's/^  //' | while IFS= read -r entry; do
    grep -qF "$entry" "$LIB" \
      || fail "secret-patterns.sh drifted: hook pattern $entry missing from lib"
  done
fi

# --- 6. brainstorm-stage project builds from brainstorm.md -------------------

BS="$FIX/companies/acme/projects/spark"
mkdir -p "$BS/research/deep" "$BS/journal"
cat > "$BS/brainstorm.md" <<'MD'
---
company: acme
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
echo "landscape" > "$BS/research/landscape.md"
echo "deeper" > "$BS/research/deep/market.md"
echo "older" > "$BS/journal/2026-08-01-0900-brainstorm-adhoc.md"
echo "newest" > "$BS/journal/2026-08-02-0900-brainstorm-adhoc.md"
jq '.projects += [{"id": "ac-proj-9", "title": "Spark", "status": "exploring", "prd_path": null, "brainstorm_path": "companies/acme/projects/spark/brainstorm.md"}]' \
  "$FIX/companies/acme/board.json" > "$TMP/board" && mv "$TMP/board" "$FIX/companies/acme/board.json"

OUT="$(HQ_ROOT="$FIX" bash "$BUILDER" build --company acme --project spark \
  --to alice@acme.test --to-name "Alice" 2>"$TMP/stderr.log")" \
  || fail "builder exited non-zero on a brainstorm-stage project: $(cat "$TMP/stderr.log")"
BDID="$(printf '%s' "$OUT" | head -1)"
case "$BDID" in dlg-*-spark) ;; *) fail "stdout is not a delegationId: '$OUT'" ;; esac
BMANIFEST="$FIX/workspace/delegations/$BDID/manifest.json"
BBRIEF="$FIX/workspace/delegations/$BDID/BRIEF.md"
[ -f "$BMANIFEST" ] || fail "brainstorm manifest not written"
[ -f "$BBRIEF" ] || fail "brainstorm BRIEF not written"

jq -e '
  .schemaVersion == 1 and
  .project.name == "spark" and
  .project.stage == "brainstorm" and
  .project.prdPath == null and
  .project.sourcePath == "companies/acme/projects/spark/brainstorm.md" and
  .project.boardId == "ac-proj-9" and
  .project.dossier == [
    "companies/acme/projects/spark/brainstorm.md",
    "companies/acme/projects/spark/research/deep/market.md",
    "companies/acme/projects/spark/research/landscape.md",
    "companies/acme/projects/spark/journal/2026-08-02-0900-brainstorm-adhoc.md"
  ] and
  .repo == null and
  .knowledge == [] and
  .policies == [] and
  .vaultPrefixes == [{"prefix": "projects/spark/", "permission": "write", "reason": "project dossier"}] and
  (.checksums | has("companies/acme/projects/spark/brainstorm.md")) and
  (.checksums | has("companies/acme/projects/spark/research/landscape.md")) and
  .status == "building"
' "$BMANIFEST" >/dev/null || fail "brainstorm manifest does not match the v1 brainstorm-stage contract: $(cat "$BMANIFEST")"

for needle in "brainstorm stage" "no PRD yet" "/plan spark" "Recommendation so far" "Option A, the small spark first." \
  "Open questions" "Whether sparks need a permit." "companies/acme/projects/spark/research/landscape.md" \
  "companies/acme/projects/spark/journal/2026-08-02-0900-brainstorm-adhoc.md" "Light a spark in the widget line."; do
  grep -qF "$needle" "$BBRIEF" || fail "brainstorm BRIEF missing: $needle"
done
! grep -q 'stories are complete' "$BBRIEF" || fail "brainstorm BRIEF must not report a story count"
! grep -q 'journal/2026-08-01-' "$BBRIEF" || fail "brainstorm BRIEF must list only the newest journal note"

# secret-shaped brainstorm content → fail closed, no bundle
LEAKY="$FIX/companies/acme/projects/leaky-spark"
mkdir -p "$LEAKY"
{ printf -- '---\nstatus: exploring\n---\n\n# Leaky\n\n> key is AKIA'; printf 'ABCDEFGHIJKLMNOP\n'; } > "$LEAKY/brainstorm.md"
BEFORE_COUNT="$(find "$FIX/workspace/delegations" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')"
if HQ_ROOT="$FIX" bash "$BUILDER" build --company acme --project leaky-spark \
  --to alice@acme.test >/dev/null 2>&1; then
  fail "builder must fail closed when brainstorm output matches a secret pattern"
fi
AFTER_COUNT="$(find "$FIX/workspace/delegations" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')"
[ "$BEFORE_COUNT" = "$AFTER_COUNT" ] || fail "builder wrote a bundle despite a secret-pattern match in brainstorm.md"

# --- 7. PRD path unchanged: stage prd, prdPath set, no dossier list ---------

jq -e '.project.stage == "prd" and .project.prdPath == "companies/acme/projects/widget/prd.json" and .project.sourcePath == .project.prdPath and (.project | has("dossier") | not)' \
  "$MANIFEST" >/dev/null || fail "PRD manifest must keep stage prd / prdPath and carry no dossier list: $(jq .project "$MANIFEST")"

echo "hq-delegate-bundle: ok (schema valid; prefixes folder-form + bucket-relative; fail-closed on neither source and secret match; brainstorm stage builds from brainstorm.md with dossier + /plan brief; prd path unchanged; pattern lib superset of hook)"
