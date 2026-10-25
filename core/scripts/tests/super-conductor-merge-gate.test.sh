#!/usr/bin/env bash
# super-conductor-merge-gate: a session on a /super-conductor link (one whose
# link has a decision queue) merges a PR only with an answered queue row for
# that repo, PR and head.
#   - a session on no link, or on a link with no decision queue, is not gated;
#   - a gated `gh pr merge` needs --match-head-commit and an answered or
#     relayed row whose ref is "merge <owner/repo> <pr> <sha>";
#   - an open, dropped, other-head, other-PR or other-repo row does not count;
#   - `gh api .../pulls/<n>/merge` is refused in a gated session;
#   - the hook prints a PreToolUse deny and nothing on allow;
#   - the hook is registered for Bash in all three hook-gate profiles.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
MG="$ROOT/core/scripts/super-conductor-merge-gate.mjs"
DQ="$ROOT/core/scripts/super-conductor-decisions.mjs"
HOOK="$ROOT/.claude/hooks/super-conductor-merge-gate.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [[ "$2" -ne 0 ]]; then echo "FAIL: $1" >&2; fail=1; fi; }
export SC_STANDING_FILE="$tmp/standing.json"

R="$tmp/root"
mkdir -p "$R/workspace/lanes-links/by-session" "$R/workspace/reports/conduct"
printf 'conductor cl-sc conductor\n' >"$R/workspace/lanes-links/by-session/sid-host"
printf 'child cl-sc lane-m\n' >"$R/workspace/lanes-links/by-session/sid-lane"
printf 'child cl-plain lane-p\n' >"$R/workspace/lanes-links/by-session/sid-plain"
Q="$R/workspace/reports/conduct/cl-sc-decisions.jsonl"
: >"$Q"
SHA=0123456789abcdef0123456789abcdef01234567

gate() { node "$MG" check --root "$R" --session "$1" --command "$2"; }

out="$(gate sid-none "gh pr merge 7 -R x/y --squash")"; rc=$?
check "a session on no link is not gated (rc $rc, got: $out)" "$([[ $rc -eq 0 ]]; echo $?)"
out="$(gate sid-plain "gh pr merge 7 -R x/y --squash")"; rc=$?
check "a link with no decision queue is not gated (rc $rc)" "$([[ $rc -eq 0 ]]; echo $?)"
out="$(gate sid-host "git status && gh pr list")"; rc=$?
check "a command with no merge is not gated (rc $rc)" "$([[ $rc -eq 0 ]]; echo $?)"

out="$(gate sid-lane "grep -rn 'gh pr merge' core/hooks")"; rc=$?
check "grep text naming the merge command is not a merge (rc $rc, got: $out)" "$([[ $rc -eq 0 ]]; echo $?)"
out="$(gate sid-lane "sed -i 's/x/gh pr merge 7/' f.sh && echo gh pr merge 7")"; rc=$?
check "sed/echo text naming the merge command is not a merge (rc $rc, got: $out)" "$([[ $rc -eq 0 ]]; echo $?)"
out="$(gate sid-lane "cd r && env GH_TOKEN=x gh pr merge 7 --squash")"; rc=$?
check "a launcher-prefixed merge is still gated (rc $rc, got: $out)" "$([[ $rc -eq 3 ]]; echo $?)"
out="$(gate sid-lane "bash -c 'gh pr merge 7 --squash'")"; rc=$?
check "a bash -c merge is still gated (rc $rc, got: $out)" "$([[ $rc -eq 3 ]]; echo $?)"
# A launcher with its own operands, a wrapper the gate has never heard of, and
# a computed env assignment all still run gh: unknown prefixes fail closed.
out="$(gate sid-lane "timeout 60 gh pr merge 7 -R x/y --squash")"; rc=$?
check "timeout N gh pr merge is still gated (rc $rc, got: $out)" "$([[ $rc -eq 3 ]]; echo $?)"
out="$(gate sid-lane "hq secrets exec --company indigo --only GH_TOKEN -- gh pr merge 7 -R x/y --squash")"; rc=$?
check "hq secrets exec -- gh pr merge is still gated (rc $rc, got: $out)" "$([[ $rc -eq 3 ]]; echo $?)"
out="$(gate sid-lane "GH_TOKEN=\$(cat tok) gh pr merge 7 -R x/y --squash")"; rc=$?
check "NAME=\$(...) gh pr merge is still gated (rc $rc, got: $out)" "$([[ $rc -eq 3 ]]; echo $?)"
out="$(gate sid-lane "nice -n 5 gh pr merge 7 -R x/y --squash")"; rc=$?
check "nice -n N gh pr merge is still gated (rc $rc, got: $out)" "$([[ $rc -eq 3 ]]; echo $?)"
# Text commands lose the exemption when the text can run: a substitution or
# subshell (with or without a launcher inside), a pipe onward, a redirection,
# sed's e command, awk's system().
out="$(gate sid-lane "echo \$(gh pr merge 7 -R x/y --squash)")"; rc=$?
check "a merge inside a substitution is still gated even under echo (rc $rc, got: $out)" "$([[ $rc -eq 3 ]]; echo $?)"
out="$(gate sid-lane "cat \$(env gh pr merge 7 -R x/y --squash)")"; rc=$?
check "a launcher inside a substitution under cat is still gated (rc $rc, got: $out)" "$([[ $rc -eq 3 ]]; echo $?)"
out="$(gate sid-lane "echo \$(timeout 60 gh pr merge 7 -R x/y --squash)")"; rc=$?
check "timeout inside a substitution under echo is still gated (rc $rc, got: $out)" "$([[ $rc -eq 3 ]]; echo $?)"
out="$(gate sid-lane "echo \`sudo gh pr merge 7 -R x/y --squash\`")"; rc=$?
check "a backtick substitution under echo is still gated (rc $rc, got: $out)" "$([[ $rc -eq 3 ]]; echo $?)"
out="$(gate sid-lane "echo gh pr merge 7 -R x/y --squash | sh")"; rc=$?
check "echo piped into sh is still gated (rc $rc, got: $out)" "$([[ $rc -eq 3 ]]; echo $?)"
out="$(gate sid-lane "printf '%s' 'gh pr merge 7 -R x/y --squash' | bash")"; rc=$?
check "printf piped into bash is still gated (rc $rc, got: $out)" "$([[ $rc -eq 3 ]]; echo $?)"
out="$(gate sid-lane "echo gh pr merge 7 -R x/y --squash > run.sh")"; rc=$?
check "echo redirected to a file is still gated (rc $rc, got: $out)" "$([[ $rc -eq 3 ]]; echo $?)"
out="$(gate sid-lane "sed '1e gh pr merge 7 -R x/y --squash' f")"; rc=$?
check "sed e command is still gated (rc $rc, got: $out)" "$([[ $rc -eq 3 ]]; echo $?)"
out="$(gate sid-lane "awk 'BEGIN{system( \"gh pr merge 7 -R x/y --squash\")}'")"; rc=$?
check "awk system() is still gated (rc $rc, got: $out)" "$([[ $rc -eq 3 ]]; echo $?)"
out="$(gate sid-lane "sed 's/^/gh pr merge 7 -R x/y --squash/e' f")"; rc=$?
check "sed s///e flag is still gated (rc $rc, got: $out)" "$([[ $rc -eq 3 ]]; echo $?)"
out="$(gate sid-lane "sed -n 's/^/gh pr merge 7 -R x/y --squash/ep' f")"; rc=$?
check "sed s///ep flags are still gated (rc $rc, got: $out)" "$([[ $rc -eq 3 ]]; echo $?)"
out="$(gate sid-lane "echo() { sh -c \"\$*\"; }; echo gh pr merge 7 -R x/y --squash")"; rc=$?
check "a redefined echo is still gated (rc $rc, got: $out)" "$([[ $rc -eq 3 ]]; echo $?)"
out="$(gate sid-lane "function cat { \"\$@\"; }
cat gh pr merge 7 -R x/y --squash")"; rc=$?
check "a redefined cat is still gated (rc $rc, got: $out)" "$([[ $rc -eq 3 ]]; echo $?)"
out="$(gate sid-lane "awk 'BEGIN{\"gh pr merge 7 -R x/y --squash\" | getline}'")"; rc=$?
check "awk getline is still gated (rc $rc, got: $out)" "$([[ $rc -eq 3 ]]; echo $?)"
out="$(gate sid-lane "sed 's/x/gh pr merge 7/' f.sh")"; rc=$?
check "a plain sed substitution naming the merge is text only (rc $rc, got: $out)" "$([[ $rc -eq 0 ]]; echo $?)"
# Text can leave a segment without a | or > inside it: a brace group or
# function body piped as a whole, &> (the & splits the segment), exec
# redirects, printf -v, sed w/-i writes, sed flags in any order, alias forms.
out="$(gate sid-lane "{ echo gh pr merge 7 -R x/y --squash; } | sh")"; rc=$?
check "a brace group piped into sh is still gated (rc $rc, got: $out)" "$([[ $rc -eq 3 ]]; echo $?)"
out="$(gate sid-lane "if true; then
echo gh pr merge 7 -R x/y --squash
fi | sh")"; rc=$?
check "an if block piped into sh is still gated (rc $rc, got: $out)" "$([[ $rc -eq 3 ]]; echo $?)"
out="$(gate sid-lane "echo gh pr merge 7 -R x/y --squash &>x; sh x")"; rc=$?
check "echo &> file then sh is still gated (rc $rc, got: $out)" "$([[ $rc -eq 3 ]]; echo $?)"
out="$(gate sid-lane "exec >x; echo gh pr merge 7 -R x/y --squash; sh x")"; rc=$?
check "exec redirect then echo then sh is still gated (rc $rc, got: $out)" "$([[ $rc -eq 3 ]]; echo $?)"
out="$(gate sid-lane "printf -v c %s gh pr merge 7 -R x/y --squash; \$c")"; rc=$?
check "printf -v then expansion is still gated (rc $rc, got: $out)" "$([[ $rc -eq 3 ]]; echo $?)"
out="$(gate sid-lane "sed -i '1i gh pr merge 7 -R x/y --squash' x; sh x")"; rc=$?
check "sed -i then sh is still gated (rc $rc, got: $out)" "$([[ $rc -eq 3 ]]; echo $?)"
out="$(gate sid-lane "sed -n 's/^/gh pr merge 7 -R x/y --squash/w s.sh' f")"; rc=$?
check "sed w flag is still gated (rc $rc, got: $out)" "$([[ $rc -eq 3 ]]; echo $?)"
out="$(gate sid-lane "sed 's/^/gh pr merge 7 -R x/y --squash/ge' f")"; rc=$?
check "sed ge flags are still gated (rc $rc, got: $out)" "$([[ $rc -eq 3 ]]; echo $?)"
out="$(gate sid-lane "alias -g echo=sh; echo gh pr merge 7 -R x/y --squash")"; rc=$?
check "alias -g redefinition is still gated (rc $rc, got: $out)" "$([[ $rc -eq 3 ]]; echo $?)"
out="$(gate sid-lane "awk -i inplace '{print \"gh pr merge 7 -R x/y --squash\"}' s.sh; sh s.sh")"; rc=$?
check "gawk in-place then sh is still gated (rc $rc, got: $out)" "$([[ $rc -eq 3 ]]; echo $?)"
out="$(gate sid-lane "cat notes.txt | gh pr merge 7 -R x/y --squash")"; rc=$?
check "a merge after a pipe from cat is still gated (rc $rc, got: $out)" "$([[ $rc -eq 3 ]]; echo $?)"

out="$(gate sid-lane "gh pr merge 7 -R x/y --squash")"; rc=$?
check "a gated merge without --match-head-commit is refused (rc $rc, got: $out)" "$([[ $rc -eq 3 && "$out" == *match-head-commit* ]]; echo $?)"
out="$(gate sid-lane "gh pr merge 7 -R x/y --squash --match-head-commit $SHA")"; rc=$?
check "a gated merge with no queue row is refused (rc $rc, got: $out)" "$([[ $rc -eq 3 && "$out" == *"merge x/y 7 $SHA"* ]]; echo $?)"

id="$(node "$DQ" add --file "$Q" --source conductor --ref "merge x/y 7 $SHA" --question "Merge x/y 7 at ${SHA:0:8}?" --option Merge --option Hold --priority critical --no-standing)"
out="$(gate sid-lane "gh pr merge 7 -R x/y --squash --match-head-commit $SHA")"; rc=$?
check "an open (unanswered) row does not allow the merge (rc $rc)" "$([[ $rc -eq 3 ]]; echo $?)"
node "$DQ" claim --file "$Q" --id "$id" --desk desk >/dev/null
node "$DQ" answer --file "$Q" --id "$id" --answer Merge --desk desk >/dev/null
out="$(gate sid-lane "gh pr merge 7 -R x/y --squash --match-head-commit $SHA")"; rc=$?
check "an answered Merge row for the same repo, PR and head allows it (rc $rc, got: $out)" "$([[ $rc -eq 0 ]]; echo $?)"
out="$(gate sid-host "gh pr merge https://github.com/x/y/pull/7 --squash --match-head-commit ${SHA:0:12}")"; rc=$?
check "a PR URL and a short head prefix match the row (rc $rc, got: $out)" "$([[ $rc -eq 0 ]]; echo $?)"
out="$(gate sid-lane "gh pr merge 7 -R x/y --match-head-commit fedcba9876543210fedcba9876543210fedcba98")"; rc=$?
check "another head is refused (rc $rc)" "$([[ $rc -eq 3 ]]; echo $?)"
out="$(gate sid-lane "gh pr merge 8 -R x/y --match-head-commit $SHA")"; rc=$?
check "another PR is refused (rc $rc)" "$([[ $rc -eq 3 ]]; echo $?)"
out="$(gate sid-lane "gh pr merge 7 -R x/z --match-head-commit $SHA")"; rc=$?
check "another repo is refused (rc $rc)" "$([[ $rc -eq 3 ]]; echo $?)"
out="$(gate sid-lane "gh pr merge 7 --match-head-commit $SHA")"; rc=$?
check "a gated merge must name the repo with -R (rc $rc, got: $out)" "$([[ $rc -eq 3 && "$out" == *"-R"* ]]; echo $?)"
out="$(gate sid-lane "echo ok; gh pr merge 7 -R x/y --match-head-commit $SHA && gh pr merge 9 -R x/y --match-head-commit $SHA")"; rc=$?
check "every merge in a compound command needs its own row (rc $rc)" "$([[ $rc -eq 3 ]]; echo $?)"

hid="$(node "$DQ" add --file "$Q" --source conductor --ref "merge x/y 10 $SHA" --question 'Merge x/y 10?' --option Merge --option Hold --priority critical --no-standing)"
node "$DQ" claim --file "$Q" --id "$hid" --desk desk >/dev/null
node "$DQ" answer --file "$Q" --id "$hid" --answer Hold --desk desk >/dev/null
out="$(gate sid-lane "gh pr merge 10 -R x/y --match-head-commit $SHA")"; rc=$?
check "an answered Hold row does not allow the merge (rc $rc)" "$([[ $rc -eq 3 ]]; echo $?)"
did="$(node "$DQ" add --file "$Q" --source conductor --ref "merge x/y 11 $SHA" --question 'Merge x/y 11?' --option Merge --option Hold --priority critical --no-standing)"
node "$DQ" drop --file "$Q" --id "$did" --note gone --by desk >/dev/null
out="$(gate sid-lane "gh pr merge 11 -R x/y --match-head-commit $SHA")"; rc=$?
check "a dropped row does not allow the merge (rc $rc)" "$([[ $rc -eq 3 ]]; echo $?)"

out="$(gate sid-lane "gh api -X PUT repos/x/y/pulls/7/merge")"; rc=$?
check "gh api pulls/<n>/merge is refused in a gated session (rc $rc)" "$([[ $rc -eq 3 ]]; echo $?)"
out="$(gate sid-lane "g'h' pr merge 12 -R x/y --match-head-commit $SHA")"; rc=$?
check "quote-split gh pr merge is still gated (rc $rc)" "$([[ $rc -eq 3 ]]; echo $?)"
# Review fix (#1583 re-review): only the gh subcommand position decides api vs pr.
out="$(gate sid-lane "gh pr merge 12 -R x/y -t api --match-head-commit $SHA")"; rc=$?
check "-t api on gh pr merge is still gated (rc $rc, got: $out)" "$([[ $rc -eq 3 ]]; echo $?)"
out="$(gate sid-lane "gh pr merge 12 -R x/y --body api --match-head-commit $SHA")"; rc=$?
check "--body api on gh pr merge is still gated (rc $rc)" "$([[ $rc -eq 3 ]]; echo $?)"
out="$(gate sid-lane "gh pr merge 12 -R x/y --subject=api --match-head-commit $SHA")"; rc=$?
check "--subject=api on gh pr merge is still gated (rc $rc)" "$([[ $rc -eq 3 ]]; echo $?)"
out="$(gate sid-lane "gh api repos/x/y/pulls/7 --jq .mergeable")"; rc=$?
check "a read-only gh api call that is not a merge is not gated (rc $rc)" "$([[ $rc -eq 0 ]]; echo $?)"
out="$(gate sid-lane "xargs -I{} gh gh pr merge 12 -R x/y --match-head-commit $SHA")"; rc=$?
check "a second gh token in one segment is checked too (rc $rc)" "$([[ $rc -eq 3 ]]; echo $?)"
# Review fix (#1583, third review): a value flag before the subcommand
# (gh -R owner/repo pr merge, gh -X PUT api ...) does not hide the merge.
out="$(gate sid-lane "gh -R x/y pr merge 12 --match-head-commit $SHA")"; rc=$?
check "gh -R x/y pr merge with no row is gated (rc $rc, got: $out)" "$([[ $rc -eq 3 ]]; echo $?)"
out="$(gate sid-lane "gh --repo x/y pr merge 7 --match-head-commit $SHA")"; rc=$?
check "gh --repo x/y pr merge 7 with its answered row is allowed, repo read before the subcommand (rc $rc, got: $out)" "$([[ $rc -eq 0 ]]; echo $?)"
out="$(gate sid-lane "gh -X PUT api repos/x/y/pulls/7/merge")"; rc=$?
check "gh -X PUT api .../merge is refused (rc $rc)" "$([[ $rc -eq 3 ]]; echo $?)"
out="$(gate sid-lane "gh --method=PUT api repos/x/y/pulls/7/merge")"; rc=$?
check "gh --method=PUT api .../merge is refused (rc $rc)" "$([[ $rc -eq 3 ]]; echo $?)"
out="$(gate sid-lane "gh -R x/y pr view 12")"; rc=$?
check "gh -R x/y pr view is not a merge (rc $rc)" "$([[ $rc -eq 0 ]]; echo $?)"

# The hook: PreToolUse JSON in, deny JSON out, nothing on allow.
payload() { jq -cn --arg s "$1" --arg c "$2" '{session_id:$s, tool_name:"Bash", tool_input:{command:$c}}'; }
out="$(payload sid-lane "gh pr merge 8 -R x/y --match-head-commit $SHA" | CLAUDE_PROJECT_DIR="$R" bash "$HOOK")"
check "the hook denies an ungated merge with a reason (got: $out)" "$([[ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out")" == deny ]]; echo $?)"
out="$(payload sid-lane "gh pr merge 7 -R x/y --match-head-commit $SHA" | CLAUDE_PROJECT_DIR="$R" bash "$HOOK")"
check "the hook prints nothing when a row covers the merge (got: $out)" "$([[ -z "$out" ]]; echo $?)"
out="$(payload sid-none "gh pr merge 7 -R x/y" | CLAUDE_PROJECT_DIR="$R" bash "$HOOK")"
check "the hook prints nothing for a session on no link (got: $out)" "$([[ -z "$out" ]]; echo $?)"
[[ -x "$HOOK" ]]; check "the hook is executable" $?

REG="$ROOT/.claude/hooks/hook-registry.json"
node -e '
  const r = require(process.argv[1]).hooks;
  process.exit((r.PreToolUse || []).some((e) => /(^|\|)Bash(\||$)/.test(e.matcher) && e.hooks.some((h) => h.id === "super-conductor-merge-gate")) ? 0 : 1);
' "$REG"; check "super-conductor-merge-gate is registered for PreToolUse Bash" $?
check "super-conductor-merge-gate is in all three hook-gate profile lists" "$([[ $(grep -c 'super-conductor-merge-gate' "$ROOT/.claude/hooks/hook-gate.sh") -eq 3 ]]; echo $?)"

[[ "$fail" -eq 0 ]] || exit 1
echo "super-conductor-merge-gate: ok"
