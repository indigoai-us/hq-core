#!/usr/bin/env bash
# hq-core: public
# Regression tests for two command shapes that the shared shell lexer
# (hq_shell_simple_commands in core/scripts/hook-lib.sh) read differently from
# Bash, so a write into a protected folder got past block-core-writes-bash:
#
# 1. A command substitution inside double quotes ($( or a backtick). The
#    lexer kept the whole quoted text as one word, so the command inside it
#    was never read as a command.
# 2. A backtick at the start of a word. The lexer glued the backtick to the
#    command name, so the command inside was not recognised.
#
# The lexer now reads the text of each such substitution as its own commands
# and prints them as records of their own. The outer record keeps the
# substitution text in its word, as before. A cd inside a substitution is not
# printed, because guards read records as one flat list and would apply it to
# the commands after the substitution.
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

pass() { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "FAIL [$1]" >&2; }

# has_line <command> <record with | between words> <label> [mode]
has_line() {
  local cmd="$1" want="$2" label="$3" mode="${4:-}" records line found=0
  records="$(hq_shell_simple_commands "$cmd" "$mode" | tr '\037' '|')" || records=""
  while IFS= read -r line; do
    [ "$line" = "$want" ] && found=1
  done <<< "$records"
  if [ "$found" -eq 1 ]; then pass; else fail "$label: no '$want' record in: $(printf '%s' "$records" | tr '\n' '~')"; fi
}

# no_line <command> <record> <label>
no_line() {
  local cmd="$1" want="$2" label="$3" records line found=0
  records="$(hq_shell_simple_commands "$cmd" | tr '\037' '|')" || records=""
  while IFS= read -r line; do
    [ "$line" = "$want" ] && found=1
  done <<< "$records"
  if [ "$found" -eq 0 ]; then pass; else fail "$label: unexpected '$want' record in: $(printf '%s' "$records" | tr '\n' '~')"; fi
}

# same_count <command> <label>: default and raw output print the same lines
# (records and the newlines inside words), so callers that read both modes
# side by side line up.
same_count() {
  local cmd="$1" label="$2" a b
  a="$(hq_shell_simple_commands "$cmd" | wc -l | tr -d ' ')"
  b="$(hq_shell_simple_commands "$cmd" raw | wc -l | tr -d ' ')"
  if [ "$a" = "$b" ]; then pass; else fail "$label: default=$a raw=$b"; fi
}

CP_HOOK='cp|evil.sh|.claude/hooks/x.sh'

# --- 1. Substitutions inside double quotes are read as commands ------------
has_line 'echo "$(cp evil.sh .claude/hooks/x.sh)"' "$CP_HOOK" 'a $( inside double quotes is read as a command'
has_line 'echo "`cp evil.sh .claude/hooks/x.sh`"' "$CP_HOOK" 'a backtick inside double quotes is read as a command'
has_line 'x="$(cp evil.sh .claude/hooks/x.sh)"' "$CP_HOOK" 'a quoted substitution in an assignment is read as a command'
has_line 'echo "a $(cp evil.sh .claude/hooks/x.sh) b"' "$CP_HOOK" 'a substitution in the middle of a quoted word'
has_line 'echo "pre`cp evil.sh .claude/hooks/x.sh`post"' "$CP_HOOK" 'a backtick in the middle of a quoted word'
has_line 'echo "x" "$(true)" "$(cp evil.sh .claude/hooks/x.sh)"' "$CP_HOOK" 'the second of two quoted substitutions'
has_line 'echo "$(echo "`cp evil.sh .claude/hooks/x.sh`")"' "$CP_HOOK" 'a backtick in quotes inside a quoted substitution'
has_line 'echo "$(echo ")"; cp evil.sh .claude/hooks/x.sh)"' "$CP_HOOK" 'a quoted ) inside the substitution does not end it'
has_line "echo \"\$(echo '\"'; cp evil.sh .claude/hooks/x.sh)\"" "$CP_HOOK" 'a quoted double quote inside the substitution does not end the outer quote'
has_line 'echo "$( (cp evil.sh .claude/hooks/x.sh) )"' "$CP_HOOK" 'a subshell inside the substitution'
has_line 'echo "$(case x in x) cp evil.sh .claude/hooks/x.sh;; esac)"' "$CP_HOOK" 'the ) after a case pattern does not end the substitution'
has_line 'echo "$(case x in x) echo;; esac)"; cp evil.sh .claude/hooks/x.sh' "$CP_HOOK" 'the command after a substitution holding a case'
has_line "echo \"\$(cp evil.sh \$'.claude/hooks/x.sh')\"" "$CP_HOOK" 'an ANSI-C string inside the substitution is decoded'
has_line "echo \"\$(echo # )${NL}cp evil.sh .claude/hooks/x.sh)\"" "$CP_HOOK" 'a comment inside the substitution runs to the end of the line'
has_line "bash -c \"\$(cat <<'EOF'${NL}cp evil.sh .claude/hooks/x.sh${NL}EOF${NL})\"" "$CP_HOOK" \
  'a heredoc body inside a quoted substitution is still shown'
has_line 'echo "$((`cp evil.sh .claude/hooks/x.sh` + 1))"' "$CP_HOOK" 'a backtick inside quoted arithmetic'
# The outer record keeps the substitution text in its word, so a target built
# from a substitution still names the protected folder.
has_line 'cp evil.sh "$(echo .claude/hooks)/x.sh"' 'cp|evil.sh|$(echo .claude/hooks)/x.sh' 'the outer word keeps the substitution text'
has_line 'x="pre$(cmd a "b c")post" y' 'x=pre$(cmd a "b c")post|y' 'the outer word goes on after the substitution'
has_line 'x="pre$(cmd a "b c")post" y' 'cmd|a|b c' 'quotes inside the substitution group its words'
has_line 'echo "$(cp evil.sh .claude/hooks/x.sh)"' 'echo|"$(cp evil.sh .claude/hooks/x.sh)"' 'raw mode keeps the outer word as written' raw
# A << inside quoted arithmetic is a shift, not a heredoc.
has_line "echo \"\$((1<<2))\"${NL}cp evil.sh \$'.claude/hooks/x.sh'" "$CP_HOOK" 'a shift in quoted arithmetic starts no heredoc'
# A substitution left open at the end still shows its commands.
has_line 'echo "$(cp evil.sh .claude/hooks/x.sh' "$CP_HOOK" 'an unterminated quoted substitution still shows its command'

# --- 2. A backtick at the start of a word -----------------------------------
has_line '`cp evil.sh .claude/hooks/x.sh`' "$CP_HOOK" 'a backtick at the start of the command'
has_line 'x=`cp evil.sh .claude/hooks/x.sh`' "$CP_HOOK" 'a backtick at the start of an assignment value'
has_line 'echo `true; cp evil.sh .claude/hooks/x.sh`' "$CP_HOOK" 'the second command inside backticks'
has_line 'echo `echo \`cp evil.sh .claude/hooks/x.sh\``' "$CP_HOOK" 'an escaped backtick inside backticks starts one more level'
has_line "cat <<EOF${NL}\`cp evil.sh .claude/hooks/x.sh\`${NL}EOF" "$CP_HOOK" 'a backtick in an unquoted heredoc body'
has_line 'echo `echo a#b` c' 'echo|`echo a#b`|c' 'the outer record keeps the backtick text as one word'
has_line 'echo `echo a#b` c' 'echo|a#b' 'a # inside a word in backticks is not a comment'
has_line "echo \`#'\`; cp evil.sh .claude/hooks/x.sh" "$CP_HOOK" 'a comment inside backticks still ends at the closing backtick'
has_line "echo \`echo '\`; cp evil.sh .claude/hooks/x.sh" "$CP_HOOK" 'an open quote inside backticks still ends at the closing backtick'

# --- cd inside a substitution ------------------------------------------------
# It changes the directory only inside the substitution, so it is not printed:
# a guard would otherwise apply it to the commands after the substitution.
no_line 'echo "$(cd /tmp)"; cp evil.sh .claude/hooks/x.sh' 'cd|/tmp' 'a cd inside a quoted substitution is not printed'
no_line 'echo `cd /tmp`; cp evil.sh .claude/hooks/x.sh' 'cd|/tmp' 'a cd inside backticks is not printed'
has_line 'echo "$(cd /tmp; cp evil.sh .claude/hooks/x.sh)"' "$CP_HOOK" 'the command after a cd inside a substitution is printed'
has_line 'cd /tmp; echo "$(date)"' 'cd|/tmp' 'a cd outside a substitution is still printed'
# env options and assignments before cd are skipped the way the guard skips
# them (review of d6e6d61f7, minor 1).
no_line 'echo "$(env X=../../.. -i cd /tmp)"; cp evil.sh .claude/hooks/x.sh' 'env|X=../../..|-i|cd|/tmp' \
  'a cd after env options inside a substitution is not printed'
has_line 'echo "$(env X=../../.. -i cd /tmp)"; cp evil.sh .claude/hooks/x.sh' "$CP_HOOK" \
  'the write after an env cd inside a substitution is printed'

# --- Message heredocs (review of d6e6d61f7, minor 2) -------------------------
# The body of a lone cat <<'EOF' that is the whole quoted value of a gh
# --body/--title or git commit -m is message text, so its lines are not
# printed. Any other quoted heredoc body in a substitution still is.
no_line "git commit -m \"\$(cat <<'EOF'${NL}subject${NL}${NL}cp evil.sh .claude/hooks/x.sh${NL}EOF${NL})\"" "$CP_HOOK" \
  'a git commit -m heredoc body line is not a command'
no_line "gh pr comment 1 --body \"\$(cat <<'EOF'${NL}review:${NL}  cp evil.sh .claude/hooks/x.sh${NL}EOF${NL})\"" "$CP_HOOK" \
  'a gh --body heredoc body line is not a command'
has_line "eval \"\$(cat <<'EOF'${NL}cp evil.sh .claude/hooks/x.sh${NL}EOF${NL})\"" "$CP_HOOK" \
  'an eval heredoc body is still shown'
has_line "git commit -m \"\$(cat <<'EOF' | sh${NL}cp evil.sh .claude/hooks/x.sh${NL}EOF${NL})\"" "$CP_HOOK" \
  'a message heredoc piped to a shell is still shown'
has_line "git commit -m \"\$(cat <<EOF${NL}cp evil.sh .claude/hooks/x.sh${NL}EOF${NL})\"" "$CP_HOOK" \
  'an unquoted message heredoc body is still shown'
has_line "gh pr comment 1 --body \"x\$(cat <<'EOF'${NL}cp evil.sh .claude/hooks/x.sh${NL}EOF${NL})\"" "$CP_HOOK" \
  'a heredoc that is only part of the message word is still shown'
has_line "git commit -m \"\$(cat <<'EOF'${NL}subject${NL}EOF${NL})\"; cp evil.sh .claude/hooks/x.sh" "$CP_HOOK" \
  'the command after a message heredoc is printed'
# Bash 3.2 ends the substitution at an unmatched ), so the lines after one
# are printed again; matched parentheses keep the body hidden.
no_line "git commit -m \"\$(cat <<'EOF'${NL}fix(core): subject${NL}${NL}cp evil.sh .claude/hooks/x.sh${NL}EOF${NL})\"" "$CP_HOOK" \
  'matched parentheses in a message heredoc keep its lines hidden'
has_line "git commit -m \"\$(cat <<'EOF'${NL}subject ) x${NL}cp evil.sh .claude/hooks/x.sh${NL}EOF${NL})\"" "$CP_HOOK" \
  'the lines after an unmatched ) in a message heredoc are printed'
has_line "git commit -m \"\$(cat <<'EOF'${NL}use \`x\`${NL}cp evil.sh .claude/hooks/x.sh${NL}EOF${NL})\"" "$CP_HOOK" \
  'the lines after a backtick in a message heredoc are printed'
same_count "gh pr comment 1 --body \"\$(cat <<'EOF'${NL}review:${NL}  cp evil.sh .claude/hooks/x.sh${NL}EOF${NL})\"" \
  'a hidden message heredoc body'
# A function, alias, PATH, hash or enable change in the same command can make
# cat, gh or git run the body (review of 3ef4f6152, minor 1), so message
# heredoc bodies are printed again.
MSG_BODY="--body \"\$(cat <<'EOF'${NL}cp evil.sh .claude/hooks/x.sh${NL}EOF${NL})\""
has_line "cat() { sh; }; gh pr comment 1 $MSG_BODY" "$CP_HOOK" \
  'a cat function makes a PR body heredoc a command again'
has_line "cat () { sh; }; git commit -m \"\$(cat <<'EOF'${NL}cp evil.sh .claude/hooks/x.sh${NL}EOF${NL})\"" "$CP_HOOK" \
  'a cat function makes a commit message heredoc a command again'
has_line "function cat { sh; }; gh pr comment 1 $MSG_BODY" "$CP_HOOK" \
  'a function keyword definition makes the body a command again'
has_line "gh() { sh; }; gh pr comment 1 $MSG_BODY" "$CP_HOOK" \
  'a gh function makes the body a command again'
has_line "alias cat=sh${NL}gh pr comment 1 $MSG_BODY" "$CP_HOOK" \
  'an alias on an earlier line makes the body a command again'
has_line "export PATH=/tmp/evil:\$PATH; gh pr comment 1 $MSG_BODY" "$CP_HOOK" \
  'a PATH change makes the body a command again'
has_line "hash -p /bin/sh cat; gh pr comment 1 $MSG_BODY" "$CP_HOOK" \
  'hash -p makes the body a command again'
has_line "enable -n echo; gh pr comment 1 $MSG_BODY" "$CP_HOOK" \
  'enable makes the body a command again'

# Double quotes in a message body: Bash 3.2 does not count a parenthesis in a
# double-quoted span unless it belongs to a $( in that span, so JSON text such
# as {"a": "$(date)"} keeps the body hidden. A quoted ( with a bare ) on a
# later line ends the substitution under Bash 3.2 and runs the next lines, so
# those are printed again, as are bare parentheses in quotes, a quote inside a
# quoted $(, and a quote left open at the end of a line.
HF='bash core/scripts/handoff-finalize.sh --summary'
no_line "$HF \"\$(cat <<'EOF'${NL}{\"a\": \"\$(date)\"}${NL}cp evil.sh .claude/hooks/x.sh${NL}EOF${NL})\"" "$CP_HOOK" \
  'a JSON line with a quoted substitution keeps a handoff summary body hidden'
no_line "gh pr comment 1 --body \"\$(cat <<'EOF'${NL}say \"hi\" (twice)${NL}cp evil.sh .claude/hooks/x.sh${NL}EOF${NL})\"" "$CP_HOOK" \
  'balanced double quotes keep a PR body hidden'
has_line "$HF \"\$(cat <<'EOF'${NL}\"(\"${NL})${NL}cp evil.sh .claude/hooks/x.sh${NL}EOF${NL})\"" "$CP_HOOK" \
  'a quoted ( then a bare ) prints the body lines again'
has_line "$HF \"\$(cat <<'EOF'${NL}\"a ) b\"${NL}cp evil.sh .claude/hooks/x.sh${NL}EOF${NL})\"" "$CP_HOOK" \
  'a bare ) inside double quotes prints the body lines again'
has_line "$HF \"\$(cat <<'EOF'${NL}\"\$(echo \"a\")\"${NL}cp evil.sh .claude/hooks/x.sh${NL}EOF${NL})\"" "$CP_HOOK" \
  'a quote inside a quoted $( prints the body lines again'
has_line "$HF \"\$(cat <<'EOF'${NL}\"open${NL}cp evil.sh .claude/hooks/x.sh${NL}EOF${NL})\"" "$CP_HOOK" \
  'a double quote left open at the end of a line prints the body lines again'
# Only the shipped relative handoff script, run directly or as the first
# operand of bash or sh, takes its --summary and --title text as data.
has_line "bash /tmp/core/scripts/handoff-finalize.sh --summary \"\$(cat <<'EOF'${NL}cp evil.sh .claude/hooks/x.sh${NL}EOF${NL})\"" "$CP_HOOK" \
  'a handoff script outside the HQ tree has its body printed'
has_line "bash -x core/scripts/handoff-finalize.sh --summary \"\$(cat <<'EOF'${NL}cp evil.sh .claude/hooks/x.sh${NL}EOF${NL})\"" "$CP_HOOK" \
  'a shell option before the handoff script prints the body'
has_line "core/scripts/handoff-finalize.sh --notes \"\$(cat <<'EOF'${NL}cp evil.sh .claude/hooks/x.sh${NL}EOF${NL})\"" "$CP_HOOK" \
  'a handoff option other than --summary or --title prints the body'
no_line "core/scripts/handoff-finalize.sh --title \"\$(cat <<'EOF'${NL}cp evil.sh .claude/hooks/x.sh${NL}EOF${NL})\"" "$CP_HOOK" \
  'a handoff --title body run directly is hidden'
# The script is named by a relative path, so a directory change or a shell
# startup variable in the same command can make that name run other code.
HF_BODY="--summary \"\$(cat <<'EOF'${NL}cp evil.sh .claude/hooks/x.sh${NL}EOF${NL})\""
for pre in 'cd /tmp; ' 'pushd /tmp; ' 'popd; ' 'CDPATH=/tmp ' 'BASH_ENV=/tmp/x ' 'ENV=/tmp/x ' 'SHELLOPTS=x ' 'BASHOPTS=x '; do
  has_line "${pre}bash core/scripts/handoff-finalize.sh $HF_BODY" "$CP_HOOK" \
    "a handoff body after '$pre' is printed"
done
has_line "core/scripts/handoff-finalize.sh() { sh; }; core/scripts/handoff-finalize.sh $HF_BODY" "$CP_HOOK" \
  'a function named like the handoff script prints the body'
has_line "hash -p /bin/sh bash; bash core/scripts/handoff-finalize.sh $HF_BODY" "$CP_HOOK" \
  'hash -p on bash prints the handoff body'
# US-029: the native `hq core handoff finalize` takes --summary and --title
# text as data, by exact command match only.
HQF_TITLE_BODY="--title \"\$(cat <<'EOF'${NL}cp evil.sh .claude/hooks/x.sh${NL}EOF${NL})\""
no_line "hq core handoff finalize $HF_BODY" "$CP_HOOK" \
  'an hq core handoff finalize --summary body is hidden'
no_line "hq core handoff finalize --slug s $HQF_TITLE_BODY" "$CP_HOOK" \
  'an hq core handoff finalize --title body after other options is hidden'
for look in 'hq core handoff run' 'hq core handoff post' 'hq core handoff finalized' 'hq core finalize handoff' \
            'hq handoff finalize' 'hq core handoff --x finalize' 'hqx core handoff finalize' './hq core handoff finalize' \
            '/tmp/hq core handoff finalize' 'bash hq core handoff finalize' 'command hq core handoff finalize'; do
  has_line "$look $HF_BODY" "$CP_HOOK" "a lookalike [$look] has its body printed"
done
has_line "hq core handoff finalize --message \"\$(cat <<'EOF'${NL}cp evil.sh .claude/hooks/x.sh${NL}EOF${NL})\"" "$CP_HOOK" \
  'an hq core handoff finalize option other than --summary or --title prints the body'
for pre in 'cd /tmp; ' 'BASH_ENV=/tmp/x ' 'hq() { sh; }; ' 'alias hq=sh; ' 'PATH=/tmp/evil:$PATH; ' 'hash -p /bin/sh hq; '; do
  has_line "${pre}hq core handoff finalize $HF_BODY" "$CP_HOOK" \
    "an hq core handoff finalize body after '$pre' is printed"
done
# A hidden body line is left out of the outer word of the heredoc-aware
# reading too. Default output keeps a newline inside a word, so the line would
# otherwise reach guards as a record of its own. (The flat reading printed
# after it for any << is unchanged: it reads the quoted text as before
# substitutions were modelled.)
hf_lexer_lines="$(_hq_shell_simple_commands_lexer "$HF \"\$(cat <<'EOF'${NL}cp evil.sh .claude/hooks/x.sh${NL}EOF${NL})\"" | tr '\037' '|')" || true
case "${NL}${hf_lexer_lines}${NL}" in
  *"${NL}cp evil.sh .claude/hooks/x.sh${NL}"*) fail "a hidden body line is not left in the outer word: $(printf '%s' "$hf_lexer_lines" | tr '\n' '~')" ;;
  *) pass ;;
esac
has_line "$HF \"\$(cat <<'EOF'${NL}cp evil.sh .claude/hooks/x.sh${NL}EOF${NL})\"" "bash|core/scripts/handoff-finalize.sh|--summary|\$(cat <<'EOF'" \
  'the outer word keeps the heredoc header line'
has_line "bash -c \"\$(cat <<'EOF'${NL}cp evil.sh .claude/hooks/x.sh${NL}EOF${NL})\"" 'cp evil.sh .claude/hooks/x.sh' \
  'a shown body line stays in the outer word'

# --- Output modes stay aligned ---------------------------------------------
same_count 'echo "$(cp evil.sh .claude/hooks/x.sh)" `date` x' 'quoted and backtick substitutions'
same_count 'echo "$(cd /tmp)" `cd /tmp` x' 'dropped cd records'
same_count "git commit -m \"\$(cat <<'EOF'${NL}subject${NL}${NL}body it's${NL}EOF${NL})\"" 'a commit message heredoc in a quoted substitution'
same_count "bash core/scripts/handoff-finalize.sh --summary \"\$(cat <<'EOF'${NL}{\"a\": \"companies/x\", \"b\": \"\$(date)\"}${NL}EOF${NL})\"" \
  'a hidden handoff summary heredoc'

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

  guard 2 "echo \"\$(cp evil.sh $H/x.sh)\"" 'a write inside a quoted substitution is blocked'
  guard 2 "echo \"\`cp evil.sh $H/x.sh\`\"" 'a write inside a quoted backtick is blocked'
  guard 2 "x=\"\$(cp evil.sh $H/x.sh)\"" 'a write inside a quoted assignment substitution is blocked'
  guard 2 "\`cp evil.sh $H/x.sh\`" 'a write in a backtick at the start of the command is blocked'
  guard 2 "x=\`cp evil.sh $H/x.sh\`" 'a write in a backtick assignment is blocked'
  guard 2 "echo \"\$(cd /tmp)\"; cp evil.sh .claude/hooks/x.sh" 'a cd inside a quoted substitution does not move later commands'
  guard 2 "echo \`cd /tmp\`; cp evil.sh .claude/hooks/x.sh" 'a cd inside backticks does not move later commands'
  guard 2 "echo \"\$(env X=../../.. -i cd /tmp)\"; cp evil.sh .claude/hooks/x.sh" \
    'an env cd inside a quoted substitution does not move later commands'
  guard 2 "eval \"\$(cat <<'EOF'${NL}cp evil.sh .claude/hooks/x.sh${NL}EOF${NL})\"" 'a write in an eval heredoc is blocked'

  guard 0 "echo \"today is \$(date) in $H\"" 'a quoted substitution that only names a protected path is allowed'
  guard 0 "ls \"\$(dirname $H/x)\"" 'a read inside a quoted substitution is allowed'
  guard 0 "echo \`date\` $H > /tmp/hq-lexer-subst-test-out" 'a backtick writing outside protected paths is allowed'
  guard 0 "git -C /tmp/hq-lexer-subst-test commit -m \"\$(cat <<'EOF'${NL}fix(core): it's in $H${NL}EOF${NL})\"" \
    'a commit message heredoc that names a protected path is allowed'
  guard 0 "gh pr comment 1 --body \"\$(cat <<'EOF'${NL}review:${NL}  cp evil.sh .claude/hooks/x.sh${NL}EOF${NL})\"" \
    'a PR comment body that quotes a protected-path write is allowed'
  guard 0 "git -C /tmp/hq-lexer-subst-test commit -m \"\$(cat <<'EOF'${NL}subject${NL}${NL}cp evil.sh .claude/hooks/x.sh${NL}EOF${NL})\"" \
    'a commit message that quotes a protected-path write is allowed'
  guard 2 "cat() { sh; }; gh pr comment 1 --body \"\$(cat <<'EOF'${NL}cp evil.sh .claude/hooks/x.sh${NL}EOF${NL})\"" \
    'a PR body heredoc behind a cat function is blocked'
  guard 2 "alias cat=sh${NL}git -C /tmp/hq-lexer-subst-test commit -m \"\$(cat <<'EOF'${NL}cp evil.sh .claude/hooks/x.sh${NL}EOF${NL})\"" \
    'a commit message heredoc behind an alias is blocked'
  guard 2 "export PATH=/tmp/evil:\$PATH; gh pr comment 1 --body \"\$(cat <<'EOF'${NL}cp evil.sh .claude/hooks/x.sh${NL}EOF${NL})\"" \
    'a PR body heredoc after a PATH change is blocked'
  # Input that ends inside a quoted substitution also gets the flat reading,
  # so the quote after the opener cannot hide the write (main blocks these).
  guard 2 "echo \"\`\"; cp evil.sh $H/x.sh" 'a write after an unclosed quoted backtick is blocked'
  guard 2 "echo \"\$(\" ; cp evil.sh $H/x.sh" 'a write after an unclosed quoted substitution is blocked'
  guard 2 "\`echo \"\`; cp evil.sh $H/x.sh" 'a write after an unclosed backtick at a word start is blocked'
  # A # right after an operator inside a quoted $( is a comment for Bash 5,
  # but /bin/bash 3.2 ends the substitution at the ) after it and runs the
  # rest, so the flat reading is added (main blocks these).
  for pre in 'echo "$(echo x;#)"' 'echo "$(echo x&#)"' 'echo "$(echo x|#)"' 'echo "$(echo x&&#)"' 'echo "$(;#)"' 'x="$(:;#)"' 'gh pr comment 1 --body "$(echo x;#)"'; do
    guard 2 "$pre ; cp evil.sh $H/x.sh${NL})\"" "a write after $pre is blocked"
  done
  # $_ holds the last argument of the previous command, which for a message
  # command is the hidden body. A later word that reads $_ (directly, through
  # ${!name}, eval or a nameref) can run it, so the body is printed.
  LAST_BODY="\"\$(cat <<'EOF'${NL}cp evil.sh .claude/hooks/x.sh${NL}EOF${NL})\""
  for msg in 'core/scripts/handoff-finalize.sh --summary' 'bash core/scripts/handoff-finalize.sh --title' \
             'gh pr comment 1 --body' 'git -C /tmp/hq-lexer-subst-test commit -m'; do
    for tl in '; sh -c "$_"' ' && eval "$_"' '; bash -c "$_"' '; zsh -c "$_"' '; sh -c "${_}"' \
              '; eval ${_}' '; python3 -c "$_"' '; node -e "$_"' '; perl -e "$_"' \
              '; x="$_"; sh -c "$x"' '; sh -c "${_:0}"' '; n=_; sh -c "${!n}"' \
              "; eval 'sh -c \"\$''_\"'" '; declare -n r=_; sh -c "$r"' '; typeset -n r=_; sh -c "$r"' \
              "; sh -c \"\$\\${NL}_\"" "; sh -c \"\$\\${NL}{_}\"" "; n=_; sh -c \"\$\\${NL}{!n}\"" \
              "; ev\\${NL}al \"\$\\${NL}_\"" "; al\\${NL}ias cat=sh; sh -c \"\$\\${NL}_\""; do
      guard 2 "$msg $LAST_BODY$tl" "$msg heredoc replayed by [$tl] is blocked"
    done
    guard 0 "$msg $LAST_BODY" "a plain $msg heredoc stays allowed"
    guard 0 "$msg $LAST_BODY; echo \$__x \$_a" "$msg heredoc with \$_-prefixed names stays allowed"
  done
  # US-029: hq core handoff finalize --summary/--title text is data; a
  # protected path in any other argument, or a lookalike command, still blocks.
  guard 0 "hq core handoff finalize --summary \"\$(cat <<'EOF'${NL}cp evil.sh .claude/hooks/x.sh${NL}EOF${NL})\"" \
    'an hq core handoff finalize --summary that quotes a protected-path write is allowed'
  guard 0 "hq core handoff finalize --title \"\$(cat <<'EOF'${NL}cp evil.sh .claude/hooks/x.sh${NL}EOF${NL})\"" \
    'an hq core handoff finalize --title that quotes a protected-path write is allowed'
  guard 2 "hq core handoff finalize --summary \"\$(cat <<'EOF'${NL}ok${NL}EOF${NL})\"; cp evil.sh $H/x.sh" \
    'a protected-path write after an hq core handoff finalize summary is blocked'
  guard 2 "hq core handoff finalize --summary \"\$(cp evil.sh $H/x.sh)\"" \
    'a protected-path write run inside an hq core handoff finalize summary is blocked'
  guard 2 "hq core handoff finalize --title t --summary s \"\$(cat <<'EOF'${NL}cp evil.sh .claude/hooks/x.sh${NL}EOF${NL})\"" \
    'a heredoc in a positional argument of hq core handoff finalize is blocked'
  for look in 'hq core handoff run' 'hq core handoff finalized' 'hq handoff finalize' 'hqx core handoff finalize' './hq core handoff finalize'; do
    guard 2 "$look --summary \"\$(cat <<'EOF'${NL}cp evil.sh .claude/hooks/x.sh${NL}EOF${NL})\"" \
      "a lookalike [$look] summary heredoc is blocked"
  done
  guard 2 "hq() { sh; }; hq core handoff finalize --summary \"\$(cat <<'EOF'${NL}cp evil.sh .claude/hooks/x.sh${NL}EOF${NL})\"" \
    'an hq core handoff finalize summary behind an hq function is blocked'
else
  echo "SKIP: guard cases (jq not available)"
fi

echo "hook-lib-lexer-substitutions: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
