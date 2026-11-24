---
name: land-batch
description: "Triage, review, and merge several open PRs in order, with CI and deploy checks. Triggers: \"land all PRs\", \"merge open PRs\"."
allowed-tools: Bash, Read, Grep, Glob, Write, Edit, Agent, AskUserQuestion
---

# Land Batch

**Triage open PRs -> prioritize -> review each -> batch train or auto-merge on green -> verify deploys.**

This skill takes a set of open PRs from "open" to "merged and verified." It handles
triage/prioritization, per-PR review, conflict resolution, batch-train or GitHub
auto-merge landing pinned to reviewed heads, and post-merge deploy tracking.

## Input

Accepts one of:
- **No argument** — all open PRs on the current repo
- **PR numbers** (e.g. `3040 3051 2965`) — specific PRs to land
- **Label/filter** (e.g. `--label ready-to-merge`) — filtered set

## Step 0: Discover + Triage

### 0a: List open PRs and repo merge capabilities

```bash
gh pr list -R {repo} --state open --json number,title,headRefName,headRefOid,isDraft,mergeable,createdAt,labels,statusCheckRollup,additions,deletions,files
gh api repos/{repo} --jq '{allow_auto_merge, delete_branch_on_merge}'
```

### 0b: Classify each PR

For each PR, determine:
- **Scope**: files changed, apps/services affected
- **Risk (merge effect)**: LOW (non-deploying or isolated low-blast-radius change), MEDIUM (deploying feature, new routes, sync/ACLs/billing), HIGH (infra, DB migration, auth/security guards). On repos where merging to main does not deploy directly to users (shipped via a separate release/tag), rate merge risk on the effect of the merge rather than inflating every PR to MEDIUM for the next release.
- **CI status**: all green, in progress, partial fail, not run
- **Merge readiness**: clean, has conflicts, draft, held
- **Dependencies**: does PR X need to land before PR Y?

### 0c: Build merge order and check confirmation gate

Prioritize by:
1. **Blockers first** — PRs that other PRs depend on
2. **Low risk first** — config, docs, cleanup PRs land fast
3. **Infrastructure before features** — DB/infra PRs before feature PRs that use them
4. **Smallest first** within same tier — reduces conflict surface

Present triage table:

```
PR Triage
─────────
| # | Title | Head | Risk | CI | Order |
|---|-------|------|------|----|-------|
| ... | ... | ... | ... | ... | ... |

Proposed merge order: #X -> #Y -> #Z
```

**Confirmation gate:**
- **Clean LOW-risk PRs (0 CRITICAL review findings, LOW merge-effect risk, no hold, required checks green or pending auto-merge):** proceed automatically under standing clean-low-risk auto-merge rules; do not block the batch on an interactive confirmation prompt.
- **MEDIUM/HIGH risk PRs, unresolved CRITICALs, holds, releases, or risky ordering choices:** hold those items for explicit user confirmation while non-dependent clean LOW PRs proceed.

## Step 1: Review + Land

### 1a: Resolve conflicts and review each PR on its exact `head_sha`

For each PR in merge order:
- Skip draft PRs unless the user asked to ready them.
- If `mergeable: CONFLICTING`, update from `main`, resolve conflicts, push, and record the new `head_sha`.
- Run an independent review on `{head_sha}` (0 CRITICAL required; fix mechanical findings on the branch and re-verify on the new `head_sha`).

### 1b: Land via Batch Train, Auto-Merge, or Direct Squash

Choose the highest-throughput safe path supported by `{repo}`:

1. **Batch train (preferred for 2+ ready PRs in the same repo when `scripts/ci/batch-train.py` or a merge queue is available):**
   Pass every reviewed PR pinned as `{number}@{head_sha}` so the train validates the combined batch once, bisects on red, and squash-merges with `--match-head-commit`:
   ```bash
   python3 scripts/ci/batch-train.py --repo {repo} --prs {n1}@{sha1},{n2}@{sha2}
   ```
   For production-on-merge repos that require serialized deploys, add `--one-at-a-time --deploy-check '<cmd>' --deploy-wait '<cmd>'`.
2. **GitHub auto-merge (preferred when no batch-train executor is present and `allow_auto_merge` is `true`):**
   For each independent reviewed PR whose ruleset approval requirement is met (and respecting deploy spacing / contract order — never arm parallel merges into a known broken prod deploy):
   ```bash
   gh pr merge {number} -R {repo} --auto --squash --delete-branch --match-head-commit {head_sha}
   ```
   Monitor completion in the background (`gh pr checks {number} -R {repo} --watch`).
3. **Direct squash fallback (only when neither batch-train nor `--auto` can fire):**
   Wait for required checks to finish green on `{head_sha}` (background watch, no foreground sleep loop), then merge pinned to the reviewed head:
   ```bash
   gh pr merge {number} -R {repo} --squash --delete-branch --match-head-commit {head_sha}
   ```
   Use `--admin` only when authorized and **only** for a review-only gate — never to bypass failing required checks or unverified flakes.

### 1c: Post-merge conflict check (non-train merges only)

After direct merges, check remaining PRs' `mergeable` status (`gh pr view {next_number} -R {repo} --json mergeable`); only update a branch from `main` when GitHub reports `CONFLICTING`.

### 1d: Track what needs deploy

After each merge, note:
- Lambda/serverless changes -> needs `gh workflow run cd.yml` or prod deploy watch
- SST infra changes -> needs SST deploy verification
- DB migrations -> needs migration verification
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
- **CI failure after conflict resolution**: Re-run full CI. Never bypass failing required checks (rerun transient infra flakes with `gh run rerun {run_id} -R {repo} --failed` or let the batch train bisect)
- **Review FAIL**: Fix on branch, push, wait for CI, then continue the loop
- **Deploy failure**: Report immediately. Don't continue to production deploy if a prior deploy is broken
- **Secret-scanner false positive**: Verify and resolve per repo policy before merging

## Rules

- Do not block clean LOW-risk PRs on interactive confirmation when a standing auto-merge policy applies; always pause for MEDIUM/HIGH risk, holds, or releases
- Never force-push during landing
- Always anchor `gh` calls with `-R {repo}` and pin merges with `--match-head-commit {head_sha}`
- Prefer `scripts/ci/batch-train.py` (when available) or `gh pr merge --auto` over serial manual polling loops
- Respect production-on-merge deploy spacing and serialization rules
- Never bypass failing required CI checks with `--admin`; use `--admin` only for authorized review-only gates
- Track all infra changes for deploy — don't let SST/Lambda changes slip through un-deployed
- Post-deploy seed scripts must be called out explicitly in the report
