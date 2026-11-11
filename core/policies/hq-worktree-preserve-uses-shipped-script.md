---
id: hq-worktree-preserve-uses-shipped-script
title: Preserve a dirty worktree only through worktree-preserve.sh; never skip hooks with --no-verify
when: (worktree && (preserve || purge || remove || sweep || disk)) || (add && push && all) || no-verify || (wip && push)
on: [PreToolUse, UserPromptSubmit, AssistantIntent]
enforcement: hard
tier: 1
version: 1
created: 2026-11-07
updated: 2026-11-11
source: incident
public: true
---

## Rule

1. **One flow preserves a dirty worktree.** To keep uncommitted work before a
   worktree is removed, run
   `bash core/scripts/worktree-preserve.sh /abs/worktree [--push] [--dry-run]`.
   Do not write a loop that runs `git add -A`, `git commit` and `git push`
   over worktrees, and do not reuse one from `workspace/tmp/`.
2. **Never `--no-verify`.** `git commit --no-verify` (or `-n`) and
   `git push --no-verify` skip the secret scan and the push guard. The
   PreToolUse hook `block-no-verify-bulk-add` blocks them. With the repo
   owner's explicit OK for one command, prefix it with `HQ_ALLOW_NO_VERIFY=1`.
3. **Look at what a bulk add staged.** `git add -A` (or `--all`, or `.`)
   followed by `git push` in one Bash command is not blocked; with hooks on,
   the commit secret scan and the push guard check it. Read
   `git diff --cached --stat` before committing a bulk add.
4. **A KEPT worktree stays.** When `worktree-preserve.sh` prints `KEPT`, it
   committed nothing. Read the reason (size ceiling, HQ-root marker paths,
   secret scan, hook), fix the cause or report it; do not remove the worktree,
   do not pass `--allow-large` without the owner's word, and do not bypass the
   marker check (it has no override).
5. **The push guard is a backstop, not the plan.** `core/scripts/push-guard.sh`
   runs on every `git push` once `commit-secret-scan.sh enable` has wired the
   HQ git hooks. A blocked push names the marker paths; remove them from the
   commits. `HQ_PUSH_GUARD_ALLOW=1` is for the owner, once, for an intended
   large or unusual push.

## Why

On 2026-11-05 an agent-written purge script ran that exact sequence on 426
worktrees. One worktree under `repos/private/` held a copy of the whole HQ
root (personal overlay, company folders, a credentials folder: 161,628
files). The script staged all of it, skipped the commit-time secret scan with
`--no-verify`, and pushed it to the private repo `hq-core-staging`. The
repository had to be purged through GitHub Support.

Nothing in the flow looked at what was being staged, and no guard sat between
`add -A` and `push`. The shipped script and the push guard each stop that on
their own; the PreToolUse rule stops the hooks from being skipped.

## Where

- `core/scripts/worktree-preserve.sh`, denylist
  `core/settings/worktree-preserve-denylist.txt` (local additions in
  `personal/settings/worktree-preserve-denylist.txt`), ledger
  `workspace/reports/worktree-preserve-<date>.md`.
- `core/scripts/push-guard.sh`, run by the `pre-push` stage of
  `core/scripts/lib/git-hooks-dispatcher.sh`.
- `core/hooks/PreToolUse/30-Bash--block-no-verify-bulk-add.sh`, fixture
  `core/hook-tests/block-no-verify-bulk-add.yaml`.
- Related: `hq-commit-secret-scan`, `hq-root-never-push-remote`.
