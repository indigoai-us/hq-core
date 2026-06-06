---
id: hq-git-divergence-check-both-directions
title: Check git branch divergence in both directions before acting
scope: global
trigger: Before any action that depends on understanding how two git refs have diverged (merge, rebase, force-push decision, "are we ahead/behind" status check)
when: git && ( rebase || merge || push || pull )
on: [PreToolUse]
enforcement: soft
public: true
version: 1
created: 2026-04-19
updated: 2026-04-19
source: session-learning
---

## Rule

NEVER treat `git log A..B` one-sided output as the complete divergence picture. Always check both directions, or use the symmetric form explicitly.

Correct patterns:

```bash
# Symmetric ahead/behind counts (preferred — single call, unambiguous output)
git rev-list --left-right --count origin/main...main
# Output: "<behind>\t<ahead>"  — e.g. "6\t3" means origin/main has 6 commits local doesn't, local has 3 commits origin doesn't

# OR explicit both-direction inspection
git log origin/main..main       # commits local has that origin doesn't (ahead)
git log main..origin/main       # commits origin has that local doesn't (behind)

# NOT sufficient on its own:
git log origin/main..main       # only tells you "ahead" — says nothing about "behind"
```

A branch can be diverged (commits in both directions). A single-sided `A..B` reports only one side of that divergence, which is a partial answer. Decisions like "is it safe to fast-forward?", "should I force-push?", "do I need to merge or pull first?" require the symmetric view.

If reporting status to the user or writing to handoff/thread state, always state BOTH numbers: "N ahead, M behind" — never just "N ahead." "Ahead" alone implies "behind = 0" to readers and leads to incorrect next-step decisions.

Composes with `hq-no-force-push-diverged-release-branch.md` (which requires counting ahead/behind before force-push) and `hq-pull-before-work.md` (which mandates pulling before work starts). This rule tightens the *methodology* for producing those counts.

## Rationale

Observed 2026-04-19 during a release-branch divergence investigation. An earlier session reported "local is 3 commits ahead of origin/release/v11.1.1" based on `git log origin/release/v11.1.1..release/v11.1.1`. The one-sided view hid the fact that origin had 6 commits local didn't have — the branch was diverged, not simply ahead. Acting on "3 ahead" would have pointed toward a clean force-push; the reality required a merge or cherry-pick to preserve origin's 6 commits.

`git rev-list --left-right --count A...B` (three dots, symmetric) produces both numbers in a single call with unambiguous tab-separated output. It's the canonical answer to "how diverged are these refs?" and should be the default for any divergence question.

The deeper principle: "N commits ahead" is only meaningful relative to a specific base. Without the "behind" count, readers (human and AI) fill in "behind = 0" and make wrong decisions. Always produce the symmetric view and always report both numbers.
