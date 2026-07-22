#!/usr/bin/env bash
# Regression: the update-preserved native personal context is editable without
# opening the rest of the release-owned .claude/ tree to direct writes.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
HOOK="$ROOT/.claude/hooks/block-core-writes.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }
[ -x "$HOOK" ] || fail "hook is not executable: $HOOK"

mkdir -p "$TMP/.claude" "$TMP/core"
printf '{}' >"$TMP/.claude/settings.local.json"

run() {
  local expected="$1" path="$2" label="$3" output rc=0
  set +e
  output="$(jq -n --arg path "$path" '{tool_input:{file_path:$path}}' | CLAUDE_PROJECT_DIR="$TMP" bash "$HOOK" 2>&1)"
  rc=$?
  set -e
  [ "$rc" -eq "$expected" ] || fail "$label: expected $expected, got $rc: $output"
  pass "$label"
}

run 0 "$TMP/.claude/personal-context.md" 'native personal context is writable'
run 0 "$TMP/.claude/settings.local.json" 'machine-local settings stay writable'
run 2 "$TMP/.claude/CLAUDE.md" 'locked charter stays protected'
run 2 "$TMP/core/core.yaml" 'core stays protected'

echo "PASS: block-core-writes native context exception"
