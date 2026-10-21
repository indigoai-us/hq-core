#!/usr/bin/env bash
# Regression (2026-10-18): the /deploy skill must
#   - read every page of GET /api/apps (it is paginated with nextCursor), and
#   - apply the access gate BEFORE any upload, and take the app down when the
#     gate cannot be proven on the live URL afterwards.
# Reading one page and gating after upload is how project-summary left two
# internal pages public on 2026-10-18.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SKILL="$ROOT/.claude/skills/deploy/SKILL.md"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }
[ -f "$SKILL" ] || fail "deploy skill is missing: $SKILL"

line_of() { grep -n -F -- "$1" "$SKILL" | head -1 | cut -d: -f1; }

# 1. App list reads every page.
grep -Fq 'APPS_JSON=$(HQ_DEPLOY_JWT="$JWT" .claude/skills/deploy/scripts/list-apps.sh --api "$API"' "$SKILL" \
  || fail "APPS_JSON is not built from list-apps.sh (all pages)"
if grep -Eq 'deploy_request app-list --method GET --url "\$API/api/apps"' "$SKILL"; then
  fail "a single-page GET /api/apps lookup is still present"
fi
[ -x "$ROOT/.claude/skills/deploy/scripts/list-apps.sh" ] || fail "list-apps.sh missing or not executable"
pass "app lookup reads every page"

# 2. The gate section comes before every upload section.
gate="$(line_of '#### C.3 — Wire access mode BEFORE upload')"
find="$(line_of '#### Find or create the app')"
[ -n "$gate" ] || fail "C.3 gate section not found"
[ "$find" -lt "$gate" ] || fail "C.3 runs before the app id exists"
for upload in '#### Inject social preview tags' '#### Static upload' '#### App upload' '#### SSR upload'; do
  n="$(line_of "$upload")"
  [ -n "$n" ] || fail "section missing: $upload"
  [ "$gate" -lt "$n" ] || fail "gate (line $gate) must precede '$upload' (line $n)"
done
pass "gate is applied before any upload"

# 3. Existing apps wait for the edge redirect before upload.
edge="$(line_of '#### Wait for the edge before uploading to an existing app')"
static="$(line_of '#### Static upload')"
[ -n "$edge" ] && [ "$edge" -lt "$static" ] || fail "no pre-upload edge wait for existing apps"
pass "existing apps wait for the edge before upload"

# 4. Post-upload verification fails closed with a takedown.
VERIFY="$(awk '/^#### Auth-gate verify/ {on=1} /^### C.4/ {on=0} on' "$SKILL")"
grep -Fq 'deploy_request app-takedown --method PATCH --url "$API/api/apps/$APP_ID"' <<<"$VERIFY" \
  || fail "auth-gate verify does not take the app down on failure"
grep -Fq '"active": false' <<<"$VERIFY" || fail "takedown does not deactivate the app"
grep -Fq 'take_down_and_fail' <<<"$VERIFY" || fail "verify failure does not call take_down_and_fail"
grep -Fq "do not auto-delete the deploy" <<<"$VERIFY" && fail "stale 'do not auto-delete' guidance remains"
pass "unproven gate after upload takes the app down"

echo "ALL PASS: deploy-skill-gate-before-upload"
