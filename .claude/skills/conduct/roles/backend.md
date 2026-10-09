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

## Report back

What changed (files at a high level), how you verified it (commands and
results), the PR link, and open risks.
