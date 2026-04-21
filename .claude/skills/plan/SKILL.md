---
name: prd
description: Plan a project and generate PRD for execution. Creates prd.json + README.md with full HQ context awareness. Runtime-agnostic — executes identically in Claude Code and Codex. Adapts interview depth to brainstorm context if available.
allowed-tools: Read, Write, Edit, Grep, Glob, Bash(git:*), Bash(qmd:*), Bash(ls:*), Bash(date:*), Bash(scripts/read-policy-frontmatter.sh:*), Bash(scripts/build-policy-digest.sh:*), Bash(npx:*)
---

# PRD — Project Planning & PRD Generation

Create execution-ready PRDs with full HQ context awareness.

**Important:** Do NOT implement. Just create the PRD.

## Step 0: Company Anchor (from user input)

Check if the **first word** of the user's input matches a company slug in `companies/manifest.yaml`.

**How to check:** Read `companies/manifest.yaml`. Extract top-level keys (company slugs). If the first word exactly matches one of those slugs:

1. **Set `{co}`** = matched slug for the entire flow. Strip the slug — the remaining text is the project description
2. **Announce:** "Anchored on **{co}**"
3. **Load policies (frontmatter-only)** — For each file in `companies/{co}/policies/` (skip `example-policy.md`), run `bash scripts/read-policy-frontmatter.sh {file}`. Note `enforcement: hard` titles. For hard-enforcement policies only, additionally read the `## Rule` section with a targeted range. The SessionStart hook also injects the company policy digest at `companies/{co}/policies/_digest.md` — prefer that if present. Apply as constraints throughout the PRD
4. **Scope qmd searches** — If company has `qmd_collections` in manifest, use `-c {collection}` for all `qmd` calls
5. **Pre-load repos** — Extract `{co}.repos[]` from manifest. Present as repo options in the Architecture tier repo question
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
- Read `workers/registry.yaml` (workers already indexed there — never Glob for worker discovery). Skip if the description is clearly code/infra work not matching a worker skill
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
- If target repo identified, list files in `{repoPath}/.claude/policies/` (if dir exists), then for each run `bash scripts/read-policy-frontmatter.sh {file}`. Prefer the repo digest at `{repoPath}/.claude/policies/_digest.md` if present (SessionStart hook injects it). For hard-enforcement policies, additionally read the `## Rule` section

**Target Repo (if repo specified or discovered):**
- If anchored: company repos already pre-loaded from manifest. Present as options
- If target repo has a qmd collection (e.g. `{product}`): `qmd query "<description keywords>" -c {collection} --json -n 10` — hybrid search for related code, patterns, existing implementations
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
3. **Extract brainstorm context** for use in Step 3.7 (Research) and Step 4 (Interview):
   - `brainstorm.context` — from `## Context` section (problem description, pain points)
   - `brainstorm.recommendation` — from `## Recommendation` section (approach, rationale)
   - `brainstorm.rejectedApproaches` — from rejected/discarded options (anti-patterns to avoid)
   - `brainstorm.unknowns` — from `## What We Don't Know` section (open questions, risks)
   - `brainstorm.techChoices` — any mentioned tech stack, data models, architecture preferences
   - `brainstorm.integrations` — identified external services
   - `brainstorm.workers` — identified relevant workers, repos

4. **Enrich interview questions (NOT collapse to confirmations).** Brainstorm context is added to each question as additional context, but the full question is still asked one-at-a-time:
   - Each question in Step 4 gets a "Brainstorm suggested: {relevant finding}" line added to the question text, alongside the standard options
   - The user still answers the full question — brainstorm context informs their answer, it doesn't replace the question
   - Example: STRATEGIC-1 (Demand Reality) shows "Brainstorm suggested: {brainstorm.context pain points}" but still asks the full question and expects a specific answer

5. **Mandatory questions from brainstorm unknowns.** Items from `brainstorm.unknowns` ("What We Don't Know") become **mandatory interview questions that cannot be smart-skipped**, regardless of research findings. These represent gaps the brainstorm session explicitly identified as unresolved. For each unknown:
   - Map to the closest Question Bank question (e.g., an unknown about auth → ARCHITECTURE-2)
   - If no close match, add as an ad-hoc question in the relevant tier
   - Mark as `mandatory: true` in the question tracking — smart-skip logic is bypassed

6. **Higher smart-skip threshold with brainstorm.** When brainstorm.md exists, the smart-skip condition for any question requires **both** brainstorm AND research to clearly answer the question with consistent, unambiguous findings. If brainstorm says one thing and research says another, the question must be asked to resolve the conflict.

7. **Research agents incorporate brainstorm.** Step 3.7's Agent 2 (HQ Context Scanner) already includes brainstorm enrichment in its prompt (see `{brainstorm_context}` variable). When brainstorm.md is detected here, that variable is populated with the brainstorm's recommended approach, rejected approaches, and open questions — so the research brief reflects brainstorm context.

**Effect:** Interview depth is preserved even with brainstorm. Questions are richer (pre-loaded with brainstorm context as suggested answers) but still asked in full. The brainstorm's explicit unknowns become mandatory deep-dives. This prevents the "brainstorm answered everything → shallow PRD" failure mode.

**If not found:** proceed normally (no change to existing behavior). All smart-skip thresholds use the default (research-only) conditions.

## Step 3.7: Research Phase (Phase 1 — Subagents)

Before asking interview questions, gather context via parallel research subagents. Research artifacts persist to disk (not chat) so they survive session handoffs and are available to execution workers.

**Output directory:** `{project_dir}/research/` (alongside `brainstorm.md` and `prd.json`). Where `{project_dir}` = `companies/{co}/projects/{slug}/` or `projects/{slug}/` for personal/HQ projects.

```bash
mkdir -p {project_dir}/research
```

### Agent Dispatch

Spawn agents in parallel using the Agent tool. Each agent writes its findings to a specific file. The main session waits for all agents to complete before proceeding.

**Resolve `{repoPath}`** from Step 2 context (company manifest repos, user input, or brainstorm references). If no repo is identifiable, set `{repoPath} = null`.

| Agent | Condition | Output |
|-------|-----------|--------|
| Codebase Scanner | `{repoPath}` exists | `research/codebase-scan.md` |
| HQ Context Scanner | Always | `research/hq-context.md` |
| Repo Deep-Read | `{repoPath}` exists | `research/repo-analysis.md` |

**If `{repoPath}` is null** (non-code project): only spawn Agent 2 (HQ Context). Skip Agents 1 and 3.

---

#### Agent 1 — Codebase Scanner

```
Spawn Agent (subagent_type: Explore) with prompt:

"Scan the repository at {repoPath} to understand its architecture for a new project: '{description}'.

Search for and document:
1. **Project structure**: Read CLAUDE.md (if exists), package.json/Cargo.toml/go.mod, and top-level directory layout
2. **Tech stack**: Framework, language version, ORM/DB client, auth system, CSS approach, test framework
3. **Existing patterns**: How are routes/endpoints structured? How are components organized? What naming conventions are used?
4. **Data models**: Read schema files, migration directories, or type definitions for existing entities
5. **Auth system**: How is authentication handled? What middleware/guards exist? What roles are defined?
6. **Key integrations**: External services already wired up (Stripe, SendGrid, analytics, etc.)

Write a structured markdown report to: {project_dir}/research/codebase-scan.md

Format:
# Codebase Scan: {repo name}

## Tech Stack
- Framework: ...
- Language: ...
- Database: ...
- Auth: ...
- Testing: ...

## Architecture Patterns
(describe routing, component, and data patterns)

## Existing Data Models
(list entities with key fields and relationships)

## Integrations
(list external services with how they're connected)

## Relevant Existing Code
(files/patterns directly relevant to: '{description}')

Keep the report factual and concise — no recommendations, just findings."
```

#### Agent 2 — HQ Context Scanner

```
Spawn Agent (subagent_type: Explore) with prompt:

"Scan HQ context for a new project '{slug}' ({description}) for company '{co}'.

Search for:
1. **Existing projects**: Read companies/{co}/projects/ — list any related or overlapping projects with their status
2. **Company workers**: Read companies/{co}/workers/ (if exists) + workers/registry.yaml — list workers relevant to this project's domain
3. **Company knowledge**: Search companies/{co}/knowledge/ for documents related to '{description keywords}'
4. **Company policies**: List companies/{co}/policies/ — note any hard-enforcement policies that constrain this project
5. **Related repos**: Check companies/manifest.yaml for {co}'s repos — note which might be relevant
{brainstorm_context}

Write a structured markdown report to: {project_dir}/research/hq-context.md

Format:
# HQ Context: {slug}

## Related Projects
(list with status and overlap description, or 'None found')

## Relevant Workers
(list with skills that apply)

## Knowledge Base Findings
(relevant docs with paths)

## Applicable Policies
(hard-enforcement policies with rule summaries)

## Available Repos
(company repos from manifest)

## Brainstorm Findings
(if brainstorm.md exists: recommended approach, rejected approaches, open questions — otherwise 'No brainstorm')

Keep the report factual and concise — no recommendations, just findings."
```

**Brainstorm enrichment:** If brainstorm.md was detected in Step 3.5, append to the Agent 2 prompt:
```
{brainstorm_context} = "
6. **Brainstorm context**: Read {project_dir}/brainstorm.md — extract:
   - Recommended approach and its rationale
   - Rejected approaches and why
   - 'What We Don't Know' items (open questions)
   - Any mentioned tech choices, data models, or architecture preferences
"
```
If no brainstorm: `{brainstorm_context} = ""`

#### Agent 3 — Repo Deep-Read

```
Spawn Agent (subagent_type: Explore) with prompt:

"Deep-read the repository at {repoPath} for recent activity and test patterns relevant to: '{description}'.

Search for:
1. **Recent git history**: Run `git log --oneline -30` — summarize recent development themes and active areas
2. **Test structure**: Find test directories, test file patterns, test commands in package.json/scripts. Note coverage configuration if present
3. **Recent changes**: Run `git diff --stat HEAD~10` — what files are actively being modified?
4. **CI/CD**: Check .github/workflows/, vercel.json, Dockerfile, deploy scripts — document the deployment pipeline
5. **Open issues/branches**: Run `git branch -r --list 'origin/feature/*'` — note active feature work that might conflict

Write a structured markdown report to: {project_dir}/research/repo-analysis.md

Format:
# Repo Analysis: {repo name}

## Recent Development
(themes from last 30 commits)

## Active Areas
(files/directories with most recent changes)

## Test Infrastructure
- Framework: ...
- Test command: ...
- Coverage: ...
- Test directories: ...

## CI/CD Pipeline
(deployment pipeline description)

## Active Branches
(feature branches that might overlap with this project)

Keep the report factual and concise — no recommendations, just findings."
```

### Synthesis — Research Brief

After all agents complete, the main session reads the research files and writes a compact synthesis:

1. Read all files in `{project_dir}/research/` that were written by agents
2. Synthesize into `{project_dir}/research/research-brief.md`:

```markdown
# Research Brief: {slug}

## Key Findings
- {3-5 bullet points of most important discoveries across all agents}

## Pre-Answered Questions
(questions from the Question Bank that research already answers — list question ID + finding)

## Open Questions Surfaced
(new questions raised by research that should be asked during interview)

## Constraints Discovered
(hard policies, existing patterns, or technical constraints that limit options)

## Brainstorm Alignment
(if brainstorm exists: how research findings align/conflict with brainstorm's recommendation — otherwise omit)
```

3. Display to user: "Research complete. {N} findings across {agent count} scans. Key constraints: {list}."

**The research brief is the primary input for smart-skip logic in Step 4.** When a question's smart-skip condition references "research," it means checking `research-brief.md` for pre-answered questions.

## Step 4: Deep Interview (Phase 2 — One-at-a-Time)

Sequential one-at-a-time questioning using the Question Bank (see bottom of this file). Each question is asked via **AskUserQuestion** with 2-4 concrete options + a free text override. Questions are asked one at a time — never batched.

**Minimum:** 10 questions asked (including smart-skip confirmations). **Target:** 15. Track count throughout.

### Interview Rules

1. **One question at a time.** Ask a single question via AskUserQuestion. Wait for the response. Process it. Then ask the next question. Never combine multiple questions into one AskUserQuestion call.

2. **Pushback on vague answers.** If the user's response matches the question's pushback pattern (vague, category-level, non-specific), push back **once** with the defined follow-up. After the pushback response, accept whatever the user provides — never push more than once per question.

3. **Anti-sycophancy.** Never say "that's interesting," "great idea," "love that," or similar flattery. Instead, **take a position** on every answer: "That narrows scope well," "I'd challenge that — {reason}," "Strong signal — the pain is quantified." React substantively or move on silently.

4. **Smart-skip logic.** Before asking each question, check its smart-skip condition against:
   - `{project_dir}/research/research-brief.md` (from Step 3.7)
   - `{project_dir}/brainstorm.md` (from Step 3.5, if exists)
   - Prior answers from earlier questions in this interview
   If the smart-skip condition is met, present the question's **confirmation format** instead of the full question. Confirmations still count toward the question minimum. Use AskUserQuestion with options: `["Confirm", "Modify — {free text}"]`.

5. **CEO cognitive patterns as evaluation lenses.** Do NOT ask these as explicit questions. Instead, apply them silently when evaluating answers and formulating follow-ups:
   - **Bezos one-way vs two-way doors**: When the user describes architecture or rollout, classify the reversibility internally. Surface it in QUALITY-4 if the user proposes a one-way door without a rollback plan.
   - **Inversion reflex**: When evaluating scope answers, silently ask "what would make this fail?" Use the inversion to inform pushback — e.g., "You've described the happy path. What's the most likely failure mode?"
   - **Focus as subtraction**: When scope seems broad, apply "the primary value of this project is what it does NOT do." Push toward narrower scope in STRATEGIC-4.
   - **Speed calibration**: For two-way door decisions, don't over-question. Accept 70% confidence and move on. Reserve deep questioning for irreversible choices.

### Context Enrichment

Use context gathered in Step 2 (company policies, repo policies, manifest) and Step 3.7 (research) to **enrich each question** with specific details. Weave enrichments into the question text naturally — don't dump detected context separately.

**Enrichment sources:**
- **Research brief** (`research/research-brief.md`): tech stack findings, existing patterns, data models → enrich ARCHITECTURE-1 through ARCHITECTURE-5 with specific repo details
- **Company policies** (`companies/{co}/policies/`): hard-enforcement constraints → surface as "Note: company policy requires {X}" in relevant questions
- **Repo scan** (from research agents): auth system, ORM, test framework, CI → pre-fill options with detected specifics (e.g., "Uses existing Clerk auth via @clerk/nextjs")
- **Manifest** (`companies/manifest.yaml`): services, Vercel team, integrations → enrich integration and deployment questions

If enrichment **fully answers** a question, present as confirmation (same as smart-skip): "Research found {X}. Confirm or modify?"

### Project Type Classification

After the Strategic tier (questions 1-5), classify the project type to determine which Architecture and Quality questions to ask:

- **Code project** (has repoPath, or code/app/API/feature keywords) — ask all tiers
- **Content/knowledge/report** — skip ARCHITECTURE-1 through ARCHITECTURE-5; skip QUALITY-2, QUALITY-3, QUALITY-4. Ask QUALITY-1 and QUALITY-5 only
- **Personal/HQ tooling** — skip ARCHITECTURE-2 (auth), ARCHITECTURE-5 (scale); ask rest

Note skips: "(Skipping {question} — {reason})"

### Interview Sequence

#### Tier 1 — Strategic (5 questions)

Ask questions STRATEGIC-1 through STRATEGIC-5 from the Question Bank, in order. Each via AskUserQuestion.

**After STRATEGIC-5 (Premise Challenge):** This question generates 2-4 premises. Present each premise via AskUserQuestion with options: `["Agree", "Disagree", "Not sure — needs investigation"]`. Premises flagged as "not sure" become mandatory investigation items surfaced in metadata.openQuestions.

**After Strategic tier completes:** Classify project type (see above). Announce: "Strategic tier complete ({N}/10 minimum). Moving to Architecture."

#### Tier 2 — Architecture (5 questions, conditional)

Ask questions ARCHITECTURE-1 through ARCHITECTURE-5, skipping per project type classification. Each via AskUserQuestion.

**After Architecture tier completes:** Announce: "Architecture tier complete ({N}/10 minimum). Moving to Quality."

#### Tier 3 — Quality (5 questions, conditional)

Ask questions QUALITY-1 through QUALITY-5, skipping per project type classification. Each via AskUserQuestion.

### Escape Hatch

**After question 10** (regardless of which tier you're in), present an escape hatch via AskUserQuestion:

```
"10 questions answered — minimum met. {remaining} questions remain in the bank."
Options:
A. "Continue to remaining questions" (recommended for code projects)
B. "Generate PRD now — enough context gathered"
```

If user chooses B, skip remaining questions and proceed to Step 4.5. If A, continue through remaining questions. Present the escape hatch again after question 13 if questions remain.

### Step 4.5: Metadata Extraction + Operational Questions

After the Question Bank interview completes (or user escapes), extract prd.json metadata from the answers and ask remaining operational questions not covered by the Question Bank.

**Metadata extraction** — Map interview answers to prd.json fields. This is done automatically by the skill (no user interaction needed):

| Interview Source | prd.json Field |
|-----------------|----------------|
| STRATEGIC-1 (Demand Reality) | `metadata.goal` |
| STRATEGIC-2 (Status Quo Teardown) | `metadata.currentSolution` |
| STRATEGIC-3 (Desperate Specificity) | `metadata.audiences` |
| STRATEGIC-4 (Narrowest Wedge) | `metadata.nonGoals` (from excluded scope) |
| STRATEGIC-5 (Premise Challenge) | `metadata.openQuestions` (from "not sure" premises) |
| ARCHITECTURE-1 (Data Model) | `metadata.dataModel` |
| ARCHITECTURE-2 (Auth) | `metadata.authModel` |
| ARCHITECTURE-3 (Error Handling) | `metadata.architectureNotes` (append) |
| ARCHITECTURE-4 (Component Boundaries) | `metadata.architectureNotes` (append) |
| ARCHITECTURE-5 (Performance) | `metadata.performanceRequirements` |
| QUALITY-1 (Testing) | drives `e2eTests` per story |
| QUALITY-2 (Quality Gates) | `metadata.qualityGates` |
| QUALITY-3 (Monitoring) | `metadata.monitoringNotes` |
| QUALITY-4 (Rollout) | `metadata.rolloutStrategy` |
| QUALITY-5 (Success Criteria) | `metadata.successCriteria` |

**Operational questions** — Ask these via AskUserQuestion only if not already answered by research or interview context. Skip any that research or prior answers already resolve:

1. **Repo path** (if not yet resolved): "Which repo does this target?" Options: list from manifest + "None — non-code project" + free text
2. **Branch name**: "Branch name?" Default: `feature/{slug}`. Options: `["feature/{slug}", "Custom — {free text}"]`
3. **Base branch**: "Base branch?" Default: `main`. Options from repo's branches if known
4. **Workers**: "Research found these relevant workers: {list}. Use them?" Options: `["Yes — use suggested workers", "Modify list — {free text}", "No workers — direct execution"]`
5. **Design reference** (UI projects only): "Any design reference?" Options: `["Figma file (provide ID)", "Visual reference", "Follow existing design system", "No constraints", "Not a UI project"]`
6. **Integrations** (if not covered by ARCHITECTURE questions): "External integrations?" Options: `["None", "Existing — {list from research}", "New — {free text}"]`
7. **Analytics** (deployable UI only): "Analytics tracking needed?" Options: `["No", "Use existing {system}", "New events needed — {free text}"]`
8. **E2E tests**: "What E2E tests should verify each story?" For each planned story, ask for Given/When/Then assertions. Options: `["Define tests per story", "Skip — non-deployable project"]`

Display: "Interview complete. {N} questions asked across {tiers answered} tiers. Generating PRD..."

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
      "model_hint": ""
    }
  ],
  "metadata": {
    "createdAt": "{ISO8601}",
    "goal": "{Overall project goal}",
    "successCriteria": "{Measurable outcome}",
    "qualityGates": ["{from QUALITY-2 — gate commands}"],
    "repoPath": "{repos/private/repo-name or empty}",
    "baseBranch": "{main or staging or master}",
    "relatedWorkers": ["{worker-ids from scan}"],
    "knowledge": ["{relevant knowledge paths}"],
    "audiences": ["{from STRATEGIC-3 — user roles + technical level}"],
    "currentSolution": "{from STRATEGIC-2 — what exists today}",
    "designRef": "{from operational questions — Figma ID, reference, or empty}",
    "nonGoals": ["{from STRATEGIC-4 — explicit out-of-scope items}"],
    "dataModel": "{from ARCHITECTURE-1 — key entities/tables or empty}",
    "authModel": "{from ARCHITECTURE-2 — auth approach or empty}",
    "architectureNotes": "{from ARCHITECTURE-3/4 — approach or empty}",
    "performanceRequirements": "{from ARCHITECTURE-5 — targets or empty}",
    "integrations": ["{from operational questions — service name, type, credentialsReady}"],
    "securityNotes": "{from ARCHITECTURE-2/3 — PII/compliance notes or empty}",
    "rolloutStrategy": "{from QUALITY-4 — ship strategy or empty}",
    "analyticsEvents": ["{from operational questions — event names or empty}"],
    "monitoringNotes": "{from QUALITY-3 — prod monitoring plan or empty}",
    "openQuestions": ["{remaining unresolved questions — Step 8.5 resolves these before Step 9}"],
    "decisions": []
  }
}
```

**`decisions[]` schema:** Appended by Step 8.5 as `{question, answer, decidedAt, decidedBy}`. Optional — absent means empty. Additive and backwards-compatible; existing PRDs without the field are unaffected.

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
{metadata.nonGoals — from STRATEGIC-4 excluded scope. If empty, state "None defined"}

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

## Step 5.1: Spec Review (Phase 3 — Adversarial Review Loop)

After prd.json and README.md are generated, spawn an adversarial spec review subagent to catch completeness and consistency issues before finalization. This is the quality gate between generation and publication.

### Review Subagent

Spawn a single Agent subagent with the following prompt:

```
Spawn Agent with prompt:

"You are an adversarial spec reviewer. Your job is to find problems, not praise.

Read the PRD at: {project_dir}/prd.json
Also read: {project_dir}/README.md

Review on 5 dimensions. For each, score 1-10 and list specific issues:

1. **Completeness** — Are all requirements from the interview addressed in stories? Are there gaps between metadata fields and story ACs? Does every story have testable ACs?

2. **Consistency** — Do stories agree with each other? Do ACs contradict metadata? Does the dependency graph make sense (no circular deps, no missing deps)? Do file lists overlap in conflicting ways?

3. **Clarity** — Could a developer implement each story without asking questions? Are ACs specific enough to verify? Is the metadata unambiguous?

4. **Scope (YAGNI)** — Are there stories that go beyond the stated goal? Are there ACs that add unnecessary complexity? Is the MVP actually minimal?

5. **Feasibility** — Is each story completable in one AI session? Are complexity scores (AC count × 1 + file count × 2) under 20? Are there stories that assume capabilities that don't exist?

Return a JSON object:
{
  \"qualityScore\": <1-10 overall>,
  \"dimensions\": {
    \"completeness\": { \"score\": <1-10>, \"issues\": [\"...\"] },
    \"consistency\": { \"score\": <1-10>, \"issues\": [\"...\"] },
    \"clarity\": { \"score\": <1-10>, \"issues\": [\"...\"] },
    \"scope\": { \"score\": <1-10>, \"issues\": [\"...\"] },
    \"feasibility\": { \"score\": <1-10>, \"issues\": [\"...\"] }
  },
  \"suggestedFixes\": [
    { \"dimension\": \"...\", \"issue\": \"...\", \"fix\": \"...\" }
  ]
}

Be harsh. A quality PRD should score 8+. Common failure modes:
- Stories with 'works correctly' ACs (not testable)
- Missing error handling stories for critical paths
- Scope creep disguised as 'nice to have' ACs
- Dependency chains that force serial execution when parallel is possible
- Stories that modify 10+ files (should be split)
"
```

### Review Loop

1. **Parse response.** Extract qualityScore, issues, and suggestedFixes from the subagent's return.

2. **If issues found (suggestedFixes is non-empty):**
   - Apply each fix to prd.json (edit ACs, add missing stories, fix dependencies, etc.)
   - Re-derive README.md from the updated prd.json
   - Re-dispatch the review subagent with the updated files
   - **Maximum 3 iterations.** Track iteration count.

3. **Convergence guard.** If the same issues persist across 2+ iterations (same dimension + similar issue text), stop iterating. Persist unresolved issues as a **"Reviewer Concerns"** section appended to README.md:
   ```markdown
   ## Reviewer Concerns
   The following issues were flagged during spec review but could not be auto-resolved:
   - [{dimension}] {issue description}
   ```

4. **On subagent failure** (error, timeout, malformed response): Skip review entirely. Tell the user: "Spec review unavailable — presenting unreviewed PRD." Do NOT block PRD creation on review failure. No artificial timeout — let the subagent run to completion.

5. **Display summary to user:**
   ```
   PRD survived {N} round(s) of review. {M} issues caught and fixed. Quality score: {X}/10.
   ```
   If issues were persisted as Reviewer Concerns: "({K} unresolved concerns noted in README.md)"

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
npx tsx scripts/prd-to-beads.ts --project={name}
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

**Update INDEX.md:** Regenerate `companies/{co}/projects/INDEX.md` per `knowledge/public/hq-core/index-md-spec.md`.

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
    discovered_facts: {new facts from interview answers — especially ARCHITECTURE-1 data model, operational integrations, any architecture or capability info learned about the company}
    doc_scout_gaps: {postImplementation items from Step 7.6, or 'none'}
    Read the skill file for full instructions."
)
```

Do NOT wait for the pulse to complete — continue immediately to Step 8.

**Skip if:** company has no knowledge directory.

## Step 8: Linear Sync (best-effort, {Product}/Voyage only)

If `{co}` is `{product}`, attempt Linear sync. If credentials are unavailable or API fails, skip silently — Linear sync never blocks PRD creation.

1. Read `companies/{product}/settings/linear/credentials.json` and `config.json`
2. Validate `workspace: "voyage"` in config
3. Create Linear project linked to best-fit initiative, with `leadId` (default: {your-name}) and `targetDate` (default: today+1d)
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
   - Anchored company policies (e.g. `{company}-aws-credentials-safety` → "{company} aws_profile (804849608251, us-east-1)")
   - Common-sense defaults ("existing cert" when signing, "existing pool" when auth)
3. **Always append a `"Defer — track as pre-flight story"` option LAST** to every question. Users must be able to opt out of answering any single question without abandoning decision mode entirely.
4. **Write results back to prd.json:**
   - **Answered:** append to `metadata.decisions[]` as `{question, answer, decidedAt: <today ISO date>, decidedBy: <owner name from agents-profile.md>}`. Remove from `metadata.openQuestions[]`.
   - **Deferred:** keep in `metadata.openQuestions[]` but annotate `{deferredAt, deferredReason}`. Generate a new user story `US-000` (or `US-00N` if taken) with:
     - `priority: 1`
     - `labels: ["investigation", "pre-flight"]`
     - `acceptanceCriteria`: `"Investigate <question>, write findings to companies/{co}/projects/{name}/references.md, unblock <dependent story ids>"`
     - `dependsOn`: minimal prerequisites (usually just US-001 or US-002)
     - `notes`: `"Blocks <dependent stories>. Created via /plan Step 8.5 decision-mode deferral."`
   - **Insert the new story at the top of `userStories[]`** and **prepend its id to the `dependsOn[]` of every dependent story** (inferred from the question text — e.g. "Affects US-009 scope" → add to US-009's deps).
5. **Re-derive README.md** from the updated prd.json so the human-readable view reflects the Decisions section + new investigation stories + updated dependencies.
6. **Re-sync orchestrator state** — update `workspace/orchestrator/state.json` for this project: `storiesTotal += <number of new investigation stories>`, bump `updatedAt`.
7. **Re-sync board.json** — bump `companies/{co}/board.json` entry's `updated_at` timestamp (no field changes needed; investigation stories ride under the same project).
8. Only after Step 8.5 completes may Step 9 run.

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
- One question at a time (don't overwhelm)
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

## Question Bank

Structured question definitions organized into three tiers: Strategic (problem validation + scope control), Architecture (technical design decisions), and Quality (testing, monitoring, shipping). Each question includes pushback patterns, smart-skip conditions, and confirmation formats for brainstorm-aware interviews.

Total: 15 questions (5 Strategic + 5 Architecture + 5 Quality).

---

### STRATEGIC-1: Demand Reality

- **Question:** "What is the strongest evidence this project needs to exist? Point to specific pain — time wasted, money lost, errors caused, users blocked."
- **Pushback pattern:**
  - Vague answer: "It would be nice to have" / "People have been asking for it" / "The market is moving this way"
  - Push: "Name one person who lost time or money because this didn't exist last week. What did it cost them? If you can't point to a specific incident, what makes you confident the pain is real?"
- **Smart-skip condition:** Brainstorm `## Context` contains quantified pain (hours lost, error rates, revenue impact, support tickets). Skip if evidence is concrete and sourced.
- **Confirmation format:** "Based on brainstorm: {extracted pain point with numbers}. Confirm or modify?"

### STRATEGIC-2: Status Quo Teardown

- **Question:** "What do users do today to solve this — even badly? Walk me through the current workflow step by step, including the duct tape."
- **Pushback pattern:**
  - Vague answer: "Nothing exists" / "They don't have a solution" / "They use spreadsheets"
  - Push: "If truly nothing exists, the pain might not be acute enough to act on. If they use spreadsheets, show me the spreadsheet — what columns, how many rows, how often do they touch it? The current hack reveals what the solution must beat."
- **Smart-skip condition:** Brainstorm documents a specific current workflow with named tools, steps, and failure modes. Skip if the teardown is already thorough.
- **Confirmation format:** "Based on brainstorm: current workflow is {steps using tools X, Y, Z — breaks when W}. Confirm or modify?"

### STRATEGIC-3: Desperate Specificity

- **Question:** "Who is the single most desperate user for this? Not a category — a specific person, role, and the consequence they face without it."
- **Pushback pattern:**
  - Vague answer: "Marketing teams" / "SMBs" / "Enterprise customers" / "Internal users"
  - Push: "Give me a name or a job title with a day-in-the-life. What does this person do at 9 AM Monday that this project changes? Category-level answers hide whether anyone actually needs this urgently."
- **Smart-skip condition:** Brainstorm `## Context` or a prior STRATEGIC answer already names a specific role with described workflow impact. Skip if a concrete persona is established.
- **Confirmation format:** "Based on brainstorm: primary user is {role/name} who currently {painful workflow}. Confirm or modify?"

### STRATEGIC-4: Narrowest Wedge

- **Question:** "What is the absolute smallest version that delivers real value? One feature, one workflow, one screen — what's the wedge?"
- **Pushback pattern:**
  - Vague answer: "We need the full platform to be useful" / "It won't be differentiated without X, Y, and Z" / "Users expect a complete solution"
  - Push: "If you can't ship value with one feature, the scope is hiding unclear priorities. Which single capability, if it worked perfectly, would make someone switch from their current duct-tape solution? That's the wedge — everything else is Phase 2."
- **Smart-skip condition:** Brainstorm `## Recommendation` already defines a scoped MVP with explicit cut lines, or a prior STRATEGIC answer produced a tight scope with non-goals. Skip if scope is already minimal and justified.
- **Confirmation format:** "Based on brainstorm: MVP is {scoped feature/workflow}. Non-goals: {list}. Confirm or modify?"

### STRATEGIC-5: Premise Challenge

- **Question:** "I'm going to state 2-4 premises this project assumes. For each, tell me: agree, disagree, or 'not sure — needs investigation.'"
- **Pushback pattern:**
  - Vague answer: "Yeah, those all sound right" (blanket agreement without engagement)
  - Push: "Blanket agreement worries me — at least one of these should feel uncomfortable or uncertain. Which premise are you least confident about? That's where the risk lives. If all premises are obviously true, we might be solving a problem that's already solved."
- **Smart-skip condition:** Brainstorm `## What We Don't Know` already surfaces key assumptions with risk assessments. Skip only if the brainstorm explicitly validated or invalidated the core premises. Otherwise, always run — premises shift between brainstorm and PRD scoping.
- **Confirmation format:** "Premises from brainstorm analysis: (1) {premise — status}. (2) {premise — status}. Confirm each or flag for investigation."

---

### ARCHITECTURE-1: Data Model + Shadow Paths

- **Question:** "What are the key data entities this project introduces or modifies? For each entity, trace the data path: INPUT (where does it enter?) -> VALIDATE (what can go wrong?) -> TRANSFORM (what changes?) -> PERSIST (where does it land?) -> OUTPUT (who sees it and how?)."
- **Pushback pattern:**
  - Vague answer: "We'll have a users table and a settings table" / "Standard CRUD" / "We'll figure out the schema later"
  - Push: "Walk me through one concrete record. A user submits X — what happens at each stage? Where can it fail silently? What happens to orphaned records if a step fails halfway? The shadow paths (partial writes, race conditions, cascading deletes) are where production bugs hide."
- **Smart-skip condition:** Brainstorm or research-brief already provides entity definitions with relationships, and the project modifies an existing well-documented schema. Skip if entities + relationships are clear and the repo already has migration patterns.
- **Confirmation format:** "Based on brainstorm/interview: key entities are {list with relationships}. Data flow: {INPUT->OUTPUT summary}. Confirm or modify?"

### ARCHITECTURE-2: Auth + Permissions Model

- **Question:** "Who can do what, and how do you enforce it? Map every user role to its allowed actions. What happens when someone tries something they shouldn't?"
- **Pushback pattern:**
  - Vague answer: "We'll use the existing auth" / "Admin and regular users" / "We'll add permissions later"
  - Push: "Using existing auth is fine — but does this project introduce new resources that need new permission checks? List every action this project adds and mark who can perform it. 'Admin and regular users' isn't a model — it's a sketch. What's the third role you haven't thought of yet (support staff, API consumers, automated systems)?"
- **Smart-skip condition:** Project uses existing auth with no new resources/actions (confirmed in research-brief or prior answer), or project has no auth. Skip if no new permission boundaries are introduced.
- **Confirmation format:** "Based on interview: {auth system} handles auth. New actions: {list or 'none — existing coverage sufficient'}. Confirm or modify?"

### ARCHITECTURE-3: Error Handling + Failure Modes

- **Question:** "For every operation that can fail (API calls, DB writes, external services, user input), what's the rescue action? What does the user see? What gets logged? What gets retried?"
- **Pushback pattern:**
  - Vague answer: "We'll show error messages" / "Standard error handling" / "We'll add try-catch blocks"
  - Push: "Pick the most critical operation in this project. Now: network times out mid-operation — what state is the data in? User refreshes — do they see a broken half-state or a clean recovery? 'Standard error handling' means 'I haven't thought about failures yet.' Every external call needs an explicit rescue plan."
- **Smart-skip condition:** Project is purely UI/content with no external service calls, no DB writes, and no async operations. Skip if the project cannot produce partial-failure states.
- **Confirmation format:** "Based on architecture: critical failure points are {list}. Rescue strategy: {retry/rollback/user notification pattern}. Confirm or modify?"

### ARCHITECTURE-4: Component Boundaries + Coupling

- **Question:** "Draw the component boundaries. What talks to what? Where are the coupling points that would force cascade changes if one component evolves? Are there single points of failure?"
- **Pushback pattern:**
  - Vague answer: "Frontend talks to backend talks to database" / "Microservices" / "We'll follow existing patterns"
  - Push: "Following existing patterns is a fine starting point — name the pattern. Now: if requirement X changes next month, which files change? If the answer is 'everything,' the boundaries are wrong. Identify the one component that, if it goes down, takes the whole feature with it — that's your single point of failure. What's the mitigation?"
- **Smart-skip condition:** Project is a small addition to an existing well-structured codebase (< 3 new files), confirmed by research-brief codebase scan, with no new service boundaries. Skip if it's purely additive within established patterns.
- **Confirmation format:** "Based on interview: follows {existing pattern} in {repo}. New components: {list or 'none — fits existing structure'}. Confirm or modify?"

### ARCHITECTURE-5: Performance + Scale Considerations

- **Question:** "What are the realistic performance constraints? Expected data volume (rows, requests/sec, payload sizes), latency requirements, and the operation most likely to become a bottleneck at 10x current scale."
- **Pushback pattern:**
  - Vague answer: "It needs to be fast" / "Performance isn't a concern right now" / "We'll optimize later"
  - Push: "Name the heaviest query or operation this project introduces. How many rows does it scan? Does it run on every page load or once per session? 'Optimize later' is fine for premature optimization, but N+1 queries and missing indexes are architecture decisions — not optimizations. What's the one thing that will break first at 10x scale?"
- **Smart-skip condition:** Project is internal tooling with < 10 users and no real-time requirements (confirmed by STRATEGIC-3 audience answer and project type classification). Skip if scale is genuinely not a factor.
- **Confirmation format:** "Based on interview: {standard perf / specific targets}. Expected volume: {estimate}. Likely bottleneck: {operation or 'none identified'}. Confirm or modify?"

---

### QUALITY-1: Testing Strategy

- **Question:** "What's the testing plan? For each story, what test type covers it (unit, integration, E2E)? What's the coverage target for critical paths? What framework and runner will you use?"
- **Pushback pattern:**
  - Vague answer: "We'll write tests" / "100% coverage" / "We'll add tests at the end"
  - Push: "100% coverage is a vanity metric — what's the critical path that MUST have coverage? Name the one user flow that, if broken in production, causes the most damage. That flow gets E2E coverage first. 'Add tests at the end' means 'no tests' — testing strategy is decided now, not after the code is written."
- **Smart-skip condition:** Operational question 8 (E2E tests) already produced specific test definitions per story, and the repo has an established test framework (detected in research-brief). Skip if test infrastructure + story-level tests are already defined.
- **Confirmation format:** "Based on interview: E2E tests defined for {N} stories using {framework}. Critical path: {flow}. Confirm or modify?"

### QUALITY-2: Quality Gates + CI

- **Question:** "What commands must pass before code merges? Typecheck, lint, test suite, build verification — list every gate. What's the CI pipeline?"
- **Pushback pattern:**
  - Vague answer: "We'll use CI" / "Standard checks" / "GitHub Actions"
  - Push: "Name the exact commands. `pnpm typecheck && pnpm lint && pnpm test` — or what? 'Standard checks' means different things in every repo. If the repo already has CI, confirm the existing gates are sufficient for this project's new code. If not, what's missing?"
- **Smart-skip condition:** Research-brief already detected CI config (`.github/workflows/`, `vercel.json`, etc.) with exact gate commands. Skip if gates are explicitly defined and repo has existing CI.
- **Confirmation format:** "Based on interview: quality gates are `{commands}`. CI: {existing pipeline or 'needs setup'}. Confirm or modify?"

### QUALITY-3: Monitoring + Observability

- **Question:** "Once this ships, how do you know it's working? What gets logged, what triggers an alert, and what dashboard do you check Monday morning?"
- **Pushback pattern:**
  - Vague answer: "We'll monitor it" / "We have logging" / "We'll check the logs if something breaks"
  - Push: "If a user hits an error at 3 AM, how long until you know? 'Check the logs if something breaks' means you find out when a user complains. Name the specific metric or log pattern that tells you this feature is healthy — and what threshold triggers a human looking at it."
- **Smart-skip condition:** Research-brief detected existing observability (Sentry, Datadog, etc.) in the repo, and the project doesn't introduce new failure surfaces beyond existing monitoring coverage. Skip if monitoring plan is concrete.
- **Confirmation format:** "Based on interview: monitoring via {system}. Key health signal: {metric/log pattern}. Alert threshold: {condition or 'existing coverage sufficient'}. Confirm or modify?"

### QUALITY-4: Rollout + Risk Mitigation

- **Question:** "What's the rollout plan? Ship to everyone at once, feature flag, staged rollout, internal-first? If it goes wrong, what's the rollback plan — and how fast can you execute it?"
- **Pushback pattern:**
  - Vague answer: "We'll just deploy it" / "Feature flag" (without specifics) / "We can always revert"
  - Push: "Feature flag how — env var, LaunchDarkly, database toggle, user segment? 'We can always revert' — how long does a revert take? 60 seconds or 60 minutes? If this touches database migrations, revert isn't simple — what's the data migration rollback plan? For two-way-door decisions, ship fast. For one-way doors (schema changes, data migrations, external API contracts), spell out the rollback."
- **Smart-skip condition:** Research-brief or brainstorm already specified a concrete rollout strategy with mechanism details, or the project is internal tooling with no production users. Skip if rollout is fully specified or risk is negligible.
- **Confirmation format:** "Based on interview: rollout via {strategy}. Rollback plan: {mechanism, estimated time}. Decision type: {one-way/two-way door}. Confirm or modify?"

### QUALITY-5: Success Criteria + Definition of Done

- **Question:** "How do you know this project succeeded — not 'shipped,' but actually worked? What metric moves, what behavior changes, or what becomes possible that wasn't before? Define the measurement and the timeframe."
- **Pushback pattern:**
  - Vague answer: "Users like it" / "It works" / "We hit our deadline" / "No bugs reported"
  - Push: "Shipping on time with zero bugs is necessary but not sufficient — it means the code works, not that the project succeeded. What changes in the real world? Fewer support tickets? Faster workflow completion? Higher conversion? Pick one metric you'll check 30 days after launch. If you can't name one, the project's value proposition might be unclear."
- **Smart-skip condition:** STRATEGIC-4 (Success Criteria) already defined a measurable success metric with a target value and timeframe. Skip if success criteria are quantified and time-bound.
- **Confirmation format:** "Based on interview: success = {metric} reaching {target} within {timeframe}. Measurement method: {how you'll check}. Confirm or modify?"
