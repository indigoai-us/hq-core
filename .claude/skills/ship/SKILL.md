---
name: ship
description: |
  Meta pipeline: review → land → deploy → smoke → heal → monitor. Takes one or
  more PRs from "open" through merged, deployed, live-verified, and monitored
  until every declared KPI is healthy. Use when asked to "ship this", "land and
  monitor", "take this all the way to prod", or when a feature spans repos and
  needs the full loop closed (per policy hq-smoke-cross-repo-contracts-before-done).
allowed-tools: Bash, Read, Grep, Glob, Write, Edit, Agent, AskUserQuestion, TaskCreate, TaskUpdate, Monitor, CronCreate, CronList
---

# Ship

**REVIEW → LAND → DEPLOY → SMOKE → HEAL (on any failure) → MONITOR → DOCUMENT.**

This skill is a meta-pipeline that composes existing pack skills into one
closed loop. It does not reimplement them — it sequences them and owns the
failure/heal/re-verify cycle plus standing monitoring. A PR is not "shipped"
when it merges; it is shipped when the live user-facing path works and a
standing monitor is watching it.

A worked example of the full loop looks like: one session takes a paired
frontend and backend PR from open through merged, deployed, smoke-verified
against the live signup path, and monitored until the declared KPIs are healthy
— with the session journal kept in that project's `journal/` directory.

## Input

Accepts any combination of:

- **PR refs** — one or more, each as `owner/repo#123`, a PR URL, a bare number
  (repo inferred from cwd), or nothing (open PR for the current branch).
- **KPI checklist** — a list of observable health criteria the shipped feature
  must satisfy (e.g. "funnel smoke passes", "no 5xx on /api/me/signup/*",
  "checkout redirect lands on Stripe"). If omitted, derive one in Step 0 and
  confirm it with the user.
- **Flags** — `--no-monitor` (skip Step 6 standing monitor), `--skip-review`
  (only when the PRs already carry a completed paranoid review this session),
  `--no-docs` (skip Step 7 documentation sync).

## Done Criteria (define BEFORE executing)

The pipeline is complete only when ALL of these are observably true:

1. Every input PR is merged (state `MERGED`, merge commit recorded).
2. Every production deploy triggered by those merges completed successfully
   (Vercel deployment `READY` on the production target, and/or the deploy-prod
   GitHub workflow run concluded `success`).
3. A real end-to-end smoke against the LIVE deployed stack passed — real auth,
   real data, whole loop, cleanup done (hard policy
   `hq-smoke-cross-repo-contracts-before-done`).
4. A standing monitor exists and is verified (cron smoke workflow or scheduled
   task), OR `--no-monitor` was passed.
5. Every KPI in the checklist reads healthy, and the final report includes the
   KPI table.

Documentation sync (Step 7) is deliberately NOT in this list. A change is
"shipped" when the live path works and a monitor watches it — whether the docs
got updated does not gate that status. Docs run last, foreground, after the
above are all true.

Write these as concrete, checkable statements for THIS run in Step 0 (with the
actual repo names, URLs, workflow names, KPI probes) before touching anything.

## Step 0: Resolve Scope + Ordering

1. Resolve each PR ref → `{repo, number, title, branch, base}`. Anchor every
   `gh` call with `-R owner/repo`.
2. Resolve the owning company; load company policy constraints via
   frontmatter-only scan of `companies/{co}/policies/` (digests are retired —
   SessionStart uses `inject-policy-on-trigger`) and the manifest infra fields
   for deploy targets. Never guess credentials.
3. Identify each repo's production deploy mechanism:
   - **Vercel git integration** — merge to main auto-deploys; watch via
     `vercel ls`/`vercel inspect` or the GitHub deployment status API.
   - **GH deploy-prod workflow** — merge triggers (or you dispatch) a workflow;
     watch the run.
   - **Manual (SST etc.)** — merging does NOT deploy; the deploy is an explicit
     pipeline step you must run and watch.
4. **Multi-repo ordering (hard rule):** when PRs span a producer and consumer
   of a shared contract, land in contract-safe order — **additive API fields /
   server first, defensive consumers second**. The server must tolerate old
   clients before any client that depends on the new field/route deploys.
   Removals invert: consumers stop reading first, producer removes last.
   Build the merge order accordingly; within a tier, smallest/lowest-risk first
   (reuse `land-batch` triage semantics for >2 PRs).
5. Derive or confirm the KPI checklist. Each KPI must name its probe (command,
   URL, query, or workflow) — a KPI without a probe is not a KPI.
6. Present the plan (PRs, order, deploy mechanisms, KPIs, done criteria) and
   get an explicit go. Landing + deploying is irreversible-adjacent; this gate
   is mandatory.

## Step 1: REVIEW (pre-merge gate)

For each PR, run the paranoid pre-landing review — reuse
`/review` semantics (two-pass: CRITICAL blocks, INFORMATIONAL
goes in the PR body), or `/code-review` where available. For multi-PR ships,
additionally review the CROSS-PR contract: do the field names, envelopes,
auth token types, and encodings match on both sides of every boundary the PRs
touch? (This is exactly where mocked unit tests lie — see the six-bug cascade
in the smoke policy.)

- CRITICAL findings → fix on the branch, push, wait for CI, re-review.
- Never merge past an unresolved CRITICAL without explicit user override.

## Step 2: LAND

For each PR in the Step 0 order, reuse `/land` semantics:

1. Wait for CI green — use a background Monitor on
   `gh pr checks {n} -R {repo}` (see Background Monitors below). Fix failures
   at root cause; no skipped/loosened tests, ever.
2. Resolve outstanding review threads (bot suggestions applied if valid; human
   comments summarized to the user).
3. Merge: `gh pr merge {n} -R {repo} --squash --delete-branch` (respect repo
   merge policy). Verify state `MERGED` and record the merge commit.
4. Between PRs: pull main, re-check the next PR's `mergeable` (earlier merges
   can create conflicts), and re-verify contract ordering still holds.

## Step 3: DEPLOY (watch to completion)

For each merged PR, watch its production deploy to a terminal state:

- **Vercel:** find the deployment created from the merge commit and watch
  until `READY` on production (`gh api repos/{owner}/{repo}/deployments` +
  statuses, or `vercel inspect`). A `READY` preview is not done — it must be
  the production target.
- **GH workflow:** find the run triggered by the merge (or dispatch it), then
  `gh run watch {id} -R {repo}` in the background until concluded `success`.
- **Manual deploy repos:** run the documented deploy, watch it, and say so in
  the report — never report "merged" as "deployed" for these.

Respect the Step 0 ordering here too: do not start a consumer's deploy until
its producer's deploy is live, when the consumer needs the new contract.

## Step 4: SMOKE (live, end-to-end)

Hard gate per `hq-smoke-cross-repo-contracts-before-done`:

- Exercise the WHOLE user-facing loop on the LIVE deployed stack with real
  auth and real data — not unit tests, not previews, not mocked boundaries.
  (Reference: the funnel ship created a real company via the new route and
  followed the redirect all the way onto real Stripe checkout.)
- Prefer agent-browser for browser flows (pack policy
  `hq-prefer-agent-browser`); API loops via real authed requests.
- **Clean up** every test artifact the smoke creates (delete smoke companies,
  test records, orders) — or explicitly hand the leftover to the user in the
  report with a deletion note.
- Record exactly what was exercised and what was observed; "it loaded" is not
  a smoke result.

## Step 5: HEAL (on any failure, any step)

On any failure — CI red, review CRITICAL, deploy failed, smoke broke, KPI
unhealthy — do NOT patch blind. Apply `/investigate`
discipline:

1. Scope-lock to the failure; form ranked hypotheses; test one variable at a
   time; 3-strike rule before widening scope.
2. Fix at root cause, with a regression test (`hq-bugfix-requires-tests`).
3. Re-enter the pipeline at the earliest affected step: fix → review the fix →
   land it → watch its deploy → re-smoke. Never re-verify less than what the
   fix could have affected.
4. If the failure is in production and user-impacting, tell the user
   immediately (security/blocker signal) and offer revert as an option before
   a slow forward-fix.

## Step 6: MONITOR (standing, until KPIs are green)

1. **Verify or create a standing monitor:**
   - Check for an existing cron smoke — a scheduled GitHub workflow smoking
     this path, or a scheduled task (`CronList` / scheduled-tasks) already
     probing it. If one exists and covers the shipped path, verify it ran
     green post-deploy.
   - If none exists, create one: a scheduled smoke workflow in the owning
     repo, or a scheduled task that runs the smoke and alerts on failure
     (the funnel ship used a 6-hour scheduled task alerting #hq-dev).
2. **Watch until healthy:** probe every KPI in the checklist. Use background
   Monitors with sensible windows — not sleep loops (see below). Keep watching
   until every KPI reads healthy for at least one full probe cycle
   post-deploy, healing (Step 5) anything that reads unhealthy.
3. Confirm the standing monitor itself works (trigger it once or verify its
   most recent run) — an unverified monitor is not a monitor.

## Background Monitors (not sleep loops)

NEVER busy-wait with foreground `sleep` loops. Use the harness's background
facilities:

- `gh run watch` / long-poll commands via Bash `run_in_background: true` — the
  harness re-invokes you when they exit.
- The `Monitor` tool with an until-condition for waiting on external state.
- Scheduled tasks / cron workflows for anything beyond the session's horizon.

Multiple independent watches (e.g. two repos' deploys) run as parallel
background monitors, not serially.

## Step 7: DOCUMENT (foreground, last — after everything above is green)

Only after Steps 1–6 are done (merged, deployed, smoked, monitored) sync the
documentation to match what shipped. This runs **foreground and last** — never
in the background, never racing the ship work, never a gate on "shipped". Skip
the whole step with `--no-docs`.

Compose the two existing doc skills; do not reimplement them:

1. **In-repo docs** — run `/document-release` for the shipped
   repos. Syncs README, CLAUDE.md, architecture docs, and INDEX files to match
   the diff. (This overlaps with what `/handoff` runs, but running it here — with
   the shipped diff hot in session — produces higher-fidelity edits than a later
   headless handoff subagent reconstructing the diff from git. It is idempotent,
   so the overlap is harmless.)
2. **Published docs site** — run `publish-docs`. It resolves the active company's
   docs-site sync skill (e.g. `{co}:sync-docs`) and runs it foreground, or cleanly
   no-ops if the company has no published docs site. This covers the standalone
   docs-site repo (e.g. `docs.{company}.com`) that `document-release` never touches.

A failure in either doc skill is reported plainly in Step 8 but does NOT retroact
the ship's merged/deployed/smoked status — surface it and let the user decide
whether to heal or hand it off. Docs are not in the Done Criteria.

## Step 8: Report

```
Ship Complete
─────────────
PRs:      #{n} {repo} → merged {commit[:8]}  (one line each, in landed order)
Review:   {pass | N criticals fixed}
Deploys:  {repo}: {vercel READY | workflow success | manual done}  (each)
Smoke:    {what was exercised} → PASS  (artifacts cleaned: {yes | handed off})
Heals:    {none | N failures root-caused and re-landed, one line each}
Monitor:  {existing verified | created: name + schedule + alert channel}
Docs:     {in-repo synced + site published <url> | in-repo synced, no site | skipped (--no-docs)}

KPI Table
| KPI | Probe | Status |
|-----|-------|--------|
| ... | ...   | ✅/❌  |
```

All KPIs must be ✅ (or explicitly waived by the user) before reporting done.
Then journal the ship per session-journal discipline.

## Rules

- Done criteria are written in Step 0 and never loosened mid-run.
- Never skip CI, never fake or loosen a test, every bugfix ships a regression
  test (`hq-no-test-shortcuts`, `hq-bugfix-requires-tests`).
- Additive-first / defensive-consumer ordering is a hard rule for multi-repo
  ships — both for merge order and deploy order.
- Merged ≠ deployed ≠ working. Only a live smoke plus healthy KPIs closes the
  loop; a standing monitor keeps it closed.
- Anchor every git/gh mutation (`git -C`, `gh -R`); never mutate from HQ root.
- Company isolation: one company's credentials and deploy targets only.
- Failures are reported plainly and immediately; healing is transparent in the
  final report, not hidden.
- Documentation (Step 7) is foreground, last, and non-gating: it runs only after
  the ship is verified, never in the background, and a docs failure never
  downgrades a merged/deployed/smoked ship. Compose `document-release` +
  `publish-docs`; do not reimplement doc logic here.
