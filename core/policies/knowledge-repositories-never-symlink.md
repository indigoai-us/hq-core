---
id: hq-knowledge-repositories-never-symlink
title: Knowledge directories use canonical paths and never symlinks
when: knowledge && (repo || git || symlink)
on: [PreToolUse, PostToolUse, UserPromptSubmit, AssistantIntent]
enforcement: hard
version: 2
created: 2026-08-13
updated: 2026-09-28
source: user-correction
public: true
---

## Rule

Every knowledge directory must be a real directory at its canonical HQ location.
Company knowledge at `companies/{co}/knowledge/` is always a plain directory
with no Git metadata; company folders sync through the tenant vault. Personal
knowledge under `personal/knowledge/` may use embedded Git when independent
version history is needed. Core knowledge is governed by the HQ root repository
and may use package-managed links from `core/packages/*/knowledge/`. Never
create a repository under `repos/` and symlink the knowledge path to it.
`repos/` is for code repositories only.

Treat an existing knowledge symlink to a separate git repository as an invalid
legacy layout. Tools may read it only long enough to identify the target and
report the migration issue. Personal knowledge symlinks may use the supported
personal migration flow. Company knowledge symlinks must be materialized
manually as plain real directories after preserving any needed files and Git
history outside the company folder. Verify both `test -d PATH` and
`! test -L PATH` before treating the migration as complete.

Package-manager links from `core/knowledge/` into `core/packages/*/knowledge/`
are not knowledge repositories and remain supported. They expose immutable pack
content installed by `scan-packages`; they must not target `repos/` or a separate
git worktree.

## Rationale

HQ cloud sync records directory symlinks as small vault markers rather than
uploading the documents behind them, so teammates receive an empty or broken
knowledge base. Symlink resolution also changes across worktrees and machines.
Real canonical directories keep sync, search, and local tools aligned. Plain
company knowledge directories prevent repository metadata from syncing to every
member's device.
