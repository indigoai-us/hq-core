#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
CASE="${1:-all}"
HOOK_SOURCE="${SCOPE_1112_HOOK_SOURCE:-$ROOT/.claude/hooks/mandatory-scope-authorizer.sh}"
TMP="$(mktemp -d)"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
expect_exit() {
  local expected="$1" actual="$2" label="$3"
  [ "$expected" = "$actual" ] || fail "$label (expected exit $expected, got $actual)"
  echo "PASS: $label (exit $actual)"
}
install_fixture() {
  rm -rf "${TMP:?}"/*
  mkdir -p "$TMP/.claude/hooks" "$TMP/core/scripts/lib" \
    "$TMP/companies/indigo/settings" "$TMP/companies/otherco/settings" \
    "$TMP/workspace/sessions/sess-bound"
  cp "$HOOK_SOURCE" "$TMP/.claude/hooks/mandatory-scope-authorizer.sh"
  cp "$ROOT/core/scripts/lib/session-authz.sh" "$TMP/core/scripts/lib/"
  cp "$ROOT/core/scripts/lib/session-scope-capability.sh" "$TMP/core/scripts/lib/"
  cp "$ROOT/core/scripts/lib/session-id.sh" "$TMP/core/scripts/lib/"
  cp "$ROOT/core/scripts/hook-lib.sh" "$TMP/core/scripts/"
  chmod +x "$TMP/.claude/hooks/mandatory-scope-authorizer.sh"
  printf 'companies:\n  indigo:\n    name: Indigo\n  otherco:\n    name: Otherco\n' > "$TMP/companies/manifest.yaml"
  . "$ROOT/core/scripts/lib/session-scope-capability.sh"
  session_scope_mint "$TMP" sess-bound indigo
  printf 'company_slug: indigo\n' > "$TMP/workspace/sessions/sess-bound/meta.yaml"
}
run_hook() {
  local command="$1" payload rc=0
  payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
    '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
  : > "$TMP/err.txt"
  printf '%s' "$payload" | bash "$TMP/.claude/hooks/mandatory-scope-authorizer.sh" 2>"$TMP/err.txt" || rc=$?
  printf '%s' "$rc"
}
run_case() {
  local id="$1" rc command
  install_fixture
  case "$id" in
    expansion)
      command='c=companies; cat workspace/../$c/otherco/settings/x'
      rc="$(run_hook "$command")"
      expect_exit 2 "$rc" 'parent traversal expansion into a foreign company is denied'
      command='c=companies; cat workspace/../$c/indigo/settings/x'
      rc="$(run_hook "$command")"
      expect_exit 0 "$rc" 'parent traversal expansion into the bound company is allowed'
      ;;
    heredoc)
      command=$'cat <<\'BODY\' > /tmp/fz-generated-script\ncat companies/otherco/settings/x\nBODY\nbash /tmp/fz-generated-script'
      rc="$(run_hook "$command")"
      expect_exit 2 "$rc" 'executed quoted heredoc cannot read a foreign company'
      command=$'cat <<\'BODY\' > /tmp/fz-generated-script\ncat companies/indigo/settings/x\nBODY\nbash /tmp/fz-generated-script'
      rc="$(run_hook "$command")"
      expect_exit 0 "$rc" 'executed quoted heredoc can read the bound company'
      ;;
    diagnostic-reason)
      command='cat companies/$unresolved/settings/x'
      rc="$(run_hook "$command")"
      expect_exit 2 "$rc" 'unresolved company expansion is denied'
      grep -Fq 'Reason: variable expansion has no statically resolvable value' "$TMP/err.txt" \
        || fail 'diagnostic identifies why the company expansion was denied'
      ;;
    diagnostic-company)
      command='cat companies/$unresolved/settings/x'
      rc="$(run_hook "$command")"
      expect_exit 2 "$rc" 'unresolved company expansion is denied'
      grep -Fq 'BLOCKED: Unresolvable company-path expansion' "$TMP/err.txt" \
        || fail 'company-specific diagnostic is used for unresolved company paths'
      grep -Fq 'Session company_slug: indigo' "$TMP/err.txt" \
        || fail 'diagnostic names the bound Indigo company'
      echo 'PASS: unresolved expansion diagnostic names the bound company'
      ;;
    *) fail "unknown case: $id" ;;
  esac
}

if [ "$CASE" = all ]; then
  for id in expansion heredoc diagnostic-reason diagnostic-company; do run_case "$id"; done
else
  run_case "$CASE"
fi
