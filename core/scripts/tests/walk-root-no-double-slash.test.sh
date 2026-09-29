#!/usr/bin/env bash
# Regression test: walk_up_to_hq_root must never form a "//" path.
# Covers the Windows MSYS2 SMB stall bug (see findings F-28, F-29).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Source only the function definitions from share-suggestion-state.sh (lines
# before main()) so we can override is_hq_root with a recording wrapper.
FUNCS_TMP="$TMP/funcs.sh"
MAIN_LINE="$(grep -n '^main()' "$ROOT/core/scripts/share-suggestion-state.sh" | head -1 | cut -d: -f1)"
head -n "$((MAIN_LINE - 1))" "$ROOT/core/scripts/share-suggestion-state.sh" > "$FUNCS_TMP"

# Track every path is_hq_root is called with.
_tested_paths=()
# shellcheck disable=SC1090
source "$FUNCS_TMP"
# Override is_hq_root to record every argument and still apply the real logic.
is_hq_root() {
  _tested_paths+=("${1:-}")
  [ -n "${1:-}" ] && [ -d "${1%/}/core" ] && [ -d "${1%/}/.claude" ]
}

assert_no_double_slash() {
  local label="$1"
  for p in "${_tested_paths[@]+"${_tested_paths[@]}"}"; do
    case "$p" in
      //*) fail "$label: double-slash path tested: '$p'" ;;
    esac
  done
}

# --- 1. Walk from /tmp (outside any HQ root) produces no "//" paths ---
_tested_paths=()
walk_up_to_hq_root "/tmp" && fail "walk from /tmp should not find a root" || true
assert_no_double_slash "walk from /tmp"
echo "PASS: walk from /tmp - no double-slash paths formed"

# --- 2. Walk finds root from a deeply nested subfolder ---
FAKE_HQ="$TMP/fake-hq"
NESTED="$FAKE_HQ/companies/acme/projects/demo"
mkdir -p "$NESTED" "$FAKE_HQ/core" "$FAKE_HQ/.claude"

_tested_paths=()
found="$(walk_up_to_hq_root "$NESTED")" || fail "walk from nested subfolder should find root"
[ "$found" = "$FAKE_HQ" ] || fail "wrong root from nested subfolder: got '$found', expected '$FAKE_HQ'"
assert_no_double_slash "walk from nested subfolder"
echo "PASS: walk from nested subfolder finds root correctly"

# --- 3. Walk finds root when started from the root directory itself ---
_tested_paths=()
found="$(walk_up_to_hq_root "$FAKE_HQ")" || fail "walk from root dir should find root"
[ "$found" = "$FAKE_HQ" ] || fail "wrong root from root dir: got '$found'"
assert_no_double_slash "walk from root dir"
echo "PASS: walk from root dir finds root correctly"

# --- 4. CLAUDE_PROJECT_DIR short-circuits the walk ---
_tested_paths=()
found="$(CLAUDE_PROJECT_DIR="$FAKE_HQ" resolve_hq_root)" || fail "resolve_hq_root with CLAUDE_PROJECT_DIR should succeed"
[ "$found" = "$FAKE_HQ" ] || fail "wrong root via CLAUDE_PROJECT_DIR: '$found'"
assert_no_double_slash "CLAUDE_PROJECT_DIR short-circuit"
echo "PASS: CLAUDE_PROJECT_DIR short-circuits walk with no double-slash paths"

# --- 5. resolve_hq_root finds root from a nested subfolder ---
_tested_paths=()
found="$(cd "$NESTED" && CLAUDE_PROJECT_DIR="" resolve_hq_root)" || fail "resolve_hq_root should find root from nested subfolder via PWD"
[ "$found" = "$FAKE_HQ" ] || fail "wrong root via PWD walk: '$found'"
assert_no_double_slash "resolve from nested subfolder via PWD"
echo "PASS: resolve_hq_root finds root from nested subfolder via PWD"

# --- 6. resolve_hq_root fails cleanly from outside any HQ root ---
_tested_paths=()
out="$(cd /tmp && CLAUDE_PROJECT_DIR="" resolve_hq_root 2>/dev/null)" \
  && fail "resolve_hq_root should fail outside any HQ root (got: '$out')" || true
assert_no_double_slash "resolve from outside HQ root"
echo "PASS: resolve_hq_root fails cleanly outside HQ with no double-slash paths"

echo "walk-root-no-double-slash: ok"
