#!/usr/bin/env bash
# hq-core: public
# Regression tests for .claude/hooks/mandatory-scope-authorizer.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

install_fixture() {
  local bound="${1:-}"
  rm -rf "$TMP"/*
  mkdir -p "$TMP/.claude/hooks" "$TMP/core/scripts/lib" \
    "$TMP/companies/indigo/settings" "$TMP/companies/otherco/settings" \
    "$TMP/companies/_template" "$TMP/core/docs" "$TMP/personal" \
    "$TMP/workspace/sessions/sess-bound"
  cp "$ROOT/.claude/hooks/mandatory-scope-authorizer.sh" "$TMP/.claude/hooks/"
  cp "$ROOT/core/scripts/lib/session-authz.sh" "$TMP/core/scripts/lib/"
  cp "$ROOT/core/scripts/lib/session-scope-capability.sh" "$TMP/core/scripts/lib/"
  chmod +x "$TMP/.claude/hooks/mandatory-scope-authorizer.sh"

  printf 'companies:\n  indigo:\n    name: Indigo\n  otherco:\n    name: otherco\n' \
    > "$TMP/companies/manifest.yaml"
  touch "$TMP/companies/indigo/settings/.keep" "$TMP/companies/otherco/settings/.keep"
  touch "$TMP/core/docs/readme.md" "$TMP/personal/note.md" "$TMP/companies/_template/readme.md"
  printf 'sess-bound\n' > "$TMP/workspace/sessions/.current"

  if [ -n "$bound" ]; then
    printf 'company_slug: %s\n' "$bound" > "$TMP/workspace/sessions/sess-bound/meta.yaml"
    # shellcheck source=../lib/session-scope-capability.sh
    . "$ROOT/core/scripts/lib/session-scope-capability.sh"
    session_scope_mint "$TMP" "sess-bound" "$bound"
  fi
}

run_hook() {
  local payload="$1"
  local rc=0
  : > "$TMP/err.txt"
  printf '%s' "$payload" | bash "$TMP/.claude/hooks/mandatory-scope-authorizer.sh" 2>"$TMP/err.txt" || rc=$?
  printf '%s' "$rc"
}

echo "[1] bound indigo blocks cross-company Read"
install_fixture "indigo"
payload='{"tool_name":"Read","session_id":"sess-bound","cwd":"'"$TMP"'","tool_input":{"file_path":"'"$TMP"'/companies/otherco/settings/foo.yaml"}}'
rc="$(run_hook "$payload")"
[ "$rc" = "2" ] || fail "expected exit 2 for cross-company read, got $rc"
grep -q "Cross-company scope violation" "$TMP/err.txt" || fail "missing block message"

echo "[2] bound indigo allows same-company, core, personal, manifest"
for rel in \
  "companies/indigo/settings/foo.yaml" \
  "core/docs/readme.md" \
  "personal/note.md" \
  "companies/manifest.yaml"; do
  payload='{"tool_name":"Read","session_id":"sess-bound","cwd":"'"$TMP"'","tool_input":{"file_path":"'"$TMP"'/'"$rel"'"}}'
  rc="$(run_hook "$payload")"
  [ "$rc" = "0" ] || fail "expected allow for $rel, got $rc"
done

echo "[3] unbound session blocks companies/* except manifest and _template"
install_fixture ""
payload='{"tool_name":"Read","session_id":"sess-bound","cwd":"'"$TMP"'","tool_input":{"file_path":"'"$TMP"'/companies/indigo/settings/foo.yaml"}}'
rc="$(run_hook "$payload")"
[ "$rc" = "2" ] || fail "expected exit 2 for unbound company read, got $rc"

payload='{"tool_name":"Read","session_id":"sess-bound","cwd":"'"$TMP"'","tool_input":{"file_path":"'"$TMP"'/companies/_template/readme.md"}}'
rc="$(run_hook "$payload")"
[ "$rc" = "0" ] || fail "expected allow for _template, got $rc"

payload='{"tool_name":"Read","session_id":"sess-bound","cwd":"'"$TMP"'","tool_input":{"file_path":"'"$TMP"'/companies/manifest.yaml"}}'
rc="$(run_hook "$payload")"
[ "$rc" = "0" ] || fail "expected allow for manifest, got $rc"

echo "[4] Bash blocks embedded cross-company path"
install_fixture "indigo"
payload='{"tool_name":"Bash","session_id":"sess-bound","cwd":"'"$TMP"'","tool_input":{"command":"cat companies/otherco/settings/secrets.yaml"}}'
rc="$(run_hook "$payload")"
[ "$rc" = "2" ] || fail "expected exit 2 for bash cross-company, got $rc"

echo "[5] Bash blocks shell-expanded companies/ paths"
install_fixture "indigo"
payload='{"tool_name":"Bash","session_id":"sess-bound","cwd":"'"$TMP"'","tool_input":{"command":"co=otherco; cat companies/$co/settings/x"}}'
rc="$(run_hook "$payload")"
[ "$rc" = "2" ] || fail "expected exit 2 for shell-expanded companies path, got $rc"

echo "[6] Read follows symlink target for company scope"
install_fixture "indigo"
mkdir -p "$TMP/companies/indigo/settings"
touch "$TMP/companies/otherco/settings/foo.yaml"
ln -sfn "$TMP/companies/otherco/settings/foo.yaml" "$TMP/companies/indigo/settings/otherco-link.yaml"
payload='{"tool_name":"Read","session_id":"sess-bound","cwd":"'"$TMP"'","tool_input":{"file_path":"'"$TMP"'/companies/indigo/settings/otherco-link.yaml"}}'
rc="$(run_hook "$payload")"
[ "$rc" = "2" ] || fail "expected exit 2 for symlink into other company, got $rc"

echo "PASS: mandatory-scope-authorizer.test.sh"
