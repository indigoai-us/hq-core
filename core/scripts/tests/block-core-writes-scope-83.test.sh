#!/usr/bin/env bash
# Regression (US-022, Windows): a plain write to a protected path must stay
# blocked when file_path and CLAUDE_PROJECT_DIR spell the same folder
# differently, one with its long name and one with its 8.3 short name
# (C:/Users/runneradmin/... versus C:/Users/RUNNER~1/...). Before the fix,
# block-core-writes.sh compared the two spellings as plain strings, decided the
# file was outside the HQ root, and allowed the write (exit 0).
#
# Windows only: it needs Git Bash's cygpath and a folder with a distinct 8.3
# name. Elsewhere, and where that is missing on a developer machine, it says
# why and exits 0; on a Windows CI runner a missing precondition fails the test.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
HOOK_SRC="$ROOT/.claude/hooks/block-core-writes.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }
skip() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) [ -z "${CI:-}${GITHUB_ACTIONS:-}" ] || fail "would skip on a Windows CI runner: $*" ;;
  esac
  echo "SKIP: $*"; exit 0
}
command -v cygpath >/dev/null 2>&1 || skip "not Git Bash on Windows (no cygpath)"
command -v jq >/dev/null 2>&1 || fail "jq is required on the Windows runner"
[ -f "$HOOK_SRC" ] || fail "hook not found: $HOOK_SRC"

BASE="$(mktemp -d)"; trap 'rm -rf "$BASE"' EXIT
LONG="$(cygpath -m -l "$BASE")/hq root long name"
mkdir -p "$LONG/core/scripts" "$LONG/.claude/hooks" "$LONG/personal"
SHORT="$(cygpath -m -s "$LONG")"
[ "$SHORT" != "$LONG" ] || skip "this volume makes no 8.3 names ($LONG)"
cp "$ROOT/core/scripts/hook-lib.sh" "$LONG/core/scripts/hook-lib.sh"
cp "$HOOK_SRC" "$LONG/.claude/hooks/block-core-writes.sh"
HOOK="$LONG/.claude/hooks/block-core-writes.sh"

gate() { # gate <project dir> <file path>
  printf '%s' "$2" | jq -Rs '{tool_input:{file_path:.}}' \
    | CLAUDE_PROJECT_DIR="$1" bash "$HOOK" >/dev/null 2>&1 && echo 0 || echo $?
}
expect() { # expect <want> <project dir> <file path> <label>
  local got; got="$(gate "$2" "$3")"
  [ "$got" = "$1" ] || fail "want exit $1 got $got for: $4 ($3, root $2)"
  pass "exit $1 :: $4"
}

for rel in core/scripts/anything.sh .claude/hooks/zz.sh core/new-dir/new-file.md; do
  expect 2 "$SHORT" "$LONG/$rel"  "$rel: long file path, 8.3 root"
  expect 2 "$LONG"  "$SHORT/$rel" "$rel: 8.3 file path, long root"
  expect 2 "$LONG"  "$LONG/$rel"  "$rel: long and long (control)"
  expect 2 "$SHORT" "$SHORT/$rel" "$rel: 8.3 and 8.3 (control)"
done
expect 0 "$SHORT" "$LONG/personal/notes.md"  "personal/ write stays allowed, long file path, 8.3 root"
expect 0 "$LONG"  "$SHORT/personal/notes.md" "personal/ write stays allowed, 8.3 file path, long root"
[ ! -e "$LONG/core/scripts/anything.sh" ] || fail "the probe wrote a file"
echo "ALL PASS: block-core-writes-scope-83"
