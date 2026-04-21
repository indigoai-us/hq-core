---
name: brainstorm
description: Explore approaches and tradeoffs before committing to a PRD. Research HQ context, compare options, surface unknowns, generate brainstorm.md with recommendation.
allowed-tools: Read, Write, Edit, Grep, Glob, Bash(git:*), Bash(qmd:*), Bash(ls:*), Bash(date:*)
---

# Brainstorm - Structured Exploration

Think through a problem before committing to a PRD. Research HQ context, compare approaches, surface unknowns.

**Input:** The user's argument — typically `[company] <idea description or board idea ID>`.

**Pipeline:** idea capture --> **brainstorm** --> PRD --> run-project

## Step 0: Parse Input & Company Anchor

Check if the **first word** of the user's input matches a company slug in `companies/manifest.yaml`.

**How to check:** Read `companies/manifest.yaml`. Extract top-level keys (company slugs). If the first word exactly matches one:

1. **Set `{co}`** = matched slug. Strip from input — remaining text is the description
2. **Announce:** "Anchored on **{co}**"
3. **Load policies (frontmatter-only)** — For each file in `companies/{co}/policies/` (skip `example-policy.md`), run `bash scripts/read-policy-frontmatter.sh {file}`. Note `enforcement: hard` titles. For hard-enforcement policies only, additionally Read the `## Rule` section with a targeted range. The SessionStart hook also injects the company policy digest at `companies/{co}/policies/_digest.md` — prefer that if present
4. **Scope qmd searches** — If company has `qmd_collections` in manifest, use `-c {collection}`

**If no match** -- full input is the description text. Company resolved later.

**Board ID detection:** After company check, see if remaining args match a board.json project ID pattern (`{prefix}-proj-{NNN}`). If so, this brainstorm is expanding an existing idea — proceed to Step 1 with that ID.

## Step 0.5: Mode Selection

Infer the brainstorm mode from context — no question needed:

- **STARTUP** — early-stage idea, no existing solution, exploring whether worth building. Default when: no existing board entry with `prd_path`, no prior art in HQ, greenfield domain
- **BUILDER** — existing product/system, designing a feature or extension. Default when: expanding existing project, board entry has `prd_path`, target repo already exists

Announce mode: `Mode: **STARTUP**` or `Mode: **BUILDER**`

Mode affects Steps 2-4 (premise challenge depth, question framing, research scope).

## Step 1: Resolve Company + Board Idea

**If board ID matched in Step 0:**
1. If `{co}` already set: read `companies/{co}/board.json`, find entry by ID
2. If `{co}` not set: scan all `companies/*/board.json` for the ID (use manifest `board_path` list)
3. Extract the entry's `title` and `description` as starting context
4. Set `source_idea_id` = matched ID

**If no board ID and no company:** infer from cwd (`companies/{slug}/` --> use that slug, `repos/{pub|priv}/{name}` --> manifest lookup). If still ambiguous, ask the user directly in Step 3.

**If input is empty:** go straight to Step 3 (full interview).

## Step 2: HQ Research (before any questions)

Do not ask questions yet. Build context from HQ first.

**Hybrid search (BM25 + vector + re-ranking):**
- If anchored + company has `qmd_collections`: `qmd query "<description keywords>" -c {collection} --json -n 10`
- If not anchored: `qmd query "<description keywords>" --json -n 10`

**Existing projects:**
- If anchored: search `companies/{co}/projects/` directly or `qmd search "prd.json" -c {co} --json -n 10`
- Read top 2-3 match metadata (name, description, status) to check for overlap

**Workers:**
- Read `workers/registry.yaml` — identify workers with skills matching the description

**Policies (anchored only):**
- Already loaded in Step 0. Note any constraints that affect approach selection

**Target repo (if inferable):**
- Note existence, don't deep-read. If repo has qmd collection, run scoped search

Present compact summary:
```
Research complete:
- Related projects: {list or "none found"}
- Relevant workers: {list}
- Policies: {count loaded}
- Prior art: {relevant knowledge hits or "none"}
```

### Premise Challenge (always run, both modes)

After research, before asking the user anything, challenge the premise:

1. **Is this the right problem?** What assumption must be true for this to matter?
2. **What happens if we do nothing?** Is inaction a viable option?
3. **What simpler/cheaper solution might already solve 80%?** Existing tool, manual process, or minor tweak?

State a position. Don't hedge. If the premise is weak, say so before exploring approaches. This may eliminate the need for a full brainstorm.

Present as:
```
Premise check:
- Core assumption: {what must be true}
- Inaction cost: {what happens if we skip this}
- 80% solution: {simpler alternative, or "none — this requires dedicated work"}
- Verdict: {STRONG / QUESTIONABLE / WEAK}
```

If verdict is WEAK: flag it and ask the user if they want to continue or reconsider.

## Step 3: Light Interview (1 question max)

Batch all missing directional info into **one** question posed directly to the user. Skip any field already clear from args, board entry, or research. Wait for the user's response before proceeding.

### STARTUP mode questions (include only what's missing):

1. **Demand Reality** — Who has this problem badly enough to hack a workaround today? Can you name a specific person or group?
2. **Status Quo** — What do they do right now? Why isn't that good enough?
3. **Narrowest Wedge** — What's the smallest starting point that delivers real value to one specific person?
4. **Direction + constraints** — Speed vs quality? Hard constraints? (timeline, must-use-tech, budget ceiling)
5. **Which company?** (only if not anchored and not inferrable from context)

### BUILDER mode questions (include only what's missing):

1. **What's the core problem or opportunity?** (skip if description is >15 words with clear intent)
2. **Which direction matters most?**
   - A. Speed to ship (MVP fast, iterate later)
   - B. Quality/durability (build it right once)
   - C. Exploration (prove or disprove a hypothesis first)
   - D. Cost minimization (cheapest viable path)
3. **Hard constraints?** (timeline, must-use-tech, budget ceiling, avoid-tech) — optional, free text
4. **Which company?** (only if not anchored and not inferrable from context)

**If all info is already clear** (description + company + direction obvious from context), skip the interview entirely.

## Step 4: 3-Layer Landscape Gate

Research in layers — stop as soon as you have enough signal. Don't research for thoroughness.

**Layer 1 — HQ (always, already done in Step 2):**
qmd, workers, policies, existing projects. Already complete.

**Layer 2 — Reasoning (always, free):**
Competitive landscape, known tools, pricing, market context from training data. No API calls needed. Run this as part of your analysis — identify alternatives, comparable tools, known pricing tiers, and market dynamics. 2-3 bullets.

**Layer 3 — Live Web (conditional, privacy-gated):**
**Only if:** idea involves a new API/service you're not confident about, unfamiliar domain, or user explicitly requested research.

Before searching: announce what you'll search for and why. Proceed only after implicit or explicit approval (user continuing the conversation counts as approval).

**If Layer 2 is sufficient** (internal tooling, known platforms — the common case): skip Layer 3 entirely.

## Step 5: Generate brainstorm.md

**Derive slug** from title (lowercase, hyphens, no special chars).

**Create** `companies/{co}/projects/{slug}/brainstorm.md` (or `projects/{slug}/brainstorm.md` for personal/HQ):

```markdown
---
company: {slug}
created_at: {ISO8601}
status: exploring
promoted_to: null
source_idea_id: {board ID or null}
---

# {Title}

> {1-sentence problem/opportunity framing}

## Context

{2-4 sentences: why this matters now, what triggered the exploration, rough size of the thing}

## What We Know

- {Confirmed fact from HQ research — existing projects, prior work, tech constraints}
- {Relevant worker or knowledge base that exists}
- ...

## What We Don't Know

- {Open question that would change the approach}
- {Assumption that needs validating}
- {Missing info that blocks confident decision-making}
- ...

## Premise Check

{Position on whether the core assumption holds. State verdict: STRONG / QUESTIONABLE / WEAK}

## Narrowest Wedge *(STARTUP mode only)*

{Smallest version that delivers real value to one specific person. What can you ship in days, not weeks?}

## Approaches

### Option A: {Name}

**How it works:** {2-3 sentences describing the approach}

**Tradeoffs:**
- Pro: {specific advantage}
- Pro: {specific advantage}
- Con: {specific cost or risk}

**Effort:** {S / M / L / XL}
**When to choose this:** {specific signal or condition that makes this the right pick}

---

### Option B: {Name}

**How it works:** {2-3 sentences}

**Tradeoffs:**
- Pro: {specific advantage}
- Con: {specific cost or risk}

**Effort:** {S / M / L / XL}
**When to choose this:** {condition}

---

### Option C: {Name} *(only if genuinely distinct from A and B)*

...

---

## Recommendation

**Preferred approach:** Option {X} — {one sentence on why}

**Key condition:** {What would make you choose a different option instead}

**Biggest risk:** {The one thing most likely to blow up the preferred approach}

## Next Steps

- [ ] {Specific validation task or question to resolve before starting PRD}
- [ ] {Other prerequisite}

**Promotion path:**
- Ready to build --> promote to PRD (brainstorm.md pre-populates the interview)
- Needs more research --> edit this file, revisit later
- Not worth pursuing --> park as idea on the board
```

**Approach rules:**
- Generate exactly 2 approaches if the problem is well-defined
- Generate 3 only if there's a genuine third dimension (build vs buy, now vs later, etc.)
- Never more than 3 — collapse similar options or pick the most distinct
- Each option must differ on at least one of: effort, reversibility, dependency, or user experience
- Must state a recommendation — no "it depends" without a stated override condition
- T-shirt effort: S (hours-days), M (days-week), L (week-month), XL (month+). Be honest

## Step 6: Board Integration

Read `companies/{co}/board.json`.

**If started from existing board idea** (`source_idea_id` set):
- Find that entry by ID
- Update `status` --> `"exploring"`
- Add `brainstorm_path: "companies/{co}/projects/{slug}/brainstorm.md"`
- Update `updated_at`

**If fresh brainstorm** (no existing board idea):
- Generate next ID: collect all `id` values from `projects` array, extract numeric suffixes from `{prefix}-proj-{NNN}` pattern, next = `{prefix}-proj-{max_N + 1}` zero-padded to 3 digits
- Append new entry:
  ```json
  {
    "id": "{prefix}-proj-{NNN}",
    "title": "{concise title}",
    "description": "{user's description}",
    "status": "exploring",
    "scope": "company",
    "app": null,
    "initiative_id": null,
    "objective_id": null,
    "prd_path": null,
    "brainstorm_path": "companies/{co}/projects/{slug}/brainstorm.md",
    "created_at": "{ISO8601}",
    "updated_at": "{ISO8601}"
  }
  ```

Write updated `board.json`.

## Step 6.5: Spawn Knowledge Pulse (Background)

If `{co}` is resolved and company has a knowledge directory (not `null` in manifest):

```
spawn_task(
  reason: "Pulse-garden {co} knowledge",
  prompt: "Run the knowledge-pulse skill at .claude/skills/knowledge-pulse/SKILL.md.
    company_slug: {co}
    knowledge_path: companies/{co}/knowledge/
    policies_path: companies/{co}/policies/
    caller: brainstorm
    qmd_collection: {qmd_collections[0] from manifest, or omit if none}
    search_results_summary: {condensed list of qmd hits from Step 2, max 10 items — path + title per hit}
    discovered_facts: {any new company facts surfaced during premise check or research, or 'none'}
    Read the skill file for full instructions."
)
```

Do NOT wait for the pulse to complete — continue immediately to Step 7.

**Skip if:** company has no knowledge directory.

## Step 7: Confirm & Reindex

Print:
```
Brainstorm: **{title}** ({id})
File: companies/{co}/projects/{slug}/brainstorm.md

Approaches:
  A. {Option A name} — {effort}
  B. {Option B name} — {effort}
  {C. Option C name — effort, if present}

Recommendation: Option {X}

Next: promote to PRD, edit brainstorm.md, or park on the board.
```

Reindex: `qmd update 2>/dev/null || true`

## Rules

- **Scan HQ before asking anything** — research phase (Step 2) happens before the first question. Never ask for info findable in qmd, board.json, or policies
- **1 question max** — direction + constraints in one message. If everything is clear from args/context, zero questions is fine
- **2-3 approaches, no more** — present distinct options, not variations. If only one reasonable path exists, say so and explain why
- **State a recommendation** — "it depends" without a stated override condition is not a recommendation
- **No execution** — brainstorm.md is the output. Do NOT write code, scaffold repos, or modify any implementation files
- **No prd.json** — this skill does NOT produce prd.json. That is the PRD skill's job
- **No Linear sync** — brainstorms are pre-planning. Linear happens at PRD time
- **No orchestrator registration** — brainstorms are not executable
- **Web research is conditional** — only if idea requires external context. Don't search for thoroughness
- **board.json + brainstorm.md are the only files written** — no other files modified (knowledge pulse runs as a background agent and writes its own report independently)
- **T-shirt effort, not story points** — S (hours-days), M (days-week), L (week-month), XL (month+)
- **Company isolation enforced** — if anchored, scope all searches to that company. Never mix company knowledge in approaches
- **brainstorm.md is human-editable** — the user may refine it after generation. The PRD skill reads whatever is in the file, not just what was machine-generated
- **Do not create README.md** — brainstorm.md is self-contained
- **Anti-sycophancy** — Never say "that's interesting," "great idea," "excellent question." Take a position immediately. If the premise is weak, say so before exploring approaches. State which approach you'd actually build and why. Brainstorm is for honest analysis, not validation
