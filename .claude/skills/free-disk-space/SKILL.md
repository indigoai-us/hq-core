---
name: free-disk-space
description: Find and reclaim disk space from stale HQ worktrees, build folders, and dev caches without losing unpushed work.
allowed-tools: Bash, AskUserQuestion
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
   - `caches` — clears app caches, the npm cache, and safe `~/.cache` entries. Keeps
     the qmd search index and Codex runtimes. No risk to work.
   - `prune-backed-up [hours]` — deletes worktrees that are clean, pushed to their
     upstream, have no stash, and were not touched in the last N hours (default 6).
   - `slim-idle [days]` — in worktrees idle N days (default 7), deletes git-ignored
     dependency and build folders. Code and commits stay; they rebuild on next use.

3. **Run** the chosen mode and report GB freed plus the new free total.

4. **Remaining worktrees** with uncommitted, unpushed, or stashed work are never
   deleted by this skill. If the user wants them gone, list them and confirm each
   one, or offer to push them first. Deleting unpushed work is irreversible: state
   that plainly and get an explicit yes before removing anything outside the modes
   above.

## Rules

- Never delete `~/.cache/qmd` (search index) or `~/.cache/codex-runtimes`.
- Do not empty the Trash or touch `~/Downloads`, Documents, or app data without an
  explicit request naming them.
- Age-based worktree deletion uses the last commit date. Report how many worktrees
  and how many GB a cutoff would catch before deleting by age.
