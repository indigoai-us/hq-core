---
name: land
description: |
  Land a PR: monitor CI, resolve review issues, merge, monitor production.
  Use when asked to "land this", "merge and monitor", "ship this PR", or after PR creation when next step is merge + prod verification.
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

```
If no PR number/URL given:
  branch=$(git branch --show-current)
  gh pr list --head "$branch" --json number,url --jq '.[0]'
```

Extract: `repo`, `pr_number`, `branch`, `base_branch`.

Display:
```
Landing PR #{number}: {title}
Branch: {branch} → {base}
```

## Step 1: Monitor CI

Poll CI checks every 30s (max 10 minutes):

```bash
gh pr checks {pr_number} --repo {repo}
```

**Outcomes:**
- All pass → proceed to Step 2
- Any fail → read the failing check's logs, diagnose, and attempt fix. Push fix, re-poll
- Timeout (10min) → report status and ask user whether to continue waiting or merge anyway

Display check status on each poll (only changed states).

## Step 2: Resolve Reviews

```bash
gh pr view {pr_number} --repo {repo} --json reviews,comments,reviewRequests
```

**Outcomes:**
- No reviews/comments, no review requests → proceed to Step 3
- Pending review requests → notify user, ask whether to wait or proceed
- Review comments exist → read each comment, assess if actionable:
  - Codex/bot suggestions: evaluate and apply if valid, push fix
  - Human comments: summarize for user, ask for guidance
  - Approved with no blocking comments → proceed
- Changes requested → summarize feedback, attempt fixes if code-related, push, re-request review

After resolving, re-check CI (fixes may have broken something).

## Step 3: Merge

Determine merge strategy:
- Default: `--squash` (clean single commit)
- If branch has meaningful commit history user wants preserved: `--merge`
- If user specified: use their preference

```bash
gh pr merge {pr_number} --repo {repo} --squash --delete-branch
```

**If branch protection blocks merge:**
- Check if `--admin` is available (user has admin rights)
- If yes: use `--admin` flag
- If no: report the blocking requirement and ask user

Verify merge:
```bash
gh pr view {pr_number} --repo {repo} --json state,mergedAt,mergeCommit
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
- Never skip CI checks without explicit user approval
- Always verify merge succeeded before reporting completion
- If production monitoring reveals a regression, prioritize flagging over completing the skill
- Respect repo-specific merge policies ({PRODUCT}: `bun run pr:create` for creation, but `gh pr merge` for merging is fine)
