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
  "secrets share") exit 0 ;;
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

# --- fixture: HQ root, project with .env.schema, bundle ----------------------

FIX="$TMP/hqroot"
PROJ="$FIX/companies/acme/projects/widget"
mkdir -p "$PROJ"
cat > "$PROJ/.env.schema" <<'SCHEMA'
# Widget runtime credentials
DATABASE_URL=
WIDGET_API_KEY=
STRIPE_WEBHOOK_SECRET=
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
printf '%s' "$PLAN" | grep -q "WIDGET_API_KEY" || fail "confirmation prose must list the names"
printf '%s' "$PLAN" | grep -q "alice@acme.test" || fail "confirmation prose must name the principal"
jq -e '.secrets == []' "$MANIFEST" >/dev/null || fail "declined run must not record names"

# --- 1. with --yes: names granted, values never read -------------------------

: > "$INVOKE_LOG"
HQ_ROOT="$FIX" bash "$HELPER" --manifest "$MANIFEST" --yes >/dev/null 2>&1 \
  || fail "grant run exited non-zero"

SHARE_COUNT="$(grep -c '^secrets share' "$INVOKE_LOG")"
[ "$SHARE_COUNT" -eq 3 ] || fail "expected exactly 3 share calls, got $SHARE_COUNT: $(cat "$INVOKE_LOG")"
for name in DATABASE_URL WIDGET_API_KEY STRIPE_WEBHOOK_SECRET; do
  grep -q "^secrets share $name --with alice@acme.test --permission read --company acme$" "$INVOKE_LOG" \
    || fail "missing read share for $name"
done

# value-read commands must never run
if grep -Eq '^secrets (get|env|exec)|--reveal' "$INVOKE_LOG"; then
  fail "a value-reading command was invoked: $(cat "$INVOKE_LOG")"
fi

jq -e '.secrets == ["DATABASE_URL","STRIPE_WEBHOOK_SECRET","WIDGET_API_KEY"] and .secretsSkipped == false and .secretsGrantedAt != null' \
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
printf '%s' "$OUT" | grep -qi "no .env.schema" || fail "no-schema run must say so plainly: $OUT"
jq -e '.secrets == [] and .secretsSkipped == false' "$MANIFEST" >/dev/null \
  || fail "no-schema run must record empty secrets without the skipped flag"

echo "hq-delegate-secrets: ok (names only, own confirm gate, --no-secrets and no-schema paths, sentinel value never surfaced)"
