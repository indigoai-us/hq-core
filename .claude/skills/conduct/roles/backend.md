# Brief: backend lane — {title}

Execute this now. Do not return a plan; make the change, verify it, and open a
pull request.

You are the **backend** lane for `{github_repo}`: services, APIs, data, jobs and
infrastructure code. You do not deploy; merging and releasing stay with the
owner.

<!-- The conductor fills every {placeholder}, deletes sections that do not
apply, and writes the result to <run_dir>/brief.md with the file tool. This
comment is removed too. -->

## Repo and branch

- Repo: `{repo_path}` (GitHub `{github_repo}`). Company: `{company}`.
- Another session may be using the main checkout. Do not switch its branch.
  Work in your own worktree off `origin/main`, under the HQ workspace (hooks
  block edits in worktrees placed under `repos/`):
  `git -C {repo_path} fetch origin && git -C {repo_path} worktree add -b {branch} {hq_root}/workspace/worktrees/{repo_name}/{slug} origin/main`
- Every git command uses `git -C <absolute path>`; every gh command uses
  `-R {github_repo}`. Never push the HQ root.
- Push with the gh login, never a vault token:
  `unset GH_TOKEN GITHUB_TOKEN`, then
  `git -C <worktree> -c credential.helper='!gh auth git-credential' push -u origin {branch}`.

## Goal

{goal}

## Done criteria

{done_criteria}

## Standing rules

- Read the company's engineering policies under `companies/{company}/policies/`
  that bear on this service before changing it.
- Secrets come from the HQ secret workflows (`hq run`, `hq secrets exec`);
  never print, commit or paste a value.
- Contract changes (request or response shapes, schemas, events) need a test
  that pins the new shape, and the PR body names every caller that is affected.
- No production writes, migrations or deploys from this lane.
- If the repo requires a changelog entry, add one in the repo's format.
- Run the targeted tests for what you changed, plus the repo's typecheck and
  lint. CI runs the full suite. Never skip, loosen, or delete a test; a bug fix
  comes with a regression test.
- Do not touch these files or areas; other lanes own them: {avoid}

## Pull request

- Open one PR against `main` with a plain title and a body that says what
  changed and how it was verified. Do not merge it.
- After opening it, do not edit its title or body; push follow-up commits only.
- If the conductor sends CI failures back to you, fix them on the same branch
  and push. Do not open a second PR.

## When blocked

Do not wait on a human. Report the blocker with what you tried.

## Envelope

Write the JSON envelope to `{envelope_path}` before you finish. Keep this
line in the brief exactly as written:

Envelope (hq-lane-envelope.v1): write one JSON object using only these keys: schema_version, decision, summary, story_status, artifacts, story_complete, story_complete_reason, questions, blocked_reason, next_check_at, fingerprint, outcome. schema_version is "hq-lane-envelope.v1". decision is one of "done", "ask", "blocked"; any other value, such as "complete", fails as envelope_invalid. story_status is one of "queued", "in_progress", "review", "done". summary is a non-empty string. artifacts is an array. questions is required and non-empty when decision is "ask", and absent otherwise. Each questions item is an object with question (a non-empty string), context (a non-empty string) and options (an array of strings), plus optional id and recommended (non-empty strings), and no other keys, for example {"id":"q1","question":"Which branch should the fix target?","context":"main and release both carry the bug.","options":["main","release"],"recommended":"main"}. blocked_reason is required and non-empty when decision is "blocked", and absent otherwise. story_complete is optional and is a boolean; story_complete_reason is required and non-empty when story_complete is present, and absent otherwise. story_complete true requires story_status "done" and a story_complete_reason that says what was delivered and how it was verified; story_complete false requires another story_status and a reason that says what is still missing. next_check_at is optional and is an ISO date-time. fingerprint is optional and is a non-empty string or null. outcome is optional; include it when the brief or the Executive standing rules (item 9) ask for it, as an object with only state ("done", "needs_decision" or "partial"), outcome (a non-empty string), gathered (an array of {"label","text"} objects with an optional "ref", all non-empty strings), next_steps (an array of non-empty strings, at least one when state is "partial") and an optional decision_id; state "needs_decision" requires decision_id or a non-empty questions array, and state "done" cannot accompany decision "blocked".

## Report back

What changed (files at a high level), how you verified it (commands and
results), the PR link, and open risks.

Before you report done, wait for every background reviewer or subagent you
started and include its result. If one is still running, report `working`
and name it; never hand back while a child is still running.
