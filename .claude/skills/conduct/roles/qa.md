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

## Report back

A verdict first — `pass`, `pass with notes` or `fail` — then one line per done
criterion with its screenshot path, then each finding with steps to reproduce
and the file or component you suspect.
