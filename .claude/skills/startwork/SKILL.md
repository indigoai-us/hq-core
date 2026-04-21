---
name: startwork
description: Start a work session — resolve company, project, or repo context, gather state from handoff.json and manifest.yaml, present smart options. Lightweight session entry point that replaces ad-hoc orientation.
allowed-tools: Read, Grep, Glob, Bash(git:*), Bash(qmd:*), Bash(ls:*)
---

# Start Work Session

Lightweight session entry point. Resolves context fast, presents smart options, gets you working.

## When to Use

Beginning of every session. Replaces ad-hoc orientation.

## Process

### 1. Resolve Argument

Determine mode from the user's argument (first match wins):

- **No arg / empty** — Resume mode
- **Arg matches company slug** in `companies/manifest.yaml` — Company mode
- **Arg matches a directory** in `projects/` (not `_archive/`) or `companies/*/projects/` — Project mode
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
   - Fallback (if qmd unavailable): `grep -rl '"passes"' projects/ companies/ --include='prd.json'`
   - Filter results for `projects/` paths and `companies/*/projects/` paths (skip `_archive`). For each (max 5), read the prd.json and extract `name` + count stories where `passes !== true`. Collect projects with remaining work.

#### Company Mode (arg = company slug)

1. Read `companies/manifest.yaml` — extract the company's entry (repos, workers, knowledge, qmd_collections)
2. Read `workspace/threads/handoff.json` — if last thread relates to this company, note it
3. Search for company projects:
   - Primary: `qmd search "prd.json" --json -n 10` via shell
   - Fallback: `grep -rl '"passes"' projects/ companies/ --include='prd.json'`
   - Filter to projects whose repoPath matches any of the company's repos. Count incomplete stories per project.
4. If company has repos, run `git -C {first-repo} log --oneline -3` and `git -C {first-repo} branch --show-current`
5. List the company's workers from manifest (names only, don't read worker.yaml files)

#### Project Mode (arg = project name)

1. Read `projects/{name}/prd.json` — extract: `name`, `description`, `branchName`, incomplete stories (where `passes !== true`) with id + title + priority
2. Extract `metadata.repoPath` — identify company by matching against manifest repos
3. If repoPath exists: `git -C {repoPath} branch --show-current` and `git -C {repoPath} status --short`

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

### 2.5 Load Applicable Policies

Once company `{co}` is resolved (from any mode):

1. **Company policies**: If `{co}` known, read frontmatter-only for each policy in `companies/{co}/policies/` via `bash scripts/read-policy-frontmatter.sh {file}` (skip `example-policy.md`). Note count + titles of any `enforcement: hard` rules. For hard-enforcement policies only, additionally read the `## Rule` section with targeted Read + range.
2. **Repo policies**: If repo context resolved, check `{repoPath}/.claude/policies/` (if dir exists). Same frontmatter-only pattern.
3. **Global policies**: Count files in `.claude/policies/`. Prefer the compiled digest at `.claude/policies/_digest.md` if present (auto-loaded by SessionStart hook — this step becomes a no-op when digest is available). If no digest, filter to policies whose `trigger` matches current context — don't load all.

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
Knowledge pulse: {summary line from workspace/reports/knowledge-pulse/{co}-{today}.md if exists, e.g. "3 docs tagged, 2 flagged stale" — or omit line if no recent pulse}

Active work:
  - {project} -- {done}/{total} stories ({remaining} left)
  ...
```

Then present numbered options built from context:

- **Resume mode**: next_steps items (up to 3) + "Pick a project" + "Something else"
- **Company mode**: active projects for that company (up to 3) + "Run a worker" + "Something else"
- **Project mode**: top 3 incomplete stories by priority + "Something else"
- **Repo mode**: related projects with incomplete work (up to 3) + "Open repo (no project)" + "Something else"
- **Task mode**: proposed pipeline phases (up to 5) + "Run this pipeline" + "Modify pipeline" + "Skip workers — do it directly" + "Run /plan for full options" + "Something else"

Output the numbered list and wait for user input. After user picks, proceed directly into the work.

## Rules

- NEVER read INDEX.md, agents files, or company knowledge dirs during startup
- NEVER run exploratory searches to orient — this skill replaces exploration with targeted reads
- Max file reads: handoff.json + 1 thread + manifest + up to 5 prd.json (headers only)
- If >5 active projects found, show top 5 by most recent file modification
- Always verify git branch with `git branch --show-current` before displaying git state
- Context diet: every read must serve the orientation summary. No speculative loading
- If handoff.json doesn't exist, skip resume context — go straight to asking what to work on
- Use `qmd search` via shell command — if qmd unavailable, fall back to Grep to scan for prd.json files
