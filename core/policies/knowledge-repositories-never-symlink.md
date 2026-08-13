---
id: hq-knowledge-repositories-never-symlink
title: Knowledge repositories are real directories — never symlinks
when: knowledge && (repo || git || symlink)
on: [PreToolUse, PostToolUse, UserPromptSubmit, AssistantIntent]
enforcement: hard
version: 1
created: 2026-08-13
updated: 2026-08-13
source: user-correction
public: true
---

## Rule

Every knowledge **repository** must be a real directory at its canonical HQ
location: `core/knowledge/`, `personal/knowledge/`, or
`companies/{co}/knowledge/`. When knowledge needs independent version history,
initialize git inside the canonical `personal/knowledge/` or
`companies/{co}/knowledge/` directory — never inside `core/knowledge/`, which
`/update-hq` replaces wholesale and is reserved for release-shipped and
package-mounted content. Never create a repository under
`repos/` and symlink the knowledge path to it. `repos/` is for code repositories
only.

Treat an existing knowledge symlink to a separate git repository as an invalid
legacy layout. Tools may read it only long enough to determine whether it targets
a separate git repository and support a safe migration. `hq reindex` performs the
migration automatically: it pulls each legacy repo, materializes its content
(including git history, as an embedded repo) at the canonical path, and removes
the fully migrated legacy repo under `repos/`. Whether migrating automatically or
by hand, verify both `test -d PATH` and `! test -L PATH` before treating the
migration as complete.

Package-manager links from `core/knowledge/` into `core/packages/*/knowledge/`
are not knowledge repositories and remain supported. They expose immutable pack
content installed by `scan-packages`; they must not target `repos/` or a separate
git worktree.

## Rationale

HQ cloud sync records directory symlinks as small vault markers rather than
uploading the documents behind them, so teammates receive an empty or broken
knowledge base. Symlink resolution also changes across worktrees and machines.
Real canonical directories keep sync, search, git, and local tools aligned.
