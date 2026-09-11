# hq-core: public
# Grok: repos/ edits go through worktrees

Grok-only. Do not weaken the repos/ deny.

Direct writes under `repos/` are blocked (`direct edits inside repos/ are
not allowed`). That guard stays.

For repo coding: `/worktree` (or `workspace/worktrees/<name>`) first, then
edit inside the worktree. Do not patch `repos/public/` or `repos/private/`
in the main checkout.
