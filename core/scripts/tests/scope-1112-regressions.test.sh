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
  cp "$ROOT/.claude/hooks/bash-arith-subst-guard-lib.sh" "$TMP/.claude/hooks/"
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
    data-file-reference)
      # A file written from a quoted heredoc and then handed to gh/git as a
      # message body is read as text, never executed. Its prose (here a
      # backticked `/fde`) must not be scanned as shell.
      command=$'cat > workspace/pr.md <<\'EOF\'\nAdds a page at `/fde`.\nEOF\ngh pr create -R o/r --title t --body-file workspace/pr.md'
      rc="$(run_hook "$command")"
      expect_exit 0 "$rc" 'heredoc file passed to gh pr create --body-file is data'
      command=$'cat > workspace/msg.txt <<\'EOF\'\nShip `/fde` and the $2,000 plan.\nEOF\ngit -C repos/x commit -F workspace/msg.txt'
      rc="$(run_hook "$command")"
      expect_exit 0 "$rc" 'heredoc file passed to git commit -F is data'
      command=$'cat > workspace/pr.md <<\'EOF\'\nAdds a page at `/fde`.\nEOF\ngh issue comment 3 -R o/r --body-file=workspace/pr.md'
      rc="$(run_hook "$command")"
      expect_exit 0 "$rc" 'heredoc file passed to gh issue comment --body-file= is data'
      # The same file run later stays scanned and a foreign company is denied.
      command=$'cat > workspace/s.sh <<\'EOF\'\ncat companies/otherco/settings/x\nEOF\ngh pr create -R o/r --body-file workspace/s.sh\nbash workspace/s.sh'
      rc="$(run_hook "$command")"
      expect_exit 2 "$rc" 'a body file that is also executed stays scanned'
      command=$'cat > workspace/s.sh <<\'EOF\'\ncat companies/otherco/settings/x\nEOF\ncat workspace/s.sh | sh'
      rc="$(run_hook "$command")"
      expect_exit 2 "$rc" 'a written file piped to a shell stays scanned'
      command=$'cat > workspace/s.sh <<\'EOF\'\ncat companies/otherco/settings/x\nEOF\ngh pr create -R o/r --body-file workspace/s.sh --title "$(cat workspace/s.sh)"'
      rc="$(run_hook "$command")"
      expect_exit 2 "$rc" 'a second, non-data reference to the file stays scanned'
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
  for id in expansion heredoc data-file-reference diagnostic-reason diagnostic-company; do run_case "$id"; done
else
  run_case "$CASE"
fi
