---
id: hq-github
title: GitHub — always pass an explicit repo to gh
scope: global
when: git
on: [PreToolUse]
enforcement: hard
version: 2
created: 2026-04-29
updated: 2026-07-28
applies_to: [github]
public: true
vendor_public_ok: true
tags: [vendor:github, gate]
source: split-from-hq-github
---

## Rule

ALWAYS pass an explicit `-R {owner}/{repo}` (or `--repo`) to every resource-scoped `gh` command, and use a fully-qualified path for every `gh api repos/{owner}/{repo}/...` call. NEVER trust a bare `gh pr/run/issue/release/workflow <id>` when the working directory is HQ, a git worktree, or any repo other than the one the resource lives in — IDs are ambiguous across repos, and `gh` resolves them against the current repo's `origin`, so it will silently act on the wrong resource or return a misleading 404.

Even with `--repo`, verify the returned identity before acting on it: `gh pr view <N> --repo <owner>/<repo> --json number,headRefName,state,url` and confirm `headRefName`/`url` match what you expected. A same-numbered stale or merged PR in the right repo looks identical to the live one; the branch name is the cheapest disambiguator.

```bash
gh pr merge <N> --repo {owner}/{repo} --squash
gh run view <run-id> -R {owner}/{repo}
gh api repos/{owner}/{repo}/actions/runs/<id>
```

**Full GitHub reference** (review-thread resolution via GraphQL, commit-status slicing, archive-flag verification, GitHub App vs PAT, Tailwind lib distribution) is on-demand in `hq-github-reference` — it is not auto-injected. Read it before deep GitHub work, or `qmd get -c hq-infra hq-github-reference`.
