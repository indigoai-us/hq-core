#!/usr/bin/env bash
# hq-core: public
# Regression tests for core/scripts/hq-session.sh
#
# Guards the REPO_ROOT depth bug: the script lives in core/scripts/, so it must
# walk up TWO levels ("../..") to reach the HQ root. A regression to one level
# ("..") makes SESSIONS_DIR resolve to <root>/core/workspace/sessions, so
# .current is never found and `set` dies with "no current session".

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hq-session.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"
}

# Build a minimal HQ-shaped layout so the script's BASH_SOURCE-relative
# REPO_ROOT computation has something real to resolve against.
mkdir -p "$TMP/core/scripts" "$TMP/workspace/sessions"
cp "$SRC" "$TMP/core/scripts/hq-session.sh"
chmod +x "$TMP/core/scripts/hq-session.sh"
HS="$TMP/core/scripts/hq-session.sh"

# 1. No .current yet -> `current` prints empty, exits 0.
out="$("$HS" current)"
assert_eq "$out" "" "current with no session"

# 2. Seed a current session.
printf 'sess-1\n' > "$TMP/workspace/sessions/.current"
mkdir -p "$TMP/workspace/sessions/sess-1"

assert_eq "$("$HS" current)" "sess-1" "current id"

# 3. `path` must resolve under <root>/workspace/sessions, NOT <root>/core/...
#    This is the direct guard against the REPO_ROOT depth regression.
path_out="$("$HS" path)"
assert_eq "$path_out" "$TMP/workspace/sessions/sess-1/meta.yaml" "meta path"
case "$path_out" in
  "$TMP/core/"*) fail "REPO_ROOT resolved one level too shallow: $path_out" ;;
esac

# 4. set/get roundtrip (would error 'no current session' under the bug).
"$HS" set company acme
assert_eq "$("$HS" get company)" "acme" "get after set"

# 5. set replaces in place rather than duplicating.
"$HS" set company beta
assert_eq "$("$HS" get company)" "beta" "get after overwrite"
count="$(grep -c '^company:' "$path_out")"
assert_eq "$count" "1" "company key not duplicated"

echo "PASS: hq-session.sh ($(basename "$HS"))"
