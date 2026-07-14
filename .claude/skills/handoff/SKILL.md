---
name: handoff
description: Preserve session state for a follow-up agent with handoff files and commits.
allowed-tools: Read, Write, Edit, Grep, Glob, Bash(git:*), Bash(bash:*), Bash(nohup:*), Bash(jq:*), Bash(date:*), Bash(mkdir:*), Bash(cat:*), Bash(rm:*), Bash, AskUserQuestion
---

# Fresh Session Continuity

Write a thread file + `handoff.json` with minimal foreground token cost. Keep shell-only cleanup in a detached post-script, and run model-based follow-ups (`/learn`, `/document-release`) as visible Codex subagents when the runtime supports subagents.

**Why the split:** handoff used to chain 4+ heavy sub-skills (/learn → INDEX regen → document-release → qmd) in the foreground, which re-ingested ~200KB of INDEX.md and large policy bodies — enough to trigger mid-handoff autocompact and corrupt the thread write. Detached shell cleanup keeps logs tiny; Codex subagents keep model work isolated without hidden `claude -p` auth failures. If the session dies after `handoff.json` is written, next session self-heals via `/startwork`.

**User's message (optional):** $ARGUMENTS

## Process

### 1. Launch concurrent bg git commit for knowledge repos

```bash
nohup bash -c '
for symlink in knowledge/public/* knowledge/private/* companies/*/knowledge; do
  [ -L "$symlink" ] || [ -d "$symlink/.git" ] || continue
  repo_dir=$(cd "$symlink" && git rev-parse --show-toplevel 2>/dev/null) || continue
  dirty=$(cd "$repo_dir" && git status --porcelain)
  [ -z "$dirty" ] && continue
  (cd "$repo_dir" && git add -A && git commit -m "checkpoint: auto-commit before handoff") \
    && echo "OK: $repo_dir" || echo "ERR: $repo_dir"
done
' > /tmp/handoff-git-bg.log 2>&1 &
echo $! > /tmp/handoff-git-bg.pid
```

### 2. Collect learnings (do NOT invoke /learn)

Reflect on the session and build a JSON array of operational learnings — mistakes that cost time, unexpected behaviors, patterns that worked, user corrections. If nothing novel, use `[]`.

Format:
```json
[
  {"type": "rule", "content": "NEVER: ...", "scope": "global", "source": "session-learning"},
  {"type": "rule", "content": "ALWAYS: ...", "scope": "company:{co}", "source": "session-learning"}
]
```

Choose one concrete learnings file path, such as `/tmp/handoff-learnings-{short-slug}.json`, write the array there, and reuse that exact path in Steps 4 and 4.5. Empty array is fine. **Do not call `/learn` here — Step 4.5 dispatches it through a visible Codex subagent when applicable.**

### 2.5 Close active session journal (if any)

Spec: `core/knowledge/public/hq-core/journal-spec.md`. If a journal was opened earlier in this session by `/brainstorm`, `/deep-plan`, `/prd`, or `/plan`, close it now so its frontmatter records `status: closed` + a one-line summary.

```bash
.claude/skills/_shared/journal.sh close "{one-line synthesis of session, ≤120 chars}"
```

The helper is fail-soft (no-op if no active journal pointer exists). The summary should mirror what you write into `--summary` for `handoff-finalize.sh`. Helper clears `.claude/state/active-journal` on success.

### 3. Call handoff-finalize.sh (synchronous, one tool call)

`core/scripts/handoff-finalize.sh` handles everything that must be durable before session end:
- Waits for bg git loop (Step 1)
- Writes thread file + `handoff.json` + `workspace/threads/{thread}.changeset.json`
- Regenerates thread INDEX + recent.md + orchestrator INDEX via dedicated bash scripts (`rebuild-threads-index.sh`, `rebuild-orchestrator-index.sh`) — zero Claude context
- Commits HQ via explicit paths: thread/index files plus the validated `--files-touched-json` paths (never `git add -A`)
- Classifies noisy HQ root status via `core/scripts/hq-status-summary.sh` so baseline local files do not become accidental handoff scope
- Launches qmd reindex fire-and-forget

Invoke with flags matching what this session accomplished:

```bash
core/scripts/handoff-finalize.sh \
  --title "Handoff: {one-line title}" \
  --summary "{one-paragraph summary of what changed}" \
  --message "{user's handoff message, or echo of the summary}" \
  --next-steps-json '[{"...json array of next steps..."}]' \
  --files-touched-json '[{"...json array of relative paths edited..."}]' \
  --learnings-json '[]' \
  --tags-json '["handoff","{co}","{topic}"]' \
  --slug "{short-hyphenated-slug}"
```

The script also copies the next-step command to the user's clipboard (fail-soft; pbcopy/wl-copy/xclip). Default is `/resumework {thread_id}`. If a different command is the right continuation, pass it explicitly via `--next-command "{command}"`.

`--files-touched-json` is the session changeset boundary. Pass precise paths for files/directories intentionally changed this session. It may be an array of strings or objects:

```json
[
  "core/scripts/handoff-finalize.sh",
  {"path":"docs/architecture.md","reason":"updated diagram for new flow"},
  {"path":"old/file.md","deleted":true,"reason":"removed obsolete file"}
]
```

Do not compensate for noisy root `git status` by passing broad parent directories unless the whole directory is intentionally in scope.

The script emits a single JSON line to stdout:
```json
{"thread_id":"T-...","thread_path":"workspace/threads/T-...json",
 "changeset_path":"workspace/threads/T-...changeset.json",
 "handoff_path":"workspace/threads/handoff.json","hq_committed":true,
 "committed_paths":["..."],"skipped_paths":[],"baseline_noise_count":123,
 "indexes_regen":true,"qmd_pid":"12345","git_bg_errors":"",
 "next_command":"/resumework T-...","clipboard_copied":true}
```

**Capture `thread_path` from the result** — you need it for Step 4. Keep `changeset_path`, `committed_paths`, `skipped_paths`, and `baseline_noise_count` for the final report.

### 4. Launch handoff-post.sh detached (mechanical cleanup only)

```bash
nohup bash core/scripts/handoff-post.sh \
  "{thread_path from Step 3}" \
  "{learnings_file path from Step 2}" \
  > /tmp/handoff-post.log 2>&1 &
```

`handoff-post.sh` runs detached and:
1. Archives threads older than 60 days into `workspace/threads/archive/YYYY-MM/` (gated once per 24h)
2. Regenerates INDEX files again (captures any archive moves)
3. Records whether learn/doc-release should be handled by Codex subagents
4. Launches qmd reindex (qmd cleanup/update/embed)

Logs land at `/tmp/handoff-post.log` and `/tmp/qmd-handoff.log`. If the session dies while the post-script runs, the script keeps going — `handoff.json` is already valid.

### 4.5 Dispatch Codex subagents for model follow-ups

In Codex, use `spawn_agent` for each applicable follow-up. These are visible subagents, not detached shell jobs. Start them after Step 4 so they run while the shell cleanup proceeds, then `wait_agent` before the final report. Do **not** call `claude -p`, `codex exec`, `/learn`, or `/document-release` from `handoff-post.sh`.

Spawn a learnings subagent if `{learnings_file path from Step 2}` contains any array item:

```
Use the learn skill to process the JSON learnings in {learnings_file}. Apply each item exactly as written, preserving scope and user corrections. Do not read INDEX.md. Commit only the files you change, if the repository rules require it. Return a concise summary of applied learnings, skipped items, and changed files.
```

Spawn a document-release subagent if `{thread_path}` has any `files_touched` entry under `companies/` or `repos/`:

```
Use the document-release skill for the handoff thread at {thread_path}. Update release/docs indexes only where warranted by the touched files. Do not read unrelated company knowledge. Commit only the files you change, if the repository rules require it. Return a concise summary of changes, skipped work, and changed files.
```

If Codex subagents are unavailable, report the follow-up as skipped in Step 6. Do not fall back to `claude -p`.

### 5. Detect active pipelines (cheap, keep in foreground)

```bash
# `find` (not a bare glob) so this no-ops cleanly when the dir/files are
# absent — zsh aborts a bare unmatched glob with "no matches found".
find workspace/orchestrator/_pipeline -mindepth 2 -maxdepth 2 \
  -name pipeline-state.json 2>/dev/null | while read -r sf; do
  status=$(jq -r '.status // ""' "$sf" 2>/dev/null)
  if [ "$status" = "in_progress" ] || [ "$status" = "paused" ]; then
    pipeline_id=$(jq -r '.pipeline_id' "$sf")
    company=$(jq -r '.company' "$sf")
    done_count=$(jq -r '.summary.done // 0' "$sf")
    total=$(jq -r '.summary.total // 0' "$sf")
    echo "Active pipeline: ${pipeline_id} (${company}) — ${done_count}/${total} done"
  fi
done
```

If any active pipelines surface, mention them in the report and suggest `core/scripts/run-pipeline.sh --resume {pipeline_id}`.

### 6. Report

```
Handoff ready.

Thread: {thread_id}
Summary: {conversation_summary}
Git: {branch} @ {commit}
Changeset: {changeset_path}
Committed paths: {committed_paths count}
Skipped paths: {skipped_paths count, if any}
Baseline noise: {baseline_noise_count} unrelated/baseline status entries

Background work dispatched:
  - handoff-post.sh PID {from nohup} → /tmp/handoff-post.log
  - /learn → Codex subagent {status or skipped reason}
  - /document-release → Codex subagent {status or skipped reason}
  - qmd reindex → /tmp/qmd-handoff.log

To continue in a fresh session:
  1. Start a new session
  2. Run: {next_command} — already copied to your clipboard, just paste
     (resumes THIS handoff exactly; or /startwork to resume the latest
     handoff / pick a new target)

If `clipboard_copied` was false, drop the "already copied" phrasing and just show the command.

If `git_bg_errors` was non-empty, append:
⚠ Knowledge repo git errors: {git_bg_errors}
```

## Thread vs Checkpoint

Threads (current format) carry richer context: git state, worker state, learnings, searchability. Legacy checkpoints in `workspace/checkpoints/` still work but aren't written by this skill.

## Why Fresh Sessions

Fresh context = no accumulated noise, clean slate for complex tasks, follows Ralph methodology (fresh agent per task). Use handoff when a session has been running a while, you're switching task types, or you want cleaner separation between work chunks.

## Rules

- **Never invoke `/learn` or `/document-release` in the parent foreground** — both must run in visible Codex subagents when available. Invoking them directly in the handoff parent is the original bug that caused double-compaction.
- **Never call `claude -p` from handoff** — Codex handoff model work uses Codex subagents. If subagents are unavailable, report the follow-up as skipped.
- **Do not Read INDEX.md files** — they're regenerated by bash scripts that pipe metadata through `jq -s`. Reading them into Claude's context defeats the whole point.
- **Always use `handoff-finalize.sh` for thread + commit + INDEX regen** — don't narrate individual steps, don't inline jq commands.
- **Changeset owns scope** — when HQ root status is noisy, scope comes from `--files-touched-json` and the generated changeset, not from whole-repo `git status`.
- **Context diet** — this skill should emit <15K tokens of tool output on a typical session. If you find yourself Reading more than 3 files, stop and rethink.
- **Session handoffs execute directly** — skip any planning-mode detour.
- **Commit flow** — knowledge repo commits run in bg (Step 1), HQ commit runs inside `handoff-finalize.sh` via explicit paths. Never `git add -A` from this skill.

## See also

- `/resumework {thread_id}` — resume THIS thread exactly in a fresh session (takes the thread id this skill prints)
- `/startwork` — the follow-up agent resumes the latest handoff, or picks a new company/project/repo
- `/checkpoint` — a lighter mid-session save
