---
id: hq-git-fsck-stash-recovery
title: Recover hook-dropped stashes via git fsck dangling commits
scope: global
trigger: a git hook (pre-commit, lint-staged, husky) or manual mishap dropped/lost a stash and you need to recover the original working tree
enforcement: soft
public: true
version: 1
created: 2026-04-21
updated: 2026-04-21
source: session-learning
---

## Rule

ALWAYS recover hook-dropped stashes through dangling-commit archaeology, not blind `git stash apply`:

1. `git fsck --dangling --no-reflogs` (add `--no-reflogs` if reflog is too noisy) to enumerate orphan commits
2. For each candidate SHA, inspect parent count:
   - `git log -1 --format='%P' <sha>` — THREE parents = a true `git stash` snapshot (WIP, index, untracked). TWO parents = just the index tree (`index on ...`) and usually NOT what you want
3. Confirm with `git log -1 --format='%s' <sha>` — true stashes start with `WIP on` or `On <branch>:`
4. Recover individual files with `git restore --source=<sha> -- <paths>` rather than `git stash apply <sha>` — the per-path restore avoids pulling in pre-rebase siblings (e.g. an older CLAUDE.md) that would overwrite current work

## Rationale

Hooks that call `git stash pop` inside a failing path can drop the stash ref while leaving the commit dangling but unreferenced. Plain `git stash list` won't show it. `git fsck --dangling` surfaces every orphan, but half the candidates are `index on ...` commits (2 parents) that represent just the staged tree at stash time — applying them overwrites the working tree with nothing useful. The 3-parent shape is the signature of the top-level stash commit whose tree is the actual WIP. Restoring by path (not `stash apply`) is load-bearing when the stash predates a rebase: a full apply drags along the pre-rebase snapshot of unrelated files.
