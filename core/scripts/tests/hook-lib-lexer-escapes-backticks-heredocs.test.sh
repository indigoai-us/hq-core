#!/usr/bin/env bash
# hq-core: public
# Regression tests for three command shapes that the shared shell lexer
# (hq_shell_simple_commands in core/scripts/hook-lib.sh) read differently from
# Bash, so a write into a protected folder got past block-core-writes-bash:
#
# 1. ANSI-C strings ($'...') whose escapes spell a protected name. The lexer
#    found the end of the string but kept the escapes undecoded, so the guard
#    compared the escaped text, not the word Bash runs.
# 2. A backtick substitution holding a #. Bash reads the text between the
#    backticks on its own, so a # there is a comment only up to the closing
#    backtick, and a quote there ends at the closing backtick too. The lexer
#    read the comment, or the quote, to the end of the line.
# 3. A heredoc body holding an apostrophe. Bash reads the body as data up to
#    the delimiter line. The lexer read it as shell, so the apostrophe opened
#    a quote that hid the commands after the heredoc.
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
NL=$'\n'
TAB=$'\t'

pass() { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "FAIL [$1]" >&2; }

# has_line <command> <record with | between words> <label> [mode]
# The lexer prints exactly this record (one output line) for the command.
has_line() {
  local cmd="$1" want="$2" label="$3" mode="${4:-}" records line found=0
  records="$(hq_shell_simple_commands "$cmd" "$mode" | tr '\037' '|')" || records=""
  while IFS= read -r line; do
    [ "$line" = "$want" ] && found=1
  done <<< "$records"
  if [ "$found" -eq 1 ]; then pass; else fail "$label: no '$want' record in: $(printf '%s' "$records" | tr '\n' '~')"; fi
}

# record_count <command> <count> <label> [mode]
record_count() {
  local cmd="$1" want="$2" label="$3" mode="${4:-}" records n
  records="$(hq_shell_simple_commands "$cmd" "$mode")" || records=""
  if [ -z "$records" ]; then n=0; else n="$(printf '%s\n' "$records" | wc -l | tr -d ' ')"; fi
  if [ "$n" = "$want" ]; then pass; else fail "$label: expected $want records, got $n"; fi
}

CP_HOOK='cp|evil.sh|.claude/hooks/x.sh'

# --- 1. ANSI-C escapes are decoded ----------------------------------------
has_line "cp evil.sh \$'\\x2eclaude/hooks/x.sh'" "$CP_HOOK" 'hex escape for the dot is decoded'
has_line "cp evil.sh \$'.claude/hoo\\x6bs/x.sh'" "$CP_HOOK" 'hex escape for a letter is decoded'
has_line "cp evil.sh \$'\\056claude/hooks/x.sh'" "$CP_HOOK" 'octal escape is decoded'
has_line "cp evil.sh \$'\\u002eclaude/hooks/x.sh'" "$CP_HOOK" 'four-digit unicode escape is decoded'
has_line "cp evil.sh .cla\$'\\x75'de/hooks/x.sh" "$CP_HOOK" 'an escape in the middle of a word is decoded'
has_line "\$'cp' evil.sh .claude/hooks/x.sh" "$CP_HOOK" 'an ANSI-C command name reads as the command'
# Bash ends the rest of the string at a NUL byte, then goes on with the word.
has_line "cp evil.sh \$'.claude/hooks/x\\x00junk'.sh" "$CP_HOOK" 'a NUL escape ends the string as in Bash'
# The raw form still shows the word as written.
has_line "cp evil.sh \$'\\x2eclaude/hooks/x.sh'" "cp|evil.sh|\$'\\x2eclaude/hooks/x.sh'" \
  'raw mode keeps the ANSI-C word as written' raw
# A decoded unit separator must not split the word into two argv words.
has_line "echo \$'a\\037b'" 'echo|a?b' 'a decoded separator byte stays inside its word'
record_count "printf \$'%s\\t' x" 1 'an unambiguous escape prints one record'
# Bash 3.2 has no \u or \U escape, so the word has two readings. Both records
# are printed, in every mode, so raw output still lines up.
has_line "cp evil.sh \$'core/\\U0000002e\\U0000002e/x'" 'cp|evil.sh|core/../x' '\U is decoded as Bash 5 reads it'
has_line "cp evil.sh \$'core/\\U0000002e\\U0000002e/x'" 'cp|evil.sh|core/\U0000002e\U0000002e/x' \
  '\U is also read as Bash 3.2 reads it'
record_count "cp evil.sh \$'core/\\U0000002e/x'" 2 'an escape with two readings prints two records'
record_count "cp evil.sh \$'core/\\U0000002e/x'" 2 'raw mode prints the same two records' raw
has_line "cp evil.sh \$'.claude/hoo\\u006bs/x.sh'" 'cp|evil.sh|.claude/hoo\u006bs/x.sh' \
  '\u is also read as Bash 3.2 reads it (as written)'
# A decoded newline, tab or space must not split the record or the target
# word: guards read records line by line and split targets on whitespace.
has_line "X=\$'\\n' cp evil.sh .claude/hooks/x.sh" 'X=?|cp|evil.sh|.claude/hooks/x.sh' \
  'a decoded newline in an assignment prefix stays in its word'
record_count "X=\$'\\n' git push" 1 'a decoded newline does not split the record'
record_count "X=\$'\\n' git push" 1 'a decoded newline does not split the raw record' raw
has_line "cp evil.sh \$'\\x0a' .claude/hooks/" 'cp|evil.sh|?|.claude/hooks/' 'a hex newline stays one word'
has_line "cp evil.sh \$'\\012' .claude/hooks/" 'cp|evil.sh|?|.claude/hooks/' 'an octal newline stays one word'
has_line "cp evil.sh .claude/hooks/x\$'\\t'y.sh" 'cp|evil.sh|.claude/hooks/x?y.sh' 'a decoded tab stays inside the target'
has_line "cp evil.sh .claude/hooks/x\$'\\x20'y.sh" 'cp|evil.sh|.claude/hooks/x?y.sh' 'a decoded space stays inside the target'

# --- 2. Backtick substitutions start a new parse -------------------------
has_line "echo \`#'\`; cp evil.sh .claude/hooks/x.sh" "$CP_HOOK" 'a quote in a comment inside backticks does not hide the next command'
has_line "echo \`echo #\`; cp evil.sh .claude/hooks/x.sh" "$CP_HOOK" 'a comment inside backticks ends at the closing backtick'
has_line "echo \`echo # it's\` b; cp evil.sh .claude/hooks/x.sh" "$CP_HOOK" 'an apostrophe in a comment inside backticks does not hide the next command'
has_line "x=\`#'\`; cp evil.sh .claude/hooks/x.sh" "$CP_HOOK" 'a comment right after an opening backtick in an assignment'
has_line "echo \`echo '\`; cp evil.sh .claude/hooks/x.sh" "$CP_HOOK" 'an open single quote ends at the closing backtick'
has_line "echo \`echo \"\`; cp evil.sh .claude/hooks/x.sh" "$CP_HOOK" 'an open double quote ends at the closing backtick'
has_line "echo \`echo '\\\`'\`; cp evil.sh .claude/hooks/x.sh" "$CP_HOOK" 'an escaped backtick inside a quote does not end the substitution'
# A # that does not start a word inside backticks is not a comment.
# The command in the backticks is its own record (see
# hook-lib-lexer-substitutions.test.sh), and the # stays in its word.
has_line "echo \`echo a#b\` c" 'echo|a#b' 'a # inside a word in backticks is not a comment'

# --- 3. Heredoc bodies are data ------------------------------------------
has_line "cat <<EOF${NL}don't${NL}EOF${NL}cp evil.sh .claude/hooks/x.sh" "$CP_HOOK" \
  'an apostrophe in a heredoc body does not hide the next command'
has_line "cat <<'EOF'${NL}don't${NL}EOF${NL}cp evil.sh .claude/hooks/x.sh" "$CP_HOOK" \
  'an apostrophe in a quoted heredoc body does not hide the next command'
has_line "cat <<\"EOF\"${NL}say \"hi${NL}EOF${NL}cp evil.sh .claude/hooks/x.sh" "$CP_HOOK" \
  'a double quote in a heredoc body does not hide the next command'
has_line "cat <<-EOF${NL}${TAB}don't${NL}${TAB}EOF${NL}cp evil.sh .claude/hooks/x.sh" "$CP_HOOK" \
  'a tab-stripped heredoc ends at its indented delimiter'
has_line "cat <<- EOF${NL}${TAB}don't${NL}${TAB}EOF${NL}cp evil.sh .claude/hooks/x.sh" "$CP_HOOK" \
  'a tab-stripped heredoc with a space before the delimiter'
has_line "cat <<A <<B${NL}it's${NL}A${NL}don't${NL}B${NL}cp evil.sh .claude/hooks/x.sh" "$CP_HOOK" \
  'two heredocs on one line are read one after the other'
has_line "cat <<EOF; cp evil.sh .claude/hooks/x.sh${NL}don't${NL}EOF" "$CP_HOOK" \
  'a command after the heredoc operator on the same line is still read'
has_line "cat <<EOF${NL}\$(echo ')${NL}EOF${NL}cp evil.sh .claude/hooks/x.sh" "$CP_HOOK" \
  'a quote left open in a body substitution ends with the body'
# Commands in an unquoted body still run in Bash, so they stay visible.
has_line "cat <<EOF${NL}don't \$(cp evil.sh .claude/hooks/x.sh)${NL}EOF" "$CP_HOOK" \
  'a command substitution in an unquoted body is still read as a command'
has_line "cat <<EOF${NL}\$(cp evil.sh '.claude/hooks/x.sh')${NL}EOF" "$CP_HOOK" \
  'quotes inside a body substitution are read as quotes'
# A here-string is not a heredoc.
has_line "cat <<<\"don't\"; cp evil.sh .claude/hooks/x.sh" "$CP_HOOK" 'a here-string is not a heredoc'
# An arithmetic shift looks like a heredoc. The lines after it are still read,
# with quotes dropped from words, so nothing is hidden.
has_line "echo \$((1<<2))${NL}cp evil.sh '.claude/hooks/x.sh'" "$CP_HOOK" \
  'an arithmetic shift does not hide the lines after it'
# A << inside arithmetic is a shift, so it starts no heredoc: comments, quotes
# and ANSI-C strings on the lines after it are read as shell.
has_line "echo \$((1<<2))${NL}cp evil.sh .claude/hooks/x.sh # it's" "$CP_HOOK" \
  'a comment after an arithmetic shift is still a comment'
has_line "echo \$((1<<2))${NL}cp evil.sh \$'.claude/hooks/x.sh'" "$CP_HOOK" \
  'an ANSI-C string after an arithmetic shift is still decoded'
has_line "(( z = 1 << 2 ))${NL}cp evil.sh \$'.claude/hooks/x.sh'" "$CP_HOOK" \
  'a shift in an arithmetic command starts no heredoc'
has_line "if (( 1 << 2 )); then :; fi${NL}cp evil.sh \$'.claude/hooks/x.sh'" "$CP_HOOK" \
  'a shift in an arithmetic test after if starts no heredoc'
has_line "echo \$[1<<2]${NL}cp evil.sh \$'.claude/hooks/x.sh'" "$CP_HOOK" \
  'a shift in old-style arithmetic starts no heredoc'
# Bash also reads << as a shift inside ${...}, $[ ... ] and the subscript of
# name[...] at an assignment spot, and a heredoc inside backticks ends at the
# closing backtick. None of them starts a heredoc, so a comment on a later
# line is still a comment and cannot replace the write target.
has_line "echo \${x:0:1<<1}${NL}cp evil.sh .claude/hooks/x.sh #" "$CP_HOOK" \
  'a shift in a substring expansion starts no heredoc'
has_line "echo \${#x}\${x:1<<1}${NL}cp evil.sh .claude/hooks/x.sh # note" "$CP_HOOK" \
  'a shift in a second substring expansion starts no heredoc'
has_line "a[1<<2]=3${NL}cp evil.sh .claude/hooks/x.sh # note" "$CP_HOOK" \
  'a shift in an array subscript starts no heredoc'
has_line "a[ 1 << 2 ]=3${NL}cp evil.sh .claude/hooks/x.sh # note" "$CP_HOOK" \
  'a spaced shift in an array subscript starts no heredoc'
has_line "b=1 a[1<<2]=3${NL}cp evil.sh .claude/hooks/x.sh # note" "$CP_HOOK" \
  'a shift in a subscript after another assignment starts no heredoc'
has_line "echo \$[ 1 << 2 ]${NL}cp evil.sh .claude/hooks/x.sh # it's" "$CP_HOOK" \
  'a spaced shift in old-style arithmetic starts no heredoc'
has_line "echo \`cat <<EOF\`${NL}body${NL}EOF${NL}cp evil.sh .claude/hooks/x.sh # note" "$CP_HOOK" \
  'a heredoc inside one-line backticks has no body after the backtick'
has_line "echo \${x:0:1<<1}${NL}cp evil.sh \$'.claude/hooks/x.sh'" "$CP_HOOK" \
  'an ANSI-C string after a substring shift is still decoded'
# Real heredocs next to those shapes still start: in a command argument a
# subscript-like word is not special, and a body inside multi-line backticks
# is bounded by the closing backtick.
has_line "echo a[1<<2]${NL}it's${NL}2]${NL}cp evil.sh .claude/hooks/x.sh" "$CP_HOOK" \
  'a subscript-like command argument still starts a heredoc'
has_line "x=\`cat <<EOF${NL}it's body${NL}EOF${NL}\`${NL}cp evil.sh .claude/hooks/x.sh" "$CP_HOOK" \
  'a heredoc body inside multi-line backticks does not hide the next command'
# Bash 5 reads << inside a compound array assignment as part of a subscript
# (Bash 3.2 stops at a syntax error on that line), so it starts no heredoc and
# a comment on the next line is still a comment.
has_line "a=( [1<<2]=3 )${NL}cp evil.sh .claude/hooks/x.sh # note" "$CP_HOOK" \
  'a shift in a compound array subscript starts no heredoc'
has_line "a+=( [1<<2]=3 )${NL}cp evil.sh .claude/hooks/x.sh # note" "$CP_HOOK" \
  'a shift in an appended compound array subscript starts no heredoc'
has_line "declare -a a=( [1<<2]=3 )${NL}cp evil.sh .claude/hooks/x.sh # note" "$CP_HOOK" \
  'a shift in a declare compound array subscript starts no heredoc'
has_line "declare -A m=( [k<<]=v )${NL}cp evil.sh .claude/hooks/x.sh # note" "$CP_HOOK" \
  'a << in an associative compound array key starts no heredoc'
# A heredoc after a closed compound assignment, or inside a substitution in
# one, still starts, so its body cannot hide the next command.
has_line "a=(1 2)${NL}cat <<EOF${NL}it's${NL}EOF${NL}cp evil.sh .claude/hooks/x.sh" "$CP_HOOK" \
  'a heredoc after a closed compound assignment still starts'
has_line "a=(\$(cat <<EOF${NL}it's${NL}EOF${NL}))${NL}cp evil.sh .claude/hooks/x.sh" "$CP_HOOK" \
  'a heredoc in a substitution inside a compound assignment still starts'
# A [ in a case pattern is not a subscript: the ) that ends the pattern ends
# it, so a later heredoc still starts.
has_line "case x in a) ;; b[) ;; esac${NL}cat <<EOF${NL}it's${NL}EOF${NL}cp evil.sh .claude/hooks/x.sh" "$CP_HOOK" \
  'a bracket in a case pattern does not stop a later heredoc'
# A command substitution inside \${...} reads << as a heredoc, as in Bash 5.
has_line "echo \${x:-\$(cat <<EOF${NL}it's${NL}EOF${NL})}${NL}cp evil.sh .claude/hooks/x.sh" "$CP_HOOK" \
  'a heredoc in a substitution inside a parameter expansion still starts'
has_line "a[\$(echo 1)<<2]=3${NL}cp evil.sh .claude/hooks/x.sh # note" "$CP_HOOK" \
  'a shift after a substitution in a subscript starts no heredoc'
# A backslash-newline joins two lines into one, so a shift split across it
# is still a shift. The lexer cannot look ahead past the line end, so no
# heredoc starts on a line that a backslash-newline continued.
has_line "a\\${NL}[1<<2]=3${NL}cp evil.sh .claude/hooks/x.sh # note" "$CP_HOOK" \
  'a subscript split by a line continuation starts no heredoc'
has_line "(\\${NL}(1<<2))${NL}cp evil.sh .claude/hooks/x.sh # note" "$CP_HOOK" \
  'an arithmetic command split by a line continuation starts no heredoc'
has_line "echo \$\\${NL}{x:0:1<<1}${NL}cp evil.sh .claude/hooks/x.sh # note" "$CP_HOOK" \
  'a substring expansion split by a line continuation starts no heredoc'
has_line "cp evil.sh .claude/hoo\\${NL}ks/x.sh" "$CP_HOOK" \
  'a line continuation inside a word joins the word'
# A redirection before an assignment does not stop the subscript reading.
has_line ">/dev/null a[1<<2]=3${NL}cp evil.sh .claude/hooks/x.sh # note" "$CP_HOOK" \
  'a subscript after a redirection starts no heredoc'
has_line "2>/dev/null a[1<<2]=3${NL}cp evil.sh .claude/hooks/x.sh # note" "$CP_HOOK" \
  'a subscript after an fd redirection starts no heredoc'
# A \$"..." delimiter is the quoted text without the dollar sign.
has_line "cat <<\$\"EOF\" >/dev/null${NL}hi${NL}EOF${NL}cp evil.sh .claude/hooks/x.sh # note" "$CP_HOOK" \
  'a locale-quoted heredoc delimiter ends at its text'
has_line "cp evil.sh \$\".claude/hooks/x.sh\"" "$CP_HOOK" \
  'a locale-quoted word reads without the dollar sign'
# A delimiter that starts with a substitution is not read as a heredoc.
has_line "cat <<\$(x) >/dev/null${NL}hi${NL}\$(x)${NL}cp evil.sh .claude/hooks/x.sh # note" "$CP_HOOK" \
  'a substitution heredoc delimiter does not hide the next command'
# Parentheses in heredoc body text are data: an open $(( there must not stop
# a later heredoc from starting.
has_line "cat <<'A'${NL}\$((${NL}A${NL}cat <<B${NL}don't${NL}B${NL}cp evil.sh .claude/hooks/x.sh" "$CP_HOOK" \
  'an arithmetic opener in a body does not stop the next heredoc'

# A quoted string inside a quoted heredoc body stays one word with its spaces
# (mandatory-scope-authorizer tells body text from shell words by that shape),
# and an apostrophe on a body line still cannot reach the commands after it.
has_line "python3 - <<'EOF'${NL}import os${NL}os.system('cp a \$D/out')${NL}EOF" 'cp a $D/out' \
  'a quoted string in a quoted heredoc body stays one word'
has_line "python3 - <<'EOF'${NL}import os${NL}os.system('cp a \$D/out')${NL}EOF" "'cp a \$D/out'" \
  'the quoted body string keeps its quotes in raw mode' raw
has_line "cat <<'EOF'${NL}don't${NL}EOF${NL}cp evil.sh .claude/hooks/x.sh" "$CP_HOOK" \
  'an apostrophe in a quoted body does not hide the next command'

# --- Input that ends in a backslash ---------------------------------------
records="$(hq_shell_simple_commands "cp evil.sh .claude/hooks/x.sh \\" | tr '\037' '|')" || records=""
case "$records" in
  "$CP_HOOK"*) pass ;;
  *) fail "a trailing backslash does not drop the command: got $(printf '%s' "$records" | tr '\n' '~')" ;;
esac

# --- End to end through block-core-writes-bash.sh ---------------------------
if command -v jq >/dev/null 2>&1; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  mkdir -p "$TMP/.claude/hooks" "$TMP/core/packages"
  printf '{}' > "$TMP/.claude/settings.local.json"
  H="$TMP/.claude/hooks"

  # guard <expected_exit> <command> <label>
  guard() {
    local expect="$1" cmd="$2" label="$3" rc=0 payload
    payload=$(jq -n --arg cmd "$cmd" '{tool_input: {command: $cmd}}')
    printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$TMP" bash "$HOOK" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq "$expect" ]; then pass; else fail "$label: expected exit $expect, got $rc -- cmd: $cmd"; fi
  }

  guard 2 "cp evil.sh \$'$TMP/.claude/hoo\\x6bs/x.sh'" 'an escape-spelled hooks folder is blocked'
  guard 2 "\$'cp' evil.sh $H/x.sh" 'an ANSI-C command name is blocked'
  guard 2 "cp evil.sh \$'$TMP/core/\\U0000002e\\U0000002e/x'" 'a target that is protected under Bash 3.2 is blocked'
  guard 2 "echo \`#'\`; cp evil.sh $H/x.sh" 'a quote in a comment inside backticks is blocked'
  guard 2 "echo \`echo #\`; cp evil.sh $H/x.sh" 'a comment inside backticks is blocked'
  guard 2 "echo \`echo '\`; cp evil.sh $H/x.sh" 'an open quote inside backticks is blocked'
  guard 2 "cat <<EOF${NL}don't${NL}EOF${NL}cp evil.sh $H/x.sh" 'an apostrophe in a heredoc body is blocked'
  guard 2 "cat <<'EOF'${NL}don't${NL}EOF${NL}echo x > $H/x.sh" 'a redirect after a quoted heredoc is blocked'
  guard 2 "cat <<EOF${NL}don't \$(cp evil.sh $H/x.sh)${NL}EOF" 'a write in a body substitution is blocked'
  guard 2 "X=\$'\\n' cp evil.sh $H/x.sh" 'a decoded newline before the command is blocked'
  guard 2 "cp evil.sh \$'\\x0a' $H/" 'a decoded newline between the arguments is blocked'
  guard 2 "cp evil.sh $H/x\$'\\t'y.sh" 'a decoded tab in the target is blocked'
  guard 2 "cp evil.sh $H/x\$'\\x20'y.sh" 'a decoded space in the target is blocked'
  guard 2 "echo \$((1<<2))${NL}cp evil.sh $H/x.sh # it's" 'a write after an arithmetic shift is blocked'
  guard 2 "(( z = 1 << 2 ))${NL}cp evil.sh \$'$H/x.sh'" 'a write after an arithmetic command is blocked'
  guard 2 "echo \${x:0:1<<1}${NL}cp evil.sh $H/x.sh #" 'a write after a substring shift is blocked'
  guard 2 "echo \${#x}\${x:1<<1}${NL}cp evil.sh $H/x.sh # note" 'a write after a second substring shift is blocked'
  guard 2 "a[1<<2]=3${NL}cp evil.sh $H/x.sh # note" 'a write after an array subscript shift is blocked'
  guard 2 "echo \$[ 1 << 2 ]${NL}cp evil.sh $H/x.sh # it's" 'a write after a spaced old-style shift is blocked'
  guard 2 "echo \`cat <<EOF\`${NL}body${NL}EOF${NL}cp evil.sh $H/x.sh # note" 'a write after a heredoc inside backticks is blocked'
  guard 2 "a=( [1<<2]=3 )${NL}cp evil.sh $H/x.sh # note" 'a write after a compound array subscript shift is blocked'
  guard 2 "a+=( [1<<2]=3 )${NL}cp evil.sh $H/x.sh # note" 'a write after an appended compound array shift is blocked'
  guard 2 "declare -a a=( [1<<2]=3 )${NL}cp evil.sh $H/x.sh # note" 'a write after a declare compound array shift is blocked'
  guard 2 "declare -A m=( [k<<]=v )${NL}cp evil.sh $H/x.sh # note" 'a write after an associative compound array key is blocked'
  guard 2 "case x in a) ;; b[) ;; esac${NL}cat <<EOF${NL}it's${NL}EOF${NL}cp evil.sh $H/x.sh" 'a write after a case-pattern bracket and a heredoc is blocked'
  guard 2 "echo \${x:-\$(cat <<EOF${NL}it's${NL}EOF${NL})}${NL}cp evil.sh $H/x.sh" 'a write after a heredoc inside a parameter expansion is blocked'
  guard 2 "a\\${NL}[1<<2]=3${NL}cp evil.sh $H/x.sh #z" 'a write after a continued subscript shift is blocked'
  guard 2 "(\\${NL}(1<<2))${NL}cp evil.sh $H/x.sh #z" 'a write after a continued arithmetic command is blocked'
  guard 2 ">/dev/null a[1<<2]=3${NL}cp evil.sh $H/x.sh #z" 'a write after a redirected subscript shift is blocked'
  guard 2 "cat <<\$\"EOF\" >/dev/null${NL}hi${NL}EOF${NL}cp evil.sh $H/x.sh #z" 'a write after a locale-quoted heredoc is blocked'
  guard 2 "cat <<\$(x) >/dev/null${NL}hi${NL}\$(x)${NL}cp evil.sh $H/x.sh #z" 'a write after a substitution-delimited heredoc is blocked'

  guard 0 "cat > /tmp/hq-lexer-test-out <<'EOF'${NL}don't read $H/x.sh${NL}EOF" \
    'a heredoc that names a protected path and writes outside protected paths is allowed'
  guard 0 "printf \$'%s\\n' x > /tmp/hq-lexer-test-out" 'an ANSI-C string writing outside protected paths is allowed'
  guard 0 "echo \`echo #\` > /tmp/hq-lexer-test-out" 'a comment in backticks writing outside protected paths is allowed'
  guard 0 "echo \$((1<<2)) > /tmp/hq-lexer-test-out" 'an arithmetic shift writing outside protected paths is allowed'
  guard 0 "printf \$'%s\\t%s\\n' a b > /tmp/hq-lexer-test-out" 'a tab and newline escape writing outside protected paths is allowed'

  # Wrong heredoc guesses fail closed. In each shape below the lexer starts a
  # heredoc Bash does not start, or keeps a body open after Bash has ended it.
  # The flat reading printed alongside keeps the comment cut, so the cp target
  # is still the protected path.
  W="cp evil.sh $H/x.sh # note"
  guard 2 "time -p ((1<<2))${NL}$W" 'fail closed: arithmetic after time -p'
  guard 2 "function f ((1<<2))${NL}$W" 'fail closed: arithmetic after a function name'
  guard 2 "coproc ((1<<2))${NL}$W" 'fail closed: arithmetic after coproc'
  guard 2 ">&2 a[1<<2]=3${NL}$W" 'fail closed: subscript after a >&2 redirection'
  guard 2 "2>&1 a[1<<2]=3${NL}$W" 'fail closed: subscript after a 2>&1 redirection'
  guard 2 "<<<x a[1<<2]=3${NL}$W" 'fail closed: subscript after a here-string'
  guard 2 "{fd}>/dev/null a[1<<2]=3${NL}$W" 'fail closed: subscript after a {fd} redirection'
  guard 2 "cat <<a\$(x) >/dev/null${NL}body${NL}a\$(x)${NL}$W" 'fail closed: substitution in the delimiter'
  guard 2 "echo \$(cat <<EOF${NL}hi${NL}EOF)${NL}$W" 'fail closed: body ended by EOF) inside a substitution'
  guard 2 "echo \${x:-\`echo }\`<<1}${NL}$W" 'fail closed: brace inside backticks in a parameter expansion'
  guard 2 "a[\`echo ]\`<<2]=3${NL}$W" 'fail closed: bracket inside backticks in a subscript'
  guard 2 "a=( \$(case x in y) echo 1;; esac) [1<<2]=3 )${NL}$W" 'fail closed: case pattern inside a compound assignment'
else
  echo "SKIP: guard cases (jq not available)"
fi

# --- End to end through mandatory-scope-authorizer.sh ------------------------
# The same five shapes, writing into another company than the bound one.
if command -v jq >/dev/null 2>&1; then
  STMP="$(mktemp -d)"; STMP="$(cd "$STMP" && pwd -P)"
  trap 'rm -rf "${TMP:-}" "$STMP"' EXIT
  mkdir -p "$STMP/.claude/hooks" "$STMP/core/scripts/lib" "$STMP/.codex/hooks" \
    "$STMP/companies/indigo/settings" "$STMP/companies/otherco/settings" \
    "$STMP/workspace/sessions/sess-bound" "$STMP/home/.hq"
  cp "$ROOT/.claude/hooks/mandatory-scope-authorizer.sh" "$ROOT/.claude/hooks/bash-arith-subst-guard-lib.sh" "$STMP/.claude/hooks/"
  cp "$ROOT/core/scripts/lib/session-authz.sh" "$ROOT/core/scripts/lib/session-scope-capability.sh" \
    "$ROOT/core/scripts/lib/hook-caller-lineage.sh" "$ROOT/core/scripts/lib/session-id.sh" "$STMP/core/scripts/lib/"
  cp "$ROOT/core/scripts/hqd-hook-flag-cache-lib.sh" "$LIB" "$STMP/core/scripts/"
  cp "$ROOT/.codex/hooks/codex-explicit-path-flag.cjs" "$STMP/.codex/hooks/"
  printf 'companies:\n  indigo:\n    name: Indigo\n  otherco:\n    name: otherco\n' > "$STMP/companies/manifest.yaml"
  printf 'sess-bound\n' > "$STMP/workspace/sessions/.current"
  printf 'company_slug: indigo\n' > "$STMP/workspace/sessions/sess-bound/meta.yaml"
  (
    export HOME="$STMP/home"
    # shellcheck source=core/scripts/lib/session-scope-capability.sh
    . "$ROOT/core/scripts/lib/session-scope-capability.sh"
    session_scope_mint "$STMP" "sess-bound" "indigo"
  )
  OT=companies/otherco/settings/x.md

  # scope <expected_exit> <command> <label>
  scope() {
    local expect="$1" cmd="$2" label="$3" rc=0
    jq -n --arg cwd "$STMP" --arg command "$cmd" \
      '{tool_name: "Bash", session_id: "sess-bound", cwd: $cwd, tool_input: {command: $command}}' \
      | HOME="$STMP/home" bash "$STMP/.claude/hooks/mandatory-scope-authorizer.sh" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq "$expect" ]; then pass; else fail "$label: expected exit $expect, got $rc -- cmd: $cmd"; fi
  }

  scope 2 "echo \${x:0:1<<1}${NL}cp evil.sh $OT #" 'scope: a write after a substring shift is blocked'
  scope 2 "echo \${#x}\${x:1<<1}${NL}cp evil.sh $OT # note" 'scope: a write after a second substring shift is blocked'
  scope 2 "a[1<<2]=3${NL}cp evil.sh $OT # note" 'scope: a write after an array subscript shift is blocked'
  scope 2 "echo \$[ 1 << 2 ]${NL}cp evil.sh $OT # it's" 'scope: a write after a spaced old-style shift is blocked'
  scope 2 "echo \`cat <<EOF\`${NL}body${NL}EOF${NL}cp evil.sh $OT # note" 'scope: a write after a heredoc inside backticks is blocked'
  scope 2 "a=( [1<<2]=3 )${NL}cp evil.sh $OT # note" 'scope: a write after a compound array subscript shift is blocked'
  scope 2 "declare -A m=( [k<<]=v )${NL}cp evil.sh $OT # note" 'scope: a write after an associative compound array key is blocked'
  scope 2 "case x in a) ;; b[) ;; esac${NL}cat <<EOF${NL}it's${NL}EOF${NL}cp evil.sh $OT" 'scope: a write after a case-pattern bracket and a heredoc is blocked'
  scope 2 "echo \${x:-\$(cat <<EOF${NL}it's${NL}EOF${NL})}${NL}cp evil.sh $OT" 'scope: a write after a heredoc inside a parameter expansion is blocked'
  # The arithmetic check blocks the substring, subscript and backtick shapes on
  # its own. The spaced old-style shape reaches the path check, so a write into
  # the bound company is allowed and the row above is a path decision.
  scope 0 "echo \$[ 1 << 2 ]${NL}cp evil.sh companies/indigo/settings/x.md # it's" \
    'scope: a write into the bound company after a spaced old-style shift is allowed'
else
  echo "SKIP: scope cases (jq not available)"
fi

echo "hook-lib-lexer-escapes-backticks-heredocs: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
