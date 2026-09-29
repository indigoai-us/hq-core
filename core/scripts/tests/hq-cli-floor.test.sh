#!/usr/bin/env bash
# Regression coverage for the portable hq-cli floor reader, comparator, cache,
# and check-hq-hooks missing/old CLI diagnostics.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
LIB="$ROOT/core/scripts/lib/hq-cli-floor.sh"
CHECKER="$ROOT/core/scripts/check-hq-hooks.sh"
SCAN_LIB="$ROOT/core/scripts/lib/hook-command-scan.sh"
TMP="$(mktemp -d)"
cleanup() {
  chmod -R u+w "$TMP" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT
. "$LIB"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2'"; }
assert_equal() { [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"; }

make_cli() {
  local package_root="$1"
  mkdir -p "$package_root/bin" "$package_root/path"
  cat > "$package_root/package.json" <<'JSON'
{"name":"@indigoai-us/hq-cli","version":"5.269.0"}
JSON
  cat > "$package_root/bin/hq" <<'HQ'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf 'call\n' >> "$HQ_STUB_CALLS"
  printf 'hq %s\n' "$HQ_STUB_VERSION"
elif [ "${1:-}" = "doctor" ]; then
  printf '{"schemaVersion":"hq-doctor.v1","results":[]}\n'
fi
HQ
  chmod +x "$package_root/bin/hq"
  ln -s "$package_root/bin/hq" "$package_root/path/hq"
}

call_count() {
  if [ ! -f "$1" ]; then printf '0'; else wc -l < "$1" | tr -d '[:space:]'; fi
}

capture_floor() {
  FLOOR_OUTPUT=""
  FLOOR_RC=0
  set +e
  FLOOR_OUTPUT="$(hq_cli_floor_check "$1" "$2" 2>&1)"
  FLOOR_RC=$?
  set -e
}

# The file reader handles a quoted top-level value and an inline comment without yq.
mkdir -p "$TMP/root/core"
printf 'requiresHqCli: ">=5.269.0" # scaffold floor\n' > "$TMP/root/core/core.yaml"
required="$(hq_cli_floor_required "$TMP/root")" || fail "floor reader rejected a valid core.yaml"
assert_equal "$required" ">=5.269.0" "floor reader"
printf 'hqVersion: "15.0.0"\n' > "$TMP/root/core/core.yaml"
if hq_cli_floor_required "$TMP/root" >/dev/null; then
  fail "floor reader must report an absent key"
fi

# Current, old, missing, malformed, and prerelease comparisons.
make_cli "$TMP/current"
PATH="$TMP/current/path:/usr/bin:/bin"
export PATH
HQ_STUB_VERSION="5.269.0"
HQ_STUB_CALLS="$TMP/current-calls"
XDG_CACHE_HOME="$TMP/current-cache"
export HQ_STUB_VERSION HQ_STUB_CALLS XDG_CACHE_HOME
: > "$HQ_STUB_CALLS"
capture_floor "floor-test.sh" "$required"
assert_equal "$FLOOR_RC" "0" "current CLI floor"
assert_equal "$(call_count "$HQ_STUB_CALLS")" "1" "first version probe"
capture_floor "floor-test.sh" "$required"
assert_equal "$FLOOR_RC" "0" "cached current CLI floor"
assert_equal "$(call_count "$HQ_STUB_CALLS")" "1" "cache hit must not spawn hq"

if hq_cli_version_ge "5.270.0-beta.1" "5.270.0"; then
  fail "prerelease must compare below its release"
else
  compare_rc=$?
  assert_equal "$compare_rc" "1" "prerelease comparison"
fi
hq_cli_version_ge "5.270.0-beta.1" "5.269.0" || fail "newer prerelease should satisfy an older floor"
hq_cli_version_ge "5.270.0" "5.269.99" || fail "newer minor version should satisfy numeric floor"

HQ_STUB_VERSION="5.268.9"
XDG_CACHE_HOME="$TMP/old-cache"
export HQ_STUB_VERSION XDG_CACHE_HOME
capture_floor "floor-test.sh" "$required"
assert_equal "$FLOOR_RC" "127" "old CLI floor"
assert_contains "$FLOOR_OUTPUT" 'floor-test.sh: this script needs hq-cli >= 5.269.0 (found 5.268.9)' "old CLI message"
assert_contains "$FLOOR_OUTPUT" 'npm install -g @indigoai-us/hq-cli@latest' "old CLI upgrade command"

mkdir -p "$TMP/no-hq"
PATH="$TMP/no-hq:/usr/bin:/bin"
export PATH
capture_floor "floor-test.sh" "$required"
assert_equal "$FLOOR_RC" "127" "missing CLI floor"
assert_contains "$FLOOR_OUTPUT" "floor-test.sh: requires the hq CLI — this script's implementation now ships with it." "missing CLI message"
assert_contains "$FLOOR_OUTPUT" 'Install it with: npm install -g @indigoai-us/hq-cli' "missing CLI install command"

PATH="$TMP/current/path:/usr/bin:/bin"
export PATH
capture_floor "floor-test.sh" '>=5.269'
assert_equal "$FLOOR_RC" "64" "malformed floor value"
assert_contains "$FLOOR_OUTPUT" '>=5.269' "malformed floor message"

# A malformed YAML sequence at the floor key is rejected as one checker issue.
mkdir -p "$TMP/hooks-malformed/core"
printf 'requiresHqCli: [unterminated\n' > "$TMP/hooks-malformed/core/core.yaml"
required="$(hq_cli_floor_required "$TMP/hooks-malformed")" || fail "malformed floor reader status"
capture_floor "floor-test.sh" "$required"
assert_equal "$FLOOR_RC" "64" "malformed core.yaml floor"
assert_contains "$FLOOR_OUTPUT" 'unsupported value [unterminated' "malformed core.yaml floor message"

# A cache hit avoids the hq process, while changes to either keyed file invalidate it.
for change in executable-mtime executable-size package-mtime package-size package-content-same-metadata; do
  package_root="$TMP/$change"
  calls="$TMP/$change-calls"
  make_cli "$package_root"
  : > "$calls"
  HQ_STUB_CALLS="$calls"
  HQ_STUB_VERSION="5.269.0"
  XDG_CACHE_HOME="$TMP/$change-cache"
  export HQ_STUB_CALLS HQ_STUB_VERSION XDG_CACHE_HOME
  touch -t 202001010000 "$package_root/bin/hq" "$package_root/package.json"
  PATH="$package_root/path:/usr/bin:/bin"
  export PATH
  capture_floor "cache-test.sh" "5.269.0"
  assert_equal "$FLOOR_RC" "0" "$change initial probe"
  assert_equal "$(call_count "$calls")" "1" "$change initial call count"

  case "$change" in
    executable-mtime)
      before_size="$(wc -c < "$package_root/bin/hq" | tr -d '[:space:]')"
      touch -t 202001010001 "$package_root/bin/hq"
      after_size="$(wc -c < "$package_root/bin/hq" | tr -d '[:space:]')"
      assert_equal "$after_size" "$before_size" "mtime-only executable update size"
      ;;
    executable-size)
      printf '\n# changed size\n' >> "$package_root/bin/hq"
      touch -t 202001010000 "$package_root/bin/hq"
      ;;
    package-mtime)
      before_size="$(wc -c < "$package_root/package.json" | tr -d '[:space:]')"
      touch -t 202001010001 "$package_root/package.json"
      after_size="$(wc -c < "$package_root/package.json" | tr -d '[:space:]')"
      assert_equal "$after_size" "$before_size" "mtime-only package update size"
      ;;
    package-size)
      printf ' ' >> "$package_root/package.json"
      touch -t 202001010000 "$package_root/package.json"
      ;;
    package-content-same-metadata)
      before_size="$(wc -c < "$package_root/package.json" | tr -d '[:space:]')"
      before_state="$( _hq_cli_floor_file_state "$package_root/package.json" )"
      sed 's/"version":"5.269.0"/"version":"5.270.0"/' "$package_root/package.json" > "$package_root/package.updated.json"
      mv "$package_root/package.updated.json" "$package_root/package.json"
      touch -t 202001010000 "$package_root/package.json"
      after_size="$(wc -c < "$package_root/package.json" | tr -d '[:space:]')"
      after_state="$( _hq_cli_floor_file_state "$package_root/package.json" )"
      assert_equal "$after_size" "$before_size" "content-only package update size"
      assert_equal "$after_state" "$before_state" "content-only package update file state"
      ;;
  esac
  capture_floor "cache-test.sh" "5.269.0"
  assert_equal "$FLOOR_RC" "0" "$change invalidated probe"
  assert_equal "$(call_count "$calls")" "2" "$change invalidation call count"
done

# If the configured cache home is a file, each call falls back to hq for any user.
package_root="$TMP/unwritable"
make_cli "$package_root"
unwritable_cache_home="$TMP/unwritable-cache-home"
printf 'not a directory\n' > "$unwritable_cache_home"
[ -f "$unwritable_cache_home" ] || fail "cache-home fixture is not a regular file"
: > "$TMP/unwritable-calls"
HQ_STUB_CALLS="$TMP/unwritable-calls"
HQ_STUB_VERSION="5.269.0"
XDG_CACHE_HOME="$unwritable_cache_home"
PATH="$package_root/path:/usr/bin:/bin"
export HQ_STUB_CALLS HQ_STUB_VERSION XDG_CACHE_HOME PATH
capture_floor "cache-test.sh" "5.269.0"
assert_equal "$FLOOR_RC" "0" "cache directory unavailable result"
capture_floor "cache-test.sh" "5.269.0"
assert_equal "$FLOOR_RC" "0" "cache directory unavailable retry"
assert_equal "$(call_count "$HQ_STUB_CALLS")" "2" "unavailable cache must probe hq each time"

make_hook_root() {
  local root="$1"
  mkdir -p "$root/core/scripts/lib" "$root/.claude"
  cp "$CHECKER" "$root/core/scripts/check-hq-hooks.sh"
  cp "$LIB" "$root/core/scripts/lib/hq-cli-floor.sh"
  cp "$SCAN_LIB" "$root/core/scripts/lib/hook-command-scan.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$root/core/scripts/setup.sh"
  chmod +x "$root/core/scripts/check-hq-hooks.sh" "$root/core/scripts/setup.sh"
  printf 'requiresHqCli: ">=5.269.0"\n' > "$root/core/core.yaml"
  cat > "$root/.claude/settings.json" <<'JSON'
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/core/scripts/setup.sh\""}]}],"PreToolUse":[{"hooks":[{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/core/scripts/setup.sh\""}]}]}}
JSON
}

run_checker() {
  local root="$1" expected_rc="$2" output rc
  set +e
  output="$(bash "$root/core/scripts/check-hq-hooks.sh" --root "$root" 2>&1)"
  rc=$?
  set -e
  assert_equal "$rc" "$expected_rc" "check-hq-hooks exit"
  CHECKER_OUTPUT="$output"
}

hook_root="$TMP/hooks-current"
make_hook_root "$hook_root"
make_cli "$TMP/hooks-cli"
PATH="$TMP/hooks-cli/path:/usr/bin:/bin"
HQ_STUB_CALLS="$TMP/hooks-current-calls"
HQ_STUB_VERSION="5.269.0"
XDG_CACHE_HOME="$TMP/hooks-current-cache"
export PATH HQ_STUB_CALLS HQ_STUB_VERSION XDG_CACHE_HOME
run_checker "$hook_root" 0
assert_contains "$CHECKER_OUTPUT" 'HQ hook health: PASS' "current CLI hook check"

hook_root="$TMP/hooks-old"
make_hook_root "$hook_root"
make_cli "$TMP/hooks-old-cli"
PATH="$TMP/hooks-old-cli/path:/usr/bin:/bin"
HQ_STUB_CALLS="$TMP/hooks-old-calls"
HQ_STUB_VERSION="5.268.9"
XDG_CACHE_HOME="$TMP/hooks-old-cache"
export PATH HQ_STUB_CALLS HQ_STUB_VERSION XDG_CACHE_HOME
run_checker "$hook_root" 2
assert_contains "$CHECKER_OUTPUT" '  - check-hq-hooks.sh: this script needs hq-cli >= 5.269.0 (found 5.268.9)' "old CLI hook issue"
floor_line_count="$(printf '%s\n' "$CHECKER_OUTPUT" | grep -cF 'check-hq-hooks.sh: this script needs')"
assert_equal "$floor_line_count" "1" "old CLI hook issue count"

hook_root="$TMP/hooks-missing"
make_hook_root "$hook_root"
PATH="$TMP/no-hq:/usr/bin:/bin"
export PATH
run_checker "$hook_root" 2
assert_contains "$CHECKER_OUTPUT" "  - check-hq-hooks.sh: requires the hq CLI — this script's implementation now ships with it." "missing CLI hook issue"
assert_contains "$CHECKER_OUTPUT" 'Install it with: npm install -g @indigoai-us/hq-cli' "missing CLI hook install command"
floor_line_count="$(printf '%s\n' "$CHECKER_OUTPUT" | grep -cF 'check-hq-hooks.sh: requires the hq CLI')"
assert_equal "$floor_line_count" "1" "missing CLI hook issue count"

printf 'PASS: hq-cli-floor (reader, SemVer, cache key/invalidation, fallback, checker floor)\n'
