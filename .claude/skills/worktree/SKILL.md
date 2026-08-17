---
name: worktree
description: Create a git worktree under workspace/worktrees/ and route all subsequent work through it. Main checkout is never modified — neither working tree nor local branch refs. By default fetches origin and branches off origin/{default} so the worktree gets the latest upstream state without mutating the main tree. Use when the user asks to "do X in a worktree", "spin up a worktree", "isolate this change", "work without touching main", or whenever a non-trivial change should be sandboxed.
allowed-tools: Bash(bash .claude/skills/worktree/worktree.sh:*), Bash(git:*), Read, AskUserQuestion
---

# Worktree

Sandbox any work in a git worktree at `workspace/worktrees/{repo}/{name}/`. The main checkout — both its working tree and its local branch refs — is left exactly as it was. The worktree is created on a fresh branch that points at the latest `origin/{default-branch}` (after a `git fetch`), so the work starts from upstream HEAD without any local-branch fast-forward.

## When to invoke

Trigger phrases:
- "do this in a worktree"
- "spin up a worktree for X"
- "make this change without touching main"
- "isolate this work"
- "I don't want my main checkout dirty"

Also invoke implicitly when the user requests a multi-file change in a repo where their main tree clearly has in-progress work (uncommitted edits, an unrelated branch checked out, or stash they care about) and isolation is the obviously right move.

## Default behavior

1. Resolve **source repo** = `git rev-parse --show-toplevel` of the current cwd (or `--source <path>` if given). Abort if not inside a git repo and no `--source` was provided, and abort if the resolved source is the HQ root itself — a worktree of HQ is rejected by `block-hq-worktree-session.sh`, so repo work must target a checkout under `repos/`. From the HQ root, always pass `--source`.
2. Resolve **default branch** via `git symbolic-ref refs/remotes/origin/HEAD`, falling back to `main` then `master`. Pass `--base <ref>` to override.
3. **Fetch** origin's default branch (unless `--no-pull`). Never fast-forwards the local branch — the worktree branches directly off `origin/{default}`, leaving the main checkout's refs untouched.
4. **Slug** the worktree name (kebab-case, short). Caller passes `--name`. The new branch defaults to `wt/{name}` (override with `--branch`).
5. **Create** the worktree:
   ```
   git -C {source} worktree add --no-track {HQ_ROOT}/workspace/worktrees/{repo}/{name} -b {branch} origin/{default}
   ```
   `--no-track` keeps the base branch from becoming the new branch's upstream (so a plain `git push` targets the feature branch, not the base).
6. **Print** the absolute worktree path. All subsequent edits, builds, tests run inside that path.

## Procedure

Invoke from the HQ root (where the `.claude/skills/...` path resolves) and pass `--source` to point at the target repo. The helper reads `--source` explicitly rather than the cwd, so it works regardless of where you run it:

```bash
bash .claude/skills/worktree/worktree.sh \
  --name <slug> \
  --source <repo-path> \
  [--branch <new-branch-name>] \
  [--base <branch-or-ref>] \
  [--no-pull]
```

On success the script prints:
- the absolute worktree path
- the branch name
- the base ref + short SHA the worktree starts from
- the source repo path
- a cleanup hint

After it succeeds, **cd into the printed path** and do all subsequent work there. Do not edit anything under the source repo's main checkout for the duration of this task.

### Asking the caller

If the user has not specified everything, ask **one question at a time** (per HQ's decision-queue policy):

1. **Worktree name** — if the user gave a task description but no slug, propose a kebab-case slug derived from the task and confirm.
2. **Skip the pull?** — only ask if the user signaled they're offline / want a snapshot of the current `origin/HEAD` without re-fetching. Otherwise default to fetching.
3. **Base branch override** — only ask if the repo's default branch is ambiguous (no `origin/HEAD`, no `main`, no `master`) or the user mentioned a non-default base.

Skip any of these if the user pinned the value in their request.

## Safety

- **Never** make edits in the main checkout. The whole point of this skill is isolation — if the user asks to edit main directly mid-flow, stop and confirm they want to abandon the worktree.
- **Never** delete an existing worktree directory without confirmation. If `workspace/worktrees/{repo}/{name}/` already exists, the script aborts; offer the user three options: pick a new name, `git worktree remove` the old one, or reuse it as-is (the latter requires running outside this skill).
- **Never** `rm -rf` a worktree to clean it up — that leaves stale `.git/worktrees/{name}/` administrative state in the source repo. Always use `git worktree remove`.
- **Never** auto-merge, auto-push, or auto-PR the worktree branch. Those are separate user decisions; surfacing the worktree path is where this skill ends.
- If `git fetch origin` fails (no network / bad auth), the script aborts before creating anything. Suggest the user retry with `--no-pull` to branch off the last-known `origin/{default}`, but flag that they're working from stale upstream state.
- If the source repo has no `origin` remote, the script falls back to branching off the local default branch (and skips fetch). Surface this to the user — it means the worktree starts from whatever the local main is, not "latest from upstream".

## Cleanup

When the user is done with the worktree (merged, abandoned, or just wants to free the slot):

```bash
git -C {source} worktree remove {HQ_ROOT}/workspace/worktrees/{repo}/{name}
git -C {source} branch -D wt/{name}    # only if the branch is no longer wanted
```

If `git worktree remove` complains about uncommitted changes in the worktree, surface that to the user — don't pass `--force` without explicit confirmation. Lost worktree edits are unrecoverable.

## Completion

End with:
- The absolute worktree path (so the user can `cd` if they want).
- The branch name + base SHA.
- A reminder that the main checkout is untouched (working tree, local `main`, stash all unchanged).
- The exact cleanup commands for when the user is done.
