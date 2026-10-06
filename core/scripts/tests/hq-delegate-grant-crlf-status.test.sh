#!/usr/bin/env bash
# Regression: jq.exe emits CRLF in Git Bash. Grant status and displayed write
# prefixes must not retain CR bytes. The jq shim is deterministic and delegates
# parsing to installed jq, adding CRLF to the exact values used by the helper.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
GRANT="${HQ_DELEGATE_GRANT_TEST_SOURCE:-$ROOT/core/scripts/hq-delegate-grant.sh}"
REAL_JQ="$(command -v jq)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$TMP/bin" "$TMP/hqroot"
cat > "$TMP/manifest.json" <<'JSON'
{
  "company": "acme",
  "project": {"name": "widget"},
  "to": {"principal": "alice@example.test"},
  "status": "building",
  "vaultPrefixes": [{"prefix": "projects/widget/", "permission": "write", "reason": "fixture"}]
}
JSON

cat > "$TMP/bin/jq" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "--binary" ] && [ "${2:-}" = "-n" ]; then
  exit 0
fi
if [ "${1:-}" = "--binary" ]; then shift; fi
case "${2:-}" in
  '.vaultPrefixes[] | "  2. Grant '*|".company // empty"|".project.name // empty"|".to.principal // empty"|".to.displayName // .to.principal // empty") CRLF_QUERY=1 ;;
esac
if [ "${1:-}" = "-r" ] && { [ "${2:-}" = ".status // empty" ] || [ "${2:-}" = '.vaultPrefixes[] | select(.permission == "write") | .prefix' ] || [ "${CRLF_QUERY:-0}" = 1 ]; }; then
  set +e
  "$REAL_JQ" "$@" | sed 's/$/\r/'
  jq_rc=${PIPESTATUS[0]}
  set -e
  exit "$jq_rc"
fi
exec "$REAL_JQ" "$@"
STUB
chmod +x "$TMP/bin/jq"

# Run the real helper body through its MSYS wrapper on any host. The test only
# substitutes the read-only Bash OSTYPE/MSYSTEM selectors and makes sed -b
# portable; jq behavior and all command arguments remain real to the fixture.
TEST_GRANT="$TMP/hq-delegate-grant-msys.sh"
sed 's/\${OSTYPE:-}/${TEST_OSTYPE:-}/g; s/\${MSYSTEM:-}/${TEST_MSYSTEM:-}/g; s/sed -b/sed/g' "$GRANT" > "$TEST_GRANT"

set +e
OUTPUT="$(PATH="$TMP/bin:$PATH" REAL_JQ="$REAL_JQ" TEST_OSTYPE=msys TEST_MSYSTEM=MINGW64 HQ_ROOT="$TMP/hqroot" bash "$TEST_GRANT" --manifest "$TMP/manifest.json" 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] || fail "building status with CRLF jq output should reach confirmation (exit 2), got $RC: $OUTPUT"
printf '%s' "$OUTPUT" | grep -qF 'confirmation required' \
  || fail "building status with CRLF jq output should print the confirmation diagnostic: $OUTPUT"
case "$OUTPUT" in *$'\r'*) fail "jq CRLF must not leak into the printed write-prefix plan: $OUTPUT" ;; esac

echo "PASS: CRLF jq status and grant-plan output preserve the shell contract"
