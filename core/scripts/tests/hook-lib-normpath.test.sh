#!/usr/bin/env bash
# Differential regression coverage for hq_normpath's lexical path contract.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
LIB="$ROOT/core/scripts/hook-lib.sh"
[ -f "$LIB" ] || { echo "FAIL: hook-lib.sh missing at $LIB" >&2; exit 1; }

# shellcheck source=core/scripts/hook-lib.sh
. "$LIB"

# This is a verbatim copy of hq_normpath's pre-refactor awk implementation.
# Keep it independent from the implementation under test so it is the oracle
# for this contract-preserving refactor.
normpath_awk_reference() {
  printf '%s' "$1" | awk -v winsep="${HQ_LIB_WINSEP:-0}" '
    {
      p = $0
      if (winsep) gsub(/\\/, "/", p)
      isabs = (p ~ /^\//) ? 1 : 0
      drive = ""
      if (p ~ /^[A-Za-z]:/) { drive = substr(p, 1, 2); p = substr(p, 3); isabs = (p ~ /^\//) ? 1 : 0 }
      root = ""
      if (isabs) root = (winsep && p ~ /^\/\/([^\/]|$)/) ? "//" : "/"
      n = split(p, seg, "/")
      out_n = 0
      for (i = 1; i <= n; i++) {
        s = seg[i]
        if (s == "" || s == ".") continue
        if (s == "..") {
          if (out_n > 0 && out[out_n] != "..") { out_n--; continue }
          if (isabs) continue
          out[++out_n] = ".."
        } else out[++out_n] = s
      }
      r = ""
      for (i = 1; i <= out_n; i++) r = r (i > 1 ? "/" : "") out[i]
      if (isabs) r = root r
      if (drive != "") r = drive r
      if (r == "") r = (isabs ? root : ".")
      print r
    }'
}

PASS=0
FAIL=0
pass() { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hook-lib-normpath.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
CASE_NUMBER=0

assert_same() {
  local label="$1" input="$2" winsep actual reference
  CASE_NUMBER=$((CASE_NUMBER + 1))
  for winsep in 0 1; do
    actual="$TMP/$CASE_NUMBER.$winsep.actual"
    reference="$TMP/$CASE_NUMBER.$winsep.reference"
    HQ_LIB_WINSEP="$winsep" hq_normpath "$input" > "$actual"
    HQ_LIB_WINSEP="$winsep" normpath_awk_reference "$input" > "$reference"
    if cmp -s "$actual" "$reference"; then
      pass "$label (winsep=$winsep)"
    else
      printf '  FAIL %s (winsep=%s): byte output differs\n' \
        "$label" "$winsep" >&2
      FAIL=$((FAIL + 1))
    fi
  done
}

# The production implementation must remain a shell-only hot-path primitive.
FUNCTION_SOURCE="$(declare -f hq_normpath)"
case "$FUNCTION_SOURCE" in
  *awk*|*'$('*) fail 'hq_normpath is not fork-free' ;;
  *) pass 'hq_normpath body is fork-free' ;;
esac

newline_path='line
feed'

assert_same 'empty string' ''
assert_same 'dot' '.'
assert_same 'dot dot' '..'
assert_same 'root slash' '/'
assert_same 'two leading slashes' '//'
assert_same 'three leading slashes' '///'
assert_same 'four leading slashes' '////'
assert_same 'absolute path' '/a/b'
assert_same 'relative path' 'a/b'
assert_same 'leading dot' './a'
assert_same 'trailing dot segment' 'a/.'
assert_same 'interior dot segment' 'a/./b'
assert_same 'interior double slash' 'a//b'
assert_same 'trailing separator' 'a/b/'
assert_same 'multiple trailing separators' 'a/b//'
assert_same 'absolute dot dot at root' '/..'
assert_same 'absolute repeated dot dot at root' '/../..'
assert_same 'absolute parent past root' '/a/../..'
assert_same 'relative parent past root' 'a/../..'
assert_same 'relative parent prefix' '../a'
assert_same 'relative repeated parent' 'a/../../b'
assert_same 'leading whitespace segment' ' leading/a'
assert_same 'trailing whitespace segment' 'a/trailing '
assert_same 'literal ellipsis segment' 'a/.../b'
assert_same 'POSIX backslash stays literal' 'a\b'
assert_same 'backslash inside absolute path' '/a/b\c'
assert_same 'symlink-shaped POSIX backslash path' 'link\name/file.txt'
assert_same 'Windows UNC root stays distinct' '//server/share'
assert_same 'Windows UNC parent resolution' '//server/share/../x'
assert_same 'drive prefix only' 'C:'
assert_same 'drive absolute root' 'C:/'
assert_same 'drive parent resolution' 'C:/a/../b'
assert_same 'lowercase drive relative path' 'c:a/b'
assert_same 'space in path' 'a path/with space'
assert_same 'single quote in path' "a'quote/b"
assert_same 'dollar in path' 'price$tag/file'
assert_same 'newline in path' "$newline_path"
assert_same 'production HQ root' '/home/ec2-user/hq'
assert_same 'production CLAUDE.md path' '/home/ec2-user/hq/.claude/CLAUDE.md'
assert_same 'production core path' '/home/ec2-user/hq/core'
assert_same 'production company template path' '/home/ec2-user/hq/companies/_template'

printf 'hook-lib-normpath: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
