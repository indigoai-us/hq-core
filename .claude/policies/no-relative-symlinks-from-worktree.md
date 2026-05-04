---
id: no-relative-symlinks-from-worktree
enforcement: hard
scope: global
tags: [git, worktree, symlinks, knowledge-repos]
public: true
created: 2026-04-16
provenance: user-correction
---

## Rule

NEVER use relative symlinks to access pattern-2 knowledge repos from a git worktree. `../../repos/` resolves against the worktree root, not the HQ root. Use the canonical absolute path (`$HOME/Documents/HQ/repos/public/knowledge-{name}/`).

## Rationale

Git worktrees give each branch its own working tree directory, which means relative paths anchored at HQ root silently break when accessed from a worktree. Absolute paths via `$HOME/Documents/HQ/...` resolve correctly from any worktree and from the main checkout.
