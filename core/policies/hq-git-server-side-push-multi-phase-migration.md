---
id: hq-git-server-side-push-multi-phase-migration
title: Use server-side fast-forward push for multi-phase migrations on a dirty working tree
scope: global
trigger: multi-phase migration commits, branch promotion to main, working tree contains unrelated dirty files
enforcement: soft
public: true
version: 1
created: 2026-04-24
updated: 2026-04-24
source: session-learning
---

## Rule

For multi-phase migration runs that touch a working tree with concurrent unrelated dirty files (other companies, other features, sibling worktrees), promote the feature branch to `main` via server-side fast-forward push:

```bash
# From the feature branch with dirty siblings present
git push origin feature/<name>:main
git update-ref refs/heads/main feature/<name>
```

Do NOT use the local-checkout pattern (`git checkout main && git merge feature/<name>`). The checkout step shuffles every tracked file, which fails (or silently skips) when sibling dirty files would be overwritten.

## Rationale

The HQ working tree carried unrelated dirty files across multiple companies (orchestrator state, scheduled-task lockfiles, sibling thread JSONs). `git checkout main` would have either failed the checkout or required a temporary stash dance that risks losing the in-progress state. Server-side push moved the `main` ref forward without touching any working-tree file, then a local `update-ref` resync'd the local `main` pointer. Zero working-tree perturbation, full ancestry preserved.
