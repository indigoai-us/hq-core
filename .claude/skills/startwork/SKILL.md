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

**1.0b Bounded-action short-circuit (HARD RULE — check SECOND, after the slash-command rule, before mode resolution):**

If the argument names a bounded action owned by a dedicated skill in the table below, abort the normal classification flow, route to that skill with the raw remaining args, and STOP. Do NOT enter Company Mode. Do NOT read `companies/manifest.yaml`, do NOT run the qmd/grep project scan, do NOT run git, do NOT build the Worker Packet, and do NOT perform §2.4 session metadata, §2.5 policies, §2.6 worker routing, or any background maintenance. The target skill performs its own tenancy-safe company resolution.

Bounded-action routing table (closed list — route only on these):

| Argument names… | Route to |
|---|---|
| open / read / check / send a DM, "DM {person}", inbox, message thread | `/dm` |
| meeting notes, transcript, recap, "what was discussed" | `/meeting-notes` |
| signals, decisions, risks, commitments, wins | `/signals` |
| action items (read-only "what are my action items") | `/signals` (company skills may own the mutable tracker) |
| find / search / "where is X" | `/search` |
| goals, OKRs, key results | `/goals` |
| "who am I", session identity, login state | `/hq-whoami` |

- A company slug appearing as a word inside a bounded action does NOT upgrade the request to Company Mode — the bounded-action route wins. Example: `/startwork open my DM on indigo` → route to `/dm` (the slug is context for the target skill, not a mode selector).
- Negative example (the documented failure this rule exists for): `/startwork open Izzy's latest project DM` → route to `/dm` and stop. Full company orientation for this request is a scope bug, not thoroughness.
- Fall-through: if the argument is a bare company/project/repo name, or names orientation itself ("what's the state of X", "pick up X", "start on X", "what should I work on"), this rule does not apply — continue to §1.1 Mode resolution.

This rule exists because a bounded read-only request ("open Izzy's latest project DM") was observed expanding into full company orientation, duplicate policy ingestion, a background maintenance agent, and an unrequested session handoff. Runtimes that follow skill text literally (Codex) must find the fast path in the text itself.

**1.1 Mode resolution** (only if no short-circuit fired):

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

   Also glob `workspace/gates/pending/*.json` (cheap, no file reads yet). If any exist, a paused workflow is waiting on human answers — note the count for the gate below. Spec: `core/knowledge/public/hq-core/workflow-gates-spec.md`.

2. **Ask the user (AskUserQuestion), one question, then wait.** Present these options:
   - **Answer waiting workflow questions ({N})** — only if step 1 found pending gates. A paused workflow resumes the moment these are answered, so list this option FIRST.
   - **Resume last session** — only if step 1 found a handoff; label it with the one-liner (e.g. *"Resume: {summary}"*).
   - **Pick a company / project / repo** — user names the target; you then re-enter this skill in the matching mode (Company / Project / Repo) with that arg.
   - **Not sure what to work on** — route to `/strategize` (strategic prioritization). Announce the handoff and load `.claude/skills/strategize/SKILL.md`. Do not do project discovery here.
   - **Something else** — free-text; user describes intent → treat as Task mode.

   Do not present numbered markdown for this gate — use the structured picker. This is the whole point of the gate: no `qmd search "prd.json"`, no thread-file read, no per-project prd.json reads happen until the user has chosen.

3. **After the pick, load only what that path needs:**
   - *Resume last session* → before reading the thread file, resolve `thread_id` from `handoff.json.last_thread` and apply the same resume-lock confirmation procedure from `/resumework` Step 2. Run `bash core/scripts/hq-session.sh current` to obtain the session id, then `bash core/scripts/resume-thread-lock.sh inspect "{thread_id}"`. On `unlocked`, acquire the marker with `bash core/scripts/resume-thread-lock.sh acquire "{thread_id}" --session-id "{session_id}"`. On `locked` or `stale`, use AskUserQuestion with the returned `prompt` and stop on cancel; only after **Re-resume anyway** run `bash core/scripts/resume-thread-lock.sh acquire "{thread_id}" --replace --expected-generation "{lock_generation from inspected JSON}" --session-id "{session_id}"`. If replacement exits `4`, re-inspect and ask again because a newer marker replaced the one the user confirmed. Then, and only then, read the thread file handoff.json points to (extract `conversation_summary`, `next_steps`, `git.branch`, `git.current_commit`, `git.dirty`, `files_touched`); run `git log --oneline -3`; if the thread references a `project_dir`, read its most-recent journal file (frontmatter + `## Open threads` only — see Project Mode step 4). Skip the global qmd/grep project scan unless the user then asks "what else is active?".
   - *Answer waiting workflow questions* → for each pending gate, oldest first: read its JSON (question, options, context, recommended), ask ONE AskUserQuestion per gate (options from the gate file, recommended first, plus a "Skip this gate" option), and on an answer run `bash core/scripts/workflow-gate.sh answer {id} "{choice}"` (add `--notes` if the user typed free text). Skipped gates stay pending. When done, re-present this entry gate so the user can pick where to work.
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

Board status comes from the work mesh, never local prd.passes. If ground/check and the project-view cache both fail, then and only then use local prd for description — still not as live Board columns.

1. Resolve the project dir (`personal/projects/{name}` or `companies/{co}/projects/{name}`). Read `prd.json` only for `name`, `description`, `branchName`, and acceptance text — not story status.
2. Extract `metadata.repoPath` — identify company by matching against manifest repos
3. If repoPath exists: `git -C {repoPath} branch --show-current` and `git -C {repoPath} status --short`
4. If company `{co}` is resolved, load the live Board:
   ```
   bash core/scripts/work-mesh.sh ground --company {co} --project {name} --json
   # fallback: bash core/scripts/work-mesh.sh check --company {co} --project {name} --json
   ```
   Present columns from `stories[]` (`id`, `title`, `status`). If JSON has no stories, read `~/.hq/work-mesh/cache/projects/{companyUid}/{projectId}.json`.
   - `queued` = available next work
   - `in_progress` / `review` = already claimed; do not offer as free next work
   - `done` = done
   Include active mesh thread owners/blockers in the orientation block. If the helper prints nothing, omit the mesh line and continue.
   Do **not** `report --task-title` during orientation — that mints a T-NNN card. Session is presence. Attach later with `--task {id}`.
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

### 2.5 Report Applicable Policies (display-only — no policy re-reads)

Policy loading is NOT this skill's job. Two mechanisms already inject policies before this step runs:

1. **Company policies**: surfaced automatically when §2.4 runs `hq-session.sh set company_slug` — the bind emits the company's hard-enforcement rules (deduped and budgeted) directly into the tool result. Do NOT re-scan `companies/{co}/policies/` frontmatter here; that duplicates the bind emission.
2. **Repo policies**: if repo context resolved and `{repoPath}/.claude/policies/` exists, read frontmatter-only for each file via `bash core/scripts/read-policy-frontmatter.sh {file}` (skip `example-policy.md`). This is the one scan this step still owns — repo policies are not covered by the company bind.
3. **Global policies**: injected by the SessionStart/PreToolUse trigger hook (`inject-policy-on-trigger.sh`). No action here.

Display in orientation block (counts only — `ls | wc -l` is enough for N/K):
```
Policies: {N} company, {M} repo, {K} global ({H} hard-enforcement)
```

Rules:
- This step performs no company-policy file reads. The bind emission (§2.4) is the company-policy surface
- Repo policies: frontmatter only; for repo hard-enforcement policies read the `## Rule` section
- If no company resolved (resume mode with no company context), the count line may omit company
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

Active work:
  - {project} -- {done}/{total} stories ({remaining} left)
  ...

Board (work mesh):
  - {id} {title} — {status}
  ...
Work mesh threads:
  {active mesh owners/blockers for the selected company/project, or omit if none/unavailable}
```

Then present numbered options built from context:

- **Entry-gate mode (no arg)**: no orientation block is rendered before the gate — the AskUserQuestion gate (Gather Context → Entry-Gate Mode step 2) *is* the first interaction. Render an orientation block only *after* the user picks "Resume last session", using the loaded thread context; then offer next_steps items (up to 3) + "Pick a project" + "Something else".
- **Company mode**: worker-recommended next actions + active projects for that company (up to 3) + "Run a worker" + "Something else"
- **Project mode**: top 3 **queued** Board stories from work-mesh `stories[]` via `/execute-task` + matching worker route + "Something else". Skip `in_progress` unless the user already owns that row.
- **Repo mode**: related projects with incomplete work (up to 3) + "Open repo (no project)" + "Something else"
- **Task mode**: proposed worker pipeline phases (up to 5) + "Run this worker pipeline" + "Modify pipeline" + "Do it directly (no worker)" + "Run /plan for full options" + "Something else"

Output the numbered list and wait for user input. After user picks, proceed directly into the work.

## Rules

- NEVER read INDEX.md, agents files, or company knowledge dirs during startup
- NEVER run exploratory searches to orient — this skill replaces exploration with targeted reads
- A bounded single-action request (§1.0b table) routes to its owning skill and never triggers orientation loading, session-metadata writes, policy scans, worker routing, or background maintenance
- NEVER spawn a background knowledge-pulse (or any maintenance agent) from startup. The pulse is spawned only by the planning skills (`/brainstorm`, `/plan`, `/deep-plan`, `/prd`) — interactive startup spawns zero agents
- Max file reads: handoff.json + 1 thread + manifest + up to 5 prd.json (headers only) + up to 2 journal files per resolved project (frontmatter + Open threads section only — never load Auto-capture)
- If >5 active projects found, show top 5 by most recent file modification
- Always verify git branch with `git branch --show-current` before displaying git state
- Context diet: every read must serve the orientation summary. No speculative loading
- Naked `/startwork` (no arg) MUST hit the entry gate first — ask via AskUserQuestion before reading the thread file or running any project scan. The only pre-gate read allowed is handoff.json itself (one-liner peek)
- If the user is unsure what to work on, route them to `/strategize` rather than doing eager project discovery
- If handoff.json doesn't exist, skip the "Resume last session" option — the gate still asks (pick target / not sure / something else)
- Use `qmd search` via shell command — if qmd unavailable, fall back to Grep to scan for prd.json files
- Before specialized work, prefer the relevant worker route surfaced by the Worker Packet
