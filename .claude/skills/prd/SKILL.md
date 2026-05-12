---
name: prd
description: Create an execution-ready PRD for a project. Creates prd.json + README.md with full HQ context awareness. Runtime-agnostic — executes identically in Claude Code and Codex. Lightweight by default — uses batched questions and adapts interview depth to brainstorm context if available. For deep research subagents + 3-tier 15-question interview, use /deep-plan instead.
allowed-tools: Read, Write, Edit, Grep, Glob, Bash(git:*), Bash(qmd:*), Bash(ls:*), Bash(date:*), Bash(stat:*), Bash(core/scripts/read-policy-frontmatter.sh:*), Bash(core/scripts/build-policy-digest.sh:*), Bash(npx:*)
---

# PRD — Project Planning & PRD Generation

Create execution-ready PRDs with full HQ context awareness. Lightweight flow — batched questions, fast capture, no research subagents. For deep planning on large or strategically important PRDs, use `/deep-plan` instead. For adversarial spec review of an already-generated PRD, use `/review-plan`.

**Important:** Do NOT implement. Just create the PRD.

## Step 0: Company Anchor (from user input)

Check if the **first word** of the user's input matches a company slug in `companies/manifest.yaml`.

**How to check:** Read `companies/manifest.yaml`. Extract top-level keys (company slugs). If the first word exactly matches one of those slugs:

1. **Set `{co}`** = matched slug for the entire flow. Strip the slug — the remaining text is the project description
2. **Announce:** "Anchored on **{co}**"
3. **Load policies (frontmatter-only)** — For each file in `companies/{co}/policies/` (skip `example-policy.md`), run `bash core/scripts/read-policy-frontmatter.sh {file}`. Note `enforcement: hard` titles. For hard-enforcement policies only, additionally read the `## Rule` section with a targeted range. The SessionStart hook also injects the company policy digest at `companies/{co}/policies/_digest.md` — prefer that if present. Apply as constraints throughout the PRD
4. **Scope qmd searches** — If company has `qmd_collections` in manifest, use `-c {collection}` for all `qmd` calls
5. **Pre-load repos** — Extract `{co}.repos[]` from manifest. Present as repo options in Batch 3 Q10
6. **Scope workers** — Filter to company workers (`companies/{co}/workers/`) + public workers (`workers/public/`)
7. **Scope projects** — Only search `companies/{co}/projects/` for existing project collision check

**If no match** (first word is not a company slug) — proceed normally. The full input text is the project description.

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
- If target repo identified, list files in `{repoPath}/.claude/policies/` (if dir exists), then for each run `bash core/scripts/read-policy-frontmatter.sh {file}`. Prefer the repo digest at `{repoPath}/.claude/policies/_digest.md` if present (SessionStart hook injects it). For hard-enforcement policies, additionally read the `## Rule` section

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

1. **Company**: If project targets a company, read `companies/manifest.yaml`. If company has `knowledge: null`, flag: "Company {co} has no knowledge repo. Create one? [Y/n]" — if yes, create embedded repo at `companies/{co}/knowledge/` with `git init`, update manifest + modules.yaml.

2. **Repo**: If `repoPath` specified and doesn't exist locally, flag: "Repo not found at {path}. Clone it or create new?" Add to `manifest.yaml` if missing.

3. **qmd collection**: If company has `qmd_collections: []` in manifest, flag and offer to create collection.

Fix any gaps before proceeding.

## Step 3: Get + Validate Project Name

Ask the user for project slug (or infer from description). Then:
1. If `{co}` already set by Step 0: use it directly (skip company detection)
   If NOT set: determine company from context (infer from description, repo, or ask the user)
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
3. **Pre-load brainstorm content** into interview context for Step 4:
   - **Batch 1** (Problem/Success): pre-fill from brainstorm's `## Context`, `## Recommendation`. Present as confirmations ("Based on brainstorm: {X}. Confirm or modify?") instead of open-ended questions
   - **Batch 2** (Users/Current State): pre-fill audience and current solution from brainstorm context if mentioned
   - **Batch 3** (Scope/Constraints): pre-fill from `## What We Don't Know` + any constraints mentioned. Surface unknowns as explicit questions to resolve. Pre-fill non-goals from brainstorm's rejected approaches
   - **Batch 4** (Data/Architecture): pre-fill from brainstorm's recommended approach's tech choices, data model mentions
   - **Batch 5** (Integrations): pre-fill from brainstorm's identified external services
   - **Batch 6** (Quality/Shipping): pre-fill from brainstorm's identified workers, repos
   - **Batch 7** (E2E): unchanged — brainstorm doesn't cover testing specifics
4. **Effect**: interview batches collapse to confirmations rather than open-ended questions. User answers faster, stories are better anchored to the evaluated approach

**If not found:** proceed normally (no change to existing behavior).

## Step 3.6: Open Session Journal

Spec: `core/knowledge/public/hq-core/journal-spec.md`. Open a session journal at the project_dir so research, decisions, and dead ends survive context compaction:

```bash
.claude/skills/_shared/journal.sh open prd "{project_dir}"
```

Where `{project_dir}` = `companies/{co}/projects/{slug}/` or `projects/{slug}/` for personal/HQ. The helper:

- Creates `{project_dir}/journal/{ISO8601}-prd.md` with frontmatter (`status: active`, `skill: prd`)
- Writes `.claude/state/active-journal` so the autocapture hook + later steps append to this file
- Stays open across `/handoff` boundaries — only `/handoff` and `/checkpoint` close it

The autocapture PostToolUse hook appends `## Auto-capture` lines for any Agent / WebFetch / WebSearch / AskUserQuestion calls. Step 4 (interview decisions) and Step 8.5 (resolved/deferred questions) append curated entries via the same helper.

**Skip if:** journal helper unavailable (fail-soft).

## Step 4: Discovery Interview

Ask questions in batches. Users respond with shorthand: "1a A, 1b: build a dashboard, 1c B"

Each question has lettered options for fast answers + free text override. Present one batch at a time, wait for response, then present next batch.

**Before Batch 4:** Classify project type from description + Batch 1-3 answers:
- **Code project** (has repoPath, or code/app/API/feature keywords) — ask all batches
- **Content/knowledge/report** — skip Batches 4, 5; skip 6g/6h. Note: "(Batch 4 skipped — non-code project)"
- **Personal/HQ tooling** — skip 5b, 5c, 6g, 6h

### Dynamic Question Enrichment

Use the context gathered in Step 2 (company policies, repo policies, manifest, repo scan) to **enrich questions with specific details** rather than asking generic versions. This makes questions faster to answer and surfaces constraints the user might forget.

**From company policies** (`companies/{co}/policies/`):
- Policy mentions feature flags / rollout — pre-fill 5c with the required approach, present as confirmation
- Policy mentions PII / GDPR / compliance — always surface 5b regardless of keywords, note the policy
- Policy mentions brand voice / design system — pre-fill 2c option C with the specific system name
- Policy mentions specific deploy procedures — add context to 6a (quality gates)
- Any `enforcement: hard` policy that constrains architecture, auth, or integrations — surface as a constraint in the relevant batch header (e.g. "Note: company policy requires Clerk auth for all new features")

**From repo scan** (target repo's CLAUDE.md, package.json, existing patterns):
- Repo uses specific auth (Clerk, NextAuth, Supabase Auth) — pre-fill 4b option A with: "Uses existing auth ({system}) — no changes needed"
- Repo uses specific ORM/DB (Prisma, pgClient, Supabase) — add hint to 4a: "This repo uses {ORM}. Describe entities in those terms"
- Repo has analytics/tracking (PostHog, Segment, Mixpanel, GA) — pre-fill 6g option B with the system name
- Repo has monitoring (Sentry, Datadog, CloudWatch) — pre-fill 6h option B/D with the service name
- Repo has existing test commands — pre-fill 6a with detected commands
- Repo has existing design system / component library — mention in 2c option C

**From manifest** (`companies/manifest.yaml`):
- Company has `services: [stripe, ...]` — if project might involve payments, surface in 5a as a hint
- Company has `vercel_team` — enrich 5c with "deploys via Vercel to {team}"
- Company has existing integrations — list them as option B context in 5a

**Presentation:** Weave enrichments into the question text naturally. Don't add a separate "detected context" dump — make each question smarter:
```
// Generic (bad):
4b. Auth / permissions model?
    A. Uses existing auth — no changes needed

// Enriched (good):
4b. Auth / permissions model? (repo uses Clerk via @clerk/nextjs)
    A. Uses existing Clerk auth — no changes needed
```

If a policy or repo context **fully answers** a question, present it as a confirmation rather than an open question:
```
5c. Rollout strategy? → Company policy requires feature flags for all new features.
    Confirming: B. Feature flag (env var)  [Y/n]
```

---

**Batch 1 — Problem & Success**
1a. Core problem or goal?
1b. What does success look like? (measurable metric or verifiable state)
1c. Who benefits? (list all beneficiaries)

---

**Batch 2 — Users & Current State**
2a. Who are the primary users?
    A. Internal / admin only
    B. External customers / end users
    C. Both internal and external
    D. Developer tooling / no direct end user
    (free text to specify roles and technical level, e.g. "Geoff — CEO, non-technical")

2b. What exists today? (current solution, even if it's a spreadsheet or nothing)
    A. Nothing — greenfield
    B. Existing feature being replaced or upgraded
    C. Manual process being automated
    D. Third-party tool being replaced
    (free text to describe what's being replaced and why it's insufficient)

2c. Are there reference designs, mockups, or brand constraints? *(skip if non-UI)*
    A. Figma file exists (provide file/node ID)
    B. Visual reference / screenshot (describe or link)
    C. Follow existing design system exactly (name which one)
    D. No design constraints — AI chooses
    E. Not a UI project (skip)
    *Conditional: auto-skip with E for pure backend/CLI/data projects*

---

**Batch 3 — Scope & Constraints**
3a. What's in scope for MVP?
3b. Hard constraints (time, tech, budget)?
3c. Dependencies on other projects?
3d. What is explicitly NOT in scope? (non-goals — things users might ask for but we won't build)
    (free text list, or "none")

---

**Batch 4 — Data & Architecture** *(conditional: code projects only)*
*Trigger: project has repoPath or description contains DB/schema/API/model keywords. Auto-skip for content/knowledge/reports/social.*

4a. Key data entities? (tables, columns, domain objects this project touches)
    (free text, e.g. "new `depletions` table, adds `sku_id` FK to `line_items`" — or "no DB changes")

4b. Auth / permissions model?
    A. Uses existing auth — no changes needed
    B. New role or permission level needed (describe)
    C. New auth provider or login method
    D. No auth (public or internal tool)

4c. Architecture approach?
    A. Follow existing patterns in the repo exactly
    B. New pattern needed (describe)
    C. No opinion — let workers decide

4d. Performance requirements? *(conditional: only if real-time/scale/latency/throughput keywords in description)*
    A. Standard — no special requirements
    B. Latency target: [specify, e.g. "< 2s page load"]
    C. Throughput target: [specify, e.g. "1000 req/s"]
    D. Mobile / low-bandwidth optimization needed
    *Default: A*

---

**Batch 5 — Integrations & Security** *(conditional: projects with external service interaction)*
*Trigger: description contains API/webhook/OAuth/third-party/Stripe/Slack/integration keywords. Auto-skip for fully internal projects.*

5a. External integrations or third-party APIs?
    A. None — fully self-contained
    B. Existing integrations (already wired up, just using them)
    C. New integration needed — list: which service, what data flows, are credentials already set up?

5b. Sensitive data or security considerations? *(conditional: only if user/payment/PII/customer keywords)*
    A. No PII or sensitive data
    B. PII handled (email, name, payment info) — existing compliance approach applies
    C. New compliance requirement (HIPAA, GDPR, etc.)
    D. Rate limiting or abuse protection needed
    E. User-generated content with moderation needs

5c. Rollout strategy? *(conditional: only for production-deployed projects with real users)*
    A. Ship to all users immediately
    B. Feature flag (specify: env var, LaunchDarkly, user segment)
    C. Staged rollout (% of users or specific cohort)
    D. Internal only first, then broader rollout
    *Default: A*

---

**Batch 6 — Quality & Shipping**
6a. Quality gates? (detect repo from scan, suggest commands)
    A. `pnpm typecheck && pnpm lint`
    B. `npm run typecheck && npm run lint`
    C. None (no automated checks)
    D. Other: [specify]

6b. Based on scan: "Should this use {relevant workers}?"
6c. Does this need a new worker or skill?
6d. Repo path? (e.g. `repos/private/{name}`, or "none" if non-code)
6e. Branch name? (default: `feature/{project-name}`)
6f. Base branch? (default: `main`, or `staging` for {your-repo}, etc.) — Pure Ralph creates feature branch from this

6g. Analytics / event tracking needed? *(conditional: deployable UI projects only)*
    A. No — not a user-facing feature
    B. Yes — use existing tracking system (name it)
    C. Yes — new tracking events needed (list key events, e.g. "depletion.filter.applied")
    D. Not sure — include tracking stub only
    *Default: A*

6h. How do we know it's working in production? *(conditional: production-deployed projects only)*
    A. Manual testing only
    B. Existing monitoring covers it (no changes needed)
    C. New health check or monitoring alert needed (describe)
    D. Success metric visible in existing dashboard (name it)
    *Default: B for existing repos, A for greenfield*

---

**Batch 7 — E2E Testing** *(recommended for deployable projects)*
For each user story targeting a deployable repo, specify E2E tests:

7a. What E2E tests should verify each story works?
    - For UI: "Page loads", "User can complete [action]", "Form shows validation errors"
    - For API: "Endpoint returns expected response", "Error cases handled"
    - For CLI: "Command runs successfully", "Opens correct URL"
    - For integration: "Full flow from [A] to [B] works"
    - Leave empty for non-deployable projects (knowledge, content, data)

### Append interview decisions to journal

After the interview batches complete:

```bash
.claude/skills/_shared/journal.sh append decisions "Interview decisions: project type — {classification}; scope — {what's in / what's out}; notable answers — {2-3 bullets}"
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
    "qualityGates": ["{commands from Batch 6a}"],
    "repoPath": "{repos/private/repo-name or empty}",
    "baseBranch": "{main or staging or master}",
    "relatedWorkers": ["{worker-ids from scan}"],
    "knowledge": ["{relevant knowledge paths}"],
    "audiences": ["{from Batch 2a — user roles + technical level}"],
    "currentSolution": "{from Batch 2b — what exists today}",
    "designRef": "{from Batch 2c — Figma ID, reference, or empty}",
    "nonGoals": ["{from Batch 3d — explicit out-of-scope items}"],
    "dataModel": "{from Batch 4a — key entities/tables or empty}",
    "authModel": "{from Batch 4b — auth approach or empty}",
    "architectureNotes": "{from Batch 4c — approach or empty}",
    "performanceRequirements": "{from Batch 4d — targets or empty}",
    "integrations": ["{from Batch 5a — service name, type, credentialsReady}"],
    "securityNotes": "{from Batch 5b — PII/compliance notes or empty}",
    "rolloutStrategy": "{from Batch 5c — ship strategy or empty}",
    "analyticsEvents": ["{from Batch 6g — event names or empty}"],
    "monitoringNotes": "{from Batch 6h — prod monitoring plan or empty}",
    "openQuestions": ["{remaining unresolved questions — Step 8.5 resolves these before Step 9}"],
    "decisions": [],
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
{metadata.nonGoals — from Batch 3d answers. If empty, state "None defined"}

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

## Step 5.5: Update Brainstorm (if exists)

If a `brainstorm.md` was detected in Step 3.5, update its YAML frontmatter:
- Set `status: "promoted"`
- Set `promoted_to: "companies/{co}/projects/{name}/prd.json"`

This marks the brainstorm as consumed. The file is preserved for reference.

## Step 5.6: Sync to Company Board

Read `companies/manifest.yaml` to find `metadata.company` → `board_path`.

If `board_path` exists, read `companies/{co}/board.json` and upsert a project entry:
- **Match**: find existing entry by `prd_path === "companies/{co}/projects/{name}/prd.json"` or title similarity
- **If found**: update `status` to `prd_created`, set `prd_path`, update `updated_at`
- **If not found**: append new entry:
  ```json
  {
    "id": "{co-prefix}-proj-{N+1}",
    "title": "{project name}",
    "description": "{1-sentence description}",
    "status": "prd_created",
    "scope": "company",
    "app": null,
    "initiative_id": null,
    "prd_path": "companies/{co}/projects/{name}/prd.json",
    "created_at": "{ISO8601}",
    "updated_at": "{ISO8601}"
  }
  ```
- Write updated `board.json` back to `board_path`
- If no `metadata.company` in prd.json or no board_path, skip silently

**Verify:** After upserting the board entry, re-read board.json and confirm the new project ID exists. If the write failed silently (file parse error, missing board, manifest lookup miss), log the error and retry once. Silent failure leaves projects invisible in the HQ app — the orphan scanner catches them with an "Unregistered" badge, but proper registration is required.

## Step 6: Register with Orchestrator

Read `workspace/orchestrator/state.json`. Append to `projects` array:

```json
{
  "name": "{name}",
  "state": "READY",
  "prdPath": "companies/{co}/projects/{name}/prd.json",
  "updatedAt": "{ISO8601}",
  "storiesComplete": 0,
  "storiesTotal": "{N}",
  "checkedOutFiles": []
}
```

If project already exists in state.json, update it instead of duplicating.

## Step 7: Sync to Beads

```bash
npx tsx core/scripts/prd-to-beads.ts --project={name}
```

Silent — just log success/failure.

## Step 7.5: Capture Learning (Auto-Learn)

Run the `learn` skill (or `/learn` in Claude Code) to register the new project in the learning system:

```json
{
  "source": "build-activity",
  "severity": "medium",
  "scope": "global",
  "rule": "Project {name} exists at companies/{co}/projects/{name}/ with {N} stories targeting {repoPath or 'no repo'}",
  "context": "Created via prd skill"
}
```

Also reindex: `qmd update 2>/dev/null || true`

**Update INDEX.md:** Regenerate `companies/{co}/projects/INDEX.md` per `core/knowledge/public/hq-core/index-md-spec.md`.

## Step 7.6: Doc Scout (read-only)

Check if the new project's scope reveals missing or stale docs. Scout only — no modifications (project hasn't been built yet).

1. **Repo README** (`{repoPath}/README.md` if `repoPath` set):
   - Does it exist? Is it boilerplate (`create-next-app`, default template)?
   - If repo is new or README is stale, note for post-implementation

2. **HQ knowledge** (`companies/{co}/knowledge/`):
   - `qmd search "{project topic}" -c {co} --json -n 3` — is this topic already covered?
   - If no coverage and project is non-trivial, note the gap

3. **External docs**: If company has a knowledge site (check INDEX.md references), note potential publishing need

**Do NOT create or modify docs** — project hasn't been implemented. Instead:
- Add a `postImplementation` array to prd.json `metadata` listing doc tasks:
  ```json
  "postImplementation": [
    "Update repo README with API docs",
    "Create {topic} architecture doc in companies/{co}/knowledge/"
  ]
  ```
- Include these notes in the Step 8 confirmation output so user sees them

## Step 7.7: Spawn Knowledge Pulse (Background)

If `{co}` is resolved and company has a knowledge directory (not `null` in manifest):

```
spawn_task(
  reason: "Pulse-garden {co} knowledge",
  prompt: "Run the knowledge-pulse skill at .claude/skills/knowledge-pulse/SKILL.md.
    company_slug: {co}
    knowledge_path: companies/{co}/knowledge/
    policies_path: companies/{co}/policies/
    caller: prd
    qmd_collection: {qmd_collections[0] from manifest, or omit if none}
    search_results_summary: {condensed list of qmd hits from Step 2, max 10 items — path + title per hit}
    discovered_facts: {new facts from interview answers — especially Batch 4a data model, 5a integrations, any architecture or capability info learned about the company}
    doc_scout_gaps: {postImplementation items from Step 7.6, or 'none'}
    Read the skill file for full instructions."
)
```

Do NOT wait for the pulse to complete — continue immediately to Step 8.

**Skip if:** company has no knowledge directory.

## Step 8: Linear Sync (best-effort, when configured)

If `{co}` is `{product}`, attempt Linear sync. If credentials are unavailable or API fails, skip silently — Linear sync never blocks PRD creation.

1. Read `companies/{product}/settings/linear/credentials.json` and `config.json`
2. Validate `workspace: "{your-tenant}"` in config
3. Create Linear project linked to best-fit initiative, with `leadId` (default: corey) and `targetDate` (default: today+1d)
4. Create issue per story with `assigneeId` (resolved by team routing) and `dueDate` (matches project targetDate)
5. Store all IDs in prd.json: `metadata.linearProjectId`, `metadata.linearCredentials`, per-story `linearIssueId`, `linearAssigneeId`

No orphan issues — every issue must have a `projectId`. If project creation fails, skip issue creation.

## Step 8.5: Resolve Open Questions (Decision Mode)

**HARD BLOCK: PRD is NOT complete until this step finishes.**

Read `metadata.openQuestions[]` from the prd.json just written. **If empty**, skip this step entirely and proceed to Step 9.

**If non-empty:**

1. **Enter plan mode for the resolution.** Announce to the user: `"Open questions remain — entering decision mode."` Use **AskUserQuestion** (NOT free-text questions) so answers are structured and auditable. ToolSearch `select:AskUserQuestion` if it isn't loaded yet.
2. **Batch up to 4 questions per AskUserQuestion call.** For each question, infer **2–3 concrete candidate options** from:
   - The PRD's own metadata (`integrations`, `architectureNotes`, `authModel`, `dataModel`, `rolloutStrategy`, etc.)
   - Prior `metadata.decisions[]` already captured (if re-running)
   - Anchored company policies (e.g. `indigo-aws-credentials-safety` → "Indigo aws_profile (804849608251, us-east-1)")
   - Common-sense defaults ("existing cert" when signing, "existing pool" when auth)
3. **Always append a `"Defer — track as pre-flight story"` option LAST** to every question. Users must be able to opt out of answering any single question without abandoning decision mode entirely.
4. **Write results back to prd.json:**
   - **Answered:** append to `metadata.decisions[]` as `{question, answer, decidedAt: <today ISO date>, decidedBy: <owner name from agents-profile.md>}`. Remove from `metadata.openQuestions[]`.
   - **Deferred:** keep in `metadata.openQuestions[]` but annotate `{deferredAt, deferredReason}`. Generate a new user story `US-000` (or `US-00N` if taken) with:
     - `priority: 1`
     - `labels: ["investigation", "pre-flight"]`
     - `acceptanceCriteria`: `"Investigate <question>, write findings to companies/{co}/projects/{name}/references.md, unblock <dependent story ids>"`
     - `dependsOn`: minimal prerequisites (usually just US-001 or US-002)
     - `notes`: `"Blocks <dependent stories>. Created via /prd Step 8.5 decision-mode deferral."`
   - **Insert the new story at the top of `userStories[]`** and **prepend its id to the `dependsOn[]` of every dependent story** (inferred from the question text — e.g. "Affects US-009 scope" → add to US-009's deps).
5. **Re-derive README.md** from the updated prd.json so the human-readable view reflects the Decisions section + new investigation stories + updated dependencies.
6. **Re-sync orchestrator state** — update `workspace/orchestrator/state.json` for this project: `storiesTotal += <number of new investigation stories>`, bump `updatedAt`.
7. **Re-sync board.json** — bump `companies/{co}/board.json` entry's `updated_at` timestamp (no field changes needed; investigation stories ride under the same project).
8. **Append decision-mode results to journal:**

```bash
.claude/skills/_shared/journal.sh append decisions "Open question resolution: resolved {N} → metadata.decisions[]; deferred {M} → investigation stories; key decisions — {2-3 bullet summary}"
```

9. Only after Step 8.5 completes may Step 9 run.

**Rationale:** Open questions historically drifted into `metadata.openQuestions[]` and were forgotten. Forcing resolution at PRD creation (in plan mode, via AskUserQuestion) catches cost/timeline implications while context is rich, not in the executing agent's downstream session where context is thinner. The "Defer — track as pre-flight story" escape hatch preserves the option to punt without losing traceability.

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

**Then run `/handoff` (or the `handoff` skill) and end the session.** Do NOT proceed to execution.

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
- Batch questions (don't overwhelm)
- **prd.json is the source of truth** — README.md is derived from it, never the reverse
- **All stories start with `passes: false`** — `/run-project` marks them true
- **Planning, not execution** — this skill IS planning for everything except Step 8.5, which uses plan mode + AskUserQuestion to force resolution of open questions before PRD completion
- **Track stories in prd.json** — that is the task list, no separate todo tracking needed
- **HARD BLOCK: Do NOT implement** — ONLY create the PRD files (`companies/{co}/projects/{name}/prd.json` + `README.md`). NEVER edit target files (repos, decks, sites, etc.) during a PRD session. Plan approval = "approved to generate PRD files," NOT "approved to implement." Implementation happens via `/execute-task` or `/run-project` AFTER PRD creation. Violating this bypasses project tracking, worker assignment, handoffs, and quality gates
- **STOP after PRD creation** — After Step 9 confirmation, run the `handoff` skill and end session. NEVER start executing stories, running workers, or writing implementation code in the same session as PRD creation. No exceptions, regardless of project size or user request. If user asks to start immediately, explain that execution requires a fresh session for context isolation (Ralph pattern). prd.json tracks all work for humans and future agent runs — this separation is mandatory
- **Infrastructure before planning** — never create a PRD that references infrastructure (company, repo, knowledge) that doesn't exist. Fix gaps first (Step 2.5)
- **MANDATORY: Always create project files** — Every PRD invocation MUST produce `companies/{co}/projects/{name}/prd.json` and `companies/{co}/projects/{name}/README.md`. No exceptions. These files are how HQ tracks work — they are NOT just inputs for `/run-project`. Never output a PRD to chat only, never skip file creation because the user "just wants a quick plan", never treat file generation as optional. If the user provides enough info to generate stories, write the files
- **Every story MUST have testable acceptance criteria** — "works correctly" is not acceptable
- **Include testing stories** — For deployable projects, at least one story should be dedicated to E2E test infrastructure
- **ALWAYS: Verify board.json write in Step 5.6** — After upserting the board entry, re-read board.json and confirm the new project ID exists. If the write failed silently (file parse error, missing board, manifest lookup miss), log the error and retry once. Silent failure leaves projects invisible in the HQ app — the orphan scanner catches them with an "Unregistered" badge, but proper registration is required
