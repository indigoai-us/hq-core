---
id: hq-git-large-diff-audit-before-panic
title: Audit diff composition before panicking over large file counts
when: git && commit
on: [AssistantIntent, PreToolUse]
enforcement: soft
public: true
version: 2
created: 2026-04-18
updated: 2026-04-29
source: session-learning
---

## Rule

ALWAYS decompose a suspiciously-large diff by change type before assuming the release is out of control. Run:

```bash
git diff --name-status {base}..{head} | awk '{print $1}' | sort | uniq -c
```

Output shape:

```
  423 A
  156 D
   38 M
  892 R100
   12 R095
```

Interpret before reacting:

| Code | Meaning | Usually |
|------|---------|---------|
| `R100` | Pure rename (100% similarity) | Bulk — noise, not signal |
| `R0xx` | Partial rename (some edits) | Count as modifications |
| `A` | Added file | Substantive — review |
| `D` | Deleted file | Substantive — review (or expected allowlist prune) |
| `M` | Modified in place | Substantive — review |

**Rule of thumb:** in a 1000-file diff, substantive change (A + M + partial-renames) is usually 5–10× smaller than total. A release that looks like "1,421 files changed" often decomposes to ~150 real changes plus ~900 renames plus ~370 allowlist-filter deletes.

Report the breakdown to the user before claiming the release is too noisy to merge or before trying to narrow scope.

## Rationale

Raw file counts from `git diff --stat` or the GitHub PR UI conflate renames, deletes, and edits into a single "files changed" number. In repos that undergo tree reshuffles (e.g. allowlist pivots, folder reorganizations, scaffold rebuilds), pure renames can dominate the count while the actual edit surface is small.

A prior HQ publish run produced a release commit with 1,421 changed files. Initial instinct was to narrow scope and split into smaller releases. The `--name-status` decomposition showed ~900 were `R100` renames (folder reorganization) and ~370 were `D` (allowlist pivot pruning owner-private dirs that had previously leaked in). The substantive edits (A + M) totaled ~150 files — a reasonable review surface for a minor-version release.

The audit takes <1s and prevents two expensive failure modes: (1) unnecessary scope narrowing that creates multi-commit drift, and (2) panicked reviewers blocking a release that is actually well-scoped. It also catches the opposite case — a "small" 30-file diff where 25 are `M` with deep semantic changes is *more* review-worthy than a 1000-file diff that's 90% renames.
