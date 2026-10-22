---
name: checkpoint
description: Save a lightweight session checkpoint.
allowed-tools: Write, Bash, Read, Bash(bash core/scripts/checkpoint-recent-auto.sh:*), Bash(bash core/scripts/checkpoint-knowledge-repos.sh:*)
---

# /checkpoint - Save Progress

Save current work state as a thread to survive context loss.

**Task ID (optional):** $ARGUMENTS

## Process

0. **Capture session learnings**
   Reflect on this session. If any reusable learnings exist (mistakes, patterns, gotchas, workflow improvements), call `/learn` for each before proceeding. Skip if nothing novel was learned. See CLAUDE.md `## Session Learnings` for guidance.

0c. **Extract session insights (lightweight)**
    Same as /handoff step 0c but briefer — max 2 insights.
    Skip if session just started or no explanatory content generated.
    Call `/learn` with source: "session-insight" for each.

0d. **Capture signal and entity candidates (opt-in companies only)**
    If the bound company has `signals_capture` or `ontology_capture` on
    (`core/scripts/knowledge-prefs.sh get {co} <field>`), follow
    `.claude/skills/_shared/session-close-capture.md` and write up to 10
    candidates from this checkpoint's conversation summary with
    `core/scripts/ontology-candidate.sh`, source ref `checkpoint:{thread_id}`.
    Both switches off: skip silently. Fail-soft.

**Never search `workspace/` with an unbounded `find`** (no `-maxdepth`) while checkpointing. `workspace/worktrees/` holds full repo checkouts, so such a scan can run for many minutes and outlive the session as an orphan. Use the helpers named in each step; they already know where checkpoints and journal pointers live.

1. **Check for recent auto-checkpoint** (upgrade instead of duplicate)
   ```bash
   # Newest auto-checkpoint from the last 5 minutes (top level of workspace/threads only, time-bounded)
   bash core/scripts/checkpoint-recent-auto.sh "$PWD" 5
   ```
   If found: upgrade that file in-place (add full fields: `initial_commit`, `commits_made`, `remote_url`, `knowledge_repos`, `worker`, `next_steps`; change `type` to `"checkpoint"`; rename file to remove `-auto-`). Then continue from step 7 (INDEX updates).

2. **Generate thread ID** if not provided
   - Format: `T-{YYYYMMDD}-{HHMMSS}-{slug}`
   - Derive slug from recent work (e.g., `mrr-report`, `email-fix`)

3. **Capture git state**
   ```bash
   git rev-parse --abbrev-ref HEAD          # branch
   git remote get-url origin 2>/dev/null    # remote
   git rev-parse --short HEAD               # current commit
   git log --oneline -5                     # recent commits
   git diff --name-only HEAD~3              # recently touched files
   git status --porcelain                   # dirty check
   ```

4. **Capture personal/core knowledge repo git states**
   Personal knowledge folders may contain embedded Git repositories at their canonical real-directory paths. Company knowledge is a plain directory synced through the company vault. Continue detecting legacy symlinks only so they can be reported for migration; do not inspect company knowledge for embedded Git state:
   ```bash
   # Works from bash or zsh: the scan is a bash script, so no bash-only syntax runs in your shell.
   bash core/scripts/checkpoint-knowledge-repos.sh "$PWD"
   ```
   Include dirty personal/core knowledge repos in the thread JSON under `git.knowledge_repos`.

5. **Gather session state**
   - Summarize what was accomplished
   - List files touched
   - Identify next steps

5.5. **Close active session journal** (if any)
   Spec: `core/knowledge/public/hq-core/journal-spec.md`. If a journal was opened earlier in this session by `/brainstorm`, `/deep-plan`, or `/prd`, close it now:
   ```bash
   .claude/skills/_shared/journal.sh close "{project_dir}" "{one-line synthesis, ≤120 chars}"
   ```
   Pass the resolved project directory that owns this session's journal. Fail-soft: no-op if no owned active journal pointer exists. To check for one, run `.claude/skills/_shared/journal.sh path` (prints the path, or exits 1 when there is none); do not hunt for journal files under `workspace/`. Use the same one-line summary you used for `conversation_summary` below.

6. **Write thread** to `workspace/threads/{thread_id}.json` (include knowledge_repos from step 3):
   ```json
   {
     "thread_id": "T-20260123-143052-mrr-report",
     "version": 1,
     "created_at": "ISO8601",
     "updated_at": "ISO8601",

     "workspace_root": "~/",
     "cwd": "current/working/dir",

     "git": {
       "branch": "main",
       "remote_url": "git@github.com:...",
       "initial_commit": "abc1234",
       "current_commit": "def5678",
       "commits_made": ["hash: message"],
       "dirty": false,
       "knowledge_repos": {
         "knowledge-{company}": {"commit": "abc1234", "dirty": true},
         "knowledge-ralph": {"commit": "def5678", "dirty": false}
       }
     },

     "worker": {
       "id": "worker-id or null",
       "skill": "skill-name or null",
       "state": "completed"
     },

     "conversation_summary": "1-2 sentence summary",
     "files_touched": ["relative/paths"],
     "next_steps": ["remaining tasks"],

     "metadata": {
       "title": "Human-readable title",
       "tags": ["searchable", "tags"]
     }
   }
   ```

7. **Also write legacy checkpoint** to `workspace/checkpoints/{task-id}.json` for backward compat

8. **Update INDEX files and recent threads**
   - Update `workspace/threads/recent.md` with last 15 threads (table format)
   - Update `INDEX.md` timestamp only (do NOT regenerate full content — it's now slim)
   - Regenerate `workspace/threads/INDEX.md` (all threads, full table)
   - Check files_touched for any `companies/*/knowledge/` paths — if found, regenerate that company's `knowledge/INDEX.md`
   - See `core/knowledge/public/hq-core/index-md-spec.md` for INDEX format

8b. **Document release**
    Check the installed session catalog with `bash core/scripts/skill-installed.sh document-release "${HQ_ACTIVE_COMPANY:-}"`.
    If the skill is installed, run `/document-release` — the skill resolves company + project context on its own.
    If it is absent, skip this step silently. Best-effort — skip silently on failure.

9. **Report**
   Chat report follows the active output style (`core/policies/hq-audience-mode.md`). Files this skill writes stay full prose. The templates below are chat-only.

   **Default (`HQ`, and any style that is not `hq-operator`):** one or two short plain sentences. Do not print Scope, Dedup, Action, file paths, thread IDs, or PIDs. Do not paste the operator template.

   When trusted command-report details context is present, lead with a short plain-language summary. Put useful, non-sensitive diagnostics in a collapsed `Technical details` section. Without that context, keep the summary-only format.

   When trusted context is absent (for example, a routed natural-language or programmatic invocation), check the flag at report time with `HQ_CLI_BIN="$(command -v hq 2>/dev/null || true)" node .claude/hooks/command-report-details-flag.cjs`. Use expanded details only when it prints `true`; otherwise keep the summary-only format. This gate never overrides `hq-operator` style.

   `Progress saved. Keep going here, or open a new chat later and I'll pick this up.`

   **Operator (`/output-style hq-operator`):**
   ```
   Thread saved: workspace/threads/{thread_id}.json

   Summary: {summary}
   Git: {branch} @ {commit} ({dirty ? "dirty" : "clean"})
   Files: {count} files touched
   Next: {next_steps or "Work complete"}

   To hand off to fresh session: /handoff
   ```

## Thread vs Checkpoint

| Feature | Thread (new) | Checkpoint (legacy) |
|---------|--------------|---------------------|
| Git context | Full (branch, commits, dirty) | Minimal |
| Worker state | Captured | Not captured |
| Location | workspace/threads/ | workspace/checkpoints/ |
| Format | Rich JSON | Simple JSON |

## Notes

- Threads ensure work survives context clears
- Run frequently during long sessions
- Threads are searchable via `/search`

## See also

- `/handoff` — a full continuation package
- `/journal` — durable working memory
