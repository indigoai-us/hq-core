# Brief: orchestrator lane — release batch for {github_repo}

Execute this now. Do not return a plan; gather the batch, run the full CI, and
report readiness.

You are the **orchestrator** lane. The other lanes in this session opened pull
requests. You collect them into one release batch, make sure the full CI suite
has run on each, and report whether the batch is ready. You do not merge,
release or deploy: those wait for the owner's explicit approval.

<!-- The conductor fills every {placeholder}, deletes sections that do not
apply, and writes the result to <run_dir>/brief.md with the file tool. This
comment is removed too. -->

## The batch

- Repo: `{repo_path}` (GitHub `{github_repo}`). Company: `{company}`.
- Pull requests: {pr_list}
- Release target: {release_target}

## What to do

1. For each PR, read its state with
   `gh pr view <n> -R {github_repo} --json state,mergeable,mergeStateStatus,headRefOid,reviewDecision`.
   Note conflicts between PRs (the same files touched, or an order they must
   land in).
2. Pull-request CI often runs only a subset of jobs. Dispatch the repo's full
   CI workflow on each PR's head (`gh workflow run <workflow> -R {github_repo}
   --ref <branch>`, or the repo's documented full-suite trigger) and wait for
   it, bounded: give up on a run after {ci_timeout} seconds and report it as
   pending.
3. Read every check on each PR's final head, not only the summary. A skipped
   check is not a pass.
4. Do not merge, tag, release, deploy, or edit any PR's title or body. Do not
   push to any branch.

## Stop and report

Stop here and report. The conductor asks the owner whether to merge and
release; only after that approval, quoted back to you, may a later brief carry
the merge.

## When blocked

Do not wait on a human. Report the blocker with what you tried.

## Report back

One readiness line first: `ready`, `ready except <PRs>` or `not ready`. Then one
row per PR: number, title, head SHA, full-CI result with failing job names and
run links, merge state, and the merge order you recommend.
