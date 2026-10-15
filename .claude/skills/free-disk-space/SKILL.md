---
name: free-disk-space
description: Reclaim disk from stale linked worktrees, build dirs, and allowlisted dev caches. Dry-run unless --apply; never deletes full clones, .env, or unpushed work.
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
   belong to.

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

3. **Dry run first.** Run the chosen mode without `--apply`
   (`bash core/scripts/free-disk-space.sh <mode>`). It prints `would-remove` and
   `kept ... reason=...` lines and deletes nothing. Show that list to the user.

4. **Ask before apply.** Use AskUserQuestion to confirm the dry-run list. Only
   after an explicit yes, re-run the same mode with `--apply`
   (`bash core/scripts/free-disk-space.sh --apply <mode>`).

5. **Remaining worktrees** with uncommitted work, unpushed commits, a stash,
   hidden local edits (skip-worktree or assume-unchanged), a nested git repository,
   or ignored files such
   as `.env` are never deleted by this skill. If the user wants
   them gone, list them and confirm each one, or offer to push them first.
   Deleting unpushed work is irreversible: state that plainly and get an explicit
   yes before removing anything outside the modes above.

## Rules

- Never delete `~/.cache/qmd` (search index) or `~/.cache/codex-runtimes`.
- Do not empty the Trash or touch `~/Downloads`, Documents, or app data without an
  explicit request naming them.
- Age-based worktree deletion uses the last commit date. Report how many worktrees
  and how many GB a cutoff would catch before deleting by age.
