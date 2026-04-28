---
id: hq-git-discipline
title: HQ git discipline — branch hygiene, focused commits, safe probes, history-preserving moves, chip-safe pushes, reflog/stash safety
scope: global
trigger: any git operation in HQ working tree, repos/, or knowledge repos — commits, pushes, merges, rebases, history rewrites, stash, reflog, gc
enforcement: hard
public: true
version: 1
created: 2026-04-27
updated: 2026-04-27
source: consolidation
merged_from:
  - git-workflow
  - git-branch-verify
  - git-add-explicit-paths-no-drift
  - git-checkout-not-a-probe
  - git-filter-repo-case-variants
  - hq-git-bulk-archive-rename-detection
  - hq-git-log-shell-wrapper-hides-merges
  - hq-git-push-refspec-chip-safe
  - hq-git-reflog-expire-all-destroys-stash
  - hq-git-staged-deletion-verify-blob-before-reset
  - hq-git-stash-for-focused-pr-with-wip
merged_at: 2026-04-27
---

## Rule

Eleven independent hard rules covering day-to-day git hygiene, focused commits, safe inspection, history-preserving moves, chip-safe pushes, and stash/reflog protection. Each is a real failure mode with its own remedy; do not collapse them when reading. Soft-enforcement git policies live in their own files (see Related).

### 1. Verify branch before committing

ALWAYS run `git branch --show-current` before committing to any repo. Never assume the current branch — inherited cwd or package installs can silently land you on an unintended branch. Recovery if wrong: create the correct branch, cherry-pick the commit, revert from the wrong branch.

### 2. Pull latest before starting repo work

ALWAYS `git fetch origin` then check `git rev-list --count HEAD..origin/<branch>` before making changes. If `> 0`, pull (or merge) before proceeding. If pull fails due to local changes, stash first (rule 13). For repos significantly behind origin (50+ commits), prefer merge over rebase. A `{your-project}` session in 2026-03-21 built a control plane on a local main 372 commits behind origin/main — merge produced 21 conflicted files that took hours; a session-start `git pull` would have cost 10 seconds.

### 3. Create `.gitignore` before first commit in new projects

ALWAYS create `.gitignore` (with `node_modules/`, `.next/`, `.vercel/`, build artifacts) BEFORE running `git init && git add -A && git commit`. If build artifacts enter git history, GitHub rejects pushes for files >100 MB and the only fix is nuking `.git` and reinitializing. During `vyg-competitive-intel` scaffolding, `npm install` ran before `git init` and the first commit captured `next-swc.darwin-arm64.node` (100.35 MB), forcing full repo reinitialization.

### 4. Never push HQ to a remote

NEVER push HQ data to any remote repository. HQ is local-only. The `origin` remote (`indigoai-us/hq`) is used only for PULLING upstream updates. Only push repos inside `repos/` — never the HQ root. HQ contains private company credentials, projects, and orchestrator state that must not leave the local machine.

### 5. Stage focused commits with explicit paths — no `git add -A` when drift exists

Before committing a focused deliverable (PRD, policy, infra file, feature code), run `git status --short`. If unrelated modifications, untracked files, or submodule pointer drift exist alongside the intended change, stage **only the intended paths**:

```bash
git add path/one path/two path/three
git commit -m "..."
```

NEVER use `git add -A`, `git add .`, or `git add -u` when drift the commit shouldn't address is present. If drift is itself worth committing, commit it separately — one concern per commit. For submodule / knowledge-repo pointer drift (e.g. `m companies/{co}/tools/chart-renderer`), check whether it represents in-progress upstream work before staging.

**Concurrent-session caveats.** If another session is editing the same repo, the working tree can change between `git add` and `git commit`:

1. Verify commit content with `git show <sha>:<path>` (reads commit object directly, not the working tree).
2. `git stash push --include-untracked -m "<label>" -- <paths>` to isolate before staging; pop after.

**Vercel-build side effects.** `vercel build` mutates `next-env.d.ts`, `package-lock.json`, `.next/`, `.vercel/output/`, `tsconfig.tsbuildinfo`. Always use explicit `git add <path>` after a local build — `git add -A` rides those artifacts into the diff and can silently downgrade dep pins via lockfile drift.

### 6. `git checkout {branch} -- .` is NOT a read-only probe

`git checkout {branch} -- .` **overwrites your current working tree** with every file from `{branch}`, leaving HEAD pointing at your original branch. The result is a staged undo of every committed-and-pushed change that differs between the two branches — invisible from the commit graph alone.

To inspect another branch without switching:

```bash
git show main:path/to/file              # single file content
git diff main..HEAD -- path/to/file     # diff without modifying tree
git diff --name-only main..HEAD         # list of differing files
git worktree add /tmp/main-check main   # full-tree scratch space
```

To compare lint/build between branches: `git stash -u && git switch main && npm run lint && git switch - && git stash pop`.

**Recovery if accidentally run.** Verify HEAD with `git rev-parse HEAD`; verify origin with `git rev-parse origin/{branch}`; if both intact, `git reset --hard HEAD` restores cleanly. If local has unpushed commits, confirm they're in `git reflog` first — `checkout -- .` only touches the working tree, never commits.

The path form (`-- <pathspec>`) is a write operation dressed up as a read. When you catch yourself typing `git checkout {something} -- .`, STOP.

### 7. `git filter-repo --replace-text` requires explicit case variants

`git filter-repo --replace-text` does exact literal matching. A rule for `secret-name` does NOT match `Secret-Name` or `SECRET-NAME`. ALWAYS add explicit replacement rules for every case variant of every term:

```
literal:term==>
literal:Term==>
literal:TERM==>
```

During a v9.0.0 history scrub, a lowercase-only first pass left 65 hits; the second pass needed 29 additional case variants (74 total rules) to fully scrub.

### 8. Bulk archive/rename — single commit for rename detection

ALWAYS stage bulk archive/rename operations as a single commit so git's rename detection produces `R100` records, preserving `git log --follow` history:

```bash
mv companies/{old}/projects/{slug} companies/{old}/projects/_archive/{slug}
git add -u companies/{old}/projects/{slug}          # the deletion
git add companies/{old}/projects/_archive/{slug}    # the addition
git commit -m "archive: move {slug} to _archive/"   # both sides in ONE commit
```

Anti-patterns that destroy history:

- **Two separate commits** (deletion-commit then addition-commit) — rename detection runs per-commit and cannot bridge them.
- **`cp -r` + `rm -r`** instead of `mv` — breaks inode continuity.
- **`git mv` in a loop across thousands of files** — slow and occasionally mis-stages.

For >10k-file renames, bump `git config diff.renameLimit 999999` for the commit; never disable detection.

### 9. Verify merges via raw plumbing, not shell-wrapper `git log`

The HQ shell wrapper for `git log` (and oh-my-zsh git aliases) filter merge commits out of the default display. `git log --oneline -20` showing only regular commits does NOT prove a merge didn't land — it may exist on HEAD but be hidden.

When verifying a merge landed, ALWAYS use plumbing that bypasses aliases:

```bash
git rev-parse HEAD
git cat-file -p HEAD | head -5    # two `parent` lines = merge commit
# or
git log -1 --pretty=raw HEAD      # raw, always shows parents
git log --merges -5               # merges-only, bypasses default filter
```

NEVER conclude "the merge didn't land" from a filtered `git log --oneline`. This produced at least one false-negative during swarm-mode branch validation where the orchestrator re-tried a merge that had already succeeded.

### 10. Detached-HEAD + push refspec from worktrees with active chips

When committing to a specific branch from a worktree where spawned-task chips may be active, use detached-HEAD + push refspec in a single bash invocation:

```bash
git checkout --detach origin/{target} && {edits or cherry-pick} && git push origin HEAD:{target}
```

NEVER rely on `git checkout {branch} && git commit && git push origin {branch}` when chips are active — a chip can swap the branch back mid-stream, silently landing the commit on the wrong branch and turning the push into a no-op (because `HEAD` now points at whatever branch the chip restored). The detached-HEAD form pins the commit to a SHA and the explicit `HEAD:{target}` refspec forwards that SHA directly to the remote, neither step depending on the local branch pointer surviving concurrent mutation. Composes safely with `isolation: "worktree"` chips — last-line safety net if isolation fails or isn't used.

### 11. Preserve at-risk WIP before `reflog expire --all` or `gc --prune=now`

`git reflog expire --all` expires the reflog for *every* ref — including the synthetic `refs/stash`. Once gone, `git stash list` returns empty and the stash commits become unreachable; a subsequent `git gc --prune=now` deletes them. ALWAYS protect WIP first:

1. Promote stashes to real branches:
   ```bash
   git stash list | awk -F: '{print $1}' | while read s; do
     git stash branch "rescue/${s//[\/]/-}" "$s" || true
   done
   ```
2. Or scope expiration to specific refs:
   ```bash
   git reflog expire --expire=now HEAD
   git reflog expire --expire=now refs/heads/main
   ```
3. NEVER chain `reflog expire --all` with `gc --prune=now` without first verifying every stash has a corresponding branch (`git branch --list 'rescue/*'`).

The `--all` flag's blast radius is non-obvious: stashes look like a separate data structure in porcelain (`git stash list`), but plumbing-wise they are reflog entries on `refs/stash`. The same `--all` that "cleans up old branch reflogs" wipes the stash reflog with no prompt.

### 12. Verify blob hash before resetting a staged-deletion + untracked pair

When `git status` shows the confusing pair:

```
D  src/index.ts          # staged deletion
?? src/index.ts          # same path, now untracked
```

DO NOT reach for `git checkout HEAD -- <path>` or `git reset --hard` — both are destructive. Verify whether the on-disk blob still matches HEAD first:

```bash
git ls-tree HEAD -- src/index.ts | awk '{print $3}'   # HEAD blob hash
git hash-object src/index.ts                          # current on-disk hash
```

- **Hashes match** → someone ran `git rm --cached <path>`. File is unchanged on disk; only the index entry was dropped. Non-destructive fix:
  ```bash
  git reset HEAD -- src/index.ts
  ```
- **Hashes differ** → file was truly modified. Only then consider `git checkout` or manual merge, knowing on-disk content will change.

`git reset HEAD -- <path>` when hashes match is idempotent and loses zero work. Same principle as rule 6: verify state before invoking an operation that writes.

### 13. `git stash push -u` to land focused PRs while WIP exists

When you need to land a single-concern PR while uncommitted WIP exists, ALWAYS use `git stash push -u -m "<label>"` to capture both modified AND untracked files, then:

1. `git stash push -u -m "wip-<context>"` — captures everything
2. Branch from the now-clean tree, make the targeted edit, commit, push, open the PR
3. `git checkout <previous-branch>` (or stay on the new branch if appropriate)
4. `git stash pop` — restores the WIP intact

NEVER bundle unrelated WIP into a "fix the test suite" / "while I'm in here" PR. A focused PR's diff must contain exactly the change its title describes — bundling collapses signal-to-noise for review and breaks revert safety. The `-u` flag is the difference between "saved my modified files" and "saved my entire working state" — untracked files (new test fixtures, scratch scripts, generated artifacts) are silently lost without it. A labeled stash entry (`-m`) makes recovery unambiguous when multiple stashes accumulate.

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

Keeping the rules on one page rather than eleven separate files preserves cross-references (rule 1 underlies rule 10's branch verify; rule 5 composes with rule 13's stash; rules 6 and 12 share the verify-before-write principle) and reduces cold-start digest weight without losing any failure mode.

## Provenance

Consolidated 2026-04-27 from eleven prior policy files (see `merged_from`). The earlier `git-workflow.md` consolidation (2026-04-13) had folded `git-branch-verify.md`, `hq-pull-before-work.md`, `hq-gitignore-before-first-commit.md`, and `no-hq-remote-push.md` but left `git-branch-verify.md` on disk as a duplicate; this merge completes that cleanup. Eleven soft-enforcement git policies (`hq-git-stash-build-artifacts-conflict`, `hq-git-branch-delete-reverify-current`, `hq-git-diff-three-dot-for-pr-review`, `hq-git-divergence-check-both-directions`, `hq-git-fsck-stash-recovery`, `hq-git-large-diff-audit-before-panic`, `hq-git-merge-ff-only-trunk`, `hq-git-server-side-push-multi-phase-migration`, `hq-git-squash-merge-branch-ahead-expected`, `hq-git-stage-then-reset-submodule-pointer`, `hq-git-verify-ancestry-before-claiming-on-main`) remain separate to preserve their soft status — they are not auto-injected at session start.

## Related

- `.claude/policies/repo-run-coordination.md` — cross-session repo ownership locks (composes with rules 1, 5, 10).
- `.claude/policies/hq-swarm-pr-branch.md` — swarm-mode branch handling after `/run-project --swarm` (composes with rule 10).
- `.claude/policies/hq-task-chip-worktree-isolation.md` — task chip isolation; rule 10 is the last-line safety net if isolation fails.
- `.claude/policies/hq-bash-discipline.md` — broader shell discipline (chip-safe push idiom from rule 10 is bash-specific).
- Eleven soft git policies listed in Provenance — soft-enforcement nuance for less-common scenarios.
