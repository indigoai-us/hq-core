---
id: hq-cmd-handoff-execution-integrity
title: /handoff execution integrity — must complete, never re-probe, defer heavy work post-script
scope: command
trigger: "/handoff invocation, especially Step 7 (handoff.json write) and any caller of core/scripts/handoff-finalize.sh"
enforcement: soft
created: 2026-04-28
supersedes: hq-cmd-handoff-must-complete, hq-cmd-handoff-no-discovery-rerun, hq-cmd-handoff-defer-heavy-post-script
public: true
---

## Rule

`/handoff` is the LAST thing a session does. It must survive the worst-case context state, complete every step, and never destroy the artifact it just produced. Three hard rules govern the execution flow.

### A. Must complete every step — verify the handoff.json pointer

When the user requests `/handoff`, the skill MUST complete every step without fail. Never report handoff as done while any step is incomplete.

**Never pause mid-handoff to ask the user for permission, status confirmation, or direction.** Once `/handoff` starts, drive the skill through every step autonomously — even after context compaction or tool-permission errors. Retry failed tool calls; resume the skill at the correct step after a compaction break; surface problems in the final Step 8 report, not as blocking mid-flight questions. The only mid-flight pauses allowed are the interactive questions the skill explicitly prescribes (e.g. Step 0b's knowledge-update picker). A status check from the user ("status?") does not imply permission was required — keep going unless the user explicitly says stop.

**Specifically at Step 7 (write `workspace/threads/handoff.json`):**

1. After the Write tool returns success, Read `workspace/threads/handoff.json` back and confirm `last_thread` matches the current session's `thread_id`.
2. If the Write failed with "File has been modified since read" or any other error, retry: Read the file again, then Write with the new content. Repeat until the write succeeds and verification passes.
3. Do NOT rely on "the git commit looked successful" as proof — `git add -A && git commit` may capture adjacent changes (recent.md, thread file) while `handoff.json` silently stayed stale. The commit message and diff stats can look identical whether or not `handoff.json` was actually updated.
4. Only after verification passes may the skill proceed to Step 8 and report "Handoff ready."

If any step (commit, INDEX update, qmd reindex launch, handoff.json write) cannot complete, surface the failure to the user in the Step 8 report — do not hide it.

### B. Never re-run handoff-finalize.sh as a probe — parse, don't rerun

NEVER invoke `core/scripts/handoff-finalize.sh` a second time (synchronously or in a backgrounded subshell) for the sole purpose of "discovering" the thread file path or handoff.json state. Every invocation of `handoff-finalize.sh`:

1. Writes a **new** thread file (derived from the arguments passed, which in a rerun are almost always empty/placeholder values).
2. **Overwrites** `workspace/threads/handoff.json` with the new run's fields.

A "discovery" rerun with empty fields therefore destroys the good handoff produced by the primary run — the committed handoff.json now points at a near-empty thread file with no summary, blockers, or next-step context.

**Correct pattern — parse the JSON line from captured stdout:**

The primary `handoff-finalize.sh` run prints a trailing JSON line:

```json
{"thread":"workspace/threads/T-YYYYMMDD-HHMMSS-slug.json","handoff":"workspace/threads/handoff.json","commit":"<sha>"}
```

When a downstream step (e.g. `scripts/handoff-bg-commit.sh`, a detached `/learn` run, or `handoff-post.sh`) needs the thread path, parse that JSON from the captured stdout — don't rerun:

```bash
# Capture once
FINALIZE_OUT=$(bash core/scripts/handoff-finalize.sh --summary "..." --next-steps "...")
THREAD_PATH=$(echo "$FINALIZE_OUT" | tail -1 | jq -r .thread)

# Pass THREAD_PATH into the background job
nohup bash core/scripts/handoff-post.sh "$THREAD_PATH" &
```

If the thread path is needed in a separate shell (no captured stdout), read `workspace/threads/handoff.json` directly — it is the durable pointer — and extract `thread_file` via `jq`. Still zero reruns.

If you catch yourself about to write `bash core/scripts/handoff-finalize.sh ... &` a second time in the same handoff chain, stop. Parse instead.

### C. Defer heavy work to detached post-script

NEVER invoke `/learn` or `/document-release` in the foreground of `/handoff`. Both skills re-ingest the full policy digest (~51KB) plus related context, and running them while the `/handoff` session is already near the autocompact threshold reliably triggers a mid-handoff compaction — which destroys the skill's state and leaves `handoff.json` / INDEX writes half-finished.

The correct pattern is:

1. `/handoff` foreground performs ONLY the minimal, compaction-survivable steps: commit pending changes, write the thread file, write `handoff.json`, verify the pointer (per Rule A), and kick off `core/scripts/handoff-finalize.sh` + `core/scripts/handoff-post.sh` as a detached background process.
2. `core/scripts/handoff-post.sh` runs OUTSIDE the session (via `nohup` / detached shell) and dispatches `/learn` and `/document-release` as fresh headless `claude -p` invocations — each with its own clean context window. The parent `/handoff` session finishes before these start.
3. Also defer INDEX regeneration and `qmd update` to `handoff-post.sh` when their inputs are large (see `hq-index-md-regenerate-via-shell` for the large-INDEX case). The foreground `/handoff` should not Read-then-Edit a 200KB+ INDEX.

If you catch yourself about to call `/learn` or `/document-release` from inside `/handoff` (directly, via Skill, or via sub-agent), STOP and route through `handoff-post.sh` instead.

## Rationale

**A (Must complete):** Discovered 2026-04-16 when a `/handoff` session reported success but left `handoff.json` pointing at the previous session's thread, because the Step 7 Write hit a stale-read error that was silently swallowed. The following startwork invocation would have resumed the wrong thread. Detected only when the user asked "did we finish /handoff" and manual inspection showed the pointer mismatch. The failure mode is hard to notice from inside the skill: `git commit` can succeed with 1-file/14-deletions stats that look exactly like a normal handoff commit, even though the deletion was only to `workspace/threads/recent.md` and `handoff.json` was untouched. Read-back verification is the only reliable proof.

**B (No discovery rerun):** During the 2026-04-21 onboarding domain deprecation handoff, a background-commit script was chained to a second `handoff-finalize.sh` invocation whose arguments were empty because the intent was "just tell me the thread path." The rerun successfully wrote a new (near-empty) thread file AND overwrote handoff.json with empty summary/blockers/next-steps, silently discarding the real handoff the primary call had just committed. Recovery required grepping the git log for the last good JSON and manually restoring handoff.json. Root cause: treating a side-effecting generator as a read-only query. The script's contract is "produce a handoff," not "tell me about one." This class of bug (re-invoking a side-effecting CLI as a probe) recurs anywhere a tool's stdout happens to contain useful identifiers — the fix is always the same: capture stdout once, parse downstream.

**C (Defer heavy work):** Discovered 2026-04-18 during the `T-20260418-161959-handoff-token-fix` session. A prior `/handoff` run invoked `/learn` in the foreground after writing the thread file; the policy-digest re-ingestion pushed the transcript past 75%, autocompact fired mid-handoff, and the surviving post-compact context could no longer find the skill state to finish Step 7 cleanly. `handoff.json` ended up stale and the `/document-release` pass never ran. The fix (commit `063616897`) moved both calls to `core/scripts/handoff-post.sh` as detached headless invocations, which succeed every time because each gets a fresh context budget.

The general principle threading all three rules: `/handoff` runs at the worst-case context state. Anything that reloads large corpora, re-executes side-effectful generators, or pauses for confirmation must move outside the session boundary.
