#!/bin/bash
# block-no-verify-bulk-add.sh — PreToolUse hook for Bash.
#
# Blocks the --no-verify shapes from the loop that pushed a copy of an HQ root
# to GitHub on 2026-11-05 (incident a1227963): an agent-written loop ran
# `git add -A`, `git commit --no-verify` and `git push` on every dirty
# worktree, so the commit-time secret scan and the pre-push guard never ran.
#
# Blocked in one Bash command:
#   1. `git commit --no-verify` / `git commit -n` anywhere (the secret scan and
#      the repo's own hooks are skipped; policy hq-commit-secret-scan rule 3
#      already requires the owner's explicit OK for this).
#   2. `git push --no-verify` (skips the pre-push HQ-root guard).
#
# `git add -A` (or --all, or .) together with `git push` in one command is
# allowed: with hooks left on, the commit secret scan and push-guard.sh check
# what was staged and what leaves the machine. (The hook keeps its original
# file name so the installed hook path and fixture id stay stable.)
#
# Escape hatch, with the owner's OK for the one command:
#   HQ_ALLOW_NO_VERIFY=1 git -C /abs/repo commit --no-verify ...
#
# Exit codes: 0 = allow, 2 = block.

set -uo pipefail

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || true
[[ -z "$CMD" ]] && exit 0

if [[ "${HQ_ALLOW_NO_VERIFY:-}" == "1" ]]; then exit 0; fi
if echo "$CMD" | grep -Eq '(^|[[:space:]])HQ_ALLOW_NO_VERIFY=1([[:space:]]|$)'; then exit 0; fi

# Only commands that run git at all (bare or by path: /usr/bin/git).
echo "$CMD" | grep -Eq '(^|[[:space:];&|(/])git([[:space:]]|$)' || exit 0

block() {
  cat >&2 <<MSG
BLOCKED: $1

  Command: $CMD

WHY: On 2026-11-05 this exact shape (git add -A; git commit --no-verify; git
push, in a loop over worktrees) pushed a full copy of the HQ root — 161,628
files of personal and company data — to a private GitHub repo, because nothing
looked at the staged set and --no-verify skipped the secret scan.

FIX:
  - To preserve a dirty worktree before removing it, use the shipped flow,
    which checks size, HQ-root marker paths and secrets first:
      bash core/scripts/worktree-preserve.sh /abs/worktree [--push] [--dry-run]
  - Otherwise stage, commit WITHOUT --no-verify, inspect
    \`git -C /abs/repo diff --stat HEAD~1\`, and push in a separate call.
  - Skipping hooks needs the repo owner's explicit OK for that one command
    (policy hq-commit-secret-scan). With it, prefix the single command:
      HQ_ALLOW_NO_VERIFY=1 git -C /abs/repo commit --no-verify ...

If this block is wrong or surprising, report it with /hq-bug.
MSG
  exit 2
}

# A git segment is one `git ...` invocation up to the next ; & | or newline.
# commit -n is --no-verify; add -n is a dry run, so match per subcommand.
# Quoted strings (commit messages, grep patterns) are blanked first so the
# words inside them cannot trip the match.
STRIPPED="$(printf '%s' "$CMD" | sed -E "s/'[^']*'/''/g; s/\"[^\"]*\"/\"\"/g")"
# A token ends at whitespace, a separator, or the end of the line.
END='([[:space:];&|]|$)'
# `git <globals> <subcommand>`: globals are options and their values.
GIT='git([[:space:]]+[^|;&[:space:]]+)*[[:space:]]+'
# Bundled short flags: commit -n, -qn, -an, -nq ... (only flags that take no value).
if echo "$STRIPPED" | grep -Eq "${GIT}commit([[:space:]]+[^|;&]*)?[[:space:]](--no-verify|-[aqsv]*n[aqsv]*)$END"; then
  block "git commit --no-verify skips the secret scan and the repo's hooks."
fi
if echo "$STRIPPED" | grep -Eq "${GIT}push([[:space:]]+[^|;&]*)?[[:space:]]--no-verify$END"; then
  block "git push --no-verify skips the HQ-root push guard."
fi

exit 0
