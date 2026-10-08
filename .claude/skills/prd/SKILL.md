---
name: prd
description: "Create an execution-ready PRD (prd.json + README.md) with a light interview. For deep research use /deep-plan."
allowed-tools: Read, Write, Edit, Grep, Glob, Task, Bash(git:*), Bash(qmd:*), Bash(ls:*), Bash(date:*), Bash(stat:*), Bash(core/scripts/read-policy-frontmatter.sh:*), Bash(npx:*), Bash, Bash(bash core/scripts/work-mesh-live-bind-trusted.sh:*), Bash(bash core/scripts/resolve-company.sh:*), Bash(bash core/scripts/register-project.sh:*), Bash(bash core/scripts/work-mesh-project-registration-offer.sh:*), Bash(.claude/skills/_shared/journal.sh:*), AskUserQuestion, Bash(bash core/scripts/read-policy-frontmatter.sh:*)
---

# PRD — Project Planning & PRD Generation

Create execution-ready PRDs with full HQ context awareness. Lightweight flow — batched questions, fast capture, no research subagents. For deep planning on large or strategically important PRDs, use `/deep-plan` instead. For adversarial spec review of an already-generated PRD, use `/review-plan`.

**Important:** Do NOT implement. Just create the PRD.

## Work Mesh Live — trusted bind (do this first)

After Step 0 resolves `{co}` and before any other tool call that touches project work, bind the session per
`.claude/skills/_shared/work-mesh-live-bind.md` (US-011):

```bash
bash core/scripts/work-mesh-live-bind-trusted.sh \
  --company "{co}" --project "{project}" --task "{task}"
```

Omit `--task` when unknown. This writes `workspace/sessions/<sid>/meta.yaml`
and reconciles with `observation.trustedContext` (no `--trusted` CLI flag).

## Step 0: Company Anchor (resolver, not first word)

Resolve the company with the shared resolver — never by hand, and never from the first word alone:

```bash
bash core/scripts/resolve-company.sh --prompt "{the user's full input}"
```

It returns `{"company":"<slug>","source":"prompt|session|device_default|none"}` and resolves in this order:

1. **`prompt`** — an explicit manifest slug appearing as a whole token anywhere in the input. Longest slug wins; an exact length tie breaks on earliest occurrence.
2. **`session`** — the company already bound for this session (`workspace/sessions/<id>/meta.yaml`). It always wins over the device default.
3. **`device_default`** — the enabled default returned by `hq mesh context default get --json`. Disabled and `needsChoice` states are deliberately treated as unset.
4. **`none`** — nothing resolved; use the structured picker before creating project files.

If the resolver is unavailable (older HQ install), fall back to the previous behavior: match the first word against `companies/manifest.yaml` top-level keys.

If `company` is non-empty:

1. **Set `{co}`** = the resolved slug for the entire flow. If the slug was the leading word of the input, strip it — the remaining text is the project description. If it appeared mid-sentence, leave the input intact
2. **Announce:** "Anchored on **{co}**" (add "— from this session's `/startwork`" when `source` is `session`, or "— from this device's default company" when `source` is `device_default`)
3. **Load policies (frontmatter-only)** — Collect eligible files in `companies/{co}/policies/`, skipping `example-policy.md`, `README.md`, and `_digest.md`; preserve their order and split the stable file order into consecutive chunks of at most 40 files. For each chunk, run `bash core/scripts/read-policy-frontmatter.sh {file1} {file2} ...` once with each path as a separate argument. Keep each call under 30 KB of output. The first output block belongs to the chunk’s first file argument; each later block belongs to the path named by its preceding `# --- policy-file: <path> ---` separator. Note `enforcement: hard` titles. For hard-enforcement policies only, additionally read the `## Rule` section with a targeted range. Policy digests (`**/policies/_digest.md`) are **retired** — SessionStart now injects matching policies via `inject-policy-on-trigger`; do not look for or prefer a digest file. Apply hard rules as constraints throughout the PRD
4. **Scope qmd searches** — If company has `qmd_collections` in manifest, use `-c {collection}` for all `qmd` calls
5. **Pre-load repos** — Extract `{co}.repos[]` from manifest. Present as options for Q-6d (repo path)
6. **Scope workers** — Filter to company workers (`companies/{co}/workers/`) + public workers (`workers/public/`)
7. **Scope projects** — Only search `companies/{co}/projects/` for existing project collision check

**If `source` is `none`** — do not silently assume personal scope. Ask the user which company this belongs to, or whether it is personal/HQ work, before creating any project files. Silently filing company work under `personal/projects/` hides it from the owning company permanently. The full input text is the project description either way.

## Step 1: Get Project Description

If user provided input, use as starting point.
If empty, ask the user: "Describe what you want to build or accomplish." Wait for response.

## Step 2: Scan HQ Context

Before asking questions, explore HQ. Resolve `mode` from Step 0 + input:

- **company mode** — a company slug was anchored in Step 0
- **repo mode** — no company anchor but a target repo is mentioned or resolvable from input
- **personal/HQ mode** — neither of the above (personal projects, HQ infrastructure work)

If `{co}` is anchored, scope all searches to that company.

**Companies & Context (only if `mode in (company, repo)`):**
- Read `agents-companies.md` (roles, priorities, three-tier roster) — needed to route cross-company PRDs
- Read `companies/manifest.yaml` (companies already listed there — never Glob for company discovery)
- **Skip both if already anchored in Step 0**: Step 0 already loaded manifest and matched the company. Re-reading is pure waste
- **Skip entirely for personal/HQ mode**: no company routing needed, no repo to map

**Workers (only if `mode in (company, repo)` AND the description plausibly needs a worker — otherwise skip):**
- Read `core/workers/registry.yaml` (workers already indexed there — never Glob for worker discovery). Skip if the description is clearly code/infra work not matching a worker skill
- If anchored: filter to company workers (`companies/{co}/workers/`) + public workers (`workers/public/`)
- **Skip entirely for personal/HQ mode**

**Existing Projects:**
- If anchored: `qmd search "prd.json" --json -n 20 -c {co}` (scoped) or search `companies/{co}/projects/` directly
- If not anchored: `qmd search "prd.json" --json -n 20` — existing projects across all companies and personal

**Knowledge (use single qmd hybrid query, not Grep, not vsearch+search pair):**
- If anchored + company has `qmd_collections`: `qmd query "<description keywords>" -c {collection} --json -n 10`
- If not anchored: `qmd query "<description keywords>" --json -n 10` — hybrid BM25 + vector + re-ranking for related knowledge, prior work, workers

**Company Policies (anchored only):**
- Already loaded in Step 0 (frontmatter-only). Do NOT re-read here. Note constraints from that scan

**Repo Policies (if repo resolved):**
- If target repo identified, list files in `{repoPath}/.claude/policies/` (if dir exists; skip `README.md` / `_digest.md`), preserve their order, and split the stable file order into consecutive chunks of at most 40 files. For each chunk, run `bash core/scripts/read-policy-frontmatter.sh {file1} {file2} ...` once with each path as a separate argument. Keep each call under 30 KB of output. The first output block belongs to the chunk’s first file argument; each later block belongs to the path named by its preceding `# --- policy-file: <path> ---` separator. Do not prefer a digest file (retired). For hard-enforcement policies, additionally read the `## Rule` section

**Target Repo (if repo specified or discovered):**
- If anchored: company repos already pre-loaded from manifest. Present as options
- If target repo has a qmd collection (e.g. `my-app`): `qmd query "<description keywords>" -c {collection} --json -n 10` — hybrid search for related code, patterns, existing implementations
- Present: "Found related code: {list of relevant files}"

Present:
```
Scanned HQ:
- Mode: {company | repo | personal/HQ}
- Company: {co} (anchored) | TBD | n/a
- Workers: {relevant list or "skipped"}
- Existing projects: {list or "none matching"}
- Relevant knowledge: {if any}
- Policies: {count loaded, or "none"}
- Category: [company-specific | cross-company | personal | HQ infrastructure]
```

## Step 2.5: Infrastructure Pre-Check

Before generating the PRD, verify infrastructure exists for the target company/repo:

1. **Company**: If project targets a company, read `companies/manifest.yaml`. If company has `knowledge: null`, flag that it has no knowledge directory. If the user wants one, create `companies/{co}/knowledge/` as a plain real directory (never initialize Git or symlink it), add a README if useful, and update the manifest `knowledge` field with that directory path.

2. **Repo**: If `repoPath` specified and doesn't exist locally, flag: "Repo not found at {path}. Clone it or create new?" Add to `manifest.yaml` if missing.

3. **qmd collection**: If company has `qmd_collections: []` in manifest, flag and offer to create collection.

Fix any gaps before proceeding.

## Step 3: Get + Validate Project Name

Ask the user for project slug (or infer from description). Then:
1. If `{co}` already set by Step 0: use it directly (skip company detection)
   If NOT set: ask the user. Do not infer a tenant from the description — Step 0's resolver already had the session bind and the full prompt to work with, so an inference here is a guess, and a wrong guess files the work where its company will never find it
2. Check if `companies/{co}/projects/{name}/` exists (also check root `projects/{name}/` for personal/HQ)
   - If exists: ask the user "Project exists. Continue editing or choose different name?"
3. Validate slug format (lowercase, hyphens only)

## Step 3.5: Brainstorm Detection

Now that `{co}` and `{slug}` are resolved, check if a brainstorm file exists:

```
companies/{co}/projects/{slug}/brainstorm.md
```

**If found:**
1. Read it. Extract YAML frontmatter (`status`, `source_idea_id`)
2. If `status: "promoted"` — warn the user: "This brainstorm was already promoted to a PRD. Open existing prd.json instead?"
3. **Load recorded answers as known facts.** If the brainstorm records answers by question id (lines such as `Q-1a: <answer>` under a decisions or answers section, or a `known_facts` map in frontmatter), load each id that exists in `.claude/skills/_shared/questions/prd.md` into `known_facts` for Step 4. The engine skips these questions; do not re-ask them as confirmations. They are counted under `skipped_known`.
4. Brainstorm prose without answer ids (Context, Recommendation, rejected approaches, What We Don't Know) feeds the question set's `prefill:` hints instead.

**If not found:** proceed normally (no change to existing behavior).

## Step 3.6: Open Session Journal

Spec: `core/knowledge/public/hq-core/journal-spec.md`. Open a session journal at the project_dir so research, decisions, and dead ends survive context compaction:

```bash
.claude/skills/_shared/journal.sh open prd "{project_dir}"
```

Where `{project_dir}` = `companies/{co}/projects/{slug}/` or `projects/{slug}/` for personal/HQ. The helper:

- Creates `{project_dir}/journal/{ISO8601}-prd.md` with frontmatter (`status: active`, `skill: prd`)
- Writes a session-scoped pointer under `.claude/state/active-journal.d/` so this session's autocapture hook + later steps append to this file
- Stays open across `/handoff` boundaries — only `/handoff` and `/checkpoint` close it

The autocapture PostToolUse hook appends `## Auto-capture` lines for any Agent / WebFetch / WebSearch / AskUserQuestion calls. Step 4 (interview decisions) and Step 8.5 (resolved/deferred questions) append curated entries via the same helper.

**Skip if:** journal helper unavailable (fail-soft).

## Step 4: Discovery Interview

Run the grilling engine (`.claude/skills/grilling/SKILL.md`) with:

- `question_set`: `.claude/skills/_shared/questions/prd.md` (the former Batches 1 to 7, with tiers and `depends_on`)
- `known_facts`: the brainstorm answers from Step 3.5, plus any question a `prefill:` hint fully answers from the Step 2 scan (company policies, repo scan, manifest)
- `mode`: `one-at-a-time` (one AskUserQuestion per question) unless the user passed `--rounds`

Before asking, apply the question set's `prefill:` hints to the question text and option labels. The engine resolves the `project_type` fact (code, content, or hq-tooling) once Q-1a, Q-2b, and Q-3a are answered; questions whose `applies_to` excludes the resolved type are skipped and not counted.

Write the engine count object to `prd.json` `metadata.interview` in Step 5:

```json
"interview": {"asked": 9, "skipped_known": 5, "skipped_fact": 1,
              "by_tier": {"strategic": 3, "architecture": 4, "quality": 2}}
```

Add the Live Path Watch question to `asked` and to the quality tier when it is asked. Then run `bash core/scripts/prd-interview-check.sh {prd.json}`. If it prints `WARN: {N}/10 answered` or a tier warning, show the warning and continue (policy `core/policies/prd-minimum-questions.md`).

### Append interview decisions to journal

After the interview completes:

```bash
.claude/skills/_shared/journal.sh append "{project_dir}" decisions "Interview decisions: project type — {classification}; scope — {what's in / what's out}; notable answers — {2-3 bullets}"
```

### Live Path Watch hook

Before generating the PRD, detect whether this project plausibly replaces, hardens, or builds alongside an existing **live production surface**. Purpose: prevent silent regressions on routes that already serve real users.

Trigger the hook when ANY of the following match:

- Project description contains a full URL (`https://...`) or a known production hostname (check `companies/{co}/manifest.yaml` `dns_zones` and any existing project's `metadata.replacementFor.liveUrls`)
- `repoPath` matches a repo that has prior PRDs declaring `metadata.replacementFor` (grep `companies/{co}/projects/*/prd.json` for `replacementFor`)
- Description matches replacement/hardening language: `rebuild`, `replace`, `harden`, `v[0-9]+`, `migration`, `rewrite`, `safeguard`, `regression`, `silent`, `prevent` + live noun

On match, ask via AskUserQuestion:

- `question`: "This PRD looks like it touches a live surface. Declare it so heartbeats and canaries can protect it from silent regression?"
- `header`: `"Live Path Watch"`
- `options`:
  - `label: "Yes — declare live URL(s)"` — follow up with a free-text prompt for the URL list (one per line), then set `metadata.replacementFor = { liveUrls, description, detectedFrom: "hook" }` and add `livePathWatch` to any story whose `acceptanceCriteria` mention the matched URLs
  - `label: "No — not a live-surface project"` — record the dismissal in `metadata.openQuestions` as `"LivePathWatch hook fired but was dismissed: {reason}"` (free text)
  - `label: "User already answered"` — skip (user populated `replacementFor` earlier in interview)

If user picks "Yes": also add a canary E2E test to the highest-priority story: `"curl -sS <liveUrl> returns 200 and contains none of {forbiddenTokens}"`.

Policy `core/policies/hq-live-path-watch-on-replacement-prds.md` (hard enforcement) blocks PRD generation when the hook matches but the user neither declared `replacementFor` nor explicitly dismissed. The hook MUST run before Step 5.

## Step 5: Generate PRD

Create `companies/{co}/projects/{name}/` folder with two files. Use root `projects/{name}/` only for personal/HQ projects.

### Primary: companies/{co}/projects/{name}/prd.json

This is the **source of truth**. `/run-project` and `/execute-task` consume this file.

```json
{
  "name": "{project-slug}",
  "description": "{1-sentence goal}",
  "branchName": "feature/{name}",
  "userStories": [
    {
      "id": "US-001",
      "title": "{Story title}",
      "description": "{As a [user], I want [feature] so that [benefit]}",
      "acceptanceCriteria": ["{Specific verifiable criterion}"],
      "deliverables": ["repo-path:{path relative to repoPath}", "url:{https://…}"],   // OPTIONAL — only when the output is known up front; workers record actual `evidence` at completion
      "e2eTests": [],
      "priority": 1,
      "passes": false,
      "files": [],
      "labels": [],
      "dependsOn": [],
      "notes": "",
      "model_hint": "",
      "worker_preference": [],
      "livePathWatch": []
    }
  ],
  "metadata": {
    "createdAt": "{ISO8601}",
    "goal": "{Overall project goal}",
    "successCriteria": "{Measurable outcome}",
    "qualityGates": ["{commands from Q-6a}"],
    "repoPath": "{repos/private/repo-name or empty}",
    "baseBranch": "{main or staging or master}",
    "relatedWorkers": ["{worker-ids from scan}"],
    "knowledge": ["{relevant knowledge paths}"],
    "audiences": ["{from Q-2a — user roles + technical level}"],
    "currentSolution": "{from Q-2b — what exists today}",
    "designRef": "{from Q-2c — Figma ID, reference, or empty}",
    "nonGoals": ["{from Q-3d — explicit out-of-scope items}"],
    "dataModel": "{from Q-4a — key entities/tables or empty}",
    "authModel": "{from Q-4b — auth approach or empty}",
    "architectureNotes": "{from Q-4c — approach or empty}",
    "performanceRequirements": "{from Q-4d — targets or empty}",
    "integrations": ["{from Q-5a — service name, type, credentialsReady}"],
    "securityNotes": "{from Q-5b — PII/compliance notes or empty}",
    "rolloutStrategy": "{from Q-5c — ship strategy or empty}",
    "analyticsEvents": ["{from Q-6g — event names or empty}"],
    "monitoringNotes": "{from Q-6h — prod monitoring plan or empty}",
    "openQuestions": ["{remaining unresolved questions — Step 8.5 resolves these before Step 9}"],
    "decisions": [],
    "interview": {"asked": 0, "skipped_known": 0, "skipped_fact": 0, "by_tier": {"strategic": 0, "architecture": 0, "quality": 0}},
    "replacementFor": null
  }
}
```

**`decisions[]` schema:** Appended by Step 8.5 as `{question, answer, decidedAt, decidedBy}`. Optional — absent means empty. Additive and backwards-compatible; existing PRDs without the field are unaffected.

**`worker_preference[]` schema:** Optional ordered list of preferred worker IDs (strings) per story. Used by `/execute-task` Layer 2 worker selection (`core/settings/orchestrator.yaml → worker_selection`). When non-empty AND any pinned worker can fill a role slot in the resolved sequence, that worker wins and the LLM picker is skipped. Default: empty array — fully auto-select. Example: `["backend-dev", "qa-tester"]`.

**Populating `files`:** For each story, infer file paths from the description + acceptance criteria + target repo structure. If `repoPath` is set, search the repo (via qmd or Glob) to find existing files the story will modify, and predict new files it will create. Paths are repo-relative (e.g. `src/middleware/auth.ts`, not absolute). Best-effort — empty is fine for stories with unclear scope.

### Derived: companies/{co}/projects/{name}/README.md

Generate FROM the prd.json data. Human-friendly view.

```markdown
# {name from prd.json}

**Goal:** {metadata.goal}
**Success:** {metadata.successCriteria}
**Repo:** {metadata.repoPath}
**Branch:** {branchName}

## Overview
{description}

## Audiences
{metadata.audiences — who uses this and their technical level. Omit section if empty}

## Quality Gates
- `{metadata.qualityGates[0]}`

## User Stories

### US-001: {title}
**Description:** {description}
**Priority:** {priority}
**Depends on:** {dependsOn or "None"}

**Acceptance Criteria:**
- [ ] {criterion 1}
- [ ] {criterion 2}

**E2E Tests:** (if non-empty)
- [ ] {e2eTest 1}
- [ ] {e2eTest 2}

## Non-Goals
{metadata.nonGoals — from Q-3d answers. If empty, state "None defined"}

## Technical Considerations
{Enriched from interview answers:}
- **Data model:** {metadata.dataModel — or omit if empty}
- **Auth:** {metadata.authModel — or omit if empty}
- **Architecture:** {metadata.architectureNotes — or omit if empty}
- **Performance:** {metadata.performanceRequirements — or omit if empty}
- **Integrations:** {metadata.integrations — list services, note if creds ready. Or omit if empty}
- **Security:** {metadata.securityNotes — or omit if empty}
- **Rollout:** {metadata.rolloutStrategy — or omit if empty}
- **Analytics:** {metadata.analyticsEvents — list events. Or omit if empty}
- **Monitoring:** {metadata.monitoringNotes — or omit if empty}
{Omit any sub-bullet where the field is empty. If ALL fields empty, write general constraints/dependencies instead}

## Decisions
{Render as table from metadata.decisions[]. Omit section entirely if empty. Columns: Question | Answer | Decided by. Populated by Step 8.5 decision-mode pass.}

| Question | Answer | Decided by |
|---|---|---|
| {decisions[i].question} | {decisions[i].answer} | {decisions[i].decidedBy} |

## Open Questions
{Remaining unresolved questions from metadata.openQuestions[]. If all were resolved in Step 8.5, write "None — all resolved in decision mode (see Decisions above)." If any were deferred, list each with its deferredReason and link to the generated pre-flight story.}
```

## Steps 5.5–8.5: Finalize (shared)

Follow `.claude/skills/_shared/prd-finalize.md` in order, as caller `/prd`. One line per step:

- Step 5.5: Update Brainstorm (if exists) — set the brainstorm frontmatter to status promoted with promoted_to.
- Step 5.6: Sync to Company Board — upsert the project entry in the company board.json.
- Step 5.7: Register the canonical project in Work Mesh — run the registration offer check, then register-project.sh; report "registration incomplete" on failure.
- Step 6: Register with Orchestrator — add the project to workspace/orchestrator/state.json.
- Step 7: Optional Beads Setup — run bd init when the bd CLI is on PATH; otherwise skip.
- Step 7.5: Capture Learning (Auto-Learn) — register the project through /learn, reindex qmd, regenerate the projects INDEX.md.
- Step 7.6: Doc Scout (read-only) — record missing or stale docs as metadata.postImplementation; modify no docs.
- Step 7.7: Spawn Knowledge Pulse (Background) — start a background knowledge pulse for the company.
- Step 8: Linear Sync (best-effort, when configured) — create the Linear project and issues when configured; skip silently on failure.
- Step 8.5: Resolve Open Questions (Decision Mode) — resolve open questions with AskUserQuestion, Defer option last; deferred ones become pre-flight investigation stories.

## Step 9: Confirm & STOP

Tell user:
```
Project **{name}** created with {N} user stories.
Decisions resolved: {metadata.decisions.length} (Step 8.5)
Open questions remaining: {metadata.openQuestions.length}

Files:
  companies/{co}/projects/{name}/prd.json   (source of truth — tracks all work)
  companies/{co}/projects/{name}/README.md  (human-readable view)

Post-implementation docs needed:
  {list from postImplementation metadata, or "None detected"}

To execute, start a new session and run:
  /run-project {name}        (multi-story orchestrator)
  /execute-task {name}/US-001 (single story)
```

**Final step — auto-checkpoint <!-- AUTO-CHECKPOINT-ON-COMPLETION -->.** By default, do not proceed to execution. Rather than asking the user to manually `/handoff`, automatically save a lightweight checkpoint so stories execute cleanly in a fresh session. Write `workspace/threads/T-{UTC YYYYMMDD-HHMMSS}-auto-prd-{project}.json` with `thread_id`, `version: 1`, `type: "auto-checkpoint"`, `created_at`, `updated_at`, `workspace_root`, `cwd`, `git: { branch, current_commit, dirty }`, `conversation_summary` (the project + that its PRD was created), `files_touched` (the `prd.json` + `README.md`), `next_steps` ("in a fresh session run `/run-project {project}` or `/execute-task {project}/US-001`"), and `metadata: { title: "Auto: prd {project}", tags: ["auto-checkpoint", "prd"], trigger: "prd-complete" }`. Keep it cheap (no INDEX/`recent.md`/`qmd` rebuild, no legacy checkpoint). Then tell the user the PRD is ready and a fresh session can start execution from this checkpoint. If the user explicitly asks to execute in THIS session, you may proceed after warning once that planning context can bleed into execution; the auto-checkpoint is written regardless.

## Story Guidelines

- Each story completable in one AI session
- Acceptance criteria must be verifiable (not "works correctly")
- Order: schema → backend → UI → integration
- Keep stories atomic (one deliverable each)
- Every story starts with `passes: false`
- `model_hint` (optional): override model for all workers in this story. Values: `"opus"`, `"sonnet"`, `"haiku"`. Leave empty to use worker defaults from worker.yaml
- `files` (recommended): list of repo-relative file paths this story will likely create/modify. Used by file-locking system to prevent concurrent edit conflicts. Infer from story description + codebase search. Empty `[]` = no locks (backwards-compatible). Agents can expand the list dynamically during execution
- `e2eTests` (recommended for deployable projects): list of executable test descriptions that verify each acceptance criterion. Leave `[]` for non-code projects. These drive the `acceptance-test-writer` phase in `/execute-task` which generates real test files (`__tests__/stories/{story-id}.test.ts`) — cumulative back-pressure that protects completed stories from regression by later stories
  - Format each entry as a Given/When/Then assertion: `"Given [context], when [action], then [expected]"`
  - At least 1 test per acceptance criterion for code stories
  - Tests should verify BEHAVIOR, not implementation details
  - Examples: `"Given a logged-in user, when they pull to refresh, then the list reloads with fresh data"`, `"Given the settings form, when email is cleared and submitted, then a validation error shows"`
- For deployable projects, include at least one story dedicated to E2E test infrastructure (Phase 0 pattern)

### Story Complexity Budget

Score each story: **(AC count x 1) + (file count x 2)**. Threshold: **<= 20**.

At PRD generation, compute per-story. If score > 20:
1. Warn: `"US-004 complexity=29. Recommend splitting."`
2. Offer auto-split by: tab group, entity boundary, or API/UI separation
3. If user declines split: add `"model_hint": "opus"` to the story

Splitting heuristics:
- **Tab-heavy UI**: split by tab group (tabs 1-3 / tabs 4-5)
- **Multi-entity**: split by entity (brand detail / brand SKU)
- **API + UI**: always split (schema/API story → UI story depends on it)
- **12+ ACs**: almost always needs a split regardless of file count

## Rules

- Scan HQ first, ask questions second
- One AskUserQuestion per interview question (grilling engine default)
- **prd.json is the source of truth** — README.md is derived from it, never the reverse
- **All stories start with `passes: false`** — `/run-project` marks them true
- **Planning, not execution** — this skill IS planning for everything except Step 8.5, which uses plan mode + AskUserQuestion to force resolution of open questions before PRD completion
- **Track stories in prd.json** — that is the task list, no separate todo tracking needed
- **Do NOT silently implement instead of planning** — A PRD invocation's job is to create the PRD files (`companies/{co}/projects/{name}/prd.json` + `README.md`). Do not skip that and start editing target files (repos, decks, sites, etc.) in their place. Plan approval = "approved to generate PRD files," not an implicit "approved to implement." Implementation runs via `/execute-task` or `/run-project` — by default in a fresh session, or in this session if the user explicitly requests it (see the handoff default below). Bypassing the PRD files entirely loses project tracking, worker assignment, and quality gates
- **Default to auto-checkpoint after PRD creation** — After Step 9 confirmation, the default is to auto-checkpoint (see "Final step — auto-checkpoint") and end the session, so stories execute in a fresh session with clean context isolation (Ralph pattern). This is a strong default, not a hard block: if the user explicitly asks to execute now, you may proceed to `/execute-task` or `/run-project` in this session — but first warn once that planning context can reduce execution isolation, and recommend handoff + fresh session as the cleaner path. Never auto-execute without an explicit request. prd.json tracks all work regardless, so a fresh session can always resume
- **Infrastructure before planning** — never create a PRD that references infrastructure (company, repo, knowledge) that doesn't exist. Fix gaps first (Step 2.5)
- **MANDATORY: Always create project files** — Every PRD invocation MUST produce `companies/{co}/projects/{name}/prd.json` and `companies/{co}/projects/{name}/README.md`. No exceptions. These files are how HQ tracks work — they are NOT just inputs for `/run-project`. Never output a PRD to chat only, never skip file creation because the user "just wants a quick plan", never treat file generation as optional. If the user provides enough info to generate stories, write the files
- **Every story MUST have testable acceptance criteria** — "works correctly" is not acceptable
- **Include testing stories** — For deployable projects, at least one story should be dedicated to E2E test infrastructure
- **ALWAYS: Verify board.json write in Step 5.6** — After upserting the board entry, re-read board.json and confirm the new project ID exists. If the write failed silently (file parse error, missing board, manifest lookup miss), log the error and retry once. Silent failure leaves projects invisible in the HQ app — the orphan scanner catches them with an "Unregistered" badge, but proper registration is required
