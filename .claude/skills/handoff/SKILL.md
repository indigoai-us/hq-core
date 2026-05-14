---
name: handoff
description: Prepare for a new session to continue this work. Minimal foreground — writes thread file, handoff.json, and HQ commit via handoff-finalize.sh; defers INDEX regen, /learn, document-release, and qmd reindex to handoff-post.sh (detached, headless). Designed to survive mid-handoff context compaction.
allowed-tools: Read, Write, Edit, Grep, Glob, Bash(git:*), Bash(bash:*), Bash(nohup:*), Bash(jq:*), Bash(date:*), Bash(mkdir:*), Bash(cat:*), Bash(rm:*)
---

# Fresh Session Continuity

Write a thread file + `handoff.json` with minimal foreground token cost, then defer the heavyweight work (INDEX regen, /learn, /document-release, qmd) to a detached post-script that gets its own fresh context for each headless Claude call.

**Why the split:** handoff used to chain 4+ heavy sub-skills (/learn → INDEX regen → document-release → qmd) in the foreground, which re-ingested ~200KB of INDEX.md and 51KB policy digest — enough to trigger mid-handoff autocompact and corrupt the thread write. This skill keeps the foreground at <15K tokens of tool output. If the session dies after `handoff.json` is written, next session self-heals via `/startwork`.

**User's message (optional):** $ARGUMENTS

## Process

### 1. Launch concurrent bg git commit for knowledge repos

```bash
nohup bash -c '
for symlink in core/knowledge/public/* core/knowledge/private/* personal/knowledge/* companies/*/knowledge; do
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

Write the array to `/tmp/handoff-learnings-$$.json` (shell expands `$$` to the PID). Empty array is fine. **Do not call `/learn` here — `handoff-post.sh` dispatches it headless.**

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
 "indexes_regen":true,"qmd_pid":"12345","git_bg_errors":""}
```

**Capture `thread_path` from the result** — you need it for Step 4. Keep `changeset_path`, `committed_paths`, `skipped_paths`, and `baseline_noise_count` for the final report.

### 4. Launch handoff-post.sh detached (heavy work, fresh contexts)

```bash
nohup bash core/scripts/handoff-post.sh \
  "{thread_path from Step 3}" \
  "/tmp/handoff-learnings-$$.json" \
  > /tmp/handoff-post.log 2>&1 &
```

`handoff-post.sh` runs detached and:
1. Archives threads older than 60 days into `workspace/threads/archive/YYYY-MM/` (gated once per 24h)
2. Regenerates INDEX files again (captures any archive moves)
3. Dispatches `/learn` in a fresh headless `codex exec` session — learnings get processed without touching this foreground context
4. Dispatches `/document-release` headless if `files_touched` includes `companies/` or `repos/` paths
5. Launches qmd reindex (qmd cleanup/update/embed)

Logs land at `/tmp/handoff-post.log`, `/tmp/handoff-learn.log`, `/tmp/handoff-docrelease.log`, `/tmp/qmd-handoff.log`. If the session dies while the post-script runs, the script keeps going — `handoff.json` is already valid.

### 5. Detect active pipelines (cheap, keep in foreground)

```bash
for sf in workspace/orchestrator/_pipeline/*/pipeline-state.json; do
  [ -f "$sf" ] || continue
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
  - /learn (headless) → /tmp/handoff-learn.log (if learnings captured)
  - /document-release (headless, if scope matched) → /tmp/handoff-docrelease.log
  - qmd reindex → /tmp/qmd-handoff.log

To continue in a fresh session:
  1. Start a new session
  2. Run: /startwork (it will find workspace/threads/handoff.json)

If `git_bg_errors` was non-empty, append:
⚠ Knowledge repo git errors: {git_bg_errors}
```

## Thread vs Checkpoint

Threads (current format) carry richer context: git state, worker state, learnings, searchability. Legacy checkpoints in `workspace/checkpoints/` still work but aren't written by this skill.

## Why Fresh Sessions

Fresh context = no accumulated noise, clean slate for complex tasks, follows Ralph methodology (fresh agent per task). Use handoff when a session has been running a while, you're switching task types, or you want cleaner separation between work chunks.

## Rules

- **Never invoke `/learn` or `/document-release` in the foreground** — both are dispatched headless by `handoff-post.sh`. Invoking them here is the original bug that caused double-compaction.
- **Do not Read INDEX.md files** — they're regenerated by bash scripts that pipe metadata through `jq -s`. Reading them into Claude's context defeats the whole point.
- **Always use `handoff-finalize.sh` for thread + commit + INDEX regen** — don't narrate individual steps, don't inline jq commands.
- **Changeset owns scope** — when HQ root status is noisy, scope comes from `--files-touched-json` and the generated changeset, not from whole-repo `git status`.
- **Context diet** — this skill should emit <15K tokens of tool output on a typical session. If you find yourself Reading more than 3 files, stop and rethink.
- **Session handoffs execute directly** — skip any planning-mode detour.
- **Commit flow** — knowledge repo commits run in bg (Step 1), HQ commit runs inside `handoff-finalize.sh` via explicit paths. Never `git add -A` from this skill.
