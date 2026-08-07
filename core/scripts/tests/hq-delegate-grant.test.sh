#!/usr/bin/env bash
# Regression: hq-delegate-grant.sh must materialize the dossier, write the
# manifest's grants via DIRECT ACL grants, verify each via read-back, and
# fail closed on convention violations or unverified grants.
#
# Guards:
#   1. Happy path: one sync push + one share per prefix, expected permission
#      per prefix, every shared prefix ends in "/", manifest advances to
#      'granted' with verifiedAt stamps.
#   2. ACL read-back missing the grantee -> non-zero, status stays 'building'.
#   3. A companies/<slug>/-anchored prefix -> non-zero naming the convention,
#      nothing invoked.
#   4. Without --yes -> exit 2, plan printed, zero mutating invocations.
#   5. No share-session URL path: every share call carries --with (direct
#      grant), never the bare browser-flow form.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
GRANT="$ROOT/core/scripts/hq-delegate-grant.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$GRANT" ] || fail "missing grant helper: $GRANT"

# --- stub hq CLI -------------------------------------------------------------
INVOKE_LOG="$TMP/invocations.log"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/hq" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$HQ_STUB_LOG"
case "$1 $2" in
  "sync push") exit 0 ;;
  "groups create") exit 0 ;;
  "groups add") exit 0 ;;
  "files share") exit 0 ;;
  "files acl")
    resp="${HQ_STUB_ACL_RESPONSE:-}"
    [ -n "$resp" ] || resp="grantee: alice@acme.test  permission: MATCHPERM"
    # The stub echoes a per-permission line so grantee+permission matching is real.
    printf '%s\n' "$resp"
    exit 0
    ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/hq"
export PATH="$TMP/bin:$PATH"
export HQ_STUB_LOG="$INVOKE_LOG"

write_manifest() { # path status
  cat > "$1" <<JSON
{
  "schemaVersion": 1,
  "delegationId": "dlg-test-widget",
  "company": "acme",
  "mode": "transfer",
  "to": {"kind": "person", "principal": "alice@acme.test", "displayName": "Alice"},
  "project": {"name": "widget", "prdPath": "companies/acme/projects/widget/prd.json", "boardId": null},
  "vaultPrefixes": [
    {"prefix": "projects/widget/", "permission": "write", "reason": "project dossier"},
    {"prefix": "knowledge/insights/", "permission": "read", "reason": "referenced knowledge"},
    {"prefix": "policies/", "permission": "read", "reason": "referenced policies"}
  ],
  "secrets": [],
  "status": "$2"
}
JSON
}

# --- 4. without --yes: plan only, exit 2, zero mutations ---------------------

M="$TMP/manifest.json"
write_manifest "$M" building
: > "$INVOKE_LOG"
set +e
PLAN="$(bash "$GRANT" --manifest "$M" 2>/dev/null)"
RC=$?
set -e
[ "$RC" -eq 2 ] || fail "without --yes must exit 2, got $RC"
[ ! -s "$INVOKE_LOG" ] || fail "without --yes nothing may be invoked, got: $(cat "$INVOKE_LOG")"
printf '%s' "$PLAN" | grep -q "projects/widget/" || fail "plan must name the project prefix"
printf '%s' "$PLAN" | grep -q "alice@acme.test" || fail "plan must name the principal"
printf '%s' "$PLAN" | grep -qi "privilege escalation" || fail "plan must flag the write grant as a privilege escalation"
jq -e '.status == "building"' "$M" >/dev/null || fail "plan-only run must not advance status"

# --- 1. happy path -----------------------------------------------------------

: > "$INVOKE_LOG"
export HQ_STUB_ACL_RESPONSE="grantee: alice@acme.test permission: write
grantee: alice@acme.test permission: read"
bash "$GRANT" --manifest "$M" --yes >/dev/null 2>&1 || fail "happy path exited non-zero"

grep -q "^sync push companies/acme/projects/widget/ --company acme --on-conflict keep" "$INVOKE_LOG" \
  || fail "must push the project dir to the vault first: $(cat "$INVOKE_LOG")"

SHARE_COUNT="$(grep -c '^files share' "$INVOKE_LOG")"
[ "$SHARE_COUNT" -eq 3 ] || fail "expected exactly 3 share calls, got $SHARE_COUNT"
grep -q '^files share projects/widget/ --with alice@acme.test --permission write --company acme$' "$INVOKE_LOG" \
  || fail "missing write share on projects/widget/"
grep -q '^files share knowledge/insights/ --with alice@acme.test --permission read --company acme$' "$INVOKE_LOG" \
  || fail "missing read share on knowledge/insights/"
grep -q '^files share policies/ --with alice@acme.test --permission read --company acme$' "$INVOKE_LOG" \
  || fail "missing read share on policies/"

# 5. direct grants only — every share carries --with (no browser/share-session flow)
if grep '^files share' "$INVOKE_LOG" | grep -vq -- '--with'; then
  fail "a share call omitted --with (browser/share-session flow is forbidden here)"
fi

# every shared prefix is folder form
grep '^files share' "$INVOKE_LOG" | awk '{print $3}' | while IFS= read -r p; do
  case "$p" in
    */) ;;
    *) fail "shared prefix not folder form: $p" ;;
  esac
done

jq -e '.status == "granted"' "$M" >/dev/null || fail "manifest must advance to granted"
jq -e 'all(.vaultPrefixes[]; .verifiedAt != null)' "$M" >/dev/null \
  || fail "every vaultPrefix must be stamped verifiedAt"

# --- 2. read-back missing grantee -> fail, status unchanged ------------------

write_manifest "$M" building
: > "$INVOKE_LOG"
export HQ_STUB_ACL_RESPONSE="grantee: someone-else@acme.test permission: write"
set +e
bash "$GRANT" --manifest "$M" --yes >/dev/null 2>&1
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "unverified grant must exit non-zero"
jq -e '.status == "building"' "$M" >/dev/null \
  || fail "failed read-back must leave manifest status unchanged"
unset HQ_STUB_ACL_RESPONSE

# --- 3. company-anchored prefix -> hard error, nothing invoked ---------------

write_manifest "$M" building
TMP_M="$(mktemp)"
jq '.vaultPrefixes[0].prefix = "companies/acme/projects/widget/"' "$M" > "$TMP_M" && mv "$TMP_M" "$M"
: > "$INVOKE_LOG"
set +e
ERR="$(bash "$GRANT" --manifest "$M" --yes 2>&1 >/dev/null)"
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "company-anchored prefix must be a hard error"
printf '%s' "$ERR" | grep -qi "convention" || fail "error must name the prefix-convention rule: $ERR"
[ ! -s "$INVOKE_LOG" ] || fail "convention violation must invoke nothing: $(cat "$INVOKE_LOG")"

# bare (non-folder) prefix is equally hard an error
write_manifest "$M" building
TMP_M="$(mktemp)"
jq '.vaultPrefixes[1].prefix = "knowledge/insights"' "$M" > "$TMP_M" && mv "$TMP_M" "$M"
: > "$INVOKE_LOG"
set +e
bash "$GRANT" --manifest "$M" --yes >/dev/null 2>&1
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "bare non-folder prefix must be a hard error"
[ ! -s "$INVOKE_LOG" ] || fail "bare-prefix violation must invoke nothing"

# --- agent recipient: grants flow through a per-agent delegation group -------
# (Live finding: `hq files share --with` rejects agt_ principals — only
# email/grp_/@all are valid file-ACL grantees. Agent grants use grp_dlg-<tail>.)

write_manifest "$M" building
TMP_M="$(mktemp)"
jq '.to = {"kind": "agent", "principal": "agt_01KTXDEACON", "displayName": "Deacon"}' "$M" > "$TMP_M" && mv "$TMP_M" "$M"
: > "$INVOKE_LOG"
export HQ_STUB_ACL_RESPONSE="grantee: group:grp_dlg-ktxdeacon permission: write
grantee: group:grp_dlg-ktxdeacon permission: read"
bash "$GRANT" --manifest "$M" --yes >/dev/null 2>&1 || fail "agent-recipient grant run exited non-zero"

grep -q '^groups create grp_dlg-ktxdeacon --name Delegation: Deacon --company acme$' "$INVOKE_LOG" \
  || fail "agent recipient must ensure the delegation group exists: $(cat "$INVOKE_LOG")"
grep -q '^groups add grp_dlg-ktxdeacon agt_01KTXDEACON --company acme$' "$INVOKE_LOG" \
  || fail "agent recipient must be added to the delegation group"
if grep '^files share' "$INVOKE_LOG" | grep -q 'agt_'; then
  fail "files share must never receive a raw agt_ principal"
fi
grep -q '^files share projects/widget/ --with grp_dlg-ktxdeacon --permission write --company acme$' "$INVOKE_LOG" \
  || fail "agent write grant must target the delegation group"
jq -e '.status == "granted" and .grantPrincipal == "grp_dlg-ktxdeacon"' "$M" >/dev/null \
  || fail "manifest must record the group grant principal"
unset HQ_STUB_ACL_RESPONSE

echo "hq-delegate-grant: ok (plan/confirm gate, push+share+readback, folder-form enforced, fail-closed on unverified grant, direct grants only, agent-via-group)"
