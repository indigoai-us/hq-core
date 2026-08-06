---
name: architect
description: |
  Surface architectural friction and propose deepening opportunities — turn shallow modules into deep ones for better testability and AI-navigability.
  Output: ranked candidate list with deletion-test outcome, leverage/locality scoring, file refs. Never edits code directly; presents candidates and walks the user through grilling-style design decisions for picked candidates.
  Use when the codebase is hard to change, when /diagnose hands off "no good test seam," or when planning a refactor wave.
allowed-tools: Read, Grep, Glob, Bash, Agent, Write, Edit, AskUserQuestion
---

# Architect

Find places where the architecture is the bug. Pattern adapted from `mattpocock/skills` `improve-codebase-architecture`.

## Glossary — see `/codebase-design`

`/codebase-design` is the **single source of truth** for the deep-module vocabulary — **module, interface, implementation, depth, seam, adapter, leverage, locality**. Load it for the full definitions and use those terms exactly; never drift into "component," "service," "API," or "boundary."

One-line summary: a **deep** module puts a lot of behaviour behind a small **interface** at a clean **seam** — **depth** buys **leverage** for callers and **locality** for maintainers.

Key heuristics (full treatment in `/codebase-design`):

- **Deletion test:** imagine deleting the module. If complexity vanishes, it was a pass-through. If complexity reappears across N callers, it was earning its keep.
- **The interface is the test surface.**
- **One adapter = hypothetical seam. Two adapters = real seam.**
- **Side effects belong inside deepened modules**, not at the call site.

## Process

### Step 0 — Resolve company + path

1. Honour explicit `[company] [path]` arguments
2. Default `path` to cwd if cwd is inside `repos/`; else ask via `AskUserQuestion`
3. Resolve company from manifest if path is under `companies/{co}/repos/...`

### Step 1 — Read the project's domain model + decisions

- Read `<repo>/CONTEXT.md` if present (domain glossary)
- Read `<repo>/docs/adr/` if present (architectural decisions)
- Read `<repo>/core/policies/` for any soft architecture rules

If `CONTEXT.md` exists, **always** use its vocabulary in candidate descriptions. ADRs record decisions the skill should not re-litigate; mark candidates that contradict an ADR with `_contradicts ADR-NNNN — but worth reopening because…_` and only when friction is real.

### Step 2 — Fan out exploration

Spawn parallel `Agent subagent_type=Explore` calls — one per top-level slice of the target. Each agent:

- Walks its slice
- Notes friction in the architecture glossary's vocabulary
- Returns ≤500 words under fixed headings: **Shallow modules**, **Tightly coupled seams**, **Untested interfaces**, **Pass-throughs (deletion-test wins)**

### Step 3 — Score and rank candidates

For each friction point, assign:

| Dimension | Question | Score 1-3 |
|---|---|---|
| **Deletion test** | Would deleting this concentrate complexity? | 3 = yes, strong; 1 = no, just moves it |
| **Leverage** | Behaviour-to-interface ratio after deepening | 3 = high (lots behind a small interface); 1 = low |
| **Locality** | Change/bug concentration after deepening | 3 = single place; 1 = stays scattered |
| **Test surface** | Does the deepened interface become a useful test seam? | 3 = yes, replaces N small unit tests; 1 = no improvement |
| **Cost** | Refactor effort | 3 = small; 1 = large |

Sum to a single rank. Present top 5–10.

### Step 4 — Present candidates (no edits yet)

Output via numbered list, NOT `AskUserQuestion` first (the list is too long for a 4-option question — present then ask):

```markdown
## Candidate N — <name in CONTEXT.md vocabulary>

**Files:** <file:line refs>
**Problem:** <friction described in glossary terms>
**Solution (plain English):** <what would change>
**Benefits:** locality: <X>, leverage: <Y>, test improvement: <Z>
**Score:** <total> (deletion: <d>, leverage: <l>, locality: <lo>, test: <t>, cost: <c>)
**Recommendation:** <Strong / Worth exploring / Speculative>
**ADR conflicts:** <none / contradicts ADR-NNNN — re-open because …>
```

The **Recommendation** badge is a plain-English read on top of the numeric score: `Strong` = high score and low risk, tackle first; `Worth exploring` = real friction but non-trivial cost or uncertainty; `Speculative` = plausible but the case isn't proven yet. Show both — the number ranks, the badge conveys confidence.

Then ask via `AskUserQuestion` (multiSelect: true): "Which candidates do you want to explore?" with up to 4 options (paginate if more).

### Step 5 — Grilling loop per picked candidate

For each picked candidate, drop into a one-question-at-a-time design conversation:

- What constraints does the deepened module need to satisfy?
- What goes behind the seam? What stays in callers?
- What's the interface — types, invariants, error modes, ordering, config?
- What tests survive the change? What new tests does the seam enable?
- Are there alternative interface shapes worth considering?

**Design it twice.** When the interface shape is non-obvious, don't settle on the first design. Reuse HQ's Explore fan-out: spin up parallel `Agent` sub-agents to design the deepened interface several *radically different* ways (e.g. a data-oriented shape, a callback/handler shape, a builder/pipeline shape). Then compare the returns on **depth** (behaviour-per-interface), **locality** (where change concentrates), and **seam placement** — and bring the winner (or a hybrid) back into the grilling conversation. See `/codebase-design`'s DESIGN-IT-TWICE.md for the pattern.

**Side effects happen inline:**

- Naming a deepened module after a concept not in `CONTEXT.md` → add the term lazily.
- Sharpening a fuzzy term during the conversation → update `CONTEXT.md` right there.
- User rejects with a load-bearing reason → offer `/adr`, framed as: _"Want me to record this as an ADR so future architecture passes don't re-suggest it?"_ Only offer for reasons future explorers would actually need; skip ephemeral or self-evident ones.

**Do not write the refactor.** This skill produces the design and the case for it. Implementation goes through `/run-project` or `/tdd`.

### Step 6 — Save report

Save to `workspace/reports/{slug}-architect.md`:

```markdown
# Architect: <repo> @ <path>

**HEAD:** <sha>
**CONTEXT.md present:** yes / no
**ADRs present:** <count>

## Candidates

### 1. <name> — DECISION: <explored / declined / pending>
<full block from Step 4>

#### Grilling notes (if explored)
<key questions + answers>

#### Outcome
- ADR opened: <yes / no — link>
- Implementation queued: <yes — /prd or /run-project ref / no>

### 2. …
```

## Output integration

| Outcome | Next step |
|---|---|
| Candidate explored, design crystallised | `/prd` (PRD with userStories[] for the refactor) or `/run-project` (if scope is small) |
| Candidate rejected with load-bearing reason | `/adr` |
| New domain term surfaced | already updated `CONTEXT.md` inline |
| Code change shouldn't proceed without test seam | hand off to `/tdd` |
| Pre-PR review on changed files only | `/review --architect-pass` |

## Rules

- **Never edit production code in this skill.** Candidates and design only.
- **Never propose interfaces in Step 4** — wait for the user to pick before designing.
- **Always use CONTEXT.md vocabulary for the domain.** Always use the architecture glossary for structure terms.
- **Don't list every theoretical refactor an ADR forbids.** Only surface ADR-contradicting candidates when the friction is real enough to warrant revisiting the decision.
- **Two-adapter rule before declaring a seam.** A single adapter is a hypothetical seam, not a real one — don't recommend abstracting until at least two concrete users exist.

## Cross-references

- `/diagnose` Phase 6 — entry point when "no good test seam" is the diagnosis.
- `/review --architect-pass` — narrower scope (changed files only); same heuristics.
- `/adr` — capture decisions that should not be re-litigated.
- `/prd` — turn explored candidates into PRD + userStories.
- `/tdd` — refactor under test once the candidate is designed.
- Pattern source: `mattpocock/skills` `improve-codebase-architecture` (`repos/public/skills/skills/engineering/improve-codebase-architecture/SKILL.md`).
