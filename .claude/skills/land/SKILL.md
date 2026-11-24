---
name: land
description: "Land a PR: watch CI, resolve review issues, merge, verify production. Triggers: \"land this\", \"merge and monitor\"."
allowed-tools: Bash, Read, Grep, Glob, Write, Edit, Agent, AskUserQuestion
---

# Land

**Monitor CI → Resolve reviews → Merge → Monitor production.**

This skill takes a PR from "open" to "merged and verified in production." It handles the full landing sequence, including CI polling, review resolution, merge strategy selection, and post-merge production verification.

## Input

Accepts one of:
- **PR number** (e.g. `3021`) — looks up repo from cwd or context
- **PR URL** (e.g. `https://github.com/org/repo/pull/3021`)
- **No argument** — finds the open PR for the current branch

## Step 0: Resolve PR

```bash
# If no PR number/URL given:
branch=$(git branch --show-current)
gh pr list --head "$branch" --json number,url --jq '.[0]'

# Resolve exact head SHA, draft/mergeable state, and repo auto-merge support:
gh pr view {pr_number} -R {repo} --json number,title,headRefName,baseRefName,headRefOid,isDraft,mergeable,reviewDecision
gh api repos/{repo} --jq '{allow_auto_merge, delete_branch_on_merge}'
```

Extract: `repo`, `pr_number`, `branch`, `base_branch`, `head_sha`, `allow_auto_merge`. Anchor every `gh` call with `-R {repo}`.

Display:
```
Landing PR #{number}: {title}
Branch: {branch} → {base} (head {head_sha[:8]})
```

## Step 1: Resolve Reviews Before or Alongside CI

Check reviews and review threads immediately so a clean PR never waits past green CI:

```bash
gh pr view {pr_number} -R {repo} --json reviews,comments,reviewRequests,reviewThreads
```

**Outcomes:**
- Independent review clean (0 unresolved CRITICAL findings, no changes requested, all review threads resolved) → proceed to Step 2
- Review comments exist → read each comment, assess if actionable:
  - Bot/automated suggestions: evaluate and apply if valid, push fix, update `head_sha`
  - Human comments: summarize for user, ask for guidance
  - Approved with no blocking comments → proceed
- Changes requested → summarize feedback, attempt fixes if code-related, push, re-request review, update `head_sha`

## Step 2: Arm Auto-Merge or Watch CI

Never busy-wait in a foreground poll loop with a short timeout (a 10-minute foreground cap drops PRs whose CI takes longer).

Check policy gates before arming or merging:
- **Standing clean-low-risk rule**: a PR with 0 CRITICAL findings, LOW merge-effect risk, no hold, and green required checks does not need an extra confirmation prompt.
- **Explicit go required**: MEDIUM or HIGH risk, unresolved CRITICALs, holds, releases/publishes, or deploy-freeze windows.
- **Production-on-merge deploy spacing**: for repos that auto-deploy on merge to main, verify the previous production deploy is not failing, and respect any repo-specific deploy serialization or spacing rule before arming or merging.

### Path A: GitHub Auto-Merge (preferred when `allow_auto_merge: true`)

If the PR is ready (not draft), reviews and policy gates are satisfied, and the ruleset's approval requirement is already met (either `required_approving_review_count: 0` or a valid non-author approval is on the PR):

```bash
gh pr merge {pr_number} -R {repo} --auto --squash --delete-branch --match-head-commit {head_sha}
```

Use `--merge` instead of `--squash` only if the user requested it or the repo preserves branch commit history.

Verify auto-merge is armed, then wait in the background (or monitor `gh pr checks {pr_number} -R {repo} --watch`) until state is `MERGED` or a check fails:
- If any required check fails → inspect logs (`gh run view {run_id} -R {repo} --log-failed`), fix at root cause, push, re-review if needed, and re-arm on the new `head_sha`.

### Path B: Background CI Watch + Direct Merge (when `--auto` cannot fire)

Use this path only when `allow_auto_merge` is `false`, or when a ruleset requires a review approval that is satisfied via an authorized bypass (GitHub auto-merge does not invoke ruleset bypass actors):

1. Watch checks in the background (never a 10-minute foreground sleep loop):
   ```bash
   gh pr checks {pr_number} -R {repo} --watch
   ```
2. Once every required check is green on `{head_sha}`, merge pinned to that exact commit:
   ```bash
   gh pr merge {pr_number} -R {repo} --squash --delete-branch --match-head-commit {head_sha}
   ```
   Add `--admin` only when the user has authorized admin bypass and **only** for a review-only gate — never to bypass failing or pending required checks.

## Step 3: Verify Merge

```bash
gh pr view {pr_number} -R {repo} --json state,mergedAt,mergeCommit
```

## Step 4: Monitor Production

Post-merge verification. This step is context-dependent — the skill adapts based on what was changed.

### 4a: Identify what to monitor

From the PR diff, determine:
- **Lambda/serverless changes** → check if SST deployment is needed (code on main ≠ deployed)
- **Database changes** → query for expected state changes
- **API changes** → test endpoints
- **Frontend changes** → check deployment status (Vercel, etc.)

### 4b: Execute monitoring

**For Lambda changes ({PRODUCT} pattern):**
- Note: merging to main does NOT auto-deploy Lambda. SST deployment is separate
- Query DB for expected state changes (e.g. stale messages expiring)
- Check CloudWatch logs if accessible
- Report: "Code is on main. Lambda redeploy needed for changes to take effect"

**For deployed services (Vercel, etc.):**
- Check deployment status: `vercel ls --scope {team}` or GitHub deployment status
- Verify the deployment completed
- If accessible, hit a health endpoint or verify the change visually

**For database/data fixes:**
- Run verification queries to confirm expected state
- Compare against baseline captured before merge

### 4c: Report

```
Landing Complete
────────────────
PR: #{number} merged → {merge_commit[:8]}
CI: All {N} checks passed
Reviews: {resolved|none}
Merge: squash → {base_branch}
Production: {status}
  - {monitoring_detail_1}
  - {monitoring_detail_2}
```

If production verification reveals issues, flag immediately and offer to investigate.

## Error Handling

- **CI flake**: If a check fails but the failure looks transient (network timeout, flaky test), offer to re-run: `gh run rerun {run_id} --repo {repo} --failed`
- **Merge conflict**: `gh pr view` shows mergeable state. If conflicted, report to user — don't attempt auto-resolution
- **Rate limiting**: If `gh` commands hit rate limits, back off and retry with increasing intervals

## Rules

- Never force-push during landing — the PR branch is shared state
- Always pin merges with `--match-head-commit {head_sha}` and explicit `-R {repo}` so unreviewed pushes cannot merge
- Prefer `gh pr merge --auto` over foreground polling whenever repo rulesets and deploy spacing permit
- Never skip or bypass failing required CI checks without explicit user approval
- Always verify merge succeeded before reporting completion
- If production monitoring reveals a regression, prioritize flagging over completing the skill
- Respect repo-specific merge, review, and deploy-spacing policies
