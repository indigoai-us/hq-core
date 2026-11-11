#!/usr/bin/env bash
# hq-core: public
# Regression tests for ANSI-C quoting and the PID expansion in the shared shell
# lexer (hq_shell_simple_commands in core/scripts/hook-lib.sh).
#
# Bash reads $'...' as an ANSI-C string, where a backslash escapes the next
# character, so an escaped quote does not end it. Bash also reads $$ as the PID
# before any quote, so in $$'...' the quote is an ordinary single quote, where a
# backslash escapes nothing. A lexer that gets either wrong carries a quote open
# over the commands that follow and hides them from every Bash guard that uses
# it. The cases below check the lexer's records directly, then check that
# block-core-writes-bash.sh still blocks the hidden command end to end.
#
# Kept out of block-core-writes-bash.test.sh on purpose: the guard parity
# harness replays that file against the reviewed baseline hook-lib.sh.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
LIB="$ROOT/core/scripts/hook-lib.sh"
HOOK="$ROOT/.claude/hooks/block-core-writes-bash.sh"
[ -f "$LIB" ] || { echo "FAIL: hook-lib.sh missing at $LIB" >&2; exit 1; }

# shellcheck source=core/scripts/hook-lib.sh
. "$LIB"

PASS=0
FAIL=0
US=$'\037'

pass() { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "FAIL [$1]" >&2; }

# has_record <command> <word1> <word2> <label>
# The lexer emits a record whose first two words are word1 and word2, so that
# simple command is visible to the guards.
has_record() {
  local cmd="$1" want="$2$US$3" label="$4" records line found=0
  records="$(hq_shell_simple_commands "$cmd")" || records=""
  while IFS= read -r line; do
    case "$line" in
      "$want$US"*|"$want") found=1 ;;
    esac
  done <<< "$records"
  if [ "$found" -eq 1 ]; then pass; else fail "$label: no '$2 $3' record in: $(printf '%s' "$records" | tr '\037' '|')"; fi
}

# record_count <command> <count> <label>
record_count() {
  local cmd="$1" want="$2" label="$3" records n
  records="$(hq_shell_simple_commands "$cmd")" || records=""
  if [ -z "$records" ]; then n=0; else n="$(printf '%s\n' "$records" | wc -l | tr -d ' ')"; fi
  if [ "$n" = "$want" ]; then pass; else fail "$label: expected $want records, got $n"; fi
}

# --- Lexer records ---------------------------------------------------------
# A quote after $$ is ordinary, so the cp is its own command.
has_record "echo \$\$'\\'; cp evil.sh .claude/hooks/block-core-writes-bash.sh; echo '\\'" \
  cp evil.sh 'quote after $$ does not hide the next command'
record_count "echo \$\$'\\'; cp evil.sh .claude/hooks/block-core-writes-bash.sh; echo '\\'" 3 \
  'quote after $$ splits into three commands'
# An escaped quote inside $'...' does not end the string.
has_record "echo \$'\\''; cp evil.sh .claude/hooks/x.sh" \
  cp evil.sh 'escaped quote in ANSI-C string does not hide the next command'
has_record "echo \$'a\\'b'; cp evil.sh .claude/hooks/x.sh" \
  cp evil.sh 'escaped quote mid ANSI-C string does not hide the next command'
has_record "x=\$'\\''; cp evil.sh .claude/hooks/x.sh" \
  cp evil.sh 'ANSI-C string in an assignment does not hide the next command'
# An odd run of dollar signs still ends in one that opens an ANSI-C string, as
# in Bash, so the escaped quote stays inside it and the string ends at the
# final quote: one echo record.
record_count "echo \$\$\$'a\\'b'" 1 'odd dollar run still opens an ANSI-C string'
# Plain ANSI-C strings keep their words.
has_record "printf \$'%s\\n' hello" printf "\$%s\\n" 'ANSI-C word keeps its dollar sign and escapes'

# --- End to end through block-core-writes-bash.sh ---------------------------
if command -v jq >/dev/null 2>&1; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  mkdir -p "$TMP/.claude/hooks" "$TMP/core/packages/x"
  printf '{}' > "$TMP/.claude/settings.local.json"

  # guard <expected_exit> <command> <label>
  guard() {
    local expect="$1" cmd="$2" label="$3" rc=0 payload
    payload=$(jq -n --arg cmd "$cmd" '{tool_input: {command: $cmd}}')
    printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$TMP" bash "$HOOK" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq "$expect" ]; then pass; else fail "$label: expected exit $expect, got $rc -- cmd: $cmd"; fi
  }

  guard 2 "echo \$\$'\\'; cp evil.sh $TMP/.claude/hooks/block-core-writes-bash.sh; echo '\\'" \
    'a quote after $$ does not hide a later cp into .claude/hooks'
  guard 2 "echo \$\$'\\' > $TMP/.claude/hooks/x.sh; echo '\\'" \
    'a quote after $$ does not hide a redirect into .claude/hooks'
  guard 2 "echo \$'\\''; cp evil.sh $TMP/.claude/hooks/x.sh" \
    'an escaped quote in an ANSI-C string does not hide a later cp'
  guard 2 "echo \$'\\'' > $TMP/.claude/hooks/x.sh" \
    'an escaped quote in an ANSI-C string does not hide a redirect'
  guard 2 "echo \$'a\\'b'; cp evil.sh $TMP/.claude/hooks/x.sh" \
    'an escaped quote mid ANSI-C string does not hide a later cp'
  guard 2 "x=\$'\\''; cp evil.sh $TMP/.claude/hooks/x.sh" \
    'an ANSI-C assignment does not hide a later cp'
  guard 0 "echo \$'a\\'b' > /tmp/hq-lexer-test-out" \
    'an ANSI-C string with a redirect outside protected paths is allowed'
  guard 0 "echo \$\$ > /tmp/hq-lexer-test-pid" \
    'a plain PID expansion is allowed'
else
  echo "SKIP: guard cases (jq not available)"
fi

echo "hook-lib-ansi-c-lexer: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
