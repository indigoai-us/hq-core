#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_SCRIPT="${BUILD_PLUGIN_SCRIPT:-$SCRIPT_DIR/../build-plugin.sh}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/us150-build-prerequisites.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

ISOLATED_PATH="$TEST_ROOT/path"
TEST_TMPDIR="$TEST_ROOT/tmp"
TEST_HOME="$TEST_ROOT/home"
OUTPUT="$TEST_ROOT/output/cowork.plugin"
STDOUT_FILE="$TEST_ROOT/stdout.txt"
STDERR_FILE="$TEST_ROOT/stderr.txt"
MKTEMP_LOG="$TEST_ROOT/mktemp-calls.log"
mkdir -p "$ISOLATED_PATH" "$TEST_TMPDIR" "$TEST_HOME"

for tool in bash dirname mkdir mv rm; do
  tool_path="$(command -v "$tool")"
  ln -s "$tool_path" "$ISOLATED_PATH/$tool"
done

REAL_MKTEMP="$(command -v mktemp)"
cat > "$ISOLATED_PATH/mktemp" <<'MK'
#!/usr/bin/env bash
printf 'called\n' >> "$US150_MKTEMP_LOG"
exec "$US150_REAL_MKTEMP" "$@"
MK
chmod +x "$ISOLATED_PATH/mktemp"

for tool in node npm; do
  cat > "$ISOLATED_PATH/$tool" <<'STUB'
#!/bin/sh
printf 'unexpected offline-test invocation: %s\n' "$0" >&2
exit 97
STUB
  chmod +x "$ISOLATED_PATH/$tool"
done

status=0
PATH="$ISOLATED_PATH" \
  HOME="$TEST_HOME" \
  TMPDIR="$TEST_TMPDIR" \
  US150_MKTEMP_LOG="$MKTEMP_LOG" \
  US150_REAL_MKTEMP="$REAL_MKTEMP" \
  "$BUILD_SCRIPT" "$OUTPUT" >"$STDOUT_FILE" 2>"$STDERR_FILE" || status=$?

checks=0
failures=0
check() {
  label="$1"
  shift
  checks=$((checks + 1))
  if "$@"; then
    printf 'ok %s\n' "$label"
  else
    failures=$((failures + 1))
    printf 'not ok %s\n' "$label" >&2
  fi
}

check "exits non-zero" test "$status" -ne 0
check "diagnostic identifies missing tools" grep -Fq 'Missing required Cowork plugin build tools:' "$STDERR_FILE"
check "diagnostic names rsync" grep -Fq 'rsync' "$STDERR_FILE"
check "diagnostic names zip" grep -Fq 'zip' "$STDERR_FILE"
check "diagnostic explains how to install rsync" grep -Fq 'pacman -S rsync' "$STDERR_FILE"
check "diagnostic explains how to install zip" grep -Fq 'pacman -S zip' "$STDERR_FILE"

shopt -s nullglob dotglob
TMP_ENTRIES=("$TEST_TMPDIR"/*)
shopt -u nullglob dotglob
check "no staging output was created before the check" test ! -e "$MKTEMP_LOG"
check "requested plugin artifact was not written" test ! -e "$OUTPUT"
check "temporary build directory was not written" test "${#TMP_ENTRIES[@]}" -eq 0

if [ "$failures" -eq 0 ]; then
  printf 'PASS build-plugin prerequisites (%s/%s assertions)\n' "$checks" "$checks"
  exit 0
fi
printf 'FAIL build-plugin prerequisites (%s/%s assertions failed)\n' "$failures" "$checks" >&2
exit 1
