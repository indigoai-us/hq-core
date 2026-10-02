---
name: handoff
description: Preserve session state for a follow-up agent with handoff files and commits.
model: sonnet
effort: low
allowed-tools: Read, Write, Edit, Grep, Glob, Bash(git:*), Bash(bash:*), Bash(jq:*), Bash(date:*), Bash(mkdir:*), Bash(cat:*), Bash(rm:*), Bash(.claude/skills/_shared/journal.sh:*), Bash(bash core/scripts/handoff-open-steps.sh:*), Bash(bash core/scripts/handoff-knowledge-commit.sh:*), Bash(core/scripts/handoff-finalize.sh:*), Bash(bash core/scripts/hq-detach.sh:*), Bash, AskUserQuestion, Task, Agent, Skill
---

# Fresh Session Continuity

Write a thread file + `handoff.json` with minimal foreground token cost. Keep shell-only cleanup in a detached post-script, and run model-based follow-ups (`/learn`, `/document-release`) through the current runtime's visible delegation capability, with a synchronous Skill fallback after the handoff is durable.

**Why the split:** handoff used to chain 4+ heavy sub-skills (/learn → INDEX regen → document-release → qmd) in the foreground, which re-ingested ~200KB of INDEX.md and large policy bodies — enough to trigger mid-handoff autocompact and corrupt the thread write. Detached shell cleanup keeps logs tiny; visible runtime delegation keeps model work isolated without hidden `claude -p` auth failures. If the session dies after `handoff.json` is written, next session self-heals via `/startwork`.

**User's message (optional):** $ARGUMENTS

## Process

### 1. Commit only session-scoped personal/core knowledge changes

Before saving knowledge, write the exact relative paths intentionally changed by this session into a unique JSON changeset file. Do not scan repository status to expand this list. Use the same changeset file in Step 3.

```bash
mkdir -p workspace/threads/.handoff-tmp
CHANGESET_TMP=$(mktemp workspace/threads/.handoff-tmp/.handoff-changeset-XXXXXX)
cat > "$CHANGESET_TMP" <<'CHANGESET_JSON'
["core/knowledge/public/<repo>/<file-you-changed>"]
CHANGESET_JSON
bash core/scripts/handoff-knowledge-commit.sh --files-touched-json-file "$CHANGESET_TMP"
```

Include only files this session intentionally changed. The helper commits only listed files inside personal/core knowledge repositories and leaves unrelated staged or dirty files untouched. It does not process company knowledge, which remains a plain synced directory.

### 2. Collect learnings (do NOT invoke /learn)

Reflect on the session and build a JSON array of operational learnings — mistakes that cost time, unexpected behaviors, patterns that worked, user corrections. If nothing novel, use `[]`.

Format:
```json
[
  {"type": "rule", "content": "NEVER: ...", "scope": "global", "source": "session-learning"},
  {"type": "rule", "content": "ALWAYS: ...", "scope": "company:{co}", "source": "session-learning"}
]
```

Choose one concrete learnings file path, such as `/tmp/handoff-learnings-{short-slug}.json`, write the array there, and retain the same serialized array as `{learnings_json}`. Reuse the exact path in Steps 4 and 4.5. Empty array is fine. **Do not call `/learn` here — Step 4.5 dispatches it after the learning array is durable.**

### 2.2 Capture signal and entity candidates (opt-in companies only)

If the bound company has `signals_capture` or `ontology_capture` on
(`core/scripts/knowledge-prefs.sh get {co} <field>`), follow
`.claude/skills/_shared/session-close-capture.md`: from the summary you are
about to pass to `handoff-finalize.sh`, write up to 15 candidates — decisions,
commitments, risks, open questions, action items, and the people / projects /
companies they name — with `core/scripts/ontology-candidate.sh`, source ref
`handoff:{thread_id}`. Both switches off: skip silently. Fail-soft.

### 2.5 Close active session journal (if any)

Spec: `core/knowledge/public/hq-core/journal-spec.md`. If a journal was opened earlier in this session by `/brainstorm`, `/deep-plan`, `/prd`, or `/plan`, close it now so its frontmatter records `status: closed` + a one-line summary.

```bash
.claude/skills/_shared/journal.sh close "{project_dir}" "{one-line synthesis of session, ≤120 chars}"
```

Pass the resolved project directory that owns this session's journal. The helper is fail-soft (no-op if no owned active journal pointer exists). The summary should mirror what you write into `--summary` for `handoff-finalize.sh`. Helper clears only this session's pointer on success.

### 3. Call handoff-finalize.sh (synchronous, one tool call)

`core/scripts/handoff-finalize.sh` handles everything that must be durable before session end:
- Receives the same explicit session changeset used by the knowledge commit helper (Step 1)
- Writes thread file + `handoff.json` + `workspace/threads/{thread}.changeset.json`
- Regenerates thread INDEX + recent.md + orchestrator INDEX via dedicated bash scripts (`rebuild-threads-index.sh`, `rebuild-orchestrator-index.sh`) — zero Claude context
- Commits HQ via explicit paths: thread/index files plus the validated `--files-touched-json` paths (never `git add -A`)
- Classifies noisy HQ root status via `hq core hq-status-summary` so baseline local files do not become accidental handoff scope
- Schedules ownership-aware qmd reindex via `qmd-reindex-bg.sh` (shared with post): agent boxes hard-skip (`skipped-agent`, zero qmd mutation — managed timer/post-sync own freshness); laptops use one non-blocking single-flight cleanup→update→embed

Reuse the `CHANGESET_TMP` file prepared in Step 1 and pass its path — never inline the changeset into `--files-touched-json`. On Windows Git Bash the OS caps a command line at ~32KB (~8KB under cmd.exe), and a large changeset rides argv through several hops (status-summary, jq) and aborts the handoff. The file form keeps it off argv. This mirrors the learnings temp-file pattern from Step 2. Use `mktemp` under `workspace/threads/.handoff-tmp/` (gitignored, exists on Git Bash — do **not** use `/tmp`, which some Windows setups lack; do **not** use a slug-only deterministic path under `workspace/threads/` — concurrent sessions collide and unignored temps flip `git.dirty`). Clean it up whether the finalizer succeeds or fails, and propagate a non-zero finalize exit status:

```bash
rc=0
core/scripts/handoff-finalize.sh \
  --title "Handoff: {one-line title}" \
  --summary "{one-paragraph summary of what changed}" \
  --message "{user's handoff message, or echo of the summary}" \
  --next-steps-json '[{"...json array of next steps..."}]' \
  --files-touched-json-file "$CHANGESET_TMP" \
  --learnings-json '{learnings_json from Step 2}' \
  --tags-json '["handoff","{co}","{topic}"]' \
  --slug "{short-hyphenated-slug}" || rc=$?
rm -f "$CHANGESET_TMP"   # clean up on both success and failure
[ "$rc" -eq 0 ] || { echo "handoff-finalize failed (rc=$rc)" >&2; exit "$rc"; }
```

Every next step is stored with an `id` (`<thread_id>#<n>`) and `status: open`.
Before writing the new thread's next steps, close the ones this session actually
finished so they stop being copied forward:

```bash
bash core/scripts/handoff-open-steps.sh list                    # what is still open across recent handoffs
bash core/scripts/handoff-open-steps.sh close <step-id> --note "<what closed it>"
```

The script also copies the next-step command to the user's clipboard (fail-soft; pbcopy/wl-copy/xclip). Default is `/resumework {thread_id}`. If a different command is the right continuation, pass it explicitly via `--next-command "{command}"`.

The inline `--files-touched-json '[...]'` flag still works for small changesets and older callers, but the file form above is the default because it is the only one that survives a large untracked tree on Windows.

`--files-touched-json-file` (or the inline `--files-touched-json`) is the session changeset boundary. Pass precise paths for files/directories intentionally changed this session. It may be an array of strings or objects:

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
 "hq_commit_status":"committed","hq_commit_error":"",
 "committed_paths":["..."],"stage_failures":[],"skipped_paths":[],
 "baseline_noise_count":123,
 "indexes_regen":true,"qmd_pid":"12345","git_bg_errors":"",
 "next_command":"/resumework T-...","clipboard_copied":true}
```

`qmd_pid` may be a worker PID on laptops, or the tokens `skipped-agent` / `skipped` (or empty when HOME is unset / helper missing). Busy and dedupe are quiet inside the worker after a PID was already printed; they must never be reported as a successful agent reindex.

**Capture `thread_path` from the result** — you need it for Step 4. Keep `changeset_path`, `committed_paths`, `skipped_paths`, and `baseline_noise_count` for the final report.

`hq_commit_status` says why `hq_committed` is what it is: `committed`, `nothing-to-commit`, `failed` (git refused the commit), or `stage-failed` (`git add` rejected paths — the shape a held `.git/index.lock` takes, where no commit is even attempted). Both failure states exit **4** after printing the payload, with git's message in `hq_commit_error` and the unstageable paths in `stage_failures`. Treat exit 4 as a hard stop — the thread files exist on disk but are uncommitted, so tell the user the handoff did not complete, surface the git error, and do not proceed to Step 4.

### 4. Launch handoff-post.sh detached (mechanical cleanup only)

```bash
bash core/scripts/hq-detach.sh --handoff --pidfile /tmp/handoff-post.pid --logfile /tmp/handoff-post.log -- \
  bash core/scripts/handoff-post.sh \
  "{thread_path from Step 3}" \
  "{learnings_file path from Step 2}"
```

`handoff-post.sh` runs detached and:
1. Archives threads older than 60 days into `workspace/threads/archive/YYYY-MM/` (gated once per 24h)
2. Regenerates INDEX files again (captures any archive moves)
3. Records eligible learn/doc-release work as pending until the handoff reports dispatch proof
4. Schedules the same ownership-aware helper as finalize (`qmd-reindex-bg.sh`). On agent boxes both paths return `skipped-agent` and never start qmd or the managed indexer. On laptops, if a finalize-spawned worker already holds the single-flight lock (or just finished within the helper dedupe window), this is a quiet no-op — not a second independent writer

Logs land at `/tmp/handoff-post.log` and `/tmp/qmd-handoff.log`. If the session dies while the post-script runs, the script keeps going — `handoff.json` is already valid.

### 4.5 Dispatch runtime-appropriate model follow-ups

Only begin this step after `handoff-finalize.sh` succeeds: `{learnings_json}` is now stored in `{thread_path}` and is recoverable even if every execution route fails. Do **not** call `claude -p` or `codex exec`, and do **not** run model work from `handoff-post.sh`.

Run applicable follow-ups sequentially in this order: `/learn` first, then `/document-release`; wait for each result before starting the next. Before dispatch, tell the user a rough expected duration for the applicable work by estimating each follow-up and adding the estimates. Label it as an estimate, not a promise.

Before dispatching document-release, resolve its availability once for this session with `bash core/scripts/skill-installed.sh document-release "${HQ_ACTIVE_COMPANY:-}"`. Use the bound active company from `HQ_ACTIVE_COMPANY`; do not derive the skill scope from `.metadata.company`, which may describe a touched tenant. When no company is bound, the check searches root and package skills only. Only when document-release is installed may a document-release follow-up use a dispatch route or appear in the recovery warning. If the check reports that it is absent, do not invoke it and record `document-release: skipped (skill not installed)` in the follow-up outcomes.

For each applicable follow-up, use the first capability available in this order:

1. **Codex:** when `spawn_agent` (and `wait_agent`) is available, call `spawn_agent` and wait for its result. This is visible delegation.
2. **Claude Code:** otherwise, when the visible `Task` or `Agent` mechanism is available, launch the follow-up through that mechanism and wait for its result.
3. **Last fallback:** otherwise, or when the visible dispatch returns an error or no completion proof, invoke the corresponding `Skill` tool **synchronously** in this parent after finalization.

Treat a follow-up as applied only when its agent/task/Skill result confirms completion. A launched ID alone is not proof. Keep it as durably pending when all available routes fail or no route exists.

Use this prompt for each learnings follow-up when `{learnings_json}` contains any array item:

```
Use the learn skill to process this JSON learnings array: {learnings_json}. Apply each item exactly as written, preserving scope and user corrections. Do not read INDEX.md. Commit only the files you change, if the repository rules require it. Return a concise summary of applied learnings, skipped items, and changed files.
```

Use this prompt for each document-release follow-up when `{thread_path}` has any `files_touched` entry under `companies/` or `repos/` and the installed-skill check passed:

```
Use the document-release skill for the handoff thread at {thread_path}. Update release/docs indexes only where warranted by the touched files. Do not read unrelated company knowledge. Commit only the files you change, if the repository rules require it. Return a concise summary of changes, skipped work, and changed files.
```

For synchronous fallback, invoke `Skill` with `/learn {learnings_json}` or `/document-release {thread_path}` as applicable. Do not call `claude -p`.

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

Chat report follows the active output style (`core/policies/hq-audience-mode.md`). Files this skill writes stay full prose. The templates below are chat-only.

**Default (`HQ`, and any style that is not `hq-operator`):** one or two short plain sentences. Do not print Scope, Dedup, Action, file paths, thread IDs, or PIDs. Do not paste the operator template.

- Clipboard copied: `All saved. To pick up later, open a new chat and paste what's on your clipboard.`
- Clipboard not copied: `All saved. To pick up later, open a new chat and run {next_command}.`
- Active pipelines: add one plain sentence that some work is still running and a new chat can pick it up.
- `git_bg_errors` non-empty: add one plain sentence that one knowledge folder did not save, and they can ask you to retry. No raw git dump.

If any eligible follow-up is still uncompleted after the synchronous Skill fallback, put this warning first (Auto-Clarity — the person must run a command). In the default style, lead with one plain sentence that something still needs finishing, then the recovery commands. Include the document-release recovery entry and its `Run exactly:` line only when the same installed-skill check above passed. If the skill is absent, record `document-release: skipped (skill not installed)` and omit the document-release recovery entry and command:

```
WARN: Follow-up recovery required
- Learnings: {learning_count} item(s) are durably pending in thread {thread_id} at {thread_path}.
  Run exactly: /learn {learnings_json}
- Documentation: release follow-up is pending for thread {thread_id} at {thread_path}.
  Run exactly: /document-release {thread_path}
```

**Operator (`/output-style hq-operator`):**

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
  - handoff-post.sh PID {from /tmp/handoff-post.pid} → /tmp/handoff-post.log
  - /learn → {Codex spawn_agent | Claude Task/Agent | synchronous Skill | durably pending}
  - /document-release → {Codex spawn_agent | Claude Task/Agent | synchronous Skill | durably pending | document-release: skipped (skill not installed)}
  - qmd helper (`skipped-agent` | `skipped` | worker pid) → /tmp/qmd-handoff.log

To continue in a fresh session:
  1. Start a new session
  2. Run: {next_command} — already copied to your clipboard, just paste
     (resumes THIS handoff exactly; or /startwork to resume the latest
     handoff / pick a new target)

If `clipboard_copied` was false, drop the "already copied" phrasing and just show the command.

If `git_bg_errors` was non-empty, append:
⚠ Personal/core knowledge repo git errors: {git_bg_errors}
```

If recovery is still needed in operator mode, put the same `WARN: Follow-up recovery required` block at the top (before `Handoff ready.`), substituting actual values and including only applicable commands.

## Thread vs Checkpoint

Threads (current format) carry richer context: git state, worker state, learnings, searchability. Legacy checkpoints in `workspace/checkpoints/` still work but aren't written by this skill.

## Why Fresh Sessions

Fresh context = no accumulated noise, clean slate for complex tasks, follows Ralph methodology (fresh agent per task). Use handoff when a session has been running a while, you're switching task types, or you want cleaner separation between work chunks.

## Rules

- **Use visible dispatch first, then synchronous Skill only as a last fallback** — `spawn_agent` is preferred in Codex; `Task`/`Agent` is preferred in Claude Code. The parent may invoke `Skill` only after finalization and only when visible dispatch is unavailable or unconfirmed.
- **Never call `claude -p` from handoff** — unconfirmed follow-up work remains durable in the handoff thread and must emit the Step 6 recovery warning, never silently skip.
- **Do not Read INDEX.md files** — they're regenerated by bash scripts that pipe metadata through `jq -s`. Reading them into Claude's context defeats the whole point.
- **Always use `handoff-finalize.sh` for thread + commit + INDEX regen** — don't narrate individual steps, don't inline jq commands.
- **Changeset owns scope** — when HQ root status is noisy, scope comes from `--files-touched-json` and the generated changeset, not from whole-repo `git status`.
- **Context diet** — this skill should emit <15K tokens of tool output on a typical session. If you find yourself Reading more than 3 files, stop and rethink.
- **Session handoffs execute directly** — skip any planning-mode detour.
- **Commit flow:** personal/core knowledge repos commit only the explicit session changeset through `handoff-knowledge-commit.sh` (Step 1), company knowledge syncs through its vault, and `handoff-finalize.sh` commits the HQ changes using explicit paths. Never `git add -A` from this skill.

## See also

- `/resumework {thread_id}` — resume THIS thread exactly in a fresh session (takes the thread id this skill prints)
- `/startwork` — the follow-up agent resumes the latest handoff, or picks a new company/project/repo
- `/checkpoint` — a lighter mid-session save
- `/delegate` — hand the project to ANOTHER person or fleet agent (ownership transfer + verified access + pickup DM), rather than to your own next session
