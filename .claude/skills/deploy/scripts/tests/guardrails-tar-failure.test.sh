#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
GUARDRAILS="$ROOT/.claude/skills/deploy/scripts/guardrails-check.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/tmp" "$TMP_ROOT/output" "$TMP_ROOT/cwd"
printf 'artifact\n' > "$TMP_ROOT/output/index.html"

cat > "$TMP_ROOT/bin/tar" <<'STUB'
#!/usr/bin/env bash
set -u
archive=''
while [ "$#" -gt 0 ]; do
  if [ "$1" = '-czf' ]; then
    archive="$2"
    shift 2
  else
    shift
  fi
done
[ -n "$archive" ] || exit 64
printf 'partial archive' > "$archive"
exit 1
STUB
chmod +x "$TMP_ROOT/bin/tar"

RESULT="$(cd "$TMP_ROOT/cwd" && PATH="$TMP_ROOT/bin:$PATH" TMPDIR="$TMP_ROOT/tmp" "$GUARDRAILS" "$TMP_ROOT/output")"
case "$RESULT" in
  *'"pass":false'*'"reason":"tar_create_failed"'*) ;;
  *) printf 'FAIL: expected tar_create_failed JSON, got: %s\n' "$RESULT" >&2; exit 1 ;;
esac
FAILED_TARBALL="$(find "$TMP_ROOT/tmp" -type f -name 'hq-deploy-tar.*' -print -quit)"
if [ -n "$FAILED_TARBALL" ]; then
  echo 'FAIL: failed tarball was left behind' >&2
  exit 1
fi
printf 'PASS: tar failure is reported and its partial archive is removed\n'
