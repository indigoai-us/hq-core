#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$ROOT/.claude/skills/deploy/scripts/guardrails-check.sh"
TMP="$(mktemp -d)"
TARBALL=""
cleanup() {
  [ -z "$TARBALL" ] || rm -f "$TARBALL"
  rm -rf "$TMP"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$TMP/project/api" "$TMP/build"
printf '<html>synthetic fixture</html>\n' > "$TMP/build/index.html"
printf 'export default () => new Response("ok")\n' > "$TMP/project/api/health.js"

cd "$TMP/project"
result="$("$SCRIPT" "$TMP/build" "$TMP/project/api")"
printf '%s\n' "$result" | jq -e '.pass == true and .file_count == 2' >/dev/null \
  || fail "guardrails did not count the frontend and API handler: $result"
TARBALL="$(printf '%s\n' "$result" | jq -r '.tarball_path')"
[ -f "$TARBALL" ] || fail "guardrails did not create the app artifact"
entries="$(tar -tzf "$TARBALL")"
printf '%s\n' "$entries" | grep -Fxq 'api/health.js' \
  || fail "app artifact omitted the root api handler: $entries"
printf '%s\n' "$entries" | grep -Eq '(^|\./)index\.html$' \
  || fail "app artifact omitted the built frontend: $entries"
echo 'PASS: app artifact contains both build output and root api handler'
