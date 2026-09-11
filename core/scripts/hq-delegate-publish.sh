#!/usr/bin/env bash
# hq-core: public
# Publish final delegation artifacts and verify their canonical cloud bytes.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HQ_ROOT="${HQ_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
. "$SCRIPT_DIR/lib/secret-patterns.sh"
die() { echo "hq-delegate-publish: $*" >&2; exit 1; }
[ "${1:-}" = --manifest ] && [ -f "${2:-}" ] || die 'usage: --manifest <path>'
MANIFEST="$2"
LOCK="$MANIFEST.send-lock"
if [ "${3:-}" = --lock-held ]; then
  [ -d "$LOCK" ] || die 'verification lock missing'
  OWN_LOCK=0
else
  [ "$#" -eq 2 ] || die 'usage: --manifest <path>'
  mkdir "$LOCK" 2>/dev/null || die 'verification or delivery is active; retry after it finishes'
  OWN_LOCK=1
fi
STAGE=""
trap '[[ -z "$STAGE" ]] || rm -rf "$STAGE"; [ "$OWN_LOCK" -eq 0 ] || rmdir "$LOCK"' EXIT
COMPANY="$(jq -er '.company' "$MANIFEST")"
PROJECT="$(jq -er '.project.name' "$MANIFEST")"
ID="$(jq -er '.delegationId' "$MANIFEST")"
for part in "$COMPANY" "$PROJECT" "$ID"; do
  [[ "$part" =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]*$ ]] || die 'unsafe path segment'
done
jq -e '.status == "granted" or .status == "verified"' "$MANIFEST" >/dev/null || die 'confirmed grants required'
if [ "$(jq -r '.mode' "$MANIFEST")" = transfer ]; then
  jq -e '.ownershipTransferredAt != null' "$MANIFEST" >/dev/null || die 'transfer must finish before publication'
fi
REL="companies/$COMPANY/projects/$PROJECT"
PROJECT_DIR="$HQ_ROOT/$REL"
BUNDLE="$(cd "$(dirname "$MANIFEST")" && pwd)"
[ -f "$BUNDLE/BRIEF.md" ] || die 'BRIEF.md missing'
[ -f "$PROJECT_DIR/prd.json" ] || die 'PRD missing'
if [ "$(jq -r '.mode' "$MANIFEST")" = transfer ]; then
  EXPECTED_OWNER="$(jq -r '.to.principal' "$MANIFEST")"
  jq -e --arg owner "$EXPECTED_OWNER" '.metadata.owner == $owner' "$PROJECT_DIR/prd.json" >/dev/null || die 'local PRD owner does not match recipient'
fi
STAGE="$(mktemp -d)"
atomic_copy() {
  local target_tmp
  target_tmp="$(mktemp "${2}.tmp.XXXXXX")"
  if ! cp "$1" "$target_tmp"; then rm -f "$target_tmp"; return 1; fi
  mv -f "$target_tmp" "$2"
}
DEST="$PROJECT_DIR/delegation/$ID"
cp "$BUNDLE/BRIEF.md" "$STAGE/BRIEF.md"
file_hash() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d ' ' -f1; else shasum -a 256 "$1" | cut -d ' ' -f1; fi
}
# Snapshot final project content, excluding mutable/self-referential receipts.
: > "$STAGE/hashes"
for file in "$PROJECT_DIR/prd.json" "$PROJECT_DIR/README.md" "$PROJECT_DIR/journal/delegations.md"; do
  [ -f "$file" ] || continue
  jq -cn --arg key "${file#"$HQ_ROOT/"}" --arg value "$(file_hash "$file")" '{key:$key,value:$value}' >> "$STAGE/hashes"
done
jq -cn --arg key "$REL/delegation/$ID/BRIEF.md" --arg value "$(file_hash "$STAGE/BRIEF.md")" '{key:$key,value:$value}' >> "$STAGE/hashes"
jq -s 'from_entries' "$STAGE/hashes" > "$STAGE/checksums"
jq --slurpfile hashes "$STAGE/checksums" '.checksums=$hashes[0] | .status="granted" | .recipientAccess="unconfirmed" | del(.publication,.verifiedAt,.sentAt,.dmEventId)' "$MANIFEST" > "$STAGE/manifest.json"
hq_scan_secrets "$STAGE/manifest.json" "$STAGE/BRIEF.md" || die 'unsafe generated dossier'
if grep -Eq 'share-session/[A-Za-z0-9_-]+' "$STAGE/manifest.json" "$STAGE/BRIEF.md"; then
  die 'share-session capability in dossier; nothing published'
fi
mkdir -p "$DEST"
atomic_copy "$STAGE/BRIEF.md" "$DEST/BRIEF.md"
atomic_copy "$STAGE/manifest.json" "$DEST/manifest.json"
atomic_copy "$STAGE/manifest.json" "$MANIFEST"
# keep may preserve stale canonical content. Read-back must catch that instead
# of overwriting concurrent changes merely to make the check pass.
hq sync push "$REL/" --company "$COMPANY" --on-conflict keep || die 'final dossier push failed; resume publication'
cp "$STAGE/hashes" "$STAGE/receipts"
jq -cn --arg key "$REL/delegation/$ID/manifest.json" --arg value "$(file_hash "$DEST/manifest.json")" '{key:$key,value:$value}' >> "$STAGE/receipts"
while IFS= read -r row; do
  path="$(printf '%s' "$row" | jq -r '.key')"
  expected="$(printf '%s' "$row" | jq -r '.value')"
  matched=0
  for delay in 0 1 2; do
    [ "$delay" -eq 0 ] || sleep "$delay"
    if hq files cat "${path#"companies/$COMPANY/"}" --company "$COMPANY" > "$STAGE/remote"; then
      if [ "$(file_hash "$STAGE/remote")" = "$expected" ]; then matched=1; break; fi
    fi
  done
  [ "$matched" -eq 1 ] || die "canonical cloud content differs or is unreadable: $path; resolve before sending"
done < "$STAGE/receipts"
jq -s 'from_entries' "$STAGE/receipts" > "$STAGE/files"
jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg path "$REL/delegation/$ID/manifest.json" --slurpfile files "$STAGE/files" \
  '.publication={verifiedAt:$now,manifestPath:$path,files:$files[0]} | .recipientAccess="unconfirmed"' "$MANIFEST" > "$STAGE/updated"
atomic_copy "$STAGE/updated" "$MANIFEST"
echo 'hq-delegate-publish: canonical dossier bytes verified as sender; recipient access unconfirmed'
