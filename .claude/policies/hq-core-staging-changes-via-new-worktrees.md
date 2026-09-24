---
id: hq-core-staging-changes-via-new-worktrees
title: All hq-core-staging changes happen in a fresh dedicated worktree
scope: repo
when: (git && (worktree || branch || commit || push || fetch || pull || switch || checkout || merge || rebase || reset || stash || restore || cherry-pick || revert || am || apply || add || rm || mv || clean || tag)) || (gh && pr) || (hq-core-staging && (edit || delete || write))
on: [UserPromptSubmit, PreToolUse, AssistantIntent]
trigger: any session or worker about to create, edit, or delete files in hq-core-staging, or run a git/gh mutation against it (branch, commit, push, PR)
enforcement: hard
public: false
version: 2
created: 2026-08-17
updated: 2026-09-24
source: user-correction
applies_to: [git, github]
---

## Rule

NEVER edit or run git mutations directly in the primary hq-core-staging
checkout (`repos/private/hq-core-staging/`). Every change — code, docs,
policies, hooks, workflows — MUST be made in a fresh, dedicated git worktree
created for that task, via the HQ `/worktree` skill (shipped in this repo at
`.claude/skills/worktree/`) — do not hand-roll `git worktree add`:

```bash
bash .claude/skills/worktree/worktree.sh \
  --name <task-slug> \
  --source /abs/path/to/repos/private/hq-core-staging \
  [--branch <branch-name>]        # defaults to wt/<task-slug>
```

The skill fetches origin, branches off `origin/main`, creates the worktree at
`workspace/worktrees/hq-core-staging/<task-slug>/`, and guarantees the primary
checkout (working tree, refs, stash) is untouched. Only if the skill script is
unavailable in the running environment (e.g. a bare CI worker), fall back to
the equivalent raw command:

```bash
git -C /abs/path/to/repos/private/hq-core-staging worktree add \
  /abs/path/to/workspace/worktrees/hq-core-staging/<task-slug> \
  -b <branch-name> origin/main
```

Work, commit, and push only inside that worktree, then open a PR. When the
branch lands, remove the worktree
(`git -C <repo> worktree remove <path>` — never `rm -rf`, which strands
administrative state in `.git/worktrees/`) and delete the branch. One task,
one worktree, one branch — never reuse another task's worktree or branch.

The primary checkout stays read-only (it is typically parked on a detached
HEAD). Treat it as the shared base other workers cut worktrees from, not as a
working directory.

## Rationale

Multiple workers and sessions operate on hq-core-staging concurrently
(release stamping, backmerges, review-fix workers, agency executors). If any
of them edits the primary checkout directly, they share one working tree and
one HEAD: uncommitted edits interleave, `git checkout`/`git switch` by one
worker rips files out from under another, and commits land on whatever branch
the last worker left checked out. Fresh per-task worktrees give every worker
an isolated tree and branch, so concurrent work cannot conflict until it
merges — where conflicts are visible and resolvable.

This composes with, and does not contradict, `hq-no-worktree-for-repo-work`:
that rule forbids worktrees of the **HQ root**; worktrees of source repos
under `workspace/worktrees/<repo>/<name>/` are the sanctioned flow, and for
this repo they are mandatory.

## Examples

- Fixing a hook script here → `bash .claude/skills/worktree/worktree.sh
  --name fix-hook-name --source <repo>`, edit inside the printed worktree
  path, push, PR.
- Quick one-line README tweak → same flow; there is no "small enough to edit
  in place" exception, because conflicts come from concurrency, not change
  size.
- Reviewing or reading code → fine in the primary checkout; reads don't
  conflict.
