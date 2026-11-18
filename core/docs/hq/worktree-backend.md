# Worktree backend (git or twig)

HQ creates code-repo dev worktrees through one helper,
`core/scripts/worktree-backend.sh`. These callers use it:

- the `/worktree` skill (`.claude/skills/worktree/worktree.sh`)
- `/run-project` worktrees: `ensure_worktree`, `ensure_missing_repo_worktree`
  and per-story worktrees in `.claude/scripts/run-project.sh`
- pipeline lanes: `add_worktree` in `core/scripts/pipeline-conductor.sh`
  (plain git on Windows)

`core/scripts/worktree.sh` forwards to `hq core worktree` in the hq CLI, which
still calls `git worktree add` directly. Routing it through the helper is an
hq-cli change.

## The setting

```yaml
# core/settings/worktrees.yaml (ships with backend: git)
worktrees:
  backend: git   # git | twig
```

Resolution order, first match wins:

1. `HQ_WORKTREE_BACKEND` environment variable
2. `personal/settings/worktrees.yaml`
3. `core/settings/worktrees.yaml`
4. `git`

To opt in, install twig and create `personal/settings/worktrees.yaml`:

```bash
cargo install git-twig --locked
git twig --version    # needs 0.3.0 or newer
```

```yaml
worktrees:
  backend: twig
```

Check what is in effect:

```bash
bash core/scripts/worktree-backend.sh backend
```

## What twig does

[git twig](https://twig.leostera.dev) creates ordinary linked Git worktrees
using native copy-on-write: APFS clonefile on macOS, reflink on Linux Btrfs and
reflink-enabled XFS. A new worktree shares file data with the source checkout
until either side writes. The author describes it as a prototype.

Twig copies committed tracked files only. Untracked and ignored directories,
such as `node_modules/` and `target/`, are not copied, so install dependencies
(or copy a warm build cache) as you would with plain git.

## How the helper uses twig

- Twig takes its CoW path only when the requested commit is the source
  checkout's current HEAD. HQ usually bases worktrees on `origin/<default>`.
  When the base differs from HEAD, the helper clones HEAD with
  `git twig new --detach`, then runs `git switch` in the new worktree to the
  requested branch and base. Git rewrites only the files that differ.
- Twig refuses its CoW path when a repo has a `post-index-change` or
  `reference-transaction` hook. HQ's global git-hooks dispatcher installs a
  forwarding stub for every hook name, so every HQ repo has both. When those two
  are HQ dispatcher stubs with nothing to forward to, the helper gives twig a
  filtered view of the hooks directory (all other stubs kept) through
  `git -c core.hooksPath=...`, for that one command. A real hook of either kind
  is left in place and twig uses stock Git.
- Fallback to plain `git worktree add` happens silently when twig is missing,
  older than 0.3.0, the platform is not macOS or Linux, or twig fails. A
  partial worktree left by a failed twig attempt is removed before the git
  retry. On filesystems without CoW (ext4, for example) twig itself delegates to
  stock Git.

## Removal and cleanup

Twig worktrees are ordinary linked worktrees. `worktree-backend.sh remove`,
`git worktree remove`, `worktree-gc.sh`, `free-disk-space.sh`,
`worktree-preserve.sh` and `/clean-worktree` all work on them unchanged. Twig
keeps failed-attempt staging under `<common-git-dir>/twigs/staging`; the helper
never deletes it.

## Soak log

When the effective backend is `twig`, every create appends one JSON line to
`workspace/reports/twig-soak/events.jsonl` with the repo, path, backend used
(`twig-cow`, `twig-cow+switch`, `twig-stock`, or `git` for a fallback), the
fallback reason, any error, duration in milliseconds, and the free-space change
on the target filesystem. Write a daily summary with:

```bash
bash core/scripts/twig-soak-summary.sh            # today (UTC)
bash core/scripts/twig-soak-summary.sh --date 2026-11-16
```

## Tests

`core/scripts/tests/worktree-backend.test.sh` covers: setting off uses plain
git; setting on with twig uses twig; base different from HEAD; existing-branch
and detached modes; twig missing, too old, or failing falls back; HQ hook-stub
filtering; env override; and removal of twig-made and git-made worktrees. It
uses a stub twig, and also runs the real twig when it is installed.
