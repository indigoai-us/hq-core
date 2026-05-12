---
id: hq-git-stash-for-focused-pr-with-wip
title: Use git stash push -u to land focused PRs while uncommitted WIP exists
scope: global
trigger: Need to land a single-concern PR (one bug fix, one infra file, one policy) while the working tree carries uncommitted WIP from unrelated work
enforcement: hard
tier: 1
public: true
version: 2
created: 2026-04-25
updated: 2026-04-29
source: session-learning
---

## Rule

ALWAYS use `git stash push -u -m "<label>"` to capture both modified AND untracked files when you need to land a focused PR while uncommitted WIP exists in the working tree. Then:

1. `git stash push -u -m "wip-<context>"` — captures everything
2. Branch from the now-clean tree, make the targeted edit, commit, push, open the PR
3. `git checkout <previous-branch>` (or stay on the new branch if appropriate)
4. `git stash pop` — restores the WIP intact

**Path-scoped variant (single-file WIP):** when the WIP is a single in-progress file edit (no untracked siblings to capture), use `git stash push -m "wip-<context>" -- <path>` to stash only that path. The narrower capture is faster to reason about and avoids stashing unrelated tracked-file edits that should stay in place. Pop with `git stash pop` after the focused PR is pushed.

Do NOT bundle unrelated WIP into a "fix the test suite" / "while I'm in here" PR. A focused PR's diff must contain exactly the change its title describes — even when the WIP touches adjacent files in the same directory.

## Rationale

Bundling unrelated work into a focused PR breaks two contracts:

1. **Reviewability.** A PR titled "fix jsdom Storage regression" should diff exactly the test setup file. If the diff also touches three component tests, four mock exports, and a CSS class rename, reviewers cannot tell which lines fix the regression and which lines are drift cleanup. The signal-to-noise ratio collapses, review quality drops, and bisect later loses precision when the bundled change is implicated in a new bug.

2. **Revert safety.** A focused commit can be reverted cleanly if it regresses. A bundled commit forces the team to either revert unrelated improvements alongside the bad fix or hand-craft a partial revert — both expensive.

`git stash push -u` is the right tool because the `-u` flag is the difference between "saved my modified files" and "saved my entire working state." Untracked files (new test fixtures, scratch scripts, generated artifacts) are silently lost without `-u` and frequently represent hours of un-replayable work. A labeled stash entry (`-m`) makes the recovery step unambiguous when multiple stashes accumulate.
