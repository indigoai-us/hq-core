---
id: hq-reference-files-with-full-path
title: Reference Files with Full Paths
when: always
on: [SessionStart]
enforcement: soft
version: 1
created: 2026-07-16
source: feedback_d34764fe-737c-42f2-868a-8174841c9fbe
public: true
tier: 1
---

## Rule

When referencing a file in a session, always write its full path from the HQ root or use an absolute path. For example, use `repos/private/outpost/app/schema.sql` or the absolute worktree path, never a bare repo-relative path such as `app/schema.sql`.

Clickable file links resolve against the HQ root. Relative paths from inside a worktree or symlinked repo fail to open.

## Rationale

A session can operate inside a git worktree or a repo reached through a symlink while clickable links still resolve from the HQ root. A bare repo-relative path therefore points at a different location than the file the session used. A full HQ-root or absolute path removes that resolution mismatch and keeps file references clickable.
