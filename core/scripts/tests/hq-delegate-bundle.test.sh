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
#   3. Missing prd.json → non-zero exit, nothing written.
#   4. Secret-shaped content in the prd → non-zero exit, no new directory
#      under workspace/delegations/.
#   5. The shared secret-pattern lib stays a superset of the runtime hook's
#      patterns (.claude/hooks/detect-secrets.sh) so the two cannot drift.
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
  echo '{"email": "[EMAIL]", "personUid": "prs_owner1"}'
  exit 0
fi
exit 0
STUB
chmod +x "$TMP/bin/hq"
export PATH="$TMP/bin:$PATH"

# --- 1+2. happy path ---------------------------------------------------------

OUT="$(HQ_ROOT="$FIX" bash "$BUILDER" build --company acme --project widget \
  --to [EMAIL] --to-name "Alice" 2>"$TMP/stderr.log")" \
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
  .from.email == "[EMAIL]" and
  .to.kind == "person" and
  .to.principal == "[EMAIL]" and
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

# --- 3. missing prd.json → non-zero, nothing written -------------------------

mkdir -p "$FIX/companies/acme/projects/empty"
if HQ_ROOT="$FIX" bash "$BUILDER" build --company acme --project empty \
  --to [EMAIL] >/dev/null 2>&1; then
  fail "builder must exit non-zero when the project has no prd.json"
fi
[ -z "$(find "$FIX/workspace/delegations" -maxdepth 1 -name '*empty*' 2>/dev/null)" ] \
  || fail "builder wrote a bundle for a project with no prd.json"

# Missing --company is a usage error.
if HQ_ROOT="$FIX" bash "$BUILDER" build --project widget --to [EMAIL] >/dev/null 2>&1; then
  fail "builder must exit non-zero when --company is missing"
fi

# --- 4. secret-shaped prd → fail closed, no bundle ---------------------------

SECRET_PROJ="$FIX/companies/acme/projects/leaky"
mkdir -p "$SECRET_PROJ"
jq '.name = "leaky" | .description = "key is AKIA" + "ABCDEFGHIJKLMNOP"' \
  "$PROJ/prd.json" > "$SECRET_PROJ/prd.json"

BEFORE_COUNT="$(find "$FIX/workspace/delegations" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')"
if HQ_ROOT="$FIX" bash "$BUILDER" build --company acme --project leaky \
  --to [EMAIL] >/dev/null 2>&1; then
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

echo "hq-delegate-bundle: ok (schema valid; prefixes folder-form + bucket-relative; fail-closed on missing prd and secret match; pattern lib superset of hook)"
