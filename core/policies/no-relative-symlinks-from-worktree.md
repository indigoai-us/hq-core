---
id: no-relative-symlinks-from-worktree
enforcement: hard
public: true
tier: 1
scope: global
tags: [git, worktree, symlinks, knowledge-repos]
created: 2026-04-16
provenance: user-correction
---

## Rule

Never use relative symlinks (e.g. `../../repos/`) for pattern-2 knowledge repos accessed from a git worktree — they resolve against the worktree root, not HQ root. Use absolute paths: `$HOME/Documents/HQ/repos/public/knowledge-{name}/`.
