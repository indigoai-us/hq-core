---
id: hq-check-dirty-tree-before-repo-edit
title: Check working tree for uncommitted changes before editing repo source
when: repo
on: [SessionStart]
enforcement: soft
public: true
version: 1
created: 2026-05-28
updated: 2026-05-28
source: session-learning
---

## Rule

ALWAYS: before editing a repo's source files, check the working tree for uncommitted changes (git status --short) — they may belong to a concurrent session. A dirty tree on the same branch + files you're about to touch = collision risk; coordinate or use an isolated worktree instead of overwriting.

## Rationale

Multiple concurrent Claude/Codex sessions can share the same repo working tree. Uncommitted edits in the tree are not necessarily yours — they may be in-flight work from a sibling session. Overwriting them silently destroys the other session's work and is invisible until that session tries to commit and finds its changes gone. Running `git status --short` as a pre-edit check surfaces the collision; if the dirty files overlap with the planned edits, the safe response is to coordinate (pause, ask, or hand off) or branch into an isolated worktree rather than write blind.
