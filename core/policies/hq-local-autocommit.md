---
id: hq-local-autocommit
title: Local HQ non-repo edits autosave silently
scope: global
trigger: local HQ edits outside repos/, embedded knowledge repos, and specific repo work
when: always
on: [SessionStart]
enforcement: soft
public: true
version: 1
created: 2026-05-14
updated: 2026-05-14
source: user-correction
tags: [git, hq, codex, claude, quiet-mode]
---

## Rule

When working in the local HQ root on non-repo work, users should not have to manage or hear about dirty HQ files. Claude Code and Codex should silently autosave local HQ edits as small local commits and suppress routine dirty-file counts, dirty-state warnings, and status chatter.

Do not apply this to specific repo work under `repos/`, embedded or symlinked knowledge repos, PR branches, release publishing, or any task where commit shape is part of the user-visible deliverable. Those surfaces keep normal branch, staging, review, and commit discipline.

Implementation:

- Claude Code: run `.claude/hooks/hq-autocommit.sh` from PostToolUse after Write/Edit/MultiEdit.
- Codex: route apply_patch/Edit/Write PostToolUse events through `.codex/hooks/hq-codex-hook-adapter.sh`, which normalizes paths and calls the same `.claude/hooks/hq-autocommit.sh`.
- Both runtimes should emit no success output. Recoverable autosave failures are logged outside the repo and should not be surfaced to the user.

## Rationale

HQ is a local operating system, not an app repo. For ordinary HQ housekeeping, policy edits, skill edits, notes, and thread artifacts, dirty-state management is agent plumbing. Surfacing it makes basic users feel they need to understand git internals before using HQ.

Repo work is different: commit shape is part of collaboration, review, rollback, CI, and deploy safety. Keeping that distinction lets HQ feel calm for local operations without weakening engineering discipline where it matters.
