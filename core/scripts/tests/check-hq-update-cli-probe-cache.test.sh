#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
HOOK="$ROOT/.claude/hooks/check-hq-update.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

mkdir -p "$TMP/root/core/scripts" "$TMP/bin"
printf 'hqVersion: "99.999.999"\n' > "$TMP/root/core/core.yaml"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$TMP/root/core/scripts/remove-stray-gate-hooks.sh"
chmod +x "$TMP/root/core/scripts/remove-stray-gate-hooks.sh"
cat > "$TMP/bin/hq" <<'EOF_HQ'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf 'version\n' >> "$HQ_TEST_VERSION_CALLS"
  printf 'hq 5.331.0\n'
fi
EOF_HQ
cat > "$TMP/bin/npm" <<'EOF_NPM'
#!/usr/bin/env bash
exit 0
EOF_NPM
cat > "$TMP/bin/gh" <<'EOF_GH'
#!/usr/bin/env bash
exit 1
EOF_GH
chmod +x "$TMP/bin/hq" "$TMP/bin/npm" "$TMP/bin/gh"
: > "$TMP/version.calls"

run_hook() {
  local label="$1" rc=0
  env -u CI \
    BASH_ENV=/dev/null \
    CLAUDE_PROJECT_DIR="$TMP/root" \
    HQ_UPDATE_CHECK_STATE_DIR="$TMP/state" \
    HQ_TEST_VERSION_CALLS="$TMP/version.calls" \
    PATH="$TMP/bin:/usr/bin:/bin" \
    bash "$HOOK" > "$TMP/$label.out" 2> "$TMP/$label.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "$label returned $rc instead of 0"
  [ ! -s "$TMP/$label.out" ] || fail "$label changed the no-update output"
  [ ! -s "$TMP/$label.err" ] || fail "$label wrote to stderr"
}

run_hook first
run_hook second
calls="$(wc -l < "$TMP/version.calls" | tr -d '[:space:]')"
[ "$calls" = 1 ] || fail "unchanged hq binary was version-probed $calls times"
printf 'PASS: unchanged hq binaries reuse the host-local version probe without changing output or exit status\n'
