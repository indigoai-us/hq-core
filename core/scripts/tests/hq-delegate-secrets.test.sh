#!/usr/bin/env bash
# Regression: hq-delegate-secrets.sh must grant secret access BY NAME ONLY —
# no command may ever read, print, or transmit a secret value — behind its
# own explicit confirmation, with --no-secrets and no-schema paths that
# grant nothing.
#
# Guards:
#   1. Schema with 3 names + --yes -> exactly those 3 names shared with
#      --permission read; the stub's value-read commands (get/env/exec/
#      --reveal) are NEVER invoked; manifest records names only.
#   2. --no-secrets -> zero invocations, {secrets: [], secretsSkipped: true}.
#   3. Without --yes -> exit 2, zero invocations, prose lists names +
#      principal.
#   4. No .env.schema -> secrets: [], plain report, exit 0, zero grants.
#   5. A sentinel secret VALUE planted in the stub store never appears in
#      the manifest or anywhere in the bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HELPER="$ROOT/core/scripts/hq-delegate-secrets.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$HELPER" ] || fail "missing helper: $HELPER"

# --- stub hq CLI with a sentinel value that must never surface ---------------
SENTINEL="sentinel-value-Zx9Qw7-never-leaks"
INVOKE_LOG="$TMP/invocations.log"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/hq" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "\$HQ_STUB_LOG"
case "\$1 \$2" in
  "secrets share") echo "error: unknown option --company placement" >&2; exit 1 ;;
  "secrets list")
    # names only, one per line after a header; the stub vault is HQ_STUB_VAULT
    [ "\${HQ_STUB_LIST_FAILS:-0}" = 1 ] && exit 1
    echo "NAME                      UPDATED"
    tr ' ' '\n' <<< "\${HQ_STUB_VAULT:-}" | sed '/^$/d' | sed 's/$/   2026-01-01/'
    exit 0
    ;;
  "secrets --company") exit 0 ;;
  "secrets get"|"secrets env"|"secrets exec")
    echo "$SENTINEL"
    exit 0
    ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/hq"
export PATH="$TMP/bin:$PATH"
export HQ_STUB_LOG="$INVOKE_LOG"
# Names the stub vault knows (checked before any share; nothing missing here)
export HQ_STUB_VAULT="DATABASE_URL WIDGET_API_KEY STRIPE_WEBHOOK_SECRET SERVICE/API_KEY REPO_ONLY_TOKEN LANE_TOKEN"

# --- fixture: HQ root, project with .env.schema, bundle ----------------------

FIX="$TMP/hqroot"
PROJ="$FIX/companies/acme/projects/widget"
mkdir -p "$PROJ"
cat > "$PROJ/.env.schema" <<'SCHEMA'
# Widget runtime credentials
DATABASE_URL=
WIDGET_API_KEY=
STRIPE_WEBHOOK_SECRET=
SERVICE/API_KEY=
SCHEMA

BUNDLE="$FIX/workspace/delegations/dlg-test-widget"
mkdir -p "$BUNDLE"
MANIFEST="$BUNDLE/manifest.json"
write_manifest() {
  cat > "$MANIFEST" <<'JSON'
{
  "schemaVersion": 1,
  "delegationId": "dlg-test-widget",
  "company": "acme",
  "to": {"kind": "person", "principal": "alice@acme.test"},
  "project": {"name": "widget"},
  "repo": null,
  "secrets": [],
  "status": "building"
}
JSON
}
write_manifest
echo "# Delegation brief — widget" > "$BUNDLE/BRIEF.md"

# --- 3. without --yes: exit 2, prose plan, zero invocations ------------------

: > "$INVOKE_LOG"
set +e
PLAN="$(HQ_ROOT="$FIX" bash "$HELPER" --manifest "$MANIFEST" 2>/dev/null)"
RC=$?
set -e
[ "$RC" -eq 2 ] || fail "without --yes must exit 2, got $RC"
[ ! -s "$INVOKE_LOG" ] || fail "without --yes nothing may be invoked: $(cat "$INVOKE_LOG")"
printf '%s' "$PLAN" | grep >/dev/null "WIDGET_API_KEY" || fail "confirmation prose must list the names"
printf '%s' "$PLAN" | grep >/dev/null "SERVICE/API_KEY" || fail "confirmation prose must include slash-separated secret paths"
printf '%s' "$PLAN" | grep >/dev/null "alice@acme.test" || fail "confirmation prose must name the principal"
jq -e '.secrets == []' "$MANIFEST" >/dev/null || fail "declined run must not record names"

# --- 1. with --yes: names granted, values never read -------------------------

: > "$INVOKE_LOG"
HQ_ROOT="$FIX" bash "$HELPER" --manifest "$MANIFEST" --yes >/dev/null 2>&1 \
  || fail "grant run exited non-zero"

SHARE_COUNT="$(grep -c '^secrets --company acme share' "$INVOKE_LOG")"
[ "$SHARE_COUNT" -eq 4 ] || fail "expected exactly 4 share calls, got $SHARE_COUNT: $(cat "$INVOKE_LOG")"
for name in DATABASE_URL WIDGET_API_KEY STRIPE_WEBHOOK_SECRET SERVICE/API_KEY; do
  grep -q "^secrets --company acme share $name --with alice@acme.test --permission read$" "$INVOKE_LOG" \
    || fail "missing read share for $name"
done

# value-read commands must never run
if grep -Eq '^secrets (get|env|exec)|--reveal' "$INVOKE_LOG"; then
  fail "a value-reading command was invoked: $(cat "$INVOKE_LOG")"
fi

jq -e '.secrets == ["DATABASE_URL","SERVICE/API_KEY","STRIPE_WEBHOOK_SECRET","WIDGET_API_KEY"] and .secretsSkipped == false and .secretsGrantedAt != null' \
  "$MANIFEST" >/dev/null || fail "manifest must record exactly the granted names: $(jq -c '.secrets' "$MANIFEST")"

# --- 5. the sentinel value appears nowhere in the bundle ---------------------

if grep -r "$SENTINEL" "$BUNDLE" >/dev/null 2>&1; then
  fail "a secret VALUE leaked into the bundle"
fi

# --- 2. --no-secrets: zero invocations, skipped recorded ---------------------

write_manifest
: > "$INVOKE_LOG"
HQ_ROOT="$FIX" bash "$HELPER" --manifest "$MANIFEST" --no-secrets >/dev/null 2>&1 \
  || fail "--no-secrets run exited non-zero"
[ ! -s "$INVOKE_LOG" ] || fail "--no-secrets must invoke nothing"
jq -e '.secrets == [] and .secretsSkipped == true' "$MANIFEST" >/dev/null \
  || fail "--no-secrets must record secrets: [] with skipped: true"

# --- 4. no .env.schema: plain report, zero grants, exit 0 --------------------

write_manifest
rm "$PROJ/.env.schema"
: > "$INVOKE_LOG"
OUT="$(HQ_ROOT="$FIX" bash "$HELPER" --manifest "$MANIFEST" --yes 2>&1)" \
  || fail "no-schema run must exit 0"
[ ! -s "$INVOKE_LOG" ] || fail "no-schema run must grant nothing"
printf '%s' "$OUT" | grep >/dev/null -i "no .env.schema" || fail "no-schema run must say so plainly: $OUT"
jq -e '.secrets == [] and .secretsSkipped == false' "$MANIFEST" >/dev/null \
  || fail "no-schema run must record empty secrets without the skipped flag"

# --- 6. agent recipient: shares go to the grant step's delegation group ------

cat > "$PROJ/.env.schema" <<'SCHEMA'
WIDGET_API_KEY=
SCHEMA
write_agent_manifest() { # grantPrincipal-json
  jq --argjson gp "$1" '.to = {"kind":"agent","principal":"agt_3AW3X306DC808FHSHNHY96VT6A"} | if $gp == null then del(.grantPrincipal) else .grantPrincipal = $gp end' \
    > "$MANIFEST.tmp" <<'JSON'
{"schemaVersion":1,"delegationId":"dlg-test-widget","company":"acme","to":{},"project":{"name":"widget"},"repo":null,"secrets":[],"status":"granted"}
JSON
  mv "$MANIFEST.tmp" "$MANIFEST"
}
write_agent_manifest '"grp_dlg0123456789abcdef0123456789abcdef"'
: > "$INVOKE_LOG"
HQ_ROOT="$FIX" bash "$HELPER" --manifest "$MANIFEST" --yes >/dev/null 2>&1 \
  || fail "agent recipient with a recorded delegation group must succeed"
grep -q "^secrets --company acme share WIDGET_API_KEY --with grp_dlg0123456789abcdef0123456789abcdef --permission read$" "$INVOKE_LOG" \
  || fail "agent secrets must be shared with the delegation group: $(cat "$INVOKE_LOG")"
if grep -q -- "--with agt_" "$INVOKE_LOG"; then fail "agt_ id must never be passed to hq secrets share"; fi

# --- 7. agent recipient before the grant step: refuse, share nothing ---------

write_agent_manifest null
: > "$INVOKE_LOG"
set +e
OUT="$(HQ_ROOT="$FIX" bash "$HELPER" --manifest "$MANIFEST" --yes 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "agent recipient without grantPrincipal must fail"
[ ! -s "$INVOKE_LOG" ] || fail "agent recipient without grantPrincipal must share nothing: $(cat "$INVOKE_LOG")"
printf '%s' "$OUT" | grep "hq-delegate-grant.sh" >/dev/null || fail "failure must point at the grant step: $OUT"
jq -e '.secrets == []' "$MANIFEST" >/dev/null || fail "refused run must not record names"

# --- 8. person uid: shares go to the email the grant step mapped -------------

jq '.to = {"kind":"person","principal":"prs_01ABC"} | .grantPrincipal = "bob@acme.test"' "$MANIFEST" > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
: > "$INVOKE_LOG"
HQ_ROOT="$FIX" bash "$HELPER" --manifest "$MANIFEST" --yes >/dev/null 2>&1 \
  || fail "person uid with a recorded email must succeed"
grep -q "^secrets --company acme share WIDGET_API_KEY --with bob@acme.test --permission read$" "$INVOKE_LOG" \
  || fail "person-uid secrets must be shared with the mapped email: $(cat "$INVOKE_LOG")"

# --- 9. source precedence: project schema > prd.json metadata.secrets > repo --

REPO_DIR="$FIX/repos/private/widget-repo"
mkdir -p "$REPO_DIR"
printf 'REPO_ONLY_TOKEN=\nWIDGET_API_KEY=\nSERVICE/API_KEY=\n' > "$REPO_DIR/.env.schema"
write_repo_manifest() {
  write_manifest
  jq '.repo = {"path":"repos/private/widget-repo"}' "$MANIFEST" > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
}

# 9a. no project declaration -> repo schema, and the plan says so
rm -f "$PROJ/.env.schema" "$PROJ/prd.json"
write_repo_manifest
: > "$INVOKE_LOG"
set +e
PLAN="$(HQ_ROOT="$FIX" bash "$HELPER" --manifest "$MANIFEST" 2>/dev/null)"
RC=$?
set -e
[ "$RC" -eq 2 ] || fail "repo-schema plan must exit 2, got $RC"
printf '%s' "$PLAN" | grep >/dev/null "Source: repo .env.schema" || fail "plan must name the repo schema as the source: $PLAN"
printf '%s' "$PLAN" | grep >/dev/null "REPO_ONLY_TOKEN" || fail "plan must list the repo schema's names"
printf '%s' "$PLAN" | grep >/dev/null -i "project declares no secrets" || fail "plan must say the repo-wide schema is a fallback: $PLAN"

# 9b. prd.json metadata.secrets beats the repo schema (strings and {name} objects)
cat > "$PROJ/prd.json" <<'JSON'
{"metadata":{"secrets":["LANE_TOKEN",{"name":"WIDGET_API_KEY","purpose":"ads read"}]}}
JSON
write_repo_manifest
: > "$INVOKE_LOG"
PLAN="$(HQ_ROOT="$FIX" bash "$HELPER" --manifest "$MANIFEST" --yes 2>&1)" || fail "prd.json-sourced grant failed: $PLAN"
printf '%s' "$PLAN" | grep >/dev/null "Source: prd.json metadata.secrets" || fail "plan must name prd.json as the source: $PLAN"
SHARE_COUNT="$(grep -c '^secrets --company acme share' "$INVOKE_LOG")"
[ "$SHARE_COUNT" -eq 2 ] || fail "prd.json source must share exactly its 2 names, got $SHARE_COUNT: $(cat "$INVOKE_LOG")"
grep -q "share REPO_ONLY_TOKEN" "$INVOKE_LOG" && fail "repo-only name must not be shared when prd.json declares the lane's secrets"
jq -e '.secrets == ["LANE_TOKEN","WIDGET_API_KEY"]' "$MANIFEST" >/dev/null || fail "manifest must record the prd.json names: $(jq -c .secrets "$MANIFEST")"

# 9c. a project .env.schema beats prd.json
printf 'LANE_TOKEN=\n' > "$PROJ/.env.schema"
write_repo_manifest
: > "$INVOKE_LOG"
HQ_ROOT="$FIX" bash "$HELPER" --manifest "$MANIFEST" --yes >/dev/null 2>&1 || fail "project-schema grant failed"
[ "$(grep -c '^secrets --company acme share' "$INVOKE_LOG")" -eq 1 ] || fail "project schema must win: $(cat "$INVOKE_LOG")"
grep -q "share LANE_TOKEN --with" "$INVOKE_LOG" || fail "project schema name must be shared"

# 9d. an empty prd.json metadata.secrets does not shadow the repo schema
rm -f "$PROJ/.env.schema"
echo '{"metadata":{"secrets":[]}}' > "$PROJ/prd.json"
write_repo_manifest
: > "$INVOKE_LOG"
HQ_ROOT="$FIX" bash "$HELPER" --manifest "$MANIFEST" --yes >/dev/null 2>&1 || fail "empty prd.json secrets must fall through to the repo schema"
grep -q "share REPO_ONLY_TOKEN --with" "$INVOKE_LOG" || fail "empty metadata.secrets must fall through to the repo schema: $(cat "$INVOKE_LOG")"
rm -f "$PROJ/prd.json"

# --- 10. a missing name aborts before any share -----------------------------

printf 'WIDGET_API_KEY=\nNOT_IN_VAULT_URL=\n' > "$PROJ/.env.schema"
write_manifest
: > "$INVOKE_LOG"
set +e
OUT="$(HQ_ROOT="$FIX" bash "$HELPER" --manifest "$MANIFEST" --yes 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "a name missing from the vault must fail"
if grep -q '^secrets --company acme share' "$INVOKE_LOG"; then
  fail "no share may run when any name is missing: $(cat "$INVOKE_LOG")"
fi
grep -q '^secrets list --company acme' "$INVOKE_LOG" || fail "names must be checked with hq secrets list: $(cat "$INVOKE_LOG")"
printf '%s' "$OUT" | grep >/dev/null "NOT_IN_VAULT_URL" || fail "failure must name the missing secret: $OUT"
printf '%s' "$OUT" | grep >/dev/null "nothing granted" || fail "failure must say nothing was granted: $OUT"
jq -e '.secrets == []' "$MANIFEST" >/dev/null || fail "aborted run must not record names"

# 10b. the list itself failing aborts with nothing shared
printf 'WIDGET_API_KEY=\n' > "$PROJ/.env.schema"
write_manifest
: > "$INVOKE_LOG"
set +e
OUT="$(HQ_STUB_LIST_FAILS=1 HQ_ROOT="$FIX" bash "$HELPER" --manifest "$MANIFEST" --yes 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "an unlistable vault must fail closed"
if grep -q '^secrets --company acme share' "$INVOKE_LOG"; then
  fail "no share may run when the vault cannot be listed: $(cat "$INVOKE_LOG")"
fi

echo "hq-delegate-secrets: ok (names only, own confirm gate, --no-secrets and no-schema paths, source precedence, pre-share existence check, sentinel value never surfaced)"
