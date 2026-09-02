---
id: hq-git-discipline
title: HQ git discipline — branch hygiene, focused commits, safe probes, history-preserving moves, chip-safe pushes, reflog/stash safety
when: git && commit
on: [PreToolUse]
enforcement: hard
tier: 1
public: true
version: 1
created: 2026-04-27
updated: 2026-08-06
source: consolidation
merged_from:
  - git-workflow
  - git-branch-verify
  - git-add-explicit-paths-no-drift
  - git-checkout-not-a-probe
  - git-filter-repo-case-variants
  - hq-git-bulk-archive-rename-detection
  - hq-git-log-shell-wrapper-hides-merges
  - hq-gitignore-before-first-commit
  - hq-git-push-refspec-chip-safe
  - hq-git-reflog-expire-all-destroys-stash
  - hq-git-staged-deletion-verify-blob-before-reset
  - hq-git-stash-for-focused-pr-with-wip
merged_at: 2026-04-27
---

## Rule

Verify branch + pull before commit; explicit paths (no `git add -A` with drift); `git checkout -- .` is destructive, not a probe; never push HQ; preserve WIP before reflog gc.

### 1. Verify branch before committing

ALWAYS run `git branch --show-current` before committing. Never assume the current branch — inherited cwd or package installs can silently land you on an unintended one.

### 2. Pull latest before starting repo work

ALWAYS `git fetch origin`, then check `git rev-list --count HEAD..origin/<branch>`. If `> 0`, pull or merge before changing anything. If the pull fails on local changes, stash first (rule 13). For repos 50+ commits behind, prefer merge over rebase.

### 3. Create `.gitignore` before first commit in new projects

ALWAYS write `.gitignore` (`node_modules/`, `.next/`, `.vercel/`, build artifacts) BEFORE `git init && git add -A && git commit`. Build artifacts in history mean GitHub rejects the push above 100 MB, and the only fix is nuking `.git`.

### 4. Never push HQ to a remote

NEVER push HQ to any remote. HQ is local-only; `origin` (`indigoai-us/hq`) is for PULLING upstream updates. Only repos inside `repos/` get pushed — never the HQ root. HQ holds private company credentials, projects, and orchestrator state.

### 5. Stage focused commits with explicit paths — no `git add -A` when drift exists

Run `git status --short` first. If unrelated modifications, untracked files, or submodule pointer drift sit alongside the intended change, stage **only the intended paths**:

```bash
git add path/one path/two && git commit -m "..."
```

NEVER `git add -A`, `git add .`, or `git add -u` when drift the commit shouldn't address is present — commit that separately, one concern per commit. After a local `vercel build`, explicit paths are mandatory: it mutates `next-env.d.ts`, `package-lock.json`, `.next/`, `.vercel/output/`, `tsconfig.tsbuildinfo`, and `-A` rides those in and can silently downgrade dep pins. If another session shares the repo, verify with `git show <sha>:<path>` (reads the commit object, not the tree).

### 6. `git checkout {branch} -- .` is NOT a read-only probe

The path form **overwrites your working tree** with every file from `{branch}` while HEAD stays put — a staged undo of every pushed change differing between the two, invisible from the commit graph. It is a write dressed up as a read. When you catch yourself typing `git checkout {something} -- .`, STOP. Read another branch with `git show main:<path>`, `git diff main..HEAD -- <path>`, or `git worktree add /tmp/check main` instead.

### 7. `git filter-repo --replace-text` requires explicit case variants

`--replace-text` matches literally: a rule for `secret-name` does NOT match `Secret-Name` or `SECRET-NAME`. ALWAYS add a rule per case variant of every term (`literal:term==>`, `literal:Term==>`, `literal:TERM==>`).

### 8. Bulk archive/rename — single commit for rename detection

Stage both sides of a bulk move in ONE commit so rename detection emits `R100` and `git log --follow` survives:

```bash
mv {src} {dest}
git add -u {src} && git add {dest}
git commit -m "archive: move {slug} to _archive/"
```

NEVER split the deletion and addition across two commits (detection runs per-commit and cannot bridge them), and never substitute `cp -r` + `rm -r` for `mv`. For >10k files, raise `git config diff.renameLimit 999999` — never disable detection.

### 9. Verify merges via raw plumbing, not shell-wrapper `git log`

The HQ `git log` wrapper and oh-my-zsh aliases filter merge commits out of the default display, so a clean `git log --oneline -20` does NOT prove a merge is absent. Verify with plumbing that bypasses aliases — `git cat-file -p HEAD` (two `parent` lines = merge), `git log -1 --pretty=raw HEAD`, or `git log --merges -5`. NEVER conclude "the merge didn't land" from a filtered `git log --oneline`.

### 10. Detached-HEAD + push refspec from worktrees with active chips

When committing from a worktree where spawned-task chips may be active, pin the commit to a SHA and push it by refspec in one invocation:

```bash
git checkout --detach origin/{target} && {edits} && git push origin HEAD:{target}
```

NEVER use `git checkout {branch} && git commit && git push origin {branch}` there — a chip can swap the branch mid-stream, landing the commit on the wrong branch and making the push a silent no-op.

### 11. Preserve at-risk WIP before `reflog expire --all` or `gc --prune=now`

`reflog expire --all` expires *every* ref's reflog including the synthetic `refs/stash`, making stash commits unreachable; a following `gc --prune=now` deletes them. Protect WIP first — promote stashes to branches (`git stash branch`), or scope expiry to named refs (`git reflog expire --expire=now refs/heads/main`). NEVER chain `reflog expire --all` into `gc --prune=now` without confirming every stash has a branch.

### 12. Verify blob hash before resetting a staged-deletion + untracked pair

When `git status` shows the same path as both `D` (staged deletion) and `??` (untracked), DO NOT reach for `git checkout HEAD -- <path>` or `git reset --hard` — both are destructive. Compare `git ls-tree HEAD -- <path>` against `git hash-object <path>` first. Hashes match → it was `git rm --cached`; `git reset HEAD -- <path>` is idempotent and loses nothing. Hashes differ → the file really changed; only then consider a write. Same principle as rule 6: verify state before invoking an operation that writes.

### 13. `git stash push -u` to land focused PRs while WIP exists

To land a single-concern PR while uncommitted WIP exists: `git stash push -u -m "wip-<context>"`, branch from the clean tree, make the targeted edit, commit, push, open the PR, then `git stash pop`. The `-u` is the difference between saving your modified files and saving your whole working state — untracked fixtures and scratch scripts are lost without it. NEVER bundle unrelated WIP into a "while I'm in here" PR; a focused diff must contain exactly what its title describes, or revert safety breaks.

## Examples

Extended recovery procedures and the incidents each rule was paid for.

**Rule 1 recovery.** Committed on the wrong branch: create the correct branch, cherry-pick the commit onto it, revert it from the wrong branch.

**Rule 2.** A 2026-03-21 session built a control plane on a local main 372 commits behind origin/main; the merge produced 21 conflicted files and took hours. A session-start `git pull` would have cost 10 seconds.

**Rule 3.** On a research project `npm install` ran before `git init`, so the first commit captured `next-swc.darwin-arm64.node` (100.35 MB) and the repo had to be reinitialized from scratch.

**Rule 5.** For submodule / knowledge-repo pointer drift (e.g. `m companies/{co}/tools/chart-renderer`), check whether it represents in-progress upstream work before staging. To isolate before staging under concurrent edits: `git stash push --include-untracked -m "<label>" -- <paths>`, then pop after.

**Rule 6 recovery.** Verify `git rev-parse HEAD` and `git rev-parse origin/{branch}`; if both are intact, `git reset --hard HEAD` restores cleanly. With unpushed commits, confirm they are in `git reflog` first — `checkout -- .` only touches the working tree, never commits. To compare lint/build across branches: `git stash -u && git switch main && npm run lint && git switch - && git stash pop`.

**Rule 7.** A v9.0.0 history scrub left 65 hits after a lowercase-only first pass; the second pass needed 29 additional case variants (74 rules total).

**Rule 11.** Promote every stash to a branch before expiring:

```bash
git stash list | awk -F: '{print $1}' | while read s; do
  git stash branch "rescue/${s//[\/]/-}" "$s" || true
done
git branch --list 'rescue/*'    # verify before gc
```

The blast radius is non-obvious: stashes look like a separate structure in porcelain, but are reflog entries on `refs/stash`. The same `--all` that cleans up old branch reflogs wipes them with no prompt.

## Rationale

All eleven rules share the same failure shape: **a routine git command does the wrong thing because git's surface area conflates read-vs-write, branch-vs-pathspec, all-refs-vs-one-ref, or session-local-vs-shared state**. Each was paid for in production:

- Rules 1–4 (`git-workflow`) — branch confusion, 372-commit divergence merge, 100 MB build artifacts in history, and the standing rule that HQ never pushes upstream.
- Rule 5 — focused-PRD commits that would have swept submodule + report drift into the diff.
- Rule 6 — a sprint-handoff session that ran `git checkout main -- .` on a feature branch and reverted every sprint file.
- Rule 7 — v9.0.0 history scrub left 65 hits because lowercase-only filter rules missed `{Term}`, `{TERM}` variants.
- Rule 8 — a two-commit archive that lost months of `git log --follow` history; single-commit redo produced clean `R100` records.
- Rule 9 — swarm-mode validation re-tried a merge that had already succeeded because the shell wrapper hid it from `git log --oneline`.
- Rule 10 — chip-induced branch swap during commit produced silent data loss (commit on wrong branch, push reports success but is a no-op).
- Rule 11 — `reflog expire --all` followed by `gc --prune=now` destroyed stashed WIP that had to be reconstructed.
- Rule 12 — `D + ??` after `git rm --cached` looks confusing; instinct `git checkout HEAD -- <path>` overwrites in-progress edits.
- Rule 13 — hq-desktop jsdom 28 + vitest 4 upgrade where a focused single-file PR needed to land while ~25 unrelated test files were mid-edit.

Keeping the rules on one page rather than eleven separate files preserves cross-references (rule 1 underlies rule 10's branch verify; rule 5 composes with rule 13's stash; rules 6 and 12 share the verify-before-write principle) and reduces cold-start context weight without losing any failure mode.

## Related

- `.claude/policies/repo-run-coordination.md` — cross-session repo ownership locks (composes with rules 1, 5, 10).
- `core/policies/hq-task-chip-worktree-isolation.md` — task chip isolation; rule 10 is the last-line safety net if isolation fails.
- `core/policies/hq-bash-discipline.md` — broader shell discipline (chip-safe push idiom from rule 10 is bash-specific).
- Eleven soft git policies listed in Provenance — soft-enforcement nuance for less-common scenarios.
