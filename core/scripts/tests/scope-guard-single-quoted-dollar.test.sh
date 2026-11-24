#!/usr/bin/env bash
# hq-core: public
# A `$` inside single quotes is literal text to the shell. A word spelled in
# several quoted pieces (a JSON body passed through shlex.quote with an
# apostrophe in it, possibly across lines) used to reach the path checks with
# its quotes gone, so `$5` in `orders $150+` read as an unset positional
# parameter and the send was refused. Real expansions in the same shapes, and
# other-company paths, stay refused.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"

failures=0
checks=0
fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

hook_source="${SCOPE_HOOK_SOURCE:-$ROOT/.claude/hooks/mandatory-scope-authorizer.sh}"
mkdir -p "$TMP/.claude/hooks" "$TMP/core/scripts/lib" "$TMP/workspace/sessions/sess-1" \
  "$TMP/companies/ownco" "$TMP/companies/otherco" "$TMP/claude-config"
cp "$hook_source" "$TMP/.claude/hooks/mandatory-scope-authorizer.sh"
cp "$ROOT"/.claude/hooks/*-lib.sh "$TMP/.claude/hooks/"
cp "$ROOT/core/scripts/hook-lib.sh" "$TMP/core/scripts/"
cp "$ROOT"/core/scripts/lib/*.sh "$TMP/core/scripts/lib/"
printf 'companies:\n  otherco:\n    name: otherco\n  ownco:\n    name: ownco\n' > "$TMP/companies/manifest.yaml"
printf 'company_slug: ownco\n' > "$TMP/workspace/sessions/sess-1/meta.yaml"

run_case() { # <label> <command> <expected exit>
  local label="$1" cmd="$2" expected="$3" payload rc=0 stderr_file
  checks=$((checks + 1))
  stderr_file="$TMP/stderr-$checks"
  payload="$(jq -cn --arg cwd "$TMP" --arg c "$cmd" \
    '{tool_name:"Bash",session_id:"sess-1",cwd:$cwd,tool_input:{command:$c}}')"
  printf '%s' "$payload" | CLAUDE_CONFIG_DIR="$TMP/claude-config" CLAUDE_PROJECT_DIR="$TMP" \
    bash "$TMP/.claude/hooks/mandatory-scope-authorizer.sh" >/dev/null 2>"$stderr_file" || rc=$?
  printf '%-72s exit=%s\n' "$label" "$rc"
  if [ "$rc" -ne "$expected" ]; then
    fail "$label expected exit $expected, got $rc: $(head -c 300 "$stderr_file" | tr '\n' ' ')"
  elif [ "$expected" -eq 2 ] && ! grep -q 'Cross-company scope violation' "$stderr_file"; then
    fail "$label was denied without the cross-company message"
  fi
}

# The shape a sandboxed agent sends: slack-call <method> <shlex.quote(json.dumps(args))>.
# json.dumps writes a newline as the two characters \n; shlex.quote turns each
# apostrophe into '"'"'.
json_send='slack-call chat.postMessage '\''{"channel": "C1", "text": "two yes/no'\''"'\''"'\''s from the owner on shipping:\n1. Extend the cutoff if we need it? We'\''"'\''"'\''re treating that as a no.\n2. Free shipping on orders $150+ on Thu only (labels about $24)?"}'\'''
run_case 'JSON body with apostrophes, an escaped newline and $150+ is text' "$json_send" 0
run_case 'single-quoted $5 after a double-quoted piece is text' "printf '%s\\n' 'a/b'\"x\"'c\$5'" 0
run_case 'apostrophe idiom then single-quoted $5 is text' "slack-call chat.postMessage '{\"text\": \"a/b'\"'\"''\"'\"'\$5\"}'" 0
multi_line="slack-call chat.postMessage '{\"text\": \"a/b'\"'\"'c
d \$5 more\"}'"
run_case 'single-quoted $5 on the second line of a quoted word is text' "$multi_line" 0

run_case 'double-quoted variable in a mixed word stays refused' "cat 'a/b'\"\$X\"'c'" 2
run_case 'unquoted positional after a quoted piece stays refused' "cat 'a/b'\"x\"'c'\$5" 2
run_case 'double-quoted positional in a mixed word stays refused' "cat 'a/b'\"x\$5\"" 2
run_case 'other company path with single-quoted dollar stays refused' "cat 'companies/otherco/x'\"x\"'\$5'" 2
run_case 'other company path after an apostrophe idiom stays refused' "cat 'companies/otherco/a'\"'\"'b'" 2
# A second parse expands single-quoted dollars, so these stay refused.
run_case 'eval of a single-quoted substitution stays refused' "eval 'cat '\"\"'\$(printf companies/oth)erco/f'" 2
run_case 'eval of a single-quoted variable path stays refused' "eval 'cat a/b''\$X/c'" 2
run_case 'bash here-string of a single-quoted substitution stays refused' "bash <<< 'cat '\"\"'\$(printf companies/oth)erco/f'" 2
run_case 'source of a here-string with a single-quoted variable stays refused' "source /dev/stdin <<< 'cat a/b'\"x\"'\$X/c'" 2
run_case 'sudo eval of a single-quoted variable path stays refused' "sudo eval 'cat a/b''\$X/c'" 2
sub="'cat '\"\"'\$(printf companies/oth)erco/f'"
run_case 'trap of a single-quoted substitution stays refused' "trap $sub EXIT" 2
run_case 'git alias with a single-quoted substitution stays refused' "git -c alias.x='!cat '\"\"'\$(printf companies/oth)erco/f' x" 2
run_case 'versioned shell name with a single-quoted substitution stays refused' "bash5 -c $sub" 2
run_case 'pwsh with a single-quoted substitution stays refused' "pwsh -c $sub" 2
ansi_c="echo \$'it\\'s'
cat 'a/b'\"\$X\"'c'"
run_case 'ANSI-C string on an earlier line does not hide a later variable' "$ansi_c" 2

echo "checks=$checks failures=$failures"
[ "$failures" -eq 0 ]
