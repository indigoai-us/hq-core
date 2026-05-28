---
id: git-add-explicit-paths-no-drift
title: Stage focused commits by explicit path, never git add -A when unrelated drift exists
scope: global
trigger: committing PRD artifacts, infrastructure changes, or any focused deliverable
enforcement: hard
tier: 1
public: true
version: 4
created: 2026-04-16
updated: 2026-05-21
source: user-correction
---

## Rule

Before committing a focused deliverable (PRD, policy, infrastructure file, feature code), run `git status --short` and inspect the working tree. If unrelated modifications, untracked files, or submodule pointer drift exist alongside the intended change, stage **only the intended paths explicitly**:

```bash
git add path/one path/two path/three
git commit -m "..."
```

Never use `git add -A`, `git add .`, or `git add -u` when the working tree contains drift the commit is not meant to address. If the drift is itself worth committing, commit it separately with its own message — one concern per commit.

When the drift is a submodule or knowledge-repo pointer (e.g. `m companies/{co}/tools/chart-renderer`), check whether it represents in-progress upstream work before deciding to stage, skip, or reset. Never silently fold submodule pointer bumps into an unrelated commit.

## Never mix directories and individual files in one `git add -A <paths>` call

`git add -A <dir1> <dir2> <file1.ts> <file2.ts>` looks like it stages everything you listed, but in practice it can silently drop modifications to the listed individual files while still picking up the directory contents (observed 2026-05-21 in `liverecover-gtm-hq` PR #149: `git add -A src/app/ops src/app/tasks src/components/ui/nav.tsx next.config.ts` staged the directory file renames but dropped modifications to `nav.tsx` and `next.config.ts`, requiring follow-up fix PR #150).

Either:

1. **Stage directories and files in separate `git add` calls** (then commit once), OR
2. **Run `git status` (or `git diff --cached --name-only`) between stage and commit** and verify every intended path is actually in the index before you commit.

The silent-drop failure mode is invisible without explicit verification — `git add` returns 0 either way.

## Concurrent-session caveats

When another session is actively editing the same repo, the working tree can change between `git add` and `git commit`. Two techniques keep the commit honest:

1. **Verify commit content after the fact with `git show <sha>:<path>`.** `git diff HEAD~1` reads the working tree, which may have drifted; `git show` reads the commit object directly. Use it to confirm the commit captured what you intended.
2. **Stash by path to isolate before staging.** `git stash push --include-untracked -m "<label>" -- <paths>` removes only the concurrent session's files, leaving your intended edits clean. Pop the stash after your commit lands so you don't strand the sibling session's work.

Never use `git add -A` in a repo you know is being edited concurrently — even a one-second window between staging and committing is enough for another session's autosave to land.

## Merge-resolution caveats

When resolving a merge in a worktree where the main worktree (or a sibling worktree on the same repo) already has pre-existing dirty state — uncommitted changes, untracked files, gitlink/submodule pointer drift — `git add -A` is especially dangerous. A merge commit visible in shared history that quietly bundled an unrelated session's WIP is hard to untangle.

Use selective `git add <paths>` to stage ONLY the merge-resolution files:

```bash
# 1. Inspect what merge actually conflicted
git status --short | grep -E '^(UU|AA|DD|AU|UA|UD|DU)'

# 2. Stage only those resolution paths explicitly
git add <conflicted-path-1> <conflicted-path-2> ...

# 3. Verify staged set excludes pre-existing dirt
git diff --cached --name-only
git diff --cached --name-only | grep -E '<known-dirty-paths>' && echo "DIRT LEAKED — do not commit"
```

Only after the staged set matches the resolution set may you `git commit` the merge.

If the merge requires staging legitimate build-script side effects alongside the conflict resolutions (regenerated digests, INDEX rebuilds), see `hq-cmd-handoff-merge-stage-build-artifacts` for how to distinguish derived artifacts from pre-existing dirt.

## Release-commit caveat — never sweep untracked litter into a publishable artifact

When staging a **release** commit (version bump, tag-triggering commit) for a package or app, untracked litter in the working tree is not just noise — it can break the published build. Observed in the hq-sync v0.1.88 release: `git add -A` swept a stray untracked `pnpm-workspace.yaml` into the release commit, which broke the tauri build with `ERROR packages field missing or empty`. The file looked harmless but its mere presence at the repo root changed the build's package resolution.

Before any release commit:

1. Run `git status --short` and account for **every** untracked file — a stray `pnpm-workspace.yaml`, `.npmrc`, `tsconfig.*`, or lockfile at the repo root can silently alter build behavior.
2. Stage only the intended release paths explicitly (`package.json`, `src-tauri/tauri.conf.json`, changelog, etc.).
3. If untracked litter exists, remove or `.gitignore` it — do NOT let it ride the release commit.
