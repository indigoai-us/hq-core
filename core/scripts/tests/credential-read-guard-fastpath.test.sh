#!/usr/bin/env bash
# hq-core: public
# credential-read-guard-fastpath.test.sh — the builtin-only fast path in
# block-credential-file-read.sh allows only calls the full check allows.
#
# Sections:
#   [1] differential: the whole credential-read-guard.test.sh corpus runs
#       against the hook and against a reference with the fast path off
#       (HQ_CRED_GUARD_FASTPATH=0). Any exit-code difference fails. Set
#       CRED_GUARD_REF_HOOK to compare against another hook file instead,
#       for example the pre-fast-path version from origin/main.
#   [2] bypass attempts aimed at the fast path: case, quote and backslash
#       splits, variables, globs, braces, links, and JSON-level tricks
#       (\u escapes, duplicate keys, two documents, NUL bytes, non-string
#       fields). Each must block, with and without the fast path.
#   [3] the fast path is taken (no jq process) for ordinary Bash and Read
#       calls, and not taken for the inputs it must hand to the full check.
#
# CRED_GUARD_HOOK_BASH selects the interpreter for the hook (CI runs this
# file under bash 5 and macOS /bin/bash 3.2).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
HOOK="$ROOT/.claude/hooks/block-credential-file-read.sh"
MAIN_TEST="$ROOT/core/scripts/tests/credential-read-guard.test.sh"
HOOK_BASH="${CRED_GUARD_HOOK_BASH:-bash}"
REF_HOOK="${CRED_GUARD_REF_HOOK:-$HOOK}"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable" >&2; exit 0; }
[ -f "$HOOK" ] || { echo "FAIL: missing $HOOK" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cred-guard-fast.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
# Physical path: on macOS TMPDIR is under /var, a symlink, and the Read fast
# path hands any path through a symlink to the full check.
TMP="$(cd "$TMP" && pwd -P)"

echo "[1] differential over the credential-read-guard corpus (hook bash: $HOOK_BASH)"
rc=0
CRED_GUARD_HOOK_BASH="$HOOK_BASH" CRED_GUARD_REF_HOOK="$REF_HOOK" CRED_GUARD_VERDICT_LOG="$TMP/verdicts" \
  bash "$MAIN_TEST" >"$TMP/main.log" 2>&1 || rc=$?
total=0
diffs=0
if [ -f "$TMP/verdicts" ]; then
  total=$(wc -l <"$TMP/verdicts" | tr -d ' ')
  diffs=$(awk '$1 != $2' "$TMP/verdicts" | wc -l | tr -d ' ')
fi
blocked=$(awk '$2 == 2' "$TMP/verdicts" 2>/dev/null | wc -l | tr -d ' ')
if [ "$rc" -eq 0 ] && [ "$total" -gt 400 ] && [ "$diffs" -eq 0 ]; then
  ok "corpus: $total payloads ($blocked blocked by the reference), 0 verdict differences"
else
  bad "corpus: rc=$rc payloads=$total diffs=$diffs"
  grep '^FAIL' "$TMP/main.log" | head -20
fi

# ---------------------------------------------------------------- fixtures
FH="$TMP/home"
PROJ="$FH/proj"
mkdir -p "$FH/.ssh" "$FH/.aws" "$PROJ/sub/deeper"
printf 'fake\n' >"$FH/.npmrc"
printf 'fake\n' >"$FH/.ssh/id_rsa"
printf 'fake\n' >"$FH/.aws/credentials"
printf 'fake\n' >"$PROJ/.env"
printf 'hello\n' >"$PROJ/README.md"
printf 'hello\n' >"$PROJ/sub/deeper/notes.txt"
ln -s "$FH/.npmrc" "$PROJ/lnk"
ln -s "$FH/.ssh" "$PROJ/keys"
ln -s "$FH/.aws" "$PROJ/sub/cfgdir"

payload_read() { jq -nc --arg p "$1" --arg cwd "$2" '{session_id:"fast",hook_event_name:"PreToolUse",tool_name:"Read",cwd:$cwd,tool_input:{file_path:$p}}'; }
payload_bash() { jq -nc --arg c "$1" --arg cwd "$2" '{session_id:"fast",hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$cwd,tool_input:{command:$c,description:"x"}}'; }

# run_hook <payload-file> <fastpath 0|1> [hook] -> exit code
run_hook() {
  local rc=0
  HOME="$FH" HQ_CRED_GUARD_FASTPATH="$2" "$HOOK_BASH" "${3:-$HOOK}" <"$1" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}

# expect_block <desc> <payload-file>: blocked with and without the fast
# path, and by the reference hook.
n=0
expect_block() {
  local a b r
  a=$(run_hook "$2" 1)
  b=$(run_hook "$2" 0)
  r=$(run_hook "$2" 0 "$REF_HOOK")
  if [ "$a" = 2 ] && [ "$b" = 2 ] && [ "$r" = 2 ]; then ok "blocked: $1"; else bad "$1 (fast=$a full=$b ref=$r)"; fi
}
bash_block() { n=$((n + 1)); payload_bash "$2" "${3:-$PROJ}" >"$TMP/p$n"; expect_block "Bash: $1" "$TMP/p$n"; }
read_block() { n=$((n + 1)); payload_read "$2" "${3:-$PROJ}" >"$TMP/p$n"; expect_block "Read: $1" "$TMP/p$n"; }
raw_block() { n=$((n + 1)); printf '%s' "$2" >"$TMP/p$n"; expect_block "raw JSON: $1" "$TMP/p$n"; }
# raw_block_new: payloads the single jq call now rejects. The guard before
# this change allowed them, so only this hook (both paths) is checked.
raw_block_new() {
  local a b
  n=$((n + 1)); printf '%s' "$2" >"$TMP/p$n"
  a=$(run_hook "$TMP/p$n" 1); b=$(run_hook "$TMP/p$n" 0)
  if [ "$a" = 2 ] && [ "$b" = 2 ]; then ok "blocked: raw JSON: $1"; else bad "raw JSON: $1 (fast=$a full=$b)"; fi
}

echo "[2] bypass attempts aimed at the fast path"
bash_block "mixed case" 'cat ~/.NpMrC'
bash_block "upper case absolute" "cat $FH/.NPMRC"
bash_block "double-quote split" 'cat ~/.np"m"rc'
bash_block "single-quote split" "cat ~/.np''mrc"
bash_block "empty quotes inside" 'cat "$HOME"/."n""p""m""r""c"'
bash_block "backslash split" 'cat ~/.np\mrc'
bash_block "backslash before every letter" 'cat ~/.\n\p\m\r\c'
bash_block "variable-built name" 'a=np; cat ~/.${a}mrc'
bash_block "variable-built dir" 'd=.ss; cat ~/${d}h/id_rsa'
bash_block "variable holding the whole path" 'f=~/.npmrc; cat "$f"'
bash_block "glob star" 'cat ~/.n*rc'
bash_block "glob question" 'cat ~/.np?rc'
bash_block "glob class" 'cat ~/.[n]pmrc'
bash_block "brace expansion" 'cat ~/.{n,x}pmrc'
bash_block "HOME with braces" 'cat ${HOME}/.npmrc'
bash_block "neutral symlink name" 'cat lnk'
bash_block "neutral symlink, absolute" "cat $PROJ/lnk"
bash_block "linked .ssh dir under a neutral name" 'cat keys/id_rsa'
bash_block "linked .aws dir two levels down" 'cat sub/cfgdir/credentials'
bash_block "cwd inside .ssh" 'cat id_rsa' "$FH/.ssh"
bash_block "project .env, mixed case" 'cat .ENV'
bash_block "redirect from .env" 'wc -c < .env'
bash_block "command substitution" 'echo $(cat ~/.npmrc)'
bash_block "tab and newline separated" $'cat\t~/.npmrc\nls'
read_block "mixed case" "$FH/.NpMrC"
read_block "tilde" '~/.npmrc'
read_block "\${HOME}" '${HOME}/.npmrc'
read_block "neutral symlink" "$PROJ/lnk"
read_block "through a linked dir" "$PROJ/keys/id_rsa"
read_block "dot-dot into .ssh" "$PROJ/../.ssh/id_rsa"
read_block "relative .env" ".env"
U='n'
raw_block "unicode escape in the Bash command" "{\"tool_name\":\"Bash\",\"cwd\":\"$PROJ\",\"tool_input\":{\"command\":\"cat ~/.${U}pmrc\"}}"
raw_block "unicode escape in the Read path" "{\"tool_name\":\"Read\",\"cwd\":\"$PROJ\",\"tool_input\":{\"file_path\":\"$FH/.${U}pmrc\"}}"
raw_block "unicode escape in the tool name" "{\"tool_name\":\"Ba\\u0073h\",\"cwd\":\"$PROJ\",\"tool_input\":{\"command\":\"cat ~/.npmrc\"}}"
raw_block "unicode escape in a key" "{\"tool_name\":\"Bash\",\"cwd\":\"$PROJ\",\"tool_input\":{\"comm\\u0061nd\":\"cat ~/.npmrc\"}}"
raw_block "escaped slash" "{\"tool_name\":\"Read\",\"cwd\":\"$PROJ\",\"tool_input\":{\"file_path\":\"$FH\\/.npmrc\"}}"
raw_block "duplicate command key, bad one last" "{\"tool_name\":\"Bash\",\"cwd\":\"$PROJ\",\"tool_input\":{\"command\":\"ls\",\"command\":\"cat ~/.npmrc\"}}"
raw_block "duplicate tool_input, bad one last" "{\"tool_name\":\"Bash\",\"cwd\":\"$PROJ\",\"tool_input\":{\"command\":\"ls\"},\"tool_input\":{\"command\":\"cat ~/.npmrc\"}}"
raw_block "duplicate tool_name" "{\"tool_name\":\"Glob\",\"tool_name\":\"Bash\",\"cwd\":\"$PROJ\",\"tool_input\":{\"command\":\"cat ~/.npmrc\"}}"
raw_block "tool name with trailing newline" "{\"tool_name\":\"Bash\\n\",\"cwd\":\"$PROJ\",\"tool_input\":{\"command\":\"cat ~/.npmrc\"}}"
raw_block "trailing newline on the Read path" "{\"tool_name\":\"Read\",\"cwd\":\"$PROJ\",\"tool_input\":{\"file_path\":\"$FH/.npmrc\\n\"}}"
raw_block "cwd with trailing newline into .ssh" "{\"tool_name\":\"Bash\",\"cwd\":\"$FH/.ssh\\n\",\"tool_input\":{\"command\":\"cat id_rsa\"}}"
raw_block_new "two documents (the pre-fast-path guard allowed this)" "{\"tool_name\":\"Bash\",\"cwd\":\"$PROJ\",\"tool_input\":{\"command\":\"ls\"}}{\"tool_name\":\"Bash\",\"cwd\":\"$PROJ\",\"tool_input\":{\"command\":\"cat ~/.npmrc\"}}"
raw_block "trailing garbage" "{\"tool_name\":\"Bash\",\"cwd\":\"$PROJ\",\"tool_input\":{\"command\":\"ls\"}} x"
raw_block "missing colon" "{\"tool_name\" \"Bash\",\"cwd\":\"$PROJ\",\"tool_input\":{\"command\":\"ls\"}}"
raw_block "unterminated object" "{\"tool_name\":\"Bash\",\"cwd\":\"$PROJ\",\"tool_input\":{\"command\":\"ls\"}"
raw_block "tool_input is a string" "{\"tool_name\":\"Bash\",\"cwd\":\"$PROJ\",\"tool_input\":\"ls\"}"
raw_block_new "command is an array (the pre-fast-path guard allowed this)" "{\"tool_name\":\"Bash\",\"cwd\":\"$PROJ\",\"tool_input\":{\"command\":[\"cat\",\"$FH/.npmrc\"]}}"
raw_block "non-ASCII homoglyph next to the name" "{\"tool_name\":\"Bash\",\"cwd\":\"$PROJ\",\"tool_input\":{\"command\":\"cat ~/.npmrc # é\"}}"
# Known limit of the full check, kept equal: an ANSI-C escape for the dot
# ($'\x2e'npmrc) is not decoded by either path. All three verdicts must match.
n=$((n + 1))
payload_bash "cat ~/\$'\\x2e'npmrc" "$PROJ" >"$TMP/p$n"
a=$(run_hook "$TMP/p$n" 1); b=$(run_hook "$TMP/p$n" 0); r=$(run_hook "$TMP/p$n" 0 "$REF_HOOK")
if [ "$a" = "$b" ] && [ "$b" = "$r" ]; then ok "known limit, same verdict on every path: ANSI-C dot (rc=$a)"; else bad "ANSI-C dot verdicts differ (fast=$a full=$b ref=$r)"; fi
n=$((n + 1))
printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"cat ~/.np\000mrc"}}' "$PROJ" >"$TMP/p$n"
expect_block "raw JSON: NUL byte inside the credential name" "$TMP/p$n"

echo "[3] fast path taken for ordinary calls, skipped where it must be"
# A jq shim that records each run, so a run without the record took the
# fast path.
mkdir -p "$TMP/shim"
REAL_JQ="$(command -v jq)"
printf '#!/bin/sh\n: >>"%s/jq-ran"\nexec "%s" "$@"\n' "$TMP" "$REAL_JQ" >"$TMP/shim/jq"
chmod +x "$TMP/shim/jq"
# expect_path <want-rc> <fast|full> <desc> <payload-file>
expect_path() {
  local rc=0 took
  rm -f "$TMP/jq-ran"
  HOME="$FH" PATH="$TMP/shim:$PATH" "$HOOK_BASH" "$HOOK" <"$4" >/dev/null 2>&1 || rc=$?
  if [ -e "$TMP/jq-ran" ]; then took=full; else took=fast; fi
  if [ "$rc" = "$1" ] && [ "$took" = "$2" ]; then ok "$3 (rc=$rc, $took)"; else bad "$3 (want rc=$1 $2, got rc=$rc $took)"; fi
}
path_bash() { n=$((n + 1)); payload_bash "$4" "${5:-$PROJ}" >"$TMP/p$n"; expect_path "$1" "$2" "Bash: $3" "$TMP/p$n"; }
path_read() { n=$((n + 1)); payload_read "$4" "${5:-$PROJ}" >"$TMP/p$n"; expect_path "$1" "$2" "Read: $3" "$TMP/p$n"; }
path_bash 0 fast "git status" 'git -C /abs/repo status --short'
path_bash 0 fast "quoted args and variables" 'git -C "$ROOT" log --oneline -3 && echo "done: $X"'
path_bash 0 fast "multi-line script" $'set -e\nbranch=main\nprintf "%s\\n" "$branch"'
# A $(...) or backtick body can build a credential name from neutral text,
# so the full check analyzes it as a computed path (COMPUTED_PATH) and the
# fast path hands it over. Still allowed when the full check allows it.
path_bash 0 full "multi-line script with a substitution goes to the full check" $'set -e\nbranch=$(git -C /abs branch --show-current)\nprintf "%s\\n" "$branch"'
path_bash 0 fast "escaped quotes in JSON" 'echo "a \"quoted\" word"'
path_bash 0 fast "plain file in cwd" 'cat README.md'
path_read 0 fast "project file" "$PROJ/README.md"
path_read 0 fast "nested project file" "$PROJ/sub/deeper/notes.txt"
path_bash 0 full "file two levels down goes to realpath" 'cat sub/deeper/notes.txt'
path_bash 0 full "glob goes to the full check" 'ls *.md'
path_bash 0 full "non-ASCII text goes to the full check" 'echo café'
n=$((n + 1))
printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command\\n":"echo hi","command":"cat lnk"}}' "$PROJ" >"$TMP/p$n"
expect_path 2 full "raw JSON: look-alike key with a newline does not hide the real command" "$TMP/p$n"
n=$((n + 1))
printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"cat lnk","command\\n":"echo hi"}}' "$PROJ" >"$TMP/p$n"
expect_path 2 full "raw JSON: look-alike key after the real command" "$TMP/p$n"
path_bash 2 full "credential word" 'cat ~/.npmrc'
path_bash 2 full "neutral symlink" 'cat lnk'
# Computed names that resolve to the neutral symlink: the fast path allowed
# these before (hq-core promotion 389, scope-guard-hotfix-security cases).
bash_block "substitution builds part of a name" 'cat "$(echo l)nk"'
bash_block "substitution is the whole operand" 'cat "$(printf %s bG5r | base64 -d)"'
bash_block "substitution reaches the operand through a variable" 'x=$(printf %s bG5r | base64 -d); cat "$x"'
bash_block "backtick substitution" 'cat `printf %s bG5r | base64 -d`'
bash_block "pwd substitution before a path" 'cat "$(pwd)/lnk"'
path_read 2 full "credential path" "$FH/.npmrc"
path_read 2 full "neutral symlink" "$PROJ/lnk"
path_read 0 full ".env template still allowed" "$PROJ/.env.example"
# The hook must not write to stderr on an allowed call, even when the
# inherited locale is not installed (bash warns on any LC_ALL assignment
# then; the fast path must not change the locale).
n=$((n + 1))
payload_bash 'git -C /abs/repo status --short' "$PROJ" >"$TMP/p$n"
rc=0
HOME="$FH" LC_ALL=xx_XX.UTF-8 "$HOOK_BASH" "$HOOK" <"$TMP/p$n" >"$TMP/loc.out" 2>"$TMP/loc.err" || rc=$?
if [ "$rc" = 0 ] && ! grep -q 'block-credential-file-read' "$TMP/loc.err" && [ ! -s "$TMP/loc.out" ]; then
  ok "no stderr from the hook with an uninstalled locale"
else
  bad "hook wrote output with an uninstalled locale (rc=$rc): $(head -c 200 "$TMP/loc.err" | tr '\n' ' ')"
fi
n=$((n + 1))
printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"echo \001 hi"}}' "$PROJ" >"$TMP/p$n"
expect_path "$(run_hook "$TMP/p$n" 0)" full "raw control byte in a string goes to the full check" "$TMP/p$n"
n=$((n + 1))
HQ_CRED_GUARD_FASTPATH=0 payload_bash 'git status' "$PROJ" >"$TMP/p$n"
rm -f "$TMP/jq-ran"
HOME="$FH" PATH="$TMP/shim:$PATH" HQ_CRED_GUARD_FASTPATH=0 "$HOOK_BASH" "$HOOK" <"$TMP/p$n" >/dev/null 2>&1
[ -e "$TMP/jq-ran" ] && ok "HQ_CRED_GUARD_FASTPATH=0 runs the full check" || bad "HQ_CRED_GUARD_FASTPATH=0 still took the fast path"

if [ "$fail" -eq 0 ]; then
  echo "ALL PASS: credential-read-guard-fastpath ($pass)"
  exit 0
fi
echo "FAILURES: credential-read-guard-fastpath ($fail failed, $pass passed)" >&2
exit 1
