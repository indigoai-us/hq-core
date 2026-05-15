---
name: startwork
description: Start a work session — resolve company, project, or repo context, gather state from handoff.json and manifest.yaml, surface worker routes, and present smart options. Lightweight session entry point that replaces ad-hoc orientation.
allowed-tools: Read, Grep, Glob, Bash(git:*), Bash(qmd:*), Bash(ls:*), Bash(core/scripts/hq-session.sh:*), Bash, AskUserQuestion
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

- **No arg / empty** — Resume mode
- **Arg matches company slug** in `companies/manifest.yaml` — Company mode
- **Arg matches a directory** in `personal/projects/` (not `_archive/`) or `companies/*/projects/` — Project mode
- **Arg matches a directory** in `repos/private/` or `repos/public/` — Repo mode
- **Partial match** — arg is a substring of any company slug, project dir, or repo name. 1 match: use that mode. 2-5 matches: present numbered list, wait for user to pick. >5: ask user to be more specific
- **Free-text task** — arg is ≥3 words and doesn't match any company/project/repo/partial → Task mode
- **No match** — ask user to clarify

### 2. Gather Context

#### Resume Mode (no arg)

1. Read `workspace/threads/handoff.json`
2. Read the thread file it points to. Extract: `conversation_summary`, `next_steps`, `git.branch`, `git.current_commit`, `git.dirty`, `files_touched`
3. Run `git log --oneline -3` for recent HQ commits
4. Search for active projects:
   - Primary: `qmd search "prd.json" --json -n 10` via shell
   - Fallback (if qmd unavailable): `grep -rl '"passes"' personal/projects/ companies/ --include='prd.json'`
   - Filter results for `personal/projects/` paths and `companies/*/projects/` paths (skip `_archive`). For each (max 5), read the prd.json and extract `name` + count stories where `passes !== true`. Collect projects with remaining work.
5. **If the resumed thread references a project_dir** (extract from thread `files_touched` or `conversation_summary`): read the most-recent journal file from `{project_dir}/journal/*.md` (frontmatter + `## Open threads` only). Surface its `summary` + open threads in orientation. See Project Mode step 4 for the read pattern.

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
4. **Read session journals** (spec: `core/knowledge/public/hq-core/journal-spec.md`). If `{project_dir}/journal/` exists:
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
3. **Global policies**: Count files in `core/policies/`. Prefer the compiled digest at `core/policies/_digest.md` if present (auto-loaded by SessionStart hook — this step becomes a no-op when digest is available). If no digest, filter to policies whose `trigger` matches current context — don't load all.

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
```

Then present numbered options built from context:

- **Resume mode**: next_steps items (up to 3) + "Pick a project" + "Something else"
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
- If handoff.json doesn't exist, skip resume context — go straight to asking what to work on
- Use `qmd search` via shell command — if qmd unavailable, fall back to Grep to scan for prd.json files
- Before specialized work, prefer the relevant worker route surfaced by the Worker Packet
