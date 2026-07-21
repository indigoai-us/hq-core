---
name: startwork
description: Resolve current HQ context and surface useful next work options.
allowed-tools: Read, Grep, Glob, Bash(git:*), Bash(qmd:*), Bash(ls:*), Bash(core/scripts/hq-session.sh:*), Bash(core/scripts/work-mesh.sh:*), Bash(bash core/scripts/resume-thread-lock.sh:*), Bash, AskUserQuestion
---

# Start Work Session

Lightweight session entry point. Resolves context fast, presents smart options, gets you working.

## When to Use

Beginning of every session. Replaces ad-hoc orientation.

## Process

### 1. Resolve Argument

**1.0 Slash-command short-circuit (HARD RULE — check FIRST):**

If the argument contains a slash-command token (whitespace-delimited substring matching `/<name>` for any `<name>` that is a valid slash command in `.claude/commands/`), abort the normal classification flow and route to that command. Specifically:

- **`/deep-plan` token present** → STOP. Do not classify, do not enter Task Mode, do not pick a worker pipeline. Announce: *"`/deep-plan` detected in args — routing to deep-plan skill."* Then load `.claude/skills/deep-plan/SKILL.md` and execute it end-to-end with the remaining args (everything after `/deep-plan`) as the project description. The deep-plan skill produces `companies/{co}/projects/{name}/prd.json` + board entry and HARD STOPS at `/handoff`. Implementation MUST NOT happen in this session.
- **`/plan` token present** → route to `.claude/skills/plan/SKILL.md` similarly.
- **Other `/foo` tokens** → check `.claude/commands/foo.md`; if present, route to that command's skill (if any) or invoke the command directly.

This rule supersedes the classification table below. The reason it exists: prior failure where `/startwork {company} vyg /deep-plan apps/...` was treated as free-text task description, causing the agent to enter Claude Code's built-in plan mode and start implementing instead of running the deep-plan questionnaire. Policy: `core/policies/deep-plan-skill-routing.md`.

**1.1 Mode resolution** (only if no slash-command short-circuit fired):

Determine mode from the user's argument (first match wins):

- **No arg / empty** — Entry-gate mode (ask before loading context — see "Entry-Gate Mode" below)
- **Arg matches company slug** in `companies/manifest.yaml` — Company mode
- **Arg matches a directory** in `personal/projects/` (not `_archive/`) or `companies/*/projects/` — Project mode
- **Arg matches a directory** in `repos/private/` or `repos/public/` — Repo mode
- **Partial match** — arg is a substring of any company slug, project dir, or repo name. 1 match: use that mode. 2-5 matches: present numbered list, wait for user to pick. >5: ask user to be more specific
- **Free-text task** — arg is ≥3 words and doesn't match any company/project/repo/partial → Task mode
- **No match** — ask user to clarify

### 2. Gather Context

#### Entry-Gate Mode (no arg)

**Do NOT eager-load context.** A naked `/startwork` must ask the user where to go *before* reading the thread file, running the qmd/grep project scan, or reading any prd.json. Only the single cheap read in step 1 is permitted before the gate.

1. **Cheap peek only.** If `workspace/threads/handoff.json` exists, read it (small, allowed by context-diet) and extract only the last-session one-liner (its `summary` / `conversation_summary` field) + referenced branch. Do NOT read the thread file it points to yet. If handoff.json is absent, skip — no last-session option.

2. **Ask the user (AskUserQuestion), one question, then wait.** Present these options:
   - **Resume last session** — only if step 1 found a handoff; label it with the one-liner (e.g. *"Resume: {summary}"*).
   - **Pick a company / project / repo** — user names the target; you then re-enter this skill in the matching mode (Company / Project / Repo) with that arg.
   - **Not sure what to work on** — route to `/strategize` (strategic prioritization). Announce the handoff and load `.claude/skills/strategize/SKILL.md`. Do not do project discovery here.
   - **Something else** — free-text; user describes intent → treat as Task mode.

   Do not present numbered markdown for this gate — use the structured picker. This is the whole point of the gate: no `qmd search "prd.json"`, no thread-file read, no per-project prd.json reads happen until the user has chosen.

3. **After the pick, load only what that path needs:**
   - *Resume last session* → before reading the thread file, resolve `thread_id` from `handoff.json.last_thread` and apply the same resume-lock confirmation procedure from `/resumework` Step 2. Run `bash core/scripts/hq-session.sh current` to obtain the session id, then `bash core/scripts/resume-thread-lock.sh inspect "{thread_id}"`. On `unlocked`, acquire the marker with `bash core/scripts/resume-thread-lock.sh acquire "{thread_id}" --session-id "{session_id}"`. On `locked` or `stale`, use AskUserQuestion with the returned `prompt` and stop on cancel; only after **Re-resume anyway** run `bash core/scripts/resume-thread-lock.sh acquire "{thread_id}" --replace --expected-generation "{lock_generation from inspected JSON}" --session-id "{session_id}"`. If replacement exits `4`, re-inspect and ask again because a newer marker replaced the one the user confirmed. Then, and only then, read the thread file handoff.json points to (extract `conversation_summary`, `next_steps`, `git.branch`, `git.current_commit`, `git.dirty`, `files_touched`); run `git log --oneline -3`; if the thread references a `project_dir`, read its most-recent journal file (frontmatter + `## Open threads` only — see Project Mode step 4). Skip the global qmd/grep project scan unless the user then asks "what else is active?".
   - *Pick company/project/repo* → proceed via the corresponding mode's Gather Context section with the supplied arg.
   - *Not sure* → `/strategize` owns it from here; stop gathering.
   - *Something else* → Task Mode gather.

#### Company Mode (arg = company slug)

1. Read `companies/manifest.yaml` — extract the company's entry (repos, workers, knowledge, qmd_collections)
2. Read `workspace/threads/handoff.json` — if last thread relates to this company, note it
3. Search for company projects:
   - Primary: `qmd search "prd.json" --json -n 10` via shell
   - Fallback: `grep -rl '"passes"' personal/projects/ companies/ --include='prd.json'`
   - Filter to projects whose repoPath matches any of the company's repos. Count incomplete stories per project.
4. If company has repos, run `git -C {first-repo} log --oneline -3` and `git -C {first-repo} branch --show-current`
5. List the company's workers from manifest (names only, don't read worker.yaml files)

#### Project Mode (arg = project name)

1. Read `personal/projects/{name}/prd.json` or `companies/{co}/projects/{name}/prd.json` — extract: `name`, `description`, `branchName`, incomplete stories (where `passes !== true`) with id + title + priority
2. Extract `metadata.repoPath` — identify company by matching against manifest repos
3. If repoPath exists: `git -C {repoPath} branch --show-current` and `git -C {repoPath} status --short`
4. If company `{co}` is resolved, run `bash core/scripts/work-mesh.sh check --company {co} --project {name}`. Include any active owners, blockers, or in-progress threads in the orientation block. If the helper prints nothing or is unavailable, omit the line and continue. A local daemon may keep `workspace/work-mesh/live-cache.json` warm with `bash core/scripts/work-mesh.sh watch`; use that only as live context, not as a direct MQTT write path.
5. **Read session journals** (spec: `core/knowledge/public/hq-core/journal-spec.md`). If `{project_dir}/journal/` exists:
   - `ls -t {project_dir}/journal/*.md 2>/dev/null | head -2` — most recent 2 files
   - For each: read frontmatter (`status`, `summary`) + `## Open threads` section only — skip `## Auto-capture` (reference material, too noisy for orientation)
   - If most-recent file has `status: active` and mtime > 24h, treat as abandoned (visually flag in orientation block)
   - Surface in orientation: latest file's `summary` + any unresolved `## Open threads` bullets

#### Task Mode (arg = free-text task description)

1. Resolve company/repo from cwd or recent handoff context (read `workspace/threads/handoff.json` if exists)
2. Classify task using inline pattern table:
   - DB/migration/schema/prisma → `schema_change`
   - API/endpoint/route/webhook → `api_development`
   - Component/page/UI/form/React → `ui_component`
   - Backend + frontend indicators combined → `full_stack`
   - Content/copy/docs/marketing → `content`
   - Design/visual/brand → `design`
   - Deploy/CI/infra → `ops`
   - Otherwise → `enhancement`
3. Map to worker pipeline (same sequences as `/plan` command Step 5)
4. If company resolved, check company-specific workers in manifest — prefer over generic

#### Repo Mode (arg = repo directory name)

1. Resolve full path: check `repos/private/{arg}` then `repos/public/{arg}`
2. Git state: `git -C {repoPath} branch --show-current`, `git -C {repoPath} log --oneline -5`, `git -C {repoPath} status --short`
3. Owning company: scan `companies/manifest.yaml` for a company whose `repos:` list contains this path
4. Related projects:
   - Primary: `qmd search "{repo-name} prd.json" --json -n 10` via shell
   - Fallback: use Grep to find prd.json files referencing this repo
   - For each match (max 5), read the prd.json and extract `name` + count incomplete stories

### 2.4 Persist Session Metadata

Once company `{co}` is resolved (from any mode), write it into the current
session's metadata so per-company hooks and other context-aware skills can
find it:

```bash
bash core/scripts/hq-session.sh set company_slug "{co}"
# Optional, when applicable:
bash core/scripts/hq-session.sh set project "{project_name}"
bash core/scripts/hq-session.sh set repo    "{repo_name}"
bash core/scripts/hq-session.sh set mode    "{Resume|Company|Project|Repo|Task}"
```

This file lives at `workspace/sessions/<session_id>/meta.yaml`. The current
session_id is bootstrapped by `.claude/hooks/master-hook.sh` on the first
hook event of every session and tracked in `workspace/sessions/.current`.

**Important:** until `company_slug` is set, the master hook runs no
per-company hooks (fail-closed for tenant isolation). Setting it from
startwork is what activates the per-company harness for the rest of the
session.

**Skip if:** no company resolved (resume mode with no company context).

### 2.5 Load Applicable Policies

Once company `{co}` is resolved (from any mode):

1. **Company policies**: If `{co}` known, read frontmatter-only for each policy in `companies/{co}/policies/` via `bash core/scripts/read-policy-frontmatter.sh {file}` (skip `example-policy.md`). Note count + titles of any `enforcement: hard` rules. For hard-enforcement policies only, additionally read the `## Rule` section with targeted Read + range.
2. **Repo policies**: If repo context resolved, check `{repoPath}/.claude/policies/` (if dir exists). Same frontmatter-only pattern.
3. **Global policies**: Count files in `core/policies/`. On:[SessionStart] policies are already injected automatically by the SessionStart trigger hook (`inject-policy-on-trigger.sh`), so this step is largely a no-op. If you need more, filter to policies whose `when:`/`trigger` matches current context — don't load all.

Display in orientation block:
```
Policies: {N} company, {M} repo, {K} global ({H} hard-enforcement)
```

**Hard-enforcement policies** with triggers matching current context: list titles in orientation block so user sees constraints upfront.

Rules:
- Only READ policy frontmatter (title, enforcement, trigger) — don't load full body into context
- Exception: hard-enforcement policies — read full `## Rule` section
- If no company resolved (resume mode with no company context), skip company policies
- Precedence: company > repo > global

### 2.6 Worker Routing & Skill Readiness

After policies are known, build a compact Worker Packet for the resolved context.

1. Read `core/workers/registry.yaml` (auto-generated read-only index) once and keep only entries relevant to the current company, project, repo, or task intent.
2. If company `{co}` is resolved, include any registry entries whose `company:` field is `{co}` (sourced from `worker.company` in each `worker.yaml`) or whose path starts with `companies/{co}/workers/`.
3. If project mode and `prd.json` story metadata includes declared workers or worker hints, include those first.
4. If task mode, map the classified intent to a worker route before offering direct execution:
   - `design`, `ui_component` → design/frontend workers
   - `content` → content workers
   - `ops`, deploy/CI/infrastructure → ops/deploy workers
   - `api_development`, `schema_change`, `full_stack`, `enhancement` → implementation workers plus QA/review workers when available
5. Do not read every worker.yaml. Read a worker.yaml only when:
   - it is the selected/recommended worker, or
   - you need its skill list to present a concrete option.

Display in orientation block:
```
Worker route: {primary worker/skill or "none matched"} ({N} candidates)
```

Rules:
- Worker-backed paths should appear before direct parent-session execution whenever a relevant worker exists.
- Direct execution remains available, but label it as direct/no-worker so the user can make an informed choice.
- If no worker matches, say so and proceed normally.
- If the selected path needs worker execution, route through `/run {worker} {skill}` or `/execute-task` rather than reimplementing the worker inline.

### 2.7 Spawn Knowledge Pulse (Background)

Once `{co}` is resolved (from any mode except resume-with-no-company):

1. Read `companies/manifest.yaml` to resolve `knowledge` path and `qmd_collections` for `{co}`
2. If company has a knowledge directory (not `null` in manifest), spawn a background knowledge pulse:

```
spawn_task(
  reason: "Pulse-garden {co} knowledge",
  prompt: "Run the knowledge-pulse skill at .claude/skills/knowledge-pulse/SKILL.md.
    company_slug: {co}
    knowledge_path: companies/{co}/knowledge/
    policies_path: companies/{co}/policies/
    caller: startwork
    qmd_collection: {qmd_collections[0] from manifest, or omit if none}
    No search_results_summary or discovered_facts (startwork is read-only).
    Read the skill file for full instructions."
)
```

3. Do NOT wait for the pulse to complete — continue immediately to Step 3

**Skip if:** no company resolved (resume mode with no company context), or company has no knowledge directory.

### 3. Present Options

Display a concise orientation block:

```
Session Start
--------------
{Mode: Resume | Company: {slug} | Project: {name}}

{If resume: "Last session: {summary}" + "Next steps: {next_steps}"}
{If company: "Repos: {list}" + "Workers: {list}"}
{If project: "Goal: {description}" + "Branch: {branchName}"}
{If repo: "Repo: {repoPath}" + "Company: {slug}" + "Branch: {branch}"}
{If task: "Task: {description}" + "Intent: {classified_intent}" + "Pipeline: {worker count} workers"}

Git: {branch} @ {short-hash} {" (dirty)" if dirty}
Worker route: {primary worker/skill or "none matched"} ({N} candidates)
Knowledge pulse: {summary line from workspace/reports/knowledge-pulse/{co}-{today}.md if exists, e.g. "3 docs tagged, 2 flagged stale" — or omit line if no recent pulse}

Active work:
  - {project} -- {done}/{total} stories ({remaining} left)
  ...

Work mesh:
  {active mesh owners/blockers for the selected company/project, or omit if none/unavailable}
```

Then present numbered options built from context:

- **Entry-gate mode (no arg)**: no orientation block is rendered before the gate — the AskUserQuestion gate (Gather Context → Entry-Gate Mode step 2) *is* the first interaction. Render an orientation block only *after* the user picks "Resume last session", using the loaded thread context; then offer next_steps items (up to 3) + "Pick a project" + "Something else".
- **Company mode**: worker-recommended next actions + active projects for that company (up to 3) + "Run a worker" + "Something else"
- **Project mode**: top 3 incomplete stories by priority via `/execute-task` + matching worker route + "Something else"
- **Repo mode**: related projects with incomplete work (up to 3) + "Open repo (no project)" + "Something else"
- **Task mode**: proposed worker pipeline phases (up to 5) + "Run this worker pipeline" + "Modify pipeline" + "Do it directly (no worker)" + "Run /plan for full options" + "Something else"

Output the numbered list and wait for user input. After user picks, proceed directly into the work.

## Rules

- NEVER read INDEX.md, agents files, or company knowledge dirs during startup
- NEVER run exploratory searches to orient — this skill replaces exploration with targeted reads
- Max file reads: handoff.json + 1 thread + manifest + up to 5 prd.json (headers only) + up to 2 journal files per resolved project (frontmatter + Open threads section only — never load Auto-capture)
- If >5 active projects found, show top 5 by most recent file modification
- Always verify git branch with `git branch --show-current` before displaying git state
- Context diet: every read must serve the orientation summary. No speculative loading
- Naked `/startwork` (no arg) MUST hit the entry gate first — ask via AskUserQuestion before reading the thread file or running any project scan. The only pre-gate read allowed is handoff.json itself (one-liner peek)
- If the user is unsure what to work on, route them to `/strategize` rather than doing eager project discovery
- If handoff.json doesn't exist, skip the "Resume last session" option — the gate still asks (pick target / not sure / something else)
- Use `qmd search` via shell command — if qmd unavailable, fall back to Grep to scan for prd.json files
- Before specialized work, prefer the relevant worker route surfaced by the Worker Packet
