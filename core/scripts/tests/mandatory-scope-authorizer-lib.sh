#!/usr/bin/env bash
# hq-core: public
# Shared setup and helpers for the mandatory-scope-authorizer regression suite.
# Sourced by mandatory-scope-authorizer.test.sh and
# mandatory-scope-authorizer-feedback-shapes.test.sh, which CI runs in
# parallel. Not a test on its own.


ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# Canonicalize. On macOS mktemp -d hands back /var/folders/... while /var is a
# symlink to /private/var, and the hook resolves its own root with `pwd -P`. The
# payload paths would then sit "outside" HQ_ROOT, every absolute-path case would
# normalize to empty, and the suite would report a pass-through as an allow —
# on this machine every case below [1] failed for that reason alone, against an
# untouched hook. CI runs on Linux, where /tmp is real, so it never showed there.
# Same treatment as core/scripts/tests/workflow-runner.test.sh.
TMP="$(cd "$TMP" && pwd -P)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

REGRESSION_FAILURES=0

expect_exit() {
  local expected="$1" actual="$2" case_name="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $case_name"
  else
    echo "FAIL: $case_name (expected exit $expected, got $actual)" >&2
    REGRESSION_FAILURES=$((REGRESSION_FAILURES + 1))
  fi
}

install_fixture() {
  local bound="${1:-}"
  rm -rf "${TMP:?}"/*
  mkdir -p "$TMP/.claude/hooks" "$TMP/core/scripts/lib" "$TMP/core/scripts" \
    "$TMP/companies/indigo/settings" "$TMP/companies/otherco/settings" \
    "$TMP/companies/cmp_FIXTURE/settings" "$TMP/companies/cmp_OTHER/settings" \
    "$TMP/companies/_template" "$TMP/core/docs" "$TMP/personal" \
    "$TMP/workspace/sessions/sess-bound" "$TMP/home/.hq"
  cp "$ROOT/.claude/hooks/mandatory-scope-authorizer.sh" "$TMP/.claude/hooks/"
  cp "$ROOT/.claude/hooks/bash-arith-subst-guard-lib.sh" "$ROOT/.claude/hooks/path-fold-lib.sh" "$TMP/.claude/hooks/"
  cp "$ROOT/core/scripts/lib/session-authz.sh" "$TMP/core/scripts/lib/"
  cp "$ROOT/core/scripts/lib/session-scope-capability.sh" "$TMP/core/scripts/lib/"
  cp "$ROOT/core/scripts/lib/hook-caller-lineage.sh" "$TMP/core/scripts/lib/"
  cp "$ROOT/core/scripts/lib/session-id.sh" "$TMP/core/scripts/lib/"
  cp "$ROOT/core/scripts/hqd-hook-flag-cache-lib.sh" "$TMP/core/scripts/"
  mkdir -p "$TMP/.codex/hooks"
  cp "$ROOT/.codex/hooks/codex-explicit-path-flag.cjs" "$TMP/.codex/hooks/"
  cp "$ROOT/core/scripts/hook-lib.sh" "$TMP/core/scripts/"
  chmod +x "$TMP/.claude/hooks/mandatory-scope-authorizer.sh"

  printf 'companies:\n  indigo:\n    name: Indigo\n  otherco:\n    name: otherco\n' \
    > "$TMP/companies/manifest.yaml"
  touch "$TMP/companies/indigo/settings/.keep" "$TMP/companies/otherco/settings/.keep"
  touch "$TMP/core/docs/readme.md" "$TMP/personal/note.md" "$TMP/companies/_template/readme.md"
  printf 'sess-bound\n' > "$TMP/workspace/sessions/.current"
  export HOME="$TMP/home"

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
  printf '%s' "$payload" | "${BASH_BIN:-bash}" "$TMP/.claude/hooks/mandatory-scope-authorizer.sh" 2>"$TMP/err.txt" || rc=$?
  printf '%s' "$rc"
}

# Path blocks keep their Reason line. Arithmetic blocks carry their own
# explanation and rewrite hint, without claiming a company/path violation.
has_expected_block_reason() {
  if grep -q '^BLOCKED: Bash arithmetic check\.' "$TMP/err.txt"; then
    grep -Eq '^BLOCKED: Bash arithmetic check\. .+\.$' "$TMP/err.txt" \
      && grep -q '^Rewrite: assign a literal number or an arithmetic result ' "$TMP/err.txt" \
      && ! grep -Eq 'Cross-company|Path:' "$TMP/err.txt"
  else
    grep -Eq '^Reason: .+' "$TMP/err.txt"
  fi
}

# Arguments: <feedback id> <expected exit> <command> [payload cwd]
scope_112_case() {
  local id="$1" expect="$2" command="$3" cwd="${4:-$TMP}" rc
  payload="$(jq -cn --arg cwd "$cwd" --arg command "$command" \
    '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
  rc="$(run_hook "$payload")"
  expect_exit "$expect" "$rc" "feedback_$id: $(printf '%s' "$command" | tr '\n' ' ')"
}

# The suite redefines run_hook_env partway through part 1; this is the
# later definition, which is the one in effect for the feedback-shapes part.
run_hook_env() {
  # run_hook_env <payload> [NAME=value ...]: the hook with extra environment.
  local payload="$1" rc=0
  shift
  : > "$TMP/err.txt"
  printf '%s' "$payload" | env "$@" "${BASH_BIN:-bash}" "$TMP/.claude/hooks/mandatory-scope-authorizer.sh" 2>"$TMP/err.txt" || rc=$?
  printf '%s' "$rc"
}
