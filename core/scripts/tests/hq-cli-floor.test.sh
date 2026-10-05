#!/usr/bin/env bash
# Regression coverage for the portable hq-cli floor reader, comparator, cache,
# and check-hq-hooks missing/old CLI diagnostics.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
LIB="$ROOT/core/scripts/lib/hq-cli-floor.sh"
CHECKER="$ROOT/core/scripts/check-hq-hooks.sh"
SCAN_LIB="$ROOT/core/scripts/lib/hook-command-scan.sh"
TMP="$(mktemp -d)"
JQ_COMMAND="$(command -v jq 2>/dev/null || command -v jq.exe 2>/dev/null || true)"
JQ_BIN_DIR="${JQ_COMMAND%/*}"
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
assert_equal "$(call_count "$HQ_STUB_CALLS")" "0" "package metadata avoids a second CLI process"
capture_floor "floor-test.sh" "$required"
assert_equal "$FLOOR_RC" "0" "repeated current CLI floor"
assert_equal "$(call_count "$HQ_STUB_CALLS")" "0" "repeated package lookup must not spawn hq"
cache_file="$XDG_CACHE_HOME/hq-cli-floor/version"
{
  IFS= read -r cache_schema || fail "cache schema missing"
  IFS= read -r cache_command || fail "cache command missing"
  IFS= read -r cache_target || fail "cache target missing"
  IFS= read -r cache_package || fail "cache package path missing"
} < "$cache_file"
{
  printf '%s\n%s\n%s\n%s\nnot-semver\n' \
    "$cache_schema" "$cache_command" "$cache_target" "$cache_package"
} > "$cache_file"
capture_floor "floor-test.sh" "$required"
assert_equal "$FLOOR_RC" "0" "invalid cached version re-reads the installed package"
assert_equal "$(call_count "$HQ_STUB_CALLS")" "0" "invalid cache verification does not start hq"

# The package reader uses the top-level version when a nested field repeats the key.
package_root="$TMP/nested-version"
make_cli "$package_root"
printf '{"name":"@indigoai-us/hq-cli","version":"5.269.0","scripts":{"version":"99.0.0"}}\n' > "$package_root/package.json"
PATH="$package_root/path:/usr/bin:/bin"
XDG_CACHE_HOME="$TMP/nested-version-home"
export PATH XDG_CACHE_HOME
capture_floor "nested-version.sh" "5.269.0"
assert_equal "$FLOOR_RC" "0" "nested package version does not override top-level version"

if hq_cli_version_ge "5.270.0-beta.1" "5.270.0"; then
  fail "prerelease must compare below its release"
else
  compare_rc=$?
  assert_equal "$compare_rc" "1" "prerelease comparison"
fi
hq_cli_version_ge "5.270.0-beta.1" "5.269.0" || fail "newer prerelease should satisfy an older floor"
hq_cli_version_ge "5.270.0" "5.269.99" || fail "newer minor version should satisfy numeric floor"

PATH="$TMP/current/path:/usr/bin:/bin"
export PATH
HQ_STUB_VERSION="5.268.9"
sed 's/5.269.0/5.268.9/' "$TMP/current/package.json" > "$TMP/current/package.updated.json"
mv "$TMP/current/package.updated.json" "$TMP/current/package.json"
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

# A cold lookup reads the installed package version without starting hq.
package_root="$TMP/package-version-change"
calls="$TMP/package-version-change-calls"
make_cli "$package_root"
: > "$calls"
HQ_STUB_CALLS="$calls"
HQ_STUB_VERSION="5.270.0"
XDG_CACHE_HOME="$TMP/package-version-change-cache"
PATH="$package_root/path:/usr/bin:/bin"
export HQ_STUB_CALLS HQ_STUB_VERSION XDG_CACHE_HOME PATH
sed 's/5.269.0/5.270.0/' "$package_root/package.json" > "$package_root/package.updated.json"
mv "$package_root/package.updated.json" "$package_root/package.json"
capture_floor "package-version-test.sh" "5.270.0"
assert_equal "$FLOOR_RC" "0" "updated package version floor"
assert_equal "$(call_count "$calls")" "0" "package version change does not invoke hq --version"

# Unknown package contents retain the historical executable version probe.
sleep 1 # Ensure the replacement package metadata is newer than the warm cache.
printf '{"name":"@indigoai-us/hq-cli"}\n' > "$package_root/package.json"
capture_floor "package-version-test.sh" "5.270.0"
assert_equal "$FLOOR_RC" "0" "malformed package metadata fallback"
assert_equal "$(call_count "$calls")" "1" "unrecognized package metadata invokes hq --version"

# The optional cache-home variable is irrelevant to the direct package-version path.
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
assert_equal "$(call_count "$HQ_STUB_CALLS")" "0" "cache directory unavailable must not spawn hq"

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
  local root="$1" expected_rc="$2" output rc original_path="$PATH"
  if [ -n "$JQ_BIN_DIR" ]; then PATH="$PATH:$JQ_BIN_DIR"; fi
  export PATH
  set +e
  output="$(bash "$root/core/scripts/check-hq-hooks.sh" --root "$root" 2>&1)"
  rc=$?
  set -e
  PATH="$original_path"
  export PATH
  if [ "$rc" != "$expected_rc" ]; then
    printf 'check-hq-hooks output (rc=%s expected=%s):\n%s\n' "$rc" "$expected_rc" "$output" >&2
    fail "check-hq-hooks exit"
  fi
  CHECKER_OUTPUT="$output"
}

# Cache invalidation follows package and executable updates, including upgrades
# and downgrades, when an installation creates newer package files.
package_root="$TMP/cache-version-transition"
make_cli "$package_root"
PATH="$package_root/path:/usr/bin:/bin"
XDG_CACHE_HOME="$TMP/cache-version-transition-home"
export PATH XDG_CACHE_HOME
capture_floor "cache-transition.sh" "5.269.0"
assert_equal "$FLOOR_RC" "0" "prime cached CLI version"
sed 's/5.269.0/5.270.0/' "$package_root/package.json" > "$package_root/package.updated.json"
mv "$package_root/package.updated.json" "$package_root/package.json"
touch -r "$XDG_CACHE_HOME/hq-cli-floor/version" "$package_root/package.json"
capture_floor "cache-transition.sh" "5.270.0"
assert_equal "$FLOOR_RC" "0" "cached CLI upgrade is detected"
sed 's/5.270.0/5.268.9/' "$package_root/package.json" > "$package_root/package.updated.json"
mv "$package_root/package.updated.json" "$package_root/package.json"
touch -r "$XDG_CACHE_HOME/hq-cli-floor/version" "$package_root/package.json"
capture_floor "cache-transition.sh" "5.269.0"
assert_equal "$FLOOR_RC" "127" "cached CLI downgrade is detected"
assert_contains "$FLOOR_OUTPUT" 'found 5.268.9' "cached CLI downgrade version"

# The generated forwarder has no external helper on a warm cache hit. The
# only executable recorded after the cache is primed is the final hq command.
hot_root="$TMP/hot-forwarder-root"
hot_package="$TMP/hot-forwarder-package"
hot_shims="$TMP/hot-forwarder-shims"
hot_home="$TMP/hot-forwarder-home"
hot_execs="$TMP/hot-forwarder-execs"
mkdir -p "$hot_root/core/scripts/lib" "$hot_root/core" "$hot_package/bin" "$hot_package/path" "$hot_shims"
cp "$ROOT/core/scripts/derive-trigger-facts.sh" "$hot_root/core/scripts/derive-trigger-facts.sh"
cp "$LIB" "$hot_root/core/scripts/lib/hq-cli-floor.sh"
printf 'requiresHqCli: ">=5.342.5"\n' > "$hot_root/core/core.yaml"
printf '{"name":"@indigoai-us/hq-cli","version":"5.342.7"}\n' > "$hot_package/package.json"
cat > "$hot_package/bin/hq" <<'HQ'
#!/usr/bin/env bash
printf 'hq\n' >> "$HOT_EXEC_LOG"
exit 0
HQ
chmod +x "$hot_package/bin/hq"
ln -s "$hot_package/bin/hq" "$hot_package/path/hq"
for utility in dirname basename readlink grep awk stat cksum mkdir mv; do
  cat > "$hot_shims/$utility" <<'SHIM'
#!/usr/bin/env bash
utility="${0##*/}"
printf '%s\n' "$utility" >> "$HOT_EXEC_LOG"
system_path="${PATH#"$HOT_SHIMS:"}"
system_utility="$(PATH="$system_path" command -v "$utility")"
"$system_utility" "$@"
status=$?
printf '%s rc=%s\n' "$utility" "$status" >> "$HOT_EXEC_LOG"
exit "$status"
SHIM
  chmod +x "$hot_shims/$utility"
done
PATH="$hot_shims:$hot_package/path:/usr/bin:/bin"
XDG_CACHE_HOME="$hot_home"
HOT_EXEC_LOG="$hot_execs"
HOT_SHIMS="$hot_shims"
export PATH XDG_CACHE_HOME HOT_EXEC_LOG HOT_SHIMS
sleep 1 # Ensure the binary and package files predate the cache entry on coarse timestamp filesystems.
hot_cold_stderr="$TMP/hot-forwarder-cold-stderr"
set +e
bash "$hot_root/core/scripts/derive-trigger-facts.sh" </dev/null 2>"$hot_cold_stderr"
hot_cold_rc=$?
set -e
if [ ! -s "$hot_home/hq-cli-floor/version" ]; then
  printf 'cold cache diagnostics: rc=%s hq=%s package=%s xdg=%s\n' \
    "$hot_cold_rc" "$(command -v hq)" "$hot_package/package.json" "$XDG_CACHE_HOME" >&2
  if [ -f "$hot_cold_stderr" ]; then cat "$hot_cold_stderr" >&2; fi
  if [ -f "$hot_execs" ]; then cat "$hot_execs" >&2; fi
  printf 'cache dir exists=%s temp exists=%s\n' \
    "$([ -d "$hot_home/hq-cli-floor" ] && printf yes || printf no)" \
    "$([ -e "$hot_home/hq-cli-floor/version.$$" ] && printf yes || printf no)" >&2
  fail "cold forwarder did not write the version cache"
fi
: > "$hot_execs"
bash "$hot_root/core/scripts/derive-trigger-facts.sh" </dev/null
exec 3< "$hot_execs"
IFS= read -r hot_first <&3 || hot_first=""
if [ "$hot_first" != hq ]; then
  cache_schema=""
  cache_command=""
  cache_target=""
  cache_package=""
  cache_version=""
  {
    IFS= read -r cache_schema || true
    IFS= read -r cache_command || true
    IFS= read -r cache_target || true
    IFS= read -r cache_package || true
    IFS= read -r cache_version || true
  } < "$hot_home/hq-cli-floor/version"
  same_target=no
  target_newer=no
  package_newer=no
  [[ "$hot_package/path/hq" -ef "$cache_target" ]] && same_target=yes
  [[ "$cache_target" -nt "$hot_home/hq-cli-floor/version" ]] && target_newer=yes
  [[ "$cache_package" -nt "$hot_home/hq-cli-floor/version" ]] && package_newer=yes
  printf 'warm cache diagnostics: schema=%s command_matches=%s target_exists=%s package_exists=%s same_target=%s target_newer=%s package_newer=%s version=%s\n' \
    "$cache_schema" "$([ "$cache_command" = "$hot_package/path/hq" ] && printf yes || printf no)" \
    "$([ -e "$cache_target" ] && printf yes || printf no)" "$([ -f "$cache_package" ] && printf yes || printf no)" \
    "$same_target" "$target_newer" "$package_newer" "$cache_version" >&2
fi
assert_equal "$hot_first" "hq" "warm forwarder first process"
if IFS= read -r hot_second <&3; then
  fail "warm forwarder spawned extra process: $hot_second"
fi
exec 3<&-

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
sed 's/5.269.0/5.268.9/' "$TMP/hooks-old-cli/package.json" > "$TMP/hooks-old-cli/package.updated.json"
mv "$TMP/hooks-old-cli/package.updated.json" "$TMP/hooks-old-cli/package.json"
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

# Live-root fallback preserves a logical HQ path when the installation is reached
# through a directory symlink. Exercise both root modes through generated scripts.
symlink_physical_root="$TMP/symlink-physical-hq"
symlink_logical_root="$TMP/symlink-logical-hq"
symlink_manifest="$TMP/symlink-forwarders.yaml"
symlink_stub_bin="$TMP/symlink-stub-bin"
symlink_args="$TMP/symlink-forwarder-args"
mkdir -p "$symlink_physical_root/core/scripts/lib" "$symlink_stub_bin"
ln -s "$symlink_physical_root" "$symlink_logical_root"
printf 'hq_cli_floor_check() { :; }\n' > "$symlink_physical_root/core/scripts/lib/hq-cli-floor.sh"
cat > "$symlink_stub_bin/hq" <<'HQ'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$SYMLINK_HQ_ARGS"
HQ
chmod +x "$symlink_stub_bin/hq"
cat > "$symlink_manifest" <<'YAML'
entries:
  - path: core/scripts/live-fallback.sh
    command: derive-trigger-facts
    kind: generated
    root: live
    interpreter: bash
    min_cli: 5.342.5
    state: forwarded
  - path: core/scripts/live-project-fallback.sh
    command: migrate-policy-triggers
    kind: generated
    root: live-project
    interpreter: bash
    min_cli: 5.342.5
    state: forwarded
YAML
"$ROOT/core/scripts/generate-forwarders.sh" --manifest "$symlink_manifest" --output-root "$symlink_logical_root"
export SYMLINK_HQ_ARGS="$symlink_args"
PATH="$symlink_stub_bin:/usr/bin:/bin"
export PATH
unset HQ_ROOT CLAUDE_PROJECT_DIR
bash "$symlink_logical_root/core/scripts/live-fallback.sh"
assert_equal "$(sed -n '3p' "$symlink_args")" "$symlink_logical_root" "live forwarder preserves logical symlink root"
bash "$symlink_logical_root/core/scripts/live-project-fallback.sh"
assert_equal "$(sed -n '3p' "$symlink_args")" "$symlink_logical_root" "live-project forwarder preserves logical symlink root"

printf 'PASS: hq-cli-floor (reader, SemVer, package metadata fast path, fallback, checker floor)\n'
