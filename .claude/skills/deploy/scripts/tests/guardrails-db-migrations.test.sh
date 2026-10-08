#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
GUARDRAILS="$ROOT/.claude/skills/deploy/scripts/guardrails-check.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PROJECT="$TMP_ROOT/project"
mkdir -p "$PROJECT/dist" "$PROJECT/api" "$PROJECT/db/migrations"
printf 'artifact\n' > "$PROJECT/dist/index.html"
printf 'export default () => null\n' > "$PROJECT/api/hello.ts"
printf 'create table if not exists t (id int);\n' > "$PROJECT/db/migrations/001_create.sql"

list_tarball() {
  local result tarball
  result="$(cd "$PROJECT" && "$GUARDRAILS" "$@")"
  case "$result" in
    *'"pass":true'*) ;;
    *) printf 'FAIL: guardrails did not pass: %s\n' "$result" >&2; exit 1 ;;
  esac
  tarball="$(printf '%s' "$result" | sed -E 's/.*"tarball_path":"([^"]*)".*/\1/')"
  tar -tzf "$tarball"
  rm -f "$tarball"
}

assert_has() {
  printf '%s\n' "$1" | grep -Eq "$2" || { printf 'FAIL: archive is missing %s\n' "$2" >&2; exit 1; }
}

WITH_BUILD_DIR="$(list_tarball "$PROJECT/dist" "$PROJECT/api")"
assert_has "$WITH_BUILD_DIR" '^\./index\.html$'
assert_has "$WITH_BUILD_DIR" '^api/hello\.ts$'
assert_has "$WITH_BUILD_DIR" '^db/migrations/001_create\.sql$'

WITHOUT_API="$(list_tarball "$PROJECT/dist")"
assert_has "$WITHOUT_API" '^db/migrations/001_create\.sql$'

ROOT_AS_OUTPUT="$(list_tarball "$PROJECT")"
COUNT="$(printf '%s\n' "$ROOT_AS_OUTPUT" | grep -c '^\(\./\)\{0,1\}db/migrations/001_create\.sql$')"
[ "$COUNT" = "1" ] || { printf 'FAIL: migration appears %s times when the project root is the output dir\n' "$COUNT" >&2; exit 1; }

rm -rf "$PROJECT/db"
NO_DB="$(list_tarball "$PROJECT/dist" "$PROJECT/api")"
if printf '%s\n' "$NO_DB" | grep -q 'db/migrations'; then
  echo 'FAIL: db/migrations added although the project has none' >&2
  exit 1
fi

mkdir -p "$TMP_ROOT/bin"
cat > "$TMP_ROOT/bin/tar" <<'STUB'
#!/usr/bin/env bash
printf '%s' "${COPYFILE_DISABLE:-unset}" > "$STUB_ENV_OUT"
exec /usr/bin/env -i PATH=/usr/bin:/bin tar "$@"
STUB
chmod +x "$TMP_ROOT/bin/tar"
(cd "$PROJECT" && STUB_ENV_OUT="$TMP_ROOT/copyfile" PATH="$TMP_ROOT/bin:$PATH" "$GUARDRAILS" "$PROJECT/dist" >/dev/null)
[ "$(cat "$TMP_ROOT/copyfile")" = "1" ] || { echo 'FAIL: tar ran without COPYFILE_DISABLE=1' >&2; exit 1; }

printf 'PASS: db/migrations is packed from the project root exactly once and tar runs with COPYFILE_DISABLE=1\n'
