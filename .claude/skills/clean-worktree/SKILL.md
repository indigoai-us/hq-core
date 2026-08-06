---
name: clean-worktree
description: Clean up an HQ git worktree — merge a detached worktree branch back into local main in the primary HQ tree, then remove the worktree and delete the branch. Use when HQ work happened in a separate worktree (e.g. .claude/worktrees/<name> on claude/*, or workspace/worktrees/<name> on codex/*) and needs to land and be cleaned up — including right after /handoff when HQ itself is running from a separate worktree. HQ is local-only; this workflow never pushes to a remote.
allowed-tools: Bash(git:*), Bash(ls:*), Bash(rmdir:*), Read, AskUserQuestion
---

# Clean HQ Worktree

Use this when HQ work was done in a separate git worktree and you now need to bring those commits back into the primary HQ tree's `main` branch and remove the leftover worktree. Triggers: "clean up that worktree", "merge the worktree back", "fold the agent worktree into main", "reclaim the worktree", or noticing stale entries in `.claude/worktrees/` or `workspace/worktrees/`.

This is HQ-internal builder work. It operates only on the local HQ git repository. HQ is local-only by hard policy (`hq-root-never-push-remote`): nothing in this workflow ever contacts a remote — no `push`, no `fetch`, no `pull`. Cross-machine state moves via `hq-sync`, never git push.

## Recommended After `/handoff`

When HQ itself is running from a separate worktree (the active session's tree is `.claude/worktrees/<name>` or `workspace/worktrees/<name>` rather than the primary HQ root), the work and handoff artifacts land on that worktree's branch. Once `/handoff` has fully completed — thread file written, `handoff.json` saved, INDEX updated, finalize commit done — run `/clean-worktree` to merge that branch back into the primary tree's `main` and remove the worktree, so the next session starts from a single clean tree on `main`.

Do this **after** handoff finishes, never **during** it: handoff owns its own commit/finalize flow, and merging a worktree mid-handoff corrupts that state. The sequence is always: `/handoff` completes → then `/clean-worktree`.

## Mental Model

The HQ root (`${HQ_ROOT}`) is itself a git repository, always checked out on `main`. Agent isolation and Codex worktrees create *linked* worktrees of that same repository:

- `.claude/worktrees/<name>/` — typically on branch `claude/<name>`
- `workspace/worktrees/<name>/` — typically on branch `codex/<name>`

A linked worktree shares the HQ object store. Cleaning it up means: land its branch's commits into `main` in the primary tree, then tear down the worktree and delete its branch so the tree is clean again. You cannot `git checkout <branch>` in the primary tree (the worktree holds it checked out, and the primary tree must stay on `main`) — you merge the branch *into* `main` from the primary tree instead.

## Critical Guardrails

These are non-negotiable. Several are mechanically enforced.

1. **Every git mutation in this workflow carries an explicit absolute `-C` anchor AND the `HQ_ALLOW_HQ_ROOT_GIT=1` prefix, in the same Bash call.** Worktree operations and merges into `main` mutate the shared HQ object store and are HQ-root-class. Bare HQ-root git mutations are mechanically blocked by `.claude/hooks/block-hq-root-git-mutation.sh`. Form: `HQ_ALLOW_HQ_ROOT_GIT=1 git -C ${HQ_ROOT} <cmd>` for primary-tree ops, `HQ_ALLOW_HQ_ROOT_GIT=1 git -C ${HQ_ROOT}/.claude/worktrees/<name> <cmd>` for in-worktree ops. Never rely on an earlier `cd` — shell cwd drifts across context compaction and parallel calls.
2. **Never push, fetch, or pull HQ.** No remote interaction anywhere in this skill. Do not ask "should I push HQ?" — the answer is always no.
3. **Read-only inspection commands** (`git worktree list`, `git status`, `git log`, `git diff`, `git branch --merged`) need neither the anchor-prefix nor confirmation. Run them freely.
4. **Destructive steps require explicit confirmation in full prose.** `git worktree remove`, `git branch -D`, and any `--force` permanently discard work. Before each, list exactly what will be lost (uncommitted files, unmerged commits) and wait for the user to confirm.
5. **Resolve conflicts; never discard them.** If the merge conflicts, resolve file-by-file, `git add` the resolution, and commit. Never `git checkout --`/`git restore` a conflicted path to make it go away, and never `--no-verify` on `main`.
6. **One worktree at a time.** If several are reclaimable, use `AskUserQuestion` to pick one per call — never batch the decision.
7. **Do not run during `/handoff`.** Run it only after handoff has fully completed (see "Recommended After /handoff" above).

## Process

### 1. Discover candidates

```bash
git worktree list --porcelain
```

The entry whose `branch` is `refs/heads/main` and whose path is the HQ root is the primary tree — never a cleanup target. Every *other* entry under the HQ root (`.claude/worktrees/...` or `workspace/worktrees/...`) is a candidate.

If the user named a worktree or branch, resolve it to one candidate (match on directory basename or branch name). If not, present the candidates with their state and ask which one (`AskUserQuestion`, one pick). For each candidate gather, read-only:

```bash
git -C <WT> status --short | wc -l                 # dirty file count
git -C <WT> log main..HEAD --oneline               # commits to bring back
git -C <WT> diff --stat main...HEAD                 # change scope
```

If a candidate has **zero commits ahead of main and no dirty files**, there is nothing to merge — go straight to step 5 (cleanup only) for that one.

### 2. Capture uncommitted work in the worktree

If `git -C <WT> status --short` is non-empty, the worktree has uncommitted changes that the merge would otherwise leave behind. Commit them inside the worktree before merging:

```bash
HQ_ALLOW_HQ_ROOT_GIT=1 git -C <WT> add -A
HQ_ALLOW_HQ_ROOT_GIT=1 git -C <WT> commit -m "clean-worktree: capture uncommitted work from <name>"
```

If `git commit` reports nothing to commit (changes were only ignored/session files), note it and continue. Do not force-add ignored paths.

### 3. Pre-merge safety check on the primary tree

```bash
git -C ${HQ_ROOT} status --short
```

Untracked files in the primary tree that collide with incoming paths will abort the merge. HQ autocommit normally keeps the primary tree tidy; if there is unexpected dirty/untracked state that would collide, surface it to the user and resolve it (commit or move aside) before merging — do not blindly `--force` or clean.

### 4. Merge the branch into main

From the primary tree, on `main`:

```bash
HQ_ALLOW_HQ_ROOT_GIT=1 git -C ${HQ_ROOT} merge --no-ff <BRANCH> \
  -m "clean-worktree: merge <BRANCH> into main"
```

`--no-ff` keeps a visible reclaim point in history. A fast-forward (`HQ_ALLOW_HQ_ROOT_GIT=1 git -C ${HQ_ROOT} merge --ff-only <BRANCH>`) is acceptable when `main` has not advanced and the user prefers linear history — ask only if it matters; otherwise default to `--no-ff`.

**On conflict:** do not abort by default. Inspect with `git -C ${HQ_ROOT} status`, resolve each conflicted file deliberately (these are often skill/command/policy file deletions vs. edits — preserve the intended end state, do not just take one side blindly), then:

```bash
HQ_ALLOW_HQ_ROOT_GIT=1 git -C ${HQ_ROOT} add <resolved-paths>
HQ_ALLOW_HQ_ROOT_GIT=1 git -C ${HQ_ROOT} commit --no-edit
```

If conflicts are too entangled to resolve confidently, `HQ_ALLOW_HQ_ROOT_GIT=1 git -C ${HQ_ROOT} merge --abort`, report the conflicting paths to the user, and stop — do not guess.

### 5. Verify the merge landed

```bash
git -C ${HQ_ROOT} branch --merged main | grep -F "<BRANCH>"
git -C ${HQ_ROOT} log --oneline -3
```

`<BRANCH>` must appear in `--merged`. The reclaimed commits must be visible in `main`'s log. Do not proceed to cleanup until this is confirmed.

### 6. Cleanup — destructive, confirm first

State explicitly to the user, in full prose, what is about to be permanently removed: the worktree directory at `<WT>`, the branch `<BRANCH>`, and confirm there is no uncommitted or unmerged work left (steps 2 and 5 should have ensured this). Wait for confirmation, then:

```bash
HQ_ALLOW_HQ_ROOT_GIT=1 git -C ${HQ_ROOT} worktree remove <WT>
HQ_ALLOW_HQ_ROOT_GIT=1 git -C ${HQ_ROOT} branch -d <BRANCH>
HQ_ALLOW_HQ_ROOT_GIT=1 git -C ${HQ_ROOT} worktree prune
```

- `git worktree remove` (no `--force`) refuses if the worktree is still dirty — that is a safety feature. If it refuses, return to step 2; only use `--force` after the user explicitly confirms the remaining changes are disposable.
- `git branch -d` (lowercase) refuses to delete an unmerged branch — also a safety feature. If it refuses, the merge in step 4 did not actually land; do not reach for `-D`. Only use `git branch -D` after the user explicitly confirms they intend to discard unmerged commits.
- If the directory lingers after `worktree remove` (rare), remove the now-empty path with `rmdir <WT>` and re-run `worktree prune`.

### 7. Report

Concise summary: branch cleaned up, number of commits and files merged into `main`, worktree path removed, branch deleted. End with `git worktree list` so the user sees the tree is clean.

## Notes

- HQ non-repo edits autosave via `.claude/hooks/hq-autocommit.sh`, so most worktree work is already committed on its branch — step 2 usually finds nothing, but always check.
- This skill does not touch `repos/` worktrees. Those are normal code repos with their own push/PR discipline; cleaning up an HQ orchestration-layer worktree is a different operation from landing a code branch.
- If the worktree's branch was already merged in a prior session, steps 4–5 are no-ops and you proceed straight to cleanup — that is the normal "just clean up the leftover" path.
