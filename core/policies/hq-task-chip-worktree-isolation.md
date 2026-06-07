---
id: hq-task-chip-worktree-isolation
title: Never spawn task chips that do git ops in a shared worktree
scope: global
trigger: spawning Task tool chips that will run git commands while the parent session (or a sibling chip) is actively using the same worktree
when: git
on: [PreToolUse]
enforcement: soft
tier: 1
public: true
version: 1
created: 2026-04-21
updated: 2026-04-21
source: session-learning
---

## Rule

NEVER spawn a Task tool chip that performs git operations in the same worktree another agent or session is actively using. Two chips in one worktree silently swap branches under each other, lose uncommitted edits, and produce orphan commits on stale branches.

If parallel work genuinely requires git operations, spawn each chip with `isolation: "worktree"` so the Task tool provisions a dedicated temporary worktree per chip:

```jsonc
// Correct — each chip gets its own worktree
{ "subagent_type": "general-purpose", "isolation": "worktree", "prompt": "..." }
```

Alternatives when isolation isn't an option:

- Run chips **sequentially** (no concurrent git activity in the shared worktree)
- Keep chip work **read-only** (Read/Grep/Glob/`git status`) — never Edit/Write/`git checkout`/`git commit` concurrently
- Use the detached-HEAD + push-refspec pattern (`hq-git-discipline.md` rule 10) as a safety net when concurrent git is unavoidable

## Rationale

The Task tool by default runs chips in the parent's working directory. Git's working-tree state (HEAD pointer, index, untracked files) is a single-writer resource — two agents interleaving `git checkout`, `git add`, `git stash`, and `git commit` silently corrupt each other's state. Observed failure modes:

1. Chip A checks out `feature-x`, chip B checks out `main`, chip A commits → commit lands on `main`.
2. Chip A stashes, chip B stashes, both pop — stashes interleave and partial work is lost.
3. Parent commits while a chip is mid-edit → the chip's untracked changes get swept into the commit (or conversely, stranded).

`isolation: "worktree"` routes each chip into a temporary `git worktree add` directory that's cleaned up on exit if the chip made no changes. This makes chip-local git state independent from the parent's and from siblings', which is the only safe model for concurrent git work. See also `hq-git-discipline.md` rule 10 for the defense-in-depth push pattern.
