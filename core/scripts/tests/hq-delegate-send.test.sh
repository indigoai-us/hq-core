#!/usr/bin/env bash
# Regression: hq-delegate-send.sh must generate a pickup prompt covered
# one-to-one against the manifest, deliver exactly one hq dm with file
# flags, refuse to send before verification, and fail closed on secret or
# share-session content.
#
# Guards:
#   1. Manifest with 4 vault prefixes -> prompt contains exactly those 4
#      `hq files get` lines (each exactly once) and no others.
#   2. --send on a verified manifest -> exactly ONE hq dm invocation using
#      --prompt-file and --details-file; status -> sent; eventId recorded.
#   3. Prompt and brief scanned: no secret-pattern match, no share-session
#      URL shape.
#   4. repo: null -> no git/checkout section, no branch reference.
#   5. --send with status != verified -> refused, no dm invocation.
#   6. A share-session URL smuggled into the brief -> send aborts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HELPER="$ROOT/core/scripts/hq-delegate-send.sh"
LIB="$ROOT/core/scripts/lib/secret-patterns.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$HELPER" ] || fail "missing helper: $HELPER"
[ -f "$LIB" ] || fail "missing secret-pattern lib: $LIB"

# --- stub hq CLI -------------------------------------------------------------
INVOKE_LOG="$TMP/invocations.log"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/hq" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$HQ_STUB_LOG"
if [ "$1" = "dm" ]; then
  [ "${HQ_STUB_DM_FAIL:-0}" = 0 ] || exit 1
  [ "${HQ_STUB_DM_NO_RECEIPT:-0}" = 0 ] || exit 0
  echo "DM sent to $2 (eventId evt_stub123)"
fi
exit 0
STUB
chmod +x "$TMP/bin/hq"
export PATH="$TMP/bin:$PATH"
export HQ_STUB_LOG="$INVOKE_LOG"

# --- fixture -----------------------------------------------------------------

FIX="$TMP/hqroot"
PROJ="$FIX/companies/acme/projects/widget"
mkdir -p "$PROJ"
cat > "$PROJ/prd.json" <<'JSON'
{
  "name": "widget",
  "description": "Build the widget.",
  "metadata": {"goal": "Widgets ship."},
  "userStories": [
    {"id": "US-001", "title": "Frame", "description": "Build the frame.", "priority": 1, "passes": true},
    {"id": "US-002", "title": "Spin", "description": "Make it spin.", "priority": 1, "passes": false}
  ]
}
JSON

BUNDLE="$FIX/workspace/delegations/dlg-test-widget"
mkdir -p "$BUNDLE"
MANIFEST="$BUNDLE/manifest.json"
write_manifest() { # status repo_json
  cat > "$MANIFEST" <<JSON
{
  "schemaVersion": 1,
  "delegationId": "dlg-test-widget",
  "mode": "transfer",
  "company": "acme",
  "from": {"email": "owner@acme.test", "personUid": null},
  "to": {"kind": "person", "principal": "alice@acme.test", "displayName": "Alice"},
  "project": {"name": "widget", "prdPath": "companies/acme/projects/widget/prd.json", "boardId": null},
  "vaultPrefixes": [
    {"prefix": "projects/widget/", "permission": "write", "reason": "project dossier"},
    {"prefix": "knowledge/insights/", "permission": "read", "reason": "knowledge"},
    {"prefix": "knowledge/eng/", "permission": "read", "reason": "knowledge"},
    {"prefix": "policies/", "permission": "read", "reason": "policies"}
  ],
  "repo": $2,
  "secrets": ["DATABASE_URL", "WIDGET_API_KEY"],
  "publication":{"verifiedAt":"now","files":{"companies/acme/projects/widget/prd.json":"fixture"}},
  "status": "$1"
}
JSON
  local rel="companies/acme/projects/widget/delegation/dlg-test-widget"
  mkdir -p "$FIX/$rel"
  cp "$BUNDLE/BRIEF.md" "$FIX/$rel/BRIEF.md"
  jq '.status="granted" | .recipientAccess="unconfirmed" | del(.publication,.verifiedAt,.sentAt,.dmEventId)' "$MANIFEST" > "$FIX/$rel/manifest.json"
  jq --arg mp "$rel/manifest.json" \
    --arg mh "$(sha256sum "$FIX/$rel/manifest.json" | cut -d ' ' -f1)" \
    --arg bp "$rel/BRIEF.md" --arg bh "$(sha256sum "$FIX/$rel/BRIEF.md" | cut -d ' ' -f1)" \
    --arg ph "$(sha256sum "$PROJ/prd.json" | cut -d ' ' -f1)" \
    '.publication={verifiedAt:"now",manifestPath:$mp,files:{($mp):$mh,($bp):$bh,"companies/acme/projects/widget/prd.json":$ph}}' "$MANIFEST" > "$TMP/updated"
  mv "$TMP/updated" "$MANIFEST"
}
REPO_JSON='{"path": "repos/public/widget-repo", "remote": "git@github.test:acme/widget-repo.git", "branch": "feature/widget", "baseBranch": "main", "headSha": "abc1234", "dirtyFiles": [], "accessVerified": true, "accessNote": ""}'
echo "# Delegation brief — widget" > "$BUNDLE/BRIEF.md"

# --- 1. prompt covers the manifest one-to-one --------------------------------

write_manifest verified "$REPO_JSON"
: > "$INVOKE_LOG"
HQ_ROOT="$FIX" bash "$HELPER" --manifest "$MANIFEST" >/dev/null 2>&1 \
  || fail "prompt generation exited non-zero"
PROMPT="$BUNDLE/PICKUP-PROMPT.md"
[ -f "$PROMPT" ] || fail "PICKUP-PROMPT.md not written"

GET_COUNT="$(grep -c '^hq files get ' "$PROMPT")"
[ "$GET_COUNT" -eq 4 ] || fail "expected exactly 4 hq files get lines, got $GET_COUNT"
for p in "projects/widget/" "knowledge/insights/" "knowledge/eng/" "policies/"; do
  C="$(grep -c "^hq files get $p --company acme$" "$PROMPT")"
  [ "$C" -eq 1 ] || fail "prefix $p must appear exactly once, got $C"
done

# ordered essentials: goal, state, next steps, repo, secrets consumption
for needle in "Widgets ship." "1 of 2 stories" "US-002" \
  "git -C repos/public/widget-repo fetch origin" \
  "git -C repos/public/widget-repo switch -- feature/widget" \
  "hq secrets exec --only DATABASE_URL,WIDGET_API_KEY" \
  "hq run --"; do
  grep -qF "$needle" "$PROMPT" || fail "prompt missing: $needle"
done
grep -q "Sender-side checks do not prove your access" "$PROMPT" || fail "prompt must state recipient access is unconfirmed"

# generation alone must not send
[ ! -s "$INVOKE_LOG" ] || fail "generation without --send must invoke nothing: $(cat "$INVOKE_LOG")"

# --- 3. no secrets, no share-session shapes ----------------------------------

(
  # shellcheck source=/dev/null
  . "$LIB"
  hq_scan_secrets "$PROMPT" "$BUNDLE/BRIEF.md"
) || fail "prompt or brief matched a secret pattern"
if grep -Eq 'share-session/' "$PROMPT" "$BUNDLE/BRIEF.md"; then
  fail "a share-session URL shape appeared in a delegation artifact"
fi

# --- 2. --send on verified: one dm, file flags, status sent ------------------

: > "$INVOKE_LOG"
HQ_ROOT="$FIX" bash "$HELPER" --manifest "$MANIFEST" --send >/dev/null 2>&1 \
  || fail "send exited non-zero"
DM_COUNT="$(grep -c '^dm ' "$INVOKE_LOG")"
[ "$DM_COUNT" -eq 1 ] || fail "expected exactly one hq dm invocation, got $DM_COUNT"
grep '^dm alice@acme.test ' "$INVOKE_LOG" | grep -q -- '--prompt-file' \
  || fail "dm must use --prompt-file"
grep '^dm alice@acme.test ' "$INVOKE_LOG" | grep -q -- '--details-file' \
  || fail "dm must use --details-file"
jq -e '.status == "sent" and .dmEventId == "evt_stub123" and .sentAt != null' "$MANIFEST" >/dev/null \
  || fail "manifest must record sent status + eventId: $(jq -c '{status, dmEventId}' "$MANIFEST")"

# --- 5. --send before verification is refused --------------------------------

write_manifest granted "$REPO_JSON"
: > "$INVOKE_LOG"
set +e
HQ_ROOT="$FIX" bash "$HELPER" --manifest "$MANIFEST" --send >/dev/null 2>&1
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "--send must refuse when status is not 'verified'"
if grep -q '^dm ' "$INVOKE_LOG"; then fail "no dm may be sent before verification"; fi
jq -e '.status == "granted"' "$MANIFEST" >/dev/null || fail "refused send must not advance status"

# --- 4. repo: null -> no git section -----------------------------------------

write_manifest verified null
HQ_ROOT="$FIX" bash "$HELPER" --manifest "$MANIFEST" >/dev/null 2>&1 \
  || fail "repo:null generation exited non-zero"
if grep -Eq 'git (fetch|switch|checkout)|git -C' "$PROMPT"; then
  fail "repo:null prompt must contain no git section"
fi
grep -q "feature/widget" "$PROMPT" && fail "repo:null prompt must not reference a branch" || true

# --- 6. share-session URL smuggled into the brief -> abort -------------------

write_manifest verified "$REPO_JSON"
echo "see https://hq.example.com/share-session/tok123abc" >> "$BUNDLE/BRIEF.md"
: > "$INVOKE_LOG"
set +e
HQ_ROOT="$FIX" bash "$HELPER" --manifest "$MANIFEST" --send >/dev/null 2>&1
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "a share-session URL in the brief must abort the send"
if grep -q '^dm ' "$INVOKE_LOG"; then fail "no dm may be sent when a share-session URL is present"; fi

echo '# Brief' > "$BUNDLE/BRIEF.md"
for failure in HQ_STUB_DM_FAIL HQ_STUB_DM_NO_RECEIPT; do
  write_manifest verified null
  : > "$INVOKE_LOG"
  if env "$failure=1" HQ_ROOT="$FIX" bash "$HELPER" --manifest "$MANIFEST" --send >/dev/null 2>&1; then fail 'uncertain delivery accepted'; fi
  jq -e '.status == "sending" and .dmEventId == null' "$MANIFEST" >/dev/null || fail 'uncertain delivery state lost'
  if HQ_ROOT="$FIX" bash "$HELPER" --manifest "$MANIFEST" --send >/dev/null 2>&1; then fail 'uncertain delivery blindly retried'; fi
  [ "$(grep -c '^dm ' "$INVOKE_LOG")" = 1 ] || fail 'duplicate DM after uncertain response'
done
write_manifest verified null
jq 'del(.publication)' "$MANIFEST" > "$TMP/m" && mv "$TMP/m" "$MANIFEST"
: > "$INVOKE_LOG"
if HQ_ROOT="$FIX" bash "$HELPER" --manifest "$MANIFEST" --send >/dev/null 2>&1; then fail 'legacy verified status without publication accepted'; fi
[ ! -s "$INVOKE_LOG" ] || fail 'DM sent without publication receipt'
echo "hq-delegate-send: ok (single DM, truthful probe, publication required, uncertain delivery cannot duplicate)"
for artifact in prd brief manifest; do
  write_manifest verified null
  case "$artifact" in
    prd) echo ' ' >> "$PROJ/prd.json" ;;
    brief) echo 'New unpublished detail' >> "$BUNDLE/BRIEF.md" ;;
    manifest) jq '.repo={branch:"feature/changed"}' "$MANIFEST" > "$TMP/m" && mv "$TMP/m" "$MANIFEST" ;;
  esac
  : > "$INVOKE_LOG"
  if HQ_ROOT="$FIX" bash "$HELPER" --manifest "$MANIFEST" --send >/dev/null 2>&1; then fail "unpublished $artifact accepted"; fi
  [ ! -s "$INVOKE_LOG" ] || fail "DM sent with unpublished $artifact"
done
write_manifest verified null
mkdir "$MANIFEST.send-lock"
: > "$INVOKE_LOG"
if HQ_ROOT="$FIX" bash "$HELPER" --manifest "$MANIFEST" --send >/dev/null 2>&1; then fail 'send ignored verification lock'; fi
[ ! -s "$INVOKE_LOG" ] || fail 'DM sent during verification'
rmdir "$MANIFEST.send-lock"
write_manifest verified null
REAL_JQ="$(command -v jq)"
export REAL_JQ
cat > "$TMP/bin/jq" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = '.status = "sending"' ]; then
  echo 'partial'
  exit 1
fi
exec "$REAL_JQ" "$@"
STUB
chmod +x "$TMP/bin/jq"
: > "$INVOKE_LOG"
if HQ_ROOT="$FIX" bash "$HELPER" --manifest "$MANIFEST" --send >/dev/null 2>&1; then fail 'failed sending-state write accepted'; fi
[ ! -s "$INVOKE_LOG" ] || fail 'DM sent without durable sending marker'
jq -e '.status == "verified"' "$MANIFEST" >/dev/null || fail 'failed state write destroyed manifest'
