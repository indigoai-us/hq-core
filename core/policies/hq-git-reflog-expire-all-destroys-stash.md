---
id: hq-git-reflog-expire-all-destroys-stash
title: Preserve at-risk WIP before git reflog expire --all or git gc --prune=now
scope: global
trigger: any session about to run `git reflog expire --all`, `git gc --prune=now`, `git gc --aggressive`, or any operation that drops dangling/unreachable objects
enforcement: hard
tier: 1
public: true
version: 1
created: 2026-04-26
updated: 2026-04-26
source: session-learning
---

## Rule

ALWAYS preserve at-risk WIP before any reflog expiration or garbage collection that drops unreachable objects. Specifically:

1. Before `git reflog expire --all --expire=now` (or any `--all` variant), promote every stash entry you care about to a real ref:
   ```bash
   # Promote each stash to a branch
   git stash list | awk -F: '{print $1}' | while read s; do
     git stash branch "rescue/${s//[\/]/-}" "$s" || true
   done
   # Or commit WIP to a dedicated branch
   git checkout -b rescue/wip-$(date +%s) && git add -A && git commit -m "WIP rescue"
   ```
2. Prefer scoping reflog expiration to specific refs instead of `--all`:
   ```bash
   git reflog expire --expire=now HEAD          # only HEAD's reflog
   git reflog expire --expire=now refs/heads/main  # only main
   ```
3. NEVER chain `git reflog expire --all` with `git gc --prune=now` without first verifying every stash has a corresponding branch (`git branch --list 'rescue/*'`) or commit on a tracked ref.

## Rationale

`git reflog expire --all` expires the reflog for *every* ref — including the synthetic `refs/stash`. Once the stash reflog is gone, `git stash list` returns empty and the underlying stash commits become unreachable. A subsequent `git gc --prune=now` deletes the unreachable objects, silently destroying uncommitted work that the user thought was safely stashed.

The `--all` flag's blast radius is non-obvious: stash entries look like a separate data structure in the porcelain UI (`git stash list`, `git stash pop`), but plumbing-wise they are just reflog entries on `refs/stash`. The same `--all` that "cleans up old branch reflogs" also wipes the stash reflog with no warning prompt.

Scoping expiration to specific refs (`HEAD`, `refs/heads/<branch>`) preserves the stash reflog and avoids the destruction path. Promoting stashes to branches before expiring converts the at-risk reflog entries into reachable refs that survive any reflog/gc cycle.
