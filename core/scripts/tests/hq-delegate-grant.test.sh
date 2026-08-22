#!/usr/bin/env bash
# Regression: hq-delegate-grant.sh must materialize the dossier, write the
# manifest's grants via DIRECT ACL grants, verify each via read-back, and
# fail closed on convention violations or unverified grants.
#
# The stub models the REAL `hq files acl` table AND the resolution behaviour
# that broke the literal-grep verifier in production: `hq files share --with
# <member-email>` resolves a provisioned member to their personUid, so the ACL
# lists the grant as `person  prs_…` and never echoes the email. The verifier
# must still recognise the grant.
#
# Guards:
#   1. Happy path: one sync push + one share per prefix, expected permission
#      per prefix, every shared prefix ends in "/", manifest advances to
#      'granted' with verifiedAt stamps.
#   1b. RESOLUTION regression: a member email whose ACL row is stored under a
#       prs_ uid (not the literal email) still verifies.
#   1c. Pending (unresolved) email stays email-keyed and still verifies.
#   2. Grant that never lands in the ACL -> non-zero, status stays 'building'.
#   3. A companies/<slug>/-anchored (or bare) prefix -> non-zero, nothing run.
#   4. Without --yes -> exit 2, plan printed, zero mutating invocations.
#   5. No share-session URL path: every share call carries --with (direct
#      grant), never the bare browser-flow form.
#   6. Agent recipient: grants flow through a per-agent delegation group.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
GRANT="$ROOT/core/scripts/hq-delegate-grant.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$GRANT" ] || fail "missing grant helper: $GRANT"

# --- stub hq CLI -------------------------------------------------------------
# Stateful: `files share` mutates a per-prefix ACL store (resolving known member
# emails to prs_ uids, exactly as the real CLI does); `files acl` renders that
# store as the real table. HQ_STUB_SHARE_NOOP=1 makes share a no-op (models a
# share that reports success but never lands the grant).
INVOKE_LOG="$TMP/invocations.log"
ACL_STATE="$TMP/aclstate"
mkdir -p "$TMP/bin" "$ACL_STATE"
cat > "$TMP/bin/hq" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$HQ_STUB_LOG"

pfx_file() { printf '%s/%s' "$HQ_STUB_ACL_STATE" "$(printf '%s' "$1" | tr '/@' '__')"; }

# Resolve a --with principal to an ACL grantee row "TYPE GRANTEE" exactly as the
# real vault does: known member email -> person prs_…, group id -> group, any
# other email -> email (pending, stays email-keyed).
resolve_grantee() {
  case "$1" in
    grp_*)              printf 'group %s' "$1" ;;
    alice@acme.test)    printf 'person prs_ALICE' ;;
    *@*)                printf 'email %s' "$1" ;;
    *)                  printf 'person prs_%s' "$1" ;;
  esac
}

case "$1 $2" in
  "sync push")     exit 0 ;;
  "groups create") exit 0 ;;
  "groups add")    exit 0 ;;
  "files share")
    # args: files share <pfx> --with <who> --permission <perm> --company <co>
    pfx=""; who=""; perm=""
    shift 2
    while [ $# -gt 0 ]; do
      case "$1" in
        --with)       who="$2"; shift 2 ;;
        --permission) perm="$2"; shift 2 ;;
        --company)    shift 2 ;;
        *)            [ -z "$pfx" ] && pfx="$1"; shift ;;
      esac
    done
    if [ "${HQ_STUB_SHARE_NOOP:-0}" != "1" ]; then
      row="$(resolve_grantee "$who")"
      f="$(pfx_file "$pfx")"
      line="$row $perm"
      grep -qxF "$line" "$f" 2>/dev/null || printf '%s\n' "$line" >> "$f"
    fi
    echo "Granted $perm on ${pfx}* to $who"
    exit 0 ;;
  "files acl")
    pfx="$3"
    f="$(pfx_file "$pfx")"
    echo "ACL for ${pfx}* (restricted)"
    echo "Creator: prs_CREATOR"
    echo "Your effective permission: admin"
    echo ""
    echo "Direct entries (granted on this prefix):"
    echo "TYPE    GRANTEE                         PERMISSION  GRANTED_BY  GRANTED_AT"
    if [ -f "$f" ]; then
      while read -r type grantee perm; do
        [ -n "$type" ] || continue
        printf '%s  %s  %s  prs_CREATOR  2026-08-21\n' "$type" "$grantee" "$perm"
      done < "$f"
    fi
    echo ""
    echo "Inherited (granted on an ancestor prefix):"
    echo "TYPE    GRANTEE   PERMISSION  GRANTED_BY  SOURCE  GRANTED_AT"
    echo "group   grp_core  admin       prs_CREATOR  *       2026-04-29"
    exit 0 ;;
  "people resolve")
    tok="$3"
    case "$tok" in
      alice@acme.test|Alice)
        echo '{"status":"found","email":"alice@acme.test","person":{"name":"Alice","email":"alice@acme.test","role":"admin"}}' ;;
      *)
        echo '{"status":"not_found"}' ;;
    esac
    exit 0 ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/hq"
export PATH="$TMP/bin:$PATH"
export HQ_STUB_LOG="$INVOKE_LOG"
export HQ_STUB_ACL_STATE="$ACL_STATE"

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
  "knowledge": ["companies/acme/knowledge/insights/widget-notes.md", "repos/public/widget-repo/docs/widget.md"],
  "policies": ["companies/acme/policies/widget-policy.md"],
  "secrets": [],
  "status": "$2"
}
JSON
}

reset_acl_state() { rm -rf "$ACL_STATE"; mkdir -p "$ACL_STATE"; }

# Fixture HQ root so referenced knowledge exists locally for pushing
FIXROOT="$TMP/hqroot"
mkdir -p "$FIXROOT/companies/acme/knowledge/insights" "$FIXROOT/companies/acme/policies"
echo note > "$FIXROOT/companies/acme/knowledge/insights/widget-notes.md"
echo policy > "$FIXROOT/companies/acme/policies/widget-policy.md"
export HQ_ROOT="$FIXROOT"

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

# --- 1 + 1b. happy path, with the member email resolved to a prs_ uid --------

reset_acl_state
: > "$INVOKE_LOG"
bash "$GRANT" --manifest "$M" --yes >/dev/null 2>&1 || fail "happy path exited non-zero"

grep -q "^sync push companies/acme/projects/widget/ --company acme --on-conflict keep" "$INVOKE_LOG" \
  || fail "must push the project dir to the vault first: $(cat "$INVOKE_LOG")"

# Referenced company-local knowledge/policies are pushed too (live finding:
# a read grant on a prefix is useless if the referenced file was never
# pushed); repo-based docs are NOT pushed.
grep -q "^sync push companies/acme/knowledge/insights/widget-notes.md --company acme --on-conflict keep" "$INVOKE_LOG" \
  || fail "must push referenced knowledge files: $(cat "$INVOKE_LOG")"
grep -q "^sync push companies/acme/policies/widget-policy.md --company acme --on-conflict keep" "$INVOKE_LOG" \
  || fail "must push referenced policy files"
if grep '^sync push' "$INVOKE_LOG" | grep -q 'repos/'; then
  fail "repo-based docs must never be pushed to the vault"
fi

SHARE_COUNT="$(grep -c '^files share' "$INVOKE_LOG")"
[ "$SHARE_COUNT" -eq 3 ] || fail "expected exactly 3 share calls, got $SHARE_COUNT"
grep -q '^files share projects/widget/ --with alice@acme.test --permission write --company acme$' "$INVOKE_LOG" \
  || fail "missing write share on projects/widget/"
grep -q '^files share knowledge/insights/ --with alice@acme.test --permission read --company acme$' "$INVOKE_LOG" \
  || fail "missing read share on knowledge/insights/"
grep -q '^files share policies/ --with alice@acme.test --permission read --company acme$' "$INVOKE_LOG" \
  || fail "missing read share on policies/"

# 1b. The ACL stored the grant under a prs_ uid, NOT the literal email — the
# regression that broke production. Verification must still have passed.
grep -qxF 'person prs_ALICE write' "$ACL_STATE/projects_widget_" \
  || fail "member email should have resolved to a prs_ uid in the ACL store"
if grep -q 'alice@acme.test' "$ACL_STATE/projects_widget_" 2>/dev/null; then
  fail "resolved member must NOT be stored under the literal email"
fi

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

# --- 1b-2. idempotent re-run: rows already present, grant still verifies ------
# (Re-running /delegate resumes; the resolved rows already exist so no NEW row
# appears — the known-person fallback must still recognise the landed grant.)
write_manifest "$M" building
: > "$INVOKE_LOG"
bash "$GRANT" --manifest "$M" --yes >/dev/null 2>&1 \
  || fail "idempotent re-run over already-present resolved grants must still verify"
jq -e '.status == "granted"' "$M" >/dev/null || fail "re-run must advance to granted"

# --- 1c. pending (unresolved) email stays email-keyed and verifies -----------

reset_acl_state
write_manifest "$M" building
TMP_M="$(mktemp)"
jq '.to = {"kind":"person","principal":"bob@pending.test","displayName":"Bob"}' "$M" > "$TMP_M" && mv "$TMP_M" "$M"
: > "$INVOKE_LOG"
bash "$GRANT" --manifest "$M" --yes >/dev/null 2>&1 || fail "pending-email grant must verify (email-keyed)"
grep -qxF 'email bob@pending.test write' "$ACL_STATE/projects_widget_" \
  || fail "pending email must stay email-keyed in the ACL store"
jq -e '.status == "granted"' "$M" >/dev/null || fail "pending-email run must advance to granted"

# --- 2. grant never lands in the ACL -> fail, status unchanged ---------------

reset_acl_state
write_manifest "$M" building
: > "$INVOKE_LOG"
set +e
HQ_STUB_SHARE_NOOP=1 bash "$GRANT" --manifest "$M" --yes >/dev/null 2>&1
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "unverified grant must exit non-zero"
jq -e '.status == "building"' "$M" >/dev/null \
  || fail "failed read-back must leave manifest status unchanged"

# --- 3. company-anchored prefix -> hard error, nothing invoked ---------------

reset_acl_state
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

# --- 6. agent recipient: grants flow through a per-agent delegation group -----
# (Live finding: `hq files share --with` rejects agt_ principals — only
# email/grp_/@all are valid file-ACL grantees. Agent grants use grp_dlg-<tail>.)

reset_acl_state
write_manifest "$M" building
TMP_M="$(mktemp)"
jq '.to = {"kind": "agent", "principal": "agt_01KTXDEACON", "displayName": "Deacon"}' "$M" > "$TMP_M" && mv "$TMP_M" "$M"
: > "$INVOKE_LOG"
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

echo "hq-delegate-grant: ok (plan/confirm gate, push+share+readback, resolution-aware verify, folder-form enforced, fail-closed on unverified grant, direct grants only, agent-via-group)"
