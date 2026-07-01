---
name: resumework
description: Resume work from a specific handoff thread by id. Loads that thread's saved state (summary, next steps, git, files touched, learnings) and drops you straight back into the work. Use when you have a thread id in hand — e.g. from a previous `/handoff` report — and want to continue that exact session in a fresh one, rather than picking the most recent handoff (`/startwork`) or doing a post-mortem (`/recover-session`).
allowed-tools: Read, Grep, Glob, Bash(git:*), Bash(qmd:*), Bash(ls:*), Bash(find:*), Bash(jq:*), Bash(cat:*), Bash(core/scripts/hq-session.sh:*), Bash, AskUserQuestion
---

# Resume Work From a Thread

Targeted resume. Unlike `/startwork` (which peeks at `handoff.json` for the *latest* session), this skill takes an **explicit thread id** and rehydrates that exact thread so you can continue it in a fresh session.

**Thread id (required):** $ARGUMENTS

## When to Use

- A `/handoff` report gave you a thread id (`T-YYYYMMDD-HHMMSS-slug`) and you want to pick that work back up later.
- You want to resume a session that is **not** the most recent handoff (so `/startwork`'s "Resume last session" would load the wrong one).
- You're continuing real work — not auditing a crashed session. For a post-mortem of a wedged session, use `/recover-session` instead.

## Process

### 1. Resolve the thread id

The argument is a thread id, with or without the `.json` suffix, and may be a partial slug. Resolve it to exactly one thread file under `workspace/threads/` (also check `workspace/threads/archive/**` for older threads).

```bash
arg="$ARGUMENTS"                       # e.g. T-20260625-084414-files-acl-grant-timeout
id="${arg%.json}"; id="${id##*/}"      # strip .json and any leading path
id="$(echo "$id" | tr -d '[:space:]')" # trim stray whitespace

# Exact match first, then prefix/substring across active + archived threads.
matches=$(ls "workspace/threads/${id}.json" 2>/dev/null)
if [ -z "$matches" ]; then
  matches=$(find workspace/threads -name '*.json' ! -name '*.changeset.json' \
    -path "*${id}*" 2>/dev/null)
fi
printf '%s\n' "$matches"
```

- **No arg / empty** — STOP. This skill requires a thread id. Tell the user the form (`/resumework <thread-id>`) and offer `/startwork` (resume the latest handoff) as the no-id alternative. List the few most recent thread ids to choose from: `ls -t workspace/threads/T-*.json 2>/dev/null | grep -v changeset | head -5`.
- **Exactly one match** — proceed with that file.
- **Multiple matches** — present them via AskUserQuestion (id + title, newest first) and wait for the user to pick one. Do not guess.
- **No match** — report it plainly and show the 5 most recent thread ids so the user can correct the id.

Never load a `*.changeset.json` as the thread — it's the changeset sidecar, not the thread.

### 2. Load the thread

Read the resolved thread file (it's small — one Read). Extract:

- `conversation_summary` — what the prior session accomplished
- `next_steps[]` — the ordered todo handed off
- `git.branch`, `git.current_commit`, `git.dirty`
- `files_touched[]` — the changeset boundary
- `learnings[]` — operational notes (do **not** re-`/learn` them; they're already applied)
- `metadata.title`, `metadata.tags`
- `changeset_path` — if present, note it (don't read it unless the user needs the full diff scope)

If the thread references a company (via tags, `cwd`, or a `companies/{co}/...` path in `files_touched`), note the slug for Step 4.

### 3. Verify current git state vs the thread

The thread records the git state at handoff. Confirm where the repo is now so the user knows if anything drifted:

```bash
# Anchor to the repo the thread worked in when it's a nested repo;
# otherwise use HQ root context.
git -C {repoPath or HQ root} branch --show-current
git -C {repoPath or HQ root} log --oneline -3
git -C {repoPath or HQ root} status --short
```

Flag plainly if the current branch differs from `git.branch`, or if `git.current_commit` is no longer at HEAD (someone committed/merged since the handoff). If `git.dirty` was true at handoff but the tree is now clean, the in-flight edits may have been committed or lost — call that out.

### 4. Persist session metadata (if a company resolved)

```bash
bash core/scripts/hq-session.sh set company_slug "{co}"   # only if resolved
bash core/scripts/hq-session.sh set mode "Resume"
```

Skip the `company_slug` line if no company is resolvable from the thread — same fail-closed behavior as `/startwork`.

### 5. Present the resume block + next steps

```
Resuming thread
---------------
Thread: {thread_id}
Title:  {metadata.title}
Last session: {conversation_summary}

Git (at handoff): {git.branch} @ {git.current_commit}{" (dirty)" if dirty}
Git (now):        {current branch} @ {current short-hash}{drift note if any}

Files touched last session: {count} ({first few paths})

Next steps:
  1. {next_steps[0].step}
  2. {next_steps[1].step}
  ...
```

Then offer, via AskUserQuestion (one question, wait):

- **Start on next step 1** — begin the first handed-off next step.
- **Pick a different next step** — let the user choose which step to start.
- **Something else** — free-text; treat as a fresh task in this resumed context.

After the pick, proceed directly into the work.

## Rules

- A thread id is **required**. Naked `/resumework` does not fall through to latest-handoff resume — that's `/startwork`'s job. Point the user there instead.
- Read at most: the one resolved thread file + git state + (optionally) one journal file if the thread names a `project_dir`. Do not read INDEX.md, agents files, or company knowledge — same context diet as `/startwork`.
- Never re-run `/learn` on the thread's `learnings[]`; they were applied at handoff time. They're shown for context only.
- Resolve to exactly one thread before loading. On ambiguity, ask — never guess which thread the user meant.
- Always verify the live git branch with `git branch --show-current`; never trust the thread's recorded branch as current.
- This skill executes directly — no plan-mode detour.

## See also

- `/startwork` — resume the *latest* handoff (reads `handoff.json`) or pick a fresh company/project/repo.
- `/handoff` — writes the thread this skill resumes; its report prints the thread id to pass here.
- `/recover-session` — post-mortem triage of a crashed/wedged session (not normal resume).
