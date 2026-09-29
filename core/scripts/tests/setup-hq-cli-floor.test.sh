#!/usr/bin/env bash
# setup.sh warns about an old hq CLI and continues, and remains usable when hq
# is absent. All setup writes happen in a synthetic temporary root.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2'"; }

make_setup_root() {
  local root="$1"
  mkdir -p "$root/core/scripts/lib" "$root/.claude/hooks" "$root/companies"
  cp "$ROOT/core/scripts/setup.sh" "$root/core/scripts/setup.sh"
  cp "$ROOT/core/scripts/lib/portable.sh" "$root/core/scripts/lib/portable.sh"
  cp "$ROOT/core/scripts/lib/hq-cli-floor.sh" "$root/core/scripts/lib/hq-cli-floor.sh"
  cat > "$root/core/core.yaml" <<'YAML'
requiresHqCli: ">=5.269.0"
recommended_packages: []
YAML
  printf '{"env":{}}\n' > "$root/.claude/settings.json"
  cat > "$root/core/scripts/compose-settings-path.sh" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s' "$PATH"
SCRIPT
  cat > "$root/core/scripts/restore-hook-settings.sh" <<'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT
  cat > "$root/core/scripts/check-hq-hooks.sh" <<'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT
  chmod +x "$root/core/scripts/setup.sh" "$root/core/scripts/compose-settings-path.sh" \
    "$root/core/scripts/restore-hook-settings.sh" "$root/core/scripts/check-hq-hooks.sh"
}

make_stub_tools() {
  local bin="$1" npm_calls="$2"
  mkdir -p "$bin"
  cat > "$bin/node" <<'SCRIPT'
#!/usr/bin/env bash
printf 'v20.0.0\n'
SCRIPT
  cat > "$bin/npm" <<SCRIPT
#!/usr/bin/env bash
if [ "\${1:-}" = "--version" ]; then
  printf '10.0.0\n'
else
  printf 'install\n' >> "$npm_calls"
  exit 1
fi
SCRIPT
  cat > "$bin/qmd" <<'SCRIPT'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then printf 'qmd 2.5.3\n'; fi
exit 0
SCRIPT
  chmod +x "$bin/node" "$bin/npm" "$bin/qmd"
}

run_setup() {
  local root="$1" bin="$2" home="$3" cache="$4" output rc
  set +e
  output="$(HOME="$home" XDG_CACHE_HOME="$cache" HQ_SKIP_PACKAGES=1 \
    PATH="$bin:/usr/bin:/bin" /bin/bash "$root/core/scripts/setup.sh" </dev/null 2>&1)"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "setup exited $rc: $output"
  SETUP_OUTPUT="$output"
}

# An old CLI is diagnosed with the exact upgrade command; non-interactive setup
# prints the command and still completes without invoking npm install.
old_root="$TMP/setup-old"
old_bin="$TMP/setup-old-bin"
make_setup_root "$old_root"
make_stub_tools "$old_bin" "$TMP/setup-old-npm-calls"
mkdir -p "$TMP/hq-package/bin" "$TMP/hq-package/path"
cat > "$TMP/hq-package/package.json" <<'JSON'
{"name":"@indigoai-us/hq-cli","version":"5.268.9"}
JSON
cat > "$TMP/hq-package/bin/hq" <<'HQ'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then printf 'hq 5.268.9\n'; fi
HQ
chmod +x "$TMP/hq-package/bin/hq"
ln -s "$TMP/hq-package/bin/hq" "$old_bin/hq"
run_setup "$old_root" "$old_bin" "$TMP/home-old" "$TMP/cache-old"
assert_contains "$SETUP_OUTPUT" 'setup.sh: this script needs hq-cli >= 5.269.0 (found 5.268.9)' "old CLI setup warning"
assert_contains "$SETUP_OUTPUT" 'Upgrade with: npm install -g @indigoai-us/hq-cli@latest' "non-interactive upgrade instruction"
[ ! -f "$TMP/setup-old-npm-calls" ] || fail "non-interactive setup attempted npm install"
assert_contains "$SETUP_OUTPUT" 'HQ setup complete.' "old CLI setup completion"

# A missing CLI is reported as optional setup guidance and does not stop setup.
missing_root="$TMP/setup-missing"
missing_bin="$TMP/setup-missing-bin"
make_setup_root "$missing_root"
make_stub_tools "$missing_bin" "$TMP/setup-missing-npm-calls"
run_setup "$missing_root" "$missing_bin" "$TMP/home-missing" "$TMP/cache-missing"
assert_contains "$SETUP_OUTPUT" 'hq CLI not found' "missing CLI setup guidance"
assert_contains "$SETUP_OUTPUT" 'HQ setup complete.' "missing CLI setup completion"

printf 'PASS: setup hq-cli floor (older and missing CLI paths)\n'
