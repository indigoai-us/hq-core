#!/usr/bin/env bash
# hq-core: public
# Regression tests for shell comments and unterminated quotes in the shared
# shell lexer (hq_shell_simple_commands in core/scripts/hook-lib.sh).
#
# Bash ignores everything after an unquoted # that starts a word. A lexer that
# reads a quote inside such a comment as the start of a string emits no record,
# so every Bash guard that uses it sees nothing to check. Input that ends inside
# a quote must still show the words before the quote.
#
# Kept out of block-core-writes-bash.test.sh on purpose: the guard parity
# harness replays that file against the reviewed baseline hook-lib.sh, which
# does not have this lexer change.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
HOOK="$ROOT/.claude/hooks/block-core-writes-bash.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.claude/hooks" "$TMP/core/packages"
printf '{}' > "$TMP/.claude/settings.local.json"

PASS=0
FAIL=0

# run <expected_exit> <command> <label>
run() {
  local expect="$1" cmd="$2" label="$3" rc=0 payload
  payload=$(jq -n --arg cmd "$cmd" '{tool_input: {command: $cmd}}')
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$TMP" bash "$HOOK" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq "$expect" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL [$label]: expected exit $expect, got $rc -- cmd: $cmd" >&2
  fi
}

# --- A quote inside a trailing comment must not hide the command ---------
# Bash ignores everything after an unquoted # that starts a word, so the cp
# runs; the shell lexer used to read the quote as the start of a string and
# emit no record at all.
run 2 "cp evil.sh $TMP/.claude/hooks/x.sh #'" \
  'single quote in a trailing comment does not hide a cp into .claude/hooks'
run 2 "cp evil.sh $TMP/.claude/hooks/x.sh # it's done" \
  'apostrophe in a trailing comment does not hide a cp into .claude/hooks'
run 2 "echo x > $TMP/.claude/hooks/x.sh #\"" \
  'double quote in a trailing comment does not hide a redirect'
run 2 "cp evil.sh $TMP/.claude/hooks/a#b" \
  'a # inside a word is not a comment'
# Input that ends inside a quote still shows the words before the quote.
run 2 "rm -rf $TMP/core/packages '" \
  'an unterminated quote does not hide earlier protected targets'
lexed="$(bash -c '. "$1"; hq_shell_simple_commands "$2"' _ "$ROOT/core/scripts/hook-lib.sh" "cp a b #'")"
if [ "$lexed" = "cp"$'\037'"a"$'\037'"b" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); echo "FAIL [lexer-comment]: record was [${lexed//$'\037'/<US>}]" >&2
fi

echo "hook-lib-comment-lexer: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
