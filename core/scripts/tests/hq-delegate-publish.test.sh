#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export HQ_ROOT="$TMP/hq" HQ_TEST_CLOUD="$TMP/cloud"
PROJ="$HQ_ROOT/companies/acme/projects/widget"
BUNDLE="$HQ_ROOT/workspace/delegations/dlg-test"
mkdir -p "$PROJ/journal" "$BUNDLE" "$TMP/bin" "$HQ_TEST_CLOUD"
export PATH="$TMP/bin:$PATH"
cat > "$TMP/bin/hq" <<'STUB'
#!/usr/bin/env bash
set -eu
case "$1 $2" in
  'sync push')
    [ "${HQ_TEST_PUSH_FAIL:-0}" = 0 ] || exit 1
    mkdir -p "$HQ_TEST_CLOUD/projects"
    cp -R "$HQ_ROOT/companies/acme/projects/widget" "$HQ_TEST_CLOUD/projects/"
    if [ "${HQ_TEST_STALE:-0}" = 1 ]; then
      echo '{"metadata":{"owner":"old@example.test"}}' > "$HQ_TEST_CLOUD/projects/widget/prd.json"
    fi ;;
  'files cat') cat "$HQ_TEST_CLOUD/$3" ;;
  *) echo "unexpected command $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/hq"
echo '{"metadata":{"owner":"alice@example.test"}}' > "$PROJ/prd.json"
echo 'marker' > "$PROJ/README.md"
echo 'ownership transfer' > "$PROJ/journal/delegations.md"
echo '# Brief' > "$BUNDLE/BRIEF.md"
M="$BUNDLE/manifest.json"
reset_manifest() {
  cat > "$M" <<'JSON'
{"schemaVersion":1,"company":"acme","project":{"name":"widget"},"delegationId":"dlg-test","mode":"transfer","status":"granted","ownershipTransferredAt":"2026-09-11T00:00:00Z","to":{"principal":"alice@example.test"}}
JSON
}
reset_manifest
bash "$ROOT/core/scripts/hq-delegate-publish.sh" --manifest "$M" >/dev/null
jq -e '.recipientAccess == "unconfirmed" and (.publication.files|length)==5' "$M" >/dev/null || fail 'publication evidence missing'
jq -e '.metadata.owner == "alice@example.test"' "$HQ_TEST_CLOUD/projects/widget/prd.json" >/dev/null || fail 'cloud owner stale'
cmp "$PROJ/delegation/dlg-test/manifest.json" "$HQ_TEST_CLOUD/projects/widget/delegation/dlg-test/manifest.json" || fail 'cloud manifest differs'
BEFORE="$(sha256sum "$PROJ/delegation/dlg-test/manifest.json")"
bash "$ROOT/core/scripts/hq-delegate-publish.sh" --manifest "$M" >/dev/null
[ "$(sha256sum "$PROJ/delegation/dlg-test/manifest.json")" = "$BEFORE" ] || fail 'publication replay changes immutable snapshot'

reset_manifest
if HQ_TEST_STALE=1 bash "$ROOT/core/scripts/hq-delegate-publish.sh" --manifest "$M" >/dev/null 2>&1; then fail 'stale canonical owner accepted'; fi
jq -e '.publication == null and .status == "granted"' "$M" >/dev/null || fail 'stale publication received success receipt'
reset_manifest
if HQ_TEST_PUSH_FAIL=1 bash "$ROOT/core/scripts/hq-delegate-publish.sh" --manifest "$M" >/dev/null 2>&1; then fail 'failed publish accepted'; fi
jq -e '.publication == null' "$M" >/dev/null || fail 'failed publish received receipt'
reset_manifest
jq 'del(.ownershipTransferredAt)' "$M" > "$TMP/m" && mv "$TMP/m" "$M"
if bash "$ROOT/core/scripts/hq-delegate-publish.sh" --manifest "$M" >/dev/null 2>&1; then fail 'publication before transfer accepted'; fi
echo 'hq-delegate-publish: ok (final owner and dossier, exact bytes, stable replay, stale/read/write failures gated)'
for unsafe in 'https://example.test/share-session/test-capability' '-----BEGIN RSA PRIVATE KEY-----'; do
  reset_manifest
  before="$(sha256sum "$PROJ/delegation/dlg-test/BRIEF.md")"
  echo "$unsafe" > "$BUNDLE/BRIEF.md"
  if bash "$ROOT/core/scripts/hq-delegate-publish.sh" --manifest "$M" >/dev/null 2>&1; then fail 'unsafe brief accepted'; fi
  [ "$(sha256sum "$PROJ/delegation/dlg-test/BRIEF.md")" = "$before" ] || fail 'unsafe brief reached synced directory'
  jq -e '.publication == null' "$M" >/dev/null || fail 'unsafe content received receipt'
done

# A failed staged copy must preserve the last resumable manifest.
echo '# Brief' > "$BUNDLE/BRIEF.md"
reset_manifest
cp "$M" "$TMP/before-manifest"
REAL_CP="$(command -v cp)"
export REAL_CP
cat > "$TMP/bin/cp" <<'STUB'
#!/usr/bin/env bash
if [[ "$2" == "$HQ_ROOT/workspace/delegations/dlg-test/manifest.json.tmp."* ]]; then
  echo 'partial' > "$2"
  exit 1
fi
exec "$REAL_CP" "$@"
STUB
chmod +x "$TMP/bin/cp"
if bash "$ROOT/core/scripts/hq-delegate-publish.sh" --manifest "$M" >/dev/null 2>&1; then fail 'partial copy accepted'; fi
cmp "$M" "$TMP/before-manifest" || fail 'failed copy destroyed resumable manifest'
rm "$TMP/bin/cp"
mkdir "$M.send-lock"
if bash "$ROOT/core/scripts/hq-delegate-publish.sh" --manifest "$M" >/dev/null 2>&1; then fail 'publication ignored delivery lock'; fi
if bash "$ROOT/core/scripts/hq-delegate-verify.sh" --manifest "$M" >/dev/null 2>&1; then fail 'verification ignored delivery lock'; fi
cmp "$M" "$TMP/before-manifest" || fail 'concurrent publication changed manifest'
rmdir "$M.send-lock"
