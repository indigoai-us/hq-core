---
name: resumework
description: "Resume a specific handoff thread by id. For the latest handoff use /startwork."
allowed-tools: Read, Grep, Glob, Bash(git:*), Bash(qmd:*), Bash(ls:*), Bash(find:*), Bash(jq:*), Bash(cat:*), Bash(core/scripts/hq-session.sh:*), Bash(bash core/scripts/resume-thread-lock.sh:*), Bash(bash core/scripts/handoff-sync-prefetch.sh:*), Bash(session_id="$(bash core/scripts/hq-session.sh:*), Bash(lock_json="$(bash core/scripts/resume-thread-lock.sh:*), Bash(if bash core/scripts/resume-thread-lock.sh:*), Bash(bash core/scripts/handoff-open-steps.sh:*), Bash, AskUserQuestion
---

# Resume Work From a Thread

Targeted resume. Unlike `/startwork` (which peeks at `handoff.json` for the *latest* session), this skill takes an **explicit thread id** and rehydrates that exact thread so you can continue it in a fresh session.

**Thread id (required):** $ARGUMENTS

## When to Use

- A `/handoff` report gave you a thread id (`T-YYYYMMDD-HHMMSS-slug`) and you want to pick that work back up later.
- You want to resume a session that is **not** the most recent handoff (so `/startwork`'s "Resume last session" would load the wrong one).
- You're continuing real work — not auditing a crashed session. For a post-mortem of a wedged session, use `/recover-session` instead.

## Process

### 0. Prefetch cross-device state and resolve the thread id

Before resolving the thread, pull the session continuity pointer from the personal vault so a `/handoff` run on another machine is visible on this one. The workspace tree is otherwise machine-local; only `workspace/threads/handoff.json` plus the referenced thread file are carved into the personal vault (hq-cloud-sync `computeContinuityPointerPaths`). Without this pull, resuming on a second device sees stale state (or no thread file at all). The helper is fail-soft: missing-CLI, offline, logged-out, or lock-held hosts return within the timeout and leave the local pointer untouched. Its output is advisory, so continue even if it exits non-zero.

The argument is a thread id, with or without the `.json` suffix, and may be a partial slug. Resolve it to exactly one thread file under `workspace/threads/` (also check `workspace/threads/archive/**` for older threads).

```bash
bash core/scripts/handoff-sync-prefetch.sh || true

arg="$ARGUMENTS"                       # e.g. T-20260625-084414-files-acl-grant-timeout
id="${arg%.json}"; id="${id##*/}"      # strip .json and any leading path
id="$(echo "$id" | tr -d '[:space:]')" # trim stray whitespace
if [ -z "$id" ]; then
  printf '%s\n' 'A thread id is required. Recent threads:'
  ls -t workspace/threads/T-*.json 2>/dev/null | grep -v changeset | head -5
  exit 0
fi

# Exact match first, then prefix/substring across active + archived threads.
matches=$(find workspace/threads -maxdepth 1 -type f -name "${id}.json" -print 2>/dev/null)
if [ -z "$matches" ]; then
  matches=$(find workspace/threads \
    -path 'workspace/threads/resume-locks' -prune -o \
    -name '*.json' ! -name '*.changeset.json' -path "*${id}*" -print 2>/dev/null)
fi
printf '%s\n' "$matches"
```

- **No arg / empty** — STOP. This skill requires a thread id. Tell the user the form (`/resumework <thread-id>`) and offer `/startwork` (resume the latest handoff) as the no-id alternative. List the few most recent thread ids to choose from: `ls -t workspace/threads/T-*.json 2>/dev/null | grep -v changeset | head -5`.
- **Exactly one match** — proceed with that file.
- **Multiple matches** — present them via AskUserQuestion (id + title, newest first) and wait for the user to pick one. Do not guess.
- **No match** — report it plainly and show the 5 most recent thread ids so the user can correct the id.

Never load a `*.changeset.json` as the thread — it's the changeset sidecar, not the thread.

### 1. Check and record the resume lock

After resolving exactly one thread and **before reading its handoff details**, inspect its durable resume lock. The lock lives at `workspace/threads/resume-locks/{thread_id}.lock/`, separate from the immutable thread JSON: thread archival can move `T-*.json` files without losing the marker.

Replace the `thread_file` placeholder below with the exact path returned by Step 0. Tool calls run in separate shells, so do not rely on the earlier shell's `matches` variable.

```bash
thread_file="<resolved-thread-file>"
thread_id="$(basename "$thread_file" .json)"
session_id="$(bash core/scripts/hq-session.sh current)"
[ -n "$session_id" ] || session_id=unknown-session
lock_json="$(bash core/scripts/resume-thread-lock.sh inspect "$thread_id")"
status="$(jq -r '.status // empty' <<<"$lock_json")"
case "$status" in
  unlocked)
    if bash core/scripts/resume-thread-lock.sh acquire "$thread_id" --session-id "$session_id"; then
      bash core/scripts/handoff-open-steps.sh list --limit 10
    else
      rc=$?
      if [ "$rc" -ne 3 ]; then exit "$rc"; fi
      lock_json="$(bash core/scripts/resume-thread-lock.sh inspect "$thread_id")"
      printf '%s\n' "$lock_json"
    fi
    ;;
  locked|stale) printf '%s\n' "$lock_json" ;;
  *) printf 'Unexpected resume lock status: %s\n' "$status" >&2; exit 1 ;;
esac
```

On `unlocked`, continue only after acquisition succeeds. The open-step list is emitted after acquisition so steps from other recent handoffs remain visible too. **`locked` or `stale`** — use **AskUserQuestion** and wait. Do not read or act on the thread before the user confirms re-resume. Ask exactly the `prompt` supplied by `lock_json`; it includes the prior session and timestamp. The question must explicitly ask: **“This thread was already resumed by {session} at {when}. Re-resume anyway?”** Offer only:

- **Re-resume anyway** — refresh the marker for this session and continue.
- **Cancel resume** — stop; do not read or act on the thread.

Only after the user chooses **Re-resume anyway**, keep `lock_json.lock_generation` as `lock_generation`, then run:

```bash
thread_id="<resolved-thread-id>"
lock_generation="<confirmed-lock-generation>"
session_id="$(bash core/scripts/hq-session.sh current)"
[ -n "$session_id" ] || session_id=unknown-session
bash core/scripts/resume-thread-lock.sh acquire "$thread_id" --replace --expected-generation "$lock_generation" --session-id "$session_id"
bash core/scripts/handoff-open-steps.sh list --limit 10
```

If acquisition race-loses with exit `3`, re-inspect and ask using the new prompt. If the confirmed replacement exits `4`, the marker changed while the question was open; re-inspect it and ask again using the new prompt. Never reuse the earlier confirmation to replace a newer lock.

Never silently proceed or silently replace a marker. A stale marker (expired after the configured `HQ_RESUME_LOCK_STALE_SECONDS`, 24 hours by default, or malformed) is still evidence of an earlier resume, so it follows this same explicit confirmation path. Do not delete stale lock state; the confirmed `--replace` refreshes it.

### 2. Load the thread

Read the resolved thread file (it's small — one Read). Extract:

- `conversation_summary` — what the prior session accomplished
- `next_steps[]` — the ordered todo handed off. Each step carries `id` and `status`; show only `status: open` ones. The pre-read lock command also lists steps left open by OTHER recent handoffs. Close a step with `bash core/scripts/handoff-open-steps.sh close <id>` when it is actually done.
- `git.branch`, `git.current_commit`, `git.dirty`
- `files_touched[]` — the changeset boundary
- `learnings[]` — operational notes (do **not** re-`/learn` them; they're already applied)
- `metadata.title`, `metadata.tags`
- `changeset_path` — if present, note it (don't read it unless the user needs the full diff scope)

If the thread references a company (via tags, `cwd`, or a `companies/{co}/...` path in `files_touched`), note the slug for Step 3.
Treat `files_touched` paths as metadata. If you need to inspect one, bind the
company first and read the exact path literally; do not build a shell loop from
`jq` or command-substitution output. An unresolved company path must remain
blocked by the scope authorizer.

### 3. Verify current git state and persist session metadata

The thread records the git state at handoff. Confirm where the repo is now so the user knows if anything drifted, then persist the successor session's company and mode after resolving the thread.

```bash
# Anchor to the repo the thread worked in when it's a nested repo;
# otherwise use HQ root context. Resolve repoPath first, then substitute its
# literal absolute path into each command; do not use an unresolved expansion.
git -C /absolute/path/to/repo branch --show-current
git -C /absolute/path/to/repo log --oneline -3
git -C /absolute/path/to/repo status --short

# Run the first line only if a company slug was resolved from the thread.
bash core/scripts/hq-session.sh set company_slug "{co}"
bash core/scripts/hq-session.sh set mode "Resume"
session_id="$(bash core/scripts/hq-session.sh current)"
session_key="${session_id//[^A-Za-z0-9._-]/_}"
if [ -f ".claude/state/session-title-${session_key}.manual" ]; then
  printf '%s\n' 'Manual session title found; leave it unchanged.'
else
  printf '%s\n' 'No manual session title; successor title may be updated.'
fi
```

Flag plainly if the current branch differs from `git.branch`, or if `git.current_commit` is no longer at HEAD (someone committed/merged since the handoff). If `git.dirty` was true at handoff but the tree is now clean, the in-flight edits may have been committed or lost — call that out. If no company is resolvable, omit the `company_slug` command; this keeps the same fail-closed behavior as `/startwork`.

After the thread is loaded and its company/work subject is clear, update this successor session's title with `set_session_title` according to `core/policies/hq-session-title-grammar.md`. Carry the useful work subject from `metadata.title` or `conversation_summary`; include company, product, or mode when that adds information. If the manual title marker exists, skip the title update to preserve the user's manual rename. If the optional title tool is unavailable, skip the update without blocking resume.

### 4. Present the resume block + next steps

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
- Once a thread is exactly resolved, always inspect and acquire its resume lock before loading it. If it is already locked or stale, always ask the user whether to re-resume; never silently proceed or hard-block.
- Keep the marker under `workspace/threads/resume-locks/`; never add resume state to the handoff JSON or changeset sidecar, because they are immutable handoff records and can be archived.
- Always verify the live git branch with `git branch --show-current`; never trust the thread's recorded branch as current.
- This skill executes directly — no plan-mode detour.

## See also

- `/startwork` — resume the *latest* handoff (reads `handoff.json`) or pick a fresh company/project/repo.
- `/handoff` — writes the thread this skill resumes; its report prints the thread id to pass here.
- `/recover-session` — post-mortem triage of a crashed/wedged session (not normal resume).
