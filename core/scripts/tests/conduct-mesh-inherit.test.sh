#!/usr/bin/env bash
# hq-core: public
# Regression: detached /conduct lanes keep the parent pool id but bind Work
# Mesh to the child engine session supplied in SessionStart stdin.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$ROOT/core/hooks/SessionStart/35-work-mesh-session-start.sh"
TMP="$(mktemp -d)"
HQ="$TMP/hq"
PARENT="conduct-parent-$$"
CHILD="conduct-child-$$"

cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

mkdir -p "$TMP/home" "$TMP/spool" "$TMP/seq" \
  "$HQ/core/hooks/SessionStart" "$HQ/core/scripts/lib" \
  "$HQ/companies/indigo" "$HQ/companies/holler" "$HQ/workspace/sessions/$PARENT"
cp "$HOOK" "$HQ/core/hooks/SessionStart/"
cp "$ROOT/core/scripts/lib/work-mesh-enqueue.sh" "$HQ/core/scripts/lib/"
cp "$ROOT/core/scripts/lib/session-auto-bind.sh" "$HQ/core/scripts/lib/"
printf 'session_id: %s\ncompany_slug: indigo\n' "$PARENT" > "$HQ/workspace/sessions/$PARENT/meta.yaml"

printf '{"session_id":"%s","cwd":"/tmp/conduct-child"}\n' "$CHILD" |
  env HOME="$TMP/home" HQ_ROOT="$HQ" HQ_SESSION_ID="$PARENT" \
    HQ_PARENT_SESSION_ID="$PARENT" HQ_SPAWN_COMPANY=indigo \
    WORK_MESH_SPOOL="$TMP/spool/events.jsonl" WORK_MESH_SEQ_DIR="$TMP/seq" \
    HQ_WORK_MESH_RECONCILE_STUB=1 /bin/bash "$HQ/core/hooks/SessionStart/35-work-mesh-session-start.sh" >/dev/null

META="$HQ/workspace/sessions/$CHILD/meta.yaml"
[ -f "$META" ] || fail "child SessionStart did not create metadata"
grep -qx 'company_slug: indigo' "$META" \
  || fail "child session did not inherit indigo"
grep -F '"sessionId":"'"$CHILD"'"' "$TMP/spool/events.jsonl" >/dev/null \
  || fail "mesh event used parent session instead of child"
grep -F '"companySlug":"indigo"' "$TMP/spool/events.jsonl" >/dev/null \
  || fail "child mesh event was not labeled indigo"
pass "child engine session inherits indigo while HQ_SESSION_ID remains parent"

MISMATCH_CHILD="conduct-mismatch-child-$$"
MISMATCH_LOG="$TMP/mismatch.err"
printf '{"session_id":"%s","cwd":"/tmp/conduct-mismatch-child"}\n' "$MISMATCH_CHILD" |
  env HOME="$TMP/home" HQ_ROOT="$HQ" HQ_SESSION_ID="$PARENT" \
    HQ_PARENT_SESSION_ID="$PARENT" HQ_SPAWN_COMPANY=holler \
    WORK_MESH_SPOOL="$TMP/spool/mismatch-events.jsonl" WORK_MESH_SEQ_DIR="$TMP/seq" \
    HQ_WORK_MESH_RECONCILE_STUB=1 /bin/bash "$HQ/core/hooks/SessionStart/35-work-mesh-session-start.sh" \
    >/dev/null 2>"$MISMATCH_LOG"

MISMATCH_META="$HQ/workspace/sessions/$MISMATCH_CHILD/meta.yaml"
[ -f "$MISMATCH_META" ] || fail "mismatch child SessionStart did not create metadata"
grep -qx 'company_slug: indigo' "$MISMATCH_META" \
  || fail "mismatch child inherited HQ_SPAWN_COMPANY instead of parent indigo"
grep -F 'session-auto-bind: ignoring HQ_SPAWN_COMPANY=holler because it mismatches parent company_slug=indigo' "$MISMATCH_LOG" >/dev/null \
  || fail "mismatch did not emit tenancy guard reason"
grep -F '"companySlug":"indigo"' "$TMP/spool/mismatch-events.jsonl" >/dev/null \
  || fail "mismatch child mesh event was labeled with HQ_SPAWN_COMPANY"
if grep -F '"companySlug":"holler"' "$TMP/spool/mismatch-events.jsonl" >/dev/null; then
  fail "mismatch child minted holler mesh scope"
fi
pass "mismatched spawn company falls back to the parent tenant"
