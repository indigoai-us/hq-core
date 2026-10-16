---
name: brainstorm
description: Compare approaches to best-in-class prior art, merge existing work, verify cruft removal, and recommend the most durable design before PRD work.
allowed-tools: Read, Write, Edit, Grep, Glob, Bash(git:*), Bash(qmd:*), Bash(ls:*), Bash(date:*), Task, Bash(bash core/scripts/work-mesh-live-bind-trusted.sh:*), Bash(bash core/scripts/work-mesh-project-registration-offer.sh:*), Bash(bash core/scripts/register-project.sh:*), Bash, AskUserQuestion, WebSearch, Bash(bash core/scripts/read-policy-frontmatter.sh:*)
---

# Brainstorm - Structured Exploration

Think through a problem before committing to a PRD. Research HQ context, compare approaches, surface unknowns.

**Input:** The user's argument — typically `[company] <idea description or board idea ID>`.

**Pipeline:** idea capture --> **brainstorm** --> PRD --> run-project

## Guiding Principles

These shape every step below. When two steps pull in different directions, these win.

1. **Best long-term solution wins, not least effort.** Coding agents make code nearly free to write, so code volume and build effort are not costs to minimise. Pick the solution that is the most durable, flexible, resilient, scalable, cost-efficient to run (infrastructure spend), mature, and modern. The real costs are runtime spend, operational burden, fragility, and lock-in. Elegance still matters: prefer one well-designed system that merges or replaces several existing ones, because fewer systems are more resilient and cheaper to run. Judge approaches by what exists and runs after the change, not by how much code it takes.
2. **Find what already exists before proposing anything new.** Fast AI work produces duplicates: two skills, workers, scripts, or repos that do the same job. Step 2 sweeps for them. Every brainstorm states what it reuses, what it merges, and what it retires.
3. **Remove cruft as part of the solution.** Out-of-date or superseded material found during the sweep goes into the recommendation as a verified removal plan. The brainstorm verifies each removal (evidence plus user confirmation); the PRD carries it out. The brainstorm itself deletes nothing.
4. **Deeper, not bigger** (adapted from [be-ambitious](https://github.com/DannyMac180/skills/blob/main/be-ambitious/SKILL.md)). Keep the user's goal fixed, and raise the standard for that outcome: what an expert in the field would do that was not asked for, the rawest primary sources, named methods and tools, and an external check with a stated pass condition. Drop side quests and extra deliverables that do not serve the goal. The solution design itself is unbounded (Principle 7).
5. **Assume agent velocity.** A `/run-project` loop typically finishes in 1 to 3 hours what a human team once planned in months. Never shrink scope, defer the clean solution, or pick a hack because the full version "sounds long". Effort fields still use scope/risk sizing and session counts (policy `ai-velocity-time-sense`), never calendar estimates.
6. **Fresh, authoritative research.** Web research prefers primary sources (official docs, changelogs, release notes, maintainer repos, standards) published in the last 60 days. Training-data knowledge of tools, models, APIs, and pricing is treated as a hypothesis until a fresh source confirms it.
7. **Study the best, then go past them.** Research how the most advanced companies solve this problem for quality, UX, and speed: their engineering blogs, published architectures, open-source code, and shipped products. Use that as the reference bar, not the ceiling. Then design from first principles with no bounds on what is possible, and aim for a solution better than anything that exists. At least one approach is this clean-sheet design.


## Work Mesh Live — trusted bind (do this first)

As soon as Step 0 resolves `{co}`, and before any other tool call that touches project work, bind the session per
`.claude/skills/_shared/work-mesh-live-bind.md` (US-011):

```bash
bash core/scripts/work-mesh-live-bind-trusted.sh \
  --company "{co}" --project "{project}" --task "{task}"
```

Omit `--task` when unknown. This writes `workspace/sessions/<sid>/meta.yaml`
and reconciles with `observation.trustedContext` (no `--trusted` CLI flag).

## Step 0: Parse Input & Company Anchor

Check if the **first word** of the user's input matches a company slug in `companies/manifest.yaml`.

**How to check:** Read `companies/manifest.yaml`. Extract top-level keys (company slugs). If the first word exactly matches one:

1. **Set `{co}`** = matched slug. Strip from input — remaining text is the description
2. **Announce:** "Anchored on **{co}**"
3. **Bind the session** — run `bash core/scripts/work-mesh-live-bind-trusted.sh --company "{co}"` now, before any read under `companies/{co}/`. The scope guard blocks company paths until the session is bound to `{co}`.
4. **Load policies (frontmatter-only)** — Collect the eligible files for the resolved company, except `example-policy.md`, preserve their order, and split the stable file order into consecutive chunks of at most 40 files. For each chunk, run `bash core/scripts/read-policy-frontmatter.sh {file1} {file2} ...` once with each path as a separate argument. Keep each call under 30 KB of output. The first output block belongs to the chunk’s first file argument; each later block belongs to the path named by its preceding `# --- policy-file: <path> ---` separator. Note `enforcement: hard` titles. For hard-enforcement policies only, additionally Read the `## Rule` section with a targeted range
5. **Scope qmd searches** — If company has `qmd_collections` in manifest, use `-c {collection}`

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
2. If `{co}` not set: scan all `companies/*/board.json` for the ID (use manifest `board_path` list). Once found, set `{co}` and bind the session as in Step 0 before reading further
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
- Read `core/workers/registry.yaml` — identify workers with skills matching the description

**Policies (anchored only):**
- Already loaded in Step 0. Note any constraints that affect approach selection

**Target repo (if inferable):**
- Note existence, don't deep-read. If repo has qmd collection, run scoped search

### Overlap & Cruft Sweep (always run)

Search for anything that already does part of the job, inside the company scope plus HQ core. Cover every surface, using 3 to 5 keyword variants of the idea (synonyms, the verb, the output it produces):

| Surface | Where to look |
|---|---|
| Code and repos | the company's `repos:` list in `companies/manifest.yaml`; `grep -rl` / `qmd` inside those repos for the key nouns and verbs |
| Infrastructure | manifest `deploy:` / `vercel_projects:` / `sources:`, `hq integrations list --usable`, existing deploy targets and services |
| Workers | `core/workers/registry.yaml` and `companies/{co}/workers/` |
| Skills and commands | `.claude/skills/`, `companies/{co}/skills/`, `personal/skills/` (HQ work only) |
| Projects and ideas | `companies/{co}/projects/*/` (brainstorm.md, prd.json status), `board.json` entries in any status, including in-flight and parked |
| Knowledge and policies | qmd hits from above, `companies/{co}/policies/`, `core/policies/` |

When the surface is broad, delegate the sweep to an `Explore` subagent with the keyword list and the table above, and have it return paths plus one-line verdicts.

Give every hit one verdict:

- **Reuse** — does the job as is; the solution calls it
- **Extend** — does most of the job; the solution builds on it
- **Merge** — overlaps another hit or the new idea; the solution combines them into one
- **Replace** — the new solution supersedes it; it gets retired
- **Unrelated** — keyword match only; drop it

**Cruft verification.** A hit is a removal candidate when it is superseded, duplicated, or out of date. Before listing it, collect evidence for each candidate:

1. Last change: `git -C {repo} log -1 --format=%cs -- {path}` (or file mtime outside git)
2. Live references: grep for its name or path across skills, hooks, workers, scripts, and repos; zero callers is strong evidence
3. Status: board/PRD status, deprecated markers, a newer item that does the same job
4. Blast radius: what breaks if it goes (callers, docs, scheduled jobs, deployed services)

Only candidates with evidence go forward. Each one is confirmed with the user in Step 3 (`Q-retire`) and, once confirmed, becomes part of the recommendation's removal plan. The brainstorm never deletes anything itself (**No execution** rule).

Write the full sweep to `research/hq-landscape.md` (Step 4, Layer 1).

Present compact summary:
```
Research complete:
- Related projects: {list or "none found"}
- Relevant workers: {list}
- Existing code/skills/infra: {hits with verdict: reuse / extend / merge / replace}
- Removal candidates: {count, with one-line evidence each, or "none"}
- Policies: {count loaded}
- Prior art: {relevant knowledge hits or "none"}
```

### Premise Challenge (always run, both modes)

After research, before asking the user anything, challenge the premise:

1. **Is this the right problem?** What assumption must be true for this to matter?
2. **What happens if we do nothing?** Is inaction a viable option?
3. **What already exists to build on?** Check the sweep first: a Reuse or Extend hit is the foundation, and a mature external platform may beat a custom build on durability and running cost. Do not pick a smaller, weaker solution because it is quicker to build.

State a position. Don't hedge. If the premise is weak, say so before exploring approaches. This may eliminate the need for a full brainstorm.

Present as:
```
Premise check:
- Core assumption: {what must be true}
- Inaction cost: {what happens if we skip this}
- Foundation: {existing item or mature platform to build on, or "none — clean sheet"}
- Verdict: {STRONG / QUESTIONABLE / WEAK}
```

If verdict is WEAK: flag it and ask the user if they want to continue or reconsider.

## Step 3: Interview (grilling engine, one question at a time)

This is a grilling in the wayfinder sense: the agent asks, the human answers, one question per exchange. Never stand in for the human's side of the exchange.

Run the grilling engine (`.claude/skills/grilling/SKILL.md`) with:

- `question_set`: `.claude/skills/_shared/questions/brainstorm.md` (STARTUP and BUILDER sets as `depends_on` branches on the `Q-mode` fact)
- `known_facts`: `Q-mode` from Step 0.5, `Q-company` from Step 0 or Step 1, and any question already answered by the args, the board entry, a prior turn, or Step 2 research
- `mode`: `one-at-a-time` (one `AskUserQuestion` per question) unless the user passed `--rounds`

Each question is its own `AskUserQuestion` call with 2 to 4 options pre-filled from Step 2 research. Mark the first option `(Recommended)` when research points to one answer. Never batch several decisions into one question, and never collapse the interview to a single question (`decision-queue-one-at-a-time`). If `Q-company` is still unresolved, ask it as a picker of plausible company slugs from `companies/manifest.yaml`.

When the sweep produced removal candidates, `Q-retire` is part of the interview: the user confirms which removals enter the plan.

If an answer opens a new decision (for example a constraint that changes the approach space), ask a follow-up the same way. The interview ends when no directional input is missing.

Record every answer in brainstorm.md under `## Interview Answers` as `Q-id: answer` lines. The plan phase (Step 8) and `/prd` load these ids as `known_facts`.

### Interactive checkpoint after research (optional but encouraged)

Before starting the interview, if Step 2 surfaced a strong prior-art hit (existing project, near-duplicate worker, dead-end policy), AskUserQuestion ONCE: "Proceed with new brainstorm / Extend existing {project} / Park — duplicate of {X}." This prevents redundant brainstorms.

## Step 4: 3-Layer Landscape Research (stored to the project)

Research in layers, and **write the findings down** — every substantive research pass produces a markdown note under the project's `research/` directory (wayfinder assets pattern: notes are linked from the brainstorm, not pasted into it):

```
{project_dir}/research/
  hq-landscape.md        # Layer 1 — prior art, related projects, workers, policy constraints
  market-landscape.md    # Layer 2 — alternatives, comparable tools, pricing, dynamics
  web-{topic}.md         # Layer 3 — one note per live-web investigation, with sources
```

Where `{project_dir}` is `companies/{co}/projects/{slug}/` (or `personal/projects/{slug}/` for personal/HQ). Each note gets a one-line frontmatter-style header (`layer`, `date`, `question it answers`). Notes survive context compaction and feed `/prd` and `/deep-plan` directly — brainstorm.md links them, it never restates them in full.

**Layer 1 — HQ (always, from Step 2):**
qmd, workers, policies, existing projects, and the Overlap & Cruft Sweep. Distil the Step 2 findings into `research/hq-landscape.md`: the hits that mattered with their verdicts, the removal candidates with evidence, and the policy constraints that shape the approach space.

**Layer 2 — Reasoning (always, free):**
Competitive landscape, known tools, pricing, market context from training data. No API calls needed. Identify alternatives, comparable tools, known pricing tiers, and market dynamics. Write `research/market-landscape.md`. Training data is stale for fast-moving topics (AI models, agent tooling, SDKs, APIs, pricing): mark those claims `unverified` and check them in Layer 3.

**Layer 3 — Live Web (default-on for external-facing ideas):**
Run live web research whenever the idea touches an external API/service, a library or model, an unfamiliar domain, a competitive market, or the user asked for research. Skip only for purely internal tooling on platforms you know cold. Announce what you'll search for and why before searching (user continuing counts as approval). Write one `research/web-{topic}.md` per investigation, with sources cited. For deep multi-source questions, delegate to research subagents (Task/Agent) and have each write its own note.

Freshness and authority rules for Layer 3:

- Get today's date with `date +%F` and put the current month and year in queries ("{topic} changelog {Month YYYY}").
- Prefer primary sources: official docs, changelogs, release notes, maintainer repos and issues, standards bodies, vendor engineering blogs. Use aggregators and SEO listicles only to find a primary source.
- Default window is the last 60 days. Cite every source with its publish or last-updated date. A source older than 60 days is used only when nothing newer covers the point, and is labelled `stale ({date})` in the note.
- Where a fresh source contradicts Layer 2, the fresh source wins; record the correction.
- Name the expert methods and tools the field uses for this problem (Guiding Principle 4), from sources, not invented.
- Always write `research/web-best-in-class.md` when Layer 3 runs: how the most advanced companies solve this problem (architecture, UX, speed, quality bar), each point with a dated primary source (Guiding Principle 7).

**Depth guidance:** more research is better than less **as long as it is stored** — a finding that lives only in context is wasted. Stop a layer when new passes stop changing the approach comparison, not at a fixed effort cap.

## Step 5: Generate brainstorm.md

**Derive slug** from title (lowercase, hyphens, no special chars).

**Create** `companies/{co}/projects/{slug}/brainstorm.md` (or `personal/projects/{slug}/brainstorm.md` for personal/HQ):

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

## Research

<!-- index of research/ notes — gist + link, never the full content -->

- [HQ landscape](research/hq-landscape.md) — {one-line gist}
- [Market landscape](research/market-landscape.md) — {one-line gist}
- [{Web topic}](research/web-{topic}.md) — {one-line gist} *(if Layer 3 ran)*

## What We Know

- {Confirmed fact from HQ research — existing projects, prior work, tech constraints}
- {Relevant worker or knowledge base that exists}
- ...

## What We Don't Know

- {Open question that would change the approach}
- {Assumption that needs validating}
- {Missing info that blocks confident decision-making}
- ...

## Overlap & Cruft

| Existing item | Path | What it does | Verdict |
|---|---|---|---|
| {skill / worker / repo / script / project} | {path} | {one line} | {reuse / extend / merge / replace} |

**Removal candidates (confirmed in Q-retire):**
- {path} — {why it is cruft: superseded by X / zero callers / last changed {date}} · blast radius: {callers or "none"}

## Interview Answers

Q-direction: {answer}
Q-success: {answer}
{one `Q-id: answer` line per Step 3 answer}

## Premise Check

{Position on whether the core assumption holds. State verdict: STRONG / QUESTIONABLE / WEAK}

## Narrowest Wedge *(STARTUP mode only)*

{Smallest version that delivers real value to one specific person. What's the narrowest scope — one seam, not the whole subsystem?}

## Approaches

### Option A: {Name}

**How it works:** {2-3 sentences describing the approach}

**Reuses / merges / retires:** {existing items it builds on, combines, or removes}
**Systems after the change:** {what exists and runs afterwards, e.g. "1 service replaces 2 scripts and a cron"}
**Scorecard:** durable {H/M/L} · flexible {H/M/L} · resilient {H/M/L} · scalable {H/M/L} · infra cost {H/M/L running spend} · mature {H/M/L} · modern {H/M/L}

**Tradeoffs:**
- Pro: {specific advantage}
- Pro: {specific advantage}
- Con: {specific cost or risk}

**Effort:** {S / M / L / XL — scope/risk} · {throughput: ~N sessions, sequential|concurrent-able}
**When to choose this:** {specific signal or condition that makes this the right pick}

---

### Option B: {Name}

**How it works:** {2-3 sentences}

**Reuses / merges / retires:** {items}
**Systems after the change:** {what exists and runs afterwards}
**Scorecard:** durable · flexible · resilient · scalable · infra cost · mature · modern {H/M/L each}

**Tradeoffs:**
- Pro: {specific advantage}
- Con: {specific cost or risk}

**Effort:** {S / M / L / XL — scope/risk} · {throughput: ~N sessions, sequential|concurrent-able}
**When to choose this:** {condition}

---

### Option C: {Name} *(only if genuinely distinct from A and B)*

...

---

## Recommendation

**Preferred approach:** Option {X} — {one sentence on why}

**Key condition:** {What would make you choose a different option instead}

**Biggest risk:** {The one thing most likely to blow up the preferred approach}

**Best-in-class reference:** {who does this best today and what they do, linked to `research/web-best-in-class.md`}

**Where we go past it:** {what the recommended design does better than the reference, from first principles}

**Removal plan:** {each confirmed removal candidate, what replaces it, and the check that proves it is gone safely (zero references, tests pass), or "none"}

### Expert standard *(deeper, not bigger)*

- **Expert moves:** {2-3 things an expert would do for this same outcome that the request did not ask for}
- **Rawest material:** {primary sources or data the build should start from}
- **Methods and tools:** {named techniques or libraries, and why each fits}
- **External verification:** {the check outside the model and the user, with its pass and fail condition}

## Next Steps

- [ ] {Specific validation task or question to resolve before starting PRD}
- [ ] {Other prerequisite}
- [ ] {One line per confirmed removal: "Retire {path}, replaced by {X}"}

**Promotion path:**
- Ready to build --> promote to a PRD with `/prd` (brainstorm.md pre-populates the interview)
- Needs more research --> edit this file, revisit later
- Not worth pursuing --> park as idea on the board
```

**Approach rules:**
- Generate exactly 2 approaches if the problem is well-defined
- Generate 3 only if there's a genuine third dimension (build vs buy, now vs later, etc.)
- Never more than 3 — collapse similar options or pick the most distinct
- Each option must differ on at least one of: effort, reversibility, dependency, or user experience
- Must state a recommendation — no "it depends" without a stated override condition
- When the sweep found two or more items doing related jobs, one option must merge or replace them
- One option is always the first-principles clean-sheet design (Guiding Principle 7), set against the best-in-class reference
- Rank options on the scorecard: durable, flexible, resilient, scalable, infra cost, mature, modern. Never rank by lines of code or build effort. Recommend the strongest scorecard unless a stated condition overrides it
- Do not cut scope or pick a stopgap for time reasons: a `/run-project` loop clears months of former human work in 1 to 3 hours
- T-shirt effort = scope/risk, NOT calendar time (policy `ai-velocity-time-sense`): S (one seam, low risk), M (one subsystem, modest unknowns), L (multiple seams, real unknowns), XL (cross-cutting, hard-to-reverse). If "how long" is needed, use sessions + concurrency ("~2 sessions, parallel-able"), never weeks/months. Be honest about breadth

## Step 6: Board Integration

Read `companies/{co}/board.json`.

**If started from existing board idea** (`source_idea_id` set):
- Find that entry by ID
- Update `status` --> `"brainstormed"`
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
    "status": "brainstormed",
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

### Offer Work Mesh registration for a cloud-backed project

After the Board entry is written, check whether the entry has a Work Mesh
registration:

```bash
bash core/scripts/work-mesh-project-registration-offer.sh --check {co} {board-project-id}
```

If it prints `offer`, ask once with `AskUserQuestion` and these options:
`Create the Work Mesh project now` and `Not now`. This offer is controlled by
the default-off `workmesh.offer-project-create-on-brainstorm` hq-flags key.
On acceptance, record the choice and register the existing Board entry:

```bash
bash core/scripts/work-mesh-project-registration-offer.sh --accept {co} {board-project-id}
bash core/scripts/register-project.sh --brainstorm {co} {board-project-id}
```

Verify registration from the script's `registered {co}/{board-project-id}`
line. On `Not now`, call `--defer` for that entry; do not register it, and do
not ask again for that entry. `accepted`, `deferred`, `registered`, `local`,
`off`, or `missing` means no prompt is needed. If an accepted registration
previously failed, retry it without asking again.

## Step 6.4: Open Session Journal

Spec: `core/knowledge/public/hq-core/journal-spec.md`. Open a session journal at the project_dir so research, decisions, and dead ends survive context compaction:

```bash
.claude/skills/_shared/journal.sh open brainstorm "{project_dir}"
```

Where `{project_dir}` is `companies/{co}/projects/{slug}/` (or `personal/projects/{slug}/` for personal/HQ). The helper:

- Creates `{project_dir}/journal/{ISO8601}-brainstorm.md` with frontmatter (`status: active`, `skill: brainstorm`, `summary: ""`)
- Writes a session-scoped pointer at `.claude/state/active-journal.d/` so only this session's subsequent steps and autocapture hook append to this file
- Stays open across `/prd`, `/deep-plan` handoffs — only `/handoff` and `/checkpoint` close it

After the helper returns, append a curated entry summarizing the brainstorm outcome (preferred approach, biggest risk, open questions) to the journal's `## Decisions` section. The autocapture hook will append a `## Auto-capture` line for any subsequent Agent / WebFetch / WebSearch / AskUserQuestion calls in this session.

**Skip if:** journal helper is unavailable (fail-soft, don't error).

## Step 6.5: Spawn Knowledge Pulse (Background)

If `{co}` is resolved and company has a knowledge directory (not `null` in manifest):

Use the background `Task` tool without worktree isolation so the child stays in this canonical HQ checkout.

```
Task({
  subagent_type: "general-purpose",
  description: "Pulse-garden {co} knowledge",
  run_in_background: true,
  prompt: "Run the knowledge-pulse skill at .claude/skills/knowledge-pulse/SKILL.md.
    company_slug: {co}
    knowledge_path: companies/{co}/knowledge/
    policies_path: companies/{co}/policies/
    caller: brainstorm
    qmd_collection: {qmd_collections[0] from manifest, or omit if none}
    search_results_summary: {condensed list of qmd hits from Step 2, max 10 items — path + title per hit}
    discovered_facts: {any new company facts surfaced during premise check or research, or 'none'}
    Read the skill file for full instructions."
})
```

Do NOT wait for the pulse to complete — continue immediately to Step 7.

**Skip if:** company has no knowledge directory.

## Step 6.6: Deploy Visual Brainstorm Deck

The brainstorm is written. Automatically deploy a **visual research deck** so the findings are
shareable, not just a markdown file — the framing, what we know / don't know, the premise
verdict, the approaches compared with their tradeoffs, and the recommendation, rendered on the
company's design standards.

Invoke the `project-summary` skill in **deck mode** on this brainstorm:
`project-summary {co}/{slug} --brainstorm` (for personal/HQ brainstorms the path is
`personal/projects/{slug}` and it falls back to a password gate). It reads `brainstorm.md`,
renders a branded deck, deploys it company-gated via hq-deploy, and returns a live URL.

**Runs once per session.** Run the deck deploy after the Step 7 gate, not before it. When the gate answer is `Stop here` or `Upgrade to deep-plan`, deploy the brainstorm deck as described here. When the gate answer is `Plan it now`, defer this deploy: the project summary deploy at the end of Step 8 covers the brainstorm and the PRD, and only that one link is reported.

Rules for this step:
- **Visualization only** — it reads `brainstorm.md` and writes no project files; this does not
  violate the "brainstorm.md + board.json are the only files written" rule (the deck is a
  deploy artifact under `workspace/`, not a project file).
- **Non-fatal** — if the build or deploy fails (no HQ identity, offline, etc.), log a one-line
  note and continue. The brainstorm must never be blocked by the deck deploy.
- Capture the returned URL (or `skipped — {reason}`, or `deferred to plan phase`) and surface it in the final summary.

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
```

The project folder is delegatable as it stands: `/delegate <who> {slug}` hands
over `brainstorm.md`, `research/`, and the latest journal entry, tells the
recipient there is no PRD yet, and points them at `/prd {slug}`. No `prd.json`
is needed first.

Reindex: `qmd update 2>/dev/null || true`

### Plan gate

After the confirm, ask one `AskUserQuestion` with exactly three options, in this order:

1. `Plan it now` — add `(Recommended)` when the brainstorm recommends a single approach
2. `Upgrade to deep-plan`
3. `Stop here`

Handle the answer:

- **Plan it now**: continue to Step 8 in this session.
- **Upgrade to deep-plan**: run the Step 6.6 deck deploy, then print `Next: /deep-plan {co} {slug} (brainstorm: {brainstorm_path})` and stop. Do not write prd.json.
- **Stop here**: run the Step 6.6 deck deploy, print the deck URL, and stop. Board status stays `brainstormed` (the Step 6 board entry is not advanced), and prd.json is not written.

## Step 8: Plan Phase (only after the gate answers Plan it now)

The plan phase is the only part of this skill that writes prd.json. It reuses the `/prd` interview and finalize steps so the user does not re-answer questions.

1. **Interview.** Run the grilling engine with `question_set: .claude/skills/_shared/questions/prd.md`, `mode: one-at-a-time`, and `known_facts` loaded from the Phase B answers: every `Q-id: answer` line in brainstorm.md whose id exists in the PRD question set, plus answers the PRD set's `prefill:` hints take from brainstorm.md (Context, Recommendation, rejected approaches). Do not re-ask loaded ids as confirmations.
2. **Generate.** Write `{project_dir}/prd.json` and `{project_dir}/README.md` following `/prd` Step 5 (`.claude/skills/prd/SKILL.md`), including `metadata.interview` from the engine count object. Every item in the brainstorm's **Removal plan** becomes its own story (or acceptance criteria on the story that replaces it), with the removal check as its acceptance test. Carry the **External verification** pass condition into the PRD's acceptance criteria. Run `bash core/scripts/prd-interview-check.sh {project_dir}/prd.json` and show any warning.
3. **Finalize.** Follow `.claude/skills/_shared/prd-finalize.md` in order as caller `/prd`. Step 5.5 sets brainstorm.md frontmatter to `status: promoted` with `promoted_to: {project_dir}/prd.json`. Step 5.6 sets the board entry to `prd_created`. Step 5.7 runs Work Mesh registration, which is where policy `hq-work-mesh-prd-genesis` fires; do not skip it.
4. **Deploy once.** Run the project summary deploy that policy `auto-deploy-project-summary-on-brainstorm-prd` requires for a finished PRD (`project-summary {co}/{slug}`). This one deploy covers the brainstorm and the PRD, because Step 6.6 was deferred. Report only this link.
5. **Confirm.** Print the `/prd` Step 9 summary and stop. Do not start execution.

## Phases

| Phase | Steps | Files written |
|-------|-------|---------------|
| A (research) | 0 to 2, 4 | `{project_dir}/research/*.md` |
| B (interview) | 3 | none; answers go into brainstorm.md in Phase C |
| C (brainstorm) | 5 to 7 | `brainstorm.md`, `board.json`, journal |
| Plan | 8 | `prd.json`, `README.md`, `board.json`, brainstorm.md frontmatter |

## Final step — auto-checkpoint <!-- AUTO-CHECKPOINT-ON-COMPLETION -->

Once the gate is answered and its branch has finished, automatically save a lightweight checkpoint so the user can continue in a fresh session without a manual `/handoff`. This only **snapshots** continuity — it does **not** close the brainstorm (which stays open across `/prd`).

Write `workspace/threads/T-{UTC YYYYMMDD-HHMMSS}-auto-brainstorm-{slug}.json` with: `thread_id`, `version: 1`, `type: "auto-checkpoint"`, `created_at`, `updated_at`, `workspace_root`, `cwd`, `git: { branch, current_commit, dirty }`, `conversation_summary` (topic + recommended option, one sentence), `files_touched` (include the `brainstorm.md` path, and `prd.json` and `README.md` when Step 8 ran), `phases` (a map from each touched file to the phase that produced it: `A`, `B`, `C`, or `plan`, as listed in the Phases table), `gate_answer` (`Plan it now`, `Upgrade to deep-plan`, or `Stop here`), `next_steps` (e.g. "promote to PRD with `/prd`, or refine `brainstorm.md`"), and `metadata: { title: "Auto: brainstorm {slug}", tags: ["auto-checkpoint", "brainstorm"], trigger: "brainstorm-complete" }`.

Keep it cheap: do **not** rebuild INDEX, update `recent.md`, run `qmd update`, or write a legacy checkpoint. Then tell the user a fresh session can resume from this checkpoint (`/startwork`).

## Rules

- **Scan HQ before asking anything** — research phase (Step 2) happens before the first question. Never ask for info findable in qmd, board.json, or policies
- **Sweep for overlap every time** — no brainstorm skips the Overlap & Cruft Sweep. A recommendation that builds something HQ or the company already has is a defect
- **Removals are verified, not assumed** — each removal candidate carries evidence (last change, live references, superseded-by) and the user's `Q-retire` confirmation before it enters the plan
- **Quality over effort** — never recommend an option because it is less code or quicker to build. Code is cheap with coding agents; runtime cost, fragility, and lock-in are not
- **Fresh sources for fast-moving facts** — tool, model, API, and pricing claims cite a primary source from the last 60 days, or are labelled stale or unverified
- **One question AT A TIME, not one total** — the gate and every interview question is its own `AskUserQuestion` call (decision-queue style per `decision-queue-one-at-a-time`). Ask every unresolved field; skip any already clear from args/research. Never batch multiple decisions into a single combined question, and never collapse the full interview to a single question. 4–8 questions is a normal interview
- **2-3 approaches, no more** — present distinct options, not variations. If only one reasonable path exists, say so and explain why
- **State a recommendation** — "it depends" without a stated override condition is not a recommendation
- **No execution** — brainstorm.md is the output. Do NOT write code, scaffold repos, or modify any implementation files
- **Phases A through C never write prd.json; only the plan phase does, after the gate** — Step 8 runs only when the gate answers `Plan it now`
- **No Linear sync** — brainstorms are pre-planning. Linear happens at PRD time
- **No orchestrator registration** — brainstorms are not executable
- **Research is stored, not ephemeral** — every substantive research pass writes a note under `{project_dir}/research/`, linked from brainstorm.md. Live web research is default-on for external-facing ideas; skip only for purely internal tooling on well-known platforms
- **board.json + brainstorm.md + research/ notes are the only project files written in Phases A through C** (the plan phase adds prd.json and README.md) — plus the final auto-checkpoint thread under `workspace/threads/` (see "Final step — auto-checkpoint"). No implementation/target files are modified (knowledge pulse runs as a background agent and writes its own report independently)
- **T-shirt effort, not story points** — sized by scope/risk, not calendar time: S (one seam), M (one subsystem), L (multiple seams + unknowns), XL (cross-cutting, hard-to-reverse). See policy `ai-velocity-time-sense`
- **Company isolation enforced** — if anchored, scope all searches to that company. Never mix company knowledge in approaches
- **brainstorm.md is human-editable** — the user may refine it after generation. The PRD skill reads whatever is in the file, not just what was machine-generated
- **Do not create README.md** — brainstorm.md is self-contained
- **Anti-sycophancy** — Never say "that's interesting," "great idea," "excellent question." Take a position immediately. If the premise is weak, say so before exploring approaches. State which approach you'd actually build and why. Brainstorm is for honest analysis, not validation

## See also

- `/prd` — turn the chosen approach into a PRD
- `/idea` — capture it on the board first
- `/wayfinder` — when the effort is too big for one brainstorm and the destination is foggy; brainstorm is its grilling engine. Interview + stored-research pattern adapted from [mattpocock/skills](https://github.com/mattpocock/skills)
