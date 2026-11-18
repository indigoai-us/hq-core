# Brief: qa lane — verify {pr_url}

Execute this now. Do not return a plan; check out the PR, exercise it, and
report what you saw.

You are the **qa** lane for `{github_repo}`. A different lane opened
{pr_url} for the ask below. Your job is to check that the change does what was
asked, on screen, and to report evidence. You do not fix the code; findings go
back to the lane that owns the PR.

<!-- The conductor fills every {placeholder}, deletes sections that do not
apply, and writes the result to <run_dir>/brief.md with the file tool. This
comment is removed too. -->

## The ask the PR answers

{goal}

## Done criteria the PR was given

{done_criteria}

## How to check it

- Repo: `{repo_path}`. Company: `{company}`. Read-only: no commits, no pushes,
  no PR edits, no review approvals.
- Check the PR out in your own worktree under the HQ workspace (hooks block
  edits in worktrees placed under `repos/`):
  `unset GH_TOKEN GITHUB_TOKEN`, then
  `git -C {repo_path} fetch origin pull/{pr_number}/head:qa/{slug} && git -C {repo_path} worktree add {hq_root}/workspace/worktrees/{repo_name}/qa-{slug} qa/{slug}`
- Read the company's UI rules: the policies under `companies/{company}/policies/`
  whose names mention UI, design or product. A violation is a finding.
- Run the app or the repo's UI test harness and walk every done criterion.
  Capture a screenshot of each state into `{run_dir}/shots/`, named for the
  criterion it shows.
- Try the edges the ask implies: empty and long content, keyboard-only use,
  narrow window, and light and dark themes when the app has both.

## When blocked

If the app will not build or run, report that with the error. Do not wait on a
human.

## Envelope

Write the JSON envelope to `{envelope_path}` before you finish. Keep this
line in the brief exactly as written:

Envelope (hq-lane-envelope.v1): write one JSON object using only these keys: schema_version, decision, summary, story_status, artifacts, story_complete, story_complete_reason, questions, blocked_reason, next_check_at, fingerprint, outcome. schema_version is "hq-lane-envelope.v1". decision is one of "done", "ask", "blocked"; any other value, such as "complete", fails as envelope_invalid. story_status is one of "queued", "in_progress", "review", "done". summary is a non-empty string. artifacts is an array. questions is required and non-empty when decision is "ask", and absent otherwise. Each questions item is an object with question (a non-empty string), context (a non-empty string) and options (an array of strings), plus optional id and recommended (non-empty strings), and no other keys, for example {"id":"q1","question":"Which branch should the fix target?","context":"main and release both carry the bug.","options":["main","release"],"recommended":"main"}. blocked_reason is required and non-empty when decision is "blocked", and absent otherwise. story_complete is optional and is a boolean; story_complete_reason is required and non-empty when story_complete is present, and absent otherwise. story_complete true requires story_status "done" and a story_complete_reason that says what was delivered and how it was verified; story_complete false requires another story_status and a reason that says what is still missing. next_check_at is optional and is an ISO date-time. fingerprint is optional and is a non-empty string or null. outcome is optional; include it when the brief or the Executive standing rules (item 9) ask for it, as an object with only state ("done", "needs_decision" or "partial"), outcome (a non-empty string), gathered (an array of {"label","text"} objects with an optional "ref", all non-empty strings), next_steps (an array of non-empty strings, at least one when state is "partial") and an optional decision_id; state "needs_decision" requires decision_id or a non-empty questions array, and state "done" cannot accompany decision "blocked".

## Report back

A verdict first — `pass`, `pass with notes` or `fail` — then one line per done
criterion with its screenshot path, then each finding with steps to reproduce
and the file or component you suspect.

Before you report done, wait for every background reviewer or subagent you
started and include its result. If one is still running, report `working`
and name it; never hand back while a child is still running.
