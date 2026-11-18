#!/usr/bin/env bash
# Regression (US-022, Windows): Windows file systems ignore letter case, so
# C:/hq/CORE/x and C:/HQ/core/x are the same file. block-core-writes.sh must
# block a protected write whose file_path and HQ root differ only in case, keep
# matching the bypass flag value exactly, and never let a failed 8.3 long-name
# lookup turn a protected write into an allowed one (only a path holding "~" is
# looked up, and a failed lookup refuses the write).
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
REAL_CYGPATH="$(command -v cygpath 2>/dev/null)" || skip "not Git Bash on Windows (no cygpath)"
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
UP="$(printf '%s' "$LONG" | tr '[:lower:]' '[:upper:]')"
LOW="$(printf '%s' "$LONG" | tr '[:upper:]' '[:lower:]')"
[ -d "$UP/core" ] || skip "this volume is case-sensitive"

gate() { # gate <project dir> <file path> [PATH prefix]
  printf '%s' "$2" | jq -Rs '{tool_input:{file_path:.}}' \
    | PATH="${3:+$3:}$PATH" CLAUDE_PROJECT_DIR="$1" bash "$HOOK" >/dev/null 2>&1 && echo 0 || echo $?
}
expect() { # expect <want> <project dir> <file path> <label> [PATH prefix]
  local got; got="$(gate "$2" "$3" "${5:-}")"
  [ "$got" = "$1" ] || fail "want exit $1 got $got for: $4 ($3, root $2)"
  pass "exit $1 :: $4"
}

echo '[1] case-only differences'
expect 2 "$LONG" "$LONG/CORE/scripts/anything.sh"     "CORE/ in file_path, root as created"
expect 2 "$LONG" "$LONG/Core/new-dir/new.md"          "Core/ with a new subfolder"
expect 2 "$LONG" "$LONG/.CLAUDE/hooks/zz.sh"          ".CLAUDE/ in file_path"
expect 2 "$UP"   "$LONG/core/scripts/anything.sh"     "upper-case root, file_path as created"
expect 2 "$LOW"  "$UP/CORE/scripts/anything.sh"       "lower-case root, upper-case file_path"
expect 2 "$LONG" "$LONG/core/scripts/anything.sh"     "same case (control)"
expect 0 "$UP"   "$LONG/personal/notes.md"            "personal/ stays allowed with a different-case root"
expect 0 "$LONG" "$LONG/.claude/SETTINGS.LOCAL.JSON"  "settings.local.json stays writable in any case"
expect 2 "$LONG" "$LONG/.claude/Settings.json"        ".claude/settings.json stays blocked in any case"

echo '[1b] the bypass flag value is still matched exactly'
printf '{"env":{"HQ_BYPASS_CORE_PROTECT":"TRUE"}}\n' > "$LONG/.claude/settings.local.json"
expect 2 "$LONG" "$LONG/core/scripts/anything.sh"     "bypass value TRUE does not unlock core/"
printf '{"env":{"HQ_BYPASS_CORE_PROTECT":"true"}}\n' > "$LONG/.claude/settings.local.json"
expect 0 "$LONG" "$LONG/CORE/scripts/anything.sh"     "bypass value true still works (control)"
rm -f "$LONG/.claude/settings.local.json"

echo '[2] a failed 8.3 lookup never turns a protected write into an allowed one'
FAKE="$BASE/fakebin"; mkdir -p "$FAKE"
cat > "$FAKE/cygpath" <<EOF
#!/usr/bin/env bash
# Fails the long-name lookup (-l) for any path under core/; everything else is real cygpath.
case " \$* " in *" -l "*) case "\$*" in */core*|*/CORE*) exit 1 ;; esac ;; esac
exec "$REAL_CYGPATH" "\$@"
EOF
chmod +x "$FAKE/cygpath"
expect 2 "$SHORT" "$SHORT/core/scripts/anything.sh" "8.3 file_path and 8.3 root, lookup fails for the file only" "$FAKE"
expect 2 "$SHORT" "$LONG/core/scripts/anything.sh"  "long file_path and 8.3 root, lookup would fail for the file" "$FAKE"
expect 2 "$LONG"  "$SHORT/core/scripts/anything.sh" "8.3 file_path and long root, lookup fails for the file" "$FAKE"
[ ! -e "$LONG/core/scripts/anything.sh" ] || fail "the probe wrote a file"
echo "ALL PASS: block-core-writes-case-windows"
