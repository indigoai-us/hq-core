#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CHECKER="$ROOT/core/scripts/check-deleted-script-refs.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/deleted-script-refs.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# The repository's initially empty list allows the current tree.
bash "$CHECKER" --root "$ROOT" || fail 'empty deleted-script list rejected the repository'

# A tracked caller to a listed path must fail and identify the caller.
FIXTURE="$TMP/repo"
mkdir -p "$FIXTURE/core/scripts" "$FIXTURE/tools"
git -c init.defaultBranch=main init -q "$FIXTURE"
printf '%s\n' 'core/scripts/retired-example.sh' > "$FIXTURE/core/scripts/deleted-script-paths.txt"
printf '%s\n' 'exec "$ROOT/core/scripts/retired-example.sh"' > "$FIXTURE/tools/caller.sh"
git -C "$FIXTURE" add core/scripts/deleted-script-paths.txt tools/caller.sh

if OUTPUT="$(bash "$CHECKER" --root "$FIXTURE" 2>&1)"; then
  fail 'tracked reference to a deleted script unexpectedly passed'
fi
case "$OUTPUT" in
  *'tracked files still reference deleted script path: core/scripts/retired-example.sh'*'tools/caller.sh'*) ;;
  *) fail "guard failure did not identify the deleted path and caller: $OUTPUT" ;;
esac

# A caller may resolve a script beside itself and mention only the basename.
git -C "$FIXTURE" rm -q -f tools/caller.sh
mkdir -p "$FIXTURE/tools"
printf '%s\n' 'exec "$SCRIPT_DIR/retired-example.sh"' > "$FIXTURE/tools/relative-caller.sh"
git -C "$FIXTURE" add tools/relative-caller.sh
if OUTPUT="$(bash "$CHECKER" --root "$FIXTURE" 2>&1)"; then
  fail 'tracked relative reference to a deleted script unexpectedly passed'
fi
case "$OUTPUT" in
  *'tracked files still reference deleted script path: core/scripts/retired-example.sh'*'tools/relative-caller.sh'*) ;;
  *) fail "guard failure did not identify the relative caller: $OUTPUT" ;;
esac

# A listed script that remains indexed must fail without a caller reference.
git -C "$FIXTURE" rm -q -f tools/relative-caller.sh
printf '%s\n' 'echo synthetic' > "$FIXTURE/core/scripts/retired-example.sh"
git -C "$FIXTURE" add core/scripts/retired-example.sh
if OUTPUT="$(bash "$CHECKER" --root "$FIXTURE" 2>&1)"; then
  fail 'listed script that remains tracked unexpectedly passed'
fi
case "$OUTPUT" in
  *'listed script still exists in worktree or index: core/scripts/retired-example.sh'*) ;;
  *) fail "guard failure did not identify the still-tracked script: $OUTPUT" ;;
esac

# An untracked worktree copy must fail even though it is absent from the index.
printf '%s\n' 'core/scripts/retired-untracked.sh' > "$FIXTURE/core/scripts/deleted-script-paths.txt"
printf '%s\n' 'echo synthetic' > "$FIXTURE/core/scripts/retired-untracked.sh"
if OUTPUT="$(bash "$CHECKER" --root "$FIXTURE" 2>&1)"; then
  fail 'listed script that remains untracked in the worktree unexpectedly passed'
fi
case "$OUTPUT" in
  *'listed script still exists in worktree or index: core/scripts/retired-untracked.sh'*) ;;
  *) fail "guard failure did not identify the still-present worktree script: $OUTPUT" ;;
esac

printf 'PASS: deleted-script reference guard catches callers and still-present scripts\n'
