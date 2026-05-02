---
id: hq-always-pr-shared-state-repos
title: Always use a PR for shared-state repos — never push directly to main
scope: global
trigger: Before `git push` or `gh pr merge` targeting a shared-state branch (main, master, staging, production) on any repo under `repos/{public,private}/` or a company-scoped repo
enforcement: hard
tier: 1
public: true
version: 1
created: 2026-04-24
updated: 2026-04-24
source: user-correction
---

## Rule

Never push commits directly to `main` (or any shared-state branch: `master`, `staging`, `production`, `release/*`) on ANY repo. Always:

1. Create a feature branch (`fix/...`, `feat/...`, `chore/...`).
2. Push the branch to origin.
3. Open a PR via `gh pr create --base main --head {branch}`.
4. Wait for CI + review before merging.

This rule applies **regardless of what `git log` shows**: the presence of prior direct-to-main commits in a repo's history is not evidence of a standing policy allowing direct pushes. Different committers made different choices; the default for AI agents is always-PR.

### Exceptions (narrow, explicit)

Direct pushes to `main` are allowed ONLY when the user explicitly authorizes the specific push in the current turn. Examples of valid authorization:

- "Push directly to main, skip the PR."
- "This is a trivial typo, just push it."
- "You can push straight to main for this one."

**NOT valid authorization:**

- A general "fix it" or "ship it" instruction (even urgent ones).
- Observing that prior commits went to main directly.
- Repos owned by the user personally.
- Small diffs or "obviously correct" fixes.
- Time pressure.

When in doubt, open a PR. The cost of an extra PR is ~10 seconds; the cost of an unreviewed regression on main can be hours.

### Recovery from accidental direct push

If a direct push lands on main before this rule is checked:

1. Acknowledge the mistake to the user immediately.
2. Create a feature branch at the pushed commit: `git branch fix/... <sha>; git push -u origin fix/...`
3. Revert the commit on main: `git revert <sha>; git push origin main`
4. Rebase/cherry-pick the fix onto the feature branch so it's ahead of main again (plain rebase will drop the commit since it's already in main's ancestry — use `git cherry-pick` instead).
5. Open a PR from the feature branch.

## Rationale

An agent pushed a commit directly to a shared-state repo's main branch after observing that prior commits from the human owner had gone direct-to-main. The agent treated that history as permission — it wasn't. Prior direct pushes were the human owner's judgment call; the agent's default is stricter.

Recovery required a revert + retroactive PR, creating a transient window where repo `main` HEAD disagreed with the deployed artifact. Even though the deployment was serving correct code throughout, the repo briefly documented the inverse — a confusing state that never should have been created.

The `Executing actions with care` section of CLAUDE.md already covers this at a high level ("Actions visible to others or that affect shared state ... confirm first"). This policy is the concrete, enforceable form for git operations specifically.
