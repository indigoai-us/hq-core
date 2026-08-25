---
id: hq-worktree-retention
title: HQ Worktree Retention — auto-GC stale worktrees, never lose work
public: true
when: worktree
on: [UserPromptSubmit, AssistantIntent]
enforcement: soft
tier: 2
version: 1
created: 2026-08-17
updated: 2026-08-17
source: authored
---

## Rule

HQ git worktrees (under `workspace/worktrees/` and `.claude/worktrees/`)
accumulate forever unless garbage-collected — a real machine reached 113
worktrees / ~200GB. `core/scripts/worktree-gc.sh` reclaims them **safely**:
it removes a worktree ONLY when every guard holds, and defaults to a dry-run.

### Removal requires ALL of

1. **Clean working tree** — `git status --porcelain` is empty. A worktree with
   any uncommitted, staged, or untracked change is NEVER removed.
2. **Older than the retention window** — default 7 days (`--days N` or
   `HQ_WORKTREE_GC_DAYS`). Age comes from the creation stamp
   (`workspace/worktrees/.gc-meta/<key>.json`, written by `worktree.sh`) when
   present, else the worktree directory mtime.
3. **Branch work preserved somewhere**:
   - *Pushable (github origin) repos* — the tip is reachable from origin
     (`origin/HEAD` → `origin/main` → `origin/master`) or the branch exists on
     origin at the same tip. Fetch is best-effort; a **failed fetch is treated
     as UNSAFE** and the worktree is skipped. Nothing is ever pushed.
   - *HQ-root local-only worktrees* (`.claude/worktrees/agent-*` and any
     `workspace/worktrees/` worktree whose repo IS the HQ root — HQ never
     pushes) — the branch is already merged into the HQ root's local `main`.
4. **Not in use** — no active session / thread / lock file references the
   worktree path, and it was not modified in the last 2 hours.

### Safety guarantees

Removal uses gentle git verbs only: `git -C <main-repo> worktree remove` (no
`rm -rf`, no `--force`), then `worktree prune`, then `branch -d` (never `-D`, so
git itself refuses to drop an unmerged branch). HQ-root-class removals carry the
`HQ_ALLOW_HQ_ROOT_GIT=1` escape hatch. A single worktree error is logged and
skipped — it never aborts the run.

### Cadence

`handoff-post.sh` runs `worktree-gc.sh --apply --gated` detached on every
`/handoff`; `--gated` caps real runs to once per 24h and never blocks handoff.

### Run it manually

```bash
# Safe classification — the default makes NO changes:
bash core/scripts/worktree-gc.sh --dry-run

# Machine-readable (examined / removed / reclaimed / skipped-by-reason):
bash core/scripts/worktree-gc.sh --dry-run --json

# Actually remove provably-safe stale worktrees:
bash core/scripts/worktree-gc.sh --apply

# Widen or tighten the retention window:
bash core/scripts/worktree-gc.sh --days 14 --apply
```
