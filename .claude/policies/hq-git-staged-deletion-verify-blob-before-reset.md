---
id: hq-git-staged-deletion-verify-blob-before-reset
title: Verify on-disk blob hash matches HEAD before resetting a staged-deletion-plus-untracked file
scope: global
trigger: git status shows `D <path>` (staged deletion) AND `?? <path>` (untracked) for the same file
enforcement: hard
tier: 1
public: true
version: 1
created: 2026-04-22
updated: 2026-04-22
source: session-learning
---

## Rule

When `git status` shows the confusing pair:

```
D  src/index.ts          # staged deletion
?? src/index.ts          # same path, now untracked
```

DO NOT reach for `git checkout HEAD -- <path>` or `git reset --hard`. Both are destructive in this state — the first overwrites the working-tree copy, the second discards every other staged change.

Instead, verify whether the on-disk blob still matches HEAD:

```bash
# Blob hash at HEAD
git ls-tree HEAD -- src/index.ts | awk '{print $3}'

# Blob hash of the current on-disk file
git hash-object src/index.ts
```

- **Hashes match** → someone ran `git rm --cached <path>`. The file is unchanged on disk; only the index entry was dropped. Fix is non-destructive:

  ```bash
  git reset HEAD -- src/index.ts
  ```

  This re-adds the file to the index pointing at the existing HEAD blob, and `?? src/index.ts` disappears.

- **Hashes differ** → the file was truly modified or rewritten. Only then consider `git checkout` or merging manually, with the knowledge that the on-disk content will change.

Running `git reset HEAD -- <path>` when hashes match is idempotent and loses zero work.

## Rationale

The `D` + `??` pair is almost always produced by `git rm --cached`, a command that sounds like "uncache the change" but actually stages a deletion while leaving the file on disk. Confronted with it, the instinct is `git checkout HEAD -- <path>` — which, in a messy working tree, silently overwrites in-progress edits. Comparing blob hashes takes two commands and distinguishes "index is confused" from "file is genuinely different" before any destructive git operation runs. This is the same principle as the `git-checkout-not-a-probe` policy: verify state before invoking an operation that writes.
