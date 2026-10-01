#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPTS="$ROOT/core/scripts"
INSTALLER="$SCRIPTS/ci/install-pinned-hq-cli.sh"
GUARD="$SCRIPTS/check-cli-hosted.sh"
GENERATOR="$SCRIPTS/generate-forwarders.sh"
TMP="$(mktemp -d /tmp/cli-hosted-pinned-cli.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

failures=0
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}
pass() { printf 'PASS: %s\n' "$1"; }

MOCK_BIN="$TMP/mock-bin"
MOCK_PREFIX="$TMP/global"
MOCK_NPM_ROOT="$MOCK_PREFIX/lib/node_modules"
mkdir -p "$MOCK_BIN" "$MOCK_PREFIX/bin" "$MOCK_NPM_ROOT/@indigoai-us/hq-cli"
cat > "$MOCK_BIN/npm" <<'NPM'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "prefix -g") printf '%s\n' "${npm_config_prefix:-$MOCK_NPM_PREFIX}" ;;
  "root -g") printf '%s\n' "$MOCK_NPM_ROOT" ;;
  install\ -g\ *) printf '%s\n' "$*" >> "$MOCK_NPM_INSTALL_LOG" ;;
  *) printf 'unexpected npm arguments: %s\n' "$*" >&2; exit 64 ;;
esac
NPM
chmod +x "$MOCK_BIN/npm"

cat > "$MOCK_BIN/hq" <<'HQ'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1-}" = "--version" ]; then
  printf '%s\n' "${HQ_MOCK_VERSION:?}"
  exit 0
fi
if [ "${1-}" = "core" ] && [ "${2-}" = "--help" ]; then exit 0; fi
if [ "${1-}" = "core" ] && [ "${2-}" = "commands" ] && [ "${3-}" = "--json" ]; then
  if [ "${HQ_MOCK_CATALOG_FAIL:-0}" = "1" ]; then
    printf 'unknown command\n' >&2
    exit 1
  fi
  cat "${HQ_MOCK_CATALOG_FILE:?}"
  exit 0
fi
printf 'unexpected hq arguments: %s\n' "$*" >&2
exit 64
HQ
chmod +x "$MOCK_BIN/hq"

INSTALL_ROOT="$TMP/install-root"
mkdir -p "$INSTALL_ROOT/core/scripts/lib"
cp "$SCRIPTS/lib/cli-hosted-manifest.awk" "$INSTALL_ROOT/core/scripts/lib/cli-hosted-manifest.awk"
cat > "$INSTALL_ROOT/core/core.yaml" <<'YAML'
requiresHqCli: ">=5.269.0"
YAML
cat > "$INSTALL_ROOT/core/scripts/cli-hosted.yaml" <<'YAML'
entries:
  - path: core/scripts/fixture-live.sh
    command: fixture-live
    kind: generated
    root: live
    interpreter: bash
    min_cli: 5.112.0
    state: forwarded
    note: |
      synthetic row
  - path: core/scripts/fixture-newer.sh
    command: fixture-newer
    kind: generated
    root: cwd
    interpreter: bash
    min_cli: 5.270.0
    state: forwarded
    note: |
      synthetic row
YAML
cat > "$MOCK_PREFIX/bin/hq" <<'HQ'
#!/usr/bin/env bash
if [ "${1-}" = "--version" ]; then printf '5.270.0\n'; exit 0; fi
# Like the real version gate when the server minimum is above the pin: without
# the opt-out, a command self-updates and exits without running.
if [ "${HQ_NO_UPDATE_CHECK-}" != "1" ]; then printf 'below the minimum required version\n' >&2; exit 75; fi
if [ "${1-}" = "core" ] && [ "${2-}" = "--help" ]; then exit 0; fi
exit 64
HQ
chmod +x "$MOCK_PREFIX/bin/hq"
GITHUB_PATH_FILE="$TMP/github-path"
GITHUB_ENV_FILE="$TMP/github-step-vars"
MOCK_NPM_LOG="$TMP/npm-installs"
: > "$MOCK_NPM_LOG"
if [ ! -f "$INSTALLER" ]; then
  fail 'pinned CLI installer exists'
else
  install_output="$(MOCK_NPM_PREFIX="$MOCK_PREFIX" MOCK_NPM_ROOT="$MOCK_NPM_ROOT" \
    MOCK_NPM_INSTALL_LOG="$MOCK_NPM_LOG" GITHUB_PATH="$GITHUB_PATH_FILE" \
    GITHUB_ENV="$GITHUB_ENV_FILE" HQ_MOCK_VERSION=5.270.0 PATH="$MOCK_BIN:$PATH" \
    bash "$INSTALLER" --root "$INSTALL_ROOT" 2>&1)" || {
      fail "pinned CLI installer succeeds: $install_output"
      install_output=""
    }
  if ! grep -qx 'HQ_NO_UPDATE_CHECK=1' "$GITHUB_ENV_FILE" 2>/dev/null; then
    fail 'installer turns the version gate off for later CI steps'
  else
    pass 'installer turns the version gate off for later CI steps'
  fi
  if ! grep -F -q 'install -g @indigoai-us/hq-cli@5.270.0 --ignore-scripts' "$MOCK_NPM_LOG"; then
    fail 'installer selects the maximum manifest min_cli and suppresses package lifecycle scripts'
  else
    pass 'installer selects the maximum manifest min_cli and suppresses package lifecycle scripts'
  fi
  if ! grep -F -q "$MOCK_PREFIX/bin" "$GITHUB_PATH_FILE"; then
    fail 'installer exports the npm global bin directory through GITHUB_PATH'
  else
    pass 'installer exports the npm global bin directory through GITHUB_PATH'
  fi
  if ! grep -F -q '5.270.0' <<<"$install_output"; then
    fail 'installer prints the installed hq version'
  else
    pass 'installer prints the installed hq version'
  fi
fi

WINDOWS_PREFIX="$TMP/windows-global"
WINDOWS_PATH_FILE="$TMP/windows-github-path"
mkdir -p "$WINDOWS_PREFIX"
cat > "$WINDOWS_PREFIX/hq" <<'HQ'
#!/usr/bin/env bash
if [ "${1-}" = "--version" ]; then printf '5.270.0\n'; exit 0; fi
if [ "${1-}" = "core" ] && [ "${2-}" = "--help" ]; then exit 0; fi
exit 64
HQ
chmod +x "$WINDOWS_PREFIX/hq"
if WINDOWS_INSTALL_OUTPUT="$(MOCK_NPM_PREFIX="$WINDOWS_PREFIX" MOCK_NPM_ROOT="$MOCK_NPM_ROOT" \
  MOCK_NPM_INSTALL_LOG="$MOCK_NPM_LOG" GITHUB_PATH="$WINDOWS_PATH_FILE" \
  HQ_MOCK_VERSION=5.270.0 PATH="$MOCK_BIN:$PATH" \
  bash "$INSTALLER" --root "$INSTALL_ROOT" 2>&1)"; then
  if grep -F -q "$WINDOWS_PREFIX" "$WINDOWS_PATH_FILE" \
    && grep -F -q 'hq --version: 5.270.0' <<<"$WINDOWS_INSTALL_OUTPUT"; then
    pass 'installer accepts an npm global bin placed directly in its prefix'
  else
    fail 'installer exports and validates a prefix-level Windows-style npm bin'
  fi
else
  fail "installer accepts a prefix-level Windows-style npm bin: $WINDOWS_INSTALL_OUTPUT"
fi

LATEST_PREFIX="$TMP/current-cli-prefix"
LATEST_PATH_FILE="$TMP/current-cli-github-path"
mkdir -p "$LATEST_PREFIX/bin"
cat > "$LATEST_PREFIX/bin/hq" <<'HQ'
#!/usr/bin/env bash
if [ "${1-}" = "--version" ]; then printf '%s\n' "${HQ_MOCK_VERSION:?}"; exit 0; fi
if [ "${1-}" = "core" ] && [ "${2-}" = "--help" ]; then exit 0; fi
exit 64
HQ
chmod +x "$LATEST_PREFIX/bin/hq"
LATEST_INSTALL_OUTPUT=""
if LATEST_INSTALL_OUTPUT="$(npm_config_prefix="$LATEST_PREFIX" MOCK_NPM_PREFIX="$MOCK_PREFIX" \
  MOCK_NPM_ROOT="$MOCK_NPM_ROOT" MOCK_NPM_INSTALL_LOG="$MOCK_NPM_LOG" \
  GITHUB_PATH="$LATEST_PATH_FILE" HQ_MOCK_VERSION=5.277.0 PATH="$MOCK_BIN:$PATH" \
  bash "$INSTALLER" --root "$INSTALL_ROOT" --version latest 2>&1)"; then
  if grep -F -q 'install -g @indigoai-us/hq-cli@latest --ignore-scripts' "$MOCK_NPM_LOG" \
    && grep -F -q "$LATEST_PREFIX/bin" "$LATEST_PATH_FILE" \
    && grep -F -q 'hq --version: 5.277.0' <<<"$LATEST_INSTALL_OUTPUT"; then
    pass 'installer can install latest into a separate npm prefix and reports the resolved version'
  else
    fail 'latest installer selects the separate prefix and reports the resolved hq version'
  fi
else
  fail "installer accepts --version latest: $LATEST_INSTALL_OUTPUT"
fi

make_guard_root() {
  local tree="$1" call="${2:-archive-old-threads}"
  mkdir -p "$tree/core/scripts/ci"
  cat > "$tree/core/scripts/cli-hosted.yaml" <<'YAML'
entries:
  - path: core/scripts/fixture-live.sh
    command: fixture-live
    kind: generated
    root: live
    interpreter: bash
    min_cli: 5.269.0
    state: forwarded
    note: |
      synthetic parity row
YAML
  cp "$GUARD" "$tree/core/scripts/check-cli-hosted.sh"
  cp "$GENERATOR" "$tree/core/scripts/generate-forwarders.sh"
  cp "$INSTALLER" "$tree/core/scripts/ci/install-pinned-hq-cli.sh"
  bash "$GENERATOR" --manifest "$tree/core/scripts/cli-hosted.yaml" --output-root "$tree" >/dev/null
  cat > "$tree/core/scripts/handoff-post.sh" <<SH
#!/usr/bin/env bash
if hq core $call --session-files-file "\$FILES_TOUCHED_FILE"; then :; fi
SH
  chmod +x "$tree/core/scripts/handoff-post.sh"
  git -C "$tree" init -q
  git -C "$tree" add -A
}

write_catalog() {
  local file="$1" fixture_root="${2:-live}" archive_name="${3:-archive-old-threads}"
  cat > "$file" <<JSON
[
  {"name":"fixture-live","execution":"native","root":"$fixture_root"},
  {"name":"$archive_name","execution":"native","root":"live"},
  {"name":"commands","execution":"native","root":"cwd"}
]
JSON
}

write_release_changelog() {
  local version="$1" supports="$2"
  mkdir -p "$MOCK_NPM_ROOT/@indigoai-us/hq-cli"
  if [ "$supports" = yes ]; then
    printf '# Changelog\n\n## [%s]\n\n- Add `hq core commands --json`.\n' "$version" \
      > "$MOCK_NPM_ROOT/@indigoai-us/hq-cli/CHANGELOG.md"
  else
    printf '# Changelog\n\n## [%s]\n\n- Existing CLI release.\n' "$version" \
      > "$MOCK_NPM_ROOT/@indigoai-us/hq-cli/CHANGELOG.md"
  fi
}

run_guard() {
  local tree="$1" version="$2" catalog="$3" catalog_fails="$4" required_ci="${5:-0}" out="$TMP/guard.out" err="$TMP/guard.err"
  local status=0
  if MOCK_NPM_PREFIX="$MOCK_PREFIX" MOCK_NPM_ROOT="$MOCK_NPM_ROOT" \
    HQ_MOCK_VERSION="$version" HQ_MOCK_CATALOG_FILE="$catalog" \
    HQ_MOCK_CATALOG_FAIL="$catalog_fails" HQ_CLI_REQUIRED_IN_CI="$required_ci" PATH="$MOCK_BIN:$PATH" \
    bash "$GUARD" --root "$tree" --manifest "$tree/core/scripts/cli-hosted.yaml" >"$out" 2>"$err"; then
    status=0
  else
    status=$?
  fi
  printf '%s\n' "$status"
}

expect_guard_failure() {
  local tree="$1" version="$2" catalog="$3" fail_catalog="$4" needle="$5" label="$6" required_ci="${7:-0}" status
  status="$(run_guard "$tree" "$version" "$catalog" "$fail_catalog" "$required_ci")"
  if [ "$status" -eq 0 ]; then
    fail "$label: guard accepted an invalid catalog or call site"
  elif ! grep -F -q -- "$needle" "$TMP/guard.err"; then
    cat "$TMP/guard.err" >&2
    fail "$label: guard output did not include [$needle]"
  else
    pass "$label"
  fi
}

CATALOG="$TMP/catalog.json"
write_catalog "$CATALOG"
write_release_changelog 5.276.0 no
TREE="$TMP/guard-clean"
make_guard_root "$TREE"
status="$(run_guard "$TREE" 5.276.0 "$CATALOG" 0)"
if [ "$status" -ne 0 ]; then
  fail 'supported CLI catalog passes when every row and allow-listed call site is registered'
elif ! grep -F -q 'cli-hosted manifest and backmerge checks passed' "$TMP/guard.out"; then
  fail 'clean catalog guard emits its success line'
else
  pass 'supported CLI catalog passes when every row and allow-listed call site is registered'
fi

TREE="$TMP/guard-missing-command"
make_guard_root "$TREE"
write_catalog "$CATALOG" live archive-old-threads
cat > "$CATALOG" <<'JSON'
[
  {"name":"archive-old-threads","execution":"native","root":"live"},
  {"name":"commands","execution":"native","root":"cwd"}
]
JSON
expect_guard_failure "$TREE" 5.276.0 "$CATALOG" 0 \
  'core/scripts/fixture-live.sh: hq core fixture-live is missing from hq core commands' \
  'negative control: a manifest command missing from the CLI catalog fails'

TREE="$TMP/guard-root-mismatch"
make_guard_root "$TREE"
write_catalog "$CATALOG" cwd
expect_guard_failure "$TREE" 5.276.0 "$CATALOG" 0 \
  'core/scripts/fixture-live.sh: hq core fixture-live root is cwd, expected live' \
  'negative control: a manifest root-mode mismatch fails'

TREE="$TMP/guard-allowlisted-call"
make_guard_root "$TREE" unsupported-command
write_catalog "$CATALOG"
expect_guard_failure "$TREE" 5.276.0 "$CATALOG" 0 \
  'core/scripts/handoff-post.sh: hq core unsupported-command is missing from hq core commands' \
  'negative control: an allow-listed source calling an unlisted CLI command fails'

TREE="$TMP/guard-old-cli"
make_guard_root "$TREE"
write_release_changelog 5.276.0 no
status="$(run_guard "$TREE" 5.276.0 "$CATALOG" 1)"
if [ "$status" -ne 0 ]; then
  fail 'pre-catalog published CLI defers catalog parity'
elif ! grep -F -q 'catalog parity deferred' "$TMP/guard.out"; then
  fail 'pre-catalog published CLI reports why catalog parity is deferred'
else
  pass 'pre-catalog published CLI defers parity with a clear explanation'
fi

TREE="$TMP/guard-old-cli-required"
make_guard_root "$TREE"
write_release_changelog 5.276.0 no
expect_guard_failure "$TREE" 5.276.0 "$CATALOG" 1 \
  'hq-cli 5.276.0: hq core commands --json is unavailable; catalog parity is required in CI' \
  'negative control: CI mode fails closed when the installed CLI has no catalog' 1

TREE="$TMP/guard-released-cli-missing-command"
make_guard_root "$TREE"
write_release_changelog 5.277.0 yes
expect_guard_failure "$TREE" 5.277.0 "$CATALOG" 1 \
  'hq-cli 5.277.0: published CHANGELOG.md contains hq core commands --json but the command is unavailable' \
  'negative control: missing catalog command fails once the installed release changelog advertises it'

if [ "$failures" -gt 0 ]; then exit 1; fi
printf 'cli-hosted pinned CLI and catalog tests passed\n'
