---
name: brainstorm
description: Compare approaches, surface unknowns, and draft a recommendation before PRD work.
allowed-tools: Read, Write, Edit, Grep, Glob, Bash(git:*), Bash(qmd:*), Bash(ls:*), Bash(date:*), Task, Bash(bash core/scripts/work-mesh-live-bind-trusted.sh:*), Bash(bash core/scripts/work-mesh-project-registration-offer.sh:*), Bash(bash core/scripts/register-project.sh:*), Bash, AskUserQuestion, WebSearch, Bash(bash core/scripts/read-policy-frontmatter.sh:*)
---

# Brainstorm - Structured Exploration

Think through a problem before committing to a PRD. Research HQ context, compare approaches, surface unknowns.

**Input:** The user's argument — typically `[company] <idea description or board idea ID>`.

**Pipeline:** idea capture --> **brainstorm** --> PRD --> run-project


## Work Mesh Live — trusted bind (do this first)

Before any other tool call that touches project work, bind the session per
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
3. **Load policies (frontmatter-only)** — Collect the eligible files for the resolved company, except `example-policy.md`, preserve their order, and split the stable file order into consecutive chunks of at most 40 files. For each chunk, run `bash core/scripts/read-policy-frontmatter.sh {file1} {file2} ...` once with each path as a separate argument. Keep each call under 30 KB of output. The first output block belongs to the chunk’s first file argument; each later block belongs to the path named by its preceding `# --- policy-file: <path> ---` separator. Note `enforcement: hard` titles. For hard-enforcement policies only, additionally Read the `## Rule` section with a targeted range
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
- Read `core/workers/registry.yaml` — identify workers with skills matching the description

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

## Step 3: Interview (grilling engine, one question at a time)

This is a grilling in the wayfinder sense: the agent asks, the human answers, one question per exchange. Never stand in for the human's side of the exchange.

Run the grilling engine (`.claude/skills/grilling/SKILL.md`) with:

- `question_set`: `.claude/skills/_shared/questions/brainstorm.md` (STARTUP and BUILDER sets as `depends_on` branches on the `Q-mode` fact)
- `known_facts`: `Q-mode` from Step 0.5, `Q-company` from Step 0 or Step 1, and any question already answered by the args, the board entry, a prior turn, or Step 2 research
- `mode`: `one-at-a-time` (one `AskUserQuestion` per question) unless the user passed `--rounds`

Each question is its own `AskUserQuestion` call with 2 to 4 options pre-filled from Step 2 research. Mark the first option `(Recommended)` when research points to one answer. Never batch several decisions into one question, and never collapse the interview to a single question (`decision-queue-one-at-a-time`). If `Q-company` is still unresolved, ask it as a picker of plausible company slugs from `companies/manifest.yaml`.

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
qmd, workers, policies, existing projects. Distil the Step 2 findings into `research/hq-landscape.md` — the hits that mattered, the overlap verdict, the policy constraints that shape the approach space.

**Layer 2 — Reasoning (always, free):**
Competitive landscape, known tools, pricing, market context from training data. No API calls needed. Identify alternatives, comparable tools, known pricing tiers, and market dynamics. Write `research/market-landscape.md`.

**Layer 3 — Live Web (default-on for external-facing ideas):**
Run live web research whenever the idea touches an external API/service, an unfamiliar domain, a competitive market, or the user asked for research. Skip only for purely internal tooling on platforms you know cold. Announce what you'll search for and why before searching (user continuing counts as approval). Write one `research/web-{topic}.md` per investigation, with sources cited. For deep multi-source questions, delegate to research subagents (Task/Agent) and have each write its own note.

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

**Tradeoffs:**
- Pro: {specific advantage}
- Pro: {specific advantage}
- Con: {specific cost or risk}

**Effort:** {S / M / L / XL — scope/risk} · {throughput: ~N sessions, sequential|concurrent-able}
**When to choose this:** {specific signal or condition that makes this the right pick}

---

### Option B: {Name}

**How it works:** {2-3 sentences}

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

## Next Steps

- [ ] {Specific validation task or question to resolve before starting PRD}
- [ ] {Other prerequisite}

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
2. **Generate.** Write `{project_dir}/prd.json` and `{project_dir}/README.md` following `/prd` Step 5 (`.claude/skills/prd/SKILL.md`), including `metadata.interview` from the engine count object. Run `bash core/scripts/prd-interview-check.sh {project_dir}/prd.json` and show any warning.
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
