---
name: free-disk-space
description: Reclaim disk from stale linked worktrees, build dirs, allowlisted dev caches, unreachable HQ git objects, and disabled HQ sync mirrors. Dry-run unless --apply; never deletes full clones, .env, or unpushed work.
allowed-tools: Bash(bash core/scripts/free-disk-space.sh:*), AskUserQuestion
---

# /free-disk-space

Reclaim disk space on the user's machine. All work goes through
`core/scripts/free-disk-space.sh`. Run long modes with `run_in_background: true`;
`du` over worktrees can take minutes.

**User's input:** $ARGUMENTS

## Steps

1. **Scan.** Run `bash core/scripts/free-disk-space.sh scan`. Report free space and
   the largest areas in a plain table: what it is, size, whether it is safe to clear.
   If worktrees are large, also run `worktrees-status` to show which projects they
   belong to. A `partial` row timed out; its size is a lower bound, shown as `>=`.

   The scan ends with an "hq git and sync mirror" block. Report it too:
   - `hq-git ... loose=... packed=...` is the HQ root git (`<hq>/.git`). A large
     loose size means files reached git without being packed.
   - `warn autosave-stale` means HQ autosave has not committed for 7 or more days.
     Tell the user plainly that autosave may be writing files into git without
     committing them, and suggest `/hq-bug` with the scan output.
   - `disabled-mirror ...` is an HQ sync git recovery copy of an HQ root that
     sync turned off (it holds `hq-sync-mirror-disabled.json`). It may belong to
     another or a wiped HQ root, so do not say it holds the same objects as
     `<hq>/.git/objects`. Only `trash-disabled-mirror` can tell, by checking that
     every object in it (commits from refs, HEAD and reflogs, and unreferenced
     objects) exists in the HQ root. `active-mirror` lines are in use;
     never offer them.

2. **Offer options** with AskUserQuestion, one question per call. Nothing is deleted
   before the user picks.
   - `caches` — deletes only a named allowlist of developer caches (Homebrew, pip,
     Yarn, npm, pnpm, node-gyp, go-build, cargo, turbo, typescript, electron), the
     npm cache, and safe `~/.cache` entries (`gh`, `prisma`, `node`, `agent-browser`).
     It does not touch other app caches. It keeps the qmd search index and Codex
     runtimes.
   - `prune-backed-up [hours]` — removes linked git worktrees that are clean, pushed
     (including every branch checked out there), stash-free, free of ignored files
     outside rebuildable build directories, free of a nested git repository under
     those directories, free of skip-worktree or assume-unchanged index flags,
     untouched for N hours (default 6; any file, commit, or checkout), and not owned
     by a session. A worktree is session-owned when a live process has its cwd
     inside it (`reason=live-session`) or a Claude Code / Codex transcript from
     the last 7 days recorded a cwd inside it (`reason=recent-session`).
     Full clones are never removed. Removal uses `git worktree remove`, not `rm -rf`.
   - `slim-idle [days]` — in worktrees idle N days (default 7), deletes git-ignored
     dependency and build folders that contain no tracked files and no nested git
     repository. It skips a checkout with skip-worktree or assume-unchanged flags,
     with a nested git repository, or owned by a session. Code and commits stay.
   - `prune-hq-history` — runs `git prune --expire=1.hour.ago` on the HQ root git. It
     deletes only loose objects that no commit, ref, reflog, or index reaches and
     that are over an hour old, so a git command running at the same time keeps
     its new objects. The
     dry run prints `would-prune objects=N disk=...`. It holds the autosave lock
     while it runs and stops if autosave is running. It refuses
     (`reason=borrowed-by <repo>`) while a repo under the HQ root or a recovery
     copy borrows the HQ root's objects through `objects/info/alternates`.
   - `trash-disabled-mirror` — moves a disabled HQ sync recovery copy under
     `~/.hq/hq-root-git/` to the Trash only when every object in it (commits reachable from its refs, HEAD and
     reflogs, and unreferenced objects) exists in the current HQ root's git
     (`refs-covered`). It keeps a copy with a commit the HQ root lacks
     (`reason=commit-missing-from-hq-root`), a copy with any other object the HQ
     root lacks, such as a dangling commit or a lone blob
     (`reason=object-missing-from-hq-root`), a non-bare copy with an index or
     working-tree changes (`reason=non-bare-copy-has-index` or
     `non-bare-copy-has-changes`), a copy that cannot
     be read (`reason=refs-unreadable`), any copy when the HQ root is shallow
     (`reason=hq-root-shallow`), an active copy, and a copy the HQ root
     borrows objects from. It never deletes. The space comes back only when the
     user empties the Trash.

   When the scan shows a disabled mirror and a large loose size, offer both
   `trash-disabled-mirror` and `prune-hq-history`: either one alone can free very
   little.

3. **Dry run first.** Run the chosen mode without `--apply`
   (`bash core/scripts/free-disk-space.sh <mode>`). It prints `would-remove` and
   `kept ... reason=...` lines and deletes nothing. Show that list to the user.

4. **Ask before apply.** Use AskUserQuestion to confirm the dry-run list. Only
   after an explicit yes, re-run the same mode with `--apply`
   (`bash core/scripts/free-disk-space.sh --apply <mode>`). For
   `prune-hq-history` and `trash-disabled-mirror`, also pass `--yes`
   (`bash core/scripts/free-disk-space.sh --apply --yes <mode>`). Without `--yes`
   those modes refuse and change nothing. Pass `--yes` only after the user says
   yes to that dry run in this conversation.

5. **Remaining worktrees** with uncommitted work, unpushed commits, a stash,
   hidden local edits (skip-worktree or assume-unchanged), a nested git repository,
   or ignored files such
   as `.env` are never deleted by this skill. If the user wants
   them gone, list them and confirm each one, or offer to push them first.
   Deleting unpushed work is irreversible: state that plainly and get an explicit
   yes before removing anything outside the modes above.

## Rules

- Never delete `~/.cache/qmd` (search index) or `~/.cache/codex-runtimes`.
- Never run `git prune`, `git gc`, or `rm` on `<hq>/.git` or `~/.hq` by hand. Use
  the modes above.
- Do not empty the Trash or touch `~/Downloads`, Documents, or app data without an
  explicit request naming them.
- Age-based worktree deletion uses the last commit date. Report how many worktrees
  and how many GB a cutoff would catch before deleting by age.
