#!/usr/bin/env bash
# Regression: hq-delegate-verify.sh must prove every granted prefix is
# reachable before any DM, resume without re-granting, and offer a
# zero-mutation dry run of the whole delegation plan.
#
# Guards:
#   1. One prefix's browse fails -> exit non-zero, that prefix named with a
#      likely cause, status stays 'granted', and no dm was ever invoked.
#   2. All prefixes reachable -> status becomes 'verified' (send gates on
#      this) with verifiedAt stamped.
#   3. Re-run after a failed probe issues no `files share` (no re-grant).
#   4. Empty-but-reachable prefix is a failure (dossier never pushed).
#   5. --dry-run: prints recipient, mode, prefixes+permissions, secret
#      names, repo+branch, and the DM headline; invokes no mutating
#      command; leaves workspace/delegations/ untouched; exits 0.
#   6. Probe from status 'building' refuses (grants must exist first).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HELPER="$ROOT/core/scripts/hq-delegate-verify.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$HELPER" ] || fail "missing helper: $HELPER"

# --- stub hq CLI -------------------------------------------------------------
# HQ_STUB_BROWSE_FAIL: prefix whose browse errors
# HQ_STUB_BROWSE_EMPTY: prefix whose browse succeeds with empty output
INVOKE_LOG="$TMP/invocations.log"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/hq" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$HQ_STUB_LOG"
case "$1 $2" in
  "files browse")
    if [ "$3" = "${HQ_STUB_BROWSE_FAIL:-}" ]; then
      echo "403 Forbidden" >&2
      exit 1
    fi
    if [ "$3" = "${HQ_STUB_BROWSE_EMPTY:-}" ]; then
      exit 0
    fi
    echo "prd.json  1.2KB  shared-with-you"
    # the referenced knowledge file is present unless the scenario hides it
    if [ "${HQ_STUB_BROWSE_NO_FILE:-0}" != "1" ]; then
      echo "notes.md  0.4KB  shared-with-you"
    fi
    exit 0
    ;;
  "whoami "*|"whoami ")
    echo '{"email":"owner@acme.test"}'
    exit 0
    ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/hq"
export PATH="$TMP/bin:$PATH"
export HQ_STUB_LOG="$INVOKE_LOG"

# --- fixture -----------------------------------------------------------------

FIX="$TMP/hqroot"
PROJ="$FIX/companies/acme/projects/widget"
mkdir -p "$PROJ" "$FIX/workspace/delegations"
cat > "$PROJ/prd.json" <<'JSON'
{
  "name": "widget", "description": "Build the widget.", "branchName": "feature/widget",
  "metadata": {"goal": "ship", "repoPath": "repos/public/widget-repo", "baseBranch": "main",
    "knowledge": ["companies/acme/knowledge/insights/notes.md"]},
  "userStories": [{"id": "US-001", "title": "Frame", "description": "d", "priority": 1, "passes": false}]
}
JSON
cat > "$PROJ/.env.schema" <<'SCHEMA'
WIDGET_API_KEY=
SCHEMA

M="$TMP/manifest.json"
write_manifest() { # status
  cat > "$M" <<JSON
{
  "schemaVersion": 1, "delegationId": "dlg-test-widget", "mode": "transfer",
  "company": "acme",
  "to": {"kind": "person", "principal": "alice@acme.test"},
  "project": {"name": "widget", "prdPath": "companies/acme/projects/widget/prd.json"},
  "vaultPrefixes": [
    {"prefix": "projects/widget/", "permission": "write"},
    {"prefix": "knowledge/insights/", "permission": "read"}
  ],
  "knowledge": ["companies/acme/knowledge/insights/notes.md"],
  "policies": [],
  "status": "$1"
}
JSON
}

# --- 1+3. failing browse: named prefix, no dm, no re-grant, status kept ------

write_manifest granted
: > "$INVOKE_LOG"
export HQ_STUB_BROWSE_FAIL="knowledge/insights/"
set +e
OUT="$(HQ_ROOT="$FIX" bash "$HELPER" --manifest "$M" 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "failed probe must exit non-zero"
printf '%s' "$OUT" | grep -q "FAIL  knowledge/insights/" || fail "output must name the failing prefix: $OUT"
printf '%s' "$OUT" | grep -qi "likely cause" || fail "output must state a likely cause"
jq -e '.status == "granted"' "$M" >/dev/null || fail "failed probe must leave status at granted"
if grep -Eq '^(dm|files share|sync push)' "$INVOKE_LOG"; then
  fail "probe must never send a dm, share, or push: $(cat "$INVOKE_LOG")"
fi

# re-run (still failing): still no share/dm — resume never re-grants
set +e
HQ_ROOT="$FIX" bash "$HELPER" --manifest "$M" >/dev/null 2>&1
set -e
if grep -Eq '^(dm|files share)' "$INVOKE_LOG"; then
  fail "re-run must not issue shares or dms"
fi
unset HQ_STUB_BROWSE_FAIL

# --- 4. reachable-but-empty prefix fails -------------------------------------

write_manifest granted
export HQ_STUB_BROWSE_EMPTY="projects/widget/"
set +e
OUT="$(HQ_ROOT="$FIX" bash "$HELPER" --manifest "$M" 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "empty prefix must fail the probe"
printf '%s' "$OUT" | grep -q "EMPTY" || fail "empty prefix failure must say so: $OUT"
unset HQ_STUB_BROWSE_EMPTY

# --- 2. all reachable -> verified --------------------------------------------

write_manifest granted
: > "$INVOKE_LOG"
HQ_ROOT="$FIX" bash "$HELPER" --manifest "$M" >/dev/null 2>&1 \
  || fail "healthy probe exited non-zero"
jq -e '.status == "verified" and .verifiedAt != null' "$M" >/dev/null \
  || fail "healthy probe must advance status to verified"
BROWSE_COUNT="$(grep -c '^files browse' "$INVOKE_LOG")"
[ "$BROWSE_COUNT" -eq 3 ] || fail "expected one browse per prefix (2) + one per referenced file (1), got $BROWSE_COUNT"

# --- referenced file absent from a reachable prefix -> FAIL naming the file --
# (Live finding: Deacon's pickup pulled a reachable knowledge prefix that
# silently lacked the specific referenced note.)

write_manifest granted
export HQ_STUB_BROWSE_NO_FILE=1
set +e
OUT="$(HQ_ROOT="$FIX" bash "$HELPER" --manifest "$M" 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "missing referenced file must fail the probe"
printf '%s' "$OUT" | grep -q "FAIL  knowledge/insights/notes.md" \
  || fail "failure must name the missing referenced file: $OUT"
jq -e '.status == "granted"' "$M" >/dev/null || fail "missing-file probe must not advance status"
unset HQ_STUB_BROWSE_NO_FILE

# --- 6. probe from 'building' refuses ----------------------------------------

write_manifest building
set +e
HQ_ROOT="$FIX" bash "$HELPER" --manifest "$M" >/dev/null 2>&1
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "probe from 'building' must refuse (grants first)"

# --- 5. dry run: full plan, zero mutation ------------------------------------

: > "$INVOKE_LOG"
BEFORE="$(find "$FIX/workspace/delegations" -mindepth 1 | sort)"
OUT="$(HQ_ROOT="$FIX" bash "$HELPER" --dry-run --company acme --project widget --to alice@acme.test 2>/dev/null)" \
  || fail "dry run must exit 0"
AFTER="$(find "$FIX/workspace/delegations" -mindepth 1 | sort)"
[ "$BEFORE" = "$AFTER" ] || fail "dry run must leave workspace/delegations/ untouched"
if grep -Eq '^(dm|files share|sync push|secrets share)' "$INVOKE_LOG"; then
  fail "dry run invoked a mutating command: $(cat "$INVOKE_LOG")"
fi
for needle in "alice@acme.test" "transfer" "projects/widget/" "knowledge/insights/" \
  "WIDGET_API_KEY" "feature/widget" "DM that would be sent"; do
  printf '%s' "$OUT" | grep -qF "$needle" || fail "dry-run plan missing: $needle"
done
printf '%s' "$OUT" | grep -q "write" || fail "dry-run plan must show permissions"

echo "hq-delegate-verify: ok (probe gates the DM, named failures with causes, resume without re-grant, empty=fail, dry run fully inert)"
