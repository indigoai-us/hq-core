---
name: land-batch
description: |
  Triage, review, and sequentially merge multiple open PRs. Handles CI monitoring,
  conflict resolution between PRs, Codex-style review, and post-merge deploy verification.
  Use when asked to "land all PRs", "merge open PRs", or "triage and ship".
allowed-tools: Bash, Read, Grep, Glob, Write, Edit, Agent, AskUserQuestion
---

# Land Batch

**Triage open PRs -> prioritize -> review each -> merge sequentially -> verify deploys.**

This skill takes a set of open PRs from "open" to "merged and verified." It handles
the full batch landing sequence: triage/prioritization, per-PR review, conflict resolution
between sequentially-merged PRs, and post-merge deploy tracking.

## Input

Accepts one of:
- **No argument** — all open PRs on the current repo
- **PR numbers** (e.g. `3040 3051 2965`) — specific PRs to land
- **Label/filter** (e.g. `--label ready-to-merge`) — filtered set

## Step 0: Discover + Triage

### 0a: List open PRs

```bash
gh pr list --state open --json number,title,headRefName,createdAt,labels,statusCheckRollup,additions,deletions,files
```

### 0b: Classify each PR

For each PR, determine:
- **Scope**: files changed, apps affected (function-v2, web-front, web-client, etc.)
- **Risk**: LOW (config/docs/deletion), MEDIUM (feature, new routes), HIGH (infra, DB, auth)
- **CI status**: all green, partial fail, not run
- **Merge readiness**: clean, has conflicts, needs rebase
- **Dependencies**: does PR X need to land before PR Y?

### 0c: Build merge order

Prioritize by:
1. **Blockers first** — PRs that other PRs depend on
2. **Low risk first** — config, docs, cleanup PRs land fast
3. **Infrastructure before features** — DB/infra PRs before feature PRs that use them
4. **Smallest first** within same tier — reduces conflict surface

Present triage table to user:

```
PR Triage
─────────
| # | Title | Risk | CI | Apps | Order |
|---|-------|------|----|------|-------|
| ... | ... | ... | ... | ... | ... |

Proposed merge order: #X -> #Y -> #Z
Proceed? (y/n/reorder)
```

Wait for user confirmation before proceeding.

## Step 1: Per-PR Landing Loop

For each PR in merge order:

### 1a: Pre-merge checks

```bash
# Fresh CI status
gh pr view {number} --json statusCheckRollup,mergeable,reviewDecision

# Check for conflicts with main (PRs merged earlier may cause new conflicts)
gh pr view {number} --json mergeable
```

If `mergeable: CONFLICTING`:
- Checkout the branch
- Merge main in (prefer merge over rebase for branches far behind)
- Resolve conflicts (take main for already-landed changes, keep branch for new work)
- Push conflict resolution
- Wait for CI to re-run

### 1b: Code review

Launch a review sub-agent (or inline review for small PRs <100 lines):

**Review checklist:**
- Auth/security: new API routes have auth, no IDOR, no injection
- Infra: SST/DynamoDB/Lambda changes noted for deploy
- Code quality: no dangling imports, proper error handling
- Tenant isolation: multi-tenant queries scoped properly
- Data validation: input size limits, cursor validation
- Dependencies: new packages audited

**Review verdicts:**
- **PASS** — merge immediately
- **PASS WITH NOTES** — merge, track notes for follow-up
- **FAIL** — fix issues on branch before merge, then re-review

### 1c: Merge

```bash
gh pr merge {number} --squash --delete-branch
```

If branch protection blocks: use `--admin` if available.
If E2E flake (pre-existing, unrelated): merge with `--admin` after confirming flake is known.

### 1d: Post-merge sync

```bash
# Update local main
git checkout main && git pull

# Check if next PR in queue now has conflicts
gh pr view {next_number} --json mergeable
```

### 1e: Track what needs deploy

After each merge, note:
- Lambda/serverless changes -> needs `gh workflow run cd.yml`
- SST infra changes -> needs manual SST deploy
- DB migrations -> needs `prisma migrate` verification
- Frontend changes -> auto-deploys via Vercel/CD

## Step 2: Deploy Verification

After all PRs merged:

### 2a: Trigger deploys

```bash
# If Lambda changes were merged:
gh workflow run cd.yml -f env=development -f apps={affected-apps}

# Monitor deploy:
gh run list --workflow cd.yml -L 1 --json status,conclusion,databaseId
```

### 2b: SST deploy (if needed)

SST infra changes require manual deploy:
```bash
sst deploy --stage development
```

If SST lock exists: `sst unlock --stage=development` first (requires admin AWS creds).

### 2c: Post-deploy checks

- Verify CD pipeline completes
- Check for DB migration status if applicable
- Run post-deploy seed scripts if any PR requires them

## Step 3: Report

```
Batch Landing Complete
──────────────────────
Merged: {N} PRs
  - #{number}: {title} ({risk})
  ...

Deploy status:
  - Lambda: {deployed/pending/not-needed}
  - SST infra: {deployed/pending/not-needed}
  - Frontend: {auto-deployed/pending}
  - DB migrations: {applied/pending/none}

Follow-ups:
  - {any PASS WITH NOTES items}
  - {any post-deploy scripts needed}
  - {any remaining open PRs not in this batch}
```

## Error Handling

- **Merge conflict cascade**: If PR N's merge causes conflicts in PR N+1, resolve before continuing. Don't skip PRs
- **CI failure after conflict resolution**: Re-run full CI. Don't merge with failing checks (except known E2E flakes)
- **Review FAIL**: Fix on branch, push, wait for CI, then continue the loop
- **Deploy failure**: Report immediately. Don't continue to production deploy if dev fails
- **GitGuardian false positive**: Note and proceed if the flagged secret is pre-existing (not introduced by the PR)

## Rules

- Always get user confirmation on triage order before starting merges
- Never force-push during landing
- Merge PRs one at a time, pulling main between each
- Track all infra changes for deploy — don't let SST/Lambda changes slip through un-deployed
- If a PR adds new DynamoDB tables or SST resources, flag for SST deploy
- Known E2E flakes (api-v2:e2e:development connection reset) are not merge blockers
- Use `--admin` for branch protection bypass only when user has admin rights
- Post-deploy seed scripts must be called out explicitly in the report
