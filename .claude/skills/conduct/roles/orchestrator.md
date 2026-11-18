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

## Envelope

Write the JSON envelope to `{envelope_path}` before you finish. Keep this
line in the brief exactly as written:

Envelope (hq-lane-envelope.v1): write one JSON object using only these keys: schema_version, decision, summary, story_status, artifacts, story_complete, story_complete_reason, questions, blocked_reason, next_check_at, fingerprint, outcome. schema_version is "hq-lane-envelope.v1". decision is one of "done", "ask", "blocked"; any other value, such as "complete", fails as envelope_invalid. story_status is one of "queued", "in_progress", "review", "done". summary is a non-empty string. artifacts is an array. questions is required and non-empty when decision is "ask", and absent otherwise. Each questions item is an object with question (a non-empty string), context (a non-empty string) and options (an array of strings), plus optional id and recommended (non-empty strings), and no other keys, for example {"id":"q1","question":"Which branch should the fix target?","context":"main and release both carry the bug.","options":["main","release"],"recommended":"main"}. blocked_reason is required and non-empty when decision is "blocked", and absent otherwise. story_complete is optional and is a boolean; story_complete_reason is required and non-empty when story_complete is present, and absent otherwise. story_complete true requires story_status "done" and a story_complete_reason that says what was delivered and how it was verified; story_complete false requires another story_status and a reason that says what is still missing. next_check_at is optional and is an ISO date-time. fingerprint is optional and is a non-empty string or null. outcome is optional; include it when the brief or the Executive standing rules (item 9) ask for it, as an object with only state ("done", "needs_decision" or "partial"), outcome (a non-empty string), gathered (an array of {"label","text"} objects with an optional "ref", all non-empty strings), next_steps (an array of non-empty strings, at least one when state is "partial") and an optional decision_id; state "needs_decision" requires decision_id or a non-empty questions array, and state "done" cannot accompany decision "blocked".

## Report back

One readiness line first: `ready`, `ready except <PRs>` or `not ready`. Then one
row per PR: number, title, head SHA, full-CI result with failing job names and
run links, merge state, and the merge order you recommend.

Before you report done, wait for every background reviewer or subagent you
started and include its result. If one is still running, report `working`
and name it; never hand back while a child is still running.
