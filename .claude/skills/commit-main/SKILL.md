---
name: commit-main
description: Commit every dirty file in the current repo, only when on main.
allowed-tools: Bash(git:*), Bash(date:*), Read
---

# Commit Dirty Main State

Codex adapter for `/commit-main`.

**Arguments:** `<commit message>`

## Source Of Truth

Read `.claude/commands/commit-main.md` first. That slash command owns the workflow, branch guard, staging behavior, and completion report.

## Codex Adaptation

Execute the command workflow inline from the current repository.

- Treat the user's arguments as the commit message.
- If the message is missing, ask the user for a commit message before staging anything.
- Verify `git branch --show-current` returns exactly `main` before staging.
- Use `git status --short` to detect whether there are changes to commit.
- Use `git add -A` because the command's purpose is to commit every dirty path, including deletions and untracked files.
- Commit with `git commit -m "<commit message>"`.
- End with the new commit hash and remaining dirty-file count.

## Completion

Report whether a commit was created. If the command stopped because the branch was not `main`, no commit message was provided, or the repo was already clean, say that directly.
