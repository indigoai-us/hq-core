---
id: hq-git-log-shell-wrapper-hides-merges
title: Verify merges via plumbing (rev-parse + cat-file + reflog), never trust git log display
scope: global
trigger: verifying whether a merge commit landed on a branch or trying to confirm merge history
enforcement: hard
public: true
version: 2
created: 2026-04-24
updated: 2026-04-28
source: session-learning
---

## Rule

Two distinct `git log` failure modes can hide merge commits from display. NEITHER `git log --oneline` NOR `git log --graph` is a reliable source of truth for "did the merge land."

**Failure mode 1 — wrapper filter.** The HQ shell wrapper for `git log` (and common zsh/ohmyzsh git aliases) filters merge commits out of the default display. Running `git log --oneline -20` and seeing only regular commits does NOT prove that a merge commit did not land — the merge may exist on HEAD but be hidden from the wrapper's output.

**Failure mode 2 — graph rendering.** `git log --graph` can omit merge commits when topology spans multiple branches with shared decorations. The graph layout heuristic suppresses certain merge nodes whose parents both reduce to already-displayed lineage, producing a tree that looks linear even when a merge exists on HEAD. Observed during a 2026-04-28 merge where `--graph` rendered the post-merge history without the merge commit, while `rev-parse HEAD` and `git reflog` both confirmed the merge landed cleanly.

**Always use plumbing-level probes for verification:**

```bash
# 1. Source-of-truth: HEAD ref state
git rev-parse HEAD                    # current commit SHA
git rev-parse HEAD^1 HEAD^2 2>/dev/null  # both parents — succeeds only if HEAD is a merge

# 2. Cross-check via reflog (records every ref movement, never filtered)
git reflog -10                        # see "merge: ..." entries

# 3. Inspect the commit object directly
git cat-file -p HEAD | head -5
# Look for:
#   tree <sha>
#   parent <sha>       ← first parent
#   parent <sha>       ← second parent (merge indicator)
#   author ...
```

Or bypass the wrapper via explicit `--no-abbrev-commit --pretty=raw`:

```bash
git log -1 --pretty=raw HEAD     # raw output, always shows parent lines
git log --merges -5              # merges only, bypasses default filter
```

NEVER conclude "the merge didn't land" from `git log --oneline` OR `git log --graph` alone. Both display layers (wrapper filter, graph layout) can lie. `git rev-parse HEAD` plus `git reflog` are the source of truth for ref state.

## Rationale

Many zsh configurations (oh-my-zsh `git` plugin, custom aliases in `~/.zshrc`, HQ's own wrapper scripts) alias `git log` to `git log --no-merges` or apply a format filter that elides merge commits. This is intentional ergonomics for reviewing feature work — merges add noise to linear history — but it silently breaks verification logic that assumes `git log` shows all commits.

`git log --graph` has a separate failure mode: its rendering algorithm prioritizes display compactness over completeness. When a merge commit's parents both flow into already-displayed lineage with shared ref decorations, the graph can collapse the merge node out of view. The merge still exists on HEAD; the display just doesn't draw it.

`git rev-parse HEAD && git cat-file -p HEAD` uses plumbing commands that have no ergonomic alias surface and are guaranteed to show the raw commit object. The presence of two `parent` lines is the unambiguous proof of a merge; no wrapper or graph-rendering heuristic can hide them. `git reflog` independently records every ref movement (commit, merge, reset, checkout) and is also immune to display filtering.
