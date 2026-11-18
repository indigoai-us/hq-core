#!/usr/bin/env bash
# Regression (US-022, Windows): a package contribution link whose stored target
# is ABSOLUTE must stay blocked when the link target and the HQ root spell the
# same folder differently: one with its long name, the other with its 8.3 short
# name (C:\Users\RUNNER~1\... versus C:\Users\runneradmin\...). Before the fix,
# block-core-writes.sh compared the two spellings as plain strings, decided the
# link left core/, and allowed the write (exit 0) into immutable pack content.
# Found on a GitHub-hosted windows-latest runner (hq-cli run 43994917032).
#
# Windows only: it needs Git Bash's cygpath, a folder with a distinct 8.3 name,
# and native symlinks (Developer Mode or the symlink privilege). Elsewhere, and
# where those are missing on a developer machine, it says why and exits 0; on a
# Windows CI runner a missing precondition fails the test.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
HOOK_SRC="$ROOT/.claude/hooks/block-core-writes.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }
# A skip is honest off Windows. On a Windows CI runner (CI or GITHUB_ACTIONS set)
# every precondition must hold, so a skip there is a failure.
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
# A folder name with spaces gets a distinct 8.3 name on volumes that make them.
PROJ_LONG="$(cygpath -m -l "$BASE")/hq root long name"
mkdir -p "$PROJ_LONG"
PROJ_SHORT="$(cygpath -m -s "$PROJ_LONG")"
[ "$PROJ_SHORT" != "$PROJ_LONG" ] || skip "this volume makes no 8.3 names ($PROJ_LONG)"

mkdir -p "$PROJ_LONG/core/scripts" "$PROJ_LONG/.claude/hooks" "$PROJ_LONG/core/knowledge/public" \
         "$PROJ_LONG/personal/knowledge/mine"
cp "$ROOT/core/scripts/hook-lib.sh" "$PROJ_LONG/core/scripts/hook-lib.sh"
cp "$HOOK_SRC" "$PROJ_LONG/.claude/hooks/block-core-writes.sh"
HOOK="$PROJ_LONG/.claude/hooks/block-core-writes.sh"

pack() { # pack <name>: a package knowledge folder with one file
  mkdir -p "$PROJ_LONG/core/packages/hq-pack-$1/knowledge/$1"
  printf 'packs: []\n' > "$PROJ_LONG/core/packages/hq-pack-$1/knowledge/$1/registry.yaml"
}
link() { # link <absolute target> <link path>, a native symlink
  MSYS=winsymlinks:nativestrict ln -s "$1" "$2" 2>/dev/null
}
pack longt; pack shortt
link "$PROJ_LONG/core/packages/hq-pack-longt/knowledge/longt" "$PROJ_LONG/core/knowledge/public/longt" \
  || skip "native symlinks are not available to this user"
link "$PROJ_SHORT/core/packages/hq-pack-shortt/knowledge/shortt" "$PROJ_LONG/core/knowledge/public/shortt" \
  || fail "second native link could not be made"
# A link out of core/ (to personal/), absolute and long, must stay allowed.
link "$PROJ_LONG/personal/knowledge/mine" "$PROJ_LONG/core/knowledge/public/mine" \
  || fail "personal link could not be made"
[ -f "$PROJ_SHORT/core/knowledge/public/longt/registry.yaml" ] \
  || skip "native links exist but cannot be followed here"

gate() { # gate <project dir> <file path>
  printf '%s' "$2" | jq -Rs '{tool_input:{file_path:.}}' \
    | CLAUDE_PROJECT_DIR="$1" bash "$HOOK" >/dev/null 2>&1 && echo 0 || echo $?
}
expect() { # expect <want> <project dir> <file path> <label>
  local got; got="$(gate "$2" "$3")"
  [ "$got" = "$1" ] || fail "want exit $1 got $got for: $4 ($3, root $2)"
  pass "exit $1 :: $4"
}

expect 2 "$PROJ_LONG"  "$PROJ_LONG/core/knowledge/public/longt/registry.yaml"   "long target, long root (control)"
expect 2 "$PROJ_SHORT" "$PROJ_SHORT/core/knowledge/public/longt/registry.yaml"  "long target, root reached by its 8.3 name"
expect 2 "$PROJ_LONG"  "$PROJ_LONG/core/knowledge/public/shortt/registry.yaml"  "8.3 target, long root"
expect 2 "$PROJ_SHORT" "$PROJ_SHORT/core/knowledge/public/shortt/registry.yaml" "8.3 target, 8.3 root (control)"
expect 0 "$PROJ_SHORT" "$PROJ_SHORT/core/knowledge/public/mine/notes.md"        "absolute link out of core/ stays allowed with an 8.3 root"
expect 2 "$PROJ_SHORT" "$PROJ_SHORT/core/scripts/anything.sh"                   "plain core/ write, 8.3 root"
for n in longt shortt; do
  [ "$(cat "$PROJ_LONG/core/packages/hq-pack-$n/knowledge/$n/registry.yaml")" = 'packs: []' ] || fail "$n registry.yaml changed"
done
echo "ALL PASS: block-core-writes-package-mount-83"
